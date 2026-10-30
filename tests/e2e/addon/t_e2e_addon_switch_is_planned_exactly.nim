## Gate ``e2e_addon_switch_is_planned_exactly``.
##
## Ten scripted generations on each base (Debian 13 and Ubuntu 24.04 by
## default) that add, change and remove units, drop-ins, files, tmpfiles
## and sysctl fragments and a sysusers account. For every generation:
##
## - the plan (``repro infra plan``) prints the service transition list
##   (spec §7.1, §7.3), and the apply's observed unit-state changes -- the
##   job-completion records systemd writes to the journal (``JOB_TYPE``,
##   ``JOB_RESULT``, ``UNIT``; a ``restart`` job completes as a ``restart``
##   record for the stop and a ``start`` record for the start) between a
##   cursor taken before the apply and one taken after, plus ``systemctl
##   show`` afterwards -- equal that list: every fixture unit the journal saw change is in the list with
##   the verb that produces that change, every effective entry of the
##   list was observed, and no fixture unit changed otherwise;
## - the base fingerprint diff across the apply equals the delta the two
##   ledgers account for (the do-no-harm comparison every add-on gate
##   makes), so links, copies, the static tree link, the sysctl values
##   and the retained account are all exactly what the ledger says.
##
## Every apply is pinned to its plan (``--plan <add-on plan-id>``), and
## the pin is falsified once: before generation 3, a unit the plan saw
## active crashes between the plan and the pinned apply, which refuses
## with ``EPlanStale`` (exit 3) and writes nothing (the fingerprint is
## unchanged). The transition sections are read with the strict parser
## (an unknown verb fails the gate) and compared with the ``exclusive``
## flag.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=plan-id-omits-unit-state``):
## the plan id covers the units but not the state observed for them, so
## the pinned apply after the crash goes through instead of refusing:
## red.
##
## The switch's materialisation is checked too: a managed ``/etc`` file
## is a link into ``/etc/repro/static``, which is a link into the store;
## unit files, sysusers and tmpfiles fragments are regular files; and a
## generation whose only change is a dependency of a unit restarts (or,
## with ``reloadIfChanged``, reloads) that unit and nothing else.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_switch_is_planned_exactly``).
## Bases: ``REPRO_ADDON_BASES`` (default here: debian-13-amd64,ubuntu-24.04-amd64).
##
## *Mocking.* None: real images, systemd, the journal and the static
## add-on binary.

import std/[json, os, sets, strutils, tables, times, unittest]

import repro_test_support/reasoned_skip
import repro_addon/[ledger, transitions]

import ./addon_testbed

const
  Prefixes = """addOn {
  managedEtcPrefixes = ["/etc/repro-fixture/"]
}

"""
  # A service that handles SIGHUP (so `reload` is a real transition) and
  # SIGTERM promptly.
  ServiceBody = "[Service]\nExecStart=/bin/sh -c 'trap : HUP; while :; do sleep 1; done'\nExecReload=/bin/kill -HUP $MAINPID\n"
  UnitA = "[Unit]\nDescription=fixture A (@V@)\n" & ServiceBody &
          "\n[Install]\nWantedBy=multi-user.target\n"
  UnitB = "[Unit]\nDescription=fixture B (@V@)\n" & ServiceBody &
          "\n[Install]\nWantedBy=multi-user.target\n"

proc unit(name, content: string; extra = ""): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"" &
    content & "\"\n" & extra & "}\n\n"
proc etcFile(content: string): string =
  "fs.systemFile {\n  path = \"/etc/repro-fixture/a.conf\"\n  content = \"" &
    content & "\"\n}\n\n"
proc tmpfiles(): string =
  "linux.tmpfilesRule {\n  name = \"repro-fixture.conf\"\n  content = \"d /var/lib/repro-fixture 0750 root root -\n\"\n}\n\n"
proc sysusers(): string =
  "linux.sysusersEntry {\n  name = \"repro-fixture\"\n  description = \"Reprobuild fixture\"\n}\n\n"
