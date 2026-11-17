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
  import std/[os, osproc, posix, strtabs]

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
