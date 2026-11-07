## Reading the TARGET of a symbolic link (or a Windows junction) — the one
## link-text reader every library in this repository goes through.
##
## ## Why this module exists
##
## Nim's `os.expandSymlink` is not implemented on Windows: there it returns
## its argument unchanged
## (https://nim-lang.org/docs/os.html#expandSymlink%2Cstring — "On Windows
## this is a noop, `symlinkPath` is simply returned"). Every caller that
## asked a link where it points therefore got the LINK'S OWN PATH back, and
## carried on as if that were the answer. Measured on eli-pc with the
## v0.2.16 bundle: each `repro home apply --plan` drift row for an existing
## symlink named the link itself, with its `\\?\` prefix, as the "different
## source" it pointed at (reprobuild-pm issue
## `2026-10-26-windows-stow-drift-names-the-link-itself-as-its-different-source`).
## The same call fed a path-escape check (a link resolving to itself is
## always "beneath the root"), a cycle detector (a link resolving to itself
## is always "a cycle"), and the link-text component of content identities.
##
## `readSymlinkTarget` is the drop-in replacement: on POSIX it is
## `readlink(2)` via `expandSymlink`, unchanged; on Windows it reads the
## reparse point itself.
##
## ## The Windows primitive, and why not `GetFinalPathNameByHandleW`
##
## The link is opened with `FILE_FLAG_OPEN_REPARSE_POINT` (so the open does
## NOT traverse it) and `FILE_FLAG_BACKUP_SEMANTICS` (so a DIRECTORY link is
## openable at all), and `DeviceIoControl(FSCTL_GET_REPARSE_POINT)` returns
## its `REPARSE_DATA_BUFFER`:
##
## * https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ni-winioctl-fsctl_get_reparse_point
## * https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_reparse_data_buffer
## * https://learn.microsoft.com/en-us/windows/win32/fileio/reparse-point-tags
##
## `GetFinalPathNameByHandleW` answers a different question — where the
## whole chain finally LANDS, after every link on the way — and it needs the
## target to exist and to be traversable. Over an SSH logon Windows refuses
## to traverse some links at all ("untrusted mount point"), while the
## reparse data stays readable. `repro_core/path_identity` uses the
## final-path primitive because containment needs the landing place; a
## link's TEXT needs this one, exactly as `readlink(2)` does not follow.
##
## ## Which of the two names is the target
##
## A symlink or mount-point buffer carries a SUBSTITUTE name (what the I/O
## manager parses and FOLLOWS: `\??\C:\dir\file` for an absolute target, NT
## namespace) and a PRINT name (display text: `C:\dir\file`). The substitute
## name is returned, its `\??\` prefix rewritten to the Win32 spelling
## (`\??\C:\x` becomes `C:\x`, `\??\UNC\server\share` becomes
## `\\server\share`, any other device keeps the `\\?\` form).
##
## The print name is not authoritative. `FSCTL_SET_REPARSE_POINT` stores
## whatever print name it is given, and any user who can write a directory
## can create a junction whose print name names one place while its
## substitute name sends the OS to another. A reader returning the print
## name would let such a link pass a containment check, or keep a content
## identity while its real target changed. Go's `os.Readlink` and Rust's
## `std::fs::read_link` read the substitute name for the same reason.
##
## A relative symlink (`SYMLINK_FLAG_RELATIVE`) is returned relative, like
## `readlink`; `resolvedSymlinkTarget` joins it to the link's directory.
##
## Any other tag (an AppExecLink alias, a cloud-files placeholder, a WSL
## `LX_SYMLINK`) is reported as unreadable rather than guessed at.

import std/[os, strutils]

const
  IoReparseTagMountPoint* = 0xA0000003'u32
    ## `IO_REPARSE_TAG_MOUNT_POINT` — a junction (or a volume mount point).
  IoReparseTagSymlink* = 0xA000000C'u32
    ## `IO_REPARSE_TAG_SYMLINK` — a file or directory symbolic link.
  SymlinkFlagRelative* = 0x1'u32
    ## `SYMLINK_FLAG_RELATIVE` in `SymbolicLinkReparseBuffer.Flags`.
  MaximumReparseDataBufferSize* = 16 * 1024
    ## `MAXIMUM_REPARSE_DATA_BUFFER_SIZE` (winnt.h).

type
  ReparseLinkKind* = enum
    rlkSymlink     ## `IO_REPARSE_TAG_SYMLINK`
    rlkMountPoint  ## `IO_REPARSE_TAG_MOUNT_POINT` (junction)

  ReparseLinkParse* = object
    ## The link a `REPARSE_DATA_BUFFER` describes, or why it describes none.
    ok*: bool
    kind*: ReparseLinkKind
    target*: string        ## the substitute name, in its Win32 spelling
    substituteName*: string
    printName*: string
    relative*: bool        ## `SYMLINK_FLAG_RELATIVE` (symlinks only)
    tag*: uint32
    reason*: string        ## set when `ok` is false

