## Gate ``e2e_addon_floor_upgrade_keeps_installed_generations`` (milestone
## A9, review findings H1 and H2 of round 1 and finding 3 of round 2; spec
## §10.1 *A host upgraded to a build with the floor* and *Stored generations
## and floor versions*, §7.5).
##
## Every engine that has stored add-on generations installs one, and then
## the engine under test takes over. Two chains, each on its own guest,
## because the first floored engine cannot follow the pre-floor one (it
## parsed a stored pre-floor generation under its floor and wedged: round
## 1's H1, which is why no host carries both):
##
## - ``prefloor`` (9d5ce19e07, no floor) then ``v3`` (221ac312b6, floor
##   version 3, the first engine that records a unit's floor version);
## - ``v1`` (1a598170c0, floor version 1) then ``v2`` (d03bb6759e, floor
##   version 2).
##
## Between them every stored form the engine under test must restore:
## pre-floor, versions 1 and 2 (recorded by no version; told apart by the
## ledger) and version 3 (recorded), each re-rendered by its frozen
## renderer.
##
## Each engine installs a generation of a web service that runs the base's
## own ``python3`` (the floored ones naming the exception it needs). Then
## the engine under test:
##
## - plans a profile over the stored generations without wedging, and its
##   plan names the unit's floor change (the chain's last version ->
##   today's); the unfixed
##   profile is refused for its own unit, by the floor;
## - a floored generation that fails its confirm is reverted, and the revert
##   restores the newest stored generation's unit byte for byte;
## - the fixed profile applies under today's floor;
## - ``repro system rollback`` to each stored generation, newest first,
##   restores each one's unit byte for byte, and the service serves each
##   one's page.
##
## Falsifying mutations: ``stored-profile-floored`` (stored generations
## parsed with today's floor default) and ``stored-floor-unversioned``
## (a stored floored unit rendered with today's floor version): a revert
## or a rollback no longer restores the stored bytes, red.
##
## Needs ``REPRO_ADDON_OLD_ENGINES``: ``prefloor:<dir>;v1:<dir>;v2:<dir>;v3:<dir>``,
## each a ``scripts/build_addon_static.sh --out`` directory of a worktree at
## that engine's commit (``<dir>/<debArch>/repro``); a missing engine is a
## failure, never a skip.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None: five real builds of the add-on, real switches.

