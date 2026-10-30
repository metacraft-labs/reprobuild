## Writing into the host's filesystem as root without ever following a
## symbolic link.
##
## The system-scope drivers write into ``/etc`` as root: unit files,
## drop-ins, sysctl, sysusers and tmpfiles fragments, managed
## configuration files and the add-on's own links. A path-based
## ``open(fmWrite)`` follows every link on the way -- Debian ships
## ``/etc/os-release -> ../usr/lib/os-release``, and anyone who can plant
## a link on a managed path redirects the write (ReproOS Add-On Mode
## threat model T34, G29). Checking the path's *text* first does not
## help: the check and the open resolve the path twice.
##
## So nothing here resolves a path as a whole. Every routine walks the
## directory components one ``openat(2)`` at a time with ``O_NOFOLLOW``
## (a link component fails with ``ELOOP``), refuses a leaf that is a link
## where a file is expected, creates the new inode next to the leaf under
## a temporary name relative to the directory descriptor, and
## ``renameat(2)``s it over the leaf. ``rename`` replaces a link at the
## destination rather than writing through it, so even a link planted
## between the leaf check and the rename cannot redirect the bytes.
##
## ``symlinkComponent`` is the read-only half: the add-on's collision
## observer uses it at plan time and again before each write to name a
## link on a target path, so a plan that would write through one is
## refused before anything is written.
##
## This module was ``repro_addon/etc_write`` (A3); it moved here so the
## drivers in this library can use it (A4), and ``repro_addon/etc_write``
## re-exports it.

import std/[os, posix, strutils]

const NoFollowMutation {.strdefine: "reproAddonMutation".} = ""
  ## The add-on's compile-time falsifying mutations (``repro_addon/
  ## mutations``): ``nofollow-write-skips-fsync`` builds this writer
  ## without its fsyncs, so the crash gate can show it detects their loss.
const SkipsFsync = NoFollowMutation == "nofollow-write-skips-fsync"


type
  NoFollowError* = object of CatchableError
  SymlinkOnPath* = object of NoFollowError
    ## A component of the target path (the leaf included) is a symbolic
    ## link. ``link`` is that component's path.
    link*: string

var
  oDirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
  oNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  oCloExec {.importc: "O_CLOEXEC", header: "<fcntl.h>".}: cint
  atSymlinkNoFollow {.importc: "AT_SYMLINK_NOFOLLOW", header: "<fcntl.h>".}: cint
  atRemoveDir {.importc: "AT_REMOVEDIR", header: "<fcntl.h>".}: cint

proc c_openat(dirfd: cint; path: cstring; flags: cint; mode: Mode): cint
  {.importc: "openat", header: "<fcntl.h>", varargs.}
proc c_renameat(olddirfd: cint; oldpath: cstring; newdirfd: cint;
                newpath: cstring): cint
  {.importc: "renameat", header: "<stdio.h>".}
proc c_fstatat(dirfd: cint; path: cstring; st: var Stat; flags: cint): cint
  {.importc: "fstatat", header: "<sys/stat.h>".}
proc c_unlinkat(dirfd: cint; path: cstring; flags: cint): cint
  {.importc: "unlinkat", header: "<unistd.h>".}
proc c_symlinkat(target: cstring; newdirfd: cint; linkpath: cstring): cint
  {.importc: "symlinkat", header: "<unistd.h>".}
proc c_mkdirat(dirfd: cint; path: cstring; mode: Mode): cint
  {.importc: "mkdirat", header: "<sys/stat.h>".}
proc c_readlinkat(dirfd: cint; path: cstring; buf: cstring; size: csize_t): int
  {.importc: "readlinkat", header: "<unistd.h>".}

proc components*(path: string): seq[string] =
  ## The non-empty path segments of an absolute, normalised path.
  if not path.isAbsolute:
    raise newException(NoFollowError, "not an absolute path: " & path)
  for seg in path.split('/'):
    if seg.len == 0 or seg == ".":
      continue
    if seg == "..":
      raise newException(NoFollowError, "path contains '..': " & path)
    result.add(seg)
  if result.len == 0:
    raise newException(NoFollowError, "the root directory is not a file: " & path)

