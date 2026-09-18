## ``Cargo.lock`` reader and crates.io vendor planner.
##
## ## What this is for
##
## A from-source Rust package has to build with no network access after its
## fetch step, and `cargo build` needs every transitive dependency present
## before it will run offline. The crate tarball a recipe fetches contains
## the package and nothing else, so the dependency closure has to be fetched
## too — and the only pinned, hash-carrying description of that closure is
## the `Cargo.lock` inside the fetched source.
##
## This module turns that file into a download plan: for every registry
## dependency, the exact URL to fetch and the exact SHA-256 to verify it
## against, both taken from the lockfile rather than from a resolver. Nothing
## here opens a socket or touches the filesystem; it reads text and returns
## data, so the plan is testable without a network and the fetching is
## somebody else's job.
##
## ## Why a dedicated parser rather than a TOML deserializer
##
## `Cargo.lock` is machine-written by cargo to a fixed shape — a `version`
## key, then a series of `[[package]]` tables with string and string-array
## fields. That is a small enough grammar to read exactly, and reading it
## exactly is the point: this parser REFUSES what it does not understand
## instead of skipping it. A generic deserializer that silently ignored an
## unrecognised construct would produce a plan that is short by a crate, and
## a build missing one dependency fails a long way from here with a message
## about a missing crate rather than about a lockfile.
##
## The refusals are deliberate and each one is a case the plan would
## otherwise get wrong:
##
## * an unknown lockfile `version` — cargo has changed the file's semantics
##   across versions (v1 put checksums in a `[metadata]` table, v2 moved
##   them onto the package, v3 changed source encoding), so accepting an
##   unknown one is guessing;
## * a registry package with no `checksum` — there would be nothing to
##   verify the download against;
## * a `git+` source — those are not on crates.io and need a clone, which
##   this plan cannot express;
## * a syntactically valid line this module does not recognise inside a
##   `[[package]]` block.
##
## A package with NO `source` key is the local workspace member itself and
## is correctly absent from the plan — it is the thing being built.

import std/[algorithm, os, strutils, tables]

type
  CargoLockError* = object of CatchableError
    ## Raised for any lockfile this module will not read exactly. The
    ## message names the line so a recipe author can see what to look at.

  CargoLockPackage* = object
    ## One `[[package]]` entry, carrying only the fields a vendor plan
    ## needs. `dependencies` is deliberately not retained: cargo resolves
    ## the graph itself from the vendored directory, and keeping an edge
    ## list here would invite this module to grow a resolver.
    name*: string
    version*: string
    source*: string
      ## Empty for a workspace-local package — the crate being built.
    checksum*: string
      ## SHA-256 hex of the `.crate` tarball. Empty exactly when `source`
      ## is empty.

  VendorEntry* = object
    ## One crate to download and unpack into the vendor directory.
    name*: string
    version*: string
    url*: string
      ## The crates.io static download URL.
    sha256*: string
      ## From the lockfile. The fetch step verifies against this and
      ## nothing else — there is no second source of truth to consult.
    directoryName*: string
      ## `<name>-<version>`, which is both the directory cargo expects
      ## inside a vendored source and the name inside the `.crate`
      ## tarball.

const
  CratesIoRegistrySources* = [
    "registry+https://github.com/rust-lang/crates.io-index",
    "sparse+https://index.crates.io/",
  ]
    ## The two spellings cargo writes for crates.io: the git index (lock
    ## v2 and earlier, and v3 with the git protocol) and the sparse HTTP
    ## index (v3 with the default protocol since Rust 1.70). Both resolve
    ## to the same download host, so both map onto the same plan.

  SupportedLockVersions* = [3, 4]
    ## v3 and v4 carry per-package checksums and are what every current
    ## cargo writes. v1 and v2 are refused rather than half-supported:
    ## v1 keeps checksums in a trailing `[metadata]` table under keys of
    ## the form `checksum <name> <version> (<source>)`, which is a
    ## different parse, and a recipe pinning a decade-old lockfile should
    ## say so out loud.

  CratesIoDownloadBase* = "https://static.crates.io/crates/"
    ## `static.crates.io` rather than `crates.io/api/v1/...`: the static
    ## host serves the same bytes without a redirect, and a fetch step
    ## that does not follow redirects is one less thing that can differ
    ## between two machines.

