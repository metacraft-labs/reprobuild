## Owner-only credential files on Windows: the counterpart of the POSIX
## `open(O_CREAT|O_EXCL, 0600)` that `identity.nim` and `pki.nim` use for a
## private-key file (deployment-security-architecture.md CRED-3: a private
## scalar is readable by its owner only, never by another local user).
##
## WHAT 0600 MEANS HERE, AND HOW WINDOWS SAYS IT. On POSIX the key file is
## CREATED with mode 0600, so no other user ever holds a descriptor on it,
## not even for the instant between creation and a later `chmod`. A Windows
## file has no mode; who may open it is its DACL, and a new file INHERITS
## its DACL from the directory (under a user profile that is typically the
## user, SYSTEM and Administrators; under `C:\` or a shared temp directory
## it can include `Users` or `Everyone`). So the equivalent is:
##
## * the file is created with an explicit security descriptor whose DACL is
##   PROTECTED (`SE_DACL_PROTECTED`: nothing is inherited from the
##   directory, now or when the directory's ACL changes later) and holds
##   exactly ONE entry, full access for the user the process runs as (the
##   token's user SID). That is rw for the owner and nothing for anyone
##   else, i.e. 0600. (The directory's owner and an administrator can still
##   take ownership and rewrite the DACL, as root can `chmod` on POSIX; that
##   is the account boundary, not the file's.)
## * the descriptor is applied by `CreateFileW` itself, with `CREATE_NEW`
##   and `FILE_FLAG_OPEN_REPARSE_POINT` (fails if anything is at the path,
##   a symbolic link included: `O_EXCL`), after removing any previous file,
##   exactly as the POSIX path does. There is no window in which the file
##   exists with the inherited DACL, which is precisely the defect the old
##   Windows branch had (`writeFile` then `setFilePermissions`, and the
##   latter only toggles the read-only attribute on Windows, it never
##   touches the DACL).
## * `CREATE_NEW` ALONE IS NOT `O_EXCL`. Measured on Windows 11 (NTFS):
##   `CreateFileW(CREATE_NEW)` on a DANGLING symbolic link follows it and
##   creates the link's target, where POSIX `open(O_CREAT|O_EXCL)` fails
##   with `EEXIST` and never follows a link. So a link planted at the path
##   between the removal and the create (the same window the POSIX path
##   has) would have put the key wherever the link pointed, and left the
##   link for every later read to follow. `FILE_FLAG_OPEN_REPARSE_POINT`
##   makes the create see the link itself, so it fails as `O_EXCL` does
##   (independent verification of campaign M17 chunk 2,
##   `t_host_identity_key_file_is_owner_only`).
##
## Reading mirrors the POSIX reader: the bytes go into a caller-owned fixed
## buffer, never a heap string. The POSIX reader makes no mode check at read
## time, so neither does this one; `ownerOnlyAclViolation` exists so a test
## can verify what the writer produced through an independent API
## (`GetNamedSecurityInfoW`).