proc dropIn(nice: string): string =
  "systemd.systemDropIn {\n  unit = \"cron.service\"\n  name = \"fixture\"\n  content = \"[Service]\nNice=" &
    nice & "\n\"\n}\n\n"
proc sysctl(value: string): string =
  "linux.sysctl {\n  key = \"net.ipv4.ip_forward\"\n  value = \"" & value & "\"\n}\n\n"

const DependsOnFile = "  depends_on = [\"fs.systemFile:/etc/repro-fixture/a.conf\"]\n"

## The ten generations and, for each, the transitions the plan must list
## (verb and unit; the apply's journal must show exactly these) and the
## fixture units' expected ActiveState afterwards.
type Generation = object
  name: string
  profile: string
  expected: seq[(string, string)]      ## (verb, unit) of the effective entries
  leave: seq[string]                   ## units the plan lists as `leave`
  active: Table[string, string]        ## fixture unit -> ActiveState after

let generations = [
  Generation(name: "g1-add",
    profile: Prefixes & unit("repro-fixture-a.service", UnitA.replace("@V@", "v1")) &
      etcFile("one\n") & tmpfiles() & sysusers(),
    expected: @[("start", "repro-fixture-a.service")],
    active: {"repro-fixture-a.service": "active"}.toTable),
  Generation(name: "g2-change-unit-add-dependent",
    profile: Prefixes & unit("repro-fixture-a.service", UnitA.replace("@V@", "v2")) &
      unit("repro-fixture-b.service", UnitB.replace("@V@", "v1"), DependsOnFile) &
      etcFile("one\n") & tmpfiles() & sysusers(),
    expected: @[("restart", "repro-fixture-a.service"),
                ("start", "repro-fixture-b.service")],
    active: {"repro-fixture-a.service": "active",
             "repro-fixture-b.service": "active"}.toTable),
  Generation(name: "g3-dependency-only",
    profile: Prefixes & unit("repro-fixture-a.service", UnitA.replace("@V@", "v2")) &
      unit("repro-fixture-b.service", UnitB.replace("@V@", "v1"), DependsOnFile) &
      etcFile("two\n") & tmpfiles() & sysusers(),
    expected: @[("restart", "repro-fixture-b.service")],
    active: {"repro-fixture-a.service": "active",
             "repro-fixture-b.service": "active"}.toTable),
  Generation(name: "g4-dropin-sysctl",
    profile: Prefixes & unit("repro-fixture-a.service", UnitA.replace("@V@", "v2")) &
      unit("repro-fixture-b.service", UnitB.replace("@V@", "v1"), DependsOnFile) &
      etcFile("two\n") & tmpfiles() & sysusers() & dropIn("5") & sysctl("1"),
    expected: @[("restart", "cron.service")],
    active: {"repro-fixture-a.service": "active",
             "repro-fixture-b.service": "active", "cron.service": "active"}.toTable),
  Generation(name: "g5-change-dropin-sysctl",
    profile: Prefixes & unit("repro-fixture-a.service", UnitA.replace("@V@", "v2")) &
      unit("repro-fixture-b.service", UnitB.replace("@V@", "v1"), DependsOnFile) &
      etcFile("two\n") & tmpfiles() & sysusers() & dropIn("7") & sysctl("0"),
    expected: @[("restart", "cron.service")],
    active: {"cron.service": "active"}.toTable),
  Generation(name: "g6-held-restart-and-reload",
    profile: Prefixes &
      unit("repro-fixture-a.service", UnitA.replace("@V@", "v3"), "  restartIfChanged = false\n") &
      unit("repro-fixture-b.service", UnitB.replace("@V@", "v1"),
           DependsOnFile & "  reloadIfChanged = true\n") &
      etcFile("three\n") & tmpfiles() & sysusers() & dropIn("7") & sysctl("0"),
    expected: @[("reload", "repro-fixture-b.service")],
    leave: @["repro-fixture-a.service"],
    active: {"repro-fixture-a.service": "active",
             "repro-fixture-b.service": "active"}.toTable),
  Generation(name: "g7-remove-fragments",
    profile: Prefixes &
      unit("repro-fixture-a.service", UnitA.replace("@V@", "v3"), "  restartIfChanged = false\n") &
      unit("repro-fixture-b.service", UnitB.replace("@V@", "v1"),
           DependsOnFile & "  reloadIfChanged = true\n") &
      etcFile("three\n"),
    expected: @[("restart", "cron.service")],
    active: {"cron.service": "active"}.toTable),
  Generation(name: "g8-remove-dependent",
    profile: Prefixes &
      unit("repro-fixture-a.service", UnitA.replace("@V@", "v3"), "  restartIfChanged = false\n") &
      etcFile("three\n"),
    expected: @[("stop", "repro-fixture-b.service")],
    active: {"repro-fixture-a.service": "active",
             "repro-fixture-b.service": "inactive"}.toTable),
  Generation(name: "g9-stop-held",
    profile: Prefixes &
      unit("repro-fixture-a.service", UnitA.replace("@V@", "v3"), "  stopOnRemoval = false\n") &
      etcFile("three\n"),
    expected: @[],
    active: {"repro-fixture-a.service": "active"}.toTable),
  Generation(name: "g10-remove-all",
    profile: Prefixes,
    expected: @[],
    leave: @["repro-fixture-a.service"],
    active: {"repro-fixture-a.service": "active"}.toTable),
]

