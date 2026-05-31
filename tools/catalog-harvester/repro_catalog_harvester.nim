## M66 catalog harvester — CLI entry point.
##
## Subcommands:
##
##   ``harvest``  — clone / refresh one or more Scoop buckets, parse
##                  each ``<app>.json``, translate to the M63
##                  ``VersionedProvisioning`` schema, and write
##                  ``packages/<tool>.nim`` files.
##
##   ``inspect``  — translate a SINGLE manifest and print the result
##                  to stdout without writing a file. Useful for
##                  debugging a sticky translation.
##
##   ``verify``   — re-harvest a checked-in ``packages/<tool>.nim``
##                  and assert byte-identical output. Catches drift
##                  between the catalog and the upstream bucket.
##
## Examples:
##
##   repro_catalog_harvester harvest \
##     --bucket scoopinstaller/main \
##     --app ripgrep --app maven \
##     --out libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/
##
##   repro_catalog_harvester inspect --bucket ./tests/fixtures/bucket-simple \
##     --app hello
##
##   repro_catalog_harvester verify --bucket scoopinstaller/main \
##     --app ripgrep --catalog libs/.../packages/ripgrep.nim
##
## Exit codes: 0 = OK; 2 = bad CLI invocation; 3 = harvest error
## (one or more manifests failed); 4 = verify drift detected.

import std/[os, parseopt, strutils, tables]

import src/manifest_parser
import src/bucket_clone
import src/nim_emit
import src/msys2_source
import repro_dsl_stdlib/packages_schema

const HelpText = """
catalog-harvester — multi-source harvester for the reprobuild M63 catalog.

USAGE
  catalog-harvester <subcommand> [options]

SUBCOMMANDS
  harvest   Harvest one or more packages and emit packages/<tool>.nim files.
            Default source is Scoop bucket cloning; the M6 ``--source
            msys2:<package>`` shape pulls from the MSYS2 pacman repository
            instead.
  inspect   Translate one manifest and print the result (no write).
  verify    Re-harvest a checked-in packages/<tool>.nim and assert
            byte-identical output (drift detector).

SOURCE SELECTION
  --source scoop                       (default) Scoop bucket cloning.
  --source msys2:<package>             (M6) MSYS2 pacman repository.
                                       <package> is either a full pacman
                                       name (mingw-w64-x86_64-ocaml) or
                                       a bare shorthand (ocaml) that the
                                       harvester auto-prefixes per --env.
  --env <mingw64|ucrt64|clang64|       (M6) MSYS2 environment to harvest
        mingw32|msys>                  from. Defaults to mingw64.
  --version <pin>                      (M6) Pin a specific upstream
                                       version (e.g. 5.4.1). Default: the
                                       latest version in the index.

COMMON OPTIONS
  --bucket <spec>           Repeatable. <spec> is one of:
                              * <org>/<repo>      (GitHub shortname)
                              * https://… URL    (git clone URL)
                              * /path/to/local/  (local bucket dir)
                            Scoop source only.
  --app <name>              Repeatable. If omitted, every manifest in
                            the bucket is harvested. For --source
                            msys2:, --app overrides the catalog
                            identifier (defaults to the package name).
  --output-dir <path>       For 'harvest': output directory; defaults
                            to libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/
  --version-history <N>     For 'harvest': walk N historical versions
                            (Scoop source only; default: 1). N > 1
                            unshallows the clone.
  --dry-run                 For 'harvest': print what would be written
                            (file paths + first 10 lines) and exit 0.
  --no-refresh              Skip 'git pull' for cached buckets.
  --bin-default <a>=<b,c>   Synthesize bin_relpath for manifests whose
                            'bin' field is empty by combining their
                            'env_add_path' segments with the supplied
                            relative paths. Repeatable. Required for
                            tools like maven/elixir/ruby whose Scoop
                            manifest exposes binaries via PATH only.
  --app-alias <src>=<dst>   Rename the catalog identifier on emit;
                            the manifest stays addressed by <src> in
                            the bucket, but the output file is
                            <dst>.nim and the seq is <dst>Catalog.
                            Repeatable. Required when Scoop's
                            manifest name contains characters Nim
                            forbids in identifiers (e.g.
                            'haskell-cabal' -> 'cabal').

VERIFY-ONLY OPTIONS
  --catalog <path>          The existing packages/<tool>.nim file.

EXIT CODES
  0 = OK
  2 = bad CLI invocation
  3 = harvest error (one or more packages skipped or invalid)
  4 = verify drift detected

ENVIRONMENT
  XDG_CACHE_HOME / LOCALAPPDATA      Override bucket / msys2 cache root.
  REPRO_M6_INDEX_FIXTURE_DIR         (M6) Override the MSYS2 repository
                                     URL with a local fixture directory
                                     (used by the hermetic test suite).
"""

