## Secure protocol shared by the generated pre-push hook and the lock
## publisher.  The client hook is advisory (a user can always use
## ``git push --no-verify``), but an ordinary environment variable must never
## be enough to disable it.

import std/[json, os, osproc, strutils, times]
import nimcrypto/sysrand
import blake3
import git_tool

when defined(posix):
  import std/posix
  when defined(macosx):
    const ReproOpenNoFollow = 0x00000100.cint
  elif defined(linux):
    const ReproOpenNoFollow = 0x00020000.cint
  else:
    const ReproOpenNoFollow = 0.cint

  {.emit: """
  #include <sys/types.h>
  #include <sys/stat.h>
  #include <sys/time.h>
  #include <fcntl.h>
  #include <unistd.h>
  #include <errno.h>
  #include <signal.h>
  #include <string.h>
  #include <stdio.h>
  #if defined(__linux__)
  #include <sys/syscall.h>
  #endif

  static int rb_secure_component_at(int parent, const char *name, int create) {
    int made = 0;
    if (create && mkdirat(parent, name, 0700) != 0) {
      if (errno != EEXIST) return -1;
    } else if (create) {
      made = 1;
    }
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != geteuid() ||
        (made && fchmod(fd, 0700) != 0) || fstat(fd, &st) != 0 ||
        (st.st_mode & 0777) != 0700) {
      close(fd); return -1;
    }
    return fd;
  }

  static int rb_open_cap_dir(const char *common, int create) {
    int common_fd = open(common, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (common_fd < 0) return -1;
    int repro_fd = rb_secure_component_at(common_fd, "reprobuild", create);
    close(common_fd);
    if (repro_fd < 0) return -1;
    int cap_fd = rb_secure_component_at(repro_fd, "hook-capabilities", create);
    close(repro_fd);
    return cap_fd;
  }

  static int rb_write_cap_at(int dirfd, const char *name,
      const char *content, size_t length) {
    int fd = openat(dirfd, name,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return 0;
    int ok = fchmod(fd, 0600) == 0;
    size_t off = 0;
    while (ok && off < length) {
      ssize_t n = write(fd, content + off, length - off);
      if (n <= 0) ok = 0; else off += (size_t)n;
    }
    if (ok && fsync(fd) != 0) ok = 0;
    close(fd);
    if (!ok) unlinkat(dirfd, name, 0);
    if (ok) fsync(dirfd);
    return ok;
  }

  static int rb_claim_cap_at(int dirfd, const char *source, const char *dest) {
  #if defined(__linux__)
    return syscall(SYS_renameat2, dirfd, source, dirfd, dest, 1) == 0;
  #elif defined(__APPLE__)
    return renameatx_np(dirfd, source, dirfd, dest, 0x00000004) == 0;
  #elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    return renameatx_np(dirfd, source, dirfd, dest, 0x00000004) == 0;
  #else
    return 0;
  #endif
  }

  static int rb_open_cap_at(int dirfd, const char *name) {
    return openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  }

  static int rb_unlink_cap_at(int dirfd, const char *name) {
    return unlinkat(dirfd, name, 0) == 0 || errno == ENOENT;
  }

  static long long rb_cap_mtime_at(int dirfd, const char *name) {
    struct stat st;
    if (fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISREG(st.st_mode) || st.st_uid != geteuid() || st.st_nlink != 1 ||
        (st.st_mode & 0777) != 0600) return -1;
    return (long long)st.st_mtime;
  }

  static int rb_pending_cleanup_fd = -1;
  static char rb_pending_cleanup_name[80];
  static int rb_pending_cleanup_armed = 0;
  static struct sigaction rb_old_hup, rb_old_int, rb_old_term;
  static void rb_pending_signal(int sig) {
    if (rb_pending_cleanup_fd >= 0 && rb_pending_cleanup_name[0] != '\0')
      unlinkat(rb_pending_cleanup_fd, rb_pending_cleanup_name, 0);
    _exit(128 + sig);
  }
  static void rb_disarm_pending_cleanup(void) {
    if (rb_pending_cleanup_armed) {
      sigaction(SIGHUP, &rb_old_hup, NULL);
      sigaction(SIGINT, &rb_old_int, NULL);
      sigaction(SIGTERM, &rb_old_term, NULL);
      rb_pending_cleanup_armed = 0;
    }
    if (rb_pending_cleanup_fd >= 0) close(rb_pending_cleanup_fd);
    rb_pending_cleanup_fd = -1;
    rb_pending_cleanup_name[0] = '\0';
  }
  static int rb_arm_pending_cleanup(int dirfd, const char *name) {
    rb_disarm_pending_cleanup();
    if (strlen(name) >= sizeof(rb_pending_cleanup_name)) return 0;
    rb_pending_cleanup_fd = dup(dirfd);
    if (rb_pending_cleanup_fd < 0) return 0;
    fcntl(rb_pending_cleanup_fd, F_SETFD, FD_CLOEXEC);
    strcpy(rb_pending_cleanup_name, name);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = rb_pending_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESETHAND;
    if (sigaction(SIGHUP, &sa, &rb_old_hup) != 0 ||
        sigaction(SIGINT, &sa, &rb_old_int) != 0 ||
        sigaction(SIGTERM, &sa, &rb_old_term) != 0) {
      rb_disarm_pending_cleanup(); return 0;
    }
    rb_pending_cleanup_armed = 1;
    return 1;
  }
  """.}

  proc rbOpenCapDir(common: cstring; create: cint): cint
    {.importc: "rb_open_cap_dir", nodecl.}
  proc rbWriteCapAt(dirfd: cint; name, content: cstring; length: csize_t): cint
    {.importc: "rb_write_cap_at", nodecl.}
  proc rbClaimCapAt(dirfd: cint; source, dest: cstring): cint
    {.importc: "rb_claim_cap_at", nodecl.}
  proc rbOpenCapAt(dirfd: cint; name: cstring): cint
    {.importc: "rb_open_cap_at", nodecl.}
  proc rbUnlinkCapAt(dirfd: cint; name: cstring): cint
    {.importc: "rb_unlink_cap_at", nodecl.}
  proc rbCapMtimeAt(dirfd: cint; name: cstring): int64
    {.importc: "rb_cap_mtime_at", nodecl.}
  proc rbArmPendingCleanup(dirfd: cint; name: cstring): cint
    {.importc: "rb_arm_pending_cleanup", nodecl.}
  proc rbDisarmPendingCleanup()
    {.importc: "rb_disarm_pending_cleanup", nodecl.}
