## Reading cargo's target-directory layout.
##
## A *profile directory* (`target/debug`, `target/<triple>/release`, a custom
## profile) is the only thing cargo owns here that the janitor ever opens. It
## holds:
##
##   .fingerprint/<pkg>-<hash>/   per-unit freshness records
##   deps/<name>-<hash>[.<ext>]   per-unit outputs (`lib<crate>-<hash>.rlib`, ...)
##   build/<pkg>-<hash>/          build-script binaries and their run output
##   incremental/<crate>-<id>/    rustc incremental caches (id is not the hash)
##   <name>[.<ext>]               final artifacts hard-linked out of deps/
##   .cargo-lock                  cargo's own lock for this directory
##
## Layout reference:
## https://doc.rust-lang.org/cargo/reference/build-cache.html

import std/[algorithm, json, os, sets, strutils, tables, times]
import ./types

const
  FingerprintDir* = ".fingerprint"
  DepsDir* = "deps"
  BuildDir* = "build"
  IncrementalDir* = "incremental"
  CargoLockName* = ".cargo-lock"

type
  UnitEntries* = object
    ## Every path of one unit inside one profile directory.
    hash*: string
    paths*: seq[string] ## absolute; files and directories
    crateName*: string  ## from `<crate>-<hash>.d`, empty if unknown
    compiled*: bool     ## has files in deps/ or a build-script binary
    newestMtime*: int64 ## unix seconds, newest write among the paths
    bytes*: int64

proc embeddedUnitHash*(name: string): string =
  ## The unit hash a cargo-generated file or directory name carries: the
  ## last `-<16 hex digits>` that is followed by a dot or ends the name
  ## (`libc1-64b61c28001f86a6.rmeta`, `app-a027ea8afa199e3b`,
  ## `app-a027ea8afa199e3b.d`). Empty when the name carries none.
  var i = name.len - 1
  while i >= UnitHashLen + 1:
    # candidate hash occupies [i - UnitHashLen + 1 .. i] preceded by '-'
    let start = i - UnitHashLen + 1
    if name[start - 1] == '-' and
        (i == name.len - 1 or name[i + 1] == '.') and
        isUnitHash(name[start .. i]):
      return name[start .. i]
    dec i

proc newestMtimeOf(path: string): int64 =
  try:
    result = getLastModificationTime(path).toUnix
  except OSError:
    result = 0

proc fileIdOf(path: string): tuple[device: int64, file: int64] =
  try:
    let info = getFileInfo(path, followSymlink = false)
    (int64(info.id.device), int64(info.id.file))
  except OSError:
    (-1'i64, -1'i64)

proc sumBytes(path: string; seen: var HashSet[(int64, int64)];
              total: var int64) =
  var info: FileInfo
  try:
    info = getFileInfo(path, followSymlink = false)
  except OSError:
    return
  if info.kind == pcDir:
    for kind, child in walkDir(path):
      discard kind
      sumBytes(child, seen, total)
  else:
    let id = (int64(info.id.device), int64(info.id.file))
    if id notin seen:
      seen.incl id
      total += info.size

proc treeBytes*(path: string): int64 =
  ## Bytes of every file under `path` (or of `path` itself), each hard-linked
  ## file counted once and symlinks counted as links, never followed. This is
  ## the quantity the janitor reports and the tests bound.
  var seen = initHashSet[(int64, int64)]()
  sumBytes(path, seen, result)

proc treeNewestMtime*(path: string; depth = 2): int64 =
  ## Newest modification time of `path` and, for a directory, of its content
  ## down to `depth` levels. Unit directories are shallow, so this stays cheap.
  result = newestMtimeOf(path)
  if depth > 0 and dirExists(path) and not symlinkExists(path):
    for kind, child in walkDir(path):
      discard kind
      result = max(result, treeNewestMtime(child, depth - 1))

