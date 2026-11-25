## Writing a system file on Windows as an administrator without ever
## following a reparse point, and only into directories no ordinary user
## controls.
##
## The Windows half of ``nofollow_write`` (see its header for why a
## path-based open is unsafe for a privileged write). ``${PROGRAMDATA}``
## lets every local user create folders, so a junction or a symbolic link
## planted under it redirects an elevated ``open(path, fmWrite)`` to any
## file on the machine. Checking the path's text first does not help: the
## check and the open resolve the path twice.
##
## So nothing here opens a path as a whole:
##
## * The drive root is opened by name; every component below it is opened
##   with ``NtCreateFile`` *relative to the handle of the directory before
##   it* (``OBJECT_ATTRIBUTES.RootDirectory``) and with
##   ``FILE_OPEN_REPARSE_POINT``, so a junction, a mount point or a
##   symbolic link is opened as itself and then refused
##   (``SymlinkOnPath``) because its attributes carry
##   ``FILE_ATTRIBUTE_REPARSE_POINT``. Nothing is resolved by name twice.
## * Each directory opened on the way is judged by its security
##   descriptor (``untrustedReason``): its owner must be SYSTEM,
##   Administrators, TrustedInstaller or the writing user, and no other
##   principal may hold an allow ACE that lets it take the directory over
##   or remove what is in it (``WRITE_DAC``, ``WRITE_OWNER``, ``DELETE``,
##   ``FILE_DELETE_CHILD``, ``GENERIC_ALL``). The right to *create* a file
##   or folder, which ``${PROGRAMDATA}`` grants to Users, is allowed: a
##   folder a user creates is owned by that user and refused, and a file a
##   user plants as the leaf is replaced, never written through.
## * The new content is written to a temporary file created in the parent
##   directory's handle, flushed, and renamed over the leaf with
##   ``FileRenameInformation`` (``ReplaceIfExists``) relative to the same
##   handle. A rename replaces a reparse point or a hard link at the
##   destination rather than writing through it.
##
## References: NtCreateFile
## <https://learn.microsoft.com/windows-hardware/drivers/ddi/ntifs/nf-ntifs-ntcreatefile>,
## FILE_RENAME_INFORMATION
## <https://learn.microsoft.com/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information>,
## GetSecurityInfo
## <https://learn.microsoft.com/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo>,
## well-known SIDs
## <https://learn.microsoft.com/windows-server/identity/ad-ds/manage/understand-security-identifiers>.

import std/[os, strutils]

import ./nofollow_write
export NoFollowError, SymlinkOnPath

type
  UntrustedDirectory* = object of NoFollowError
    ## A directory on the path can be modified by a principal other than
    ## an administrator or the writer. ``dir`` is that directory.
    dir*: string

const
  # The SIDs of the principals that own the system: LocalSystem,
  # BUILTIN\Administrators and NT SERVICE\TrustedInstaller.
  AdminSids* = ["S-1-5-18", "S-1-5-32-544",
    "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"]
  # Rights that let a holder replace or redirect what is in a directory.
  RightDelete = 0x0001_0000'u32
  RightWriteDac = 0x0004_0000'u32
  RightWriteOwner = 0x0008_0000'u32
  RightDeleteChild = 0x0000_0040'u32
  RightGenericAll = 0x1000_0000'u32
  TakeOverRights* = RightDelete or RightWriteDac or RightWriteOwner or
    RightDeleteChild or RightGenericAll
  # Rights that let a holder change a file's bytes.
  ContentWriteRights* = TakeOverRights or 0x0000_0002'u32 or # FILE_WRITE_DATA
    0x0000_0004'u32 or                                     # FILE_APPEND_DATA
    0x4000_0000'u32                                        # GENERIC_WRITE
  AceInheritOnly* = 0x08'u8

type AceView* = object
  ## One ACE of a DACL, reduced to what the trust rules read.
  allow*: bool        ## an allow ACE whose layout is read (see ``aceViewKind``)
  unknown*: bool      ## an ACE type this module cannot read: fails closed
  aceType*: uint8
  inheritOnly*: bool  ## applies to children only, not to this object
  sid*: string        ## the trustee, as a string SID
  mask*: uint32

