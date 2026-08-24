## Filesystem link-capability probe — Local-CAS-Hardlink-Materialization M0.
##
## Spec: ``reprobuild-specs/Local-Content-Addressed-Store.md``
##       §"Hardlink, Reflink, and Copy Policy" (normative).
##
## The store materializes a CAS blob into a destination by one of three
## mechanisms, and they are NOT interchangeable — they differ in exactly
## the property that decides whether sharing is safe:
##
## ==========  ==========================  ======================================
## mechanism   storage                     mutation through one name
## ==========  ==========================  ======================================
## reflink     shared extents until write  breaks sharing on write — SAFE
## hardlink    one inode, N names          visible through ALL names — THE HAZARD
## copy        independent                 independent
## ==========  ==========================  ======================================
##
## So the preference order is reflink → hardlink → copy, and it is driven
## by safety first and cost second: a reflink is both cheaper than a copy
## and safer than a hardlink. See ``preferredMechanisms``.
##
## **Availability is not a filesystem-name lookup.** This module never
## decides from a mount-type string. It ATTEMPTS the operation once per
## filesystem pair and caches what actually happened, because prediction
## is wrong in ways that matter:
##
## * Same-device is necessary but not sufficient. On Btrfs ``link()``
##   across subvolumes fails ``EXDEV`` on a single device, because
##   subvolumes carry distinct ``st_dev``.
## * Reflink is an operation, not a filesystem property: ``FICLONE`` on
##   Linux (Btrfs, XFS with ``reflink=1``), ``clonefile(2)`` on APFS,
##   ``FSCTL_DUPLICATE_EXTENTS_TO_FILE`` on Windows ReFS. NTFS has none,
##   which is exactly why the spec says "Windows: NTFS hardlinks are used
##   by default".
## * Network filesystems may advertise hardlinks with weaker semantics
##   and generally offer no reflink; server-side copy offload is a copy.
## * Overlayfs interposes copy-up semantics that change what a write
##   through a link does; a bind mount does not.
##
## **What the probe deliberately does NOT answer.** NTFS caps a file at
## 1023 hardlinks. That limit is a property of an individual blob, not of
## the filesystem pair, so it cannot be cached here: a pair whose probe
## said ``hardlink = true`` can still fail ``ERROR_TOO_MANY_LINKS`` on a
## widely-shared blob. Callers MUST treat ``loLinkLimitExceeded`` from a
## real ``attemptHardlink`` as "fall back to copy for THIS file" and MUST
## NOT invalidate the cached capability. See ``isPerFileFallback``.
##
## This module is scoped to the filesystem primitives the policy needs: the
## model, the probe, and the per-file observations (``hardlinkCount``,
## ``fileIdentity``) that "one inode" makes meaningful. It has no opinion
## about ``casMaterialize`` (M1) or where path-based ingest stages its
## work (M2). The one policy statement it does carry is
## ``preferredMechanisms``' ``allowSharedInode`` lever, which M3 settled:
## see its doc comment.

import std/[locks, os, strutils, tables]

from repro_core/paths import extendedPath

when defined(windows):
  import std/winlean

when defined(posix):
  import std/posix

# ---------------------------------------------------------------------------
# Public model
# ---------------------------------------------------------------------------

