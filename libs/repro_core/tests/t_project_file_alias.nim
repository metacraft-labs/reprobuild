## Unit tests for ``repro_core/project_file`` — the ``repro.nim`` /
## ``reprobuild.nim`` alias resolver.
##
## The contract lives in
## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"`repro.nim` ↔
## `reprobuild.nim` alias":
##
## * The engine looks for ``repro.nim`` first, then ``reprobuild.nim``.
## * Having both files in the same directory is an *ambiguity* the
##   resolver flags (``ambiguous=true``) and ``warnIfAmbiguous`` surfaces
##   to stderr; ``repro.nim`` still wins the precedence race.
## * A directory with neither file resolves to an empty match.

import std/[os, osproc, streams, strtabs, strutils, unittest]

import repro_core

# ----------------------------------------------------------------------
# Subprocess probe mode.
#
# When invoked with ``REPRO_PROJECT_FILE_ALIAS_PROBE`` set, this binary
# runs a single ``warnIfAmbiguous`` call against the directory named by
# the env var and exits zero. The outer test re-execs this same binary
# with that env var set so it can capture the child's stderr (Nim's
# ``stderr`` File handle is a ``let`` and can't be rebound in-process;
# subprocess capture is the supported way to verify the warning reaches
# stderr).
const ProbeEnvVar = "REPRO_PROJECT_FILE_ALIAS_PROBE"

if existsEnv(ProbeEnvVar):
  let probeDir = getEnv(ProbeEnvVar)
  let probeMatch = resolveProjectFile(probeDir)
  warnIfAmbiguous(probeMatch, probeDir)
  quit(0)

