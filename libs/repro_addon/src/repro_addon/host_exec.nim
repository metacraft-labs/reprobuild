## Running the host distribution's own tools.
##
## Add-on mode manages objects on a host whose operating system belongs to
## someone else, so some of what it observes and changes is only reachable
## through that distribution's tools: ``systemctl`` for unit state and
## ``dpkg-divert`` for diversions. Those binaries are not something
## Reprobuild provisions or could provision -- they ARE the base the add-on
## sits on -- so they are run through the explicit ``uncontrolled*`` escape
## hatch of ``repro_core/ambient_execution`` rather than a typed execution
## profile, and always by absolute path, never through ``PATH``.
##
## Every call here passes an argv, never a shell string: nothing an
## operator or a profile supplies is ever interpreted by a shell.
##
## The environment is fixed (``LC_ALL=C``, no pager, no colour) so that the
## text the add-on parses does not depend on the operator's locale or
## terminal, which is what keeps the fingerprint and the preflight plan
## deterministic.

import std/[os, osproc, posix, streams, strtabs, strutils, times]

import repro_core/ambient_execution
import repro_core/process_close

type
  HostToolResult* = object
    exitCode*: int
    output*: string     ## stdout (and stderr, when merged)

  HostToolMissing* = object of CatchableError
    ## The tool is not installed at the absolute path the caller named.

const
  SystemctlCandidates* = ["/usr/bin/systemctl", "/bin/systemctl"]
  DpkgDivertCandidates* = ["/usr/bin/dpkg-divert", "/usr/sbin/dpkg-divert"]
  DpkgQueryCandidates* = ["/usr/bin/dpkg-query"]
  SystemdRunCandidates* = ["/usr/bin/systemd-run", "/bin/systemd-run"]

proc fixedToolEnv(): StringTableRef =
  ## The whole environment a host tool sees. ``PATH`` is set because some
  ## tools (dpkg-divert) exec helpers by name; it lists only the
  ## distribution's own directories.
  result = newStringTable(modeCaseSensitive)
  result["LC_ALL"] = "C"
  result["LANG"] = "C"
  result["PATH"] = "/usr/sbin:/usr/bin:/sbin:/bin"
  result["SYSTEMD_PAGER"] = ""
  result["SYSTEMD_COLORS"] = "0"
  result["SYSTEMD_LESS"] = ""
  result["DEBIAN_FRONTEND"] = "noninteractive"

proc resolveHostTool*(candidates: openArray[string]): string =
  ## The first candidate path that exists as an executable file, or ""
  ## when none does. Only absolute paths are accepted: a relative name
  ## would be a PATH lookup by another route.
  for c in candidates:
    if not c.isAbsolute:
      raise newException(ValueError,
        "host tool candidate must be an absolute path: " & c)
    if fileExists(c):
      try:
        if fpUserExec in getFilePermissions(c) or
            fpGroupExec in getFilePermissions(c) or
            fpOthersExec in getFilePermissions(c):
          return c
      except OSError:
        discard
  ""

const BoundedOutputBytes* = 64 * 1024
  ## What a bounded ``runHostTool`` keeps of a tool's output.

proc runHostTool*(argv: openArray[string]; mergeStderr = true;
                  input = ""; timeoutSec = 0): HostToolResult =
  ## Run ``argv[0]`` (an absolute path) with ``argv[1..]`` and capture its
  ## output. Raises ``HostToolMissing`` when ``argv[0]`` does not exist,
  ## so a caller can tell "the tool said no" from "there is no tool".
  ## ``timeoutSec > 0`` bounds the wall time: the process is killed at the
  ## deadline and the result has exit code 124 (``timeout(1)``'s), with
  ## whatever it printed. Its output is drained while it runs, so a tool
  ## that prints more than a pipe holds is never blocked writing; only the
  ## first ``BoundedOutputBytes`` are kept.
  if argv.len == 0:
    raise newException(ValueError, "runHostTool: empty argv")
  if not argv[0].isAbsolute:
    raise newException(ValueError,
      "runHostTool: the tool must be named by absolute path: " & argv[0])
  if not fileExists(argv[0]):
    raise newException(HostToolMissing, "host tool not found: " & argv[0])
  var options: set[ProcessOption] = {}
  if mergeStderr:
    options.incl poStdErrToStdOut
  var p = uncontrolledStartProcess(argv[0], args = argv[1 .. ^1],
                                   env = fixedToolEnv(), options = options)
  try:
    if input.len > 0:
      p.inputStream.write(input)
    p.inputStream.close()
    if timeoutSec > 0:
      # Drain the pipe as the tool writes (poll + read): a probe that
      # prints more than the pipe buffer must not block on its write until
      # the deadline kills it, and nothing it prints may grow without
      # bound in this process.
      let deadline = epochTime() + timeoutSec.float
      let fd = p.outputHandle.cint
      var buf = newString(4096)
      var eof = false
      var code = -1
      while true:
        code = p.peekExitCode()
        let left = deadline - epochTime()
        if eof or left <= 0:
          if code != -1 or left <= 0: break
          sleep(20)
          continue
        # Once the tool has exited, only what is already in the pipe is
        # read (a zero poll timeout): a process it left behind holding the
        # pipe open must not keep this waiting.
        var pfd = TPollfd(fd: fd, events: POLLIN)
        let wait = if code != -1: 0
                   else: cint(max(1, min(200, int(left * 1000))))
        let n = poll(addr pfd, 1, cint(wait))
        if n == 0 and code != -1: break
        if n > 0:
          let got = posix.read(fd, addr buf[0], buf.len)
          if got > 0:
            if result.output.len < BoundedOutputBytes:
              result.output.add(buf[0 ..< min(got,
                BoundedOutputBytes - result.output.len)])
          elif got == 0 or errno notin [EINTR, EAGAIN]:
            eof = true
      if code == -1:
        p.kill()
        discard p.waitForExit()
        result.output.add("\n(killed after " & $timeoutSec & " s)")
        result.exitCode = 124
        return
      result.exitCode = code
    else:
      result.output = p.outputStream.readAll()
      result.exitCode = p.waitForExit()
  finally:
    closeProcessOnce(p)

