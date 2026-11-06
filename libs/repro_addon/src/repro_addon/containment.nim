## An operator's containment of an add-on host, and its release (spec §13
## decision 51; A11 drill finding D5; RESP-4).
##
##   repro system addon contain --operator NAME --reason TEXT
##       1. records ``addon-containment`` / ``operator-contained`` (attested
##          by the host's key, naming the operator and the reason) and ships
##          it to the sink BEFORE anything stops, so the off-host check can
##          tell the deploy agent's silence that follows from an attacker's
##          (it then reports the agent ``contained``, not ``silent``);
##       2. writes the containment marker (``<state>/addon/contained``);
##       3. gives the fetch timer, the fetch unit and the apply unit a runtime
##          drop-in conditioning them on the marker's absence
##          (``ConditionPathExists=!``, see ``ContainDropInName``), stops the
##          fetch side, so no network-fed input is fetched, then, under the
##          host apply lock (a switch in progress finishes first), the apply
##          unit, and clears the agent units' failed state, so the host
##          reads as it was before the compromise;
##       4. at every boot while the marker exists, the re-assert unit writes
##          the drop-ins again, and the apply unit refuses to run.
##   repro system addon release --operator NAME --reason TEXT
##       records ``operator-released`` and ships it, removes the marker and
##       the drop-ins, and starts the fetch timer again.
##
## Neither verb changes a generation. A containment that the check cannot
## verify (unsigned, or recorded after the agent had already gone silent)
## does not suppress the silence alert.

import std/[os, strutils, times]

import repro_peer_cache/identity
import repro_peer_cache/types

import repro_core/host_apply_lock

import ./attestation
import ./contain_marker
import ./evidence
import ./evidence_ship
import ./generation0
import ./host_exec
import ./mutations

export contain_marker

type
  ContainmentError* = object of CatchableError

  ContainResult* = object
    record*: string           ## the local record
    shipped*: bool            ## the sink acknowledged it
    shipError*: string
    already*: bool

const
  ContainedUnits* = [AgentFetchTimer, AgentFetchUnit]
    ## Stopped and masked first: no more network-fed input.
  ContainedApplyUnit* = AgentApplyUnit

proc shipNow(site: EvidenceSite): tuple[shipped: bool; error: string] =
  ## Ship the outbox now, through the shipping run itself; ``shipped`` when
  ## nothing stayed queued.
  if not fileExists(EvidenceConfPath):
    return (false, "this host has no Evidence sink")
  try:
    let conf = loadEvidenceConf()
    let r = runEvidenceShip(defaultShipSite(), conf, site.host)
    (r.pending == 0 and r.error.len == 0, r.error)
  except CatchableError as e:
    (false, e.msg)

proc unitLoaded(u: string): bool =
  ## The unit exists on this host (a host whose agent is the full engine's
  ## ``repro deploy-agent`` has no add-on agent units, finding 6).
  try:
    let r = runSystemctl(["show", "-p", "LoadState", "--value", u])
    r.exitCode == 0 and r.output.strip() notin ["not-found", ""]
  except CatchableError: false

proc systemctlAll(verb: openArray[string]; units: openArray[string]): string =
  ## "" when systemctl accepted the request, otherwise its output. Units
  ## this host does not have are left out.
  var args = @verb
  var any = units.len == 0
  for u in units:
    if unitLoaded(u):
      args.add(u)
      any = true
  if not any: return ""
  try:
    let r = runSystemctl(args)
    if r.exitCode != 0: return r.output.strip()
  except CatchableError as e:
    return e.msg
  ""

const ContainDropInName* = "50-repro-contained.conf"
  ## The runtime drop-in each contained unit gets, under
  ## ``/run/systemd/system/<unit>.d/``. A runtime MASK cannot be used: the
  ## agent's units are files in ``/etc/systemd/system``, which takes
  ## precedence over ``/run`` (systemd.unit(5) "Unit File Load Path"), so
  ## ``systemctl mask --runtime`` leaves them startable (measured in the
  ## A11 drill gate on debian-13 at reprobuild 1a9f6aa697). Drop-ins are
  ## merged from every directory, and a condition PID 1 checks needs no
  ## access from the unit's own sandbox.

