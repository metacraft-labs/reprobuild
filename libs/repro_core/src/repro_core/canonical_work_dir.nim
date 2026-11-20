## Canonical work trees: a per-run work tree at a path that names neither the
## checkout nor the user.
##
## Governed by reprobuild-pm
## `spec/Hermetic-Builds-And-Path-Independence.md` §"Canonical work trees",
## which states the root for each OS, its trust boundary, the per-user
## fallback, the per-key lock and cleanup. This module is that mechanism; the
## engine calls it for an action that declares `canonicalWorkKey`.
##
## Layout, under the system root (`C:\repro-exec`, `/var/tmp/repro-exec`) or
## the per-user fallback (`<user cache>/repro-exec`):
##
## ```
## <root>/            shared and sticky (POSIX 1777; Windows: create-subdir only)
## <root>/<key>/      owner-only, verified before every use
## <root>/<key>/lock  the per-key lock, inside the verified directory
## <root>/<key>/work  what the action sees; emptied before every run
## ```
##
## A directory that fails its check is REFUSED and left exactly as it is
## (Tool-Owned-Caches.md §"Trust Boundary": a repaired directory would still
## hold what was put there before the repair). A refused system root or key
## directory falls back to the per-user location; a refused per-user location
## refuses the action.

import std/[os, strutils]

import ./file_lock
import ./tree_removal
import ./paths

when defined(posix):
  import std/posix

const
  CanonicalWorkDirEnv* = "REPRO_CANONICAL_WORK_DIR"
    ## The variable that hands an action its work tree.
  ExecRootOverrideEnv* = "REPRO_EXEC_ROOT"
    ## Overrides the system root. Held to the same checks.
  KeepCanonicalWorkEnv* = "REPRO_KEEP_CANONICAL_WORK"
    ## `1` keeps a successful run's work tree for inspection.
  ExecRootDirName* = "repro-exec"
  MaxCanonicalWorkKeyLen* = 80

type
  CanonicalWorkPlacement* = enum
    cwpSystemRoot   ## under the system-wide root
    cwpUserFallback ## under the per-user cache directory

  CanonicalWorkLease* = object
    ## A held work tree. Release it with `releaseCanonicalWork`.
    key*: string
    keyDir*: string
    workDir*: string
    placement*: CanonicalWorkPlacement
    fallbackReason*: string
      ## Why the system root was not used; "" when it was.
    lock: ReproFileLock

  CanonicalWorkStatus* = enum
    cwsAcquired ## `lease` is held
    cwsBusy     ## another process holds the key; retry later
    cwsRefused  ## neither location may be used; `reason` says why

  CanonicalWorkOutcome* = object
    status*: CanonicalWorkStatus
    lease*: CanonicalWorkLease
    reason*: string
      ## Busy: the lock that is held. Refused: both refusals.
    busyPath*: string

proc isValidCanonicalWorkKey*(key: string): bool =
  ## A key is one path component the engine can place under a shared root:
  ## ASCII letters, digits, `-` and `_`, not starting with `-`.
  if key.len == 0 or key.len > MaxCanonicalWorkKeyLen or key[0] == '-':
    return false
  for ch in key:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_'}:
      return false
  true

proc defaultSystemExecRoot*(): string =
  ## The system root of this OS, ignoring the override.
  when defined(windows):
    var drive = getEnv("SystemDrive")
    if drive.len == 0:
      drive = "C:"
    drive & "\\" & ExecRootDirName
  else:
    "/var/tmp/" & ExecRootDirName

proc systemExecRoot*(): string =
  ## `REPRO_EXEC_ROOT` when set, else the OS default.
  let override = getEnv(ExecRootOverrideEnv)
  if override.len > 0: override else: defaultSystemExecRoot()

proc userFallbackExecRoot*(): string =
  ## `<user cache directory>/repro-exec`, or "" when the cache directory
  ## cannot be resolved.
  let cache = getCacheDir()
  if cache.len == 0:
    return ""
  absolutePath(cache) / ExecRootDirName

