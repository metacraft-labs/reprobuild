## `repro home` subcommands (M61 + M63).
##
## CLI surface over the M60 structural editor in
## `libs/repro_home_intent`. Every edit goes through the editor library's
## public API (`addPackageReference`, `removePackageReference`,
## `setHostActivities`, etc.); this module does NOT bypass the editor.
##
## M63 wires the apply pipeline:
##   - A new `repro home apply` subcommand runs the pipeline directly.
##   - `add`, `remove`, `enable`, `disable` run the apply pipeline
##     inline after a successful edit unless `--no-apply` was passed.
##   - `--now` on current-host `enable`/`disable` is the default local
##     apply behaviour. `--host <name>` without `--now` is a pure
##     intent edit; `--host <name> --now` drives M71 remote apply.
##
## ## Package-catalog lookup seam
##
## Spec rule: `repro home add` must reject packages not declared by the
## profile's package catalog (typo / missing `uses:`). The catalog is
## owned by the profile-compilation pipeline (M63), so M61 does NOT
## resolve the catalog at runtime; instead it exposes a typed seam
## (`PackageCatalogLookup`) that the apply pipeline will populate.
##
## At M61 the seam is fed from either:
##
##   - `$REPRO_HOME_PACKAGE_CATALOG` — comma-separated list of known
##     package names. Used by the gate to test the unknown-package
##     error path without standing up a full profile compilation.
##   - The CLI flag `--catalog=<name>[,<name>...]` — same semantics,
##     escape hatch for ad-hoc use.
##
## When neither is provided, every package name is accepted. This
## matches the spec's "do NOT load packages at runtime" rule for M61
## while still letting the gate exercise the error path.

import std/[json, options, os, osproc, sets, streams, strutils, tables, tempfiles, times]
from repro_core/paths import extendedPath
from repro_cli_support/self_spawn_image import selfSpawnIoMonitorPath
from repro_core/process_streams import drainStream
from repro_profile/data_refs import dataFilePathProblem

import blake3
import repro_home_intent
import repro_home_generations
import repro_home_apply
import repro_home_resources
import repro_home_rollback
import repro_launch_plan
import repro_local_store
import repro_profile_intent
import repro_profile_compile
import ./migrate_from_env_scripts as mfes
import ./home_export
import ./home_compare
import ./cli_program

type
  PackageCatalogLookup* = proc(package: string): bool {.gcsafe.}

const
  CatalogEnvVar* = "REPRO_HOME_PACKAGE_CATALOG"
  ConfigurableSchemaEnvVar* = "REPRO_HOME_CONFIGURABLE_SCHEMA"
    ## M65: comma-separated `<pkg>.<key>` entries declaring which
    ## configurables each package recognizes. Mirrors the
    ## $REPRO_HOME_PACKAGE_CATALOG seam: production code feeds the
    ## schema from the resolved package catalog (the apply pipeline
    ## already does the resolution); the env var is the gate / ad-hoc
    ## seam. Empty means "accept every key" so existing gates do not
    ## regress.

# ---------------------------------------------------------------------------
# Diagnostic printers.
# ---------------------------------------------------------------------------

proc printNoProfile(err: ref ENoProfile) =
  stderr.writeLine("repro home: no home.nim found at '" & err.profilePath &
    "' (profile directory: " & err.profileDir & ")")
  stderr.writeLine("  hint: create one at that path (or set " &
    "$REPRO_HOME_PROFILE_DIR / pass --profile-dir <path>)")

proc printUnknownPredicate(err: ref EUnknownPredicate) =
  stderr.writeLine("repro home: unknown predicate '" & err.identifier &
    "' at " & err.profilePath & ":" & $err.line)

proc printUnstructured(err: ref EUnstructured) =
  stderr.writeLine("repro home: unstructured profile: " & err.msg)

proc printUnknownPackage(profilePath, pkg: string) =
  stderr.writeLine("repro home: unknown package '" & pkg & "' in profile '" &
    profilePath & "'")
  stderr.writeLine("  hint: run `repro home list-packages` to see the " &
    "available package catalog (or check the profile's `uses:` declarations)")

# ---------------------------------------------------------------------------
# Package-catalog lookup seam.
# ---------------------------------------------------------------------------

proc defaultCatalogLookup(pkg: string): bool {.gcsafe.} =
  ## When no explicit catalog is configured, accept every name. The
  ## M63 apply pipeline performs full catalog resolution; M61 cannot
  ## load packages at runtime per spec.
  true

var
  configuredCatalog: HashSet[string]
  haveConfiguredCatalog: bool = false
  catalogLookupOverride: PackageCatalogLookup = nil

proc setPackageCatalogLookup*(lookup: PackageCatalogLookup) =
  ## Override the catalog lookup. Used by the M63 apply pipeline; tests
  ## that want a hard-coded catalog should prefer the env var or the
  ## `--catalog=` flag because they exercise the CLI surface end to end.
  catalogLookupOverride = lookup

proc loadCatalogFromEnv() =
  configuredCatalog.clear()
  haveConfiguredCatalog = false
  let raw = getEnv(CatalogEnvVar)
  if raw.len == 0:
    return
  haveConfiguredCatalog = true
  for piece in raw.split(','):
    let id = piece.strip()
    if id.len > 0:
      configuredCatalog.incl id

proc loadCatalogFromFlag(value: string) =
  configuredCatalog.clear()
  haveConfiguredCatalog = false
  if value.len == 0:
    return
  haveConfiguredCatalog = true
  for piece in value.split(','):
    let id = piece.strip()
    if id.len > 0:
      configuredCatalog.incl id

proc packageInCatalog(pkg: string): bool =
  if catalogLookupOverride != nil:
    return catalogLookupOverride(pkg)
  if haveConfiguredCatalog:
    return pkg in configuredCatalog
  defaultCatalogLookup(pkg)

# ---------------------------------------------------------------------------
# Configurable-schema lookup seam (M65).
# ---------------------------------------------------------------------------

var
  configuredSchema: HashSet[string]
  haveConfiguredSchema: bool = false

proc loadConfigurableSchemaFromEnv() =
  configuredSchema.clear()
  haveConfiguredSchema = false
  let raw = getEnv(ConfigurableSchemaEnvVar)
  if raw.len == 0:
    return
  haveConfiguredSchema = true
  for piece in raw.split(','):
    let entry = piece.strip()
    if entry.len > 0:
      configuredSchema.incl entry

proc configurableInSchema(pkg, key: string): bool =
  if not haveConfiguredSchema:
    return true
  let composed = pkg & "." & key
  composed in configuredSchema

# ---------------------------------------------------------------------------
# Predicate-keyword tracking.
# ---------------------------------------------------------------------------

type
  PredicateSpec = object
    text: string
    keyword: CondKeyword
    given: bool

proc emptyPredicate(): PredicateSpec =
  PredicateSpec(text: "", keyword: ckWhen, given: false)

# ---------------------------------------------------------------------------
# Flag parsing helpers.
# ---------------------------------------------------------------------------

proc resolveCommandHost(command, hostFlag: string; flagGiven: bool;
                        identity: var HostIdentity): bool =
  ## The host identity of one `repro home` subcommand, resolved by the one
  ## resolver every subcommand shares (`selectHost`: `$REPRO_HOST`, then
  ## `--host`, then the OS hostname; a `--host` that `$REPRO_HOST` would
  ## override is refused). It installs the result as the process-wide
  ## override, so the planner, the apply pipeline and the export / facts
  ## producers all see this host. False (after a diagnostic naming the
  ## command) when the host cannot be resolved; callers exit 2.
  try:
    identity = selectHost(hostFlag, flagGiven)
    true
  except EHostIdentity as err:
    stderr.writeLine("repro home " & command & ": " & err.msg)
    false

proc normalizeTargetPlatform(raw: string): string =
  let p = raw.toLowerAscii()
  if p notin ["linux", "macos", "windows", "bsd"]:
    raise newException(ValueError,
      "unsupported --target-platform '" & raw & "'")
  p

proc normalizeTargetArch(raw: string): string =
  let a = raw.toLowerAscii()
  if a notin ["x86_64", "arm64", "arm32"]:
    raise newException(ValueError, "unsupported --target-arch '" & raw & "'")
  a

# ---------------------------------------------------------------------------
# M83 Phase D + F3: compile-then-adapt path for `home.nim` profiles.
#
# Phase F3 removed the legacy-parser auto-fallback from the apply path.
# Profile compilation failure is now a HARD ERROR. The hand-rolled
# `loadProfile` parser still ships as a library proc for the structural
# editor (`repro home add/set/remove`), which legitimately needs to read
# the source text and edit it byte-for-byte preserving comments and
# formatting — but the apply pipeline no longer falls through to it on a
# Phase A compile failure.
# ---------------------------------------------------------------------------

proc defaultProfileCompileOptionsFor(profileRoot: string;
                                     stateDir: string;
                                     publicCliPath = ""):
    ProfileCompileOptions =
  ## `publicCliPath` is the `repro` image the compile's engine wraps every
  ## action with (`<publicCliPath> internal io monitor`). It goes through the
  ## self-spawn guard like every other internal-verb spawn
  ## (Distribution-And-Packaging.md §5.2): an explicit path or
  ## `REPRO_PUBLIC_CLI_PATH` is used as given, and the running image only
  ## when it has declared itself `repro`. An embedded caller that names
  ## neither gets "" here, which `compileProfileToRbpi` refuses with
  ## `MissingPublicCliPathReason` -- instead of re-executing the caller's own
  ## image as its monitor driver, which ran nothing and surfaced as
  ## "iomon file is too short" (reprobuild-pm issue
  ## 2026-10-27-windows-m76-differing-regular-file-case-fails-in-the-profile-compile).
  result = ProfileCompileOptions(
    stateDir: stateDir,
    publicCliPath: selfSpawnIoMonitorPath(publicCliPath),
    # Empty: `compileProfileToRbpi` resolves the sources through
    # `reprobuildRepoRoot()`, which honours `$REPROBUILD_REPO_ROOT` and the
    # installed package's `$REPROBUILD_SOURCE_ROOT` alike.
    repoRoot: "",
    workDir: profileRoot.parentDir,
    verbose: false,
    forceRebuild: false)

type
  CompileAdaptOutcome* = object
    profile*: Profile           ## nil when the compile or the data failed
    compileError*: string
    dataError*: string
      ## GM4: the profile compiled, but a plan-time data file it declares
      ## could not be read or holds a row its schema refuses. Reported as
      ## such, never as a compile failure.
    cacheHit*: bool             ## informational

proc compileAndAdaptHomeProfile*(profilePath: string;
                                 stateDir: string;
                                 publicCliPath = ""): CompileAdaptOutcome =
  ## Run the Phase C build-engine edge against `profilePath`, decode
  ## the RBPI artifact, and adapt it to the `Profile` shape the apply
  ## pipeline consumes.
  ##
  ## `publicCliPath` names the `repro` image that runs the compile; the CLI
  ## leaves it empty (it IS that image), an in-process caller passes one. See
  ## `defaultProfileCompileOptionsFor`.
  ##
  ## On success: `result.profile` is non-nil; the caller threads it
  ## through `ApplyOptions.preLoadedProfile`.
  ##
  ## On compile failure: `result.profile` is nil and
  ## `result.compileError` carries the diagnostic. Apply-path callers
  ## propagate as a hard error via `formatProfileCompileError`.
  ##
  ## GM4: the profile's plan-time data files are read and expanded HERE,
  ## after the compile edge (`expandedHomeProfile`), so a data edit
  ## re-plans without recompiling. A data-file failure sets `dataError`.
  result = CompileAdaptOutcome()
  var opts = defaultProfileCompileOptionsFor(profilePath, stateDir,
    publicCliPath)
  # The files the compile read, on a cache hit too: the apply records the
  # ones under the profile directory in the generation's intent snapshot,
  # helper modules in subdirectories included (`Profile.compiledFrom`;
  # reprobuild-pm issue
  # 2026-10-18-home-intent-snapshot-omits-imported-modules-in-subdirectories).
  # The hit is served from the same record either way; only the record's
  # read set is reported back.
  opts.reportObservedInputs = true
  try:
    let artifact = compileProfileToRbpi(profilePath, opts)
    let intent = decodeRbpi(artifact.rbpiBytes)
    result.profile = expandedHomeProfile(intent, profilePath)
    result.profile.compiledFrom = artifact.observedInputs
  except ProfileCompileError as err:
    result.compileError = err.msg
  except EDataFile as err:
    result.dataError = err.msg
  except CatchableError as err:
    result.compileError = err.msg

proc formatProfileCompileError*(commandName, profilePath,
                                compileError: string;
                                planCommand = ""): string =
  ## M83 Phase F3: render the actionable error message produced when a
  ## profile fails to compile on the apply path. The shape is uniform
  ## across `repro home` and `repro infra` callers so operators see the
  ## same surface no matter which subcommand surfaced the failure.
  ##
  ## The message points at the Phase F migration recipe, shows the Nim
  ## compilation diagnostic verbatim, and suggests running the matching
  ## `plan` subcommand to triage whether the issue is profile syntax or
  ## an apply-side problem.
  let plan =
    if planCommand.len > 0: planCommand
    else: commandName & " plan"
  result =
    commandName & ": profile compilation failed for " & profilePath &
      "\n" &
    "  diagnostic:\n" &
    "    " & compileError.strip().replace("\n", "\n    ") & "\n" &
    "  hint: see Profile-Migration-Patterns.md in Reprobuild's internal " &
      "specification set for the Phase A migration recipe.\n" &
    "  hint: run `" & plan & "` to see whether the issue is profile " &
      "syntax vs. an apply-side problem."

proc formatCompileAdaptFailure*(commandName, profilePath: string;
                                outcome: CompileAdaptOutcome): string =
  ## The diagnostic for a failed `compileAndAdaptHomeProfile`: a data-file
  ## problem names the file, row and key; anything else is a compile failure.
  if outcome.dataError.len > 0:
    return commandName & ": " & outcome.dataError &
      "\n  hint: fix the row, or the profile's `data:` section in " &
      profilePath
  formatProfileCompileError(commandName, profilePath, outcome.compileError,
    planCommand = "repro home plan")

# ---------------------------------------------------------------------------
# Apply-pipeline plumbing (M63).
# ---------------------------------------------------------------------------

proc renderStowDiagnostic(d: StowDiagnostic): string =
  let tag =
    case d.severity
    of dsInfo: "info"
    of dsWarning: "warning"
  "repro home apply: " & tag & ": " & d.message

proc renderRecovered(rec: AbortedGenerationRecord): string =
  "repro home apply: recovered partial generation at " & rec.originalPath &
    " -> quarantined to " & rec.quarantinedPath &
    " (reason: " & rec.reason & ")"

proc runApplyInline*(commandName: string;
                     mode: ApplyMode = amFull;
                     setOverrideKey: string = "";
                     adoptAddresses: seq[string] = @[];
                     relock = false;
                     uninstallFromScoop = false): int =
  ## Shared apply-pipeline runner used by `repro home apply` and by
  ## the inline path of `add`/`remove`/`enable`/`disable`/`set`.
  ## Reports the new generation id on stdout and any diagnostics on
  ## stderr. M65: callers from `set` pass `mode = amSet` with
  ## `setOverrideKey = "<pkg>.<key>"`; the pipeline takes the
  ## incremental refinalize fast path and emits cache-hit-vs-rebuilt
  ## counts in the apply log. M68 Phase B: `repro home adopt` passes
  ## `adoptAddresses` so the resource step records the named
  ## resources from their live observed bytes instead of running
  ## the driver create / update.
  try:
    var opts: ApplyOptions
    opts.applyMode = mode
    opts.setOverrideKey = setOverrideKey
    opts.adoptAddresses = adoptAddresses
    opts.relock = relock
    opts.uninstallFromScoop = uninstallFromScoop
    # M83 Phase F3: the compile-then-adapt path is the ONLY apply path.
    # A profile compilation failure is a HARD ERROR — the legacy text
    # parser no longer auto-fills the gap.
    let profilePath =
      if opts.profilePath.len > 0: opts.profilePath
      else: resolveProfilePath()
    let stateDir = resolveStateDir()
    let outcomeCompile = compileAndAdaptHomeProfile(profilePath, stateDir)
    if outcomeCompile.profile == nil:
      stderr.writeLine(formatCompileAdaptFailure(
        "repro home " & commandName, profilePath, outcomeCompile))
      return 1
    opts.preLoadedProfile = outcomeCompile.profile
    let outcome = runApply(opts)
    for r in outcome.abortedRecovered:
      stderr.writeLine(renderRecovered(r))
    for d in outcome.diagnostics:
      stderr.writeLine(renderStowDiagnostic(d))
    # GM7: on a host that declares the concerns Reprobuild applies, say which
    # ones ran, how much of the profile was left to the other tool, and what
    # a narrowed set released (left in place, no longer managed).
    if outcome.applied.declared:
      echo "apply: concerns applied: " &
        describeAppliedConcerns(outcome.applied,
          if opts.host.len > 0: opts.host else: currentHost())
      echo "apply: not applied: " & $outcome.notAppliedCount &
        " operation(s) of other concerns"
    # Store-And-Installation-Layout.md § macOS Application Bundles: a
    # running application is not replaced (deferred to the next apply), and
    # one that updated itself past the declared version is kept.
    if outcome.deferred.len > 0:
      echo "apply: deferred " & $outcome.deferred.len & " change(s) to " &
        "objects in use (the next apply makes them):"
      for d in outcome.deferred:
        echo "  defer    " & d
    if outcome.keptVendorUpdates.len > 0:
      echo "apply: kept " & $outcome.keptVendorUpdates.len & " vendor " &
        "update(s) newer than the declared version:"
      for k in outcome.keptVendorUpdates:
        echo "  keep     " & k
    if outcome.released.len > 0:
      echo "apply: released " & $outcome.released.len & " item(s) of " &
        "concerns no longer applied (left in place, no longer managed):"
      for r in outcome.released:
        echo "  release  " & r
    case outcome.kind
    of aokFreshApplied:
      # Stable log line that exposes step 11 eager-GC execution to
      # subprocess-spawning gates (e.g. gate 1). `ranAt` is zero only
      # on the no-op branch; on the fresh-applied branch the GC ran
      # and `reclaimed` is the list of pending-deletion entries that
      # were unlinked (zero on a fresh apply with no prior generations).
      echo "apply: eager gc reclaimed " & $outcome.gcResult.reclaimed.len &
        " prefixes (ranAt " & $outcome.gcResult.ranAt & ")"
      # M65: cache-hit-vs-rebuilt accounting for the generated-file
      # surface. The gate asserts that unrelated files cache-hit on
      # a focused `repro home set`.
      echo "apply: cache-hit " & $outcome.cacheHitCount & " rebuilt " &
        $outcome.rebuiltCount
      echo "repro home " & commandName &
        ": applied generation " & outcome.generationIdHex
    of aokNoOpVerified:
      echo "repro home " & commandName &
        ": no-op (current generation " & outcome.generationIdHex &
        " already matches the live state)"
    return 0
  except EApplyIntentLoad as err:
    stderr.writeLine("repro home " & commandName &
      ": step 1 (load intent) failed: " & err.msg)
    return 1
  except EApplyUnrealizablePackages as err:
    # Refused at planning time, before anything changed: the message names
    # every package with its reason, not the one step 7 would have reached.
    stderr.writeLine("repro home " & commandName & ": " & err.msg)
    return 1
  except EApplyRealizeFailed as err:
    stderr.writeLine("repro home " & commandName &
      ": step 7 (realize package " & err.packageId & " via " &
      err.adapter & ") failed: " & err.msg)
    return 1
  except EApplyMaterializeFailed as err:
    stderr.writeLine("repro home " & commandName &
      ": step 8 (materialize " & err.absoluteOutputPath & ") failed: " &
      err.msg)
    return 1
  except EApplyLauncherFailed as err:
    stderr.writeLine("repro home " & commandName &
      ": step 9 (launcher for command " & err.commandName &
      ") failed: " & err.msg)
    return 1
  except EApplyCurrentRotationFailed as err:
    stderr.writeLine("repro home " & commandName &
      ": step 10 (rotate current to " & err.targetPath &
      ") failed: " & err.msg)
    return 1
  except EApplyManifestCommit as err:
    stderr.writeLine("repro home " & commandName &
      ": step 11 (commit manifest) failed: " & err.msg)
    return 1
  except EApplyKilledByTestHook as err:
    stderr.writeLine("repro home " & commandName &
      ": aborted after step " & $err.killStep &
      " by REPRO_TEST_APPLY_KILL_AFTER_STEP hook; the partial " &
      "generation will be quarantined on the next apply.")
    return 1
  except EApplyBusy as err:
    stderr.writeLine("repro home " & commandName &
      ": another apply is in progress (lock " & err.lockPath &
      " held; waited " & $err.waitedSeconds & "s).")
    return 1
  except EPreventDestroy as err:
    # M68 Phase B: a resource with `lifecyclePolicy = preventDestroy`
    # was removed from `home.nim` (or otherwise scheduled for
    # destroy). `preventDestroy` is absolute — it is NOT bypassable
    # by `--reconcile-drift` / `--accept-overwrite`. The escape
    # hatch is restoring the declaration or `repro home resource
    # forget <id>` (a separate command, out of M68 scope).
    stderr.writeLine("repro home " & commandName &
      ": " & err.msg)
    stderr.writeLine("  hint: restore the resource's declaration in " &
      "home.nim, or run `repro home resource forget " &
      err.resourceAddress & "` to drop the binding without destroying " &
      "the underlying object.")
    return 1
  except EDrift as err:
    stderr.writeLine("repro home " & commandName & ": " & err.msg)
    return 1
  except EStowConflict as err:
    # M72 Deliverable 3: a stow target pre-existed as a regular file
    # or a link to a different source. The materializer left it
    # byte-identical; surface it as drift.
    stderr.writeLine("repro home " & commandName & ": stow drift: " &
      err.msg)
    stderr.writeLine("  hint: pass --reconcile-drift (or " &
      "--accept-overwrite) to replace the target — the prior content " &
      "is recorded so `repro home rollback` can restore it.")
    return 1
  except EAdoptUndeclared as err:
    stderr.writeLine("repro home " & commandName & ": " & err.msg)
    return 1
  except EAdoptFailed as err:
    stderr.writeLine("repro home " & commandName & ": " & err.msg)
    return 1
  except EHomeApply as err:
    stderr.writeLine("repro home " & commandName &
      ": apply failed at step " & $err.step & " (" & err.stepName &
      "): " & err.msg)
    return 1
  except CatchableError as err:
    stderr.writeLine("repro home " & commandName &
      ": apply failed with unexpected error: " & err.msg)
    return 1