when defined(windows):
  import std/winlean

  type
    WinHandle = pointer
    WinDword = uint32
    WinBool = int32
    WinSecurityAttributes = object
      length: WinDword
      securityDescriptor: pointer
      inheritHandle: WinBool
    WinFileTime = object
      lowDateTime: WinDword
      highDateTime: WinDword
    WinFileInformation = object
      attributes: WinDword
      creationTime: WinFileTime
      lastAccessTime: WinFileTime
      lastWriteTime: WinFileTime
      volumeSerialNumber: WinDword
      fileSizeHigh: WinDword
      fileSizeLow: WinDword
      numberOfLinks: WinDword
      fileIndexHigh: WinDword
      fileIndexLow: WinDword
    WinAcl = object
      revision: uint8
      reserved1: uint8
      size: uint16
      aceCount: uint16
      reserved2: uint16
    WinAclSizeInformation = object
      aceCount: WinDword
      bytesInUse: WinDword
      bytesFree: WinDword
    WinAceHeader = object
      aceType: uint8
      aceFlags: uint8
      aceSize: uint16
    WinAccessAllowedAce = object
      header: WinAceHeader
      mask: WinDword
      sidStart: WinDword
    WinStreamData = object
      streamSize: int64
      streamName: array[296, uint16]

  const
    WinGenericRead = 0x80000000'u32
    WinGenericWrite = 0x40000000'u32
    WinReadControl = 0x00020000'u32
    WinFileShareRead = 0x00000001'u32
    WinFileShareDelete = 0x00000004'u32
    WinCreateNew = 1'u32
    WinOpenExisting = 3'u32
    WinFileAttributeDirectory = 0x00000010'u32
    WinFileAttributeNormal = 0x00000080'u32
    WinFileAttributeReparsePoint = 0x00000400'u32
    WinFileFlagWriteThrough = 0x80000000'u32
    WinFileFlagOpenReparsePoint = 0x00200000'u32
    WinFileFlagBackupSemantics = 0x02000000'u32
    WinMoveFileWriteThrough = 0x00000008'u32
    WinOwnerSecurityInformation = 0x00000001'u32
    WinDaclSecurityInformation = 0x00000004'u32
    WinSeFileObject = 1'u32
    WinSeDaclProtected = 0x1000'u16
    WinAclSizeInformationClass = 2'u32
    WinAccessAllowedAceType = 0'u8
    WinObjectInheritAce = 0x01'u8
    WinContainerInheritAce = 0x02'u8
    WinInheritedAce = 0x10'u8
    WinFileAllAccess = 0x001F01FF'u32
    WinSddlRevision = 1'u32
    WinTokenUser = 1'u32
    WinTokenQuery = 0x0008'u32
    WinErrorAlreadyExists = 183'u32
    WinErrorHandleEof = 38'u32
    WinFindStreamStandard = 0'u32

  proc winInvalidHandle(): WinHandle = cast[WinHandle](-1)

  proc winCreateFile(path: WideCString; desiredAccess, shareMode: WinDword;
      security: ptr WinSecurityAttributes; creation, flags: WinDword;
      templateHandle: WinHandle): WinHandle
      {.importc: "CreateFileW", stdcall, dynlib: "kernel32".}
  proc winCreateDirectory(path: WideCString;
      security: ptr WinSecurityAttributes): WinBool
      {.importc: "CreateDirectoryW", stdcall, dynlib: "kernel32".}
  proc winWriteFile(handle: WinHandle; buffer: pointer; count: WinDword;
      written: ptr WinDword; overlapped: pointer): WinBool
      {.importc: "WriteFile", stdcall, dynlib: "kernel32".}
  proc winReadFile(handle: WinHandle; buffer: pointer; count: WinDword;
      read: ptr WinDword; overlapped: pointer): WinBool
      {.importc: "ReadFile", stdcall, dynlib: "kernel32".}
  proc winFlushFileBuffers(handle: WinHandle): WinBool
      {.importc: "FlushFileBuffers", stdcall, dynlib: "kernel32".}
  proc winCloseHandle(handle: WinHandle): WinBool
      {.importc: "CloseHandle", stdcall, dynlib: "kernel32".}
  proc winGetLastError(): WinDword
      {.importc: "GetLastError", stdcall, dynlib: "kernel32".}
  proc winGetFileInformation(handle: WinHandle;
      info: ptr WinFileInformation): WinBool
      {.importc: "GetFileInformationByHandle", stdcall, dynlib: "kernel32".}
  proc winMoveFileEx(source, dest: WideCString; flags: WinDword): WinBool
      {.importc: "MoveFileExW", stdcall, dynlib: "kernel32".}
  proc winGetCurrentProcess(): WinHandle
      {.importc: "GetCurrentProcess", stdcall, dynlib: "kernel32".}
  proc winOpenProcessToken(processHandle: WinHandle; access: WinDword;
      tokenHandle: ptr WinHandle): WinBool
      {.importc: "OpenProcessToken", stdcall, dynlib: "advapi32".}
  proc winGetTokenInformation(token: WinHandle; informationClass: WinDword;
      information: pointer; informationLength: WinDword;
      returnLength: ptr WinDword): WinBool
      {.importc: "GetTokenInformation", stdcall, dynlib: "advapi32".}
  proc winConvertSidToString(sid: pointer; value: ptr pointer): WinBool
      {.importc: "ConvertSidToStringSidW", stdcall, dynlib: "advapi32".}
  proc winConvertSddl(value: WideCString; revision: WinDword;
      descriptor: ptr pointer; descriptorSize: ptr WinDword): WinBool
      {.importc: "ConvertStringSecurityDescriptorToSecurityDescriptorW",
        stdcall, dynlib: "advapi32".}
  proc winLocalFree(value: pointer): pointer
      {.importc: "LocalFree", stdcall, dynlib: "kernel32".}
  proc winGetSecurityInfo(handle: WinHandle; objectType, information: WinDword;
      owner, group: ptr pointer; dacl, sacl: ptr ptr WinAcl;
      descriptor: ptr pointer): WinDword
      {.importc: "GetSecurityInfo", stdcall, dynlib: "advapi32".}
  proc winGetSecurityDescriptorControl(descriptor: pointer;
      control: ptr uint16; revision: ptr WinDword): WinBool
      {.importc: "GetSecurityDescriptorControl", stdcall, dynlib: "advapi32".}
  proc winGetAclInformation(acl: ptr WinAcl; information: pointer;
      informationLength, informationClass: WinDword): WinBool
      {.importc: "GetAclInformation", stdcall, dynlib: "advapi32".}
  proc winGetAce(acl: ptr WinAcl; index: WinDword; ace: ptr pointer): WinBool
      {.importc: "GetAce", stdcall, dynlib: "advapi32".}
  proc winFindFirstStream(path: WideCString; infoLevel: WinDword;
      data: ptr WinStreamData; flags: WinDword): WinHandle
      {.importc: "FindFirstStreamW", stdcall, dynlib: "kernel32".}
  proc winFindNextStream(handle: WinHandle; data: ptr WinStreamData): WinBool
      {.importc: "FindNextStreamW", stdcall, dynlib: "kernel32".}
  proc winFindClose(handle: WinHandle): WinBool
      {.importc: "FindClose", stdcall, dynlib: "kernel32".}

