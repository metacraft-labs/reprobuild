## Atomic, durable replacement of a small record file or a symlink.
##
## For records that are the only copy of what they record, such as a
## generation pointer, the `current` marker, or anything else Reprobuild
## cannot produce again from its inputs. Replacing such a record must leave
## either the previous version or the new one in place, never neither and
## never a truncated file, whether the writer is killed or the machine loses
## power:
##
## - The new content goes to a temporary file in the destination's own
##   directory. That file is flushed and synced (`F_FULLFSYNC` on macOS,
##   `FlushFileBuffers` on Windows) before anything else happens.
## - The temporary file is then renamed over the destination. The old
##   destination is never removed first: that would open a window in which
##   the record does not exist, and a crash inside that window loses it.
##   POSIX `rename(2)` replaces atomically
##   (https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html).
##   On Windows the rename is `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING |
##   MOVEFILE_WRITE_THROUGH`, which returns only once the rename is on disk
##   (https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw).
## - On POSIX the directory is synced afterwards, because a rename is a
##   directory-entry update and is durable only once the directory is
##   (https://man7.org/linux/man-pages/man2/fsync.2.html, "Calling fsync()
##   does not necessarily ensure that the entry in the directory containing
##   the file has also reached disk").
##
## Each temporary name is unique per call (pid, a per-process counter and a
## timestamp), so two concurrent writers of one destination never share a
## temporary file and cannot rename each other's half-written bytes into
## place. A failure removes the temporary file and raises; the destination
## is then unchanged.
##
## The policy that requires this is reprobuild-pm
## `spec/Configuration-Storage-Principles.md` §"Authoritative Operational
## State".

import std/[os, times, atomics, strutils]

when defined(windows):
  import std/winlean
else:
  from std/posix import nil

from ./paths import extendedPath

var durableTempCounter: Atomic[int]
  ## With the pid and a nanosecond stamp, makes every temporary name unique
  ## across processes and across the threads of one process.

proc durableTempPath(dest: string): string =
  ## A fresh temporary path beside ``dest``. It starts with ``.`` and ends in
  ## ``.tmp`` so a directory listing can recognise and skip it.
  let now = getTime()
  let (dir, name) = splitPath(dest)
  dir / ("." & name & "." & $getCurrentProcessId() & "-" &
    $(durableTempCounter.fetchAdd(1) + 1) & "-" & $now.toUnix() &
    $now.nanosecond & ".tmp")

when not defined(windows):
  proc c_rename(oldpath, newpath: cstring): cint {.
    importc: "rename", header: "<stdio.h>".}
    ## rename(2), declared by C's <stdio.h>. Called directly rather than
    ## through `os.moveFile`, which falls back to copy-and-delete across
    ## devices; a non-atomic fallback is exactly what this module must not do.

  when defined(macosx):
    # <fcntl.h>: plain fsync(2) on macOS hands the data to the drive, whose
    # cache can still lose it on power loss; F_FULLFSYNC asks the drive to
    # flush as well.
    # https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html
    const F_FULLFSYNC = cint(51)

  proc syncFd(fd: cint): bool =
    when defined(macosx):
      # Not every filesystem supports F_FULLFSYNC (some network mounts do
      # not); fall back to fsync rather than failing the write.
      if posix.fcntl(fd, F_FULLFSYNC) == 0:
        return true
    posix.fsync(fd) == 0

proc syncDirectoryDurably*(dir: string) =
  ## Make a rename or unlink inside ``dir`` durable. On POSIX this fsyncs the
  ## directory. It is best effort: a filesystem that cannot fsync a directory
  ## (some return EINVAL) still performed the atomic rename. On Windows it
  ## does nothing; there a rename is made durable by `MOVEFILE_WRITE_THROUGH`
  ## instead, since user code cannot fsync a directory handle.
  when not defined(windows):
    let fd = posix.open(cstring(extendedPath(dir)), posix.O_RDONLY)
    if fd < 0:
      return
    discard syncFd(fd)
    discard posix.close(fd)

proc writeSyncedFile(path: string; data: pointer; len: int) =
  ## Create ``path`` (a fresh temporary file), write the ``len`` bytes at
  ## ``data``, flush and sync it. Raises on any failure.
  var f: File
  if not open(f, extendedPath(path), fmWrite):
    raise newException(IOError, "cannot open '" & path & "' for writing: " &
      osErrorMsg(osLastError()))
  try:
    if len > 0 and f.writeBuffer(data, len) != len:
      raise newException(IOError, "short write to '" & path & "'")
    f.flushFile()
    when defined(windows):
      if flushFileBuffers(Handle(getOsFileHandle(f))) == 0:
        raise newException(IOError, "FlushFileBuffers of '" & path &
          "' failed: " & osErrorMsg(osLastError()))
    else:
      if not syncFd(getFileHandle(f)):
        raise newException(IOError, "fsync of '" & path & "' failed: " &
          osErrorMsg(osLastError()))
  finally:
    f.close()

proc renameOver(src, dest: string) =
  ## Rename ``src`` over ``dest`` in one step, replacing ``dest`` if it
  ## exists. Never removes ``dest`` first.
  when defined(windows):
    let wsrc = newWideCString(extendedPath(src))
    let wdst = newWideCString(extendedPath(dest))
    if moveFileExW(wsrc, wdst,
        MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) == 0:
      raiseOSError(osLastError(), "rename '" & src & "' -> '" & dest & "'")
  else:
    if c_rename(cstring(extendedPath(src)), cstring(extendedPath(dest))) != 0:
      raiseOSError(osLastError(), "rename '" & src & "' -> '" & dest & "'")