# ---------------------------------------------------------------------------
# `repro home add`.
# ---------------------------------------------------------------------------

proc splitToolAtVersion(spec: string):
    tuple[tool, version: string; hasVersion: bool] =
  ## M69: parse a `<tool>` or `<tool>@<version>` positional argument.
  ## The version is everything after the FIRST `@`; the tool name is
  ## everything before. A spec with no `@` returns `(tool, "", false)`.
  ## The literal `@latest` is preserved here — the caller resolves it
  ## against the catalog so the structural editor writes the concrete
  ## pinned version (the intent-layer's "no `latest` on disk" rule).
  let at = spec.find('@')
  if at < 0:
    return (spec, "", false)
  (spec[0 ..< at], spec[at + 1 .. ^1], true)

proc runHomeAddDataRow(pkg, version, activity: string;
                       pred: PredicateSpec; dataFile: string;
                       noApply: bool): int =
  ## GM4: `repro home add --data FILE` — the structural editor targets a
  ## plan-time data file instead of `home.nim`. The row is validated exactly
  ## as the planner reads it (`appendPackageRow`): a canonical package from
  ## the catalog, an activity name, a `when` in the built-in predicate
  ## grammar. FILE must be declared in the profile's `data:` section; a row
  ## in an undeclared file would never apply. `home.nim` is not touched.
  if pred.given and pred.keyword == ckIf:
    stderr.writeLine("repro home add: --if is not accepted with --data; a " &
      "data row's guard is its `when` field (use --when)")
    return 2
  let pathProblem = dataFilePathProblem(dataFile)
  if pathProblem.len > 0:
    stderr.writeLine("repro home add: --data " & dataFile & ": " &
      pathProblem)
    return 2
  if pred.given:
    try:
      discard validateBuiltinPredicate(pred.text, "--when")
    except EUnknownPredicate as e:
      stderr.writeLine("repro home add: --when " & pred.text & ": '" &
        e.identifier & "' is not a built-in predicate; data rows accept " &
        "only windows, macos, linux, bsd, wsl, x86_64, arm64, arm32 and " &
        "host ==/!=/in, combined with and/or/not")
      return 2
    except EUnstructured as e:
      stderr.writeLine("repro home add: --when " & pred.text & ": " &
        e.seen & "; expected " & e.expected)
      return 2
  try:
    let profilePath = loadProfilePath()
    let prof = inspectProfile(profilePath)
    if dataFile notin prof.dataFileRefs:
      stderr.writeLine("repro home add: " & dataFile & " is not declared " &
        "in the `data:` section of " & profilePath &
        (if prof.dataFileRefs.len > 0:
           " (declared: " & prof.dataFileRefs.join(", ") & ")"
         else: " (it has none)"))
      stderr.writeLine("  hint: add `data:` with the line \"" & dataFile &
        "\" to the profile; rows in an undeclared file are never read")
      return 1
    if not packageInCatalog(pkg):
      printUnknownPackage(profilePath, pkg)
      return 1
    let row = DataPackageRow(name: pkg, activity: activity,
      whenPredicate: (if pred.given: pred.text else: ""), version: version)
    let outcome = appendPackageRow(profilePath, profilePath.parentDir,
      dataFile, row)
    case outcome
    of aroAlreadyPresent:
      echo "repro home add: " & dataFile & " already has this row (" & pkg &
        " in activity " & activity & "); unchanged"
    of aroCreated:
      echo "repro home add: created " & dataFile & " with " & pkg &
        " in activity " & activity
    of aroAppended:
      echo "repro home add: added " & pkg & " to " & dataFile &
        " (activity " & activity & ")"
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EUnstructured as e:
    printUnstructured(e); return 1
  except EDataFile as e:
    stderr.writeLine("repro home add: " & e.msg)
    return 1
  except CatchableError as e:
    stderr.writeLine("repro home add: error: " & e.msg)
    return 1
  if noApply:
    return 0
  return runApplyInline("add")

proc predicateOf(command, whenText, ifText: string;
                 pred: var PredicateSpec): bool =
  ## The guard `--when` or `--if` gives a reference (at most one of them);
  ## false after a usage diagnostic when both are given.
  pred = emptyPredicate()
  if whenText.len > 0 and ifText.len > 0:
    stderr.writeLine("repro home " & command & ": give one of --when and --if")
    return false
  if whenText.len > 0:
    pred.text = whenText
    pred.keyword = ckWhen
    pred.given = true
  elif ifText.len > 0:
    pred.text = ifText
    pred.keyword = ckIf
    pred.given = true
  true

proc runHomeAdd(c: ReproCommandLineHomeAdd): int =
  let pkgSpec = c.package
  let activity = c.activity
  var pred: PredicateSpec
  if not predicateOf("add", c.whenPredicate, c.ifPredicate, pred):
    return 2
  let noApply = c.noApply
  let dataFile = c.data
  if c.catalog.len > 0:
    loadCatalogFromFlag(c.catalog)
  let split = splitToolAtVersion(pkgSpec)
  let pkg = split.tool
  var version = split.version
  if pkg.len == 0:
    stderr.writeLine("repro home add: missing <package> name (got '@" &
      version & "'); expected `<tool>` or `<tool>@<version>`")
    return 2
  if split.hasVersion and version.len == 0:
    stderr.writeLine("repro home add: empty version literal after `@` in '" &
      pkgSpec & "'; pass `<tool>` for a bare reference or " &
      "`<tool>@<concrete-version>`")
    return 2
  if version == "latest":
    # GM4b: `@latest` materializes the version an unpinned reference
    # resolves to on this host, so pinning it does not change the
    # selection (Provisioning-Contributions.md §"Profile Package
    # References").
    # A name the reprobuild-packages catalog defines resolves from it, as
    # `repro home apply` would resolve it for this profile.
    # The contribution catalogs the profile imports (`catalogs:`) take part
    # as they do in `repro home apply`. `repro home add` edits the profile
    # as text, so the text inspector reads it here as well.
    # The profile's catalog imports are read OUTSIDE the fallback below: a
    # refused import (ref, unreadable, clash) must be reported, never
    # replaced by resolving the name some other way.
    let profilePath =
      try: loadProfilePath()
      except CatchableError: ""
    var imported: ImportedCatalogs
    if profilePath.len > 0:
      try: imported = importedCatalogsFor(profilePath)
      except CatchableError as err:
        stderr.writeLine("repro home add: " & err.msg)
        return 1
    let catalog =
      try:
        projectCatalogPackages([pkg], profilePath,
          resolveStateDir() / "catalog-projection",
          inspectProfile(profilePath).catalogImports, imported)
      except CatchableError:
        ProfileCatalog()
    let latest = unpinnedHostVersion(pkg, catalog)
    if latest.isNone:
      stderr.writeLine("repro home add: cannot resolve `" & pkg &
        "@latest`: no definition of '" & pkg & "' offers a versioned " &
        "(tarball or scoop) realization for this host")
      let offered = offeredVersions(pkg, catalog)
      if offered.len > 0:
        stderr.writeLine("  hint: versions offered for other platforms: " &
          offered.join(", "))
      return 1
    version = latest.get
  if dataFile.len > 0:
    return runHomeAddDataRow(pkg, version, activity, pred, dataFile, noApply)
  try:
    let profilePath = loadProfilePath()
    if not packageInCatalog(pkg):
      printUnknownPackage(profilePath, pkg)
      return 1
    addPackageReference(profilePath, pkg, activity = activity,
                        predicate = pred.text,
                        predicateKeyword = pred.keyword,
                        version = version)
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EUnknownPredicate as e:
    printUnknownPredicate(e); return 1
  except EUnstructured as e:
    printUnstructured(e); return 1
  except CatchableError as e:
    stderr.writeLine("repro home add: error: " & e.msg)
    return 1
  if noApply:
    return 0
  return runApplyInline("add")

# ---------------------------------------------------------------------------
# `repro home remove`.
# ---------------------------------------------------------------------------

proc activityNames(p: Profile): seq[string] =
  for ch in p.root.children:
    if ch.kind == nkActivity:
      result.add ch.activityName

proc runHomeRemoveDataRows(pkg, version, activity: string;
                           pred: PredicateSpec; dataFile: string;
                           noApply: bool): int =
  ## GM4: `repro home remove <pkg> --data FILE` — remove the package rows
  ## naming `pkg` from a plan-time data file the profile declares
  ## (`removePackageRows`: only those rows' lines go, every other byte
  ## stays). `--activity`, `--when` and `@<version>` narrow the match; `--if`
  ## is refused (a row's guard is its `when` field). No matching row is an
  ## error (exit 1) and leaves the file unchanged. `home.nim` is not touched.
  if pred.given and pred.keyword == ckIf:
    stderr.writeLine("repro home remove: --if is not accepted with --data; " &
      "a data row's guard is its `when` field (use --when)")
    return 2
  let pathProblem = dataFilePathProblem(dataFile)
  if pathProblem.len > 0:
    stderr.writeLine("repro home remove: --data " & dataFile & ": " &
      pathProblem)
    return 2
  try:
    let profilePath = loadProfilePath()
    let prof = inspectProfile(profilePath)
    if dataFile notin prof.dataFileRefs:
      stderr.writeLine("repro home remove: " & dataFile & " is not " &
        "declared in the `data:` section of " & profilePath)
      return 1
    let removed = removePackageRows(profilePath, profilePath.parentDir,
      dataFile, pkg, activity = activity,
      predicate = (if pred.given: pred.text else: ""), version = version)
    if removed == 0:
      stderr.writeLine("repro home remove: " & dataFile & " has no row " &
        "for " & pkg & (if activity.len > 0: " in activity " & activity
                        else: "") &
        (if pred.given: " under when " & pred.text else: "") &
        "; unchanged")
      return 1
    echo "repro home remove: removed " & $removed & " row(s) for " & pkg &
      " from " & dataFile
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EUnstructured as e:
    printUnstructured(e); return 1
  except EDataFile as e:
    stderr.writeLine("repro home remove: " & e.msg)
    return 1
  except CatchableError as e:
    stderr.writeLine("repro home remove: error: " & e.msg)
    return 1
  if noApply:
    return 0
  return runApplyInline("remove")

proc runHomeRemove(c: ReproCommandLineHomeRemove): int =
  let pkgSpec = c.package
  let activitySpec = c.activity.get("")
  let activityGiven = c.activity.isSome
  var pred: PredicateSpec
  if not predicateOf("remove", c.whenPredicate, c.ifPredicate, pred):
    return 2
  let noApply = c.noApply
  let dataFile = c.data
  let split = splitToolAtVersion(pkgSpec)
  let pkg = split.tool
  let version = split.version
  if pkg.len == 0:
    stderr.writeLine("repro home remove: missing <package> name in '" &
      pkgSpec & "'")
    return 2
  if dataFile.len > 0:
    return runHomeRemoveDataRows(pkg, version,
      (if activityGiven: activitySpec else: ""), pred, dataFile, noApply)
  try:
    let profilePath = loadProfilePath()
    var removedCount = 0
    # Default semantics (no flags): remove every occurrence across all
    # activities and both predicate keywords.
    if not activityGiven and not pred.given:
      # Walk every activity and remove from both the bare body and every
      # conditional inside it. M69: when `<tool>@<version>` is given,
      # match BOTH name AND version so a bare `package(jdk)` is NOT
      # stripped when the user asked to remove only `jdk@21.0.5`.
      proc matchesRef(ref1: IntentNode): bool =
        ref1.kind == nkPackageRef and ref1.packageName == pkg and
          (version.len == 0 or ref1.packageVersion == version)
      while true:
        let prof = inspectProfile(profilePath)
        var removedAny = false
        for actName in activityNames(prof):
          let actOpt = findActivity(prof, actName)
          if actOpt.isNone: continue
          let act = actOpt.get
          # Remove from the activity's bare body.
          for ch in act.activityChildren:
            if matchesRef(ch):
              removePackageReference(profilePath, pkg, activity = actName,
                version = version)
              removedAny = true
              inc removedCount
              break
          if removedAny: break
          # Then from conditional blocks.
          for ch in act.activityChildren:
            if ch.kind == nkCondBlock:
              for pkgRef in ch.condChildren:
                if matchesRef(pkgRef):
                  removePackageReference(profilePath, pkg,
                    activity = actName, predicate = ch.predicateSource,
                    version = version)
                  removedAny = true
                  inc removedCount
                  break
              if removedAny: break
          if removedAny: break
        if not removedAny:
          break
    else:
      # Scoped removal: --activity and/or --when/--if applied.
      let targetActivity =
        if activityGiven: activitySpec else: "default"
      let removed =
        if pred.given:
          removePackageReference(profilePath, pkg, activity = targetActivity,
            predicate = pred.text, version = version)
        else:
          removePackageReference(profilePath, pkg, activity = targetActivity,
            version = version)
      if removed: inc removedCount
    if removedCount == 0:
      # No package line to remove. When the activities searched compose
      # helper calls, the package may be one they contribute, which only
      # the module defining the helper can change: say so, naming each call,
      # instead of reporting success (Home-Profile-Intent-Layer.md
      # §Structural Edit Contract).
      let prof = inspectProfile(profilePath)
      var calls: seq[string]
      for ch in prof.root.children:
        if ch.kind != nkActivity: continue
        if activityGiven or pred.given:
          let scope = if activityGiven: activitySpec else: "default"
          if ch.activityName != scope: continue
        for opaque in opaqueNodes(ch.activityChildren):
          if opaque.opaqueKind == okHelperCall:
            calls.add "activity " & ch.activityName & ": " &
              opaque.opaqueConstruct
      if calls.len > 0:
        stderr.writeLine("repro home remove: `" & pkg & "` has no package " &
          "line in " & profilePath & " to remove; the activities searched " &
          "compose helper calls whose packages a text edit cannot see or " &
          "change:")
        for c in calls:
          stderr.writeLine("  " & c)
        stderr.writeLine("  hint: if one of them contributes `" & pkg &
          "`, remove it in the module that defines the helper; `repro home " &
          "why " & pkg & "` names the activity it comes from")
        return 1
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EUnknownPredicate as e:
    printUnknownPredicate(e); return 1
  except EUnstructured as e:
    printUnstructured(e); return 1
  except CatchableError as e:
    stderr.writeLine("repro home remove: error: " & e.msg)
    return 1
  if noApply:
    return 0
  return runApplyInline("remove")

# ---------------------------------------------------------------------------
# `repro home enable` / `disable`.
# ---------------------------------------------------------------------------

type
  RemoteApplyFlags = object
    remoteRepro: string
    targetStoreRoot: string
    targetStoreDaemon: string
    targetStoreEndpoint: string
    targetStateDir: string
    targetHomeDir: string
    sshPath: string
    sshOptions: seq[string]
    port: int
    targetPlatform: string
    targetArch: string
    targetWslGiven: bool
    targetWsl: bool

  EnableDisableFlags = object
    activity: string
    host: string
    now: bool
    noApply: bool
    hostGiven: bool
    ok: bool
    exitCode: int
    remote: RemoteApplyFlags

proc parseEnableDisableFlags[T](name: string; c: T): EnableDisableFlags =
  ## What `repro home enable|disable` was given, from its configuration
  ## object (repro's description, `repro_cli_support/cli_description`).
  ## `ok` is false, after a diagnostic, when a value is refused.
  result.ok = false
  result.exitCode = 2
  result.now = c.now
  result.noApply = c.noApply
  result.hostGiven = c.host.isSome
  let hostOverride = c.host.get("")
  result.remote.remoteRepro = c.remoteRepro
  result.remote.sshPath = c.ssh
  result.remote.targetStoreRoot = c.targetStoreRoot
  result.remote.targetStoreDaemon = c.targetStoreDaemon
  result.remote.targetStoreEndpoint = c.targetStoreEndpoint
  result.remote.targetStateDir = c.targetStateDir
  result.remote.targetHomeDir = c.targetHomeDir
  result.remote.port = c.port
  result.remote.sshOptions = c.sshOption
  try:
    if c.targetPlatform.len > 0:
      result.remote.targetPlatform = normalizeTargetPlatform(c.targetPlatform)
    if c.targetArch.len > 0:
      result.remote.targetArch = normalizeTargetArch(c.targetArch)
  except ValueError as err:
    stderr.writeLine("repro home " & name & ": " & err.msg)
    return
  if c.targetWsl.isSome:
    result.remote.targetWsl = c.targetWsl.get
    result.remote.targetWslGiven = true
  let positional = c.activity
  result.activity = positional
  # `--host` here names the TARGET host -- the `hosts:` entry to edit, and
  # with `--now` the host to apply remotely -- not this machine's identity,
  # so it may differ from $REPRO_HOST (CLI/home/enable.md). Without it the
  # target is this machine, resolved by the shared resolver.
  if result.hostGiven:
    if hostOverride.len == 0:
      stderr.writeLine("repro home " & name & ": --host needs a non-empty name")
      return
    result.host = hostOverride
  else:
    var identity: HostIdentity
    if not resolveCommandHost(name, "", false, identity):
      return
    result.host = identity.name
  result.ok = true
  result.exitCode = 0

