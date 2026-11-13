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

import std/[algorithm, os, posix, sequtils, strutils]

import repro_core
import repro_local_store/store

import repro_elevation/store_view

import ./generation0
import ./linux_fs
import ./mutations

export store_view.isMountPoint

type
  StoreRootError* = object of CatchableError

  RealisedPrefixes* = object
    binaryPrefixId*: PrefixIdBytes
    binaryPrefixPath*: string     ## absolute
    reproExe*: string             ## binaryPrefixPath / bin/repro
    filesPrefixId*: PrefixIdBytes
    filesPrefixPath*: string      ## absolute
    binaryDigest*: string         ## realisation digest (``storeTreeDigest``)
    filesDigest*: string          ## of each, computed from the bytes this
                                  ## process staged, never read back from
                                  ## the store (spec §10.2, "The digest at
                                  ## realisation")

const
  ReproRoot* = "/repro"
  BinaryPackage* = "repro-addon"
  FilesPackage* = "repro-addon-files"
  StaticTreePackageName* = "repro-addon-etc"
    ## The static tree's package (``static_tree.StaticTreePackage``).
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

proc filesPrefixId*(names: openArray[string];
                    version = ReprobuildVersion): PrefixIdBytes =
  ## The files prefix is content-addressed by the names of the files in it,
  ## which are their SHA-256 digests, and the version of the add-on that
  ## realised it.
  computeRealizationHash(FilesPackage, version, "addon-bootstrap",
    "", "", provenanceChecksum = "manifest:" & filesManifest(names))

proc filesPrefixPath*(names: openArray[string];
                      version = ReprobuildVersion;
                      storeRoot = StoreRoot): string =
  storeRoot / prefixRelativePath(FilesPackage, version,
                                 filesPrefixId(names, version))

proc prefixVersionOf*(path: string): string =
  ## The version a prefix path ``<store>/prefixes/<pkg>/<version>-<hash16>``
  ## was realised under (the add-on's own prefixes use plain versions).
  let leaf = extractFilename(path)
  let dash = leaf.rfind('-')
  if dash > 0: leaf[0 ..< dash] else: ""

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

proc takeOverRootDir*(path: string; mode: int): string =
  ## Take over a directory that already exists as one of the add-on's
  ## pre-bootstrap inputs (spec §6.1): it must be a real directory, never
  ## a link; it becomes root's, and gets exactly ``mode`` (the modes of
  ## §5.3 -- every taken-over directory gets one, nothing keeps the mode it
  ## had). Returns the ledger kind hint. The preflight accepted the
  ## directory by shape, owner and mode; this is the write that the
  ## acknowledged plan authorises.
  var st: Stat
  if lstat(path.cstring, st) != 0:
    raise newException(StoreRootError, path & " does not exist; the " &
      "preflight saw it")
  if S_ISLNK(st.st_mode) or not S_ISDIR(st.st_mode):
    raise newException(StoreRootError, path & " is not a directory")
  if posix.chown(path.cstring, 0, 0) != 0:
    raiseOSError(osLastError(), "chown " & path)
  if posix.chmod(path.cstring, Mode(mode)) != 0:
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
    when mutated("uninstall-keeps-repro-subvolume"):
      # NEGATIVE CONTROL (see mutations.nim): the subvolume is left behind,
      # which the fingerprint's ``btrfs-subvolumes`` and ``addon-roots``
      # records must show.
      return
    deleteBtrfsSubvolume(parentDir(ReproRoot), extractFilename(ReproRoot))
  else:
    removeDir(ReproRoot)

# ---------------------------------------------------------------------------
# The private writable view (``repro_elevation/store_view``, shared with the
# privileged driver, which writes the store too).
# ---------------------------------------------------------------------------

proc enterWritableStoreView*() =
  ## Make ``/repro/store`` writable for this thread only (spec §10.2).
  enterWritableStoreView(StoreRoot)

# ---------------------------------------------------------------------------
# Realising the add-on's prefixes and registering generation roots.
# ---------------------------------------------------------------------------

