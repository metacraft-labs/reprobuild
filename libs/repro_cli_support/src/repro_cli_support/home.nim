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
##   - `--now` on `enable`/`disable` is now the default behaviour (no
##     extra effect); combining it with `--host <name>` is rejected
##     because remote apply is deferred to M71.
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

import std/[options, os, sets, strutils, tables, times]
from repro_core/paths import extendedPath

import repro_home_intent
import repro_home_generations
import repro_home_apply
import repro_home_apply/catalog_lookup
import repro_home_resources
import repro_home_rollback
import repro_local_store
import repro_profile_intent
import repro_profile_compile
import ./migrate_from_env_scripts as mfes

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

proc parseFlagValue(args: openArray[string]; i: var int;
                    flag: string): string =
  ## Accept either `--flag VALUE` or `--flag=VALUE`. `i` is advanced
  ## past the value.
  let cur = args[i]
  if cur == flag:
    if i + 1 >= args.len:
      raise newException(ValueError, "missing value for " & flag)
    inc i
    return args[i]
  if cur.startsWith(flag & "="):
    return cur[flag.len + 1 .. ^1]
  raise newException(ValueError, "internal: parseFlagValue called for " & flag)

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
                                     stateDir: string):
    ProfileCompileOptions =
  result = ProfileCompileOptions(
    stateDir: stateDir,
    publicCliPath: getAppFilename(),
    repoRoot: getEnv(RepoRootEnvVar),
    workDir: profileRoot.parentDir,
    verbose: false,
    forceRebuild: false)

type
  CompileAdaptOutcome* = object
    profile*: Profile           ## nil when the compile failed
    compileError*: string
    cacheHit*: bool             ## informational

proc compileAndAdaptHomeProfile*(profilePath: string;
                                 stateDir: string): CompileAdaptOutcome =
  ## Run the Phase C build-engine edge against `profilePath`, decode
  ## the RBPI artifact, and adapt it to the `Profile` shape the apply
  ## pipeline consumes.
  ##
  ## On success: `result.profile` is non-nil; the caller threads it
  ## through `ApplyOptions.preLoadedProfile`.
  ##
  ## On compile failure: `result.profile` is nil and
  ## `result.compileError` carries the diagnostic. Apply-path callers
  ## propagate as a hard error via `formatProfileCompileError`.
  result = CompileAdaptOutcome()
  let opts = defaultProfileCompileOptionsFor(profilePath, stateDir)
  try:
    let artifact = compileProfileToRbpi(profilePath, opts)
    let intent = decodeRbpi(artifact.rbpiBytes)
    result.profile = profileIntentToHomeProfile(intent, profilePath)
  except ProfileCompileError as err:
    result.compileError = err.msg
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
    "  hint: see reprobuild-specs/Profile-Migration-Patterns.md for " &
      "the Phase A migration recipe.\n" &
    "  hint: run `" & plan & "` to see whether the issue is profile " &
      "syntax vs. an apply-side problem."

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
                     adoptAddresses: seq[string] = @[]): int =
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
    # M83 Phase F3: the compile-then-adapt path is the ONLY apply path.
    # A profile compilation failure is a HARD ERROR — the legacy text
    # parser no longer auto-fills the gap.
    let profilePath =
      if opts.profilePath.len > 0: opts.profilePath
      else: resolveProfilePath()
    let stateDir = resolveStateDir()
    let outcomeCompile = compileAndAdaptHomeProfile(profilePath, stateDir)
    if outcomeCompile.profile == nil:
      stderr.writeLine(formatProfileCompileError(
        "repro home " & commandName, profilePath,
        outcomeCompile.compileError,
        planCommand = "repro home plan"))
      return 1
    opts.preLoadedProfile = outcomeCompile.profile
    let outcome = runApply(opts)
    for r in outcome.abortedRecovered:
      stderr.writeLine(renderRecovered(r))
    for d in outcome.diagnostics:
      stderr.writeLine(renderStowDiagnostic(d))
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

proc runHomeAdd(args: openArray[string]): int =
  if args.len == 0:
    stderr.writeLine("usage: repro home add <package>[@<version>|@latest] " &
      "[--activity NAME] [--when PRED | --if PRED] [--no-apply] " &
      "[--catalog=<list>]")
    stderr.writeLine("  examples:")
    stderr.writeLine("    repro home add git              # bare reference")
    stderr.writeLine("    repro home add jdk@21.0.5       # pin to a concrete version")
    stderr.writeLine("    repro home add jdk@latest       # resolve to the highest-SemVer")
    stderr.writeLine("                                    #   slice at edit time and write")
    stderr.writeLine("                                    #   the concrete pinned literal")
    return 2
  var pkgSpec = ""
  var activity = "default"
  var pred = emptyPredicate()
  var noApply = false
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--activity" or a.startsWith("--activity="):
      activity = parseFlagValue(args, i, "--activity")
    elif a == "--when" or a.startsWith("--when="):
      pred.text = parseFlagValue(args, i, "--when")
      pred.keyword = ckWhen
      pred.given = true
    elif a == "--if" or a.startsWith("--if="):
      pred.text = parseFlagValue(args, i, "--if")
      pred.keyword = ckIf
      pred.given = true
    elif a == "--no-apply":
      noApply = true
    elif a == "--catalog" or a.startsWith("--catalog="):
      loadCatalogFromFlag(parseFlagValue(args, i, "--catalog"))
    elif a.startsWith("--"):
      stderr.writeLine("repro home add: unknown flag: " & a)
      return 2
    elif pkgSpec.len == 0:
      pkgSpec = a
    else:
      stderr.writeLine("repro home add: unexpected positional: " & a)
      return 2
    inc i
  if pkgSpec.len == 0:
    stderr.writeLine("repro home add: missing <package>")
    return 2
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
    let latest = latestCatalogVersion(pkg)
    if not latest.found:
      stderr.writeLine("repro home add: cannot resolve `" & pkg &
        "@latest`: no built-in catalog registered for '" & pkg & "'")
      stderr.writeLine("  hint: registered tools: " &
        registeredToolNames().join(", "))
      return 1
    version = latest.version
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