# ---------------------------------------------------------------------------
# POSIX checks
# ---------------------------------------------------------------------------

when defined(posix):
  const StickyBit = 0o1000

  proc modeText(mode: int): string = "0" & toOct(mode, 4)

  proc describeStat(st: Stat): string =
    "owned by uid " & $int(st.st_uid) & ", mode " &
      modeText(int(st.st_mode) and 0o7777)

  proc sharedDirProblem(path: string; st: Stat; what: string): string =
    ## A directory other accounts may create entries in is safe only when it
    ## is owned by root or this user and, if group or others can write it,
    ## carries the sticky bit.
    let mode = int(st.st_mode) and 0o7777
    let owner = int(st.st_uid)
    if owner != 0 and owner != int(geteuid()):
      return what & " " & path & " is " & describeStat(st) &
        ": its owner is neither root nor this user (uid " & $int(geteuid()) &
        "), and the owner of a shared directory can rename any entry in it"
    if (mode and 0o022) != 0 and (mode and StickyBit) == 0:
      return what & " " & path & " is " & describeStat(st) &
        ": group or others can write it and it is not sticky, so another " &
        "account could rename or replace an entry in it"
    ""

  proc verifyExecRootPosix(root: string): string =
    var st: Stat
    if lstat(root.cstring, st) != 0:
      return "cannot inspect the canonical work root " & root & ": " &
        osErrorMsg(osLastError())
    if S_ISLNK(st.st_mode) or not S_ISDIR(st.st_mode):
      return "the canonical work root " & root & " is not a real directory " &
        "(a symbolic link or another file is in its place; " &
        describeStat(st) & ")"
    result = sharedDirProblem(root, st, "the canonical work root")
    if result.len > 0:
      return
    # Every ancestor of the root's resolved path: an ancestor another
    # account can rename entries of could swap the root itself.
    var parent = ""
    try:
      parent = expandFilename(parentDir(root))
    except OSError as err:
      return "cannot resolve the parent of the canonical work root " & root &
        ": " & err.msg
    var cur = parent
    while cur.len > 0:
      var ast: Stat
      if stat(cur.cstring, ast) != 0:
        return "cannot inspect " & cur & ", an ancestor of the canonical " &
          "work root: " & osErrorMsg(osLastError())
      let problem = sharedDirProblem(cur, ast,
        "an ancestor of the canonical work root,")
      if problem.len > 0:
        return problem
      if cur == "/":
        break
      let up = parentDir(cur)
      cur = if up.len == 0 or up == cur: "/" else: up
    result = ""

  proc verifyKeyDirPosix(dir: string): string =
    var st: Stat
    if lstat(dir.cstring, st) != 0:
      return "cannot inspect the canonical work directory " & dir & ": " &
        osErrorMsg(osLastError())
    if S_ISLNK(st.st_mode) or not S_ISDIR(st.st_mode):
      return "the canonical work directory " & dir & " is not a real " &
        "directory (" & describeStat(st) & ")"
    if int(st.st_uid) != int(geteuid()):
      return "the canonical work directory " & dir & " is " &
        describeStat(st) & ": it belongs to another account, not this user " &
        "(uid " & $int(geteuid()) & ")"
    if (int(st.st_mode) and 0o077) != 0:
      return "the canonical work directory " & dir & " is " &
        describeStat(st) & ": it must grant no group or other permission " &
        "(0700)"
    ""

  proc createDirMode(path: string; mode: int): string =
    ## Creates `path` with exactly `mode` when it is missing. "" when it
    ## exists or was created; an existing directory is never changed.
    if mkdir(path.cstring, Mode(mode)) == 0:
      if chmod(path.cstring, Mode(mode)) != 0:
        return "cannot set the mode of " & path & ": " &
          osErrorMsg(osLastError())
      return ""
    let err = errno
    if err == EEXIST:
      return ""
    "cannot create " & path & ": " & osErrorMsg(OSErrorCode(err))

# ---------------------------------------------------------------------------
# Windows checks
# ---------------------------------------------------------------------------