const
  PrePushProtocolVersion* = 2
  HookCapabilityEnv* = "REPROBUILD_INTERNAL_HOOK_CAPABILITY"
  HookDispatcherProtocolEnv* = "REPROBUILD_HOOK_DISPATCH_PROTOCOL"
  LegacyHookSentinelEnv* = "REPROBUILD_HOOK_ACTIVE"
  InternalHookContextEnv* = "REPROBUILD_INTERNAL_HOOK_CONTEXT"
  InternalLockCommitContext* = "reprobuild.lock-commit.v1"
  V2DispatcherMarker* = "reprobuild hook dispatcher protocol=2"
  V2ManagedMarker* = "reprobuild managed pre-push hook protocol=2"
  CapabilitySchema* = "reprobuild.hook-capability.v2"
  CapabilityPurpose* = "nested-lock-publish"
  CapabilityTtlSeconds* = 30'i64
  CapabilityFutureSkewSeconds* = 2'i64
  CapabilityTtlMilliseconds* = CapabilityTtlSeconds * 1000'i64
  CapabilityFutureSkewMilliseconds* = CapabilityFutureSkewSeconds * 1000'i64

type
  PrePushRefUpdate* = object
    localRef*: string
    localOid*: string
    remoteRef*: string
    remoteOid*: string

  PrePushRefStream* = object
    ok*: bool
    diagnostic*: string
    objectFormat*: string
    oidLength*: int
    updates*: seq[PrePushRefUpdate]

  OutgoingUpdateShape* = enum
    ## How the outgoing branch update relates to the tip it replaces.
    ##
    ## This is deliberately SEPARATE from ``outgoingCurrent``. The two
    ## questions the classifier used to fuse are:
    ##
    ##   1. does this push PUBLISH this HEAD? — the meaning of
    ##      ``outgoingCurrent``, and the answer for a force-push is *yes*;
    ##   2. does this push ORPHAN something the workspace depends on? — a
    ##      real and separate concern, decided by the caller against the
    ##      workspace's lock records, with its own remedy.
    ##
    ## Fusing them made an ordinary rebase-and-force-push of a feature branch
    ## report the repository as "unpublished" and instruct the operator to run
    ## the very push being refused, whose only remedy was ``--no-verify`` —
    ## i.e. disabling the whole gate on a legitimate case.
    ouShapeUnknown = "unknown"
      ## The update was never classified (a protocol or eligibility refusal
      ## short-circuited first).
    ouCreate = "create"
      ## Remote-old is the zero OID: the push creates the branch and can
      ## discard nothing.
    ouFastForward = "fast-forward"
      ## Remote-old is an ancestor of the new HEAD: nothing becomes
      ## unreachable.
    ouRewrite = "rewrite"
      ## Remote-old is a locally present commit that is NOT an ancestor of the
      ## new HEAD. This push makes commits unreachable on the remote branch,
      ## and which ones can be enumerated locally.
    ouRewriteOpaque = "rewrite-opaque"
      ## Remote-old is not a locally present commit, so the push is not a
      ## fast-forward and what it discards cannot be enumerated here.

  OutgoingCurrentDecision* = object
    protocolOk*: bool
    outgoingCurrent*: bool
    diagnostic*: string
    headOid*: string
    branchRef*: string
    remoteName*: string
    remoteRef*: string
    remoteOldOid*: string
    objectFormat*: string
    updateShape*: OutgoingUpdateShape

  HookCapability* = object
    schema*: string
    protocol*: int
    token*: string
    purpose*: string
    worktree*: string
    commonDir*: string
    userIdentity*: string
    objectFormat*: string
    headOid*: string
    remoteName*: string
    remoteUrlDigest*: string
    localRef*: string
    localOid*: string
    remoteRef*: string
    remoteOid*: string
    issuerPid*: int
    issuedAtUnixMs*: int64

  CapabilityIssueResult* = object
    ok*: bool
    token*: string
    diagnostic*: string

  CapabilityConsumeResult* = object
    authorized*: bool
    claimLost*: bool
      ## The token was well-formed and the capability directory was secure,
      ## but another hook won the atomic pending-to-claimed move (or no pending
      ## record exists). The caller must scrub the token and run the ordinary
      ## gate; this is not an authorization and not a protocol-security error.
    diagnostic*: string

proc runGit(gitBin, repoRoot: string; args: openArray[string]):
    tuple[code: int; output: string] =
  var cmd = quoteShell(gitBin)
  if repoRoot.len > 0:
    cmd.add(" -C " & quoteShell(repoRoot))
  for arg in args:
    cmd.add(" " & quoteShell(arg))
  # Git exports repository-local bindings to hooks. A nested publication from
  # a linked source worktree must let `-C <backend>` select the backend instead
  # of silently inheriting the source's absolute GIT_DIR.
  let res = execCmdEx(cmd, options = {poStdErrToStdOut, poUsePath},
    env = scrubbedGitRepositoryEnv())
  (res.exitCode, res.output)

proc gitValue(gitBin, repoRoot: string; args: openArray[string]): string =
  let res = runGit(gitBin, repoRoot, args)
  if res.code == 0:
    result = res.output.strip()

proc canonicalPath(path: string): string =
  if path.len == 0: return ""
  # Capability identity is a filesystem identity, not a spelling identity.
  # `absolutePath`/`normalizedPath` leave symlink aliases intact (notably
  # /tmp versus /private/tmp on macOS), which would allow the same worktree to
  # be bound under more than one name. `expandFilename` resolves the existing
  # path through the native real-path implementation on every supported host.
  try:
    os.normalizedPath(expandFilename(path)).replace('\\', '/')
  except OSError:
    ""

