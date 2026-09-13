import std/[os, tempfiles, unittest]

import repro_cli_support

suite "same-project fragment selection":
  var root, project, other, previousDir: string

  setup:
    previousDir = getCurrentDir()
    root = createTempDir("repro-fragment-selectors-", "")
    project = root / "project"
    other = root / "other"
    createDir(project)
    createDir(other)
    writeFile(project / "repro.nim", "discard\n")
    writeFile(other / "repro.nim", "discard\n")
    setCurrentDir(project)

  teardown:
    setCurrentDir(previousDir)
    removeDir(root)

  test "omitted targets retain default selection":
    let selected = parseAndResolveSelectors([], "repro build")
    check selected.targetWasOmitted
    check selected.target == ""
    check selected.extraNameSelectors.len == 0

  test "named target union remains unchanged":
    let selected = parseAndResolveSelectors(["alpha", "beta"], "repro build")
    check selected.target == ".#alpha"
    check selected.extraNameSelectors == @["beta"]
    check not selected.targetWasOmitted

  test "two collection members share one project anchor":
    let selected = parseAndResolveSelectors([".#test#alpha", ".#test#beta"], "repro build")
    check selected.target == ".#test#alpha"
    check selected.extraNameSelectors == @["test#beta"]

  test "relative and absolute spellings resolve to the same project":
    let selected = parseAndResolveSelectors(["./#test#alpha", project & "#test#beta"], "repro build")
    check selected.target == "./#test#alpha"
    check selected.extraNameSelectors == @["test#beta"]

  test "duplicate member selectors do not add another closure":
    let selected = parseAndResolveSelectors(
      [".#test#alpha", "./#test#alpha", ".#test#beta", "./#test#beta"], "repro build")
    check selected.target == ".#test#alpha"
    check selected.extraNameSelectors == @["test#beta"]

  test "fragment selectors compose with names in either position":
    let selected = parseAndResolveSelectors(
      ["gamma", ".#test#alpha", ".#test#beta", "delta"], "repro build")
    check selected.target == ".#test#alpha"
    check selected.extraNameSelectors == @["test#beta", "delta", "gamma"]

  test "watch uses the same collection member union":
    let selected = parseAndResolveSelectors([".#test#alpha", ".#test#beta"], "repro watch")
    check selected.target == ".#test#alpha"
    check selected.extraNameSelectors == @["test#beta"]

  test "different projects are still rejected":
    expect ValueError:
      discard parseAndResolveSelectors([".#test#alpha", other & "#test#beta"], "repro build")

  test "different legacy module fragments are still rejected":
    writeFile(project / "alpha.nim", "discard\n")
    writeFile(project / "beta.nim", "discard\n")
    expect ValueError:
      discard parseAndResolveSelectors([".#alpha", ".#beta"], "repro build")

  test "unselected second roots cannot silently widen a selection":
    expect ValueError:
      discard parseAndResolveSelectors([".#test#alpha", "."], "repro build")