proc runHomeRemove(args: openArray[string]): int =
  if args.len == 0:
    stderr.writeLine("usage: repro home remove <package>[@<version>] " &
      "[--activity NAME] [--when PRED | --if PRED] [--no-apply]")
    stderr.writeLine("  examples:")
    stderr.writeLine("    repro home remove git              # strip every git reference")
    stderr.writeLine("    repro home remove jdk@21.0.5       # strip ONLY the pinned line")
    stderr.writeLine("                                       #   (a bare `package(jdk)` is kept)")
    return 2
  var pkgSpec = ""
  var activitySpec = ""
  var activityGiven = false
  var pred = emptyPredicate()
  var noApply = false
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--activity" or a.startsWith("--activity="):
      activitySpec = parseFlagValue(args, i, "--activity")
      activityGiven = true
    elif a == "--when" or a.startsWith("--when="):
      pred.text = parseFlagValue(args, i, "--when")
      pred.keyword = ckWhen
      pred.given = true
    elif a == "--if" or a.startsWith("--if="):
      pred.text = parseFlagValue(args, i, "--if")
      pred.keyword = ckIf
      pred.given = true
    elif a == "--no-apply":
      noApply = true
    elif a.startsWith("--"):
      stderr.writeLine("repro home remove: unknown flag: " & a)
      return 2
    elif pkgSpec.len == 0:
      pkgSpec = a
    else:
      stderr.writeLine("repro home remove: unexpected positional: " & a)
      return 2
    inc i
  if pkgSpec.len == 0:
    stderr.writeLine("repro home remove: missing <package>")
    return 2
  let split = splitToolAtVersion(pkgSpec)
  let pkg = split.tool
  let version = split.version
  if pkg.len == 0:
    stderr.writeLine("repro home remove: missing <package> name in '" &
      pkgSpec & "'")
    return 2
  try:
    let profilePath = loadProfilePath()
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
        let prof = loadProfile(profilePath)
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
                  break
              if removedAny: break
          if removedAny: break
        if not removedAny:
          break
    else:
      # Scoped removal: --activity and/or --when/--if applied.
      let targetActivity =
        if activityGiven: activitySpec else: "default"
      if pred.given:
        removePackageReference(profilePath, pkg, activity = targetActivity,
          predicate = pred.text, version = version)
      else:
        removePackageReference(profilePath, pkg, activity = targetActivity,
          version = version)
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

proc currentHostActivities(prof: Profile; host: string): seq[string] =
  ## Existing activity list for `host` in `hosts:`; empty seq if the
  ## host has no entry yet.
  let hostsOpt = findHostsBlock(prof)
  if hostsOpt.isNone:
    return @[]
  let hosts = hostsOpt.get
  for entry in hosts.hostsEntries:
    if entry.hostName == host:
      return entry.hostActivities
  @[]

proc parseEnableDisableFlags(name: string; args: openArray[string]):
    tuple[activity, host: string; now, noApply, hostGiven, ok: bool;
          exitCode: int] =
  result.now = false
  result.noApply = false
  result.hostGiven = false
  result.ok = false
  result.exitCode = 2
  var positional = ""
  var hostOverride = ""
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--host" or a.startsWith("--host="):
      hostOverride = parseFlagValue(args, i, "--host")
      result.hostGiven = true
    elif a == "--now":
      result.now = true
    elif a == "--no-apply":
      result.noApply = true
    elif a.startsWith("--"):
      stderr.writeLine("repro home " & name & ": unknown flag: " & a)
      return
    elif positional.len == 0:
      positional = a
    else:
      stderr.writeLine("repro home " & name & ": unexpected positional: " & a)
      return
    inc i
  if positional.len == 0:
    stderr.writeLine("usage: repro home " & name &
      " <activity> [--host NAME] [--now] [--no-apply]")
    return
  result.activity = positional
  result.host = if hostOverride.len > 0: hostOverride else: currentHost()
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

proc runHomeEnable(args: openArray[string]): int =
  let parsed = parseEnableDisableFlags("enable", args)
  if not parsed.ok:
    return parsed.exitCode
  if refuseDefaultGuard("enable", parsed.activity):
    return 1
  # M63: `--now` + `--host <name>` requests remote apply. Remote apply
  # is deferred to M71; reject the combination with a clear pointer.
  if parsed.hostGiven and parsed.now and parsed.host != currentHost():
    stderr.writeLine("repro home enable: --now combined with --host '" &
      parsed.host & "' requests remote apply, which is deferred to M71. " &
      "Run the command on '" & parsed.host & "' directly, or omit --host " &
      "to apply locally.")
    return 1
  try:
    let profilePath = loadProfilePath()
    let prof = loadProfile(profilePath)
    var acts = currentHostActivities(prof, parsed.host)
    if parsed.activity notin acts:
      acts.add parsed.activity
    setHostActivities(profilePath, parsed.host, acts)
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EUnstructured as e:
    printUnstructured(e); return 1
  except CatchableError as e:
    stderr.writeLine("repro home enable: error: " & e.msg)
    return 1
  if parsed.noApply:
    return 0
  # M63: apply runs by default after a successful intent edit.
  return runApplyInline("enable")