type
  LinkMechanism* = enum
    ## The three ways a blob can reach a destination path, in the order
    ## the spec prefers them.
    lmReflink   ## COW clone. Shared extents; a write to either name
                ## copies the touched extents instead of editing the
                ## shared ones. Cheap AND safe.
    lmHardlink  ## One inode, N names. Cheapest, but a write through the
                ## destination edits the CAS blob — the hazard M3 exists
                ## to fence.
    lmCopy      ## Independent bytes. Always available; always correct.

  LinkOutcome* = enum
    ## Why an attempt did or did not work. Derived from the operation's
    ## OWN error (``EXDEV``, ``ERROR_NOT_SAME_DEVICE``,
    ## ``ERROR_INVALID_FUNCTION``, ...), never from a guess about the
    ## filesystem.
    loOk                 ## The link/clone exists and holds the source bytes.
    loCrossDevice        ## EXDEV / ERROR_NOT_SAME_DEVICE. Distinct
                         ## filesystems (or Btrfs subvolumes) — never
                         ## retryable for this pair.
    loUnsupported        ## The filesystem or OS does not implement the
                         ## operation at all (NTFS reflink →
                         ## ERROR_INVALID_FUNCTION; EOPNOTSUPP; ENOSYS).
    loLinkLimitExceeded  ## EMLINK / ERROR_TOO_MANY_LINKS /
                         ## ERROR_BLOCK_TOO_MANY_REFERENCES. A PER-FILE
                         ## limit, not a pair capability.
    loPermissionDenied   ## EPERM / EACCES / ERROR_ACCESS_DENIED.
    loOther              ## Anything else, including a link that was
                         ## created but did not verify.

  LinkAttempt* = object
    ## The result of one real attempt, kept as a diagnostic so a caller
    ## can log *why* it fell back rather than only *that* it did.
    outcome*: LinkOutcome
    errorCode*: int    ## ``errno`` / ``GetLastError``; 0 when unused.
    message*: string   ## Human-readable, safe to log. Never parsed.

  LinkCapability* = object
    ## What a (source directory, destination directory) pair supports.
    probed*: bool
      ## ``true`` when both mechanisms were actually attempted. ``false``
      ## means the probe could not run at all (unwritable source, missing
      ## destination) — such a result is NOT cached, so a later call with
      ## a usable directory re-probes.
    hardlink*: bool
    reflink*: bool
    hardlinkAttempt*: LinkAttempt
    reflinkAttempt*: LinkAttempt
    key*: string
      ## The filesystem-pair cache key this answer is filed under.

  LinkCapabilityCache* = object
    ## Per-filesystem-pair memo. Explicitly passed so tests can observe
    ## the probe count; ``linkCapabilities`` wraps a process-wide one.
    entries: Table[string, LinkCapability]
    probes: int

# ---------------------------------------------------------------------------
# Platform bindings
# ---------------------------------------------------------------------------

when defined(windows):
  const
    ErrInvalidFunction = 1
    ErrAccessDenied = 5
    ErrNotSameDevice = 17
    ErrNotSupported = 50
    ErrInvalidParameter = 87
    ErrBlockTooManyReferences = 347
    ErrTooManyLinks = 1142

    FsctlDuplicateExtentsToFile = 0x00098344'i32
      ## ReFS block cloning. NTFS answers ERROR_INVALID_FUNCTION.

    FileEndOfFileInfo = 6'i32
      ## ``FILE_INFO_BY_HANDLE_CLASS.FileEndOfFileInfo``.

  type
    DuplicateExtentsData = object
      ## ``DUPLICATE_EXTENTS_DATA`` from ``winioctl.h``.
      fileHandle: Handle
      sourceFileOffset: int64
      targetFileOffset: int64
      byteCount: int64

  proc createHardLinkW(lpFileName, lpExistingFileName: WideCString;
                       lpSecurityAttributes: pointer): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "CreateHardLinkW".}

  proc deviceIoControl(hDevice: Handle; dwIoControlCode: DWORD;
                       lpInBuffer: pointer; nInBufferSize: DWORD;
                       lpOutBuffer: pointer; nOutBufferSize: DWORD;
                       lpBytesReturned: ptr DWORD;
                       lpOverlapped: pointer): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "DeviceIoControl".}

  proc setFileInformationByHandle(hFile: Handle; klass: int32;
                                  lpFileInformation: pointer;
                                  dwBufferSize: DWORD): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "SetFileInformationByHandle".}

  proc getVolumePathNameW(lpszFileName: WideCString;
                          lpszVolumePathName: WideCString;
                          cchBufferLength: DWORD): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "GetVolumePathNameW".}

  proc getVolumeInformationW(lpRootPathName: WideCString;
                             lpVolumeNameBuffer: WideCString;
                             nVolumeNameSize: DWORD;
                             lpVolumeSerialNumber: ptr DWORD;
                             lpMaximumComponentLength: ptr DWORD;
                             lpFileSystemFlags: ptr DWORD;
                             lpFileSystemNameBuffer: WideCString;
                             nFileSystemNameSize: DWORD): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "GetVolumeInformationW".}

  proc getDiskFreeSpaceW(lpRootPathName: WideCString;
                         lpSectorsPerCluster: ptr DWORD;
                         lpBytesPerSector: ptr DWORD;
                         lpNumberOfFreeClusters: ptr DWORD;
                         lpTotalNumberOfClusters: ptr DWORD): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "GetDiskFreeSpaceW".}