proc replaceFileDurablyImpl(dest: string; data: pointer; len: int;
                            tmpPath: string; keepMode: bool;
                            mode: set[FilePermission]) =
  let tmp = if tmpPath.len > 0: tmpPath else: durableTempPath(dest)
  try:
    writeSyncedFile(tmp, data, len)
    if mode != {}:
      # Set before the rename, so the file is never visible under ``dest``
      # without the mode it is meant to have (an executable launcher that
      # is briefly not executable). POSIX only: on Windows the permission
      # set maps to the read-only attribute alone.
      when not defined(windows):
        setFilePermissions(extendedPath(tmp), mode)
    elif keepMode and fileExists(extendedPath(dest)):
      # The rename installs the temporary file's inode, whose mode came from
      # the umask; a file the user made private (or executable) keeps its
      # mode only if it is copied onto the new inode before it goes live.
      setFilePermissions(extendedPath(tmp),
        getFilePermissions(extendedPath(dest)))
    renameOver(tmp, dest)
  except CatchableError:
    try: removeFile(extendedPath(tmp))
    except CatchableError: discard
    raise
  syncDirectoryDurably(parentDir(dest))

proc replaceFileDurably*(dest, content: string; tmpPath = "";
                         keepMode = false; mode: set[FilePermission] = {}) =
  ## Replace (or create) the file ``dest`` with ``content`` atomically and
  ## durably; see the module documentation. ``dest``'s directory must exist.
  ## Raises `IOError` / `OSError` on failure, leaving ``dest`` unchanged.
  ##
  ## ``tmpPath``, when given, is the temporary file to write; it must be in
  ## ``dest``'s directory and unique to this write. A store whose listing
  ## skips its own temporary names passes one; everyone else omits it and
  ## gets ``.<name>.<unique>.tmp``, which `removeStaleDurableTemps` sweeps.
  ##
  ## ``keepMode`` gives the new file the permission bits of the file it
  ## replaces (when there is one), for a file a user owns and edits too.
  ##
  ## ``mode``, when not empty, is the permission set the new file gets
  ## before it is renamed into place; it takes precedence over
  ## ``keepMode``, which it disables. A generated executable passes it. On
  ## Windows, where the set would map only to the read-only attribute, it
  ## is ignored.
  let data = if content.len > 0: unsafeAddr content[0] else: nil
  replaceFileDurablyImpl(dest, data, content.len, tmpPath, keepMode, mode)

proc replaceFileDurably*(dest: string; content: openArray[byte];
                         tmpPath = ""; keepMode = false;
                         mode: set[FilePermission] = {}) =
  ## `replaceFileDurably` for binary content.
  let data = if content.len > 0: unsafeAddr content[0] else: nil
  replaceFileDurablyImpl(dest, data, content.len, tmpPath, keepMode, mode)

const DefaultStaleDurableTempAge* = initDuration(hours = 1)
  ## A live write holds its temporary file for one small write, a sync and a
  ## rename: milliseconds. One an hour old belongs to a writer that died
  ## between creating it and renaming it.

proc removeStaleDurableTemps*(dest: string;
                              maxAge = DefaultStaleDurableTempAge): int =
  ## Remove the temporary files that crashed writes of ``dest`` left beside
  ## it (``.<name>.<unique>.tmp``, files or symlinks), when they are older
  ## than ``maxAge``. Younger ones may belong to a write in progress and are
  ## kept. Never touches ``dest`` itself or any other name. Returns how many
  ## were removed; a temporary that cannot be inspected or removed is left
  ## for the next sweep.
  let (dir, name) = splitPath(dest)
  let prefix = "." & name & "."
  if not dirExists(extendedPath(dir)):
    return 0
  for kind, path in walkDir(extendedPath(dir)):
    if kind notin {pcFile, pcLinkToFile, pcLinkToDir}:
      continue
    let fn = extractFilename(path)
    if not (fn.len > prefix.len + ".tmp".len and fn.startsWith(prefix) and
            fn.endsWith(".tmp")):
      continue
    try:
      # The link's own time, not its target's: a temporary symlink points at
      # a generation directory that may be old.
      let info = getFileInfo(path, followSymlink = false)
      if getTime() - info.lastWriteTime > maxAge:
        removeFile(path)
        inc result
    except CatchableError:
      discard

when not defined(windows):
  proc replaceSymlinkDurably*(link, target: string) =
    ## Point the symlink ``link`` at ``target`` atomically and durably: a new
    ## symlink is created under a temporary name beside ``link`` and renamed
    ## over it, then the directory is synced. A reader sees the old target or
    ## the new one, never a missing link. Also replaces a regular file at
    ## ``link``. Raises `OSError` on failure, leaving ``link`` unchanged.
    let tmp = durableTempPath(link)
    try:
      createSymlink(extendedPath(target), extendedPath(tmp))
      renameOver(tmp, link)
    except CatchableError:
      try: removeFile(extendedPath(tmp))
      except CatchableError: discard
      raise
    syncDirectoryDurably(parentDir(link))
