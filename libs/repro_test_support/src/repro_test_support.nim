## Shared, portable test helpers used by repository-level Nim tests.
##
## Many tests need to invoke ``repro``/``repro-daemon`` etc. with a
## specific working directory, a specific subprocess environment, and
## then assert against the merged stdout+stderr output. Each test had
## historically grown its own copy of:
##
##   proc shellCommand(args, env): string =
##     for (n,v) in env: parts.add(n & "=" & q(v))
##     for arg in args: parts.add(q(arg))
##     parts.join(" ")
##   proc runShell(command): (code, output) =
##     execCmdEx(command)
##
## That shape works under ``/bin/sh`` on POSIX (which honours the
## ``VAR=value cmd`` prefix syntax) but FAILS under Windows
## ``cmd.exe /c``: ``set`` cannot chain via ``&&`` through
## ``execCmdEx`` because Nim doesn't actually wrap the command in
## ``cmd.exe`` — it hands the whole string to ``CreateProcessW`` as
## the literal program name. The fix is structural: use
## ``startProcess(args = ..., env = ...)`` which sets per-child env
## vars through the OS env block directly, no shell required.
##
## All exported procs are deliberately tiny — they exist so each test
## file can do
##
##   import repro_test_support
##
## without duplicating the boilerplate; the behaviour is identical
## across Linux, macOS, and Windows.

import std/[os, osproc, streams, strtabs, strutils, unittest]

const
  isNixSupported* = defined(linux) or defined(macosx)
    ## True on platforms where `nix` / `nix build` is a realistic
    ## option for hermetic tool provisioning. The constant exists so
    ## tests can gate Nix-dependent fixtures at COMPILE time, e.g.
    ##   when isNixSupported:
    ##     proc requireFish(): string = ...
    ##     test "e2e_fish_hook":
    ##       discard requireFish()
    ## On Windows the test body is excluded from the binary entirely;
    ## the suite still compiles and the unrelated tests run. The
    ## previous pattern (`findExe("nix")` runtime probe) was both
    ## brittle (a stale `nix` shim on PATH hung the test) and led to
    ## test bodies that pretended to be portable when their
    ## production code was not. A single named constant lets the
    ## intent stay visible at every gate site and makes it
    ## trivial to grep for "everything that needs Nix".


type
  CmdSpec* = object
    ## Bundle of the program path, its argv, and any per-invocation
    ## env-var overrides. ``shellCommand`` returns this so call sites
    ## like ``requireSuccess(shellCommand(args, env), cwd)`` keep
    ## reading the same way they used to; only the underlying type
    ## changes from ``string`` (a shell command line) to ``CmdSpec``
    ## (a structured argv+env record).
    args*: seq[string]
    env*: seq[tuple[name, value: string]]

  CmdResult* = tuple[code: int; output: string]

proc shellCommand*(args: openArray[string];
                   env: openArray[tuple[name, value: string]] = []): CmdSpec =
  ## Bundle argv + env-var overrides into a ``CmdSpec``. The legacy
  ## name is retained so callers don't have to rename — the type
  ## change does the heavy lifting.
  result.args = @args
  result.env = @env

proc runShell*(cmd: CmdSpec; cwd = getCurrentDir()): CmdResult =
  ## Invoke ``cmd.args[0]`` with ``cmd.args[1..^1]`` under ``cwd``,
  ## merging stderr into stdout (the pre-refactor behaviour of
  ## ``execCmdEx`` with ``poStdErrToStdOut``).
  ##
  ## The subprocess inherits the parent environment, overlaid with
  ## ``cmd.env`` — matching the per-invocation override semantics
  ## the old ``VAR=value cmd`` shell prefix provided.
  if cmd.args.len == 0:
    raise newException(ValueError, "shellCommand returned an empty argv")
  var envTable = newStringTable()
  for k, v in envPairs(): envTable[k] = v
  for entry in cmd.env: envTable[entry.name] = entry.value
  let process = startProcess(cmd.args[0],
    workingDir = cwd,
    args = cmd.args[1..^1],
    env = envTable,
    options = {poStdErrToStdOut})
  defer: process.close()
  result.output = process.outputStream.readAll()
  result.code = process.waitForExit()

proc requireSuccess*(cmd: CmdSpec; cwd = getCurrentDir()): string =
  ## Run ``cmd`` and assert exit-code 0. Returns the merged output so
  ## callers can keep chaining ``.contains("...")`` checks.
  let res = runShell(cmd, cwd)
  if res.code != 0:
    checkpoint(res.output)
  check res.code == 0
  res.output

proc requireFailure*(cmd: CmdSpec; cwd = getCurrentDir()): string =
  ## Mirror of ``requireSuccess`` for the negative-path callers that
  ## previously checked ``res.code != 0`` themselves.
  let res = runShell(cmd, cwd)
  if res.code == 0:
    checkpoint(res.output)
  check res.code != 0
  res.output

proc daemonSocketEndpoint*(name: string): string =
  ## Portable per-test endpoint name. AF_UNIX socket paths are picked
  ## under ``/tmp`` on POSIX; on Windows the equivalent name lives in
  ## the kernel-managed named-pipe namespace.
  when defined(windows):
    r"\\.\pipe\" & name.replace('\\', '_').replace('/', '_')
  else:
    "/tmp" / (name & ".sock")
