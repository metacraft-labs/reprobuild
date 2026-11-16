## An inline-exec action has a deadline, and its output cannot hold it.
##
## The 2026-11-15 win-ci-bare-001 outage: the deploy agent ran the elevated
## Python tool-cache seed, stopped reading the child's output pipe after the
## first short read, and then waited on the child with no deadline. The child
## blocked writing ~805 KB into the full pipe, the agent's tick never ended,
## and the runner it had drained stayed stopped for ~21 h.
##
## Each case below runs a real `/bin/sh` child through the production spawn
## (`runInlineExecCall`, or `runBoundedExec` underneath it). The negative
## controls run the same child through the shape the agent used before, and
## require that shape to still be stuck after a few seconds — so a case that
## passes cannot be passing because its child was too gentle to matter.

import std/[os, osproc, streams, strutils, tempfiles, times, unittest]

import repro_elevation

when defined(posix):
  import std/posix

proc shellOp(address, script: string; timeoutSeconds = 0): PrivilegedOperation =
  PrivilegedOperation(kind: pokInlineExecCall,
    address: address,
    iecExecutable: "/bin/sh",
    iecArguments: @["-c", script],
    iecWorkingDirectory: "",
    iecEnvironment: @[],
    iecToolIdentityRefs: @[],
    iecAcceptExitCodes: @[0],
    iecTimeoutSeconds: timeoutSeconds)

proc processAlive(pid: int): bool =
  ## Alive and not a zombie. A killed orphan is reaped by init or a subreaper
  ## at its own pace, so a zombie counts as dead.
  when defined(posix):
    if kill(Pid(pid), 0) != 0:
      return false
    when defined(linux):
      try:
        let stat = readFile("/proc/" & $pid & "/stat")
        let close = stat.rfind(')')
        if close >= 0 and close + 2 < stat.len and stat[close + 2] == 'Z':
          return false
      except CatchableError:
        return false
    return true
  else:
    false

proc waitUntilDead(pid: int; seconds: float): bool =
  let until = epochTime() + seconds
  while epochTime() < until:
    if not processAlive(pid):
      return true
    sleep(50)
  not processAlive(pid)

const
  # 4 MiB to stdout and 4 MiB to stderr: far past any pipe buffer (64 KiB on
  # Linux, 4 KiB to 64 KiB on Windows), and ten times what the seed wrote.
  ChattyScript =
    "head -c 4194304 /dev/zero | tr '\\000' o; " &
    "head -c 4194304 /dev/zero | tr '\\000' e >&2; " &
    "echo END-OF-CHATTY-CHILD"

