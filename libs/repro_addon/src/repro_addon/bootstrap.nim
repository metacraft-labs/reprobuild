## ``repro system addon bootstrap --plan <digest>``.
##
## Bootstrap turns a distribution host the preflight accepted into an
## add-on host:
##
## 1. **re-run the preflight** on the host and refuse unless its plan digest
##    is the one the operator acknowledged -- before anything is written;
## 2. **create the roots** (``/repro`` -- a btrfs subvolume on a btrfs root
##    -- ``/repro/store``, ``/var/lib/repro/{system,agent}``, ``/etc/repro``)
##    with their modes;
## 3. **install the trust anchors** (validated as ECDSA-P256 anchor files;
##    written by generation 0 itself) and **generate the secrets recipient
##    key on the host**, so its private half never travels: created with
##    its final mode ``0400`` in one ``open(O_CREAT|O_EXCL)``, never written
##    first and narrowed after;
## 4. **copy this very binary into the store** and verify the digest on the
##    store copy;
## 5. **apply generation 0** through the add-on layer, i.e. through
##    ``repro infra apply`` -- bootstrap has no apply code of its own;
## 6. **report**: write the first evidence record locally and print the
##    plan digest, generation id and recipient public key.
##
## What it must not do -- install, remove or upgrade a package; modify a
## path the preflight saw; open a port; leave a credential other than the
## recipient key -- is what ``e2e_addon_bootstrap_changes_nothing_preexisting``
## checks, by requiring the fingerprint diff to equal generation 0's ledger.

import std/[json, os, posix, strutils, times]

import repro_core
import repro_infra
import repro_peer_cache/auth as peerAuth
import repro_peer_cache/key_types

import ./addon_apply
import ./fingerprint
import ./generation0
import ./host_exec
import ./ledger
import ./mutations
import ./preflight
import ./store_root

type
  AddonBootstrapError* = object of CatchableError
  AddonPlanMismatch* = object of AddonBootstrapError
    ## The host's plan is not the one the operator acknowledged.

  BootstrapOptions* = object
    planDigest*: string
    deploySignersPath*: string
    cachePublishersPath*: string
    cacheUrl*: string
    stateDir*: string

  BootstrapResult* = object
    planDigest*: string
    generationId*: string
    binarySha256*: string
    reproExe*: string
    recipientPublicKeyHex*: string
    ledger*: Ledger

const
  AgentDir* = "/var/lib/repro/agent"
  RecipientKeyPath* = AgentDir & "/recipient.key"
  RecipientPubPath* = AgentDir & "/recipient.pub"
  KeyFileMarker = "ecdsa-p256:"

var ONoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

proc hexOf(bytes: openArray[byte]): string =
  const digits = "0123456789abcdef"
  for b in bytes:
    result.add(digits[int(b) shr 4])
    result.add(digits[int(b) and 15])

proc createExclusive(path, content: string; mode: int) =
  ## Create ``path`` with its final mode at ``open(2)``: ``O_EXCL`` refuses
  ## an existing file or link, and the bytes are never readable under any
  ## wider mode, whatever the umask.
  let fd = posix.open(path.cstring,
    O_WRONLY or O_CREAT or O_EXCL or ONoFollow or O_CLOEXEC, Mode(mode))
  if fd < 0:
    raiseOSError(osLastError(), "create " & path)
  try:
    if fchmod(fd, Mode(mode)) != 0:
      raiseOSError(osLastError(), "fchmod " & path)
    var off = 0
    while off < content.len:
      let n = posix.write(fd, unsafeAddr content[off], content.len - off)
      if n < 0: raiseOSError(osLastError(), "write " & path)
      off += n
    if fsync(fd) != 0: raiseOSError(osLastError(), "fsync " & path)
  finally:
    discard posix.close(fd)

proc generateRecipientKey*(): string =
  ## Generate the host's secrets recipient key pair. Returns the public key
  ## (hex, uncompressed). The private key is written in the format the
  ## deploy agent's ``--secrets-key`` loads, and round-tripped through that
  ## loader before bootstrap continues.
  let kp = peerAuth.generateKeypair()
  const keyMode = when mutated("recipient-key-0644"): 0o644 else: 0o400
  createExclusive(RecipientKeyPath,
                  KeyFileMarker & hexOf(kp.privateKey) & "\n", keyMode)
  createExclusive(RecipientPubPath, hexOf(kp.publicKey) & "\n", 0o444)
  let back = peerAuth.loadPrivateKeyFile(RecipientKeyPath)
  if peerAuth.derivePublicKey(back) != kp.publicKey:
    raise newException(AddonBootstrapError,
      "the recipient key written to " & RecipientKeyPath &
      " does not load back to the generated key")
  hexOf(kp.publicKey)

proc rootEntry(path, kindHint: string): LedgerEntry =
  let st = statOwner(path)
  LedgerEntry(class: lcRoot, path: path, mode: st.mode, owner: st.owner,
              kindHint: kindHint)

