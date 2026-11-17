## Whether standard input is an interactive terminal, the question
## `repro shell`'s spawn mode asks before it starts a shell
## (`shell_invocation.shellSpawnRefusal`).
##
## On POSIX the answer is `isatty(0)`.
##
## On Windows `isatty` (the C runtime's `_isatty`) answers a different
## question, whether the handle is a character device, and gets both cases
## that matter wrong: `< NUL` is a character device, so it answers yes for an
## input nobody types into, and the terminal of MSYS2 and Cygwin (mintty, the
## Git for Windows terminal) is a named pipe, so it answers no for an
## interactive user. Standard input is therefore a terminal on Windows when
## either:
##
## * it is a Windows console: `GetConsoleMode` succeeds on its handle
##   (https://learn.microsoft.com/en-us/windows/console/getconsolemode); or
## * it is a pipe (`GetFileType` is `FILE_TYPE_PIPE`) whose name
##   (`GetFileInformationByHandleEx(..., FileNameInfo, ...)`) is the input
##   pipe of an MSYS2 or Cygwin pseudo-terminal,
##   `\msys-<hex>-pty<N>-from-master` or `\cygwin-<hex>-pty<N>-from-master`.
##
## The pipe-name test is the one Git for Windows makes in `is_cygwin_pty`
## (https://github.com/git-for-windows/git/blob/main/compat/winansi.c) and
## mingw-w64 makes in its `isatty`
## (https://github.com/mingw-w64/mingw-w64/blob/master/mingw-w64-crt/misc/isatty.c).
## It is matched exactly here, not by substring, so an ordinary pipe whose
## name happens to contain `-pty` is not taken for a terminal. Only the
## `-from-master` pipe is accepted: it is the one the pty's slave side reads,
## i.e. standard input; `-to-master` is the output side.
##
## `isMsysPtyInputPipeName` is the pure part, exported so it can be tested on
## every operating system.

import std/strutils
when not defined(windows):
  import std/terminal

const
  MsysPipePrefix = "msys-"
  CygwinPipePrefix = "cygwin-"
  PtyMarker = "-pty"
  PtyInputSuffix = "-from-master"
    ## The pieces of a pty input pipe's name, in order (module
    ## documentation).

proc isMsysPtyInputPipeName*(name: string): bool =
  ## Whether `name`, a pipe's name as `FileNameInfo` reports it (relative to
  ## the named-pipe device, so with a leading `\`), is the input pipe of an
  ## MSYS2 or Cygwin pseudo-terminal: `\msys-<hex>-pty<N>-from-master` or
  ## `\cygwin-<hex>-pty<N>-from-master`, with at least one hex digit and at
  ## least one decimal digit.
  var i = 0
  if name.len == 0 or name[0] != '\\':
    return false
  inc i
  if name.continuesWith(MsysPipePrefix, i):
    i += MsysPipePrefix.len
  elif name.continuesWith(CygwinPipePrefix, i):
    i += CygwinPipePrefix.len
  else:
    return false
  let hexStart = i
  while i < name.len and name[i] in HexDigits:
    inc i
  if i == hexStart:
    return false
  if not name.continuesWith(PtyMarker, i):
    return false
  i += PtyMarker.len
  let digitStart = i
  while i < name.len and name[i] in Digits:
    inc i
  if i == digitStart:
    return false
  # Exactly the suffix, and nothing after it.
  name.len - i == PtyInputSuffix.len and name.continuesWith(PtyInputSuffix, i)

when defined(windows):
  import std/winlean

  const
    FileTypePipe = 0x0003'i32
      ## `FILE_TYPE_PIPE`
      ## (https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfiletype).
    FileNameInfoClass = 2'i32
      ## `FileNameInfo` of `FILE_INFO_BY_HANDLE_CLASS`
      ## (https://learn.microsoft.com/en-us/windows/win32/api/minwinbase/ne-minwinbase-file_info_by_handle_class).
    MaxPipeNameChars = 512
      ## Room for the name; a pty pipe's is under 64 characters, and a
      ## longer name is not one.

  proc getConsoleModeW(h: Handle; mode: ptr int32): WINBOOL {.stdcall,
    dynlib: "kernel32", importc: "GetConsoleMode".}
  proc getFileTypeW(h: Handle): int32 {.stdcall, dynlib: "kernel32",
    importc: "GetFileType".}
  proc getFileInformationByHandleExW(h: Handle; class: int32;
    info: pointer; size: int32): WINBOOL {.stdcall, dynlib: "kernel32",
    importc: "GetFileInformationByHandleEx".}

  proc pipeName(h: Handle): string =
    ## The name `FileNameInfo` reports for `h`, or "" when it reports none.
    # FILE_NAME_INFO: a DWORD byte length, then that many bytes of UTF-16
    # (https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_name_info).
    var buffer: array[4 + 2 * MaxPipeNameChars, byte]
    if getFileInformationByHandleExW(h, FileNameInfoClass, addr buffer[0],
        int32(buffer.len)) == 0:
      return ""
    var byteLen: int32
    copyMem(addr byteLen, addr buffer[0], 4)
    if byteLen <= 0 or byteLen > 2 * MaxPipeNameChars:
      return ""
    # The names compared are ASCII; a code unit outside it makes the name
    # one that cannot match, so it is replaced rather than decoded.
    for k in 0 ..< int(byteLen) div 2:
      let unit = uint16(buffer[4 + 2 * k]) or
        (uint16(buffer[5 + 2 * k]) shl 8)
      result.add(if unit < 0x80: char(unit) else: '?')

proc stdinIsTerminal*(): bool =
  ## Whether standard input is an interactive terminal (module
  ## documentation): `isatty(0)` on POSIX; a console, or an MSYS2/Cygwin pty
  ## input pipe, on Windows.
  when defined(windows):
    let h = getStdHandle(STD_INPUT_HANDLE)
    if h == INVALID_HANDLE_VALUE or h == Handle(0):
      return false
    var mode: int32
    if getConsoleModeW(h, addr mode) != 0:
      return true
    if getFileTypeW(h) != FileTypePipe:
      return false
    isMsysPtyInputPipeName(pipeName(h))
  else:
    isatty(stdin)