type
  Subcommand = enum
    scNone, scHarvest, scInspect, scVerify

  HarvestSource = enum
    hsScoop = "scoop"
    hsMsys2 = "msys2"

  CliOptions = object
    sub: Subcommand
    source: HarvestSource          ## M6: harvester source selector
    msys2Packages: seq[string]     ## M6: --source msys2:<package> tails
    msys2Env: Msys2Env             ## M6: --env (default mingw64)
    msys2VersionPin: string        ## M6: --version <pin>
    buckets: seq[string]
    apps: seq[string]
    outputDir: string
    versionHistory: int
    dryRun: bool
    noRefresh: bool
    catalog: string
    binDefaults: Table[string, seq[string]]
      ## M67: per-app bin_relpath synthesis defaults for manifests
      ## whose ``bin`` field is absent / empty. CLI: ``--bin-default
      ## <app>=<relpath1>,<relpath2>``, repeatable. Combined with the
      ## manifest's ``env_add_path`` to produce
      ## ``bin_relpath``. Required when ``validateVersionedProvisioning``
      ## would otherwise reject the entry for missing ``bin_relpath``.
    appAliases: Table[string, string]
      ## M67: rename a manifest's logical tool name on emit. CLI:
      ## ``--app-alias <manifestApp>=<toolName>``, repeatable. Used
      ## when the Scoop bucket carries a manifest under one name
      ## (e.g. ``haskell-cabal``) but the reprobuild catalog wants a
      ## different identifier (``cabal``). Affects the emitted
      ## filename (``cabal.nim``) AND the seq identifier
      ## (``cabalCatalog``). Also enforces a valid Nim identifier —
      ## hyphens, dots, and other non-identifier chars in the source
      ## manifest name would otherwise produce uncompilable output.