proc runAddonBootstrap*(opts: BootstrapOptions): BootstrapResult =
  let stateDir = if opts.stateDir.len > 0: opts.stateDir else: DefaultStateDir
  if opts.planDigest.len == 0:
    raise newException(AddonBootstrapError,
      "bootstrap needs --plan <digest>: run `repro system addon preflight` " &
      "first and acknowledge the digest it prints")

  # 1. The plan, recomputed on the host, before any write.
  let plan = runPreflight(PreflightInputs(
    deploySignersPath: opts.deploySignersPath,
    cachePublishersPath: opts.cachePublishersPath,
    cacheUrl: opts.cacheUrl))
  if plan.digest != opts.planDigest:
    raise newException(AddonPlanMismatch,
      "the host's preflight plan is " & plan.digest & ", not the " &
      "acknowledged " & opts.planDigest & "; nothing was written. Re-run " &
      "the preflight and review what changed.")
  if not plan.compatible:
    var failed: seq[string]
    for c in plan.checks:
      if c.verdict == vFail: failed.add(c.id & ": " & c.detail)
    raise newException(AddonBootstrapError,
      "the acknowledged plan is not compatible; nothing was written:\n  " &
      failed.join("\n  "))
  for p in [opts.deploySignersPath, opts.cachePublishersPath]:
    if p.len > 0:
      discard peerAuth.loadTrustAnchors(p)   # strict: raises on a bad file

  # 2. Roots.
  var entries: seq[LedgerEntry]
  entries.add(rootEntry(ReproRoot, createRootDir(ReproRoot, 0o755)))
  entries.add(rootEntry(StoreRoot, createRootDir(StoreRoot, 0o755)))
  entries.add(rootEntry("/var/lib/repro", createRootDir("/var/lib/repro", 0o755)))
  entries.add(rootEntry(stateDir, createRootDir(stateDir, 0o700)))
  entries.add(rootEntry(AgentDir, createRootDir(AgentDir, 0o700)))
  entries.add(rootEntry("/etc/repro", createRootDir("/etc/repro", 0o755)))
  entries.add(rootEntry(AnchorsDir, createRootDir(AnchorsDir, 0o755)))
  ensureSystemStateDir(stateDir)

  when mutated("bootstrap-installs-jq"):
    # FALSIFYING MUTATION (see mutations.nim): a bootstrap that installs a
    # distribution package, which the specification forbids.
    discard runHostTool(["/usr/bin/apt-get", "install", "-y", "jq"])

  # 3. The recipient key, generated here.
  result.recipientPublicKeyHex = generateRecipientKey()
  when mutated("provisions-publisher-key"):
    # FALSIFYING MUTATION (see mutations.nim): a bootstrap that leaves a
    # binary-cache publisher keypair on the host, which would make it a
    # cache publisher under a key nobody provisioned.
    let pub = peerAuth.generateKeypair()
    createExclusive(AgentDir / "cache-publisher.key",
                    KeyFileMarker & hexOf(pub.privateKey) & "\n", 0o400)
  for k in [RecipientKeyPath, RecipientPubPath]:
    let st = statOwner(k)
    entries.add(LedgerEntry(class: lcKey, path: k, sha256: sha256OfFile(k),
                            mode: st.mode, owner: st.owner))

  # 4. This binary and generation 0's file bodies into the store.
  var files: seq[tuple[name, content: string]]
  for o in plan.gen0:
    if o.kind == ookEtcFile:
      files.add((name: contentFileName(o), content: o.content))
  let prefixes = realiseAddonPrefixes("/proc/self/exe", plan.binarySha256,
                                      files)
  if prefixes.reproExe != plan.gen0Inputs.reproExe:
    raise newException(AddonBootstrapError, "the add-on binary landed at " &
      prefixes.reproExe & ", not at the planned " & plan.gen0Inputs.reproExe)
  let storeCopy = sha256OfFile(prefixes.reproExe)
  if storeCopy != plan.binarySha256:
    raise newException(AddonBootstrapError, "the store copy of the add-on " &
      "binary hashes to " & storeCopy & ", not the planned " &
      plan.binarySha256)
  for (path, id) in [(prefixes.binaryPrefixPath, prefixes.binaryPrefixId),
                     (prefixes.filesPrefixPath, prefixes.filesPrefixId)]:
    entries.add(LedgerEntry(class: lcStorePrefix, path: path,
      sha256: hexOf(id)))

  # 5. Generation 0, through repro infra apply.
  let ownText = renderOwnProfile(plan.gen0, prefixes.filesPrefixPath)
  let applied = runAddonApply(AddonApplyOptions(stateDir: stateDir,
    hostIdentity: readHostname(), userProfileText: "",
    ownProfileText: ownText, bootstrapEntries: entries))

  # 6. Report.
  result.planDigest = plan.digest
  result.generationId = applied.generationId
  result.binarySha256 = plan.binarySha256
  result.reproExe = prefixes.reproExe
  result.ledger = applied.ledger
  let evidence = %*{
    "schema": "reprobuild.addon.evidence.bootstrap.v1",
    "time": $now().utc,
    "planDigest": plan.digest,
    "generationId": applied.generationId,
    "binarySha256": plan.binarySha256,
    "reproExe": prefixes.reproExe,
    "recipientPublicKey": result.recipientPublicKeyHex,
    "deploySignersSha256": sha256OfFile(DeploySignersPath),
    "cachesConfSha256": sha256OfFile(CachesConfPath),
  }
  writeFileAtomic(addonDir(stateDir) / "bootstrap-evidence.json",
                  canonical(evidence) & "\n", 0o600)