elif defined(linux):
  const
    Ficlone = 0x40049409'u
      ## ``_IOW(0x94, 9, int)``. Btrfs / XFS-with-reflink / bcachefs.

  proc ioctlClone(f: cint; device: uint): cint
    {.importc: "ioctl", header: "<sys/ioctl.h>", varargs, discardable.}

elif defined(macosx):
  proc clonefile(src, dst: cstring; flags: cint): cint
    {.importc: "clonefile", header: "<sys/clonefile.h>".}

# ---------------------------------------------------------------------------
# Error classification — always from the operation's own error
# ---------------------------------------------------------------------------

when defined(windows):
  proc classifyWinError(code: int; what: string): LinkAttempt =
    let outcome =
      case code
      of ErrNotSameDevice: loCrossDevice
      of ErrInvalidFunction, ErrNotSupported: loUnsupported
      of ErrTooManyLinks, ErrBlockTooManyReferences: loLinkLimitExceeded
      of ErrAccessDenied: loPermissionDenied
      of ErrInvalidParameter: loUnsupported
      else: loOther
    LinkAttempt(outcome: outcome, errorCode: code,
                message: what & " failed with Windows error " & $code)

when defined(posix):
  proc classifyPosixError(code: int; what: string): LinkAttempt =
    let outcome =
      if code == EXDEV: loCrossDevice
      elif code == EMLINK: loLinkLimitExceeded
      elif code == EPERM or code == EACCES: loPermissionDenied
      elif code == EOPNOTSUPP or code == ENOSYS or code == EINVAL:
        loUnsupported
      else: loOther
    LinkAttempt(outcome: outcome, errorCode: code,
                message: what & " failed with errno " & $code)

proc isPerFileFallback*(attempt: LinkAttempt): bool =
  ## ``true`` when the failure is a property of THIS file rather than of
  ## the filesystem pair — NTFS's 1023-link cap and ReFS's per-extent
  ## reference cap being the two that matter. A caller that hits this
  ## MUST fall back to copy for the one file and MUST NOT invalidate the
  ## cached pair capability, and MUST NOT surface it as a build error.
  attempt.outcome == loLinkLimitExceeded

# ---------------------------------------------------------------------------
# Mechanism attempts
# ---------------------------------------------------------------------------

proc attemptHardlink*(src, dst: string): LinkAttempt =
  ## Create ``dst`` as a second name for ``src``'s inode. ``dst`` MUST
  ## NOT already exist. Never raises; the outcome carries the reason.
  ##
  ## Reminder from the model above: on success ``src`` and ``dst`` are
  ## the SAME inode, so mode bits, timestamps and in-place writes are
  ## shared between them.
  when defined(windows):
    let ok = createHardLinkW(newWideCString(extendedPath(dst)),
                             newWideCString(extendedPath(src)), nil)
    if ok == 0:
      return classifyWinError(int(getLastError()), "CreateHardLinkW")
    LinkAttempt(outcome: loOk)
  elif defined(posix):
    if link(cstring(src), cstring(dst)) != 0:
      return classifyPosixError(int(errno), "link()")
    LinkAttempt(outcome: loOk)
  else:
    LinkAttempt(outcome: loUnsupported,
                message: "hardlinks are not available on this platform")

when defined(windows):
  proc volumeRootOf(path: string): string =
    ## The mount point that owns ``path`` (``C:\``, or a directory when a
    ## volume is mounted into a folder). Empty when it cannot be found.
    var buf: array[512, Utf16Char]
    if getVolumePathNameW(newWideCString(path),
                          cast[WideCString](addr buf[0]),
                          DWORD(buf.len)) == 0:
      return ""
    $cast[WideCString](addr buf[0])

  proc clusterSizeOf(path: string): int64 =
    ## Bytes per allocation unit on the volume owning ``path``.
    ## ``FSCTL_DUPLICATE_EXTENTS_TO_FILE`` requires cluster-aligned
    ## offsets and byte counts. Falls back to 4 KiB, the ReFS default.
    let root = volumeRootOf(path)
    if root.len == 0:
      return 4096
    var sectorsPerCluster, bytesPerSector, freeClusters, totalClusters: DWORD
    if getDiskFreeSpaceW(newWideCString(root), addr sectorsPerCluster,
                         addr bytesPerSector, addr freeClusters,
                         addr totalClusters) == 0:
      return 4096
    let size = int64(uint32(sectorsPerCluster)) * int64(uint32(bytesPerSector))
    if size <= 0: 4096 else: size

