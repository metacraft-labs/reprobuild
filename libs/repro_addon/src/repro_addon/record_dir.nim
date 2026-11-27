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

import std/[algorithm, os, posix, strutils, tables, times]

import ./mutations

proc openatC(dirfd: cint; path: cstring; flags: cint): cint
  {.importc: "openat", header: "<fcntl.h>", varargs.}
proc mkdiratC(dirfd: cint; path: cstring; mode: Mode): cint
  {.importc: "mkdirat", header: "<sys/stat.h>".}
proc unlinkatC(dirfd: cint; path: cstring; flags: cint): cint
  {.importc: "unlinkat", header: "<unistd.h>".}
var AtRemoveDir {.importc: "AT_REMOVEDIR", header: "<fcntl.h>".}: cint
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
  ## ``<digits>@<digits>.<digits>`` with an optional ``g<integer>``, the
  ## integer one optional ``-`` and at least one digit (A11 round 21: a
  ## lone ``-`` or ``--4`` is not a generation).
  let at = s.find('@')
  if at <= 0: return false
  if not s[0 ..< at].allCharsInSet(Digits): return false
  var rest = s[at + 1 .. ^1]
  let g = rest.find('g')
  if g >= 0:
    let gen = rest[g + 1 .. ^1]
    let digits = if gen.startsWith('-'): gen[1 .. ^1] else: gen
    if digits.len == 0 or not digits.allCharsInSet(Digits):
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
  ledgerCopy: string     ## the state's ledger copy; "" when not given

var bindings = initTable[string, DirBinding]()
  ## The records directories bound to a recorded identity (§13 decision
  ## 178, amended): the module's one piece of state, set by the verbs that
  ## use ``/var/log/repro-addon`` (bootstrap, uninstall, verify) before
  ## they touch it, and read by ``openCheckedDir``. A table keyed by path,
  ## so a test binds its own temporary directory the same way.

proc bindRecordsDir*(dir, identityFile: string; ledgerCopy = "") =
  ## Bind ``dir`` to the identity recorded in ``identityFile`` (root-only
  ## add-on state). When there is no recorded identity yet -- a host
  ## bootstrapped before §13 decision 178's amendment -- the first checked
  ## open records it (trust on first use) where ``identityFile``'s
  ## directory exists and the ledger copy ``ledgerCopy`` is present. With
  ## no identity recorded and the named ledger copy absent, the state
  ## counts as gone, whether or not the identity's directory survived (a
  ## failed rmdir, or a crash before it; A11 round 22), and ``dir`` is used
  ## with nothing to compare (``boundWithoutState``), which the caller
  ## reports; it is never recorded at first use then. With the ledger copy
  ## present and no identity directory, something removed the record, and
  ## every checked open refuses (uninstall removes the identity only after
  ## the ledger copy, A11 round 21). With no ledger copy named (a test's
  ## binding) the identity's directory decides.
  ## An identity file that is present but empty or malformed (a torn
  ## write, or one somebody else wrote) is never taken as "nothing
  ## recorded": every checked open then refuses, naming it.
  var b = DirBinding(identityFile: identityFile, ledgerCopy: ledgerCopy)
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
        elif b.expected.len == 0 and b.ledgerCopy.len > 0 and
            not (fileExists(b.ledgerCopy) or symlinkExists(b.ledgerCopy)) and
            not mutated("first-use-without-ledger-copy"):
          # No ledger copy: an uninstall removed it, then the identity,
          # whether or not the identity's directory went too (A11 round
          # 22: an rmdir that failed or a crash before it leaves that
          # directory). Never a first use: nothing is recorded, and the
          # caller reports the unbound use.
          b.stateGone = true
          bindings[dir] = b
        elif b.expected.len == 0 and not dirExists(parentDir(b.identityFile)) and
            (mutated("state-gone-from-addon-dir-alone") or
             b.ledgerCopy.len == 0 or
             not (fileExists(b.ledgerCopy) or symlinkExists(b.ledgerCopy))):
          # The state is gone (an uninstall removed its ledger copy, then
          # the identity): nothing to compare with and nowhere to record;
          # reported by the caller.
          b.stateGone = true
          bindings[dir] = b
        elif b.expected.len == 0 and not dirExists(parentDir(b.identityFile)):
          refusal = "refusing " & dir & ": the add-on's ledger copy " &
            b.ledgerCopy & " is there but the directory of its records " &
            "directory's identity (" & parentDir(b.identityFile) & ") is " &
            "not, so the identity bootstrap recorded is gone and nothing " &
            "tells " & dir & " from another directory put in its place. " &
            "Inspect " & dir & "; if it is the directory bootstrap made, " &
            "create " & parentDir(b.identityFile) & " (root's 0700) so the " &
            "next use records it again"
        elif b.expected.len == 0:
          if now.len > 0:
            # First use on a host bootstrapped before the identity was
            # recorded -- only with the ledger copy present, or where no
            # ledger copy was named (a test's binding): recorded now, atomically, 0600, durably, through
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

