## Per-host file content table: a file's local content hash, memoized on an
## identity the file cannot keep while its bytes change.
##
## Why. A record revalidated by content (`ffpChecksum`, `ffpHybrid`) hashes
## every input when it is recorded. A monitored compile observes its whole
## toolchain -- a gcc probe records about 200 inputs, `cc1.exe`, `as.exe`,
## the gcc and system DLLs, ~150 MB -- and every probe edge re-read and
## re-hashed all of it (reprobuild-pm issue 2026-10-10
## "trycompile-edge-cache-key-is-unique-to-its-configure", "Criterion 4,
## measured"). The bytes of a toolchain do not change between records.
##
## The model is BuildXL's `FileContentTable`
## (references/buildxl/Public/Src/Utilities/Storage/FileContentTable.cs): an
## entry is keyed by the file's identity on its volume and carries a VERSION
## the file system advances whenever the content changes and that user code
## cannot set back:
##
## * Windows: the file's USN in the NTFS change journal
##   (`FSCTL_READ_FILE_USN_DATA`). Every write moves it, and no API sets it.
##   A volume without an active journal yields no version, and its files are
##   simply not memoized (hashed every time, as before).
## * POSIX: the inode's status-change time (`st_ctim`), which the kernel
##   stamps on every content or metadata change and `utimes` cannot set.
##
## Size and modification time are compared too. An entry is trusted only if
## the file had been quiescent for `RacyWindowNs` before its hash STARTED
## (git's "racily clean" rule, as `repro_daemon_core`'s image-digest memo
## applies it): a version read from a coarse clock cannot separate two writes
## in one tick, but a file still being written within the window is simply
## hashed again. The soundness trade-off that remains is the one BuildXL
## accepts: a change that keeps the identity, size, modification time and
## version -- which needs privileged tampering with the journal or the system
## clock -- goes unseen.
##
## Entries live under `<action-cache root>/content-table/`, one small file per
## file identity, written by temp-and-rename. A missing, torn or foreign
## entry is a miss. The directory can be deleted at any time.

import std/[os, strutils, times]

when defined(windows):
  import std/winlean
when defined(posix):
  import std/posix

type
  ContentVersion* = object
    ## `known = false`: no memo for this file (unreadable, a symlink, a
    ## volume without a change journal); the caller hashes it.
    known*: bool
    volumeId*: uint64
    fileId*: uint64
    sizeBytes*: uint64
    mtimeUnixNs*: int64
    version*: uint64

const
  RacyWindowNs* = 2_000_000_000'i64
    ## Two seconds: the coarsest modification-time granularity in common use
    ## (FAT), with the coarse kernel clock's lag far inside it.
  EntryMagic = "RBCT1"

var tableRoot = ""
  ## Set once per engine run (`setContentTableRoot`) and only read after
  ## that; the accessors cast away the GC-safety analysis for that reason.

proc setContentTableRoot*(root: string) {.gcsafe.} =
  ## Enable the table for this process, rooted at `root`. Empty disables it.
  {.cast(gcsafe).}:
    tableRoot = root

proc contentTableRoot*(): string {.gcsafe.} =
  {.cast(gcsafe).}:
    result = tableRoot

