## The network guard (ReproOS Add-On Mode §4.5 steps 1-4, §5.3, §7.2 step
## 9, §7.7; §13 decisions 86, 87, 102-110, 116-129; threat model G47, G48,
## T54-T56, T59, T62).
##
## A generation that adds, changes or removes a ``network`` object is
## applied only under an independent revert: before the switch the apply
## arms a transient systemd timer that runs ``revert-network`` for the
## attempt after ``networkGuard.timeout``, independently of the apply
## process and of the store. The generation commits only once the guard
## is DISARMED: every invariant holds after the switch (each ``keep``
## address, the default routes observed before it, each out-of-band link)
## and a new key-authenticated SSH session has arrived from a non-loopback
## address that is not one of the host's own (or ``repro system addon
## confirm`` ran from such a session), created after the switch wrote its
## last network object.
##
## This module holds the guard's mechanisms; the switch (``addon_apply``),
## recovery (``reassert``) and the ``revert-network`` verb (``cli``) decide
## with them. They are:
##
## - **the out-of-store binary** ``/var/lib/repro/bin/repro`` (decisions
##   127-129), which every guard unit runs, so the guard works with the
##   store unreadable. Before every arm it is verified against the store's
##   CURRENT add-on binary and rewritten from it when it differs or is
##   missing; with the store unreadable, a copy matching the current
##   ledger's digest is used, and anything else is a failed arm. Never
##   drift;
## - **the timers**: transient ``repro-addon-guard-<attempt>-<tag>``
##   timer/service pairs (``systemd-run --on-active``), with
##   ``RemainAfterElapse=no`` so an elapsed timer leaves no unit behind,
##   listed, stopped and armed here. A unit name carries its attempt, so
##   every actor can tell "a timer of this attempt is loaded" (decisions
##   118, 121, 126) and uninstall can stop every one of them (decision
##   122);
## - **the guard record** ``<state>/addon/guard-record``: written durably
##   before the arm, it names the attempt, the generation a revert goes
##   back to, the connections the attempt writes and the previous
##   generation's connections with their preserved bytes (under the state
##   directory). ``revert-network`` restores the network objects from it
##   alone, with no store (step 3 of the firing);
## - **the invariants and the SSH evidence**: the journal is read only
##   through its trusted fields (``_SYSTEMD_UNIT`` the host's ssh unit,
##   ``_EXE`` its sshd or OpenSSH's per-session ``sshd-session``), never
##   ``SYSLOG_IDENTIFIER`` (threat model T55); a confirm counts only from
##   a logind session created after the switch wrote its last network
##   object; a session from an address the host holds itself never counts.

import std/[algorithm, json, monotimes, net, os, posix, sets, strutils, tables,
            times]

import repro_infra/addon_diagnostics
import repro_infra/apply_lock
import repro_infra/profile

import repro_elevation/nofollow_write

import ./fingerprint
import ./generation0
import ./host_exec
import ./ledger
import ./mutations
import ./network_link
import ./seams
import ./static_tree
import ./store_root

const
  GuardBinaryDir* = "/var/lib/repro/bin"
  GuardBinaryPath* = GuardBinaryDir / "repro"
  GuardUnitPrefix* = "repro-addon-guard-"
  SuccessorIntervalSec* = 10
    ## The successor timer's interval (§13 decision 109).
  GuardTimerReason* = "guard timer fired"
    ## ``fired``'s reason when the attempt's original timer fires.
  TimerGoneReason* = "armed, its timer gone"
  ArmedAcrossRebootReason* = "armed across a reboot"
  InterruptedByRebootSuffix* = "; revert interrupted by a reboot"
  GuardUnitsLeftPrefix* = "guard units still loaded"
    ## ``stopEveryGuardUnit``'s last line when units survived every pass.

var guardBinaryPath* = GuardBinaryPath
  ## The copy's path; only a unit test points it elsewhere.

proc nowRealtimeUs*(): int64 = int64(epochTime() * 1_000_000)
proc nowMonoUs*(): int64 = getMonoTime().ticks div 1000

proc randomHex*(n: int): string =
  ## ``n`` hex digits from the kernel's random source.
  var f: File
  if not open(f, "/dev/urandom"):
    raise newException(IOError, "cannot read /dev/urandom")
  defer: f.close()
  var buf = newString((n + 1) div 2)
  if f.readBuffer(addr buf[0], buf.len) != buf.len:
    raise newException(IOError, "short read from /dev/urandom")
  for c in buf: result.add(toHex(ord(c), 2).toLowerAscii())
  result = result[0 ..< n]

