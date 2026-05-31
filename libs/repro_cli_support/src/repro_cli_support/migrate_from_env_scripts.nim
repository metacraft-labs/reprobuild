## M70 — `repro home migrate-from-env-scripts`.
##
## One-shot migration command that reads a Windows-flavoured
## ``toolchain-versions.env`` (the ``VAR=VERSION`` pin file consumed by
## ``D:/metacraft/env.ps1`` + the ``windows/ensure-*.ps1`` modules) and
## synthesizes ``package(<tool>, "<version>")`` lines into the user's
## ``home.nim``. Once migrated, the user can keep ``env.ps1`` only as a
## thin PATH-priming shim — the home profile's apply pipeline owns
## binary lifecycle.
##
## Scope (matches the M70 spec):
##
##   - Reads pin entries from a versions env file (default
##     ``$METACRAFT_ROOT/windows/toolchain-versions.env``; overridable
##     via ``--env-file``).
##   - Maps each ``<VAR>=<version>`` line to its catalog tool name via
##     a small hand-curated table (the M67/M68 catalog uses lowercased
##     ``packages/<tool>.nim`` basenames; ``toolchain-versions.env``
##     uses ALL-CAPS environment variables for historical reasons).
##   - For tools where the catalog lookup succeeds AND the tool is NOT
##     in the M69 "deferred-8" realize-time-gap list, synthesizes a
##     ``package(<tool>, "<version>")`` line into a configurable
##     activity block (default: ``migrated-from-env-scripts``).
##   - For deferred-8 tools, in-catalog tools whose version isn't in
##     the catalog, and unknown vars, emits a ``# TODO`` comment line
##     directly into the activity so the user can audit + replace it
##     manually.
##   - ``--dry-run`` prints the proposed home.nim diff instead of
##     writing.
##
## Out of scope (deliberate):
##
##   - Modifying ``toolchain-versions.env`` itself (the env file
##     remains the source-of-truth for the migration command's input;
##     M70 keeps both paths coexisting for a 6-month grace window).
##   - Parsing the ``ensure-*.ps1`` scripts as code (the script set is
##     stable and small enough that the VAR→tool mapping table is
##     hand-curated; parsing the scripts would be over-engineered for
##     M70's narrow scope).
##   - Auto-running the migration from ``env.ps1`` (migration is
##     opt-in; users run it once when they're ready).
##   - Migrating the M70-deferred-8 tools (swift/gcc/git/meson/
##     python3/composer/erlang/ruby) — they're emitted as TODO
##     comments because their cakBuiltin realize paths still have
##     gaps closed by a future milestone.
##
## Tests: ``libs/repro_cli_support/tests/test_m70_migrate_from_env_scripts.nim``
## drives the public helpers + the full CLI surface end-to-end against
## a synthetic env file.

import std/[options, sets, strutils]

import repro_home_intent
import repro_home_apply/catalog_lookup

# ---------------------------------------------------------------------------
# VAR → tool name mapping.
# ---------------------------------------------------------------------------

