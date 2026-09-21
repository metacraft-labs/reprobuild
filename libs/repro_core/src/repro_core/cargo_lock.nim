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
## * a syntactically valid line this module does not recognise inside a
##   `[[package]]` block.
##
## A `git+` source is NOT refused: it becomes a git vendor entry, cloned at
## the immutable commit the lockfile pins and pointed at by a per-source
## block in `.cargo/config.toml`. A source that is neither crates.io nor
## `git+` (a `path` source, say) is still refused, because the plan has no
## way to express it.
##
## A package with NO `source` key is the local workspace member itself and
## is correctly absent from the plan — it is the thing being built.

import std/[algorithm, os, sets, strutils, tables]

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
    ## One crate to place into the vendor directory. Two kinds, told apart
    ## by `gitSource`: a crates.io crate (empty `gitSource`) is a `.crate`
    ## tarball fetched from `url` and verified against `sha256`; a git crate
    ## (non-empty `gitSource`) is cloned from `gitUrl` at `gitCommit` and its
    ## `gitSubdir` copied out. The two never mix per entry.
    name*: string
    version*: string
    url*: string
      ## The crates.io static download URL. Empty for a git entry.
    sha256*: string
      ## From the lockfile. The fetch step verifies against this and
      ## nothing else — there is no second source of truth to consult.
      ## Empty for a git entry: a git source has no crate-tarball digest;
      ## its `gitCommit` is the content address instead.
    directoryName*: string
      ## `<name>-<version>`, which is both the directory cargo expects
      ## inside a vendored source and the name inside the `.crate`
      ## tarball. A git crate uses the same `<name>-<version>` directory —
      ## `cargo vendor --versioned-dirs` does, and cargo finds a crate by
      ## scanning the vendor tree, not by the directory's name.
    gitSource*: string
      ## The `[source."…"]` key cargo's `.cargo/config.toml` uses for this
      ## crate's git source — the lockfile source string with its
      ## `#<commit>` fragment stripped, e.g.
      ## `git+https://github.com/x/y?tag=v1`. Empty for a crates.io entry;
      ## its presence is what makes an entry a git entry. It has to match
      ## cargo's spelling byte for byte, or the source replacement is
      ## silently ignored and the build reaches for the network.
    gitUrl*: string
      ## The bare git URL (`https://github.com/x/y`) — what `git clone`
      ## takes and what the config block's `git = ` line carries.
    gitRefKind*: string
      ## `rev`, `tag` or `branch` — the qualifier cargo's config block
      ## states beside `git`. Empty for a crates.io entry.
    gitRefValue*: string
      ## The value of that qualifier (the rev/tag/branch as written in the
      ## source).
    gitCommit*: string
      ## The resolved commit the lockfile pins in its `#<commit>` fragment.
      ## This is what the fetch step checks out — an immutable content
      ## address — regardless of whether the qualifier was a branch or tag.
    gitSubdir*: string
      ## The crate's path within the git tree, `.` for a single-crate repo.
      ## A repo can carry several crates in subdirectories, and only the
      ## one whose `Cargo.toml` matches is copied out.

proc isGit*(entry: VendorEntry): bool =
  ## Whether this entry is a git crate rather than a crates.io one.
  entry.gitSource.len > 0

proc cratePackageName*(cargoTomlText: string): string =
  ## The `name` under a `Cargo.toml`'s `[package]` table, or `""` when the
  ## file has none (a virtual-workspace manifest with only `[workspace]`).
  ##
  ## A targeted scan, not a TOML deserializer, for the same reason the
  ## lockfile reader is one: only one key in one table is wanted, and a
  ## manifest carries `name` keys in other tables (`[dependencies]` entries,
  ## `[[bin]]`) that a blind search would trip over. So the walk tracks the
  ## current `[table]` header and reads `name` only while inside
  ## `[package]`. This is how the generator tells which subdirectory of a
  ## cloned multi-crate git repo holds the crate a lockfile names.
  var inPackage = false
  for rawLine in cargoTomlText.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if line.startsWith("["):
      inPackage = line == "[package]"
      continue
    if not inPackage:
      continue
    let eq = line.find('=')
    if eq < 0:
      continue
    if line[0 ..< eq].strip() != "name":
      continue
    # `name = "..."` — take the first double-quoted value.
    let rest = line[eq + 1 .. ^1].strip()
    if rest.len >= 2 and rest[0] == '"':
      let close = rest.find('"', 1)
      if close > 0:
        return rest[1 ..< close]
  ""

