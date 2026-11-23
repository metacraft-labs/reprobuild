## The Omarchy post-update hook as a ledger object (spec ReproOS-Add-On-Mode
## §4.3.2; threat model T48-T50, G45; milestone AR6).
##
## Generation 0 of an Omarchy base carries
## ``~<omarchyAccount>/.config/omarchy/hooks/post-update.d/90-repro-addon``
## (``generation0.omarchyHookScript``). It is the one ledger object outside
## ``/etc`` and the add-on's own roots, and the directory it lives in is
## the account's: any process running as the account can rename, replace or
## link anything there. So root never reaches it by path. Every routine
## here walks from ``/`` one component at a time with ``openat(2)`` and
## ``O_NOFOLLOW`` (a link anywhere on the way fails with ``ELOOP``) and,
## for every component *below the home directory*, checks the inode it
## opened: owned by the account or by root, and writable by nobody else
## (no group or other write bit). A component that fails either check
## refuses the write, the removal or the observation -- nothing outside the
## home is ever written or removed through a link the account planted.
##
## - ``writeOmarchyHook`` (bootstrap): creates ``post-update.d`` when it is
##   missing -- owned by the account, mode 0755, because Omarchy's own
##   ``omarchy-hook-install`` (run by migrations as the account) must still
##   be able to add hooks there -- and writes the hook as root, mode 0644,
##   under a temporary name, published with ``linkat(2)``, which never
##   replaces an existing name. It returns the ledger entries: the hook and,
##   when it created it, the directory.
## - ``removeOmarchyHook`` (uninstall): removes the hook only when the leaf
##   is still the add-on's regular file (root-owned, the ledger's digest),
##   and the directory only when the add-on created it and it is empty.
##   Anything else is left in place and reported: a link the account put at
##   the hook's path is the account's, never "the add-on's object, gone".
## - ``observeOmarchyHook`` (verify, the re-assert unit, every plan): ""
##   when the object is as the ledger records it, else what differs.
##
## The account owns the directory, so it can still delete or replace the
## hook. That is drift the next plan and the re-assert unit report, not a
## control (spec §4.3.2; threat model T49, accepted in deviation D7).
##
## The ``omarchy-hook-writer-follows-links`` mutation writes and removes by
## path with no owner checks: the falsifier of the no-follow controls of
## ``e2e_omarchy_addon_hook_uninstall``.

import std/[os, posix, strutils]

import repro_elevation/nofollow_write

import ./fingerprint
import ./generation0
import ./mutations

const
  OmarchyHookDirRel* = ".config/omarchy/hooks/post-update.d"
  OmarchyHookFileMode* = 0o644
  OmarchyHookDirMode* = 0o755
  KindFile* = "file"
  KindDir* = "dir"

type
  OmarchyHookError* = object of CatchableError
    ## The writer, the remover or the observer refused: ``component`` is the
    ## path that failed a check ("" when the failure is not a component's).
    component*: string

  OmarchyHookObject* = object
    ## One ledger object of the hook (``ledger.lcOmarchyHook``; the ledger
    ## converts): the hook file, or the ``post-update.d`` the add-on
    ## created. Kept apart from ``LedgerEntry`` so the ledger can call the
    ## observer without an import cycle.
    path*: string
    account*: string      ## the ledger entry's ``unit``
    kindHint*: string     ## ``file`` | ``dir``
    sha256*: string       ## ``file`` only
    mode*: string         ## four octal digits
    owner*: string        ## ``uid:gid``

  OmarchyHookTarget* = object
    account*: string
    uid*, gid*: int
    home*: string
    dir*: string          ## ``<home>/.config/omarchy/hooks/post-update.d``
    path*: string         ## the hook itself
    fileUid*, fileGid*: int
      ## The hook file's owner: root (``omarchyHookTarget``). Only the
      ## hermetic test, which cannot chown to root, sets its own.

var
  oDirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
  oNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  oCloExec {.importc: "O_CLOEXEC", header: "<fcntl.h>".}: cint
  atSymlinkNoFollow {.importc: "AT_SYMLINK_NOFOLLOW", header: "<fcntl.h>".}: cint
  atRemoveDir {.importc: "AT_REMOVEDIR", header: "<fcntl.h>".}: cint

proc c_openat(dirfd: cint; path: cstring; flags: cint; mode: Mode): cint
  {.importc: "openat", header: "<fcntl.h>", varargs.}
proc c_fstatat(dirfd: cint; path: cstring; st: var Stat; flags: cint): cint
  {.importc: "fstatat", header: "<sys/stat.h>".}