type RemovalNotDurableError* = object of OSError
  ## ``removeEmptyDirChecked`` removed the directory, and the fsync of its
  ## parent that would make the removal durable failed.

proc removeEmptyDirChecked*(dir: string) =
  ## Remove the empty directory ``dir`` through its parent's descriptor
  ## (``unlinkat`` with ``AT_REMOVEDIR``), then fsync the parent: what
  ## bootstrap uses to take back a directory it has just made (A11 round
  ## 22). Raises ``OSError``.
  let parent = parentDir(dir)
  let pfd = posix.open(parent.cstring, O_RDONLY or O_CLOEXEC or ODirectory)
  if pfd < 0: raiseOSError(osLastError(), "open " & parent)
  defer: discard posix.close(pfd)
  if unlinkatC(pfd, extractFilename(dir).cstring, AtRemoveDir) != 0:
    raiseOSError(osLastError(), "remove " & dir)
  if fsync(pfd) != 0:
    raise newException(RemovalNotDurableError, "fsync " & parent & ": " &
      osErrorMsg(osLastError()))

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

proc readRecordFileNoFollow*(path: string): string =
  ## ``path``'s bytes in a root-owned directory: opened ``O_NOFOLLOW`` (a
  ## link in its place is refused) and non-blocking, required to be a
  ## regular file and read up to ``MaxRecordBytes``.
  let fd = posix.open(path.cstring, O_RDONLY or O_CLOEXEC or ONoFollow or
                      ONonBlock)
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

# ---------------------------------------------------------------------------
# Entries a root writer hands to a less privileged reader (§13 decision 181).
#
# The evidence outbox belongs to the shipping unit's dynamic user: its
# state directory and the outbox in it are that user's, so the user can
# replace any name in them -- with a link to a root file, say. A root
# writer therefore reaches the outbox through descriptors only: the state
# directory by ``openat(O_DIRECTORY|O_NOFOLLOW)`` from its root-owned
# parent, the outbox and the staging directory beside it the same way from
# that, the temporary created exclusively without following a link, made
# readable to the outbox's owner on its descriptor (``fchmod`` 0644: the
# outbox is 0700 and its owner's, inside the root-only ``/var/lib/private``,
# so no one else reaches it), and renamed into place with ``renameat``. A
# writer never follows a name the reader could have planted and changes no
# owner: a confined root writer (the egress check) has no ``CAP_CHOWN``.
# ---------------------------------------------------------------------------

