## Writing a file as root without ever following a symbolic link.
##
## The add-on writes into ``/etc`` as root: it restores the bytes a
## reconciled, replaced or adopted object had before the add-on touched
## it, and it keeps its ledger under ``/var/lib/repro``. A path-based
## ``open(fmWrite)`` follows every link on the way -- Debian ships
## ``/etc/os-release -> ../usr/lib/os-release``, and anyone who can plant
## a link on a managed path redirects the write (threat model T34, G29).
## Checking the path's *text* first does not help: the check and the open
## resolve the path twice.
##
## So the write here never resolves a path as a whole. It walks the
## directory components one ``openat(2)`` at a time with ``O_NOFOLLOW``
## (a link component fails with ``ELOOP``), refuses a leaf that is a link,
## creates a temporary file next to the leaf with
## ``O_CREAT|O_EXCL|O_NOFOLLOW`` relative to the directory descriptor,
## writes and syncs it, sets its mode and owner on the descriptor, and
## ``renameat(2)``s it over the leaf. ``rename`` replaces a link at the
## destination rather than writing through it, so even a link planted
## between the leaf check and the rename cannot redirect the bytes.
##
## ``symlinkComponent`` is the read-only half: the collision observer uses
## it at plan time and again before each write to name a link on a target
## path, so a plan that would write through one is refused before anything
## is written.

import std/[os, posix, strutils]

type
  EtcWriteError* = object of CatchableError
  SymlinkOnPath* = object of EtcWriteError
    ## A component of the target path (the leaf included) is a symbolic
    ## link. ``link`` is that component's path.
    link*: string

var
  oDirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
  oNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  oCloExec {.importc: "O_CLOEXEC", header: "<fcntl.h>".}: cint
  atSymlinkNoFollow {.importc: "AT_SYMLINK_NOFOLLOW", header: "<fcntl.h>".}: cint

proc c_openat(dirfd: cint; path: cstring; flags: cint; mode: Mode): cint
  {.importc: "openat", header: "<fcntl.h>", varargs.}
proc c_renameat(olddirfd: cint; oldpath: cstring; newdirfd: cint;
                newpath: cstring): cint
  {.importc: "renameat", header: "<stdio.h>".}
proc c_fstatat(dirfd: cint; path: cstring; st: var Stat; flags: cint): cint
  {.importc: "fstatat", header: "<sys/stat.h>".}
proc c_unlinkat(dirfd: cint; path: cstring; flags: cint): cint
  {.importc: "unlinkat", header: "<unistd.h>".}

proc components(path: string): seq[string] =
  ## The non-empty path segments of an absolute, normalised path.
  if not path.isAbsolute:
    raise newException(EtcWriteError, "not an absolute path: " & path)
  for seg in path.split('/'):
    if seg.len == 0 or seg == ".":
      continue
    if seg == "..":
      raise newException(EtcWriteError, "path contains '..': " & path)
    result.add(seg)
  if result.len == 0:
    raise newException(EtcWriteError, "the root directory is not a file: " & path)

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

proc openDirNoFollow(path: string): cint =
  ## A descriptor for the directory ``path``, opened one component at a
  ## time with ``O_NOFOLLOW``. Raises ``SymlinkOnPath`` naming the first
  ## link met, or ``EtcWriteError`` for a component that is not a
  ## directory.
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
        var e = newException(SymlinkOnPath,
          "refusing to write through a symbolic link: " & cur)
        e.link = cur
        raise e
      raiseOSError(err, "open directory " & cur)
    discard posix.close(fd)
    fd = next
  fd

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
  var st: Stat
  if c_fstatat(dirfd, leaf.cstring, st, atSymlinkNoFollow) == 0:
    if S_ISLNK(st.st_mode):
      var e = newException(SymlinkOnPath,
        "refusing to write through a symbolic link: " & path)
      e.link = path
      raise e
    if S_ISDIR(st.st_mode):
      raise newException(EtcWriteError, path & " is a directory")
  let tmp = "." & leaf & ".repro-addon-" & $getCurrentProcessId()
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
    if fsync(fd) != 0:
      raiseOSError(osLastError(), "fsync " & path)
  finally:
    discard posix.close(fd)
  if c_renameat(dirfd, tmp.cstring, dirfd, leaf.cstring) != 0:
    raiseOSError(osLastError(), "rename " & tmp & " -> " & path)
  committed = true

proc parseOwner*(owner: string): tuple[uid, gid: int] =
  ## ``uid:gid`` as the ledger and the fingerprint spell it.
  let parts = owner.split(':')
  if parts.len != 2:
    raise newException(EtcWriteError, "malformed owner: " & owner)
  (parseInt(parts[0]), parseInt(parts[1]))