proc parseCli(argv: openArray[string]): CliOptions =
  result.sub = scNone
  result.source = hsScoop
  result.msys2Env = meMingw64
  result.outputDir = "libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/"
  result.versionHistory = 1

  # Honor BOTH GNU-style ``--key value`` and Nim-style ``--key:value``
  # / ``--key=value``. Flags that take no value are declared in
  # ``longNoVal`` so the parser knows to leave subsequent positionals
  # alone for them.
  const longNoVal = @["dry-run", "no-refresh", "help"]

  var positionalSeen = false
  var p = initOptParser(@argv,
    longNoVal = longNoVal,
    shortNoVal = {'h'})
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdArgument:
      if not positionalSeen:
        case p.key
        of "harvest": result.sub = scHarvest
        of "inspect": result.sub = scInspect
        of "verify": result.sub = scVerify
        of "help":
          result.sub = scNone
        else:
          stderr.writeLine("error: unknown subcommand '" & p.key & "'")
          quit(2)
        positionalSeen = true
      else:
        stderr.writeLine("error: unexpected positional '" & p.key & "'")
        quit(2)
    of cmdLongOption, cmdShortOption:
      case p.key
      of "bucket": result.buckets.add(p.val)
      of "app", "tool": result.apps.add(p.val)
      of "source":
        # ``--source scoop`` (default) | ``--source msys2:<package>``.
        # Accepts the bare ``msys2`` form too (combine with --app to
        # name the package; useful when the package name carries
        # characters parseopt would split on).
        let lower = p.val.strip().toLowerAscii()
        if lower == "scoop":
          result.source = hsScoop
        elif lower == "msys2":
          result.source = hsMsys2
        elif lower.startsWith("msys2:"):
          result.source = hsMsys2
          let pkg = p.val[6 .. ^1].strip()
          if pkg.len > 0: result.msys2Packages.add(pkg)
        else:
          stderr.writeLine("error: --source must be one of " &
            "scoop, msys2, msys2:<package>; got '" & p.val & "'")
          quit(2)
      of "env":
        case p.val.strip().toLowerAscii()
        of "mingw64": result.msys2Env = meMingw64
        of "ucrt64":  result.msys2Env = meUcrt64
        of "clang64": result.msys2Env = meClang64
        of "mingw32": result.msys2Env = meMingw32
        of "msys":    result.msys2Env = meMsys
        else:
          stderr.writeLine("error: --env must be one of mingw64, " &
            "ucrt64, clang64, mingw32, msys; got '" & p.val & "'")
          quit(2)
      of "version":
        # MSYS2 source: pin a specific upstream version (5.4.1 etc.).
        result.msys2VersionPin = p.val.strip()
      of "output-dir", "out": result.outputDir = p.val
      of "version-history", "with-history":
        try: result.versionHistory = parseInt(p.val)
        except ValueError:
          stderr.writeLine("error: --version-history wants an integer")
          quit(2)
      of "dry-run": result.dryRun = true
      of "no-refresh": result.noRefresh = true
      of "catalog": result.catalog = p.val
      of "app-alias":
        # ``--app-alias <manifestApp>=<toolName>``
        let eq = p.val.find('=')
        if eq <= 0:
          stderr.writeLine("error: --app-alias wants <manifestApp>=<toolName>")
          quit(2)
        let srcName = p.val[0 ..< eq].strip()
        let dstName = p.val[eq + 1 .. ^1].strip()
        if srcName.len == 0 or dstName.len == 0:
          stderr.writeLine("error: --app-alias both sides must be non-empty")
          quit(2)
        # Validate dstName is a usable Nim identifier head — leading
        # underscore is fine, leading digit is not, hyphens are not.
        if dstName[0] notin {'a'..'z', 'A'..'Z', '_'}:
          stderr.writeLine("error: --app-alias target '" & dstName &
            "' must start with a letter or underscore")
          quit(2)
        for ch in dstName:
          if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
            stderr.writeLine("error: --app-alias target '" & dstName &
              "' contains invalid identifier character '" & $ch & "'")
            quit(2)
        result.appAliases[srcName] = dstName
      of "bin-default":
        # ``--bin-default <app>=<relpath1>,<relpath2>``
        let eq = p.val.find('=')
        if eq <= 0:
          stderr.writeLine("error: --bin-default wants <app>=<relpaths>")
          quit(2)
        let appName = p.val[0 ..< eq]
        var relpaths: seq[string] = @[]
        for piece in p.val[eq + 1 .. ^1].split(','):
          let trimmed = piece.strip()
          if trimmed.len > 0: relpaths.add(trimmed)
        if relpaths.len == 0:
          stderr.writeLine("error: --bin-default for '" & appName &
            "' produced an empty relpath list")
          quit(2)
        result.binDefaults[appName] = relpaths
      of "help", "h":
        result.sub = scNone
      else:
        stderr.writeLine("error: unknown option '--" & p.key & "'")
        quit(2)

# ---------------------------------------------------------------------------
# Diagnostics rendering
# ---------------------------------------------------------------------------

proc writeDiagnostics(diagnostics: openArray[Diagnostic]) =
  for d in diagnostics:
    stderr.writeLine($d.kind & " [" & d.app & "]: " & d.detail)

# ---------------------------------------------------------------------------
# Harvest one app (potentially multi-version)
# ---------------------------------------------------------------------------

type
  HarvestedApp = object
    app: string
    catalog: seq[VersionedProvisioning]
    diagnostics: seq[Diagnostic]
    fatal: bool  ## true if we couldn't synthesize ANY version

