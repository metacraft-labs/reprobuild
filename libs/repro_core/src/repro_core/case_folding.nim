## Whether a directory resolves names without regard to letter case, and the
## folded form of a name for comparing two names created in one.
##
## Two spellings of an entry that EXISTS are compared by asking the
## filesystem for each one's identity. An entry that does not exist yet has
## no identity, so a check that must hold for entries a build has still to
## create (a removal must not take another action's output) has to know how
## the directory that will hold them compares names. That is a property of
## the directory, not of the platform:
##
## - Linux folds case per directory: a directory carrying the `casefold`
##   attribute (`FS_CASEFOLD_FL`, `chattr +F`, ext4/f2fs/tmpfs) resolves
##   names case-insensitively, and a directory created in it inherits the
##   attribute (https://docs.kernel.org/filesystems/ext4/directory.html
##   #case-insensitive-directories). FAT and exFAT fold case for the whole
##   volume and carry no attribute, so they are recognised by `statfs`'s
##   filesystem magic (`MSDOS_SUPER_MAGIC`, `EXFAT_SUPER_MAGIC`,
##   https://man7.org/linux/man-pages/man2/statfs.2.html).
## - macOS answers per volume through `pathconf(_PC_CASE_SENSITIVE)`
##   (https://developer.apple.com/library/archive/documentation/System/
##   Conceptual/ManPages_iPhoneOS/man2/pathconf.2.html); the default APFS
##   volume folds.
## - Windows folds case unless a directory has been made case-sensitive
##   (`fsutil file setCaseSensitiveInfo`), which only WSL interop does. It is
##   taken to fold, as the rest of the engine already lowercases Windows
##   paths.
##
## `foldName` folds letter case only, rune by rune. The kernel's `casefold`
## and APFS also ignore Unicode normalization (NFC/NFD), which this does not
## model: two absent names that differ only in normalization compare unequal
## here. Existing entries are unaffected, since they are compared by
## identity.

import std/[os, unicode]

when defined(linux):
  from std/posix import open, close, ioctl, O_RDONLY, O_CLOEXEC, O_NONBLOCK

  var O_DIRECTORY {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint

  type StatFs {.importc: "struct statfs", header: "<sys/vfs.h>",
      bycopy.} = object
    f_type: clong

  proc c_statfs(path: cstring; buf: var StatFs): cint
    {.importc: "statfs", header: "<sys/vfs.h>".}

  const
    # include/uapi/linux/fs.h. The kernel reads and writes an `int` through
    # the pointer, whatever the request number's encoded size says.
    FS_IOC_GETFLAGS = 0x80086601'u
    FS_CASEFOLD_FL = 0x40000000'i32
    # include/uapi/linux/magic.h
    MSDOS_SUPER_MAGIC = 0x4d44
    EXFAT_SUPER_MAGIC = 0x2011BAB0

elif defined(macosx):
  proc c_pathconf(path: cstring; name: cint): clong
    {.importc: "pathconf", header: "<unistd.h>".}
  let PC_CASE_SENSITIVE {.importc: "_PC_CASE_SENSITIVE",
    header: "<unistd.h>".}: cint

proc nearestExistingDirectory*(path: string): string =
  ## `path` or its nearest ancestor that exists, following links, as the
  ## directory in which the absent rest of `path` would be created. "" when
  ## nothing on the way up exists (a relative path with no existing prefix).
  var current = path
  while current.len > 0:
    if dirExists(current):
      return current
    let parent = current.parentDir()
    if parent == current:
      break
    current = parent
  ""

proc directoryFoldsCase*(dir: string): bool =
  ## Whether names created in the existing directory `dir` are resolved
  ## without regard to letter case (see the module comment for how each
  ## platform is asked). A directory that cannot be asked answers `false`:
  ## the callers use this to widen a refusal, and an unanswerable question
  ## must not refuse what the spelling alone accepts.
  when defined(windows):
    discard dir
    true
  elif defined(linux):
    let fd = open(dir.cstring, O_RDONLY or O_DIRECTORY or O_CLOEXEC or
      O_NONBLOCK)
    if fd >= 0:
      var flags: int32 = 0
      let rc = ioctl(fd, FS_IOC_GETFLAGS, addr flags)
      discard close(fd)
      if rc == 0 and (flags and FS_CASEFOLD_FL) != 0:
        return true
    var fs: StatFs
    if c_statfs(dir.cstring, fs) == 0:
      let magic = fs.f_type.int64 and 0xFFFF_FFFF'i64
      return magic == MSDOS_SUPER_MAGIC or magic == EXFAT_SUPER_MAGIC
    false
  elif defined(macosx):
    c_pathconf(dir.cstring, PC_CASE_SENSITIVE) == 0
  else:
    discard dir
    false

proc foldName*(name: string): string =
  ## `name` with every letter in lower case, for comparing names created in
  ## a directory that folds case. Invalid UTF-8 is kept byte for byte.
  if validateUtf8(name) >= 0:
    return name
  toLower(name)
