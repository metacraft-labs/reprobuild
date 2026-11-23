## The probe's confinement (NPC-AREQ8 step 3, threat model G6).
##
## The probe runs `nimble dump --json` on a `.nimble` the static reader
## cannot read, which evaluates the file's NimScript: package code, with
## `exec`, `writeFile` and everything else NimScript offers. `runProbe` runs
## it in a sandbox (bubblewrap) that gives it:
##
## * **no network**: new network, user, PID, IPC, UTS and cgroup
##   namespaces (`--unshare-all`); inside there is only a loopback
##   interface of the sandbox's own, so no address of the host or beyond it
##   is reachable;
## * **only the host's system directories, read-only**: the sandbox's root
##   is an empty directory of its own, made read-only, into which
##   ``SystemDirs`` (and the directories of `nim` and `nimble`) are bound
##   read-only. Nothing else of the host exists inside: not `/home`,
##   `/root`, `/tmp`, `/var` or `/run`, and not `/nix/var`, whose daemon
##   socket would hand package code a build service that reaches the
##   network. A Unix socket is reachable through any mount that shows it,
##   read-only or not, so the host's tree is bound by allow-list, never as
##   a whole;
## * **writes to scratch only**: the probe's scratch directory is the only
##   writable bind (`/dev` is the sandbox's own, discarded with it);
## * **an empty `NIMBLE_DIR`** in scratch, `HOME` in scratch, and an
##   environment built from nothing: `PATH` names the directories of `nim`
##   and `nimble` and nothing else;
## * **bounded time and output**: the sandbox is killed, with everything in
##   it (`--die-with-parent`; its PID namespace ends with its first
##   process), when the wall-clock limit passes. Its output is read while
##   it runs, so a large dump cannot stall it; at most ``MaxProbeDumpBytes``
##   of it are kept, and a dump over that is a failure.
##
## The probe reads the `.nimble` file alone, copied into scratch: no other
## file of the package is in the sandbox.
##
## Its outcome is data for the caller: the dump on success, and otherwise
## the exit status and the probe's own diagnostics, which name what the
## package's code tried (the failed `exec` command, the refused write).
## The caller keeps a failure as a capture record (`capture`,
## `probe-violation`).
##
## Not built here: per-access capture of what the probe attempted (the
## monitor of spec § 4.3), and the generator's use of the probe, which
## still refuses `probe = "sandboxed"`.

import std/[os, osproc, posix, streams, strutils, times]

import repro_core/ambient_execution

import ./origin_git

const
  DefaultProbeWallSeconds* = 60
  MaxProbeDiagnosticBytes* = 16 * 1024
  MaxProbeDumpBytes* = 4 * 1024 * 1024
  SystemDirs* = ["/nix/store", "/usr", "/bin", "/sbin", "/lib", "/lib32",
    "/lib64", "/etc"]
    ## the host directories the sandbox sees, read-only, when they exist:
    ## where a `nim` and a `nimble` and what they load live. Each must hold
    ## no Unix socket of a service (see the module docstring)

type
  ProbeConfig* = object
    sandboxBin*: string ## bubblewrap (`bwrap`), an absolute path
    nimbleBin*: string  ## `nimble`, an absolute path
    nimBin*: string     ## the `nim` NimScript is evaluated with
    wallSeconds*: int   ## <= 0: ``DefaultProbeWallSeconds``

  ProbeOutcome* = object
    ok*: bool           ## `nimble dump --json` exited 0
    exitCode*: int
    timedOut*: bool
    dump*: string       ## its standard output, when it succeeded
    diagnostics*: string
      ## its standard error, and for a failure its standard output (where
      ## Nimble reports a failed evaluation), at most
      ## ``MaxProbeDiagnosticBytes``

  ProbeError* = object of CatchableError

proc realDir(bin: string): string =
  if not bin.isAbsolute or not fileExists(bin):
    raise newException(ProbeError, "the probe needs an absolute path to an " &
      "existing executable, not " & bin.escape())
  parentDir(expandFilename(bin))

proc under(path, dir: string): bool =
  path == dir or path.startsWith(dir & "/")

proc probeArgs*(cfg: ProbeConfig; scratch: string): seq[string] =
  ## The sandbox's command line (see the module docstring).
  let nimbleDir = realDir(cfg.nimbleBin)
  let nimDir = realDir(cfg.nimBin)
  result = @["--unshare-all", "--die-with-parent", "--new-session"]
  var bound: seq[string]
  for d in SystemDirs:
    if dirExists(d):
      bound.add d
      result.add @["--ro-bind", d, d]
  # The tools stay visible when they live elsewhere (a user's toolchain).
  for d in [nimbleDir, nimDir]:
    var seen = false
    for b in bound:
      if d.under(b): seen = true
    if not seen:
      bound.add d
      result.add @["--ro-bind", d, d]
  result.add @["--dev", "/dev", "--proc", "/proc"]
  result.add @["--bind", scratch, scratch]
  # Every mount point made, the sandbox's own root becomes read-only too
  # (not recursively: scratch stays writable).
  result.add @["--remount-ro", "/"]
  result.add @["--chdir", scratch / "pkg", "--clearenv",
    "--setenv", "HOME", scratch / "home",
    "--setenv", "NIMBLE_DIR", scratch / "nimble",
    "--setenv", "XDG_CACHE_HOME", scratch / "cache",
    "--setenv", "TMPDIR", scratch / "tmp",
    "--setenv", "PATH", nimDir & ":" & nimbleDir,
    "--", expandFilename(cfg.nimbleBin), "--nimbleDir:" & scratch / "nimble",
    "dump", "--json"]