proc refuseDefaultGuard(name, activity: string): bool =
  ## The spec mandates that `enable default` / `disable default` are
  ## hard errors: `default` is always-enabled per M60 and toggling it
  ## via `hosts:` is meaningless.
  if activity == "default":
    stderr.writeLine("repro home " & name &
      ": the `default` activity cannot be toggled — it is always enabled " &
      "regardless of hosts:")
    return true
  false

proc runRemoteApplyAfterEdit(name: string; parsed: EnableDisableFlags): int

proc runHomeEnable(c: ReproCommandLineHomeEnable): int =
  let parsed = parseEnableDisableFlags("enable", c)
  if not parsed.ok:
    return parsed.exitCode
  if refuseDefaultGuard("enable", parsed.activity):
    return 1
  try:
    # Only the host's `hosts:` entry is edited, read with the inspector
    # that steps over helper calls and activity `stow:` / `resources:`
    # blocks (none of which is in `hosts:`); every other line keeps its
    # bytes (Home-Profile-Intent-Layer.md §CLI Edit Semantics).
    discard editHostActivity(loadProfilePath(), parsed.host,
      parsed.activity, enable = true)
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EUnstructured as e:
    printUnstructured(e); return 1
  except CatchableError as e:
    stderr.writeLine("repro home enable: error: " & e.msg)
    return 1
  if parsed.noApply:
    return 0
  if parsed.hostGiven and parsed.host != machineHost():
    if parsed.now:
      return runRemoteApplyAfterEdit("enable", parsed)
    return 0
  # M63: apply runs by default after a successful intent edit.
  return runApplyInline("enable")

proc runHomeDisable(c: ReproCommandLineHomeDisable): int =
  let parsed = parseEnableDisableFlags("disable", c)
  if not parsed.ok:
    return parsed.exitCode
  if refuseDefaultGuard("disable", parsed.activity):
    return 1
  try:
    # As for `enable`: only the host's `hosts:` entry is edited.
    discard editHostActivity(loadProfilePath(), parsed.host,
      parsed.activity, enable = false)
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EUnstructured as e:
    printUnstructured(e); return 1
  except CatchableError as e:
    stderr.writeLine("repro home disable: error: " & e.msg)
    return 1
  if parsed.noApply:
    return 0
  if parsed.hostGiven and parsed.host != machineHost():
    if parsed.now:
      return runRemoteApplyAfterEdit("disable", parsed)
    return 0
  return runApplyInline("disable")

# ---------------------------------------------------------------------------
# `repro home list` / `repro home why`.
#
# Both report what the planner does, so they read the profile the way the
# planner does: compiled (the compile-then-adapt path, Profile-Compilation-
# Model.md, phase F3), never as text. A helper call's packages, a
# `guarded(...)` element and a data row are therefore listed like any other
# package reference, and each reference's state is the planner's own rule
# (`packageOriginsFromBody`, `enabledActivitiesFor`) evaluated for the host
# (CLI/home/list.md, CLI/home/why.md).
# ---------------------------------------------------------------------------

type
  ListedOrigin = object
    origin: PackageOrigin
    dataFile: string      ## GM4: the data file the row is in; "" for home.nim

  CompiledListing = object
    origins: seq[ListedOrigin]
    ctx: HostContext

proc compiledListing(commandName, profilePath, host: string;
                     listing: var CompiledListing): bool =
  ## Compile the profile and collect every package reference with its state
  ## on `host`. The data rows are adapted one by one, exactly as
  ## `mergeDataRows` turns them into activity-body elements, so each keeps
  ## the file it came from. Returns false after printing the diagnostic when
  ## the profile does not compile or a data file is refused. Raises
  ## `EUndeclaredHost` for a host the registry does not declare.
  let stateDir = resolveStateDir()
  var prof: Profile
  var dataFiles: seq[DataFile]
  var failure = CompileAdaptOutcome()
  try:
    let artifact = compileProfileToRbpi(profilePath,
      defaultProfileCompileOptionsFor(profilePath, stateDir))
    let intent = decodeRbpi(artifact.rbpiBytes)
    dataFiles = expandProfileData(intent, profilePath).dataFiles
    prof = profileIntentToHomeProfile(intent, profilePath)
  except ProfileCompileError as err:
    failure.compileError = err.msg
  except EDataFile as err:
    failure.dataError = err.msg
  if failure.compileError.len > 0 or failure.dataError.len > 0:
    stderr.writeLine(formatCompileAdaptFailure(commandName, profilePath,
      failure))
    return false
  listing.ctx = currentHostContext()
  listing.ctx.host = host
  let active = enabledActivitiesFor(prof, host)
  for ch in prof.root.children:
    if ch.kind != nkActivity: continue
    for o in packageOriginsFromBody(ch.activityChildren, ch.activityName,
        ch.activityName in active, listing.ctx):
      listing.origins.add ListedOrigin(origin: o)
  for file in dataFiles:
    for row in file.rows:
      let node = buildActivityElement(dataRowElement(row))
      for o in packageOriginsFromBody(@[node], row.activity,
          row.activity in active, listing.ctx):
        listing.origins.add ListedOrigin(origin: o, dataFile: file.path)
  true

const
  HomeListJsonSchema* = "reprobuild.home.list.v1"
    ## The schema of `repro home list --json`.
  HomeHistoryJsonSchema* = "reprobuild.home.history.v1"
    ## The schema of `repro home history --json`.
  HomePlanJsonSchema* = "reprobuild.home.plan.v2"
    ## The schema of `repro home plan --json`.

proc listedStateWord(state: OriginState): string =
  ## The state word `repro home list` prints for a reference (and its JSON
  ## form carries): the planner's rule for it.
  case state
  of osPlanned: "enabled"
  of osActivityNotSelected: "inactive"
  of osGuardFalse: "excluded"

proc factsText(ctx: HostContext): string =
  "platform=" & ctx.platform & " arch=" & ctx.arch &
    (if ctx.isWsl: " wsl" else: "")

proc runHomeList(c: ReproCommandLineHomeList): int =
  let hostOverride = c.host.get("")
  let hostGiven = c.host.isSome
  var identity: HostIdentity
  if not resolveCommandHost("list", hostOverride, hostGiven, identity):
    return 2
  try:
    let profilePath = loadProfilePath()
    let host = identity.name
    var listing: CompiledListing
    if not compiledListing("repro home list", profilePath, host, listing):
      return 1
    if c.json:
      var packages = newJArray()
      for l in listing.origins:
        let o = l.origin
        packages.add(%*{"package": o.packageId,
          "state": listedStateWord(o.state), "activity": o.fromActivity,
          "when": o.predicateText, "dataFile": l.dataFile})
      echo pretty(%*{"schemaId": HomeListJsonSchema, "profile": profilePath,
        "host": host, "facts": {"platform": listing.ctx.platform,
          "arch": listing.ctx.arch, "wsl": listing.ctx.isWsl},
        "packages": packages})
      return 0
    echo "repro home list: profile=" & profilePath & " host=" & host
    echo "  guards evaluated for " & factsText(listing.ctx)
    for l in listing.origins:
      let o = l.origin
      let prefix = "  " & alignLeft(listedStateWord(o.state), 9)
      let predStr =
        if o.predicateText.len == 0: "" else: "  when " & o.predicateText
      let dataStr = if l.dataFile.len > 0: "  data=" & l.dataFile else: ""
      echo prefix & o.packageId & "  activity=" & o.fromActivity & predStr &
        dataStr
    return 0
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EDataFile as e:
    stderr.writeLine("repro home list: " & e.msg)
    return 1
  except CatchableError as e:
    stderr.writeLine("repro home list: error: " & e.msg)
    return 1

proc runHomeWhy(c: ReproCommandLineHomeWhy): int =
  let pkg = c.package
  let hostOverride = c.host.get("")
  let hostGiven = c.host.isSome
  var identity: HostIdentity
  if not resolveCommandHost("why", hostOverride, hostGiven, identity):
    return 2
  try:
    let profilePath = loadProfilePath()
    let host = identity.name
    var listing: CompiledListing
    if not compiledListing("repro home why", profilePath, host, listing):
      return 1
    var planned = 0
    var found = 0
    for l in listing.origins:
      let o = l.origin
      if o.packageId != pkg: continue
      inc found
      let predStr =
        if o.predicateText.len == 0: "" else: " under when " & o.predicateText
      let state =
        case o.state
        of osPlanned: "ENABLED on host `" & host & "`"
        of osActivityNotSelected:
          "NOT enabled on host `" & host &
            "` (not in hosts: entry, not `default`)"
        of osGuardFalse:
          "activity enabled on host `" & host & "`, but the guard does " &
            "not hold for " & factsText(listing.ctx)
      let dataStr =
        if l.dataFile.len > 0: " (row in data file " & l.dataFile & ")"
        else: ""
      echo "repro home why: package `" & pkg & "` <- activity `" &
        o.fromActivity & "`" & predStr & dataStr & " [" & state & "]"
      if o.state == osPlanned: inc planned
    if found == 0:
      echo "repro home why: package `" & pkg &
        "` is NOT declared in any activity of profile " & profilePath
      return 0
    if planned == 0:
      echo "repro home why: `" & pkg & "` is declared but NOT active on `" &
        host & "` — no reference to it is planned for this host."
    return 0
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EDataFile as e:
    stderr.writeLine("repro home why: " & e.msg)
    return 1
  except CatchableError as e:
    stderr.writeLine("repro home why: error: " & e.msg)
    return 1

# ---------------------------------------------------------------------------
# `repro home history` (M62).
# ---------------------------------------------------------------------------

proc formatTimestamp(unix: int64): string =
  ## Format a unix epoch second as a UTC RFC-3339-ish marker. We avoid
  ## std/times' localization for stable, machine-readable output.
  let t = fromUnix(unix).utc()
  t.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc shortGenerationId(idHex: string): string =
  if idHex.len <= 12: idHex
  else: idHex[0 ..< 12]

proc dataFilesOfGeneration(store: var Store; storeOpen: var bool;
                           rec: GenerationRecord):
    seq[tuple[path, blake3Hex: string]] =
  ## GM4: the plan-time data files `rec` was planned from, as recorded in
  ## its intent snapshot (never the live files). Opens the store on first
  ## use. Raises when the snapshot cannot be read.
  if not storeOpen:
    store = openStore(resolveStoreRoot())
    storeOpen = true
  var key: PrefixIdBytes
  for i in 0 ..< 32:
    key[i] = rec.envelope.intentSnapshotDigest[i]
  let snapshot = decodeSnapshotBytes(readCasBlob(store, key))
  for entry in snapshot.files:
    if entry.role == ifrData:
      result.add((entry.path, blake3.toHex(blake3.digest(entry.content))))

proc runHomeHistory(json = false): int =
  ## Walks `<state-dir>/generations/` and prints one line per
  ## generation in chronological order (oldest -> newest). No history
  ## file is consulted; the only on-disk source of truth is the set
  ## of pointer envelopes the directory enumeration finds. With `json`,
  ## one `HomeHistoryJsonSchema` document carries the same records.
  try:
    let stateDir = resolveStateDir()
    let records = enumerateGenerations(stateDir)
    if json:
      var store: Store
      var storeOpen = false
      defer:
        if storeOpen:
          try: store.close() except CatchableError: discard
      var gens = newJArray()
      for rec in records:
        var gen = %*{"generationId": rec.generationId,
          "shortId": shortGenerationId(rec.generationId),
          "activationTimestamp": rec.activationTimestamp,
          "activationTime": formatTimestamp(rec.activationTimestamp),
          "host": rec.envelope.hostIdentity, "active": rec.isActive}
        try:
          var files = newJArray()
          for f in dataFilesOfGeneration(store, storeOpen, rec):
            files.add(%*{"path": f.path, "blake3": f.blake3Hex})
          gen["dataFiles"] = files
          gen["snapshotError"] = newJNull()
        except CatchableError as e:
          gen["dataFiles"] = newJArray()
          gen["snapshotError"] = %e.msg
        gens.add(gen)
      echo pretty(%*{"schemaId": HomeHistoryJsonSchema, "stateDir": stateDir,
        "generations": gens})
      return 0
    if records.len == 0:
      echo "repro home history: no generations yet at " & stateDir
      return 0
    echo "repro home history: state-dir=" & stateDir
    var store: Store
    var storeOpen = false
    defer:
      if storeOpen:
        try: store.close() except CatchableError: discard
    for rec in records:
      let marker = if rec.isActive: "  [active]" else: "          "
      echo "  " & shortGenerationId(rec.generationId) & "  " &
        formatTimestamp(rec.activationTimestamp) & "  host=" &
        rec.envelope.hostIdentity & marker
      # GM4: the plan-time data files this generation was planned from, as
      # recorded in its intent snapshot (never the live files).
      try:
        for f in dataFilesOfGeneration(store, storeOpen, rec):
          echo "      data " & f.path & " blake3=" & f.blake3Hex
      except CatchableError as e:
        echo "      data (intent snapshot unreadable: " & e.msg & ")"
    return 0
  except EStateDirInvalid as e:
    stderr.writeLine("repro home history: " & e.msg)
    return 1
  except EPointerCorrupt as e:
    stderr.writeLine("repro home history: corrupt pointer at " &
      e.pointerPath & " (field: " & e.field & "); quarantine the " &
      "generation directory and retry")
    return 1
  except EGenerationDirInvalid as e:
    stderr.writeLine("repro home history: invalid generation directory " &
      e.generationPath & " (" & e.msg & ")")
    return 1
  except CatchableError as e:
    stderr.writeLine("repro home history: error: " & e.msg)
    return 1

# ---------------------------------------------------------------------------
# `repro home apply` (M63).
# ---------------------------------------------------------------------------

proc homePlanJson(preview: PlanPreview; profilePath: string;
                  failsOnDrift, fails: bool): JsonNode =
  ## `repro home plan --json`: the preview `repro home apply --plan` prints,
  ## as one document (schema `reprobuild.home.plan.v2`). One `operations`
  ## entry per previewed operation, in the text form's order of discovery;
  ## a resource's entry also carries the resource planner's own decision.
  var operations = newJArray()
  for item in preview.items:
    var op = %*{"category": item.category, "name": item.name,
      "action": $item.action, "concern": $item.concern,
      "notApplied": item.notApplied, "detail": item.detail}
    if item.resourceAction.isSome:
      let a = item.resourceAction.get
      op["resource"] = %*{"address": a.address, "action": $a.kind,
        "resourceKind": $a.resourceKind, "summary": a.summary,
        "driftExpected": a.driftExpectedHex,
        "driftObserved": a.driftObservedHex, "deferred": a.deferred,
        "keptVendorUpdate": a.keptVendorUpdate}
    else:
      op["resource"] = newJNull()
    operations.add(op)
  %*{"schemaId": HomePlanJsonSchema, "profile": profilePath,
    "host": preview.host, "targetGeneration": preview.generationIdHex,
    "isNoOp": preview.isNoOp, "operations": operations,
    "operationCount": preview.items.len, "driftCount": preview.driftCount,
    "unrealizable": preview.unrealizable,
    "concernsApplied": (if preview.applied.declared:
      %describeAppliedConcerns(preview.applied, preview.host)
      else: newJNull()),
    "notAppliedCount": preview.notAppliedCount,
    "releasedCount": preview.releasedCount,
    # The exit code this plan gives, so a reader of the document alone
    # knows whether it fails and why.
    "failsOnDrift": failsOnDrift, "fails": fails}

proc runHomePreview(command: string; allowDrift, reconcileDrift: bool;
                    relock = false; targetPlatform = "";
                    targetArch = ""; uninstallFromScoop = false;
                    json = false): int =
  ## M72 Deliverable 2: the non-mutating preview of the FULL apply
  ## (packages, stow, generated files, managed blocks, launchers,
  ## resources). `repro home plan` and `repro home apply --plan` are two
  ## spellings of this one procedure, named by `command` in their output
  ## (Core-Invariants.md §One Implementation Per Concern); until
  ## 2026-11-18 `repro home plan` planned the `resources:` block alone and
  ## printed `0 resource(s) planned` for a profile of packages.
  ## Runs the planning half of the pipeline through `runApplyPlan`,
  ## which executes NO mutating step (no realize, no stage, no rotate, no
  ## commit, no `scoop install`). Exit 0 on a clean / no-op plan;
  ## non-zero when drift is detected unless `--allow-drift` was passed,
  ## and non-zero whenever a package of an applied concern has no
  ## realization: the apply fails on it, and neither `--allow-drift` nor
  ## `--reconcile-drift` changes that.
  try:
    var opts: ApplyOptions
    opts.reconcileStowDrift = reconcileDrift
    opts.relock = relock
    opts.uninstallFromScoop = uninstallFromScoop
    if targetPlatform.len > 0 or targetArch.len > 0:
      # GM4b: plan for another platform. Package references resolve for
      # the named target (Provisioning-Contributions.md §"Profile Package
      # References"); the host inventory is not consulted for it.
      var ctx = currentHostContext()
      if targetPlatform.len > 0:
        ctx.platform = normalizeTargetPlatform(targetPlatform)
      if targetArch.len > 0:
        ctx.arch = normalizeTargetArch(targetArch)
      # Another platform: this machine's os-release says nothing about it,
      # so a `nixos` guard is refused rather than read from here.
      ctx.nixosStated = false
      opts.targetContext = ctx
      opts.hasTargetContext = true
    # M83 Phase F3: same hard-error compile path as the real apply.
    # A missing `home.nim` is reported as such (`ENoProfile`), not as a
    # failed compile of a file that is not there.
    let profilePath =
      if opts.profilePath.len > 0: opts.profilePath
      else: loadProfilePath()
    let stateDir = resolveStateDir()
    let outcomeCompile = compileAndAdaptHomeProfile(profilePath, stateDir)
    if outcomeCompile.profile == nil:
      stderr.writeLine(formatCompileAdaptFailure(
        command, profilePath, outcomeCompile))
      return 1
    opts.preLoadedProfile = outcomeCompile.profile
    let preview = runApplyPlan(opts)
    let failsOnDrift = preview.driftCount > 0 and not allowDrift and
      not reconcileDrift
    let fails = failsOnDrift or preview.unrealizable.len > 0
    if json:
      echo pretty(homePlanJson(preview, profilePath, failsOnDrift, fails))
    else:
      stdout.write(renderPlanPreview(preview, command))
    if preview.unrealizable.len > 0:
      stderr.writeLine(command & ": " &
        $preview.unrealizable.len & " package(s) of an applied concern " &
        "have no realization on this host, so the apply would fail: " &
        preview.unrealizable.join(", "))
    if failsOnDrift:
      stderr.writeLine(command & ": " & $preview.driftCount &
        " drift item(s) detected. Pass --allow-drift to exit 0 anyway, " &
        "or --reconcile-drift to plan the reconciling apply.")
    return (if fails: 1 else: 0)
  except ENoProfile as err:
    printNoProfile(err)
    return 1
  except EPreventDestroy as err:
    # M68 Phase B: a `preventDestroy` resource scheduled for destroy is an
    # error of the plan, not a silent `destroy` line.
    stderr.writeLine(command & ": " & err.msg)
    return 1
  except EApplyIntentLoad as err:
    stderr.writeLine(command & ": step 1 (load intent) " &
      "failed: " & err.msg)
    return 1
  except EHomeApply as err:
    stderr.writeLine(command & ": planning failed at step " &
      $err.step & " (" & err.stepName & "): " & err.msg)
    return 1
  except CatchableError as err:
    stderr.writeLine(command & ": planning failed with " &
      "unexpected error: " & err.msg)
    return 1