proc runHomeDisable(args: openArray[string]): int =
  let parsed = parseEnableDisableFlags("disable", args)
  if not parsed.ok:
    return parsed.exitCode
  if refuseDefaultGuard("disable", parsed.activity):
    return 1
  if parsed.hostGiven and parsed.now and parsed.host != currentHost():
    stderr.writeLine("repro home disable: --now combined with --host '" &
      parsed.host & "' requests remote apply, which is deferred to M71. " &
      "Run the command on '" & parsed.host & "' directly, or omit --host " &
      "to apply locally.")
    return 1
  try:
    let profilePath = loadProfilePath()
    let prof = loadProfile(profilePath)
    var acts = currentHostActivities(prof, parsed.host)
    var newActs: seq[string]
    for a in acts:
      if a != parsed.activity:
        newActs.add a
    setHostActivities(profilePath, parsed.host, newActs)
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EUnstructured as e:
    printUnstructured(e); return 1
  except CatchableError as e:
    stderr.writeLine("repro home disable: error: " & e.msg)
    return 1
  if parsed.noApply:
    return 0
  return runApplyInline("disable")

# ---------------------------------------------------------------------------
# `repro home list`.
# ---------------------------------------------------------------------------

type
  PackageOrigin = object
    activity: string
    predicate: string     ## "" if directly in the activity body
    keyword: CondKeyword

proc collectPackageOrigins(prof: Profile;
                          host: string): OrderedTable[string, seq[PackageOrigin]] =
  ## Walk every activity (regardless of host enablement) and gather
  ## every package reference with provenance. The CLI's `list` and
  ## `why` commands consume this view.
  result = initOrderedTable[string, seq[PackageOrigin]]()
  for ch in prof.root.children:
    if ch.kind != nkActivity: continue
    let actName = ch.activityName
    for body in ch.activityChildren:
      case body.kind
      of nkPackageRef:
        let origin = PackageOrigin(activity: actName, predicate: "",
          keyword: ckWhen)
        if body.packageName notin result:
          result[body.packageName] = @[]
        result[body.packageName].add origin
      of nkCondBlock:
        for pkgRef in body.condChildren:
          if pkgRef.kind != nkPackageRef: continue
          let origin = PackageOrigin(activity: actName,
            predicate: body.predicateSource, keyword: body.keyword)
          if pkgRef.packageName notin result:
            result[pkgRef.packageName] = @[]
          result[pkgRef.packageName].add origin
      else: discard

proc enabledActivities(prof: Profile; host: string): HashSet[string] =
  result = initHashSet[string]()
  result.incl "default"
  let hostsOpt = findHostsBlock(prof)
  if hostsOpt.isNone:
    return
  for entry in hostsOpt.get.hostsEntries:
    if entry.hostName == host:
      for a in entry.hostActivities:
        result.incl a

proc runHomeList(args: openArray[string]): int =
  var hostOverride = ""
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--host" or a.startsWith("--host="):
      hostOverride = parseFlagValue(args, i, "--host")
    elif a.startsWith("--"):
      stderr.writeLine("repro home list: unknown flag: " & a)
      return 2
    else:
      stderr.writeLine("repro home list: unexpected positional: " & a)
      return 2
    inc i
  try:
    let profilePath = loadProfilePath()
    let prof = loadProfile(profilePath)
    let host = if hostOverride.len > 0: hostOverride else: currentHost()
    let origins = collectPackageOrigins(prof, host)
    let active = enabledActivities(prof, host)
    echo "repro home list: profile=" & profilePath & " host=" & host
    for pkg, sources in origins:
      var anyActive = false
      for s in sources:
        if s.activity in active:
          anyActive = true; break
      let prefix = if anyActive: "  enabled  " else: "  inactive "
      for s in sources:
        let predStr =
          if s.predicate.len == 0: ""
          else:
            let kw = if s.keyword == ckWhen: "when " else: "if "
            "  " & kw & s.predicate
        echo prefix & pkg & "  activity=" & s.activity & predStr
    return 0
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EUnstructured as e:
    printUnstructured(e); return 1
  except CatchableError as e:
    stderr.writeLine("repro home list: error: " & e.msg)
    return 1

# ---------------------------------------------------------------------------
# `repro home why <package>`.
# ---------------------------------------------------------------------------

proc runHomeWhy(args: openArray[string]): int =
  if args.len == 0:
    stderr.writeLine("usage: repro home why <package> [--host NAME]")
    return 2
  var pkg = ""
  var hostOverride = ""
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--host" or a.startsWith("--host="):
      hostOverride = parseFlagValue(args, i, "--host")
    elif a.startsWith("--"):
      stderr.writeLine("repro home why: unknown flag: " & a)
      return 2
    elif pkg.len == 0:
      pkg = a
    else:
      stderr.writeLine("repro home why: unexpected positional: " & a)
      return 2
    inc i
  if pkg.len == 0:
    stderr.writeLine("repro home why: missing <package>")
    return 2
  try:
    let profilePath = loadProfilePath()
    let prof = loadProfile(profilePath)
    let host = if hostOverride.len > 0: hostOverride else: currentHost()
    let origins = collectPackageOrigins(prof, host)
    let active = enabledActivities(prof, host)
    if pkg notin origins:
      echo "repro home why: package `" & pkg &
        "` is NOT declared in any activity of profile " & profilePath
      return 0
    var hitActive = 0
    for s in origins[pkg]:
      let activityActive = s.activity in active
      let predStr =
        if s.predicate.len == 0: ""
        else:
          let kw = if s.keyword == ckWhen: "when " else: "if "
          " under " & kw & s.predicate
      let activityState =
        if activityActive: "ENABLED on host `" & host & "`"
        else: "NOT enabled on host `" & host &
          "` (not in hosts: entry, not `default`)"
      echo "repro home why: package `" & pkg & "` <- activity `" &
        s.activity & "`" & predStr & " [" & activityState & "]"
      if activityActive: inc hitActive
    if hitActive == 0:
      echo "repro home why: `" & pkg & "` is declared but NOT active on `" &
        host & "` — none of its source activities is in the host's " &
        "activity list."
    return 0
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EUnstructured as e:
    printUnstructured(e); return 1
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