import std/[json, os, strutils, tables, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const
  Gate = "e2e_addon_floor_upgrade_keeps_installed_generations"
  Port = 18471
  UnitPath = "/etc/systemd/system/a9-up.service"
  PythonException = "NoExecPaths: serves with the base's own python3"

proc service(page: string): string =
  ## A web service on the base's python3. Its state is a runtime
  ## directory, so it runs as it is under the floor too.
  "[Unit]\nDescription=A9 upgrade fixture\n[Service]\n" &
    "RuntimeDirectory=a9-up\n" &
    "ExecStartPre=/bin/sh -c 'echo " & page & " > /run/a9-up/index.html'\n" &
    "ExecStart=/usr/bin/python3 -m http.server " & $Port &
    " --bind 127.0.0.1 --directory /run/a9-up\n\n" &
    "[Install]\nWantedBy=multi-user.target\n"

proc profile(unitText, check: string; extra = ""; timeout = 0): string =
  "addOn {\n  managedEtcPrefixes = []\n" &
    (if timeout > 0: "  confirmTimeout = " & $timeout & "\n" else: "") &
    "}\n\nsystemd.systemUnit {\n  name = \"a9-up.service\"\n" &
    "  content = \"" & unitText & "\"\n  healthCheck = \"" & check & "\"\n" &
    extra & "}\n"

proc served(g: Guest): string =
  g.exec("for i in $(seq 1 15); do curl -sf http://127.0.0.1:" & $Port &
         "/ && exit 0; sleep 1; done; exit 1").stdout.strip()

proc unitSha(g: Guest): string =
  g.exec("sha256sum " & UnitPath & " | cut -d' ' -f1").stdout.strip()

proc oldEngine(name, debArch: string): string =
  ## ``<dir>/<debArch>/repro`` of engine ``name`` in REPRO_ADDON_OLD_ENGINES.
  for item in getEnv("REPRO_ADDON_OLD_ENGINES").split(';'):
    let kv = item.split(':', 1)
    if kv.len == 2 and kv[0] == name:
      let p = kv[1] / debArch / "repro"
      if fileExists(p): return p
      raise newException(TestBedError, "REPRO_ADDON_OLD_ENGINES: no " & p)
  raise newException(TestBedError, "REPRO_ADDON_OLD_ENGINES names no " &
    name & " engine: the gate needs prefloor, v1, v2 and v3")

proc generationNow(g: Guest): string =
  extractFilename(g.run("readlink /var/lib/repro/system/current").strip())

proc runBase(b: BaseImage; chain: seq[string]; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    var engines = newJObject()
    var installed: seq[tuple[name, path: string]]
    for name in chain:
      installed.add((name: name, path: oldEngine(name, b.debArch)))
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    var guestEngine = initTable[string, string]()
    for (name, path) in installed:
      let at = "/root/repro-" & name
      g.copyTo(path, at)
      discard g.run("chmod 0755 " & at)
      guestEngine[name] = at
      engines[name] = %g.run("sha256sum " & at & " | cut -d' ' -f1").strip()
    record["oldEngines"] = engines
    let good = "http://127.0.0.1:" & $Port & "/"
    let floored = "  floorExceptions = [\"" & PythonException & "\"]\n"
    # 1. The chain's first engine bootstraps; each installs a generation.
    if not g.bootstrapAddon(guestEngine[chain[0]], step): return fails
    var r: ExecOut
    var gens: seq[tuple[name, id, sha, page: string]]
    for i, name in chain:
      let page = "page-" & name
      let text = if name == "prefloor": profile(service(page), good)
                 else: profile(service(page), good, floored)
      r = g.applyProfile(guestEngine[name], "g-" & name, text)
      step("the " & name & " engine applies its generation", r.exitCode == 0,
           r.stdout & r.stderr)
      step("the " & name & " generation serves its page",
           g.served() == page, "")
      if name == "prefloor":
        step("the pre-floor unit carries no floor",
             "NoExecPaths" notin g.run("cat " & UnitPath), "")
      gens.add((name: name, id: g.generationNow(), sha: g.unitSha(),
                page: page))
    step("each engine installed a different unit",
         gens[0].sha != gens[1].sha, $gens)
    var shas = newJObject()
    for x in gens: shas[x.name] = %x.sha
    record["storedUnitSha256"] = shas
    # 4. No wedge: the engine under test plans over the stored generation.
    let fixed = profile(service("page-fixed"), good, floored)
    let pf = g.exec(repro & " infra plan --profile " &
      g.putProfile("fixed", fixed), timeoutSec = 1200)
    step("the engine under test plans over the stored generations",
         pf.exitCode == 0, pf.stdout & pf.stderr)
    step("its plan names the unit's floor change",
         "a9-up.service (floor version " & chain[^1][1 .. ^1] &
           " -> floor version" in
           pf.stdout & pf.stderr, pf.stdout & pf.stderr)
    let pu = g.exec(repro & " infra plan --profile " &
      g.putProfile("unfixed", profile(service("page-x"), good)),
      timeoutSec = 1200)
    step("the unfixed profile is refused for its own unit, by the floor",
         pu.exitCode != 0 and "outside the unit's closure" in
           pu.stdout & pu.stderr, pu.stdout & pu.stderr)
    # 5. A floored generation that fails its confirm is reverted to
    # generation 3, byte for byte.
    let addonBin = g.run("ls -d /repro/store/prefixes/repro-addon/*/bin/repro " &
                         "| head -1").strip()
    let failing = profile("[Unit]\nDescription=A9 upgrade fixture\n" &
      "[Service]\nExecStart=" & addonBin & " --version\n" &
      "RemainAfterExit=yes\nType=oneshot\n\n[Install]\n" &
      "WantedBy=multi-user.target\n", "tcp:127.0.0.1:18472", timeout = 15)
    r = g.applyProfile(repro, "fails", failing)
    step("a floored generation that fails its confirm is reverted",
         r.exitCode != 0 and "rolled back" in r.stdout & r.stderr,
         r.stdout & r.stderr)
    step("the revert restores the " & gens[^1].name & " unit byte for byte",
         g.unitSha() == gens[^1].sha, g.run("cat " & UnitPath))
    step("the " & gens[^1].name & " service serves again",
         g.served() == gens[^1].page, "")
    # 6. The fixed profile applies under today's floor.
    r = g.applyProfile(repro, "fixed", fixed)
    step("the fixed profile applies under today's floor", r.exitCode == 0,
         r.stdout & r.stderr)
    let unitNow = g.run("cat " & UnitPath)
    step("its unit carries today's floor and the exception",
         "ReadOnlyPaths=/proc" in unitNow and
         "# serviceFloor exception: NoExecPaths" in unitNow, unitNow)
    step("the fixed service serves", g.served() == "page-fixed", "")
    step("the plan names the exception", PythonException in r.stdout, "")
    # 7. Rollback to each stored generation, newest first.
    for i in countdown(gens.high, 0):
      let x = gens[i]
      let rb = g.exec(repro & " system rollback " & x.id, timeoutSec = 1200)
      step("rollback to the " & x.name & " generation succeeds",
           rb.exitCode == 0, rb.stdout & rb.stderr)
      step("the rollback restores the " & x.name & " unit byte for byte",
           g.unitSha() == x.sha, g.run("cat " & UnitPath))
      step("and its service serves " & x.page, g.served() == x.page, "")
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

suite Gate:
  test "an engine upgrade keeps the generations it finds installed":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b in selectedBases():
        for chain in [@["prefloor", "v3"], @["v1", "v2"]]:
          let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
            "backend": (if useIncus(): "incus" else: "qemu"),
            "mutation": mutation(), "reprobuild": gitHead(),
            "chain": chain, "oldEngineDirs": getEnv("REPRO_ADDON_OLD_ENGINES"),
            "started": $now().utc}
          let f = runBase(b, chain, record)
          record["verdict"] = %(if f.len == 0: "green" else: "red")
          record["finished"] = %($now().utc)
          echo "record: ", writeRecord(Gate, record)
          failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