proc c_unlinkat(dirfd: cint; path: cstring; flags: cint): cint
  {.importc: "unlinkat", header: "<unistd.h>".}
proc c_mkdirat(dirfd: cint; path: cstring; mode: Mode): cint
  {.importc: "mkdirat", header: "<sys/stat.h>".}
proc c_fchownat(dirfd: cint; path: cstring; uid: Uid; gid: Gid; flags: cint): cint
  {.importc: "fchownat", header: "<unistd.h>".}
proc c_linkat(olddirfd: cint; oldpath: cstring; newdirfd: cint;
              newpath: cstring; flags: cint): cint
  {.importc: "linkat", header: "<unistd.h>".}

proc refuse(component, why: string) {.noreturn.} =
  var e = newException(OmarchyHookError, why)
  e.component = component
  raise e

proc omarchyHookTarget*(account: string): OmarchyHookTarget =
  ## The hook's place for ``account``, from the password database (never
  ## from ``$HOME``: spec §4.3.2). Raises ``OmarchyHookError`` for an
  ## unknown account or one with no absolute home.
  let pw = getpwnam(account.cstring)
  if pw == nil:
    refuse("", "omarchyAccount " & account & " is not in the password database")
  let home = ($pw.pw_dir).strip(leading = false, chars = {'/'})
  if home.len == 0 or not ($pw.pw_dir).isAbsolute:
    refuse("", "omarchyAccount " & account & " has no absolute home " &
      "directory ('" & $pw.pw_dir & "')")
  OmarchyHookTarget(account: account, uid: int(pw.pw_uid),
    gid: int(pw.pw_gid), home: home, dir: home & "/" & OmarchyHookDirRel,
    path: omarchyHookPath(home))

proc targetFor*(e: OmarchyHookObject): OmarchyHookTarget =
  ## The target a ledger entry was written for: its path and its account
  ## (``unit``), the account's uid read again from the password database
  ## (an account renumbered since is then still checked against its owner).
  ## A missing account leaves uid -1: only root-owned components pass.
  let pw = getpwnam(e.account.cstring)
  result.account = e.account
  result.uid = if pw == nil: -1 else: int(pw.pw_uid)
  result.gid = if pw == nil: -1 else: int(pw.pw_gid)
  if e.kindHint == KindDir:
    result.dir = e.path
    result.home = e.path[0 ..< max(0, e.path.len - OmarchyHookDirRel.len - 1)]
  else:
    result.path = e.path
    result.dir = parentDir(e.path)
    result.home = result.dir[0 ..< max(0, result.dir.len -
                                       OmarchyHookDirRel.len - 1)]

proc modeOf(st: Stat): int = int(st.st_mode) and 0o7777

proc ownerOk(st: Stat; t: OmarchyHookTarget): bool =
  ## Owned by the account or root, and writable by no one else.
  (int(st.st_uid) == 0 or (t.uid >= 0 and int(st.st_uid) == t.uid)) and
    (modeOf(st) and 0o022) == 0

