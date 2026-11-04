## Gate ``e2e_addon_unit_syscall_filters_cover_their_traces`` (milestone A9,
## the CONF-3 half of the confinement floor; spec §10.1; threat model G10).
##
## CONF-3: a unit's syscall filter is derived from its observed trace, not
## guessed, and the profiling configuration is kept so it can be re-run.
## This gate is that configuration, in two modes.
##
## **Check (the default).** On a bootstrapped add-on host each of the
## add-on's own service units -- the deploy agent's fetch and apply units,
## the re-assert and the secrets unit -- keeps its committed
## ``SystemCallFilter=``, and a drop-in turns the filter's action from
## failing the call (``SystemCallErrorNumber=EPERM``, what the units ship
## with) to killing the process (``SystemCallErrorNumber=`` reset;
## systemd.exec(5)). The kernel writes an audit record for every kill
## (``type=1326 ... sig=31``). The gate drives the units through their work
## -- deploy-agent ticks that apply and change files, a unit, a system
## account, tmpfiles and sysctl fragments, a re-assertion and a boot
## secrets run -- and requires every tick and run to succeed and no kill
## record to appear: the trace of every unit is inside its committed
## filter. The kill makes a call outside the filter both fail the work and
## leave a record naming it, where EPERM could be swallowed by a caller.
##
## **Derive** (``REPRO_ADDON_SYSCALL_BASELINE=1``). The drop-in lifts the
## filter instead and logs, through ``SystemCallLog=``, every call outside
## the deployment policy's recipe (``@system-service``, then
## ``~@privileged ~@resources ~@obsolete``). What it logs, attributed to the
## unit whose run it fell in, is what each unit's filter had to add back:
## how ``PrivilegedSyscallFilter`` and ``FetchSyscallFilter`` in
## ``generation0.nim`` were derived. The record lists it and the gate does
## not fail on it. The log also sees the calls systemd's own executor makes
## after installing the logging filter (``capset`` when it applies the
## capability set), which an enforced filter always allows.
##
## **Attribution** (A9 review round 2, issue
## 2026-11-03-syscall-trace-baseline-attributes-seccomp-records-by-time-window):
## a record belongs to a unit when it falls inside the lifetime of exactly
## one process -- identified by (pid, start time), so a reused pid is
## another process -- that was in the unit's control group
## (``repro_test_support/syscall_attribution``). A static sampler in the
## guest (``fixtures/cgroup_sampler/a9_cgroup_sampler.c``) reads each
## unit's ``cgroup.procs`` and each process's ``/proc/<pid>/stat`` start
## time every millisecond for the whole run; a record's time is the
## kernel's own audit time stamp, and its ``arch=`` must be the base's
## native one. A record that falls in no sampled lifetime of its pid, or in
## more than one, is unattributed: never folded into a unit's set, and a
## failure when it lies inside an add-on unit's run (where an unseen
## process of the unit could have made it). While the units work, a
## foreign unit logs its own calls (``a9-foreign.service``); none of its
## records may be attributed to an add-on unit. Falsifying mutation
## (``REPRO_ADDON_MUTATION=trace-attributes-by-window``): attribution by
## journal time, as before; the foreign unit's records land in the add-on
## units' windows: red.
##
## The control is positive (A9 review round 3, finding 10): each add-on
## unit must have had a sampled process, and every record of the foreign
## unit must be attributed *to the foreign unit*. A record merely not
## attributed to an add-on unit proves nothing: with a sampler that saw
## no unit, every record is unattributed, the foreign unit's included,
## and a check-mode run (which judges kills only) passed with no evidence
## at all. Falsifying mutation (``REPRO_ADDON_MUTATION=trace-sampler-blind``):
## the sampler watches only a unit that never runs: red.
##
## The work: deploy-agent ticks over a profile as wide as the add-on's
## classes -- a secret an operator put, materialised for a unit's
## credential; an apt closure realised from the ``.deb`` cache; a package
## conffile diverted; a system account, tmpfiles and sysctl fragments --
## seven generations (past the retention policy's five), a generation that
## fails its confirm and is reverted by the apply unit, a switch killed
## after step 4 (seam build) and recovered by the re-assert unit, and the
## boot secrets and re-assert units run again.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=privileged-filter-without-mount-chown``):
## the root units' filter without the traced ``@mount`` and ``@chown``;
## the apply unit is killed at its first store write or ``fchown``: red.
##
## Vacuity guards: a transient unit that logs ``uname`` produces a record
## naming ``uname``'s number (63 on x86_64, 122 on ARM EABI), and one whose filter denies
## ``uname`` is killed with a record naming it, so both paths reach the
## kernel log on the base. After the work the drop-ins are removed and one
## more tick runs under the units as shipped and must apply.
##
## Runs on every base architecture: the kernel's record carries the syscall
## number, and the names come from the ``<sys/syscall.h>`` of the static
## toolchain for the guest's architecture.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None: the real units under the guest's systemd and kernel.

