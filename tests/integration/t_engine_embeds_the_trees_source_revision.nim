## The engine under test embeds the source revision of the tree it was built
## from -- exactly what ``scripts/source_revision.sh`` reports for that tree.
##
## The defect this gate pins
## -------------------------
## ``ReprobuildSourceRevision`` (``libs/repro_core/src/repro_core.nim``) is the
## provenance ``repro home export`` records. ``scripts/build_apps.sh`` derived
## it from ``$REPROBUILD_SOURCE_REVISION`` or, failing that, from git; the
## ``reprobuild.apps.reprobuild`` edge in ``repro.nim`` read only the variable,
## and read it with ``getEnv`` at recipe evaluation. Nothing on the suite route
## sets the variable, so ``repro build '.#test#…'`` rebuilt
## ``build/bin/reprobuild`` with no revision and
## ``t_e2e_home_export_matches_compiled_intent`` failed at its
## ``sourceRevision`` check. That gate needs a full ``repro home export`` (nim
## compiles of a profile) to notice; this one reads the engine's bytes.
##
## Both routes now embed what ``scripts/source_revision.sh`` prints: the graph
## through the ``reprobuild.apps.source-revision`` probe edge's generated
## module, ``build_apps.sh`` by calling the script. So the check is the same
## whichever route built the engine, and it fails for the issue's reason on the
## graph route before the fix (the engine carries no revision at all).
##
## The match is exact, not a substring: the revision must be followed by a byte
## that cannot continue a revision (Nim emits string literals NUL-terminated).
## A clean tree's ``<sha>`` would otherwise be satisfied by an engine built
## while the tree was ``<sha>-dirty``.
##
## The test runs the script with the environment it inherits, as the probe
## edge does, so a ``$REPROBUILD_SOURCE_REVISION`` set for the build is
## expected in the engine too.
##
## No mocks: the real script, real git, the real engine binary.

import std/[os, osproc, strutils, unittest]

const RevisionChars = {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '+', '-'}

const EngineBinary =
  when defined(windows): "build/bin/reprobuild.exe"
  else: "build/bin/reprobuild"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / "repro.nim") and
        fileExists(dir / "scripts" / "source_revision.sh"):
      return dir
    let parent = dir.parentDir
    if parent == dir: break
    dir = parent
  raise newException(OSError,
    "cannot locate the reprobuild repository root from " & currentSourcePath())

proc exactOccurrences(haystack, needle: string): int =
  ## Occurrences of ``needle`` not followed by a revision character.
  var start = 0
  while true:
    let at = haystack.find(needle, start)
    if at < 0: break
    let after = at + needle.len
    if after >= haystack.len or haystack[after] notin RevisionChars:
      inc result
    start = at + 1

suite "engine source revision":
  test "the engine embeds the revision scripts/source_revision.sh reports":
    let root = findRepoRoot()
    let (output, code) = execCmdEx(
      "bash " & quoteShell(root / "scripts" / "source_revision.sh") &
        " --tree " & quoteShell(root))
    check code == 0
    let expected = output.strip()
    checkpoint("scripts/source_revision.sh: '" & expected & "'")
    # An empty answer would make the byte check vacuous. The suite runs from a
    # git checkout (or with the variable set), where the script always answers.
    require expected.len > 0
    for c in expected:
      check c in RevisionChars

    let engine = root / EngineBinary
    require fileExists(engine)
    let bytes = readFile(engine)
    let exact = exactOccurrences(bytes, expected)
    checkpoint("exact occurrences in " & engine & ": " & $exact)
    check exact >= 1
