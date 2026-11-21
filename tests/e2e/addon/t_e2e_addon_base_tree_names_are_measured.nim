## Gate ``e2e_addon_base_tree_names_are_measured`` (milestone A9, review
## round 10, finding 5; spec §10.1, §13 decisions 57 and 69).
##
## ``service_floor.BaseSystemTreeNames`` is the union of the names each
## supported test-bed base has directly under ``/etc``, ``/run``,
## ``/var/lib``, ``/var/cache`` and ``/var/log``. This gate is how the list
## was measured, and how it is measured again: it boots each selected base
## as the test bed prepares it (no add-on), lists those five roots
## (``ls -1A``), and fails when the base has a name the list does not hold.
## With ``REPRO_ADDON_WRITE_BASE_TREES=<dir>`` it also writes each base's
## listing as ``<dir>/<base>.txt``, the form of the fixtures in
## ``libs/repro_addon/tests/fixtures/base_trees`` that
## ``t_addon_floor_round9`` holds the list to.
##
## The list is advisory beyond the bases measured (decision 69): Raspberry
## Pi OS and the arm64 and armhf images of the decided matrix are not test-
## bed images, and on them the existence check of every apply is the
## guard.
##
## *Mocking.* None: the real base images, booted.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_infra/service_floor

import ./addon_testbed

const
  Gate = "e2e_addon_base_tree_names_are_measured"
  Roots = ["/etc", "/run", "/var/lib", "/var/cache", "/var/log"]

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
    var text = "# ls -1A of each root on " & b.name & " as the test bed " &
      "prepares it (" & Gate & ", " & $now().utc & ")\n"
    var missing: seq[string]
    for root in Roots:
      let r = g.exec("ls -1A " & root)
      step("lists " & root, r.exitCode == 0, r.stderr)
      for name in r.stdout.splitLines():
        let n = name.strip()
        if n.len == 0: continue
        text.add(root & "\t" & n & "\n")
        # Dot-files are no unit's or directory's name (the list leaves them out).
        if not n.startsWith(".") and n notin BaseSystemTreeNames and
            n notin missing:
          missing.add(n)
    record["missing"] = %missing
    step("every name the base has is on the list", missing.len == 0,
         missing.join(" "))
    let outDir = getEnv("REPRO_ADDON_WRITE_BASE_TREES")
    if outDir.len > 0:
      createDir(outDir)
      writeFile(outDir / (b.name & ".txt"), text)
      record["written"] = %(outDir / (b.name & ".txt"))
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
  test "every base tree name of each test-bed base is on the floor's list":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
