## Gate ``e2e_addon_unit_syscall_filters_cover_their_traces`` (milestone A9,
## the CONF-3 half of the confinement floor; spec §10.1; threat model G10).
##
## CONF-3: a unit's syscall filter is derived from its observed trace, not
## guessed, and the profiling configuration is kept so it can be re-run.
## This gate is that configuration. On a bootstrapped add-on host it gives
## each of the add-on's own service units -- the deploy agent's fetch and
## apply units, the re-assert and the secrets unit -- a drop-in that lifts
## its ``SystemCallFilter=`` and logs, through ``SystemCallLog=``, every
## system call the filter would NOT allow (systemd.exec(5); the kernel
## writes one ``type=1326`` audit record per logged call). It then drives
## the units through their work -- deploy-agent ticks that apply and change
## files, a unit, a system account, tmpfiles and sysctl fragments, a
## re-assertion and a boot secrets run -- attributes every record to the
## unit whose run it fell in, and requires none: the trace of every unit is
## inside its committed filter.
##
## ``REPRO_ADDON_SYSCALL_BASELINE=1`` profiles against the deployment
## policy's recipe instead (``@system-service``, then ``~@privileged
## ~@resources ~@obsolete``): the calls it logs are what each unit's filter
## had to add back, which is how ``PrivilegedSyscallFilter`` and
## ``FetchSyscallFilter`` in ``generation0.nim`` were derived. The gate then
## records the set and does not fail on it.
##
## Vacuity guard: a transient unit that logs ``uname`` produces a record
## naming syscall 63 (``uname`` on x86_64), so the log path works on the
## base. After profiling the drop-ins are removed and one more tick runs
## under the enforced filters and must apply.
##
## Runs on amd64 bases (the record carries the syscall number; the names
## come from this host's x86_64 ``<sys/syscall.h>``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None: the real units under the guest's systemd and kernel.

