## Regression: the runner must keep running cases after its own binary has
## been replaced on disk.
##
## The runner starts every case through a process-group supervisor, which is
## the runner re-executing itself. It used to find itself with
## ``getAppFilename()``, which on Linux is the ``/proc/self/exe`` LINK TEXT.
## After any rebuild of ``build/bin`` replaces the file (an atomic rename),
## that text is ``".../repro_test_runner (deleted)"`` — a path that does not
## exist — so every later spawn failed with ENOENT and every remaining case
## became a harness error. A full local suite run recorded 10,059 harness
## errors out of 10,070 cases this way: suites that rebuild ``.#apps`` into
## the same checkout replaced the runner half an hour in.
##
## The scenario reproduces exactly that shape. It runs a COPY of the
## production runner (the real ``build/bin`` is never touched) with one worker
## over a two-case fixture:
##
## * the first case blocks until released;
## * while it is blocked, the test replaces the runner's file the way a
##   rebuild does — writes a new file beside it and renames it over — and
##   PROVES the precondition by reading ``/proc/<runner>/exe``, which must now
##   end in `` (deleted)``; a scenario that failed to reproduce the unlink
##   would otherwise pass without testing anything;
## * the second case records whether it started AFTER the replacement, so a
##   runner that happened to schedule it first fails this test loudly instead
##   of passing it vacuously.
##
## No mocks or stubs are used: the runner is the production binary, the
## fixture is a real compiled executable, and the replacement is a real
## rename(2) observed through the kernel's own /proc view.