proc newAttemptId*(): string = randomHex(32)

proc guardUnitName*(attempt, tag: string): string =
  GuardUnitPrefix & attempt & "-" & tag

proc attemptOfUnit*(unit: string): string =
  ## The attempt a guard unit belongs to ("" when ``unit`` is not one).
  var u = unit
  for suffix in [".timer", ".service"]:
    if u.endsWith(suffix): u = u[0 ..< u.len - suffix.len]
  if not u.startsWith(GuardUnitPrefix): return ""
  let rest = u[GuardUnitPrefix.len .. ^1]
  let dash = rest.find('-')
  if dash != 32: return ""
  rest[0 ..< 32]

# ---------------------------------------------------------------------------
# The guard record.
# ---------------------------------------------------------------------------

type
  GuardObject* = object
    path*, uuid*, sha256*, preserved*: string
    name*: string                    ## the link's interface name

  GuardRecord* = object
    attempt*: string
    previous*: string                ## the generation a revert goes back to
    attemptObjects*: seq[GuardObject] ## what the attempt writes
    previousObjects*: seq[GuardObject] ## the previous generation's, with the
                                     ## path of their preserved bytes

proc guardRecordPath*(stateDir: string): string =
  stateDir / "addon" / "guard-record"

proc render*(r: GuardRecord): string =
  result = "# repro-addon-guard-record v1\n"
  result.add("attempt\t" & escapeField(r.attempt) & "\n")
  result.add("previous\t" & escapeField(r.previous) & "\n")
  for o in r.attemptObjects:
    result.add("attempt-object\t" & escapeField(o.path) & "\t" &
      escapeField(o.uuid) & "\t" & escapeField(o.sha256) & "\t" &
      escapeField(o.name) & "\n")
  for o in r.previousObjects:
    result.add("previous-object\t" & escapeField(o.path) & "\t" &
      escapeField(o.uuid) & "\t" & escapeField(o.sha256) & "\t" &
      escapeField(o.preserved) & "\t" & escapeField(o.name) & "\n")

proc parseGuardRecord*(text: string): GuardRecord =
  let lines = text.splitLines()
  if lines.len == 0 or lines[0] != "# repro-addon-guard-record v1":
    raise newException(ValueError, "not a repro-addon guard record")
  for line in lines[1 .. ^1]:
    if line.len == 0: continue
    var f: seq[string]
    for x in line.split('\t'): f.add(unescapeField(x))
    case f[0]
    of "attempt": result.attempt = f[1]
    of "previous": result.previous = f[1]
    of "attempt-object":
      if f.len != 5: raise newException(ValueError, "malformed guard record")
      result.attemptObjects.add(GuardObject(path: f[1], uuid: f[2],
                                            sha256: f[3], name: f[4]))
    of "previous-object":
      if f.len != 6: raise newException(ValueError, "malformed guard record")
      result.previousObjects.add(GuardObject(path: f[1], uuid: f[2],
                                             sha256: f[3], preserved: f[4],
                                             name: f[5]))
    else: raise newException(ValueError, "unknown guard record field " & f[0])

proc writeGuardRecord*(stateDir: string; r: GuardRecord) =
  ## Durable (fsynced and renamed) before the timer that reads it is armed.
  createDir(stateDir / "addon")
  writeFileNoFollow(guardRecordPath(stateDir), r.render(), 0o600)

proc readGuardRecord*(stateDir: string): GuardRecord =
  parseGuardRecord(readFile(guardRecordPath(stateDir)))

proc clearGuardRecord*(stateDir: string) =
  try: discard removeLeafNoFollow(guardRecordPath(stateDir))
  except CatchableError: discard

proc keyfileUuid*(content: string): string =
  for line in content.splitLines():
    if line.startsWith("uuid="): return line[5 .. ^1].strip()
  ""

# ---------------------------------------------------------------------------
# The out-of-store binary (§13 decisions 127-129).
# ---------------------------------------------------------------------------

proc storeAddonBinaryOf*(ownProfileText: string): string =
  ## The add-on binary generation 0's units run: the store path ending
  ## ``/bin/repro`` that the re-assert unit's ``ExecStart=`` names in the
  ## own profile (the profile every switch applies). "" when none is.
  for line in ownProfileText.splitLines():
    let t = line.strip()
    if not t.startsWith("ExecStart="): continue
    for word in t["ExecStart=".len .. ^1].splitWhitespace():
      let w = word.strip(chars = {'-', '@', '+', '!', ':'}, trailing = false)
      if w.startsWith(StoreRoot & "/") and w.endsWith("/bin/repro") and
          " system addon reassert" in t:
        return w
  ""