proc attemptReflink*(src, dst: string): LinkAttempt =
  ## Create ``dst`` as a copy-on-write clone of ``src``: the extents are
  ## shared until either name is written, at which point the written
  ## extents are copied. This is the mechanism the spec prefers, because
  ## it is the only cheap one whose mutation semantics match a copy.
  ##
  ## Any partially created ``dst`` is removed before returning a failure,
  ## so a failed attempt leaves no debris for the caller to clean up.
  when defined(windows):
    let srcW = newWideCString(extendedPath(src))
    let srcH = createFileW(srcW, GENERIC_READ,
                           FILE_SHARE_READ or FILE_SHARE_WRITE or
                             FILE_SHARE_DELETE,
                           nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0)
    if srcH == INVALID_HANDLE_VALUE:
      return classifyWinError(int(getLastError()), "CreateFileW(source)")
    var info: BY_HANDLE_FILE_INFORMATION
    if getFileInformationByHandle(srcH, addr info) == 0:
      let code = int(getLastError())
      discard closeHandle(srcH)
      return classifyWinError(code, "GetFileInformationByHandle")
    let size = (int64(uint32(info.nFileSizeHigh)) shl 32) or
               int64(uint32(info.nFileSizeLow))
    let dstW = newWideCString(extendedPath(dst))
    let dstH = createFileW(dstW, GENERIC_READ or GENERIC_WRITE, 0, nil,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0)
    if dstH == INVALID_HANDLE_VALUE:
      let code = int(getLastError())
      discard closeHandle(srcH)
      return classifyWinError(code, "CreateFileW(destination)")

    template failWin(code: int; what: string): LinkAttempt =
      discard closeHandle(dstH)
      discard closeHandle(srcH)
      try: removeFile(extendedPath(dst)) except CatchableError: discard
      classifyWinError(code, what)

    if size == 0:
      # A zero-length clone shares nothing and needs no FSCTL; the empty
      # destination created above already IS the clone. Issuing the
      # ioctl with a zero byte count would answer ERROR_INVALID_PARAMETER
      # and be misread as "reflink unsupported here".
      discard closeHandle(dstH)
      discard closeHandle(srcH)
      return LinkAttempt(outcome: loOk)

    let cluster = clusterSizeOf(dst)
    let aligned = ((size + cluster - 1) div cluster) * cluster
    # The destination must already be at least as long as the cloned
    # range; the FSCTL does not extend it.
    var eof = aligned
    if setFileInformationByHandle(dstH, FileEndOfFileInfo, addr eof,
                                  DWORD(sizeof(eof))) == 0:
      return failWin(int(getLastError()), "SetEndOfFile(aligned)")
    var request = DuplicateExtentsData(fileHandle: srcH,
                                       sourceFileOffset: 0,
                                       targetFileOffset: 0,
                                       byteCount: aligned)
    var returned: DWORD
    if deviceIoControl(dstH, FsctlDuplicateExtentsToFile, addr request,
                       DWORD(sizeof(request)), nil, 0, addr returned,
                       nil) == 0:
      return failWin(int(getLastError()), "FSCTL_DUPLICATE_EXTENTS_TO_FILE")
    # Trim the cluster-alignment padding back off so the clone is
    # byte-identical to the source.
    var realEof = size
    if setFileInformationByHandle(dstH, FileEndOfFileInfo, addr realEof,
                                  DWORD(sizeof(realEof))) == 0:
      return failWin(int(getLastError()), "SetEndOfFile(exact)")
    discard closeHandle(dstH)
    discard closeHandle(srcH)
    LinkAttempt(outcome: loOk)
  elif defined(linux):
    let srcFd = posix.open(cstring(src), O_RDONLY)
    if srcFd < 0:
      return classifyPosixError(int(errno), "open(source)")
    let dstFd = posix.open(cstring(dst), O_WRONLY or O_CREAT or O_TRUNC,
                           Mode(0o644))
    if dstFd < 0:
      let code = int(errno)
      discard posix.close(srcFd)
      return classifyPosixError(code, "open(destination)")
    let rc = ioctlClone(dstFd, Ficlone, srcFd)
    let code = int(errno)
    discard posix.close(dstFd)
    discard posix.close(srcFd)
    if rc != 0:
      try: removeFile(dst) except CatchableError: discard
      return classifyPosixError(code, "ioctl(FICLONE)")
    LinkAttempt(outcome: loOk)
  elif defined(macosx):
    if clonefile(cstring(src), cstring(dst), 0) != 0:
      return classifyPosixError(int(errno), "clonefile()")
    LinkAttempt(outcome: loOk)
  else:
    LinkAttempt(outcome: loUnsupported,
                message: "no reflink primitive is bound for this platform")