proc runHomeApply(c: ReproCommandLineHomeApply): int =
  ## Standalone apply: runs the M63 pipeline against the currently
  ## resolved profile, host, state dir, and store.
  ##
  ## M72: `--plan` runs a non-mutating preview instead of the real
  ## apply. `--reconcile-drift` / `--accept-overwrite` let the real
  ## apply replace a drifted stow target (per the home-scope drift
  ## contract). `--allow-drift` makes `--plan` exit 0 despite drift.
  let planMode = c.plan
  let allowDrift = c.allowDrift
  let reconcileDrift = c.reconcileDrift
  let uninstallFromScoop = c.uninstallFromScoop
  let relock = c.relock
  let targetPlatform = c.targetPlatform
  let targetArch = c.targetArch
  let hostFlag = c.host.get("")
  let hostGiven = c.host.isSome
  if (targetPlatform.len > 0 or targetArch.len > 0) and not planMode:
    stderr.writeLine("repro home apply: --target-platform / --target-arch " &
      "plan for another platform and need --plan; a real apply for another " &
      "host goes through `repro home enable <activity> --host NAME --now`")
    return 2
  var identity: HostIdentity
  if not resolveCommandHost(if planMode: "apply --plan" else: "apply",
                            hostFlag, hostGiven, identity):
    return 2
  if planMode:
    return runHomePreview("repro home apply --plan", allowDrift,
      reconcileDrift, relock, targetPlatform, targetArch,
      uninstallFromScoop)
  # A real apply with --reconcile-drift threads the policy through the
  # apply pipeline so a drifted stow target can be replaced.
  if reconcileDrift:
    putEnv("REPRO_HOME_APPLY_RECONCILE_DRIFT", "1")
  return runApplyInline("apply", relock = relock,
    uninstallFromScoop = uninstallFromScoop)

# ---------------------------------------------------------------------------
# `repro home __build-bundle` (M71 Phase A, internal).
# ---------------------------------------------------------------------------

proc bytesToString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc runHomeBuildBundle(c: ReproCommandLineHomeBuildBundle): int =
  ## Internal M71 command. Phase A bundles an already-realized local
  ## generation. Phase B's `--evaluate` mode first performs a local
  ## apply under explicit target facts, then bundles that generation.
  ## This still does not perform SSH transfer or remote activation.
  var generation = c.generation.get("current")
  let generationGiven = c.generation.isSome
  let stateDir = c.stateDir
  let storeRoot = c.storeRoot
  let homeDir = c.homeDir
  let outPath = c.`out`
  let targetHost = c.targetHost
  let targetPlatform = c.targetPlatform
  let targetArch = c.targetArch
  let targetWslGiven = c.targetWsl.isSome
  let targetWsl = c.targetWsl.get(false)
  # Any target fact asks for evaluation.
  let evaluate = c.evaluate or targetHost.len > 0 or
    targetPlatform.len > 0 or targetArch.len > 0 or targetWslGiven
  try:
    let resolvedStateDir =
      if stateDir.len > 0: stateDir else: resolveStateDir()
    let resolvedStoreRoot = resolveStoreRoot(storeRoot)
    if evaluate:
      if generationGiven and generation != "current":
        raise newException(ValueError,
          "--generation cannot select an existing generation in --evaluate mode")
      var ctx = currentHostContext()
      if targetHost.len > 0:
        ctx.host = targetHost
      if targetPlatform.len > 0:
        ctx.platform = normalizeTargetPlatform(targetPlatform)
      if targetArch.len > 0:
        ctx.arch = normalizeTargetArch(targetArch)
      if targetWslGiven:
        ctx.isWsl = targetWsl
        if targetWsl and targetPlatform.len == 0:
          ctx.platform = "linux"
      # Evaluating for another target: the local os-release does not say
      # whether it is NixOS.
      if targetHost.len > 0 or targetPlatform.len > 0 or targetArch.len > 0 or
          targetWslGiven:
        ctx.nixosStated = false
      # The profile directory is `repro home --profile-dir`, which the
      # namespace applies as an override before any subcommand runs.
      var applyOpts: ApplyOptions
      applyOpts.stateDir = resolvedStateDir
      applyOpts.storeRoot = resolvedStoreRoot
      applyOpts.homeDir = homeDir
      applyOpts.host = ctx.host
      applyOpts.targetContext = ctx
      applyOpts.hasTargetContext = true
      let applied = runApply(applyOpts)
      generation = applied.generationIdHex
    var store = openStore(resolvedStoreRoot)
    defer:
      try: store.close() except CatchableError: discard
    let outcome = writeActivationBundle(resolvedStateDir, store, generation)
    if outPath.len > 0:
      let parent = parentDir(outPath)
      if parent.len > 0:
        createDir(extendedPath(parent))
      writeFile(extendedPath(outPath), bytesToString(outcome.bundleBytes))
    echo "generationId: " & outcome.generationIdHex
    echo "bundleDigest: " & outcome.bundleDigestHex
    echo "bundlePath: " & outcome.bundlePath
    return 0
  except EActivationBundleCorrupt as err:
    stderr.writeLine("repro home __build-bundle: " & err.msg)
    return 1
  except EPointerCorrupt as err:
    stderr.writeLine("repro home __build-bundle: corrupt pointer at " &
      err.pointerPath & " (field: " & err.field & ")")
    return 1
  except StoreError as err:
    stderr.writeLine("repro home __build-bundle: store error: " & err.msg)
    return 1
  except ValueError as err:
    stderr.writeLine("repro home __build-bundle: " & err.msg)
    return 2
  except CatchableError as err:
    stderr.writeLine("repro home __build-bundle: error: " & err.msg)
    return 1

# ---------------------------------------------------------------------------
# `repro home __receive-bundle` / `__transfer-bundle` (M71 Phase C,
# internal transfer/import only).
# ---------------------------------------------------------------------------

proc stringToBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc boolField(value: bool): string =
  if value: "true" else: "false"

proc readBinaryFile(path: string): seq[byte] =
  stringToBytes(readFile(extendedPath(path)))

proc renderImportResult(res: ActivationBundleImportResult) =
  echo "bundleDigest: " & res.bundleDigestHex
  echo "targetBundlePath: " & res.targetBundlePath
  echo "bundleStatus: " & (if res.bundleAlreadyPresent:
    "already-present" else: "stored")
  echo "prefixesImported: " & $res.prefixesImported
  echo "prefixesAlreadyPresent: " & $res.prefixesAlreadyPresent
  echo "bytesReceived: " & $res.bytesReceived

proc runHomeReceiveBundle(c: ReproCommandLineHomeReceiveBundle): int =
  let storeRoot = c.storeRoot
  let queryDigest = c.query
  let queryPrefixes = c.queryPrefix
  let expectedDigest = c.expectedDigest
  let bundlePath = c.bundle
  if storeRoot.len == 0:
    stderr.writeLine("repro home __receive-bundle: --store-root is required")
    return 2

  try:
    var store = openStore(resolveStoreRoot(storeRoot))
    defer:
      try: store.close() except CatchableError: discard
    if queryDigest.len > 0:
      let digest = parsePrefixIdHex(queryDigest)
      let targetPath = store.casPath(digest)
      var present = fileExists(extendedPath(targetPath))
      if present:
        try:
          store.verifyCasBlob(digest)
        except CatchableError:
          present = false
      echo "bundleDigest: " & queryDigest.toLowerAscii()
      echo "bundlePresent: " & boolField(present)
      echo "targetBundlePath: " & targetPath
      var prefixPresent = 0
      for raw in queryPrefixes:
        let pid = parsePrefixIdHex(raw)
        let lookup = store.lookupPrefix(pid)
        let ok = lookup.found and
          dirExists(extendedPath(store.absolutePrefixPath(lookup.row.realizedPath)))
        if ok:
          inc prefixPresent
        echo "prefixStatus: " & raw.toLowerAscii() & " " &
          (if ok: "present" else: "missing")
      echo "prefixesPresent: " & $prefixPresent
      echo "prefixesMissing: " & $(queryPrefixes.len - prefixPresent)
      return 0

    let bytes =
      if bundlePath.len > 0: readBinaryFile(bundlePath)
      else: stringToBytes(stdin.readAll())
    let imported = importActivationBundleBytes(store, bytes,
      expectedDigestHex = expectedDigest,
      filePath = if bundlePath.len > 0: bundlePath else: "<stdin>")
    renderImportResult(imported)
    return 0
  except EActivationBundleCorrupt as err:
    stderr.writeLine("repro home __receive-bundle: " & err.msg)
    return 1
  except StoreError as err:
    stderr.writeLine("repro home __receive-bundle: store error: " & err.msg)
    return 1
  except ValueError as err:
    stderr.writeLine("repro home __receive-bundle: " & err.msg)
    return 2
  except CatchableError as err:
    stderr.writeLine("repro home __receive-bundle: error: " & err.msg)
    return 1

proc runCapture(program: string; args: seq[string]; input = ""):
    tuple[exitCode: int; output: string] =
  let p = startProcess(program, args = args,
    options = {poUsePath, poStdErrToStdOut})
  if input.len > 0:
    p.inputStream().write(input)
  p.inputStream().close()
  # N51: `readAll` stops at the first short pipe read, not at EOF. This
  # captures an `ssh`/`repro home __receive-bundle` transcript, so a truncated
  # one turns a remote error into an unexplained one.
  result.output = drainStream(p.outputStream())
  result.exitCode = p.waitForExit()
  p.close()

proc remoteReceiveCommand(remoteRepro, targetStoreRoot: string;
                          extra: openArray[string]): string =
  var parts = @[remoteRepro, "home", "__receive-bundle",
    "--store-root", targetStoreRoot]
  for item in extra:
    parts.add item
  for idx, part in parts:
    if idx > 0:
      result.add(" ")
    result.add(quoteShell(part))

proc sshRun(sshPath, target: string; port: int; sshOptions: seq[string];
            remoteCommand: string; input = ""):
    tuple[exitCode: int; output: string] =
  var args: seq[string]
  for opt in sshOptions:
    args.add opt
  if port > 0:
    args.add("-p")
    args.add($port)
  args.add(target)
  args.add(remoteCommand)
  runCapture(sshPath, args, input)

proc fieldValueLoose(output, name: string): string =
  let prefix = name & ": "
  for line in output.splitLines():
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

type
  ERemoteTransferFailed = object of CatchableError

  TransferBundleOptions = object
    bundleDigestHex: string
    storeRoot: string
    target: string
    remoteRepro: string
    targetStoreRoot: string
    sshPath: string
    sshOptions: seq[string]
    port: int

  TransferBundleResult = object
    transferStatus: string
    bundleDigestHex: string
    targetBundlePath: string
    prefixesImported: string
    prefixesAlreadyPresent: string
    bytesReceived: string

proc raiseRemoteTransfer(msg: string) {.noreturn.} =
  raise newException(ERemoteTransferFailed, msg)

proc transferActivationBundle(opts: TransferBundleOptions):
    TransferBundleResult =
  let bundleDigest = parsePrefixIdHex(opts.bundleDigestHex)
  let resolvedStoreRoot = resolveStoreRoot(opts.storeRoot)
  var store = openStore(resolvedStoreRoot)
  defer:
    try: store.close() except CatchableError: discard
  let bundleBytes = store.readCasBlob(bundleDigest)
  let bundle = decodeActivationBundleBytes(bundleBytes,
    store.casPath(bundleDigest))

  var queryExtra = @["--query", opts.bundleDigestHex]
  for prefix in bundle.prefixes:
    queryExtra.add("--query-prefix")
    queryExtra.add(prefixIdHex(prefix.prefixId))
  let query = sshRun(opts.sshPath, opts.target, opts.port, opts.sshOptions,
    remoteReceiveCommand(opts.remoteRepro, opts.targetStoreRoot, queryExtra))
  if query.exitCode != 0:
    raiseRemoteTransfer("target query failed:\n" & query.output)

  let bundlePresent = fieldValueLoose(query.output, "bundlePresent") == "true"
  let targetBundlePath = fieldValueLoose(query.output, "targetBundlePath")
  var receiveExtra: seq[string]
  receiveExtra.add("--expected-digest")
  receiveExtra.add(opts.bundleDigestHex)
  result.transferStatus =
    if bundlePresent:
      if targetBundlePath.len == 0:
        raise newException(ValueError,
          "target query did not return targetBundlePath")
      receiveExtra.add("--bundle")
      receiveExtra.add(targetBundlePath)
      "already-present"
    else:
      "sent"
  let input = if bundlePresent: "" else: bytesToString(bundleBytes)
  let recv = sshRun(opts.sshPath, opts.target, opts.port, opts.sshOptions,
    remoteReceiveCommand(opts.remoteRepro, opts.targetStoreRoot, receiveExtra),
    input)
  if recv.exitCode != 0:
    raiseRemoteTransfer("target receive failed:\n" & recv.output)

  let recvTargetPath = fieldValueLoose(recv.output, "targetBundlePath")
  result.bundleDigestHex = opts.bundleDigestHex.toLowerAscii()
  result.targetBundlePath =
    if recvTargetPath.len > 0: recvTargetPath else: targetBundlePath
  result.prefixesImported = fieldValueLoose(recv.output, "prefixesImported")
  result.prefixesAlreadyPresent = fieldValueLoose(recv.output,
    "prefixesAlreadyPresent")
  result.bytesReceived = if bundlePresent: "0" else: $bundleBytes.len

proc renderTransferResult(res: TransferBundleResult) =
  echo "transferStatus: " & res.transferStatus
  echo "bundleDigest: " & res.bundleDigestHex
  echo "targetBundlePath: " & res.targetBundlePath
  echo "prefixesImported: " & res.prefixesImported
  echo "prefixesAlreadyPresent: " & res.prefixesAlreadyPresent
  echo "bytesReceived: " & res.bytesReceived

type
  RemoteBuildResult = object
    localGenerationId: string
    bundleDigestHex: string
    bundlePath: string
    sourceStateDir: string
    sourceStoreRoot: string

proc remoteApplyTargetContext(parsed: EnableDisableFlags): HostContext =
  result = currentHostContext()
  result.host = parsed.host
  if parsed.remote.targetPlatform.len > 0:
    result.platform = parsed.remote.targetPlatform
  if parsed.remote.targetArch.len > 0:
    result.arch = parsed.remote.targetArch
  if parsed.remote.targetWslGiven:
    result.isWsl = parsed.remote.targetWsl
    if parsed.remote.targetWsl and parsed.remote.targetPlatform.len == 0:
      result.platform = "linux"
  # A remote target: this machine's os-release does not say whether it is
  # NixOS.
  result.nixosStated = false

proc validateRemoteApplyPreflight(name: string;
                                  parsed: EnableDisableFlags;
                                  targetCtx: HostContext): int =
  if parsed.remote.targetStoreRoot.len == 0:
    stderr.writeLine("repro home " & name & ": remote apply preflight " &
      "failed: --target-store-root is required for --host --now")
    stderr.writeLine("remoteApplyStatus: failed")
    stderr.writeLine("remoteApplyPhase: preflight")
    stderr.writeLine("targetHost: " & parsed.host)
    stderr.writeLine("localIntentStatus: preserved")
    return 2
  if parsed.remote.targetStoreDaemon.len == 0 and
      parsed.remote.targetStoreEndpoint.len > 0:
    stderr.writeLine("repro home " & name & ": remote apply preflight " &
      "failed: --target-store-endpoint requires --target-store-daemon=dev")
    stderr.writeLine("remoteApplyStatus: failed")
    stderr.writeLine("remoteApplyPhase: preflight")
    stderr.writeLine("targetHost: " & parsed.host)
    stderr.writeLine("localIntentStatus: preserved")
    return 2
  if parsed.remote.targetStoreDaemon == "dev" and
      parsed.remote.targetStoreEndpoint.len == 0:
    stderr.writeLine("repro home " & name & ": remote apply preflight " &
      "failed: --target-store-endpoint is required with " &
      "--target-store-daemon=dev")
    stderr.writeLine("remoteApplyStatus: failed")
    stderr.writeLine("remoteApplyPhase: preflight")
    stderr.writeLine("targetHost: " & parsed.host)
    stderr.writeLine("localIntentStatus: preserved")
    return 2
  if parsed.remote.targetStateDir.len == 0:
    stderr.writeLine("repro home " & name & ": remote apply preflight " &
      "failed: --target-state-dir is required for --host --now")
    stderr.writeLine("remoteApplyStatus: failed")
    stderr.writeLine("remoteApplyPhase: preflight")
    stderr.writeLine("targetHost: " & parsed.host)
    stderr.writeLine("localIntentStatus: preserved")
    return 2
  if parsed.remote.targetHomeDir.len == 0:
    stderr.writeLine("repro home " & name & ": remote apply preflight " &
      "failed: --target-home-dir is required for this remote apply " &
      "implementation; refusing to evaluate against the source HOME")
    stderr.writeLine("remoteApplyStatus: failed")
    stderr.writeLine("remoteApplyPhase: preflight")
    stderr.writeLine("targetHost: " & parsed.host)
    stderr.writeLine("localIntentStatus: preserved")
    return 2

  let sourceCtx = currentHostContext()
  if targetCtx.platform != sourceCtx.platform:
    stderr.writeLine("repro home " & name & ": remote apply preflight " &
      "failed: target platform '" & targetCtx.platform & "' differs from " &
      "source platform '" & sourceCtx.platform & "', and no cross-builder " &
      "capability is configured")
    stderr.writeLine("remoteApplyStatus: failed")
    stderr.writeLine("remoteApplyPhase: preflight")
    stderr.writeLine("targetHost: " & parsed.host)
    stderr.writeLine("sourcePlatform: " & sourceCtx.platform)
    stderr.writeLine("targetPlatform: " & targetCtx.platform)
    stderr.writeLine("missingCapability: cross-builder")
    stderr.writeLine("localIntentStatus: preserved")
    stderr.writeLine("hint: run the apply on the target host or configure " &
      "a cross-builder before retrying")
    return 1
  0

proc buildRemoteApplyBundle(parsed: EnableDisableFlags;
                            targetCtx: HostContext): RemoteBuildResult =
  result.sourceStateDir = resolveStateDir()
  result.sourceStoreRoot = resolveStoreRoot()
  var applyOpts: ApplyOptions
  applyOpts.stateDir = result.sourceStateDir
  applyOpts.storeRoot = result.sourceStoreRoot
  applyOpts.homeDir = parsed.remote.targetHomeDir
  applyOpts.host = parsed.host
  applyOpts.targetContext = targetCtx
  applyOpts.hasTargetContext = true
  applyOpts.recordOnlyGeneratedFiles = true
  let applied = runApply(applyOpts)
  result.localGenerationId = applied.generationIdHex
  var store = openStore(result.sourceStoreRoot)
  defer:
    try: store.close() except CatchableError: discard
  let bundle = writeActivationBundle(result.sourceStateDir, store,
    result.localGenerationId)
  result.bundleDigestHex = bundle.bundleDigestHex
  result.bundlePath = bundle.bundlePath

proc remoteActivateCommand(remoteRepro, targetStoreRoot, targetStateDir,
                           bundleDigestHex: string): string =
  let parts = @[remoteRepro, "home", "__remote-activate",
    "--store-root", targetStoreRoot,
    "--state-dir", targetStateDir,
    "--bundle-digest", bundleDigestHex]
  for idx, part in parts:
    if idx > 0:
      result.add(" ")
    result.add(quoteShell(part))

