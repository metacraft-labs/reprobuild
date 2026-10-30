## Gate ``e2e_addon_gc_keeps_current_and_previous``.
##
## After bootstrap and five further generations, each with its own static
## tree (a managed file whose content differs per generation), the
## retention policy is set as aggressively as it goes (keep nothing beyond
## the current and the previous generation) and ``repro store gc`` runs
## with no grace period. Afterwards:
##
## - the static trees of the three older generations are gone from the
##   store, and so are their generation roots;
## - the trees of the current and the previous generation are intact,
##   ``/etc/repro/static`` still resolves and the managed file still reads
##   the current generation's content;
## - a reboot starts every service of the current generation (the fixture
##   service is active, the add-on's own units too) and ``verify`` is ok.
##
## Vacuity guard: before the retention policy released anything, the same
## ``repro store gc`` collected nothing (every generation was a root).
##
## Then three properties of the policy itself:
##
## - **a held unit's generation is kept** (§5.2): a unit with
##   ``restartIfChanged = false`` started by generation 6 keeps running
##   from it while generations 7-9 change its file; retention keeps
##   generation 6's root and gc leaves generation 6's tree -- while
##   generation 5, which never carried the unit, and the units that run
##   the current definition (the gc fixture, the add-on's own) pin
##   nothing: generation 5's root is released;
## - **an uncommitted attempt is not "previous"**: a switch that fails in
##   step 7 (a unit that cannot start) writes the ledger copy under the id
##   it would have committed; the next apply's retention still keeps the
##   generation ``current`` named, 9, and gc leaves its tree;
## - **``--keep-generations 0 --keep-days 0`` on the apply is honoured**,
##   not read as "unset" and replaced by the default: generations 7 and 8
##   lose their roots and gc collects their trees.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_gc_keeps_current_and_previous``).
## Bases: ``REPRO_ADDON_BASES`` (default here: debian-13-amd64,ubuntu-24.04-amd64).
##
## *Mocking.* None: real images, the real store and collector, a real
## reboot.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const
  Service = "[Unit]\nDescription=gc fixture\n[Service]\nExecStart=/bin/sleep infinity\n\n[Install]\nWantedBy=multi-user.target\n"

  # A unit held by restartIfChanged = false: generations that change it
  # leave the instance an older generation started running.
  HeldUnit = "[Unit]\nDescription=held fixture @V@\n[Service]\nExecStart=/bin/sleep infinity\n\n[Install]\nWantedBy=multi-user.target\n"
  # Cannot start: the switch fails in step 7.
  FailingUnit = "[Unit]\nDescription=failing fixture\n[Service]\nType=oneshot\nExecStart=/bin/false\n\n[Install]\nWantedBy=multi-user.target\n"

