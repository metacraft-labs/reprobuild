## ``repro system addon evidence-enrol --evidence-sink <addr>:<port>
## --evidence-sink-ca <file> [--heartbeat-interval S]`` (owner decision
## 2026-11-04; spec §6.2, §10.6).
##
## Gives an add-on host that was bootstrapped without an Evidence sink the
## evidence objects bootstrap with a sink would have given it:
##
## 1. refuses unless this is an add-on host with no sink yet, none of the
##    evidence keys exists (never adopted, never replaced), and -- when the
##    host runs the deploy agent -- its base can carry the egress observer
##    (``EAddOnEgressObserverUnavailable`` otherwise; no silent fallback);
## 2. under the host apply lock, creates ``/var/lib/repro/evidence``, the
##    attestation key and the sink write credential (``evidence_keys``);
## 3. applies ONE switch whose own profile is generation 0's plus the
##    evidence objects (and the egress observer, with the fetch unit moved
##    under it), ledgered, retained and reachable by ``repro system
##    rollback`` like every other switch -- the way ``agent-repin`` changes
##    generation 0's objects;
## 4. records itself: an ``addon-bootstrap`` audit record (``evidence-enrol``,
##    outcome ``aoOperatorAction``) carrying the attestation key the
##    off-host check enrols, and prints the credential's host id to enrol
##    at the sink.

import std/[json, os, posix, strutils, times]

import repro_core/host_apply_lock
import repro_peer_cache/evidence_record
import repro_peer_cache/evidence as sinkEvidence
import repro_peer_cache/identity
import repro_peer_cache/types

import ./addon_apply
import ./agent_repin
import ./attestation
import ./evidence
import ./evidence_keys
import ./evidence_ship
import ./fingerprint
import ./generation0
import ./ledger
import ./nft_tables
import ./preflight
import ./store_custody
import ./store_root

type
  EnrolOptions* = object
    stateDir*: string
    sink*: string
    sinkCaPath*: string
    heartbeatSec*: int

  EnrolResult* = object
    generationId*: string
    attestationPublicKeyHex*: string
    credentialHost*: string
    observed*: bool

  EvidenceEnrolError* = object of CatchableError

proc pollSecOf(timerContent: string): int =
  ## The fetch timer's ``OnUnitActiveSec=`` in seconds (``5min`` or ``Ns``).
  for l in timerContent.splitLines():
    if l.startsWith("OnUnitActiveSec="):
      let v = l["OnUnitActiveSec=".len .. ^1].strip()
      try:
        if v.endsWith("min"): return parseInt(v[0 ..< ^3]) * 60
        if v.endsWith("s"): return parseInt(v[0 ..< ^1])
        return parseInt(v)
      except ValueError: discard
  0

proc allowedOf(fetchUnit: string): seq[string] =
  for l in fetchUnit.splitLines():
    if l.startsWith("IPAddressAllow="):
      result.add(l["IPAddressAllow=".len .. ^1].splitWhitespace())