proc containDropIn*(markerPath: string): string =
  "[Unit]\n" &
  "# Contained by an operator (repro system addon contain, spec §13\n" &
  "# decision 51): nothing starts while the marker exists.\n" &
  "ConditionPathExists=!" & markerPath & "\n"

proc writeContainDropIns(markerPath: string; runDir = "/run/systemd/system"):
    seq[string] =
  for u in @ContainedUnits & @[ContainedApplyUnit]:
    try:
      let d = runDir / (u & ".d")
      createDir(d)
      writeFile(d / ContainDropInName, containDropIn(markerPath))
    except CatchableError as e:
      result.add(u & ": " & e.msg)

proc removeContainDropIns(runDir = "/run/systemd/system") =
  for u in @ContainedUnits & @[ContainedApplyUnit]:
    try: removeFile(runDir / (u & ".d") / ContainDropInName)
    except OSError: discard

proc maskAgent*(markerPath: string): seq[string] =
  ## Make the agent's units unstartable while ``markerPath`` exists (a
  ## runtime drop-in each), stop the fetch side, then the apply side under
  ## the apply lock, and clear their failed state.
  result = writeContainDropIns(markerPath)
  let r = systemctlAll(["daemon-reload"], [])
  if r.len > 0: result.add(r)
  let a = systemctlAll(["stop"], ContainedUnits)
  if a.len > 0: result.add(a)
  var lock = acquireHostApplyLock("repro system addon contain")
  try:
    let b = systemctlAll(["stop"], [ContainedApplyUnit])
    if b.len > 0: result.add(b)
  finally:
    lock.release()
  discard systemctlAll(["reset-failed"], [AgentFetchUnit, ContainedApplyUnit])

proc nextContainmentSequence(stateDir: string): uint64 =
  ## Strictly increasing per host, kept root-only beside the marker.
  let p = stateDir / "addon" / "containment-sequence"
  var n = 0'u64
  try: n = parseBiggestUInt(readFile(p).strip()).uint64
  except CatchableError: discard
  inc n
  createDir(parentDir(p))
  writeFile(p & ".tmp", $n & "\n")
  setFilePermissions(p & ".tmp", {fpUserRead, fpUserWrite})
  moveFile(p & ".tmp", p)
  n

proc credentialHostId(): string =
  ## The sink credential's host id (the id the sink stamps), "" when the
  ## host has no credential.
  if not (fileExists(EvidenceCredentialCertPath) and
          fileExists(EvidenceCredentialKeyPath)): return ""
  try: $loadOrCreateHostIdentity(EvidenceCredentialCertPath,
                                 EvidenceCredentialKeyPath).hostId
  except CatchableError: ""

proc recordContainmentAs*(site: EvidenceSite; credentialHost, action,
                          operator, reason: string; sequence: uint64;
                          atMs = int64(epochTime() * 1000)): string =
  ## The record of a containment or a release, carrying a statement of its
  ## own signed by the attestation key: host, credential id, action,
  ## operator, reason, a strictly increasing sequence and the time (finding
  ## 3). The generation attestation alone would bind none of it. Exported
  ## so a test writes the record the contain verb writes.
  var fields = @[("outcome", "aoOperatorAction"), ("operator", operator),
                 ("reason", reason)]
  when not mutated("contain-unsigned"):
    let c = ContainmentStatement(host: site.host,
      credentialHost: credentialHost, action: action, operator: operator,
      reason: reason, sequence: sequence, atMs: atMs)
    let signed = signContainment(c, site.attestationKey)
    fields.add(("containment", signed.statement))
    fields.add(("containmentSignature", signed.signature))
  recordEvidence(EvidenceEvent(detector: edContainment, category: ecAudit,
    trigger: (if action == "contain": "operator-contained"
              else: "operator-released"),
    kind: (if action == "contain": "contained" else: "released"),
    fields: fields, attest: true), site)

proc recordContainment(stateDir: string; site: EvidenceSite;
                       action, operator, reason: string): string =
  recordContainmentAs(site, credentialHostId(), action, operator, reason,
                      nextContainmentSequence(stateDir))