when defined(windows):
  proc winWideAscii(value: pointer): string =
    if value == nil: return ""
    let chars = cast[ptr UncheckedArray[uint16]](value)
    var i = 0
    while chars[i] != 0'u16:
      if chars[i] > 0x7f'u16: return ""
      result.add(char(chars[i]))
      inc i

  proc winSidString(sid: pointer): string =
    if sid == nil: return ""
    var text: pointer
    if winConvertSidToString(sid, addr text) == 0: return ""
    result = winWideAscii(text)
    discard winLocalFree(text)

  proc currentWindowsSid(): string =
    var token: WinHandle
    if winOpenProcessToken(winGetCurrentProcess(), WinTokenQuery,
        addr token) == 0:
      return ""
    defer: discard winCloseHandle(token)
    var needed: WinDword
    discard winGetTokenInformation(token, WinTokenUser, nil, 0, addr needed)
    if needed == 0: return ""
    var buffer = newSeq[byte](int(needed))
    if winGetTokenInformation(token, WinTokenUser, addr buffer[0], needed,
        addr needed) == 0:
      return ""
    # TOKEN_USER begins with SID_AND_ATTRIBUTES; the first pointer is the SID.
    winSidString(cast[ptr pointer](addr buffer[0])[])

  proc winPrivateDescriptor(isDirectory: bool): pointer =
    let sid = currentWindowsSid()
    if sid.len == 0: return nil
    let flags = if isDirectory: "OICI" else: ""
    let sddl = "O:" & sid & "D:P(A;" & flags & ";FA;;;" & sid &
      ")(A;" & flags & ";FA;;;SY)"
    if winConvertSddl(newWideCString(sddl), WinSddlRevision, addr result,
        nil) == 0:
      result = nil

  proc winAclIsPrivate(handle: WinHandle; isDirectory: bool): bool =
    var owner, descriptor: pointer
    var dacl: ptr WinAcl
    if winGetSecurityInfo(handle, WinSeFileObject,
        WinOwnerSecurityInformation or WinDaclSecurityInformation,
        addr owner, nil, addr dacl, nil, addr descriptor) != 0:
      return false
    if descriptor == nil: return false
    defer: discard winLocalFree(descriptor)
    let currentSid = currentWindowsSid()
    if currentSid.len == 0 or winSidString(owner) != currentSid or dacl == nil:
      return false
    var control: uint16
    var revision: WinDword
    if winGetSecurityDescriptorControl(descriptor, addr control,
        addr revision) == 0 or (control and WinSeDaclProtected) == 0:
      return false
    var aclInfo: WinAclSizeInformation
    if winGetAclInformation(dacl, addr aclInfo, WinDword(sizeof(aclInfo)),
        WinAclSizeInformationClass) == 0 or aclInfo.aceCount != 2:
      return false
    let expectedFlags =
      if isDirectory: WinObjectInheritAce or WinContainerInheritAce
      else: 0'u8
    var sawUser, sawSystem: bool
    for index in 0'u32 ..< aclInfo.aceCount:
      var rawAce: pointer
      if winGetAce(dacl, index, addr rawAce) == 0 or rawAce == nil:
        return false
      let ace = cast[ptr WinAccessAllowedAce](rawAce)
      if ace[].header.aceType != WinAccessAllowedAceType or
          ace[].header.aceFlags != expectedFlags or
          (ace[].header.aceFlags and WinInheritedAce) != 0 or
          ace[].mask != WinFileAllAccess:
        return false
      let sid = winSidString(addr ace[].sidStart)
      if sid == currentSid and not sawUser:
        sawUser = true
      elif sid == "S-1-5-18" and not sawSystem:
        sawSystem = true
      else:
        return false
    sawUser and sawSystem

  proc winHasOnlyDefaultStream(path: string): bool =
    var data: WinStreamData
    let search = winFindFirstStream(newWideCString(path),
      WinFindStreamStandard, addr data, 0)
    if search == winInvalidHandle(): return false
    defer: discard winFindClose(search)
    if winWideAscii(addr data.streamName[0]) != "::$DATA": return false
    if winFindNextStream(search, addr data) != 0: return false
    winGetLastError() == WinErrorHandleEof

  proc winSecureHandle(path: string; isDirectory: bool): WinHandle =
    let flags = WinFileFlagOpenReparsePoint or
      (if isDirectory: WinFileFlagBackupSemantics else: 0'u32)
    result = winCreateFile(newWideCString(path),
      WinGenericRead or WinReadControl,
      WinFileShareRead or WinFileShareDelete, nil, WinOpenExisting, flags, nil)
    if result == winInvalidHandle(): return nil
    var info: WinFileInformation
    if winGetFileInformation(result, addr info) == 0 or
        (info.attributes and WinFileAttributeReparsePoint) != 0 or
        ((info.attributes and WinFileAttributeDirectory) != 0) != isDirectory or
        (not isDirectory and info.numberOfLinks != 1) or
        not winAclIsPrivate(result, isDirectory) or
        (not isDirectory and not winHasOnlyDefaultStream(path)):
      discard winCloseHandle(result)
      result = nil

  proc ensurePrivateWindowsDirectory(path: string): bool =
    let descriptor = winPrivateDescriptor(isDirectory = true)
    if descriptor == nil: return false
    defer: discard winLocalFree(descriptor)
    var security = WinSecurityAttributes(
      length: WinDword(sizeof(WinSecurityAttributes)),
      securityDescriptor: descriptor, inheritHandle: 0)
    if winCreateDirectory(newWideCString(path), addr security) == 0 and
        winGetLastError() != WinErrorAlreadyExists:
      return false
    let handle = winSecureHandle(path, isDirectory = true)
    if handle == nil: return false
    discard winCloseHandle(handle)
    true

proc storageObjectFormat*(gitBin, repoRoot: string): string =
  let value = gitValue(gitBin, repoRoot,
    ["rev-parse", "--show-object-format=storage"])
  case value
  of "sha1", "sha256": value
  else: ""

proc oidLengthFor(format: string): int =
  case format
  of "sha1": 40
  of "sha256": 64
  else: 0

proc isHexOid(value: string; expectedLength: int): bool =
  if value.len != expectedLength: return false
  for ch in value:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

proc isZeroOid*(value: string): bool =
  value.len > 0 and value.allCharsInSet({'0'})

proc validRefName(gitBin, repoRoot, value: string; allowHead: bool): bool =
  if allowHead and value == "HEAD": return true
  if not value.startsWith("refs/"): return false
  runGit(gitBin, repoRoot, ["check-ref-format", value]).code == 0

proc parsePrePushRefStream*(gitBin, repoRoot, refsPath: string):
    PrePushRefStream =
  result.objectFormat = storageObjectFormat(gitBin, repoRoot)
  result.oidLength = oidLengthFor(result.objectFormat)
  if result.oidLength == 0:
    result.diagnostic = "unsupported or unreadable Git object format"
    return
  if refsPath.len == 0 or not fileExists(refsPath):
    result.diagnostic = "pre-push refs stream is missing"
    return
  let content = readFile(refsPath)
  if content.len == 0:
    # Git's protocol permits zero updates. This is distinct from a single
    # empty record ("\n"), which is malformed framing. An empty stream cannot
    # grant outgoing-current status, but an already-published repository may
    # legitimately have no candidate source update to classify.
    result.ok = true
    return
  if '\r' in content or '\0' in content or '\t' in content:
    result.diagnostic = "pre-push refs stream contains forbidden control bytes"
    return
  var lines = content.split('\n')
  if lines.len > 0 and lines[^1].len == 0:
    lines.setLen(lines.len - 1)
  if lines.len == 0:
    result.diagnostic = "pre-push refs stream is empty"
    return
  for line in lines:
    if line.len == 0:
      result.diagnostic = "pre-push refs stream contains a blank line"
      return
    for ch in line:
      if ord(ch) < 0x20 or ord(ch) == 0x7f:
        result.diagnostic = "pre-push refs stream contains forbidden control bytes"
        return
    if line[0] == ' ' or line[^1] == ' ' or "  " in line:
      result.diagnostic = "pre-push refs record is not canonically spaced"
      return
    let fields = line.split(' ')
    if fields.len != 4:
      result.diagnostic = "pre-push refs record must contain exactly four fields"
      return
    if not ((fields[0] == "(delete)" and isZeroOid(fields[1])) or
        validRefName(gitBin, repoRoot, fields[0], allowHead = true)):
      result.diagnostic = "pre-push refs record has an invalid local ref"
      return
    if not validRefName(gitBin, repoRoot, fields[2], allowHead = false):
      result.diagnostic = "pre-push refs record has an invalid remote ref"
      return
    if not isHexOid(fields[1], result.oidLength) or
        not isHexOid(fields[3], result.oidLength):
      result.diagnostic = "pre-push refs record has an invalid object id"
      return
    result.updates.add(PrePushRefUpdate(
      localRef: fields[0], localOid: fields[1].toLowerAscii(),
      remoteRef: fields[2], remoteOid: fields[3].toLowerAscii()))
  result.ok = true

proc normalizedRemoteLocation*(value: string): string =
  ## Normalize without retaining or returning URL credentials.  Git may hand
  ## the hook the literal configured URL; comparisons therefore happen only
  ## against this credential-free form and diagnostics never include it.
  var s = value.strip().replace('\\', '/')
  if s.contains("://"):
    let schemeEnd = s.find("://")
    let scheme = s[0 ..< schemeEnd].toLowerAscii()
    var rest = s[(schemeEnd + 3) .. ^1]
    let slash = rest.find('/')
    var authority = if slash >= 0: rest[0 ..< slash] else: rest
    var tail = if slash >= 0: rest[slash .. ^1] else: ""
    # Queries and fragments are transport/authentication material, not
    # repository identity. In particular signed HTTPS URLs rotate these values
    # without changing the remote, and they may contain bearer credentials.
    let query = tail.find('?')
    let fragment = tail.find('#')
    var suffix = tail.len
    if query >= 0: suffix = min(suffix, query)
    if fragment >= 0: suffix = min(suffix, fragment)
    tail = tail[0 ..< suffix]
    let at = authority.rfind('@')
    if at >= 0: authority = authority[(at + 1) .. ^1]
    authority = authority.toLowerAscii()
    if scheme == "file":
      # A file URL's authority is part of its identity. In particular,
      # file://host/path must never be collapsed into file:///path. Resolve
      # only authority-less local paths through the filesystem; remote-host
      # paths are kept lexical and host-preserving.
      if authority.len == 0:
        let local = canonicalPath(if tail.len > 0: tail else: "/")
        if local.len == 0: return ""
        s = "file://" & local
      else:
        s = "file://" & authority & tail
    else:
      s = scheme & "://" & authority & tail
  elif s.contains('@') and s.contains(':'):
    # scp-style SSH URL: user@host:path.  The username is not part of the
    # repository identity and may itself be sensitive.
    let at = s.rfind('@')
    s = s[(at + 1) .. ^1]
    let colon = s.find(':')
    if colon >= 0:
      s = s[0 ..< colon].toLowerAscii() & s[colon .. ^1]
  elif s.startsWith("/") or s.startsWith("./") or s.startsWith("../"):
    s = canonicalPath(s)
  s

proc remoteLocationDigest*(value: string): string =
  let normalized = normalizedRemoteLocation(value)
  let digest = blake3.digest(normalized)
  result = newStringOfCap(64)
  for b in digest:
    result.add(toHex(int(b), 2).toLowerAscii())

proc configuredPushLocations(gitBin, repoRoot, remoteName: string): seq[string] =
  let res = runGit(gitBin, repoRoot,
    ["remote", "get-url", "--push", "--all", remoteName])
  if res.code != 0: return
  for line in res.output.splitLines():
    let value = line.strip()
    if value.len > 0:
      result.add(normalizedRemoteLocation(value))

proc remoteLocationMatches*(gitBin, repoRoot, remoteName,
    hookLocation: string): bool =
  let candidate = normalizedRemoteLocation(hookLocation)
  if candidate.len == 0: return false
  for configured in configuredPushLocations(gitBin, repoRoot, remoteName):
    if configured == candidate: return true

proc evaluateOutgoingCurrent*(gitBin, repoRoot, refsPath, hookRemoteName,
    hookRemoteLocation, agreedRemoteName, agreedRemoteLocation: string):
    OutgoingCurrentDecision =
  let parsed = parsePrePushRefStream(gitBin, repoRoot, refsPath)
  result.protocolOk = parsed.ok
  result.objectFormat = parsed.objectFormat
  if not parsed.ok:
    result.diagnostic = parsed.diagnostic
    return
  result.headOid = gitValue(gitBin, repoRoot, ["rev-parse", "HEAD^{commit}"])
    .toLowerAscii()
  if not isHexOid(result.headOid, parsed.oidLength):
    result.protocolOk = false
    result.diagnostic = "could not independently observe HEAD as a commit"
    return
  result.remoteName = hookRemoteName
  if hookRemoteName.len == 0 or agreedRemoteName.len == 0 or
      not remoteLocationMatches(gitBin, repoRoot, hookRemoteName,
        hookRemoteLocation):
    result.diagnostic = "push target is not the manifest-agreed remote"
    return
  if hookRemoteName != agreedRemoteName:
    # A checkout may use a different local alias for the exact repository
    # named by the manifest (for example, manifest ``origin`` and checkout
    # ``metacraft-labs``). The alias name alone carries no authority: its
    # actual push destination must both match that alias's configured push URL
    # (above) and equal the fully resolved manifest fetch location. Keeping
    # this fallback location-exact prevents an alias whose fetch URL happens
    # to agree but whose pushURL points elsewhere from borrowing provisional
    # publication status.
    let hookLocation = normalizedRemoteLocation(hookRemoteLocation)
    let agreedLocation = normalizedRemoteLocation(agreedRemoteLocation)
    if hookLocation.len == 0 or agreedLocation.len == 0 or
        hookLocation != agreedLocation:
      result.diagnostic = "push target is not the manifest-agreed remote"
      return
  if parsed.updates.len != 1:
    result.diagnostic = "outgoing-current requires exactly one pushed ref"
    return
  let update = parsed.updates[0]
  if update.localOid != result.headOid:
    result.diagnostic = "pushed object is not the independently observed HEAD"
    return
  if update.localRef == "HEAD":
    discard
  elif update.localRef.startsWith("refs/heads/"):
    let resolved = gitValue(gitBin, repoRoot,
      ["rev-parse", update.localRef & "^{commit}"]).toLowerAscii()
    if resolved != result.headOid:
      result.diagnostic = "pushed local branch does not resolve to HEAD"
      return
  else:
    result.diagnostic = "outgoing-current only applies to HEAD or a branch"
    return
  if not update.remoteRef.startsWith("refs/heads/"):
    result.diagnostic = "outgoing-current only applies to a remote branch"
    return
  # Classify the update's SHAPE. A push that names one ref, whose local object
  # is the independently observed HEAD, and whose destination is the
  # manifest-agreed remote branch, publishes that HEAD — fast-forward or not.
  # Rewriting the branch is a claim about what the push DISCARDS, which is a
  # separate question with a separate remedy and is decided by the caller
  # against the workspace's lock records (``repro check`` stage 2b).
  if isZeroOid(update.remoteOid):
    result.updateShape = ouCreate
  else:
    let oldType = gitValue(gitBin, repoRoot,
      ["cat-file", "-t", update.remoteOid])
    if oldType != "commit":
      result.updateShape = ouRewriteOpaque
    elif runGit(gitBin, repoRoot,
        ["merge-base", "--is-ancestor", update.remoteOid,
         result.headOid]).code == 0:
      result.updateShape = ouFastForward
    else:
      result.updateShape = ouRewrite
  result.branchRef = update.localRef
  result.remoteRef = update.remoteRef
  result.remoteOldOid = update.remoteOid
  result.outgoingCurrent = true

proc commitsMadeUnreachable*(gitBin, repoRoot, remoteOldOid,
    headOid: string): seq[string] =
  ## The commits a branch update from ``remoteOldOid`` to ``headOid`` would
  ## make unreachable on that branch: ``remoteOldOid`` itself plus everything
  ## reachable from it but not from the new HEAD, newest first.
  ##
  ## Empty for a create or a fast-forward (``rev-list old ^new`` is empty and
  ## ``old`` is itself reachable from ``new``), and empty when the old object
  ## is not present locally — an absent old object is reported by
  ## ``updateShape == ouRewriteOpaque`` rather than by a silently empty set,
  ## because "nothing is discarded" and "what is discarded cannot be seen" are
  ## different answers and only the first is safe to act on.
  if remoteOldOid.len == 0 or isZeroOid(remoteOldOid) or headOid.len == 0:
    return
  if gitValue(gitBin, repoRoot, ["cat-file", "-t", remoteOldOid]) != "commit":
    return
  let res = runGit(gitBin, repoRoot,
    ["rev-list", remoteOldOid, "^" & headOid])
  if res.code != 0:
    return
  for line in res.output.splitLines():
    let oid = line.strip().toLowerAscii()
    if oid.len > 0:
      result.add(oid)

proc commonGitDir*(gitBin, repoRoot: string): string =
  let raw = gitValue(gitBin, repoRoot, ["rev-parse", "--git-common-dir"])
  if raw.len == 0: return ""
  if raw.isAbsolute: canonicalPath(raw)
  else: canonicalPath(repoRoot / raw)

proc canonicalWorktree(gitBin, repoRoot: string): string =
  let raw = gitValue(gitBin, repoRoot, ["rev-parse", "--show-toplevel"])
  if raw.len == 0: return ""
  canonicalPath(raw)

proc capabilityDir(gitBin, repoRoot: string): string =
  let common = commonGitDir(gitBin, repoRoot)
  if common.len > 0: common / "reprobuild" / "hook-capabilities" else: ""

proc currentUserIdentity(): string =
  when defined(posix):
    "uid:" & $geteuid()
  elif defined(windows):
    let sid = currentWindowsSid()
    if sid.len > 0: "sid:" & sid else: ""
  else:
    "user:" & getEnv("USER")

proc secureCapabilityDir(path: string): tuple[ok: bool; diagnostic: string] =
  if path.len == 0: return (false, "Git common directory is unavailable")
  when defined(posix):
    let common = path.parentDir.parentDir
    let fd = rbOpenCapDir(common.cstring, 1)
    if fd < 0:
      return (false,
        "hook capability directory failed handle/ownership/mode checks")
    discard close(fd)
  elif defined(windows):
    let common = path.parentDir.parentDir
    if not ensurePrivateWindowsDirectory(common / "reprobuild") or
        not ensurePrivateWindowsDirectory(path):
      return (false,
        "hook capability directory failed SID/DACL/reparse checks")
  else:
    try:
      createDir(path)
    except CatchableError as err:
      return (false, "cannot create hook capability directory: " & err.msg)
  (true, "")

proc capabilityToJson(cap: HookCapability): JsonNode =
  %*{
    "schema": cap.schema, "protocol": cap.protocol, "token": cap.token,
    "purpose": cap.purpose,
    "worktree": cap.worktree, "commonDir": cap.commonDir,
    "userIdentity": cap.userIdentity, "objectFormat": cap.objectFormat,
    "headOid": cap.headOid, "remoteName": cap.remoteName,
    "remoteUrlDigest": cap.remoteUrlDigest, "localRef": cap.localRef,
    "localOid": cap.localOid, "remoteRef": cap.remoteRef,
    "remoteOid": cap.remoteOid, "issuerPid": cap.issuerPid,
    "issuedAtUnixMs": cap.issuedAtUnixMs
  }

proc capabilityFromJson(node: JsonNode): HookCapability =
  result.schema = node["schema"].getStr()
  result.protocol = node["protocol"].getInt()
  result.token = node["token"].getStr()
  result.purpose = node["purpose"].getStr()
  result.worktree = node["worktree"].getStr()
  result.commonDir = node["commonDir"].getStr()
  result.userIdentity = node["userIdentity"].getStr()
  result.objectFormat = node["objectFormat"].getStr()
  result.headOid = node["headOid"].getStr()
  result.remoteName = node["remoteName"].getStr()
  result.remoteUrlDigest = node["remoteUrlDigest"].getStr()
  result.localRef = node["localRef"].getStr()
  result.localOid = node["localOid"].getStr()
  result.remoteRef = node["remoteRef"].getStr()
  result.remoteOid = node["remoteOid"].getStr()
  result.issuerPid = node["issuerPid"].getInt()
  result.issuedAtUnixMs = node["issuedAtUnixMs"].getBiggestInt().int64

proc randomToken(): string =
  var bytes: array[32, byte]
  if randomBytes(addr bytes[0], bytes.len) != bytes.len:
    return ""
  result = newStringOfCap(64)
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii())

