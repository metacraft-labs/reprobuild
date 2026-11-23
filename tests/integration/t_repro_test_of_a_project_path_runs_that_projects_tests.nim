## ``repro test <path>`` runs the ``test`` collection of the project the path
## anchors, sharded or not.
##
## ``repro test [args]`` is ``repro build test [args]``, so ``repro test
## ./sub`` is ``./sub``'s ``test`` collection. The selectors used to reach the
## build as written, and ``repro build ./sub`` selects ``sub``'s graph minus
## its ``test`` collection: the unsharded run ran no test and exited 0 — a CI
## step ``repro test ./sub`` was green without running a test — while the
## sharded run refused the same selection as naming no test command.
##
## ``app`` declares three test edges and ``aggregate("test", ...)`` over
## them. Its ``sub/`` directory is a project with two test edges, ``sub_a``
## and ``sub_b``, an ``aggregate("test", ...)`` over them, and a ``test.nim``
## module beside its ``repro.nim`` (where ``./sub#test`` would be the legacy
## ``<dir>#<module>`` form, so the path must be anchored on the project
## file). From ``app``:
##
##   1. ``repro test --no-certify ./sub`` runs exactly ``sub_a`` and
##      ``sub_b`` and exits 0. Before the fix it exited 0 having run nothing;
##   2. ``repro test --no-certify --shard 1/1 ./sub`` runs and reports the
##      same two test commands. Before the fix it exited 2, "the selection
##      names no test command";
##   3. the certifying ``repro test ./sub`` (the default) runs them as well;
##   4. ``repro test --no-certify ./sub/repro.nim``, the project file
##      spelled out, runs them too;
##   5. ``repro test --no-certify .`` runs ``app``'s own three tests and none
##      of ``sub``'s.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the real
## provider, engine and filesystem monitor. Skip rule: ``git`` or
## ``ssh-keygen`` missing (the shared fixture registers a signing key).

import std/[algorithm, json, os, strutils, unittest]
import repro_test_support/reasoned_skip
import ./certify_workspace_mode_fixture

const buildLines =
  "    discard aggregate(\"test\", @[unit_a, side, unit_b])\n"

proc subEdge(stem: string): string =
  "    let " & stem & " = certTool(actionId = \"" & stem & "\",\n" &
    "      input = \"src/" & stem & ".txt\",\n" &
    "      output = \"build/" & stem & "-out\",\n" &
    "      marker = \".repro/runs.log\")\n"

proc ranIn(dir: string): seq[string] =
  ## The outputs the tool wrote in ``dir``'s tree, by file name, sorted.
  let log = dir / ".repro" / "runs.log"
  if fileExists(log):
    for line in readFile(log).splitLines():
      if line.strip().len > 0:
        result.add(line.strip().extractFilename)
  result.sort()

proc rerunnable(fx: WorkspaceCertifyFixture; sub: string; version: int) =
  ## Change ``sub``'s test inputs, committed and pushed, and forget what ran,
  ## so the next run executes both tests again instead of reusing a cached
  ## result, in a clean tree a certifying run may issue in.
  for stem in ["sub_a", "sub_b"]:
    writeFile(sub / "src" / (stem & ".txt"), stem & " v" & $version & "\n")
  discard fx.cf.gitIn(fx.app, "add -A")
  discard fx.cf.gitIn(fx.app, "commit -q -m inputs-v" & $version)
  discard fx.cf.gitIn(fx.app, "push -q origin main")
  removeFile(sub / ".repro" / "runs.log")
  removeFile(fx.app / ".repro" / "runs.log")

suite "repro test of a project path runs that project's tests":

  test "t_repro_test_of_a_project_path_runs_that_projects_tests":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; the shared fixture builds real " &
        "repositories and registers a signing key")
    else:
      var fx = setupWorkspaceCertifyFixture("project-path",
        ["unit_a", "side", "unit_b"], buildLines)
      defer: removeDir(fx.cf.sib.scratch)

      # ---- the nested project ---------------------------------------------
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
      # The module ``./sub#test`` would select in the legacy form.
      writeFile(sub / "test.nim", "echo \"not the test collection\"\n")
      writeFile(sub / ".gitignore", ".repro/\nbuild/\n")
      let refresh = fx.reproIn(["lock", "refresh", "sub"])
      checkpoint(refresh.output)
      check refresh.code == 0
      discard fx.cf.gitIn(fx.app, "add -A")
      discard fx.cf.gitIn(fx.app, "commit -q -m sub-project")
      discard fx.cf.gitIn(fx.app, "push -q origin main")

      # ---- 1. unsharded: the path runs sub's test collection --------------
      let plain = fx.reproIn(["test", "--tool-provisioning=path",
        "--no-certify", "./sub"])
      checkpoint(plain.output)
      check plain.code == 0
      check ranIn(sub) == @["sub_a-out", "sub_b-out"]
      check fx.executedOutputs().len == 0

      # ---- 2. sharded: the same selection, the same test commands ---------
      rerunnable(fx, sub, 2)
      let report = fx.cf.sib.scratch / "shard-sub.json"
      let sharded = fx.reproIn(["test", "--tool-provisioning=path",
        "--no-certify", "--shard", "1/1", "--write-report=" & report,
        "./sub"])
      checkpoint(sharded.output)
      check sharded.code == 0
      check "names no test command" notin sharded.output
      check ranIn(sub) == @["sub_a-out", "sub_b-out"]
      if fileExists(report):
        var ids: seq[string]
        for entry in parseJson(readFile(report))["tests"].elems:
          ids.add(entry["id"].getStr())
        ids.sort()
        check ids == @["sub_a", "sub_b"]
      else:
        checkpoint("no shard report at " & report)
        check false

      # ---- 3. the certifying run selects the same collection --------------
      rerunnable(fx, sub, 3)
      let certifying = fx.reproIn(["test", "--tool-provisioning=path",
        "./sub"])
      checkpoint(certifying.output)
      check certifying.code == 0
      check ranIn(sub) == @["sub_a-out", "sub_b-out"]

      # ---- 4. the project file spelled out --------------------------------
      rerunnable(fx, sub, 4)
      let fileSpelled = fx.reproIn(["test", "--tool-provisioning=path",
        "--no-certify", "./sub/repro.nim"])
      checkpoint(fileSpelled.output)
      check fileSpelled.code == 0
      check ranIn(sub) == @["sub_a-out", "sub_b-out"]

      # ---- 5. ``.`` is the current project's test collection --------------
      rerunnable(fx, sub, 5)
      let here = fx.reproIn(["test", "--tool-provisioning=path",
        "--no-certify", "."])
      checkpoint(here.output)
      check here.code == 0
      var appRan: seq[string]
      for output in fx.executedOutputs():
        appRan.add(output.extractFilename)
      appRan.sort()
      check appRan == @["side-out", "unit_a-out", "unit_b-out"]
      check ranIn(sub).len == 0
