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

import repro_solver/uses_constraints

const
  InstalledPrefixRecordPath* = "share" / "repro" / "cross-build-info"
    ## Where an installed prefix records how it was built.
  InstalledPrefixNimRevisionPath* = "nim" / ".nim-fork-revision"
    ## The fork revision the shipped compiler was built from.
  InstalledPrefixCompilerEnvVar = "REPRO_NIM_COMPILER"
    ## The provider compiler in use (`repro_tool_profiles.bootstrapNimCompilerEnv`),
    ## named in a refusal.
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

proc nimReleaseAdmitted*(version, rawConstraint: string): bool =
  ## Whether release `version` satisfies the `uses:` constraint
  ## `rawConstraint` (`nim >=2.2 <3.0`, `nim ^2.2`, `nim v2.3.1`, ...), read
  ## by the `uses:` grammar itself (`repro_solver/uses_constraints`), so the
  ## installed prefix's compiler is admitted exactly when the recipe's range
  ## admits it (N3: "refused by the existing range check"). A name-only
  ## constraint admits every release; an unparseable one admits none.
  parseReproUsesConstraint(rawConstraint).admits(version)

proc requireUsesAdmitInstalledPrefixNim*(rawConstraints: openArray[string]) =
  ## N3: when the provider compiler is the installed prefix's Nim (the
  ## bootstrap recorded its release in `$REPRO_INSTALLED_PREFIX_NIM`), a
  ## recipe whose own `uses:` names `nim` with a range that excludes that
  ## release is refused, naming both, rather than compiled with a compiler
  ## the recipe says it does not accept. `rawConstraints` are the recipe's
  ## `uses:` entries as written. A pinned compiler (rule 1) never sets the
  ## variable, so it is never second-guessed here.
  ##
  ## Run by every route that hands an engine a recipe's interface: the
  ## extraction itself (`repro_interface_artifacts.extractInterfaceFromModule`)
  ## and the build engine's interface edge, whose cache hit runs no
  ## extraction (`repro_cli_support.extractInterfaceEdge`).
  let version = getEnv(InstalledPrefixNimEnvVar)
  if version.len == 0:
    return
  for raw in rawConstraints:
    let constraint = parseReproUsesConstraint(raw)
    if constraint.selector != "nim":
      continue
    if not constraint.admits(version):
      raise newException(InstalledPrefixNimError, "the recipe's `uses: \"" &
        raw & "\"` excludes Nim " & version &
        ", the compiler this installed prefix ships and compiles recipes " &
        "with (" & getEnv(InstalledPrefixCompilerEnvVar) & ")" &
        "\n  remedy: widen the range to admit " & version &
        ", or pin the provider compiler in the project's lock")

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
    return InstalledPrefixNim(prefix: prefix, exe: exe, version: version)
