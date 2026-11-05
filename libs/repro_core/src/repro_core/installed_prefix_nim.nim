## The Nim compiler an installed reprobuild prefix ships, checked before use
## (reprobuild-pm Distribution-And-Packaging.md §5.3, amendment N3, approved
## by Zahary Karadjov, 2026-11-04).
##
## An installed prefix ships the Nim fork its images were built by under
## `nim/`, because the appliance compiles providers and profiles itself. The
## compiler is found by the running image's own prefix (the §5.1 anchor),
## never by `PATH` and never by a path baked in at build time, and it is used
## only when it is the fork the prefix records:
##
## * `nim/.nim-fork-revision` must equal the `nim_fork=` line of
##   `share/repro/cross-build-info`, and both must exist;
## * its release, read from `nim/lib/system/compilation.nim`, must lie in the
##   range the caller requires (the bootstrap's `nim >=2.2 <3.0`, or a
##   project's own `uses: nim` range).
##
## Both the provider compile (`repro_tool_profiles.ensureBootstrapToolchainEnv`)
## and the profile compile (`repro_profile_compile.resolveProfileNimCompiler`)
## resolve through `findInstalledPrefixNim`, so one installed engine compiles
## both with one checked compiler.
##
## Both producers of a prefix write this record: the graph's `.#prefix`
## (`packaging/producers/installed_prefix`, from the catalog's `nim-fork`)
## and `scripts/cross/build_linux_cross.sh` (`scripts/cross/nim_fork_record.sh`).

import std/[os, strutils]

const
  InstalledPrefixRecordPath* = "share" / "repro" / "cross-build-info"
    ## Where an installed prefix records how it was built.
  InstalledPrefixNimRevisionPath* = "nim" / ".nim-fork-revision"
    ## The fork revision the shipped compiler was built from.
  InstalledPrefixNimEnvVar* = "REPRO_INSTALLED_PREFIX_NIM"
    ## Set by the provider-compile bootstrap when it chose the prefix's Nim,
    ## to `<version>`, so a later check of the project's own `uses: nim`
    ## range knows which release it has to admit.

type
  InstalledPrefixNimError* = object of CatchableError
    ## The prefix ships a Nim that may not be used, and why.

  InstalledPrefixNim* = object
    prefix*: string
    exe*: string      ## "" when no candidate prefix ships `nim/bin/nim`
    version*: string
    revision*: string

proc installedPrefixNimVersion*(nimTree: string): string =
  ## The Nim release `nimTree` is, from its `lib/system/compilation.nim`
  ## (`NimMajor` / `NimMinor` / `NimPatch`), or "" when it says none. Read,
  ## not run: on the build host the compiler is for another machine, and on
  ## its own host this costs no spawn.
  let file = nimTree / "lib" / "system" / "compilation.nim"
  if not fileExists(file):
    return ""
  var parts = ["", "", ""]
  for line in readFile(file).splitLines:
    for i, name in ["NimMajor", "NimMinor", "NimPatch"]:
      if line.strip().startsWith(name & "*") and "=" in line:
        parts[i] = line.rsplit('=', maxsplit = 1)[1].strip()
  for part in parts:
    if part.len == 0 or not part.allCharsInSet(Digits):
      return ""
  parts.join(".")

proc compareReleases(a, b: string): int =
  ## Numeric comparison of dotted releases; a missing component is 0.
  let x = a.split('.')
  let y = b.split('.')
  for i in 0 ..< max(x.len, y.len):
    let u = if i < x.len: (try: parseInt(x[i]) except ValueError: 0) else: 0
    let v = if i < y.len: (try: parseInt(y[i]) except ValueError: 0) else: 0
    if u != v:
      return cmp(u, v)
  0

proc nimReleaseAdmitted*(version, rawConstraint: string): bool =
  ## Whether `version` satisfies a `uses:` constraint such as
  ## `nim >=2.2 <3.0` or `nim ==2.3.1` (the package name may be absent; the
  ## comparators may be separated by spaces or commas). An empty or
  ## name-only constraint admits every release.
  var tokens = rawConstraint.replace(",", " ").splitWhitespace()
  if tokens.len > 0 and tokens[0][0] notin {'<', '>', '=', '0' .. '9'}:
    tokens.delete(0)
  for token in tokens:
    var op = ""
    for prefix in [">=", "<=", "==", ">", "<", "="]:
      if token.startsWith(prefix):
        op = prefix
        break
    let bound = token[op.len .. ^1].strip()
    if bound.len == 0:
      continue
    let c = compareReleases(version, bound)
    let ok =
      case op
      of ">=": c >= 0
      of ">": c > 0
      of "<=": c <= 0
      of "<": c < 0
      else: c == 0
    if not ok:
      return false
  true

proc findInstalledPrefixNim*(prefixes: openArray[string];
                             rawConstraint = "nim >=2.2 <3.0"):
    InstalledPrefixNim =
  ## The first of `prefixes` that ships `nim/bin/nim`, checked; an empty
  ## `exe` when none ships one (the caller keeps its other routes). Raises
  ## `InstalledPrefixNimError`, naming what it found, when the shipped
  ## compiler is not the recorded fork, the record is missing, or its
  ## release is outside `rawConstraint`.
  for prefix in prefixes:
    if prefix.len == 0:
      continue
    let exe = prefix / "nim" / "bin" / addFileExt("nim", ExeExt)
    if not fileExists(exe):
      continue
    let record = prefix / InstalledPrefixRecordPath
    if not fileExists(record):
      raise newException(InstalledPrefixNimError, "the installed prefix " &
        prefix & " ships " & exe & " but no build record " & record &
        " to check it against" &
        "\n  remedy: reinstall the prefix")
    var recorded = ""
    for line in readFile(record).splitLines:
      if line.startsWith("nim_fork="):
        recorded = line["nim_fork=".len .. ^1].strip()
    let revisionFile = prefix / InstalledPrefixNimRevisionPath
    let shipped =
      if fileExists(revisionFile): readFile(revisionFile).strip() else: ""
    if recorded.len == 0 or shipped != recorded:
      raise newException(InstalledPrefixNimError, "the installed prefix " &
        prefix & " ships a Nim that is not the fork it records" &
        "\n  " & InstalledPrefixNimRevisionPath & ": " &
        (if shipped.len > 0: shipped else: "(missing)") &
        "\n  " & InstalledPrefixRecordPath & " nim_fork: " &
        (if recorded.len > 0: recorded else: "(missing)") &
        "\n  remedy: reinstall the prefix; its nim/ was replaced, damaged, " &
        "or written by a producer that does not record the fork")
    let version = installedPrefixNimVersion(prefix / "nim")
    if version.len == 0 or not nimReleaseAdmitted(version, rawConstraint):
      raise newException(InstalledPrefixNimError, "the installed prefix " &
        prefix & " ships Nim " &
        (if version.len > 0: version else: "(unknown release)") &
        ", outside the range " & rawConstraint &
        "\n  remedy: pin the provider compiler in the project's lock, or " &
        "widen the range")
    return InstalledPrefixNim(prefix: prefix, exe: exe, version: version,
      revision: recorded)