proc isRegistrySource*(source: string): bool =
  ## Whether `source` is one of the crates.io spellings.
  for known in CratesIoRegistrySources:
    if source == known:
      return true
  false

proc stripInlineComment(line: string): string =
  ## Remove a trailing `#` comment, respecting double-quoted strings.
  ##
  ## Cargo does not write comments into the package tables, but a
  ## hand-edited lockfile may carry them and a `#` inside a URL string
  ## must not be mistaken for one.
  var inString = false
  for i, ch in line:
    if ch == '"':
      inString = not inString
    elif ch == '#' and not inString:
      return line[0 ..< i]
  line

proc parseQuoted(value, context: string; lineNo: int): string =
  ## Read a double-quoted TOML basic string.
  ##
  ## Only the escapes cargo actually emits are handled. An unknown escape
  ## raises rather than passing through: a silently mangled URL or
  ## checksum is worse than a refusal.
  let trimmed = value.strip()
  if trimmed.len < 2 or trimmed[0] != '"' or trimmed[^1] != '"':
    raise newException(CargoLockError,
      "Cargo.lock line " & $lineNo & ": expected a quoted string for " &
      context & ", got: " & trimmed)
  var i = 1
  let last = trimmed.len - 1
  while i < last:
    let ch = trimmed[i]
    if ch != '\\':
      result.add(ch)
      inc i
      continue
    inc i
    if i >= last:
      raise newException(CargoLockError,
        "Cargo.lock line " & $lineNo & ": trailing backslash in " & context)
    case trimmed[i]
    of '"': result.add('"')
    of '\\': result.add('\\')
    of 'n': result.add('\n')
    of 't': result.add('\t')
    else:
      raise newException(CargoLockError,
        "Cargo.lock line " & $lineNo & ": unsupported escape \\" &
        trimmed[i] & " in " & context)
    inc i

proc parseCargoLock*(text: string): seq[CargoLockPackage] =
  ## Read every `[[package]]` entry, in file order.
  ##
  ## Raises `CargoLockError` on anything not understood exactly — see the
  ## module docstring for why each refusal is there.
  var sawVersion = false
  var inPackage = false
  var current = CargoLockPackage()
  var pendingArray = false
  var lineNo = 0
  var packages: seq[CargoLockPackage] = @[]

  # A template rather than a closure: Nim refuses to capture ``result`` in
  # a nested proc (it would outlive the call), and accumulating into a
  # local that is returned at the end is the same thing without the
  # indirection.
  template flush() =
    if inPackage:
      if current.name.len == 0:
        raise newException(CargoLockError,
          "Cargo.lock: a [[package]] entry ending before line " & $lineNo &
          " has no name")
      if current.version.len == 0:
        raise newException(CargoLockError,
          "Cargo.lock: package '" & current.name & "' has no version")
      packages.add(current)
    current = CargoLockPackage()

  for rawLine in text.splitLines():
    inc lineNo
    let line = stripInlineComment(rawLine).strip()
    if line.len == 0:
      continue

    if pendingArray:
      # Inside a multi-line `dependencies = [` array. Cargo writes one
      # quoted entry per line and a closing bracket; nothing else.
      if line == "]" or line == "],":
        pendingArray = false
      continue

    if line == "[[package]]":
      flush()
      inPackage = true
      continue

    if line.startsWith("[["):
      raise newException(CargoLockError,
        "Cargo.lock line " & $lineNo & ": unsupported array-of-tables " &
        line & "; only [[package]] is understood")

    if line.startsWith("["):
      # A plain table. `[metadata]` is the v1 checksum table, which this
      # module refuses along with v1 itself; any other table is unknown.
      raise newException(CargoLockError,
        "Cargo.lock line " & $lineNo & ": unsupported table " & line)

    let eq = line.find('=')
    if eq <= 0:
      raise newException(CargoLockError,
        "Cargo.lock line " & $lineNo & ": expected `key = value`, got: " &
        line)
    let key = line[0 ..< eq].strip()
    let value = line[eq + 1 .. ^1].strip()

    if not inPackage:
      if key == "version":
        let parsed =
          try:
            parseInt(value)
          except ValueError:
            raise newException(CargoLockError,
              "Cargo.lock line " & $lineNo &
              ": lockfile version is not an integer: " & value)
        if parsed notin SupportedLockVersions:
          raise newException(CargoLockError,
            "Cargo.lock: lockfile version " & $parsed & " is not supported" &
            " (understood: " & $SupportedLockVersions & "). Regenerate the" &
            " lockfile with a current cargo, or pin a release that ships one.")
        sawVersion = true
        continue
      raise newException(CargoLockError,
        "Cargo.lock line " & $lineNo & ": unexpected top-level key '" &
        key & "'")

    case key
    of "name": current.name = parseQuoted(value, "package name", lineNo)
    of "version": current.version = parseQuoted(value, "version", lineNo)
    of "source": current.source = parseQuoted(value, "source", lineNo)
    of "checksum": current.checksum = parseQuoted(value, "checksum", lineNo)
    of "dependencies":
      if value == "[":
        pendingArray = true
      elif value.startsWith("[") and value.endsWith("]"):
        discard
      else:
        raise newException(CargoLockError,
          "Cargo.lock line " & $lineNo &
          ": unsupported `dependencies` value: " & value)
    else:
      raise newException(CargoLockError,
        "Cargo.lock line " & $lineNo & ": unsupported key '" & key &
        "' in [[package]]")

  flush()

  if not sawVersion:
    raise newException(CargoLockError,
      "Cargo.lock: no `version` key. Lockfiles without one are v1, whose" &
      " checksums live in a [metadata] table this reader does not parse.")
  packages