import std/[algorithm, json, os, osproc, sequtils, sets, strutils, tables, unittest]

import repro_test_support/reasoned_skip
import repro_test_support/syscall_attribution

import repro_dsl_stdlib/packages/apt_closure
import repro_addon/generation0

import ./addon_testbed
import ./agent_e2e_support
import ./deb_fixture_support

proc fixtureDeb(work, name, debArch: string):
    tuple[path: string; lock: AptClosureLock] =
  ## A one-file .deb and its closure lock (the closure gates' fixture) for
  ## the guest's architecture.
  result.path = work / (name & ".deb")
  writeDeb(result.path, @[dir("./"), dir("./usr/"), dir("./usr/share/"),
    dir("./usr/share/" & name & "/"),
    ("./usr/share/" & name & "/ok.txt", '0', 0o644, name & "\n", "")])
  result.lock = fixtureLock(name, result.path, debArch)

const
  Gate = "e2e_addon_unit_syscall_filters_cover_their_traces"
  Units = ["repro-agent-fetch.service", "repro-agent-apply.service",
           "repro-addon-reassert.service", "repro-addon-secrets.service"]
  BaselineFilter = @["@system-service", "~@privileged @resources @obsolete"]
    ## The deployment policy's recipe (CONF-1's SystemCallFilter row).
  DropInName = "90-a9-syscall-profile.conf"

proc baselineMode(): bool = getEnv("REPRO_ADDON_SYSCALL_BASELINE") == "1"

proc syscallNames(debArch: string): Table[int, string] =
  ## The guest architecture's syscall numbers to names, from the
  ## ``<sys/syscall.h>`` of the static toolchain the add-on is built with for
  ## it (``addon_testbed.staticCc``): x86_64's for amd64, ARM EABI's for
  ## armhf. ARM's private calls (``__ARM_NR_set_tls`` and its kin, spelled
  ## in hexadecimal) are named too: the kernel logs them by number.
  let (o, c) = execCmdEx("echo '#include <sys/syscall.h>' | " &
    quoteShell(staticCc(debArch)) & " -E -dM -")
  doAssert c == 0, "cannot read <sys/syscall.h>: " & o
  for l in o.splitLines():
    let f = l.splitWhitespace()
    if f.len != 3 or f[0] != "#define": continue
    for prefix in ["__NR_", "__ARM_NR_"]:
      if f[1].startsWith(prefix):
        try:
          let n = if f[2].startsWith("0x"): parseHexInt(f[2])
                  else: parseInt(f[2])
          if n notin result: result[n] = f[1][prefix.len .. ^1]
        except ValueError: discard

proc numberOf(names: Table[int, string]; name: string): int =
  for n, s in names:
    if s == name: return n
  raise newException(TestBedError, "no syscall number for " & name)

proc withoutEscapes(s: string): string =
  ## ``s`` without ANSI control sequences (``ESC [ ... <letter>``).
  var i = 0
  while i < s.len:
    if s[i] == '\e' and i + 1 < s.len and s[i + 1] == '[':
      var j = i + 2
      while j < s.len and s[j] notin {'A'..'Z', 'a'..'z'}: inc j
      i = j + 1
    else:
      result.add(s[i])
      inc i

