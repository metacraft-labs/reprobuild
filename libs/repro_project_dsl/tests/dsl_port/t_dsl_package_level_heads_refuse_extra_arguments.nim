## The package-level section HEADS whose arity is fixed refuse an extra
## argument, anchored on the offending token and naming it verbatim.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every case compiles a real recipe module with the real ``nim`` this
## repo is built with and asserts on its real output. See
## ``service_block_compile_probe.nim`` for why the in-process
## ``compiles`` spelling cannot be used here (short version: measured, it
## answers *false* for every ``package`` block — well-formed or not — so
## both a refusal and its control would be vacuous).
##
## The defect, filed as ``reprobuild-pm/issues/2026-10-08-package-level-
## dsl-heads-and-bodies-silently-drop-arguments.md`` and measured again at
## reprobuild ``27e6fb94``: seven package-level heads ACCEPTED AND
## DISCARDED an argument written beside them. Every walker that reads
## these sections reads the block body at ``stmt[^1]`` (or the name at
## ``stmt[1]``) and never looks at the children in between, so
## ``executable probeBin, junkIdentB:`` lowered exactly as
## ``executable probeBin:`` would, and ``junkIdentB`` — an identifier that
## exists nowhere — was never semchecked. Each refusal case below compiled
## with ZERO errors at ``27e6fb94``, so each one's ``not probe.ok`` failed
## there and is load-bearing, not vacuous.
##
## Only the HEAD half of that issue is pinned here. The BODY half — an
## unrecognised statement inside one of these bodies — awaits a design
## ruling (a package-level ``config:`` / ``discard`` body is a deliberate
## no-op in hundreds of recipes) and is deliberately left untested.
##
## Governing text: ``macros_b.nim``'s ``dslHeadArgumentDropRule`` — "An
## extra argument here is REFUSED rather than dropped: it is never
## semchecked, so an identifier that does not exist compiles clean …" —
## and ``Package-Model.md`` ("Lowerings that cannot honor a particular
## trigger should fail at lock time with a clear error rather than
## silently dropping it").
##
## Every refusal is a one-line edit to ONE well-formed recipe, and that
## recipe's own compile is the first test in the file. Each edit is
## checked to have changed the source (a drifted needle would otherwise
## turn a refusal into a second run of the control), and each refusal
## asserts on the DIAGNOSTIC — the offending identifier verbatim and the
## line/column of that identifier — not only on the exit code.

import std/[strutils, unittest]

import ./service_block_compile_probe

const WellFormed = """
import repro_project_dsl

package probeRecipe:
  config:
    issuer: string = "http://localhost:8080"

  executable probeBin:
    build:
      output("bin/probe")

  executable bareBin

  library myLib:
    build:
      output("lib/libmy.a")

  files myFiles:
    build:
      output("share/data.txt")

  versions:
    discard

  build:
    discard

  devEnv:
    activity "default"
"""
  ## Every head under test in its legal shape, including the two legal
  ## shapes of an artifact head (``executable bareBin`` with no body, and
  ## ``executable probeBin:`` with one) and a nested ``build:`` in each
  ## of the three artifact kinds.

proc editedSource(needle, replacement: string): string =
  ## One-line edit to ``WellFormed``. Raises rather than returning a
  ## misleading result when the needle is not present exactly once, so a
  ## drifted fixture is a red test and not a silently vacuous one.
  if WellFormed.count(needle) != 1:
    raise newException(ValueError,
      "fixture drift: WellFormed does not contain exactly one " & needle)
  result = WellFormed.replace(needle, replacement)
  doAssert result != WellFormed

proc anchorTag(source, token: string): string =
  ## The ``recipe.nim(<line>, <column>)`` prefix Nim prints for the FIRST
  ## occurrence of ``token`` in ``source``. Computed from the generated
  ## source rather than hard-coded so an unrelated fixture edit does not
  ## turn into an anchor failure; what is under test is that the refusal
  ## points at the offending token and not at the head before it.
  var lineNo = 0
  for line in source.splitLines():
    inc lineNo
    let column = line.find(token)
    if column >= 0:
      return "recipe.nim(" & $lineNo & ", " & $(column + 1) & ")"
  raise newException(ValueError,
    "fixture drift: the generated source has no `" & token & "`")

proc refusal(needle, replacement, junk, tag: string):
    tuple[probe: ServiceCompileProbeResult; source: string] =
  let source = editedSource(needle, replacement)
  doAssert source.count(junk) == 1,
    "the offending token must be unique in the fixture: " & junk
  result.source = source
  result.probe = checkRecipeSource(source, tag)

const NoSilentDrop = "An extra argument here is REFUSED rather than dropped"