when defined(windows):
  import std/[os, winlean]

  type
    OwnerOnlyFileError* = object of CatchableError

    SidAndAttributes = object
      sid: pointer
      attributes: uint32

    TokenUser = object
      user: SidAndAttributes

    AclHeader = object
      aclRevision: uint8
      sbz1: uint8
      aclSize: uint16
      aceCount: uint16
      sbz2: uint16

    AceHeader = object
      aceType: uint8
      aceFlags: uint8
      aceSize: uint16

    AccessAllowedAce = object
      header: AceHeader
      mask: uint32
      sidStart: uint32

    SecurityDescriptorBuf = array[64, byte]
      ## SECURITY_DESCRIPTOR_MIN_LENGTH is 40 on x64 (20 on x86); 64 is
      ## enough on both and keeps pointer alignment.

  const
    TOKEN_QUERY = 0x0008'u32
    TokenUserInfoClass = 1'i32
    ACL_REVISION = 2'u32
    ACCESS_ALLOWED_ACE_TYPE = 0'u8
    INHERITED_ACE = 0x10'u8
    FILE_ALL_ACCESS = 0x001F01FF'u32
    SECURITY_DESCRIPTOR_REVISION = 1'u32
    SE_DACL_PROTECTED = 0x1000'u16
    SE_FILE_OBJECT = 1'i32
    DACL_SECURITY_INFORMATION = 0x00000004'u32
    FILE_ATTRIBUTE_NORMAL_W = 0x80'i32
    FILE_FLAG_OPEN_REPARSE_POINT_W = 0x00200000'i32
    ERROR_SUCCESS_W = 0'i32

  proc openProcessToken(process: Handle; access: uint32;
                        token: var Handle): WINBOOL {.
    stdcall, dynlib: "advapi32", importc: "OpenProcessToken".}
  proc getTokenInformation(token: Handle; infoClass: int32; info: pointer;
                           infoLen: uint32; returnLen: var uint32): WINBOOL {.
    stdcall, dynlib: "advapi32", importc: "GetTokenInformation".}
  proc getLengthSid(sid: pointer): uint32 {.
    stdcall, dynlib: "advapi32", importc: "GetLengthSid".}
  proc equalSid(a, b: pointer): WINBOOL {.
    stdcall, dynlib: "advapi32", importc: "EqualSid".}
  proc initializeAcl(acl: pointer; aclLen: uint32; revision: uint32): WINBOOL {.
    stdcall, dynlib: "advapi32", importc: "InitializeAcl".}
  proc addAccessAllowedAce(acl: pointer; revision: uint32; mask: uint32;
                           sid: pointer): WINBOOL {.
    stdcall, dynlib: "advapi32", importc: "AddAccessAllowedAce".}
  proc initializeSecurityDescriptor(sd: pointer; revision: uint32): WINBOOL {.
    stdcall, dynlib: "advapi32", importc: "InitializeSecurityDescriptor".}
  proc setSecurityDescriptorDacl(sd: pointer; present: WINBOOL; dacl: pointer;
                                 defaulted: WINBOOL): WINBOOL {.
    stdcall, dynlib: "advapi32", importc: "SetSecurityDescriptorDacl".}
  proc setSecurityDescriptorControl(sd: pointer; mask: uint16;
                                    bits: uint16): WINBOOL {.
    stdcall, dynlib: "advapi32", importc: "SetSecurityDescriptorControl".}
  proc getSecurityDescriptorControl(sd: pointer; control: var uint16;
                                    revision: var uint32): WINBOOL {.
    stdcall, dynlib: "advapi32", importc: "GetSecurityDescriptorControl".}
  proc getNamedSecurityInfoW(name: WideCString; objectType: int32;
                             info: uint32; owner, group: pointer;
                             dacl: ptr pointer; sacl: pointer;
                             sd: ptr pointer): int32 {.
    stdcall, dynlib: "advapi32", importc: "GetNamedSecurityInfoW".}
  proc getAce(acl: pointer; index: uint32; ace: var pointer): WINBOOL {.
    stdcall, dynlib: "advapi32", importc: "GetAce".}

  proc currentUserSid(): seq[byte] =
    ## The token user's SID, copied out (`TOKEN_USER` points into its own
    ## buffer).
    var token: Handle
    if openProcessToken(getCurrentProcess(), TOKEN_QUERY, token) == 0:
      raise newException(OwnerOnlyFileError,
        "cannot open the process token: " & osErrorMsg(osLastError()))
    defer: discard closeHandle(token)
    var needed = 0'u32
    discard getTokenInformation(token, TokenUserInfoClass, nil, 0, needed)
    if needed == 0:
      raise newException(OwnerOnlyFileError,
        "cannot size the token user: " & osErrorMsg(osLastError()))
    var info = newSeq[byte](int(needed))
    if getTokenInformation(token, TokenUserInfoClass, addr info[0], needed,
        needed) == 0:
      raise newException(OwnerOnlyFileError,
        "cannot read the token user: " & osErrorMsg(osLastError()))
    let sid = cast[ptr TokenUser](addr info[0]).user.sid
    let sidLen = int(getLengthSid(sid))
    result = newSeq[byte](sidLen)
    copyMem(addr result[0], sid, sidLen)

  proc createNewOwnerOnlyFile*(path: string; data: openArray[char]) =
    ## Creates `path` holding `data`, readable and writable by the current
    ## user only (a protected one-entry DACL, applied at creation; see the
    ## module doc). Fails if ANYTHING is at `path`, a dangling symbolic link
    ## included (`CREATE_NEW` with `FILE_FLAG_OPEN_REPARSE_POINT`: the
    ## `O_CREAT|O_EXCL` of the POSIX writers). Raises `OwnerOnlyFileError`.
    var sid = currentUserSid()
    # ACL header + one ACCESS_ALLOWED_ACE whose trailing SidStart DWORD is
    # replaced by the SID: sizeof(ACL) + sizeof(ACE) - sizeof(DWORD) + |SID|,
    # rounded up to a DWORD.
    let aclLen = (sizeof(AclHeader) + sizeof(AccessAllowedAce) - 4 +
      sid.len + 3) and not 3
    var acl = newSeq[byte](aclLen)
    var sd: SecurityDescriptorBuf
    if initializeAcl(addr acl[0], uint32(aclLen), ACL_REVISION) == 0 or
        addAccessAllowedAce(addr acl[0], ACL_REVISION, FILE_ALL_ACCESS,
          addr sid[0]) == 0 or
        initializeSecurityDescriptor(addr sd[0],
          SECURITY_DESCRIPTOR_REVISION) == 0 or
        setSecurityDescriptorDacl(addr sd[0], 1, addr acl[0], 0) == 0 or
        setSecurityDescriptorControl(addr sd[0], SE_DACL_PROTECTED,
          SE_DACL_PROTECTED) == 0:
      raise newException(OwnerOnlyFileError,
        "cannot build an owner-only security descriptor for " & path & ": " &
        osErrorMsg(osLastError()))
    var sa = SECURITY_ATTRIBUTES(nLength: int32(sizeof(SECURITY_ATTRIBUTES)),
      lpSecurityDescriptor: addr sd[0], bInheritHandle: 0)
    let h = createFileW(newWideCString(path), GENERIC_WRITE, 0, addr sa,
      CREATE_NEW, FILE_ATTRIBUTE_NORMAL_W or FILE_FLAG_OPEN_REPARSE_POINT_W,
      Handle(0))
    if h == INVALID_HANDLE_VALUE:
      raise newException(OwnerOnlyFileError,
        "cannot create " & path & ": " & osErrorMsg(osLastError()))
    try:
      var off = 0
      while off < data.len:
        var written = 0'i32
        if writeFile(h, unsafeAddr data[off], int32(data.len - off),
            addr written, nil) == 0 or written <= 0:
          raise newException(OwnerOnlyFileError,
            "cannot write " & path & ": " & osErrorMsg(osLastError()))
        off += int(written)
    finally:
      discard closeHandle(h)

  proc createOwnerOnlyFile*(path: string; data: openArray[char]) =
    ## `createNewOwnerOnlyFile` after removing a previous file or link at
    ## `path`, as the POSIX writers do; the create fails if anything
    ## reappears there in between. Raises `OwnerOnlyFileError`.
    if fileExists(path) or symlinkExists(path):
      removeFile(path)
    createNewOwnerOnlyFile(path, data)

  proc readOwnerFileInto*(path: string; buf: var openArray[char]): int =
    ## Reads at most `buf.len` bytes of `path` into `buf` (a caller-owned
    ## fixed buffer, so a secret never lands in a heap string) and returns
    ## how many were read. Raises `OwnerOnlyFileError`.
    let h = createFileW(newWideCString(path), GENERIC_READ, FILE_SHARE_READ,
      nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL_W, Handle(0))
    if h == INVALID_HANDLE_VALUE:
      raise newException(OwnerOnlyFileError,
        "cannot open " & path & ": " & osErrorMsg(osLastError()))
    try:
      while result < buf.len:
        var got = 0'i32
        if readFile(h, addr buf[result], int32(buf.len - result), addr got,
            nil) == 0:
          raise newException(OwnerOnlyFileError,
            "cannot read " & path & ": " & osErrorMsg(osLastError()))
        if got == 0:
          break
        result += int(got)
    finally:
      discard closeHandle(h)

  proc ownerOnlyAclViolation*(path: string): string =
    ## "" when `path`'s DACL is what `createOwnerOnlyFile` writes: protected
    ## from inheritance, and exactly one non-inherited ACCESS_ALLOWED entry,
    ## for the current user. Otherwise what differs. Read through
    ## `GetNamedSecurityInfoW`, independently of the writer.
    var dacl: pointer = nil
    var sd: pointer = nil
    let rc = getNamedSecurityInfoW(newWideCString(path), SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION, nil, nil, addr dacl, nil, addr sd)
    if rc != ERROR_SUCCESS_W:
      return "cannot read the DACL of " & path & " (error " & $rc & ")"
    defer: localFree(sd)
    if dacl.isNil:
      return "the file has a NULL DACL (everyone has full access)"
    var control = 0'u16
    var revision = 0'u32
    if getSecurityDescriptorControl(sd, control, revision) == 0:
      return "cannot read the security descriptor control"
    if (control and SE_DACL_PROTECTED) == 0:
      return "the DACL is not protected from inheritance"
    let header = cast[ptr AclHeader](dacl)
    if header.aceCount != 1:
      return "the DACL has " & $header.aceCount & " entries, not 1"
    var ace: pointer = nil
    if getAce(dacl, 0, ace) == 0:
      return "cannot read the DACL entry"
    let allowed = cast[ptr AccessAllowedAce](ace)
    if allowed.header.aceType != ACCESS_ALLOWED_ACE_TYPE:
      return "the entry is not an access-allowed entry (type " &
        $allowed.header.aceType & ")"
    if (allowed.header.aceFlags and INHERITED_ACE) != 0:
      return "the entry is inherited"
    var sid = currentUserSid()
    if equalSid(addr allowed.sidStart, addr sid[0]) == 0:
      return "the entry is not for the current user"
    ""
