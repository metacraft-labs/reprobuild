## ``repro test`` reads a fragment-less project path as that project's
## ``test`` collection.
##
## WHY. ``repro test [args]`` is ``repro build test [args]``, so in
## ``repro test ./sub`` the path says which project's ``test`` runs. The
## selectors used to reach the build unchanged, and ``repro build ./sub``
## selects ``sub``'s graph minus its ``test`` collection: the unsharded run
## built that, ran no test and exited 0. ``testCollectionOfPath`` is the one
## place the rewrite is made; this test pins what it rewrites and what it
## leaves alone.
##
## HOW. A real temporary directory, entered as the working directory, holding
## a project ``sub/`` (``repro.nim`` beside a ``test.nim`` module, the shape
## in which ``sub#test`` would be the legacy ``<dir>#<module>`` form), a
## legacy-named project ``old/`` (``reprobuild.nim``), a directory ``bare/``
## with no project file, and a plain module file ``tool.nim``. The real
## function and the real ``parseBuildTarget`` the build reads anchors with.
## No mocks. ``{.all.}`` and ``privateAccess`` reach the module-private
## ``parseBuildTarget``.

import std/[importutils, os, tempfiles, unittest]

import repro_cli_support {.all.}

privateAccess(ParsedBuildTarget)

suite "repro test reads a project path as its test collection":

  let previousDir = getCurrentDir()
  let root = createTempDir("repro-test-project-path-", "")
  createDir(root / "sub")
  writeFile(root / "sub" / "repro.nim", "discard\n")
  writeFile(root / "sub" / "test.nim", "discard\n")
  createDir(root / "old")
  writeFile(root / "old" / "reprobuild.nim", "discard\n")
  createDir(root / "bare")
  writeFile(root / "repro.nim", "discard\n")
  writeFile(root / "tool.nim", "discard\n")
  setCurrentDir(root)

  test "a project directory selects its test collection on its project file":
    check testCollectionOfPath("./sub") == ("./sub" / "repro.nim") & "#test"
    check testCollectionOfPath("sub/") == ("sub/" / "repro.nim") & "#test"
    check testCollectionOfPath(".") == ("." / "repro.nim") & "#test"
    check testCollectionOfPath("./old") ==
      ("./old" / "reprobuild.nim") & "#test"
    # The build reads the rewritten anchor as the ``test`` action of the
    # project, not as the ``test.nim`` module beside it.
    let parsed = parseBuildTarget(testCollectionOfPath("./sub"))
    check parsed.fragmentKind == tfkActionSelection
    check parsed.selectedActionId == "test"
    check parsed.modulePath == "./sub" / "repro.nim"

  test "a project file path selects its test collection":
    check testCollectionOfPath("./sub/repro.nim") == "./sub/repro.nim#test"
    check testCollectionOfPath("old/reprobuild.nim") ==
      "old/reprobuild.nim#test"

  test "a directory with no project file is anchored on the file it would hold":
    # So a Mode-1 workspace still resolves, and anything else reports the
    # missing project file.
    check testCollectionOfPath("./bare") == ("./bare" / "repro.nim") & "#test"

  test "every other selector is left as written":
    for sel in ["test", "unit-suite", "sib:suite", "./sub#test",
        "./sub#unit", ".#test#unit", "./tool.nim", "./absent",
        "unit.a"]:
      check testCollectionOfPath(sel) == sel
    check testCollectionSelectors(["./sub", "unit-suite"]) ==
      @[("./sub" / "repro.nim") & "#test", "unit-suite"]
    check testCollectionSelectors(newSeq[string]()).len == 0

  setCurrentDir(previousDir)
  removeDir(root)
