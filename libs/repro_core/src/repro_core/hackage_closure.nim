## The pinned Hackage dependency closure of a from-source Haskell recipe.
##
## ## What this is for
##
## A from-source Haskell package builds with `cabal build` and no network,
## and cabal needs every Hackage package its plan uses already present in a
## package repository it can read. The source tarball a recipe fetches is
## the package and nothing else. This module is the committed description of
## the rest: a manifest of the files of a `file+noindex` package repository
## -- one source distribution per planned package, plus the revised `.cabal`
## file Hackage serves when the plan used a revision -- each pinned by URL
## and SHA-256.
##
## The vendor action (`repro_project_dsl/hackage_vendor`) downloads every
## file, verifies it, and lays them out flat in one directory: that directory
## IS a `file+noindex` repository, the only one the build's private cabal
## configuration names. A package the manifest missed cannot come from
## anywhere else, so it fails the solver offline rather than being fetched.
##
## ## Why revised `.cabal` files are part of it
##
## Hackage lets maintainers revise a released package's `.cabal` file
## (usually to widen or narrow a dependency bound), and cabal's solver reads
## the REVISED description from the index, not the one inside the tarball. A
## plan made against the index can therefore depend on a revision. cabal
## reads `<name>-<version>.cabal` beside `<name>-<version>.tar.gz` in a
## `file+noindex` repository as that package's description, so committing
## the revision the plan used reproduces the plan offline.
##
## ## Where the manifest comes from
##
## Generated, not hand-written, by reprobuild-packages'
## `tools/hackage_closure_manifest.nim` from the `plan.json` cabal writes
## when it solves a build against a pinned index state. `plan.json` records
## each planned package's tarball SHA-256 (`pkg-src-sha256`) and the
## SHA-256 of the description it used (`pkg-cabal-sha256`); the generator
## downloads both and checks them against those values, so the manifest is
## bound to the plan, not merely to what Hackage served on the day.
##
## ## Format
##
## ```
## # repro hackage vendor manifest v1
## <file-name> <sha256> <url>
## ```
##
## `<file-name>` is `<name>-<version>.tar.gz` or `<name>-<version>.cabal`;
## fields are whitespace-separated; `#` lines are comments. Nothing here
## opens a socket or touches the filesystem except the path helpers.

import std/[os, sequtils, sets, strutils]

type
  HackageClosureError* = object of CatchableError

  HackageVendorEntry* = object
    fileName*: string
      ## `<name>-<version>.tar.gz` (a source distribution) or
      ## `<name>-<version>.cabal` (the revised description the plan used).
    sha256*: string
    url*: string

const
  HackageVendorManifestHeader* = "# repro hackage vendor manifest v1"
  HackageVendorManifestName* = "hackage-vendor.manifest"
    ## The committed manifest, beside the recipe's `repro.nim`.
  HackageVendorSubdir* = ".repro/hackage-vendor"
    ## Scratch root for the repository, the download cache and the private
    ## cabal directory. Under `.repro/` so `repro clean` takes it.
  HackageDownloadBase* = "https://hackage.haskell.org/package/"

proc isSdist*(entry: HackageVendorEntry): bool =
  entry.fileName.endsWith(".tar.gz")

proc packageId*(entry: HackageVendorEntry): string =
  ## `<name>-<version>` of the file.
  if entry.isSdist: entry.fileName[0 ..< ^".tar.gz".len]
  else: entry.fileName[0 ..< ^".cabal".len]

proc validPackageId(id: string): bool =
  ## `<name>-<version>`: a Hackage package name (alphanumeric words joined
  ## by `-`, at least one letter per word) and a dotted numeric version.
  let dash = id.rfind('-')
  if dash <= 0 or dash == id.len - 1:
    return false
  let name = id[0 ..< dash]
  let version = id[dash + 1 .. ^1]
  for word in name.split('-'):
    if word.len == 0 or not word.allCharsInSet(Letters + Digits) or
        not word.anyIt(it in Letters):
      return false
  for part in version.split('.'):
    if part.len == 0 or not part.allCharsInSet(Digits):
      return false
  true

proc sdistUrl*(packageId: string): string =
  HackageDownloadBase & packageId & "/" & packageId & ".tar.gz"

proc revisionUrl*(packageId: string; revision: int): string =
  HackageDownloadBase & packageId & "/revision/" & $revision & ".cabal"