proc parseGroups(text: string): Table[string, seq[string]] =
  ## ``systemd-analyze syscall-filter`` output: a ``@group`` line, then its
  ## members (names or nested groups), indented; ``#`` comments. systemd 255
  ## writes an ANSI reset before each nested group name even with no
  ## terminal (A9 review round 2: the derivation then read ``\e[0m@basic-io``
  ## as a call name and logged what the recipe allows); escapes are
  ## removed, and the command runs with ``SYSTEMD_COLORS=0``.
  var cur = ""
  for raw0 in text.splitLines():
    let raw = withoutEscapes(raw0)
    let l = raw.strip()
    if l.len == 0 or l.startsWith("#"): continue
    if not raw.startsWith(" ") and l.startsWith("@"):
      cur = l
      result[cur] = @[]
    elif cur.len > 0:
      result[cur].add(l)

proc expand(groups: Table[string, seq[string]]; item: string;
            acc: var HashSet[string]) =
  if item.startsWith("@"):
    for m in groups.getOrDefault(item): expand(groups, m, acc)
  else: acc.incl(item)

proc allowedBy(groups: Table[string, seq[string]];
               lines: seq[string]): HashSet[string] =
  ## The set a sequence of ``SystemCallFilter=`` values allows: the first
  ## is the allow-list, a ``~`` line removes, a later plain line adds
  ## (systemd.exec(5)). Only allow-list filters are handled: every unit
  ## here starts with one.
  for i, v in lines:
    let deny = v.startsWith("~")
    var s: HashSet[string]
    for it in v.strip(chars = {'~'}).splitWhitespace():
      expand(groups, it, s)
    if deny:
      doAssert i > 0, "a filter starting with a deny-list: " & v
      result.excl(s)
    else: result.incl(s)

proc unitFilter(g: Guest; unit: string): seq[string] =
  for l in g.exec("systemctl cat " & unit).stdout.splitLines():
    if l.startsWith("SystemCallFilter="):
      result.add(l["SystemCallFilter=".len .. ^1].strip())

proc profileDropIn(g: Guest; unit: string; logged: seq[string]) =
  ## Derive mode: no filter, every call in ``logged`` logged.
  let dir = "/run/systemd/system/" & unit & ".d"
  discard g.run("mkdir -p " & dir & " && cat > " & dir & "/" & DropInName &
    " <<'A9EOF'\n[Service]\nSystemCallFilter=\nSystemCallLog=" &
    logged.join(" ") & "\nA9EOF\n")

proc killDropIn(g: Guest; unit: string) =
  ## Check mode: the committed filter, a call outside it kills (and so is
  ## always logged by the kernel).
  let dir = "/run/systemd/system/" & unit & ".d"
  discard g.run("mkdir -p " & dir & " && printf '[Service]\\n" &
    "SystemCallErrorNumber=\\n' > " & dir & "/" & DropInName)

proc now(g: Guest): float = parseFloat(g.run("date +%s.%N").strip())

type AuditRecord = tuple[at: float; nr: int; comm: string; sig: int;
                         pid: int; arch: string]

proc auditRecords(g: Guest; since: float): seq[AuditRecord] =
  ## Every seccomp audit record since ``since``. Without auditd the kernel
  ## prints them (``audit: type=1326 ...``, the kernel transport); where
  ## journald reads the audit socket they arrive as ``SECCOMP ...`` on the
  ## audit transport. Both carry ``syscall=`` and ``comm=``; the journal's
  ## own timestamp places them in time.
  let text = g.exec("journalctl -q -o short-unix --no-pager --since @" &
    $int(since) & " | grep -E 'type=1326|SECCOMP'").stdout
  for l in text.splitLines():
    let f = l.splitWhitespace()
    if f.len < 2 or "syscall=" notin l: continue
    var rec: AuditRecord
    try: rec.at = parseFloat(f[0])
    except ValueError: continue
    # The kernel's own stamp, not the journal's receive time.
    let k = auditTime(l)
    if k >= 0: rec.at = k
    for tok in f:
      if tok.startsWith("syscall="):
        try: rec.nr = parseInt(tok["syscall=".len .. ^1])
        except ValueError: rec.nr = -1
      elif tok.startsWith("comm="):
        rec.comm = tok["comm=".len .. ^1].strip(chars = {'"'})
      elif tok.startsWith("sig="):
        try: rec.sig = parseInt(tok["sig=".len .. ^1])
        except ValueError: rec.sig = -1
      elif tok.startsWith("pid="):
        try: rec.pid = parseInt(tok["pid=".len .. ^1])
        except ValueError: rec.pid = -1
      elif tok.startsWith("arch="):
        rec.arch = tok["arch=".len .. ^1].toLowerAscii()
    result.add(rec)