type
  GuardBinaryCheck* = object
    ok*: bool          ## the copy is good to arm with
    repaired*: bool    ## it was rewritten from the store
    digest*: string    ## its SHA-256 now
    note*: string      ## what was done, for the report
    why*: string       ## why the arm must fail (``ok`` false)

proc storeBinaryVerified(storeExe: string): tuple[ok: bool; digest, why: string] =
  ## Is the store's add-on binary readable and the bytes its prefix's
  ## name stands for? The prefix is content-addressed by the binary's
  ## SHA-256 (``store_root.binaryPrefixPath``), so the check needs no
  ## other record. "Store unreadable" (§13 decision 127) is any failure.
  if storeExe.len == 0:
    return (false, "", "no add-on binary is named by the own profile")
  if not dirExists(StoreRoot):
    return (false, "", StoreRoot & " is missing or not mounted")
  if not fileExists(storeExe) or symlinkExists(storeExe):
    return (false, "", storeExe & " is not readable")
  var digest = ""
  try: digest = sha256OfFile(storeExe)
  except CatchableError as e:
    return (false, "", storeExe & " cannot be read: " & e.msg)
  let prefix = parentDir(parentDir(storeExe))
  if binaryPrefixPath(digest, prefixVersionOf(prefix)) != prefix:
    return (false, digest, storeExe & " does not hold the bytes its " &
      "prefix names (sha256 " & digest & ")")
  (true, digest, "")

proc ensureGuardBinary*(storeExe, ledgerDigest: string;
                        path = guardBinaryPath): GuardBinaryCheck =
  ## Verify the copy against the store's current add-on binary and rewrite
  ## it (directory 0700 root, file 0755) when it differs or is missing,
  ## reporting the repair (decision 128). With the store unreadable, a copy
  ## matching ``ledgerDigest`` (the current ledger's ``guardBinary``
  ## digest) is used; anything else is a failed arm.
  let store = storeBinaryVerified(storeExe)
  var have = ""
  if fileExists(path) and not symlinkExists(path):
    try: have = sha256OfFile(path)
    except CatchableError: have = ""
  if not store.ok:
    if have.len > 0 and have == ledgerDigest:
      return GuardBinaryCheck(ok: true, digest: have, note: "the store is " &
        "unreadable (" & store.why & "); " & path & " matches the ledger's " &
        "digest and is used")
    return GuardBinaryCheck(ok: false, digest: have, why: "the store is " &
      "unreadable (" & store.why & ") and " & path &
      (if have.len == 0: " is missing" else: " does not match the ledger's " &
         "digest " & ledgerDigest) & "; no good copy can be made")
  if have == store.digest:
    return GuardBinaryCheck(ok: true, digest: have)
  try:
    let dir = parentDir(path)
    if not dirExists(dir):
      createDir(dir)
    discard chmod(dir.cstring, Mode(0o700))
    writeFileNoFollow(path, readFile(storeExe), 0o755, uid = 0, gid = 0)
  except CatchableError as e:
    return GuardBinaryCheck(ok: false, digest: have, why: "cannot write " &
      path & ": " & e.msg)
  GuardBinaryCheck(ok: true, repaired: true, digest: store.digest,
    note: path & (if have.len == 0: " was missing" else: " differed from " &
      "the store's add-on binary (sha256 " & have[0 ..< 12] & ")") &
      "; rewritten from " & storeExe & " (repaired, never drift: §13 " &
      "decision 128)")

proc guardBinaryEntry*(digest: string; path = guardBinaryPath): LedgerEntry =
  LedgerEntry(class: lcGuardBinary, path: path, sha256: digest,
              mode: "0755", owner: "0:0")

# ---------------------------------------------------------------------------
# Timers.
# ---------------------------------------------------------------------------

type ArmResult* = object
  unit*: string        ## the unit armed, "" when the arm failed
  problem*: string     ## ``EAddOnGuardTimer``'s detail when it failed

proc newTag(): string = randomHex(8)