suite "inline-exec actions are bounded and cannot be held by their output":

  test "a child that sleeps past its deadline is killed with its whole tree and the action fails":
    when defined(posix):
      let dir = createTempDir("iec-deadline-", "")
      defer:
        try: removeDir(dir) except CatchableError: discard
      let pidFile = dir / "grandchild.pid"
      # The shell starts a grandchild and waits on it: the shape of the seed
      # wrapper (powershell -Command) waiting on setup.ps1.
      let op = shellOp("sleeps-past-deadline",
        "sleep 300 & echo $! > '" & pidFile & "'; echo started; wait",
        timeoutSeconds = 2)
      let t0 = epochTime()
      var msg = ""
      expect EProtocol:
        try:
          discard runInlineExecCall(op)
        except EProtocol as e:
          msg = e.msg
          raise
      let elapsed = epochTime() - t0
      check elapsed >= 1.5
      check elapsed < 30.0
      check "deadline of 2 s" in msg
      check "sleeps-past-deadline" in msg
      # The output written before the kill is still in the diagnostic.
      check "started" in msg
      check fileExists(pidFile)
      let grandchild = parseInt(readFile(pidFile).strip())
      # The whole tree, not just the direct child: Task Scheduler killing only
      # repro.exe is what left the seed's wrapper behind on the box.
      check waitUntilDead(grandchild, 10.0)

  test "a child that writes several MB to stdout and stderr completes":
    when defined(posix):
      let t0 = epochTime()
      let outcome = runInlineExecCall(
        shellOp("chatty", ChattyScript, timeoutSeconds = 120))
      check outcome.exitCode == 0
      check epochTime() - t0 < 60.0
      check outcome.stdoutTail.strip().endsWith("END-OF-CHATTY-CHILD")
      check outcome.stdoutTail.len <= MaxCapturedOutputTailBytes
      # And all of it was written: nothing was dropped to make room.
      let bounded = runBoundedExec(@["/bin/sh", "-c", ChattyScript],
        timeoutMs = 120_000)
      check not bounded.timedOut
      check bounded.exitCode == 0
      check bounded.outputBytes >= 2'i64 * 4_194_304

  test "NEGATIVE CONTROL: the pre-fix spawn shape is stuck on the same chatty child":
    when defined(posix):
      # What the box ran (reprobuild 39ad8158): read the merged pipe once, then
      # wait. On Windows `readAll` stops after the first ReadFile that does not
      # fill its buffer; one `readData` call is that read. After it nobody
      # reads the pipe, so a child with more to write blocks forever.
      let p = startProcess("/bin/sh", args = @["-c", ChattyScript],
        options = {poStdErrToStdOut})
      var buf = newString(1024)
      let got = p.outputStream.readData(addr buf[0], buf.len)
      check got > 0
      var exitedOnItsOwn = false
      let until = epochTime() + 5.0
      while epochTime() < until:
        if not p.running:
          exitedOnItsOwn = true
          break
        sleep(50)
      # Still running five seconds later: blocked on the full pipe. The
      # bounded spawn finished the same child in the case above.
      check not exitedOnItsOwn
      p.kill()
      discard p.waitForExit()
      p.close()

  test "a descendant that keeps stdout open does not hold the action past the child's exit":
    when defined(posix):
      let dir = createTempDir("iec-holder-", "")
      defer:
        try: removeDir(dir) except CatchableError: discard
      let pidFile = dir / "holder.pid"
      let t0 = epochTime()
      let outcome = runInlineExecCall(shellOp("leaves-a-holder",
        "sleep 60 & echo $! > '" & pidFile & "'; echo child-done",
        timeoutSeconds = 45))
      check outcome.exitCode == 0
      check epochTime() - t0 < 15.0
      check "child-done" in outcome.stdoutTail
      if fileExists(pidFile):
        discard kill(Pid(parseInt(readFile(pidFile).strip())), SIGKILL)

  test "NEGATIVE CONTROL: on a pipe, that descendant keeps EOF from arriving":
    when defined(posix):
      # `drainStream` (the current pipe reader) returns at EOF, and EOF needs
      # every write end closed. With the child gone and its grandchild still
      # holding stdout, poll() on the read end reports neither data nor
      # hang-up: a reader waiting for EOF waits for the grandchild.
      let p = startProcess("/bin/sh",
        args = @["-c", "sleep 60 & echo $!; exit 0"],
        options = {poStdErrToStdOut})
      let holder = parseInt(p.outputStream.readLine().strip())
      check p.waitForExit() == 0
      var fds = [TPollfd(fd: p.outputHandle.cint, events: POLLIN)]
      let ready = poll(addr fds[0], 1, 3000)
      check ready == 0          # timed out: no EOF while the holder lives
      discard kill(Pid(holder), SIGKILL)
      let readyAfter = poll(addr fds[0], 1, 5000)
      check readyAfter == 1     # control of the control: EOF once it is gone
      p.close()

  test "a child that reads stdin sees EOF instead of waiting forever":
    when defined(posix):
      let t0 = epochTime()
      let outcome = runInlineExecCall(shellOp("reads-stdin",
        "cat >/dev/null; echo after-stdin", timeoutSeconds = 30))
      check outcome.exitCode == 0
      check epochTime() - t0 < 10.0
      check "after-stdin" in outcome.stdoutTail

  test "NEGATIVE CONTROL: with a stdin pipe nobody closes, the same child waits":
    when defined(posix):
      let p = startProcess("/bin/sh", args = @["-c", "cat >/dev/null; echo x"],
        options = {poStdErrToStdOut})
      sleep(3000)
      check p.running
      p.kill()
      discard p.waitForExit()
      p.close()

  test "a non-zero exit within the deadline still fails as before":
    when defined(posix):
      expect EProtocol:
        discard runInlineExecCall(shellOp("exits-3", "echo nope; exit 3",
          timeoutSeconds = 30))

  test "the deadline comes from the edge, then the environment, then the default":
    let saved = getEnv(InlineExecTimeoutEnvVar)
    let hadSaved = existsEnv(InlineExecTimeoutEnvVar)
    defer:
      if hadSaved: putEnv(InlineExecTimeoutEnvVar, saved)
      else: delEnv(InlineExecTimeoutEnvVar)
    delEnv(InlineExecTimeoutEnvVar)
    check effectiveInlineExecTimeoutSeconds(shellOp("a", "true")) ==
      DefaultInlineExecTimeoutSeconds
    check effectiveInlineExecTimeoutSeconds(
      shellOp("a", "true", timeoutSeconds = 3)) == 3
    putEnv(InlineExecTimeoutEnvVar, "7")
    check effectiveInlineExecTimeoutSeconds(shellOp("a", "true")) == 7
    # The edge's own deadline beats the environment.
    check effectiveInlineExecTimeoutSeconds(
      shellOp("a", "true", timeoutSeconds = 3)) == 3
    # `<= 0` turns the default off.
    putEnv(InlineExecTimeoutEnvVar, "0")
    check effectiveInlineExecTimeoutSeconds(shellOp("a", "true")) == 0
    # Garbage is ignored rather than turning the deadline off.
    putEnv(InlineExecTimeoutEnvVar, "soon")
    check effectiveInlineExecTimeoutSeconds(shellOp("a", "true")) ==
      DefaultInlineExecTimeoutSeconds
    # The default stays below the DeployAgent task's 5-hour limit, so the
    # agent, not Task Scheduler, ends a wedged action.
    check DefaultInlineExecTimeoutSeconds < 5 * 3600
