## The uninstall records' directory: files in a directory that only root
## may change, written, read and removed through one descriptor of that
## directory (ReproOS Add-On Mode spec §13 decisions 165 and 178; A11 code
## review rounds 17 and 18).
##
## The add-on keeps signed records -- the discard intents and completions,
## the state-removal token -- in ``/var/log/repro-addon``. Its parent is not
## always root's alone: Ubuntu's ``/var/log`` is ``root:syslog 0775`` with no
## sticky bit, so a member of group ``syslog`` can rename ``repro-addon`` or
## put a symbolic link in its place. Anything done by path there could then
## follow that link: chmod its target, write the records into it, or read a
## planted record. Here the directory is opened once, from its parent, with
## ``O_DIRECTORY|O_NOFOLLOW``; it is judged on that descriptor (``fstat``:
## a directory, owned by the user running the add-on -- root -- and writable
## by no group or other); and every later step goes through the descriptor
## (``openat``, ``linkat``, ``renameat``, ``unlinkat``, ``fsync``), so no
## rename of the path between the check and the use changes which directory
## is used. Pre-creating the directory with the wrong owner still denies
## its use: that is a refusal, never a takeover.
##
## The *at(2) calls are POSIX.1-2008:
## https://pubs.opengroup.org/onlinepubs/9799919799/functions/openat.html,
## https://pubs.opengroup.org/onlinepubs/9799919799/functions/linkat.html,
## https://pubs.opengroup.org/onlinepubs/9799919799/functions/renameat.html,
## https://pubs.opengroup.org/onlinepubs/9799919799/functions/unlinkat.html.

import std/[os, posix, strutils, tables]

import ./mutations

proc openatC(dirfd: cint; path: cstring; flags: cint): cint
  {.importc: "openat", header: "<fcntl.h>", varargs.}
proc mkdiratC(dirfd: cint; path: cstring; mode: Mode): cint
  {.importc: "mkdirat", header: "<sys/stat.h>".}
proc unlinkatC(dirfd: cint; path: cstring; flags: cint): cint
  {.importc: "unlinkat", header: "<unistd.h>".}
proc renameatC(olddirfd: cint; oldpath: cstring; newdirfd: cint;
               newpath: cstring): cint
  {.importc: "renameat", header: "<stdio.h>".}
proc linkatC(olddirfd: cint; oldpath: cstring; newdirfd: cint;
             newpath: cstring; flags: cint): cint
  {.importc: "linkat", header: "<unistd.h>".}
proc fstatatC(dirfd: cint; path: cstring; buf: var Stat; flags: cint): cint
  {.importc: "fstatat", header: "<sys/stat.h>".}
var AtSymlinkNoFollow {.importc: "AT_SYMLINK_NOFOLLOW", header: "<fcntl.h>".}: cint
var ODirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
var ONoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
var ONonBlock {.importc: "O_NONBLOCK", header: "<fcntl.h>".}: cint
proc fdopendirC(fd: cint): ptr DIR {.importc: "fdopendir", header: "<dirent.h>".}
proc c_syscall(n: clong): clong {.importc: "syscall", header: "<unistd.h>",
                                  varargs.}
proc c_ioctl(fd: cint; req: culong): cint {.importc: "ioctl",
  header: "<sys/ioctl.h>", varargs.}