proc validTokenName(value: string): bool =
  isHexOid(value, 64)

proc validCapabilityRecordName(value: string): bool =
  ## Maintenance is intentionally limited to the two exact protocol names:
  ## `<token>.pending` and `<token>.<numeric-pid>.claimed`.
  if value.len == 64 + ".pending".len and value.endsWith(".pending"):
    return validTokenName(value[0 ..< 64])
  if value.len <= 64 + 2 + ".claimed".len or
      not value.endsWith(".claimed") or value[64] != '.':
    return false
  if not validTokenName(value[0 ..< 64]): return false
  let pidEnd = value.len - ".claimed".len
  let pid = value[65 ..< pidEnd]
  if pid.len == 0: return false
  for ch in pid:
    if ch notin {'0'..'9'}: return false
  true

when defined(windows):
  proc writeExclusiveDurable(path, content: string): bool =
    let descriptor = winPrivateDescriptor(isDirectory = false)
    if descriptor == nil: return false
    defer: discard winLocalFree(descriptor)
    var security = WinSecurityAttributes(
      length: WinDword(sizeof(WinSecurityAttributes)),
      securityDescriptor: descriptor, inheritHandle: 0)
    let handle = winCreateFile(newWideCString(path), WinGenericWrite, 0,
      addr security, WinCreateNew,
      WinFileAttributeNormal or WinFileFlagWriteThrough or
        WinFileFlagOpenReparsePoint,
      nil)
    if handle == winInvalidHandle(): return false
    var ok = true
    var writtenTotal = 0
    while writtenTotal < content.len:
      var written: WinDword
      if winWriteFile(handle, unsafeAddr content[writtenTotal],
          WinDword(content.len - writtenTotal), addr written, nil) == 0 or
          written == 0:
        ok = false
        break
      writtenTotal += int(written)
    if ok and winFlushFileBuffers(handle) == 0: ok = false
    discard winCloseHandle(handle)
    if not ok:
      try: removeFile(path)
      except CatchableError: discard
    ok