proc aceViewKind*(aceType: uint8): tuple[allow, unknown: bool] =
  ## How the trust rules treat an ACE type
  ## (<https://learn.microsoft.com/windows/win32/secauthz/ace-header>).
  ## ACCESS_ALLOWED (0) and ACCESS_ALLOWED_CALLBACK (9) share the
  ## header-mask-SID layout and are read. The deny types (1, 6, 10, 12)
  ## grant nothing. Everything else (the object allow types 5 and 11, whose
  ## SID sits after optional GUIDs, and any type a later Windows adds) is
  ## unknown, and an unknown ACE makes the object untrusted rather than
  ## being skipped.
  case aceType
  of 0, 9: (true, false)
  of 1, 6, 10, 12: (false, false)
  else: (false, true)

proc foreignGrant(aces: openArray[AceView]; rights: uint32;
                  writerSid: string): string =
  ## Why an ACE lets a principal other than an administrator or
  ## ``writerSid`` use one of ``rights`` on the object itself; "" when none
  ## does.
  for a in aces:
    if a.inheritOnly:
      continue
    if a.unknown:
      return "its DACL holds an ACE of type " & $a.aceType &
        " that this check cannot read"
    if not a.allow or a.sid in AdminSids or a.sid == writerSid:
      continue
    if (a.mask and rights) != 0:
      return "its DACL grants " & a.sid & " access mask 0x" &
        toHex(a.mask and rights, 8)
  ""

proc untrustedReason*(ownerSid: string; hasDacl: bool; aces: openArray[AceView];
                      writerSid: string): string =
  ## "" when a directory owned by ``ownerSid`` with this DACL can be taken
  ## over or emptied only by an administrator or ``writerSid``; otherwise
  ## why not. A missing (NULL) DACL grants everyone everything. Pure, so
  ## the rule is tested on every platform.
  if ownerSid notin AdminSids and ownerSid != writerSid:
    return "it is owned by " & ownerSid
  if not hasDacl:
    return "it has no DACL, which grants everyone full control"
  foreignGrant(aces, TakeOverRights, writerSid)

proc keepsDacl*(ownerSid: string; links: int; hasDacl: bool;
                aces: openArray[AceView]; writerSid: string): bool =
  ## Whether the replacement of an existing file takes over its DACL. Only
  ## a restriction an administrator made is worth keeping, so the file
  ## must be owned by an administrator or the writer, have no other hard
  ## link (a user who can create files in the folder can hard-link an
  ## administrator's file there, and with it that file's DACL), and grant
  ## no one else a right to change its bytes. Otherwise the new file gets
  ## the DACL its folder hands down. Pure, so the rule is tested on every
  ## platform.
  (ownerSid in AdminSids or ownerSid == writerSid) and links == 1 and
    hasDacl and foreignGrant(aces, ContentWriteRights, writerSid) == ""