when defined(windows):
  import std/winlean

  type
    CwSecurityAttributes = object
      nLength: DWORD
      lpSecurityDescriptor: pointer
      bInheritHandle: WINBOOL

    CwAclHeader = object
      aclRevision: uint8
      sbz1: uint8
      aclSize: uint16
      aceCount: uint16
      sbz2: uint16

    CwAceHeader = object
      aceType: uint8
      aceFlags: uint8
      aceSize: uint16

  const
    SeFileObject = 1'i32
    OwnerSecurityInformation = 0x1'u32
    DaclSecurityInformation = 0x4'u32
    SddlRevision1 = 1'u32
    TokenQuery = 0x8'u32
    TokenUserClass = 1'i32
    FileAttributeDirectory = 0x10'u32
    FileAttributeReparsePoint = 0x400'u32
    InvalidFileAttributes = 0xFFFFFFFF'u32
    ErrorAlreadyExists = 183'i32
    InheritOnlyAce = 0x08'u8
    AccessAllowedAceType = 0'u8
    AccessAllowedCallbackAceType = 9'u8
    AccessAllowedObjectAceType = 5'u8
    AccessAllowedCallbackObjectAceType = 11'u8

    SidSystem = "S-1-5-18"
    SidAdministrators = "S-1-5-32-544"
    SidCreatorOwner = "S-1-3-0"
    SidOwnerRights = "S-1-3-4"
    SidTrustedInstaller =
      "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"

    # What another account may hold on the root itself: list, add a
    # subdirectory, read extended attributes, traverse, read attributes,
    # read the security descriptor, synchronize -- and the generic read and
    # execute rights that map onto those.
    RootOthersAllowedMask = 0x1200AD'u32 or 0x80000000'u32 or 0x20000000'u32
    # What another account must not hold on the root's parent: delete a
    # child (which renames the root), or change the parent's DACL or owner
    # (which grants it that).
    ParentOthersForbiddenMask = 0x40'u32 or 0x40000'u32 or 0x80000'u32 or
      0x10000000'u32

    RootSddl = "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICIIO;FA;;;CO)" &
      "(A;;0x1200ad;;;AU)"

  proc cwGetFileAttributesW(path: WideCString): uint32 {.
    stdcall, dynlib: "kernel32", importc: "GetFileAttributesW".}
  proc cwCreateDirectoryW(path: WideCString;
                          sa: ptr CwSecurityAttributes): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "CreateDirectoryW".}
  proc cwGetLastError(): int32 {.
    stdcall, dynlib: "kernel32", importc: "GetLastError".}
  proc cwLocalFree(p: pointer): pointer {.
    stdcall, dynlib: "kernel32", importc: "LocalFree".}
  proc cwGetCurrentProcess(): Handle {.
    stdcall, dynlib: "kernel32", importc: "GetCurrentProcess".}
  proc cwCloseHandle(h: Handle): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "CloseHandle".}
  proc cwOpenProcessToken(process: Handle; access: uint32;
                          token: ptr Handle): WINBOOL {.
    stdcall, dynlib: "advapi32", importc: "OpenProcessToken".}
  proc cwGetTokenInformation(token: Handle; infoClass: int32; info: pointer;
                             length: uint32; returned: ptr uint32): WINBOOL {.
    stdcall, dynlib: "advapi32", importc: "GetTokenInformation".}
  proc cwConvertSidToStringSidW(sid: pointer; str: ptr pointer): WINBOOL {.
    stdcall, dynlib: "advapi32", importc: "ConvertSidToStringSidW".}
  proc cwConvertStringSdToSd(sddl: WideCString; revision: uint32;
                             sd: ptr pointer; size: ptr uint32): WINBOOL {.
    stdcall, dynlib: "advapi32",
    importc: "ConvertStringSecurityDescriptorToSecurityDescriptorW".}
  proc cwGetNamedSecurityInfoW(name: WideCString; objectType: int32;
                               info: uint32; owner, group, dacl, sacl: ptr pointer;
                               sd: ptr pointer): uint32 {.
    stdcall, dynlib: "advapi32", importc: "GetNamedSecurityInfoW".}
  proc cwGetAce(acl: pointer; index: uint32; ace: ptr pointer): WINBOOL {.
    stdcall, dynlib: "advapi32", importc: "GetAce".}

  proc sidText(sid: pointer): string =
    if sid == nil:
      return ""
    var str: pointer = nil
    if cwConvertSidToStringSidW(sid, addr str) == 0 or str == nil:
      return ""
    result = $cast[WideCString](str)
    discard cwLocalFree(str)

  proc currentUserSid*(): string =
    ## The string SID of the account this process runs as, or "".
    var token: Handle
    if cwOpenProcessToken(cwGetCurrentProcess(), TokenQuery, addr token) == 0:
      return ""
    defer: discard cwCloseHandle(token)
    var needed = 0'u32
    discard cwGetTokenInformation(token, TokenUserClass, nil, 0, addr needed)
    if needed == 0:
      return ""
    var buf = newSeq[byte](int(needed))
    if cwGetTokenInformation(token, TokenUserClass, addr buf[0], needed,
        addr needed) == 0:
      return ""
    # TOKEN_USER starts with SID_AND_ATTRIBUTES, whose first field is the
    # SID pointer.
    sidText(cast[ptr pointer](addr buf[0])[])

  type AceView = object
    sid: string
    mask: uint32
    flags: uint8
    parsed: bool   ## false: an allow ACE whose SID this code does not read

  type SecurityView = object
    ok: bool
    error: string
    owner: string
    nullDacl: bool
    aces: seq[AceView]

  proc readSecurity(path: string): SecurityView =
    var owner, dacl, sd: pointer
    let rc = cwGetNamedSecurityInfoW(newWideCString(path), SeFileObject,
      OwnerSecurityInformation or DaclSecurityInformation, addr owner, nil,
      addr dacl, nil, addr sd)
    if rc != 0:
      result.error = "cannot read the security descriptor of " & path &
        ": " & osErrorMsg(OSErrorCode(rc))
      return
    defer: discard cwLocalFree(sd)
    result.ok = true
    result.owner = sidText(owner)
    if dacl == nil:
      result.nullDacl = true
      return
    let header = cast[ptr CwAclHeader](dacl)
    for i in 0'u32 ..< uint32(header.aceCount):
      var ace: pointer
      if cwGetAce(dacl, i, addr ace) == 0 or ace == nil:
        continue
      let ah = cast[ptr CwAceHeader](ace)
      case ah.aceType
      of AccessAllowedAceType, AccessAllowedCallbackAceType:
        let mask = cast[ptr uint32](cast[uint](ace) + 4)[]
        let sid = cast[pointer](cast[uint](ace) + 8)
        result.aces.add(AceView(sid: sidText(sid), mask: mask,
          flags: ah.aceFlags, parsed: true))
      of AccessAllowedObjectAceType, AccessAllowedCallbackObjectAceType:
        let mask = cast[ptr uint32](cast[uint](ace) + 4)[]
        result.aces.add(AceView(mask: mask, flags: ah.aceFlags, parsed: false))
      else:
        discard   # deny and audit ACEs only take access away

  proc describeAce(ace: AceView): string =
    (if ace.parsed: ace.sid else: "<object ACE>") & " (mask 0x" &
      toHex(ace.mask, 8).toLowerAscii & ", flags 0x" &
      toHex(int(ace.flags), 2).toLowerAscii & ")"

  proc trustedSid(sid, me: string): bool =
    sid == me or sid == SidSystem or sid == SidAdministrators

  proc reparseProblem(path, what: string): string =
    let attrs = cwGetFileAttributesW(newWideCString(path))
    if attrs == InvalidFileAttributes:
      return "cannot inspect " & what & " " & path & ": " &
        osErrorMsg(osLastError())
    if (attrs and FileAttributeReparsePoint) != 0:
      return what & " " & path & " is a reparse point (a symbolic link or " &
        "junction), not a real directory"
    if (attrs and FileAttributeDirectory) == 0:
      return what & " " & path & " is not a directory"
    ""

  proc verifyExecRootWindows(root: string): string =
    let me = currentUserSid()
    if me.len == 0:
      return "cannot determine this account's SID"
    result = reparseProblem(root, "the canonical work root")
    if result.len > 0:
      return
    let sec = readSecurity(root)
    if not sec.ok:
      return sec.error
    if not (trustedSid(sec.owner, me) or sec.owner == SidTrustedInstaller):
      return "the canonical work root " & root & " is owned by " & sec.owner &
        ", which is neither this user (" & me & "), SYSTEM nor " &
        "Administrators; the owner of the root can grant itself the right " &
        "to rename any directory in it"
    if sec.nullDacl:
      return "the canonical work root " & root & " (owner " & sec.owner &
        ") has a null DACL: every account has full control of it"
    for ace in sec.aces:
      if (ace.flags and InheritOnlyAce) != 0:
        continue
      if ace.parsed and (trustedSid(ace.sid, me) or ace.sid == SidCreatorOwner):
        continue
      if (ace.mask and not RootOthersAllowedMask) != 0 or not ace.parsed:
        return "the canonical work root " & root & " (owner " & sec.owner &
          ") grants " & describeAce(ace) & " more than listing it and " &
          "creating subdirectories, so another account could rename, " &
          "remove or replace a directory in it"
    let parent = parentDir(root)
    if parent.len > 0 and parent != root:
      let psec = readSecurity(parent)
      if not psec.ok:
        return psec.error
      if not (trustedSid(psec.owner, me) or psec.owner == SidTrustedInstaller):
        return "the parent " & parent & " of the canonical work root is " &
          "owned by " & psec.owner & ", which could rename the root"
      if psec.nullDacl:
        return "the parent " & parent & " of the canonical work root has a " &
          "null DACL"
      for ace in psec.aces:
        if (ace.flags and InheritOnlyAce) != 0:
          continue
        if ace.parsed and (trustedSid(ace.sid, me) or
            ace.sid == SidCreatorOwner or ace.sid == SidTrustedInstaller):
          continue
        if (ace.mask and ParentOthersForbiddenMask) != 0:
          return "the parent " & parent & " of the canonical work root " &
            "grants " & describeAce(ace) & " the right to delete a child " &
            "or change its DACL or owner, so another account could rename " &
            "the root"
    result = ""

  proc verifyKeyDirWindows(dir: string): string =
    let me = currentUserSid()
    if me.len == 0:
      return "cannot determine this account's SID"
    result = reparseProblem(dir, "the canonical work directory")
    if result.len > 0:
      return
    let sec = readSecurity(dir)
    if not sec.ok:
      return sec.error
    if sec.owner != me:
      return "the canonical work directory " & dir & " is owned by " &
        sec.owner & ": it belongs to another account, not this user (" & me &
        ")"
    if sec.nullDacl:
      return "the canonical work directory " & dir & " has a null DACL: " &
        "every account has full control of it"
    for ace in sec.aces:
      # Inheritable ACEs count too: they would reach the work tree.
      if ace.parsed and (trustedSid(ace.sid, me) or ace.sid == SidOwnerRights or
          ace.sid == SidCreatorOwner):
        continue
      return "the canonical work directory " & dir & " (owner " & sec.owner &
        ") grants " & describeAce(ace) & "; it must grant nothing to any " &
        "account other than this user, SYSTEM and Administrators"
    result = ""

  proc createDirSddl(path, sddl: string): string =
    var sd: pointer
    if cwConvertStringSdToSd(newWideCString(sddl), SddlRevision1, addr sd,
        nil) == 0:
      return "cannot build the security descriptor for " & path & ": " &
        osErrorMsg(osLastError())
    defer: discard cwLocalFree(sd)
    var sa = CwSecurityAttributes(nLength: DWORD(sizeof(CwSecurityAttributes)),
      lpSecurityDescriptor: sd, bInheritHandle: 0)
    if cwCreateDirectoryW(newWideCString(path), addr sa) != 0:
      return ""
    let err = cwGetLastError()
    if err == ErrorAlreadyExists:
      return ""
    "cannot create " & path & ": " & osErrorMsg(OSErrorCode(err))