proc runHomeHistory(args: openArray[string]): int =
  ## Walks `<state-dir>/generations/` and prints one line per
  ## generation in chronological order (oldest -> newest). No history
  ## file is consulted; the only on-disk source of truth is the set
  ## of pointer envelopes the directory enumeration finds.
  for a in args:
    if a == "--help" or a == "-h":
      echo "usage: repro home history"
      echo ""
      echo "List home-profile generations in chronological order."
      echo "Reads `$REPRO_HOME_STATE_DIR` (or the OS default) and"
      echo "walks `generations/` directly; no separate history file"
      echo "is consulted."
      return 0
    stderr.writeLine("repro home history: unexpected argument: " & a)
    return 2
  try:
    let stateDir = resolveStateDir()
    let records = enumerateGenerations(stateDir)
    if records.len == 0:
      echo "repro home history: no generations yet at " & stateDir
      return 0
    echo "repro home history: state-dir=" & stateDir
    for rec in records:
      let marker = if rec.isActive: "  [active]" else: "          "
      echo "  " & shortGenerationId(rec.generationId) & "  " &
        formatTimestamp(rec.activationTimestamp) & "  host=" &
        rec.envelope.hostIdentity & marker
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

proc runHomeApplyPlan(allowDrift, reconcileDrift: bool): int =
  ## M72 Deliverable 2: `repro home apply --plan` — a non-mutating
  ## preview of the FULL apply (packages, stow, generated files,
  ## managed blocks, launchers, resources). Runs the planning half of
  ## the pipeline through `runApplyPlan`, which executes NO mutating
  ## step (no realize, no stage, no rotate, no commit, no `scoop
  ## install`). Exit 0 on a clean / no-op plan; non-zero when drift is
  ## detected unless `--allow-drift` was passed.
  try:
    var opts: ApplyOptions
    opts.reconcileStowDrift = reconcileDrift
    # M83 Phase F3: same hard-error compile path as the real apply.
    let profilePath =
      if opts.profilePath.len > 0: opts.profilePath
      else: resolveProfilePath()
    let stateDir = resolveStateDir()
    let outcomeCompile = compileAndAdaptHomeProfile(profilePath, stateDir)
    if outcomeCompile.profile == nil:
      stderr.writeLine(formatProfileCompileError(
        "repro home apply --plan", profilePath,
        outcomeCompile.compileError,
        planCommand = "repro home plan"))
      return 1
    opts.preLoadedProfile = outcomeCompile.profile
    let preview = runApplyPlan(opts)
    stdout.write(renderPlanPreview(preview))
    if preview.driftCount > 0 and not allowDrift and not reconcileDrift:
      stderr.writeLine("repro home apply --plan: " & $preview.driftCount &
        " drift item(s) detected. Pass --allow-drift to exit 0 anyway, " &
        "or --reconcile-drift to plan the reconciling apply.")
      return 1
    return 0
  except EApplyIntentLoad as err:
    stderr.writeLine("repro home apply --plan: step 1 (load intent) " &
      "failed: " & err.msg)
    return 1
  except EHomeApply as err:
    stderr.writeLine("repro home apply --plan: planning failed at step " &
      $err.step & " (" & err.stepName & "): " & err.msg)
    return 1
  except CatchableError as err:
    stderr.writeLine("repro home apply --plan: planning failed with " &
      "unexpected error: " & err.msg)
    return 1

proc runHomeApply(args: openArray[string]): int =
  ## Standalone apply: runs the M63 pipeline against the currently
  ## resolved profile, host, state dir, and store. `--no-apply` is
  ## rejected because apply IS the action.
  ##
  ## M72: `--plan` runs a non-mutating preview instead of the real
  ## apply. `--reconcile-drift` / `--accept-overwrite` let the real
  ## apply replace a drifted stow target (per the home-scope drift
  ## contract). `--allow-drift` makes `--plan` exit 0 despite drift.
  var planMode = false
  var allowDrift = false
  var reconcileDrift = false
  for a in args:
    if a == "--help" or a == "-h":
      echo "usage: repro home apply [--plan] [--allow-drift] " &
        "[--reconcile-drift | --accept-overwrite]"
      echo ""
      echo "Run the home-profile apply pipeline against the current"
      echo "intent (`home.nim`), producing a new generation and"
      echo "rotating the `current` pointer."
      echo ""
      echo "  --plan             Non-mutating preview of the full apply"
      echo "                     (packages, stow, generated files,"
      echo "                     managed blocks, launchers, resources)."
      echo "                     Mutates nothing; runs no `scoop install`."
      echo "  --allow-drift      With --plan: exit 0 even when drift is"
      echo "                     detected."
      echo "  --reconcile-drift  Replace a drifted stow target / resource"
      echo "  --accept-overwrite (alias of --reconcile-drift) instead of"
      echo "                     failing closed; records the prior"
      echo "                     content so rollback can restore it."
      return 0
    if a == "--no-apply":
      stderr.writeLine("repro home apply: --no-apply is meaningless on " &
        "this subcommand (apply IS the action). --no-apply belongs on " &
        "intent-mutating commands (add, remove, enable, disable).")
      return 2
    if a == "--plan":
      planMode = true
    elif a == "--allow-drift":
      allowDrift = true
    elif a == "--reconcile-drift" or a == "--accept-overwrite":
      reconcileDrift = true
    elif a.startsWith("--"):
      stderr.writeLine("repro home apply: unknown flag: " & a)
      return 2
    else:
      stderr.writeLine("repro home apply: unexpected positional: " & a)
      return 2
  if planMode:
    return runHomeApplyPlan(allowDrift, reconcileDrift)
  # A real apply with --reconcile-drift threads the policy through the
  # apply pipeline so a drifted stow target can be replaced.
  if reconcileDrift:
    putEnv("REPRO_HOME_APPLY_RECONCILE_DRIFT", "1")
  return runApplyInline("apply")