proc readU16(data: openArray[byte]; at: int): uint32 =
  uint32(data[at]) or (uint32(data[at + 1]) shl 8)

proc readU32(data: openArray[byte]; at: int): uint32 =
  uint32(data[at]) or (uint32(data[at + 1]) shl 8) or
    (uint32(data[at + 2]) shl 16) or (uint32(data[at + 3]) shl 24)

proc addRune(result: var string; cp: uint32) =
  ## UTF-8 encoding of one code point (RFC 3629 §3).
  if cp < 0x80:
    result.add char(cp)
  elif cp < 0x800:
    result.add char(0xC0'u32 or (cp shr 6))
    result.add char(0x80'u32 or (cp and 0x3F))
  elif cp < 0x10000:
    result.add char(0xE0'u32 or (cp shr 12))
    result.add char(0x80'u32 or ((cp shr 6) and 0x3F))
    result.add char(0x80'u32 or (cp and 0x3F))
  else:
    result.add char(0xF0'u32 or (cp shr 18))
    result.add char(0x80'u32 or ((cp shr 12) and 0x3F))
    result.add char(0x80'u32 or ((cp shr 6) and 0x3F))
    result.add char(0x80'u32 or (cp and 0x3F))

proc utf16leToUtf8*(data: openArray[byte]; first, byteLen: int): string =
  ## Decode `byteLen` bytes of UTF-16LE starting at `first` (RFC 2781 §2.2).
  ## An unpaired surrogate becomes U+FFFD, as Windows' own
  ## `WideCharToMultiByte` does without `WC_ERR_INVALID_CHARS`. The caller
  ## bounds-checks the range.
  var i = first
  let stop = first + byteLen - (byteLen mod 2)
  while i < stop:
    let unit = readU16(data, i)
    i += 2
    if unit >= 0xD800'u32 and unit <= 0xDBFF'u32 and i < stop:
      let low = readU16(data, i)
      if low >= 0xDC00'u32 and low <= 0xDFFF'u32:
        i += 2
        result.addRune(0x10000'u32 + ((unit - 0xD800'u32) shl 10) +
          (low - 0xDC00'u32))
        continue
      result.addRune(0xFFFD)
    elif unit >= 0xD800'u32 and unit <= 0xDFFF'u32:
      result.addRune(0xFFFD)
    else:
      result.addRune(unit)

proc stripNtObjectPrefix*(name: string): string =
  ## `\??\C:\x` -> `C:\x`; `\??\UNC\server\share` -> `\\server\share`. The
  ## `\??\` prefix names the NT object manager's per-session DOS-device
  ## directory; it is how a substitute name spells a Win32 absolute path
  ## (https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file#nt-namespaces).
  ## The `\\?\` spelling some writers use is treated the same way. Any other
  ## device (`\??\Volume{GUID}\x`, a volume mount point's target) has no
  ## drive-letter or UNC spelling and keeps the Win32 `\\?\` form, which
  ## names the same object; dropping the prefix alone would leave a
  ## relative path naming something else.
  for prefix in [r"\??\", r"\\?\"]:
    if name.startsWith(prefix):
      let rest = name[prefix.len .. ^1]
      if rest.len >= 4 and rest[0 .. 3].toUpperAscii == r"UNC\":
        return r"\\" & rest[4 .. ^1]
      if rest.len >= 2 and rest[0] in {'A'..'Z', 'a'..'z'} and rest[1] == ':':
        return rest
      return r"\\?\" & rest
  name

proc parseReparseDataBuffer*(data: openArray[byte]): ReparseLinkParse =
  ## Parse the `REPARSE_DATA_BUFFER` that `FSCTL_GET_REPARSE_POINT` returns
  ## (layout: https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_reparse_data_buffer).
  ## Pure: it reads only `data`, so the byte layout is testable on any host.
  ##
  ## ```
  ## 0  ULONG  ReparseTag
  ## 4  USHORT ReparseDataLength      (bytes after this 8-byte header)
  ## 6  USHORT Reserved
  ## 8  USHORT SubstituteNameOffset   (bytes, into PathBuffer)
  ## 10 USHORT SubstituteNameLength   (bytes, no terminator)
  ## 12 USHORT PrintNameOffset
  ## 14 USHORT PrintNameLength
  ## 16 ULONG  Flags                  (symlink only)
  ## 20 / 16   WCHAR PathBuffer[]     (symlink / mount point)
  ## ```
  ##
  ## Every offset is bounds-checked against both `ReparseDataLength` and the
  ## bytes actually supplied; a buffer that does not hold together is
  ## refused with a reason, never read past.
  const headerLen = 8
  if data.len < headerLen:
    return ReparseLinkParse(reason: "reparse buffer is " & $data.len &
      " bytes, shorter than its 8-byte header")
  result.tag = readU32(data, 0)
  let dataLen = int(readU16(data, 4))
  let available = min(data.len, headerLen + dataLen)
  var pathBuffer: int
  case result.tag
  of IoReparseTagSymlink:
    result.kind = rlkSymlink
    pathBuffer = 20
  of IoReparseTagMountPoint:
    result.kind = rlkMountPoint
    pathBuffer = 16
  else:
    return ReparseLinkParse(tag: result.tag,
      reason: "reparse tag 0x" & toHex(result.tag, 8) &
        " is neither a symbolic link nor a junction")
  if available < pathBuffer:
    return ReparseLinkParse(tag: result.tag, reason: "reparse buffer of " &
      $available & " usable bytes is too short for its link header")
  let subOff = int(readU16(data, 8))
  let subLen = int(readU16(data, 10))
  let printOff = int(readU16(data, 12))
  let printLen = int(readU16(data, 14))
  for (off, size, what) in [(subOff, subLen, "substitute"),
                            (printOff, printLen, "print")]:
    if pathBuffer + off + size > available:
      return ReparseLinkParse(tag: result.tag, reason: "reparse buffer " &
        what & " name (offset " & $off & ", length " & $size &
        ") runs past the " & $available & " usable bytes")
  if result.kind == rlkSymlink:
    result.relative = (readU32(data, 16) and SymlinkFlagRelative) != 0
  result.substituteName = utf16leToUtf8(data, pathBuffer + subOff, subLen)
  result.printName = utf16leToUtf8(data, pathBuffer + printOff, printLen)
  # The substitute name is what the OS follows; the print name is display
  # text its creator chose (see the module note).
  result.target =
    if result.relative: result.substituteName
    else: stripNtObjectPrefix(result.substituteName)
  if result.target.len == 0:
    return ReparseLinkParse(tag: result.tag,
      reason: "reparse buffer names an empty target")
  result.ok = true

when defined(windows):
  import std/winlean
  from repro_core/paths import extendedPath

  const
    fsctlGetReparsePoint = 0x000900A8'i32
      ## `FSCTL_GET_REPARSE_POINT` (winioctl.h).

  proc deviceIoControl(hDevice: Handle; dwIoControlCode: DWORD;
                       lpInBuffer: pointer; nInBufferSize: DWORD;
                       lpOutBuffer: pointer; nOutBufferSize: DWORD;
                       lpBytesReturned: ptr DWORD;
                       lpOverlapped: pointer): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "DeviceIoControl", sideEffect.}

  proc raiseWin32(what, path: string; code: OSErrorCode) {.noreturn.} =
    raise newException(OSError, what & " '" & path & "': " &
      osErrorMsg(code).strip() & " (win32 error " & $int32(code) & ")")

  proc readReparseBuffer(path: string): seq[byte] =
    ## The raw `REPARSE_DATA_BUFFER` of `path`, not following it.
    let handle = createFileW(newWideCString(extendedPath(path)), 0.DWORD,
      (FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE).DWORD,
      nil, OPEN_EXISTING.DWORD,
      (FILE_FLAG_OPEN_REPARSE_POINT or FILE_FLAG_BACKUP_SEMANTICS).DWORD,
      Handle(0))
    if handle == INVALID_HANDLE_VALUE:
      raiseWin32("cannot open the link", path, osLastError())
    defer: discard closeHandle(handle)
    result = newSeq[byte](MaximumReparseDataBufferSize)
    var returned: DWORD = 0
    if deviceIoControl(handle, fsctlGetReparsePoint.DWORD, nil, 0.DWORD,
        addr result[0], DWORD(result.len), addr returned, nil) == 0:
      raiseWin32("cannot read the reparse point of", path, osLastError())
    result.setLen(int(returned))

proc readSymlinkTarget*(linkPath: string): string =
  ## The text `linkPath` points at, without following it — POSIX
  ## `readlink(2)`, and on Windows the reparse point's substitute name (see
  ## the module note). A relative target stays relative. Raises `OSError` when
  ## `linkPath` is not a link, cannot be opened, or is a reparse point of
  ## another kind; never returns `linkPath` itself as a stand-in.
  when defined(windows):
    let parsed = parseReparseDataBuffer(readReparseBuffer(linkPath))
    if not parsed.ok:
      raise newException(OSError,
        "cannot read the link target of '" & linkPath & "': " & parsed.reason)
    parsed.target
  else:
    expandSymlink(linkPath)

proc resolvedSymlinkTarget*(linkPath: string): string =
  ## `readSymlinkTarget`, made absolute: a relative target is joined to the
  ## link's own directory (where the OS resolves it) and normalized. The
  ## result names one hop, not the final landing place of a chain. Raises
  ## as `readSymlinkTarget` does.
  let raw = readSymlinkTarget(linkPath)
  if raw.isAbsolute:
    raw
  else:
    normalizedPath(parentDir(stripNtObjectPrefix(linkPath)) / raw)