proc parseGitSource*(source: string): tuple[configKey, url, refKind,
    refValue, commit: string] =
  ## Decompose a lockfile `git+…` source string into the pieces cargo's
  ## vendor config and a clone both need. Input, as cargo writes it:
  ##
  ##   git+https://github.com/x/y?tag=v1.1.3#a33a00f8dadbade0…
  ##
  ## yields configKey `git+https://github.com/x/y?tag=v1.1.3` (the
  ## `#<commit>` fragment dropped, because cargo's `[source."…"]` key drops
  ## it), url `https://github.com/x/y`, refKind `tag`, refValue `v1.1.3`,
  ## commit `a33a00f8…`. A source with no `?<qualifier>` (a default-branch
  ## dependency) yields an empty refKind/refValue; the `#<commit>` is always
  ## present in a lockfile, and its absence is refused rather than guessed.
  if not source.startsWith("git+"):
    raise newException(CargoLockError,
      "not a git source: " & source)
  let hashPos = source.rfind('#')
  if hashPos < 0:
    raise newException(CargoLockError,
      "git source has no '#<commit>' fragment, so there is no immutable" &
      " revision to check out: " & source)
  result.commit = source[hashPos + 1 .. ^1]
  if result.commit.len == 0:
    raise newException(CargoLockError,
      "git source has an empty '#<commit>' fragment: " & source)
  result.configKey = source[0 ..< hashPos]
  let afterScheme = result.configKey["git+".len .. ^1]
  let qPos = afterScheme.find('?')
  if qPos < 0:
    result.url = afterScheme
  else:
    result.url = afterScheme[0 ..< qPos]
    let query = afterScheme[qPos + 1 .. ^1]
    let eqPos = query.find('=')
    if eqPos < 0:
      raise newException(CargoLockError,
        "git source qualifier is not '<kind>=<value>': " & source)
    result.refKind = query[0 ..< eqPos]
    result.refValue = query[eqPos + 1 .. ^1]
    if result.refKind notin ["rev", "tag", "branch"]:
      raise newException(CargoLockError,
        "git source qualifier '" & result.refKind & "' is not one of" &
        " rev/tag/branch: " & source)
  if result.url.len == 0:
    raise newException(CargoLockError,
      "git source has no URL: " & source)

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
    if pkg.source.startsWith("git+"):
      # A git dependency. It is cloned at its pinned commit and its crate
      # subtree copied into the vendor tree, and cargo is pointed at it by a
      # per-source block in `.cargo/config.toml`. The subdirectory within
      # the repo is left as `.` here — the single-crate-repo case, which is
      # what a lockfile alone can prove; a repo that carries several crates
      # needs the subdir resolved by scanning it, which is the generator's
      # job, not this pure-lockfile planner's.
      let git = parseGitSource(pkg.source)
      result.add(VendorEntry(
        name: pkg.name,
        version: pkg.version,
        directoryName: pkg.name & "-" & pkg.version,
        gitSource: git.configKey,
        gitUrl: git.url,
        gitRefKind: git.refKind,
        gitRefValue: git.refValue,
        gitCommit: git.commit,
        gitSubdir: "."))
      continue
    if not isRegistrySource(pkg.source):
      raise newException(CargoLockError,
        "Cargo.lock: package '" & pkg.name & " " & pkg.version &
        "' comes from '" & pkg.source & "', which is neither crates.io" &
        " nor a git source. A vendored build cannot express that source;" &
        " vendor the dependency into the fetched tarball or pin a release" &
        " that does not use it.")
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
  ##
  ## A git crate has no crate-tarball digest, so its `package` is `null` —
  ## the spelling cargo writes for a git-vendored crate. Verified against a
  ## real offline build: cargo accepts an empty `files` map with a null
  ## `package` for a git source exactly as it does the `package`-digest
  ## form for a crates.io one, so neither kind needs per-file hashing.
  if entry.isGit:
    "{\"files\":{},\"package\":null}"
  else:
    "{\"files\":{},\"package\":\"" & entry.sha256 & "\"}"