# statx(2) by number, on the open descriptor (AT_EMPTY_PATH): neither libc
# this links against is required to wrap it; only stx_ino (offset 32) and
# stx_btime (offset 80: tv_sec i64, tv_nsec u32) are read
# (https://man7.org/linux/man-pages/man2/statx.2.html).
const
  SysStatx =
    when defined(amd64): 332
    elif defined(arm64) or defined(riscv64): 291
    elif defined(arm): 397
    elif defined(i386): 383
    else: -1
  AtEmptyPath = 0x1000
  StatxIno = 0x100'u32
  StatxBtime = 0x800'u32
  # FS_IOC_GETVERSION = _IOR('v', 1, long)
  # (https://man7.org/linux/man-pages/man2/ioctl_iflags.2.html).
  FsIocGetVersion = (2'u64 shl 30) or (uint64(sizeof(clong)) shl 16) or
                    (uint64(ord('v')) shl 8) or 1'u64

const MaxRecordBytes* = 1024 * 1024
  ## No record the add-on writes comes near this; a read stops here, so a
  ## planted endless file (a link to ``/dev/zero``, were one followed)
  ## cannot exhaust memory.

const AddonLogDir* = "/var/log/repro-addon"
  ## Where the add-on keeps its uninstall records: the discard intents and
  ## completions, and the state-removal token.

type
  RecordExistsError* = object of OSError
    ## The record's name is taken: a record is never written over.

proc statxIdentity(fd: cint): string =
  ## The identity of the directory open at ``fd``: ``<ino>@<sec>.<nsec>``
  ## (its inode number and birth time, from ``statx``), with ``g<N>``
  ## appended where the file system reports an inode generation -- the
  ## same scheme as the state-removal token's (§13 decision 165). "" when
  ## the kernel or the file system reports no birth time: the inode number
  ## alone does not tell a replacement apart (it is reused), so every
  ## caller refuses then (§13 decision 178, amended: "Refuse at
  ## bootstrap"; the checked open refuses too).
  when SysStatx > 0:
    var buf: array[256, byte]
    if c_syscall(clong(SysStatx), fd, cstring(""), cint(AtEmptyPath),
                 cuint(StatxIno or StatxBtime), addr buf) != 0:
      return ""
    var mask: uint32
    copyMem(addr mask, addr buf[0], 4)
    if (mask and StatxBtime) == 0: return ""
    var ino: uint64
    var sec: int64
    var nsec: uint32
    copyMem(addr ino, addr buf[32], 8)
    copyMem(addr sec, addr buf[80], 8)
    copyMem(addr nsec, addr buf[88], 4)
    result = $ino & "@" & $sec & "." & $nsec
    var v: clong
    if c_ioctl(fd, culong(FsIocGetVersion), addr v) == 0:
      result.add("g" & $v)
  else:
    ""

var identityOverride*: proc (fd: cint): string {.nimcall.} = nil
  ## A test seam, nil in production: what ``fdIdentity`` returns instead
  ## of the kernel's answer, so a test can fake a file system with no
  ## birth time, or a reused inode number with another birth time.

proc fdIdentity*(fd: cint): string =
  ## ``statxIdentity``, unless a test set ``identityOverride``.
  if identityOverride != nil: identityOverride(fd) else: statxIdentity(fd)

proc validIdentity*(s: string): bool =
  ## Whether ``s`` is an identity ``fdIdentity`` could have produced:
  ## ``<digits>@<digits>.<digits>`` with an optional ``g<integer>``.
  let at = s.find('@')
  if at <= 0: return false
  if not s[0 ..< at].allCharsInSet(Digits): return false
  var rest = s[at + 1 .. ^1]
  let g = rest.find('g')
  if g >= 0:
    let gen = rest[g + 1 .. ^1]
    if gen.len == 0 or not gen.strip(chars = {'-'}, trailing = false).allCharsInSet(Digits):
      return false
    rest = rest[0 ..< g]
  let dot = rest.find('.')
  dot > 0 and dot < rest.high and rest[0 ..< dot].allCharsInSet(Digits) and
    rest[dot + 1 .. ^1].allCharsInSet(Digits)

proc writeInCheckedDir*(path, text: string; mode = 0o600;
                        replace = false; create = true)
proc readInCheckedDir*(path: string): string

const RecordsDirIdentityName* = "records-dir.identity"

proc recordsDirIdentityPath*(stateDir: string): string =
  ## Where the identity of the records directory bootstrap made is kept:
  ## in the add-on's root-only state (§13 decision 178, amended).
  stateDir / "addon" / RecordsDirIdentityName

type DirBinding = object
  identityFile: string   ## root-only state holding the recorded identity
  expected: string       ## the identity read or recorded; "" until known
  corrupt: string        ## why the identity file cannot be trusted, or ""
  recordedNow: bool      ## recorded at first use by this process
  stateGone: bool        ## used with no state to compare against (L3)

var bindings = initTable[string, DirBinding]()
  ## The records directories bound to a recorded identity (§13 decision
  ## 178, amended): the module's one piece of state, set by the verbs that
  ## use ``/var/log/repro-addon`` (bootstrap, uninstall, verify) before
  ## they touch it, and read by ``openCheckedDir``. A table keyed by path,
  ## so a test binds its own temporary directory the same way.

proc bindRecordsDir*(dir, identityFile: string) =
  ## Bind ``dir`` to the identity recorded in ``identityFile`` (root-only
  ## add-on state). When there is no recorded identity yet -- a host
  ## bootstrapped before §13 decision 178's amendment -- the first checked
  ## open records it (trust on first use) where ``identityFile``'s
  ## directory exists.
  ## An identity file that is present but empty or malformed (a torn
  ## write, or one somebody else wrote) is never taken as "nothing
  ## recorded": every checked open then refuses, naming it.
  var b = DirBinding(identityFile: identityFile)
  if fileExists(identityFile) or symlinkExists(identityFile):
    try:
      let text = readInCheckedDir(identityFile).strip()
      if validIdentity(text) or mutated("identity-file-torn-accepted"):
        b.expected = text
      else: b.corrupt = identityFile & " holds no identity the add-on wrote"
    except CatchableError as e:
      b.corrupt = identityFile & " cannot be read: " & e.msg
  bindings[dir] = b

proc unbindRecordsDir*(dir: string) =
  bindings.del(dir)

proc recordedIdentity*(dir: string): string =
  ## The identity ``dir`` is bound to, "" when unbound or not yet recorded.
  bindings.getOrDefault(dir).expected

proc boundWithoutState*(dir: string): bool =
  ## Whether ``dir`` was used with nothing to compare its identity with,
  ## because the state that holds the record is gone: only an uninstall's
  ## re-run after it removed the state (§13 decision 165). The token it
  ## reads binds its own chain, so a directory put in the place of the
  ## records directory can deny that re-run and do nothing else
  ## (threat-model G54, residual); the caller reports it, never silently.
  bindings.getOrDefault(dir).stateGone

proc recordedAtFirstUse*(dir: string): bool =
  ## Whether this process recorded ``dir``'s identity at its first use (a
  ## host bootstrapped before the identity was recorded).
  bindings.getOrDefault(dir).recordedNow

proc fdDirRefusal(fd: cint; dir: string): string =
  ## "" when the directory open at ``fd`` may hold the add-on's records:
  ## a directory owned by the user running the add-on (root) and writable
  ## by no group or other.
  when mutated("token-dir-unchecked"):
    return ""          # FALSIFIER: any directory may hold the records
  var st: Stat
  if fstat(fd, st) != 0: return dir & ": " & $strerror(errno)
  if not S_ISDIR(st.st_mode): return dir & " is not a directory"
  if st.st_uid != geteuid():
    return dir & " is owned by uid " & $st.st_uid & ", not " & $geteuid()
  if (int(st.st_mode) and 0o022) != 0:
    return dir & " is writable by its group or by others (mode " &
      toOct(int(st.st_mode) and 0o7777, 4) & ")"
  ""

proc openCheckedDir*(dir: string; create: bool): cint =
  ## ``dir`` opened once: its parent by path, then the directory itself by
  ## ``openat(O_DIRECTORY|O_NOFOLLOW)``, created 0700 (and the parent
  ## fsynced) when absent and ``create``. -1 when it is absent and not
  ## ``create``; raises ``OSError`` when it may not hold the records (a
  ## link, not a directory, another owner, writable by others). The caller
  ## closes the descriptor.
  let parent = parentDir(dir)
  let name = extractFilename(dir)
  let pfd = posix.open(parent.cstring, O_RDONLY or ODirectory or O_CLOEXEC)
  if pfd < 0: raiseOSError(osLastError(), "open " & parent)
  defer: discard posix.close(pfd)
  var fd = openatC(pfd, name.cstring, O_RDONLY or ODirectory or ONoFollow or
                   O_CLOEXEC)
  if fd < 0 and errno == ENOENT:
    if not create: return -1
    if mkdiratC(pfd, name.cstring, Mode(0o700)) != 0 and errno != EEXIST:
      raiseOSError(osLastError(), "mkdir " & dir)
    if fsync(pfd) != 0: raiseOSError(osLastError(), "fsync " & parent)
    fd = openatC(pfd, name.cstring, O_RDONLY or ODirectory or ONoFollow or
                 O_CLOEXEC)
  if fd < 0:
    raise newException(OSError, "refusing " & dir & ": " & $strerror(errno) &
      " (a symbolic link, or not a directory)")
  let why = fdDirRefusal(fd, dir)
  if why.len > 0:
    discard posix.close(fd)
    raise newException(OSError, "refusing " & why)
  if dir in bindings:
    # §13 decision 178, amended: the directory bootstrap made, and no
    # other. A member of a group that can write /var/log can rename the
    # root-only directory away and put another root directory in its
    # place; rename(2) needs write permission on the parent only.
    var refusal = ""
    try:
      let now = fdIdentity(fd)
      var b = bindings[dir]
      when not mutated("records-dir-identity-unchecked"):
        if b.corrupt.len > 0:
          refusal = "refusing " & dir & ": its recorded identity is " &
            "unusable (" & b.corrupt & "). Inspect " & dir & "; if it is the " &
            "directory bootstrap made, remove " & b.identityFile &
            " so the next use records it again"
        elif now.len == 0 and not mutated("unbound-when-no-birth-time"):
          refusal = "refusing " & dir & ": its file system reports no " &
            "birth time (statx STATX_BTIME), so the add-on cannot tell it " &
            "from another directory put in its place; keep /var/log on a " &
            "file system that records birth times"
        elif b.expected.len == 0 and not dirExists(parentDir(b.identityFile)):
          # The state is gone (an uninstall removed it): nothing to compare
          # with and nowhere to record; reported by the caller.
          b.stateGone = true
          bindings[dir] = b
        elif b.expected.len == 0:
          if now.len > 0:
            # First use on a host bootstrapped before the identity was
            # recorded: recorded now, atomically, 0600, durably, through
            # the checked state directory. A record that cannot be written
            # is a refusal: the directory is never used unbound.
            writeInCheckedDir(b.identityFile, now & "\n", 0o600,
                              replace = true, create = false)
            b.expected = now
            b.recordedNow = true
            bindings[dir] = b
        elif now != b.expected:
          refusal = "refusing " & dir & ": it is not the directory " &
            "bootstrap made (identity " & now & ", recorded " & b.expected &
            " in " & b.identityFile & "); something renamed it or put another " &
            "directory in its place. Inspect " & dir & " and the directory " &
            "it replaced; if it is the add-on's and only moved back, remove " &
            b.identityFile & " so the next use records it again"
    except CatchableError as e:
      refusal = "refusing " & dir & ": its identity cannot be recorded or " &
        "compared (" & e.msg & ")"
    if refusal.len > 0:
      discard posix.close(fd)
      raise newException(OSError, refusal)
  fd

proc checkedDirRefusal*(dir: string): string =
  ## "" when ``dir`` may hold the records, or is absent; else why not.
  try:
    let fd = openCheckedDir(dir, create = false)
    if fd >= 0: discard posix.close(fd)
    ""
  except CatchableError as ex: ex.msg

var afterTightenHook*: proc () {.nimcall.} = nil
  ## A test seam, nil in production: run by ``ensureCheckedDir`` between
  ## the tightening and the identity, where a rename race would land.

proc ensureCheckedDir*(dir: string; tighten = false): string {.discardable.} =
  ## ``dir`` created root's 0700 when absent, and checked; raises
  ## ``OSError`` when it may not hold the records. With ``tighten`` (§13
  ## decision 178: bootstrap) an existing root directory that passed the
  ## checks gets mode 0700, through the descriptor. Returns the identity
  ## of the directory on that same descriptor, after the tightening: the
  ## one bootstrap records (A11 round 20: a second open could find
  ## another directory renamed into the place in between).
  let fd = openCheckedDir(dir, create = true)
  defer: discard posix.close(fd)
  if tighten:
    when not mutated("records-dir-left-open"):
      if fchmod(fd, Mode(0o700)) != 0:
        raiseOSError(osLastError(), "chmod 0700 " & dir)
      if fsync(fd) != 0: raiseOSError(osLastError(), "fsync " & dir)
  if afterTightenHook != nil: afterTightenHook()
  when mutated("bootstrap-identity-reopened"):
    # FALSIFIER: round 19's identity, from a fresh open of the path.
    let fd2 = openCheckedDir(dir, create = false)
    if fd2 >= 0:
      result = fdIdentity(fd2)
      discard posix.close(fd2)
  else:
    result = fdIdentity(fd)

proc birthTimeProbe*(dir: string): string =
  ## The identity ``dir`` would have, read before anything is written:
  ## ``dir``'s own when it exists (checked like every use of it), else its
  ## parent's -- the file system ``dir`` would be made on. "" when that
  ## file system reports no birth time; bootstrap then refuses with
  ## nothing written (§13 decision 178, amended 2026-11-16).
  var st: Stat
  if lstat(dir.cstring, st) == 0:
    let fd = openCheckedDir(dir, create = false)
    if fd < 0: return ""
    defer: discard posix.close(fd)
    return fdIdentity(fd)
  let pfd = posix.open(parentDir(dir).cstring,
                       O_RDONLY or O_CLOEXEC or ODirectory)
  if pfd < 0: raiseOSError(osLastError(), "open " & parentDir(dir))
  defer: discard posix.close(pfd)
  fdIdentity(pfd)

proc identityOfCheckedDir*(dir: string): string =
  ## The identity of ``dir`` as the checked open sees it; "" when absent.
  let fd = openCheckedDir(dir, create = false)
  if fd < 0: return ""
  defer: discard posix.close(fd)
  fdIdentity(fd)

proc listInCheckedDir*(dir: string): seq[tuple[name: string; regular: bool]] =
  ## The entries of ``dir``, enumerated through a duplicate of its checked
  ## descriptor (``fdopendir``), each judged without following a link
  ## (``fstatat(AT_SYMLINK_NOFOLLOW)``): ``regular`` is true only for a
  ## regular file. Empty when the directory is absent.
  let dfd = openCheckedDir(dir, create = false)
  if dfd < 0: return
  defer: discard posix.close(dfd)
  let lfd = dup(dfd)
  if lfd < 0: raiseOSError(osLastError(), "dup " & dir)
  let d = fdopendirC(lfd)
  if d == nil:
    discard posix.close(lfd)
    raiseOSError(osLastError(), "fdopendir " & dir)
  defer: discard closedir(d)
  while true:
    let ent = readdir(d)
    if ent == nil: break
    let name = $cast[cstring](addr ent.d_name)
    if name == "." or name == "..": continue
    var st: Stat
    let regular = fstatatC(dfd, name.cstring, st, AtSymlinkNoFollow) == 0 and
                  S_ISREG(st.st_mode)
    result.add((name, regular))

proc unlinkAt(dfd: cint; name, dir: string) =
  ## Unlink ``name`` in the open directory, if there, and fsync it.
  var st: Stat
  if fstatatC(dfd, name.cstring, st, AtSymlinkNoFollow) != 0:
    if errno == ENOENT: return
    raiseOSError(osLastError(), "stat " & dir / name)
  if unlinkatC(dfd, name.cstring, 0) != 0:
    raiseOSError(osLastError(), "unlink " & dir / name)
  if fsync(dfd) != 0: raiseOSError(osLastError(), "fsync " & dir)

proc existsInCheckedDir*(path: string): bool =
  ## Whether a name exists in ``path``'s directory (a link counts), looked
  ## up through the checked descriptor; false when the directory is absent.
  let dir = parentDir(path)
  let dfd = openCheckedDir(dir, create = false)
  if dfd < 0: return false
  defer: discard posix.close(dfd)
  var st: Stat
  fstatatC(dfd, extractFilename(path).cstring, st, AtSymlinkNoFollow) == 0

proc removeInCheckedDir*(path: string) =
  ## Remove ``path``, durably, through its directory's checked descriptor;
  ## nothing when the directory or the name is absent.
  let dir = parentDir(path)
  let dfd = openCheckedDir(dir, create = false)
  if dfd < 0: return
  defer: discard posix.close(dfd)
  unlinkAt(dfd, extractFilename(path), dir)

proc writeInCheckedDir*(path, text: string; mode = 0o600;
                        replace = false; create = true) =
  ## Write ``path`` durably through its directory's checked descriptor: a
  ## temporary name (a stale one unlinked first) created exclusively without
  ## following a link, written and fsynced, then given the name -- by
  ## ``linkat``, which refuses a taken name (``RecordExistsError``), or with
  ## ``replace`` by ``renameat`` -- and the directory fsynced.
  let dir = parentDir(path)
  let name = extractFilename(path)
  let dfd = openCheckedDir(dir, create)
  if dfd < 0: raise newException(OSError, dir & " is absent")
  defer: discard posix.close(dfd)
  let tmp = "." & name & ".tmp-" & $getCurrentProcessId()
  unlinkAt(dfd, tmp, dir)
  let fd = openatC(dfd, tmp.cstring, O_WRONLY or O_CREAT or O_EXCL or
                   O_CLOEXEC or ONoFollow, Mode(mode))
  if fd < 0: raiseOSError(osLastError(), "create " & dir / tmp)
  var ok = false
  try:
    var off = 0
    while off < text.len:
      let n = posix.write(fd, unsafeAddr text[off], text.len - off)
      if n <= 0: raiseOSError(osLastError(), "write " & dir / tmp)
      off += n
    if fsync(fd) != 0: raiseOSError(osLastError(), "fsync " & dir / tmp)
    ok = true
  finally:
    discard posix.close(fd)
    if not ok: discard unlinkatC(dfd, tmp.cstring, 0)
  if replace:
    if renameatC(dfd, tmp.cstring, dfd, name.cstring) != 0:
      let e = errno
      discard unlinkatC(dfd, tmp.cstring, 0)
      raise newException(OSError, "rename to " & path & " failed: " &
        $strerror(e))
  else:
    if linkatC(dfd, tmp.cstring, dfd, name.cstring, 0) != 0:
      let e = errno
      discard unlinkatC(dfd, tmp.cstring, 0)
      if e == EEXIST:
        raise newException(RecordExistsError, path & " exists; a record " &
          "is never written over")
      raise newException(OSError, "link to " & path & " failed: " &
        $strerror(e))
    discard unlinkatC(dfd, tmp.cstring, 0)
  if fsync(dfd) != 0: raiseOSError(osLastError(), "fsync " & dir)

proc readRegularBounded(fd: cint; path: string): string =
  ## The bytes of the regular file open at ``fd``, at most
  ## ``MaxRecordBytes``; raises ``OSError`` for anything else.
  var st: Stat
  if fstat(fd, st) != 0 or not S_ISREG(st.st_mode):
    raise newException(OSError, path & " is not a regular file")
  var buf = newString(4096)
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n < 0: raiseOSError(osLastError(), "read " & path)
    if n == 0: break
    result.add(buf[0 ..< n])
    if result.len > MaxRecordBytes and not mutated("record-read-unbounded"):
      raise newException(OSError, path & " is larger than any record (" &
        $MaxRecordBytes & " bytes)")

proc readBoundedByPath*(path: string): string =
  ## A record an operator names on the command line (``verify-discard-
  ## record``), wherever it was copied: opened by path, but non-blocking,
  ## required to be a regular file and read up to ``MaxRecordBytes``.
  when mutated("operator-read-blocking"):
    return readFile(path)     # FALSIFIER: a blocking, unbounded read by path
  let fd = posix.open(path.cstring, O_RDONLY or O_CLOEXEC or ONonBlock)
  if fd < 0: raiseOSError(osLastError(), "open " & path)
  defer: discard posix.close(fd)
  readRegularBounded(fd, path)

proc readInCheckedDir*(path: string): string =
  ## ``path``'s bytes, read through its directory's checked descriptor
  ## without following a link; raises ``OSError`` when they cannot be.
  let dir = parentDir(path)
  let dfd = openCheckedDir(dir, create = false)
  if dfd < 0: raise newException(OSError, dir & " is absent")
  defer: discard posix.close(dfd)
  # O_NONBLOCK: a FIFO planted under the name must not block the read
  # (while uninstall holds the host apply lock); it is then refused as not
  # a regular file.
  let fd = openatC(dfd, extractFilename(path).cstring,
                   O_RDONLY or O_CLOEXEC or ONoFollow or
                   (when mutated("record-read-blocking"): 0 else: ONonBlock))
  if fd < 0: raiseOSError(osLastError(), "open " & path)
  defer: discard posix.close(fd)
  readRegularBounded(fd, path)