proc runEvidenceEnrol*(opts: EnrolOptions): EnrolResult =
  let stateDir = if opts.stateDir.len > 0: opts.stateDir else: DefaultStateDir
  if not isAddonHost(stateDir):
    raise newException(EvidenceEnrolError, "this is not an add-on host (no " &
      "ledger under " & stateDir & ")")
  if fileExists(EvidenceConfPath):
    raise newException(EvidenceEnrolError, EvidenceConfPath & " exists: this " &
      "host already ships its evidence; nothing was written")
  let present = existingEvidenceKeys()
  if present.len > 0:
    raise newException(EvidenceEnrolError, "refusing to adopt or replace " &
      "existing evidence keys: " & present.join(", ") & "; nothing was written")
  if dirExists(EvidenceStateDir):
    raise newException(EvidenceEnrolError, EvidenceStateDir & " exists; " &
      "nothing was written")
  let ev = try: resolveEvidenceInputs(opts.sink, opts.sinkCaPath,
                                      opts.heartbeatSec)
           except ValueError as e:
             raise newException(EvidenceEnrolError, e.msg)
  let own = readFile(ownProfilePath(stateDir))
  # The add-on's binary in the store, as bootstrap recorded it.
  var reproExe = ""
  try:
    reproExe = parseJson(readFile(addonDir(stateDir) / BootstrapEvidenceName)){
      "reproExe"}.getStr()
  except CatchableError:
    discard
  if not reproExe.startsWith(StoreRoot & "/") or not fileExists(reproExe):
    raise newException(EvidenceEnrolError, "bootstrap's record (" &
      addonDir(stateDir) / BootstrapEvidenceName & ") names no add-on " &
      "binary in the store")
  let fetch = unitContentOf(own, AgentFetchUnit)
  var inp = Gen0Inputs(reproExe: reproExe, evidence: ev)
  if fetch.len > 0:
    inp.agent = AgentUnitsInputs(target: "agent",
      pollIntervalSec: pollSecOf(unitContentOf(own, AgentFetchTimer)))
    let nft = nftBinary()
    let problem = egressObserverProblem(nft)
    if problem.len > 0:
      raise newException(EvidenceEnrolError, problem & "; nothing was written")
    inp.egress = EgressObserverInputs(nft: nft, allowedAddresses: allowedOf(fetch))
    result.observed = true

  var hostLock = acquireHostApplyLock("repro system addon evidence-enrol")
  defer: hostLock.release()
  var entries: seq[LedgerEntry]
  let hint = createRootDir(EvidenceStateDir, 0o700)
  let st = statOwner(EvidenceStateDir)
  entries.add(LedgerEntry(class: lcRoot, path: EvidenceStateDir,
    mode: st.mode, owner: st.owner, kindHint: hint))
  let keys = createEvidenceKeys()
  entries.add(keys.entries)
  createEvidenceDirs()
  result.attestationPublicKeyHex = keys.attestationPublicKeyHex
  result.credentialHost = keys.credentialHost

  var objects = evidenceObjects(inp)
  if result.observed:
    objects.add(egressObjects(inp))
    entries.add(LedgerEntry(class: lcNftTable, path: EgressTableKey))
  var files: seq[tuple[name, content: string]]
  for o in objects:
    if o.kind == ookEtcFile: files.add((contentFileName(o), o.content))
  let fp = realiseFilesPrefix(files)
  entries.add(LedgerEntry(class: lcStorePrefix, path: fp.path,
                          sha256: prefixIdHex(fp.id), value: fp.digest))
  recordRealised(custodySite(stateDir), fp.path, fp.digest)
  var newOwn = own
  if result.observed:
    let (a, b) = blockBounds(own, UnitBlockHead & AgentFetchUnit & "\"\n")
    let blk = own[a ..< b]
    newOwn = own[0 ..< a] &
      blk.replace("  content = \"" & fetch & "\"",
                  "  content = \"" & observeFetchUnit(fetch) & "\"") &
      own[b .. ^1]
  # The objects the fetch unit requires go before it; appending them is
  # enough because a switch orders unit starts by their dependencies.
  newOwn.add("\n" & renderOwnProfile(objects, fp.path))
  let userText = if fileExists(userProfilePath(stateDir)):
                   readFile(userProfilePath(stateDir)) else: ""
  var r: AddonApplyResult
  try:
    r = runAddonApply(AddonApplyOptions(stateDir: stateDir,
      hostIdentity: readHostname(), userProfileText: userText,
      storedTarget: true, ownProfileText: newOwn, bootstrapEntries: entries,
      purpose: "evidence-enrol"))
  except CatchableError:
    # No generation names the keys: take back what this run created, so a
    # second run is not refused for keys nothing uses.
    for k in [AttestationKeyPath, AttestationPubPath]:
      try: removeFile(k) except OSError: discard
    try: removeDir(EvidenceStateDir) except OSError: discard
    raise
  result.generationId = r.generationId
  discard recordEvidence(EvidenceEvent(detector: edBootstrap,
    category: ecAudit, trigger: "evidence-enrol", kind: "evidence-enrol",
    fields: @[("outcome", "aoOperatorAction"),
              ("credentialHost", keys.credentialHost),
              ("purpose", "evidence-enrol"),
              ("dpkgLastRun", dpkgLastRun("/var/log/dpkg.log")),
              ("bootId", bootIdNow())],
    attest: true), defaultSite(stateDir))

# ---------------------------------------------------------------------------
# Re-keying an enrolled host (spec §13 decision 52; A11 drill D7).
# ---------------------------------------------------------------------------

type
  RekeyResult* = object
    generationId*: string
    oldAttestationKey*, newAttestationKey*: string
    oldCredentialHost*, newCredentialHost*: string
    handedOver*: bool

proc nextPath(p: string): string = p & ".next"

