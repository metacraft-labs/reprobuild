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

import repro_home_intent
import repro_home_generations
import repro_home_apply
import repro_home_rollback

type
  PackageCatalogLookup* = proc(package: string): bool {.gcsafe.}

const
  CatalogEnvVar* = "REPRO_HOME_PACKAGE_CATALOG"

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

proc runApplyInline*(commandName: string): int =
  ## Shared apply-pipeline runner used by `repro home apply` and by
  ## the inline path of `add`/`remove`/`enable`/`disable`. Reports
  ## the new generation id on stdout and any diagnostics on stderr.
  try:
    var opts: ApplyOptions
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

proc runHomeAdd(args: openArray[string]): int =
  if args.len == 0:
    stderr.writeLine("usage: repro home add <package> [--activity NAME] " &
      "[--when PRED | --if PRED] [--no-apply] [--catalog=<list>]")
    return 2
  var pkg = ""
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
    elif pkg.len == 0:
      pkg = a
    else:
      stderr.writeLine("repro home add: unexpected positional: " & a)
      return 2
    inc i
  if pkg.len == 0:
    stderr.writeLine("repro home add: missing <package>")
    return 2
  try:
    let profilePath = loadProfilePath()
    if not packageInCatalog(pkg):
      printUnknownPackage(profilePath, pkg)
      return 1
    addPackageReference(profilePath, pkg, activity = activity,
                        predicate = pred.text,
                        predicateKeyword = pred.keyword)
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
    stderr.writeLine("usage: repro home remove <package> [--activity NAME] " &
      "[--when PRED | --if PRED] [--no-apply]")
    return 2
  var pkg = ""
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
    elif pkg.len == 0:
      pkg = a
    else:
      stderr.writeLine("repro home remove: unexpected positional: " & a)
      return 2
    inc i
  if pkg.len == 0:
    stderr.writeLine("repro home remove: missing <package>")
    return 2
  try:
    let profilePath = loadProfilePath()
    # Default semantics (no flags): remove every occurrence across all
    # activities and both predicate keywords.
    if not activityGiven and not pred.given:
      # Walk every activity and remove from both the bare body and every
      # conditional inside it.
      while true:
        let prof = loadProfile(profilePath)
        var removedAny = false
        for actName in activityNames(prof):
          let actOpt = findActivity(prof, actName)
          if actOpt.isNone: continue
          let act = actOpt.get
          # Remove from the activity's bare body.
          for ch in act.activityChildren:
            if ch.kind == nkPackageRef and ch.packageName == pkg:
              removePackageReference(profilePath, pkg, activity = actName)
              removedAny = true
              break
          if removedAny: break
          # Then from conditional blocks.
          for ch in act.activityChildren:
            if ch.kind == nkCondBlock:
              for pkgRef in ch.condChildren:
                if pkgRef.kind == nkPackageRef and
                    pkgRef.packageName == pkg:
                  removePackageReference(profilePath, pkg,
                    activity = actName, predicate = ch.predicateSource)
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
          predicate = pred.text)
      else:
        removePackageReference(profilePath, pkg, activity = targetActivity)
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

proc runHomeApply(args: openArray[string]): int =
  ## Standalone apply: runs the M63 pipeline against the currently
  ## resolved profile, host, state dir, and store. `--no-apply` is
  ## rejected because apply IS the action.
  for a in args:
    if a == "--help" or a == "-h":
      echo "usage: repro home apply"
      echo ""
      echo "Run the home-profile apply pipeline against the current"
      echo "intent (`home.nim`), producing a new generation and"
      echo "rotating the `current` pointer."
      return 0
    if a == "--no-apply":
      stderr.writeLine("repro home apply: --no-apply is meaningless on " &
        "this subcommand (apply IS the action). --no-apply belongs on " &
        "intent-mutating commands (add, remove, enable, disable).")
      return 2
    if a.startsWith("--"):
      stderr.writeLine("repro home apply: unknown flag: " & a)
      return 2
    stderr.writeLine("repro home apply: unexpected positional: " & a)
    return 2
  return runApplyInline("apply")

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
      "list | why | history | apply | rollback} ...")
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
  of "rollback": return runHomeRollback(subArgs)
  else:
    stderr.writeLine("repro home: unknown subcommand: " & sub)
    return 2