# ---------------------------------------------------------------------------
# Admission
# ---------------------------------------------------------------------------

proc verifyExecRoot*(root: string): string =
  ## "" when `root` may hold canonical work trees: a real directory, owned by
  ## a privileged account or this user, on which no other account can rename
  ## or replace an entry. Otherwise why not. Never changes anything.
  when defined(posix):
    verifyExecRootPosix(root)
  elif defined(windows):
    verifyExecRootWindows(root)
  else:
    "canonical work roots are not supported on this OS"

proc verifyCanonicalKeyDir*(dir: string): string =
  ## "" when `dir` is a real directory owned by this user that grants no
  ## other account anything. Otherwise why not. Never changes anything.
  when defined(posix):
    verifyKeyDirPosix(dir)
  elif defined(windows):
    verifyKeyDirWindows(dir)
  else:
    "canonical work roots are not supported on this OS"

proc ensureExecRoot*(root: string): string =
  ## Creates the system root when it is missing, shared and sticky (POSIX
  ## 1777; Windows: SYSTEM and Administrators full control, CREATOR OWNER
  ## full control inherited only, Authenticated Users list and create
  ## subdirectories on the root itself), then verifies it whoever created
  ## it. "" when admitted.
  if not isAbsolute(root):
    return "the canonical work root " & root & " is not an absolute path"
  when defined(posix):
    let created = createDirMode(root, 0o1777)
    if created.len > 0:
      return created
  elif defined(windows):
    let created = createDirSddl(root, RootSddl)
    if created.len > 0:
      return created
  verifyExecRoot(root)