proc armGuardTimer*(stateDir, attempt, previous, reason: string;
                    delaySec: int): ArmResult =
  ## Arm a guard timer for ``attempt``: ``systemd-run --on-active`` of
  ## ``/var/lib/repro/bin/repro system addon revert-network <previous>
  ## --attempt <attempt> [--reason <reason>]``, a transient timer and
  ## service named ``repro-addon-guard-<attempt>-<tag>``. A failure is
  ## returned (decisions 125, 126), never raised: the caller decides
  ## whether it refuses (before a switch) or reports and goes on (during
  ## a revert).
  let unit = guardUnitName(attempt, newTag())
  when mutated("guard-skips-arm"):
    # FALSIFYING MUTATION (e2e_omarchy_addon_network_guard_reverts_lost_address):
    # no transient revert unit is armed, and the arm reports success.
    return ArmResult(unit: unit)
  if seamFlag(stateDir, "guard-arm-fails"):
    return ArmResult(problem: diagnosticMessage(adGuardTimer, "systemd-run " &
      "refused (test seam guard-arm-fails)"))
  if not fileExists(guardBinaryPath) or symlinkExists(guardBinaryPath):
    return ArmResult(problem: diagnosticMessage(adGuardTimer,
      guardBinaryPath & " (the guard's static repro) is missing"))
  let run = resolveHostTool(SystemdRunCandidates)
  if run.len == 0:
    return ArmResult(problem: diagnosticMessage(adGuardTimer,
      "no systemd-run on the host"))
  var argv = @[run, "--quiet", "--collect", "--unit=" & unit,
    "--description=repro add-on network guard for attempt " & attempt,
    "--on-active=" & $max(1, delaySec) & "s",
    "--timer-property=AccuracySec=1s",
    "--timer-property=RemainAfterElapse=no",
    "--property=Type=oneshot",
    "--", guardBinaryPath, "system", "addon", "revert-network", previous,
    "--attempt", attempt, "--state-dir", stateDir]
  if reason.len > 0: argv.add(["--reason", reason])
  try:
    let r = runHostTool(argv, timeoutSec = 60)
    if r.exitCode != 0:
      return ArmResult(problem: diagnosticMessage(adGuardTimer,
        "systemd-run failed (exit " & $r.exitCode & "): " & r.output.strip()))
  except CatchableError as e:
    return ArmResult(problem: diagnosticMessage(adGuardTimer,
      "systemd-run could not run: " & e.msg))
  ArmResult(unit: unit)

proc verifyGuardBinaryOf*(stateDir: string): GuardBinaryCheck =
  ## Decision 128 for an arm made outside the switch's own check before
  ## step 1 (a recovery's or a failure path's fresh timer, a successor):
  ## the copy is verified against the store's add-on binary that the
  ## host's own profile names, and repaired; with the store unreadable,
  ## against the current ledger's ``guardBinary`` digest.
  var own = ""
  try: own = readFile(stateDir / "addon" / "own.profile")
  except CatchableError: discard
  var digest = ""
  try:
    for e in readLedger(stateDir / "addon-ledger").entries:
      if e.class == lcGuardBinary: digest = e.sha256
  except CatchableError:
    discard
  ensureGuardBinary(storeAddonBinaryOf(own), digest)

proc armVerifiedGuardTimer*(stateDir, attempt, previous, reason: string;
                            delaySec: int): tuple[arm: ArmResult;
                                                  note: string] =
  ## Every arm but the switch's own (which verified the copy before step
  ## 1): verify and repair the copy first (``verifyGuardBinaryOf``), so a
  ## timer never runs bytes that cannot revert; a copy that cannot be made
  ## good is a failed arm (``EAddOnGuardTimer``), which the caller reports
  ## and goes on from (decisions 125, 126, 128). ``note`` says what the
  ## verification did (a repair), "" when nothing.
  let chk = verifyGuardBinaryOf(stateDir)
  if not chk.ok:
    return (ArmResult(problem: diagnosticMessage(adGuardTimer, chk.why)), "")
  (armGuardTimer(stateDir, attempt, previous, reason, delaySec), chk.note)

proc listGuardUnits*(pattern: string): seq[tuple[unit, load, active: string]] =
  ## ``systemctl list-units --all`` of the units matching ``pattern``.
  try:
    let r = runSystemctl(["list-units", "--all", "--plain", "--no-legend",
                          "--no-pager", pattern])
    for line in r.output.splitLines():
      let f = line.splitWhitespace()
      if f.len >= 3 and f[0].startsWith(GuardUnitPrefix):
        result.add((f[0], f[1], f[2]))
  except CatchableError:
    discard