proc symlinkComponent*(path: string): string =
  ## The first component of ``path`` (the leaf included) that is a
  ## symbolic link, or "" when no existing component is one. Components
  ## that do not exist yet are not links. Read-only.
  var cur = ""
  for seg in components(path):
    cur.add("/" & seg)
    var st: Stat
    if lstat(cur.cstring, st) != 0:
      return ""                      # nothing beyond this exists yet
    if S_ISLNK(st.st_mode):
      return cur

proc raiseSymlinkOnPath(link: string) =
  var e = newException(SymlinkOnPath,
    "refusing to write through a symbolic link: " & link)
  e.link = link
  raise e

proc openDirNoFollow*(path: string): cint =
  ## A descriptor for the directory ``path``, opened one component at a
  ## time with ``O_NOFOLLOW``. Raises ``SymlinkOnPath`` naming the first
  ## link met, or ``NoFollowError`` for a component that is not a
  ## directory. The caller closes it.
  var fd = posix.open("/", O_RDONLY or oDirectory or oCloExec)
  if fd < 0:
    raiseOSError(osLastError(), "open /")
  var cur = ""
  for seg in components(path):
    cur.add("/" & seg)
    let next = c_openat(fd, seg.cstring,
                        O_RDONLY or oDirectory or oNoFollow or oCloExec, Mode(0))
    if next < 0:
      let err = osLastError()
      discard posix.close(fd)
      if err == OSErrorCode(ELOOP) or symlinkExists(cur):
        raiseSymlinkOnPath(cur)
      raiseOSError(err, "open directory " & cur)
    discard posix.close(fd)
    fd = next
  fd

proc createDirsNoFollow*(path: string; mode = 0o755) =
  ## ``mkdir -p`` that never follows a link: each missing component is
  ## created with ``mkdirat`` relative to the descriptor of the component
  ## before it, and an existing component that is a link is refused with
  ## ``SymlinkOnPath``. Idempotent.
  var fd = posix.open("/", O_RDONLY or oDirectory or oCloExec)
  if fd < 0:
    raiseOSError(osLastError(), "open /")
  defer: discard posix.close(fd)
  var cur = ""
  for seg in components(path):
    cur.add("/" & seg)
    var next = c_openat(fd, seg.cstring,
                        O_RDONLY or oDirectory or oNoFollow or oCloExec, Mode(0))
    if next < 0:
      let err = osLastError()
      if err == OSErrorCode(ELOOP) or symlinkExists(cur):
        raiseSymlinkOnPath(cur)
      if err != OSErrorCode(ENOENT):
        raiseOSError(err, "open directory " & cur)
      if c_mkdirat(fd, seg.cstring, Mode(mode)) != 0:
        if osLastError() != OSErrorCode(EEXIST):
          raiseOSError(osLastError(), "mkdir " & cur)
      else:
        # The new directory's entry is durable only once its parent is
        # synced; a file later written inside it would otherwise survive a
        # power cut in a directory that did not.
        when not SkipsFsync:
          if fsync(fd) != 0:
            raiseOSError(osLastError(), "fsync the parent of " & cur)
      next = c_openat(fd, seg.cstring,
                      O_RDONLY or oDirectory or oNoFollow or oCloExec, Mode(0))
      if next < 0:
        let again = osLastError()
        if again == OSErrorCode(ELOOP) or symlinkExists(cur):
          raiseSymlinkOnPath(cur)
        raiseOSError(again, "open directory " & cur)
    discard posix.close(fd)
    fd = next

type
  LeafKind* = enum
    lkAbsent, lkFile, lkLink, lkDir, lkOther

proc statLeaf(dirfd: cint; leaf: string): tuple[kind: LeafKind; mode: int] =
  var st: Stat
  if c_fstatat(dirfd, leaf.cstring, st, atSymlinkNoFollow) != 0:
    return (lkAbsent, 0)
  let mode = int(st.st_mode) and 0o7777
  if S_ISLNK(st.st_mode): (lkLink, mode)
  elif S_ISDIR(st.st_mode): (lkDir, mode)
  elif S_ISREG(st.st_mode): (lkFile, mode)
  else: (lkOther, mode)

proc leafNoFollow*(path: string): tuple[kind: LeafKind; mode: int] =
  ## What the leaf of ``path`` is, observed through a no-follow walk of
  ## its directory (so a link component on the way is ``SymlinkOnPath``,
  ## never silently resolved).
  let parts = components(path)
  let dirfd = openDirNoFollow(parentDir(path))
  defer: discard posix.close(dirfd)
  statLeaf(dirfd, parts[^1])