const
  EnvVarToToolMap*: array[14, tuple[envVar, tool: string]] = [
    ## The hand-curated mapping from ``toolchain-versions.env`` keys to
    ## M67/M68 catalog tool names. Order is presentation order (used
    ## when the migrate command iterates a parsed env file with
    ## position-insensitive lookups). New env-file keys land here as
    ## the upstream env file grows.
    (envVar: "JUST_VERSION",    tool: "just"),
    (envVar: "GH_VERSION",      tool: "gh"),
    (envVar: "PYTHON_VERSION",  tool: "python3"),
    (envVar: "JDK_VERSION",     tool: "jdk"),
    (envVar: "MAVEN_VERSION",   tool: "maven"),
    (envVar: "GRADLE_VERSION",  tool: "gradle"),
    (envVar: "SWIFT_VERSION",   tool: "swift"),
    (envVar: "ZIG_VERSION",     tool: "zig"),
    (envVar: "CMAKE_VERSION",   tool: "cmake"),
    (envVar: "NINJA_VERSION",   tool: "ninja"),
    (envVar: "NODE_VERSION",    tool: "node"),
    (envVar: "GCC_VERSION",     tool: "gcc"),
    (envVar: "GIT_VERSION",     tool: "git"),
    (envVar: "MESON_VERSION",   tool: "meson"),
  ]

  IgnoredEnvVars*: array[5, string] = [
    ## Env-file keys that are intentionally NOT tools (build qualifiers,
    ## runtime-only deps that don't have a catalog representation, or
    ## graphics stacks owned by the parallel system-profile track per
    ## the M70 spec). These are filtered silently — no TODO comment
    ## clutters the migrated activity for them.
    "JDK_BUILD",            # version qualifier consumed by ensure-jdk.ps1
    "GIT_REPO_VERSION",     # Android's repo tool; out of the home-profile catalog
    "VULKAN_HEADERS_VERSION",  # runtime SDK; system-profile track
    "MESA_VERSION",         # software-renderer; system-profile track
    "MSYS2_AUTOTOOLS_VERSION", # MSYS2 pacman bundle; future system-profile track
  ]

  DeferredTools*: array[8, string] = [
    ## The M69 "deferred-8" — registered in the M67/M68 catalog
    ## (``getCatalog(<tool>)`` returns ``some(...)``) BUT realize-time
    ## via cakBuiltin still has gaps (missing platform asset, custom
    ## post-extract step, etc.). Migrating these as live
    ## ``package(...)`` lines would cause ``repro home apply`` to fail
    ## at realize-time; emit them as TODO comments so the user audits
    ## + replaces them when the next milestone closes the gap.
    "swift",
    "gcc",
    "git",
    "meson",
    "python3",
    "composer",
    "erlang",
    "ruby",
  ]

proc isIgnoredEnvVar*(envVar: string): bool =
  for v in IgnoredEnvVars:
    if v == envVar: return true
  false

proc isDeferredTool*(tool: string): bool =
  for d in DeferredTools:
    if d == tool: return true
  false

proc lookupTool*(envVar: string): Option[string] =
  ## Return the catalog tool name for an env-file key, or ``none`` if
  ## the key is unknown / ignored. Ignored keys (build qualifiers,
  ## system-profile tools) return ``none`` too — callers distinguish
  ## "unknown" vs "ignored" via ``isIgnoredEnvVar``.
  for (k, t) in EnvVarToToolMap:
    if k == envVar:
      return some(t)
  none(string)

# ---------------------------------------------------------------------------
# Env-file parsing.
# ---------------------------------------------------------------------------

type
  EnvFilePin* = object
    ## A single ``<VAR>=<version>`` entry parsed from
    ## ``toolchain-versions.env``. Preserves the original env-file
    ## line number so diagnostics can point at the source line.
    envVar*: string
    version*: string
    lineNo*: int  ## 1-based, for diagnostics

  EnvFileParseResult* = object
    pins*: seq[EnvFilePin]

proc parseEnvFile*(source: string): EnvFileParseResult =
  ## Parse the contents of a ``toolchain-versions.env`` file. Comments
  ## (``# ...``) and blank lines are skipped silently. Each
  ## ``KEY=VALUE`` line becomes one ``EnvFilePin``; whitespace around
  ## ``=`` is trimmed. The parser is permissive: a malformed line
  ## (missing ``=``) is skipped silently — the spec calls for a
  ## best-effort parse with hand-curated VAR→tool mapping, not a
  ## strict env-file validator.
  result.pins = @[]
  var lineNo = 0
  for raw in source.splitLines():
    inc lineNo
    let stripped = raw.strip()
    if stripped.len == 0 or stripped.startsWith("#"):
      continue
    let eq = stripped.find('=')
    if eq <= 0:
      continue
    let key = stripped[0 ..< eq].strip()
    let val = stripped[eq + 1 .. ^1].strip()
    if key.len == 0:
      continue
    result.pins.add(EnvFilePin(envVar: key, version: val, lineNo: lineNo))

