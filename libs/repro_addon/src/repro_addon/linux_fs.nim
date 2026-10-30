## Linux filesystem facts the add-on needs and ``std/posix`` does not bind:
## ``statfs(2)`` (filesystem type and free space) and the two btrfs
## ioctls that create and delete a subvolume.
##
## The btrfs calls are made directly rather than through ``btrfs(8)``
## because a host whose root is btrfs is not guaranteed to have
## btrfs-progs installed, and the add-on must not install a package
## (spec "What bootstrap must not do").
##
## References:
## - statfs(2): https://man7.org/linux/man-pages/man2/statfs.2.html
## - BTRFS_IOC_SUBVOL_CREATE / BTRFS_IOC_SNAP_DESTROY and
##   ``struct btrfs_ioctl_vol_args``:
##   https://github.com/torvalds/linux/blob/master/include/uapi/linux/btrfs.h

import std/[os, posix, strutils]

const
  Ext4SuperMagic* = 0xEF53'i64
  BtrfsSuperMagic* = 0x9123683E'i64
  XfsSuperMagic* = 0x58465342'i64
  TmpfsMagic* = 0x01021994'i64
  OverlayfsSuperMagic* = 0x794C7630'i64
  SquashfsMagic* = 0x73717368'i64
  ZfsSuperMagic* = 0x2FC12FC1'i64
  BtrfsFirstFreeObjectId* = 256'u64
    ## The inode number of every btrfs subvolume root.

type
  StatfsBuf {.importc: "struct statfs", header: "<sys/vfs.h>".} = object
    f_type: clong
    f_bsize: clong
    f_blocks: culong
    f_bfree: culong
    f_bavail: culong

  FsInfo* = object
    magic*: int64
    availableBytes*: uint64

proc c_statfs(path: cstring; buf: ptr StatfsBuf): cint {.
  importc: "statfs", header: "<sys/vfs.h>".}

proc statFs*(path: string): FsInfo =
  ## Raises ``OSError`` when ``path`` cannot be examined.
  var buf: StatfsBuf
  if c_statfs(path.cstring, addr buf) != 0:
    raiseOSError(osLastError(), "statfs " & path)
  # ``f_type`` is a signed long holding an unsigned 32-bit magic; mask it
  # so the btrfs magic compares equal on 32-bit armhf too.
  result.magic = int64(buf.f_type) and 0xFFFFFFFF'i64
  result.availableBytes = uint64(buf.f_bavail) * uint64(buf.f_bsize)

proc fsTypeName*(magic: int64): string =
  case magic
  of Ext4SuperMagic: "ext4"
  of BtrfsSuperMagic: "btrfs"
  of XfsSuperMagic: "xfs"
  of TmpfsMagic: "tmpfs"
  of OverlayfsSuperMagic: "overlay"
  of SquashfsMagic: "squashfs"
  of ZfsSuperMagic: "zfs"
  else: "magic-0x" & toHex(magic, 8)

proc isBtrfs*(path: string): bool =
  statFs(path).magic == BtrfsSuperMagic

proc isBtrfsSubvolume*(path: string): bool =
  ## True when ``path`` is the root directory of a btrfs subvolume.
  var st: Stat
  if lstat(path.cstring, st) != 0 or not S_ISDIR(st.st_mode):
    return false
  isBtrfs(path) and uint64(st.st_ino) == BtrfsFirstFreeObjectId

const
  BtrfsPathNameMax = 4087

var ODirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint

type
  BtrfsIoctlVolArgs = object
    fd: int64
    name: array[BtrfsPathNameMax + 1, char]

proc c_ioctl(fd: cint; request: culong; arg: pointer): cint {.
  importc: "ioctl", header: "<sys/ioctl.h>", varargs.}

proc iow(typ, nr: int; size: int): culong =
  ## ``_IOW(type, nr, size)`` for the generic ioctl encoding used by
  ## x86_64, arm64 and arm (direction bit 1 = write, at bit 30).
  culong((1 shl 30) or (size shl 16) or (typ shl 8) or nr)

let
  BtrfsIocSubvolCreate = iow(0x94, 14, sizeof(BtrfsIoctlVolArgs))
  BtrfsIocSnapDestroy = iow(0x94, 15, sizeof(BtrfsIoctlVolArgs))

proc btrfsVolIoctl(parent, name: string; request: culong; what: string) =
  if name.len == 0 or name.len > BtrfsPathNameMax or '/' in name:
    raise newException(ValueError, "invalid btrfs subvolume name: " & name)
  let fd = posix.open(parent.cstring, O_RDONLY or ODirectory)
  if fd < 0:
    raiseOSError(osLastError(), what & ": open " & parent)
  defer: discard posix.close(fd)
  var args: BtrfsIoctlVolArgs
  for i, c in name:
    args.name[i] = c
  if c_ioctl(fd, request, addr args) != 0:
    raiseOSError(osLastError(), what & " " & (parent / name))

proc createBtrfsSubvolume*(parent, name: string) =
  ## ``btrfs subvolume create <parent>/<name>``.
  btrfsVolIoctl(parent, name, BtrfsIocSubvolCreate, "btrfs subvolume create")

proc deleteBtrfsSubvolume*(parent, name: string) =
  ## ``btrfs subvolume delete <parent>/<name>``. The kernel removes a
  ## non-empty subvolume in one call (CAP_SYS_ADMIN, which root has).
  btrfsVolIoctl(parent, name, BtrfsIocSnapDestroy, "btrfs subvolume delete")
