## The thin daemon client (`build/bin/repro`) must never hand over to ITSELF.
##
## THE DEFECT THIS PINS. `resolveFullCli` in `apps/repro-client` honours two
## overrides for the engine it hands every non-routable invocation to —
## `REPRO_FULL_CLI` and `REPRO_PUBLIC_CLI_PATH` — and returned either one
## unchecked. When one of them named the thin client, `handOver` `execv`ed the
## thin client with the same argv and the same environment, which resolved the
## same override and `execv`ed again. Forever, at ONE pid: no child, no output,
## a core spent in `execve`. The sibling probe had always guarded exactly this
## ("exec'ing ourselves is an infinite loop, not a fallback"); the overrides
## did not.
##
## WHY IT COST HOURS AND NOT A RED TEST. From outside the loop looks like
## healthy work. The engine spawned `build/bin/repro internal io monitor …` for
## a monitored helper edge; that process never became the engine, never
## started the monitored child, and never exited, while its parent waited on
## it. It burns CPU, so a no-progress watchdog (no output AND no CPU) never
## fires. `t_develop_override_records_the_identity_it_replaced` set
## `REPRO_PUBLIC_CLI_PATH=build/bin/repro` — correct before the thin client
## took that name, a self-reference after — and each of its cases ran ~96
## minutes until a hard ceiling killed it.
##
## THE CONTRACT. Both overrides name the ENGINE (`apps/repro-trampoline` sets
## `REPRO_PUBLIC_CLI_PATH` to the prefix's `bin/reprobuild`, "never `exe`").
## One naming the thin client is a misconfiguration, and the client now REFUSES
## it: exit 127 at once, with a diagnostic naming the variable and the path.
##
## WHAT MAKES THIS FAIL. Reverting the `namesThisImage` checks in
## `resolveFullCli`. Each refusal case then sees a process still alive at the
## deadline — its `/proc/<pid>/exe` still the thin client, its argv unchanged —
## and fails on `exited`, printing that evidence. The deadline is what keeps the
## pre-fix run from hanging the suite the way the original defect did; the
## process is SIGKILLed by pid (an `execv` loop never changes pid, so the pid is
## always the looping process).
##
## WHY IT CANNOT PASS VACUOUSLY. The same copied binary is first shown to hand
## over THROUGH the override it is about to be refused on (`the copy hands over
## to the engine an override names`): it reaches the real engine and prints its
## version. So "exited 127" below cannot mean "this binary never reads the
## variable" or "this binary cannot exec at all". And each refusal is matched
## on its own sentence, which names the variable — not on the generic "no
## reprobuild image" 127 that a copy with no sibling engine would also produce
## if the override were simply ignored.
##
## Test-double policy: NO mocks, doubles, or fakes. The client is the real
## `build/bin/repro` (build-graph artifact `reprobuild.apps.repro`), copied into
## a private directory so that NO sibling `reprobuild`, `.reprobuild-wrapped`
## or `libexec` engine can be found beside it and the override is the only way
## it can name an engine. The engine in the precondition case is the real
## `build/bin/reprobuild` (`reprobuild.apps.reprobuild`). Both are declared on
## this file's execute edge.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, times, unittest]
when defined(posix):
  import std/posix

import repro_core/cli_images
import repro_test_support

const
  ExitExecFailed = 127
  Deadline = initDuration(seconds = 20)
    ## A refusal is a few milliseconds. The loop never ends, so ANY bound
    ## separates the two; this one is generous for a loaded CI host.
  Overrides = ["REPRO_FULL_CLI", "REPRO_PUBLIC_CLI_PATH"]

type
  BoundedRun = object
    exited: bool
    code: int
    output: string
    evidence: string
      ## When the process outlived the deadline: what it was at that moment.

proc thinClient(): string =
  requireBinary(getCurrentDir() / "build" / "bin" / reproThinClientExeName(),
    "reprobuild.apps.repro")

proc engine(): string =
  requireBinary(getCurrentDir() / "build" / "bin" / reprobuildEngineExeName(),
    "reprobuild.apps.reprobuild")

proc isolatedCopy(root: string): string =
  ## The thin client alone in a directory of its own, so no engine can be
  ## resolved beside it.
  result = root / "bin" / reproThinClientExeName()
  createDir(root / "bin")
  copyFileWithPermissions(thinClient(), result)
  doAssert not fileExists(root / "bin" / reprobuildEngineExeName())
  doAssert not dirExists(root / "libexec")