suite "package-level heads refuse an argument they would have dropped":
  test "control: the well-formed recipe compiles":
    let probe = checkRecipeSource(WellFormed, "pkg-heads-control")
    checkpoint(probe.output)
    check probe.ok

  test "`config junkIdentA:` at package level":
    # The case the issue names first: the same text one level down,
    # inside an activity, was already refused by `l2ParseActivityConfig`.
    let (probe, source) = refusal("  config:", "  config junkIdentA:",
      "junkIdentA", "pkg-heads-config")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`config:` takes no arguments")
    check probe.mentions("`junkIdentA` is written on its head")
    check probe.mentions("package `probeRecipe`")
    check probe.mentions(NoSilentDrop)
    check probe.mentions(anchorTag(source, "junkIdentA"))

  test "`executable probeBin, junkIdentB:`":
    let (probe, source) = refusal("executable probeBin:",
      "executable probeBin, junkIdentB:", "junkIdentB", "pkg-heads-exe")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`executable <name>:` takes one name")
    check probe.mentions("`junkIdentB` beside the head of " &
      "`executable probeBin:`")
    check probe.mentions(NoSilentDrop)
    check probe.mentions(anchorTag(source, "junkIdentB"))

  test "`executable bareBin, junkIdentE` — the body-less form":
    # The bare form's legal arity is two, and an extra child there was
    # dropped too: every artifact walker treats a non-`StmtList` third
    # child as "no body" and stops.
    let (probe, source) = refusal("executable bareBin",
      "executable bareBin, junkIdentE", "junkIdentE", "pkg-heads-exe-bare")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`junkIdentE` beside the head of " &
      "`executable bareBin`")
    check probe.mentions(NoSilentDrop)
    check probe.mentions(anchorTag(source, "junkIdentE"))

  test "`library myLib, junkIdent1:`":
    let (probe, source) = refusal("library myLib:",
      "library myLib, junkIdent1:", "junkIdent1", "pkg-heads-lib")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`library <name>:` takes one name")
    check probe.mentions("`junkIdent1` beside the head of `library myLib:`")
    check probe.mentions(NoSilentDrop)
    check probe.mentions(anchorTag(source, "junkIdent1"))

  test "`files myFiles, junkIdent2:`":
    let (probe, source) = refusal("files myFiles:",
      "files myFiles, junkIdent2:", "junkIdent2", "pkg-heads-files")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`files <name>:` takes one name")
    check probe.mentions("`junkIdent2` beside the head of `files myFiles:`")
    check probe.mentions(NoSilentDrop)
    check probe.mentions(anchorTag(source, "junkIdent2"))

  test "`versions junkIdent3:`":
    let (probe, source) = refusal("versions:", "versions junkIdent3:",
      "junkIdent3", "pkg-heads-versions")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`versions:` takes no arguments")
    check probe.mentions("`junkIdent3` is written on its head")
    check probe.mentions(NoSilentDrop)
    check probe.mentions(anchorTag(source, "junkIdent3"))

  test "`build junkIdentC:` at package level":
    let (probe, source) = refusal("  build:\n    discard",
      "  build junkIdentC:\n    discard", "junkIdentC", "pkg-heads-build")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`build:` takes no arguments")
    check probe.mentions("`junkIdentC` is written on its head")
    check probe.mentions("package `probeRecipe`")
    check probe.mentions(NoSilentDrop)
    check probe.mentions(anchorTag(source, "junkIdentC"))

  test "`build junkIdentD:` inside an `executable` body":
    let (probe, source) = refusal("executable probeBin:\n    build:",
      "executable probeBin:\n    build junkIdentD:", "junkIdentD",
      "pkg-heads-exe-build")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`build:` takes no arguments")
    check probe.mentions("`junkIdentD` is written on its head")
    check probe.mentions("`executable probeBin`")
    check probe.mentions(NoSilentDrop)
    check probe.mentions(anchorTag(source, "junkIdentD"))

  test "`build junkIdentL:` inside a `library` body":
    let (probe, source) = refusal("library myLib:\n    build:",
      "library myLib:\n    build junkIdentL:", "junkIdentL",
      "pkg-heads-lib-build")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`junkIdentL` is written on its head")
    check probe.mentions("`library myLib`")
    check probe.mentions(anchorTag(source, "junkIdentL"))

  test "`build junkIdentF:` inside a `files` body":
    let (probe, source) = refusal("files myFiles:\n    build:",
      "files myFiles:\n    build junkIdentF:", "junkIdentF",
      "pkg-heads-files-build")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`junkIdentF` is written on its head")
    check probe.mentions("`files myFiles`")
    check probe.mentions(anchorTag(source, "junkIdentF"))

  test "`devEnv junkIdentK:`":
    let (probe, source) = refusal("devEnv:", "devEnv junkIdentK:",
      "junkIdentK", "pkg-heads-devenv")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`devEnv:` takes no arguments")
    check probe.mentions("`junkIdentK` is written on its head")
    check probe.mentions(NoSilentDrop)
    check probe.mentions(anchorTag(source, "junkIdentK"))

  test "a call on a head is refused at the call, not at its parenthesis":
    # Nim hangs a call's line info on its opening parenthesis; the refusal
    # anchors on the call's head identifier, which is where the author
    # has to look.
    let (probe, source) = refusal("versions:",
      "versions noSuchProc(1, 2):", "noSuchProc", "pkg-heads-versions-call")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`noSuchProc(1, 2)` is written on its head")
    check probe.mentions(anchorTag(source, "noSuchProc"))

  test "a dotted argument is refused at its first token, not at the dot":
    # Nim hangs `a.b`'s line info on the dot. The refusal descends to the
    # leftmost token, so the column is where the argument starts.
    let (probe, source) = refusal("executable probeBin:",
      "executable probeBin, junkModule.junkField:", "junkModule",
      "pkg-heads-exe-dotted")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`junkModule.junkField` beside the head of " &
      "`executable probeBin:`")
    check probe.mentions(anchorTag(source, "junkModule"))