when defined(linux):
  import std/[json, os, osproc, streams, strutils, tempfiles, times, unittest]

  const FixtureSource = """
import std/[json, os]

const
  # One of repro_test_runner's ProtocolMarkers, on the ordinary argv-error
  # path so no optimisation level can elide it.
  Marker = "unittest: --run requires a test name"
  FirstCase = "replacement::first holds the runner open"
  SecondCase = "replacement::second runs after the replacement"

proc emitCatalog() =
  var tests = newJArray()
  for name in [FirstCase, SecondCase]:
    var node = newJObject()
    node["name"] = %name
    node["suite"] = %"replacement"
    node["file"] = %"runner_replacement_fixture.nim"
    node["line"] = %1
    tests.add(node)
  var summary = newJObject()
  summary["total"] = %2
  echo $(%*{"tests": tests, "summary": summary})

proc writePass() =
  let resultPath = getEnv("NIMTEST_RESULT_FILE")
  if resultPath.len == 0:
    quit(99)
  writeFile(resultPath, $(%*{"status": "PASS", "duration_ms": 1,
    "checkpoints": newJArray(), "exception": newJNull()}))

let params = commandLineParams()
if params.len == 0:
  stderr.writeLine Marker
  quit(2)
elif params[0] == "--list-json":
  emitCatalog()
  quit(0)
elif params[0] == "--run" and params.len >= 2 and params[1] == FirstCase:
  writeFile(getEnv("REPRO_REPLACE_STARTED"), "started")
  let continuePath = getEnv("REPRO_REPLACE_CONTINUE")
  var released = false
  for _ in 0 ..< 3000:
    if fileExists(continuePath):
      released = true
      break
    sleep(10)
  if not released:
    quit(98)
  writePass()
  quit(0)
elif params[0] == "--run" and params.len >= 2 and params[1] == SecondCase:
  let order =
    if fileExists(getEnv("REPRO_REPLACE_DONE")): "after-replacement"
    else: "before-replacement"
  let record = open(getEnv("REPRO_REPLACE_RECORD"), fmAppend)
  record.writeLine("second," & order)
  record.close()
  writePass()
  quit(0)
else:
  stderr.writeLine Marker
  quit(2)
"""

  proc repoRoot(): string =
    var candidate = currentSourcePath().parentDir
    while candidate.parentDir != candidate:
      if fileExists(candidate / "repro.nim") and
          fileExists(candidate / "repro_tests.nim"):
        return candidate
      candidate = candidate.parentDir
    raise newException(IOError, "cannot find reprobuild repository root")

  proc runnerArgs(binDir, summary, resultsDir: string): seq[string] =
    @["--no-build", "--threads=1", "--quiet", "--bin-dir=" & binDir,
      "--summary-json=" & summary, "--results-dir=" & resultsDir,
      "--test-timeout=60"]

  proc waitForFile(path: string; seconds: float): bool =
    let deadline = epochTime() + seconds
    while epochTime() < deadline:
      if fileExists(path):
        return true
      sleep(20)
    fileExists(path)

  suite "repro test runner survives its own binary being replaced":
    test "cases after the runner's file is replaced still run":
      let root = repoRoot()
      let installed = root / "build" / "bin" / "repro_test_runner"
      require fileExists(installed)

      let scratch = createTempDir("runner-replaced-", "")
      defer: removeDir(scratch)
      let runnerDir = scratch / "runner"
      createDir(runnerDir)
      let runner = runnerDir / "repro_test_runner"
      copyFileWithPermissions(installed, runner)

      let binDir = scratch / "bin"
      createDir(binDir)
      let fixtureSource = scratch / "runner_replacement_fixture.nim"
      writeFile(fixtureSource, FixtureSource)
      let fixture = binDir / "t_runner_replacement"
      let compilation = execCmdEx("nim c --hints:off --warnings:off" &
        " --nimcache:" & quoteShell(scratch / "nimcache") &
        " --out:" & quoteShell(fixture) & " " & quoteShell(fixtureSource),
        workingDir = root)
      if compilation.exitCode != 0:
        checkpoint(compilation.output)
      require compilation.exitCode == 0

      let started = scratch / "started"
      let released = scratch / "continue"
      let replaced = scratch / "replaced"
      let record = scratch / "record.csv"
      putEnv("REPRO_REPLACE_STARTED", started)
      putEnv("REPRO_REPLACE_CONTINUE", released)
      putEnv("REPRO_REPLACE_DONE", replaced)
      putEnv("REPRO_REPLACE_RECORD", record)
      defer:
        for name in ["REPRO_REPLACE_STARTED", "REPRO_REPLACE_CONTINUE",
                     "REPRO_REPLACE_DONE", "REPRO_REPLACE_RECORD"]:
          delEnv(name)

      let summary = scratch / "summary.json"
      let process = startProcess(runner, workingDir = root,
        args = runnerArgs(binDir, summary, scratch / "results"),
        options = {poStdErrToStdOut})
      defer:
        if process.peekExitCode() == -1:
          process.kill()
          discard process.waitForExit()
        close(process)

      require waitForFile(started, 60.0)

      # Replace the runner exactly as a rebuild of build/bin does: a new file
      # written beside it, then renamed over the old path.
      let staged = runnerDir / "repro_test_runner.new"
      copyFileWithPermissions(installed, staged)
      moveFile(staged, runner)

      # The precondition this test exists for. Without it, a scenario that
      # failed to unlink the running image would pass while proving nothing.
      let exeLink = expandSymlink("/proc/" & $process.processID & "/exe")
      checkpoint("runner /proc exe after replacement: " & exeLink)
      require exeLink.endsWith(" (deleted)")

      writeFile(replaced, "replaced")
      writeFile(released, "continue")

      let exitCode = process.waitForExit(timeout = 120_000)
      let output = process.outputStream.readAll()
      checkpoint(output)
      check exitCode == 0

      require fileExists(record)
      check readFile(record).strip() == "second,after-replacement"

      require fileExists(summary)
      let report = parseFile(summary)
      checkpoint($report)
      check report{"summary"}{"passed"}.getInt(-1) == 2
      check report{"summary"}{"failed"}.getInt(-1) == 0
      check report{"summary"}{"harness_errors"}.getInt(0) == 0
else:
  import std/unittest

  suite "repro test runner survives its own binary being replaced":
    test "cases after the runner's file is replaced still run":
      skip("platform N/A: the regression this case pins is the Linux " &
        "/proc/self/exe link text, which goes stale when the binary is " &
        "replaced; every other platform keeps getAppFilename() and has " &
        "nothing to survive")