proc realisationDigest*(staged, realised: string): string =
  ## The realisation digest of the store path ``realised``, materialised
  ## from the directory ``staged`` this process wrote: the canonical tree
  ## digest of the STAGED bytes, which the store path cannot change (spec
  ## §10.2, "The digest at realisation"; it is recorded outside the store,
  ## in the generation's ledger). A store path that already existed and
  ## holds other entries than were staged -- an altered path the store
  ## reused -- is refused here rather than recorded as owned.
  result = storeTreeDigest(staged)
  let now = storeTreeDigest(realised)
  if now != result:
    raise newException(StoreRootError, "the store path " & realised &
      " does not hold the bytes realised into it (" & now & ", staged " &
      result & "): it existed with other content; it is left in place " &
      "and not used")

proc realiseFilesInto(s: var Store; files: openArray[tuple[name, content: string]];
                      version = ReprobuildVersion):
    tuple[id: PrefixIdBytes; path, digest: string] =
  ## One files prefix holding ``files`` (named by their content digest), at
  ## the path its manifest names, with its realisation digest.
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
      version: version,
      provenanceChecksum: "manifest:" & filesManifest(names)))
  (filesRes.prefixId, filesRes.absolutePath,
   realisationDigest(ftmp, filesRes.absolutePath))

proc realiseFilesPrefix*(files: openArray[tuple[name, content: string]];
                         version = ReprobuildVersion):
    tuple[id: PrefixIdBytes; path, digest: string] =
  ## A files prefix of generation-0 bodies on its own (an operator verb that
  ## adds objects to generation 0 after bootstrap: ``evidence-enrol``; the
  ## recovery of an altered one, under the version it was realised with).
  enterWritableStoreView()
  var s = openStore(StoreRoot)
  defer: s.close()
  realiseFilesInto(s, files, version)

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
  result.binaryDigest = realisationDigest(tmp, binRes.absolutePath)
  if result.binaryPrefixPath != binaryPrefixPath(binarySha256):
    raise newException(StoreRootError, "store placed the add-on binary at " &
      result.binaryPrefixPath & ", not at the planned " &
      binaryPrefixPath(binarySha256))
  let f = realiseFilesInto(s, files)
  result.filesPrefixId = f.id
  result.filesPrefixPath = f.path
  result.filesDigest = f.digest

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

# ---------------------------------------------------------------------------
# The store quarantine (spec §13 decision 46, DET-AO-5).
# ---------------------------------------------------------------------------

proc readStoreQuarantine*(path = StoreQuarantinePath): seq[string] =
  ## Store paths verification found altered; none is used by a switch again.
  try:
    for l in readFile(path).splitLines():
      let p = l.strip()
      if p.len > 0 and p notin result: result.add(p)
  except IOError, OSError:
    discard

proc releaseStoreQuarantine*(storePath: string; path = StoreQuarantinePath) =
  ## Take ``storePath`` out of the quarantine: the altered directory was
  ## moved into the evidence directory and the path re-realised from a
  ## trusted source (spec §13 decision 47). No-op when it is not there.
  var q = readStoreQuarantine(path)
  if storePath notin q: return
  q.keepItIf(it != storePath)
  createDir(parentDir(path))
  writeFile(path & ".tmp", (if q.len > 0: q.join("\n") & "\n" else: ""))
  setFilePermissions(path & ".tmp", {fpUserRead, fpUserWrite})
  moveFile(path & ".tmp", path)

proc quarantineStorePath*(storePath: string; path = StoreQuarantinePath) =
  ## Add ``storePath`` (no-op when it is there already); the file is
  ## rewritten whole, by rename.
  var q = readStoreQuarantine(path)
  if storePath in q: return
  q.add(storePath)
  createDir(parentDir(path))
  writeFile(path & ".tmp", q.join("\n") & "\n")
  setFilePermissions(path & ".tmp", {fpUserRead, fpUserWrite})
  moveFile(path & ".tmp", path)