proc harvestApp(bucket: BucketRef; app: string; versionHistory: int;
                binDefaults: openArray[string] = []): HarvestedApp =
  result.app = app

  let manifestsDir = manifestsDirOf(bucket)
  let manifestPath = manifestsDir / (app & ".json")
  if not fileExists(manifestPath):
    result.diagnostics.add(Diagnostic(
      kind: dkManifestNoUrl, app: app,
      detail: "no manifest file at " & manifestPath))
    result.fatal = true
    return

  # ----- Head manifest -----
  let raw = readFile(manifestPath)
  let parsed = parseScoopManifest(app, raw, binDefaults)
  for d in parsed.diagnostics: result.diagnostics.add(d)
  if parsed.ok:
    result.catalog.add(parsed.entry)
  else:
    # If even the head failed, surface as fatal — the operator wants
    # to see this loudly.
    result.fatal = true

  # ----- Optional history walk -----
  if versionHistory <= 1 or bucket.kind != bkGitRepository:
    return

  # We need the full git log for this file — unshallow if necessary.
  # (Cheap if already full.)
  try:
    unshallow(bucket)
  except BucketError as err:
    result.diagnostics.add(Diagnostic(
      kind: dkUnknownArchitecture, app: app,
      detail: "could not unshallow bucket: " & err.msg))
    return

  let versionCommits = commitVersionsFor(bucket, app)
  var added = result.catalog.len  # 0 or 1 — the head version
  let headVersion = if result.catalog.len > 0: result.catalog[0].version
                    else: ""

  for (sha, version) in versionCommits:
    if added >= versionHistory: break
    if version == headVersion: continue  # already covered
    let histBody = manifestAtCommit(bucket, app, sha)
    if histBody.len == 0: continue
    let histParsed = parseScoopManifest(app, histBody, binDefaults)
    for d in histParsed.diagnostics: result.diagnostics.add(d)
    if histParsed.ok:
      # Skip if we already have this version (shouldn't happen since
      # commitVersionsFor de-dupes, but defense in depth).
      var dup = false
      for existing in result.catalog:
        if existing.version == histParsed.entry.version:
          dup = true; break
      if not dup:
        result.catalog.add(histParsed.entry)
        inc added

# ---------------------------------------------------------------------------
# Catalog ordering
# ---------------------------------------------------------------------------

proc semverTuple(version: string): tuple[parts: seq[int]; rest: string] =
  ## Coarse semver decomposition. Splits the leading numeric dot-
  ## separated run; everything after the first non-numeric segment
  ## stays as a string for lexicographic ordering. Handles
  ## ``21.0.5+11`` and ``0.26-1`` without crashing.
  var parts: seq[int] = @[]
  var i = 0
  while i < version.len:
    var j = i
    while j < version.len and version[j] in {'0'..'9'}: inc j
    if j == i: break
    try: parts.add(parseInt(version[i ..< j]))
    except ValueError: break
    i = j
    if i < version.len and version[i] == '.': inc i else: break
  (parts, version[i .. ^1])

proc compareSemverDesc(a, b: VersionedProvisioning): int =
  ## Newest-first ordering. Pure-numeric semver comparison falls back
  ## to lexicographic on non-numeric remainders.
  let av = semverTuple(a.version)
  let bv = semverTuple(b.version)
  let n = min(av.parts.len, bv.parts.len)
  for k in 0 ..< n:
    if av.parts[k] != bv.parts[k]:
      return cmp(bv.parts[k], av.parts[k])
  if av.parts.len != bv.parts.len:
    return cmp(bv.parts.len, av.parts.len)
  return cmp(bv.rest, av.rest)

proc sortCatalog(items: var seq[VersionedProvisioning]) =
  ## In-place newest-first sort. Stable enough for our purposes —
  ## duplicates are caught upstream by ``validateCatalog``.
  for i in 1 ..< items.len:
    var j = i
    while j > 0 and compareSemverDesc(items[j - 1], items[j]) > 0:
      let tmp = items[j - 1]
      items[j - 1] = items[j]
      items[j] = tmp
      dec j

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