proc openOrMakeDirAt(pfd: cint; name, where: string; mode = 0o700): cint =
  ## ``name`` under the directory open at ``pfd``, not through a link;
  ## made with ``mode`` when absent (systemd hands the outbox to the
  ## shipping unit's user at its next start: it is one of its
  ## ``StateDirectory=``).
  result = openatC(pfd, name.cstring, O_RDONLY or ODirectory or ONoFollow or
                   O_CLOEXEC)
  if result < 0 and errno == ENOENT:
    if mkdiratC(pfd, name.cstring, Mode(mode)) != 0 and errno != EEXIST:
      raiseOSError(osLastError(), "mkdir " & where)
    result = openatC(pfd, name.cstring, O_RDONLY or ODirectory or ONoFollow or
                     O_CLOEXEC)
  if result < 0: raiseOSError(osLastError(), "open " & where)
  var st: Stat
  if fstat(result, st) != 0 or not S_ISDIR(st.st_mode):
    discard posix.close(result)
    raise newException(OSError, where & " is not a directory")

proc openDelegatedState(state: string; create: bool): cint =
  ## The state directory a root writer or reader reaches the delegated
  ## directories through. Root: by ``O_NOFOLLOW`` from its root-owned
  ## parent, opened by path (made 0700 when absent and ``create``, as
  ## /var/lib/private must be). Its own user: as named (no privilege to
  ## guard; the shipping unit reaches it through the link systemd made).
  ## -1 when it is absent and not ``create``.
  if geteuid() == 0:
    let top = parentDir(state)
    if not dirExists(top):
      if not create: return -1
      createDir(top)
      discard posix.chmod(top.cstring, Mode(0o700))
    let tfd = posix.open(top.cstring, O_RDONLY or ODirectory or O_CLOEXEC)
    if tfd < 0: raiseOSError(osLastError(), "open " & top)
    try:
      if not create:
        result = openatC(tfd, extractFilename(state).cstring,
                         O_RDONLY or ODirectory or ONoFollow or O_CLOEXEC)
        if result < 0:
          if errno == ENOENT: return -1
          raiseOSError(osLastError(), "open " & state)
      else:
        result = openOrMakeDirAt(tfd, extractFilename(state), state)
    finally:
      discard posix.close(tfd)
  else:
    if not dirExists(state):
      if not create: return -1
      createDir(state)
      discard posix.chmod(state.cstring, Mode(0o700))
    result = posix.open(state.cstring, O_RDONLY or ODirectory or O_CLOEXEC)
    if result < 0: raiseOSError(osLastError(), "open " & state)

proc listDelegatedEntries*(dir: string): seq[tuple[name: string; regular: bool]] =
  ## The entries of a delegated directory (the outbox), listed the way a
  ## root writer reaches it (``writeDelegatedEntry``): the state directory
  ## by ``O_NOFOLLOW`` from its root-owned parent, ``dir`` by ``O_NOFOLLOW``
  ## from that, enumerated on a duplicate of that descriptor, and each
  ## entry judged without following a link (``fstatat(AT_SYMLINK_NOFOLLOW)``).
  ## So the directory's owner cannot point a root reader at another
  ## directory by replacing a name with a link. Empty when ``dir`` or its
  ## state directory is absent; raises when either is not a directory.
  let sfd = openDelegatedState(parentDir(dir), create = false)
  if sfd < 0: return
  defer: discard posix.close(sfd)
  let dfd = openatC(sfd, extractFilename(dir).cstring,
                    O_RDONLY or ODirectory or ONoFollow or O_CLOEXEC)
  if dfd < 0:
    if errno == ENOENT: return
    raiseOSError(osLastError(), "open " & dir)
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