proc journalCursor(g: Guest): string =
  ## The journal's current tail cursor.
  g.run("journalctl --no-pager -n 0 --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p'").strip()

proc observedJobs(g: Guest; cursor: string): seq[(string, string)] =
  ## ``(verb, unit)`` for every unit job PID 1 completed since ``cursor``:
  ## `started`, `stopped` or `reloaded`, from the journal's structured
  ## job records. A restart is a `stopped` followed by a `started`.
  let raw = g.run("journalctl --no-pager -o json --after-cursor=" &
    quoteShell(cursor) & " _PID=1 2>/dev/null; true")
  for line in raw.splitLines():
    if line.len == 0: continue
    var j: JsonNode
    try: j = parseJson(line)
    except CatchableError: continue
    if j.kind != JObject or "UNIT" notin j or "JOB_TYPE" notin j or
        "JOB_RESULT" notin j:
      continue
    if j["JOB_RESULT"].getStr() != "done": continue
    let u = j["UNIT"].getStr()
    let verb = case j["JOB_TYPE"].getStr()
      of "start": "started"
      of "stop": "stopped"
      of "reload": "reloaded"
      of "restart": "restarted"
      else: ""
    if verb.len > 0: result.add((verb, u))

proc expectedObservations(ts: seq[Transition]): Table[string, seq[string]] =
  ## What the journal must show per unit for the plan's effective entries.
  for t in ts:
    case t.verb
    of tvStart: result[t.unit] = @["started"]
    of tvStop: result[t.unit] = @["stopped"]
    of tvRestart: result[t.unit] = @["restarted", "started"]
    of tvStopStart: result[t.unit] = @["stopped", "started"]
    of tvReload: result[t.unit] = @["reloaded"]
    of tvLeave: discard