proc cmdHarvestMsys2(opts: CliOptions): int =
  ## M6: harvest one or more packages from an MSYS2 pacman repository.
  ## Each ``--source msys2:<pkg>`` invocation contributes one package
  ## to ``opts.msys2Packages``; a multi-package run reuses the same
  ## ``--env`` selection.
  if opts.msys2Packages.len == 0:
    stderr.writeLine("error: --source msys2:<package> requires at " &
      "least one package name. Pass e.g. " &
      "'--source msys2:ocaml --env mingw64'.")
    return 2
  if opts.outputDir.len == 0:
    stderr.writeLine("error: --output-dir is required")
    return 2
  if not opts.dryRun:
    createDir(opts.outputDir)
  var anyError = false
  for packageHint in opts.msys2Packages:
    # Pick the catalog tool identifier: the operator's --app overrides
    # the default (the bare package name minus the env prefix).
    var toolName = packageHint
    if toolName.startsWith("mingw-w64-"):
      # Strip the longest matching env prefix so e.g.
      # ``mingw-w64-x86_64-ocaml`` -> ``ocaml``.
      let envPrefix = envPackagePrefix(opts.msys2Env)
      if envPrefix.len > 0 and toolName.startsWith(envPrefix):
        toolName = toolName[envPrefix.len .. ^1]
    if opts.apps.len == 1:
      toolName = opts.apps[0]
    elif opts.apps.len > 1:
      stderr.writeLine("error: --source msys2 with multiple --app " &
        "renames is ambiguous; pass exactly one --app or none")
      return 2
    var entry: VersionedProvisioning
    try:
      entry = harvestMsys2Package(opts.msys2Env, packageHint, toolName,
        opts.msys2VersionPin)
    except Msys2HarvestError as err:
      stderr.writeLine("error: MSYS2 harvest of '" & packageHint &
        "' (env=" & $opts.msys2Env & ") failed: " & err.msg)
      anyError = true
      continue
    # Schema validation — surface any issues before writing the file.
    var schemaWarnings: seq[string] = @[]
    let schemaErrors = validateVersionedProvisioningEx(entry, schemaWarnings)
    for w in schemaWarnings:
      stderr.writeLine("WSchema [" & toolName & "]: " & w)
    if schemaErrors.len > 0:
      stderr.writeLine("error: harvested entry for '" & toolName &
        "' failed schema validation:")
      for e in schemaErrors:
        stderr.writeLine("  - " & e)
      anyError = true
      continue
    let bucketSpec = "msys2:" & $opts.msys2Env & "/" & packageHint
    let body = emitCatalogFile(toolName, bucketSpec, @[entry])
    let outPath = opts.outputDir / (toolName & ".nim")
    if opts.dryRun:
      echo "DRY-RUN would write " & outPath & " (version=" &
        entry.version & ")"
      var n = 0
      for ln in body.splitLines:
        if n >= 10: break
        echo "    " & ln
        inc n
    else:
      writeFile(outPath, body)
      echo "harvested " & toolName & " " & entry.version & " -> " & outPath
  if anyError: return 3
  return 0

proc cmdHarvest(opts: CliOptions): int =
  if opts.source == hsMsys2:
    return cmdHarvestMsys2(opts)
  if opts.buckets.len == 0:
    stderr.writeLine("error: --bucket is required for 'harvest'")
    return 2

  if opts.outputDir.len == 0:
    stderr.writeLine("error: --output-dir is required")
    return 2

  if not opts.dryRun:
    createDir(opts.outputDir)

  # Track which apps we've already emitted — first bucket wins for
  # cross-bucket name collisions (the spec's HBucketShadowed).
  var emittedApps: seq[string] = @[]
  var anyError = false

  for bucketSpec in opts.buckets:
    let bucket = try:
      resolveBucket(bucketSpec, refresh = not opts.noRefresh)
    except BucketError as err:
      stderr.writeLine("error: " & err.msg)
      anyError = true
      continue

    var appList = opts.apps
    if appList.len == 0:
      # No --app filter: harvest every manifest in the bucket.
      for tup in manifestFiles(bucket):
        appList.add(tup.app)

    for app in appList:
      if app in emittedApps:
        stderr.writeLine("HBucketShadowed [" & app & "]: already harvested " &
          "from an earlier bucket; ignoring " & bucketSpec)
        continue
      let appBinDefaults =
        if app in opts.binDefaults: opts.binDefaults[app] else: @[]
      let harvested = harvestApp(bucket, app, opts.versionHistory,
        appBinDefaults)
      writeDiagnostics(harvested.diagnostics)
      if harvested.fatal or harvested.catalog.len == 0:
        stderr.writeLine("error: harvest of '" & app & "' from '" &
          bucketSpec & "' produced no usable versions; skipped")
        anyError = true
        continue
      var ordered = harvested.catalog
      sortCatalog(ordered)
      # Apply --app-alias rename to control filename + variable name.
      let toolName =
        if app in opts.appAliases: opts.appAliases[app] else: app
      let body = emitCatalogFile(toolName, bucketSpec, ordered)
      let outPath = opts.outputDir / (toolName & ".nim")
      if opts.dryRun:
        echo "DRY-RUN would write " & outPath & " (" & $ordered.len &
          " version(s))"
        # Print the first few lines to make the dry-run useful.
        var n = 0
        for ln in body.splitLines:
          if n >= 10: break
          echo "    " & ln
          inc n
      else:
        writeFile(outPath, body)
      emittedApps.add(app)

  if anyError: return 3
  return 0