proc shipHandover(statement, signature, oldKey, newKey, newHost: string):
    tuple[ok: bool; why: string] =
  ## Append the hand-over with the CURRENT (old) credential and wait for the
  ## sink's acknowledgement. Straight to the sink, not through the outbox: a
  ## hand-over that did not arrive must not leave later, announcing keys the
  ## host never installed.
  try:
    let site = defaultShipSite()
    let conf = loadEvidenceConf(site.confPath)
    let a = openAppender(site, conf)
    defer: a.close()
    var r = newEvidenceRecord(ecAudit, $edKeys, "rekey-handover",
      [("outcome", "aoOperatorAction"), ("handover", statement),
       ("handoverSignature", signature), ("attestationKey", oldKey),
       ("newAttestationKey", newKey), ("newCredentialHost", newHost),
       ("host", readHostname())], nowMs = int64(epochTime() * 1000))
    r.senderPid = int32(getCurrentProcessId())
    a.append(r)
    discard a.drain(20_000)
    if a.appended == 1: (true, "")
    else: (false, (if a.lastError.len > 0: a.lastError
                   else: "the sink did not acknowledge it"))
  except CatchableError as e:
    (false, e.msg)

proc runEvidenceRekey*(stateDir = DefaultStateDir; noHandover = false):
    RekeyResult =
  ## New attestation key and sink credential, the old key's signed
  ## hand-over shipped with the old credential first (unless
  ## ``noHandover``: the old key is presumed compromised and the operator
  ## enrols the new one off-host), then one switch whose ledger names the
  ## new keys.
  if not isAddonHost(stateDir):
    raise newException(EvidenceEnrolError, "this is not an add-on host")
  if not fileExists(EvidenceConfPath):
    raise newException(EvidenceEnrolError, "this host has no Evidence sink; " &
      "use evidence-enrol without --rekey")
  let k = defaultKeyPaths()
  for p in [k.attestationKey, k.attestationPub, k.credentialKey,
            k.credentialCert]:
    if not fileExists(p):
      raise newException(EvidenceEnrolError, p & " is missing; nothing to re-key")
    if fileExists(nextPath(p)):
      raise newException(EvidenceEnrolError, nextPath(p) & " exists (an " &
        "interrupted re-key?); remove it after checking it, then run again")
  var hostLock = acquireHostApplyLock("repro system addon evidence-enrol --rekey")
  defer: hostLock.release()
  result.oldAttestationKey = readFile(k.attestationPub).strip()
  result.oldCredentialHost = $loadOrCreateHostIdentity(k.credentialCert,
                                                       k.credentialKey).hostId
  # 1. The next keys, beside the current ones.
  let att = ensureAttestationKey(nextPath(k.attestationKey))
  result.newAttestationKey = att.publicKeyHex
  let cred = loadOrCreateHostIdentity(nextPath(k.credentialCert),
                                      nextPath(k.credentialKey))
  result.newCredentialHost = $cred.hostId
  proc discardNext() =
    for p in [k.attestationKey, k.credentialCert, k.credentialKey]:
      try: removeFile(nextPath(p)) except OSError: discard
  # 2. The hand-over, signed by the old key, on the sink before anything
  # is replaced.
  if not noHandover:
    let h = KeyHandover(host: readHostname(), oldKey: result.oldAttestationKey,
      newKey: result.newAttestationKey,
      newCredentialHost: result.newCredentialHost,
      atMs: int64(epochTime() * 1000))
    let signed = signHandover(h, k.attestationKey)
    let shipped = shipHandover(signed.statement, signed.signature,
      result.oldAttestationKey, result.newAttestationKey,
      result.newCredentialHost)
    if not shipped.ok:
      discardNext()
      raise newException(EvidenceEnrolError, "the hand-over did not reach " &
        "the sink (" & shipped.why & "); nothing was replaced")
    result.handedOver = true
  # 3. The new keys replace the old (rename: never a moment without one).
  moveFile(nextPath(k.attestationKey), k.attestationKey)
  discard posix.chmod(k.attestationKey.cstring, Mode(0o400))
  writeFile(k.attestationPub & ".tmp", result.newAttestationKey & "\n")
  setFilePermissions(k.attestationPub & ".tmp", {fpUserRead, fpGroupRead,
                                                 fpOthersRead})
  moveFile(k.attestationPub & ".tmp", k.attestationPub)
  moveFile(nextPath(k.credentialKey), k.credentialKey)
  moveFile(nextPath(k.credentialCert), k.credentialCert)
  discard posix.chmod(k.credentialKey.cstring, Mode(0o400))
  discard posix.chmod(k.credentialCert.cstring, Mode(0o444))
  # 4. One switch whose ledger names the new keys.
  var entries: seq[LedgerEntry]
  for p in [k.attestationKey, k.attestationPub, k.credentialKey,
            k.credentialCert]:
    let st = statOwner(p)
    entries.add(LedgerEntry(class: lcKey, path: p, sha256: sha256OfFile(p),
                            mode: st.mode, owner: st.owner))
  let own = readFile(ownProfilePath(stateDir))
  let userText = if fileExists(userProfilePath(stateDir)):
                   readFile(userProfilePath(stateDir)) else: ""
  let r = runAddonApply(AddonApplyOptions(stateDir: stateDir,
    hostIdentity: readHostname(), userProfileText: userText,
    storedTarget: true, ownProfileText: own, bootstrapEntries: entries,
    purpose: "evidence-rekey"))
  result.generationId = r.generationId
  discard recordEvidence(EvidenceEvent(detector: edKeys,
    category: ecAudit, trigger: "rekeyed", kind: "rekeyed",
    fields: @[("outcome", "aoOperatorAction"),
              ("newAttestationKey", result.newAttestationKey),
              ("newCredentialHost", result.newCredentialHost),
              ("purpose", if noHandover: "rekey-no-handover" else: "rekey")],
    attest: true), defaultSite(stateDir))

