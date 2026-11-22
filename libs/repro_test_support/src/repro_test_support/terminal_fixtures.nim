## A real pseudo-terminal for tests whose subject asks `isatty`.
##
## Nothing but a terminal device makes `isatty(fd)` answer true: not a pipe,
## not a file, not an environment variable. A command that behaves
## differently on a terminal (a client that routes only when its stderr is
## not one, an interactive shell that refuses to start without one on its
## standard input) can therefore only be tested on its terminal arm through a
## real pty. These helpers open one and run a program with one of its
## standard streams on the pty's slave side.
##
## `posix_openpt`, `grantpt`, `unlockpt` and `ptsname` are POSIX
## (https://pubs.opengroup.org/onlinepubs/9799919799/functions/posix_openpt.html)
## and live in `<stdlib.h>`; Nim's `std/posix` does not declare them.

when defined(posix):
  import std/[os, osproc, posix, strtabs, strutils, times]

  proc posix_openpt(oflag: cint): cint
    {.importc: "posix_openpt", header: "<stdlib.h>".}
  proc grantpt(fd: cint): cint {.importc: "grantpt", header: "<stdlib.h>".}
  proc unlockpt(fd: cint): cint {.importc: "unlockpt", header: "<stdlib.h>".}
  proc ptsname(fd: cint): cstring {.importc: "ptsname", header: "<stdlib.h>".}

  proc openPtySlavePath*(): tuple[master: cint; slave: string] =
    ## Returns the master fd — which the CALLER must keep open for the slave
    ## to stay usable, and close when done — and the filesystem path of its
    ## slave side, which a shell redirection can open. The master is opened
    ## with `O_NOCTTY`, so it never becomes this process's controlling
    ## terminal.
    let master = posix_openpt(O_RDWR or O_NOCTTY)
    doAssert master >= 0, "posix_openpt failed"
    doAssert grantpt(master) == 0, "grantpt failed"
    doAssert unlockpt(master) == 0, "unlockpt failed"
    let name = ptsname(master)
    doAssert name != nil, "ptsname failed"
    (master, $name)

  type
    TerminalStdinRun* = tuple[code: int; stdout, stderr, ptyText: string]
      ## The program's exit status, its stdout and stderr (captured to
      ## files, apart), and whatever it wrote to the terminal.

  proc runWithTerminalStdin*(program: string; args: openArray[string];
                             cwd, scratchDir: string;
                             env: StringTableRef = nil): TerminalStdinRun =
    ## Run `program` with its standard input on a fresh pty's slave side and
    ## stdout / stderr captured to files under `scratchDir`.
    ##
    ## The redirection is done by an `exec`-ing `/bin/sh`, so the status
    ## returned is `program`'s and not a wrapper shell's. The master is
    ## drained while the program runs: a pty is a small kernel buffer, and a
    ## program that writes to its terminal (`/dev/tty`, or a shell echoing)
    ## would block on a full one while this waited for it to exit.
    let (master, slave) = openPtySlavePath()
    defer: discard close(master)
    let outPath = scratchDir / "terminal-run-stdout"
    let errPath = scratchDir / "terminal-run-stderr"
    var shArgs = @["-c",
      "exec \"$0\" \"$@\" <" & quoteShell(slave) & " >" & quoteShell(outPath) &
        " 2>" & quoteShell(errPath), program]
    for arg in args:
      shArgs.add(arg)
    let process = startProcess("/bin/sh", workingDir = cwd, args = shArgs,
      env = env, options = {})
    defer: process.close()
    let flags = fcntl(master, F_GETFL, 0)
    discard fcntl(master, F_SETFL, flags or O_NONBLOCK)
    var chunk = newString(8192)
    var drained = ""
    # Every byte readable right now. EAGAIN (nothing yet) and EIO (no slave
    # writer left) both read as `got <= 0`; only `running` decides the end.
    template pumpNow() =
      while true:
        let got = read(master, addr chunk[0], chunk.len)
        if got <= 0:
          break
        drained.add(chunk[0 ..< got])
    while process.running:
      pumpNow()
      sleep(2)
    pumpNow()
    result.code = process.peekExitCode()
    result.ptyText = drained
    result.stdout = if fileExists(outPath): readFile(outPath) else: ""
    result.stderr = if fileExists(errPath): readFile(errPath) else: ""

  type
    TerminalStep* = tuple[waitFor, send: string]
      ## One exchange with a program on a terminal: wait until everything
      ## it has written so far contains `waitFor`, then type `send`.

    TerminalSession* = tuple[code: int; text: string; timedOut: bool]
      ## The program's exit status, everything it wrote to the terminal
      ## (stdout and stderr both go there), and whether the session was cut
      ## short because a `waitFor` never appeared or the program did not
      ## exit in time.

  var TIOCSCTTY {.importc, header: "<sys/ioctl.h>".}: culong

  proc runOnTerminal*(program: string; args: openArray[string]; cwd: string;
                      steps: openArray[TerminalStep];
                      env: StringTableRef = nil;
                      timeoutMs = 120_000): TerminalSession =
    ## Run `program` the way a terminal emulator runs an interactive shell:
    ## in a session of its own (`setsid`), with a fresh pty's slave side as
    ## its controlling terminal (`TIOCSCTTY`) and all three standard
    ## streams, and type `steps` into it. A shell started like this is
    ## interactive in the full sense: it prints its prompts and runs its
    ## prompt hooks (bash's `PROMPT_COMMAND`, zsh's `precmd`, fish's
    ## `fish_prompt` event). A shell reading a pipe does not all do that
    ## (fish fires no `fish_prompt`), and fish refuses to stay interactive
    ## without a controlling terminal ("No TTY for interactive shell").
    ##
    ## `program` is looked up on the `PATH` of this process when it has no
    ## directory part. `env` replaces the environment (nil: this process's).
    ## Input is typed only once the program has written the step's
    ## `waitFor`, so nothing is typed before the shell reads its terminal.
    ## On a timeout the program is killed, by the pid this proc started and
    ## no other.
    ##
    ## `setsid`, `TIOCSCTTY` and the pty calls are POSIX
    ## (https://pubs.opengroup.org/onlinepubs/9799919799/functions/setsid.html,
    ## https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/termios.h.html)
    ## and `TIOCSCTTY` is the ioctl Linux and the BSDs (macOS included) use
    ## to take a terminal as the controlling one.
    let (master, slave) = openPtySlavePath()
    defer: discard close(master)
    let exe =
      if program.contains('/'): program
      else: findExe(program)
    doAssert exe.len > 0, "runOnTerminal: " & program & " is not on PATH"
    # Everything the child needs is built before `fork`: after it, in a
    # threaded parent, the child may only make async-signal-safe calls.
    var argvSeq = @[exe]
    for a in args:
      argvSeq.add(a)
    var envSeq: seq[string]
    if env == nil:
      for k, v in envPairs():
        envSeq.add(k & "=" & v)
    else:
      for k, v in env:
        envSeq.add(k & "=" & v)
    let argv = allocCStringArray(argvSeq)
    let envp = allocCStringArray(envSeq)
    defer:
      deallocCStringArray(argv)
      deallocCStringArray(envp)
    let cSlave = slave.cstring
    let cCwd = cwd.cstring
    let cExe = exe.cstring
    let pid = fork()
    doAssert pid >= 0, "fork failed"
    if pid == 0:
      discard setsid()
      let fd = posix.open(cSlave, O_RDWR)
      if fd < 0: exitnow(126)
      discard ioctl(fd, uint(TIOCSCTTY), 0)
      discard dup2(fd, 0)
      discard dup2(fd, 1)
      discard dup2(fd, 2)
      if fd > 2: discard posix.close(fd)
      discard posix.close(master)
      if chdir(cCwd) != 0: exitnow(126)
      discard execve(cExe, argv, envp)
      exitnow(127)
    let flags = fcntl(master, F_GETFL, 0)
    discard fcntl(master, F_SETFL, flags or O_NONBLOCK)
    var chunk = newString(8192)
    var text = ""
    template pumpNow() =
      while true:
        let got = read(master, addr chunk[0], chunk.len)
        if got <= 0:
          break
        text.add(chunk[0 ..< got])
    let deadline = epochTime() + timeoutMs.float / 1000.0
    var next = 0
    var searchFrom = 0
    var status: cint = 0
    while true:
      pumpNow()
      let waited = waitpid(pid, status, WNOHANG)
      if waited == pid:
        break
      if next < steps.len:
        let at = text.find(steps[next].waitFor, searchFrom)
        if at >= 0:
          searchFrom = at + steps[next].waitFor.len
          let line = steps[next].send
          if line.len > 0:
            discard write(master, unsafeAddr line[0], line.len)
          inc next
      if epochTime() > deadline:
        result.timedOut = true
        discard kill(pid, SIGKILL)
        discard waitpid(pid, status, 0)
        break
      sleep(5)
    pumpNow()
    result.code =
      if WIFEXITED(status): WEXITSTATUS(status).int
      else: 128 + WTERMSIG(status).int
    result.text = text