proc runSystemctl*(args: openArray[string]): HostToolResult =
  ## ``systemctl <args>`` with the fixed environment. Raises
  ## ``HostToolMissing`` on a host without systemctl.
  let exe = resolveHostTool(SystemctlCandidates)
  if exe.len == 0:
    raise newException(HostToolMissing,
      "systemctl not found at " & SystemctlCandidates.join(" or "))
  var argv = @[exe]
  for a in args: argv.add(a)
  runHostTool(argv)

proc systemdMajor*(versionOutput: string): int =
  ## ``systemd 257 (257.8-1~deb13u2)`` -> 257; 0 when unparsable.
  let lines = versionOutput.splitLines()
  if lines.len == 0: return 0
  let f = lines[0].splitWhitespace()
  if f.len >= 2 and f[0] == "systemd":
    try: return parseInt(f[1]) except ValueError: discard
  0

proc hostSystemdVersion*(): int =
  ## The major version of the host's systemd (``systemctl --version``), 0
  ## when it cannot be read. systemd-networkd ships in the same source
  ## package and release, so this is networkd's version too.
  try:
    let r = runSystemctl(["--version"])
    if r.exitCode == 0: return systemdMajor(r.output)
  except CatchableError:
    discard
  0

proc runInHostNamespaces*(argv: openArray[string];
                          timeoutSec = 0): HostToolResult =
  ## Run ``argv`` as a transient unit of the host's systemd and return its
  ## output: PID 1 spawns it in the host's namespaces whatever namespaces
  ## this process is confined to (the apply unit's ``PrivateNetwork=yes``,
  ## spec §9.1). ``net.*`` sysctls are per network namespace, so every
  ## read and write of one goes this way (spec §7.2 step 6, threat model
  ## G35).
  let exe = resolveHostTool(SystemdRunCandidates)
  if exe.len == 0:
    raise newException(HostToolMissing, "systemd-run not found at " &
      SystemdRunCandidates.join(" or "))
  var full = @[exe, "--quiet", "--wait", "--pipe", "--collect",
               "--service-type=exec"]
  if timeoutSec > 0:
    # Bounded twice: PID 1 stops the transient unit at its deadline, and
    # this process stops waiting for systemd-run a second later in case
    # PID 1 itself does not answer.
    full.add("--property=RuntimeMaxSec=" & $timeoutSec)
  full.add("--")
  for a in argv: full.add(a)
  runHostTool(full, timeoutSec = (if timeoutSec > 0: timeoutSec + 1 else: 0))

proc sysctlNormalize*(key: string): string =
  ## systemd's normal form of a sysctl key (``sysctl_normalize``, see
  ## sysctl.d(5) "the first separator"): when the first separator is a
  ## dot, dots become slashes and slashes become dots
  ## (``net.ipv4.conf.eth0/100.forwarding`` ->
  ## ``net/ipv4/conf/eth0.100/forwarding``); when it is a slash, the key
  ## is already in that form and dots are literal. Empty components and
  ## leading or trailing slashes are dropped.
  var k = key
  var first = -1
  for i, c in k:
    if c in {'.', '/'}:
      first = i
      break
  if first >= 0 and k[first] == '.':
    for i in first ..< k.len:
      if k[i] == '.': k[i] = '/'
      elif k[i] == '/': k[i] = '.'
  var parts: seq[string]
  for p in k.split('/'):
    if p.len > 0: parts.add(p)
  parts.join("/")

proc sysctlFingerprintKey*(key: string): string =
  ## The key as the base fingerprint spells it: the ``/proc/sys`` path
  ## components joined with dots.
  sysctlNormalize(key).replace('/', '.')

proc sysctlKeyPath*(key: string): string =
  ## ``/proc/sys/<key in systemd's normal form>``.
  "/proc/sys/" & sysctlNormalize(key)

proc readHostSysctl*(key: string): string =
  ## The host's effective value of ``key`` (whitespace collapsed), read by
  ## a transient unit in the host's namespaces; "" when unreadable.
  try:
    let r = runInHostNamespaces(["/bin/cat", sysctlKeyPath(key)])
    if r.exitCode != 0: "" else: r.output.splitWhitespace().join(" ")
  except HostToolMissing:
    ""