# ---------------------------------------------------------------------------
# Inode-level observations that follow from "one inode"
# ---------------------------------------------------------------------------

proc hardlinkCount*(path: string): int =
  ## Number of directory entries naming ``path``'s inode
  ## (``st_nlink`` / ``nNumberOfLinks``), or ``-1`` when it cannot be
  ## determined.
  ##
  ## This is the free signal in the other direction the model calls for:
  ## a CAS blob whose count exceeds the store's own reference tells the
  ## GC that outstanding materializations exist that it did not record.
  when defined(windows):
    let h = createFileW(newWideCString(extendedPath(path)), 0,
                        FILE_SHARE_READ or FILE_SHARE_WRITE or
                          FILE_SHARE_DELETE,
                        nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0)
    if h == INVALID_HANDLE_VALUE:
      return -1
    var info: BY_HANDLE_FILE_INFORMATION
    let ok = getFileInformationByHandle(h, addr info)
    discard closeHandle(h)
    if ok == 0: -1 else: int(uint32(info.nNumberOfLinks))
  elif defined(posix):
    var st: Stat
    if stat(cstring(path), st) != 0: -1 else: int(st.st_nlink)
  else:
    -1

type
  FileIdentity* = object
    ## A witness that a file is still the same file holding the same
    ## bytes. Local-CAS-Hardlink-Materialization **M2** needs this because
    ## path-based ingest hashes a source and then links it: between those
    ## two steps the source must not have changed, and a blob whose digest
    ## does not match its content is a corrupt store.
    ##
    ## Deliberately more than a size check. The pre-M2 ingest compared
    ## sizes alone, which cannot see an in-place rewrite of the same
    ## length, and cannot see the source being replaced by a different
    ## file at the same path.
    known*: bool
      ## ``false`` when the file could not be stat'd at all. A caller
      ## comparing two identities MUST treat "not known" as "changed" —
      ## see ``sameFileIdentity``.
    sizeBytes*: uint64
    mtimeRaw*: uint64
      ## An OPAQUE last-write stamp: POSIX nanoseconds since the epoch,
      ## Windows ``FILETIME`` 100-ns ticks since 1601. Deliberately not
      ## normalised to one unit — the value is only ever compared with
      ## another value from this same proc, and normalising Windows'
      ## ticks to nanoseconds overflows a 64-bit integer.
    volumeId*: uint64  ## ``st_dev`` / ``dwVolumeSerialNumber``.
    fileId*: uint64    ## ``st_ino`` / ``nFileIndex{High,Low}``.
    linkCount*: int
      ## ``st_nlink`` / ``nNumberOfLinks``. Reported but deliberately NOT
      ## part of ``sameFileIdentity``: another name appearing on the inode
      ## does not change the bytes, and the ingest's own hardlink arm
      ## raises this count itself.