proc loadedGuardTimers*(attempt: string): seq[string] =
  ## The attempt's timers that are loaded and still pending: "a timer of
  ## its attempt is loaded" (decisions 118, 121, 126).
  for u in listGuardUnits(GuardUnitPrefix & attempt & "-*.timer"):
    if u.unit.endsWith(".timer") and u.load == "loaded" and
        u.active == "active":
      result.add(u.unit[0 ..< u.unit.len - ".timer".len])

proc ownGuardUnit*(): string =
  ## The guard unit this process runs in ("" when none): read from its
  ## cgroup, which systemd names after the unit.
  try:
    for line in readFile("/proc/self/cgroup").splitLines():
      let leaf = line.rsplit('/', 1)[^1]
      if leaf.startsWith(GuardUnitPrefix) and leaf.endsWith(".service"):
        return leaf[0 ..< leaf.len - ".service".len]
  except CatchableError:
    discard
  ""

proc stopGuardUnit*(unit: string) =
  ## Stop one timer and its service (the caller's own service excepted:
  ## it ends when the caller exits).
  var args = @["stop", "--no-block", "--", unit & ".timer"]
  if unit != ownGuardUnit(): args.add(unit & ".service")
  try: discard runSystemctl(args)
  except CatchableError: discard

proc stopAttemptTimers*(attempt: string): seq[string] =
  ## Stop every timer of ``attempt`` and its service: the revert's last
  ## act (decision 106), and recovery's after a commit (decision 117).
  ## Returns the units stopped.
  var seen = initHashSet[string]()
  for u in listGuardUnits(GuardUnitPrefix & attempt & "-*"):
    var base = u.unit
    for s in [".timer", ".service"]:
      if base.endsWith(s): base = base[0 ..< base.len - s.len]
    if base in seen: continue
    seen.incl(base)
    stopGuardUnit(base)
    result.add(base)

proc stopEveryGuardUnit*(maxPasses = 30): seq[string] =
  ## Uninstall's loop (spec §6.4 step 5; §13 decisions 122, 124): stop
  ## every ``repro-addon-guard-*`` unit, pass after pass, until none is
  ## loaded -- a firing between two passes arms a successor, which the
  ## next pass stops. Returns one line per pass.
  for pass in 1 .. maxPasses:
    let units = listGuardUnits(GuardUnitPrefix & "*")
    var live: seq[string]
    for u in units:
      if u.load == "loaded" and u.active notin ["inactive", "failed"]:
        live.add(u.unit)
    if live.len == 0 and units.len == 0:
      result.add("pass " & $pass & ": no guard unit left")
      return
    var args = @["stop", "--"]
    for u in units: args.add(u.unit)
    try: discard runSystemctl(args)
    except CatchableError: discard
    try: discard runSystemctl(@["reset-failed", "--"] &
                              (block:
                                var names: seq[string]
                                for u in units: names.add(u.unit)
                                names))
    except CatchableError: discard
    var names: seq[string]
    for u in units: names.add(u.unit)
    result.add("pass " & $pass & ": stopped " & names.join(" "))
  result.add(GuardUnitsLeftPrefix & " after " & $maxPasses & " passes")

# ---------------------------------------------------------------------------
# Restoring the network objects without the store (revert-network step 3).
# ---------------------------------------------------------------------------

proc restoreNetworkObjects*(rec: GuardRecord): seq[string] =
  ## Put the previous generation's connections back from their preserved
  ## bytes and remove the connections the attempt wrote that the previous
  ## generation does not have; if a preserved copy cannot be read, the
  ## attempt's own connections are removed all the same (spec §4.5 step
  ## 1). Needs no store. Returns the problems.
  var previous = initHashSet[string]()
  for o in rec.previousObjects: previous.incl(o.path)
  for o in rec.attemptObjects:
    if o.path in previous: continue
    let uuid = if o.uuid.len > 0: o.uuid
               elif fileExists(o.path): keyfileUuid(readFile(o.path))
               else: ""
    let p = removeNetworkObject(o.path, uuid, o.name)
    if p.len > 0: result.add(p)
  for o in rec.previousObjects:
    var have = ""
    if fileExists(o.path) and not symlinkExists(o.path):
      try: have = sha256OfFile(o.path)
      except CatchableError: discard
    if have == o.sha256: continue
    var bytes = ""
    try:
      bytes = readFile(o.preserved)
      if sha256Hex(bytes) != o.sha256:
        result.add(o.preserved & " does not hold the bytes of " & o.path)
        continue
    except CatchableError as e:
      result.add("the preserved bytes of " & o.path & " are unreadable: " &
                 e.msg)
      continue
    try:
      writeKeyfile(o.path, bytes)
    except CatchableError as e:
      result.add("cannot write " & o.path & ": " & e.msg)
      continue
    let a = activateKeyfile(o.path, o.uuid)
    if a.len > 0: result.add(a)