else:
  proc writeExclusiveDurable(path, content: string): bool =
    if fileExists(path) or symlinkExists(path): return false
    try:
      writeFile(path, content)
      true
    except CatchableError:
      false

proc issueHookCapability*(gitBin, repoRoot, remoteName, remoteLocation,
    localRef, localOid, remoteRef, remoteOid: string): CapabilityIssueResult =
  let dir = capabilityDir(gitBin, repoRoot)
  let secure = secureCapabilityDir(dir)
  if not secure.ok:
    result.diagnostic = secure.diagnostic
    return
  let token = randomToken()
  if token.len == 0:
    result.diagnostic = "OS CSPRNG could not produce a hook capability"
    return
  let format = storageObjectFormat(gitBin, repoRoot)
  let common = commonGitDir(gitBin, repoRoot)
  let cap = HookCapability(
    schema: CapabilitySchema, protocol: PrePushProtocolVersion, token: token,
    purpose: CapabilityPurpose,
    worktree: canonicalWorktree(gitBin, repoRoot), commonDir: common,
    userIdentity: currentUserIdentity(), objectFormat: format,
    headOid: gitValue(gitBin, repoRoot, ["rev-parse", "HEAD^{commit}"])
    .toLowerAscii(),
    remoteName: remoteName, remoteUrlDigest: remoteLocationDigest(
        remoteLocation),
    localRef: localRef, localOid: localOid.toLowerAscii(),
    remoteRef: remoteRef, remoteOid: remoteOid.toLowerAscii(),
    issuerPid: getCurrentProcessId(),
    issuedAtUnixMs: int64(getTime().toUnixFloat() * 1000.0))
  let path = dir / (token & ".pending")
  let content = $capabilityToJson(cap) & "\n"
  var wrote = false
  when defined(posix):
    let capFd = rbOpenCapDir(common.cstring, 0)
    if capFd >= 0:
      let pendingName = token & ".pending"
      wrote = rbWriteCapAt(capFd, pendingName.cstring, content.cstring,
        csize_t(content.len)) != 0
      if wrote and rbArmPendingCleanup(capFd, pendingName.cstring) == 0:
        discard rbUnlinkCapAt(capFd, pendingName.cstring)
        wrote = false
      discard close(capFd)
  else:
    wrote = writeExclusiveDurable(path, content)
  if not wrote:
    result.diagnostic = "could not create the one-use hook capability"
    return
  result.ok = true
  result.token = token