proc fileIdentity*(path: string): FileIdentity =
  ## Stat ``path`` into a comparable witness. Never raises; an
  ## unreachable file yields ``known = false``.
  when defined(windows):
    let h = createFileW(newWideCString(extendedPath(path)), 0,
                        FILE_SHARE_READ or FILE_SHARE_WRITE or
                          FILE_SHARE_DELETE,
                        nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0)
    if h == INVALID_HANDLE_VALUE:
      return
    var info: BY_HANDLE_FILE_INFORMATION
    let ok = getFileInformationByHandle(h, addr info)
    discard closeHandle(h)
    if ok == 0:
      return
    result.sizeBytes = (uint64(uint32(info.nFileSizeHigh)) shl 32) or
                       uint64(uint32(info.nFileSizeLow))
    result.mtimeRaw =
      (uint64(uint32(info.ftLastWriteTime.dwHighDateTime)) shl 32) or
      uint64(uint32(info.ftLastWriteTime.dwLowDateTime))
    result.volumeId = uint64(uint32(info.dwVolumeSerialNumber))
    result.fileId = (uint64(uint32(info.nFileIndexHigh)) shl 32) or
                    uint64(uint32(info.nFileIndexLow))
    result.linkCount = int(uint32(info.nNumberOfLinks))
    result.known = true
  elif defined(posix):
    var st: Stat
    if stat(cstring(path), st) != 0:
      return
    result.sizeBytes = uint64(st.st_size)
    result.mtimeRaw = uint64(st.st_mtim.tv_sec) * 1_000_000_000'u64 +
                      uint64(st.st_mtim.tv_nsec)
    result.volumeId = uint64(st.st_dev)
    result.fileId = uint64(st.st_ino)
    result.linkCount = int(st.st_nlink)
    result.known = true
  else:
    discard

proc sameFileIdentity*(a, b: FileIdentity): bool =
  ## ``true`` only when both witnesses were obtained AND agree on size,
  ## last-write time, and which file on which volume this is.
  ##
  ## Conservative by construction: an unknown identity on either side is
  ## "changed", so a caller that cannot stat the source falls back to the
  ## mechanism that does not depend on the source staying still.
  a.known and b.known and
    a.sizeBytes == b.sizeBytes and
    a.mtimeRaw == b.mtimeRaw and
    a.volumeId == b.volumeId and
    a.fileId == b.fileId

proc describe*(id: FileIdentity): string =
  ## One-line diagnostic. Safe to log; never parsed.
  if not id.known:
    return "identity=unknown"
  "size=" & $id.sizeBytes & " mtimeRaw=" & $id.mtimeRaw &
    " volume=" & $id.volumeId & " fileId=" & $id.fileId &
    " links=" & $id.linkCount

proc filesystemName*(path: string): string =
  ## The filesystem type as the OS reports it (``NTFS``, ``ReFS``, ...),
  ## or ``""`` when unknown.
  ##
  ## DIAGNOSTIC ONLY. Nothing in this module decides a capability from
  ## this string, and callers MUST NOT either — that is the prediction
  ## the probe exists to replace. It is here so a log line can say which
  ## filesystem answered the way it did.
  when defined(windows):
    let root = volumeRootOf(path)
    if root.len == 0:
      return ""
    var fsName: array[64, Utf16Char]
    if getVolumeInformationW(newWideCString(root), nil, 0, nil, nil, nil,
                             cast[WideCString](addr fsName[0]),
                             DWORD(fsName.len)) == 0:
      return ""
    $cast[WideCString](addr fsName[0])
  else:
    ""

# ---------------------------------------------------------------------------
# Filesystem-pair identity (the CACHE KEY — never the answer)
# ---------------------------------------------------------------------------

proc deviceKeyOf(dir: string): string =
  ## A cheap stable identity for the filesystem holding ``dir``, used
  ## ONLY to file the probe result. Returns ``""`` when the identity
  ## cannot be established, which makes the caller fall back to a
  ## path-based key — more probes, never a wrong answer.
  when defined(windows):
    let h = createFileW(newWideCString(extendedPath(dir)), 0,
                        FILE_SHARE_READ or FILE_SHARE_WRITE or
                          FILE_SHARE_DELETE,
                        nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0)
    if h == INVALID_HANDLE_VALUE:
      return ""
    var info: BY_HANDLE_FILE_INFORMATION
    let ok = getFileInformationByHandle(h, addr info)
    discard closeHandle(h)
    if ok == 0:
      return ""
    # Serial alone can collide across cloned disks, so pair it with the
    # mount point that owns the directory.
    volumeRootOf(dir).toLowerAscii & "#" & $uint32(info.dwVolumeSerialNumber)
  elif defined(posix):
    var st: Stat
    if stat(cstring(dir), st) != 0:
      return ""
    # ``st_dev`` is the right key even where it is a poor predictor: a
    # Btrfs subvolume has its own ``st_dev``, so the pair that refuses
    # ``link()`` gets its own cache entry rather than inheriting the
    # parent volume's answer.
    "dev#" & $uint64(st.st_dev)
  else:
    ""

