## The add-on's system-scope store at ``/repro/store``.
##
## ``/repro/store`` is the same root a full ReproOS host uses, so a service
## closure built for one runs unchanged on the other. It is created by
## bootstrap and removed by uninstall:
##
## - on a btrfs root, ``/repro`` is its own subvolume, so a snapshot of
##   ``/`` neither carries the store nor rolls it back;
## - on any other root it is a plain directory.
##
## Each add-on generation is a ``profile`` root in the store's root registry
## (``repro_local_store`` ``roots`` / ``root_holds_prefix``) holding the
## prefixes that generation runs from, and the current and previous
## generation are always registered, so ``repro store gc`` can never collect
## what the next boot needs. (The retention policy beyond those two belongs
## to the add-on switch.)
##
## The store is mounted read-only over itself by generation 0's
## ``repro-store.mount``. A process that has to write it -- bootstrap
## realising a prefix, an apply registering a generation root -- first
## enters a private mount namespace in which that bind is writable
## (``enterWritableStoreView``); no other process on the host ever sees a
## writable store.

import std/[algorithm, os, posix, strutils]

import repro_core
import repro_local_store/store

import ./generation0
import ./linux_fs

type
  StoreRootError* = object of CatchableError

  RealisedPrefixes* = object
    binaryPrefixId*: PrefixIdBytes
    binaryPrefixPath*: string     ## absolute
    reproExe*: string             ## binaryPrefixPath / bin/repro
    filesPrefixId*: PrefixIdBytes
    filesPrefixPath*: string      ## absolute

const
  ReproRoot* = "/repro"
  BinaryPackage* = "repro-addon"
  FilesPackage* = "repro-addon-files"
  RootIdPrefix* = "addon-generation:"

# ---------------------------------------------------------------------------
# Prefix identities. Pure: the preflight computes them without writing, so
# the plan it prints names the exact store paths generation 0 will use.
# ---------------------------------------------------------------------------

proc binaryPrefixId*(binarySha256: string): PrefixIdBytes =
  computeRealizationHash(BinaryPackage, ReprobuildVersion, "addon-bootstrap",
    "", "bin/repro", provenanceChecksum = "sha256:" & binarySha256)

proc binaryPrefixPath*(binarySha256: string): string =
  StoreRoot / prefixRelativePath(BinaryPackage, ReprobuildVersion,
                                 binaryPrefixId(binarySha256))

proc reproExeFor*(binarySha256: string): string =
  binaryPrefixPath(binarySha256) / "bin" / "repro"

proc filesManifest(names: openArray[string]): string =
  var sorted = @names
  sorted.sort(system.cmp)
  sorted.join("\n")

proc filesPrefixId*(names: openArray[string]): PrefixIdBytes =
  ## The files prefix is content-addressed by the names of the files in it,
  ## which are their SHA-256 digests.
  computeRealizationHash(FilesPackage, ReprobuildVersion, "addon-bootstrap",
    "", "", provenanceChecksum = "manifest:" & filesManifest(names))

proc filesPrefixPath*(names: openArray[string]): string =
  StoreRoot / prefixRelativePath(FilesPackage, ReprobuildVersion,
                                 filesPrefixId(names))

# ---------------------------------------------------------------------------
# Roots.
# ---------------------------------------------------------------------------

proc createRootDir*(path: string; mode: int; asSubvolume = false): string =
  ## Create one root directory that must not exist yet, with exactly
  ## ``mode`` (the umask does not apply). Returns the ledger kind hint.
  ## With ``asSubvolume`` the directory is a btrfs subvolume (bootstrap asks
  ## for it when ``/repro``'s parent is btrfs); the parent must be btrfs.
  var st: Stat
  if lstat(path.cstring, st) == 0:
    raise newException(StoreRootError, path & " already exists")
  let parent = parentDir(path)
  if asSubvolume:
    if not isBtrfs(parent):
      raise newException(StoreRootError, parent & " is not btrfs; " & path &
        " cannot be a subvolume")
    createBtrfsSubvolume(parent, extractFilename(path))
    result = "btrfs-subvolume"
  else:
    if posix.mkdir(path.cstring, Mode(mode)) != 0:
      raiseOSError(osLastError(), "mkdir " & path)
    result = "dir"
  if posix.chmod(path.cstring, Mode(mode)) != 0:
    raiseOSError(osLastError(), "chmod " & path)
  if posix.chown(path.cstring, 0, 0) != 0:
    raiseOSError(osLastError(), "chown " & path)