# ---------------------------------------------------------------------------
# `repro home set` / `repro home get` (M65).
# ---------------------------------------------------------------------------

proc currentHostContext(): HostContext =
  ## Construct a `HostContext` for the running interpreter so the
  ## intent layer's `resolveEffectiveConfig` can evaluate predicates
  ## the same way the apply pipeline will. M65's pre-validation is
  ## the only call site; predicate evaluation in `set`/`get` cannot
  ## diverge from apply or the diagnostic would be misleading.
  result.host = currentHost()
  when defined(windows):
    result.platform = "windows"
  elif defined(macosx):
    result.platform = "macos"
  elif defined(linux):
    result.platform = "linux"
  else:
    result.platform = "unknown"
  when defined(amd64) or defined(x86_64):
    result.arch = "x86_64"
  elif defined(arm64) or defined(aarch64):
    result.arch = "arm64"
  else:
    result.arch = "unknown"

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

proc runHomeSet(args: openArray[string]): int =
  ## `repro home set <pkg>.<key> <value> [--no-apply]` — write the
  ## given configurable into the profile's `config:` section through
  ## the M60 structural editor, then run the M63 apply pipeline
  ## inline with the M58 incremental refinalize fast path
  ## (`applyMode = amSet`). Pre-validates that the package is enabled
  ## by some active activity AND that the key is declared by the
  ## package's configurable schema before touching `home.nim`; both
  ## diagnostics surface BEFORE the edit so a rejected `set` leaves
  ## the profile byte-identical.
  var pkgDotKey = ""
  var value = ""
  var noApply = false
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--no-apply":
      noApply = true
    elif a == "--help" or a == "-h":
      echo "usage: repro home set <pkg>.<key> <value> [--no-apply]"
      echo ""
      echo "Update a managed configurable in the profile's `config:`"
      echo "section. Runs apply inline by default; --no-apply skips"
      echo "the activation step. The package must be enabled by an"
      echo "active activity and the key must be declared by the"
      echo "package's configurable schema; the edit is committed only"
      echo "AFTER both pre-validations succeed."
      return 0
    elif a.startsWith("--"):
      stderr.writeLine("repro home set: unknown flag: " & a)
      return 2
    elif pkgDotKey.len == 0:
      pkgDotKey = a
    elif value.len == 0:
      value = a
    else:
      stderr.writeLine("repro home set: unexpected positional: " & a)
      return 2
    inc i
  if pkgDotKey.len == 0 or value.len == 0:
    stderr.writeLine("usage: repro home set <pkg>.<key> <value> [--no-apply]")
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
    let ctx = currentHostContext()
    let effective = resolveEffectiveConfig(prof, ctx.host, ctx)
    if parts.pkg notin effective.enabledPackages:
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
    setConfigurable(profilePath, pkgDotKey, value, nil)
  except ENoProfile as e:
    printNoProfile(e); return 1
  except EUnknownPredicate as e:
    printUnknownPredicate(e); return 1
  except EUnstructured as e:
    printUnstructured(e); return 1
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
  let cfgOpt = findConfigBlock(prof)
  if cfgOpt.isNone:
    return (false, "")
  for pkgNode in cfgOpt.get.configPackages:
    if pkgNode.configPackageName != pkg:
      continue
    for entry in pkgNode.configEntries:
      if entry.configKey == key:
        return (true, entry.configValueSource)
  (false, "")

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

proc profileFromIntentSnapshot(stateDir: string; profilePath: string):
    Option[Profile] =
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
  ## configurable" semantics.
  let activeIdHex = readCurrentGenerationId(stateDir)
  if activeIdHex.len == 0:
    return none(Profile)
  let pointerFile = pointerPath(stateDir, activeIdHex)
  if not fileExists(extendedPath(pointerFile)):
    return none(Profile)
  try:
    let env = readPointerFile(pointerFile)
    var snapshotKey: PrefixIdBytes
    for i in 0 ..< 32:
      snapshotKey[i] = env.intentSnapshotDigest[i]
    let storeRoot = resolveStoreRoot()
    var store = openStore(storeRoot)
    defer:
      try: store.close() except CatchableError: discard
    let snapshotBytes = readCasBlob(store, snapshotKey)
    let snapshot = decodeSnapshotBytes(snapshotBytes)
    let anchor = extractFilename(profilePath)
    for entry in snapshot.files:
      if entry.path == anchor or entry.path.endsWith("/" & anchor):
        var content = newString(entry.content.len)
        for i, b in entry.content:
          content[i] = char(b)
        # Re-parse the snapshotted source via a temp file so we
        # reuse the editor's `loadProfile`. The temp lives inside
        # the state dir to keep test isolation tidy.
        let tmpDir = stateDir / "get-tmp"
        createDir(extendedPath(tmpDir))
        let tmpPath = tmpDir / anchor
        writeFile(extendedPath(tmpPath), content)
        try:
          let prof = loadProfile(tmpPath)
          return some(prof)
        finally:
          try: removeFile(extendedPath(tmpPath)) except OSError: discard
    return none(Profile)
  except CatchableError:
    return none(Profile)

