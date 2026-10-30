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

import std/[os, osproc, streams, strtabs, strutils]

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

proc runHostTool*(argv: openArray[string]; mergeStderr = true;
                  input = ""): HostToolResult =
  ## Run ``argv[0]`` (an absolute path) with ``argv[1..]`` and capture its
  ## output. Raises ``HostToolMissing`` when ``argv[0]`` does not exist,
  ## so a caller can tell "the tool said no" from "there is no tool".
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