proc filesystemPairKey*(srcDir, dstDir: string): string =
  ## Cache key for the (source, destination) filesystem pair. Exposed so
  ## callers can log which pair an answer came from, and so tests can
  ## assert that two genuinely different pairs get different entries.
  let a = deviceKeyOf(srcDir)
  let b = deviceKeyOf(dstDir)
  if a.len == 0 or b.len == 0:
    "path:" & srcDir.toLowerAscii & "->path:" & dstDir.toLowerAscii
  else:
    a & "->" & b

# ---------------------------------------------------------------------------
# The probe
# ---------------------------------------------------------------------------

var probeSerial: int

proc probeFileName(tag: string): string =
  probeSerial.inc
  ".repro-linkprobe-" & tag & "-" & $getCurrentProcessId() & "-" & $probeSerial

proc quietRemove(path: string) =
  try:
    if fileExists(extendedPath(path)):
      removeFile(extendedPath(path))
  except CatchableError, Defect:
    discard

proc sameBytes(a, b: string): bool =
  try:
    readFile(extendedPath(a)) == readFile(extendedPath(b))
  except CatchableError:
    false

const ProbePayloadSize = 8192
  ## Deliberately larger than one cluster on every filesystem this runs
  ## on, so a reflink attempt exercises a real extent duplication rather
  ## than a degenerate zero/short-file path.

proc probeUncached(srcDir, dstDir: string): LinkCapability =
  ## One real probe. Both mechanisms are attempted and the resulting
  ## link is VERIFIED (content, and for hardlinks the shared link count)
  ## before it is called available — an API that returns success while
  ## producing a wrong file must not be recorded as a capability.
  result = LinkCapability(probed: false)
  if not dirExists(extendedPath(srcDir)) or not dirExists(extendedPath(dstDir)):
    let why = LinkAttempt(outcome: loOther,
                          message: "probe skipped: source or destination " &
                                   "directory does not exist")
    result.hardlinkAttempt = why
    result.reflinkAttempt = why
    return

  let probeSrc = srcDir / probeFileName("src")
  var payload = newString(ProbePayloadSize)
  for i in 0 ..< ProbePayloadSize:
    payload[i] = char((i * 31 + 7) and 0xFF)
  try:
    writeFile(extendedPath(probeSrc), payload)
  except CatchableError, Defect:
    let why = LinkAttempt(outcome: loPermissionDenied,
                          message: "probe skipped: source directory is not " &
                                   "writable (" & srcDir & ")")
    result.hardlinkAttempt = why
    result.reflinkAttempt = why
    return

  defer: quietRemove(probeSrc)

  block hardlinkArm:
    let dst = dstDir / probeFileName("hl")
    quietRemove(dst)
    var attempt = attemptHardlink(probeSrc, dst)
    if attempt.outcome == loOk:
      if not sameBytes(probeSrc, dst):
        attempt = LinkAttempt(outcome: loOther,
                              message: "hardlink reported success but the " &
                                       "destination bytes differ")
      elif hardlinkCount(probeSrc) < 2:
        attempt = LinkAttempt(outcome: loOther,
                              message: "hardlink reported success but the " &
                                       "inode link count did not rise")
    quietRemove(dst)
    result.hardlinkAttempt = attempt
    result.hardlink = attempt.outcome == loOk

  block reflinkArm:
    let dst = dstDir / probeFileName("rl")
    quietRemove(dst)
    var attempt = attemptReflink(probeSrc, dst)
    if attempt.outcome == loOk and not sameBytes(probeSrc, dst):
      attempt = LinkAttempt(outcome: loOther,
                            message: "reflink reported success but the " &
                                     "destination bytes differ")
    quietRemove(dst)
    result.reflinkAttempt = attempt
    result.reflink = attempt.outcome == loOk

  result.probed = true