type
  ERemoteStoreDaemonFailed = object of CatchableError

  RemoteStoreDaemonResult = object
    enabled: bool
    endpoint: string
    storeRoot: string
    profile: string
    pid: string

proc remoteStoreDaemonCommand(remoteRepro, action, targetStoreRoot,
                              targetStoreEndpoint: string): string =
  let parts = @[remoteRepro, "store", "daemon", action, "--dev",
    "--store-root", targetStoreRoot, "--endpoint", targetStoreEndpoint]
  for idx, part in parts:
    if idx > 0:
      result.add(" ")
    result.add(quoteShell(part))

proc requireRemoteStoreDaemon(parsed: EnableDisableFlags):
    RemoteStoreDaemonResult =
  if parsed.remote.targetStoreDaemon.len == 0:
    return RemoteStoreDaemonResult(enabled: false)

  let start = sshRun(parsed.remote.sshPath, parsed.host, parsed.remote.port,
    parsed.remote.sshOptions,
    remoteStoreDaemonCommand(parsed.remote.remoteRepro, "start",
      parsed.remote.targetStoreRoot, parsed.remote.targetStoreEndpoint))
  if start.exitCode != 0:
    raise newException(ERemoteStoreDaemonFailed,
      "target dev store daemon start failed:\n" & start.output)

  let status = sshRun(parsed.remote.sshPath, parsed.host, parsed.remote.port,
    parsed.remote.sshOptions,
    remoteStoreDaemonCommand(parsed.remote.remoteRepro, "status",
      parsed.remote.targetStoreRoot, parsed.remote.targetStoreEndpoint))
  if status.exitCode != 0:
    raise newException(ERemoteStoreDaemonFailed,
      "target dev store daemon status failed:\n" & status.output)

  let profile = fieldValueLoose(status.output, "profile")
  let endpoint = fieldValueLoose(status.output, "endpoint")
  let storeRoot = fieldValueLoose(status.output, "store-root")
  if not status.output.contains("repro store daemon: running"):
    raise newException(ERemoteStoreDaemonFailed,
      "target dev store daemon is not running:\n" & status.output)
  if profile != "development-store":
    raise newException(ERemoteStoreDaemonFailed,
      "target endpoint is not a development-store daemon:\n" & status.output)
  if endpoint != parsed.remote.targetStoreEndpoint:
    raise newException(ERemoteStoreDaemonFailed,
      "target dev store daemon endpoint mismatch: expected " &
      parsed.remote.targetStoreEndpoint & ", got " & endpoint)
  if os.normalizedPath(storeRoot) !=
      os.normalizedPath(parsed.remote.targetStoreRoot):
    raise newException(ERemoteStoreDaemonFailed,
      "target dev store daemon store-root mismatch: expected " &
      parsed.remote.targetStoreRoot & ", got " & storeRoot)

  RemoteStoreDaemonResult(
    enabled: true,
    endpoint: endpoint,
    storeRoot: storeRoot,
    profile: profile,
    pid: fieldValueLoose(status.output, "pid"))

proc printRemoteApplyFailure(name, phase, message: string;
                             parsed: EnableDisableFlags;
                             built: RemoteBuildResult;
                             transferred: TransferBundleResult) =
  stderr.writeLine("repro home " & name & ": remote apply phase '" & phase &
    "' failed for target '" & parsed.host & "'")
  stderr.writeLine("remoteApplyStatus: failed")
  stderr.writeLine("remoteApplyPhase: " & phase)
  stderr.writeLine("targetHost: " & parsed.host)
  stderr.writeLine("localIntentStatus: preserved")
  if built.localGenerationId.len > 0:
    stderr.writeLine("localGenerationId: " & built.localGenerationId)
  if built.bundleDigestHex.len > 0:
    stderr.writeLine("bundleDigest: " & built.bundleDigestHex)
  if built.bundlePath.len > 0:
    stderr.writeLine("bundlePath: " & built.bundlePath)
  if transferred.targetBundlePath.len > 0:
    stderr.writeLine("targetBundlePath: " & transferred.targetBundlePath)
  if transferred.transferStatus.len > 0:
    stderr.writeLine("transferStatus: " & transferred.transferStatus)
  stderr.writeLine("retryContext: rerun the same `repro home " & name & " " &
    parsed.activity & " --host " & parsed.host & " --now` command after " &
    "fixing the " & phase & " failure")
  if message.len > 0:
    stderr.writeLine(message)

proc runRemoteApplyAfterEdit(name: string; parsed: EnableDisableFlags): int =
  let targetCtx = remoteApplyTargetContext(parsed)
  let preflight = validateRemoteApplyPreflight(name, parsed, targetCtx)
  if preflight != 0:
    return preflight

  var built: RemoteBuildResult
  var targetDaemon = RemoteStoreDaemonResult(enabled: false)
  if parsed.remote.targetStoreDaemon.len > 0:
    try:
      targetDaemon = requireRemoteStoreDaemon(parsed)
    except CatchableError as err:
      printRemoteApplyFailure(name, "store-daemon", err.msg, parsed, built,
        TransferBundleResult())
      return 1

  try:
    built = buildRemoteApplyBundle(parsed, targetCtx)
  except CatchableError as err:
    printRemoteApplyFailure(name, "build", err.msg, parsed, built,
      TransferBundleResult())
    return 1

  var transferred: TransferBundleResult
  try:
    transferred = transferActivationBundle(TransferBundleOptions(
      bundleDigestHex: built.bundleDigestHex,
      storeRoot: built.sourceStoreRoot,
      target: parsed.host,
      remoteRepro: parsed.remote.remoteRepro,
      targetStoreRoot: parsed.remote.targetStoreRoot,
      sshPath: parsed.remote.sshPath,
      sshOptions: parsed.remote.sshOptions,
      port: parsed.remote.port))
  except CatchableError as err:
    printRemoteApplyFailure(name, "transfer", err.msg, parsed, built,
      transferred)
    return 1

  let activate = sshRun(parsed.remote.sshPath, parsed.host,
    parsed.remote.port, parsed.remote.sshOptions,
    remoteActivateCommand(parsed.remote.remoteRepro,
      parsed.remote.targetStoreRoot, parsed.remote.targetStateDir,
      built.bundleDigestHex))
  if activate.exitCode != 0:
    printRemoteApplyFailure(name, "activate", activate.output, parsed, built,
      transferred)
    return 1

  echo "remoteApplyStatus: activated"
  echo "targetHost: " & parsed.host
  echo "localGenerationId: " & built.localGenerationId
  echo "bundleDigest: " & built.bundleDigestHex
  echo "bundlePath: " & built.bundlePath
  echo "transferStatus: " & transferred.transferStatus
  echo "targetBundlePath: " & transferred.targetBundlePath
  if targetDaemon.enabled:
    echo "targetStoreDaemon: " & targetDaemon.profile
    echo "targetStoreEndpoint: " & targetDaemon.endpoint
    echo "targetStoreDaemonPid: " & targetDaemon.pid
  echo "remoteGenerationId: " & fieldValueLoose(activate.output,
    "generationId")
  echo "targetCurrent: " & fieldValueLoose(activate.output, "current")
  return 0

proc runHomeTransferBundle(c: ReproCommandLineHomeTransferBundle): int =
  let bundleDigestHex = c.bundleDigest
  let storeRoot = c.storeRoot
  let target = c.target
  let remoteRepro = c.remoteRepro
  let targetStoreRoot = c.targetStoreRoot
  let sshPath = c.ssh
  let sshOptions = c.sshOption
  let port = c.port
  if bundleDigestHex.len == 0 or target.len == 0 or targetStoreRoot.len == 0:
    stderr.writeLine("repro home __transfer-bundle: --bundle-digest, " &
      "--target, and --target-store-root are required")
    return 2

  try:
    let res = transferActivationBundle(TransferBundleOptions(
      bundleDigestHex: bundleDigestHex,
      storeRoot: storeRoot,
      target: target,
      remoteRepro: remoteRepro,
      targetStoreRoot: targetStoreRoot,
      sshPath: sshPath,
      sshOptions: sshOptions,
      port: port))
    renderTransferResult(res)
    return 0
  except ERemoteTransferFailed as err:
    stderr.writeLine("repro home __transfer-bundle: " & err.msg)
    return 1
  except StoreError as err:
    stderr.writeLine("repro home __transfer-bundle: store error: " & err.msg)
    return 1
  except ValueError as err:
    stderr.writeLine("repro home __transfer-bundle: " & err.msg)
    return 2
  except CatchableError as err:
    stderr.writeLine("repro home __transfer-bundle: error: " & err.msg)
    return 1

# ---------------------------------------------------------------------------
# `repro home __remote-activate` (M71 Phase D, internal target runtime).
# ---------------------------------------------------------------------------

type
  ERemoteActivationFailed = object of CatchableError

  RemoteActivationPayload = object
    envelope: PointerEnvelope
    manifest: ActivationManifest
    generationIdHex: string

proc raiseRemoteActivation(msg: string) {.noreturn.} =
  raise newException(ERemoteActivationFailed, msg)

proc keyFromDigest(digest: Digest256): PrefixIdBytes =
  for i in 0 ..< 32:
    result[i] = digest[i]

proc digestBytesForActivation(bytes: openArray[byte]): Digest256 =
  blake3.digest(bytes)

proc currentPlatformName(): string =
  when defined(windows):
    "windows"
  elif defined(macosx):
    "macos"
  elif defined(linux):
    "linux"
  else:
    "unknown"

proc validateRemoteActivationPayload(bundle: ActivationBundle;
                                     filePath: string):
    RemoteActivationPayload =
  let envelope = decodePointerBytes(bundle.pointerEnvelopeBytes,
    filePath & ":pointer")
  let generationId = generationIdHex(envelope.generationId)
  if envelope.generationId != bundle.sourceGenerationId:
    raiseRemoteActivation("pointer generation id " & generationId &
      " does not match bundle source generation id " &
      generationIdHex(bundle.sourceGenerationId))
  if envelope.hostIdentity != bundle.hostIdentity:
    raiseRemoteActivation("pointer host identity '" & envelope.hostIdentity &
      "' does not match bundle host identity '" & bundle.hostIdentity & "'")
  if envelope.activationTimestamp != bundle.activationTimestamp:
    raiseRemoteActivation("pointer activation timestamp does not match bundle")
  if digestBytesForActivation(bundle.activationManifestBytes) !=
      envelope.activationManifestDigest:
    raiseRemoteActivation("bundled activation manifest bytes do not hash to " &
      "the pointer activationManifestDigest")
  if digestBytesForActivation(bundle.intentSnapshotBytes) !=
      envelope.intentSnapshotDigest:
    raiseRemoteActivation("bundled intent snapshot bytes do not hash to " &
      "the pointer intentSnapshotDigest")
  if digestBytesForActivation(bundle.configurableGraphBytes) !=
      envelope.configurableGraphDigest:
    raiseRemoteActivation("bundled configurable graph bytes do not hash to " &
      "the pointer configurableGraphDigest")

  let manifest = decodeManifestBytes(bundle.activationManifestBytes,
    filePath & ":manifest")
  discard decodeSnapshotBytes(bundle.intentSnapshotBytes,
    filePath & ":snapshot")

  proc prefixInPointer(digest: Digest256): bool =
    for p in envelope.realizedPrefixIds:
      if p == digest:
        return true
    false

  for pkg in manifest.realizedPackages:
    if not prefixInPointer(pkg.realizedPrefixId):
      raiseRemoteActivation("manifest package '" & pkg.packageId &
        "' references a realized prefix not present in the pointer")

  if manifest.managedBlocks.len > 0:
    raiseRemoteActivation("remote activation cannot replay managed-block " &
      "records yet; refusing to ignore " & $manifest.managedBlocks.len &
      " managed block(s)")
  if manifest.resourceBindings.len > 0:
    raiseRemoteActivation("remote activation cannot replay resource binding " &
      "records yet; refusing to ignore " & $manifest.resourceBindings.len &
      " resource binding(s)")
  for i, gf in manifest.generatedFiles:
    if gf.ownershipPolicy != gfoOwned:
      raiseRemoteActivation("remote activation supports only owned " &
        "generated files; generatedFiles[" & $i & "] uses " &
        $gf.ownershipPolicy)
    if gf.stowSource.len > 0:
      raiseRemoteActivation("remote activation cannot replay stow-generated " &
        "file records yet: " & gf.absoluteOutputPath)
    if gf.storeContentHash != gf.postWriteDigest:
      raiseRemoteActivation("remote activation requires owned generated " &
        "file content hash to equal post-write digest: " &
        gf.absoluteOutputPath)

  RemoteActivationPayload(
    envelope: envelope,
    manifest: manifest,
    generationIdHex: generationId)

proc ensurePointerPrefixesPresent(store: Store; envelope: PointerEnvelope) =
  for i, digest in envelope.realizedPrefixIds:
    let key = keyFromDigest(digest)
    let lookup = store.lookupPrefix(key)
    if not lookup.found:
      raiseRemoteActivation("realized prefix " & prefixIdHex(key) &
        " from pointer index " & $i & " is not imported in target store")
    let abs = store.absolutePrefixPath(lookup.row.realizedPath)
    if not dirExists(extendedPath(abs)):
      raiseRemoteActivation("realized prefix " & prefixIdHex(key) &
        " is indexed but missing on disk at " & abs)

proc loadCurrentGeneratedFiles(stateDir: string; store: Store):
    Table[string, GeneratedFile] =
  result = initTable[string, GeneratedFile]()
  let active = readCurrentGenerationId(stateDir)
  if active.len == 0:
    return
  let env = readPointerFile(pointerPath(stateDir, active))
  let manifestBytes = store.readCasBlob(keyFromDigest(
    env.activationManifestDigest))
  let manifest = decodeManifestBytes(manifestBytes,
    "current generation " & active & " activation manifest")
  for gf in manifest.generatedFiles:
    result[gf.absoluteOutputPath] = gf

proc currentGeneratedFileDigests(stateDir: string; store: Store):
    Table[string, Digest256] =
  result = initTable[string, Digest256]()
  for path, gf in loadCurrentGeneratedFiles(stateDir, store):
    result[path] = gf.postWriteDigest

proc fileDigestForActivation(path: string): Digest256 =
  digestBytesForActivation(readBinaryFile(path))

proc atomicWriteActivationBytes(path: string; content: openArray[byte]) =
  let parent = parentDir(path)
  if parent.len > 0:
    createDir(extendedPath(parent))
  let tmp = path & ".repro-remote-activate.tmp"
  writeFile(extendedPath(tmp), bytesToString(content))
  if fileExists(extendedPath(path)) or symlinkExists(extendedPath(path)):
    try:
      removeFile(extendedPath(path))
    except OSError as err:
      try: removeFile(extendedPath(tmp)) except OSError: discard
      raiseRemoteActivation("could not replace generated file " & path &
        ": " & err.msg)
  try:
    moveFile(extendedPath(tmp), extendedPath(path))
  except OSError as err:
    try: removeFile(extendedPath(tmp)) except OSError: discard
    raiseRemoteActivation("could not move generated file into place at " &
      path & ": " & err.msg)

proc materializeOwnedGeneratedFiles(store: Store; stateDir: string;
                                    manifest: ActivationManifest): int =
  let currentDigests = currentGeneratedFileDigests(stateDir, store)
  for gf in manifest.generatedFiles:
    let content = store.readCasBlob(keyFromDigest(gf.storeContentHash))
    if digestBytesForActivation(content) != gf.postWriteDigest:
      raiseRemoteActivation("CAS content for generated file does not match " &
        "post-write digest: " & gf.absoluteOutputPath)
    if fileExists(extendedPath(gf.absoluteOutputPath)):
      let live = fileDigestForActivation(gf.absoluteOutputPath)
      if live == gf.postWriteDigest:
        inc result
        continue
      if gf.absoluteOutputPath in currentDigests:
        if currentDigests[gf.absoluteOutputPath] != live:
          raiseRemoteActivation("generated file drift at " &
            gf.absoluteOutputPath & "; live bytes no longer match the " &
            "current generation")
      else:
        raiseRemoteActivation("generated file target already exists outside " &
          "remote activation state: " & gf.absoluteOutputPath)
    atomicWriteActivationBytes(gf.absoluteOutputPath, content)
    if fileDigestForActivation(gf.absoluteOutputPath) != gf.postWriteDigest:
      raiseRemoteActivation("generated file post-write digest mismatch at " &
        gf.absoluteOutputPath)
    inc result

proc removeRetiredOwnedGeneratedFiles(store: Store; stateDir: string;
                                      manifest: ActivationManifest): int =
  let currentFiles = loadCurrentGeneratedFiles(stateDir, store)
  if currentFiles.len == 0:
    return
  var nextPaths = initHashSet[string]()
  for gf in manifest.generatedFiles:
    nextPaths.incl gf.absoluteOutputPath
  for path, old in currentFiles:
    if path in nextPaths:
      continue
    if old.ownershipPolicy != gfoOwned:
      raiseRemoteActivation("remote activation cannot retire non-owned " &
        "generated file from current generation: " & path)
    if fileExists(extendedPath(path)):
      let live = fileDigestForActivation(path)
      if live != old.postWriteDigest:
        raiseRemoteActivation("generated file drift at " & path &
          "; live bytes no longer match the current generation")
      try:
        removeFile(extendedPath(path))
      except OSError as err:
        raiseRemoteActivation("could not remove retired generated file " &
          path & ": " & err.msg)
      inc result

proc isSafeLauncherName(name: string): bool =
  if name.len == 0 or name == "." or name == "..":
    return false
  for ch in name:
    if ch == '/' or ch == '\\' or ch == '\0':
      return false
  true

proc remapPrefixPathValue(value, sourcePrefix, targetPrefix: string): string =
  if sourcePrefix.len == 0:
    return value
  value.replace(sourcePrefix, targetPrefix)

proc remapLaunchPlanToTarget(plan: var LaunchPlan; targetPrefix: string) =
  let sourcePrefix = plan.realizedPrefix
  if sourcePrefix.len == 0:
    raiseRemoteActivation("launch plan for " & plan.exportedCommand &
      " has no realizedPrefix to remap")
  plan.realizedPrefix = targetPrefix
  plan.executablePath = remapPrefixPathValue(plan.executablePath,
    sourcePrefix, targetPrefix)
  if plan.hasWorkingDirectory:
    plan.workingDirectory = remapPrefixPathValue(plan.workingDirectory,
      sourcePrefix, targetPrefix)
  for i in 0 ..< plan.runtimeLibraryDirs.len:
    plan.runtimeLibraryDirs[i] = remapPrefixPathValue(
      plan.runtimeLibraryDirs[i], sourcePrefix, targetPrefix)
  for i in 0 ..< plan.environmentBindings.len:
    plan.environmentBindings[i].value = remapPrefixPathValue(
      plan.environmentBindings[i].value, sourcePrefix, targetPrefix)
  for i in 0 ..< plan.executableBindings.len:
    plan.executableBindings[i].executablePath = remapPrefixPathValue(
      plan.executableBindings[i].executablePath, sourcePrefix, targetPrefix)
  if not plan.executablePath.startsWith(targetPrefix):
    raiseRemoteActivation("launch plan executable did not remap into target " &
      "prefix for " & plan.exportedCommand)