proc writeDelegatedEntry*(dir, name, bytes: string; staging = "";
                          mode = 0o600) =
  ## Write ``dir/name`` durably, readable by the owner of ``dir``'s parent
  ## (a dynamic user's state directory) when run as root, through descriptors
  ## that follow no link (see above). ``staging`` (a directory beside
  ## ``dir``) holds the temporary until the rename, so ``dir`` only ever
  ## holds complete entries; "" or a staging directory that cannot be
  ## written (a unit whose writable path is ``dir`` alone) puts the
  ## temporary inside ``dir``. ``dir``'s parent's parent is opened by path:
  ## it must be root's.
  let state = parentDir(dir)
  if staging.len > 0 and parentDir(staging) != state:
    raise newException(ValueError, staging & " is not beside " & dir)
  # Root: the state directory by O_NOFOLLOW from its root-owned parent;
  # the directory's own user: as named (``openDelegatedState``).
  let sfd = openDelegatedState(state, create = true)
  defer: discard posix.close(sfd)
  var sst: Stat
  discard fstat(sfd, sst)
  let handOver = geteuid() == 0 and sst.st_uid != 0
  # A directory root makes for the owner of the state directory must let
  # that user reach what root puts in it (0711: through, not list).
  let dfd = openOrMakeDirAt(sfd, extractFilename(dir), dir,
                            if handOver: 0o711 else: 0o700)
  defer: discard posix.close(dfd)
  var tmpDir = dfd
  var stfd: cint = -1
  if staging.len > 0:
    try:
      stfd = openOrMakeDirAt(sfd, extractFilename(staging), staging)
      tmpDir = stfd
    except OSError:
      stfd = -1
  defer:
    if stfd >= 0: discard posix.close(stfd)
  let tmp = "." & name & ".tmp-" & $getCurrentProcessId()
  discard unlinkatC(tmpDir, tmp.cstring, 0)
  var fd = openatC(tmpDir, tmp.cstring, O_WRONLY or O_CREAT or O_EXCL or
                   O_CLOEXEC or ONoFollow, Mode(mode))
  if fd < 0 and tmpDir != dfd:
    # The staging directory is not writable here: inside the outbox.
    tmpDir = dfd
    discard unlinkatC(tmpDir, tmp.cstring, 0)
    fd = openatC(tmpDir, tmp.cstring, O_WRONLY or O_CREAT or O_EXCL or
                 O_CLOEXEC or ONoFollow, Mode(mode))
  if fd < 0: raiseOSError(osLastError(), "create " & dir / tmp)
  var ok = false
  try:
    if handOver and fchmod(fd, Mode(mode or 0o044)) != 0:
      raiseOSError(osLastError(), "chmod " & dir / tmp)
    var off = 0
    while off < bytes.len:
      let n = posix.write(fd, unsafeAddr bytes[off], bytes.len - off)
      if n < 0:
        if errno == EINTR: continue
        raiseOSError(osLastError(), "write " & dir / tmp)
      off += n
    if fsync(fd) != 0: raiseOSError(osLastError(), "fsync " & dir / tmp)
    ok = true
  finally:
    discard posix.close(fd)
    if not ok: discard unlinkatC(tmpDir, tmp.cstring, 0)
  if renameatC(tmpDir, tmp.cstring, dfd, name.cstring) != 0:
    let e = osLastError()
    discard unlinkatC(tmpDir, tmp.cstring, 0)
    raiseOSError(e, "rename into " & dir / name)
  if fsync(dfd) != 0: raiseOSError(osLastError(), "fsync " & dir)

proc delegatedStateFileExists*(state, name: string): bool =
  ## Whether ``state/name`` exists (as anything: judged without following a
  ## link), ``state`` reached as ``writeDelegatedStateFile`` reaches it.
  ## False when ``state`` is absent.
  let sfd = openDelegatedState(state, create = false)
  if sfd < 0: return false
  defer: discard posix.close(sfd)
  var st: Stat
  fstatatC(sfd, name.cstring, st, AtSymlinkNoFollow) == 0