proc probeLinkCapabilities*(cache: var LinkCapabilityCache;
                            srcDir, dstDir: string): LinkCapability =
  ## Answer which mechanisms work from ``srcDir`` to ``dstDir``, probing
  ## at most once per filesystem pair.
  ##
  ## A result that could not be probed at all (``probed == false``) is
  ## NOT cached: an unwritable source or a missing destination is a
  ## property of those directories, not of the filesystem pair, and
  ## caching it would poison every later caller on the same pair.
  let key = filesystemPairKey(srcDir, dstDir)
  if cache.entries.hasKey(key):
    return cache.entries[key]
  result = probeUncached(srcDir, dstDir)
  result.key = key
  if result.probed:
    cache.probes.inc
    cache.entries[key] = result

proc probeCount*(cache: LinkCapabilityCache): int =
  ## How many real probes this cache has performed. A second call for an
  ## already-known filesystem pair must not move it.
  cache.probes

proc cachedPairCount*(cache: LinkCapabilityCache): int =
  ## How many distinct filesystem pairs have a cached answer.
  cache.entries.len

proc clear*(cache: var LinkCapabilityCache) =
  ## Forget every cached answer and reset the probe counter.
  cache.entries.clear()
  cache.probes = 0

# ---------------------------------------------------------------------------
# Process-wide cache
# ---------------------------------------------------------------------------

var
  globalCacheLock: Lock
  globalCache {.guard: globalCacheLock.}: LinkCapabilityCache

globalCacheLock.initLock()

proc linkCapabilities*(srcDir, dstDir: string): LinkCapability =
  ## ``probeLinkCapabilities`` against the process-wide cache. This is
  ## the entry point production callers use; the explicit-cache overload
  ## exists so tests can observe the probe count in isolation.
  withLock globalCacheLock:
    {.gcsafe.}:
      result = probeLinkCapabilities(globalCache, srcDir, dstDir)

proc globalProbeCount*(): int =
  withLock globalCacheLock:
    {.gcsafe.}:
      result = globalCache.probeCount()

proc resetGlobalLinkCapabilityCache*() =
  ## Drop the process-wide memo. Intended for tests and for a caller
  ## that knows a mount changed under it.
  withLock globalCacheLock:
    {.gcsafe.}:
      globalCache.clear()

# ---------------------------------------------------------------------------
# The decision the model dictates
# ---------------------------------------------------------------------------

proc preferredMechanisms*(cap: LinkCapability;
                          allowSharedInode = true): seq[LinkMechanism] =
  ## The mechanisms to try, best first, per the normative preference
  ## order: reflink, then hardlink, then copy.
  ##
  ## The order is a SAFETY order before it is a performance one. A
  ## reflink breaks sharing on write, so it behaves like a copy for
  ## every observer while costing like a link; a hardlink does not, and
  ## that is why it sorts second even though it is the cheapest.
  ##
  ## ``allowSharedInode = false`` drops the hardlink arm entirely, and it
  ## is expressed here so a caller states its mutation expectation once
  ## rather than re-deriving the policy at each call site.
  ##
  ## Both of the store's own callers pass ``false`` by default and
  ## Local-CAS-Hardlink-Materialization **M3** settled that they keep
  ## doing so: a destination that is written IN PLACE — which is what
  ## ``O_WRONLY|O_CREAT|O_TRUNC`` does, and what every compiler's ``-o``
  ## therefore does — edits the CAS blob through the shared inode, and no
  ## guard rail available to the store removes that. See
  ## ``Local-Content-Addressed-Store.md`` §"The shared-inode arm: a weaker
  ## guarantee, and the conditions for using it".
  ##
  ## ``lmCopy`` is always last and always present: copy is the arm that
  ## cannot be unavailable, which is what lets the spec promise that
  ## correctness never depends on which mechanism was used.
  result = @[]
  if cap.reflink:
    result.add lmReflink
  if cap.hardlink and allowSharedInode:
    result.add lmHardlink
  result.add lmCopy

proc `$`*(m: LinkMechanism): string =
  case m
  of lmReflink: "reflink"
  of lmHardlink: "hardlink"
  of lmCopy: "copy"

proc describe*(cap: LinkCapability): string =
  ## One-line diagnostic suitable for a log or a receipt hint.
  var parts: seq[string] = @[]
  parts.add("pair=" & cap.key)
  parts.add("probed=" & $cap.probed)
  parts.add("reflink=" & $cap.reflink & "(" & $cap.reflinkAttempt.outcome & ")")
  parts.add("hardlink=" & $cap.hardlink & "(" &
            $cap.hardlinkAttempt.outcome & ")")
  parts.join(" ")
