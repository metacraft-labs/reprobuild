## ``repro system addon bootstrap --plan <digest>``.
##
## Bootstrap turns a distribution host the preflight accepted into an
## add-on host:
##
## 1. **re-run the preflight** on the host and refuse unless its plan digest
##    is the one the operator acknowledged -- before anything is written;
## 2. **create the roots** (``/repro`` -- a btrfs subvolume on a btrfs root
##    -- ``/repro/store``, ``/var/lib/repro/{system,agent}``, ``/etc/repro``)
##    with their modes, or **take over** the ones the plan lists as
##    pre-bootstrap inputs (spec §6.1: a host the deploy agent stood up
##    first already has an empty store root, an empty state directory, a
##    recipient key, a signers file), setting those same modes and recording
##    each with the value it had before;
## 3. **install the trust anchors** (validated as ECDSA-P256 anchor files;
##    written by generation 0 itself) and **generate the secrets recipient
##    key on the host**, so its private half never travels: created with
##    its final mode ``0400`` in one ``open(O_CREAT|O_EXCL)``, never written
##    first and narrowed after -- or keep the one a pre-bootstrap input
##    supplies, never replacing a key;
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
import repro_deploy_agent/secrets

import ./addon_apply
import ./fingerprint
import ./generation0
import ./host_exec
import ./ledger
import ./linux_fs
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

proc generateRecipientKey*(kept: bool): string =
  ## Generate the host's secrets recipient key pair through the deploy
  ## agent's own keygen (``ensureRecipientKeyFile``: created ``0400`` from
  ## the start, published by a no-clobber link, never replacing an existing
  ## key). Returns the public key (hex, uncompressed). ``kept`` is the
  ## plan's word: the preflight found the key as a pre-bootstrap input
  ## (spec §6.1), so the keygen must read it back rather than create one;
  ## without it, the preflight saw no key, so one that is there now is
  ## someone else's and bootstrap refuses rather than adopting it.
  let key = ensureRecipientKeyFile(RecipientKeyPath)
  if key.created == kept:
    raise newException(AddonBootstrapError, RecipientKeyPath &
      (if kept: " was absent; the preflight saw it as a pre-bootstrap input"
       else: " already existed; the preflight saw no " & AgentDir))
  when mutated("recipient-key-0644"):
    # FALSIFYING MUTATION (see mutations.nim): a bootstrap that leaves the
    # recipient key group- and world-readable.
    discard posix.chmod(RecipientKeyPath.cstring, Mode(0o644))
  let pubHex = peerAuth.publicKeyHex(key.publicKey)
  if kept and fileExists(RecipientPubPath):
    # A kept public half must be the kept key's: a mismatch is a different
    # key's record, which no later sealing may be made against.
    if readFile(RecipientPubPath).strip() != pubHex:
      raise newException(AddonBootstrapError, RecipientPubPath &
        " is not the public half of " & RecipientKeyPath)
  else:
    createExclusive(RecipientPubPath, pubHex & "\n", 0o444)
  pubHex

proc rootEntry(path, kindHint, replaced: string): LedgerEntry =
  ## ``replaced`` is the fingerprint value the directory had before a
  ## takeover ("" for a root bootstrap created), in the component's own
  ## format: ``etc`` for a path under /etc, ``addon-roots`` otherwise.
  let st = statOwner(path)
  LedgerEntry(class: lcRoot, path: path, mode: st.mode, owner: st.owner,
              kindHint: kindHint, replaced: replaced,
              collision: (if replaced.len > 0: "adopt" else: ""))

proc baseRootValue(path: string): string =
  if path == "/etc" or path.startsWith("/etc/"): etcEntryValue(path)
  else: addonRootValue(path)

proc establishRoot(plan: PreflightReport; path: string; mode: int;
                   asSubvolume = false): LedgerEntry =
  ## Create one of the add-on's roots, or take it over when the acknowledged
  ## plan lists it as a pre-bootstrap input (spec §6.1).
  if path in plan.preBootstrap.roots:
    let before = baseRootValue(path)
    rootEntry(path, takeOverRootDir(path, mode), before)
  else:
    rootEntry(path, createRootDir(path, mode, asSubvolume), "")

