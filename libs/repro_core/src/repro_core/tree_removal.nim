## Removing a directory tree without following the links in it.
##
## Shared by the engine's scratch directories (`BuildAction.scratchDirs`) and
## its canonical work trees (`repro_core/canonical_work_dir`). Both are full of
## links: npm links every workspace package into `node_modules`, as a
## directory junction on Windows, and following one would delete the linked
## sources.

import std/os

when defined(windows):
  import std/winlean

  proc noFollowRemoveDirectoryW(path: WideCString): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "RemoveDirectoryW".}
  proc noFollowSetFileAttributesW(path: WideCString; attrs: DWORD): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "SetFileAttributesW".}
else:
  import std/posix

proc removeTreeNoFollow*(path: string) =
  ## Deletes `path` and everything below it WITHOUT FOLLOWING LINKS: a link
  ## is removed, never what it points at. `os.removeDir` neither follows nor
  ## removes a junction (it treats the link as a file, and Windows refuses to
  ## delete a directory link that way), and stops at the first read-only file.
  for kind, child in walkDir(path):
    case kind
    of pcDir:
      removeTreeNoFollow(child)
    of pcLinkToDir:
      when defined(windows):
        if noFollowRemoveDirectoryW(newWideCString(child)) == 0:
          raiseOSError(osLastError(), child)
      else:
        removeFile(child)
    of pcFile, pcLinkToFile:
      when defined(windows):
        discard noFollowSetFileAttributesW(newWideCString(child),
          DWORD(0x80))   # FILE_ATTRIBUTE_NORMAL: clears read-only
      removeFile(child)
  when defined(windows):
    discard noFollowSetFileAttributesW(newWideCString(path), DWORD(0x80))
    if noFollowRemoveDirectoryW(newWideCString(path)) == 0:
      raiseOSError(osLastError(), path)
  else:
    removeDir(path)

proc removeEmptyDirNoFollow*(path: string): bool =
  ## Removes `path` only if it is a real, EMPTY directory, and reports whether
  ## it did. A link, a file, a missing path or a directory with anything in it
  ## is left alone and answers false; nothing is recursed into. For a
  ## directory the caller created but that something else may since have put
  ## content in, this is the only safe removal.
  if symlinkExists(path) or not dirExists(path):
    return false
  when defined(windows):
    # RemoveDirectoryW refuses a non-empty directory.
    noFollowRemoveDirectoryW(newWideCString(path)) != 0
  else:
    # rmdir(2) refuses a non-empty directory.
    rmdir(path.cstring) == 0

proc removePathNoFollow*(path: string) =
  ## Removes whatever is at `path` WITHOUT FOLLOWING A LINK: a symlink (or,
  ## on Windows, a directory link or junction) is unlinked and its target is
  ## left alone, a regular file is deleted, a real directory is removed with
  ## `removeTreeNoFollow`. A missing path is not an error.
  if symlinkExists(path):
    when defined(windows):
      # A directory link is removed as a directory, never as a file -- and
      # never by recursing into it, which is what `removeDir` would do.
      if dirExists(path):
        if noFollowRemoveDirectoryW(newWideCString(path)) == 0:
          raiseOSError(osLastError(), path)
        return
    removeFile(path)
  elif dirExists(path):
    removeTreeNoFollow(path)
  elif fileExists(path):
    when defined(windows):
      discard noFollowSetFileAttributesW(newWideCString(path),
        DWORD(0x80))   # FILE_ATTRIBUTE_NORMAL: clears read-only
    removeFile(path)