proc ensureCanonicalKeyDir*(dir: string): string =
  ## Creates `dir` owner-only when it is missing, then verifies it.
  when defined(posix):
    let created = createDirMode(dir, 0o700)
    if created.len > 0:
      return created
  elif defined(windows):
    let me = currentUserSid()
    if me.len == 0:
      return "cannot determine this account's SID"
    let created = createDirSddl(dir, "O:" & me & "D:P(A;OICI;FA;;;SY)" &
      "(A;OICI;FA;;;BA)(A;OICI;FA;;;" & me & ")")
    if created.len > 0:
      return created
  verifyCanonicalKeyDir(dir)

proc ensureUserFallbackRoot*(root: string): string =
  ## The per-user root: private to this user (Tool-Owned-Caches.md
  ## §"Trust Boundary"). On POSIX it must be owned by this user with mode
  ## 0700; on Windows it lives in the profile, whose ACL admits only this
  ## user, and is checked only for being a real directory.
  if root.len == 0:
    return "the user cache directory cannot be resolved"
  try:
    createDir(extendedPath(parentDir(root)))
  except OSError as err:
    return "cannot create " & parentDir(root) & ": " & err.msg
  when defined(posix):
    let created = createDirMode(root, 0o700)
    if created.len > 0:
      return created
    verifyKeyDirPosix(root)
  elif defined(windows):
    try:
      createDir(extendedPath(root))
    except OSError as err:
      return "cannot create " & root & ": " & err.msg
    reparseProblem(root, "the per-user canonical work root")
  else:
    "canonical work roots are not supported on this OS"