proc runHomeGet(args: openArray[string]): int =
  ## `repro home get <pkg>.<key>` — print the resolved configurable
  ## value to stdout. Reads from the CURRENT generation's intent
  ## snapshot in CAS (interpretation B: the manifest is the source
  ## of truth for what's live; the on-disk `home.nim` may have been
  ## edited since). If there is no current generation yet, falls
  ## back to the on-disk profile so the command works pre-apply.
  var pkgDotKey = ""
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--help" or a == "-h":
      echo "usage: repro home get <pkg>.<key>"
      echo ""
      echo "Print the resolved value of a managed configurable to"
      echo "stdout. Reads from the CURRENT generation's recorded"
      echo "activation (the intent snapshot in CAS), so rollback"
      echo "naturally restores the prior value without rewriting"
      echo "`home.nim`."
      return 0
    elif a.startsWith("--"):
      stderr.writeLine("repro home get: unknown flag: " & a)
      return 2
    elif pkgDotKey.len == 0:
      pkgDotKey = a
    else:
      stderr.writeLine("repro home get: unexpected positional: " & a)
      return 2
    inc i
  if pkgDotKey.len == 0:
    stderr.writeLine("usage: repro home get <pkg>.<key>")
    return 2
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
    let snapshotProf = profileFromIntentSnapshot(stateDir, profilePath)
    if snapshotProf.isSome:
      prof = snapshotProf.get
    else:
      prof = loadProfile(profilePath)
    let res = lookupConfigurableInProfile(prof, parts.pkg, parts.key)
    if not res.found:
      # Distinguish "package not enabled" from "key not declared" so
      # the user sees the spec's structured diagnostic.
      let ctx = currentHostContext()
      let effective = resolveEffectiveConfig(prof, ctx.host, ctx)
      if parts.pkg notin effective.enabledPackages:
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

proc runHomePlan(args: openArray[string]): int =
  ## `repro home plan [--allow-drift]` — non-mutating preview of
  ## what the next apply would do. Walks the same DesiredSet the
  ## apply pipeline composes: M78 makes that the profile's
  ## `resources:` block (the production source) with
  ## `REPRO_TEST_RESOURCES` merged over it as a test-only override.
  ## Observes the live state and prints one line per resource. Exits
  ## non-zero when drift is detected unless `--allow-drift` was passed.
  var allowDrift = false
  var reconcileFlag = false
  for a in args:
    if a == "--help" or a == "-h":
      echo "usage: repro home plan [--allow-drift] [--reconcile-drift]"
      echo ""
      echo "Show what `repro home apply` would do without making"
      echo "any changes. Lists per-resource create / update /"
      echo "destroy / no-op decisions plus any drift detected."
      echo "Exits non-zero on drift unless --allow-drift."
      return 0
    elif a == "--allow-drift":
      allowDrift = true
    elif a == "--reconcile-drift":
      reconcileFlag = true
    elif a.startsWith("--"):
      stderr.writeLine("repro home plan: unknown flag: " & a)
      return 2
    else:
      stderr.writeLine("repro home plan: unexpected positional: " & a)
      return 2
  try:
    let homeDir = getHomeDir()
    # M78: the desired set is the profile's `resources:` block, with
    # `REPRO_TEST_RESOURCES` merged over it as a test-only override.
    let profilePath = loadProfilePath()
    let stateDir = resolveStateDir()
    # M83 Phase F3: the compile-then-adapt path is the ONLY path. A
    # profile compilation failure is a HARD ERROR — the legacy text
    # parser is no longer consulted as an apply-path fallback.
    let outcomeCompile = compileAndAdaptHomeProfile(profilePath, stateDir)
    if outcomeCompile.profile == nil:
      stderr.writeLine(formatProfileCompileError(
        "repro home plan", profilePath,
        outcomeCompile.compileError,
        planCommand = "repro home plan"))
      return 1
    let prof = outcomeCompile.profile
    let desired = composeDesiredResources(prof, homeDir, currentHost())
    # Load recorded bindings from the active generation's manifest.
    var recorded = initOrderedTable[string, RecordedBinding]()
    let activeId = readCurrentGenerationId(stateDir)
    if activeId.len > 0:
      let pointerFile = pointerPath(stateDir, activeId)
      if fileExists(extendedPath(pointerFile)):
        try:
          let env = readPointerFile(pointerFile)
          var manifestKey: PrefixIdBytes
          for i in 0 ..< 32:
            manifestKey[i] = env.activationManifestDigest[i]
          var store = openStore(resolveStoreRoot())
          defer:
            try: store.close() except CatchableError: discard
          let manifestBytes = readCasBlob(store, manifestKey)
          let manifest = decodeManifestBytes(manifestBytes)
          for rb in manifest.resourceBindings:
            if rb.resourceKind.len == 0: continue
            recorded[rb.resourceAddress] = toRecorded(rb)
        except CatchableError:
          discard
    let policy =
      if reconcileFlag: rpReconcileDrift
      else: rpFailClosed
    # M68 Phase B: `preventDestroy` enforcement is active in the
    # planner too — `repro home plan` previews exactly what apply
    # would do, so a `preventDestroy` resource scheduled for
    # destroy surfaces here as `EPreventDestroy` rather than as a
    # silent `destroy` line.
    let opts = DecisionOptions(reconcile: policy,
      enforcePreventDestroy: true)
    let report = composePlan(desired, recorded, opts)
    stdout.write(renderPlan(report))
    if report.driftCount > 0 and not allowDrift and not reconcileFlag:
      return 1
    return 0
  except EPreventDestroy as err:
    stderr.writeLine("repro home plan: " & err.msg)
    return 1
  except CatchableError as err:
    stderr.writeLine("repro home plan: error: " & err.msg)
    return 1