# ---------------------------------------------------------------------------
# The invariants (spec §4.5 step 3).
# ---------------------------------------------------------------------------

proc invariantFailures*(guard: NetworkGuardSettings;
                        defaultRoutesBefore: seq[string];
                        h: HostNetwork): seq[string] =
  ## Each invariant that does not hold now, as a line the revert's record
  ## names: a missing ``keep`` address, a default route that is not the
  ## one observed before the switch, an out-of-band link that is down or
  ## has no address.
  if not h.ok:
    return @["the host's network cannot be read: " & h.why]
  for k in guard.keep:
    var held = false
    for a in addressesOf(h, k.iface):
      if inPrefix(a.ip, k.prefix): held = true
    if not held:
      result.add("keep: " & k.iface & " holds no address in " & k.prefix)
  let now = defaultRoutes(h)
  when not mutated("guard-ignores-default-route"):
    if now != defaultRoutesBefore:
      result.add("default route: " & (if now.len == 0: "none" else:
        now.join(", ")) & ", before the switch " &
        (if defaultRoutesBefore.len == 0: "none" else:
           defaultRoutesBefore.join(", ")))
  for l in guard.outOfBand:
    let i = h.linkNamed(l)
    if i < 0:
      result.add("outOfBand: " & l & " is gone")
    elif not h.links[i].up:
      result.add("outOfBand: " & l & " is down")
    elif addressesOf(h, l).len == 0:
      result.add("outOfBand: " & l & " has no address")

# ---------------------------------------------------------------------------
# A new SSH session (spec §4.5 step 3; threat model T55).
# ---------------------------------------------------------------------------

const SshSessionDirs = ["/usr/lib/ssh", "/usr/lib/openssh",
                        "/usr/libexec/openssh", "/usr/libexec"]
  ## Where OpenSSH (9.8 and later) installs ``sshd-session`` and
  ## ``sshd-auth``, the per-connection programs that log the accepted
  ## authentication: Arch's ``/usr/lib/ssh``, Debian's
  ## ``/usr/lib/openssh``, Fedora's ``/usr/libexec/openssh``.

type SshIdentity* = object
  unit*: string          ## the host's ssh unit (``sshd.service`` or
                         ## ``ssh.service``)
  exes*: seq[string]     ## the binaries whose journal entries count

proc unitExecPath(unit: string): string =
  try:
    let r = runSystemctl(["show", "-p", "ExecStart", "--value", "--", unit])
    let i = r.output.find("path=")
    if i >= 0:
      return r.output[i + 5 .. ^1].split(' ')[0].strip(chars = {';', ' '})
  except CatchableError:
    discard
  ""

proc hostSshIdentity*(): SshIdentity =
  ## The host's ssh unit (the loaded one of ``sshd.service`` and
  ## ``ssh.service``) and the binaries that may write its "Accepted" line:
  ## its ``ExecStart=`` program and the ``sshd-session`` / ``sshd-auth``
  ## beside OpenSSH's other helpers, each a root-owned regular file.
  for u in ["sshd.service", "ssh.service"]:
    try:
      let r = runSystemctl(["show", "-p", "LoadState", "--value", "--", u])
      if r.output.strip() == "loaded":
        result.unit = u
        break
    except CatchableError:
      discard
  if result.unit.len == 0: return
  let main = unitExecPath(result.unit)
  var cands = @[main]
  for d in SshSessionDirs:
    cands.add(d / "sshd-session")
    cands.add(d / "sshd-auth")
  for c in cands:
    if c.len == 0: continue
    var st: Stat
    if lstat(c.cstring, st) == 0 and S_ISREG(st.st_mode) and st.st_uid == 0:
      result.exes.add(c)