proc writeDelegatedStateFile*(state, name, bytes: string; mode = 0o600) =
  ## Write ``state/name`` durably, a file directly in a dynamic user's state
  ## directory, through descriptors that follow no link: the temporary is
  ## made ``O_EXCL|O_NOFOLLOW`` beside it, handed to the directory's owner
  ## when run as root (``fchown``: unlike an outbox entry, the owner must
  ## also replace and rewrite it), synced, and renamed over ``name``. Made
  ## (root 0700) when the directory is absent: systemd hands a state
  ## directory whose owner is not its dynamic user to that user, contents
  ## included, at the unit's next start (``StateDirectory=``,
  ## systemd.exec(5)).
  let sfd = openDelegatedState(state, create = true)
  defer: discard posix.close(sfd)
  var sst: Stat
  if fstat(sfd, sst) != 0: raiseOSError(osLastError(), "stat " & state)
  let tmp = "." & name & ".tmp-" & $getCurrentProcessId()
  discard unlinkatC(sfd, tmp.cstring, 0)
  let fd = openatC(sfd, tmp.cstring, O_WRONLY or O_CREAT or O_EXCL or
                   O_CLOEXEC or ONoFollow, Mode(mode))
  if fd < 0: raiseOSError(osLastError(), "create " & state / tmp)
  var ok = false
  try:
    if geteuid() == 0 and sst.st_uid != 0 and
        fchown(fd, sst.st_uid, sst.st_gid) != 0:
      raiseOSError(osLastError(), "chown " & state / tmp)
    var off = 0
    while off < bytes.len:
      let n = posix.write(fd, unsafeAddr bytes[off], bytes.len - off)
      if n < 0:
        if errno == EINTR: continue
        raiseOSError(osLastError(), "write " & state / tmp)
      off += n
    if fsync(fd) != 0: raiseOSError(osLastError(), "fsync " & state / tmp)
    ok = true
  finally:
    discard posix.close(fd)
    if not ok: discard unlinkatC(sfd, tmp.cstring, 0)
  if renameatC(sfd, tmp.cstring, sfd, name.cstring) != 0:
    let e = osLastError()
    discard unlinkatC(sfd, tmp.cstring, 0)
    raiseOSError(e, "rename into " & state / name)
  if fsync(sfd) != 0: raiseOSError(osLastError(), "fsync " & state)

# ---------------------------------------------------------------------------
# A root drop directory a confined root writer fills, emptied by a
# privileged step into a delegated directory (§13 decision 188: the egress
# check's entries, moved into the shipping unit's outbox).
# ---------------------------------------------------------------------------

type CrashPointKill* = object of CatchableError
  ## What a test's ``crashPointHook`` raises to stand for the process being
  ## killed at that point: code that records its own failure (a ``finally``
  ## writing a mark) lets this one through untouched, as a kill would.

var crashPointHook*: proc (point: string) {.nimcall.} = nil
  ## Tests only: called at each point a run of the drop or legacy-state move
  ## may be killed at, so a test can stop it there (by raising) and run the
  ## move again, as a host does after a crash. Nil in every build that runs
  ## on a host.

type
  DropEntry* = tuple[name: string; bytes: string]
  DropHarvest* = object
    ## What one emptying of a drop directory did.
    moved*: int              ## entries handed over and unlinked
    left*: seq[string]       ## regular entries ``take`` failed for; they
                             ## stay for the next run
    asideNames*: seq[string] ## entries moved aside unread, with why
    stuck*: seq[string]      ## entries handed over but not removed (also in
                             ## ``left``): the only ones that may now be
                             ## queued twice until a later run removes them

proc dropAsideDir*(dir: string): string =
  ## Where an entry that cannot be handed over goes: a root directory beside
  ## the drop directory, so it no longer keeps the drop directory non-empty
  ## (the path unit's ``DirectoryNotEmpty=``) and is kept for the operator.
  dir & "-rejected"