proc makeScratch(name: string): string =
  ## Build (and clean) a per-test scratch directory under the OS temp
  ## dir. We do NOT use ``setup``/``teardown`` because the suite-level
  ## hooks don't see the test name.
  result = getTempDir() / ("repro-core-project-file-alias-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "repro_core.project_file: alias resolution":

  test "only repro.nim present resolves to the canonical name":
    # The canonical-name-only case is the recommended Mode-3 shape going
    # forward. The resolver must recognise it without falling back to
    # the legacy alias.
    let dir = makeScratch("canonical-only")
    writeFile(dir / "repro.nim", "import repro_project_dsl\n")
    let match = resolveProjectFile(dir)
    check match.path == dir / "repro.nim"
    check match.fileName == "repro.nim"
    check match.fileName == CanonicalProjectFileName
    check not match.ambiguous
    removeDir(dir)

  test "only reprobuild.nim present resolves to the legacy alias":
    # Regression: the M0-M29 fixture corpus and every existing
    # ``reprobuild-examples/`` project uses the legacy name. The resolver
    # MUST still accept it — the alias is "supported indefinitely".
    let dir = makeScratch("legacy-only")
    writeFile(dir / "reprobuild.nim", "import repro_project_dsl\n")
    let match = resolveProjectFile(dir)
    check match.path == dir / "reprobuild.nim"
    check match.fileName == "reprobuild.nim"
    check match.fileName == LegacyProjectFileName
    check not match.ambiguous
    removeDir(dir)

  test "both present: repro.nim wins + ambiguous flag is set":
    # The spec's precedence-tiebreaker: when both files exist,
    # ``repro.nim`` wins AND the caller learns it's ambiguous so the
    # user-facing warning can be emitted.
    let dir = makeScratch("both-present")
    writeFile(dir / "repro.nim", "# canonical\n")
    writeFile(dir / "reprobuild.nim", "# legacy\n")
    let match = resolveProjectFile(dir)
    check match.path == dir / "repro.nim"
    check match.fileName == "repro.nim"
    check match.ambiguous
    removeDir(dir)

  test "neither present: empty match":
    # The "no project file here" answer. Callers distinguish it by
    # ``path.len == 0``.
    let dir = makeScratch("neither-present")
    let match = resolveProjectFile(dir)
    check match.path.len == 0
    check match.fileName.len == 0
    check not match.ambiguous
    removeDir(dir)

  test "projectFileIn returns the resolved path or empty":
    # Convenience wrapper that drops the ``ambiguous`` signal. Used by
    # callers that only need the path.
    let dir = makeScratch("project-file-in")
    check projectFileIn(dir).len == 0
    writeFile(dir / "reprobuild.nim", "# legacy\n")
    check projectFileIn(dir) == dir / "reprobuild.nim"
    writeFile(dir / "repro.nim", "# canonical\n")
    check projectFileIn(dir) == dir / "repro.nim"
    removeDir(dir)

  test "ambiguousProjectFileMessage names both files and the dir":
    # The exact warning string is part of the user-facing contract — the
    # message must mention BOTH filenames and the directory so the user
    # knows which project to fix.
    let msg = ambiguousProjectFileMessage("/some/dir")
    check msg.contains(CanonicalProjectFileName)
    check msg.contains(LegacyProjectFileName)
    check msg.contains("/some/dir")
    check msg.contains("ambiguous")

  test "ProjectFileNames ordering is canonical-first":
    # The probing-order constant is part of the public surface — tests
    # and downstream callers rely on its first element being the
    # canonical name.
    check ProjectFileNames.len == 2
    check ProjectFileNames[0] == CanonicalProjectFileName
    check ProjectFileNames[1] == LegacyProjectFileName

  test "ambiguous match: warning text is the contract; warnIfAmbiguous emits it":
    # End-to-end of the precedence tiebreaker. We rely on
    # ``ambiguousProjectFileMessage`` being the exact text
    # ``warnIfAmbiguous`` writes — the proc body is two lines and the
    # message text is the public contract. Capture stderr via redirection
    # at the subprocess level instead of trying to rebind ``stderr``
    # inside this Nim process (Nim's ``stderr`` File handle is a ``let``
    # constant; the C runtime's ``stderr`` fd is the source of truth and
    # is shared across the process). See the e2e stderr-capture test for
    # the cross-process verification.
    let dir = makeScratch("ambiguous-contract")
    writeFile(dir / "repro.nim", "# canonical\n")
    writeFile(dir / "reprobuild.nim", "# legacy\n")
    let match = resolveProjectFile(dir)
    check match.ambiguous
    let expected = ambiguousProjectFileMessage(dir)
    check expected.contains("warning")
    check expected.contains(CanonicalProjectFileName)
    check expected.contains(LegacyProjectFileName)
    check expected.contains(dir)
    check expected.contains("ambiguous")
    # Invoke ``warnIfAmbiguous`` for coverage — its body is two lines
    # (the conditional + ``stderr.writeLine(ambiguousProjectFileMessage)``).
    # The text reaches the parent process's stderr in real runs; the
    # inline assertion is sufficient for this unit-test layer.
    warnIfAmbiguous(match, dir)
    removeDir(dir)

  test "warnIfAmbiguous is a no-op when only one file exists":
    # The warning MUST NOT fire on the single-file paths — that would
    # spam every existing Mode-2 project on every build. The ``ambiguous``
    # flag is the precondition; verify it's clear for both single-file
    # shapes (the proc body's guard then ensures silence).
    for fileName in [CanonicalProjectFileName, LegacyProjectFileName]:
      let dir = makeScratch("solo-" & fileName)
      writeFile(dir / fileName, "# solo\n")
      let match = resolveProjectFile(dir)
      check not match.ambiguous
      # No-op call — should not raise, should not write anything.
      warnIfAmbiguous(match, dir)
      removeDir(dir)

suite "repro_core.project_file: subprocess stderr capture":

  test "warning text reaches stderr (precedence tiebreaker)":
    # Real verification of the precedence-tiebreaker contract: spawn
    # this same test binary with ``REPRO_PROJECT_FILE_ALIAS_PROBE`` set
    # to a directory with both files, capture its stderr, and verify
    # the warning text from ``ambiguousProjectFileMessage`` appears
    # there.
    let dir = makeScratch("subprocess-warn")
    writeFile(dir / "repro.nim", "# canonical\n")
    writeFile(dir / "reprobuild.nim", "# legacy\n")
    let selfBin = getAppFilename()
    var env = newStringTable()
    for k, v in envPairs():
      env[k] = v
    env[ProbeEnvVar] = dir
    let p = startProcess(
      selfBin,
      args = @[],
      env = env,
      options = {})
    let stdoutStream = p.outputStream
    let stderrStream = p.errorStream
    discard stdoutStream.readAll()
    let stderrText = stderrStream.readAll()
    let exitCode = p.waitForExit()
    p.close()
    check exitCode == 0
    check stderrText.contains("warning")
    check stderrText.contains(CanonicalProjectFileName)
    check stderrText.contains(LegacyProjectFileName)
    check stderrText.contains("ambiguous")
    # The full message includes the project root path. Account for path
    # separator normalisation (the message uses ``/`` from the ``os``
    # module on the host; on Windows that's a forward-slash join that
    # the test fixture also produced, so equality holds).
    check stderrText.contains(dir)
    removeDir(dir)