import std/[algorithm, json, os, osproc, sequtils, sets, strutils, tables, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_unit_syscall_filters_cover_their_traces"
  Units = ["repro-agent-fetch.service", "repro-agent-apply.service",
           "repro-addon-reassert.service", "repro-addon-secrets.service"]
  BaselineFilter = @["@system-service", "~@privileged @resources @obsolete"]
    ## The deployment policy's recipe (CONF-1's SystemCallFilter row).
  DropInName = "90-a9-syscall-profile.conf"

proc baselineMode(): bool = getEnv("REPRO_ADDON_SYSCALL_BASELINE") == "1"

proc syscallNames(): Table[int, string] =
  ## x86_64 syscall numbers to names, from this host's C headers.
  let (o, c) = execCmdEx("echo '#include <sys/syscall.h>' | cc -E -dM -")
  doAssert c == 0, "cannot read <sys/syscall.h>: " & o
  for l in o.splitLines():
    let f = l.splitWhitespace()
    if f.len == 3 and f[0] == "#define" and f[1].startsWith("__NR_"):
      try: result[parseInt(f[2])] = f[1]["__NR_".len .. ^1]
      except ValueError: discard

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
  let dir = "/run/systemd/system/" & unit & ".d"
  discard g.run("mkdir -p " & dir & " && cat > " & dir & "/" & DropInName &
    " <<'A9EOF'\n[Service]\nSystemCallFilter=\nSystemCallLog=" &
    logged.join(" ") & "\nA9EOF\n")

proc now(g: Guest): float = parseFloat(g.run("date +%s.%N").strip())

proc auditRecords(g: Guest; since: float):
    seq[tuple[at: float; nr: int; comm: string]] =
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
    var rec: tuple[at: float; nr: int; comm: string]
    try: rec.at = parseFloat(f[0])
    except ValueError: continue
    for tok in f:
      if tok.startsWith("syscall="):
        try: rec.nr = parseInt(tok["syscall=".len .. ^1])
        except ValueError: rec.nr = -1
      elif tok.startsWith("comm="):
        rec.comm = tok["comm=".len .. ^1].strip(chars = {'"'})
    result.add(rec)

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  doAssert g.base.debArch == "amd64", "this gate reads x86_64 syscall numbers"
  let names = syscallNames()
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
    if r.nr == 63: sawUname = true
  step("vacuity guard: a logged uname reaches the kernel log", sawUname, "")

  var filters = newJObject()
  for u in Units:
    let committed = g.unitFilter(u)
    filters[u] = %committed
    let allowed = allowedBy(groups, if baselineMode(): BaselineFilter
                                    else: committed)
    step(u & " has a committed allow-list filter", committed.len > 0 and
         not committed[0].startsWith("~"), $committed)
    var logged: seq[string]
    for s in known:
      if s notin allowed: logged.add(s)
    logged.sort()
    g.profileDropIn(u, logged)
  record["committedFilters"] = filters
  record["mode"] = %(if baselineMode(): "baseline" else: "committed")
  discard g.run("systemctl daemon-reload")

  # The work. Each window is attributed to the unit that ran in it.
  var windows: seq[tuple[unit: string; a, b: float]]
  let prod = producer   # a ref: the closure below may capture it
  proc tick(seqNo: uint64; text: string) =
    discard prod.publish(PublishSpec(sequence: seqNo, profileText: text))
    let a = g.now()
    let t = g.tickUnits()
    let fetchExit = parseFloat(g.run("systemctl show -p " &
      "ExecMainExitTimestamp --timestamp=unix --value " &
      "repro-agent-fetch.service").strip().strip(chars = {'@'}))
    windows.add((unit: "repro-agent-fetch.service", a: a, b: fetchExit + 0.5))
    windows.add((unit: "repro-agent-apply.service", a: fetchExit + 0.5,
                 b: g.now()))
    step("tick " & $seqNo & " applies", t.outcome == "aoApplied",
         $t & "\n" & t.fetchLog & t.applyLog)
  let v1 = canonicalFile("/etc/repro/a9-trace", "one\n") &
    unitProfile("a9-trace.service", "/bin/sleep infinity") &
    "linux.sysusersEntry {\n  name = \"a9trace\"\n  kind = \"user\"\n" &
      "  description = \"A9 trace\"\n}\n" &
    "linux.tmpfilesRule {\n  name = \"repro-a9-trace.conf\"\n  content = " &
      "\"d /var/lib/a9-trace 0750 a9trace a9trace -\n\"\n}\n" &
    "linux.sysctl {\n  key = \"vm.swappiness\"\n  value = \"33\"\n}\n"
  tick(1, v1)
  let v2 = canonicalFile("/etc/repro/a9-trace", "two\n") &
    unitProfile("a9-trace.service", "/bin/sleep 3600")
  tick(2, v2)
  for u in ["repro-addon-secrets.service", "repro-addon-reassert.service"]:
    let a = g.now()
    let r = g.exec("systemctl restart " & u)
    windows.add((unit: u, a: a, b: g.now()))
    step(u & " runs", r.exitCode == 0, r.stdout & r.stderr)

  var observed = initTable[string, HashSet[string]]()
  var unattributed: seq[string]
  for r in g.auditRecords(t0):
    if r.nr == 63 and r.comm == "uname": continue   # the vacuity guard
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
      step(u & " made no system call outside its filter",
           observed.getOrDefault(u).len == 0, $obs[u])
    step("no logged call fell outside the units' runs",
         unattributed.len == 0, unattributed.join(", "))

  # Enforcement: the drop-ins go, the committed filters apply again.
  for u in Units:
    discard g.run("rm -f /run/systemd/system/" & u & ".d/" & DropInName)
  discard g.run("systemctl daemon-reload")
  tick(3, canonicalFile("/etc/repro/a9-trace", "three\n"))

suite Gate:
  test "the add-on's units stay inside their syscall filters":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0