proc tryLockKeyDir(keyDir: string; lease: var CanonicalWorkLease): bool =
  var lock: ReproFileLock
  if not tryAcquireExclusiveFileLock(keyDir / "lock", lock):
    return false
  lease.lock = lock
  true

proc tryAcquireCanonicalWork*(key: string;
                              systemRoot = systemExecRoot();
                              userRoot = userFallbackExecRoot()):
    CanonicalWorkOutcome =
  ## Places the work tree for `key` and takes its lock, without blocking.
  ##
  ## The system root is tried first; a refused root or key directory falls
  ## back to `userRoot`, and `lease.fallbackReason` says why. A held lock is
  ## `cwsBusy` (the caller defers and retries), never a fallback: a second
  ## build of the same key waits for the first rather than producing other
  ## bytes. The work tree is not emptied here (`emptyCanonicalWorkTree`).
  if not isValidCanonicalWorkKey(key):
    return CanonicalWorkOutcome(status: cwsRefused,
      reason: "invalid canonical work key '" & key & "'")
  var systemReason = ensureExecRoot(systemRoot)
  if systemReason.len == 0:
    let keyDir = systemRoot / key
    systemReason = ensureCanonicalKeyDir(keyDir)
    if systemReason.len == 0:
      var lease = CanonicalWorkLease(key: key, keyDir: keyDir,
        workDir: keyDir / "work", placement: cwpSystemRoot)
      try:
        if not tryLockKeyDir(keyDir, lease):
          return CanonicalWorkOutcome(status: cwsBusy, busyPath: keyDir,
            reason: "another build holds " & keyDir / "lock")
        return CanonicalWorkOutcome(status: cwsAcquired, lease: lease)
      except CatchableError as err:
        systemReason = "cannot lock " & keyDir / "lock" & ": " & err.msg
  var userReason = ensureUserFallbackRoot(userRoot)
  if userReason.len == 0:
    let keyDir = userRoot / key
    userReason = ensureCanonicalKeyDir(keyDir)
    if userReason.len == 0:
      var lease = CanonicalWorkLease(key: key, keyDir: keyDir,
        workDir: keyDir / "work", placement: cwpUserFallback,
        fallbackReason: systemReason)
      try:
        if not tryLockKeyDir(keyDir, lease):
          return CanonicalWorkOutcome(status: cwsBusy, busyPath: keyDir,
            reason: "another build holds " & keyDir / "lock")
        return CanonicalWorkOutcome(status: cwsAcquired, lease: lease)
      except CatchableError as err:
        userReason = "cannot lock " & keyDir / "lock" & ": " & err.msg
  CanonicalWorkOutcome(status: cwsRefused,
    reason: "no canonical work tree for '" & key & "': " & systemReason &
      "; and the per-user fallback was refused: " & userReason)