proc isFixtureUnit(u: string): bool =
  u.startsWith("repro-fixture-") or u == "cron.service"

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    # The drop-in generations need a distribution unit to drop into.
    discard g.run("export DEBIAN_FRONTEND=noninteractive; " &
      "apt-get install -y -qq cron >/dev/null", timeoutSec = 1200)
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails
    var f = g.takeFingerprint(repro)
    var l = g.ledgerOf()
    proc planIdIn(text: string): string =
      for line in text.splitLines():
        if line.startsWith("add-on plan-id: "):
          return line["add-on plan-id: ".len .. ^1].strip()
    for gen in generations:
      if gen.name == "g3-dependency-only":
        # The pinned plan goes stale: a unit it saw active crashes.
        let stalePlan = g.planProfile(repro, gen.name & "-stale", gen.profile)
        let staleId = planIdIn(stalePlan.stdout)
        step("g3: the plan prints an add-on plan id", staleId.len == 32, stalePlan.stdout)
        discard g.run("systemctl kill -s KILL repro-fixture-b.service; sleep 1; true")
        let crashed = g.takeFingerprint(repro)
        let st = g.applyProfile(repro, gen.name & "-stale", gen.profile, " --plan " & staleId)
        step("g3: the pinned apply refuses with EPlanStale after the unit crashed",
             st.exitCode == 3 and "stale" in st.stderr, "exit " & $st.exitCode & "\n" & st.stdout & st.stderr)
        let id = identityReport(crashed, g.takeFingerprint(repro))
        step("g3: the stale apply wrote nothing", id.ok, id.text)
        discard g.run("systemctl reset-failed repro-fixture-b.service; systemctl start repro-fixture-b.service")
        f = g.takeFingerprint(repro)
      let pl = g.planProfile(repro, gen.name, gen.profile)
      step(gen.name & ": plan", pl.exitCode == 0, pl.stdout & pl.stderr)
      let planned = parseTransitions(pl.stdout)
      var plannedPairs: seq[(string, string)]
      var plannedLeave: seq[string]
      for t in planned:
        if t.isEffective: plannedPairs.add(($t.verb, t.unit))
        else: plannedLeave.add(t.unit)
      step(gen.name & ": the plan's transition list is the scripted one",
           plannedPairs == gen.expected and plannedLeave == gen.leave,
           "planned " & $plannedPairs & " leave " & $plannedLeave &
           "\nexpected " & $gen.expected & " leave " & $gen.leave & "\n" & pl.stdout)
      let cursor = g.journalCursor()
      let pidA = g.exec("systemctl show -p MainPID --value repro-fixture-a.service").stdout.strip()
      let pinned = planIdIn(pl.stdout)
      step(gen.name & ": the plan prints an add-on plan id", pinned.len == 32, pl.stdout)
      let ap = g.applyProfile(repro, gen.name, gen.profile, " --plan " & pinned)
      step(gen.name & ": apply", ap.exitCode == 0, ap.stdout & ap.stderr)
      # The apply prints the same list the plan did.
      let applied = parseTransitions(ap.stdout)
      step(gen.name & ": the apply's transition list equals the plan's",
           applied.len == planned.len and (block:
             var same = true
             for i in 0 ..< min(applied.len, planned.len):
               if applied[i].unit != planned[i].unit or applied[i].verb != planned[i].verb or
                   applied[i].exclusive != planned[i].exclusive:
                 same = false
             same), ap.stdout)
      # The journal: every fixture unit's state changes equal the list.
      let jobs = g.observedJobs(cursor)
      var perUnit = initTable[string, seq[string]]()
      for (verb, u) in jobs:
        if isFixtureUnit(u): perUnit.mgetOrPut(u, @[]).add(verb)
      let expected = expectedObservations(planned)
      var same = true
      var detail = ""
      for u, verbs in perUnit:
        if u notin expected:
          same = false
          detail.add("unplanned: " & u & " " & $verbs & "\n")
        elif verbs != expected[u]:
          same = false
          detail.add(u & ": observed " & $verbs & ", planned " & $expected[u] & "\n")
      for u, verbs in expected:
        if u notin perUnit:
          same = false
          detail.add(u & ": planned " & $verbs & ", nothing observed\n")
      step(gen.name & ": observed unit-state changes == the transition list",
           same, detail & "journal jobs: " & $jobs)
      # `systemctl show` afterwards agrees with the plan's intent.
      for u, state in gen.active:
        let now = g.run("systemctl show -p ActiveState --value " & u).strip()
        step(gen.name & ": " & u & " is " & state & " afterwards", now == state, now)
      # The fingerprint diff equals the ledger diff.
      let after = g.takeFingerprint(repro)
      let l2 = g.ledgerOf()
      let d = deltaReport(f, after, l, l2)
      step(gen.name & ": fingerprint diff == ledger delta", d.ok, d.text)
      f = after
      l = l2
      # Materialisation checks at the generations that make them visible.
      case gen.name
      of "g1-add":
        step("g1: the managed file is a link into /etc/repro/static",
             g.run("readlink /etc/repro-fixture/a.conf").strip() ==
               "/etc/repro/static/repro-fixture/a.conf" and
             g.run("cat /etc/repro-fixture/a.conf") == "one\n", "")
        step("g1: the unit is a regular file (enable must not resolve a link) and systemd loads it",
             g.exec("test -f /etc/systemd/system/repro-fixture-a.service && test ! -L /etc/systemd/system/repro-fixture-a.service").exitCode == 0 and
             "fixture A (v1)" in g.run("systemctl show -p Description --value repro-fixture-a.service"), "")
        step("g1: /etc/repro/static is a link into the store",
             g.run("readlink /etc/repro/static").strip().startsWith("/repro/store/prefixes/repro-addon-etc"), "")
        step("g1: sysusers and tmpfiles fragments are regular files",
             g.exec("test -f /etc/sysusers.d/repro-repro-fixture.conf && test ! -L /etc/sysusers.d/repro-repro-fixture.conf && " &
                    "test -f /etc/tmpfiles.d/repro-fixture.conf && test ! -L /etc/tmpfiles.d/repro-fixture.conf").exitCode == 0, "")
        step("g1: the account exists and the tmpfiles directory was created",
             g.exec("getent passwd repro-fixture >/dev/null && test -d /var/lib/repro-fixture").exitCode == 0, "")
        var forms: seq[string]
        for e in parseLedger(l).entries:
          if e.resource.len > 0 and e.class in {lcEtcFile, lcUnit}: forms.add(e.path & "=" & e.form)
        step("g1: the ledger records the forms",
             "/etc/repro-fixture/a.conf=link" in forms and
             "/etc/systemd/system/repro-fixture-a.service=copy" in forms and
             "/etc/sysusers.d/repro-repro-fixture.conf=copy" in forms and
             "/etc/tmpfiles.d/repro-fixture.conf=copy" in forms, $forms)
      of "g4-dropin-sysctl":
        step("g4: the drop-in is a link systemd reports and the sysctl is set",
             "/etc/systemd/system/cron.service.d/50-repro-fixture.conf" in
               g.run("systemctl show -p DropInPaths --value cron.service") and
             g.run("cat /proc/sys/net/ipv4/ip_forward").strip() == "1", "")
      of "g6-held-restart-and-reload":
        # systemd reports the reloaded file's Description; the running
        # instance is told apart by its PID.
        step("g6: the held unit still runs the old instance (same MainPID), reported as pending",
             g.run("systemctl show -p MainPID --value repro-fixture-a.service").strip() == pidA and
             "pending restart" in ap.stdout, "pid before " & pidA & "\n" & ap.stdout)
      of "g7-remove-fragments":
        step("g7: the sysctl is back to its base value, the account is kept",
             g.run("cat /proc/sys/net/ipv4/ip_forward").strip() == "0" and
             g.exec("getent passwd repro-fixture >/dev/null").exitCode == 0 and
             g.exec("test ! -e /etc/sysusers.d/repro-repro-fixture.conf").exitCode == 0, "")
      of "g10-remove-all":
        step("g10: the unit file is gone, the instance still runs (stopOnRemoval = false)",
             g.exec("test ! -e /etc/systemd/system/repro-fixture-a.service").exitCode == 0 and
             g.run("systemctl is-active repro-fixture-a.service").strip() == "active", "")
      else: discard
    # Clean up the instance the last generation deliberately left running.
    discard g.exec("systemctl stop repro-fixture-a.service; systemctl daemon-reload")
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall exits 0 and keeps the account", un.exitCode == 0 and
         "repro-fixture" in un.stdout, un.stdout & un.stderr)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite "e2e_addon_switch_is_planned_exactly":
  test "every apply's unit-state changes equal its plan's transition list":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_switch_is_planned_exactly)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_switch_is_planned_exactly",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_switch_is_planned_exactly", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