proc loadEnvFile*(path: string): EnvFileParseResult =
  ## Read ``path`` and parse it. Raises ``IOError`` if the file is
  ## missing. The caller surfaces a friendly diagnostic.
  parseEnvFile(readFile(path))

# ---------------------------------------------------------------------------
# Migration planning.
# ---------------------------------------------------------------------------

type
  MigrationOutcomeKind* = enum
    moMigrate,    ## Clean migrate: catalog hit, not deferred, version present
    moDeferred,   ## In catalog but in the M69 deferred-8 list — TODO comment
    moMissingVersion, ## In catalog but the version isn't a known slice — TODO comment
    moUnknown,    ## Not in the VAR→tool map AND not ignored — TODO comment
    moIgnored,    ## Explicitly ignored (build qualifier / system-scope) — no line
    moAlreadyOwned ## A ``package(<tool>, ...)`` line already exists — skip

  MigrationLine* = object
    ## One synthesized line in the migrated activity. ``kind`` decides
    ## whether ``text`` is a ``package(...)`` line or a ``# TODO ...``
    ## comment.
    kind*: MigrationOutcomeKind
    envVar*: string
    tool*: string       ## "" for moUnknown / moIgnored
    version*: string
    text*: string       ## the rendered line text (without trailing newline)
    reason*: string     ## human-readable explanation (printed by --dry-run
                        ## and by the summary report)

  MigrationPlan* = object
    activity*: string
    lines*: seq[MigrationLine]

proc renderPackageLine*(tool, version: string;
                       indent: int = 4): string =
  ## Render a single ``package(<tool>, "<version>")`` activity-body
  ## line at the given indentation. Mirrors the structural editor's
  ## emission shape so the migrated lines round-trip cleanly through
  ## ``loadProfile`` after the write.
  result = repeat(' ', indent) & "package(" & tool & ", \"" & version & "\")"

proc renderTodoComment*(envVar, tool, version, reason: string;
                       indent: int = 4): string =
  ## Render a ``# TODO`` comment line explaining why a particular env-
  ## file pin was NOT migrated. The text mentions the env-file key,
  ## the catalog tool (when known), and the version (when known) so
  ## the user can audit + replace it with a concrete
  ## ``package(...)`` line once the realize-time gap is closed.
  var who = envVar
  if tool.len > 0 and version.len > 0:
    who = tool & "@" & version & " (" & envVar & ")"
  elif tool.len > 0:
    who = tool & " (" & envVar & ")"
  elif version.len > 0:
    who = envVar & "=" & version
  result = repeat(' ', indent) & "# TODO migrate " & who & " manually: " & reason

# ---------------------------------------------------------------------------
# Plan synthesis.
# ---------------------------------------------------------------------------

proc catalogVersionAvailable(tool, version: string): bool =
  ## Return true if the catalog for ``tool`` has a slice matching
  ## ``version``. Used to distinguish moMigrate (clean catalog hit
  ## with the requested version) from moMissingVersion (catalog hit
  ## but the version is unknown — the user is on a host with a
  ## newer/older pin than M67/M68 harvested).
  try:
    discard lookupCatalogSlice(tool, version)
    return true
  except EUnknownPackageId:
    return false
  except EVersionNotInCatalog:
    return false
  except CatchableError:
    return false

