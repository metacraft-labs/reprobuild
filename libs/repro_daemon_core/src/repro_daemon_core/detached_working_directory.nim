## The working directory of a long-lived process that `repro` starts detached
## from itself: the per-user `repro-daemon`, the auto-started `runquotad`, the
## development store daemon.
##
## ONE RULE, IN ONE PLACE. Each of these processes outlives the `repro` that
## started it, so the directory it starts in stays its current directory for
## its whole life. Two directories must never be that directory:
##
## * THE CALLER'S. Windows refuses to delete a directory that is some
##   process's current directory, so a daemon started from a CMake
##   `TryCompile-<id>` scratch directory kept it undeletable until it exited.
##   On POSIX the delete succeeds, but the
##   daemon keeps the file system busy (no unmount) and lives in a deleted
##   directory.
## * THE DIRECTORY ITS IMAGE IS IN (an install's `bin\`). Windows also refuses
##   to RENAME a directory that is some process's current directory: the
##   current-directory handle is opened without `FILE_SHARE_DELETE`. The
##   running image itself does not pin its directory, because the loader maps
##   images with `FILE_SHARE_DELETE`, which is what lets an installer rename
##   the old `bin\` aside and leave the old daemon running from it. Neither
##   an installer nor `repro` may kill that daemon instead, because killing
##   it ends the leases it holds; it exits once asked to retire and idle.
##   A daemon whose current directory was `bin\` made that rename fail, so
##   every in-place bundle upgrade failed while the daemon lived.
##
## WHAT IS CHOSEN.
##
## * A process that OWNS a state directory (the `repro-daemon`: its lock,
##   session records and staged dev image live there) runs in it. Nobody can
##   remove it under the daemon without breaking the daemon anyway, so pinning
##   it takes nothing from anyone. It is accepted only when it lies outside
##   the image's directory; a state directory configured inside `bin\` falls
##   back to the neutral directory below, so the rule above holds for every
##   configuration rather than for the default one.
## * Every other process runs in the system's NEUTRAL DIRECTORY: `/` on POSIX
##   (the conventional daemon directory, which pins no caller directory and
##   no file system), and the Windows system directory
##   (`GetSystemDirectoryW`, normally `C:\Windows\System32`) on Windows. The
##   latter is where the Service Control Manager starts a service, so the
##   auto-started `runquotad` runs where the installed service it stands in
##   for would, and no installer, user or test renames or deletes it.
##
## NOTHING RESOLVES AGAINST IT. Each of these daemons is handed absolute paths
## only (`withAnchoredDaemonPaths` for the `repro-daemon`; an absolute
## `--socket` or none for `runquotad`; absolute store root and endpoint for
## the store daemon), so the choice of directory changes no path they use.

import std/os
when defined(windows):
  from std/unicode import toLower

when defined(windows):
  proc getSystemDirectoryW(lpBuffer: WideCString; uSize: uint32): uint32
      {.stdcall, dynlib: "kernel32", importc: "GetSystemDirectoryW".}
      ## https://learn.microsoft.com/windows/win32/api/sysinfoapi/nf-sysinfoapi-getsystemdirectoryw

proc neutralDaemonWorkingDirectory*(): string =
  ## The directory a detached daemon with no state directory of its own runs
  ## in: `/` on POSIX, the Windows system directory on Windows. See the module
  ## comment for why each.
  when defined(windows):
    # MAX_PATH is enough for the system directory in every supported
    # configuration; a longer answer is reported as the required size, and
    # then the call is repeated with a buffer of that size.
    var size = 260'u32
    for _ in 0 .. 1:
      var buffer = newWideCString("", int(size))
      let written = getSystemDirectoryW(buffer, size)
      if written == 0:
        break
      if written < size:
        return $buffer
      size = written + 1
    # Unreachable on a working Windows installation. `%SystemRoot%` is set
    # for every process the shell starts; the drive root is the last resort
    # and, like the system directory, is never renamed by an installer.
    let systemRoot = getEnv("SystemRoot")
    if systemRoot.len > 0:
      return systemRoot / "System32"
    let systemDrive = getEnv("SystemDrive", "C:")
    systemDrive & r"\"
  else:
    "/"

proc normalizedForComparison(path: string): string =
  ## `path` absolute and normalised, with no trailing separator. On Windows
  ## it is also case-folded, because NTFS names compare case-insensitively,
  ## and not only in ASCII: a profile directory whose name holds a non-ASCII
  ## letter is the same directory in either case. `unicode.toLower` is a
  ## simple per-rune mapping: close to the volume's upcase table, not
  ## identical with it, which is enough for two spellings that differ only in
  ## how someone typed them.
  result = normalizedPath(absolutePath(path))
  while result.len > 1 and result[^1] in {DirSep, AltSep} and
      not (defined(windows) and result.len == 3 and result[1] == ':'):
    result.setLen(result.len - 1)
  when defined(windows):
    result = toLower(result)

proc isSameOrInside*(path, directory: string): bool =
  ## Whether `path` is `directory` or lies beneath it, by their absolute,
  ## normalised spellings (case-insensitively on Windows). Symbolic links are
  ## not resolved: the question is about the names an installer renames.
  if path.len == 0 or directory.len == 0:
    return false
  let candidate = normalizedForComparison(path)
  let parent = normalizedForComparison(directory)
  if candidate == parent:
    return true
  let prefix =
    if parent[^1] in {DirSep, AltSep}: parent
    else: parent & DirSep
  candidate.len > prefix.len and candidate[0 ..< prefix.len] == prefix

proc detachedDaemonWorkingDirectory*(image: string;
                                     ownedStateDir = ""): string =
  ## The working directory to start the detached daemon `image` in.
  ##
  ## `ownedStateDir` is the state directory the daemon owns, or "" when it
  ## owns none. It is returned when it is given and lies outside the image's
  ## directory; otherwise the neutral directory is. The answer is never the
  ## image's directory or one beneath it, and never the caller's working
  ## directory unless the caller chose to pass that as the daemon's own state
  ## directory. See the module comment.
  let imageDir = if image.len > 0: parentDir(absolutePath(image)) else: ""
  if ownedStateDir.len > 0 and
      (imageDir.len == 0 or not isSameOrInside(ownedStateDir, imageDir)):
    return ownedStateDir
  neutralDaemonWorkingDirectory()
