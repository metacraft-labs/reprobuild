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

import std/[json, os, strutils]

import repro_core/host_apply_lock

import ./addon_apply
import ./agent_repin
import ./attestation
import ./evidence
import ./evidence_keys
import ./fingerprint
import ./generation0
import ./ledger
import ./nft_tables
import ./preflight
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
                          sha256: prefixIdHex(fp.id)))
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

proc runEvidenceEnrolCli*(args: seq[string]): int =
  var opts: EnrolOptions
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
