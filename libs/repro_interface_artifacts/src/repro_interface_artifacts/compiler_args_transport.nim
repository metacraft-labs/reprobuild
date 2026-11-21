## Lossless transport of a long Nim compiler argument vector.
##
## Windows' `CreateProcessW` refuses a command line longer than 32,767 UTF-16
## code units including its terminating NUL (`ERROR_FILENAME_EXCED_RANGE`,
## 206; https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw).
## A recipe compile that carries every selected SDK root with its paired
## exclusion/reset flags exceeds it. The supported compiler accepts the
## vector through `nim --compilerArgsFile:<path>` instead: a version-1 JSON
## file (`{"version":1,"argv":[...]}`) that it reads once and feeds, unchanged,
## to both of its command-line passes and to NimScript's argument APIs.
##
## This module decides when the transport is needed, encodes the file and
## stages it. It never changes what is compiled:
##
## * the logical argv (and therefore every cache identity formed from it) is
##   exactly the one the caller built; only the PHYSICAL process argv changes;
## * the file lives in the invocation's own compiler scratch directory, is
##   staged atomically under a fresh name, outlives every attempt of the
##   compile (retries included) and is removed by its owner only;
## * nothing is written beside a consumer or into an installed SDK.

import std/[os, strutils, tempfiles, unicode]

when defined(posix):
  import std/posix

const
  WindowsCommandLineLimitUnits* = 32_767
    ## `CreateProcessW`'s maximum `lpCommandLine`, in UTF-16 code units,
    ## including the terminating NUL.
  CompilerArgsFileSwitch* = "--compilerArgsFile:"
  CompilerArgsFileVersion* = 1
  LinuxMaxArgStrlen = 32 * 4096
    ## `MAX_ARG_STRLEN`: Linux refuses any single argv/envp string longer than
    ## this with E2BIG, whatever `ARG_MAX` is (execve(2), "Limits on size of
    ## arguments and environment").

type
  CompilerArgsTransportError* = object of CatchableError

proc windowsQuotedCommandLine*(command: openArray[string]): string =
  ## The command line `runCommand` hands to `CreateProcessW`.
  result = ""
  for i, arg in command:
    if i > 0: result.add ' '
    result.add quoteShellWindows(arg)

proc utf16Units*(s: string): int =
  ## UTF-16 code units of a UTF-8 string, as `newWideCString` would produce:
  ## one per BMP code point, two per supplementary one.
  result = 0
  for r in s.runes:
    result += (if int32(r) >= 0x10000: 2 else: 1)

proc windowsCommandLineUnits*(command: openArray[string]): int =
  ## UTF-16 units `CreateProcessW` would receive, including the NUL.
  utf16Units(windowsQuotedCommandLine(command)) + 1

proc exceedsWindowsCommandLineLimit*(command: openArray[string]): bool =
  windowsCommandLineUnits(command) > WindowsCommandLineLimitUnits

when defined(posix):
  var environ {.importc.}: cstringArray

  proc exceedsPosixExecLimit*(command: openArray[string]): bool =
    ## Whether `execve` would refuse `command` with E2BIG under the current
    ## environment: the argv and envp strings, their NULs and pointers must fit
    ## `ARG_MAX`, and on Linux no single string may exceed `MAX_ARG_STRLEN`.
    let argMax = sysconf(SC_ARG_MAX)
    var total = 0
    for arg in command:
      when defined(linux):
        if arg.len + 1 > LinuxMaxArgStrlen: return true
      total += arg.len + 1 + sizeof(pointer)
    if environ != nil:
      var i = 0
      while environ[i] != nil:
        total += len(environ[i]) + 1 + sizeof(pointer)
        inc i
    result = argMax > 0 and total > int(argMax)

proc compilerArgvExceedsPlatformLimit*(command: openArray[string]): bool =
  ## Whether launching `command` directly would exceed this platform's
  ## process argument limit.
  when defined(windows):
    exceedsWindowsCommandLineLimit(command)
  elif defined(posix):
    exceedsPosixExecLimit(command)
  else:
    false

proc encodeJsonString(result: var string; s: string) =
  # RFC 8259 §7: escape the quote, the backslash and C0 controls; every other
  # (UTF-8) byte is emitted as is.
  result.add '"'
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '\0'..'\x08', '\x0B', '\x0C', '\x0E'..'\x1F':
      result.add "\\u00"
      result.add toHex(ord(c), 2)
    else: result.add c
  result.add '"'

proc encodeCompilerArgsFile*(argv: openArray[string]): string =
  ## The version-1 argument file for `argv` (the logical vector WITHOUT the
  ## compiler executable). A NUL cannot be carried by any process argv, so an
  ## argument containing one is refused rather than transported.
  result = "{\"version\":" & $CompilerArgsFileVersion & ",\"argv\":["
  for i, arg in argv:
    if '\0' in arg:
      raise newException(CompilerArgsTransportError,
        "compiler argument " & $i & " contains a NUL character")
    if validateUtf8(arg) >= 0:
      raise newException(CompilerArgsTransportError,
        "compiler argument " & $i & " is not valid UTF-8")
    if i > 0: result.add ','
    result.encodeJsonString(arg)
  result.add "]}"

proc stageCompilerArgsFile*(scratchDir: string; argv: openArray[string]):
    string =
  ## Writes the argument file for `argv` into the invocation-owned
  ## `scratchDir` and returns its absolute path. The bytes are written to a
  ## private temporary name and then renamed to a fresh final name, so the
  ## compiler can only ever observe a complete file.
  if scratchDir.len == 0:
    raise newException(CompilerArgsTransportError,
      "a compiler argument file needs the invocation's scratch directory")
  let content = encodeCompilerArgsFile(argv)
  let dir = absolutePath(scratchDir)
  let (stage, stagePath) = createTempFile("repro-compiler-args-", ".tmp", dir)
  try:
    stage.write(content)
  finally:
    stage.close()
  result = stagePath.changeFileExt("json")
  if fileExists(result):
    removeFile(stagePath)
    raise newException(CompilerArgsTransportError,
      "compiler argument file already exists: " & result)
  try:
    moveFile(stagePath, result)
  except OSError:
    try: removeFile(stagePath)
    except OSError: discard
    raise

proc physicalCompilerCommand*(compiler, argsFile: string): seq[string] =
  ## The process argv that carries a staged argument file: the compiler and
  ## exactly one transport option.
  @[compiler, CompilerArgsFileSwitch & argsFile]

proc removeStagedCompilerArgsFile*(path: string) =
  ## Removes a file `stageCompilerArgsFile` created. Never anything else.
  if path.len > 0:
    try: removeFile(path)
    except OSError: discard