proc rootKindHint*(path: string): string =
  ## The kind word the fingerprint's ``addon-roots`` component uses for an
  ## existing directory: ``dir``, ``btrfs-dir`` (a plain directory on a
  ## btrfs filesystem) or ``btrfs-subvolume``. A taken-over root's ledger
  ## entry must carry this word, not ``createRootDir``'s, for the ledger's
  ## expectation to equal what the fingerprint records.
  if isBtrfs(path):
    if isBtrfsSubvolume(path): "btrfs-subvolume" else: "btrfs-dir"
  else: "dir"

proc takeOverRootDir*(path: string; mode = -1): string =
  ## Take over a directory that already exists as one of the add-on's
  ## pre-bootstrap inputs (spec §6.1): it must be a real directory, never
  ## a link; it becomes root's, and gets exactly ``mode`` when one is given
  ## (the modes of §5.3; -1 keeps the mode it has). Returns the ledger
  ## kind hint. The preflight accepted the directory by shape; this is the
  ## write that the acknowledged plan authorises.
  var st: Stat
  if lstat(path.cstring, st) != 0:
    raise newException(StoreRootError, path & " does not exist; the " &
      "preflight saw it")
  if S_ISLNK(st.st_mode) or not S_ISDIR(st.st_mode):
    raise newException(StoreRootError, path & " is not a directory")
  if posix.chown(path.cstring, 0, 0) != 0:
    raiseOSError(osLastError(), "chown " & path)
  if mode >= 0 and posix.chmod(path.cstring, Mode(mode)) != 0:
    raiseOSError(osLastError(), "chmod " & path)
  rootKindHint(path)

proc selfcheckBtrfsSubvolume*(mountPoint: string): string =
  ## Exercise the subvolume leg of ``createRootDir`` on a btrfs filesystem
  ## mounted at ``mountPoint`` (a loop-backed one in a test guest): create
  ## ``<mountPoint>/repro-addon-selfcheck`` as a subvolume, verify the
  ## kernel calls it one, delete it through the subvolume ioctl, verify it
  ## is gone. Returns a one-line report; raises on any failure.
  if not isBtrfs(mountPoint):
    raise newException(StoreRootError, mountPoint & " is not btrfs")
  let name = "repro-addon-selfcheck"
  let path = mountPoint / name
  let hint = createRootDir(path, 0o755, asSubvolume = true)
  if hint != "btrfs-subvolume" or not isBtrfsSubvolume(path):
    raise newException(StoreRootError, path & " was created but is not a " &
      "btrfs subvolume (hint " & hint & ")")
  var st: Stat
  if lstat(path.cstring, st) != 0 or (int(st.st_mode) and 0o7777) != 0o755:
    raise newException(StoreRootError, path & " does not have mode 0755")
  deleteBtrfsSubvolume(mountPoint, name)
  if lstat(path.cstring, st) == 0:
    raise newException(StoreRootError, path & " still exists after the " &
      "subvolume delete")
  "btrfs subvolume " & path & ": created (inode " & $BtrfsFirstFreeObjectId &
    ", mode 0755), deleted"

proc removeReproRoot*() =
  ## Delete ``/repro`` and everything below it: a btrfs subvolume through
  ## the subvolume ioctl, a plain directory recursively.
  if not dirExists(ReproRoot):
    return
  if isBtrfsSubvolume(ReproRoot):
    deleteBtrfsSubvolume(parentDir(ReproRoot), extractFilename(ReproRoot))
  else:
    removeDir(ReproRoot)

# ---------------------------------------------------------------------------
# The private writable view.
# ---------------------------------------------------------------------------

var
  CloneNewNs {.importc: "CLONE_NEWNS", header: "<sched.h>".}: cint
  MsRec {.importc: "MS_REC", header: "<sys/mount.h>".}: culong
  MsPrivate {.importc: "MS_PRIVATE", header: "<sys/mount.h>".}: culong
  MsRemount {.importc: "MS_REMOUNT", header: "<sys/mount.h>".}: culong
  MsBind {.importc: "MS_BIND", header: "<sys/mount.h>".}: culong

proc c_unshare(flags: cint): cint {.importc: "unshare", header: "<sched.h>".}
proc c_mount(source, target, fstype: cstring; flags: culong;
             data: pointer): cint {.importc: "mount", header: "<sys/mount.h>".}

proc isMountPoint*(path: string): bool =
  ## True when ``path`` is the mount point of some entry in this
  ## process's mount table.
  for line in readFile("/proc/self/mountinfo").splitLines():
    let f = line.splitWhitespace()
    if f.len > 4 and f[4] == path:
      return true
  false

