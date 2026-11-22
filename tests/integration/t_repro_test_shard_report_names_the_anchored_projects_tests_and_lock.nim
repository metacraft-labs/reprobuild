## A sharded ``repro test`` resolves its selectors the way an unsharded one
## does (CI-Sharding.md §"CLI Surface": the sharding flags "compose with the
## existing ``repro test`` selectors (named targets, paths, fragments)"), and
## its report records the lock of the project those selectors anchor on, the
## lock each assigned command's build pins (CLI/build.md §"Target Selection").
##
## ``app`` declares three test edges, ``unit_a``, ``unit_b`` and ``side``, a
## collection ``unit-suite`` (``unit_a`` + ``unit_b``) and an
## ``aggregate("test", ...)`` over all three, and commits its ``repro.lock``.
## Its ``sub/`` directory is a project of its own with two test edges,
## ``sub_a`` and ``sub_b``, an ``aggregate("test", ...)`` over them and its
## own committed ``sub/repro.lock``. From ``app``:
##
##   1. ``repro test --shard 1/1 unit-suite``: the report lists exactly the
##      collection's two test commands (not an action id, so a plan that
##      matched selectors against action ids would select nothing) and names
##      ``app/repro.lock``;
##   2. ``repro test --shard 1/1 ./sub#test``: the selector anchors on the
##      ``sub`` project, the report lists exactly ``sub``'s two test
##      commands, only ``sub``'s edges ran, and the report names
##      ``app/sub/repro.lock`` with that lock's ``inputs_digest``, not the
##      current directory's lock (the lock each assigned command's build
##      ``./sub#<action id>`` pins);
##   3. a selector that names nothing exits 2 and runs nothing, and so does
##      the fragment-less ``./sub``: by the build's rule it selects ``sub``'s
##      graph minus its ``test`` collection, which holds no test command
##      (CI-Sharding.md §"CLI Surface": refused, exit 2, not an empty green
##      shard).
##
## Runs with ``--no-certify``: what is under test is selection and the lock
## provenance, not issuance (``t_repro_test_shard_certifies_only_nodes_it_ran_whole``
## covers that).
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the real
## provider, engine and filesystem monitor, and locks written by ``repro lock
## refresh``. Skip rule: ``git`` or ``ssh-keygen`` missing (the shared
## fixture registers a signing key).