proc tmpName(leaf: string): string =
  "." & leaf & ".repro-tmp-" & $getCurrentProcessId()

proc syncDir(dirfd: cint; what: string) =
  ## Make a rename (or unlink) in the directory behind ``dirfd`` durable.
  ## ``rename(2)`` is atomic but not durable: until the directory itself
  ## is synced, a power loss can bring back the old name even though a
  ## later write in ANOTHER directory survived. The add-on's crash record
  ## (the pending marker under ``/var/lib``) and the switch it describes
  ## (the flip under ``/etc``) live in different directories, so without
  ## this they can disagree after a power cut. See fsync(2), "Calling
  ## fsync() does not necessarily ensure that the entry in the directory
  ## containing the file has also reached disk".
  when SkipsFsync: return
  if fsync(dirfd) != 0:
    raiseOSError(osLastError(), "fsync directory of " & what)

proc writeFileNoFollow*(path, content: string; mode: int;
                        uid = -1; gid = -1) =
  ## Write ``content`` to ``path`` atomically, never through a link (see
  ## the module header). ``mode`` is the final mode; ``uid``/``gid`` set
  ## the owner when non-negative. The parent directory must exist. Raises
  ## ``SymlinkOnPath`` for a link anywhere on the path, ``OSError`` for
  ## any other failure; a failure leaves no temporary file behind.
  let parts = components(path)
  let leaf = parts[^1]
  let dirfd = openDirNoFollow(parentDir(path))
  defer: discard posix.close(dirfd)
  # The leaf itself: a link is refused by name, before any write.
  let (kind, _) = statLeaf(dirfd, leaf)
  if kind == lkLink:
    raiseSymlinkOnPath(path)
  if kind == lkDir:
    raise newException(NoFollowError, path & " is a directory")
  let tmp = tmpName(leaf)
  # A leftover of a run that crashed between creating and renaming its
  # temporary file would make the exclusive create below fail forever once
  # the PID is reused. It is ours by name (the leaf's own temporary), so
  # it goes; a link at that name is unlinked, never followed.
  discard c_unlinkat(dirfd, tmp.cstring, 0)
  let fd = c_openat(dirfd, tmp.cstring,
                    O_WRONLY or O_CREAT or O_EXCL or oNoFollow or oCloExec,
                    Mode(mode))
  if fd < 0:
    raiseOSError(osLastError(), "create " & parentDir(path) / tmp)
  var committed = false
  defer:
    if not committed:
      discard c_unlinkat(dirfd, tmp.cstring, 0)
  try:
    var off = 0
    while off < content.len:
      let n = posix.write(fd, unsafeAddr content[off], content.len - off)
      if n < 0:
        raiseOSError(osLastError(), "write " & path)
      off += n
    if fchmod(fd, Mode(mode)) != 0:
      raiseOSError(osLastError(), "fchmod " & path)
    if uid >= 0 or gid >= 0:
      if fchown(fd, Uid(uid), Gid(gid)) != 0:
        raiseOSError(osLastError(), "fchown " & path)
    when not SkipsFsync:
      if fsync(fd) != 0:
        raiseOSError(osLastError(), "fsync " & path)
  finally:
    discard posix.close(fd)
  if c_renameat(dirfd, tmp.cstring, dirfd, leaf.cstring) != 0:
    raiseOSError(osLastError(), "rename " & tmp & " -> " & path)
  committed = true
  syncDir(dirfd, path)

proc replaceWithLinkNoFollow*(path, target: string) =
  ## Make ``path`` a symbolic link to ``target`` atomically: the link is
  ## created under a temporary name relative to the parent directory's
  ## descriptor and renamed over the leaf, so the leaf changes from its
  ## old inode (a file, an older link, nothing) to the new link in one
  ## ``rename``. A link component on the way is ``SymlinkOnPath``. This
  ## is the add-on's link materialisation and its ``/etc/repro/static``
  ## flip (ReproOS Add-On Mode §7.2 steps 3 and 4).
  let parts = components(path)
  let leaf = parts[^1]
  let dirfd = openDirNoFollow(parentDir(path))
  defer: discard posix.close(dirfd)
  let (kind, _) = statLeaf(dirfd, leaf)
  if kind == lkDir:
    raise newException(NoFollowError, path & " is a directory")
  let tmp = tmpName(leaf)
  discard c_unlinkat(dirfd, tmp.cstring, 0)   # a leftover of a crashed run
  if c_symlinkat(target.cstring, dirfd, tmp.cstring) != 0:
    raiseOSError(osLastError(), "symlink " & parentDir(path) / tmp)
  if c_renameat(dirfd, tmp.cstring, dirfd, leaf.cstring) != 0:
    let err = osLastError()
    discard c_unlinkat(dirfd, tmp.cstring, 0)
    raiseOSError(err, "rename " & tmp & " -> " & path)
  syncDir(dirfd, path)