proc renderHackageVendorManifest*(entries: openArray[HackageVendorEntry];
                                  comments: openArray[string] = []): string =
  ## Serialise entries to the committed form. `comments` become `#` lines
  ## after the header.
  result = HackageVendorManifestHeader & "\n"
  for line in comments:
    result.add(if line.len == 0: "#\n" else: "# " & line & "\n")
  for entry in entries:
    result.add(entry.fileName & " " & entry.sha256 & " " & entry.url & "\n")

proc parseHackageVendorManifest*(text: string): seq[HackageVendorEntry] =
  ## Read a committed manifest back, refusing anything it does not
  ## understand: a line skipped here is a package missing from the
  ## repository, and that fails inside cabal's solver, far from the cause.
  var sawHeader = false
  var names = initHashSet[string]()
  var lineNo = 0
  for rawLine in text.splitLines():
    inc lineNo
    let line = rawLine.strip()
    if line.len == 0:
      continue
    if not sawHeader:
      if line != HackageVendorManifestHeader:
        raise newException(HackageClosureError,
          "hackage vendor manifest line " & $lineNo & ": expected the " &
          "header '" & HackageVendorManifestHeader & "', got: " & line)
      sawHeader = true
      continue
    if line.startsWith("#"):
      continue
    let fields = line.splitWhitespace()
    if fields.len != 3:
      raise newException(HackageClosureError,
        "hackage vendor manifest line " & $lineNo & ": expected " &
        "'<file-name> <sha256> <url>', got: " & line)
    let entry = HackageVendorEntry(fileName: fields[0],
      sha256: fields[1].toLowerAscii(), url: fields[2])
    if not (entry.fileName.endsWith(".tar.gz") or
        entry.fileName.endsWith(".cabal")) or
        not validPackageId(entry.packageId):
      raise newException(HackageClosureError,
        "hackage vendor manifest line " & $lineNo & ": file name is not " &
        "<name>-<version>.tar.gz or <name>-<version>.cabal: " &
        entry.fileName)
    if entry.sha256.len != 64 or not entry.sha256.allCharsInSet(HexDigits):
      raise newException(HackageClosureError,
        "hackage vendor manifest line " & $lineNo & ": sha256 is not 64 " &
        "hex characters: " & fields[1])
    if not entry.url.startsWith("https://"):
      raise newException(HackageClosureError,
        "hackage vendor manifest line " & $lineNo & ": url is not https: " &
        entry.url)
    if entry.fileName in names:
      raise newException(HackageClosureError,
        "hackage vendor manifest line " & $lineNo & ": " & entry.fileName &
        " is listed twice")
    names.incl(entry.fileName)
    result.add(entry)
  if not sawHeader:
    raise newException(HackageClosureError,
      "hackage vendor manifest: no header line")
  # A revised description without its tarball would be a package cabal
  # can plan but not build.
  for entry in result:
    if not entry.isSdist and (entry.packageId & ".tar.gz") notin names:
      raise newException(HackageClosureError,
        "hackage vendor manifest: " & entry.fileName & " has no " &
        entry.packageId & ".tar.gz beside it")

proc hackageVendorManifestPath*(projectRoot: string): string =
  projectRoot / HackageVendorManifestName

proc hackageVendorRoot*(projectRoot: string): string =
  projectRoot / HackageVendorSubdir

proc hackageVendorRepoDir*(projectRoot: string): string =
  ## The `file+noindex` repository: every manifest file, flat.
  hackageVendorRoot(projectRoot) / "repo"

proc hackageVendorCacheDir*(projectRoot: string): string =
  ## Downloads, kept across runs so a re-vendor does not re-download.
  hackageVendorRoot(projectRoot) / "downloads"

proc hackageCabalDir*(projectRoot: string): string =
  ## The build's private `CABAL_DIR`: its `config` names the vendored
  ## repository and nothing else, and its `store` holds the built
  ## dependencies. Nothing from the user's own cabal directory is read.
  hackageVendorRoot(projectRoot) / "cabal"

proc hackageVendorStampPath*(projectRoot: string): string =
  hackageVendorRoot(projectRoot) / "vendor.stamp"

proc hackageCabalConfig*(repoDir: string): string =
  ## The private cabal configuration: one `file+noindex` repository.
  ##
  ## Forward slashes on every host: `file+noindex:///abs/path` on POSIX and
  ## `file+noindex://C:/abs/path` on Windows, the spellings cabal parses.
  let url = repoDir.replace('\\', '/')
  "repository reprobuild-vendor\n" &
  "  url: file+noindex://" & url & "\n"
