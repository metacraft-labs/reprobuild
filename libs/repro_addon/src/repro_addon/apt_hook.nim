## ``repro system addon verify --after-dpkg``: what the apt hook runs
## after every dpkg run (spec §7.8).
##
## The hook itself -- the ``DPkg::Post-Invoke`` line, its timeout and its
## exit-0 wrapper -- is generation 0's (``generation0.aptHookCommand``).
## This module is the verification it bounds. It reports, never refuses
## (spec §13 decision 4), and records three kinds of finding:
##
## - **a ledger object that changed**: the same comparison ``verify``
##   makes (``verify.runAddonVerify``), e.g. a package that unpacked a file
##   over a path the add-on owns;
## - **a package that now owns a ledger path**: dpkg (or ucf) lists the
##   path for a package the ledger's plan-time observation did not name --
##   a package installed or upgraded since the generation was applied
##   (the collision observer's own records, ``collision.CollisionDriver``);
## - **a changed vendor unit** behind a ``replace`` unit or a drop-in: its
##   file's digest differs from the one the current generation recorded in
##   its base identity (``base_identity.nim``).
##
## The ALPM hook (``verify --after-pacman``, Arch; milestone AR6) runs the
## same three and adds, by spec §7.8 and §4.3.1:
##
## - **a ``.pacnew`` or ``.pacsave`` beside a ledger path**, naming the
##   package (``base_identity.pacnewFindings``);
## - **a packaged hook under the ALPM hook's name**, which the add-on's
##   file in ``/etc/pacman.d/hooks`` silently disables (threat model T46);
## - **the base identity re-observed** (spec §7.9: every ``pacman -Syu`` is
##   a small release upgrade): what changed since the current generation's
##   record is a note, and a base the supported matrix no longer admits (a
##   systemd or pacman major outside it) is a finding -- the next apply
##   refuses with ``EAddOnUnsupportedBase``.
##
## The Omarchy post-update hook (``verify --after-base-update``, spec
## §4.3.2) runs the pacman verification and adds the ``overrideBaseLayer``
## re-check against the new Omarchy version's path set: an acknowledgement
## that acknowledges nothing now, and a declared path the new scripts name
## that no acknowledgement covers, each naming the script.
##
## Each finding goes to stdout (apt prints it), to the journal (``logger``,
## identifier ``repro-addon-apt-hook``) and to the hook's event log
## (``generation0.AptHookLogPath``), which the next plan and the deploy
## agent's tick see as drift. A clean run records nothing but one journal
## line. Nothing here may raise past ``runAfterDpkgCli``: the hook's
## wrapper exits 0 anyway, but a verification that fails is recorded as
## ``verify-failed`` rather than as what it found.

import std/[os, posix, strutils, tables, times]

import repro_infra/state_dir

import repro_infra/profile

import ./addon_apply
import ./base_identity
import ./collision
import ./evidence
import ./generation0
import ./host_exec
import ./ledger
import ./mutations
import ./omarchy
import ./pacman_db
import ./verify

type
  AfterDpkgReport* = object
    status*: string            ## ok | drift | degraded
    findings*: seq[string]     ## one line each
    notes*: seq[string]

const
  LoggerCandidates = [AptHookLoggerTool, "/bin/logger"]

proc vendorUnitFindings*(base: BaseIdentity): seq[string] =
  ## Every vendor unit whose file differs from the generation's record.
  when mutated("hook-ignores-vendor-units"):
    # FALSIFYING MUTATION: the third finding is never made.
    return @[]
  for v in base.vendorUnits:
    let now = vendorUnitDigest(vendorUnitFragment(v.unit))
    if now != v.sha256:
      result.add("vendor unit " & v.unit & " changed underneath the " &
        "add-on (" & (if v.fragment.len > 0: v.fragment else: "absent") &
        ": recorded " & v.sha256[0 ..< min(12, v.sha256.len)] & ", now " &
        now[0 ..< min(12, now.len)] & "); the add-on's drop-in or " &
        "replacement still applies -- check it")