proc removeLeafNoFollow*(path: string): bool =
  ## Remove the file or link at ``path`` (a dangling link included)
  ## without following anything; false when there was nothing. A
  ## directory leaf is refused (``NoFollowError``): the caller removes
  ## directories deliberately, with ``removeEmptyDirNoFollow``.
  let parts = components(path)
  let leaf = parts[^1]
  let dirfd = openDirNoFollow(parentDir(path))
  defer: discard posix.close(dirfd)
  let (kind, _) = statLeaf(dirfd, leaf)
  case kind
  of lkAbsent: return false
  of lkDir: raise newException(NoFollowError, path & " is a directory")
  else: discard
  if c_unlinkat(dirfd, leaf.cstring, 0) != 0:
    if osLastError() == OSErrorCode(ENOENT): return false
    raiseOSError(osLastError(), "unlink " & path)
  # The removal of the add-on's pending marker is the switch's last act;
  # it must not come back after a power cut.
  syncDir(dirfd, path)
  true

type
  LinkRemoval* = enum
    lrRemoved      ## the link was there, pointing at ``target``: removed
    lrAbsent       ## nothing was there
    lrDifferent    ## something else is there (a file, a directory, a link
                   ## elsewhere): left untouched

proc removeLinkIfTarget*(path, target: string): LinkRemoval =
  ## Unlink the symbolic link at ``path`` only while it still points at
  ## ``target``, relative to its parent's descriptor and without following
  ## anything on the way. Anything else at the path is someone else's and
  ## is left exactly as it is. Raises on any other failure.
  let parts = components(path)
  let leaf = parts[^1]
  let dirfd = openDirNoFollow(parentDir(path))
  defer: discard posix.close(dirfd)
  let (kind, _) = statLeaf(dirfd, leaf)
  case kind
  of lkAbsent: return lrAbsent
  of lkLink: discard
  else: return lrDifferent
  var buf = newString(4096)
  let n = c_readlinkat(dirfd, leaf.cstring, buf.cstring, csize_t(buf.len))
  if n < 0:
    if osLastError() == OSErrorCode(ENOENT): return lrAbsent
    raiseOSError(osLastError(), "readlink " & path)
  buf.setLen(n)
  if buf != target:
    return lrDifferent
  if c_unlinkat(dirfd, leaf.cstring, 0) != 0:
    if osLastError() == OSErrorCode(ENOENT): return lrAbsent
    raiseOSError(osLastError(), "unlink " & path)
  lrRemoved

proc removeEmptyDirNoFollow*(path: string): bool =
  ## ``rmdir`` the leaf of ``path`` without following a link on the way;
  ## false when it is absent or not empty.
  let parts = components(path)
  let leaf = parts[^1]
  let dirfd = openDirNoFollow(parentDir(path))
  defer: discard posix.close(dirfd)
  let (kind, _) = statLeaf(dirfd, leaf)
  if kind != lkDir: return false
  if c_unlinkat(dirfd, leaf.cstring, atRemoveDir) != 0:
    let err = osLastError()
    if err == OSErrorCode(ENOTEMPTY) or err == OSErrorCode(EEXIST) or
        err == OSErrorCode(ENOENT):
      return false
    raiseOSError(err, "rmdir " & path)
  true

proc readLinkNoFollow*(path: string): string =
  ## The target of the link at ``path``, read relative to its parent's
  ## descriptor; "" when the leaf is not a link.
  let parts = components(path)
  let leaf = parts[^1]
  let dirfd = openDirNoFollow(parentDir(path))
  defer: discard posix.close(dirfd)
  var buf = newString(4096)
  let n = c_readlinkat(dirfd, leaf.cstring, buf.cstring, csize_t(buf.len))
  if n < 0:
    return ""
  buf.setLen(n)
  buf
