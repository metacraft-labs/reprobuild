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
import repro_core/host_apply_lock
import repro_infra
import repro_peer_cache/auth as peerAuth
import repro_peer_cache/key_types
import repro_peer_cache/identity
import repro_peer_cache/types
import repro_deploy_agent/secrets

import ./addon_apply
import ./attestation
import ./evidence
import ./evidence_keys
import ./fingerprint
import ./generation0
import ./static_tree
import ./host_exec
import ./ledger
import ./linux_fs
import ./mutations
import ./nft_tables
import ./preflight
import ./store_custody
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
    agentTarget*: string          ## the deploy agent's target (A8), or ""
    agentSources*: seq[string]    ## its manifest sources
    profileCompiler*: string      ## the fetch unit's profile compiler, or ""
    agentPollSec*: int            ## the fetch timer's interval (0: default)
    evidenceSink*: string         ## the Evidence sink, ``address:port`` (A11)
    evidenceSinkCaPath*: string   ## its host CA certificate
    evidenceHeartbeatSec*: int    ## the shipping heartbeat (0: default)
    deferRecipientKey*: bool
      ## Create no recipient key: the host creates its own at its next boot
      ## (``lcLateKey``; spec §6.2 step 3). An image's assembly boot sets it.

  BootstrapResult* = object
    planDigest*: string
    generationId*: string
    binarySha256*: string
    reproExe*: string
    recipientPublicKeyHex*: string
    attestationPublicKeyHex*: string  ## "" without an Evidence sink
    evidenceCredentialHost*: string   ## the sink credential's host id, or ""
    evidenceCredentialCert*: string   ## where its certificate is, to enrol
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
  ## The ledger entry of a content-pinned file bootstrap keeps as found:
  ## adopted, produced by no resource, its prior value recorded (so the
  ## bootstrap delta is exact) and its bytes preserved (so uninstall can
  ## put it back).
  let st = statOwner(path)
  LedgerEntry(class: class, path: path, sha256: sha256OfFile(path),
              mode: st.mode, owner: st.owner, replaced: etcEntryValue(path),
              collision: "adopt", preserved: preserved)

proc keptRecordEntry(path: string): LedgerEntry =
  ## The ledger entry of an agent record kept with its content unpinned
  ## (``lcKept``): path, mode and owner only.
  let st = statOwner(path)
  LedgerEntry(class: lcKept, path: path, mode: st.mode, owner: st.owner,
              collision: "adopt")

const
  TakenOverDirModes = [
    # Spec §5.3 modes for every directory the plan may list beyond the
    # add-on's own roots: the secrets tmpfs and the agent's state are the
    # agent's (0700), /run/repro itself is traversable (0755).
    ("/run/repro", 0o755), (SecretsRunDir, 0o700),
    (AgentStateDir, 0o700), (AgentStateRecordsDir, 0o700),
  ]

