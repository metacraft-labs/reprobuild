## A bare selector is a name even beside a file or directory of that name
## (reprobuild-pm CLI/build.md §"Target Selection"; reprobuild-pm issue
## 2026-11-12 "classifying a selector by whether a path exists makes repro
## test build the test directory").
##
## WHY. ``classifyBuildSelector`` used to take a bare name that also named an
## existing path as a path, so what ``repro build test`` meant depended on the
## contents of the current directory: a project with a ``test/``, ``bench/``
## or ``docs/`` directory — common layouts — silently built the directory
## instead of the collection. The rule is now spelling alone: a bare name is
## a name, a path is spelled as one (``./test``). The ``unknown_target``
## diagnostic offers the ``./<name>`` spelling when a bare name matches no
## target but does match a path, so the user who meant the directory is told
## how to select it.
##
## HOW. A real temporary directory holding a ``test/`` directory, a ``docs/``
## directory and a ``bench`` file, entered as the working directory; the
## real classifier, resolver front end and diagnostic renderer. No mocks.

import std/[os, strutils, tempfiles, unittest]

import repro_cli_support

suite "a bare selector is a name beside a same-named path":

  let previousDir = getCurrentDir()
  let root = createTempDir("bare-selector-beside-path-", "")
  createDir(root / "test")
  writeFile(root / "test" / "helper.nim", "discard\n")
  createDir(root / "docs")
  writeFile(root / "bench", "not a target\n")
  setCurrentDir(root)

  test "a bare name is classified as a name whatever the disk holds":
    for name in ["test", "docs", "bench", "absent"]:
      checkpoint(name)
      let classified = classifyBuildSelector(name)
      check classified.kind == bskName
      check classified.name == name

  test "a path is spelled as a path":
    for raw in ["./test", "test/", "./bench", "docs/x.nim", ".#test"]:
      checkpoint(raw)
      check classifyBuildSelector(raw).kind == bskPath

  test "a bare test beside test/ selects the current project's test target":
    let resolved = parseAndResolveSelectors(["test"], "repro build")
    check resolved.target == ".#test"
    check resolved.extraNameSelectors.len == 0

  test "./test beside test/ anchors the build at the directory":
    let resolved = parseAndResolveSelectors(["./test"], "repro build")
    check resolved.target == "./test"

  test "unknown_target names the ./ spelling when a path of that name exists":
    var err = BuildTargetUnknownError(selectorName: "docs")
    let text = renderUnknownTargetDiagnostic(err)
    checkpoint(text)
    check "no build target matches 'docs'" in text
    check "spell it './docs'" in text
    err.selectorName = "bench"
    check "spell it './bench'" in renderUnknownTargetDiagnostic(err)

  test "unknown_target offers no path spelling when no such path exists":
    let err = BuildTargetUnknownError(selectorName: "absent",
      suggestions: @["bench"])
    let text = renderUnknownTargetDiagnostic(err)
    checkpoint(text)
    check "did you mean" in text
    check "spell it" notin text
    check pathSpellingHint("absent") == ""
    # A selector that already carries a path character was a path; the
    # hint is only for a bare name.
    check pathSpellingHint("test#unit") == ""
    check pathSpellingHint("pkg:test") == ""

  setCurrentDir(previousDir)
  removeDir(root)