when defined(windows):
  import std/winlean

  type
    UnicodeString {.pure.} = object
      length: uint16
      maximumLength: uint16
      buffer: WideCString
    ObjectAttributes {.pure.} = object
      length: uint32
      rootDirectory: Handle
      objectName: ptr UnicodeString
      attributes: uint32
      securityDescriptor: pointer
      securityQualityOfService: pointer
    IoStatusBlock {.pure.} = object
      status: uint
      information: uint
    ByHandleInfo {.pure.} = object
      fileAttributes: uint32
      creationTime, lastAccessTime, lastWriteTime: array[2, uint32]
      volumeSerialNumber: uint32
      fileSizeHigh, fileSizeLow: uint32
      numberOfLinks: uint32
      fileIndexHigh, fileIndexLow: uint32
    AclHeader {.pure.} = object
      aclRevision, sbz1: uint8
      aclSize, aceCount, sbz2: uint16
    AceHeader {.pure.} = object
      aceType, aceFlags: uint8
      aceSize: uint16
    AccessAce {.pure.} = object
      header: AceHeader
      mask: uint32
      sidStart: uint32

  const
    FileOpen = 1'u32
    FileCreate = 2'u32
    FileOpenIf = 3'u32
    FileDirectoryFile = 0x0000_0001'u32
    FileSynchronousIoNonAlert = 0x0000_0020'u32
    FileNonDirectoryFile = 0x0000_0040'u32
    FileOpenForBackupIntent = 0x0000_4000'u32
    FileOpenReparsePoint = 0x0020_0000'u32
    ObjCaseInsensitive = 0x40'u32
    Synchronize = 0x0010_0000'u32
    ReadControl = 0x0002_0000'u32
    FileListDirectory = 0x0001'u32
    FileTraverse = 0x0020'u32
    FileReadAttributes = 0x0080'u32
    FileAttributeNormal = 0x80'u32
    FileAttributeDirectory = 0x10'u32
    FileAttributeReparsePoint = 0x400'u32
    FileShareAll = 0x7'u32
    GenericWrite = 0x4000_0000'u32
    FileRenameInformationClass = 10'u32
    FileDispositionInformationClass = 13'u32
    StatusObjectNameNotFound = 0xC000_0034'u32
    StatusObjectPathNotFound = 0xC000_003A'u32
    SeFileObject = 1'u32
    OwnerSecurityInformation = 0x1'u32
    DaclSecurityInformation = 0x4'u32
    ProtectedDaclSecurityInformation = 0x8000_0000'u32
    UnprotectedDaclSecurityInformation = 0x2000_0000'u32
    SeDaclProtected = 0x1000'u16
    TokenUserClass = 1'u32
    TokenQuery = 0x0008'u32

  proc ntCreateFile(h: var Handle; access: uint32; oa: var ObjectAttributes;
                    iosb: var IoStatusBlock; allocationSize: pointer;
                    fileAttributes, shareAccess, disposition,
                    options: uint32; eaBuffer: pointer;
                    eaLength: uint32): int32
    {.stdcall, dynlib: "ntdll", importc: "NtCreateFile".}
  proc ntSetInformationFile(h: Handle; iosb: var IoStatusBlock; info: pointer;
                            length: uint32; class: uint32): int32
    {.stdcall, dynlib: "ntdll", importc: "NtSetInformationFile".}
  proc rtlNtStatusToDosError(status: int32): uint32
    {.stdcall, dynlib: "ntdll", importc: "RtlNtStatusToDosError".}
  proc getFileInformationByHandle(h: Handle; info: var ByHandleInfo): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "GetFileInformationByHandle".}
  proc flushFileBuffers(h: Handle): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "FlushFileBuffers".}
  proc getSecurityInfo(h: Handle; objectType, securityInfo: uint32;
                       owner, group: ptr pointer; dacl, sacl: ptr pointer;
                       sd: ptr pointer): uint32
    {.stdcall, dynlib: "advapi32", importc: "GetSecurityInfo".}
  proc setSecurityInfo(h: Handle; objectType, securityInfo: uint32;
                       owner, group, dacl, sacl: pointer): uint32
    {.stdcall, dynlib: "advapi32", importc: "SetSecurityInfo".}
  proc getSecurityDescriptorControl(sd: pointer; control: var uint16;
                                    revision: var uint32): WINBOOL
    {.stdcall, dynlib: "advapi32", importc: "GetSecurityDescriptorControl".}
  proc convertSidToStringSidW(sid: pointer; str: var WideCString): WINBOOL
    {.stdcall, dynlib: "advapi32", importc: "ConvertSidToStringSidW".}
  proc localFree(p: pointer): pointer
    {.stdcall, dynlib: "kernel32", importc: "LocalFree".}
  proc openProcessToken(process: Handle; access: uint32;
                        token: var Handle): WINBOOL
    {.stdcall, dynlib: "advapi32", importc: "OpenProcessToken".}
  proc getTokenInformation(token: Handle; class: uint32; info: pointer;
                           length: uint32; returned: var uint32): WINBOOL
    {.stdcall, dynlib: "advapi32", importc: "GetTokenInformation".}

  proc raiseNt(status: int32; what: string) {.noreturn.} =
    raiseOSError(OSErrorCode(int32(rtlNtStatusToDosError(status))), what)

  proc sidString(sid: pointer): string =
    if sid == nil:
      return ""
    var ws: WideCString
    if convertSidToStringSidW(sid, ws) == 0:
      raiseOSError(osLastError(), "ConvertSidToStringSidW")
    result = $ws
    discard localFree(cast[pointer](ws))

  proc writerSid*(): string =
    ## The user SID of this process's token: a directory it owns is no
    ## less trusted than the writer itself.
    var token: Handle
    if openProcessToken(getCurrentProcess(), TokenQuery, token) == 0:
      raiseOSError(osLastError(), "OpenProcessToken")
    defer: discard closeHandle(token)
    var need: uint32
    discard getTokenInformation(token, TokenUserClass, nil, 0, need)
    var buf = newSeq[byte](max(int(need), 64))
    if getTokenInformation(token, TokenUserClass, addr buf[0],
                           uint32(buf.len), need) == 0:
      raiseOSError(osLastError(), "GetTokenInformation(TokenUser)")
    # TOKEN_USER starts with SID_AND_ATTRIBUTES, whose first field is the
    # SID pointer.
    sidString(cast[ptr pointer](addr buf[0])[])

  proc readAces(dacl: pointer): seq[AceView] =
    ## The ACEs of ``dacl`` (nil: none), as ``AceView``s.
    if dacl == nil:
      return
    let header = cast[ptr AclHeader](dacl)
    var p = cast[uint](dacl) + uint(sizeof(AclHeader))
    for _ in 0 ..< int(header.aceCount):
      let ace = cast[ptr AceHeader](p)
      let (allow, unknown) = aceViewKind(ace.aceType)
      var view = AceView(allow: allow, unknown: unknown, aceType: ace.aceType,
                         inheritOnly: (ace.aceFlags and AceInheritOnly) != 0)
      if allow:
        let a = cast[ptr AccessAce](p)
        view.mask = a.mask
        view.sid = sidString(addr a.sidStart)
      result.add(view)
      p += uint(ace.aceSize)

  proc judgeDirectory(h: Handle; shown, writer: string) =
    ## Raise ``UntrustedDirectory`` unless ``untrustedReason`` clears the
    ## directory behind ``h``.
    var owner, dacl, sd: pointer
    let rc = getSecurityInfo(h, SeFileObject,
      OwnerSecurityInformation or DaclSecurityInformation,
      addr owner, nil, addr dacl, nil, addr sd)
    if rc != 0:
      raiseOSError(OSErrorCode(int32(rc)), "GetSecurityInfo " & shown)
    defer: discard localFree(sd)
    let why = untrustedReason(sidString(owner), dacl != nil, readAces(dacl),
                              writer)
    if why.len > 0:
      var e = newException(UntrustedDirectory, "refusing to write under " &
        shown & ": " & why & "; a principal other than an administrator " &
        "could replace what is written there")
      e.dir = shown
      raise e

  proc raiseLink(shown: string) {.noreturn.} =
    var e = newException(SymlinkOnPath,
      "refusing to write through a reparse point (junction or symbolic " &
      "link): " & shown)
    e.link = shown
    raise e

  proc isReparsePoint(h: Handle; isDir: var bool; links: var int): bool =
    var info: ByHandleInfo
    if getFileInformationByHandle(h, info) == 0:
      raiseOSError(osLastError(), "GetFileInformationByHandle")
    isDir = (info.fileAttributes and FileAttributeDirectory) != 0
    links = int(info.numberOfLinks)
    (info.fileAttributes and FileAttributeReparsePoint) != 0

  proc isReparsePoint(h: Handle; isDir: var bool): bool =
    var links: int
    isReparsePoint(h, isDir, links)

  proc openRelative(parent: Handle; name: string; access, disposition,
                    options: uint32; status: var int32): Handle =
    ## ``NtCreateFile`` of the single component ``name`` relative to
    ## ``parent``, opening a reparse point as itself. Returns the handle,
    ## or ``INVALID_HANDLE_VALUE`` with ``status`` set.
    # `wname` owns the UTF-16 buffer the call reads; it lives to the end
    # of this proc. Its `len` is the count of UTF-16 code units.
    var wname = newWideCString(name)
    let units = len(WideCString(wname))
    var us = UnicodeString(length: uint16(units * 2),
      maximumLength: uint16(units * 2), buffer: WideCString(wname))
    var oa = ObjectAttributes(length: uint32(sizeof(ObjectAttributes)),
      rootDirectory: parent, objectName: addr us,
      attributes: ObjCaseInsensitive)
    var iosb: IoStatusBlock
    var h: Handle
    status = ntCreateFile(h, access or Synchronize, oa, iosb, nil,
      FileAttributeNormal, FileShareAll, disposition,
      options or FileOpenReparsePoint or FileSynchronousIoNonAlert, nil, 0)
    if status < 0: INVALID_HANDLE_VALUE else: h

  proc splitDrivePath(path: string): tuple[root: string; parts: seq[string]] =
    ## ``C:\ProgramData\x`` -> (``C:\``, [ProgramData, x]). Only a
    ## drive-letter absolute path is accepted: a UNC or device path names
    ## a share or an object-manager link the walk cannot vouch for.
    let p = path.replace('/', '\\')
    if p.len < 3 or not p[0].isAlphaAscii or p[1] != ':' or p[2] != '\\':
      raise newException(NoFollowError,
        "not a drive-letter absolute path: " & path)
    result.root = p[0 .. 2]
    for seg in p[3 .. ^1].split('\\'):
      if seg.len == 0 or seg == ".":
        continue
      if seg == "..":
        raise newException(NoFollowError, "path contains '..': " & path)
      result.parts.add(seg)
    if result.parts.len == 0:
      raise newException(NoFollowError, "a drive root is not a file: " & path)

  const DirAccess = FileListDirectory or FileTraverse or FileReadAttributes or
    ReadControl

  proc walkDirs(parts: openArray[string]; root: string;
                create: bool; judge = true): Handle =
    ## The handle of the directory ``root`` + ``parts``, every component
    ## opened relative to the one before it, refusing a reparse point and,
    ## when ``judge``, an untrusted directory (each judged before anything
    ## is created in it). Missing components are created when ``create``.
    ## The caller closes the result.
    let writer = if judge: writerSid() else: ""
    var wroot = newWideCString(root)
    var cur = createFileW(WideCString(wroot), cast[int32](DirAccess),
      cast[int32](FileShareAll), nil, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT, 0)
    if cur == INVALID_HANDLE_VALUE:
      raiseOSError(osLastError(), "open " & root)
    var shown = root
    try:
      var isDir: bool
      if isReparsePoint(cur, isDir):
        raiseLink(root)
      if judge: judgeDirectory(cur, shown, writer)
      for seg in parts:
        shown = shown / seg
        var status: int32
        var next = openRelative(cur, seg, DirAccess,
          if create: FileOpenIf else: FileOpen,
          FileDirectoryFile or FileOpenForBackupIntent, status)
        if next == INVALID_HANDLE_VALUE:
          raiseNt(status, "open directory " & shown)
        if isReparsePoint(next, isDir):
          discard closeHandle(next)
          raiseLink(shown)
        discard closeHandle(cur)
        cur = next
        if judge: judgeDirectory(cur, shown, writer)
    except CatchableError:
      discard closeHandle(cur)
      raise
    cur

  proc createDirsNoFollowWin*(path: string) =
    ## ``mkdir -p`` that never follows a reparse point and never creates
    ## inside an untrusted directory.
    let (root, parts) = splitDrivePath(path)
    discard closeHandle(walkDirs(parts, root, create = true))

  proc renameRelative(h, dir: Handle; leaf: string) =
    ## Rename the file behind ``h`` to ``leaf`` inside ``dir``, replacing
    ## whatever is there (FILE_RENAME_INFORMATION, ``ReplaceIfExists``).
    var wname = newWideCString(leaf)
    let units = len(WideCString(wname))
    # struct { BOOLEAN ReplaceIfExists; HANDLE RootDirectory;
    #          ULONG FileNameLength; WCHAR FileName[]; }
    let nameOff = 2 * sizeof(pointer) + 4
    var buf = newSeq[byte](nameOff + units * 2 + 2)
    buf[0] = 1
    cast[ptr Handle](addr buf[sizeof(pointer)])[] = dir
    cast[ptr uint32](addr buf[2 * sizeof(pointer)])[] = uint32(units * 2)
    if units > 0:
      copyMem(addr buf[nameOff], cast[pointer](WideCString(wname)), units * 2)
    var iosb: IoStatusBlock
    let st = ntSetInformationFile(h, iosb, addr buf[0], uint32(buf.len),
                                  FileRenameInformationClass)
    if st < 0:
      raiseNt(st, "rename onto " & leaf)

  proc deleteByHandle(h: Handle; what: string) =
    var disposition: uint8 = 1
    var iosb: IoStatusBlock
    let st = ntSetInformationFile(h, iosb, addr disposition, 1,
                                  FileDispositionInformationClass)
    if st < 0:
      raiseNt(st, "delete " & what)

  proc writeFileNoFollowWin*(path, content: string) =
    ## Write ``content`` to ``path`` atomically, never through a reparse
    ## point and only under trusted directories (see the module header).
    ## The parent must exist. An existing regular file's DACL is carried
    ## over only when ``keepsDacl`` allows it (an operator's restriction
    ## survives an update); any other replacement gets the DACL its folder
    ## hands down. Raises ``SymlinkOnPath``,
    ## ``UntrustedDirectory`` or ``OSError``; a failure leaves no
    ## temporary file behind.
    let (root, parts) = splitDrivePath(path)
    let leaf = parts[^1]
    let dir = walkDirs(parts[0 ..< parts.high], root, create = false)
    defer: discard closeHandle(dir)
    # The leaf: a reparse point or a directory is refused before any write.
    var status: int32
    var keptDacl: pointer
    var keptSd: pointer
    var keptControl: uint16
    defer:
      if keptSd != nil: discard localFree(keptSd)
    let old = openRelative(dir, leaf, FileReadAttributes or ReadControl,
                           FileOpen, FileOpenForBackupIntent, status)
    if old != INVALID_HANDLE_VALUE:
      try:
        var isDir: bool
        var links: int
        if isReparsePoint(old, isDir, links):
          raiseLink(path)
        if isDir:
          raise newException(NoFollowError, path & " is a directory")
        var owner: pointer
        let rc = getSecurityInfo(old, SeFileObject,
          OwnerSecurityInformation or DaclSecurityInformation,
          addr owner, nil, addr keptDacl, nil, addr keptSd)
        if rc != 0:
          raiseOSError(OSErrorCode(int32(rc)), "GetSecurityInfo " & path)
        if keepsDacl(sidString(owner), links, keptDacl != nil,
                     readAces(keptDacl), writerSid()):
          var rev: uint32
          discard getSecurityDescriptorControl(keptSd, keptControl, rev)
        else:
          keptDacl = nil
      finally:
        discard closeHandle(old)
    elif uint32(status) != StatusObjectNameNotFound and
        uint32(status) != StatusObjectPathNotFound:
      raiseNt(status, "open " & path)
    let tmp = "." & leaf & ".repro-tmp-" & $getCurrentProcessId()
    # A leftover of a crashed run under our temporary name goes first; it
    # is opened as itself, so a reparse point there is deleted, not
    # followed.
    let stale = openRelative(dir, tmp, RightDelete, FileOpen,
                             FileOpenForBackupIntent, status)
    if stale != INVALID_HANDLE_VALUE:
      try: deleteByHandle(stale, tmp)
      finally: discard closeHandle(stale)
    let f = openRelative(dir, tmp, GenericWrite or RightDelete or
                         ReadControl or RightWriteDac, FileCreate,
                         FileNonDirectoryFile, status)
    if f == INVALID_HANDLE_VALUE:
      raiseNt(status, "create " & tmp & " beside " & path)
    var committed = false
    try:
      var off = 0
      while off < content.len:
        var n: int32
        if writeFile(f, unsafeAddr content[off], int32(content.len - off),
                     addr n, nil) == 0:
          raiseOSError(osLastError(), "write " & path)
        off += int(n)
      if flushFileBuffers(f) == 0:
        raiseOSError(osLastError(), "flush " & path)
      if keptDacl != nil:
        let protection =
          if (keptControl and SeDaclProtected) != 0:
            ProtectedDaclSecurityInformation
          else: UnprotectedDaclSecurityInformation
        let rc = setSecurityInfo(f, SeFileObject,
          DaclSecurityInformation or protection, nil, nil, keptDacl, nil)
        if rc != 0:
          raiseOSError(OSErrorCode(int32(rc)), "SetSecurityInfo " & path)
      renameRelative(f, dir, leaf)
      committed = true
    finally:
      if not committed:
        try: deleteByHandle(f, tmp)
        except CatchableError: discard
      discard closeHandle(f)

  proc removeLeafNoFollowWin*(path: string): bool =
    ## Remove the file, or the reparse point itself (a symbolic link or a
    ## junction, never what it points at), at ``path`` without following
    ## anything on the way; false when there was nothing, its folder
    ## included. A real directory leaf is refused. Removing needs no trust
    ## in the directories: nothing is left behind for anyone to take over.
    let (root, parts) = splitDrivePath(path)
    var dir: Handle
    try:
      dir = walkDirs(parts[0 ..< parts.high], root, create = false,
                     judge = false)
    except OSError as e:
      # ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND: a folder on the way is
      # gone, so the file is too.
      if e.errorCode in [2'i32, 3'i32]:
        return false
      raise
    defer: discard closeHandle(dir)
    var status: int32
    let h = openRelative(dir, parts[^1], RightDelete or FileReadAttributes,
                         FileOpen, FileOpenForBackupIntent, status)
    if h == INVALID_HANDLE_VALUE:
      if uint32(status) == StatusObjectNameNotFound or
          uint32(status) == StatusObjectPathNotFound:
        return false
      raiseNt(status, "open " & path)
    defer: discard closeHandle(h)
    var isDir: bool
    if not isReparsePoint(h, isDir) and isDir:
      raise newException(NoFollowError, path & " is a directory")
    # Opened with FILE_OPEN_REPARSE_POINT, so a junction or link is the
    # object deleted here, never its target.
    deleteByHandle(h, path)
    true