proc discardHookCapability*(gitBin, repoRoot, token: string) =
  ## Issuers call this on every child-completion path. A successfully consumed
  ## capability has already been atomically moved and deleted; in that case the
  ## pending path is simply absent.
  if not validTokenName(token): return
  let pendingName = token & ".pending"
  when defined(posix):
    rbDisarmPendingCleanup()
    let common = commonGitDir(gitBin, repoRoot)
    let capFd = rbOpenCapDir(common.cstring, 0)
    if capFd >= 0:
      discard rbUnlinkCapAt(capFd, pendingName.cstring)
      discard close(capFd)
  else:
    let path = capabilityDir(gitBin, repoRoot) / pendingName
    try:
      if fileExists(path) or symlinkExists(path): removeFile(path)
    except CatchableError:
      discard

when defined(windows):
  proc claimNoReplace(source, dest: string): bool =
    # MoveFileEx without MOVEFILE_REPLACE_EXISTING is atomic and refuses an
    # existing destination. WRITE_THROUGH makes the namespace change durable.
    winMoveFileEx(newWideCString(source), newWideCString(dest),
      WinMoveFileWriteThrough) != 0
else:
  proc claimNoReplace(source, dest: string): bool = false

when defined(posix):
  proc readClaimedSecureFd(fd: cint): tuple[ok: bool; content: string] =
    if fd < 0: return
    var st: Stat
    if fstat(fd, st) != 0 or not S_ISREG(st.st_mode) or
        st.st_uid != geteuid() or st.st_nlink != 1 or
        (st.st_mode and Mode(0o777)) != Mode(0o600):
      discard close(fd)
      return
    var chunks = newStringOfCap(int(st.st_size))
    var buffer: array[4096, char]
    while true:
      let n = posix.read(fd, addr buffer[0], buffer.len)
      if n < 0:
        discard close(fd)
        return
      if n == 0: break
      for i in 0 ..< n:
        chunks.add(buffer[i])
      if chunks.len > 65536:
        discard close(fd)
        return
    discard close(fd)
    (true, chunks)