proc vendorPlan*(packages: openArray[CargoLockPackage]): seq[VendorEntry] =
  ## The crates to download, sorted by `(name, version)`.
  ##
  ## Sorted rather than file-ordered because the plan is an input to a
  ## content-addressed step: two hosts reading the same lockfile must
  ## produce byte-identical plans, and cargo's own ordering is not part of
  ## the file's contract.
  ##
  ## Workspace-local packages (no `source`) are absent — they are what the
  ## build produces. A `git+` or path source raises, because this plan has
  ## no way to express them and quietly dropping one yields a build that
  ## fails offline for a reason nothing here reported.
  var seen = initTable[string, string]()
  for pkg in packages:
    if pkg.source.len == 0:
      if pkg.checksum.len > 0:
        raise newException(CargoLockError,
          "Cargo.lock: package '" & pkg.name & "' has a checksum but no" &
          " source, which is not a shape cargo writes")
      continue
    if not isRegistrySource(pkg.source):
      raise newException(CargoLockError,
        "Cargo.lock: package '" & pkg.name & " " & pkg.version &
        "' comes from '" & pkg.source & "', which is not crates.io." &
        " A vendored build cannot express that source; vendor the" &
        " dependency into the fetched tarball or pin a release that" &
        " does not use it.")
    if pkg.checksum.len == 0:
      raise newException(CargoLockError,
        "Cargo.lock: registry package '" & pkg.name & " " & pkg.version &
        "' has no checksum, so there would be nothing to verify the" &
        " download against")
    if pkg.checksum.len != 64:
      raise newException(CargoLockError,
        "Cargo.lock: package '" & pkg.name & " " & pkg.version &
        "' has a checksum that is not 64 hex characters: " & pkg.checksum)
    for ch in pkg.checksum:
      if ch notin {'0' .. '9', 'a' .. 'f'}:
        raise newException(CargoLockError,
          "Cargo.lock: package '" & pkg.name & " " & pkg.version &
          "' has a non-lowercase-hex checksum: " & pkg.checksum)
    let key = pkg.name & " " & pkg.version
    if seen.hasKey(key):
      if seen[key] != pkg.checksum:
        raise newException(CargoLockError,
          "Cargo.lock: '" & key & "' appears twice with different" &
          " checksums")
      continue
    seen[key] = pkg.checksum
    result.add(VendorEntry(
      name: pkg.name,
      version: pkg.version,
      url: CratesIoDownloadBase & pkg.name & "/" & pkg.name & "-" &
        pkg.version & ".crate",
      sha256: pkg.checksum,
      directoryName: pkg.name & "-" & pkg.version))
  result.sort(proc(a, b: VendorEntry): int =
    result = cmp(a.name, b.name)
    if result == 0:
      result = cmp(a.version, b.version))

