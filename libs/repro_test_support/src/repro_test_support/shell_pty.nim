## An interactive shell on a pseudo-terminal, driven by keystrokes.
##
## Completion is a property of a shell's line editor (bash's readline, zsh's
## zle, fish's reader, PSReadLine): it runs when the Tab key arrives on a
## terminal, and nothing but a terminal makes the editor run at all. A test
## that asserts "a fresh shell completes `repro wor<Tab>`" therefore has to
## start the real shell as the session leader of a real pty, type into its
## master side and read back what the shell drew. That is what this module
## does; there is no lighter way to drive those editors, so nothing here is
## a mock.
##
## Adapted from the driver of nim-cli-spec's real-shell completion test.
## Every read has a deadline. `stop` ends the session with `exit` and, if the
## shell is still there, sends SIGKILL to that session's own pid only: a test
## never signals a process it did not start, and never by name.

when defined(posix):
  import std/[posix, strutils, times]

  import ./terminal_fixtures

  proc ioctlArg(fd: cint; request: culong): cint {.importc: "ioctl",
    header: "<sys/ioctl.h>", varargs.}
  var TIOCSCTTY {.importc, header: "<sys/ioctl.h>".}: culong
  var TIOCSWINSZ {.importc, header: "<sys/ioctl.h>".}: culong
  type
    Winsize {.importc: "struct winsize", header: "<sys/ioctl.h>".} = object
      ws_row, ws_col, ws_xpixel, ws_ypixel: cushort

  type
    ShellSession* = object
      ## One shell on one pseudo-terminal.
      name*: string
      pid*: Pid
      fd: cint
      output*: string  ## everything the shell drew so far
      seen: int        ## how much of `output` earlier waits consumed
      exited*: bool

  proc spawnShell*(name, exe: string; args: openArray[string];
                   env: openArray[(string, string)]; cwd: string):
      ShellSession =
    ## Starts `exe` with exactly `env` as the session leader of a new
    ## pseudo-terminal (250 columns, so no line wraps).
    let (master, slaveName) = openPtySlavePath()
    var size = Winsize(ws_row: 50, ws_col: 250)
    discard ioctlArg(master, TIOCSWINSZ, addr size)
    # Everything the child needs is prepared before fork: after it, the
    # child only makes system calls.
    var argvList = @[exe]
    for a in args:
      argvList.add(a)
    var envList: seq[string] = @[]
    for (k, v) in env:
      envList.add(k & "=" & v)
    let argv = allocCStringArray(argvList)
    let envp = allocCStringArray(envList)
    let cSlave = slaveName.cstring
    let cExe = exe.cstring
    let cCwd = cwd.cstring
    let pid = fork()
    doAssert pid >= 0, "fork failed"
    if pid == 0:
      discard setsid()
      let slave = posix.open(cSlave, O_RDWR)
      if slave < 0:
        exitnow(126)
      discard ioctlArg(slave, TIOCSCTTY, 0)
      discard ioctlArg(slave, TIOCSWINSZ, addr size)
      discard dup2(slave, 0)
      discard dup2(slave, 1)
      discard dup2(slave, 2)
      if slave > 2:
        discard close(slave)
      discard close(master)
      discard chdir(cCwd)
      discard execve(cExe, argv, envp)
      exitnow(127)
    deallocCStringArray(argv)
    deallocCStringArray(envp)
    ShellSession(name: name, pid: pid, fd: master)

  proc send*(s: var ShellSession; text: string) =
    ## Types `text` (`\t` is Tab, `\r` is Enter).
    var off = 0
    while off < text.len:
      let n = write(s.fd, unsafeAddr text[off], text.len - off)
      if n <= 0:
        break
      off += n

  proc answerQueries(s: var ShellSession; fresh: string) =
    ## Terminal queries a shell waits for: the cursor position and the
    ## primary device attributes.
    if "\e[6n" in fresh:
      s.send("\e[1;1R")
    if "\e[c" in fresh or "\e[0c" in fresh:
      s.send("\e[?62;22c")

  proc pump(s: var ShellSession; waitMs: int): bool =
    ## Reads what is available within `waitMs`; false when nothing came.
    var fds = [TPollfd(fd: s.fd, events: POLLIN)]
    let ready = poll(addr fds[0], 1, cint(waitMs))
    if ready <= 0:
      return false
    var buf: array[4096, char]
    let n = read(s.fd, addr buf[0], buf.len)
    if n <= 0:
      s.exited = true
      return false
    var fresh = newString(n)
    copyMem(addr fresh[0], addr buf[0], n)
    s.output.add(fresh)
    s.answerQueries(fresh)
    true

  proc waitFor*(s: var ShellSession; marker: string; timeoutMs: int): int =
    ## Reads until `marker` appears after what earlier waits consumed;
    ## returns its index in `output`, or -1 at the deadline.
    let deadline = epochTime() + timeoutMs / 1000
    while true:
      let at = s.output.find(marker, s.seen)
      if at >= 0:
        s.seen = at + marker.len
        return at
      if s.exited or epochTime() > deadline:
        return -1
      discard s.pump(200)

  proc settle*(s: var ShellSession; quietMs, timeoutMs: int) =
    ## Reads until the terminal has been quiet for `quietMs`.
    let deadline = epochTime() + timeoutMs / 1000
    while epochTime() < deadline:
      if not s.pump(quietMs):
        return

  proc lineAfter*(s: var ShellSession; marker: string;
                  timeoutMs: int): string =
    ## The rest of the line on which `marker` next appears ("" at the
    ## deadline), `marker` included.
    let at = s.waitFor(marker, timeoutMs)
    if at < 0:
      return ""
    discard s.waitFor("\n", timeoutMs)
    result = s.output[at ..< s.seen].strip()

  proc drawnSince*(s: ShellSession; mark: int): string =
    ## What the shell drew after `output` had `mark` bytes.
    if mark >= s.output.len: "" else: s.output[mark .. ^1]

  proc stop*(s: var ShellSession) =
    ## Ends the session: `exit`, then SIGKILL to this session's own pid if
    ## it is still running. Nothing else is signalled.
    if s.pid <= 0:
      return
    s.send("\x03\rexit\r")
    let deadline = epochTime() + 5
    var status: cint
    while epochTime() < deadline:
      discard s.pump(100)
      if waitpid(s.pid, status, WNOHANG) == s.pid:
        s.pid = 0
        break
    if s.pid > 0:
      discard kill(s.pid, SIGKILL)
      discard waitpid(s.pid, status, 0)
      s.pid = 0
    discard close(s.fd)

  proc transcript*(s: ShellSession): string =
    ## The terminal output with escape sequences made visible.
    s.output.replace("\e", "<ESC>")