const
  ForeignUnit = "a9-foreign.service"

proc nativeAuditArch(debArch: string): string =
  ## The ``arch=`` of a native call on the base (linux/audit.h
  ## ``AUDIT_ARCH_*``).
  case debArch
  of "amd64": "c000003e"
  of "arm64": "c00000b7"
  of "armhf": "40000028"
  else: raise newException(TestBedError, "no audit arch for " & debArch)

const
  SamplerPeriodUs = 1000
  SamplerOut = "/run/a9-lifetimes"

proc startSampler(g: Guest; units: openArray[string]) =
  ## The process-lifetime sampler (header), built for the guest's
  ## architecture with the static toolchain the add-on is built with.
  let src = reproRoot() / "tests" / "e2e" / "addon" / "fixtures" /
            "cgroup_sampler" / "a9_cgroup_sampler.c"
  let bin = g.runDir / "a9-cgroup-sampler"
  let (o, c) = execCmdEx(quoteShellCommand([staticCc(g.base.debArch),
    "-static", "-O2", "-o", bin, src]))
  doAssert c == 0, "compiling the sampler failed: " & o
  g.copyTo(bin, "/root/a9-cgroup-sampler")
  discard g.run("chmod 0755 /root/a9-cgroup-sampler; rm -f " & SamplerOut &
    "; nohup /root/a9-cgroup-sampler " & SamplerOut & " " & $SamplerPeriodUs &
    " " & units.join(" ") & " >/dev/null 2>&1 & echo $! > /run/a9-sampler.pid")