proc cargoChecksumJson*(entry: VendorEntry): string =
  ## The `.cargo-checksum.json` cargo requires beside every vendored
  ## crate.
  ##
  ## `files` is deliberately empty. Cargo reads it to detect a vendored
  ## source that was edited after unpacking; an empty object means "no
  ## per-file claim", which is what a freshly unpacked, never-edited
  ## directory honestly has. Populating it would mean hashing every file
  ## in every crate on every build to restate what the `package` digest —
  ## which IS checked, against the lockfile — already covers.
  "{\"files\":{},\"package\":\"" & entry.sha256 & "\"}"

proc cargoVendorConfig*(vendorDir: string): string =
  ## The `.cargo/config.toml` that points cargo at the vendored directory
  ## instead of the network.
  ##
  ## `crates-io` is the only table to replace, and adding a second one for
  ## the sparse-index URL is not belt-and-braces — it is an error.
  ##
  ## `crates-io` is a source NAME cargo knows intrinsically, and replacing
  ## it covers crates.io whichever protocol a lockfile names. A table keyed
  ## by URL is a source DEFINITION, and cargo refuses one with no location
  ## of its own:
  ##
  ##     error: no source location specified for
  ##     `source.sparse+https://index.crates.io/`, need `registry`,
  ##     `local-registry`, `directory`, or `git` defined
  ##
  ## That is what a real offline build reported against the first version
  ## of this function, whose comment claimed replacing one spelling would
  ## leave the other live. It does not: there is one source, reached two
  ## ways.
  let normalized = vendorDir.replace('\\', '/')
  result = "[source.crates-io]\n"
  result.add("replace-with = \"vendored-sources\"\n\n")
  result.add("[source.vendored-sources]\n")
  result.add("directory = \"" & normalized & "\"\n")

# ---------------------------------------------------------------------------
# The pinned manifest.
# ---------------------------------------------------------------------------
#
# A vendor plan has to be readable at GRAPH-EMISSION time, and the
# `Cargo.lock` it comes from does not exist then: the lockfile arrives with
# the source, which the fetch action has not run yet. Resolving that by
# parsing the lockfile at build time would mean the dependency closure — the
# single largest input to the build — is invisible to review, to diffing,
# and to the action fingerprint until the build is already running.
#
# So the closure is pinned beside the recipe as a manifest, generated once
# from an upstream lockfile and committed. It is a tab-separated table
# because that is the shape a three-line shell loop can consume without a
# parser, and the fetch step that consumes it is a shell loop:
#
#     while IFS="\t" read -r url sha dir; do ... done < manifest
#
# One line per crate, sorted, with a header carrying the format version.
# Refreshing it is a deliberate, reviewable act, and the diff is exactly the
# set of dependencies that moved.

const
  VendorManifestHeader* = "# repro cargo vendor manifest v1"
    ## First line of every manifest. Version-tagged so a reader that meets
    ## a manifest it cannot interpret says so instead of skipping lines it
    ## does not recognise — the same refusal posture as the lockfile
    ## reader, for the same reason.

proc renderVendorManifest*(plan: openArray[VendorEntry]): string =
  ## Serialise a plan to its committed form.
  ##
  ## Columns are url, sha256, directory name. The directory name is
  ## carried rather than recomputed so the file says, in full, what the
  ## fetch step will create — a reader of the diff does not have to know
  ## the `<name>-<version>` convention to see what moved.
  result = VendorManifestHeader & "\n"
  for entry in plan:
    result.add(entry.url & "\t" & entry.sha256 & "\t" &
      entry.directoryName & "\n")