proc readFingerprintRustc*(fingerprintUnitDir: string): string =
  ## The `rustc` field of a unit's fingerprint JSON (cargo's own file; the
  ## janitor only reads it), as decimal text, or "" when it cannot be read.
  ## Cargo writes it as `<kind>-<target>.json` beside the unit's freshness
  ## stamp; any one of the files names the toolchain.
  try:
    for kind, path in walkDir(fingerprintUnitDir):
      if kind == pcFile and path.endsWith(".json"):
        let node = parseJson(readFile(path))
        if node.kind == JObject and node.hasKey("rustc") and
            node["rustc"].kind in {JInt}:
          return $node["rustc"].getBiggestInt
  except CatchableError:
    discard
  ""

proc isProfileDir*(dir: string): bool =
  dirExists(dir / FingerprintDir) and dirExists(dir / DepsDir)

proc profileAbs*(targetDir, profileRel: string): string =
  var native = profileRel
  when DirSep != '/':
    native = native.replace('/', DirSep)
  targetDir / native

proc indexProfileDir*(profileAbsDir: string): OrderedTable[string, UnitEntries] =
  ## Group every hash-named entry of `deps/`, `.fingerprint/` and `build/` by
  ## unit hash. Entries without a unit hash in their name are not cargo's
  ## unit files and are not indexed, so they are never candidates for
  ## deletion.
  result = initOrderedTable[string, UnitEntries]()
  for sub in [FingerprintDir, DepsDir, BuildDir]:
    let subDir = profileAbsDir / sub
    if not dirExists(subDir): continue
    var names: seq[string]
    for kind, path in walkDir(subDir):
      discard kind
      names.add path.extractFilename
    names.sort()
    for name in names:
      let hash = embeddedUnitHash(name)
      if hash.len == 0: continue
      let path = subDir / name
      var entries = result.getOrDefault(hash, UnitEntries(hash: hash))
      entries.paths.add path
      entries.newestMtime = max(entries.newestMtime, treeNewestMtime(path))
      entries.bytes += treeBytes(path)
      if sub == DepsDir: entries.compiled = true
      # `<crate>-<hash>.d` (in deps/ or inside build/<pkg>-<hash>/) names the
      # crate whose incremental directory belongs to this unit.
      if sub == DepsDir and name.endsWith(".d") and entries.crateName.len == 0:
        let stem = name[0 ..< name.len - 2]
        if stem.endsWith("-" & hash):
          entries.crateName = stem[0 ..< stem.len - hash.len - 1]
      elif sub == BuildDir and dirExists(path) and entries.crateName.len == 0:
        for kind, child in walkDir(path):
          discard kind
          let childName = child.extractFilename
          if childName.endsWith("-" & hash & ".d"):
            entries.crateName = childName[0 ..< childName.len - hash.len - 3]
            entries.compiled = true
            break
      result[hash] = entries

proc fingerprintRustcOf*(profileAbsDir, hash: string;
                         index: OrderedTable[string, UnitEntries]): string =
  if hash notin index: return ""
  for path in index[hash].paths:
    if path.parentDir.extractFilename == FingerprintDir and dirExists(path):
      let value = readFingerprintRustc(path)
      if value.len > 0: return value
  ""

proc incrementalCrateName*(dirName: string): string =
  ## `c1-30ofg614d7ypr` -> `c1`; rustc names the directory
  ## `<crate>-<base36 id>`, crate names have no dashes.
  let dash = dirName.rfind('-')
  if dash <= 0: "" else: dirName[0 ..< dash]

proc normalizeCrateName*(targetName: string): string =
  targetName.replace('-', '_')

proc inodeIndexOfDeps*(profileAbsDir: string): Table[(int64, int64), string] =
  ## file id -> hash for the hash-named files of `deps/`; resolves final
  ## artifacts, which cargo hard-links out of `deps/` and reports by their
  ## unhashed names.
  result = initTable[(int64, int64), string]()
  let deps = profileAbsDir / DepsDir
  if not dirExists(deps): return
  for kind, path in walkDir(deps):
    if kind != pcFile: continue
    let hash = embeddedUnitHash(path.extractFilename)
    if hash.len > 0:
      result[fileIdOf(path)] = hash

proc fileIdOfPath*(path: string): tuple[device: int64, file: int64] = fileIdOf(path)