proc emptyCanonicalWorkTree*(lease: CanonicalWorkLease): string =
  ## Empties the lease's work tree (creating it when missing), without
  ## following links. "" on success.
  try:
    # The extended spelling, as the engine's scratch reset uses: an npm
    # tree nests far past MAX_PATH, and a plain path stops the removal at
    # the first file too deep to name.
    let tree = extendedPath(lease.workDir)
    if dirExists(tree) or symlinkExists(tree):
      removePathNoFollow(tree)
    createDir(tree)
  except CatchableError as err:
    return "cannot empty the canonical work tree " & lease.workDir & ": " &
      err.msg
  ""

proc isHeld*(lease: CanonicalWorkLease): bool = lease.lock.isHeld

proc releaseCanonicalWork*(lease: var CanonicalWorkLease;
                           removeTree: bool): string =
  ## Removes the work tree when `removeTree` (a successful run, unless
  ## `REPRO_KEEP_CANONICAL_WORK=1`) and releases the lock. The key directory
  ## and its lock file stay: removing them while another build waits on the
  ## lock would let two builds each lock a different file. Returns why the
  ## tree could not be removed, or "".
  if not lease.lock.isHeld:
    return ""
  if removeTree and getEnv(KeepCanonicalWorkEnv) != "1":
    try:
      let tree = extendedPath(lease.workDir)
      if dirExists(tree) or symlinkExists(tree):
        removePathNoFollow(tree)
    except CatchableError as err:
      result = "cannot remove the canonical work tree " & lease.workDir &
        ": " & err.msg
  releaseExclusiveFileLock(lease.lock)

proc actionVisiblePath*(path: string): string =
  ## The spelling handed to the action: forward slashes on Windows, which
  ## both MSYS shells and native tools accept.
  when defined(windows):
    path.replace('\\', '/')
  else:
    path