proc runAfterDpkgVerify*(stateDir = DefaultStateDir;
                         driver: CollisionDriver = nil): AfterDpkgReport =
  ## The verification the hook runs. Read-only.
  let v = runAddonVerify(stateDir)
  result.status = v.status
  for f in v.findings: result.findings.add("changed: " & f)
  result.notes = v.notes
  if v.status == "degraded": return
  let l = readLedger(ledgerCopyPath(stateDir))
  let d = if driver != nil: driver else: detectCollisionDriver()
  for f in newOwnerFindings(l, d): result.findings.add(f)
  let current = readCurrentGenerationId(stateDir)
  if current.len > 0:
    for f in vendorUnitFindings(readGenerationBase(
        generationDir(stateDir, current))):
      result.findings.add(f)
  if result.findings.len > 0 and result.status == "ok":
    result.status = "drift"

type
  HookKind* = enum
    ## Which report-only hook a verification runs for (spec §7.8, §4.3.2).
    hkApt = "apt"
    hkAlpm = "alpm"
    hkOmarchy = "omarchy"

proc hookLogPath*(k: HookKind): string =
  case k
  of hkApt: AptHookLogPath
  of hkAlpm: AlpmHookLogPath
  of hkOmarchy: OmarchyHookLogPath

proc hookTag*(k: HookKind): string =
  case k
  of hkApt: AptBoundedHook.tag
  of hkAlpm: AlpmBoundedHook.tag
  of hkOmarchy: OmarchyBoundedHook.tag

proc hookLabel*(k: HookKind): string =
  case k
  of hkApt: AptBoundedHook.label
  of hkAlpm: AlpmBoundedHook.label
  of hkOmarchy: OmarchyBoundedHook.label

proc alpmHookShadowFindings*(root = "/"): seq[string] =
  ## A hook of the ALPM hook's name in pacman's default ``HookDir``, shipped
  ## by a package (or left there) after bootstrap: the add-on's file in
  ## ``/etc/pacman.d/hooks`` replaces it, silently disabling it (spec §7.8;
  ## threat model T46). Also a package that ships the add-on's own path.
  var owners: Table[string, seq[string]]
  try:
    owners = pacmanOwnersOf(AlpmHookPackagedPaths, root)
  except CatchableError as e:
    return @["cannot read the pacman database to check the ALPM hook's " &
      "name: " & e.msg]
  let packaged = AlpmHookPackagedPaths[0]
  if packaged in owners:
    result.add("package " & owners[packaged].join(", ") & " ships " &
      packaged & ", which the add-on's " & AlpmHookPath & " silently " &
      "disables (the first HookDir with a name wins); rename or remove one")
  elif fileExists(root.strip(leading = false, chars = {'/'}) & packaged) or
      symlinkExists(root.strip(leading = false, chars = {'/'}) & packaged):
    result.add(packaged & " exists, and the add-on's " & AlpmHookPath &
      " silently disables it (the first HookDir with a name wins)")
  if AlpmHookPath in owners:
    result.add("package " & owners[AlpmHookPath].join(", ") & " now owns " &
      AlpmHookPath & ", the add-on's ALPM hook")

proc baseReobservation*(stateDir: string; driver: CollisionDriver):
    tuple[notes, findings: seq[string]] =
  ## The base identity read again (spec §7.9; AR6): what changed since the
  ## current generation's record (notes), and a matrix refusal (a finding).
  ## Read-only.
  let l = readLedger(ledgerCopyPath(stateDir))
  let now = observeBaseIdentity(l, @[], driver)
  let current = readCurrentGenerationId(stateDir)
  if current.len > 0:
    let recorded = readGenerationBase(generationDir(stateDir, current))
    for c in baseIdentityChanges(recorded, now):
      result.notes.add("base identity: " & c)
  let why = matrixRefusal(now)
  if why.len > 0:
    result.findings.add("the base is outside the supported matrix now (" &
      describeBase(now) & "): " & why & "; the next apply refuses with " &
      "EAddOnUnsupportedBase")
  else:
    result.notes.add("base identity re-observed: " & describeBase(now) &
      ", accepted by the supported matrix")

proc runAfterPacmanVerify*(stateDir = DefaultStateDir;
                           driver: CollisionDriver = nil): AfterDpkgReport =
  ## The ALPM hook's verification (spec §7.8; AR6). Read-only.
  let d = if driver != nil: driver else: detectCollisionDriver()
  result = runAfterDpkgVerify(stateDir, d)
  if result.status == "degraded": return
  let l = readLedger(ledgerCopyPath(stateDir))
  for f in pacnewFindings(l, d): result.findings.add(f)
  for f in alpmHookShadowFindings(): result.findings.add(f)
  try:
    let b = baseReobservation(stateDir, d)
    result.notes.add(b.notes)
    result.findings.add(b.findings)
  except CatchableError as e:
    result.findings.add("cannot re-observe the base identity: " & e.msg)
  if result.findings.len > 0 and result.status == "ok":
    result.status = "drift"