# ---------------------------------------------------------------------------
# `repro home adopt <resource>` (M68; Phase A skeleton).
# ---------------------------------------------------------------------------

proc runHomeAdopt(args: openArray[string]): int =
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
  if args.len == 0:
    stderr.writeLine("usage: repro home adopt <resource-address>")
    return 2
  var address = ""
  for a in args:
    if a == "--help" or a == "-h":
      echo "usage: repro home adopt <resource-address>"
      echo ""
      echo "Claim an existing real-world resource into management"
      echo "without modifying it. The resource must be declared in"
      echo "home.nim; adopt records the live observed state so the"
      echo "next apply treats it as a cache-hit. Runs apply inline."
      return 0
    elif a.startsWith("--"):
      stderr.writeLine("repro home adopt: unknown flag: " & a)
      return 2
    elif address.len == 0:
      address = a
    else:
      stderr.writeLine("repro home adopt: unexpected positional: " & a)
      return 2
  if address.len == 0:
    stderr.writeLine("repro home adopt: missing <resource-address>")
    return 2
  # Adopt runs the apply pipeline inline with the named address in
  # `adoptAddresses`; the pipeline validates the address is declared
  # and records its observed bytes as-is.
  return runApplyInline("adopt", amFull, "", @[address])

# ---------------------------------------------------------------------------
# `repro home resource move <old> <new>` (M68; Phase A skeleton).
# ---------------------------------------------------------------------------

proc runHomeResourceMove(args: openArray[string]): int =
  ## `repro home resource move <old> <new>` — rename a resource
  ## record WITHOUT re-applying. The resource's underlying state
  ## (registry value, file, managed block, ...) is unchanged; only
  ## the resource's IDENTITY in the manifest moves from `<old>` to
  ## `<new>`. This is a metadata operation — no driver apply /
  ## destroy runs. Produces a new generation reflecting the rename.
  var positional: seq[string]
  for a in args:
    if a == "--help" or a == "-h":
      echo "usage: repro home resource move <old-address> <new-address>"
      echo ""
      echo "Rename a resource record without re-applying. Carries the"
      echo "existing binding forward under the new id instead of"
      echo "destroy-old + create-new. Metadata-only: no driver runs."
      return 0
    elif a.startsWith("--"):
      stderr.writeLine("repro home resource move: unknown flag: " & a)
      return 2
    else:
      positional.add a
  if positional.len < 2:
    stderr.writeLine("usage: repro home resource move <old-address> " &
      "<new-address>")
    return 2
  if positional.len > 2:
    stderr.writeLine("repro home resource move: unexpected positional: " &
      positional[2])
    return 2
  let oldAddr = positional[0]
  let newAddr = positional[1]
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

proc runHomeResource(args: openArray[string]): int =
  if args.len == 0:
    stderr.writeLine("usage: repro home resource {move} ...")
    return 2
  case args[0]
  of "move":
    return runHomeResourceMove(args[1 .. ^1])
  else:
    stderr.writeLine("repro home resource: unknown subcommand: " & args[0])
    return 2

# ---------------------------------------------------------------------------
# `repro home rollback` (M64).
# ---------------------------------------------------------------------------

proc runHomeRollback(args: openArray[string]): int =
  ## `repro home rollback [<generation-id>] [--accept-overwrite]` —
  ## revert the filesystem state to a past generation. Without an
  ## explicit id, rolls back to the immediately previous generation.
  ## Refuses to clobber user-edited managed files unless
  ## `--accept-overwrite` is passed.
  var generationId = ""
  var acceptOverwrite = false
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--accept-overwrite":
      acceptOverwrite = true
    elif a == "--help" or a == "-h":
      echo "usage: repro home rollback [<generation-id>] [--accept-overwrite]"
      echo ""
      echo "Revert filesystem state to a past generation. Without an"
      echo "explicit id, rolls back to the immediately previous"
      echo "generation by activation timestamp. Refuses to clobber"
      echo "user-edited managed files unless --accept-overwrite."
      return 0
    elif a.startsWith("--"):
      stderr.writeLine("repro home rollback: unknown flag: " & a)
      return 2
    elif generationId.len == 0:
      generationId = a
    else:
      stderr.writeLine("repro home rollback: unexpected positional: " & a)
      return 2
    inc i

  var opts: RollbackOptions
  opts.targetGenerationId = generationId
  opts.acceptOverwrite = acceptOverwrite
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
# `repro home migrate-from-env-scripts` (M70).
# ---------------------------------------------------------------------------

proc defaultEnvFilePath(): string =
  ## Resolve the default ``--env-file`` path from $METACRAFT_ROOT (set
  ## by env.ps1) or fall back to the spec's canonical location
  ## ``D:/metacraft/windows/toolchain-versions.env``. Tests pass an
  ## explicit ``--env-file`` so they never depend on the env var.
  let root = getEnv("METACRAFT_ROOT")
  if root.len > 0:
    return root / "windows" / "toolchain-versions.env"
  when defined(windows):
    return "D:/metacraft/windows/toolchain-versions.env"
  else:
    return ""