proc dropEntryNames*(dir: string; suffix = ".evr"): seq[string] =
  ## The regular ``*<suffix>`` entries of ``dir``, judged without following
  ## a link, oldest name first; empty when ``dir`` is absent or not a
  ## directory. What uninstall counts as queued besides the outbox.
  let dfd = posix.open(dir.cstring, O_RDONLY or ODirectory or ONoFollow or
                       O_CLOEXEC)
  if dfd < 0: return
  defer: discard posix.close(dfd)
  let lfd = dup(dfd)
  if lfd < 0: return
  let d = fdopendirC(lfd)
  if d == nil:
    discard posix.close(lfd)
    return
  while true:
    let ent = readdir(d)
    if ent == nil: break
    let name = $cast[cstring](addr ent.d_name)
    if name == "." or name == ".." or not name.endsWith(suffix): continue
    var st: Stat
    if fstatatC(dfd, name.cstring, st, AtSymlinkNoFollow) == 0 and
        S_ISREG(st.st_mode):
      result.add(name)
  discard closedir(d)
  result.sort()

proc moveAside(dfd: cint; dir, name: string): string =
  ## ``name`` renamed (the entry itself, never what a link names) into
  ## ``dropAsideDir(dir)``, made root 0700 beside ``dir``; "" when done,
  ## else why not, after which the entry is unlinked if it can be.
  let parent = parentDir(dir)
  let pfd = posix.open(parent.cstring, O_RDONLY or ODirectory or O_CLOEXEC)
  if pfd < 0: return "open " & parent & ": " & osErrorMsg(osLastError())
  defer: discard posix.close(pfd)
  var afd: cint
  try:
    afd = openOrMakeDirAt(pfd, extractFilename(dropAsideDir(dir)),
                          dropAsideDir(dir))
  except OSError as e:
    return e.msg
  defer: discard posix.close(afd)
  let t = getTime()
  let target = name & "." & $(t.toUnix() * 1_000_000_000 + int64(t.nanosecond))
  if renameatC(dfd, name.cstring, afd, target.cstring) != 0:
    return "rename aside: " & osErrorMsg(osLastError())
  ""

proc moveAsidePath*(path: string): string =
  ## ``path`` itself (a link, a FIFO, a file: never what a link names)
  ## renamed into ``dropAsideDir(path)`` beside it, as ``takeDropEntries``
  ## moves an entry aside; "" when done, else why not, after which it is
  ## unlinked if it can be (a directory is never unlinked here).
  let parent = parentDir(path)
  let pfd = posix.open(parent.cstring, O_RDONLY or ODirectory or O_CLOEXEC)
  if pfd < 0: return "open " & parent & ": " & osErrorMsg(osLastError())
  defer: discard posix.close(pfd)
  result = moveAside(pfd, path, extractFilename(path))
  if result.len > 0:
    discard unlinkatC(pfd, extractFilename(path).cstring, 0)