var writableViewEntered = false

proc enterWritableStoreView*() =
  ## Move this process into a private mount namespace in which
  ## ``/repro/store`` is writable. Idempotent. The read-only bind stays in
  ## place for every other process on the host, and the private namespace
  ## ends with this process.
  if writableViewEntered:
    return
  if c_unshare(CloneNewNs) != 0:
    raiseOSError(osLastError(), "unshare(CLONE_NEWNS)")
  # Stop mount events propagating out of (or into) this namespace before
  # changing anything in it.
  if c_mount(nil, "/", nil, MsRec or MsPrivate, nil) != 0:
    raiseOSError(osLastError(), "make / private in the apply namespace")
  writableViewEntered = true
  if dirExists(StoreRoot) and isMountPoint(StoreRoot):
    # Remount the bind without MS_RDONLY: writable here, still read-only
    # everywhere else.
    if c_mount(nil, StoreRoot.cstring, nil, MsRemount or MsBind, nil) != 0:
      raiseOSError(osLastError(), "remount " & StoreRoot & " writable")

# ---------------------------------------------------------------------------
# Realising the add-on's prefixes and registering generation roots.
# ---------------------------------------------------------------------------

proc realiseAddonPrefixes*(binaryPath, binarySha256: string;
                           files: seq[tuple[name, content: string]]):
    RealisedPrefixes =
  ## Copy the running ``repro`` and generation 0's file bodies into the
  ## store as two prefixes, and verify the binary's digest on the store
  ## copy (not on the source): the digest the operator pinned is checked
  ## on the bytes that will run.
  enterWritableStoreView()
  var s = openStore(StoreRoot)
  defer: s.close()
  let tmp = StoreRoot / "tmp" / ("addon-staging-" & $getCurrentProcessId())
  removeDir(tmp)
  createDir(tmp / "bin")
  defer: removeDir(tmp)
  copyFile(binaryPath, tmp / "bin" / "repro")
  setFilePermissions(tmp / "bin" / "repro",
    {fpUserRead, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead,
     fpOthersExec})
  let binRes = s.realizeDirectoryAsPrefix(tmp,
    StoreReceiptHint(adapter: "addon-bootstrap", packageName: BinaryPackage,
      version: ReprobuildVersion, declaredExecutablePath: "bin/repro",
      exportedExecutables: @["repro"],
      provenanceChecksum: "sha256:" & binarySha256))
  result.binaryPrefixId = binRes.prefixId
  result.binaryPrefixPath = binRes.absolutePath
  result.reproExe = binRes.absolutePath / "bin" / "repro"
  if result.binaryPrefixPath != binaryPrefixPath(binarySha256):
    raise newException(StoreRootError, "store placed the add-on binary at " &
      result.binaryPrefixPath & ", not at the planned " &
      binaryPrefixPath(binarySha256))
  let ftmp = StoreRoot / "tmp" / ("addon-files-" & $getCurrentProcessId())
  removeDir(ftmp)
  createDir(ftmp)
  defer: removeDir(ftmp)
  var names: seq[string]
  for f in files:
    if f.name notin names:
      writeFile(ftmp / f.name, f.content)
      names.add(f.name)
  let filesRes = s.realizeDirectoryAsPrefix(ftmp,
    StoreReceiptHint(adapter: "addon-bootstrap", packageName: FilesPackage,
      version: ReprobuildVersion,
      provenanceChecksum: "manifest:" & filesManifest(names)))
  result.filesPrefixId = filesRes.prefixId
  result.filesPrefixPath = filesRes.absolutePath

proc registerGenerationRoot*(generationId: string;
                             prefixIds: openArray[PrefixIdBytes]) =
  ## Register ``generationId`` as a ``profile`` root holding ``prefixIds``.
  ## Earlier generations' roots are left registered, so after any apply
  ## both the current and the previous generation are roots.
  enterWritableStoreView()
  var s = openStore(StoreRoot)
  defer: s.close()
  let rootId = RootIdPrefix & generationId
  s.registerRoot(rootId, rkProfile)
  for p in prefixIds:
    s.attachPrefixToRoot(rootId, p)

proc generationRoots*(): seq[string] =
  ## The add-on generation ids registered as store roots.
  if not dirExists(StoreRoot):
    return @[]
  enterWritableStoreView()   # opening the index writes its WAL
  var s = openStore(StoreRoot)
  defer: s.close()
  for r in s.listRoots():
    if r.rootId.startsWith(RootIdPrefix) and r.kind == $rkProfile:
      result.add(r.rootId[RootIdPrefix.len .. ^1])
