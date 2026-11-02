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
## capability set), which an enforced filter always allows; and it is
## attributed by journal time, so a record received late can land in the
## next unit's window. The check above has neither weakness.
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

proc parseGroups(text: string): Table[string, seq[string]] =
  ## ``systemd-analyze syscall-filter`` output: a ``@group`` line, then its
  ## members (names or nested groups), indented; ``#`` comments.
  var cur = ""
  for raw in text.splitLines():
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

proc auditRecords(g: Guest; since: float):
    seq[tuple[at: float; nr: int; comm: string; sig: int]] =
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
    var rec: tuple[at: float; nr: int; comm: string; sig: int]
    try: rec.at = parseFloat(f[0])
    except ValueError: continue
    for tok in f:
      if tok.startsWith("syscall="):
        try: rec.nr = parseInt(tok["syscall=".len .. ^1])
        except ValueError: rec.nr = -1
      elif tok.startsWith("comm="):
        rec.comm = tok["comm=".len .. ^1].strip(chars = {'"'})
      elif tok.startsWith("sig="):
        try: rec.sig = parseInt(tok["sig=".len .. ^1])
        except ValueError: rec.sig = -1
    result.add(rec)

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let names = syscallNames(g.base.debArch)
  let unameNr = names.numberOf("uname")
  record["unameSyscall"] = %unameNr
  let groups = parseGroups(g.exec("systemd-analyze syscall-filter " &
                                  "--no-pager").stdout)
  var known: HashSet[string]
  expand(groups, "@known", known)
  step("the base's systemd lists its syscall groups",
       known.len > 200 and "@system-service" in groups, $known.len)
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

  var observed = initTable[string, HashSet[string]]()
  var unattributed: seq[string]
  for r in g.auditRecords(t1 + 2):
    if r.nr == unameNr and r.comm == "uname": continue   # the vacuity guards
    # Check mode counts kills; derive mode counts every logged call.
    if not baselineMode() and r.sig == 0: continue
    let name = names.getOrDefault(r.nr, "#" & $r.nr)
    var hit = false
    for w in windows:
      if r.at >= w.a and r.at <= w.b:
        observed.mgetOrPut(w.unit, initHashSet[string]()).incl(name)
        hit = true
        break
    if not hit: unattributed.add(name & " (" & r.comm & ")")
  var obs = newJObject()
  for u in Units:
    var s = toSeq(observed.getOrDefault(u))
    s.sort()
    obs[u] = %s
  record["outsideFilter"] = obs
  record["unattributed"] = %unattributed
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