proc planMigration*(parsed: EnvFileParseResult;
                   activity: string;
                   ownedTools: HashSet[string];
                   indent: int = 4): MigrationPlan =
  ## Build a ``MigrationPlan`` from a parsed env file. ``ownedTools``
  ## lists the tools the destination ``home.nim`` already owns (so
  ## the migrator can skip them instead of producing duplicate
  ## ``package(...)`` lines or overwriting a richer entry).
  result.activity = activity
  result.lines = @[]
  for pin in parsed.pins:
    var line = MigrationLine(
      envVar: pin.envVar, version: pin.version, tool: "")
    if isIgnoredEnvVar(pin.envVar):
      line.kind = moIgnored
      line.reason = "ignored: not a catalog tool (build qualifier / " &
        "system-scope provisioning lives in env.ps1)"
      result.lines.add(line)
      continue
    let toolOpt = lookupTool(pin.envVar)
    if toolOpt.isNone:
      line.kind = moUnknown
      line.reason = "unknown env-file key (no entry in " &
        "EnvVarToToolMap); add a mapping in " &
        "migrate_from_env_scripts.nim if this names a tool"
      line.text = renderTodoComment(pin.envVar, "", pin.version,
        "unknown env-file key " & pin.envVar, indent)
      result.lines.add(line)
      continue
    let tool = toolOpt.get()
    line.tool = tool
    if tool in ownedTools:
      line.kind = moAlreadyOwned
      line.reason = "home.nim already owns this tool — skipped to " &
        "avoid clobbering the existing pin"
      result.lines.add(line)
      continue
    if isDeferredTool(tool):
      line.kind = moDeferred
      line.reason = "M70 deferred-8: catalog entry exists but " &
        "cakBuiltin realize-time has a gap (will be fixed by a " &
        "future milestone)"
      line.text = renderTodoComment(pin.envVar, tool, pin.version,
        "deferred until cakBuiltin realize-time supports " & tool, indent)
      result.lines.add(line)
      continue
    if not catalogVersionAvailable(tool, pin.version):
      line.kind = moMissingVersion
      line.reason = "version '" & pin.version & "' is not in the " &
        "M67/M68 catalog for " & tool & " — pin a catalog version " &
        "or extend packages/" & tool & ".nim"
      line.text = renderTodoComment(pin.envVar, tool, pin.version,
        "version " & pin.version & " not in catalog", indent)
      result.lines.add(line)
      continue
    line.kind = moMigrate
    line.reason = "clean catalog hit (" & tool & "@" & pin.version & ")"
    line.text = renderPackageLine(tool, pin.version, indent)
    result.lines.add(line)

# ---------------------------------------------------------------------------
# Plan summary printer.
# ---------------------------------------------------------------------------

type
  MigrationSummary* = object
    migrated*: int
    deferred*: int
    missingVersion*: int
    unknown*: int
    ignored*: int
    alreadyOwned*: int

proc summarize*(plan: MigrationPlan): MigrationSummary =
  for line in plan.lines:
    case line.kind
    of moMigrate:        inc result.migrated
    of moDeferred:       inc result.deferred
    of moMissingVersion: inc result.missingVersion
    of moUnknown:        inc result.unknown
    of moIgnored:        inc result.ignored
    of moAlreadyOwned:   inc result.alreadyOwned

# ---------------------------------------------------------------------------
# Owned-tool detection from a parsed Profile (intent layer).
# ---------------------------------------------------------------------------

proc collectPackageRefs(blk: IntentNode; acc: var HashSet[string]) =
  case blk.kind
  of nkPackageRef:
    acc.incl(blk.packageName)
  of nkActivity:
    for ch in blk.activityChildren:
      collectPackageRefs(ch, acc)
  of nkCondBlock:
    for ch in blk.condChildren:
      collectPackageRefs(ch, acc)
  else:
    discard

proc ownedToolsInProfile*(profile: Profile): HashSet[string] =
  ## Walk every activity in ``profile`` and collect the set of tool
  ## names referenced via the ``package(<tool>...)`` form. Used both
  ## by ``planMigration`` (to skip duplicates) and by the
  ## ``home_profile_owned_tools`` PowerShell helper (which calls into
  ## a sibling binary or shell-parses ``home.nim`` directly — the
  ## intent-layer parse is the source-of-truth here).
  result = initHashSet[string]()
  for ch in profile.root.children:
    collectPackageRefs(ch, result)

proc ownedToolsAtPath*(profilePath: string): HashSet[string] =
  ## Convenience wrapper around ``loadProfile``. Returns an empty set
  ## if the profile file does not exist or is unparseable — the M70
  ## helpers prefer to silently skip detection in that case (the user
  ## can still run the migration without an existing home.nim).
  try:
    let prof = loadProfile(profilePath)
    return ownedToolsInProfile(prof)
  except CatchableError:
    return initHashSet[string]()
