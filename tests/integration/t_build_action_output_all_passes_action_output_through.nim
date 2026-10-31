## t_build_action_output_all_passes_action_output_through — ``repro build
## --action-output=all`` prints what a SUCCEEDING action wrote.
##
## What this test owns
## -------------------
## The ``--action-output`` flag as the real ``repro`` binary sees it. Without
## it a succeeding action's stdout and stderr reach nobody: ``--log`` governs
## status lines only, and the failure summary is the one place an action's
## output was ever printed. A CMake try_compile under ``-G Reprobuild`` is the
## caller that broke on that: CMake learns the compiler's implicit include and
## link directories by parsing ``gcc -v`` output out of the build tool's
## output, and got only the ``repro build`` command line back
## (reprobuild-specs issue 2026-10-10, "a Reprobuild try_compile's output never
## carries the compiler's own output").
##
## The cases pin:
##
##   * ``all`` puts a succeeding action's stdout AND stderr on repro's stdout,
##     and nothing of either on its stderr (one stream, as Ninja does);
##   * the default still prints neither (default output is unchanged);
##   * a failed action's output is printed once, not again inside the failure
##     summary;
##   * the flag is presentation only: an action built without it is served
##     from cache when rebuilt with it, i.e. it did not enter the action key;
##   * `repro test` forwards it to the in-process build it runs to issue
##     certificates;
##   * an unknown value is rejected with the vocabulary.
##
## stdout and stderr are captured SEPARATELY here, unlike the merged
## ``execCmdEx`` capture elsewhere, because which stream the output lands on is
## part of what is under test.

import std/[os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

let reproBin = getEnv("REPROBUILD_REPRO",
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt))

const
  StdoutMarker = "ao-stdout-marker"
  StderrMarker = "ao-stderr-marker"
  KeyedMarker = "ao-keyed-marker"
  FailedMarker = "ao-failed-marker"

  # Every action writes a declared output, so none of them depends on how the
  # engine treats an output-less action. ``chatty`` and ``failing`` are not
  # cacheable so each build runs them again.
  Fixture = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package actionOutputProbe:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    let chatty = shell(
      command = "mkdir -p build && printf 'ao-stdout-marker\\n' && printf 'ao-stderr-marker\\n' >&2 && printf 'c\\n' > build/chatty.txt",
      actionId = "action-output.chatty",
      extraOutputs = @["build/chatty.txt"],
      cacheable = false)
    discard target("chatty", chatty)
    let keyed = shell(
      command = "mkdir -p build && printf 'ao-keyed-marker\\n' >&2 && printf 'k\\n' > build/keyed.txt",
      actionId = "action-output.keyed",
      extraOutputs = @["build/keyed.txt"])
    discard target("keyed", keyed)
    let failing = shell(
      command = "mkdir -p build && printf 'ao-failed-marker\\n' >&2 && exit 3 && printf 'f\\n' > build/failing.txt",
      actionId = "action-output.failing",
      extraOutputs = @["build/failing.txt"],
      cacheable = false)
    discard target("failing", failing)