proc walkDir(t: OmarchyHookTarget; createLast: bool;
             created: var bool): cint =
  ## A descriptor for ``t.dir``, opened from ``/`` one component at a time
  ## with ``O_NOFOLLOW``; each component below ``t.home`` is checked
  ## (``ownerOk``). With ``createLast``, a missing ``post-update.d`` -- and
  ## only it -- is created, owned by the account, mode 0755. Raises
  ## ``OmarchyHookError`` naming the component; ``ENOENT`` on another
  ## component is an ``OSError`` the caller reports.
  created = false
  let homeDepth = components(t.home).len
  let parts = components(t.dir)
  var fd = posix.open("/", O_RDONLY or oDirectory or oCloExec)
  if fd < 0: raiseOSError(osLastError(), "open /")
  var cur = ""
  for i, seg in parts:
    cur.add("/" & seg)
    var next = c_openat(fd, seg.cstring,
                        O_RDONLY or oDirectory or oNoFollow or oCloExec, Mode(0))
    if next < 0 and errno == ENOENT and createLast and i == parts.high:
      if c_mkdirat(fd, seg.cstring, Mode(OmarchyHookDirMode)) != 0:
        let err = osLastError()
        discard posix.close(fd)
        raiseOSError(err, "mkdir " & cur)
      created = true
      # Owned by the account: the directory is Omarchy's to add hooks to.
      if c_fchownat(fd, seg.cstring, Uid(t.uid), Gid(t.gid),
                    atSymlinkNoFollow) != 0:
        let err = osLastError()
        discard c_unlinkat(fd, seg.cstring, atRemoveDir)
        discard posix.close(fd)
        raiseOSError(err, "chown " & cur)
      next = c_openat(fd, seg.cstring,
                      O_RDONLY or oDirectory or oNoFollow or oCloExec, Mode(0))
    if next < 0:
      let err = osLastError()
      var st: Stat
      let isLink = c_fstatat(fd, seg.cstring, st, atSymlinkNoFollow) == 0 and
                   S_ISLNK(st.st_mode)
      discard posix.close(fd)
      if err == OSErrorCode(ELOOP) or isLink:
        refuse(cur, cur & " is a symbolic link; the Omarchy hook is never " &
          "written, removed or read through one (spec §4.3.2)")
      if err == OSErrorCode(ENOTDIR):
        refuse(cur, cur & " is not a directory")
      raiseOSError(err, "open directory " & cur)
    discard posix.close(fd)
    fd = next
    if i >= homeDepth:
      var st: Stat
      if fstat(fd, st) != 0:
        let err = osLastError()
        discard posix.close(fd)
        raiseOSError(err, "fstat " & cur)
      if not ownerOk(st, t):
        discard posix.close(fd)
        refuse(cur, cur & " is owned by uid " & $st.st_uid & " with mode " &
          toOct(modeOf(st), 4) & "; every directory below the home of " &
          t.account & " must be owned by that account or root and writable " &
          "by no one else (spec §4.3.2)")
  fd

proc readLeaf(dirfd: cint; leaf: string): tuple[st: Stat; bytes: string] =
  ## The leaf's ``lstat`` and, for a regular file, its bytes (opened with
  ## ``O_NOFOLLOW``). Raises ``OSError`` (ENOENT when absent).
  if c_fstatat(dirfd, leaf.cstring, result.st, atSymlinkNoFollow) != 0:
    raiseOSError(osLastError(), "stat " & leaf)
  if not S_ISREG(result.st.st_mode): return
  let fd = c_openat(dirfd, leaf.cstring, O_RDONLY or oNoFollow or oCloExec,
                    Mode(0))
  if fd < 0: raiseOSError(osLastError(), "open " & leaf)
  defer: discard posix.close(fd)
  var buf = newString(65536)
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n < 0: raiseOSError(osLastError(), "read " & leaf)
    if n == 0: break
    result.bytes.add(buf[0 ..< n])

proc writeByPath(t: OmarchyHookTarget; content: string): seq[OmarchyHookObject] =
  ## FALSIFYING MUTATION (``omarchy-hook-writer-follows-links``): the
  ## naive writer, by path, following every link, with no owner check.
  var created = false
  if not dirExists(t.dir):
    createDir(t.dir)
    created = true
  writeFile(t.path, content)
  setFilePermissions(t.path, {fpUserRead, fpUserWrite, fpGroupRead,
                              fpOthersRead})
  if created:
    result.add(OmarchyHookObject(path: t.dir, account: t.account,
      kindHint: KindDir, mode: toOct(OmarchyHookDirMode, 4),
      owner: $t.uid & ":" & $t.gid))
  result.add(OmarchyHookObject(path: t.path, account: t.account,
    kindHint: KindFile, sha256: sha256Hex(content),
    mode: toOct(OmarchyHookFileMode, 4),
    owner: $t.fileUid & ":" & $t.fileGid))

proc removeCreatedDir(t: OmarchyHookTarget): tuple[removed: bool; left: string]