proc normalisedIp(ip: string): string =
  ## The canonical text of ``ip`` with any ``%scope`` dropped and an
  ## IPv4-mapped IPv6 address written as its IPv4 address, so that one
  ## address compares equal however sshd, logind or ``ip`` wrote it. ""
  ## when it is not an address.
  var t = ip.strip()
  let pct = t.find('%')
  if pct >= 0: t = t[0 ..< pct]
  try:
    let a = parseIpAddress(t)
    if a.family == IpAddressFamily.IPv6:
      # ::ffff:a.b.c.d (RFC 4291 §2.5.5.2), read from its bytes: Nim
      # renders it in hex (``::ffff:a00:20f``).
      var mapped = a.address_v6[10] == 0xff and a.address_v6[11] == 0xff
      for i in 0 .. 9:
        if a.address_v6[i] != 0: mapped = false
      if mapped:
        return $a.address_v6[12] & "." & $a.address_v6[13] & "." &
               $a.address_v6[14] & "." & $a.address_v6[15]
    $a
  except CatchableError:
    ""

proc isOwnAddress*(ip: string; own: openArray[string]): bool =
  ## Is ``ip`` one of ``own`` -- the addresses the host's own interfaces
  ## hold? A session from one of them is the host logging in to itself,
  ## which proves nothing about the network (spec §4.5 step 3, amended
  ## 2026-11-22; threat model T55).
  let n = normalisedIp(ip)
  if n.len == 0: return false
  for o in own:
    if normalisedIp(o) == n: return true
  false

proc isLoopback*(ip: string): bool =
  ## 127.0.0.0/8, ``::1``, or an IPv4-mapped loopback address.
  let n = normalisedIp(ip)
  n == "::1" or (n.startsWith("127.") and '.' in n)

proc acceptedFrom*(message: string): tuple[keyAuth: bool; ip: string] =
  ## ``Accepted publickey for <user> from <ip> port <n> ...`` -> (true, ip).
  ## Only a public-key authentication counts (spec §4.5: a new
  ## key-authenticated session).
  if not message.startsWith("Accepted publickey for "): return
  let i = message.find(" from ")
  if i < 0: return
  let rest = message[i + 6 .. ^1].splitWhitespace()
  if rest.len == 0: return
  (true, rest[0])

proc sshEvidenceIn*(journalJson: string; id: SshIdentity;
                    sinceUs: int64; ownAddresses: openArray[string]): string =
  ## The first journal entry (``journalctl -o json``, one object per line)
  ## that is a key-authenticated SSH login from a non-loopback address the
  ## host does not hold itself (``ownAddresses``), after ``sinceUs``
  ## (CLOCK_REALTIME µs), written by the host's ssh unit and one of its
  ## binaries -- judged by the journal's trusted fields only. "" when there
  ## is none. ``sinceUs`` 0 means the switch has not finished its network
  ## writes, and nothing counts yet.
  if sinceUs <= 0: return ""
  for line in journalJson.splitLines():
    if line.strip().len == 0: continue
    var j: JsonNode
    try: j = parseJson(line)
    except CatchableError: continue
    var ts: int64 = 0
    try: ts = parseBiggestInt(j{"__REALTIME_TIMESTAMP"}.getStr())
    except ValueError: continue
    if ts <= sinceUs: continue
    let unit = j{"_SYSTEMD_UNIT"}.getStr()
    let exe = j{"_EXE"}.getStr()
    let stem = id.unit[0 ..< max(0, id.unit.len - ".service".len)]
    when not mutated("guard-trusts-syslog-identifier"):
      if unit != id.unit and not (unit.startsWith(stem & "@") and
                                  unit.endsWith(".service")):
        continue
      if exe notin id.exes: continue
    else:
      if j{"SYSLOG_IDENTIFIER"}.getStr() notin ["sshd", "sshd-session"]:
        continue
    let msg = j{"MESSAGE"}.getStr()
    let a = acceptedFrom(msg)
    if not a.keyAuth or isLoopback(a.ip): continue
    when not mutated("guard-accepts-own-address"):
      if isOwnAddress(a.ip, ownAddresses): continue
    return msg & " (" & unit & ", " & exe & ")"
  ""

proc newSshSessionSince*(sinceUs: int64;
                         ownAddresses: openArray[string]): string =
  ## A key-authenticated SSH login from a non-loopback address the host
  ## does not hold, after ``sinceUs``, from the host's journal ("" when
  ## none, or when ``sinceUs`` is 0).
  if sinceUs <= 0: return ""
  let id = hostSshIdentity()
  if id.unit.len == 0 or id.exes.len == 0: return ""
  let jc = resolveHostTool(["/usr/bin/journalctl", "/bin/journalctl"])
  if jc.len == 0: return ""
  try:
    let since = "@" & $(sinceUs div 1_000_000)
    let r = runHostTool([jc, "-o", "json", "--no-pager", "--since", since,
                         "_SYSTEMD_UNIT=" & id.unit], mergeStderr = false,
                        timeoutSec = 30)
    sshEvidenceIn(r.output, id, sinceUs, ownAddresses)
  except CatchableError:
    ""