proc materializeRemoteLaunchers(store: Store; stateDir, generationId: string;
                                manifest: ActivationManifest): int =
  if manifest.exportedCommands.len == 0:
    return 0
  when defined(windows):
    raiseRemoteActivation("remote activation launcher materialization is not " &
      "implemented on Windows yet")
  else:
    let binDir = generationBinDir(stateDir, generationId)
    createDir(extendedPath(binDir))
    for command in manifest.exportedCommands:
      if command.binDirArtifactKind != "launcher-script":
        raiseRemoteActivation("remote activation supports only POSIX " &
          "launcher-script artifacts; command " & command.commandName &
          " records " & command.binDirArtifactKind)
      if not isSafeLauncherName(command.commandName):
        raiseRemoteActivation("unsafe exported command name: " &
          command.commandName)
      let launchKey = keyFromDigest(command.launchPlanDigest)
      var plan = decodeLaunchPlan(store.readCasBlob(launchKey))
      if plan.supportProfile.platform.len > 0 and
          plan.supportProfile.platform != currentPlatformName():
        raiseRemoteActivation("launch plan for " & command.commandName &
          " targets platform " & plan.supportProfile.platform &
          " but remote activation is running on " & currentPlatformName())
      if plan.provenance.realizationHashHex.len == 0:
        raiseRemoteActivation("launch plan for " & command.commandName &
          " lacks realization-hash provenance")
      let prefixKey = parsePrefixIdHex(plan.provenance.realizationHashHex)
      let lookup = store.lookupPrefix(prefixKey)
      if not lookup.found:
        raiseRemoteActivation("launch plan for " & command.commandName &
          " references missing target prefix " &
          plan.provenance.realizationHashHex)
      let targetPrefix = store.absolutePrefixPath(lookup.row.realizedPath)
      if not dirExists(extendedPath(targetPrefix)):
        raiseRemoteActivation("launch plan target prefix is missing on disk: " &
          targetPrefix)
      remapLaunchPlanToTarget(plan, targetPrefix)
      plan.binding = when defined(macosx): lbkMacosScript else: lbkLinuxScript
      let scriptPath = binDir / command.commandName
      let scriptBody = generatePosixLauncherScript(plan,
        when defined(macosx): "DYLD_LIBRARY_PATH" else: "LD_LIBRARY_PATH")
      # A content-addressed id may name a generation that is already
      # committed: replace by rename, never write in place.
      try:
        replaceLauncherFile(scriptPath, scriptBody, LauncherScriptMode)
      except CatchableError as err:
        raiseRemoteActivation("could not write launcher " & scriptPath &
          ": " & err.msg)
      inc result

proc runHomeRemoteActivate[T](c: T): int =
  ## `repro home __remote-activate` (and its older spelling `repro
  ## __remote-activate`, whose configuration object has the same fields).
  let storeRoot = c.storeRoot
  let stateDir = c.stateDir
  let bundleDigestHex = c.bundleDigest
  let expectedDigest = c.expectedDigest
  let bundlePath = c.bundle
  if storeRoot.len == 0 or stateDir.len == 0:
    stderr.writeLine("repro home __remote-activate: --store-root and " &
      "--state-dir are required")
    return 2
  if bundleDigestHex.len == 0 and bundlePath.len == 0:
    stderr.writeLine("repro home __remote-activate: --bundle-digest or " &
      "--bundle is required")
    return 2
  if bundleDigestHex.len > 0 and expectedDigest.len > 0 and
      bundleDigestHex.toLowerAscii() != expectedDigest.toLowerAscii():
    stderr.writeLine("repro home __remote-activate: --bundle-digest and " &
      "--expected-digest disagree")
    return 2

  try:
    ensureStateDir(stateDir)
    var lock = acquireApplyLock(stateDir, timeoutSeconds = 30)
    try:
      var store = openStore(resolveStoreRoot(storeRoot))
      defer:
        try: store.close() except CatchableError: discard

      let bytes =
        if bundlePath.len > 0:
          readBinaryFile(bundlePath)
        else:
          store.readCasBlob(parsePrefixIdHex(bundleDigestHex))
      let expected =
        if expectedDigest.len > 0: expectedDigest
        elif bundleDigestHex.len > 0: bundleDigestHex
        else: ""
      let imported = importActivationBundleBytes(store, bytes,
        expectedDigestHex = expected,
        filePath = if bundlePath.len > 0: bundlePath else:
          store.casPath(parsePrefixIdHex(bundleDigestHex)))
      let bundle = decodeActivationBundleBytes(bytes,
        if bundlePath.len > 0: bundlePath else: imported.targetBundlePath)
      let payload = validateRemoteActivationPayload(bundle,
        if bundlePath.len > 0: bundlePath else: imported.targetBundlePath)
      ensurePointerPrefixesPresent(store, payload.envelope)

      let launchersMaterialized = materializeRemoteLaunchers(store, stateDir,
        payload.generationIdHex, payload.manifest)
      let generatedFilesMaterialized = materializeOwnedGeneratedFiles(store,
        stateDir, payload.manifest)
      let generatedFilesRemoved = removeRetiredOwnedGeneratedFiles(store,
        stateDir, payload.manifest)

      var envelope = payload.envelope
      writeGeneration(stateDir, envelope, bundle.activationManifestBytes,
        bundle.intentSnapshotBytes, bundle.configurableGraphBytes, store)
      rotateCurrent(stateDir, payload.generationIdHex)

      echo "activationStatus: activated"
      echo "bundleDigest: " & imported.bundleDigestHex
      echo "targetBundlePath: " & imported.targetBundlePath
      echo "generationId: " & payload.generationIdHex
      echo "current: " & readCurrentGenerationId(stateDir)
      echo "prefixesImported: " & $imported.prefixesImported
      echo "prefixesAlreadyPresent: " & $imported.prefixesAlreadyPresent
      echo "launchersMaterialized: " & $launchersMaterialized
      echo "generatedFilesMaterialized: " & $generatedFilesMaterialized
      echo "generatedFilesRemoved: " & $generatedFilesRemoved
      return 0
    finally:
      releaseApplyLock(lock)
  except ERemoteActivationFailed as err:
    stderr.writeLine("repro home __remote-activate: " & err.msg)
    return 1
  except EActivationBundleCorrupt as err:
    stderr.writeLine("repro home __remote-activate: " & err.msg)
    return 1
  except EPointerCorrupt as err:
    stderr.writeLine("repro home __remote-activate: corrupt pointer at " &
      err.pointerPath & " (field: " & err.field & ")")
    return 1
  except EManifestCorrupt as err:
    stderr.writeLine("repro home __remote-activate: corrupt manifest at " &
      err.manifestPath & " (field: " & err.field & ")")
    return 1
  except EIntentSnapshotCorrupt as err:
    stderr.writeLine("repro home __remote-activate: corrupt intent snapshot " &
      "at " & err.snapshotPath & " (field: " & err.field & ")")
    return 1
  except EApplyBusy as err:
    stderr.writeLine("repro home __remote-activate: another apply/activation " &
      "is in progress (lock " & err.lockPath & " held; waited " &
      $err.waitedSeconds & "s).")
    return 1
  except StoreError as err:
    stderr.writeLine("repro home __remote-activate: store error: " & err.msg)
    return 1
  except LaunchPlanCodecError as err:
    stderr.writeLine("repro home __remote-activate: launch plan error: " &
      err.msg)
    return 1
  except ValueError as err:
    stderr.writeLine("repro home __remote-activate: " & err.msg)
    return 2
  except CatchableError as err:
    stderr.writeLine("repro home __remote-activate: error: " & err.msg)
    return 1

# ---------------------------------------------------------------------------
# `repro home set` / `repro home get` (M65).
# ---------------------------------------------------------------------------

proc splitPkgDotKey(raw: string): tuple[ok: bool; pkg, key: string] =
  let dot = raw.find('.')
  if dot <= 0 or dot == raw.len - 1:
    return (false, "", "")
  (true, raw[0 ..< dot], raw[dot + 1 .. ^1])

proc printConfigurableInactive(pkg, key, profilePath: string) =
  stderr.writeLine("repro home set: configurable `" & pkg & "." & key &
    "` targets package `" & pkg & "` which is NOT enabled by any active " &
    "activity in profile `" & profilePath & "`. The override would be a " &
    "no-op — refusing to write a dead entry to the profile.")
  stderr.writeLine("  hint: add `" & pkg & "` to an activity that the " &
    "current host enables (or `repro home enable <activity>` it first), " &
    "then re-run `repro home set`.")

proc printUnknownConfigurable(pkg, key, profilePath: string) =
  stderr.writeLine("repro home set: configurable `" & key &
    "` is not declared by package `" & pkg & "` (profile `" &
    profilePath & "`).")
  stderr.writeLine("  hint: check the package's configurable schema " &
    "with `repro home why " & pkg & "` (or set " &
    "$REPRO_HOME_CONFIGURABLE_SCHEMA for the gate seam).")

proc runHomeSet(c: ReproCommandLineHomeSet): int =
  ## `repro home set <pkg>.<key> <value> [--when PRED] [--no-apply]` —
  ## write the given configurable into the profile's `config:` section
  ## (under a `when PRED:` guard inside the package block when `--when` is
  ## given) through
  ## the M60 structural editor, then run the M63 apply pipeline
  ## inline with the M58 incremental refinalize fast path
  ## (`applyMode = amSet`). Pre-validates that the package is enabled
  ## by some active activity AND that the key is declared by the
  ## package's configurable schema before touching `home.nim`; both
  ## diagnostics surface BEFORE the edit so a rejected `set` leaves
  ## the profile byte-identical.
  let pkgDotKey = c.key
  let value = c.value
  let noApply = c.noApply
  let whenPredicate = c.whenPredicate.get("")
  if c.whenPredicate.isSome and whenPredicate.strip().len == 0:
    stderr.writeLine("repro home set: --when needs a predicate " &
      "expression (e.g. `--when windows`)")
    return 2
  # The guard's predicate is validated (repro_home_intent's predicate
  # grammar) before the profile is read, so a malformed one is a usage
  # error naming the flag rather than a profile diagnostic.
  var guardAst: PredNode = nil
  if whenPredicate.len > 0:
    try:
      guardAst = parsePredicate("--when", whenPredicate, 0)
    except EUnstructured as e:
      stderr.writeLine("repro home set: invalid --when predicate '" &
        whenPredicate & "': saw " & e.seen & "; expected " & e.expected)
      return 2
  let parts = splitPkgDotKey(pkgDotKey)
  if not parts.ok:
    stderr.writeLine("repro home set: invalid form: '" & pkgDotKey &
      "' must be <package>.<configurable>")
    return 2
  loadConfigurableSchemaFromEnv()
  try:
    let profilePath = loadProfilePath()
    let prof = loadProfile(profilePath)
    # Pre-validation 1: the package must be enabled by some active
    # activity on the current host. The spec says an inactive package
    # override is "silently inert" in the apply pipeline — for `set`,
    # the CLI converts that into a structured diagnostic so the user
    # learns the override would have no effect BEFORE the edit lands.
    #
    # A guarded value (`--when`) is for the hosts its guard selects; when
    # the guard does not hold here (or names a predicate this host cannot
    # evaluate), the current host's package set says nothing about those
    # hosts, so the check is skipped rather than refusing a valid edit.
    let ctx = currentHostContext()
    var checkEnabledHere = true
    if not guardAst.isNil:
      try:
        checkEnabledHere = predicateHolds(guardAst, ctx)
      except ValueError:
        checkEnabledHere = false
    let effective = resolveEffectiveConfig(prof, ctx.host, ctx)
    if checkEnabledHere and parts.pkg notin effective.enabledPackages:
      printConfigurableInactive(parts.pkg, parts.key, profilePath)
      return 1
    # Pre-validation 2: the key must be declared by the package's
    # configurable schema. The seam is fed by
    # $REPRO_HOME_CONFIGURABLE_SCHEMA. When the env var is absent the
    # seam accepts every key — matches "do NOT load packages at
    # runtime" while letting the gate exercise the error path.
    if not configurableInSchema(parts.pkg, parts.key):
      printUnknownConfigurable(parts.pkg, parts.key, profilePath)
      return 1
    # Edit the profile through the M60 structural editor. We already
    # ran the configurable-schema check in the pre-validation pass
    # above, so we pass `nil` here (the editor accepts that as
    # "skip the schema lookup"). Passing a closure that re-reads the
    # schema would require `gcsafe` plumbing around the module-level
    # configured-schema set — and would duplicate the diagnostic we
    # already emitted.
    setConfigurable(profilePath, pkgDotKey, value, nil,
      predicate = whenPredicate)
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EUnknownPredicate as e:
    printUnknownPredicate(e); return 1
  except EUnstructured as e:
    printUnstructured(e); return 1
  except EOverlappingAssignment as e:
    stderr.writeLine("repro home set: " & e.msg)
    return 1
  except EUnknownConfigurable as e:
    printUnknownConfigurable(e.package, e.configurable, e.profilePath)
    return 1
  except EInvalidConfigurable as e:
    stderr.writeLine("repro home set: invalid configurable form: " & e.msg)
    return 1
  except CatchableError as e:
    stderr.writeLine("repro home set: error: " & e.msg)
    return 1
  if noApply:
    return 0
  return runApplyInline("set", amSet, pkgDotKey)

# ---------------------------------------------------------------------------
# `repro home get`.
# ---------------------------------------------------------------------------

proc lookupConfigurableInProfile(prof: Profile; pkg, key: string):
    tuple[found: bool; value: string] =
  ## Find the configurable's resolved value source in the profile's
  ## `config:` block. Returns the raw RHS bytes as stored by the
  ## editor (string literals are quoted, numbers/booleans are not).
  ## The lookup is purely structural — package defaults are NOT
  ## consulted; per spec the M65 `get` returns the user-visible
  ## resolved value under FULL evaluation of the `config:` overrides.
  ## Since fixture packages do not declare defaults at M65 (the
  ## defaults seam is M68), the override IS the resolved value.
  ##
  ## Which assignment is "the" value is decided by
  ## `effectiveConfigAssignments`, the effective-config resolver's rule:
  ## guarded overrides (GM3) count only where their guard holds, and of
  ## several applicable assignments the LAST wins. Those it overrides are
  ## named on stderr (Configurable-System.md §Priorities And Contributions:
  ## "last write wins (with a structured diagnostic listing both sites)").
  let resolved = effectiveConfigAssignments(prof, currentHostContext())
  if pkg notin resolved or key notin resolved[pkg]:
    return (false, "")
  let assignment = resolved[pkg][key]
  if assignment.overridden.len > 0 and assignment.entry.configEntryLine == 0:
    # A compiled profile (`config:` holds a helper call): its overrides
    # carry no source line, only their order, so the note counts them.
    stderr.writeLine("repro home get: note: " & pkg & "." & key &
      " is assigned " & $(assignment.overridden.len + 1) &
      " times on this host in the compiled profile (helper calls in " &
      "`config:` included); the last assignment wins")
  elif assignment.overridden.len > 0:
    let file = extractFilename(prof.path)
    var sites: seq[string]
    for entry in assignment.overridden:
      sites.add file & ":" & $entry.configEntryLine
    stderr.writeLine("repro home get: note: " & pkg & "." & key &
      " is assigned " & $(assignment.overridden.len + 1) &
      " times on this host; the last assignment (" & file & ":" &
      $assignment.entry.configEntryLine & ") wins over " &
      sites.join(", "))
  (true, assignment.entry.configValueSource)

proc configHelperCalls(prof: Profile): seq[IntentNode] =
  ## The constructs in `config:` the text reader cannot see into: helper
  ## calls (`gitIdentity(...)`), at the top level, inside a package block or
  ## under a guard. Each may assign any key, and only the compiled profile
  ## knows which. Constructs elsewhere -- a helper call in an activity body,
  ## an activity's `stow:` / `resources:` block, a `const` before the header
  ## -- assign no `config:` key and are not returned
  ## (Home-Profile-Intent-Layer.md §Constructs the inspector steps over;
  ## reprobuild-pm issue
  ## 2026-10-18-home-get-refuses-a-profile-for-constructs-unrelated-to-config).
  proc walk(nodes: seq[IntentNode]; calls: var seq[IntentNode]) =
    for n in nodes:
      case n.kind
      of nkOpaque: calls.add n
      of nkCondBlock: walk(n.condChildren, calls)
      of nkConfigPackage: walk(n.configEntries, calls)
      else: discard
  for ch in prof.root.children:
    if ch.kind == nkConfigBlock:
      walk(ch.configPackages, result)

proc refuseConfigHelperCalls(profilePath, readPath: string;
                             calls: seq[IntentNode];
                             pkgDotKey, reason: string) {.noreturn.} =
  ## Raise `EUnstructured` naming every helper call in `config:` with its
  ## line, for the one case `get` cannot answer them (`reason`). The lines
  ## are those of the text `calls` were read from (the current generation's
  ## snapshot); `profilePath` is the profile the user knows.
  ## The inspector names each call at `readPath` (a temporary copy of the
  ## snapshot), shown here as `profilePath`.
  var named: seq[string]
  for c in calls:
    named.add c.opaqueConstruct.replace(readPath, profilePath)
  raiseUnstructured(profilePath, calls[0].startLine, calls[0].indent + 1,
    named.join(", ") & " in `config:`",
    "`<key> = <value>` assignments there: a helper call in `config:` may " &
    "assign `" & pkgDotKey & "`, and " & reason)

proc readActiveIntentSnapshot(stateDir: string): Option[IntentSnapshot] =
  ## The intent snapshot of the CURRENT generation, or none when there is
  ## no current generation or its snapshot cannot be read.
  let activeIdHex = readCurrentGenerationId(stateDir)
  if activeIdHex.len == 0:
    return none(IntentSnapshot)
  let pointerFile = pointerPath(stateDir, activeIdHex)
  if not fileExists(extendedPath(pointerFile)):
    return none(IntentSnapshot)
  try:
    let env = readPointerFile(pointerFile)
    var snapshotKey: PrefixIdBytes
    for i in 0 ..< 32:
      snapshotKey[i] = env.intentSnapshotDigest[i]
    let storeRoot = resolveStoreRoot()
    var store = openStore(storeRoot)
    defer:
      try: store.close() except CatchableError: discard
    some(decodeSnapshotBytes(readCasBlob(store, snapshotKey)))
  except CatchableError:
    none(IntentSnapshot)

proc snapshotMatchesProfileDir(snapshot: IntentSnapshot;
                               profileDir: string): bool =
  ## True when the on-disk profile is the one the current generation was
  ## applied from, as far as the snapshot records it: every source file the
  ## snapshot holds -- the top-level `*.nim` files and every file the
  ## compile read under the profile directory, helper modules in
  ## subdirectories included (`profileSourceFiles`) -- is on disk with the
  ## same bytes, and no top-level `*.nim` file was added since. A new
  ## import is an edit of a recorded file, so it is caught too, without a
  ## compile.
  var recorded = initTable[string, seq[byte]]()
  for entry in snapshot.files:
    if entry.role == ifrSource:
      recorded[entry.path] = entry.content
  for path, content in recorded:
    let onDisk = profileDir / path
    if not fileExists(extendedPath(onDisk)):
      return false
    let raw = readFile(extendedPath(onDisk))
    if raw.len != content.len:
      return false
    for i, ch in raw:
      if byte(ord(ch)) != content[i]:
        return false
  for entry in defaultWalkProfileFiles(profileDir):
    if entry.path notin recorded:
      return false
  true

proc unquoteValueDisplay(raw: string): string =
  ## Mirror of the pipeline's `unquoteValueSource`: strip a single
  ## pair of surrounding double quotes and unescape the editor's two
  ## escape sequences so the user-facing `get` output is the logical
  ## value (`Zahary`) rather than the on-disk source (`"Zahary"`).
  if raw.len >= 2 and raw[0] == '"' and raw[^1] == '"':
    var s = raw[1 ..< raw.len - 1]
    s = s.replace("\\\"", "\"").replace("\\\\", "\\")
    return s
  raw