proc runAddonBootstrap*(opts: BootstrapOptions): BootstrapResult =
  let stateDir = if opts.stateDir.len > 0: opts.stateDir else: DefaultStateDir
  if opts.planDigest.len == 0:
    raise newException(AddonBootstrapError,
      "bootstrap needs --plan <digest>: run `repro system addon preflight` " &
      "first and acknowledge the digest it prints")

  # 1. The plan, recomputed on the host, before any write.
  let inputs = PreflightInputs(
    deploySignersPath: opts.deploySignersPath,
    cachePublishersPath: opts.cachePublishersPath,
    cacheUrl: opts.cacheUrl, agentTarget: opts.agentTarget,
    agentSources: opts.agentSources, profileCompiler: opts.profileCompiler,
    agentPollSec: opts.agentPollSec, evidenceSink: opts.evidenceSink,
    evidenceSinkCaPath: opts.evidenceSinkCaPath,
    evidenceHeartbeatSec: opts.evidenceHeartbeatSec,
    deferRecipientKey: opts.deferRecipientKey)
  let plan = runPreflight(inputs)
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

  # 1b. Only now, with the plan acknowledged and nothing written, take the
  # host-wide apply lock for the rest of the bootstrap: it writes the store,
  # /etc and the unit set before its generation-0 apply starts, and no other
  # apply may change the host underneath it (``repro_core/host_apply_lock``).
  # The lock file (/run/repro-apply.lock) is outside every add-on root, so
  # the preflight never sees it. Another apply may have changed the host
  # while this one waited, so the plan is recomputed under the lock.
  var hostLock = acquireHostApplyLock("repro system addon bootstrap")
  defer: hostLock.release()
  let lockedPlan = runPreflight(inputs)
  if lockedPlan.digest != plan.digest:
    raise newException(AddonPlanMismatch,
      "the host's preflight plan changed to " & lockedPlan.digest &
      " while the bootstrap waited for the host apply lock; nothing was " &
      "written apart from that lock (" & hostApplyLockPath() & ", outside " &
      "every add-on root). Re-run the preflight and review what changed.")
  if plan.preBootstrap.roots.len > 0 and stateDir != DefaultStateDir:
    # The preflight inspected the default state directory; a bootstrap
    # into another one would leave the inspected /var/lib/repro/system
    # untouched and unledgered.
    raise newException(AddonBootstrapError, "the host carries pre-bootstrap " &
      "inputs under /var/lib/repro, which the preflight inspected at the " &
      "default state directory " & DefaultStateDir & "; --state-dir " &
      stateDir & " is refused; nothing was written")
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
      var mode = -1
      for (dir, m) in TakenOverDirModes:
        if dir == p: mode = m
      if mode < 0:
        raise newException(AddonBootstrapError, "the plan lists " & p &
          " as a pre-bootstrap input, which bootstrap has no mode for")
      entries.add(rootEntry(p, takeOverRootDir(p, mode), baseRootValue(p)))
  ensureSystemStateDir(stateDir)
  # Every apply's pending-switch check finds the add-on's state through
  # this, whatever --state-dir it was itself given (§7.7).
  writeAddonStateDirPointer(stateDir)

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
  var pubKept = false
  for k in plan.preBootstrap.keptFiles:
    if k.path == RecipientPubPath: pubKept = true
  if opts.deferRecipientKey:
    if keyKept:
      raise newException(AddonBootstrapError, "a deferred recipient key " &
        "cannot be combined with a kept one (" & RecipientKeyPath & ")")
    # No key now: the host's next boot creates its own (re-assert,
    # ``createLateRecipientKey``). The ledger owns the paths by shape only.
    let owner = statOwner(AgentDir).owner
    entries.add(LedgerEntry(class: lcLateKey, path: RecipientKeyPath,
                            mode: "0400", owner: owner))
    entries.add(LedgerEntry(class: lcLateKey, path: RecipientPubPath,
                            mode: "0444", owner: owner))
  else:
    result.recipientPublicKeyHex = generateRecipientKey(keyKept)
  if keyKept and result.recipientPublicKeyHex != plan.preBootstrap.recipientPublicKey:
    raise newException(AddonBootstrapError, RecipientKeyPath & " is not the " &
      "key the acknowledged plan saw (public half " &
      plan.preBootstrap.recipientPublicKey[0 ..< 16] & "...)")
  when mutated("provisions-publisher-key"):
    # FALSIFYING MUTATION (see mutations.nim): a bootstrap that leaves a
    # binary-cache publisher keypair on the host, which would make it a
    # cache publisher under a key nobody provisioned.
    let pub = peerAuth.generateKeypair()
    createExclusive(AgentDir / "cache-publisher.key",
                    peerAuth.privateKeyFileText(pub.privateKey), 0o400)
  for (k, kept) in [(RecipientKeyPath, keyKept), (RecipientPubPath, pubKept)]:
    if opts.deferRecipientKey: break
    if kept:
      # No preserved copy of key material: uninstall captures the bytes
      # from the path itself before the state goes.
      entries.add(keptFileEntry(k, "", lcKey))
    else:
      let st = statOwner(k)
      entries.add(LedgerEntry(class: lcKey, path: k, sha256: sha256OfFile(k),
                              mode: st.mode, owner: st.owner))
  for k in plan.preBootstrap.keptFiles:
    if k.path in [RecipientKeyPath, RecipientPubPath]: continue
    if k.pinned:
      let content = readFile(k.path)
      if sha256Hex(content) != k.sha256:
        raise newException(AddonBootstrapError, k.path & " changed since " &
          "the acknowledged plan was computed")
      entries.add(keptFileEntry(k.path, preserveBytes(stateDir, content)))
    else:
      entries.add(keptRecordEntry(k.path))

  # 3b. Evidence (A11, spec §10.4, §10.5), only with a sink: the
  # attestation key beside the recipient key, the sink write credential in
  # its own root-only directory, and the outbox the shipping unit's path
  # unit watches. Each key is created here, never adopted (the preflight
  # refused a host that already had one).
  let shipping = plan.gen0Inputs.evidence.sinkAddress.len > 0
  if shipping:
    entries.add(establishRoot(plan, EvidenceStateDir, 0o700))
    let keys = try: createEvidenceKeys()
               except EvidenceKeysError as e:
                 raise newException(AddonBootstrapError, e.msg)
    result.attestationPublicKeyHex = keys.attestationPublicKeyHex
    result.evidenceCredentialHost = keys.credentialHost
    result.evidenceCredentialCert = EvidenceCredentialCertPath
    entries.add(keys.entries)
    if plan.gen0Inputs.egress.nft.len > 0:
      # The egress observer's table: generation 0's unit loads it during
      # the apply below; the ledger tracks it from the start, like every
      # other object of generation 0 (owner decision 2026-11-04).
      entries.add(LedgerEntry(class: lcNftTable, path: EgressTableKey))
    createEvidenceDirs()

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
  # Each prefix's realisation digest is recorded here, in the ledger
  # (root-only, outside the store, attested by the generation's statement):
  # store verification takes the expected digest from it, never from the
  # path it verifies (spec §10.2).
  for (path, id, digest) in [
      (prefixes.binaryPrefixPath, prefixes.binaryPrefixId,
       prefixes.binaryDigest),
      (prefixes.filesPrefixPath, prefixes.filesPrefixId,
       prefixes.filesDigest)]:
    entries.add(LedgerEntry(class: lcStorePrefix, path: path,
      sha256: hexOf(id), value: digest))
    recordRealised(custodySite(stateDir), path, digest)
  # The host is under store custody from its first generation (§13
  # decision 48): an object with no recorded digest is refused, never
  # reported "unverifiable" as on a host realised before custody.
  markCustody(custodySite(stateDir))

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
  if shipping:
    evidence["attestationPublicKey"] = %result.attestationPublicKeyHex
    evidence["evidenceCredentialHost"] = %result.evidenceCredentialHost
  writeFileAtomic(addonDir(stateDir) / BootstrapEvidenceName,
                  canonical(evidence) & "\n", 0o600)
  # The first evidence record (spec §6.2 step 5): the binary's digest, the
  # anchors, the recipient key and -- what the off-host check enrols -- the
  # attestation key, attested over generation 0.
  discard recordEvidence(EvidenceEvent(detector: edBootstrap,
    category: ecAudit, trigger: "bootstrap", kind: "bootstrap",
    fields: @[("planDigest", plan.digest),
              ("digest", plan.binarySha256),
              ("recipientKey", result.recipientPublicKeyHex),
              ("credentialHost", result.evidenceCredentialHost),
              ("path", prefixes.reproExe),
              # dpkg runs up to here had no hook to follow them: the
              # off-host check counts only later ones (DET-AO-8).
              ("dpkgLastRun", dpkgLastRun("/var/log/dpkg.log")),
              ("bootId", bootIdNow())],
    attest: true), defaultSite(stateDir))