when defined(windows):
  const
    FSCTL_READ_FILE_USN_DATA = 0x000900EB'i32
    FILE_FLAG_BACKUP_SEMANTICS_CT = 0x02000000'i32
    FILE_FLAG_OPEN_REPARSE_POINT_CT = 0x00200000'i32
    FILE_ATTRIBUTE_REPARSE_POINT_CT = 0x400'i32

  proc deviceIoControl(device: Handle; code: int32; inBuf: pointer;
                       inSize: int32; outBuf: pointer; outSize: int32;
                       returned: ptr int32; overlapped: pointer): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "DeviceIoControl".}

  proc filetimeToUnixNs(ft: FILETIME): int64 =
    let raw = (int64(uint32(ft.dwHighDateTime)) shl 32) or
      int64(uint32(ft.dwLowDateTime))
    (raw - 116444736000000000'i64) * 100

proc contentVersion*(path: string): ContentVersion =
  ## The identity and version of the regular file at `path`, without reading
  ## it. Never raises; anything it cannot establish is `known = false`.
  when defined(windows):
    # Opened for no access at all (metadata only), and on the link itself:
    # a symbolic link's content identity includes its target text, which a
    # memo keyed on the target's identity would not see change.
    let h = createFileW(newWideCString(path), 0'i32,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS_CT or FILE_FLAG_OPEN_REPARSE_POINT_CT, 0)
    if h == INVALID_HANDLE_VALUE:
      return
    defer: discard closeHandle(h)
    var info: BY_HANDLE_FILE_INFORMATION
    if getFileInformationByHandle(h, addr info) == 0:
      return
    if (info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) != 0 or
        (info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT_CT) != 0:
      return
    var record: array[512, byte]
    var returned: int32 = 0
    if deviceIoControl(h, FSCTL_READ_FILE_USN_DATA, nil, 0, addr record[0],
        int32(record.len), addr returned, nil) == 0 or returned < 8:
      return
    # USN_RECORD_V2: Usn at byte 24; V3 (128-bit file references): byte 40.
    let major = uint16(record[4]) or (uint16(record[5]) shl 8)
    let offset = case major
      of 2: 24
      of 3: 40
      else: -1
    if offset < 0 or returned < int32(offset + 8):
      return
    var usn: uint64 = 0
    for i in 0 ..< 8:
      usn = usn or (uint64(record[offset + i]) shl (8 * i))
    if usn == 0:
      return
    result.volumeId = uint64(uint32(info.dwVolumeSerialNumber))
    result.fileId = (uint64(uint32(info.nFileIndexHigh)) shl 32) or
      uint64(uint32(info.nFileIndexLow))
    result.sizeBytes = (uint64(uint32(info.nFileSizeHigh)) shl 32) or
      uint64(uint32(info.nFileSizeLow))
    result.mtimeUnixNs = filetimeToUnixNs(info.ftLastWriteTime)
    result.version = usn
    result.known = true
  elif defined(posix):
    var st: Stat
    if lstat(cstring(path), st) != 0 or not S_ISREG(st.st_mode):
      return
    result.volumeId = uint64(st.st_dev)
    result.fileId = uint64(st.st_ino)
    result.sizeBytes = uint64(st.st_size)
    result.mtimeUnixNs = int64(st.st_mtim.tv_sec) * 1_000_000_000'i64 +
      int64(st.st_mtim.tv_nsec)
    result.version = uint64(st.st_ctim.tv_sec) * 1_000_000_000'u64 +
      uint64(st.st_ctim.tv_nsec)
    result.known = true
  else:
    discard

proc stamp(v: ContentVersion): string =
  $v.volumeId & ":" & $v.fileId & ":" & $v.sizeBytes & ":" & $v.mtimeUnixNs &
    ":" & $v.version

proc entryPath(v: ContentVersion): string =
  contentTableRoot() / toHex(v.volumeId, 8).toLowerAscii /
    (toHex(v.fileId, 16).toLowerAscii & ".cte")

proc nowUnixNs(): int64 =
  let t = getTime()
  t.toUnix * 1_000_000_000'i64 + int64(t.nanosecond)

proc lookupContentHash*(v: ContentVersion; key: string): string =
  ## The memoized hash text recorded under `key` (the caller's name for the
  ## hash kind) for the file `v` describes, or "" on any miss. Trusted only
  ## when the stamp matches exactly and the file had been quiescent for
  ## `RacyWindowNs` before that hash started.
  if contentTableRoot().len == 0 or not v.known:
    return ""
  try:
    let lines = readFile(entryPath(v)).splitLines()
    if lines.len < 5 or lines[0] != EntryMagic or lines[1] != stamp(v) or
        lines[2] != key:
      return ""
    let hashStartedNs = parseBiggestInt(lines[3])
    if v.mtimeUnixNs <= 0 or v.mtimeUnixNs >= hashStartedNs - RacyWindowNs:
      return ""
    lines[4]
  except CatchableError:
    ""

proc recordContentHash*(v: ContentVersion; key, hash: string;
                        hashStartedNs: int64) =
  ## Memoize `hash` for the file `v` describes, as computed by a hash that
  ## started at `hashStartedNs`. Best-effort: a write failure costs a re-hash
  ## next time, never the build.
  if contentTableRoot().len == 0 or not v.known or hash.len == 0:
    return
  let path = entryPath(v)
  let tmp = path & ".tmp." & $getCurrentProcessId() & "." & $nowUnixNs()
  try:
    createDir(parentDir(path))
    writeFile(tmp, EntryMagic & "\n" & stamp(v) & "\n" & key & "\n" &
      $hashStartedNs & "\n" & hash & "\n")
    moveFile(tmp, path)
  except CatchableError:
    try: removeFile(tmp)
    except CatchableError: discard

proc hashStartNs*(): int64 = nowUnixNs()
  ## The instant to pass to `recordContentHash`: taken BEFORE the version is
  ## read and the file hashed, so a write racing the hash is never older
  ## than it.