"""

type BuildRun = object
  exitCode: int
  stdoutText: string
  stderrText: string

proc runRepro(project, verb: string; extra: openArray[string]): BuildRun =
  var args = @[verb]
  for arg in extra:
    args.add(arg)
  args.add(["--tool-provisioning=path", "--daemon=off", "--no-runquota",
    "--progress=quiet", "--measure=none", "--no-write-report"])
  # `sh` sends stderr to a file, so `execCmdEx`'s merged capture holds stdout
  # alone. `sh` because `execCmdEx` runs no shell on Windows (a `2>` would
  # reach repro as an argument), and the fixture needs `sh` anyway. Reading
  # the two pipes of a `startProcess` child was tried first and lost data on
  # Windows: stderr came back empty and stdout truncated.
  let stderrPath = project / "build-stderr.txt"
  var command = quoteShell(findExe("sh")) & " -c " &
    quoteShell("exec \"$0\" \"$@\" 2>\"$REPRO_TEST_STDERR\"") & " " &
    quoteShell(reproBin)
  for arg in args:
    command.add(" " & quoteShell(arg))
  putEnv("REPRO_TEST_STDERR", stderrPath)
  let res = execCmdEx(command, workingDir = project)
  result.exitCode = res.exitCode
  result.stdoutText = res.output
  result.stderrText = readFile(stderrPath)

proc runBuild(project: string; extra: openArray[string]): BuildRun =
  runRepro(project, "build", extra)

proc explain(run: BuildRun): string =
  "exit=" & $run.exitCode & "\n--- stdout ---\n" & run.stdoutText &
    "\n--- stderr ---\n" & run.stderrText

# One project for the whole suite: every build of a fresh project compiles its
# provider first, which costs minutes here. No case depends on another's
# outputs — each builds its own target, and only ``keyed`` is cacheable.
let project = createTempDir("repro-action-output-", "")
writeFile(project / "repro.nim", Fixture)

suite "repro build --action-output":

  test "all prints a succeeding action's stdout and stderr on stdout":
    if not fileExists(reproBin) or findExe("sh").len == 0:
      skip("needs " & reproBin & " (run `just build`) and `sh` on PATH")
    else:
      let run = runBuild(project, ["chatty", "--action-output=all",
        "--log=quiet"])
      checkpoint(explain(run))
      check run.exitCode == 0
      check StdoutMarker in run.stdoutText
      check StderrMarker in run.stdoutText
      check StdoutMarker notin run.stderrText
      check StderrMarker notin run.stderrText
      # Status lines stay governed by --log: quiet means none.
      check "action: " notin run.stdoutText

  test "the default prints no output of a succeeding action":
    if not fileExists(reproBin) or findExe("sh").len == 0:
      skip("needs " & reproBin & " (run `just build`) and `sh` on PATH")
    else:
      let run = runBuild(project, ["chatty", "--log=quiet"])
      checkpoint(explain(run))
      check run.exitCode == 0
      for text in [run.stdoutText, run.stderrText]:
        check StdoutMarker notin text
        check StderrMarker notin text

  test "a failed action's output is printed once":
    if not fileExists(reproBin) or findExe("sh").len == 0:
      skip("needs " & reproBin & " (run `just build`) and `sh` on PATH")
    else:
      let run = runBuild(project, ["failing", "--action-output=all",
        "--log=quiet"])
      checkpoint(explain(run))
      check run.exitCode != 0
      check run.stdoutText.count(FailedMarker) == 1
      check FailedMarker notin run.stderrText
      # The failure summary keeps its header.
      check "action failed:" in run.stderrText

  test "the flag does not enter the action key":
    if not fileExists(reproBin) or findExe("sh").len == 0:
      skip("needs " & reproBin & " (run `just build`) and `sh` on PATH")
    else:
      let first = runBuild(project, ["keyed", "--log=quiet"])
      checkpoint(explain(first))
      check first.exitCode == 0
      check fileExists(project / "build" / "keyed.txt")
      # Rebuilt WITH the flag: if it were part of the action's identity the
      # action would run again and its marker would be printed.
      let second = runBuild(project, ["keyed", "--action-output=all",
        "--log=actions"])
      checkpoint(explain(second))
      check second.exitCode == 0
      check KeyedMarker notin second.stdoutText
      var keyedLine = ""
      for line in second.stdoutText.splitLines():
        if line.startsWith("action: keyed "):
          keyedLine = line
      check keyedLine.len > 0
      check "launched=false" in keyedLine

  test "repro test forwards the flag to its in-process build":
    # ``repro test`` issues certificates, so it always builds in-process to
    # observe each action's outcome. That build must still print what its
    # actions wrote when asked, as ``repro build`` does.
    if not fileExists(reproBin) or findExe("sh").len == 0:
      skip("needs " & reproBin & " (run `just build`) and `sh` on PATH")
    else:
      let run = runRepro(project, "test", ["chatty", "--action-output=all",
        "--log=quiet"])
      checkpoint(explain(run))
      check run.exitCode == 0
      check StdoutMarker in run.stdoutText
      check StderrMarker in run.stdoutText
      check StderrMarker notin run.stderrText
      # ``--no-runquota`` reaches the plan ``repro test`` reads before it
      # builds: with no runquota daemon on the host the plan is still read,
      # not refused and retried as a plain build.
      check "could not be read" notin run.stderrText

  test "an unknown value is rejected with the vocabulary":
    if not fileExists(reproBin) or findExe("sh").len == 0:
      skip("needs " & reproBin & " (run `just build`) and `sh` on PATH")
    else:
      let run = runBuild(project, ["chatty", "--action-output=bogus"])
      checkpoint(explain(run))
      check run.exitCode != 0
      let combined = run.stdoutText & run.stderrText
      check "--action-output=bogus" in combined
      check "failed or all" in combined

try:
  removeDir(project)
except OSError:
  discard
