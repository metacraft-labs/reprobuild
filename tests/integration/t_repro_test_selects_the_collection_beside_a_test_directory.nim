## ``repro test`` selects the project's ``test`` collection even when the
## project also has a ``test/`` directory (CLI/test.md §"Alias Semantics";
## reprobuild-pm issue 2026-11-06 "repro test resolves to a test directory
## instead of the test collection").
##
## ``classifyBuildSelector`` used to take a bare name that also named an
## existing path as a path, and most projects keep their tests in ``test/``.
## The alias therefore selects the collection as ``.#test``, and the
## certifying run hands its build the resolved selector, not the bare name.
## Since reprobuild-pm issue 2026-11-12 "classifying a selector by whether a
## path exists makes repro test build the test directory", a bare name is a
## name whatever the disk holds (CLI/build.md §"Target Selection" step 1), so
## ``repro build test`` selects the collection as well and the directory is
## spelled ``./test``. ``app`` declares ``aggregate("test", @[unit_a])`` and
## carries a committed ``test/`` directory holding a file. In order:
##
##   1. a plain ``repro test`` runs ``unit_a`` and issues ``targets =
##      ["test"]``. Before the fix it failed with "build target module not
##      found: …/test/reprobuild.nim" and certified nothing;
##   2. ``repro test --no-certify`` runs the collection without issuing;
##   3. an explicit ``repro test .#test`` (certifying) succeeds as well; before
##      the fix the certifying build re-added the bare name ``test`` and hit
##      the directory again;
##   4. ``repro build test`` selects the collection too. Before the 2026-11-12
##      fix it built the directory and failed with "build target module not
##      found: …/test/reprobuild.nim";
##   5. ``repro build ./test`` still names the directory: a path is spelled as
##      one;
##   6. a bare name that names no target but does name a directory
##      (``docs``) fails with ``unknown_target`` and names the ``./docs``
##      spelling.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the real
## provider, engine and monitor. Skip rule: ``git`` or ``ssh-keygen`` missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./certify_workspace_mode_fixture

const buildLines =
  "    discard aggregate(\"test\", @[unit_a])\n"

suite "repro test beside a test/ directory":

  test "t_repro_test_selects_the_collection_beside_a_test_directory":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      var fx = setupWorkspaceCertifyFixture("test-dir-shadow", ["unit_a"],
        buildLines)
      defer: removeDir(fx.cf.sib.scratch)
      let app = fx.app
      # The directory a bare ``test`` selector would resolve to.
      createDir(app / "test")
      writeFile(app / "test" / "helper.rb", "# a test helper\n")
      discard fx.cf.gitIn(app, "add test/helper.rb")
      discard fx.cf.gitIn(app, "commit -q -m test-dir")
      discard fx.cf.gitIn(app, "push -q origin main")
      check dirExists(app / "test")
      let content = fx.contentNow()

      # ---- 1. a plain, certifying repro test ---------------------------
      let plain = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint(plain.output)
      check plain.code == 0
      check "build target module not found" notin plain.output
      check fx.executedOutputs().len == 1
      check fx.certificatesFor(content, "test").len == 1
      check "issued test-certificate.v1 for 'test'" in plain.output

      # ---- 2. --no-certify -----------------------------------------------
      let quiet = fx.reproIn(["test", "--no-certify",
        "--tool-provisioning=path"])
      checkpoint(quiet.output)
      check quiet.code == 0
      check "build target module not found" notin quiet.output

      # ---- 3. an explicit .#test, certifying -----------------------------
      writeFile(app / "src" / "unit_a.txt", "unit_a v2\n")
      discard fx.cf.gitIn(app, "commit -q -am edit")
      let edited = fx.contentNow()
      let explicit = fx.reproIn(["test", "--tool-provisioning=path",
        ".#test"])
      checkpoint(explicit.output)
      check explicit.code == 0
      check "build target module not found" notin explicit.output
      check fx.certificatesFor(edited, "test").len == 1

      # ---- 4. repro build test selects the collection --------------------
      writeFile(app / "src" / "unit_a.txt", "unit_a v3\n")
      discard fx.cf.gitIn(app, "commit -q -am edit-again")
      let ranBefore = fx.executedOutputs().len
      let build = fx.reproIn(["build", "--tool-provisioning=path", "test"])
      checkpoint(build.output)
      check build.code == 0
      check fx.executedOutputs().len == ranBefore + 1
      check "build target module not found" notin build.output
      check "test" & DirSep & "reprobuild.nim" notin build.output
      check "test/reprobuild.nim" notin build.output

      # ---- 5. repro build ./test names the directory ---------------------
      let path = fx.reproIn(["build", "--tool-provisioning=path", "./test"])
      checkpoint(path.output)
      check path.code != 0
      check "test" & DirSep & "reprobuild.nim" in path.output or
        "test/reprobuild.nim" in path.output

      # ---- 6. a bare name beside a directory, naming no target -----------
      createDir(app / "docs")
      writeFile(app / "docs" / "index.md", "# docs\n")
      let docs = fx.reproIn(["build", "--tool-provisioning=path", "docs"])
      checkpoint(docs.output)
      check docs.code == 2
      check "unknown_target: no build target matches 'docs'" in docs.output
      check "spell it './docs'" in docs.output
      check "docs" & DirSep & "reprobuild.nim" notin docs.output
      check "docs/reprobuild.nim" notin docs.output