proc runProbe*(cfg: ProbeConfig; nimbleBytes, nimbleName, scratch: string):
    ProbeOutcome =
  ## Run `nimble dump --json` on ``nimbleBytes`` (named ``nimbleName``)
  ## inside the sandbox, with ``scratch`` (created empty, absolute) its only
  ## writable place.
  when not defined(linux):
    raise newException(ProbeError, "the probe's sandbox runs on Linux only")
  else:
    if not scratch.isAbsolute:
      raise newException(ProbeError, "the probe's scratch must be absolute")
    if nimbleName.len == 0 or '/' in nimbleName or
        not nimbleName.endsWith(".nimble"):
      raise newException(ProbeError, "not a .nimble file name: " &
        nimbleName.escape())
    for d in ["pkg", "home", "nimble", "cache", "tmp"]:
      createDir(scratch / d)
    writeFile(scratch / "pkg" / nimbleName, nimbleBytes)
    let args = probeArgs(cfg, scratch)
    let sandbox = if cfg.sandboxBin.isAbsolute: cfg.sandboxBin
                  else: raise newException(ProbeError,
                    "the sandbox needs an absolute path")
    let wall = if cfg.wallSeconds > 0: cfg.wallSeconds
               else: DefaultProbeWallSeconds
    var p: Process
    withSpawnLock:
      p = uncontrolledStartProcess(sandbox, workingDir = scratch, args = args,
        options = {})
      markCloseOnExec([cint(p.outputHandle), cint(p.errorHandle),
        cint(p.inputHandle)])
    try:
      streams.close(p.inputStream)
      let outFd = cint(p.outputHandle)
      let errFd = cint(p.errorHandle)
      for fd in [outFd, errFd]:
        discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)
      # Both pipes are read while the sandbox runs (a full pipe would stall
      # it into the time limit), keeping at most a bounded prefix of each.
      var outOpen, errOpen = true
      var outText, errText: string
      var outOver = false
      var buf: array[65536, char]
      let deadline = epochTime() + float(wall)
      while true:
        if not outOpen and not errOpen:
          # Both pipes closed: the sandbox is ending, or its code closed
          # them and runs on; it is waited for under the same limit.
          if peekExitCode(p) != -1: break
          if epochTime() > deadline:
            result.timedOut = true
            break
          sleep(20)
          continue
        var pfds: array[2, TPollfd]
        pfds[0] = TPollfd(fd: (if outOpen: outFd else: -1), events: POLLIN)
        pfds[1] = TPollfd(fd: (if errOpen: errFd else: -1), events: POLLIN)
        let left = deadline - epochTime()
        if left <= 0:
          result.timedOut = true
          break
        let ready = posix.poll(addr pfds[0], Tnfds(2),
          cint(min(200.0, left * 1000.0)))
        if ready < 0 and errno != EINTR:
          raiseOSError(osLastError())
        if ready <= 0: continue
        for i in 0 .. 1:
          if pfds[i].revents == 0: continue
          let fd = if i == 0: outFd else: errFd
          let n = posix.read(fd, addr buf[0], buf.len)
          if n > 0:
            if i == 0:
              let keep = min(n, MaxProbeDumpBytes - outText.len)
              if keep < n: outOver = true
              if keep > 0:
                let at = outText.len
                outText.setLen(at + keep)
                copyMem(addr outText[at], addr buf[0], keep)
            else:
              let keep = min(n, MaxProbeDiagnosticBytes - errText.len)
              if keep > 0:
                let at = errText.len
                errText.setLen(at + keep)
                copyMem(addr errText[at], addr buf[0], keep)
          elif n == 0 or (errno != EAGAIN and errno != EWOULDBLOCK):
            if i == 0: outOpen = false else: errOpen = false
      if result.timedOut:
        # SIGKILL to bubblewrap: its child is killed with it
        # (`--die-with-parent`), and with that child the PID namespace and
        # every process in it.
        p.kill()
      result.exitCode = p.waitForExit()
      result.ok = not result.timedOut and not outOver and result.exitCode == 0
      result.diagnostics = errText
      if result.ok:
        result.dump = outText
      else:
        # Nimble reports a failed evaluation on its standard output.
        if outOver:
          result.diagnostics.add "the probe's output passed " &
            $MaxProbeDumpBytes & " bytes\n"
        result.diagnostics.add outText
      if result.diagnostics.len > MaxProbeDiagnosticBytes:
        result.diagnostics = result.diagnostics[0 ..< MaxProbeDiagnosticBytes]
    finally:
      p.close()
