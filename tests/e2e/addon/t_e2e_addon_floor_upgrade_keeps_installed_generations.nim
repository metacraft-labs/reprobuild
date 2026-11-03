## Gate ``e2e_addon_floor_upgrade_keeps_installed_generations`` (milestone
## A9, review findings H1 and H2; spec §10.1 *A host upgraded to a build
## with the floor*, §7.5).
##
## A real engine upgrade across the hardening floor. The guest is
## bootstrapped and its first generation applied by the add-on binary from
## BEFORE the floor (``REPRO_ADDON_PRE_FLOOR_ARTEFACT``, a static build of
## the commit A9 started from): a web service that runs the base's own
## ``python3`` -- outside every closure, which the floor refuses in a new
## profile. Then the binary under test takes over:
##
## 1. the stored pre-floor generation does not wedge it (H1): ``repro infra
##    plan`` of a fixed profile (the unit naming the exception it needs)
##    succeeds, while a plan of the unfixed profile is refused naming the
##    floor, not the stored generation;
## 2. a floored generation that fails its confirm is reverted (H2), and the
##    revert restores the pre-floor unit file byte for byte, the service
##    serving again -- the stored generation is rendered under the rules it
##    was installed with, not re-rendered with today's floor;
## 3. the fixed profile is applied (the floor with its named exception);
## 4. ``repro system rollback`` to the pre-floor generation restores its
##    unit file byte for byte too.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=stored-profile-floored``):
## stored generations are parsed with today's floor default; the stored
## pre-floor profile no longer parses, so the plan, the revert and the
## rollback fail: red.
##
## Needs ``REPRO_ADDON_PRE_FLOOR_ARTEFACT`` (a static add-on ``repro`` built
## from the pre-floor commit, ``scripts/build_addon_static.sh --out`` in a
## worktree of it); a missing artefact is a failure, never a skip.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None: two real builds of the add-on, real switches.

import std/[json, os, strutils, times, unittest]

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

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    let old = getEnv("REPRO_ADDON_PRE_FLOOR_ARTEFACT")
    if old.len == 0 or not fileExists(old):
      raise newException(TestBedError, "REPRO_ADDON_PRE_FLOOR_ARTEFACT " &
        "names no file: the gate needs the add-on binary from before the floor")
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    g.copyTo(old, "/root/repro-pre-floor")
    discard g.run("chmod 0755 /root/repro-pre-floor")
    let oldRepro = "/root/repro-pre-floor"
    record["preFloorArtefactSha256"] =
      %g.run("sha256sum " & oldRepro & " | cut -d' ' -f1").strip()
    let good = "http://127.0.0.1:" & $Port & "/"
    # The pre-floor engine bootstraps and applies the first generation.
    if not g.bootstrapAddon(oldRepro, step): return fails
    var r = g.applyProfile(oldRepro, "pre", profile(service("page-pre"), good))
    step("the pre-floor engine applies generation 1", r.exitCode == 0,
         r.stdout & r.stderr)
    step("generation 1 serves its page", g.served() == "page-pre", "")
    let shaPre = g.unitSha()
    let genPre = g.run("readlink /var/lib/repro/system/current").strip()
    record["preFloorUnitSha256"] = %shaPre
    step("the pre-floor unit carries no floor",
         "NoExecPaths" notin g.run("cat " & UnitPath), "")
    # 1. H1: no wedge.
    let fixed = profile(service("page-fixed"), good,
      "  floorExceptions = [\"" & PythonException & "\"]\n")
    let pf = g.exec(repro & " infra plan --profile " &
      g.putProfile("fixed", fixed), timeoutSec = 1200)
    step("the upgraded engine plans the fixed profile over the stored " &
         "pre-floor generation", pf.exitCode == 0, pf.stdout & pf.stderr)
    let pu = g.exec(repro & " infra plan --profile " &
      g.putProfile("unfixed", profile(service("page-pre"), good)),
      timeoutSec = 1200)
    step("the unfixed profile is refused for its own unit, by the floor",
         pu.exitCode != 0 and "outside the unit's closure" in
           pu.stdout & pu.stderr, pu.stdout & pu.stderr)
    # 2. H2: a floored generation fails its confirm; the revert restores
    # the pre-floor unit exactly.
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
    step("the revert restores the pre-floor unit byte for byte",
         g.unitSha() == shaPre, g.run("cat " & UnitPath))
    step("the pre-floor service serves again", g.served() == "page-pre", "")
    # 3. The fixed profile applies, with its exception.
    r = g.applyProfile(repro, "fixed", fixed)
    step("the fixed profile applies under the floor", r.exitCode == 0,
         r.stdout & r.stderr)
    step("its unit carries the floor and the exception",
         "ProtectSystem=strict" in g.run("cat " & UnitPath) and
         "# serviceFloor exception: NoExecPaths" in g.run("cat " & UnitPath),
         "")
    step("the fixed service serves", g.served() == "page-fixed", "")
    step("the plan names the exception", PythonException in r.stdout, "")
    # 4. Rollback to the pre-floor generation.
    let rb = g.exec(repro & " system rollback " & extractFilename(genPre),
                    timeoutSec = 1200)
    step("rollback to the pre-floor generation succeeds", rb.exitCode == 0,
         rb.stdout & rb.stderr)
    step("the rollback restores the pre-floor unit byte for byte",
         g.unitSha() == shaPre, g.run("cat " & UnitPath))
    step("and its service serves", g.served() == "page-pre", "")
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
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "preFloorArtefact": getEnv("REPRO_ADDON_PRE_FLOOR_ARTEFACT"),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
