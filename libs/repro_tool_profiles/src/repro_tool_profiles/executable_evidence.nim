## Stat evidence for a resolved tool executable (ReproOS M7, sibling (7)).
##
## ## The defect this closes
##
## A cached tool identity records ``resolvedExecutableDigest`` -- the blake3
## of the executable's bytes, which the profile and typed-tool action
## fingerprints bind. Every cache hit (the in-process warm table, the stable
## identity file, the keyed cache file, a daemon-parent prewarm) only asked
## whether the recorded paths still EXIST, so a host executable rewritten in
## place was served with the OLD digest, warm or cold, and the actions it
## runs kept their old fingerprints.
##
## ## The check
##
## Re-hashing every executable on every hit is what the digest's own
## docstring rules out as a cold-path cost (measured by the M7 verifier: 15
## host executables, 236 MB, 4.2 s). Instead the identity records, next to
## the digest, the executable's stat evidence at the moment it was hashed,
## and every hit stats it (one ``stat`` per tool, sub-millisecond for all of
## them) and re-hashes ONLY when:
##
##   * any recorded field differs: size, mtime, the change time (NTFS
##     ``ChangeTime`` / POSIX ``st_ctim``), or the file identity (volume
##     serial + 64-bit file index, or the 128-bit ``FILE_ID_INFO`` id where
##     the volume provides one / ``st_dev`` + ``st_ino``) -- so a rewrite of
##     the same size with the mtime put back is still seen through the
##     change time, and a delete-and-recreate through the file identity;
##   * or the evidence is RACY: the recorded mtime or change time is within
##     ``RacyWindowNs`` of the moment hashing STARTED, i.e. a later write in
##     the same (coarse) timestamp tick could leave every field unchanged.
##     The window covers the 2 s FAT tick and the 1 s ext3/HFS+ ticks.
##
## A re-hash that yields a different digest is a cache MISS (the identity is
## re-resolved, so the new digest reaches the fingerprints). An equal digest
## is a hit and the refreshed evidence is written back, so the next hit is a
## stat again. Evidence taken while the file changed under the read is not
## recorded (every later hit re-hashes); a re-hash that sees the file change
## under it is a miss.
##
## ## Limits (stated in the M7 record)
##
## Only the executable itself: DLLs / shared objects / ``libexec`` next to
## it, a Scoop shim's ``.shim`` file, an interpreter a script names, are not
## evidenced -- exactly as ``resolvedExecutableDigest`` never covered them.
## A writer that restores the mtime AND the change time (NTFS lets a
## privileged process set ``ChangeTime`` through
## ``SetFileInformationByHandle``; POSIX offers no way to set ``st_ctim``
## short of changing the clock) and keeps the size and file identity is not
## seen until the evidence goes racy -- it never does once recorded.

import std/times

when defined(windows):
  import std/winlean
  import repro_core/paths as corepaths
else:
  import std/posix

const
  RacyWindowNs* = 2_000_000_000'i64
    ## A recorded mtime / change time closer than this to the moment the
    ## hash started is re-hashed on every hit.

type
  ExecutableEvidence* = object
    recorded*: bool
      ## False for a profile written before v9 or whose file changed while
      ## it was hashed: every hit re-hashes.
    size*: int64
    mtimeNs*: int64
      ## Nanoseconds since the Unix epoch.
    ctimeNs*: int64
      ## Change time (NTFS ``ChangeTime``, POSIX ``st_ctim``); 0 when the
      ## filesystem reports none.
    volume*: uint64
      ## Volume serial number / ``st_dev``.
    fileIdHigh*: uint64
    fileIdLow*: uint64
      ## File identity: the 128-bit ``FILE_ID_INFO`` id where available,
      ## else the 64-bit NTFS file index in ``fileIdLow`` / ``st_ino``.
    recordedAtNs*: int64
      ## When hashing STARTED (the racy-window reference).

proc nowNs*(): int64 =
  let t = getTime()
  t.toUnix * 1_000_000_000'i64 + int64(t.nanosecond)