proc cargoVendorConfig*(vendorDir: string;
    plan: openArray[VendorEntry] = @[]): string =
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
  ## Each git source in `plan` gets its own block too, keyed by the exact
  ## `[source."git+…"]` spelling cargo uses and stating `git = ` plus the
  ## one `rev`/`tag`/`branch` qualifier the lockfile carried. A missing or
  ## misspelled block is not a soft failure: cargo falls through to the
  ## network for that crate and the offline build dies, so the key comes
  ## verbatim from `parseGitSource`.
  let normalized = vendorDir.replace('\\', '/')
  result = "[source.crates-io]\n"
  result.add("replace-with = \"vendored-sources\"\n\n")
  var emittedGit = initHashSet[string]()
  for entry in plan:
    if not entry.isGit:
      continue
    if emittedGit.containsOrIncl(entry.gitSource):
      continue
    result.add("[source.\"" & entry.gitSource & "\"]\n")
    result.add("git = \"" & entry.gitUrl & "\"\n")
    if entry.gitRefKind.len > 0:
      result.add(entry.gitRefKind & " = \"" & entry.gitRefValue & "\"\n")
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
  VendorManifestHeaderV1* = "# repro cargo vendor manifest v1"
    ## The original header: crates.io-only manifests, three-column lines.
  VendorManifestHeaderV2* = "# repro cargo vendor manifest v2"
    ## v2 adds git-source lines (a leading `git` column) beside the
    ## crates.io lines, which keep their exact v1 shape. A v1 reader is
    ## refused a v2 file rather than left to skip lines it cannot read —
    ## the same refusal posture as the lockfile reader.
  VendorManifestHeader* = VendorManifestHeaderV2
    ## What the emitter writes. Both headers are accepted on read, so the
    ## committed v1 manifests (all crates.io-only) keep parsing unchanged.

proc renderVendorManifest*(plan: openArray[VendorEntry]): string =
  ## Serialise a plan to its committed form.
  ##
  ## A crates.io crate is three columns — url, sha256, directory name — the
  ## directory name carried rather than recomputed so the file says, in
  ## full, what the fetch step will create. A git crate is five: a leading
  ## `git` marker, the FULL lockfile source (with its `#<commit>` so the
  ## checkout is pinned in the file), the crate's subdirectory within the
  ## repo, and the directory name.
  result = VendorManifestHeader & "\n"
  for entry in plan:
    if entry.isGit:
      result.add("git\t" & entry.gitSource & "#" & entry.gitCommit & "\t" &
        entry.gitSubdir & "\t" & entry.directoryName & "\n")
    else:
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
      if line notin [VendorManifestHeaderV1, VendorManifestHeaderV2]:
        raise newException(CargoLockError,
          "cargo vendor manifest line " & $lineNo & ": expected the header " &
          "'" & VendorManifestHeaderV2 & "' (or v1), got: " & line)
      sawHeader = true
      continue
    if line.startsWith("#"):
      continue
    let fields = line.split('\t')
    if fields.len >= 1 and fields[0] == "git":
      # git<TAB><full-lockfile-source><TAB><subdir><TAB><name-version>
      if fields.len != 4:
        raise newException(CargoLockError,
          "cargo vendor manifest line " & $lineNo & ": a git line is " &
          "'git<TAB>source<TAB>subdir<TAB>dir', expected 4 fields, got " &
          $fields.len)
      let git = parseGitSource(fields[1])
      let dir = fields[3]
      let dash = dir.rfind('-')
      if dash <= 0 or dash == dir.len - 1:
        raise newException(CargoLockError,
          "cargo vendor manifest line " & $lineNo & ": directory name is " &
          "not <name>-<version>: " & dir)
      result.add(VendorEntry(
        name: dir[0 ..< dash],
        version: dir[dash + 1 .. ^1],
        directoryName: dir,
        gitSource: git.configKey,
        gitUrl: git.url,
        gitRefKind: git.refKind,
        gitRefValue: git.refValue,
        gitCommit: git.commit,
        gitSubdir: fields[2]))
      continue
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