proc profileFromIntentSnapshot(stateDir: string; profilePath: string;
                               snapshot: IntentSnapshot): Option[Profile] =
  ## Load the intent snapshot stored in CAS for the CURRENT
  ## generation and re-parse `home.nim` from those bytes. This is
  ## interpretation (B): `repro home get` reads the resolved value
  ## from the recorded activation, not from the on-disk source. The
  ## on-disk `home.nim` may have been edited since the last apply
  ## (e.g. by a `repro home set --no-apply`) — but until the next
  ## apply, the recorded activation is what the user actually has
  ## live. Rollback rotates `current` to a prior pointer, so
  ## subsequent `get` reads the prior generation's snapshot —
  ## exactly the spec's "rollback restores the prior value of the
  ## configurable" semantics. `snapshot` is `readActiveIntentSnapshot`'s.
  try:
    let anchor = extractFilename(profilePath)
    for entry in snapshot.files:
      if entry.path == anchor or entry.path.endsWith("/" & anchor):
        var content = newString(entry.content.len)
        for i, b in entry.content:
          content[i] = char(b)
        # Re-parse the snapshotted source via a temp file so we
        # reuse the inspector (`inspectProfile`, as for the on-disk
        # profile: `runHomeGet`). The temp lives inside the state dir to
        # keep test isolation tidy.
        let tmpDir = stateDir / "get-tmp"
        createDir(extendedPath(tmpDir))
        let tmpPath = tmpDir / anchor
        writeFile(extendedPath(tmpPath), content)
        try:
          let prof = inspectProfile(tmpPath)
          return some(prof)
        finally:
          try: removeFile(extendedPath(tmpPath)) except OSError: discard
    return none(Profile)
  except CatchableError:
    return none(Profile)

proc runHomeGet(c: ReproCommandLineHomeGet): int =
  ## `repro home get <pkg>.<key>` — print the resolved configurable
  ## value to stdout. Reads from the CURRENT generation's intent
  ## snapshot in CAS (interpretation B: the manifest is the source
  ## of truth for what's live; the on-disk `home.nim` may have been
  ## edited since). If there is no current generation yet, falls
  ## back to the on-disk profile so the command works pre-apply.
  let pkgDotKey = c.key
  let parts = splitPkgDotKey(pkgDotKey)
  if not parts.ok:
    stderr.writeLine("repro home get: invalid form: '" & pkgDotKey &
      "' must be <package>.<configurable>")
    return 2
  try:
    let profilePath = loadProfilePath()
    # Try the current-generation snapshot first (interpretation B).
    # If no generation is active yet (pre-apply), the on-disk profile
    # is the only thing to read from.
    let stateDir = resolveStateDir()
    var prof: Profile
    let snapshot = readActiveIntentSnapshot(stateDir)
    var snapshotProf = none(Profile)
    if snapshot.isSome:
      snapshotProf = profileFromIntentSnapshot(stateDir, profilePath,
        snapshot.get)
    if snapshotProf.isSome:
      prof = snapshotProf.get
    else:
      prof = inspectProfile(profilePath)
    # A helper call in `config:` may assign the key, and only the compiled
    # profile knows what it assigns: answer from the compiled profile, as
    # `list` / `why` do. The compile reads the on-disk profile and its
    # imports, so with a current generation it answers only when the
    # on-disk profile is the one that generation snapshotted; otherwise
    # the recorded activation (interpretation B) cannot be compiled and
    # `get` refuses, naming the calls (Home-Profile-Intent-Layer.md
    # §Constructs the inspector steps over; reprobuild-pm issue
    # 2026-10-18-home-get-refuses-a-profile-for-constructs-unrelated-to-config).
    let helperCalls = configHelperCalls(prof)
    if helperCalls.len > 0:
      if snapshotProf.isSome and
          not snapshotMatchesProfileDir(snapshot.get, profilePath.parentDir):
        refuseConfigHelperCalls(profilePath, prof.path, helperCalls,
          pkgDotKey,
          "the current generation was applied from a profile that differs " &
          "from the one on disk, so it cannot be compiled to resolve them " &
          "(run `repro home apply`, or roll back the edit)")
      let compiled = compileAndAdaptHomeProfile(profilePath, stateDir)
      if compiled.profile == nil:
        stderr.writeLine(formatCompileAdaptFailure("repro home get",
          profilePath, compiled))
        return 1
      prof = compiled.profile
    let res = lookupConfigurableInProfile(prof, parts.pkg, parts.key)
    if not res.found:
      # Distinguish "package not enabled" from "key not declared" so
      # the user sees the spec's structured diagnostic.
      let ctx = currentHostContext()
      let effective = resolveEffectiveConfig(prof, ctx.host, ctx)
      # A helper call in an activity body may enable the package, and the
      # text reader cannot see which; "not enabled" is then not a claim
      # this reader can make, and the key is reported unassigned instead.
      var activityHelpers = false
      for ch in prof.root.children:
        if ch.kind == nkActivity:
          for opaque in opaqueNodes(ch.activityChildren):
            if opaque.opaqueKind == okHelperCall:
              activityHelpers = true
      if parts.pkg notin effective.enabledPackages and not activityHelpers:
        stderr.writeLine("repro home get: package `" & parts.pkg &
          "` is not enabled by any active activity; no value to read.")
        return 1
      stderr.writeLine("repro home get: no value recorded for `" &
        pkgDotKey & "` in the active generation's `config:` section. " &
        "(Set one with `repro home set " & pkgDotKey & " <value>`.)")
      return 1
    echo unquoteValueDisplay(res.value)
    return 0
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EUnstructured as e:
    printUnstructured(e); return 1
  except CatchableError as e:
    stderr.writeLine("repro home get: error: " & e.msg)
    return 1

# ---------------------------------------------------------------------------
# `repro home plan` (M68).
# ---------------------------------------------------------------------------

proc runHomePlan(c: ReproCommandLineHomePlan): int =
  ## `repro home plan` — what the next `repro home apply` would do, without
  ## doing it: the same preview as `repro home apply --plan` (packages,
  ## stow links, generated files, managed blocks, launchers and resources),
  ## through the one procedure (`runHomePreview`). `--json` prints it as
  ## one `reprobuild.home.plan.v2` document.
  let hostFlag = c.host.get("")
  let hostGiven = c.host.isSome
  var identity: HostIdentity
  if not resolveCommandHost("plan", hostFlag, hostGiven, identity):
    return 2
  runHomePreview("repro home plan", c.allowDrift, c.reconcileDrift,
    json = c.json)

# ---------------------------------------------------------------------------
# `repro home adopt <resource>` (M68; Phase A skeleton).
# ---------------------------------------------------------------------------

proc runHomeAdopt(c: ReproCommandLineHomeAdopt): int =
  ## `repro home adopt <resource-address>` — claim an EXISTING
  ## real-world object into management WITHOUT modifying it.
  ##
  ## Adopt is for a resource the profile WANTS (the address is
  ## declared in `home.nim`) but that already exists out-of-band
  ## (the user created it manually, or Reprobuild lost track of
  ## it). The apply pipeline observes the live state and records a
  ## `ResourceBinding` whose `preWriteDigest == postWriteDigest ==
  ## digest(observedState)` — no driver write happens. A subsequent
  ## `repro home apply` then sees the resource as a cache-hit (the
  ## recorded post-write digest matches the live state).
  ##
  ## If the address is NOT declared in the profile's intent, the
  ## pipeline raises `EAdoptUndeclared`. Adopt runs apply inline
  ## (M63 wiring) so the adopted binding lands in a new generation.
  let address = c.address
  # Adopt runs the apply pipeline inline with the named address in
  # `adoptAddresses`; the pipeline validates the address is declared
  # and records its observed bytes as-is.
  return runApplyInline("adopt", amFull, "", @[address])

# ---------------------------------------------------------------------------
# `repro home resource move <old> <new>` (M68; Phase A skeleton).
# ---------------------------------------------------------------------------

proc runHomeResourceMove(c: ReproCommandLineHomeResourceMove): int =
  ## `repro home resource move <old> <new>` — rename a resource
  ## record WITHOUT re-applying. The resource's underlying state
  ## (registry value, file, managed block, ...) is unchanged; only
  ## the resource's IDENTITY in the manifest moves from `<old>` to
  ## `<new>`. This is a metadata operation — no driver apply /
  ## destroy runs. Produces a new generation reflecting the rename.
  let oldAddr = c.oldAddress
  let newAddr = c.newAddress
  try:
    let outcome = runResourceMove(oldAddr, newAddr)
    echo "repro home resource move: renamed " & outcome.oldAddress &
      " -> " & outcome.newAddress & " (generation " &
      shortGenerationId(outcome.fromGenerationIdHex) & " -> " &
      shortGenerationId(outcome.toGenerationIdHex) & ")"
    return 0
  except EUnknownResource as err:
    stderr.writeLine("repro home resource move: " & err.msg)
    return 1
  except EResourceConflict as err:
    stderr.writeLine("repro home resource move: '" & err.address2 &
      "' already exists as a resource (real-world identity '" &
      err.realWorldIdentity & "'); pick a free name.")
    return 1
  except EResourceMove as err:
    stderr.writeLine(err.msg)
    return 1
  except EApplyBusy as err:
    stderr.writeLine("repro home resource move: another apply/rollback " &
      "is in progress (lock " & err.lockPath & " held; waited " &
      $err.waitedSeconds & "s).")
    return 1
  except CatchableError as err:
    stderr.writeLine("repro home resource move: error: " & err.msg)
    return 1

proc runHomeResource(c: ReproCommandLineHomeResource): int =
  case c.command
  of ReproCommandLineHomeResourceCommand.move:
    runHomeResourceMove(c.move)

# ---------------------------------------------------------------------------
# `repro home rollback` (M64).
# ---------------------------------------------------------------------------

proc runHomeRollback(c: ReproCommandLineHomeRollback): int =
  ## `repro home rollback [<generation-id>] [--accept-overwrite]` —
  ## revert the filesystem state to a past generation. Without an
  ## explicit id, rolls back to the immediately previous generation.
  ## Refuses to clobber user-edited managed files unless
  ## `--accept-overwrite` is passed.
  let generationId = c.generation
  let acceptOverwrite = c.acceptOverwrite
  let uninstallFromScoop = c.uninstallFromScoop
  var opts: RollbackOptions
  opts.targetGenerationId = generationId
  opts.acceptOverwrite = acceptOverwrite
  opts.uninstallFromScoop = uninstallFromScoop
  try:
    let outcome = runRollback(opts)
    if outcome.driftedPaths.len > 0:
      for p in outcome.driftedPaths:
        stderr.writeLine("repro home rollback: drift detected at " & p &
          " (clobbered under --accept-overwrite).")
    echo "repro home rollback: rolled back from " &
      outcome.fromGenerationIdHex & " to " & outcome.toGenerationIdHex &
      " (" & $outcome.fileOpsApplied & " file op(s), " &
      $outcome.blockOpsApplied & " block op(s), " &
      $outcome.launcherOpsApplied & " launcher op(s))"
    # GM7: what the target generation does not apply stays in place.
    if outcome.released.len > 0:
      echo "repro home rollback: released " & $outcome.released.len &
        " item(s) of concerns the target generation does not apply " &
        "(left in place, no longer managed):"
      for r in outcome.released:
        echo "  release  " & r
    return 0
  except EUserEditDetected as err:
    stderr.writeLine("repro home rollback: user edit detected at " &
      err.path & " (" & err.recordKind & "): expected " &
      err.expectedDigestHex[0 ..< min(12, err.expectedDigestHex.len)] &
      " but observed " &
      err.observedDigestHex[0 ..< min(12, err.observedDigestHex.len)] &
      ". Pass --accept-overwrite to clobber the user's edit.")
    return 1
  except EUnknownGeneration as err:
    stderr.writeLine("repro home rollback: no generation matching '" &
      err.requestedId & "'. Available: " & err.candidates.join(", "))
    return 1
  except EAmbiguousGeneration as err:
    stderr.writeLine("repro home rollback: prefix '" & err.requestedPrefix &
      "' is ambiguous. Candidates:")
    for m in err.matches:
      stderr.writeLine("  " & m)
    return 1
  except ENoPreviousGeneration as err:
    stderr.writeLine("repro home rollback: " & err.msg)
    return 1
  except ENoActiveGeneration as err:
    stderr.writeLine("repro home rollback: " & err.msg)
    return 1
  except ERollbackContentMissing as err:
    stderr.writeLine("repro home rollback: missing CAS blob " &
      err.digestHex & " for " & err.absoluteOutputPath & ". Refusing " &
      "to restore unknown content.")
    return 1
  except EApplyBusy as err:
    stderr.writeLine("repro home rollback: another apply/rollback is in " &
      "progress (lock " & err.lockPath & " held; waited " &
      $err.waitedSeconds & "s).")
    return 1
  except EHomeRollback as err:
    stderr.writeLine("repro home rollback: " & err.msg)
    return 1
  except CatchableError as err:
    stderr.writeLine("repro home rollback: unexpected error: " & err.msg)
    return 1

# ---------------------------------------------------------------------------
# `repro home gc` (M10 — Realize-Closure-And-Catalog-Expansion).
# ---------------------------------------------------------------------------

proc renderGcCandidate(c: GcCandidate): string =
  ## One-line dry-run row: ``<size>  <package>@<version>  <path>``.
  let label =
    if c.packageName.len > 0: c.packageName & "@" & c.version
    else: c.prefixIdHex[0 ..< min(12, c.prefixIdHex.len)]
  let junctionTag = if c.isJunctionEntry: "  [junction]" else: ""
  "  " & humanBytes(c.sizeBytes).align(12) & "  " & label & "  " &
    c.absolutePath & junctionTag

proc runHomeGcCommand(c: ReproCommandLineHomeGc): int =
  ## `repro home gc` — generation retention plus store GC. Drops the
  ## generations outside the keep window with their `profile` roots,
  ## then lets store GC collect what no root holds (`runHomeGc`); a
  ## prefix any other root holds is never touched. Prints a footprint
  ## summary first, and with --dry-run stops there.
  ##
  ## EXPLICIT operator command only — never auto-runs. Per the M10
  ## spec, the gc never deletes the active generation under any
  ## circumstance: the keep-set always includes the currently-active
  ## generation regardless of the --keep-generations rank.
  var opts = GcOptions(keepGenerations: DefaultKeepGenerations,
    dryRun: c.dryRun, autoConfirm: c.force, storeRoot: c.store)
  if c.keepGenerations.isSome:
    let n = c.keepGenerations.get
    if n < 1:
      stderr.writeLine("repro home gc: --keep-generations must be >= 1 " &
        "(the active generation is ALWAYS preserved); got " & $n)
      return 2
    opts.keepGenerations = n
  try:
    let report = runHomeGc(opts)
    # Header.
    let storeRootEcho =
      if opts.storeRoot.len > 0: opts.storeRoot else: resolveStoreRoot()
    echo "repro home gc: store=" & storeRootEcho
    echo "repro home gc: kept-generations=" &
      $report.keptGenerationIds.len & " keep-N=" & $opts.keepGenerations
    case report.outcome
    of goNoCandidates:
      echo "repro home gc: no generation to drop and no unreferenced " &
        "prefix — store is clean."
      return 0
    of goSkippedDryRun:
      echo "repro home gc: dry-run — would drop " &
        $report.droppedGenerationIds.len & " generation(s)" &
        (if report.droppedGenerationIds.len > 0:
          ": " & report.droppedGenerationIds.join(", ") else: "")
      echo "repro home gc: dry-run — " & $report.candidates.len &
        " prefix(es) no root would hold, " &
        humanBytes(report.candidateBytes) & " reclaimable:"
      for c in report.candidates:
        echo renderGcCandidate(c)
      echo "repro home gc: pass --force to delete (or rerun without " &
        "--dry-run for the y/N prompt)."
      return 0
    of goSkippedCancelled:
      echo "repro home gc: cancelled by operator — nothing removed."
      return 0
    of goDeleted:
      echo "repro home gc: dropped-generations=" &
        $report.droppedGenerationIds.len &
        " collected=" & $report.deletedCount &
        " failed=" & $report.failedCount &
        " reclaimed=" & humanBytes(report.reclaimedBytes)
      if report.failures.len > 0:
        for f in report.failures:
          stderr.writeLine("repro home gc: FAILED to remove " &
            f.absolutePath & ": " & f.error)
        return 1
      return 0
  except EStateDirInvalid as e:
    stderr.writeLine("repro home gc: " & e.msg)
    return 1
  except EApplyBusy as e:
    stderr.writeLine("repro home gc: another apply is in progress (lock " &
      e.lockPath & " held; waited " & $e.waitedSeconds & "s); nothing " &
      "was removed. Retry when it has finished.")
    return 1
  except EPointerCorrupt as e:
    stderr.writeLine("repro home gc: corrupt pointer at " & e.pointerPath &
      " (field: " & e.field & "); refusing to gc against a corrupt " &
      "registry — quarantine the generation directory and retry.")
    return 1
  except EGenerationDirInvalid as e:
    stderr.writeLine("repro home gc: invalid generation directory " &
      e.generationPath & " (" & e.msg & "); refusing to gc against a " &
      "partial registry — clean up the leftover and retry.")
    return 1
  except CatchableError as e:
    stderr.writeLine("repro home gc: error: " & e.msg)
    return 1

# ---------------------------------------------------------------------------
# `repro home migrate-from-env-scripts` (M70).
# ---------------------------------------------------------------------------

proc defaultEnvFilePathFor*(root: string): string =
  ## Default ``--env-file`` path for a workspace rooted at ``root``:
  ## ``<root>/windows/toolchain-versions.env``. Returns ``""`` when
  ## ``root`` is empty: there is no machine-neutral location to fall
  ## back to, so ``runHomeMigrateFromEnvScripts`` refuses and asks for
  ## an explicit ``--env-file`` instead of guessing one.
  if root.len > 0:
    return root / "windows" / "toolchain-versions.env"
  return ""

proc defaultEnvFilePath(): string =
  ## Resolve the default ``--env-file`` path from ``$METACRAFT_ROOT``
  ## (set by the workspace's ``env.ps1``). Tests pass an explicit
  ## ``--env-file`` so they never depend on the env var.
  defaultEnvFilePathFor(getEnv("METACRAFT_ROOT"))

proc printMigrateSummary(summary: MigrationSummary) =
  echo "repro home migrate-from-env-scripts: " &
    $summary.migrated & " migrated, " &
    $summary.deferred & " deferred (TODO), " &
    $summary.missingVersion & " version-missing (TODO), " &
    $summary.unknown & " unknown (TODO), " &
    $summary.alreadyOwned & " already owned, " &
    $summary.ignored & " ignored"