when defined(windows):
  type
    FileBasicInfo = object
      creationTime: int64
      lastAccessTime: int64
      lastWriteTime: int64
      changeTime: int64
      fileAttributes: DWORD
    FileIdInfo = object
      volumeSerialNumber: uint64
      fileId: array[16, byte]

  const
    FileBasicInfoClass = 0'i32
    FileIdInfoClass = 18'i32
    FileReadAttributes = 0x80'i32
    FileTimeUnixEpoch = 116444736000000000'i64

  proc getFileInformationByHandleEx(hFile: Handle; infoClass: int32;
                                    info: pointer; size: DWORD): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "GetFileInformationByHandleEx".}

  proc ticksToUnixNs(ticks: int64): int64 =
    if ticks == 0: 0'i64 else: (ticks - FileTimeUnixEpoch) * 100

  proc fileTimeTicks(ft: FILETIME): int64 =
    (int64(ft.dwHighDateTime) shl 32) or int64(uint32(ft.dwLowDateTime))

proc statExecutable*(path: string): tuple[ok: bool; evidence: ExecutableEvidence] =
  ## The evidence of ``path`` now, following links (the digest reads through
  ## them, so a re-pointed link must show up as the target's identity).
  ## ``recordedAtNs`` is left 0; the caller stamps it.
  if path.len == 0:
    return
  when defined(windows):
    let wide = newWideCString(extendedPath(path))
    let handle = createFileW(wide, FileReadAttributes,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, Handle(0))
    if handle == INVALID_HANDLE_VALUE:
      return
    defer: discard closeHandle(handle)
    var info: BY_HANDLE_FILE_INFORMATION
    if getFileInformationByHandle(handle, addr info) == 0:
      return
    var e = ExecutableEvidence(recorded: true)
    e.size = (int64(uint32(info.nFileSizeHigh)) shl 32) or
      int64(uint32(info.nFileSizeLow))
    e.mtimeNs = ticksToUnixNs(fileTimeTicks(info.ftLastWriteTime))
    e.volume = uint64(uint32(info.dwVolumeSerialNumber))
    e.fileIdLow = (uint64(uint32(info.nFileIndexHigh)) shl 32) or
      uint64(uint32(info.nFileIndexLow))
    var basic: FileBasicInfo
    if getFileInformationByHandleEx(handle, FileBasicInfoClass, addr basic,
        DWORD(sizeof(basic))) != 0:
      e.ctimeNs = ticksToUnixNs(basic.changeTime)
      e.mtimeNs = ticksToUnixNs(basic.lastWriteTime)
    var idInfo: FileIdInfo
    if getFileInformationByHandleEx(handle, FileIdInfoClass, addr idInfo,
        DWORD(sizeof(idInfo))) != 0:
      e.volume = idInfo.volumeSerialNumber
      var hi, lo: uint64
      for k in 0 ..< 8:
        lo = lo or (uint64(idInfo.fileId[k]) shl (8 * k))
        hi = hi or (uint64(idInfo.fileId[8 + k]) shl (8 * k))
      e.fileIdHigh = hi
      e.fileIdLow = lo
    (ok: true, evidence: e)
  else:
    var st: Stat
    if stat(path.cstring, st) != 0:
      return
    var e = ExecutableEvidence(recorded: true)
    e.size = int64(st.st_size)
    e.mtimeNs = int64(st.st_mtim.tv_sec) * 1_000_000_000'i64 +
      int64(st.st_mtim.tv_nsec)
    e.ctimeNs = int64(st.st_ctim.tv_sec) * 1_000_000_000'i64 +
      int64(st.st_ctim.tv_nsec)
    e.volume = uint64(st.st_dev)
    e.fileIdLow = uint64(st.st_ino)
    (ok: true, evidence: e)

proc sameFileState*(a, b: ExecutableEvidence): bool =
  ## Every stat field equal (``recordedAtNs`` is not a file field). Two
  ## unrecorded evidences are never the same state.
  a.recorded and b.recorded and a.size == b.size and
    a.mtimeNs == b.mtimeNs and a.ctimeNs == b.ctimeNs and
    a.volume == b.volume and a.fileIdHigh == b.fileIdHigh and
    a.fileIdLow == b.fileIdLow

proc racy*(e: ExecutableEvidence): bool =
  ## The file was last written (or changed) so close to the moment its hash
  ## started that a later write in the same timestamp tick could leave every
  ## field unchanged.
  e.recordedAtNs - max(e.mtimeNs, e.ctimeNs) < RacyWindowNs