proc profile(n: int; held = ""): string =
  result = "addOn {\n  managedEtcPrefixes = [\"/etc/repro-fixture/\"]\n}\n\n" &
    "systemd.systemUnit {\n  name = \"repro-fixture-gc.service\"\n  content = \"" &
    Service & "\"\n}\n\n" &
    "fs.systemFile {\n  path = \"/etc/repro-fixture/gen.conf\"\n  content = \"generation " &
    $n & "\n\"\n}\n"
  if held.len > 0:
    result.add("\nsystemd.systemUnit {\n  name = \"repro-fixture-held.service\"\n  content = \"" &
      held & "\"\n  restartIfChanged = false\n}\n")

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
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails
    var trees: seq[string]
    for n in 1 .. 5:
      let r = g.applyProfile(repro, "g" & $n, profile(n))
      step("generation " & $n & ": applied", r.exitCode == 0, r.stdout & r.stderr)
      trees.add(g.run("readlink /etc/repro/static").strip())
    step("vacuity guard: five distinct static trees",
         trees.len == 5 and (block:
           var allDifferent = true
           for i in 0 ..< trees.len:
             for j in i + 1 ..< trees.len:
               if trees[i] == trees[j]: allDifferent = false
           allDifferent), $trees)
    let status = g.run(repro & " system addon status")
    step("every generation is a store root before retention",
         status.count("\n  ") >= 6, status)   # gen 0 + five
    # Vacuity guard: with every generation a root, gc collects nothing.
    let gc0 = g.run(repro & " store gc --grace-seconds 0")
    step("vacuity guard: gc with every generation a root collects nothing",
         "quarantined: 0" in gc0, gc0)
    for t in trees:
      step("vacuity guard: tree " & t & " is present", g.exec("test -d " & t).exitCode == 0, "")
    # The aggressive policy: nothing beyond current and previous.
    let ret = g.run(repro & " system addon retention --keep-generations 0 --keep-days 0")
    step("retention keeps the current and the previous generation",
         "(current)" in ret and "(previous)" in ret and
         "released store roots (4)" in ret, ret)
    let gc1 = g.run(repro & " store gc --grace-seconds 0")
    step("gc collects the older trees", "quarantined: 3" in gc1 or
         ("repro-addon-etc" in gc1 and "quarantined: 0" notin gc1), gc1)
    for i, t in trees:
      if i < 3:
        step("older tree " & t & " was collected", g.exec("test ! -e " & t).exitCode == 0, "")
      else:
        step("retained tree " & t & " is intact", g.exec("test -d " & t).exitCode == 0, "")
    step("the current generation's file still reads through the static link",
         g.run("cat /etc/repro-fixture/gen.conf") == "generation 5\n", "")
    step("the add-on's own prefixes survived (the binary runs)",
         g.exec("/repro/store/prefixes/repro-addon/*/bin/repro --version").exitCode == 0 or
         g.exec(g.run("readlink -f /etc/repro/bin/repro 2>/dev/null || echo " & repro).strip() & " --version").exitCode == 0, "")
    # Reboot: every service of the current generation starts.
    discard g.exec("systemctl reboot", timeoutSec = 30)
    discard g.waitPoweredOff(300)
    g.boot()
    discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true", timeoutSec = 600)
    step("after reboot: the fixture service is active",
         g.run("systemctl is-active repro-fixture-gc.service").strip() == "active", "")
    step("after reboot: the add-on's target and store mount are active",
         g.run("systemctl is-active repro-addon.target").strip() == "active" and
         g.run("systemctl is-active repro-store.mount").strip() == "active", "")
    step("after reboot: /etc/repro/static resolves and the file reads",
         g.run("cat /etc/repro-fixture/gen.conf") == "generation 5\n", "")
    let ver = g.exec(repro & " system addon verify")
    step("after reboot: verify is ok", ver.exitCode == 0 and "verify: ok" in ver.stdout,
         ver.stdout & ver.stderr)
    # --- Retention after the reboot (F4, F9, F10). ---
    proc currentId(): string =
      g.run("readlink /var/lib/repro/system/current").strip().extractFilename
    proc rootsNow(): string = g.run(repro & " system addon status")
    let gen5 = currentId()
    var ids: seq[string]
    var trees2: seq[string]
    for n in 6 .. 9:
      let held = HeldUnit.replace("@V@", (if n == 6: "v1" else: "v2"))
      let r = g.applyProfile(repro, "g" & $n, profile(n, held))
      step("generation " & $n & ": applied", r.exitCode == 0, r.stdout & r.stderr)
      ids.add(currentId())
      trees2.add(g.run("readlink /etc/repro/static").strip())
    let heldPid = g.run("systemctl show -p MainPID --value repro-fixture-held.service").strip()
    step("the held unit runs the instance generation 6 started (pending restart since 7)",
         heldPid != "0" and heldPid.len > 0 and
         g.run("systemctl is-active repro-fixture-held.service").strip() == "active", heldPid)
    # A switch that fails in step 7: nothing is committed.
    let failed = g.applyProfile(repro, "g-failed", profile(99, HeldUnit.replace("@V@", "v2")) &
      "\nsystemd.systemUnit {\n  name = \"repro-fixture-fails.service\"\n  content = \"" &
      FailingUnit & "\"\n}\n")
    let ledgerGen = g.run("sed -n 's/^generation\t//p' /var/lib/repro/system/addon-ledger 2>/dev/null || true").strip()
    step("a switch failing in step 7 commits nothing", failed.exitCode != 0 and
         currentId() == ids[^1], "exit " & $failed.exitCode & " current " & currentId() &
         "\n" & failed.stdout & failed.stderr)
    step("vacuity guard: the ledger copy names the uncommitted attempt",
         ledgerGen.len > 0 and ledgerGen != ids[^1], "ledger copy generation " & ledgerGen)
    # Generation 10 with the tightest policy the apply accepts.
    let r10 = g.applyProfile(repro, "g10", profile(10, HeldUnit.replace("@V@", "v2")),
                             " --keep-generations 0 --keep-days 0")
    step("generation 10 (keep 0 generations, 0 days): applied", r10.exitCode == 0,
         r10.stdout & r10.stderr)
    let roots = rootsNow()
    step("the previous generation is the committed one (9), not the failed attempt",
         ("previous " & ids[3]) in r10.stdout or ("(previous " & ids[3]) in r10.stdout,
         r10.stdout)
    step("retention kept generation 9 (previous) and 6 (the held unit's)",
         ids[3] in roots and ids[0] in roots, roots)
    step("retention released generations 5, 7 and 8 (0/0 is not the default; " &
         "units running the current definition pin nothing)",
         ids[1] notin roots and ids[2] notin roots and gen5 notin roots and
         "retention released the store roots of" in r10.stdout, roots & "\n" & r10.stdout)
    let gc2 = g.run(repro & " store gc --grace-seconds 0")
    step("gc kept generation 9's tree (the real previous)",
         g.exec("test -d " & trees2[3]).exitCode == 0, gc2)
    step("gc kept generation 6's tree (the held unit runs from it)",
         g.exec("test -d " & trees2[0]).exitCode == 0, gc2)
    step("gc collected generations 7 and 8's trees",
         g.exec("test ! -e " & trees2[1] & " && test ! -e " & trees2[2]).exitCode == 0, gc2)
    step("the held unit still runs the same instance",
         g.run("systemctl show -p MainPID --value repro-fixture-held.service").strip() == heldPid, "")
    discard g.exec("systemctl stop repro-fixture-held.service; true")
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
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

suite "e2e_addon_gc_keeps_current_and_previous":
  test "store gc never collects what the current or the previous generation holds":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_gc_keeps_current_and_previous)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_gc_keeps_current_and_previous",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_gc_keeps_current_and_previous", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
