## Files in a directory that only root may change, written, read and
## removed through one descriptor of that directory (ReproOS Add-On Mode
## spec §13 decisions 165 and 166; A11 code review rounds 17 and 18).
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

import std/[os, posix, strutils]

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

const AddonLogDir* = "/var/log/repro-addon"
  ## Where the add-on keeps its uninstall records: the discard intents and
  ## completions, and the state-removal token.

type
  RecordExistsError* = object of OSError
    ## The record's name is taken: a record is never written over.

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
  fd

proc checkedDirRefusal*(dir: string): string =
  ## "" when ``dir`` may hold the records, or is absent; else why not.
  try:
    let fd = openCheckedDir(dir, create = false)
    if fd >= 0: discard posix.close(fd)
    ""
  except OSError as ex: ex.msg

proc ensureCheckedDir*(dir: string) =
  ## ``dir`` created root's 0700 when absent, and checked; raises
  ## ``OSError`` when it may not hold the records.
  discard posix.close(openCheckedDir(dir, create = true))

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

proc readInCheckedDir*(path: string): string =
  ## ``path``'s bytes, read through its directory's checked descriptor
  ## without following a link; raises ``OSError`` when they cannot be.
  let dir = parentDir(path)
  let dfd = openCheckedDir(dir, create = false)
  if dfd < 0: raise newException(OSError, dir & " is absent")
  defer: discard posix.close(dfd)
  let fd = openatC(dfd, extractFilename(path).cstring,
                   O_RDONLY or O_CLOEXEC or ONoFollow)
  if fd < 0: raiseOSError(osLastError(), "open " & path)
  defer: discard posix.close(fd)
  var st: Stat
  if fstat(fd, st) != 0 or not S_ISREG(st.st_mode):
    raise newException(OSError, path & " is not a regular file")
  var buf = newString(4096)
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n < 0: raiseOSError(osLastError(), "read " & path)
    if n == 0: break
    result.add(buf[0 ..< n])