proc parseVendorManifest*(text: string): seq[VendorEntry] =
  ## Read a committed manifest back.
  ##
  ## Strict, and for the same reason the lockfile reader is: a line this
  ## does not understand is a crate that would go missing, and a build
  ## missing one dependency fails inside cargo rather than here.
  var sawHeader = false
  var lineNo = 0
  for rawLine in text.splitLines():
    inc lineNo
    let line = rawLine.strip()
    if line.len == 0:
      continue
    if not sawHeader:
      if line != VendorManifestHeader:
        raise newException(CargoLockError,
          "cargo vendor manifest line " & $lineNo & ": expected the header " &
          "'" & VendorManifestHeader & "', got: " & line)
      sawHeader = true
      continue
    if line.startsWith("#"):
      continue
    let fields = line.split('\t')
    if fields.len != 3:
      raise newException(CargoLockError,
        "cargo vendor manifest line " & $lineNo & ": expected 3 " &
        "tab-separated fields, got " & $fields.len)
    let entry = VendorEntry(
      url: fields[0],
      sha256: fields[1],
      directoryName: fields[2])
    if not entry.url.startsWith(CratesIoDownloadBase):
      raise newException(CargoLockError,
        "cargo vendor manifest line " & $lineNo & ": url is not a " &
        "crates.io download: " & entry.url)
    if entry.sha256.len != 64:
      raise newException(CargoLockError,
        "cargo vendor manifest line " & $lineNo & ": sha256 is not 64 hex " &
        "characters: " & entry.sha256)
    # `name` and `version` are recovered from the directory name rather
    # than carried as their own columns: two spellings of the same fact
    # can disagree, and the directory name is the one the fetch step and
    # cargo both use.
    let dash = entry.directoryName.rfind('-')
    if dash <= 0 or dash == entry.directoryName.len - 1:
      raise newException(CargoLockError,
        "cargo vendor manifest line " & $lineNo & ": directory name is " &
        "not <name>-<version>: " & entry.directoryName)
    var restored = entry
    restored.name = entry.directoryName[0 ..< dash]
    restored.version = entry.directoryName[dash + 1 .. ^1]
    result.add(restored)
  if not sawHeader:
    raise newException(CargoLockError,
      "cargo vendor manifest: no header line")

# ---------------------------------------------------------------------------
# On-disk layout.
# ---------------------------------------------------------------------------
#
# These live here, in the lowest module of the cargo stack, because three
# layers need to agree on them and two of them cannot see each other: the
# CONVENTION (in `repro_standard_provider`) emits the action that creates
# the vendor tree, and a `build:`-block CONSTRUCTOR (in `repro_dsl_stdlib`,
# a layer below the provider) has to point cargo at the same tree and order
# itself after the same stamp. A constant duplicated across that boundary is
# a constant that drifts, and the symptom would be a build that vendors into
# one directory and compiles against another.

const
  CargoVendorManifestName* = "cargo-vendor.manifest"
    ## The committed manifest, beside the recipe's `repro.nim`.

  CargoVendorSubdir* = ".repro/cargo-vendor"
    ## Scratch root for the unpacked tree and the download cache. Under
    ## `.repro/` so `repro clean` takes it with everything else.

proc cargoVendorManifestPath*(projectRoot: string): string =
  projectRoot / CargoVendorManifestName

proc cargoVendorRoot*(projectRoot: string): string =
  projectRoot / CargoVendorSubdir

proc cargoVendorDir*(projectRoot: string): string =
  ## The unpacked crates — the directory `.cargo/config.toml` points at.
  cargoVendorRoot(projectRoot) / "vendor"

proc cargoVendorCacheDir*(projectRoot: string): string =
  ## The downloaded `.crate` files.
  ##
  ## Separate from the unpacked tree so a re-run that wipes the vendor
  ## directory does not re-download a closure the machine already has. Keyed
  ## by crate directory name, which carries the version, so two versions of
  ## one crate never collide.
  cargoVendorRoot(projectRoot) / "crates"

proc cargoVendorStampPath*(projectRoot: string): string =
  ## The vendor action's output, and what a compile step orders itself
  ## after.
  cargoVendorRoot(projectRoot) / "vendor.stamp"

proc cargoExtractedSourceDir*(projectRoot: string): string =
  ## Where the source tarball is extracted.
  ##
  ## Matches `fetch_action`'s default of `src` rather than reading the
  ## recipe's `extractedRoot`: a recipe that moves it has to tell both
  ## sides, and neither side can read the other's opinion from here.
  projectRoot / "src"

proc cargoConfigDir*(projectRoot: string): string =
  ## `.cargo/` beside the EXTRACTED SOURCE, not beside the recipe: cargo
  ## searches upward from the manifest directory it is building, and the
  ## recipe root is not on that path.
  cargoExtractedSourceDir(projectRoot) / ".cargo"