proc runEvidenceEnrolCli*(args: seq[string]): int =
  var opts: EnrolOptions
  if "--rekey" in args:
    var noHandover = false
    for a in args:
      if a == "--no-handover": noHandover = true
      elif a != "--rekey":
        stderr.write("usage: repro system addon evidence-enrol --rekey " &
          "[--no-handover]\n")
        return 2
    try:
      let r = runEvidenceRekey(noHandover = noHandover)
      stdout.write("generation:           " & r.generationId & "\n" &
        "attestation key:      " & r.newAttestationKey & " (was " &
          r.oldAttestationKey & ")\n" &
        "evidence credential:  " & r.newCredentialHost & " (was " &
          r.oldCredentialHost & ")\n" &
        "hand-over:            " & (if r.handedOver: "signed by the old " &
          "key and on the sink" else: "none (--no-handover)") & "\n" &
        "next, on the sink:    copy " & EvidenceCredentialCertPath &
          " into the anchors, list " & r.oldCredentialHost &
          " in --revoked, then " & (if r.handedOver:
            "run addon-check --update-hosts (it follows the hand-over)"
          else: "replace the host's line in the hosts file with the new " &
            "id and key, and mark the old line retired@<the sink's head " &
            "sequence now>") & "\n")
      return 0
    except CatchableError as e:
      stderr.write("repro system addon evidence-enrol --rekey: " & e.msg & "\n")
      return 2
  var i = 0
  proc value(flag: string): string =
    let a = args[i]
    if a.startsWith(flag & "="): return a[flag.len + 1 .. ^1]
    if i + 1 >= args.len: raise newException(ValueError, flag & " needs a value")
    inc i
    args[i]
  try:
    while i < args.len:
      let a = args[i]
      if a.startsWith("--evidence-sink-ca"): opts.sinkCaPath = value("--evidence-sink-ca")
      elif a.startsWith("--evidence-sink"): opts.sink = value("--evidence-sink")
      elif a.startsWith("--heartbeat-interval"):
        opts.heartbeatSec = parseInt(value("--heartbeat-interval"))
      else: raise newException(ValueError, "unknown option " & a)
      inc i
    if opts.sink.len == 0 or opts.sinkCaPath.len == 0:
      raise newException(ValueError, "--evidence-sink and --evidence-sink-ca " &
        "are required")
  except ValueError as e:
    stderr.write("repro system addon evidence-enrol: " & e.msg & "\n")
    return 2
  try:
    let r = runEvidenceEnrol(opts)
    stdout.write("generation:           " & r.generationId & "\n" &
      "attestation key:      " & r.attestationPublicKeyHex & "\n" &
      "evidence credential:  " & r.credentialHost & " (enrol " &
        EvidenceCredentialCertPath & " at the sink)\n" &
      "egress observer:      " & (if r.observed: "installed" else:
        "none (no deploy agent)") & "\n")
    0
  except EvidenceEnrolError as e:
    stderr.write("repro system addon evidence-enrol: " & e.msg & "\n")
    2