proc writeOmarchyHook*(t: OmarchyHookTarget; content: string): seq[OmarchyHookObject] =
  ## Write the hook (bootstrap; spec §4.3.2): ``post-update.d`` created
  ## when missing, the hook root-owned 0644, never over an existing name.
  ## Returns the ledger objects, the directory's first. Raises
  ## ``OmarchyHookError`` (a link, an owner) or ``OSError``; a failure
  ## leaves no temporary file, and a directory it created is removed again.
  when mutated("omarchy-hook-writer-follows-links"):
    return writeByPath(t, content)
  var created = false
  let dirfd = walkDir(t, createLast = true, created)
  defer: discard posix.close(dirfd)
  let leaf = extractFilename(t.path)
  let tmp = "." & leaf & ".repro-tmp-" & $getCurrentProcessId()
  var done = false
  defer:
    if not done:
      discard c_unlinkat(dirfd, tmp.cstring, 0)
      if created:
        # Put the account's tree back as it was: the directory this call
        # created goes again (removed by name from its checked parent,
        # only while empty).
        discard removeCreatedDir(t)
  # A leftover temporary of ours (a crashed run whose PID is reused) is
  # unlinked by name, never followed.
  discard c_unlinkat(dirfd, tmp.cstring, 0)
  let fd = c_openat(dirfd, tmp.cstring,
                    O_WRONLY or O_CREAT or O_EXCL or oNoFollow or oCloExec,
                    Mode(OmarchyHookFileMode))
  if fd < 0: raiseOSError(osLastError(), "create " & t.dir & "/" & tmp)
  try:
    var off = 0
    while off < content.len:
      let n = posix.write(fd, unsafeAddr content[off], content.len - off)
      if n < 0: raiseOSError(osLastError(), "write " & t.path)
      off += n
    if fchmod(fd, Mode(OmarchyHookFileMode)) != 0:
      raiseOSError(osLastError(), "fchmod " & t.path)
    if fchown(fd, Uid(t.fileUid), Gid(t.fileGid)) != 0:
      raiseOSError(osLastError(), "fchown " & t.path)
    if fsync(fd) != 0: raiseOSError(osLastError(), "fsync " & t.path)
  finally:
    discard posix.close(fd)
  # linkat never replaces: a name the account put there meanwhile (a link,
  # a file) makes it fail with EEXIST rather than be overwritten.
  if c_linkat(dirfd, tmp.cstring, dirfd, leaf.cstring, 0) != 0:
    let err = osLastError()
    if err == OSErrorCode(EEXIST):
      refuse(t.path, t.path & " already exists; generation 0 writes the " &
        "Omarchy hook only where nothing is")
    raiseOSError(err, "link " & t.path)
  discard c_unlinkat(dirfd, tmp.cstring, 0)
  if fsync(dirfd) != 0: raiseOSError(osLastError(), "fsync " & t.dir)
  done = true
  if created:
    result.add(OmarchyHookObject(path: t.dir, account: t.account,
      kindHint: KindDir, mode: toOct(OmarchyHookDirMode, 4),
      owner: $t.uid & ":" & $t.gid))
  result.add(OmarchyHookObject(path: t.path, account: t.account,
    kindHint: KindFile, sha256: sha256Hex(content),
    mode: toOct(OmarchyHookFileMode, 4),
    owner: $t.fileUid & ":" & $t.fileGid))

proc observeOmarchyHook*(e: OmarchyHookObject): string =
  ## "" when the ledger's object is as recorded, else the difference
  ## (verify, the re-assert unit, uninstall's check). Never follows a link
  ## and never raises.
  let t = targetFor(e)
  var created = false
  var dirfd: cint = -1
  try:
    dirfd = walkDir(t, createLast = false, created)
  except OmarchyHookError as ex:
    return ex.msg
  except OSError as ex:
    if ex.errorCode == int32(ENOENT): return "missing"
    return ex.msg
  defer: discard posix.close(dirfd)
  if e.kindHint == KindDir:
    return ""      # the walk opened it as a directory and checked it
  var leaf: tuple[st: Stat; bytes: string]
  try:
    leaf = readLeaf(dirfd, extractFilename(t.path))
  except OSError as ex:
    if ex.errorCode == int32(ENOENT): return "missing"
    return ex.msg
  if S_ISLNK(leaf.st.st_mode):
    return "replaced by a symbolic link (ledger: a regular file)"
  if not S_ISREG(leaf.st.st_mode):
    return "replaced by something that is not a regular file"
  let digest = sha256Hex(leaf.bytes)
  if digest != e.sha256:
    return "content changed (sha256 " & digest[0 ..< 12] & ", ledger " &
           e.sha256[0 ..< min(12, e.sha256.len)] & ")"
  let owner = $leaf.st.st_uid & ":" & $leaf.st.st_gid
  if owner != e.owner or toOct(modeOf(leaf.st), 4) != e.mode:
    return "owner or mode changed (" & owner & " " & toOct(modeOf(leaf.st), 4) &
           ", ledger " & e.owner & " " & e.mode & ")"
  ""

proc removeByPath(e: OmarchyHookObject): tuple[removed: bool; left: string] =
  ## FALSIFYING MUTATION (``omarchy-hook-writer-follows-links``).
  if e.kindHint == KindDir:
    try:
      removeDir(e.path)
      return (true, "")
    except OSError as ex: return (false, ex.msg)
  try:
    removeFile(e.path)
    (true, "")
  except OSError as ex: (false, ex.msg)