proc overrideRecheckFindings*(stateDir: string; root = "/"): seq[string] =
  ## The ``overrideBaseLayer`` re-check after an Omarchy update (spec
  ## §4.3.2; AR6): the stored operator profile against the path set of the
  ## Omarchy version now installed. An acknowledgement that acknowledges
  ## nothing any more (the new scripts no longer name its path) and a
  ## declaration the new scripts name without one (the next plan refuses
  ## it with ``EAddOnBaseLayerOwned``) are findings, each naming the
  ## script. Read-only.
  when mutated("omarchy-override-not-rechecked"):
    # FALSIFYING MUTATION: the re-check is skipped.
    return @[]
  let p = userProfilePath(stateDir)
  if not fileExists(p): return
  var user: SystemProfile
  try: user = parseStoredUserProfile(readFile(p), stateDir)
  except CatchableError as e:
    return @["cannot read the stored operator profile for the " &
      "overrideBaseLayer re-check: " & e.msg]
  let set = readOmarchyPathSet(root)
  let ok = omarchyPathSetCheck(set)
  if not ok.ok:
    return @["the Omarchy path set cannot be read after the update: " &
      ok.detail]
  let ver = pacmanInstalledVersion(OmarchyPackage, root)
  let c = baseLayerCheck(set, user)
  for o in c.overrides:
    let f = o.split('\t')
    if f.len == 3 and f[2].startsWith("acknowledges nothing"):
      result.add("overrideBaseLayer on " & f[0] & " (" & f[1] & ") " &
        "acknowledges nothing now: the scripts of Omarchy " & ver &
        " no longer name it; remove the acknowledgement")
  for r in c.refusals:
    result.add("Omarchy " & ver & " now names a path the profile declares " &
      "without an acknowledgement: " & r & "; the next plan refuses it " &
      "with EAddOnBaseLayerOwned")

proc runAfterBaseUpdateVerify*(stateDir = DefaultStateDir;
                               driver: CollisionDriver = nil): AfterDpkgReport =
  ## The Omarchy post-update hook's verification (spec §4.3.2; AR6): the
  ## pacman verification, then the ``overrideBaseLayer`` re-check.
  result = runAfterPacmanVerify(stateDir, driver)
  if result.status == "degraded": return
  for f in overrideRecheckFindings(stateDir): result.findings.add(f)
  if result.findings.len > 0 and result.status == "ok":
    result.status = "drift"

proc renderAfterDpkg*(r: AfterDpkgReport): string =
  result = "repro-addon apt hook: " & r.status & "\n"
  for f in r.findings: result.add("  " & f & "\n")

const
  AptHookLogMaxBytes* = 1 shl 20
    ## The event log is rotated when it reaches 1 MiB: the file becomes
    ## ``apt-hook.log.1`` (replacing an older one), so the hook keeps at most
    ## about 2 MiB on the host. A finding stays reported by every run until
    ## it is resolved, so a long-unresolved one fills the log; rotation
    ## keeps the latest runs, which say the same.
  JournalTimeoutSec* = 5
    ## Upper bound on the whole journal hand-off of one run.

proc journal(priority: string; lines: openArray[string];
             tag = "repro-addon-apt-hook"; loggerExe = "") =
  ## Every line to the journal through ONE ``logger`` (util-linux /
  ## bsdutils), reading them from stdin, bounded by ``JournalTimeoutSec``
  ## in all. Best effort, never raising: the event log, written first, is
  ## the record.
  if lines.len == 0: return
  try:
    let exe = if loggerExe.len > 0: loggerExe
              else: resolveHostTool(LoggerCandidates)
    if exe.len == 0: return
    discard runHostTool([exe, "-t", tag, "-p",
                         "user." & priority], input = lines.join("\n") & "\n",
                        timeoutSec = JournalTimeoutSec)
  except CatchableError:
    discard

proc rotateEventLog*(path: string; maxBytes = AptHookLogMaxBytes) =
  ## Move ``path`` to ``path.1`` once it has reached ``maxBytes``.
  try:
    if fileExists(path) and getFileSize(path) >= maxBytes:
      moveFile(path, path & ".1")
  except CatchableError:
    discard