proc keptFileEntry(path, preserved: string; class = lcEtcFile): LedgerEntry =
  ## The ledger entry of a file bootstrap keeps as found: adopted, produced
  ## by no resource, its prior value recorded (so the bootstrap delta is
  ## exact) and its bytes preserved (so uninstall can put it back).
  let st = statOwner(path)
  LedgerEntry(class: class, path: path, sha256: sha256OfFile(path),
              mode: st.mode, owner: st.owner, replaced: etcEntryValue(path),
              collision: "adopt", preserved: preserved)

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

  # 2. Roots: created, or taken over where the plan says they are
  # pre-bootstrap inputs. The directories the plan lists beyond the
  # add-on's own (the secrets tmpfs, the agent's state) are taken over
  # with the mode they have.
  var entries: seq[LedgerEntry]
  entries.add(establishRoot(plan, ReproRoot, 0o755,
    asSubvolume = isBtrfs(parentDir(ReproRoot))))
  entries.add(establishRoot(plan, StoreRoot, 0o755))
  entries.add(establishRoot(plan, "/var/lib/repro", 0o755))
  entries.add(establishRoot(plan, stateDir, 0o700))
  entries.add(establishRoot(plan, AgentDir, 0o700))
  entries.add(establishRoot(plan, "/etc/repro", 0o755))
  entries.add(establishRoot(plan, AnchorsDir, 0o755))
  for p in plan.preBootstrap.roots:
    if p notin [ReproRoot, StoreRoot, "/var/lib/repro", stateDir, AgentDir,
                "/etc/repro", AnchorsDir]:
      entries.add(rootEntry(p, takeOverRootDir(p), baseRootValue(p)))
  ensureSystemStateDir(stateDir)

  when mutated("bootstrap-installs-jq"):
    # FALSIFYING MUTATION (see mutations.nim): a bootstrap that installs a
    # distribution package, which the specification forbids.
    # ``tree`` as well as ``jq``: Ubuntu's cloud image ships jq already, and
    # a mutation that changes nothing there would not be a falsifier.
    discard runHostTool(["/usr/bin/apt-get", "install", "-y", "jq", "tree"])

  # 3. The recipient key, generated here -- or kept, when the host already
  # had one as a pre-bootstrap input. The kept files (the signers file,
  # the tmpfiles fragment, the agent's sequence floor) are adopted as
  # found, their bytes preserved for uninstall.
  let keyKept = plan.preBootstrap.recipientKey.len > 0
  let pubKept = RecipientPubPath in plan.preBootstrap.keptFiles
  result.recipientPublicKeyHex = generateRecipientKey(keyKept)
  when mutated("provisions-publisher-key"):
    # FALSIFYING MUTATION (see mutations.nim): a bootstrap that leaves a
    # binary-cache publisher keypair on the host, which would make it a
    # cache publisher under a key nobody provisioned.
    let pub = peerAuth.generateKeypair()
    createExclusive(AgentDir / "cache-publisher.key",
                    peerAuth.privateKeyFileText(pub.privateKey), 0o400)
  for (k, kept) in [(RecipientKeyPath, keyKept), (RecipientPubPath, pubKept)]:
    if kept:
      # No preserved copy of key material: uninstall captures the bytes
      # from the path itself before the state goes.
      entries.add(keptFileEntry(k, "", lcKey))
    else:
      let st = statOwner(k)
      entries.add(LedgerEntry(class: lcKey, path: k, sha256: sha256OfFile(k),
                              mode: st.mode, owner: st.owner))
  for p in plan.preBootstrap.keptFiles:
    if p in [RecipientKeyPath, RecipientPubPath]: continue
    entries.add(keptFileEntry(p, preserveBytes(stateDir, readFile(p))))

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

  # 5. Generation 0, through repro infra apply. The ledger copy exists
  # BEFORE the apply, holding what bootstrap created so far: generation 0
  # enables repro-addon-reassert.service, whose first run (`verify --boot`)
  # happens inside that apply and must find a ledger, never report the
  # add-on as degraded for lack of one. The apply then replaces it with
  # the full generation-0 ledger.
  writeLedger(ledgerCopyPath(stateDir), Ledger(generation: "", entries: entries))
  let ownText = renderOwnProfile(plan.gen0, prefixes.filesPrefixPath)
  let applied = runAddonApply(AddonApplyOptions(stateDir: stateDir,
    hostIdentity: readHostname(), userProfileText: "",
    ownProfileText: ownText,
    # Already in the preliminary ledger copy the apply reads them from.
    bootstrapEntries: @[]))

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