import std/[algorithm, json, os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import repro_lock
import ./certify_workspace_mode_fixture

const buildLines =
  "    discard aggregate(\"unit-suite\", @[unit_a, unit_b])\n" &
  "    discard aggregate(\"test\", @[unit_a, side, unit_b])\n"

proc subEdge(stem: string): string =
  "    let " & stem & " = certTool(actionId = \"" & stem & "\",\n" &
    "      input = \"src/" & stem & ".txt\",\n" &
    "      output = \"build/" & stem & "-out\",\n" &
    "      marker = \".repro/runs.log\")\n"

proc reportTestIds(report: JsonNode): seq[string] =
  for entry in report["tests"].elems:
    result.add(entry["id"].getStr())
  result.sort()

proc lockDigest(path: string): string =
  parseSolvedGraphLock(readFile(path)).inputsDigest

suite "a sharded repro test anchors on its selectors":

  test "t_repro_test_shard_report_names_the_anchored_projects_tests_and_lock":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; the shared fixture builds real " &
        "repositories and registers a signing key")
    else:
      var fx = setupWorkspaceCertifyFixture("shard-anchor",
        ["unit_a", "side", "unit_b"], buildLines)
      defer: removeDir(fx.cf.sib.scratch)
      let appLock = fx.app / "repro.lock"
      check fileExists(appLock)

      # ---- the nested project, with its own tests and committed lock -------
      let sub = fx.app / "sub"
      createDir(sub / "src")
      createDir(sub / "reprobuild" / "packages")
      copyFile(fx.app / "reprobuild" / "packages" / "cert_tool.nim",
        sub / "reprobuild" / "packages" / "cert_tool.nim")
      for stem in ["sub_a", "sub_b"]:
        writeFile(sub / "src" / (stem & ".txt"), stem & " v1\n")
      writeFile(sub / "repro.nim",
        "import repro_project_dsl\n\n" &
        "package sub:\n" &
        "  usesImportPath \"reprobuild/packages\"\n" &
        "  uses:\n" &
        "    \"cert-tool >=1.0 <2.0\"\n\n" &
        "  build:\n" & subEdge("sub_a") & subEdge("sub_b") &
        "    discard aggregate(\"test\", @[sub_a, sub_b])\n")
      writeFile(sub / ".gitignore", ".repro/\nbuild/\n")
      let refresh = fx.reproIn(["lock", "refresh", "sub"])
      checkpoint(refresh.output)
      check refresh.code == 0
      let subLock = sub / "repro.lock"
      check fileExists(subLock)
      discard fx.cf.gitIn(fx.app, "add -A")
      discard fx.cf.gitIn(fx.app, "commit -q -m sub-project")
      discard fx.cf.gitIn(fx.app, "push -q origin main")
      # The two locks differ, so a report naming the wrong one is caught by
      # its digest as well as by its path.
      check lockDigest(subLock).len > 0
      check lockDigest(subLock) != lockDigest(appLock)

      # ---- 1. a collection name selects the collection's test commands -----
      let report1 = fx.cf.sib.scratch / "shard-suite.json"
      let suiteRun = fx.reproIn(["test", "--tool-provisioning=path",
        "--no-certify", "--shard", "1/1", "--write-report=" & report1,
        "unit-suite"])
      checkpoint(suiteRun.output)
      check suiteRun.code == 0
      let r1 = parseJson(readFile(report1))
      check r1["mode"].getStr() == "workspace"
      check reportTestIds(r1) == @["unit_a", "unit_b"]
      check r1["test_pass_count"].getInt() == 2
      check r1["test_fail_count"].getInt() == 0
      check r1["lock_file"].getStr() == appLock
      check r1["locked_inputs_digest"].getStr() == lockDigest(appLock)

      # ---- 2. a path selector anchors the shard on that project ------------
      let report2 = fx.cf.sib.scratch / "shard-sub.json"
      let subRun = fx.reproIn(["test", "--tool-provisioning=path",
        "--no-certify", "--shard", "1/1", "--write-report=" & report2,
        "./sub#test"])
      checkpoint(subRun.output)
      check subRun.code == 0
      let r2 = parseJson(readFile(report2))
      check reportTestIds(r2) == @["sub_a", "sub_b"]
      check r2["test_pass_count"].getInt() == 2
      check r2["test_fail_count"].getInt() == 0
      # Only sub's edges ran in sub's tree.
      var subRan: seq[string]
      let subLog = sub / ".repro" / "runs.log"
      if fileExists(subLog):
        for line in readFile(subLog).splitLines():
          if line.strip().len > 0:
            subRan.add(line.strip().extractFilename)
      subRan.sort()
      check subRan == @["sub_a-out", "sub_b-out"]
      check r2["lock_file"].getStr() == subLock
      check r2["locked_inputs_digest"].getStr() == lockDigest(subLock)

      # ---- 3. a selector that names nothing is refused, not a green shard --
      let before = fx.executedOutputs().len
      let unknown = fx.reproIn(["test", "--tool-provisioning=path",
        "--no-certify", "--shard", "1/1", "no-such-suite"])
      checkpoint(unknown.output)
      check unknown.code == 2
      check "no-such-suite" in unknown.output
      check fx.executedOutputs().len == before
      let subOnly = fx.reproIn(["test", "--tool-provisioning=path",
        "--no-certify", "--shard", "1/1", "./sub"])
      checkpoint(subOnly.output)
      check subOnly.code == 2
      check "names no test command" in subOnly.output
      check fx.executedOutputs().len == before
