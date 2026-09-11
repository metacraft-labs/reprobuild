## The dev-env activation says what it is about to do, on the stream that can
## carry it — `Interactive-UX-And-Progress.md` Principle 1.
##
## ## The defect this locks out
##
## `repro dev-env export` is the one engine invocation nobody types: the shell
## hook runs it on every `cd`. When its cache-key fast path misses it compiles
## the project provider and re-derives the environment, and until the change
## this test guards it did that in **complete silence** — measured on a real
## workspace at 31.9 s of nothing, followed by one warning about an unrelated
## file. From the prompt that is indistinguishable from a hung terminal, which
## Principle 1 names as a defect rather than a default: *"A silent multi-second
## (or multi-minute) hang is a defect, not acceptable default behavior."*
##
## ## Why the stream matters as much as the text
##
## The hook evaluates this command's **stdout** as shell code:
##
##     __repro_export=$(repro dev-env export bash …)
##     eval "$__repro_export"
##
## so an announcement written to stdout would not be read by the user at all —
## it would be *executed* by their shell. That makes "announce on stderr" a
## correctness property, not a style preference, and it is the one assertion
## here that cannot be satisfied by accident: `stdout_carries_no_announcement`
## fails the moment somebody "helpfully" moves the line.
##
## ## The three properties, and what each forbids
##
## 1. **A miss announces before it works, and reports after.** The first line
##    names the project root, so a user who has three terminals open knows
##    which one is busy and why.
## 2. **The fast path stays silent.** It answers in ~70 ms on every prompt;
##    a line there would be noise on every `cd` in every directory, and the
##    silence is what makes the hook tolerable to leave installed. This
##    assertion is why the announcement lives AFTER the `__REPRO_APPLIED`
##    comparison rather than at the top of the command.
## 3. **`--progress=quiet` is honoured**, via the same `REPROBUILD_PROGRESS`
##    knob every other reprobuild surface reads — a prompt that wants silence
##    keeps the existing way to ask for it. (Note the name: `CLI/build.md` says
##    `REPRO_PROGRESS`, the implementation reads `REPROBUILD_PROGRESS`. This
##    test pins the behaviour that ships; the spec's spelling is a separate
##    correction.)
##
## Mocking: none. The fixture is a real project, compiled by the real provider
## pipeline, driven through the real `repro` binary; only the project itself is
## synthetic, because a fixture is cheaper to keep honest than a snapshot of
## someone's workspace.

import std/[os, osproc, strtabs, strutils, unittest]

import repro_test_support
import ./dev_env_export_helper

type
  SplitOutcome = object
    exitCode: int
    stdout: string
    stderr: string

proc runExportSplit(c: M74Case; shell: string;
                    extraEnv: openArray[tuple[name, value: string]] = []):
    SplitOutcome =
  ## Run the export with stdout and stderr kept APART. ``runShell`` merges them
  ## (`poStdErrToStdOut`), which would make the property this file exists to
  ## prove unobservable.
  ##
  ## The two streams are redirected to FILES rather than read from pipes, and
  ## that is not a stylistic choice. `repro` starts a RunQuota daemon that
  ## outlives the command, and a daemon grandchild inherits the child's pipe
  ## write end — so a drain that waits for the pipes to close hangs forever
  ## after the child has already exited. (Observed exactly once, here, before
  ## this comment existed; `repro_test_support.runShell` carries a hand-rolled
  ## peek loop for the same reason.) Files have no such holder: the child exits,
  ## the bytes are on disk, and there is nothing to wait for.
  var envTable = c.envFor()
  for entry in extraEnv:
    envTable[entry.name] = entry.value
  let outPath = c.tempRoot / ("export-" & shell & "-stdout.txt")
  let errPath = c.tempRoot / ("export-" & shell & "-stderr.txt")
  let command = quoteShell(c.reproBin) & " dev-env export " & shell &
    " --project-root " & quoteShell(c.projectRoot) &
    " > " & quoteShell(outPath) & " 2> " & quoteShell(errPath)
  let process = startProcess(command,
    workingDir = c.repoRoot,
    env = envTable,
    options = {poEvalCommand})
  defer: process.close()
  result.exitCode = process.waitForExit()
  result.stdout = if fileExists(outPath): readFile(outPath) else: ""
  result.stderr = if fileExists(errPath): readFile(errPath) else: ""

proc appliedMarkerOf(script: string): string =
  ## Pull ``__REPRO_APPLIED='<key>'`` back out of the emitted bash script —
  ## the same value the hook leaves in the shell, and therefore the input that
  ## sends the NEXT invocation down the fast path.
  for line in script.splitLines():
    let idx = line.find("__REPRO_APPLIED='")
    if idx >= 0:
      let rest = line[idx + len("__REPRO_APPLIED='") .. ^1]
      let close = rest.find('\'')
      if close > 0:
        return rest[0 ..< close]
  ""

when isIoMonitorSupported:
  suite "dev-env activation announces before it works":

    test "a_cache_key_miss_announces_first_and_summarises_after":
      let c = prepareCase("repro-devenv-announce-miss")
      defer: removeDir(c.tempRoot)
      let outcome = runExportSplit(c, "bash")
      check outcome.exitCode == 0
      # Announced BEFORE the work: the first line the user sees names the
      # project, not the result.
      let firstLine = outcome.stderr.splitLines()[0]
      check firstLine.contains("repro dev-env: preparing the environment for")
      check firstLine.contains(c.projectRoot)
      # And reported after it: "ready in <duration>", plus what it actually
      # did, because "why was that slow" is the next question.
      check outcome.stderr.contains("repro dev-env: ready in")
      check outcome.stderr.contains("provider compiled") or
        outcome.stderr.contains("provider reused")

    test "stdout_carries_no_announcement":
      # The load-bearing one: the hook `eval`s stdout. A progress line there is
      # not a cosmetic defect, it is shell code the user never wrote.
      let c = prepareCase("repro-devenv-announce-stdout")
      defer: removeDir(c.tempRoot)
      let outcome = runExportSplit(c, "bash")
      check outcome.exitCode == 0
      check not outcome.stdout.contains("repro dev-env:")
      check not outcome.stdout.contains("preparing the environment")
      # Sanity: the script itself really was emitted, so the check above is
      # not vacuously passing on an empty stdout.
      check outcome.stdout.contains("__REPRO_APPLIED=")

    test "the_fast_path_stays_silent":
      let c = prepareCase("repro-devenv-announce-fastpath")
      defer: removeDir(c.tempRoot)
      let first = runExportSplit(c, "bash")
      check first.exitCode == 0
      let marker = appliedMarkerOf(first.stdout)
      check marker.len > 0
      # Second invocation with the marker the first one emitted: this is the
      # per-prompt case, and it must print nothing at all.
      let second = runExportSplit(c, "bash",
        [(name: "__REPRO_APPLIED", value: marker)])
      check second.exitCode == 0
      check second.stderr.strip() == ""
      check second.stdout.contains("no-op")

    test "progress_quiet_suppresses_the_announcement":
      let c = prepareCase("repro-devenv-announce-quiet")
      defer: removeDir(c.tempRoot)
      let outcome = runExportSplit(c, "bash",
        [(name: "REPROBUILD_PROGRESS", value: "quiet")])
      check outcome.exitCode == 0
      check not outcome.stderr.contains("repro dev-env: preparing")
      check not outcome.stderr.contains("repro dev-env: ready in")
      # Still a working activation, not a silenced failure.
      check outcome.stdout.contains("__REPRO_APPLIED=")