proc takeDropEntries*(dir: string; maxBytes: int; suffix = ".evr";
                      take: proc (e: DropEntry) {.closure.}): DropHarvest =
  ## Each regular ``*<suffix>`` file of ``dir`` handed to ``take`` and then
  ## unlinked, oldest name first. ``dir`` is opened ``O_NOFOLLOW`` (a link
  ## or a file in its place raises), each entry is judged without following
  ## a link and opened ``O_NOFOLLOW|O_NONBLOCK``, and read up to
  ## ``maxBytes``. Anything else -- a directory, a planted link, a FIFO, a
  ## larger file, a name that does not end in ``suffix`` -- is moved aside
  ## unread into ``dropAsideDir`` and named in ``asideNames``, so nothing
  ## keeps the drop directory non-empty for good (A11 round 26). An entry
  ## ``take`` raised for (the outbox full, say) stays for the next run and
  ## is named in ``left``; the caller counts it toward the shipping unit's
  ## backoff. Absent ``dir``: nothing.
  let dfd = posix.open(dir.cstring, O_RDONLY or ODirectory or ONoFollow or
                       O_CLOEXEC)
  if dfd < 0:
    if errno == ENOENT: return
    raiseOSError(osLastError(), "open " & dir)
  defer: discard posix.close(dfd)
  var names: seq[string]
  let lfd = dup(dfd)
  if lfd < 0: raiseOSError(osLastError(), "dup " & dir)
  let d = fdopendirC(lfd)
  if d == nil:
    discard posix.close(lfd)
    raiseOSError(osLastError(), "fdopendir " & dir)
  while true:
    let ent = readdir(d)
    if ent == nil: break
    let name = $cast[cstring](addr ent.d_name)
    if name == "." or name == "..": continue
    names.add(name)
  discard closedir(d)
  names.sort()
  var h: DropHarvest
  proc aside(name, why: string) =
    let failed = moveAside(dfd, dir, name)
    if failed.len == 0:
      h.asideNames.add(name & ": " & why & "; moved aside unread to " &
                            dropAsideDir(dir))
    else:
      discard unlinkatC(dfd, name.cstring, 0)
      h.asideNames.add(name & ": " & why & "; could not be moved aside (" &
                            failed & "), removed if it could be")
  for name in names:
    var st: Stat
    let statFlags = when mutated("egress-drop-follows-links"): 0.cint
                    else: AtSymlinkNoFollow
    if fstatatC(dfd, name.cstring, st, statFlags) != 0: continue
    if S_ISDIR(st.st_mode):
      when mutated("egress-drop-leaves-dirs"):
        continue                    # FALSIFYING BUILD: a directory stays
      else:
        aside(name, "a directory")
        continue
    var why = ""
    if not name.endsWith(suffix): why = "not a " & suffix & " entry"
    elif not S_ISREG(st.st_mode): why = "not a regular file"
    elif st.st_size > maxBytes: why = "larger than " & $maxBytes & " bytes"
    if why.len > 0:
      aside(name, why)
      continue
    var bytes = ""
    when mutated("egress-drop-follows-links"):
      # FALSIFYING BUILD: read by path, so a link planted in the
      # directory's place or under an entry's name is followed.
      try: bytes = readFile(dir / name)
      except IOError, OSError: continue
    else:
      let fd = openatC(dfd, name.cstring, O_RDONLY or O_CLOEXEC or ONoFollow or
                       ONonBlock)
      if fd < 0:
        aside(name, "cannot be opened: " & osErrorMsg(osLastError()))
        continue
      var fst: Stat
      if fstat(fd, fst) != 0 or not S_ISREG(fst.st_mode) or
          fst.st_size > maxBytes:
        discard posix.close(fd)
        aside(name, "changed while read")
        continue
      var buf = newString(4096)
      var ok = true
      while true:
        let n = posix.read(fd, addr buf[0], buf.len)
        if n < 0:
          ok = false
          break
        if n == 0: break
        bytes.add(buf[0 ..< n])
        if bytes.len > maxBytes:
          ok = false
          break
      discard posix.close(fd)
      if not ok:
        aside(name, "unreadable or grew past " & $maxBytes & " bytes")
        continue
    when mutated("legacy-move-unlinks-first"):
      # FALSIFYING BUILD: the entry is unlinked before it is handed over,
      # so a run killed between the two loses it.
      discard unlinkatC(dfd, name.cstring, 0)
      if crashPointHook != nil: crashPointHook("handed-over:" & name)
    try:
      take((name, bytes))
    except CatchableError as e:
      h.left.add(name & ": not moved (" & e.msg & "); left for the next run")
      continue
    # A run killed here leaves the entry in both places; the next run hands
    # it over again under the same name, which replaces the copy, so the
    # entry is neither lost nor queued twice.
    if crashPointHook != nil: crashPointHook("handed-over:" & name)
    when not mutated("legacy-move-unlinks-first"):
      if unlinkatC(dfd, name.cstring, 0) != 0 and errno != ENOENT:
        # Handed over and still here: the next run hands it over again, so
        # it counts as left (a shipping run must not send the copy and
        # then receive the entry a second time).
        let why = name & ": handed over but not removed (" &
          osErrorMsg(osLastError()) & "); left for the next run"
        h.left.add(why)
        h.stuck.add(why)
        continue
    if crashPointHook != nil: crashPointHook("removed:" & name)
    inc h.moved
  result = h