proc renderMigrateUsage(): string =
  result = ""
  result.add "usage: repro home migrate-from-env-scripts [--env-file <path>] \n"
  result.add "                                           [--activity <name>] \n"
  result.add "                                           [--dry-run]\n"
  result.add "\n"
  result.add "Read a Windows toolchain-versions.env file and synthesize\n"
  result.add "package(<tool>, \"<version>\") lines into your home.nim.\n"
  result.add "\n"
  result.add "Options:\n"
  result.add "  --env-file <path>   Path to a toolchain-versions.env-shaped\n"
  result.add "                      file. Default: " & defaultEnvFilePath() & "\n"
  result.add "  --activity <name>   Activity block to receive the synthesized\n"
  result.add "                      lines. Must be a Nim identifier (letters,\n"
  result.add "                      digits, underscore). Default:\n"
  result.add "                      migrated_from_env_scripts\n"
  result.add "  --dry-run           Print the proposed home.nim diff without\n"
  result.add "                      writing anything.\n"
  result.add "\n"
  result.add "Behavior:\n"
  result.add "  - Clean migrates: catalog hit + version present in M67/M68 +\n"
  result.add "    NOT in the M70 deferred-8 list (swift/gcc/git/meson/\n"
  result.add "    python3/composer/erlang/ruby). Written as\n"
  result.add "    package(<tool>, \"<version>\") lines.\n"
  result.add "  - TODO comments: in-catalog tools whose realize-time is\n"
  result.add "    deferred, in-catalog tools missing the requested version,\n"
  result.add "    or unknown env-file keys.\n"
  result.add "  - Idempotent: a tool already pinned in home.nim is skipped.\n"
  result.add "  - Refuses to overwrite existing package(<tool>, ...) lines.\n"

proc printMigrateSummary(summary: MigrationSummary) =
  echo "repro home migrate-from-env-scripts: " &
    $summary.migrated & " migrated, " &
    $summary.deferred & " deferred (TODO), " &
    $summary.missingVersion & " version-missing (TODO), " &
    $summary.unknown & " unknown (TODO), " &
    $summary.alreadyOwned & " already owned, " &
    $summary.ignored & " ignored"

proc runHomeMigrateFromEnvScripts(args: openArray[string]): int =
  ## `repro home migrate-from-env-scripts` per M70. Reads
  ## ``toolchain-versions.env`` and writes ``package(<tool>,
  ## "<version>")`` lines into ``home.nim`` for every pin whose tool
  ## maps cleanly onto the M67/M68 catalog. Tools that are in the
  ## catalog but realize-time-deferred (the M69 "deferred-8"), tools
  ## with a version that isn't in the catalog, and unknown env-file
  ## keys are emitted as ``# TODO`` comments so the user can audit +
  ## replace them manually.
  var envFile = ""
  var activity = "migrated_from_env_scripts"
  var dryRun = false
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--help" or a == "-h":
      stdout.write renderMigrateUsage()
      return 0
    elif a == "--env-file" or a.startsWith("--env-file="):
      envFile = parseFlagValue(args, i, "--env-file")
    elif a == "--activity" or a.startsWith("--activity="):
      activity = parseFlagValue(args, i, "--activity")
    elif a == "--dry-run":
      dryRun = true
    elif a.startsWith("--"):
      stderr.writeLine("repro home migrate-from-env-scripts: unknown flag: " & a)
      return 2
    else:
      stderr.writeLine("repro home migrate-from-env-scripts: " &
        "unexpected positional: " & a)
      return 2
    inc i

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

proc runHomeCommand*(args: seq[string]): int =
  ## Implements `repro home <subcommand>` per M61. Always loads the
  ## package catalog from `$REPRO_HOME_PACKAGE_CATALOG` first; the
  ## `--catalog=...` flag (handled inside `add`) takes precedence
  ## when present.
  loadCatalogFromEnv()
  # Extract top-level home flags that apply to every subcommand. The
  # spec defines `--profile-dir` and `--host` as global overrides; we
  # intercept them here and apply via the host_identity seam before
  # dispatching to the subcommand.
  var subArgs: seq[string]
  var i = 0
  var sub = ""
  # First positional is the subcommand; everything else passes through
  # to the subcommand handler. We do NOT intercept `--profile-dir` /
  # `--host` here because users may pass them after the subcommand —
  # subcommands recognize `--host` locally where it makes sense (list,
  # why, enable, disable). `--profile-dir` is handled globally.
  while i < args.len:
    let a = args[i]
    if a == "--profile-dir" or a.startsWith("--profile-dir="):
      setProfileDirOverride(parseFlagValue(args, i, "--profile-dir"))
    elif sub.len == 0 and not a.startsWith("--"):
      sub = a
    else:
      subArgs.add a
    inc i
  if sub.len == 0:
    stderr.writeLine("usage: repro home {add | remove | enable | disable | " &
      "list | why | history | apply | plan | rollback | set | get | " &
      "adopt | resource | migrate-from-env-scripts} ...")
    return 2
  case sub
  of "add": return runHomeAdd(subArgs)
  of "remove": return runHomeRemove(subArgs)
  of "enable": return runHomeEnable(subArgs)
  of "disable": return runHomeDisable(subArgs)
  of "list": return runHomeList(subArgs)
  of "why": return runHomeWhy(subArgs)
  of "history": return runHomeHistory(subArgs)
  of "apply": return runHomeApply(subArgs)
  of "plan": return runHomePlan(subArgs)
  of "rollback": return runHomeRollback(subArgs)
  of "set": return runHomeSet(subArgs)
  of "get": return runHomeGet(subArgs)
  of "adopt": return runHomeAdopt(subArgs)
  of "resource": return runHomeResource(subArgs)
  of "migrate-from-env-scripts":
    return runHomeMigrateFromEnvScripts(subArgs)
  else:
    stderr.writeLine("repro home: unknown subcommand: " & sub)
    return 2