proc stopSampler(g: Guest): seq[ProcLifetime] =
  ## What it saw (it writes on SIGTERM).
  discard g.run("kill -TERM $(cat /run/a9-sampler.pid); for i in $(seq 1 " &
    "100); do [ -s " & SamplerOut & " ] && break; sleep 0.2; done; true")
  parseLifetimes(g.run("cat " & SamplerOut & " 2>/dev/null"))

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let names = syscallNames(g.base.debArch)
  let unameNr = names.numberOf("uname")
  record["unameSyscall"] = %unameNr
  let groups = parseGroups(g.exec("SYSTEMD_COLORS=0 systemd-analyze syscall-filter " &
                                  "--no-pager").stdout)
  var known: HashSet[string]
  expand(groups, "@known", known)
  step("the base's systemd lists its syscall groups",
       known.len > 200 and "@system-service" in groups, $known.len)
  # The groups are read right (the derivation rests on it): the recipe
  # allows the basic calls every program makes, and denies @privileged.
  let recipe = allowedBy(groups, BaselineFilter)
  step("the recipe's groups expand (read, close, openat, mmap allowed; " &
       "mount denied)", "read" in recipe and "close" in recipe and
       "openat" in recipe and "mmap" in recipe and "mount" notin recipe,
       $recipe.len)
  # Vacuity guard: the log path reaches the kernel log on this base.
  let t0 = g.now()
  discard g.exec("systemd-run --wait --quiet -p SystemCallLog=uname " &
                 "/bin/uname")
  var sawUname = false
  for r in g.auditRecords(t0 - 1):
    if r.nr == unameNr: sawUname = true
  step("vacuity guard: a logged uname reaches the kernel log", sawUname, "")
  let t1 = g.now()
  discard g.exec("systemd-run --wait --quiet -p SystemCallFilter=~uname " &
                 "/bin/uname")
  var sawKill = false
  for r in g.auditRecords(t1 - 1):
    if r.nr == unameNr and r.sig == 31: sawKill = true
  step("vacuity guard: a denied uname is killed and logged", sawKill, "")

  var filters = newJObject()
  for u in Units:
    let committed = g.unitFilter(u)
    filters[u] = %committed
    let allowed = allowedBy(groups, if baselineMode(): BaselineFilter
                                    else: committed)
    step(u & " has a committed allow-list filter", committed.len > 0 and
         not committed[0].startsWith("~"), $committed)
    if baselineMode():
      var logged: seq[string]
      for s in known:
        if s notin allowed: logged.add(s)
      logged.sort()
      g.profileDropIn(u, logged)
    else:
      g.killDropIn(u)
  record["committedFilters"] = filters
  record["mode"] = %(if baselineMode(): "baseline" else: "committed")
  discard g.run("systemctl daemon-reload")

  # The work. Each window is attributed to the unit that ran in it.
  var windows: seq[tuple[unit: string; a, b: float]]
  let prod = producer   # a ref: the closures below may capture it
  proc runTick(seqNo: uint64; text: string): TickResult =
    discard prod.publish(PublishSpec(sequence: seqNo, profileText: text))
    let a = g.now()
    result = g.tickUnits()
    let fetchExit = parseFloat(g.run("systemctl show -p " &
      "ExecMainExitTimestamp --timestamp=unix --value " &
      "repro-agent-fetch.service").strip().strip(chars = {'@'}))
    windows.add((unit: "repro-agent-fetch.service", a: a, b: fetchExit + 0.5))
    windows.add((unit: "repro-agent-apply.service", a: fetchExit + 0.5,
                 b: g.now()))
  proc tick(seqNo: uint64; text: string) =
    let t = runTick(seqNo, text)
    step("tick " & $seqNo & " applies", t.outcome == "aoApplied",
         $t & "\n" & t.fetchLog & t.applyLog)
  proc restartUnit(u: string) =
    let a = g.now()
    let r = g.exec("systemctl restart " & u)
    windows.add((unit: u, a: a, b: g.now()))
    step(u & " runs", r.exitCode == 0, r.stdout & r.stderr)

  # What the apply unit has to do, as wide as the add-on's classes go:
  # an operator-provided secret it materialises for a unit's credential;
  # an apt closure it realises from the .deb cache (a fixture .deb, the
  # realiser's own tar reader); a package conffile it diverts (dpkg-divert,
  # an equivs package); a system account, tmpfiles and sysctl fragments.
  let put = g.exec("printf 'a9-trace-secret' > /root/a9s && chmod 0400 " &
    "/root/a9s && " & repro & " system addon secret put --service a9-trace " &
    "--name tok < /root/a9s; rc=$?; rm -f /root/a9s; exit $rc")
  step("an operator puts the secret", put.exitCode == 0, put.stdout & put.stderr)
  let deb = fixtureDeb(g.runDir, "a9-trace-closure", g.base.debArch)
  discard g.run("mkdir -p " & AddOnAptDebCacheDir & " && chmod 0700 " &
                AddOnAptDebCacheDir)
  g.copyTo(deb.path, AddOnAptDebCacheDir & "/" & deb.lock.debs[0].sha256 &
           ".deb")
  g.installEquivs()
  let conf = g.buildEquivsPackage("repro-a9-trace-conf", "1.0",
    @[(name: "pkg.conf", content: "pkg\n", destDir: "/etc/a9-trace-pkg")])
  discard g.run("export DEBIAN_FRONTEND=noninteractive; dpkg -i " & conf &
                " >/dev/null < /dev/null")
  let lockText = renderAptClosureLock(deb.lock)
  let common = "addOn {\n  managedEtcPrefixes = [\"/etc/a9-trace-pkg/\"]\n" &
    "  confirmTimeout = 15\n}\n" &
    "secrets.secretFile {\n  service = \"a9-trace\"\n  name = \"tok\"\n}\n" &
    "systemd.systemUnit {\n" & FixtureFloorWaiver &
      "  name = \"a9-trace.service\"\n  content = \"[Service]\n" &
      "ExecStart=/bin/sh -c 'cat $$CREDENTIALS_DIRECTORY/tok >/dev/null; " &
      "exec sleep infinity'\n\n[Install]\nWantedBy=multi-user.target\n\"\n" &
      "  credentials = [\"tok\"]\n}\n" &
    "systemd.systemUnit {\n" & FixtureFloorWaiver &
      "  name = \"a9-closure.service\"\n  content = \"[Service]\n" &
      "Type=oneshot\nExecStart=/usr/bin/true\n\"\n  enabled = false\n" &
      "  aptClosureLock = \"" & lockText & "\"\n}\n" &
    "fs.systemFile {\n  path = \"/etc/a9-trace-pkg/pkg.conf\"\n  content = " &
      "\"ours\n\"\n  collision = \"divert\"\n}\n" &
    "linux.sysusersEntry {\n  name = \"a9trace\"\n  kind = \"user\"\n" &
      "  description = \"A9 trace\"\n}\n" &
    "linux.tmpfilesRule {\n  name = \"repro-a9-trace.conf\"\n  content = " &
      "\"d /var/lib/a9-trace 0750 a9trace a9trace -\n\"\n}\n" &
    "linux.sysctl {\n  key = \"vm.swappiness\"\n  value = \"33\"\n}\n"
  proc gen(n: int): string =
    common & canonicalFile("/etc/repro/a9-trace", "gen " & $n & "\n")
  # Attribution (header): which process was in which unit, sampled from
  # here to the end of the work; and a foreign unit that logs its own
  # calls the whole time.
  if mutation() == "trace-sampler-blind":
    g.startSampler(@["a9-never-runs.service"])
  else:
    g.startSampler(@Units & @[ForeignUnit])
  discard g.run("systemd-run --quiet --unit=" & ForeignUnit &
    " -p SystemCallLog=clock_nanosleep -p SystemCallLog=nanosleep " &
    "/bin/sh -c 'while :; do sleep 0.05; done'")
  tick(1, gen(1))
  # Generations past the retention policy's five: the apply releases the
  # store roots of those it drops (§5.2).
  for n in 2 .. 7: tick(uint64(n), gen(n))
  # A confirm failure: a unit whose health check cannot pass; the apply
  # unit reverts to the previous generation and the agent quarantines it.
  let failing = gen(8) & "systemd.systemUnit {\n" & FixtureFloorWaiver &
    "  name = \"a9-fails.service\"\n  content = \"[Service]\n" &
    "ExecStart=/bin/sleep infinity\n\n[Install]\nWantedBy=multi-user.target" &
    "\n\"\n  healthCheck = \"tcp:127.0.0.1:18997\"\n}\n"
  let tf = runTick(8, failing)
  step("tick 8 fails its confirm and is reverted", tf.outcome == "aoRolledBack",
       $tf & "\n" & tf.applyLog)
  # A recovery: the apply unit is killed half-way through a switch (seam
  # build, after step 4), and the re-assert unit finishes or reverts it.
  g.armApplySeam("step-4")
  discard prod.publish(PublishSpec(sequence: 9, profileText: gen(9)))
  let a9 = g.now()
  g.startFetchNoWait()
  let paused = g.waitSeam(ApplySeamDir, "step-4")
  step("the switch paused after step 4", paused, "")
  discard g.exec("systemctl kill -s KILL repro-agent-apply.service; " &
    "for i in $(seq 1 60); do s=$(systemctl show -p ActiveState --value " &
    "repro-agent-apply.service); [ \"$s\" != active ] && " &
    "[ \"$s\" != activating ] && [ \"$s\" != deactivating ] && break; " &
    "sleep 1; done; rm -f " & ApplySeamDir & "/test-paused-at " &
    ApplySeamDir & "/test-resume")
  windows.add((unit: "repro-agent-apply.service", a: a9, b: g.now()))
  step("the switch left its pending marker",
       g.exec("test -e /var/lib/repro/system/addon/pending").exitCode == 0, "")
  restartUnit("repro-addon-reassert.service")
  step("the recovery resolved the switch",
       g.exec("test -e /var/lib/repro/system/addon/pending").exitCode != 0,
       g.exec("cat " & ReassertReportPath).stdout)
  restartUnit("repro-addon-secrets.service")
  restartUnit("repro-addon-reassert.service")
  tick(10, gen(10))

  discard g.run("systemctl stop " & ForeignUnit & " 2>/dev/null; true")
  let lifetimes = g.stopSampler()
  let native = nativeAuditArch(g.base.debArch)
  proc attributeRec(r: AuditRecord): Attribution =
    ## The unit a record belongs to (header).
    if mutation() == "trace-attributes-by-window":
      # Falsifying build of the attribution: by journal time (round 1).
      for w in windows:
        if r.at >= w.a and r.at <= w.b:
          return Attribution(kind: akUnit, unit: w.unit)
      return Attribution(kind: akNone)
    if r.arch.len > 0 and r.arch != native:
      return Attribution(kind: akNone)
    attribute(lifetimes, r.pid, r.at, SamplerPeriodUs / 1_000_000)
  proc inUnitRun(at: float): bool =
    for w in windows:
      if at >= w.a and at <= w.b: return true
  var observed = initTable[string, HashSet[string]]()
  var unattributed: seq[string]
  var foreignAttributed: seq[string]
  var foreignSeen = 0
  var foreignNotOwn: seq[string]   # not positively the foreign unit's
  var unattributedInRun: seq[string]
  for r in g.auditRecords(t1 + 2):
    if r.nr == unameNr and r.comm == "uname": continue   # the vacuity guards
    let name = names.getOrDefault(r.nr, "#" & $r.nr)
    let a = attributeRec(r)
    let unit = if a.kind == akUnit and a.unit in Units: a.unit else: ""
    if r.comm == "sleep":
      # The foreign unit's records (a9-foreign.service runs `sleep`; no
      # add-on unit does): never an add-on unit's.
      inc foreignSeen
      if unit.len > 0: foreignAttributed.add(unit & ": " & name)
      if a.kind != akUnit or a.unit != ForeignUnit:
        foreignNotOwn.add(name & " (pid " & $r.pid & ", " & $a.kind & ")")
      continue
    # Check mode counts kills; derive mode counts every logged call.
    if not baselineMode() and r.sig == 0: continue
    if unit.len > 0:
      observed.mgetOrPut(unit, initHashSet[string]()).incl(name)
    elif a.kind == akUnit:
      discard   # another sampled unit's (the foreign one): not the add-on's
    else:
      let what = name & " (" & r.comm & ", pid " & $r.pid & ", arch " &
                 r.arch & ", " & $a.kind & ")"
      unattributed.add(what)
      if inUnitRun(r.at): unattributedInRun.add(what)
  var obs = newJObject()
  for u in Units:
    var s = toSeq(observed.getOrDefault(u))
    s.sort()
    obs[u] = %s
  record["outsideFilter"] = obs
  record["unattributed"] = %unattributed
  record["foreignRecords"] = %foreignSeen
  record["processesSampled"] = %lifetimes.len
  record["unattributedInUnitRuns"] = %unattributedInRun
  step("no record inside an add-on unit's run is left unattributed " &
       "(no lifetime, or several)", unattributedInRun.len == 0,
       unattributedInRun.join(", "))
  step("the foreign unit's calls were logged (the attribution has " &
       "something to refuse)", foreignSeen > 0, $foreignSeen)
  step("no record of the foreign unit is attributed to an add-on unit",
       foreignAttributed.len == 0, foreignAttributed.join(", "))
  step("every record of the foreign unit is attributed to the foreign " &
       "unit (the attribution positively sees it)",
       foreignNotOwn.len == 0, foreignNotOwn.join(", "))
  var sampledPer = initTable[string, int]()
  for l in lifetimes: sampledPer.mgetOrPut(l.unit, 0).inc
  for u in Units:
    step(u & " had sampled processes (its records can be attributed)",
         sampledPer.getOrDefault(u) > 0, $sampledPer.getOrDefault(u))
  if not baselineMode():
    for u in Units:
      step(u & " made no system call outside its filter (no kill)",
           observed.getOrDefault(u).len == 0, $obs[u])
    step("no kill fell outside the units' runs",
         unattributed.len == 0, unattributed.join(", "))

  # The units as shipped: the drop-ins go.
  for u in Units:
    discard g.run("rm -f /run/systemd/system/" & u & ".d/" & DropInName)
  discard g.run("systemctl daemon-reload")
  tick(11, gen(11))

suite Gate:
  test "the add-on's units stay inside their syscall filters":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0