elif defined(windows):
  proc readClaimedSecure(path: string): tuple[ok: bool; content: string] =
    let handle = winSecureHandle(path, isDirectory = false)
    if handle == nil: return
    defer: discard winCloseHandle(handle)
    var info: WinFileInformation
    if winGetFileInformation(handle, addr info) == 0 or
        info.fileSizeHigh != 0 or info.fileSizeLow > 65536'u32:
      return
    var content = newString(int(info.fileSizeLow))
    var offset = 0
    while offset < content.len:
      var count: WinDword
      if winReadFile(handle, addr content[offset],
          WinDword(content.len - offset), addr count, nil) == 0 or count == 0:
        return
      offset += int(count)
    (true, content)
else:
  proc readClaimedSecure(path: string): tuple[ok: bool; content: string] =
    try:
      if not fileExists(path) or symlinkExists(path): return
      (true, readFile(path))
    except CatchableError:
      (false, "")

proc consumeHookCapability*(gitBin, repoRoot, token, remoteName,
    remoteLocation, refsPath: string): CapabilityConsumeResult =
  if not validTokenName(token):
    result.diagnostic = "hook capability token is malformed"
    return
  let dir = capabilityDir(gitBin, repoRoot)
  let secure = secureCapabilityDir(dir)
  if not secure.ok:
    result.diagnostic = secure.diagnostic
    return
  let pendingName = token & ".pending"
  let claimedName = token & "." & $getCurrentProcessId() & ".claimed"
  var readResult: tuple[ok: bool; content: string]
  when defined(posix):
    let common = commonGitDir(gitBin, repoRoot)
    let capFd = rbOpenCapDir(common.cstring, 0)
    if capFd < 0:
      result.diagnostic = "hook capability directory is unavailable"
      return
    defer: discard close(capFd)
    if rbClaimCapAt(capFd, pendingName.cstring, claimedName.cstring) == 0:
      result.claimLost = true
      result.diagnostic = "hook capability is missing, expired, or already used"
      return
    let claimedFd = rbOpenCapAt(capFd, claimedName.cstring)
    readResult = readClaimedSecureFd(claimedFd)
    # Delete through the held directory handle before returning authorization.
    discard rbUnlinkCapAt(capFd, claimedName.cstring)
  else:
    let pending = dir / pendingName
    let claimed = dir / claimedName
    if not claimNoReplace(pending, claimed):
      result.claimLost = true
      result.diagnostic = "hook capability is missing, expired, or already used"
      return
    readResult = readClaimedSecure(claimed)
    # Delete before returning authorization. A replay therefore fails even if
    # later hook work or the nested push itself fails.
    try: removeFile(claimed)
    except CatchableError: discard
  if not readResult.ok:
    result.diagnostic = "claimed hook capability failed file security checks"
    return
  var cap: HookCapability
  try:
    cap = capabilityFromJson(parseJson(readResult.content))
  except CatchableError:
    result.diagnostic = "claimed hook capability is malformed"
    return
  let now = int64(getTime().toUnixFloat() * 1000.0)
  let observedHead = gitValue(gitBin, repoRoot,
    ["rev-parse", "HEAD^{commit}"]).toLowerAscii()
  let mismatch =
    if cap.schema != CapabilitySchema: "schema"
    elif cap.protocol != PrePushProtocolVersion: "protocol"
    elif cap.token != token: "token"
    elif cap.purpose != CapabilityPurpose: "purpose"
    elif cap.worktree != canonicalWorktree(gitBin, repoRoot): "worktree"
    elif cap.commonDir != commonGitDir(gitBin, repoRoot): "common Git directory"
    elif cap.userIdentity != currentUserIdentity(): "user identity"
    elif cap.objectFormat != storageObjectFormat(gitBin, repoRoot):
      "object format"
    elif cap.headOid != observedHead: "backend HEAD"
    elif cap.remoteName != remoteName: "remote name"
    elif cap.remoteUrlDigest != remoteLocationDigest(remoteLocation):
      "remote location"
    elif now - cap.issuedAtUnixMs > CapabilityTtlMilliseconds: "expiry"
    elif cap.issuedAtUnixMs - now > CapabilityFutureSkewMilliseconds:
      "issue time"
    else: ""
  if mismatch.len > 0:
    result.diagnostic = "hook capability does not match this push (" &
      mismatch & ")"
    return
  let refs = parsePrePushRefStream(gitBin, repoRoot, refsPath)
  if not refs.ok or refs.updates.len != 1:
    result.diagnostic = "hook capability push refs are invalid"
    return
  let update = refs.updates[0]
  if update.localRef != cap.localRef or update.localOid != cap.localOid or
      update.remoteRef != cap.remoteRef or update.remoteOid != cap.remoteOid:
    result.diagnostic = "hook capability does not match the pushed ref"
    return
  result.authorized = true

proc cleanupExpiredCapabilities*(gitBin, repoRoot: string) =
  let dir = capabilityDir(gitBin, repoRoot)
  if not dirExists(dir): return
  if not secureCapabilityDir(dir).ok: return
  let now = getTime().toUnix()
  when defined(posix):
    let common = commonGitDir(gitBin, repoRoot)
    let capFd = rbOpenCapDir(common.cstring, 0)
    if capFd < 0: return
    defer: discard close(capFd)
  for kind, path in walkDir(dir, relative = false):
    if kind != pcFile: continue
    let name = path.extractFilename()
    if not validCapabilityRecordName(name): continue
    try:
      when defined(posix):
        let modified = rbCapMtimeAt(capFd, name.cstring)
        if modified >= 0 and now - modified > CapabilityTtlSeconds:
          discard rbUnlinkCapAt(capFd, name.cstring)
      else:
        if now - getLastModificationTime(path).toUnix() > CapabilityTtlSeconds:
          removeFile(path)
    except CatchableError:
      discard
