## Integration tests that run on every OS must not root their fixtures at a
## literal ``/tmp`` path.
##
## MOCK POLICY: no mocks. This is a source-level check: it reads the real test
## sources and the real generated suite table (``repro_tests.nim``). The
## property is about how those files are written, so their text is the only
## thing to observe. Running the cases themselves would show the defect only
## on Windows, and only after a full engine build.
##
## The defect: each file below is registered ``targetOs: soAny`` and has no
## ``when defined(windows)`` skip, yet built its fixture root as
## ``"/tmp/rb-<tag>-" & $pid``. On Windows that is a drive-relative
## ``\tmp\...`` that does not exist, so ``repro build`` refuses the project
## ("path selector ... names no file or directory") and the case fails before
## it measures anything. On every OS the literal also ignores the ``TMPDIR``
## that ``scripts/run_tests.sh`` points at its per-checkout scratch directory.
##
## The rule this checks: a file registered for every OS takes its fixture
## root from ``getTempDir()``, with a short name so the root stays short (each
## file's own comment says why its root must be short). A file that really
## needs a fixed absolute root says so and is restricted, either by a
## ``targetOs`` other
## than ``soAny`` or by skipping on Windows. Either way out is accepted here,
## so the check states the requirement rather than one way of meeting it.
##
## Scope: the three files listed below, the ones this check was written to
## guard. Other files that carry the same literal either skip on Windows or
## are being fixed separately; each such fix adds its file here, or replaces
## this list with a scan of the tree once no offender is left.

import std/[os, strutils, unittest]

const AnyOsFixtureTests = [
  "t_nim_compile_key_ignores_the_shells_temp_dir.nim",
  "t_recipe_compile_per_computation_dirs.nim",
  "t_interface_extraction_sibling_shims_are_location_free.nim",
]

proc findRepoRoot(): string =
  ## The checkout root: the nearest ancestor of this source that holds both
  ## ``repro.nim`` and the generated ``repro_tests.nim``.
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / "repro.nim") and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc registeredTargetOs(suiteTable, source: string): string =
  ## The ``targetOs:`` value of ``source``'s row in ``repro_tests.nim``, or
  ## "" when the source has no row. Each row is a ``TestSpec(...)`` block
  ## that names its ``source:`` first and carries ``targetOs:`` a few lines
  ## below, so the first ``targetOs:`` after the source line belongs to it.
  let at = suiteTable.find("source: \"" & source & "\"")
  if at < 0:
    return ""
  let key = "targetOs: "
  let k = suiteTable.find(key, at)
  if k < 0:
    return ""
  var e = k + key.len
  while e < suiteTable.len and suiteTable[e] notin {',', ')', '\n'}:
    inc e
  suiteTable[k + key.len ..< e].strip

proc codeLines(text: string): seq[string] =
  ## The stripped lines of ``text`` that are not comments. The checks below
  ## read code only, so a comment that mentions ``defined(windows)`` or
  ## ``getTempDir()`` (the fixed files' comments mention the latter) can
  ## neither excuse a file nor stand in for its fixture code.
  for raw in text.splitLines:
    let line = raw.strip
    if line.len > 0 and not line.startsWith("#"):
      result.add(line)

proc codeMentions(text, needle: string): bool =
  for line in codeLines(text):
    if needle in line:
      return true

proc literalTmpRootLines(text: string): seq[string] =
  ## Lines that build a path from a ``/tmp`` string literal: a literal that
  ## starts with ``/tmp/``, or the bare ``"/tmp"`` joined onward with ``/``.
  ## A ``/tmp`` mentioned inside a longer literal or a comment (the module
  ## headers describe ``/tmp/nix-shell.XXXXXX``) is not a root.
  for line in codeLines(text):
    if "\"/tmp/" in line or "\"/tmp\" /" in line:
      result.add(line)

suite "any-OS integration tests root their fixtures under the host's temp dir":

  test "the three any-OS fixture files take their root from getTempDir()":
    let repoRoot = findRepoRoot()
    let suiteTable = readFile(repoRoot / "repro_tests.nim")
    for name in AnyOsFixtureTests:
      let rel = "tests/integration/" & name
      checkpoint(rel)
      let path = repoRoot / rel
      require fileExists(path)
      let text = readFile(path)
      let targetOs = registeredTargetOs(suiteTable, rel)
      # A file the suite no longer runs proves nothing here: fail rather than
      # pass on a table that lost the row.
      require targetOs.len > 0
      let runsOnWindows = targetOs == "soAny" and
        not codeMentions(text, "defined(windows)")
      if runsOnWindows:
        let offending = literalTmpRootLines(text)
        for line in offending:
          checkpoint("literal /tmp root in " & rel & ": " & line)
        check offending.len == 0
        # Positive control: the root has to come from somewhere, and the rule
        # names where. Without this, deleting the fixture code would pass;
        # a comment naming ``getTempDir()`` does not count.
        let rootsUnderTempDir = codeMentions(text, "getTempDir()")
        check rootsUnderTempDir