# ---------------------------------------------------------------------------
# `repro system addon confirm` (spec §4.5 step 3).
# ---------------------------------------------------------------------------

type LogindSession* = object
  id*: string
  service*: string
  remote*: bool
  remoteHost*: string
  createdMonoUs*: int64

proc sessionOfPid*(pid: int): string =
  ## The logind session whose scope holds ``pid`` ("" when none).
  try:
    for line in readFile("/proc/" & $pid & "/cgroup").splitLines():
      for part in line.split('/'):
        if part.startsWith("session-") and part.endsWith(".scope"):
          return part["session-".len ..< part.len - ".scope".len]
  except CatchableError:
    discard
  ""

proc readLogindSession*(id: string): LogindSession =
  result.id = id
  let lc = resolveHostTool(["/usr/bin/loginctl", "/bin/loginctl"])
  if lc.len == 0 or id.len == 0: return
  try:
    let r = runHostTool([lc, "show-session", id, "-p", "Service", "-p",
      "Remote", "-p", "RemoteHost", "-p", "TimestampMonotonic"],
      mergeStderr = false, timeoutSec = 15)
    for line in r.output.splitLines():
      let eq = line.find('=')
      if eq <= 0: continue
      let v = line[eq + 1 .. ^1]
      case line[0 ..< eq]
      of "Service": result.service = v
      of "Remote": result.remote = v == "yes"
      of "RemoteHost": result.remoteHost = v
      of "TimestampMonotonic":
        try: result.createdMonoUs = parseBiggestInt(v)
        except ValueError: discard
      else: discard
  except CatchableError:
    discard

proc confirmProblem*(s: LogindSession; writtenMonoUs: int64;
                     ownAddresses: openArray[string]): string =
  ## Why ``s`` cannot confirm the switch whose last network write was done
  ## at ``writtenMonoUs`` (CLOCK_MONOTONIC µs; 0 while the switch is still
  ## writing), or "": it must be an SSH session from a non-loopback
  ## address the host does not hold itself, created after that write
  ## (spec §4.5 step 3, amended 2026-11-22; threat model T55).
  if writtenMonoUs <= 0:
    return "the switch has not yet written its network objects; a " &
      "confirmation counts only from a session created after it has"
  if s.id.len == 0: return "not run from a logind session"
  if s.service notin ["sshd", "ssh"]:
    return "session " & s.id & " is not an SSH session (service " &
      s.service & ")"
  if not s.remote or s.remoteHost.len == 0 or isLoopback(s.remoteHost):
    return "session " & s.id & " is not from a non-loopback address (" &
      s.remoteHost & ")"
  when not mutated("guard-accepts-own-address"):
    if isOwnAddress(s.remoteHost, ownAddresses):
      return "session " & s.id & " is from " & s.remoteHost & ", an " &
        "address of this host: it proves nothing about the network"
  when not mutated("guard-confirm-any-session"):
    if s.createdMonoUs <= writtenMonoUs:
      return "session " & s.id & " was created before the switch wrote " &
        "its network objects"
  ""

proc confirmRecordPath*(stateDir: string): string =
  stateDir / "addon" / "guard-confirm"

proc writeConfirm*(stateDir, attempt, session: string) =
  writeFileNoFollow(confirmRecordPath(stateDir), attempt & "\t" & session &
    "\n", 0o600)

proc confirmedBy*(stateDir, attempt: string; writtenMonoUs: int64;
                  ownAddresses: openArray[string]): string =
  ## The session that confirmed ``attempt``, re-checked now ("" when none
  ## did or it no longer qualifies).
  try:
    let f = readFile(confirmRecordPath(stateDir)).strip().split('\t')
    if f.len != 2 or f[0] != attempt: return ""
    let s = readLogindSession(f[1])
    if confirmProblem(s, writtenMonoUs, ownAddresses).len == 0:
      return "repro system addon confirm from SSH session " & s.id &
        " (" & s.remoteHost & ")"
  except CatchableError:
    discard
  ""

proc clearConfirm*(stateDir: string) =
  try: discard removeLeafNoFollow(confirmRecordPath(stateDir))
  except CatchableError: discard