proc appendEventLog*(path: string; lines: openArray[string];
                     maxBytes = AptHookLogMaxBytes) =
  ## Append ``<UTC time> <line>`` for each line, flushed and fsynced;
  ## rotate first when the log is full. Best effort.
  if lines.len == 0: return
  rotateEventLog(path, maxBytes)
  let stamp = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  var text = ""
  for l in lines:
    text.add(stamp & " " & l.replace('\n', ' ') & "\n")
  try:
    createDir(parentDir(path))
    var f: File
    if open(f, path, fmAppend):
      defer: f.close()
      f.write(text)
      f.flushFile()
      discard posix.fsync(f.getFileHandle())
  except CatchableError:
    discard

proc omarchyAttributions*(r: var AfterDpkgReport; root = "/") =
  ## After an Omarchy update, each ``changed:`` finding whose path the
  ## installed Omarchy's scripts name gets those scripts appended: the
  ## migration that wrote it (spec §4.3.2: drift "with the migration
  ## named"). Best effort; a path set that cannot be read adds nothing.
  var set: OmarchyPathSet
  try: set = readOmarchyPathSet(root)
  except CatchableError: return
  for f in r.findings.mitems:
    if not f.startsWith("changed: "): continue
    let words = f.splitWhitespace()
    if words.len < 3: continue
    let path = words[2].strip(leading = false, chars = {':'})
    var scripts: seq[string]
    for e in fileIntersections(set, path):
      for sc in e.scripts:
        if sc notin scripts: scripts.add(sc)
    if scripts.len > 0:
      f.add(" (named by Omarchy " & scripts.join(", ") & ")")

proc runHookCli*(kind: HookKind; stateDir = DefaultStateDir;
                 logPath = "";
                 site = defaultSite(DefaultStateDir);
                 dpkgLog = "/var/log/dpkg.log"): int =
  ## A hook's entry point: report, record (event log first, then the
  ## journal), exit 0.
  let log = if logPath.len > 0: logPath else: hookLogPath(kind)
  let tag = hookTag(kind)
  let label = hookLabel(kind)
  var r: AfterDpkgReport
  try:
    r = case kind
        of hkApt: runAfterDpkgVerify(stateDir)
        of hkAlpm: runAfterPacmanVerify(stateDir)
        of hkOmarchy:
          (var x = runAfterBaseUpdateVerify(stateDir); omarchyAttributions(x); x)
  except CatchableError as e:
    r = AfterDpkgReport(status: "degraded", findings: @[e.msg])
  stdout.write(label & ": " & r.status & "\n")
  for f in r.findings: stdout.write("  " & f & "\n")
  # The notes (the base identity re-observed) are the pacman and Omarchy
  # hooks'; the apt hook's output is A10's.
  if kind != hkApt:
    for n in r.notes: stdout.write("  note: " & n & "\n")
  # The evidence record (spec §7.8, §10.4; DET-AO-6): every run leaves one,
  # naming the dpkg run it followed, so the off-host check can tell a hook
  # that ran clean from one that never ran (DET-AO-8). A clean run's goes
  # off-host only; findings are a detection with a local copy too.
  try:
    var site = site
    site.stateDir = stateDir
    var fields = @[("status", r.status), ("count", $r.findings.len),
                   ("message", r.findings.join("; "))]
    if kind == hkApt:
      fields.insert(("dpkgLastRun", dpkgLastRun(dpkgLog)), 2)
    else:
      fields.add(("hook", $kind))
    discard recordEvidence(EvidenceEvent(detector: edAptHook,
      category: ecAudit, trigger: "hook-run", fields: fields, attest: true,
      offHostOnly: true), site)
    if r.status != "ok":
      discard recordEvidence(EvidenceEvent(detector: edAptHook,
        category: ecDetection, trigger: "hook-finding",
        kind: $kind & "-hook-" & r.status, fields: fields, attest: true), site)
  except CatchableError as e:
    stderr.write(label & ": cannot write its evidence record: " &
      e.msg & "\n")
  if r.status == "ok":
    var jl = @[label & ": ok"]
    if kind != hkApt:
      for n in r.notes: jl.add(label & ": " & n)
    journal("info", jl, tag = tag)
    return 0
  var lines = @[r.status & " " & $r.findings.len & " finding(s)"]
  var jl = @[label & ": " & r.status & ", " & $r.findings.len &
             " finding(s)"]
  for f in r.findings:
    lines.add("finding " & f)
    jl.add(label & ": " & f)
  appendEventLog(log, lines)
  journal("warning", jl, tag = tag)
  0

