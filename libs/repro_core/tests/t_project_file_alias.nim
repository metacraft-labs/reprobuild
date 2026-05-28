## Unit tests for ``repro_core/project_file`` — the ``repro.nim`` /
## ``reprobuild.nim`` alias resolver.
##
## The contract lives in
## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"`repro.nim` ↔
## `reprobuild.nim` alias":
##
## * The engine looks for ``repro.nim`` first, then ``reprobuild.nim``.
## * Having both files in the same directory is a HARD ERROR — the
##   resolver raises ``ProjectFileAmbiguousError`` and the CLI exits
##   non-zero with a stderr message naming both files and the directory.
## * A directory with neither file resolves to an empty match.

import std/[os, osproc, streams, strtabs, strutils, unittest]

import repro_core

# ----------------------------------------------------------------------
# Subprocess probe mode.
#
# When invoked with ``REPRO_PROJECT_FILE_ALIAS_PROBE`` set, this binary
# runs ``resolveProjectFile`` against the directory named by the env var
# and lets the exception propagate. The outer test re-execs this same
# binary with that env var set so it can capture the child's stderr
# (Nim's ``stderr`` File handle is a ``let`` and can't be rebound
# in-process; subprocess capture is the supported way to verify the
# error reaches stderr).
const ProbeEnvVar = "REPRO_PROJECT_FILE_ALIAS_PROBE"

if existsEnv(ProbeEnvVar):
  let probeDir = getEnv(ProbeEnvVar)
  try:
    discard resolveProjectFile(probeDir)
    quit(0)
  except ProjectFileAmbiguousError as err:
    # Mirror the production CLI top-level handler's framing
    # (``"repro <subcommand>: error: " & err.msg``). The resolver's own
    # ``err.msg`` deliberately omits the ``error:`` prefix so the CLI
    # doesn't double up — this probe is what verifies the prefix-merge
    # produces a clean, single-error-prefixed stderr line.
    stderr.writeLine("repro build: error: " & err.msg)
    quit(1)

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
    removeDir(dir)

  test "both present: raises ProjectFileAmbiguousError":
    # The spec (Three-Mode-Convention-System.md line 211) declares this
    # case a hard error. The resolver MUST raise — no warn-and-proceed.
    let dir = makeScratch("both-present")
    writeFile(dir / "repro.nim", "# canonical\n")
    writeFile(dir / "reprobuild.nim", "# legacy\n")
    var raised = false
    var msg = ""
    try:
      discard resolveProjectFile(dir)
    except ProjectFileAmbiguousError as err:
      raised = true
      msg = err.msg
    check raised
    check msg.contains(CanonicalProjectFileName)
    check msg.contains(LegacyProjectFileName)
    check msg.contains(dir)
    # The message text deliberately omits a leading "error:" — the CLI
    # top-level handler adds "repro <subcommand>: error: " when it
    # catches the propagated exception, and double-prefixing would
    # surface as the user-confusing "error: error: ..." string.
    check not msg.startsWith("error")
    # Actionable bit: tell the user WHICH file to remove.
    check msg.contains("remove " & LegacyProjectFileName)
    removeDir(dir)

  test "neither present: empty match":
    # The "no project file here" answer. Callers distinguish it by
    # ``path.len == 0``.
    let dir = makeScratch("neither-present")
    let match = resolveProjectFile(dir)
    check match.path.len == 0
    check match.fileName.len == 0
    removeDir(dir)

  test "projectFileIn returns the resolved path or empty":
    # Convenience wrapper. Used by callers that only need the path.
    # Raises ``ProjectFileAmbiguousError`` on the both-present case (same
    # contract as ``resolveProjectFile``).
    let dir = makeScratch("project-file-in")
    check projectFileIn(dir).len == 0
    writeFile(dir / "reprobuild.nim", "# legacy\n")
    check projectFileIn(dir) == dir / "reprobuild.nim"
    removeFile(dir / "reprobuild.nim")
    writeFile(dir / "repro.nim", "# canonical\n")
    check projectFileIn(dir) == dir / "repro.nim"
    removeDir(dir)

  test "ambiguousProjectFileMessage names both files and the dir":
    # The exact error string is part of the user-facing contract — the
    # message must mention BOTH filenames and the directory so the user
    # knows which project to fix, plus an actionable hint pointing at
    # the legacy filename as the one to remove (we're migrating toward
    # ``repro.nim`` as canonical). The message MUST NOT itself start
    # with ``"error"`` — the CLI top-level prefixes its own
    # ``"repro <cmd>: error: "`` and double-prefixing reads badly.
    let msg = ambiguousProjectFileMessage("/some/dir")
    check msg.contains(CanonicalProjectFileName)
    check msg.contains(LegacyProjectFileName)
    check msg.contains("/some/dir")
    check not msg.startsWith("error")
    check msg.contains("remove " & LegacyProjectFileName)

  test "ProjectFileNames ordering is canonical-first":
    # The probing-order constant is part of the public surface — tests
    # and downstream callers rely on its first element being the
    # canonical name.
    check ProjectFileNames.len == 2
    check ProjectFileNames[0] == CanonicalProjectFileName
    check ProjectFileNames[1] == LegacyProjectFileName

  test "ambiguous error message is the contract":
    # End-to-end of the precedence tiebreaker. We rely on
    # ``ambiguousProjectFileMessage`` being the exact text the resolver
    # raises — the message text is the public contract that the CLI
    # surface (and any other caller) prints to the user.
    let dir = makeScratch("ambiguous-contract")
    writeFile(dir / "repro.nim", "# canonical\n")
    writeFile(dir / "reprobuild.nim", "# legacy\n")
    let expected = ambiguousProjectFileMessage(dir)
    check not expected.startsWith("error")
    check expected.contains(CanonicalProjectFileName)
    check expected.contains(LegacyProjectFileName)
    check expected.contains(dir)
    check expected.contains("remove " & LegacyProjectFileName)
    var actual = ""
    try:
      discard resolveProjectFile(dir)
    except ProjectFileAmbiguousError as err:
      actual = err.msg
    check actual == expected
    removeDir(dir)

suite "repro_core.project_file: subprocess stderr capture":

  test "ambiguous: subprocess exits non-zero with error on stderr":
    # Real verification of the precedence-tiebreaker contract: spawn
    # this same test binary with ``REPRO_PROJECT_FILE_ALIAS_PROBE`` set
    # to a directory with both files, capture its stderr, and verify
    # the error text from ``ambiguousProjectFileMessage`` appears
    # there AND the exit code is non-zero (the spec says ambiguity is
    # a hard error, not a warning).
    let dir = makeScratch("subprocess-error")
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
    check exitCode != 0
    # The probe writes ``"repro build: error: " & err.msg`` to mirror the
    # production CLI top-level handler. The user-facing stderr line must:
    #   * be a single, well-formed "error:" prefix (no double "error:")
    #   * name both filenames
    #   * name the directory
    #   * tell the user which file to remove
    check stderrText.contains("repro build: error: ")
    check not stderrText.contains("error: error:")
    check stderrText.contains(CanonicalProjectFileName)
    check stderrText.contains(LegacyProjectFileName)
    check stderrText.contains("remove " & LegacyProjectFileName)
    # The full message includes the project root path. Account for path
    # separator normalisation (the message uses ``/`` from the ``os``
    # module on the host; on Windows that's a forward-slash join that
    # the test fixture also produced, so equality holds).
    check stderrText.contains(dir)
    removeDir(dir)