proc removeOmarchyHook*(e: OmarchyHookObject): tuple[removed: bool; left: string] =
  ## Remove one ledger entry of the hook (uninstall). ``removed``: the
  ## add-on's object is gone (or was already). ``left``: why it was left in
  ## place -- a link, an owner, a file that is no longer the add-on's, a
  ## directory that is not empty. Never follows a link, never raises.
  when mutated("omarchy-hook-writer-follows-links"):
    return removeByPath(e)
  let t = targetFor(e)
  var created = false
  if e.kindHint == KindDir:
    return removeCreatedDir(t)
  let d = observeOmarchyHook(e)
  if d == "missing": return (true, "")
  if d.len > 0:
    return (false, d & "; left in place (it is not the add-on's object " &
      "now)")
  var dirfd: cint = -1
  try:
    dirfd = walkDir(t, createLast = false, created)
  except CatchableError as ex:
    return (false, ex.msg)
  defer: discard posix.close(dirfd)
  if c_unlinkat(dirfd, extractFilename(t.path).cstring, 0) != 0:
    if errno == ENOENT: return (true, "")
    return (false, "unlink " & t.path & ": " & $strerror(errno))
  discard fsync(dirfd)
  (true, "")

proc removeCreatedDir(t: OmarchyHookTarget): tuple[removed: bool; left: string] =
  ## Remove ``t.dir`` -- a ``post-update.d`` the add-on created -- by name
  ## from its parent, opened through the checked walk, and only while it is
  ## empty (``rmdir`` fails with ENOTEMPTY otherwise). Never raises.
  var created = false
  var parent = t
  parent.dir = parentDir(t.dir)
  var pfd: cint = -1
  try:
    pfd = walkDir(parent, createLast = false, created)
  except OmarchyHookError as ex:
    return (false, ex.msg)
  except OSError as ex:
    if ex.errorCode == int32(ENOENT): return (true, "")
    return (false, ex.msg)
  defer: discard posix.close(pfd)
  var st: Stat
  let leaf = extractFilename(t.dir)
  if c_fstatat(pfd, leaf.cstring, st, atSymlinkNoFollow) != 0:
    if errno == ENOENT: return (true, "")
    return (false, "stat " & t.dir & ": " & $strerror(errno))
  if not S_ISDIR(st.st_mode):
    return (false, t.dir & " is no longer a directory; left in place")
  if c_unlinkat(pfd, leaf.cstring, atRemoveDir) != 0:
    let err = errno
    if err == ENOTEMPTY or err == EEXIST:
      return (false, t.dir & " is not empty (the account's own hooks); " &
        "left in place")
    return (false, "rmdir " & t.dir & ": " & $strerror(err))
  discard fsync(pfd)
  (true, "")

proc omarchyHookPathProblem*(t: OmarchyHookTarget): string =
  ## Read-only, for the preflight: "" when bootstrap's writer could put the
  ## hook in place now -- every existing component from ``/`` to
  ## ``post-update.d`` a real directory, those below the home owned by the
  ## account or root and writable by no one else, and nothing at the hook's
  ## own path (not even a link) -- else why not. A missing ``post-update.d``
  ## is fine: bootstrap creates it.
  when mutated("omarchy-hook-writer-follows-links"):
    return ""
  var created = false
  var parent = t
  parent.dir = parentDir(t.dir)
  var pfd: cint = -1
  try:
    pfd = walkDir(parent, createLast = false, created)
  except OmarchyHookError as ex:
    return ex.msg
  except OSError as ex:
    return ex.msg
  defer: discard posix.close(pfd)
  var st: Stat
  let dleaf = extractFilename(t.dir)
  if c_fstatat(pfd, dleaf.cstring, st, atSymlinkNoFollow) != 0:
    if errno == ENOENT: return ""
    return "stat " & t.dir & ": " & $strerror(errno)
  var dfd: cint = -1
  try:
    dfd = walkDir(t, createLast = false, created)
  except OmarchyHookError as ex:
    return ex.msg
  except OSError as ex:
    return ex.msg
  defer: discard posix.close(dfd)
  if c_fstatat(dfd, extractFilename(t.path).cstring, st, atSymlinkNoFollow) == 0:
    return t.path & " already exists" &
      (if S_ISLNK(st.st_mode): " (a symbolic link)" else: "") &
      "; generation 0 writes the Omarchy hook only where nothing is"
  ""