proc runContain*(operator, reason: string; stateDir = "/var/lib/repro/system";
                 site = defaultSite()): ContainResult =
  if operator.len == 0 or reason.len == 0:
    raise newException(ContainmentError, "--operator and --reason are required")
  if not fileExists(stateDir / "addon-ledger"):
    raise newException(ContainmentError, "this is not an add-on host")
  if isContained(stateDir):
    result.already = true
    return
  # 1. The record leaves the host before anything stops.
  result.record = recordContainment(stateDir, site, "contain", operator,
                                    reason)
  let s = shipNow(site)
  result.shipped = s.shipped
  result.shipError = s.error
  # 2. The marker, then 3. the units.
  createDir(stateDir / "addon")
  writeFile(containedMarkerPath(stateDir), "operator=" & operator &
    "\nreason=" & reason.replace("\n", " ") & "\nat=" &
    $now().utc & "\nrecord=" & result.record & "\n")
  let problems = maskAgent(containedMarkerPath(stateDir))
  if problems.len > 0:
    raise newException(ContainmentError, "the record was written and the " &
      "marker set, but systemctl refused: " & problems.join("; "))

proc reapplyContainment*(stateDir = "/var/lib/repro/system"): bool =
  ## At boot: mask the agent's units again while the marker exists (a
  ## runtime mask does not survive a reboot). True when it did.
  if not isContained(stateDir): return false
  discard maskAgent(containedMarkerPath(stateDir))
  true

proc runRelease*(operator, reason: string; stateDir = "/var/lib/repro/system";
                 site = defaultSite()): ContainResult =
  if operator.len == 0 or reason.len == 0:
    raise newException(ContainmentError, "--operator and --reason are required")
  if not isContained(stateDir):
    raise newException(ContainmentError, "this host is not contained")
  result.record = recordContainment(stateDir, site, "release", operator,
                                    reason)
  let s = shipNow(site)
  result.shipped = s.shipped
  result.shipError = s.error
  removeFile(containedMarkerPath(stateDir))
  removeContainDropIns()
  var problems: seq[string]
  let a = systemctlAll(["daemon-reload"], [])
  if a.len > 0: problems.add(a)
  let b = systemctlAll(["start"], [AgentFetchTimer])
  if b.len > 0: problems.add(b)
  if problems.len > 0:
    raise newException(ContainmentError, "released, but systemctl refused: " &
      problems.join("; "))

proc parseOperatorArgs(verb: string; args: seq[string]):
    tuple[operator, reason: string] =
  var i = 0
  while i < args.len:
    let a = args[i]
    var name = a
    var value = ""
    let eq = a.find('=')
    if eq > 0:
      name = a[0 ..< eq]
      value = a[eq + 1 .. ^1]
    elif i + 1 < args.len:
      inc i
      value = args[i]
    case name
    of "--operator": result.operator = value
    of "--reason": result.reason = value
    else: raise newException(ValueError, "unknown option " & a)
    inc i
  if result.operator.len == 0 or result.reason.len == 0:
    raise newException(ValueError, "usage: repro system addon " & verb &
      " --operator NAME --reason TEXT")

proc parseContainArgs*(args: seq[string]): tuple[operator, reason: string] =
  ## For the docs test (the user guide's runbook lines).
  parseOperatorArgs("contain", args)

proc runContainCli*(args: seq[string]; release = false): int =
  let verb = if release: "release" else: "contain"
  var o: tuple[operator, reason: string]
  try: o = parseOperatorArgs(verb, args)
  except ValueError as e:
    stderr.write("repro system addon " & verb & ": " & e.msg & "\n")
    return 2
  try:
    let r = if release: runRelease(o.operator, o.reason)
            else: runContain(o.operator, o.reason)
    if r.already:
      stdout.write("already contained (" & containedMarkerPath() & ")\n")
      return 0
    stdout.write((if release: "released" else: "contained") & "; record " &
      r.record & "\n")
    if r.shipped:
      stdout.write("the record reached the sink\n")
    else:
      stdout.write("the record did NOT reach the sink (" & r.shipError &
        "); it stays queued, and until it arrives the off-host check reads " &
        "the agent as silent\n")
    0
  except CatchableError as e:
    stderr.write("repro system addon " & verb & ": " & e.msg & "\n")
    1