proc procEvidence(pid: int): string =
  when defined(linux):
    var children = "?"
    try:
      children = readFile("/proc/" & $pid & "/task/" & $pid & "/children")
    except CatchableError:
      discard
    try:
      result = "exe=" & expandSymlink("/proc/" & $pid & "/exe") &
        " argv=" & readFile("/proc/" & $pid & "/cmdline").replace('\0', ' ') &
        " children=[" & children.strip() & "]"
    except CatchableError as err:
      result = "unreadable: " & err.msg
  else:
    result = "pid " & $pid & " still running"

proc runBounded(exe: string; args: openArray[string];
                env: openArray[(string, string)]): BoundedRun =
  ## Run `exe` directly (no shell, so the pid IS the client) with both
  ## overrides removed and `env` applied, and stop it at `Deadline`.
  var envTable = newStringTable()
  for key, value in envPairs():
    envTable[key] = value
  for name in Overrides:
    if envTable.hasKey(name):
      envTable.del(name)
  # Not a build, so the client never tries the daemon; unset anyway so the
  # host's configuration cannot steer it.
  if envTable.hasKey("REPRO_DAEMON"):
    envTable.del("REPRO_DAEMON")
  for (key, value) in env:
    envTable[key] = value
  let p = startProcess(exe, args = args, env = envTable,
    options = {poStdErrToStdOut})
  defer: p.close()
  let stop = getTime() + Deadline
  while p.running and getTime() < stop:
    sleep(20)
  if p.running:
    result.evidence = procEvidence(p.processID)
    when defined(posix):
      discard posix.kill(Pid(p.processID), SIGKILL)
    else:
      p.kill()
    discard p.waitForExit()
    return
  result.exited = true
  result.code = p.peekExitCode()
  result.output = p.outputStream.readAll()

proc describe(r: BoundedRun): string =
  "exited=" & $r.exited & " code=" & $r.code & "\noutput=" & r.output &
    "\nstill running after " & $Deadline & ": " & r.evidence

suite "the thin client never hands over to itself":

  test "the copy hands over to the engine an override names":
    ## The precondition every refusal below leans on: this copy READS the
    ## overrides and can exec what they name.
    let root = createTempDir("repro-thin-self", "")
    defer: removeDir(root)
    let copy = isolatedCopy(root)
    for variable in Overrides:
      let r = runBounded(copy, ["--version"], [(variable, engine())])
      checkpoint(variable & ": exited=" & $r.exited & " code=" & $r.code &
        "\noutput=" & r.output & "\n" & r.evidence)
      check r.exited
      check r.code == 0
      check r.output.strip().len > 0
      check not r.output.contains("names this thin client")

  test "REPRO_PUBLIC_CLI_PATH naming the client itself is refused, not looped":
    let root = createTempDir("repro-thin-self", "")
    defer: removeDir(root)
    let copy = isolatedCopy(root)
    let r = runBounded(copy, ["--version"],
      [("REPRO_PUBLIC_CLI_PATH", copy)])
    checkpoint(describe(r))
    check r.exited
    check r.code == ExitExecFailed
    check r.output.contains("REPRO_PUBLIC_CLI_PATH names this thin client")
    check r.output.contains(copy)

  test "REPRO_FULL_CLI naming the client itself is refused, not looped":
    let root = createTempDir("repro-thin-self", "")
    defer: removeDir(root)
    let copy = isolatedCopy(root)
    let r = runBounded(copy, ["--version"],
      [("REPRO_FULL_CLI", copy)])
    checkpoint(describe(r))
    check r.exited
    check r.code == ExitExecFailed
    check r.output.contains("REPRO_FULL_CLI names this thin client")
    check r.output.contains(copy)

  when defined(posix):
    test "a symlink spelling of the client is still the client":
      ## Identity, not spelling: a path that differs as a string but reaches
      ## the same file loops just the same.
      let root = createTempDir("repro-thin-self", "")
      defer: removeDir(root)
      let copy = isolatedCopy(root)
      let alias = root / "alias-of-repro"
      createSymlink(copy, alias)
      doAssert alias != copy and sameFile(alias, copy)
      let r = runBounded(copy, ["--version"],
        [("REPRO_PUBLIC_CLI_PATH", alias)])
      checkpoint(describe(r))
      check r.exited
      check r.code == ExitExecFailed
      check r.output.contains("REPRO_PUBLIC_CLI_PATH names this thin client")
      check r.output.contains(alias)