proc runAfterDpkgCli*(stateDir = DefaultStateDir;
                      logPath = AptHookLogPath;
                      site = defaultSite(DefaultStateDir);
                      dpkgLog = "/var/log/dpkg.log"): int =
  ## The apt hook's entry point (A10): ``runHookCli`` for ``hkApt``. Its
  ## output, records and journal lines are A10's.
  runHookCli(hkApt, stateDir, logPath, site, dpkgLog)

# ---------------------------------------------------------------------------
# The deploy agent's view: the hook's events since its previous tick.
# ---------------------------------------------------------------------------

proc fileIdentity(path: string): string =
  ## ``<device>:<inode>`` of ``path``, "" when absent.
  var st: Stat
  if stat(path.cstring, st) != 0: return ""
  $st.st_dev & ":" & $st.st_ino

proc readFrom(path: string; offset: int64): string =
  try:
    var f: File
    if not open(f, path, fmRead): return ""
    defer: f.close()
    let size = getFileSize(f)
    if offset >= size: return ""
    f.setFilePos(offset)
    result = newString(int(size - offset))
    let n = f.readBuffer(addr result[0], result.len)
    result.setLen(max(n, 0))
  except CatchableError:
    result = ""

const AptHookCursorName* = "apt-hook.cursor"
  ## Under the agent's state directory: how far the agent has read the
  ## hook's event log.

proc hookEventsSince*(cursorPath: string; logPath = AptHookLogPath): seq[string] =
  ## Every event line the hook appended since the cursor in ``cursorPath``
  ## (``<device>:<inode> <offset>`` of the log as last read), then moves the
  ## cursor to the end. A rotation since (the log is a new file) is
  ## followed: the rest of the rotated file, then the new one from its
  ## start. With no cursor yet, everything in the log counts -- a first
  ## tick on a host that already has drift reports it. Never raises.
  var savedId = ""
  var savedOff = 0'i64
  try:
    let parts = readFile(cursorPath).strip().splitWhitespace()
    if parts.len == 2:
      savedId = parts[0]
      savedOff = parseBiggestInt(parts[1])
  except CatchableError:
    discard
  let curId = fileIdentity(logPath)
  var text = ""
  var newOff = 0'i64      # the cursor ends where THIS read ended, so an
                          # event appended meanwhile is read next time
  if savedId.len > 0 and savedId == curId:
    let t = readFrom(logPath, savedOff)
    text = t
    newOff = savedOff + t.len
  else:
    if savedId.len > 0 and fileIdentity(logPath & ".1") == savedId:
      text = readFrom(logPath & ".1", savedOff)
    let t = readFrom(logPath, 0)
    text.add(t)
    newOff = t.len
  for l in text.splitLines():
    if l.strip().len > 0: result.add(l)
  try:
    createDir(parentDir(cursorPath))
    writeFile(cursorPath & ".tmp", curId & " " & $newOff & "\n")
    moveFile(cursorPath & ".tmp", cursorPath)
  except CatchableError:
    discard

const AgentDriftLogPath* = "/var/lib/repro/system/addon/agent-drift.log"
  ## The deploy agent's evidence record of drift (spec §7.8, §9.2): one line
  ## per event a tick reported, in the hook log's format. Kept apart from
  ## the hook's own log because the agent reads that one from a cursor.

proc recordAgentDrift*(outcome: string; sequence: uint64;
                       events: openArray[string];
                       logPath = AgentDriftLogPath; loggerExe = "") =
  ## What one agent tick reported as drift: appended to the agent's event
  ## log first (fsynced, rotated like the hook's), then sent to the journal
  ## under ``repro-addon-agent`` at priority warning. Nothing on a tick with
  ## no drift; best effort, never raising, never changing the tick.
  if events.len == 0: return
  var lines = @["agent-tick " & outcome & " sequence " & $sequence & ": " &
                $events.len & " drift event(s)"]
  for e in events: lines.add("drift " & e)
  appendEventLog(logPath, lines)
  var jl: seq[string]
  for l in lines: jl.add("repro-addon agent: " & l)
  journal("warning", jl, tag = "repro-addon-agent", loggerExe = loggerExe)