proc cmdInspect(opts: CliOptions): int =
  if opts.buckets.len != 1:
    stderr.writeLine("error: 'inspect' wants exactly one --bucket")
    return 2
  if opts.apps.len != 1:
    stderr.writeLine("error: 'inspect' wants exactly one --app")
    return 2
  let bucket = try:
    resolveBucket(opts.buckets[0], refresh = not opts.noRefresh)
  except BucketError as err:
    stderr.writeLine("error: " & err.msg)
    return 2
  let manifestPath = manifestsDirOf(bucket) / (opts.apps[0] & ".json")
  if not fileExists(manifestPath):
    stderr.writeLine("error: no manifest at " & manifestPath)
    return 2
  let raw = readFile(manifestPath)
  let appBinDefaults =
    if opts.apps[0] in opts.binDefaults: opts.binDefaults[opts.apps[0]]
    else: @[]
  let parsed = parseScoopManifest(opts.apps[0], raw, appBinDefaults)
  writeDiagnostics(parsed.diagnostics)
  if not parsed.ok:
    return 3
  echo serializeAsCode(parsed.entry)
  return 0

proc cmdVerify(opts: CliOptions): int =
  if opts.buckets.len < 1:
    stderr.writeLine("error: 'verify' wants --bucket")
    return 2
  if opts.apps.len != 1:
    stderr.writeLine("error: 'verify' wants exactly one --app")
    return 2
  if opts.catalog.len == 0:
    stderr.writeLine("error: 'verify' wants --catalog <path>")
    return 2
  if not fileExists(opts.catalog):
    stderr.writeLine("error: catalog file not found: " & opts.catalog)
    return 2
  let existing = readFile(opts.catalog)
  # Reuse the harvest pipeline.
  let bucket = try:
    resolveBucket(opts.buckets[0], refresh = not opts.noRefresh)
  except BucketError as err:
    stderr.writeLine("error: " & err.msg)
    return 2
  let appBinDefaults =
    if opts.apps[0] in opts.binDefaults: opts.binDefaults[opts.apps[0]]
    else: @[]
  let harvested = harvestApp(bucket, opts.apps[0], opts.versionHistory,
    appBinDefaults)
  writeDiagnostics(harvested.diagnostics)
  if harvested.fatal or harvested.catalog.len == 0:
    return 3
  var ordered = harvested.catalog
  sortCatalog(ordered)
  # Honor --app-alias so verify against a renamed catalog file
  # (e.g. haskell -> ghc.nim) matches the emitted seq identifier.
  let toolName =
    if opts.apps[0] in opts.appAliases: opts.appAliases[opts.apps[0]]
    else: opts.apps[0]
  let body = emitCatalogFile(toolName, opts.buckets[0], ordered)
  if body == existing:
    echo "verify OK: " & opts.catalog
    return 0
  stderr.writeLine("verify DRIFT: " & opts.catalog & " differs from re-harvest")
  # Best-effort diff: print the byte-length delta and the first
  # differing line.
  stderr.writeLine("  existing size: " & $existing.len)
  stderr.writeLine("  harvested size: " & $body.len)
  let exLines = existing.splitLines
  let hvLines = body.splitLines
  let n = min(exLines.len, hvLines.len)
  for i in 0 ..< n:
    if exLines[i] != hvLines[i]:
      stderr.writeLine("  first diff at line " & $(i + 1) & ":")
      stderr.writeLine("    -existing: " & exLines[i])
      stderr.writeLine("    +harvested: " & hvLines[i])
      break
  return 4

# ---------------------------------------------------------------------------
# main()
# ---------------------------------------------------------------------------

proc main(): int =
  let opts = parseCli(commandLineParams())
  case opts.sub
  of scNone:
    echo HelpText
    return 0
  of scHarvest: return cmdHarvest(opts)
  of scInspect: return cmdInspect(opts)
  of scVerify: return cmdVerify(opts)

when isMainModule:
  quit(main())