proc runHomeMigrateFromEnvScripts(c: ReproCommandLineHomeMigrateFromEnvScripts): int =
  ## `repro home migrate-from-env-scripts` per M70. Reads
  ## ``toolchain-versions.env`` and writes ``package(<tool>,
  ## "<version>")`` lines into ``home.nim`` for every pin whose tool
  ## maps cleanly onto the M67/M68 catalog. Tools that are in the
  ## catalog but realize-time-deferred (the M69 "deferred-8"), tools
  ## with a version that isn't in the catalog, and unknown env-file
  ## keys are emitted as ``# TODO`` comments so the user can audit +
  ## replace them manually.
  var envFile = c.envFile
  let activity = c.activity
  let dryRun = c.dryRun
  if envFile.len == 0:
    envFile = defaultEnvFilePath()
  if envFile.len == 0:
    stderr.writeLine("repro home migrate-from-env-scripts: " &
      "no --env-file given and METACRAFT_ROOT is unset; " &
      "pass --env-file <path-to-toolchain-versions.env>")
    return 2
  if not fileExists(envFile):
    stderr.writeLine("repro home migrate-from-env-scripts: " &
      "env file not found: " & envFile)
    return 1

  var parsed: EnvFileParseResult
  try:
    parsed = loadEnvFile(envFile)
  except IOError as e:
    stderr.writeLine("repro home migrate-from-env-scripts: " &
      "cannot read " & envFile & ": " & e.msg)
    return 1

  # Resolve the target home.nim. Use loadProfilePath so we land at the
  # XDG / APPDATA default unless the caller passed --profile-dir
  # (handled by the top-level dispatch).
  let profileDir = resolveProfileDir()
  let profilePath = profileDir / "home.nim"
  let profileExists = fileExists(profilePath)

  # Compute owned tools from the existing profile (or empty if absent).
  let owned = mfes.ownedToolsAtPath(profilePath)

  let plan = mfes.planMigration(parsed, activity, owned)
  let summary = mfes.summarize(plan)

  if dryRun:
    echo "# repro home migrate-from-env-scripts --dry-run"
    echo "# env file: " & envFile
    echo "# target home.nim: " & profilePath &
      (if profileExists: " (exists)" else: " (does not exist)")
    echo "# activity: " & activity
    echo "#"
    echo "# proposed lines (in insertion order):"
    if plan.lines.len == 0:
      echo "#   (no pins parsed from env file)"
    for line in plan.lines:
      case line.kind
      of moMigrate:
        echo line.text
      of moDeferred, moMissingVersion, moUnknown:
        echo line.text
      of moAlreadyOwned:
        echo "# SKIP " & line.tool & ": " & line.reason
      of moIgnored:
        echo "# IGNORE " & line.envVar & ": " & line.reason
    echo "#"
    printMigrateSummary(summary)
    return 0

  # Non-dry-run write. Scaffold the profile if it doesn't exist; then
  # delegate each migrate / TODO line to the structural editor's
  # addPackageReference for migrate lines and a direct line insert for
  # TODO comments (the structural editor doesn't represent comments
  # as first-class nodes — we insert them at the end of the activity
  # body alongside the package refs).
  if not profileExists:
    if not dirExists(profileDir):
      try:
        createDir(profileDir)
      except OSError as e:
        stderr.writeLine("repro home migrate-from-env-scripts: " &
          "cannot create profile directory " & profileDir & ": " & e.msg)
        return 1
    let scaffold = "import repro/profile\n\nprofile \"migrated\":\n" &
      "  activity " & activity & ":\n    discard\n"
    # Note: ``activity`` must be a valid Nim identifier (letters,
    # digits, underscore). The default is ``migrated_from_env_scripts``;
    # the CLI rejects names containing ``-`` further down via the
    # structural editor.
    try:
      writeFile(profilePath, scaffold)
    except IOError as e:
      stderr.writeLine("repro home migrate-from-env-scripts: " &
        "cannot scaffold " & profilePath & ": " & e.msg)
      return 1

  var migrated = 0
  var skipped = 0
  for line in plan.lines:
    case line.kind
    of moMigrate:
      try:
        addPackageReference(profilePath, line.tool, activity = activity,
          version = line.version)
        inc migrated
      except CatchableError as e:
        stderr.writeLine("repro home migrate-from-env-scripts: failed to " &
          "write " & line.tool & "@" & line.version & ": " & e.msg)
        return 1
    of moAlreadyOwned, moIgnored:
      inc skipped
    of moDeferred, moMissingVersion, moUnknown:
      # TODO comments: we leave them out of the file by default to keep
      # the structural editor's invariants clean (it doesn't track
      # free-floating comments as first-class nodes). The user sees the
      # full TODO list via the printed summary + the --dry-run output.
      discard

  printMigrateSummary(summary)
  if summary.deferred + summary.missingVersion + summary.unknown > 0:
    echo ""
    echo "Tools that need manual attention (run with --dry-run to see " &
      "the full TODO list):"
    for line in plan.lines:
      case line.kind
      of moDeferred, moMissingVersion, moUnknown:
        echo "  " & line.text.strip()
      else: discard
  return 0

# ---------------------------------------------------------------------------
# Top-level dispatch.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# `repro home export` (evaluated intent as a versioned JSON document).
# ---------------------------------------------------------------------------

proc runHomeExport(c: ReproCommandLineHomeExport): int =
  ## `repro home export` — see its description and `home_export.nim`.
  ## Exit codes: 0 printed / snapshot current; 1 snapshot stale, or the
  ## profile could not be found or compiled; 2 usage error, including an
  ## unreadable or non-JSON `--check` file and an unknown `--target`; 3 the
  ## export cannot describe the `--target` platform.
  let hostFlag = c.host.get("")
  let hostGiven = c.host.isSome
  let format = c.format
  let checkFile = c.check.get("")
  let target = c.target
  if c.check.isSome and checkFile.len == 0:
    stderr.writeLine("repro home export: --check needs a file")
    return 2
  if target.len > 0 and findTargetPlatform(target) < 0:
    stderr.writeLine("repro home export: unknown --target '" & target &
      "' (known: " & targetSystemNames().join(", ") & ")")
    return 2
  if format != "json":
    stderr.writeLine("repro home export: unsupported --format '" & format &
      "' (supported: json)")
    return 2
  if c.nixos.isSome and target.len == 0:
    stderr.writeLine("repro home export: --nixos states a " &
      "fact about the --target host; pass --target")
    return 2
  if target.len > 0 and checkFile.len > 0:
    stderr.writeLine("repro home export: --target and --check do not " &
      "combine (a snapshot is checked as exported, unevaluated)")
    return 2

  # Host identity, resolved by the resolver every `repro home` command
  # shares ($REPRO_HOST, then --host, then the OS hostname). A --host that
  # $REPRO_HOST would silently override is refused instead: an export for
  # the wrong host is a valid-looking document with the wrong activities in
  # it.
  var identity: HostIdentity
  if not resolveCommandHost("export", hostFlag, hostGiven, identity):
    return 2
  let host = identity.name
  let hostSource = identity.source

  var snapshot: JsonNode = nil
  if checkFile.len > 0:
    try:
      snapshot = parseJson(readFile(extendedPath(checkFile)))
    except IOError, OSError:
      stderr.writeLine("repro home export --check: cannot read " & checkFile &
        ": " & getCurrentExceptionMsg())
      return 2
    except JsonParsingError, ValueError:
      stderr.writeLine("repro home export --check: " & checkFile &
        " is not JSON: " & getCurrentExceptionMsg())
      return 2

  var doc: JsonNode
  try:
    let profilePath = loadProfilePath()
    let stateDir = resolveStateDir()
    var opts = defaultProfileCompileOptionsFor(profilePath, stateDir)
    opts.reportObservedInputs = true
    let artifact =
      try:
        compileProfileToRbpi(profilePath, opts)
      except ProfileCompileError as err:
        stderr.writeLine(formatProfileCompileError("repro home export",
          profilePath, err.msg, planCommand = "repro home plan"))
        return 1
    let probe =
      try:
        probeProfilePlatforms(profilePath, opts)
      except ProfileCompileError as err:
        stderr.writeLine("repro home export: the platform probe failed: " &
          err.msg)
        return 1
    let intent = decodeRbpi(artifact.rbpiBytes)
    doc = buildHomeExport(intent, artifact, probe, profilePath, host,
      hostSource, stateDir)
  except ENoProfile as e:
    printNoProfile(e); return 1
  except CatchableError as e:
    stderr.writeLine("repro home export: error: " & e.msg)
    return 1

  if target.len > 0:
    try:
      doc["evaluation"] = evaluateHomeExport(doc, target, host, c.nixos)
    except HomeExportRefused as err:
      stderr.writeLine("repro home export: " & err.msg)
      return 3
    except EFactNotStated as err:
      stderr.writeLine("repro home export: cannot evaluate for " & target &
        ": " & err.msg)
      return 3
    except CatchableError as err:
      stderr.writeLine("repro home export: cannot evaluate for " & target &
        ": " & err.msg)
      return 1
  if snapshot.isNil:
    stdout.write(renderHomeExport(doc))
    return 0
  let differences = diffHomeExports(snapshot, doc)
  for note in provenanceNotes(snapshot, doc):
    stderr.writeLine("repro home export --check: note (not compared): " & note)
  if differences.len == 0:
    echo "repro home export --check: " & checkFile &
      " matches a fresh export for host " & host
    return 0
  stderr.writeLine("repro home export --check: " & checkFile &
    " is stale for host " & host & " (" & $differences.len &
    " difference(s)):")
  for idx, line in differences:
    if idx >= MaxReportedDifferences:
      stderr.writeLine("  ... and " & $(differences.len - idx) & " more")
      break
    stderr.writeLine("  " & line)
  let hostArg =
    if hostSource == hsFlag: " --host " & quoteShell(host) else: ""
  stderr.writeLine("  hint: regenerate it with `repro home export --format " &
    "json" & hostArg & " > " & quoteShell(checkFile) & "`")
  return 1

# ---------------------------------------------------------------------------
# `repro home facts` / `repro home compare` (GM6: host facts and the
# equivalence report; docs/users/content/guides/machines/compare-with-home-manager.md).
# ---------------------------------------------------------------------------

proc runHomeFacts(c: ReproCommandLineHomeFacts): int =
  ## `repro home facts` -- see its description.
  let hostFlag = c.host.get("")
  let hostGiven = c.host.isSome
  var target = c.target
  let output = c.output.get("")
  if target.len > 0 and findTargetPlatform(target) < 0:
    stderr.writeLine("repro home facts: unknown --target '" & target &
      "' (known: " & targetSystemNames().join(", ") & ")")
    return 2
  if c.output.isSome and output.len == 0:
    stderr.writeLine("repro home facts: --output needs a file")
    return 2
  # The host's real home, used only to name the PATH entries that spell it
  # by its absolute path (`homeRelativePathEntry`): the Nix side names them
  # against `home.homeDirectory`, so without it one directory would have two
  # ids. Never read or written -- the plan runs against the private home
  # below.
  var hostHomeDir = ""
  if c.homeDir.isSome:
    hostHomeDir = c.homeDir.get
    if hostHomeDir.len == 0 or not isAbsolute(hostHomeDir):
      stderr.writeLine("repro home facts: --home-dir needs an absolute " &
        "directory; got '" & hostHomeDir & "'")
      return 2
  else:
    hostHomeDir = getHomeDir()
  # Without --target the facts are this machine's, so os-release says
  # whether it is NixOS (unless the flag does); for another target the flag
  # is the only source.
  let nixosFact =
    if c.nixos.isSome: c.nixos
    elif target.len == 0: some(currentHostContext().isNixos)
    else: none(bool)
  if target.len == 0:
    target = compilingPlatformSystem()
    if findTargetPlatform(target) < 0:
      stderr.writeLine("repro home facts: this repro runs on " & target &
        ", which is not a profile target platform; pass --target")
      return 2

  # Host identity, resolved by the resolver every `repro home` command
  # shares (see `repro home export`).
  var identity: HostIdentity
  if not resolveCommandHost("facts", hostFlag, hostGiven, identity):
    return 2
  let host = identity.name

  # The private home and state directory: the facts must not depend on, or
  # touch, the home of the machine running this command.
  let scratch = createTempDir("repro-home-facts-", "")
  defer:
    try: removeDir(scratch) except CatchableError: discard
  let homeDir = scratch / "home"
  let stateDir = scratch / "state"
  let storeRoot = scratch / "store"
  for d in [homeDir, stateDir, storeRoot]:
    createDir(d)

  var doc: JsonNode
  try:
    let profilePath = loadProfilePath()
    let compileOpts = defaultProfileCompileOptionsFor(profilePath, stateDir)
    let artifact =
      try:
        compileProfileToRbpi(profilePath, compileOpts)
      except ProfileCompileError as err:
        stderr.writeLine(formatProfileCompileError("repro home facts",
          profilePath, err.msg, planCommand = "repro home plan"))
        return 1
    let intent = decodeRbpi(artifact.rbpiBytes)
    if target != compilingPlatformSystem():
      # The compile is native; another platform is described only when the
      # platform probe shows the profile declares the same intent there
      # (`repro home export`'s rule, `platformDependence`).
      let probe =
        try:
          probeProfilePlatforms(profilePath, compileOpts)
        except ProfileCompileError as err:
          stderr.writeLine("repro home facts: the platform probe failed: " &
            err.msg)
          return 1
      let dependence = platformDependence(intent, probe.outcomes)
      var status = psUnevaluated
      for (system, s) in dependence.statuses:
        if system == target:
          status = s
      if status != psSame:
        var why = ""
        for (system, d) in dependence.diagnostics:
          if system == target:
            why = d.splitLines()[0]
        stderr.writeLine("repro home facts: cannot describe " & target &
          " from a compile on " & compilingPlatformSystem() & ": the " &
          "platform probe reports the profile `" & $status & "` there" &
          (if why.len > 0: " (" & why & ")" else: "") &
          "; run `repro home facts` on " & target)
        return 3
    let profile =
      try:
        expandedHomeProfile(intent, profilePath)
      except EDataFile as err:
        stderr.writeLine("repro home facts: " & err.msg)
        return 1
    let platform = ProfileTargetPlatforms[findTargetPlatform(target)]
    let opts = ApplyOptions(
      profileDir: profilePath.parentDir,
      profilePath: profilePath,
      host: host,
      targetContext: targetHostContext(platform, host, nixosFact),
      hasTargetContext: true,
      stateDir: stateDir,
      storeRoot: storeRoot,
      homeDir: homeDir,
      preLoadedProfile: profile)
    doc = collectHostFacts(opts, target, hostHomeDir)
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EFactNotStated as e:
    stderr.writeLine("repro home facts: cannot describe the profile for " &
      target & ": " & e.msg)
    return 3
  except CatchableError as e:
    stderr.writeLine("repro home facts: error: " & e.msg)
    return 1
  let rendered = pretty(doc) & "\n"
  if output.len > 0:
    try:
      writeFile(output, rendered)
    except IOError, OSError:
      stderr.writeLine("repro home facts: cannot write " & output & ": " &
        getCurrentExceptionMsg())
      return 1
  else:
    stdout.write(rendered)
  0

proc runHomeCompare(c: ReproCommandLineHomeCompare): int =
  ## `repro home compare` -- see its description and `home_compare.nim`.
  let factsFiles = c.facts
  if c.allow.len > 1:
    stderr.writeLine("repro home compare: --allow given twice")
    return 2
  let allowFile = if c.allow.len > 0: c.allow[0] else: ""
  let format = c.format
  let showSame = c.showSame
  if factsFiles.len != 2:
    stderr.writeLine("repro home compare: give exactly two --facts files " &
      "(one Nix-side, one Reprobuild-side); got " & $factsFiles.len)
    return 2
  if format notin ["text", "json"]:
    stderr.writeLine("repro home compare: unsupported --format '" & format &
      "' (supported: text, json)")
    return 2
  var docs: seq[JsonNode]
  for f in factsFiles:
    try:
      docs.add parseJson(readFile(f))
    except IOError, OSError:
      stderr.writeLine("repro home compare: cannot read " & f & ": " &
        getCurrentExceptionMsg())
      return 2
    except JsonParsingError, ValueError:
      stderr.writeLine("repro home compare: " & f & " is not JSON: " &
        getCurrentExceptionMsg())
      return 2
  var allow: seq[AllowEntry]
  var report: CompareReport
  try:
    if allowFile.len > 0:
      let content =
        try: readFile(allowFile)
        except IOError, OSError:
          stderr.writeLine("repro home compare: cannot read " & allowFile &
            ": " & getCurrentExceptionMsg())
          return 2
      allow = parseAllowlist(content, allowFile)
    report = compareFacts(docs[0], docs[1], factsFiles[0], factsFiles[1],
      allow)
  except ECompareInput as err:
    stderr.writeLine("repro home compare: " & err.msg)
    return 2
  if format == "json":
    stdout.write(pretty(renderCompareJson(report)) & "\n")
  else:
    stdout.write(renderCompareText(report, showSame))
  compareExitCode(report)

proc runHomeCommand*(conf: ReproCommandLineHome): int =
  ## Implements `repro home <subcommand>` per M61, its command line parsed
  ## from repro's description (`repro_cli_support/cli_description`). Always
  ## loads the package catalog from `$REPRO_HOME_PACKAGE_CATALOG` first;
  ## `add --catalog=...` takes precedence when present.
  ##
  ## `--profile-dir` is the namespace's own flag and applies to every
  ## subcommand. `--host` is each subcommand's: the subcommands that act AS
  ## a host (list, why, apply, apply --plan, plan, export, facts) resolve it
  ## through the one shared resolver (`resolveCommandHost` -> `selectHost`),
  ## which refuses a `--host` that `$REPRO_HOST` would override; `enable` /
  ## `disable` take `--host` as the TARGET entry (and remote-apply host),
  ## which may differ from this machine's identity. The rest act on this
  ## machine's identity ($REPRO_HOST, else the OS hostname) through the
  ## same `currentHost()`.
  loadCatalogFromEnv()
  defer: setHostOverride("")
  if conf.profileDir.len > 0:
    setProfileDirOverride(conf.profileDir)
  case conf.command
  of ReproCommandLineHomeCommand.add: runHomeAdd(conf.add)
  of ReproCommandLineHomeCommand.remove: runHomeRemove(conf.remove)
  of ReproCommandLineHomeCommand.enable: runHomeEnable(conf.enable)
  of ReproCommandLineHomeCommand.disable: runHomeDisable(conf.disable)
  of ReproCommandLineHomeCommand.list: runHomeList(conf.list)
  of ReproCommandLineHomeCommand.why: runHomeWhy(conf.why)
  of ReproCommandLineHomeCommand.history: runHomeHistory(conf.history.json)
  of ReproCommandLineHomeCommand.apply: runHomeApply(conf.apply)
  of ReproCommandLineHomeCommand.buildBundle:
    runHomeBuildBundle(conf.buildBundle)
  of ReproCommandLineHomeCommand.receiveBundle:
    runHomeReceiveBundle(conf.receiveBundle)
  of ReproCommandLineHomeCommand.transferBundle:
    runHomeTransferBundle(conf.transferBundle)
  of ReproCommandLineHomeCommand.remoteActivate:
    runHomeRemoteActivate(conf.remoteActivate)
  of ReproCommandLineHomeCommand.plan: runHomePlan(conf.plan)
  of ReproCommandLineHomeCommand.`export`: runHomeExport(conf.`export`)
  of ReproCommandLineHomeCommand.facts: runHomeFacts(conf.facts)
  of ReproCommandLineHomeCommand.compare: runHomeCompare(conf.compare)
  of ReproCommandLineHomeCommand.rollback: runHomeRollback(conf.rollback)
  of ReproCommandLineHomeCommand.gc: runHomeGcCommand(conf.gc)
  of ReproCommandLineHomeCommand.set: runHomeSet(conf.set)
  of ReproCommandLineHomeCommand.get: runHomeGet(conf.get)
  of ReproCommandLineHomeCommand.adopt: runHomeAdopt(conf.adopt)
  of ReproCommandLineHomeCommand.resource: runHomeResource(conf.resource)
  of ReproCommandLineHomeCommand.migrateFromEnvScripts:
    runHomeMigrateFromEnvScripts(conf.migrateFromEnvScripts)

proc runHomeCommand*(args: seq[string]): int =
  ## ``repro home <args>`` in this process, through the generated parser.
  runReproArgs(@["home"] & args, proc (c: ReproCommandLine): int =
    runHomeCommand(c.home))

proc runRemoteActivateCommand*(conf: ReproCommandLineRemoteActivate): int =
  ## ``repro __remote-activate``, the older spelling of ``repro home
  ## __remote-activate``.
  loadCatalogFromEnv()
  defer: setHostOverride("")
  runHomeRemoteActivate(conf)
