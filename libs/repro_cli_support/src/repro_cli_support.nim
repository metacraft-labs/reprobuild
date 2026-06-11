import std/[algorithm, hashes, json, options, os, osproc, sequtils, sets, streams,
    strutils, tables, terminal, times]
import repro_core
import repro_build_engine
import repro_cmake_trycompile
import repro_dev_env_activation
import repro_depfile
import repro_dev_env_artifacts
import repro_dev_env_engine
import repro_interface_artifacts
import repro_monitor_depfile/fs_snoop
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider_protocol
import repro_runquota
import repro_hash
# M4: unified Workspace-VCS evidence record + derived JSON view.
# ``writeBuildReport`` embeds the JSON view under the new
# ``workspaceVcs`` top-level array; the SSZ codec lives in the same
# module and stays the persistence path of record. The module physically
# resides at ``libs/repro_workspace_vcs/src/evidence.nim`` and is
# reachable here via ``config.nims``'s ``libs/repro_workspace_vcs/src``
# path entry.
import evidence as workspaceVcsEvidence
# M9: `repro workspace init` drives the M6 / M7 resolver and the M8
# composer through M2's `bakWorkspaceVcs` clone executor. The three
# imports below are sufficient: ``repro_workspace_manifests`` re-exports
# the typed records (``ResolvedProject`` / ``ResolvedRepo``), the
# resolver entry points, the composer entry points, and the structured
# ``WorkspaceManifestParseError``; ``git_tool`` / ``git_actions`` provide
# the M1 / M2 surfaces this subcommand needs (``ensureGitToolResolvable``,
# ``installGitVcsExecutor``, ``gitCloneAction`` plus the observation-only
# ``headShaQuery`` / ``queryGitState`` pair used for the divergence check).
import repro_workspace_manifests
import git_tool
import git_actions
import repro_tool_profiles
import repro_local_store
import repro_store_daemon
import repro_daemon_core
import repro_launch_plan
import repro_hcr_agent
import repro_hcr_linkgraph
import repro_elevation
import repro_cli_support/watch
import repro_cli_support/dev_session
import repro_cli_support/dev_env_shell_export
import repro_cli_support/dev_env_rollback_manifest
import repro_cli_support/dev_env_shell_hook_templates
import repro_cli_support/home
import repro_cli_support/infra
import repro_cli_support/mode1_loader
from repro_cli_support/partition as repro_partition import
  ShardBuildAction, ShardTestEdge, ShardPlanRequest, ShardPlan,
  PartitionPlanReadError,
  planTestShards, writePartitionPlanJson, readPartitionPlanJson
from runquota_partition/types import
  NodeId, value, nodeId, SharedInputPolicy, sipIndependent, sipShared,
  PartitionAssignment, PartitionPlan, DefaultRefinementPasses, `==`, hash
import repro_profile_compile
import repro_home_resources/drivers/managed_block
# Peer-Cache M2: parse the `--peer-cache=lan://CIDR[:port]` form into a
# concrete configuration and start the peer-cache services so the
# partition planner has a multicast-discovered registry to lean on.
import repro_peer_cache
# Spec-Implementation M2e — ``repro lock explain`` consumes the
# explainer surface to render structured chosen / unsat justifications.
import repro_solver

export home.runHomeCommand, home.setPackageCatalogLookup,
       home.PackageCatalogLookup, home.CatalogEnvVar,
       home.ConfigurableSchemaEnvVar
export infra.runInfraCommand, infra.runSystemCommand

proc wantsVersion*(args: openArray[string]): bool =
  args.len == 1 and args[0] in ["--version", "-V"]

proc wantsHelp*(args: openArray[string]): bool =
  ## True when the user explicitly asked for help via a top-level flag
  ## or the `help` subcommand. Distinct from "unknown / missing command"
  ## — an explicit help request prints to stdout and exits 0
  ## (POSIX-shell-pipeable convention), while a missing or unknown
  ## command keeps the older stderr / exit-2 path.
  args.len > 0 and args[0] in ["help", "--help", "-h"]

proc renderVersion*(programName: string): string =
  programName & " " & versionString()

proc renderUsage*(programName: string): string =
  if programName == "repro":
    programName & " " & versionString() & "\nusage: " & programName &
      " --version\n       " & programName &
      " capabilities [--format=json|text]\n       " & programName &
      " build [target[#name] [target...]] --daemon=auto|require|off --tool-provisioning=path|nix|tarball|scoop [--work-root=PATH] [--action-cache-root=PATH] [--progress=quiet|line|bar-line|lines|lines-bar|dots] [--progress-bars=overlay|split] [--diagnostics=PATH] [--benchmark=PATH] [--stats[=text|none]] [--report=full|none] [--log=actions|summary|quiet] [-v|-vv] [--prepare-only] [--dry-run] [--force-rebuild] [--no-runquota] [--list-targets [--json] [--package=NAME]]\n       " &
          programName &
      " graph [target[#name]] [--view=actions|neighborhood|inputs|dependents|blast-radius|critical-path|partition-candidates] [--focus=ACTION] [--path=PATH] [--run=last|ID] [--kind=dylib] [--format=text|json|dot] [--tool-provisioning=path|nix|tarball|scoop] [--work-root=PATH] [--action-cache-root=PATH]\n       " &
          programName &
      " why <package-or-action> [target[#name]] [--action=ACTION] [--format=text|json] [--tool-provisioning=path|nix|tarball|scoop] [--work-root=PATH] [--action-cache-root=PATH]\n       " &
          programName &
      " exec [selector] [--activity=name] [--dev-env-stats=PATH] -- <command> [args...]\n       " &
          programName &
      " shell [selector] [--activity=name] [--print-env=posix|fish|powershell|json] [--dev-env-stats=PATH]\n       " &
          programName &
      " dev-env export bash|zsh|fish|nushell|pwsh [--project-root=PATH] [--activity=name] [--develop-overrides=PATH] [--allow-stale] [--pre-activation-env=PATH]\n       " &
          programName &
      " dev-env deactivate <rollback-manifest> [--shell=bash|zsh|fish|nushell|pwsh]\n       " &
          programName &
      " shell hook bash|zsh|fish|nushell|pwsh [--repro-bin=PATH]\n       " &
          programName &
      " up [selector] [--activity=name] [--foreground] [--http=HOST:PORT]\n       " &
          programName &
      " down [selector] [--activity=name] [--force]\n       " &
          programName &
      " dev [selector] [--activity=name] [--foreground] [--http=HOST:PORT] [--debounce-ms=N]\n       " &
          programName &
      " hooks ensure|reinstall|uninstall [--vcs] [--shell-direnv] [--shell bash|zsh|fish|powershell] [path]\n       " &
          programName &
      " check --mode=pre-push [--workspace-root=PATH] [--current-repo=PATH] [--pushed-refs=FILE] [--tool-provisioning=path|nix|tarball|scoop] [--json]\n       " &
          programName &
      " branch [<name>] [--workspace-root=PATH] [--tool-provisioning=path|nix|tarball|scoop] [--json]\n       " &
          programName &
      " checkout <branch> [--workspace-root=PATH] [--tool-provisioning=path|nix|tarball|scoop] [--json]\n       " &
          programName &
      " watch [target[#name] [target...]] --daemon=auto|require|off --tool-provisioning=path|nix|tarball|scoop [--work-root=PATH] [--max-cycles=N] [--debounce-ms=N] [--detach] [--attach=SESSION] [--stop=SESSION] [--hcr-agent-socket=PATH --hcr-artifacts=PATH [--hcr-metadata=PATH]] [--hcr-target=NAME:SOCKET:ARTIFACTS[:METADATA] ...]\n       " &
          programName &
      " hcr coordinate --project PATH --target NAME --socket PATH --source-edit-driver PATH --artifacts PATH\n       " &
          programName &
      " hcr prepare-object --input PATH --output PATH (--function NAME|--all-code) [--segment NAME]\n       " &
          programName &
      " develop --list\n       " &
          programName &
      " develop <dependency> --into=PATH\n       " &
          programName &
      " develop <target[#name]> --tool-provisioning=path|nix|tarball|scoop [--work-root=PATH] -- <command> [args...]\n       " &
          programName &
      " develop --cmake <source-dir> --tool-provisioning=path|nix [--cmake-binary=PATH] [--work-root=PATH] -- <command> [args...]\n       " &
          programName &
      " debug fs-snoop [inspect <depfile> | [options] -- <command> [args...]]\n       " &
          programName &
      " debug artifact <path> [--format=text|json]\n       " &
          programName &
      " home {add | remove | enable | disable | list | why | history | apply | plan | rollback | set | get | adopt | resource} [--profile-dir=PATH] [--host=NAME] ...\n       " &
          programName &
      " daemon {status | start | stop | restart | logs | sessions} [--endpoint=PATH] [--state-dir=PATH] [--log=PATH]\n       " &
          programName &
      " stats [status|overview|rank|show|snapshot|compare]\n       " &
          programName &
      " store {gc | recover | roots | list | daemon} ...\n       " &
          programName &
      " infra {plan | apply} ...\n       " &
          programName &
      " system {add | remove | list | why | sync | history | rollback | audit} ...\n       " &
          programName &
      " show-conventions [--project=PATH] [--target=NAME] [--json] [PATH]\n\n" &
      "build progress: default=bar-line; aliases: " &
      "quiet=silent|none|off, line=ninja|single-line, " &
      "bar-line=bar|ninja-bar|auto|plain, lines=tup|per-line, " &
      "lines-bar=tup-bar|per-line-bar, dots=dot\n" &
      "build progress bars: default=overlay; use --progress-bars=split " &
      "or REPROBUILD_PROGRESS_BARS=split for separate check/exec bars\n" &
      "build color: auto by default; set NO_COLOR or REPROBUILD_COLOR=never " &
      "to disable, REPROBUILD_COLOR=always to force"
  elif programName == "repro-fs-snoop":
    programName & " " & versionString() & "\nusage: " & programName &
      " [options] -- <command> [args...]\n       " & programName &
      " inspect <depfile> --format text|json"
  else:
    programName & " " & versionString() & "\nusage: " & programName & " --version"

proc renderInternalUsage*(programName: string): string =
  ## Usage text for the documented-but-hidden ``repro internal …`` command
  ## group (Executable-Consolidation M1). These subcommands are role
  ## processes that ``repro`` reaches by self-spawn (``getAppFilename()`` +
  ## the ``internal`` argv) rather than via standalone sibling binaries.
  ## They are intentionally kept OUT of the primary ``repro`` help body —
  ## discoverable for debugging, walled off from the user surface — but
  ## ``repro internal --help`` prints this so the namespace is documented.
  ##
  ## The ``__repro-*`` argument spellings remain accepted as compatibility
  ## aliases for one release; the ``internal``-namespaced spellings below
  ## are the documented forms.
  programName & " " & versionString() & "\n" &
    "usage: " & programName & " internal <subcommand> [args...]\n\n" &
    "internal subcommands (role processes; not part of `" & programName &
      " help`):\n" &
    "  fs-snoop [options] -- <command> [args...]   filesystem-monitor shim " &
      "(user form: " & programName & " debug fs-snoop)\n" &
    "  runquota-helper …                           RunQuota lease helper " &
      "(alias of __repro-runquota-helper)\n" &
    "  compile-provider …                          provider-compile helper " &
      "(alias of __repro-compile-provider)\n" &
    "  compile-profile …                           profile-compile helper " &
      "(alias of __repro-compile-profile)\n" &
    "  dev-env-introspect …                        dev-env introspection " &
      "helper (alias of __repro-dev-env-introspect)\n" &
    "  render-dev-env-shell …                      dev-env shell renderer " &
      "(alias of __repro-render-dev-env-shell)\n" &
    "  direnv-activate …                           direnv activation helper " &
      "(alias of __repro-direnv-activate)\n" &
    "  native-shell-activate …                     native-shell activation " &
      "helper (alias of __repro-native-shell-activate)\n" &
    "  dev-session-supervisor …                    dev-session supervisor " &
      "(alias of __repro-dev-session-supervisor)\n" &
    "  dev-session-http …                          dev-session HTTP bridge " &
      "(alias of __repro-dev-session-http)\n" &
    "  cmake-regenerate …                          CMake regeneration helper " &
      "(alias of __repro-cmake-regenerate)"

proc parseToolProvisioning(value: string): ToolProvisioningMode =
  case value
  of "path":
    tpmPathOnly
  of "nix":
    tpmNix
  of "tarball":
    tpmTarball
  of "scoop":
    tpmScoop
  else:
    raise newException(ValueError, "unsupported --tool-provisioning=" & value)

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc digestHex(digest: ContentDigest): string =
  toHex(digest.bytes)

proc safePathSegment(value, fallback: string): string =
  for ch in value:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
        ch in {'-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = fallback

proc configuredWorkRoot(explicitRoot: string): string =
  if explicitRoot.len > 0:
    return explicitRoot
  getEnv("REPROBUILD_WORK_ROOT")

proc resolveActionCacheRoot*(explicitRoot: string = ""): string =
  ## Returns the user-level action-cache root with the precedence documented
  ## in Provider-Compile-Tiering.md §"Cache Scope" Phase 1:
  ##   1. ``explicitRoot`` (e.g. ``--action-cache-root=`` CLI flag)
  ##   2. ``${REPROBUILD_STORE_ROOT}/action-cache`` if the env var is set
  ##   3. ``${REPRO_STORE_ROOT}/action-cache`` (compat alias)
  ##   4. Platform default user cache dir
  ##
  ## The returned path is a *directory* root. The build engine adds the
  ## conventional ``action-cache`` and ``cas`` subdirectories. So this
  ## function returns ``<root-for-cache-and-cas>`` directly.
  if explicitRoot.len > 0:
    return explicitRoot
  let storeRoot = block:
    let v = getEnv("REPROBUILD_STORE_ROOT")
    if v.len > 0: v else: getEnv("REPRO_STORE_ROOT")
  if storeRoot.len > 0:
    return storeRoot / "action-cache"
  when defined(windows):
    let local = getEnv("LOCALAPPDATA")
    let base = if local.len > 0: local
               else: getEnv("USERPROFILE") / "AppData" / "Local"
    return base / "repro" / "action-cache"
  elif defined(macosx):
    let home = getEnv("HOME")
    return home / "Library" / "Caches" / "repro" / "action-cache"
  else:
    let xdg = getEnv("XDG_CACHE_HOME")
    let base = if xdg.len > 0: xdg else: getEnv("HOME") / ".cache"
    return base / "repro" / "action-cache"

# Process-wide override for the user-level action-cache root. Set by the
# ``--action-cache-root=`` CLI flag and consumed by every BuildEngineConfig
# constructor in this module. Empty means "use the platform default".
var actionCacheRootOverride: string = ""

proc setActionCacheRootOverride*(value: string) =
  actionCacheRootOverride = value

proc currentActionCacheRoot(): string =
  resolveActionCacheRoot(actionCacheRootOverride)

proc splitTarget(target: string): tuple[base: string; fragment: string] =
  let marker = target.find('#')
  if marker < 0:
    (base: target, fragment: "")
  else:
    (base: target[0 ..< marker], fragment: target[marker + 1 .. ^1])

type
  TargetFragmentKind = enum
    tfkNone
    tfkModule
    tfkActionSelection

  ParsedBuildTarget = object
    modulePath: string
    outputName: string
    selectedActionId: string
    fragmentKind: TargetFragmentKind

proc parseBuildTarget(target: string): ParsedBuildTarget =
  let parts = splitTarget(target)
  if parts.fragment.len > 0:
    if dirExists(extendedPath(parts.base)):
      let fragmentModule = parts.base / (parts.fragment & ".nim")
      if fileExists(extendedPath(fragmentModule)):
        return ParsedBuildTarget(
          modulePath: fragmentModule,
          outputName: parts.fragment,
          fragmentKind: tfkModule)
      # Project-file alias: prefer ``repro.nim``, fall back to
      # ``reprobuild.nim``. See repro_core/project_file.nim and
      # reprobuild-specs/Three-Mode-Convention-System.md. Having both
      # files in the same directory raises ``ProjectFileAmbiguousError``
      # which propagates to the CLI top-level handler.
      let projectMatch = resolveProjectFile(parts.base)
      if projectMatch.path.len > 0:
        return ParsedBuildTarget(
          modulePath: projectMatch.path,
          outputName: splitFile(projectMatch.path).name,
          selectedActionId: parts.fragment,
          fragmentKind: tfkActionSelection)
      return ParsedBuildTarget(
        modulePath: fragmentModule,
        outputName: parts.fragment,
        fragmentKind: tfkModule)
    return ParsedBuildTarget(
      modulePath: parts.base,
      outputName: parts.fragment,
      fragmentKind: tfkModule)

  let modulePath =
    if dirExists(extendedPath(parts.base)):
      # Project-file alias: prefer ``repro.nim``, fall back to
      # ``reprobuild.nim``. Empty match falls through to legacy name so
      # downstream "file not found" diagnostics still mention a concrete
      # filename. Both-files-present raises ``ProjectFileAmbiguousError``.
      let match = resolveProjectFile(parts.base)
      if match.path.len > 0: match.path
      else: parts.base / LegacyProjectFileName
    else:
      parts.base
  ParsedBuildTarget(
    modulePath: modulePath,
    outputName: splitFile(modulePath).name,
    fragmentKind: tfkNone)

proc moduleForTarget(target: string): string =
  parseBuildTarget(target).modulePath

type
  BuildSelectorKind* = enum
    ## Named-Targets M2: how a positional ``repro build`` argument is
    ## interpreted by the resolver. The path / fragment forms preserve
    ## the legacy ``parseBuildTarget`` behavior; the name forms go
    ## through the project's M1 target-export table.
    bskPath        ## Path / directory / fragment selector (legacy form).
    bskName        ## Unqualified implicit or explicit target name.
    bskQualified   ## ``<package>:<name>`` cross-package disambiguator.

  ClassifiedBuildSelector* = object
    raw*: string
    kind*: BuildSelectorKind
    package*: string  ## Only set for ``bskQualified``.
    name*: string     ## ``bskName``: the bare name. ``bskQualified``:
                      ## the post-``:`` half. ``bskPath``: empty.

  BuildTargetAmbiguousError* = object of CatchableError
    ## Raised by the M2 resolver when a name selector matches more than
    ## one package. The CLI top-level catches this and exits 2 with
    ## ``target_ambiguous`` diagnostic listing the qualified candidates.
    selectorName*: string
    candidates*: seq[string]

  BuildTargetUnknownError* = object of CatchableError
    ## Raised by the M2 resolver when a name selector matches no edge.
    ## The CLI top-level catches this and exits 2 with the
    ## ``unknown_target`` diagnostic and Levenshtein candidates.
    selectorName*: string
    suggestions*: seq[string]

proc renderAmbiguousTargetDiagnostic*(err: BuildTargetAmbiguousError): string =
  ## Named-Targets M2 ``target_ambiguous`` stderr diagnostic. Shared by
  ## the top-level CLI dispatch arm and the daemon-side
  ## ``installUserDaemonBuildExecutor`` hook so the two code paths
  ## cannot drift. Lines are terminated with ``\n`` and the returned
  ## string ends with a trailing newline, matching the ``writeLine``
  ## semantics of the original direct-mode emission.
  result.add("repro build: error: target_ambiguous: target '")
  result.add(err.selectorName)
  result.add("' is exported by multiple packages\n")
  result.add("repro build: candidates:\n")
  for cand in err.candidates:
    result.add("  ")
    result.add(cand)
    result.add('\n')
  result.add("repro build: hint: re-run with the qualified " &
    "<package>:<name> form\n")

proc renderUnknownTargetDiagnostic*(err: BuildTargetUnknownError): string =
  ## Named-Targets M2 ``unknown_target`` stderr diagnostic. Shared by
  ## the top-level CLI dispatch arm and the daemon-side
  ## ``installUserDaemonBuildExecutor`` hook so the two code paths
  ## cannot drift. Lines are terminated with ``\n`` and the returned
  ## string ends with a trailing newline.
  result.add("repro build: error: unknown_target: no build target matches '")
  result.add(err.selectorName)
  result.add("'\n")
  if err.suggestions.len > 0:
    result.add("repro build: did you mean:\n")
    for cand in err.suggestions:
      result.add("  ")
      result.add(cand)
      result.add('\n')

proc classifyBuildSelector*(raw: string): ClassifiedBuildSelector =
  ## Named-Targets M2 / [CLI/build.md §"Target Selection"] discriminator.
  ## A selector is a *path / fragment* selector when ANY of these holds:
  ## - it contains ``/`` or ``\\`` (path separator),
  ## - it contains ``.`` (file extension or relative-path marker),
  ## - it contains ``#`` (fragment selector),
  ## - it names an existing path on disk (file or directory).
  ##
  ## Otherwise it is a *name* selector. Names containing a single ``:``
  ## (and no other special chars) are treated as the qualified
  ## ``<package>:<name>`` form so M2 can disambiguate cross-package
  ## collisions even though M5 fully polishes the surface.
  result = ClassifiedBuildSelector(raw: raw)
  if raw.len == 0:
    result.kind = bskPath
    return
  for ch in raw:
    if ch == '/' or ch == '\\' or ch == '.' or ch == '#':
      result.kind = bskPath
      return
  if fileExists(extendedPath(raw)) or dirExists(extendedPath(raw)):
    result.kind = bskPath
    return
  let colon = raw.find(':')
  if colon > 0 and colon < raw.high:
    # ``<package>:<name>`` qualified form. Only accept when neither half
    # is empty AND there's exactly one ``:`` (so Windows drive letters
    # like ``C:\foo`` already get filtered by the path-shape check
    # above on ``\\``).
    let secondColon = raw.find(':', colon + 1)
    if secondColon < 0:
      result.kind = bskQualified
      result.package = raw[0 ..< colon]
      result.name = raw[colon + 1 .. ^1]
      return
  result.kind = bskName
  result.name = raw

type
  ResolvedPositionalSelectors* = object
    ## Named-Targets M3 shared resolver output. ``runBuildCommand`` and
    ## ``runWatchCommand`` both consume this so the path-vs-name
    ## discriminator + multi-target lowering are implemented in exactly
    ## one place.
    target*: string
      ## The engine's project anchor. For path-shaped positionals this
      ## is the original selector verbatim; for name-only invocations it
      ## is ``"."`` or ``".#<firstName>"`` so the legacy
      ## ``parseBuildTarget`` codepath still resolves a module.
    extraNameSelectors*: seq[string]
      ## Name-shaped positionals beyond the first. The lowering pass in
      ## ``lowerProviderSnapshot`` unions every selector's dependency
      ## closure in one engine pass.
    targetWasOmitted*: bool
      ## True when no positional was supplied. ``runBuildCommand`` uses
      ## this to flip ``selectDefaultAction = true``; watch sets the
      ## same flag for the same reason.

proc parseAndResolveSelectors*(positionalSelectors: openArray[string];
                               command: string): ResolvedPositionalSelectors =
  ## Named-Targets M3: shared path-vs-name resolver for ``repro build``
  ## and ``repro watch``. Mirrors the rules in
  ## [CLI/build.md §"Target Selection"] and
  ## [CLI/watch.md §"Target Selection"]:
  ##
  ## - The first positional whose ``classifyBuildSelector`` kind is
  ##   ``bskPath`` becomes the engine's project anchor (``target``).
  ##   A second path-shaped positional is rejected — the engine still
  ##   expects exactly one project anchor in M3 (qualified-name +
  ##   ``--list-targets`` polish lands in M5).
  ## - The first name-shaped positional, when no path anchor is present,
  ##   becomes ``".#<name>"`` so ``parseBuildTarget`` routes it through
  ##   the fragment / action-selection codepath. When a path anchor is
  ##   present, the first name-shaped positional joins
  ##   ``extraNameSelectors`` instead.
  ## - Every other name-shaped positional appends to
  ##   ``extraNameSelectors``. ``lowerProviderSnapshot`` unions their
  ##   closures with the anchor's in one engine pass.
  ##
  ## ``command`` is the user-visible verb (``"repro build"`` /
  ## ``"repro watch"``) so the duplicate-path-anchor diagnostic blames
  ## the right command.
  result.targetWasOmitted = positionalSelectors.len == 0
  if positionalSelectors.len == 0:
    result.target = ""
    return
  var anchorSet = false
  var firstNameSelector = ""
  for sel in positionalSelectors:
    let classified = classifyBuildSelector(sel)
    case classified.kind
    of bskPath:
      if not anchorSet:
        result.target = sel
        anchorSet = true
      else:
        raise newException(ValueError,
          command & ": multiple path / fragment selectors are not " &
            "supported in M3 (got '" & result.target & "' and '" & sel &
            "'); name-shaped selectors may follow a single path anchor")
    of bskName, bskQualified:
      if not anchorSet and firstNameSelector.len == 0:
        firstNameSelector = sel
      else:
        if result.extraNameSelectors.find(sel) < 0:
          result.extraNameSelectors.add(sel)
  if not anchorSet:
    # All selectors are name-shaped. Anchor at the current directory
    # and let ``parseBuildTarget`` route the first name through the
    # fragment / action-selection codepath. Remaining names go into
    # ``extraNameSelectors`` so the lowering pass takes their union.
    if firstNameSelector.len > 0:
      result.target = "." & "#" & firstNameSelector
    else:
      result.target = "."
  elif firstNameSelector.len > 0 and
      result.extraNameSelectors.find(firstNameSelector) < 0:
    # Path anchor + name selectors: the path is the project root, and
    # every name selector contributes its closure on top.
    result.extraNameSelectors.add(firstNameSelector)

proc scopedWorktreeRoot(modulePath, explicitWorkRoot: string): string =
  let workRoot = configuredWorkRoot(explicitWorkRoot)
  if workRoot.len == 0:
    return ""
  let base =
    if workRoot.isAbsolute:
      os.normalizedPath(workRoot)
    else:
      os.normalizedPath(absolutePath(workRoot))
  let projectRoot = os.normalizedPath(parentDir(absolutePath(modulePath)))
  let (_, tail) = splitPath(projectRoot)
  let hash = digestHex(blake3DomainDigest(projectRoot.bytesOf(),
    hdMetadataEnvelope))
  # The worktree dir name combines the project tail (for debuggability)
  # and a 16-char content-hash (for identity). When the resulting full
  # path approaches Windows' MAX_PATH (260 chars) the host's underlying
  # tools — notably nim's own stdlib used by the provider compile —
  # fail with ERROR_FILENAME_EXCED_RANGE since they don't transparently
  # prefix `\\?\` for every OS call. Detect that and fall back to the
  # bare hash; we lose a small amount of debuggability but the build
  # stays correct. The threshold leaves room for the tail of the path
  # the engine adds inside the worktree
  # (`/build/<outputName>/provider/project-provider.exe` ≈ 60 chars).
  const reservedTailChars = 80
  let tailSegment = safePathSegment(tail, "worktree")
  let combined = tailSegment & "-" & hash[0 .. 15]
  let baseLen = base.len + "/worktrees/".len
  let segment =
    if baseLen + combined.len + reservedTailChars > 260:
      hash[0 .. 15]
    else:
      combined
  base / "worktrees" / segment

proc outputDirForTarget(target: ParsedBuildTarget;
    explicitWorkRoot = ""): string =
  let scopedRoot = scopedWorktreeRoot(target.modulePath, explicitWorkRoot)
  if scopedRoot.len > 0:
    return scopedRoot / "build" / target.outputName
  parentDir(target.modulePath) / ".repro" / "build" / target.outputName

const DefaultBuildActionMetadataName = "reprobuild.default-build-action.v1"

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string]): string =
  args.mapIt(q(it)).join(" ")

proc projectRootForModule(modulePath: string): string =
  parentDir(modulePath)

type
  CmakeRegenerationMetadata = object
    enabled: bool
    suppressed: bool
    metadataFile: string
    sourceDir: string
    binaryDir: string
    providerRoot: string
    cmakeCommand: string
    checkFile: string
    globVerifyScript: string
    providerFile: string
    providerStateFile: string
    values: Table[string, string]

proc readKeyValueMetadata(path: string): Table[string, string] =
  if path.len == 0 or not fileExists(extendedPath(path)):
    return
  for rawLine in readFile(extendedPath(path)).splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let eq = line.find('=')
    if eq <= 0:
      continue
    result[line[0 ..< eq]] = line[eq + 1 .. ^1]

proc metadataValue(values: Table[string, string]; key: string;
                   fallback = ""): string =
  values.getOrDefault(key, fallback)

proc metadataFlag(values: Table[string, string]; key: string): bool =
  case values.getOrDefault(key, "").toLowerAscii()
  of "1", "on", "true", "yes", "enabled":
    true
  else:
    false

proc materializeCmakePath(meta: CmakeRegenerationMetadata;
                          path: string): string =
  if path.len == 0:
    return ""
  if path.isAbsolute:
    os.normalizedPath(path)
  else:
    os.normalizedPath(meta.binaryDir / path)

proc parseCmakeQuotedList(text, setName: string): seq[string] =
  var parsed: seq[string] = @[]
  var inSet = false
  var token = ""
  var inQuote = false
  var escaping = false

  proc finishToken() =
    if token.len > 0:
      parsed.add(token)
      token.setLen(0)

  for rawLine in text.splitLines():
    var line = rawLine.strip()
    if not inSet:
      if line == "set(" & setName:
        inSet = true
        continue
      if line.startsWith("set(" & setName & " "):
        inSet = true
        line = line.substr(("set(" & setName).len).strip()
      else:
        continue

    var i = 0
    while i < line.len:
      let ch = line[i]
      if inQuote:
        if escaping:
          token.add(ch)
          escaping = false
        elif ch == '\\':
          escaping = true
        elif ch == '"':
          inQuote = false
          finishToken()
        else:
          token.add(ch)
      else:
        case ch
        of '"':
          inQuote = true
        of ')':
          finishToken()
          return parsed
        of ' ', '\t':
          finishToken()
        else:
          token.add(ch)
      inc i
    if not inQuote:
      finishToken()
  parsed

proc parseCmakeListFromFile(path, setName: string): seq[string] =
  if path.len == 0 or not fileExists(extendedPath(path)):
    return
  parseCmakeQuotedList(readFile(extendedPath(path)), setName)

proc addUniquePath(paths: var seq[string]; path: string) =
  if path.len == 0:
    return
  let normalized = os.normalizedPath(path)
  if paths.find(normalized) < 0:
    paths.add(normalized)

proc cmakeRegenerationMetadataForModule(modulePath: string):
    CmakeRegenerationMetadata =
  let binaryDir = parentDir(modulePath)
  let metadataFile = binaryDir / "CMakeFiles" / "reprobuild" / "provider.meta"
  let values = readKeyValueMetadata(metadataFile)
  if values.len == 0 or values.metadataValue("generator") != "Reprobuild":
    return
  let sourceDir = values.metadataValue("source_dir")
  if sourceDir.len == 0:
    return
  result.values = values
  result.metadataFile = metadataFile
  result.sourceDir = os.normalizedPath(sourceDir)
  result.binaryDir = os.normalizedPath(values.metadataValue("binary_dir",
    binaryDir))
  result.providerRoot = os.normalizedPath(values.metadataValue("provider_root",
    result.binaryDir / "CMakeFiles" / "reprobuild"))
  result.cmakeCommand = values.metadataValue("cmake_command", "cmake")
  result.checkFile = values.metadataValue("cmake_regeneration_check_file",
    "CMakeFiles/Makefile.cmake")
  result.globVerifyScript = values.metadataValue(
    "cmake_regeneration_glob_verify",
    result.binaryDir / "CMakeFiles" / "VerifyGlobs.cmake")
  result.providerFile = values.metadataValue("cmake_regeneration_provider_file",
    result.binaryDir / "reprobuild.nim")
  result.providerStateFile = values.metadataValue(
    "cmake_regeneration_provider_state",
    result.providerRoot / "provider.last")
  result.suppressed = values.metadataFlag("cmake_regeneration_suppressed")
  result.enabled =
    not result.suppressed and
    values.metadataValue("cmake_regeneration", "enabled") != "disabled"

proc cmakeRegenerationInputs(meta: CmakeRegenerationMetadata;
                             publicCliPath: string): seq[string] =
  result.addUniquePath(meta.metadataFile)
  if publicCliPath.len > 0 and fileExists(extendedPath(publicCliPath)):
    result.addUniquePath(publicCliPath)
  if meta.cmakeCommand.isAbsolute and fileExists(extendedPath(meta.cmakeCommand)):
    result.addUniquePath(meta.cmakeCommand)
  let checkPath = meta.materializeCmakePath(meta.checkFile)
  result.addUniquePath(checkPath)
  result.addUniquePath(meta.binaryDir / "CMakeCache.txt")
  result.addUniquePath(meta.binaryDir / "CMakeFiles" / "cmake.check_cache")
  if meta.globVerifyScript.len > 0 and fileExists(extendedPath(meta.globVerifyScript)):
    result.addUniquePath(meta.globVerifyScript)
  for input in parseCmakeListFromFile(checkPath, "CMAKE_MAKEFILE_DEPENDS"):
    result.addUniquePath(meta.materializeCmakePath(input))

proc cmakeRegenerationHasGlobVerification(meta: CmakeRegenerationMetadata): bool =
  meta.globVerifyScript.len > 0 and fileExists(extendedPath(meta.globVerifyScript))

proc cmakeRegenerationOutputs(meta: CmakeRegenerationMetadata): seq[string] =
  result.addUniquePath(meta.providerFile)
  result.addUniquePath(meta.providerStateFile)
  if meta.cmakeRegenerationHasGlobVerification():
    # CMake's VerifyGlobs.cmake detects directory membership changes by
    # touching an empty marker. The action cache is content-based, so glob
    # projects must execute this edge until glob membership evidence is modeled.
    result.addUniquePath(meta.providerRoot /
      "cmake-regeneration-glob-always-run.sentinel")
  for key, value in meta.values:
    if key == "clean_manifest" or key.startsWith("clean_manifest_") or
        key == "hcr_metadata":
      result.addUniquePath(value)

proc addCmakeFingerprintField(payload: var string; value: string) =
  payload.add($value.len)
  payload.add(":")
  payload.add(value)
  payload.add("\n")

proc cmakeRegenerationFingerprint(meta: CmakeRegenerationMetadata;
                                  publicCliPath: string):
    ContentDigest =
  var payload = ""
  payload.addCmakeFingerprintField("reprobuild.cmake.regeneration.v1")
  payload.addCmakeFingerprintField(publicCliPath)
  payload.addCmakeFingerprintField(meta.cmakeCommand)
  payload.addCmakeFingerprintField(meta.sourceDir)
  payload.addCmakeFingerprintField(meta.binaryDir)
  payload.addCmakeFingerprintField(meta.checkFile)
  payload.addCmakeFingerprintField(meta.globVerifyScript)
  payload.addCmakeFingerprintField(meta.providerFile)
  payload.addCmakeFingerprintField(meta.providerStateFile)
  weakFingerprintFromText(payload)

proc cmakeRegenerationBuildAction(meta: CmakeRegenerationMetadata;
                                  publicCliPath: string): BuildAction =
  var env: seq[string] = @[]
  if meta.providerRoot.len > 0:
    let wrapperPath = meta.values.metadataValue("wrapper_path",
      meta.providerRoot / "bin")
    if wrapperPath.len > 0:
      env.add("PATH=" & wrapperPath & $PathSep & getEnv("PATH"))
  let sourceRoot = getEnv("REPROBUILD_SOURCE_ROOT")
  if sourceRoot.len > 0:
    env.add("REPROBUILD_SOURCE_ROOT=" & sourceRoot)
  let hasGlobVerification = meta.cmakeRegenerationHasGlobVerification()
  action("__repro_cmake_regenerate", @[
    publicCliPath,
    "__repro-cmake-regenerate",
    "--metadata", meta.metadataFile
  ],
    cwd = meta.binaryDir,
    inputs = cmakeRegenerationInputs(meta, publicCliPath),
    outputs = cmakeRegenerationOutputs(meta),
    commandStatsId = "repro cmake regeneration edge",
    cacheable = not hasGlobVerification,
    weakFingerprint = cmakeRegenerationFingerprint(meta, publicCliPath),
    dependencyPolicy = declaredOnlyPolicy(),
    env = env)

proc prependProcessPath(path: string) =
  if path.len == 0:
    return
  let normalized = os.normalizedPath(path)
  let current = getEnv("PATH")
  for item in current.split(PathSep):
    if item.len > 0 and os.normalizedPath(item) == normalized:
      return
  if current.len > 0:
    putEnv("PATH", normalized & $PathSep & current)
  else:
    putEnv("PATH", normalized)

proc applyCmakeProviderEnvironment(meta: CmakeRegenerationMetadata) =
  if meta.values.len == 0:
    return
  prependProcessPath(meta.values.metadataValue("wrapper_path",
    meta.providerRoot / "bin"))

proc reprobuildLibraryWorkDir(): string =
  proc hasReprobuildLibs(root: string): bool =
    dirExists(extendedPath(root / "libs" / "repro_project_dsl" / "src"))

  let envRoot = getEnv("REPROBUILD_SOURCE_ROOT")
  if envRoot.len > 0 and hasReprobuildLibs(envRoot):
    return envRoot
  let cwd = getCurrentDir()
  if hasReprobuildLibs(cwd):
    return cwd
  var sourceRoot = parentDir(currentSourcePath())
  for _ in 0 ..< 3:
    sourceRoot = parentDir(sourceRoot)
  if hasReprobuildLibs(sourceRoot):
    return sourceRoot
  cwd

proc moduleHasBuildBlock(modulePath: string): bool =
  for line in readFile(extendedPath(modulePath)).splitLines:
    if line.strip() == "build:":
      return true

proc materialProjectPath(projectRoot, path: string): string =
  if path.len == 0 or path.isAbsolute:
    path
  else:
    projectRoot / path

proc jsonStringSeq(values: openArray[string]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%value)

proc capabilitiesJson*(): JsonNode =
  var query = newJObject()
  query["command"] = %"repro capabilities"
  query["defaultFormat"] = %"json"
  query["formats"] = jsonStringSeq(["json", "text"])
  query["schemaId"] = %"reprobuild.capabilities.v1"

  var provider = newJObject()
  provider["metadataVersion"] = %3
  provider["generatedProviderKind"] = %"nim-source"
  provider["features"] = jsonStringSeq([
    "public-target-aliases",
    "default-target-metadata",
    "build-pool-metadata",
    "compile-commands",
    "declared-inputs-and-outputs",
    "depfile-dependency-evidence",
    "dyndep-fragment-conversion",
    "runquota-execution",
    "cmake-regeneration-edge",
    "provider-cache-priming",
    "build-report-json-inspection"])

  var hcrProfile = newJObject()
  hcrProfile["id"] = %"clang-gcc-debug-patchable-no-lto-v1"
  hcrProfile["status"] = %"prototype"
  hcrProfile["languages"] = jsonStringSeq(["C", "CXX"])
  hcrProfile["requires"] = jsonStringSeq([
    "debug-info",
    "patchable-function-entry",
    "relocatable-object-inputs",
    "source-object-link-relations",
    "linkgraph-evidence"])
  hcrProfile["rejects"] = jsonStringSeq([
    "lto",
    "interprocedural-optimization",
    "unsupported-asm-sources",
    "missing-debug-info"])
  var hcrProfiles = newJArray()
  hcrProfiles.add(hcrProfile)
  var codetracerProfile = newJObject()
  codetracerProfile["id"] = %"macos-arm64-direct-hcr-in-codetracer-v1"
  codetracerProfile["status"] = %"prototype"
  codetracerProfile["languages"] = jsonStringSeq(["C", "CXX"])
  codetracerProfile["requires"] = jsonStringSeq([
    "hcr-agent-protocol",
    "coordinator-agent-negotiation",
    "direct-patch-injection",
    "debug-object-payloads",
    "unwind-metadata-payloads",
    "source-generation-metadata",
    "codetracer-owned-launch",
    "mcr-recorded-agent-ipc"])
  codetracerProfile["features"] = jsonStringSeq([
    "hcr-agent-content-length-framing",
    "coordinator-agent-session-validation",
    "coordinator-direct-patch-request-packaging",
    "unix-domain-agent-ipc",
    "agent-socket-env-contract",
    "coordinator-report-json",
    "target-linked-c-agent-startup",
    "repro-hcr-coordinate-command",
    "codetracer-mcr-launch-bridge"])
  codetracerProfile["missingComponents"] = jsonStringSeq([])
  codetracerProfile["rejects"] = jsonStringSeq([
    "post-launch-attach",
    "same-process-direct-transaction-shortcut",
    "stdin-pipe-patch-substitute",
    "shared-library-positive-path",
    "coordinator-resend-during-replay",
    "disassembly-only-debugging"])
  hcrProfiles.add(codetracerProfile)

  var hcr = newJObject()
  hcr["decisionAuthority"] = %"reprobuild"
  hcr["buildSystemRole"] = %(
    "annotate candidate targets and static source/object/link relations")
  hcr["runtimeDecisions"] = jsonStringSeq([
    "rebuilt-actions",
    "changed-outputs",
    "affected-link-targets",
    "patchability",
    "reload-vs-restart"])
  hcr["candidateAnnotations"] = jsonStringSeq([
    "target-identity",
    "source-to-object-action",
    "object-to-link-action",
    "link-output",
    "linkgraph-action",
    "support-profile"])
  hcr["profiles"] = hcrProfiles

  var execution = newJObject()
  execution["scheduler"] = %"local"
  execution["runQuota"] = %"supported"
  execution["reports"] = jsonStringSeq(["build-report.json"])

  var interfaces = newJObject()
  interfaces["capabilityQuery"] = query
  interfaces["provider"] = provider
  interfaces["execution"] = execution
  interfaces["hcr"] = hcr

  result = newJObject()
  result["schemaId"] = %"reprobuild.capabilities.v1"
  result["reprobuildVersion"] = %versionString()
  result["host"] = %*{
    "os": hostOS,
    "cpu": hostCPU
  }
  result["interfaces"] = interfaces

proc renderCapabilitiesJson*(): string =
  capabilitiesJson().pretty()

proc renderCapabilitiesText*(): string =
  let caps = capabilitiesJson()
  "schemaId: " & caps["schemaId"].getStr() & "\n" &
    "reprobuildVersion: " & caps["reprobuildVersion"].getStr() & "\n" &
    "capabilityQuery: " &
      caps["interfaces"]["capabilityQuery"]["command"].getStr() & "\n" &
    "providerMetadataVersion: " &
      $caps["interfaces"]["provider"]["metadataVersion"].getInt() & "\n" &
    "hcrDecisionAuthority: " &
      caps["interfaces"]["hcr"]["decisionAuthority"].getStr()

proc runCapabilitiesCommand(args: openArray[string]): int =
  var format = "json"
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--help" or arg == "-h":
      echo "usage: repro capabilities [--format=json|text]"
      return 0
    elif arg == "--format":
      if i + 1 >= args.len:
        raise newException(ValueError, "--format requires json or text")
      format = args[i + 1]
      inc i
    elif arg.startsWith("--format="):
      format = arg["--format=".len .. ^1]
    else:
      raise newException(ValueError, "unsupported capabilities argument: " & arg)
    inc i

  case format
  of "json":
    echo renderCapabilitiesJson()
  of "text":
    echo renderCapabilitiesText()
  else:
    raise newException(ValueError, "unsupported --format=" & format)
  0

proc profileIndex(identity: PathOnlyBuildIdentity):
    Table[string, PathOnlyToolProfile] =
  for profile in identity.profiles:
    result[profile.packageSelector & "|" & profile.executableName] = profile
    if not result.hasKey(profile.executableName):
      result[profile.executableName] = profile

proc toolPathPrefix(profiles: Table[string, PathOnlyToolProfile]): string =
  var dirs: seq[string] = @[]
  for profile in profiles.values:
    let dir = parentDir(profile.resolvedExecutablePath)
    if dir.len > 0 and dirs.find(dir) < 0:
      dirs.add(dir)
  dirs.join($PathSep)

proc argvForCall(call: PublicCliCall; profile: PathOnlyToolProfile): seq[string] =
  result = @[profile.resolvedExecutablePath]

  proc encodedValues(arg: PublicCliArg): seq[string] =
    if arg.nimType.normalize == "seq[string]":
      if arg.encodedValue.len > 0:
        for item in arg.encodedValue.split("\x1f"):
          result.add(item)
    else:
      result.add(arg.encodedValue)

  proc addFormattedValue(outp: var seq[string]; flagName, value: string;
                         format: CliArgFormat) =
    case format
    of cafSeparate:
      outp.add(flagName)
      outp.add(value)
    of cafConcat:
      outp.add(flagName & value)
    of cafEquals:
      outp.add(flagName & "=" & value)

  proc addFlagArg(outp: var seq[string]; arg: PublicCliArg) =
    let flagName =
      if arg.alias.len > 0:
        arg.alias
      else:
        "--" & arg.name
    if arg.nimType.normalize == "bool":
      if arg.encodedValue.normalize == "true":
        outp.add(flagName)
      return
    let values = encodedValues(arg)
    if values.len == 0:
      return
    if arg.format == cafSeparate and not arg.repeated:
      outp.add(flagName)
      for value in values:
        outp.add(value)
    else:
      for value in values:
        outp.addFormattedValue(flagName, value, arg.format)

  proc addPositionalArg(outp: var seq[string]; arg: PublicCliArg) =
    for value in encodedValues(arg):
      outp.add(value)

  var beforeSubcommand: seq[PublicCliArg] = @[]
  var afterSubcommand: seq[PublicCliArg] = @[]
  var positional: seq[PublicCliArg] = @[]
  for arg in call.arguments:
    if arg.kind == cpkPositional:
      positional.add(arg)
      continue
    if arg.placement == capBeforeSubcommand:
      beforeSubcommand.add(arg)
    else:
      afterSubcommand.add(arg)

  for arg in beforeSubcommand:
    result.addFlagArg(arg)
  if call.subcommand.len > 0:
    result.add(call.subcommand)
  for arg in afterSubcommand:
    result.addFlagArg(arg)

  positional.sort do (a, b: PublicCliArg) -> int:
    cmp(a.position, b.position)
  for arg in positional:
    result.addPositionalArg(arg)

proc depfilePolicy(depfile: string): DependencyGatheringPolicy =
  if depfile.len == 0:
    return repro_core.declaredOnlyPolicy()
  DependencyGatheringPolicy(
    kind: dgRecognizedFormat,
    completeness: decComplete,
    recognizedReports: @[
      RecognizedDependencyReportSpec(
        formatName: DependencyFormatName(MakeDepfileFormatName),
        outputs: @[ExpectedDependencyFile(
          logicalName: "deps",
          path: depfile,
          required: true)],
        completeness: decComplete)
    ])

proc lowerDependencyPolicy(actionId, depfile: string;
                           policy: BuildActionDependencyPolicy):
    DependencyGatheringPolicy =
  case policy.kind
  of bdpDefault:
    result = depfilePolicy(depfile)
  of bdpDeclaredOnly:
    result = repro_core.declaredOnlyPolicy()
  of bdpAutomaticMonitor:
    if depfile.len > 0:
      raise newException(ValueError,
        "action " & actionId & " supplies legacy depfile and " &
          "automatic monitor dependencyPolicy; remove depfile or use " &
          "makeDepfilePolicy")
    result = DependencyGatheringPolicy(kind: dgAutomaticMonitor,
        completeness: decComplete)
  of bdpMakeDepfile:
    let selectedDepfile =
      if policy.depfile.len > 0:
        policy.depfile
      else:
        depfile
    if selectedDepfile.len == 0:
      raise newException(ValueError,
        "action " & actionId & " uses makeDepfilePolicy without a depfile path")
    if depfile.len > 0 and policy.depfile.len > 0 and depfile != policy.depfile:
      raise newException(ValueError,
        "action " & actionId & " supplies conflicting depfile paths: " &
          depfile & " and " & policy.depfile)
    result = depfilePolicy(selectedDepfile)
  result.ignoredInputPrefixes = policy.ignoredInputPrefixes

proc lowerGraphAction(node: GraphNode; profiles: Table[string, PathOnlyToolProfile];
                      projectRoot: string; actionPathPrefix = ""): BuildAction =
  let payload = decodeBuildActionPayload(toBytes(node.payload))
  # Named-Targets M1: copy implicit-target names off the decoded
  # payload onto every constructed ``BuildAction`` at the bottom of
  # this proc. The action constructors below don't know about
  # ``targetNames``; we stamp the field after the engine factory
  # returns so the engine-side edge record matches the DSL-side
  # ``BuildActionDef`` and the target-export table.
  #
  # Typed-Outputs M1: same plumbing for the per-output (fieldName,
  # types, path) entries — the engine consumes them downstream
  # without re-parsing the DSL.
  defer:
    result.targetNames = payload.targetNames
    var engineTypedOutputs: seq[EngineTypedOutput]
    for entry in payload.typedOutputs:
      engineTypedOutputs.add(EngineTypedOutput(
        fieldName: entry.fieldName,
        types: entry.types,
        path: entry.path))
    result.typedOutputs = engineTypedOutputs
  let actionCachePolicy =
    case payload.actionCachePolicy
    of acfpTimestamp:
      ffpTimestamp
    of acfpChecksum:
      ffpChecksum
    of acfpHybrid:
      ffpHybrid
  proc argValue(name: string): string =
    for arg in payload.call.arguments:
      if arg.name == name:
        return arg.encodedValue
    ""

  proc argSeqValue(name: string): seq[string] =
    let encoded = argValue(name)
    if encoded.len == 0:
      return @[]
    encoded.split("\x1f")

  if payload.call.packageName == "reprobuild.builtin" and
      payload.call.executableName == "exec":
    # Inline-exec builtin: the call carries a literal argv (and optional cwd)
    # and the action is launched directly via the engine's process action
    # without any package-profile lookup. The wrapper layer is bypassed
    # entirely; the binary graph cache holds the resolved argv.
    let argv = argSeqValue("argv")
    if argv.len == 0:
      raise newException(ValueError,
        "reprobuild.builtin.exec action " & payload.id &
          " has empty argv")
    let cwdValue = argValue("cwd")
    let commandStatsId =
      if payload.commandStatsId.len > 0:
        payload.commandStatsId
      else:
        payload.id
    let fingerprintText = [
      "reprobuild.localInlineExecAction.v1",
      payload.id,
      node.payload
    ].join("\n")
    return repro_build_engine.action(
      payload.id,
      argv,
      cwd =
        if cwdValue.len > 0: cwdValue
        else: projectRoot,
      deps = payload.deps,
      inputs = payload.inputs.mapIt(materialProjectPath(projectRoot, it)),
      outputs = payload.outputs,
      pool = payload.pool,
      poolUnits = payload.poolUnits,
      depfile = payload.depfile,
      dynamicDepsFile = payload.dynamicDepsFile,
      cacheable = payload.cacheable,
      weakFingerprint = weakFingerprintFromText(fingerprintText),
      actionCachePolicy = actionCachePolicy,
      dependencyPolicy = lowerDependencyPolicy(payload.id, payload.depfile,
        payload.dependencyPolicy),
      commandStatsId = commandStatsId)

  if payload.call.packageName == "reprobuild.builtin" and
      payload.call.executableName == "fs":
    let commandStatsId =
      if payload.commandStatsId.len > 0:
        payload.commandStatsId
      else:
        payload.id
    let fingerprintText = [
      "reprobuild.localBuiltinAction.v1",
      payload.id,
      payload.call.subcommand,
      node.payload
    ].join("\n")
    let kind =
      case payload.call.subcommand
      of "copyFile": bakCopyFile
      of "ensureDir": bakEnsureDir
      of "writeText": bakWriteText
      of "stamp": bakStamp
      of "preserveTree": bakPreserveTree
      else:
        raise newException(ValueError,
          "unknown built-in fs operation: " & payload.call.subcommand)
    return repro_build_engine.builtinAction(
      kind,
      payload.id,
      cwd = projectRoot,
      deps = payload.deps,
      inputs = payload.inputs.mapIt(materialProjectPath(projectRoot, it)),
      outputs = payload.outputs,
      commandStatsId = commandStatsId,
      cacheable = payload.cacheable,
      weakFingerprint = weakFingerprintFromText(fingerprintText),
      actionCachePolicy = actionCachePolicy,
      text = if payload.call.subcommand == "preserveTree":
          argValue("sourceRoot") & "\n" & argValue("outputRoot")
        else:
          argValue("text") & argValue("title"),
      entries = argSeqValue("entries"))

  if payload.call.packageName == "reprobuild.builtin" and
      payload.call.executableName == "hcr":
    if payload.call.subcommand != "prepareObject":
      raise newException(ValueError,
        "unknown built-in HCR operation: " & payload.call.subcommand)
    let commandStatsId =
      if payload.commandStatsId.len > 0:
        payload.commandStatsId
      else:
        payload.id
    let fingerprintText = [
      "reprobuild.localBuiltinHcrAction.v1",
      payload.id,
      payload.call.subcommand,
      node.payload
    ].join("\n")
    var argv = @[
      getAppFilename(), "hcr", "prepare-object",
      "--input", argValue("input"),
      "--output", argValue("output"),
      "--segment", argValue("segment")
    ]
    let functionName = argValue("function")
    if functionName.len > 0:
      argv.add "--function"
      argv.add functionName
    else:
      argv.add "--all-code"
    var inputs: seq[string] = @[]
    for input in payload.inputs:
      inputs.add(materialProjectPath(projectRoot, input))
    return repro_build_engine.action(
      payload.id,
      argv,
      cwd = projectRoot,
      deps = payload.deps,
      inputs = inputs,
      outputs = payload.outputs,
      pool = payload.pool,
      poolUnits = payload.poolUnits,
      depfile = payload.depfile,
      dynamicDepsFile = payload.dynamicDepsFile,
      cacheable = payload.cacheable,
      weakFingerprint = weakFingerprintFromText(fingerprintText),
      actionCachePolicy = actionCachePolicy,
      dependencyPolicy = lowerDependencyPolicy(payload.id, payload.depfile,
        payload.dependencyPolicy),
      commandStatsId = commandStatsId)

  let executableName = payload.call.executableName
  let packageName = payload.call.packageName
  let exactKey = packageName & "|" & executableName

  # Spec-Implementation M4 retired the
  # ``ct_test_nim_unittest.buildNimUnittest.build`` typed-tool
  # passthrough that used to sit here. The pre-M4 shim translated the
  # typed-tool call into a hand-rolled ``nim c`` argv:
  #
  #   subcommand "build"          -> subcommand "c"
  #   --source=<path> (positional)-> positional <path>
  #   --binary=<path>             -> --out:<path>
  #   --threads:on / --hints:off / --warnings:off (verbatim)
  #   --define:<X> / --import:<X> (verbatim)
  #
  # The shim existed because the typed-tool's executable identifier
  # ``ct_test_nim_unittest.buildNimUnittest`` had no real backing binary
  # — every action was conceptually a ``nim c`` invocation. M4 reshapes
  # the typed-tool wrapper at
  # ``ct-test/libs/ct_test_nim_unittest/src/ct_test_nim_unittest.nim``
  # so it records a ``PublicCliCall`` against the ``nim`` profile
  # directly (``executableName = "nim"``, ``subcommand = "c"``) with the
  # same flag aliases the ``nim.c`` typed-tool exposes (``--out:``,
  # ``-d:``, ``--import:``, ``--threads:on``, ``--hints:off``,
  # ``--warnings:off``). The engine's normal typed-tool resolution path
  # below now finds the ``nim`` profile and ``argvForCall`` produces
  # byte-for-byte the same argv shape the shim was synthesising — the
  # 500+ reprobuild test edges flow through the standard path. The
  # ``TestRunner`` cross-cutting interface from M3, satisfied by the
  # new ``ct_test_runner_adapter`` package at
  # ``ct-test/libs/ct_test_runner_adapter/``, handles RUN/LIST/ENUMERATE
  # at engine execution time so recipes that need to dispatch back to
  # ct-test-runner do so through ``currentBuildContext().testRunner``.

  let profile =
    if profiles.hasKey(exactKey):
      profiles[exactKey]
    elif profiles.hasKey(executableName):
      profiles[executableName]
    else:
      raise newException(ValueError,
        "tool-resolution failed: action " & payload.id &
          " references executable " & executableName &
          " but no tool profile was resolved for it")
  var inputs: seq[string] = @[]
  for input in payload.inputs:
    inputs.add(materialProjectPath(projectRoot, input))
  let outputs = payload.outputs
  let depfile = payload.depfile
  let commandStatsId =
    if payload.commandStatsId.len > 0:
      payload.commandStatsId
    else:
      payload.id
  let fingerprintText = [
    "reprobuild.localProjectAction.v1",
    payload.id,
    payload.call.packageName,
    executableName,
    payload.call.subcommand,
    node.payload,
    digestHex(profile.profileFingerprint)
  ].join("\n")
  repro_build_engine.action(
    payload.id,
    argvForCall(payload.call, profile),
    cwd = projectRoot,
    deps = payload.deps,
    inputs = inputs,
    outputs = outputs,
    pool = payload.pool,
    poolUnits = payload.poolUnits,
    depfile = depfile,
    dynamicDepsFile = payload.dynamicDepsFile,
    cacheable = payload.cacheable,
    weakFingerprint = weakFingerprintFromText(fingerprintText),
    actionCachePolicy = actionCachePolicy,
    dependencyPolicy = lowerDependencyPolicy(payload.id, depfile,
      payload.dependencyPolicy),
    commandStatsId = commandStatsId,
    env =
      if actionPathPrefix.len > 0:
        @["PATH=" & actionPathPrefix & $PathSep & getEnv("PATH")]
      else:
        @[])

proc levenshtein(a, b: string): int =
  ## Named-Targets M2 ``unknown_target`` diagnostic helper. A small
  ## inline edit-distance implementation rather than ``std/editdistance``
  ## so the resolver stays self-contained and predictable across the
  ## CLI's existing import surface. O(len(a)*len(b)) time / O(len(b))
  ## extra memory; the resolver only ever calls this against the
  ## handful of names in the project's target-export table.
  if a.len == 0: return b.len
  if b.len == 0: return a.len
  var prev = newSeq[int](b.len + 1)
  var curr = newSeq[int](b.len + 1)
  for j in 0 .. b.len:
    prev[j] = j
  for i in 1 .. a.len:
    curr[0] = i
    for j in 1 .. b.len:
      let cost =
        if a[i - 1] == b[j - 1]: 0
        else: 1
      var v = prev[j] + 1
      if curr[j - 1] + 1 < v:
        v = curr[j - 1] + 1
      if prev[j - 1] + cost < v:
        v = prev[j - 1] + cost
      curr[j] = v
    swap(prev, curr)
  prev[b.len]

proc topLevenshteinCandidates(query: string; candidates: openArray[string];
                              limit = 3): seq[string] =
  ## Return up to ``limit`` candidate names from ``candidates`` ordered
  ## by ascending Levenshtein distance to ``query``. Used by the M2
  ## ``unknown_target`` diagnostic.
  if candidates.len == 0:
    return @[]
  var scored: seq[tuple[name: string; dist: int]] = @[]
  for name in candidates:
    scored.add((name: name, dist: levenshtein(query, name)))
  scored.sort(proc(a, b: tuple[name: string; dist: int]): int =
    if a.dist != b.dist: a.dist - b.dist
    else: cmp(a.name, b.name))
  for i in 0 ..< min(limit, scored.len):
    result.add(scored[i].name)

proc aggregateTargetExportTable*(snapshot: ProviderGraphSnapshot):
    TargetExportTable =
  ## Named-Targets M2 aggregation: ``buildPackageFragment`` runs per
  ## package in isolation, so each fragment carries only the rows
  ## emitted while that package's ``build:`` body was running. The M2
  ## resolver needs a project-scoped view, so this proc walks every
  ## fragment's ``reprobuild.target-export-table.v1`` metadata node and
  ## merges the rows. Cross-package ambiguity is re-computed here
  ## because per-fragment ambiguity records only see same-name within a
  ## single package's call set.
  for fragment in snapshot.fragments:
    for node in fragment.nodes:
      # Spec-Implementation M5: accept both v1 and v2 metadata-node
      # stable names. The on-disk payload codec is backward-compatible
      # (v1 envelopes decode through ``decodeTargetExportTablePayload``
      # with the original two-value ``kind`` enum) so existing
      # snapshots from older builds still flow through this aggregator.
      if node.kind == gnkMetadata and
          (node.stableName == "reprobuild.target-export-table.v1" or
           node.stableName == "reprobuild.target-export-table.v2"):
        let perPackage = decodeTargetExportTablePayload(toBytes(node.payload))
        for entry in perPackage.entries:
          result.entries.add(entry)
  # Re-derive cross-package ambiguity over the unioned rows. A name is
  # ambiguous when two or more distinct ``owningPackage`` values claim
  # it. Per-fragment ambiguities (same-name collisions within one
  # package) are already raised as build-time errors at M1, so they
  # never reach M2.
  var packagesByName = initTable[string, seq[string]]()
  for entry in result.entries:
    if not packagesByName.hasKey(entry.name):
      packagesByName[entry.name] = @[]
    if packagesByName[entry.name].find(entry.owningPackage) < 0:
      packagesByName[entry.name].add(entry.owningPackage)
  for name, pkgs in packagesByName.pairs:
    if pkgs.len >= 2:
      var candidates: seq[string] = @[]
      for pkg in pkgs:
        candidates.add(pkg & ":" & name)
      candidates.sort()
      result.ambiguities.add(TargetExportAmbiguity(name: name,
        candidates: candidates))

type
  TargetResolutionKind* = enum
    ## Named-Targets M5: how a single selector was resolved against the
    ## project-scoped target-export table. Recorded in the build report
    ## under ``targetResolution`` so JSON consumers see the same shape as
    ## the CLI text diagnostics.
    trkResolved
    trkAmbiguous
    trkUnknown

  TargetResolutionRecord* = object
    selector*: string
    kind*: TargetResolutionKind
    actionId*: string         ## ``trkResolved``: the engine handle the
                              ## selector resolved to.
    owningPackage*: string    ## ``trkResolved``: the package whose call
                              ## emitted this edge (empty for explicit
                              ## ``target "..."`` labels and action ids).
    targetKind*: TargetExportKind ## Spec-Implementation M5: per
                              ## Build-Graph-Collections.md §"Persistence
                              ## and the Target-Export Table" the build
                              ## report carries the resolved row's
                              ## origin marker so JSON consumers can
                              ## tell a ``collection`` resolution apart
                              ## from an ``aggregate`` resolution apart
                              ## from a plain implicit / explicit
                              ## target. Defaults to ``tekImplicit`` (the
                              ## historical record kind) when the
                              ## resolver could not derive a row — e.g.
                              ## action-id pass-throughs.
    candidates*: seq[string]  ## ``trkAmbiguous``: the sorted qualified
                              ## ``<package>:<name>`` candidates.
    suggestions*: seq[string] ## ``trkUnknown``: top-3 Levenshtein
                              ## suggestions over known target names.

proc resolveTargetExportSelector*(exportTable: TargetExportTable;
                                  knownActionIds: openArray[string];
                                  knownExplicitTargets: openArray[string];
                                  selector: string): TargetResolutionRecord =
  ## Named-Targets M5: shared name-lookup that ``runGraphCommand`` /
  ## ``runWhyCommand`` use to translate a bare name or qualified
  ## ``<package>:<name>`` selector into an action id BEFORE handing the
  ## selector to ``parseBuildTarget``. Mirrors the in-lowering resolver
  ## inside ``lowerProviderSnapshot`` so the two code paths cannot
  ## drift. The return record is also embedded in the build report by
  ## ``writeBuildReport`` (M5 diagnostic-taxonomy polish).
  result.selector = selector

  # Build the same indexes the lowering resolver computes.
  var entriesByQualified = initTable[string, TargetExportEntry]()
  var entriesByName = initTable[string, seq[TargetExportEntry]]()
  for entry in exportTable.entries:
    let qualified = entry.owningPackage & ":" & entry.name
    if not entriesByQualified.hasKey(qualified):
      entriesByQualified[qualified] = entry
    if not entriesByName.hasKey(entry.name):
      entriesByName[entry.name] = @[]
    entriesByName[entry.name].add(entry)

  # Spec-Implementation M5: collection rows shadow same-name implicit
  # / explicit / aggregate rows per Build-Graph-Collections.md
  # §"Naming" — the bare-name path below prefers a ``tekCollection``
  # entry when both exist. The qualified-resolution and pass-through
  # paths return the entry's recorded kind directly.

  # 1. Qualified ``<package>:<name>``.
  let colon = selector.find(':')
  if colon > 0 and colon < selector.high:
    let secondColon = selector.find(':', colon + 1)
    if secondColon < 0 and entriesByQualified.hasKey(selector):
      let entry = entriesByQualified[selector]
      result.kind = trkResolved
      result.actionId = entry.actionId
      result.owningPackage = entry.owningPackage
      result.targetKind = entry.kind
      return

  # 2. Existing explicit target / action id pass-through.
  for actionId in knownActionIds:
    if actionId == selector:
      result.kind = trkResolved
      result.actionId = selector
      result.targetKind = tekImplicit
      return
  for explicitName in knownExplicitTargets:
    if explicitName == selector:
      result.kind = trkResolved
      result.actionId = selector
      result.targetKind = tekExplicit
      return

  # 3. Bare implicit name.
  if entriesByName.hasKey(selector):
    var ownerPackages: seq[string] = @[]
    var lastEntry: TargetExportEntry
    # Spec-Implementation M5: prefer a ``tekCollection`` entry when
    # one is present so ``repro build test`` resolves to the test
    # collection rather than an implicit name with the same spelling
    # produced by a test-binary edge.
    var collectionEntry: TargetExportEntry
    var hasCollectionEntry = false
    for entry in entriesByName[selector]:
      if ownerPackages.find(entry.owningPackage) < 0:
        ownerPackages.add(entry.owningPackage)
      lastEntry = entry
      if entry.kind == tekCollection and not hasCollectionEntry:
        collectionEntry = entry
        hasCollectionEntry = true
    if ownerPackages.len > 1:
      var candidates: seq[string] = @[]
      for pkg in ownerPackages:
        candidates.add(pkg & ":" & selector)
      candidates.sort()
      result.kind = trkAmbiguous
      result.candidates = candidates
      return
    let chosen = if hasCollectionEntry: collectionEntry else: lastEntry
    result.kind = trkResolved
    result.actionId = chosen.actionId
    result.owningPackage = chosen.owningPackage
    result.targetKind = chosen.kind
    return

  # 4. Unknown — synthesize Levenshtein suggestions.
  var known: seq[string] = @[]
  for actionId in knownActionIds:
    if known.find(actionId) < 0:
      known.add(actionId)
  for explicitName in knownExplicitTargets:
    if known.find(explicitName) < 0:
      known.add(explicitName)
  for name in entriesByName.keys:
    if known.find(name) < 0:
      known.add(name)
  result.kind = trkUnknown
  result.suggestions = topLevenshteinCandidates(selector, known)

proc lowerProviderSnapshot*(snapshot: ProviderGraphSnapshot;
                            identity: PathOnlyBuildIdentity;
                            projectRoot: string;
                            selectedActionIds: openArray[string]):
    tuple[actions: seq[BuildAction]; pools: seq[BuildPool]] =
  ## Named-Targets M2: accept multiple selectors and union their
  ## dependency closures in a single engine pass. Each selector may be
  ## an action id, an explicit ``target "name", handle`` label, an
  ## implicit target name carried by the M1 export table, or a
  ## qualified ``<package>:<name>`` form. When a selector matches more
  ## than one package, raises ``BuildTargetAmbiguousError``. When it
  ## matches no edge, raises ``BuildTargetUnknownError`` with up to
  ## three closest known names.
  let profiles = profileIndex(identity)
  let actionPathPrefix = toolPathPrefix(profiles)
  var actionNodes: seq[tuple[node: GraphNode; payload: BuildActionDef]] = @[]
  var targets = initTable[string, BuildTargetDef]()
  var pools = initTable[string, BuildPoolDef]()
  for fragment in snapshot.fragments:
    for node in fragment.nodes:
      if node.kind == gnkAction:
        actionNodes.add((
          node: node,
          payload: decodeBuildActionPayload(toBytes(node.payload))))
      elif node.kind == gnkMetadata and
          node.stableName == "reprobuild.build-target.v1":
        let target = decodeBuildTargetPayload(toBytes(node.payload))
        if targets.hasKey(target.name):
          raise newException(ValueError,
            "duplicate build target metadata: " & target.name)
        targets[target.name] = target
      elif node.kind == gnkMetadata and
          node.stableName == "reprobuild.build-pool.v1":
        let pool = decodeBuildPoolPayload(toBytes(node.payload))
        if pools.hasKey(pool.name):
          raise newException(ValueError,
            "duplicate build pool metadata: " & pool.name)
        pools[pool.name] = pool
  for pool in pools.values:
    result.pools.add(repro_build_engine.pool(pool.name, pool.capacity))
  let inferredActions = inferDeclaredActionDeps(
    actionNodes.mapIt(it.payload), projectRoot)
  for i in 0 ..< actionNodes.len:
    actionNodes[i].payload = inferredActions[i]
  var aliasForAction = initTable[string, string]()
  for target in targets.values:
    if target.actions.len == 1 and target.targets.len == 0:
      let actionId = target.actions[0]
      if aliasForAction.hasKey(actionId) and aliasForAction[actionId] !=
          target.name:
        raise newException(ValueError,
          "action " & actionId & " has multiple direct target aliases: " &
            aliasForAction[actionId] & " and " & target.name)
      aliasForAction[actionId] = target.name

  proc publicPayload(action: BuildActionDef): BuildActionDef =
    result = action
    if aliasForAction.hasKey(action.id):
      result.id = aliasForAction[action.id]
    for i in 0 ..< result.deps.len:
      if aliasForAction.hasKey(result.deps[i]):
        result.deps[i] = aliasForAction[result.deps[i]]

  proc lowerItem(item: tuple[node: GraphNode; payload: BuildActionDef]):
      BuildAction =
    var node = item.node
    node.payload = actionPayload(publicPayload(item.payload))
    lowerGraphAction(node, profiles, projectRoot, actionPathPrefix)

  # When no selector is provided, schedule every emitted edge — the
  # legacy "build everything" behavior preserved from the single-target
  # entry point.
  var hasSelector = false
  for s in selectedActionIds:
    if s.len > 0:
      hasSelector = true
      break
  if not hasSelector:
    for item in actionNodes:
      result.actions.add(lowerItem(item))
    return

  var byId = initTable[string, BuildActionDef]()
  for item in actionNodes:
    byId[item.payload.id] = item.payload

  # Named-Targets M2: aggregate every fragment's target-export table
  # into one project-scoped view. Cross-package ambiguity is re-derived
  # over the unioned rows because per-fragment ambiguity records only
  # see same-name collisions within one package's call set.
  let exportTable = aggregateTargetExportTable(snapshot)
  var entriesByQualified = initTable[string, TargetExportEntry]()
  var entriesByName = initTable[string, seq[TargetExportEntry]]()
  for entry in exportTable.entries:
    let qualified = entry.owningPackage & ":" & entry.name
    if not entriesByQualified.hasKey(qualified):
      entriesByQualified[qualified] = entry
    if not entriesByName.hasKey(entry.name):
      entriesByName[entry.name] = @[]
    entriesByName[entry.name].add(entry)

  proc resolveSelectorToActionId(selector: string): string =
    ## Returns the action id (or explicit target name) the selector
    ## resolves to. Raises ``BuildTargetAmbiguousError`` or
    ## ``BuildTargetUnknownError`` per the M2 diagnostic contract.
    # Try qualified ``<package>:<name>`` first — the form the
    # ambiguity diagnostic asks the user to re-run with.
    let colon = selector.find(':')
    if colon > 0 and colon < selector.high:
      if entriesByQualified.hasKey(selector):
        return entriesByQualified[selector].actionId
      # When the qualified form doesn't match a row, fall through to
      # the unqualified path below so we still attempt action-id /
      # explicit-target lookup (preserving the legacy behavior for
      # action ids that happen to contain a ``:``).

    # Existing action id (legacy ``parseBuildTarget`` ``#<id>`` form).
    if byId.hasKey(selector):
      return selector
    # Existing ``target "name", handle`` label.
    if targets.hasKey(selector):
      return selector

    # M2 implicit / explicit target-name lookup.
    if entriesByName.hasKey(selector):
      var ownerPackages: seq[string] = @[]
      var lastEntry: TargetExportEntry
      for entry in entriesByName[selector]:
        if ownerPackages.find(entry.owningPackage) < 0:
          ownerPackages.add(entry.owningPackage)
        lastEntry = entry
      if ownerPackages.len > 1:
        var candidates: seq[string] = @[]
        for pkg in ownerPackages:
          candidates.add(pkg & ":" & selector)
        candidates.sort()
        var err = newException(BuildTargetAmbiguousError,
          "target '" & selector & "' is exported by multiple packages: " &
            candidates.join(", ") &
            " — re-run with the qualified <package>:<name> form")
        err.selectorName = selector
        err.candidates = candidates
        raise err
      return lastEntry.actionId

    # Nothing matched — surface ``unknown_target`` with Levenshtein
    # suggestions over the known action ids, explicit target labels,
    # and implicit names.
    var known: seq[string] = @[]
    for item in actionNodes:
      if known.find(item.payload.id) < 0:
        known.add(item.payload.id)
    for name in targets.keys:
      if known.find(name) < 0:
        known.add(name)
    for name in entriesByName.keys:
      if known.find(name) < 0:
        known.add(name)
    let suggestions = topLevenshteinCandidates(selector, known)
    var err = newException(BuildTargetUnknownError,
      "unknown build target: " & selector &
        (if suggestions.len > 0:
          " (did you mean: " & suggestions.join(", ") & "?)"
        elif known.len > 0:
          " (available: " & known.join(", ") & ")"
        else: " (project defines no build actions or targets)"))
    err.selectorName = selector
    err.suggestions = suggestions
    raise err

  var resolvedRoots: seq[string] = @[]
  for selector in selectedActionIds:
    if selector.len == 0:
      continue
    let resolved = resolveSelectorToActionId(selector)
    if resolvedRoots.find(resolved) < 0:
      resolvedRoots.add(resolved)

  var selected = initHashSet[string]()
  var visitingTargets = initHashSet[string]()
  var expandedTargets = initHashSet[string]()
  var currentSelector = ""

  proc includeClosure(actionId: string) =
    if selected.contains(actionId):
      return
    if not byId.hasKey(actionId):
      raise newException(ValueError,
        "unknown dependency " & actionId & " while selecting build target " &
          currentSelector)
    selected.incl(actionId)
    for dep in byId[actionId].deps:
      includeClosure(dep)

  proc includeTarget(targetName: string) =
    if expandedTargets.contains(targetName):
      return
    if visitingTargets.contains(targetName):
      raise newException(ValueError,
        "cyclic build target dependency involving " & targetName)
    if not targets.hasKey(targetName):
      raise newException(ValueError,
        "unknown build target " & targetName & " while selecting " &
          currentSelector)
    visitingTargets.incl(targetName)
    let target = targets[targetName]
    for depTarget in target.targets:
      includeTarget(depTarget)
    for actionId in target.actions:
      includeClosure(actionId)
    visitingTargets.excl(targetName)
    expandedTargets.incl(targetName)

  for root in resolvedRoots:
    currentSelector = root
    if targets.hasKey(root):
      includeTarget(root)
    else:
      includeClosure(root)
  for item in actionNodes:
    if selected.contains(item.payload.id):
      result.actions.add(lowerItem(item))

proc lowerProviderSnapshot*(snapshot: ProviderGraphSnapshot;
                            identity: PathOnlyBuildIdentity;
                            projectRoot: string;
                            selectedActionId = ""):
    tuple[actions: seq[BuildAction]; pools: seq[BuildPool]] =
  ## Single-selector entry point preserved for the existing call sites
  ## (graph / why / etc.). The Named-Targets M2 multi-selector resolver
  ## lives on the ``openArray[string]`` overload above; this wrapper
  ## delegates to it with a one-element selector list.
  if selectedActionId.len == 0:
    lowerProviderSnapshot(snapshot, identity, projectRoot, [""])
  else:
    lowerProviderSnapshot(snapshot, identity, projectRoot, [selectedActionId])

proc defaultBuildActionId(snapshot: ProviderGraphSnapshot): string =
  for fragment in snapshot.fragments:
    for node in fragment.nodes:
      if node.kind == gnkMetadata and
          node.stableName == DefaultBuildActionMetadataName:
        if result.len > 0 and result != node.payload:
          raise newException(ValueError,
            "conflicting default build action metadata: " & result &
              " and " & node.payload)
        result = node.payload

const
  LoweredGraphCacheMagic = "RBLG"
  LoweredGraphCacheVersion = 3'u16
  LoweredGraphAlgorithmVersion = "reprobuild.loweredGraph.v1"

type
  LoweredGraphCacheRecord = object
    modulePath: string
    projectRoot: string
    selectedActionId: string
    pathEnv: string
    cacheKey: string
    actions: seq[BuildAction]
    pools: seq[BuildPool]

  DurableFileEvidence = object
    exists: bool
    size: BiggestInt
    mtimeUnix: int64
    mtimeNs: int64

  WarmToolIdentity = ref object
    key: string
    identityPath: string
    inspectionPath: string
    identityEvidence: DurableFileEvidence
    keyEvidence: DurableFileEvidence
    identity: PathOnlyBuildIdentity

  WarmProviderSnapshot = ref object
    providerArtifactId: string
    snapshotPath: string
    snapshotEvidence: DurableFileEvidence
    snapshot: ProviderGraphSnapshot

  WarmLoweredGraph = ref object
    cachePath: string
    modulePath: string
    projectRoot: string
    selectedActionId: string
    pathEnv: string
    cacheKey: string
    cacheEvidence: DurableFileEvidence
    actions: seq[BuildAction]
    pools: seq[BuildPool]

var warmToolIdentities = initTable[string, WarmToolIdentity]()
var warmProviderSnapshots = initTable[string, WarmProviderSnapshot]()
var warmLoweredGraphs = initTable[string, WarmLoweredGraph]()

proc durableFileEvidence(path: string): DurableFileEvidence =
  try:
    if not fileExists(extendedPath(path)):
      return DurableFileEvidence(exists: false)
    let info = getFileInfo(extendedPath(path), followSymlink = false)
    DurableFileEvidence(exists: true, size: info.size,
      mtimeUnix: info.lastWriteTime.toUnix,
      mtimeNs: int64(info.lastWriteTime.nanosecond))
  except CatchableError:
    DurableFileEvidence(exists: false)

proc evidenceFresh(path: string; evidence: DurableFileEvidence): bool =
  durableFileEvidence(path) == evidence

proc readByteValue(bytes: openArray[byte]; pos: var int): byte =
  if pos >= bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated byte")
  result = bytes[pos]
  inc pos

proc writeDigestPayload(outp: var seq[byte]; digest: ContentDigest) =
  outp.add(byte(ord(digest.algorithm)))
  outp.add(byte(ord(digest.domain)))
  outp.add(digest.bytes)

proc readDigestPayload(bytes: openArray[byte]; pos: var int): ContentDigest =
  let algorithm = readByteValue(bytes, pos)
  let domain = readByteValue(bytes, pos)
  if algorithm > byte(ord(haXxh3_64)):
    raiseEnvelopeError(eeMalformed, "invalid digest algorithm")
  if domain > byte(ord(hdMetadataEnvelope)):
    raiseEnvelopeError(eeMalformed, "invalid digest domain")
  if pos + 32 > bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated digest bytes")
  result.algorithm = HashAlgorithm(algorithm)
  result.domain = HashDomain(domain)
  for i in 0 ..< 32:
    result.bytes[i] = bytes[pos + i]
  pos += 32

proc writeStringSeq(outp: var seq[byte]; values: openArray[string]) =
  outp.writeU32Le(uint32(values.len))
  for value in values:
    outp.writeString(value)

proc readStringSeq(bytes: openArray[byte]; pos: var int): seq[string] =
  let count = int(readU32Le(bytes, pos))
  result = newSeq[string](count)
  for i in 0 ..< count:
    result[i] = readString(bytes, pos)

proc writeExpectedDependencyFile(outp: var seq[byte];
                                 value: ExpectedDependencyFile) =
  outp.writeString(value.logicalName)
  outp.writeString(value.path)
  outp.add(if value.required: 1'u8 else: 0'u8)

proc readExpectedDependencyFile(bytes: openArray[byte]; pos: var int):
    ExpectedDependencyFile =
  result.logicalName = readString(bytes, pos)
  result.path = readString(bytes, pos)
  result.required = readByteValue(bytes, pos) != 0

proc writeProcessSpec(outp: var seq[byte]; process: ProcessSpec) =
  outp.add(byte(ord(process.kind)))
  outp.writeString(process.executable.value)
  outp.writeStringSeq(process.args)
  outp.writeU32Le(uint32(process.env.len))
  for item in process.env:
    outp.writeString(item.name)
    outp.writeString(item.value)
  outp.writeString(process.cwd.value)
  outp.add(byte(ord(process.stdinPolicy)))
  outp.add(byte(ord(process.stdoutPolicy)))
  outp.add(byte(ord(process.stderrPolicy)))

proc readProcessSpec(bytes: openArray[byte]; pos: var int): ProcessSpec =
  let kind = readByteValue(bytes, pos)
  if kind > byte(ord(ckShell)):
    raiseEnvelopeError(eeMalformed, "invalid process kind")
  result.kind = CommandKind(kind)
  result.executable = NormalizedPath(kind: npRelative, value: readString(bytes, pos))
  result.args = readStringSeq(bytes, pos)
  let envCount = int(readU32Le(bytes, pos))
  result.env = newSeq[EnvVar](envCount)
  for i in 0 ..< envCount:
    result.env[i].name = readString(bytes, pos)
    result.env[i].value = readString(bytes, pos)
  result.cwd = NormalizedPath(kind: npRelative, value: readString(bytes, pos))
  let stdinPolicy = readByteValue(bytes, pos)
  let stdoutPolicy = readByteValue(bytes, pos)
  let stderrPolicy = readByteValue(bytes, pos)
  if stdinPolicy > byte(ord(spCapture)) or stdoutPolicy > byte(ord(spCapture)) or
      stderrPolicy > byte(ord(spCapture)):
    raiseEnvelopeError(eeMalformed, "invalid stdio policy")
  result.stdinPolicy = StdioPolicy(stdinPolicy)
  result.stdoutPolicy = StdioPolicy(stdoutPolicy)
  result.stderrPolicy = StdioPolicy(stderrPolicy)

proc writeDependencyPolicy(outp: var seq[byte];
                           policy: DependencyGatheringPolicy) =
  outp.add(byte(ord(policy.kind)))
  outp.add(byte(ord(policy.completeness)))
  outp.writeU32Le(uint32(policy.recognizedReports.len))
  for report in policy.recognizedReports:
    outp.writeString($report.formatName)
    outp.writeU32Le(uint32(report.outputs.len))
    for output in report.outputs:
      outp.writeExpectedDependencyFile(output)
    outp.add(byte(ord(report.completeness)))
  outp.writeU32Le(uint32(policy.postBuildConverters.len))
  for converterSpec in policy.postBuildConverters:
    outp.writeProcessSpec(converterSpec.converterProcess)
    outp.writeU32Le(uint32(converterSpec.inputs.len))
    for input in converterSpec.inputs:
      outp.writeExpectedDependencyFile(input)
    outp.writeU32Le(uint32(converterSpec.outputs.len))
    for output in converterSpec.outputs:
      outp.writeExpectedDependencyFile(output)
    outp.add(byte(ord(converterSpec.outputKind)))
    outp.writeString($converterSpec.outputFormatName)
    outp.add(byte(ord(converterSpec.completeness)))
  outp.writeStringSeq(policy.ignoredInputPrefixes)

proc readCompleteness(bytes: openArray[byte]; pos: var int):
    DependencyEvidenceCompleteness =
  let value = readByteValue(bytes, pos)
  if value > byte(ord(decDiagnosticOnly)):
    raiseEnvelopeError(eeMalformed, "invalid dependency completeness")
  DependencyEvidenceCompleteness(value)

proc readDependencyPolicy(bytes: openArray[byte]; pos: var int):
    DependencyGatheringPolicy =
  let kind = readByteValue(bytes, pos)
  if kind > byte(ord(dgNoRuntimeDependencies)):
    raiseEnvelopeError(eeMalformed, "invalid dependency gathering kind")
  result.kind = DependencyGatheringKind(kind)
  result.completeness = readCompleteness(bytes, pos)
  let reportCount = int(readU32Le(bytes, pos))
  result.recognizedReports = newSeq[RecognizedDependencyReportSpec](reportCount)
  for i in 0 ..< reportCount:
    result.recognizedReports[i].formatName =
      DependencyFormatName(readString(bytes, pos))
    let outputCount = int(readU32Le(bytes, pos))
    result.recognizedReports[i].outputs = newSeq[ExpectedDependencyFile](outputCount)
    for j in 0 ..< outputCount:
      result.recognizedReports[i].outputs[j] =
        readExpectedDependencyFile(bytes, pos)
    result.recognizedReports[i].completeness = readCompleteness(bytes, pos)
  let converterCount = int(readU32Le(bytes, pos))
  result.postBuildConverters =
    newSeq[PostBuildDependencyConverterSpec](converterCount)
  for i in 0 ..< converterCount:
    result.postBuildConverters[i].converterProcess = readProcessSpec(bytes, pos)
    let inputCount = int(readU32Le(bytes, pos))
    result.postBuildConverters[i].inputs =
      newSeq[ExpectedDependencyFile](inputCount)
    for j in 0 ..< inputCount:
      result.postBuildConverters[i].inputs[j] =
        readExpectedDependencyFile(bytes, pos)
    let outputCount = int(readU32Le(bytes, pos))
    result.postBuildConverters[i].outputs =
      newSeq[ExpectedDependencyFile](outputCount)
    for j in 0 ..< outputCount:
      result.postBuildConverters[i].outputs[j] =
        readExpectedDependencyFile(bytes, pos)
    let outputKind = readByteValue(bytes, pos)
    if outputKind > byte(ord(dcoRecognizedFormat)):
      raiseEnvelopeError(eeMalformed, "invalid converter output kind")
    result.postBuildConverters[i].outputKind =
      DependencyConverterOutputKind(outputKind)
    result.postBuildConverters[i].outputFormatName =
      DependencyFormatName(readString(bytes, pos))
    result.postBuildConverters[i].completeness = readCompleteness(bytes, pos)
  result.ignoredInputPrefixes = readStringSeq(bytes, pos)

proc writeBuildAction(outp: var seq[byte]; action: BuildAction) =
  outp.add(byte(ord(action.kind)))
  outp.writeString(action.id)
  outp.writeStringSeq(action.deps)
  outp.writeStringSeq(action.inputs)
  outp.writeStringSeq(action.outputs)
  outp.writeStringSeq(action.argv)
  outp.writeString(action.cwd)
  outp.writeStringSeq(action.env)
  outp.writeString(action.pool)
  outp.writeU32Le(action.poolUnits)
  outp.writeU32Le(action.cpuMilli)
  outp.writeU64Le(action.memoryBytes)
  outp.writeString(action.commandStatsId)
  outp.add(if action.cacheable: 1'u8 else: 0'u8)
  outp.writeDigestPayload(action.weakFingerprint)
  outp.add(byte(ord(action.actionCachePolicy)))
  outp.writeString(action.depfile)
  outp.writeString(action.dynamicDepsFile)
  outp.writeString(action.monitorDepfile)
  outp.writeDependencyPolicy(action.dependencyPolicy)
  outp.writeString(action.builtinText)
  outp.writeStringSeq(action.builtinEntries)

proc readBuildAction(bytes: openArray[byte]; pos: var int): BuildAction =
  let kind = readByteValue(bytes, pos)
  if kind > byte(ord(bakPreserveTree)):
    raiseEnvelopeError(eeMalformed, "invalid build action kind")
  result.kind = BuildActionKind(kind)
  result.id = readString(bytes, pos)
  result.deps = readStringSeq(bytes, pos)
  result.inputs = readStringSeq(bytes, pos)
  result.outputs = readStringSeq(bytes, pos)
  result.argv = readStringSeq(bytes, pos)
  result.cwd = readString(bytes, pos)
  result.env = readStringSeq(bytes, pos)
  result.pool = readString(bytes, pos)
  result.poolUnits = readU32Le(bytes, pos)
  result.cpuMilli = readU32Le(bytes, pos)
  result.memoryBytes = readU64Le(bytes, pos)
  result.commandStatsId = readString(bytes, pos)
  result.cacheable = readByteValue(bytes, pos) != 0
  result.weakFingerprint = readDigestPayload(bytes, pos)
  let policy = readByteValue(bytes, pos)
  if policy > byte(ord(ffpHybrid)):
    raiseEnvelopeError(eeMalformed, "invalid action cache policy")
  result.actionCachePolicy = FileFingerprintPolicy(policy)
  result.depfile = readString(bytes, pos)
  result.dynamicDepsFile = readString(bytes, pos)
  result.monitorDepfile = readString(bytes, pos)
  result.dependencyPolicy = readDependencyPolicy(bytes, pos)
  result.builtinText = readString(bytes, pos)
  result.builtinEntries = readStringSeq(bytes, pos)

proc encodeLoweredGraphCache(record: LoweredGraphCacheRecord): seq[byte] =
  result.writeString(LoweredGraphCacheMagic)
  result.writeU16Le(LoweredGraphCacheVersion)
  result.writeString(record.modulePath)
  result.writeString(record.projectRoot)
  result.writeString(record.selectedActionId)
  result.writeString(record.pathEnv)
  result.writeString(record.cacheKey)
  result.writeU32Le(uint32(record.pools.len))
  for pool in record.pools:
    result.writeString(pool.name)
    result.writeU32Le(pool.capacity)
  result.writeU32Le(uint32(record.actions.len))
  for action in record.actions:
    result.writeBuildAction(action)

proc decodeLoweredGraphCache(bytes: openArray[byte]): LoweredGraphCacheRecord =
  var pos = 0
  if readString(bytes, pos) != LoweredGraphCacheMagic:
    raiseEnvelopeError(eeUnknownMagic, "unknown lowered graph cache magic")
  let version = readU16Le(bytes, pos)
  if version != LoweredGraphCacheVersion:
    raiseEnvelopeError(eeUnsupportedVersion,
      "unsupported lowered graph cache version")
  result.modulePath = readString(bytes, pos)
  result.projectRoot = readString(bytes, pos)
  result.selectedActionId = readString(bytes, pos)
  result.pathEnv = readString(bytes, pos)
  result.cacheKey = readString(bytes, pos)
  let poolCount = int(readU32Le(bytes, pos))
  result.pools = newSeq[BuildPool](poolCount)
  for i in 0 ..< poolCount:
    result.pools[i].name = readString(bytes, pos)
    result.pools[i].capacity = readU32Le(bytes, pos)
  let actionCount = int(readU32Le(bytes, pos))
  result.actions = newSeq[BuildAction](actionCount)
  for i in 0 ..< actionCount:
    result.actions[i] = readBuildAction(bytes, pos)
  if pos != bytes.len:
    raiseEnvelopeError(eeMalformed, "trailing lowered graph cache bytes")

proc loweredGraphCachePath(outDir, selectedActionId: string): string =
  let label =
    if selectedActionId.len > 0:
      selectedActionId
    else:
      "__omitted_default__"
  outDir / "lowered-graph-cache" /
    (safePathSegment(label, "default") & "-" &
      toHex(weakFingerprintFromText(label).bytes)[0 .. 15] & ".rbbg")

proc readFreshLoweredGraphCache(path, modulePath, projectRoot, selectedActionId,
                                pathEnv, cacheKey: string):
    Option[tuple[actions: seq[BuildAction]; pools: seq[BuildPool]]] =
  if not fileExists(extendedPath(path)):
    return none(tuple[actions: seq[BuildAction]; pools: seq[BuildPool]])
  try:
    let record = decodeLoweredGraphCache(toBytes(readFile(extendedPath(path))))
    if record.modulePath != modulePath or record.projectRoot != projectRoot or
        record.selectedActionId != selectedActionId or record.pathEnv != pathEnv or
        record.cacheKey != cacheKey:
      return none(tuple[actions: seq[BuildAction]; pools: seq[BuildPool]])
    return some((actions: record.actions, pools: record.pools))
  except CatchableError:
    return none(tuple[actions: seq[BuildAction]; pools: seq[BuildPool]])

proc warmReadFreshLoweredGraphCache(path, modulePath, projectRoot,
                                    selectedActionId, pathEnv,
                                    cacheKey: string):
    Option[tuple[actions: seq[BuildAction]; pools: seq[BuildPool]]] =
  let tableKey = path & "\0" & cacheKey
  if warmLoweredGraphs.hasKey(tableKey):
    let warm = warmLoweredGraphs[tableKey]
    if warm.cachePath == path and warm.modulePath == modulePath and
        warm.projectRoot == projectRoot and
        warm.selectedActionId == selectedActionId and
        warm.pathEnv == pathEnv and warm.cacheKey == cacheKey and
        evidenceFresh(path, warm.cacheEvidence):
      return some((actions: warm.actions, pools: warm.pools))
  result = readFreshLoweredGraphCache(path, modulePath, projectRoot,
    selectedActionId, pathEnv, cacheKey)
  if result.isSome:
    let lowered = result.get()
    warmLoweredGraphs[tableKey] = WarmLoweredGraph(cachePath: path,
      modulePath: modulePath, projectRoot: projectRoot,
      selectedActionId: selectedActionId, pathEnv: pathEnv,
      cacheKey: cacheKey, cacheEvidence: durableFileEvidence(path),
      actions: lowered.actions, pools: lowered.pools)

proc writeLoweredGraphCache(path, modulePath, projectRoot, selectedActionId,
                            pathEnv, cacheKey: string;
                            lowered: tuple[actions: seq[BuildAction];
                                           pools: seq[BuildPool]]) =
  createDir(extendedPath(parentDir(path)))
  let record = LoweredGraphCacheRecord(
    modulePath: modulePath,
    projectRoot: projectRoot,
    selectedActionId: selectedActionId,
    pathEnv: pathEnv,
    cacheKey: cacheKey,
    actions: lowered.actions,
    pools: lowered.pools)
  writeFile(extendedPath(path), fromBytes(encodeLoweredGraphCache(record)))
  warmLoweredGraphs[path & "\0" & cacheKey] = WarmLoweredGraph(cachePath: path,
    modulePath: modulePath, projectRoot: projectRoot,
    selectedActionId: selectedActionId, pathEnv: pathEnv, cacheKey: cacheKey,
    cacheEvidence: durableFileEvidence(path), actions: lowered.actions,
    pools: lowered.pools)

proc evidenceJson(evidence: PathSetEvidence): JsonNode =
  %*{
    "declaredInputs": jsonStringSeq(evidence.declaredInputs),
    "declaredOutputs": jsonStringSeq(evidence.declaredOutputs),
    "depfileInputs": jsonStringSeq(evidence.depfileInputs),
    "monitorReads": jsonStringSeq(evidence.monitorReads),
    "monitorWrites": jsonStringSeq(evidence.monitorWrites),
    "monitorProbes": jsonStringSeq(evidence.monitorProbes),
    "diagnostics": jsonStringSeq(evidence.diagnostics)
  }

proc statsJson(stats: BuildStats): JsonNode =
  var metrics = newJArray()
  for metric in stats.metrics:
    let avgUs =
      if metric.count > 0:
        metric.totalUs / float(metric.count)
      else:
        0.0
    metrics.add(%*{
      "name": metric.name,
      "count": metric.count,
      "avgUs": avgUs,
      "totalMs": metric.totalUs / 1000.0
    })
  %*{"metrics": metrics}

proc metricCount(stats: BuildStats; name: string): int =
  for metric in stats.metrics:
    if metric.name == name:
      return metric.count

proc metricTotalUs(stats: BuildStats; name: string): float =
  for metric in stats.metrics:
    if metric.name == name:
      return metric.totalUs

proc metricBucketUs(stats: BuildStats; names: openArray[string]): float =
  for name in names:
    result += stats.metricTotalUs(name)

proc benchmarkMetricsJson(stats: BuildStats): JsonNode =
  result = newJArray()
  for metric in stats.metrics:
    result.add(%*{
      "name": metric.name,
      "count": metric.count,
      "totalUs": metric.totalUs
    })

proc fileSizeOrZero(path: string): BiggestInt =
  if path.len == 0 or not fileExists(extendedPath(path)):
    return 0
  getFileSize(extendedPath(path))

proc evidenceInputCount(evidence: PathSetEvidence): int =
  var seen: seq[string] = @[]
  for group in [evidence.declaredInputs, evidence.depfileInputs,
      evidence.monitorReads, evidence.monitorProbes]:
    for path in group:
      if path.len > 0 and seen.find(path) < 0:
        seen.add(path)
  seen.len

proc actionPresent(action: ActionResult): bool =
  action.id.len > 0 and action.status != asPending

proc actionResultJson(item: ActionResult): JsonNode =
  # Windows: include exitCode/stdout/stderr in the build report so failed
  # actions can be diagnosed without re-running them. Without this, the JSON
  # report only carries status/cacheDecision/etc. and failures look opaque.
  %*{
    "id": item.id,
    "status": $item.status,
    "exitCode": item.exitCode,
    "launched": item.launched,
    "wouldLaunch": item.wouldLaunch,
    "cacheDecision": $item.cacheDecision,
    "reason": item.reason,
    "dependencyPolicyKind": $item.dependencyPolicyKind,
    "runQuotaBackend": item.runQuotaBackend,
    "runQuotaSocket": item.runQuotaSocket,
    "leaseId": item.leaseId,
    "stdout": item.stdout,
    "stderr": item.stderr,
    "evidence": evidenceJson(item.evidence)
  }

proc targetResolutionJson(record: TargetResolutionRecord): JsonNode =
  ## Named-Targets M5 / Spec-Implementation M5: serialise one resolver
  ## outcome for the build report's ``targetResolution`` array. Mirrors
  ## the CLI text diagnostic taxonomy (``resolved`` / ``ambiguous`` /
  ## ``unknown``) so JSON consumers see the same shape as the stderr
  ## lines. The Spec-Implementation M5 registry split adds a
  ## ``targetKind`` field on ``trkResolved`` records carrying the
  ## row's origin marker per Build-Graph-Collections.md §"Persistence
  ## and the Target-Export Table" — one of ``"collection"``,
  ## ``"aggregate"``, ``"implicit"``, or ``"explicit"``.
  let kindText =
    case record.kind
    of trkResolved: "resolved"
    of trkAmbiguous: "ambiguous"
    of trkUnknown: "unknown"
  result = %*{
    "selector": record.selector,
    "kind": kindText
  }
  case record.kind
  of trkResolved:
    result["actionId"] = %record.actionId
    result["package"] = %record.owningPackage
    let targetKindText =
      case record.targetKind
      of tekImplicit: "implicit"
      of tekExplicit: "explicit"
      of tekAggregate: "aggregate"
      of tekCollection: "collection"
    result["targetKind"] = %targetKindText
  of trkAmbiguous:
    result["candidates"] = jsonStringSeq(record.candidates)
  of trkUnknown:
    result["suggestions"] = jsonStringSeq(record.suggestions)

proc writeBuildReport(path: string; provider: ProviderCompileArtifact;
                      refresh: ProviderRefreshReport;
                      cmakeRegenerationResult,
                      providerCompileResult,
                      buildResult: BuildRunResult;
                      workspaceVcs: openArray[
                          workspaceVcsEvidence.WorkspaceVcsEvidence] = [];
                      targetResolutions:
                          openArray[TargetResolutionRecord] = []) =
  ## M4: ``workspaceVcs`` carries the unified Workspace-VCS evidence
  ## seq accumulated by ``repro workspace status`` / ``repro check``
  ## while invoking the M2/M3 query actions. Callers pass an empty seq
  ## (the default) when no query observations occurred during the
  ## reported build. The JSON view embedded under the
  ## ``"workspaceVcs"`` key is derived from the same record the SSZ
  ## codec persists; see ``libs/repro_workspace_vcs/src/evidence.nim``.
  ##
  ## Named-Targets M5: ``targetResolutions`` carries one record per
  ## user-supplied selector classified by the M2 resolver. Empty when
  ## no positional was supplied (the legacy default-action path). The
  ## per-selector ``kind`` field mirrors the CLI text diagnostics
  ## (``resolved`` / ``ambiguous`` / ``unknown``).
  var cmakeRegenerationActions = newJArray()
  for item in cmakeRegenerationResult.results:
    cmakeRegenerationActions.add(actionResultJson(item))
  var providerCompileActions = newJArray()
  for item in providerCompileResult.results:
    providerCompileActions.add(actionResultJson(item))
  var actions = newJArray()
  for item in buildResult.results:
    actions.add(actionResultJson(item))
  var trace = newJArray()
  for event in buildResult.trace:
    trace.add(%*{
      "seq": event.seq,
      "actionId": event.actionId,
      "event": event.event,
      "detail": event.detail
    })
  var targetResolutionArr = newJArray()
  for record in targetResolutions:
    targetResolutionArr.add(targetResolutionJson(record))
  let root = %*{
    "providerBinary": provider.outputBinaryPath,
    "providerFingerprint": digestHex(provider.providerFingerprint),
    "providerCompileOutput": provider.executionResult.output,
    "cmakeRegenerationActions": cmakeRegenerationActions,
    "providerCompileActions": providerCompileActions,
    "providerSnapshot": refresh.persistedSnapshotPath,
    "providerInvocations": refresh.invoked.len,
    "actions": actions,
    "trace": trace,
    "workspaceVcs": workspaceVcsEvidence.toJson(workspaceVcs),
    "targetResolution": targetResolutionArr,
    "stats": statsJson(buildResult.stats)
  }
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), $root)

proc hasFailedActions(buildResult: BuildRunResult): bool =
  for item in buildResult.results:
    if item.status in {asFailed, asBlocked}:
      return true

proc providerCompileBuildAction(plan: ProviderCompilePlan;
                                modulePath, interfacePath, artifactPath,
                                publicCliPath, workDir: string;
                                scratchDir = ""): BuildAction =
  var inputs = plan.inputSources
  if not inputs.contains(interfacePath):
    inputs.add(interfacePath)
  var command = @[
    publicCliPath,
    "__repro-compile-provider",
    "--module", modulePath,
    "--out", plan.outputBinaryPath,
    "--artifact", artifactPath,
    "--interface", interfacePath,
    "--work-dir", workDir
  ]
  if scratchDir.len > 0:
    command.add("--scratch-dir")
    command.add(scratchDir)
  action("__repro_provider_compile", command,
    cwd = workDir,
    inputs = inputs,
    outputs = @[plan.outputBinaryPath, artifactPath],
    commandStatsId = "repro provider compile edge",
    cacheable = true,
    weakFingerprint = plan.compileEdge.actionFingerprint,
    dependencyPolicy = declaredOnlyPolicy())

proc invalidateStaleProviderCompileArtifact(plan: ProviderCompilePlan;
                                            artifactPath: string) =
  if artifactPath.len == 0 or not fileExists(extendedPath(artifactPath)):
    return
  if providerCompileArtifactFresh(artifactPath, plan.outputBinaryPath,
      plan.interfaceFingerprint, plan.providerFingerprint):
    return
  removeFile(extendedPath(artifactPath))

proc providerCompileFailure(buildResult: BuildRunResult): string =
  for item in buildResult.results:
    if item.status in {asFailed, asBlocked}:
      var parts = @[item.id & " " & $item.status]
      if item.stderr.len > 0:
        parts.add(item.stderr)
      if item.stdout.len > 0:
        parts.add(item.stdout)
      return parts.join("\n")
  "provider compile failed"

proc readTextIfExists(path: string): string =
  if path.len == 0 or not fileExists(extendedPath(path)):
    return ""
  readFile(extendedPath(path))

proc runLoggedCommand(argv: openArray[string]; cwd: string): int =
  let command = shellCommand(argv)
  let res = execCmdEx(command, workingDir = cwd)
  if res.output.len > 0:
    stdout.write(res.output)
    stdout.flushFile()
  res.exitCode

proc removeManifestEntries(path: string) =
  if path.len == 0 or not fileExists(extendedPath(path)):
    return
  for rawLine in readFile(extendedPath(path)).splitLines():
    let filePath = rawLine.strip()
    if filePath.len > 0 and fileExists(extendedPath(filePath)):
      removeFile(extendedPath(filePath))

proc invalidateCmakeProviderDerivedState(meta: CmakeRegenerationMetadata) =
  if meta.providerRoot.len > 0:
    let pattern = meta.providerRoot / "worktrees" / "*" / "build" /
      "reprobuild" / "provider-graph" / "provider-fragments.rbsz"
    for fragment in walkFiles(extendedPath(pattern)):
      removeFile(extendedPath(fragment))
  for key, value in meta.values:
    if key == "clean_manifest" or key.startsWith("clean_manifest_"):
      removeManifestEntries(value)

proc runCmakeRegenerationHelper*(args: openArray[string]): int =
  var metadataFile = ""
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--metadata":
      if i + 1 >= args.len:
        raise newException(ValueError, "--metadata requires a value")
      metadataFile = args[i + 1]
      inc i, 2
    elif arg.startsWith("--metadata="):
      metadataFile = arg.split("=", maxsplit = 1)[1]
      inc i
    else:
      raise newException(ValueError,
        "unsupported __repro-cmake-regenerate argument: " & arg)
  if metadataFile.len == 0:
    raise newException(ValueError, "--metadata is required")

  let values = readKeyValueMetadata(metadataFile)
  if values.len == 0:
    raise newException(IOError,
      "CMake regeneration metadata is missing: " & metadataFile)
  let sourceDir = values.metadataValue("source_dir")
  let binaryDir = values.metadataValue("binary_dir", parentDir(parentDir(
    parentDir(metadataFile))))
  if sourceDir.len == 0 or binaryDir.len == 0:
    raise newException(ValueError,
      "CMake regeneration metadata requires source_dir and binary_dir")
  var meta = CmakeRegenerationMetadata(
    enabled: true,
    suppressed: values.metadataFlag("cmake_regeneration_suppressed"),
    metadataFile: metadataFile,
    sourceDir: os.normalizedPath(sourceDir),
    binaryDir: os.normalizedPath(binaryDir),
    providerRoot: os.normalizedPath(values.metadataValue("provider_root",
      binaryDir / "CMakeFiles" / "reprobuild")),
    cmakeCommand: values.metadataValue("cmake_command", "cmake"),
    checkFile: values.metadataValue("cmake_regeneration_check_file",
      "CMakeFiles/Makefile.cmake"),
    globVerifyScript: values.metadataValue("cmake_regeneration_glob_verify",
      binaryDir / "CMakeFiles" / "VerifyGlobs.cmake"),
    providerFile: values.metadataValue("cmake_regeneration_provider_file",
      binaryDir / "reprobuild.nim"),
    providerStateFile: values.metadataValue(
      "cmake_regeneration_provider_state",
      values.metadataValue("provider_root", binaryDir / "CMakeFiles" /
        "reprobuild") / "provider.last"),
    values: values)

  if meta.suppressed:
    echo "cmakeRegeneration: suppressed"
    return 0

  let providerBefore = readTextIfExists(meta.providerStateFile)
  if meta.globVerifyScript.len > 0 and fileExists(extendedPath(meta.globVerifyScript)):
    let verifyRet = runLoggedCommand(@[
      meta.cmakeCommand, "-P", meta.globVerifyScript
    ], meta.binaryDir)
    if verifyRet != 0:
      return verifyRet

  let regenRet = runLoggedCommand(@[
    meta.cmakeCommand,
    "-S", meta.sourceDir,
    "-B", meta.binaryDir,
    "--check-build-system", meta.checkFile,
    "0"
  ], meta.binaryDir)
  if regenRet != 0:
    return regenRet

  let providerAfter = readTextIfExists(meta.providerFile)
  if providerAfter.len == 0:
    raise newException(IOError,
      "CMake regeneration did not produce provider file: " &
        meta.providerFile)
  if providerBefore.len > 0 and providerBefore != providerAfter:
    invalidateCmakeProviderDerivedState(meta)
  createDir(extendedPath(parentDir(meta.providerStateFile)))
  writeFile(extendedPath(meta.providerStateFile), providerAfter)
  echo "cmakeRegeneration: complete providerChanged=" &
    $(providerBefore.len > 0 and providerBefore != providerAfter)
  0

proc identityPaths(outDir: string; mode: ToolProvisioningMode):
    tuple[identityPath: string; inspectionPath: string] =
  case mode
  of tpmNix:
    (identityPath: outDir / "nix-tool-identities.rbtp",
      inspectionPath: outDir / "nix-tool-identities.inspect.json")
  of tpmTarball:
    (identityPath: outDir / "tarball-tool-identities.rbtp",
      inspectionPath: outDir / "tarball-tool-identities.inspect.json")
  of tpmScoop:
    (identityPath: outDir / "scoop-tool-identities.rbtp",
      inspectionPath: outDir / "scoop-tool-identities.inspect.json")
  else:
    (identityPath: outDir / "path-only-tool-identities.rbtp",
      inspectionPath: outDir / "path-only-tool-identities.inspect.json")

proc modeName(mode: ToolProvisioningMode): string =
  case mode
  of tpmPathOnly: "path"
  of tpmNix: "nix"
  of tpmTarball: "tarball"
  of tpmScoop: "scoop"
  else: "unspecified"

proc addCacheField(payload: var string; value: string) =
  payload.add($value.len)
  payload.add(":")
  payload.add(value)
  payload.add("\n")

proc toolIdentityCacheKey(artifact: ProjectInterfaceArtifact;
                          mode: ToolProvisioningMode): string =
  var payload = ""
  payload.addCacheField("reprobuild.toolIdentityCache.v1")
  payload.addCacheField(mode.modeName)
  payload.addCacheField(artifact.projectInterface.projectName)
  payload.addCacheField(artifact.projectInterface.packageName)
  payload.addCacheField(digestHex(artifact.interfaceFingerprint))
  if mode == tpmPathOnly:
    payload.addCacheField(getEnv("PATH"))
  for useDef in artifact.projectInterface.toolUses:
    payload.addCacheField(useDef.rawConstraint)
    payload.addCacheField(useDef.packageSelector)
    payload.addCacheField(useDef.executableName)
    payload.addCacheField(useDef.policyPath.join("/"))
    for nix in useDef.nixProvisioning:
      payload.addCacheField(nix.selector)
      payload.addCacheField(nix.executablePath)
      payload.addCacheField(nix.expressionFile)
      payload.addCacheField(nix.packageId)
      payload.addCacheField(nix.lockIdentity)
    for tarball in useDef.tarballProvisioning:
      payload.addCacheField(tarball.url)
      payload.addCacheField(tarball.mirrors.join("\n"))
      payload.addCacheField(tarball.sha256)
      payload.addCacheField(tarball.archiveType)
      payload.addCacheField($tarball.stripComponents)
      payload.addCacheField(tarball.executablePath)
      payload.addCacheField(tarball.packageId)
      payload.addCacheField(tarball.lockIdentity)
    for scoop in useDef.scoopProvisioning:
      payload.addCacheField(scoop.bucket)
      payload.addCacheField(scoop.app)
      payload.addCacheField(scoop.version)
      payload.addCacheField(scoop.preferredVersion)
      payload.addCacheField(scoop.manifestChecksum)
      payload.addCacheField(scoop.manifestUrl)
      payload.addCacheField(scoop.executablePath)
      payload.addCacheField($scoop.requiresExecutionProfileChecksum)
      payload.addCacheField(scoop.packageId)
      payload.addCacheField(scoop.lockIdentity)
  digestHex(blake3DomainDigest(payload.bytesOf(), hdMetadataEnvelope))

proc toolIdentityRealizationsUsable(identity: PathOnlyBuildIdentity): bool =
  # The cache is usable when the artifacts the identity points at are
  # still on disk: realized store paths (for nix/tarball/scoop) and the
  # resolved executable itself. The ``pathSearchList`` is the snapshot of
  # ``$PATH`` at resolution time and is fingerprinted into the cache key
  # via ``toolIdentityCacheKey`` — PATH commonly carries entries for
  # directories that don't exist on the current host (e.g. Linux-style
  # ``~/.pixi/bin`` entries persisted in a shell rc and inherited on
  # macOS). Requiring every PATH entry to exist would invalidate the
  # cache on every build and force a fresh probe each time. Cache
  # invalidation when PATH itself changes is already handled by the
  # cache-key check.
  for profile in identity.profiles:
    for storePath in profile.realizedStorePaths:
      if storePath.len > 0 and not dirExists(extendedPath(storePath)):
        return false
    if profile.resolvedExecutablePath.len > 0 and
        not fileExists(extendedPath(profile.resolvedExecutablePath)):
      return false
  true

proc cachedToolIdentity(outDir: string; mode: ToolProvisioningMode;
                        artifact: ProjectInterfaceArtifact;
                        stableIdentityPath,
                        stableInspectionPath: string):
    tuple[hit: bool; identity: PathOnlyBuildIdentity] =
  let key = toolIdentityCacheKey(artifact, mode)
  let cacheDir = outDir / "tool-identity-cache"
  let cacheIdentityPath = cacheDir / (key & ".rbtp")
  let cacheInspectionPath = cacheDir / (key & ".inspect.json")
  let stableKeyPath = cacheDir / (mode.modeName & ".current-key")
  if fileExists(extendedPath(stableIdentityPath)) and fileExists(extendedPath(stableKeyPath)) and
      readFile(extendedPath(stableKeyPath)).strip() == key:
    try:
      let identity = readPathOnlyBuildIdentity(stableIdentityPath)
      if identity.interfaceFingerprint != artifact.interfaceFingerprint:
        return
      if not identity.toolIdentityRealizationsUsable():
        return
      if not fileExists(extendedPath(stableInspectionPath)):
        if fileExists(extendedPath(cacheInspectionPath)):
          createDir(extendedPath(parentDir(stableInspectionPath)))
          copyFile(extendedPath(cacheInspectionPath), extendedPath(stableInspectionPath))
        else:
          writeInspectionJson(stableInspectionPath, identity)
      return (hit: true, identity: identity)
    except CatchableError:
      discard
  if not fileExists(extendedPath(cacheIdentityPath)):
    return
  try:
    let identity = readPathOnlyBuildIdentity(cacheIdentityPath)
    if identity.interfaceFingerprint != artifact.interfaceFingerprint:
      return
    if not identity.toolIdentityRealizationsUsable():
      return
    writePathOnlyBuildIdentity(stableIdentityPath, identity)
    if fileExists(extendedPath(cacheInspectionPath)):
      createDir(extendedPath(parentDir(stableInspectionPath)))
      copyFile(extendedPath(cacheInspectionPath), extendedPath(stableInspectionPath))
    else:
      writeInspectionJson(stableInspectionPath, identity)
    createDir(extendedPath(cacheDir))
    writeFile(extendedPath(stableKeyPath), key & "\n")
    return (hit: true, identity: identity)
  except CatchableError:
    return (hit: false, identity: PathOnlyBuildIdentity())

proc writeToolIdentityCache(outDir: string; mode: ToolProvisioningMode;
                            artifact: ProjectInterfaceArtifact;
                            identity: PathOnlyBuildIdentity) =
  let key = toolIdentityCacheKey(artifact, mode)
  let cacheDir = outDir / "tool-identity-cache"
  writePathOnlyBuildIdentity(cacheDir / (key & ".rbtp"), identity)
  writeInspectionJson(cacheDir / (key & ".inspect.json"), identity)

proc providerSnapshotInputsFresh(snapshot: ProviderGraphSnapshot): bool =
  if snapshot.fragments.len == 0:
    return false
  for fragment in snapshot.fragments:
    for input in fragment.evaluationInputs:
      case input.kind
      of gevFileRead:
        if fileContentDigest(input.identity) != input.digest:
          return false
      of gevDirectoryEnumeration:
        if directoryMemberNames(input.identity) != input.directoryMembers:
          return false
      else:
        return false
  true

proc readFreshProviderGraphSnapshot(storeRoot, providerArtifactId: string):
    Option[ProviderGraphSnapshot] =
  if not fileExists(extendedPath(providerSnapshotPath(storeRoot))):
    return none(ProviderGraphSnapshot)
  try:
    let snapshot = loadProviderGraphSnapshot(storeRoot)
    if snapshot.providerArtifactId != providerArtifactId:
      return none(ProviderGraphSnapshot)
    if not providerSnapshotInputsFresh(snapshot):
      return none(ProviderGraphSnapshot)
    return some(snapshot)
  except CatchableError:
    return none(ProviderGraphSnapshot)

proc warmReadFreshProviderGraphSnapshot(storeRoot, providerArtifactId: string):
    Option[ProviderGraphSnapshot] =
  let path = providerSnapshotPath(storeRoot)
  let key = storeRoot & "\0" & providerArtifactId
  if warmProviderSnapshots.hasKey(key):
    let warm = warmProviderSnapshots[key]
    if warm.providerArtifactId == providerArtifactId and
        evidenceFresh(path, warm.snapshotEvidence) and
        warm.snapshot.providerArtifactId == providerArtifactId and
        providerSnapshotInputsFresh(warm.snapshot):
      return some(warm.snapshot)
  result = readFreshProviderGraphSnapshot(storeRoot, providerArtifactId)
  if result.isSome:
    warmProviderSnapshots[key] = WarmProviderSnapshot(
      providerArtifactId: providerArtifactId,
      snapshotPath: path,
      snapshotEvidence: durableFileEvidence(path),
      snapshot: result.get())

proc loweredGraphCacheKey(artifact: ProjectInterfaceArtifact;
                          mode: ToolProvisioningMode;
                          providerArtifactId, providerSnapshotPath,
                          pathEnv: string): string =
  var payload = ""
  payload.addCacheField(LoweredGraphAlgorithmVersion)
  payload.addCacheField(mode.modeName)
  payload.addCacheField(artifact.projectInterface.projectName)
  payload.addCacheField(artifact.projectInterface.packageName)
  payload.addCacheField(digestHex(artifact.interfaceFingerprint))
  payload.addCacheField(toolIdentityCacheKey(artifact, mode))
  payload.addCacheField(providerArtifactId)
  if fileExists(extendedPath(providerSnapshotPath)):
    payload.addCacheField(fileContentDigest(providerSnapshotPath))
  else:
    payload.addCacheField("")
  if mode == tpmPathOnly:
    payload.addCacheField(pathEnv)
  digestHex(blake3DomainDigest(payload.bytesOf(), hdMetadataEnvelope))

proc resolveAndWriteIdentity(artifact: ProjectInterfaceArtifact;
                             outDir: string;
                             mode: ToolProvisioningMode):
    tuple[identity: PathOnlyBuildIdentity; identityPath: string;
      inspectionPath: string] =
  let paths = identityPaths(outDir, mode)
  let cached = cachedToolIdentity(outDir, mode, artifact,
    paths.identityPath, paths.inspectionPath)
  if cached.hit:
    return (identity: cached.identity, identityPath: paths.identityPath,
      inspectionPath: paths.inspectionPath)
  let identity = toolBuildIdentity(artifact, mode,
    storeRoot = outDir / "tool-store")
  writePathOnlyBuildIdentity(paths.identityPath, identity)
  writeInspectionJson(paths.inspectionPath, identity)
  writeToolIdentityCache(outDir, mode, artifact, identity)
  createDir(extendedPath(outDir / "tool-identity-cache"))
  writeFile(extendedPath(outDir / "tool-identity-cache" / (mode.modeName & ".current-key")),
    toolIdentityCacheKey(artifact, mode) & "\n")
  (identity: identity, identityPath: paths.identityPath,
    inspectionPath: paths.inspectionPath)

proc warmResolveAndWriteIdentity(artifact: ProjectInterfaceArtifact;
                                 outDir: string;
                                 mode: ToolProvisioningMode):
    tuple[identity: PathOnlyBuildIdentity; identityPath: string;
      inspectionPath: string] =
  let key = toolIdentityCacheKey(artifact, mode)
  let paths = identityPaths(outDir, mode)
  let tableKey = outDir & "\0" & mode.modeName & "\0" & key
  let stableKeyPath = outDir / "tool-identity-cache" /
    (mode.modeName & ".current-key")
  if warmToolIdentities.hasKey(tableKey):
    let warm = warmToolIdentities[tableKey]
    if warm.key == key and warm.identity.interfaceFingerprint ==
        artifact.interfaceFingerprint and
        evidenceFresh(warm.identityPath, warm.identityEvidence) and
        evidenceFresh(stableKeyPath, warm.keyEvidence) and
        warm.identity.toolIdentityRealizationsUsable():
      return (identity: warm.identity, identityPath: warm.identityPath,
        inspectionPath: warm.inspectionPath)
  result = resolveAndWriteIdentity(artifact, outDir, mode)
  warmToolIdentities[tableKey] = WarmToolIdentity(key: key,
    identityPath: result.identityPath, inspectionPath: result.inspectionPath,
    identityEvidence: durableFileEvidence(result.identityPath),
    keyEvidence: durableFileEvidence(stableKeyPath), identity: result.identity)

proc runQuotaSocketDiagnostic(): string =
  let socket = getEnv("RUNQUOTA_SOCKET", "")
  if socket.len > 0:
    socket
  else:
    "default"

proc buildMaxParallelism(): uint32 =
  let configured = getEnv("REPROBUILD_MAX_PARALLELISM", "")
  if configured.len == 0:
    return 8'u32
  try:
    let parsed = parseInt(configured)
    if parsed < 1:
      return 1'u32
    uint32(parsed)
  except ValueError:
    raise newException(ValueError,
      "REPROBUILD_MAX_PARALLELISM must be a positive integer")

proc stablePublicCliPath(): string =
  let app = getAppFilename()
  if app.isAbsolute:
    return os.normalizedPath(app)
  if app.contains(DirSep) or app.contains(AltSep):
    return os.normalizedPath(getCurrentDir() / app)
  let resolved = findExe(app)
  if resolved.len > 0:
    if resolved.isAbsolute:
      return os.normalizedPath(resolved)
    return os.normalizedPath(getCurrentDir() / resolved)
  os.normalizedPath(getCurrentDir() / app)

# Executable-Consolidation M1: the internal filesystem-monitor shim is no
# longer a standalone ``repro-fs-snoop`` binary. ``repro`` self-spawns its own
# image with this subcommand selector (``repro internal fs-snoop …``). The
# executable path is ``getAppFilename()`` (more robust than argv[0]/sibling
# lookup) and the selector below is prepended by the build engine via
# ``BuildEngineConfig.monitorCliArgs``.
const internalFsSnoopArgs* = @["internal", "fs-snoop"]

proc selfSpawnFsSnoopPath(): string =
  ## Path to the running ``repro`` image used to self-spawn the internal
  ## fs-snoop role. Replaces the former ``siblingFsSnoopPath`` /
  ## ``repro-fs-snoop`` sibling-binary lookup.
  os.normalizedPath(getAppFilename())

proc siblingTryCompileProviderPath(publicCliPath: string): string =
  ## Pre-built Tier 2a direct provider binary, normally shipped next to
  ## the repro CLI by ``scripts/build_apps.sh``. Empty string means the
  ## direct provider is unavailable on this install — callers must fall
  ## back to per-project provider compile.
  let candidate = parentDir(publicCliPath) /
    addFileExt("repro-cmake-trycompile-provider", ExeExt)
  if fileExists(extendedPath(candidate)):
    os.normalizedPath(candidate)
  else:
    ""

proc siblingStandardProviderPath(publicCliPath: string): string =
  ## Pre-built Tier 2b standard-provider binary, normally shipped next
  ## to the repro CLI by ``scripts/build_apps.sh``. Empty string means
  ## the standard provider is unavailable on this install — callers
  ## must fall back to per-project provider compile and surface a
  ## warning. See ``Provider-Compile-Tiering.md`` §"2b — repro-standard-
  ## provider".
  let candidate = parentDir(publicCliPath) /
    addFileExt("repro-standard-provider", ExeExt)
  if fileExists(extendedPath(candidate)):
    os.normalizedPath(candidate)
  else:
    ""

type
  BuildProgressMode = enum
    bpmQuiet
    bpmLine
    bpmBarLine
    bpmLines
    bpmLinesBar
    bpmDots

  BuildProgressBarStyle* = enum
    bpbsOverlay
    bpbsSplit

  BuildStatsMode = enum
    bsmNone
    bsmText

  BuildReportMode = enum
    brmFull
    brmNone

  BuildLogMode = enum
    blmActions
    blmSummary
    blmQuiet

  BuildDaemonMode = enum
    bdmAuto
    bdmRequire
    bdmOff

  DaemonBuildUnsupported = object of CatchableError

  BuildProgressRenderer = object
    enabled: bool
    mode: BuildProgressMode
    barStyle: BuildProgressBarStyle
    ansi: bool
    color: bool
    nativeProgress: bool
    lastLen: int

  BuildCommandOutcome = object
    exitCode: int
    modulePath: string
    projectRoot: string
    outDir: string
    buildReportPath: string

  BuildCommandEventSink = proc(kind, message, payloadJson: string)
  WatchCommandEventSink = proc(kind, message, payloadJson: string;
                               terminal: bool; exitCode: int;
                               watchedPaths: seq[string]; lastResult: string)

proc writeBuildBenchmark(path: string; outcome: BuildCommandOutcome;
                         stats: BuildStats; modeName, fastPath: string;
                         executedActions: int;
                         daemonConnectionUs = 0.0) =
  if path.len == 0:
    return
  let graphReadinessUs = stats.metricBucketUs([
    "repro interface extract",
    "repro tool identity resolve",
    "repro provider compile",
    "repro provider graph refresh",
    "repro lowered graph cache read",
    "repro graph lower",
    "repro lowered graph cache write",
    "repro graph infer deps",
    "repro graph validate",
    "repro cmake regeneration",
    "repro cmake state check"])
  let invalidationChecksUs = stats.metricBucketUs([
    "repro output stat",
    "repro fast noop scan",
    "repro hot input scan",
    "repro hot index navigator scan"])
  let cacheChecksUs = stats.metricBucketUs([
    "repro cas open",
    "repro action cache open",
    "repro cache lookup",
    "repro hot record lookup",
    "repro cache hit result materialize",
    "repro cache restore",
    "repro cache record"])
  let node = %*{
    "schemaId": "reprobuild.build.benchmark.v1",
    "mode": modeName,
    "fastPath": fastPath,
    "modulePath": outcome.modulePath,
    "projectRoot": outcome.projectRoot,
    "outDir": outcome.outDir,
    "exitCode": outcome.exitCode,
    "phases": {
      "daemonConnectionUs": daemonConnectionUs,
      "graphReadinessUs": graphReadinessUs,
      "invalidationChecksUs": invalidationChecksUs,
      "cacheChecksUs": cacheChecksUs,
      "executedActions": executedActions
    },
    "metrics": benchmarkMetricsJson(stats)
  }
  let dir = parentDir(path)
  if dir.len > 0:
    createDir(extendedPath(dir))
  writeFile(extendedPath(path), $node)

proc updateBenchmarkDaemonConnection(path: string; daemonConnectionUs: float) =
  if path.len == 0 or not fileExists(extendedPath(path)):
    return
  try:
    let node = parseFile(extendedPath(path))
    if not node.hasKey("phases") or node["phases"].kind != JObject:
      node["phases"] = newJObject()
    node["mode"] = %"daemon"
    node["phases"]["daemonConnectionUs"] = %daemonConnectionUs
    writeFile(extendedPath(path), $node)
  except CatchableError:
    discard

proc parseBuildProgressMode(value: string): BuildProgressMode =
  case value.toLowerAscii()
  of "quiet", "silent", "none", "off":
    bpmQuiet
  of "line", "ninja", "single-line":
    bpmLine
  of "bar-line", "bar", "ninja-bar", "auto", "plain":
    bpmBarLine
  of "lines", "tup", "per-line":
    bpmLines
  of "lines-bar", "tup-bar", "per-line-bar":
    bpmLinesBar
  of "dots", "dot":
    bpmDots
  else:
    raise newException(ValueError,
      "unsupported --progress=" & value &
        " (expected quiet, line, bar-line, lines, lines-bar, or dots)")

proc configuredBuildProgressMode(): BuildProgressMode =
  let configured = getEnv("REPROBUILD_PROGRESS", "")
  if configured.len == 0:
    return bpmBarLine
  parseBuildProgressMode(configured)

proc parseBuildProgressBarStyle(value: string): BuildProgressBarStyle =
  case value.toLowerAscii()
  of "overlay", "overlaid", "single", "combined":
    bpbsOverlay
  of "split", "two", "two-bars", "separate":
    bpbsSplit
  else:
    raise newException(ValueError,
      "unsupported --progress-bars=" & value &
        " (expected overlay or split)")

proc configuredBuildProgressBarStyle(): BuildProgressBarStyle =
  let configured = getEnv("REPROBUILD_PROGRESS_BARS", "")
  if configured.len == 0:
    return bpbsOverlay
  parseBuildProgressBarStyle(configured)

proc parseBuildStatsMode(value: string): BuildStatsMode =
  case value.toLowerAscii()
  of "1", "true", "yes", "on", "text", "stats":
    bsmText
  of "0", "false", "no", "off", "none":
    bsmNone
  else:
    raise newException(ValueError,
      "unsupported --stats=" & value & " (expected text or none)")

proc configuredBuildStatsMode(): BuildStatsMode =
  let configured = getEnv("REPROBUILD_STATS", "")
  if configured.len == 0:
    return bsmNone
  parseBuildStatsMode(configured)

proc parseBuildReportMode(value: string): BuildReportMode =
  case value.toLowerAscii()
  of "1", "true", "yes", "on", "full":
    brmFull
  of "0", "false", "no", "off", "none":
    brmNone
  else:
    raise newException(ValueError,
      "unsupported --report=" & value & " (expected full or none)")

proc configuredBuildReportMode(): BuildReportMode =
  let configured = getEnv("REPROBUILD_REPORT", "")
  if configured.len == 0:
    return brmFull
  parseBuildReportMode(configured)

proc parseBuildLogMode(value: string): BuildLogMode =
  case value.toLowerAscii()
  of "actions", "verbose":
    blmActions
  of "summary", "normal":
    blmSummary
  of "quiet", "none", "off":
    blmQuiet
  else:
    raise newException(ValueError,
      "unsupported --log=" & value & " (expected actions, summary, or quiet)")

proc configuredBuildLogMode(): BuildLogMode =
  let configured = getEnv("REPROBUILD_LOG", "")
  if configured.len == 0:
    return blmQuiet
  parseBuildLogMode(configured)

proc parseBuildDaemonMode(value, source: string): BuildDaemonMode =
  case value.normalize
  of "auto":
    bdmAuto
  of "require":
    bdmRequire
  of "off":
    bdmOff
  else:
    raise newException(ValueError,
      "unsupported " & source & "=" & value &
        " (expected auto, require, or off)")

proc configuredBuildDaemonMode(): BuildDaemonMode =
  let configured = getEnv("REPRO_DAEMON", "")
  if configured.len == 0:
    return bdmAuto
  parseBuildDaemonMode(configured, "REPRO_DAEMON")

proc supportsAnsiProgress(): bool =
  isatty(stderr) and getEnv("NO_COLOR", "").len == 0 and
    getEnv("TERM", "") != "dumb"

proc colorProgressEnabled(): bool =
  let configured = getEnv("REPROBUILD_COLOR", "auto").normalize
  case configured
  of "0", "false", "no", "off", "never":
    return false
  of "1", "true", "yes", "on", "always":
    return true
  else:
    if getEnv("NO_COLOR", "").len > 0:
      return false
    return supportsAnsiProgress()

proc nativeTerminalProgressEnabled(): bool =
  let configured = getEnv("REPROBUILD_TERMINAL_PROGRESS", "auto").normalize
  case configured
  of "0", "false", "no", "off", "never":
    return false
  of "1", "true", "yes", "on", "always":
    return supportsAnsiProgress()
  else:
    if not supportsAnsiProgress():
      return false
    if getEnv("WT_SESSION", "").len > 0 or
        getEnv("KONSOLE_VERSION", "").len > 0 or
        getEnv("WEZTERM_PANE", "").len > 0 or
        getEnv("ConEmuPID", "").len > 0 or
        getEnv("MINTTY_SHORTCUT", "").len > 0:
      return true
    let termProgram = getEnv("TERM_PROGRAM", "").toLowerAscii()
    termProgram in ["iterm.app", "wezterm", "ghostty"]

proc newBuildProgressRenderer(mode: BuildProgressMode;
                              barStyle: BuildProgressBarStyle):
    BuildProgressRenderer =
  BuildProgressRenderer(
    enabled: mode != bpmQuiet,
    mode: mode,
    barStyle: barStyle,
    ansi: supportsAnsiProgress(),
    color: colorProgressEnabled(),
    nativeProgress: nativeTerminalProgressEnabled(),
    lastLen: 0)

proc ansi(code, text: string): string =
  "\27[" & code & "m" & text & "\27[0m"

proc isUtf8Continuation(ch: char): bool =
  (ord(ch) and 0xC0) == 0x80

proc utf8CharLen(text: string; index: int): int =
  if index >= text.len:
    return 0
  let b = ord(text[index])
  result =
    if (b and 0x80) == 0x00: 1
    elif (b and 0xE0) == 0xC0: 2
    elif (b and 0xF0) == 0xE0: 3
    elif (b and 0xF8) == 0xF0: 4
    else: 1
  result = min(result, text.len - index)

proc visibleLen(text: string): int =
  var i = 0
  while i < text.len:
    if text[i] == '\27' and i + 1 < text.len and text[i + 1] == '[':
      i.inc(2)
      while i < text.len and not (text[i] in {'A' .. 'Z', 'a' .. 'z'}):
        i.inc
      if i < text.len:
        i.inc
    else:
      if not isUtf8Continuation(text[i]):
        result.inc
      i.inc

proc takeVisiblePrefix(text: string; width: int): string =
  var
    i = 0
    visible = 0
    inAnsi = false
  while i < text.len and (visible < width or inAnsi):
    if text[i] == '\27' and i + 1 < text.len and text[i + 1] == '[':
      result.add(text[i])
      inAnsi = true
      i.inc
    elif inAnsi and text[i] in {'A' .. 'Z', 'a' .. 'z'}:
      result.add(text[i])
      inAnsi = false
      i.inc
    elif inAnsi:
      result.add(text[i])
      i.inc
    elif not isUtf8Continuation(text[i]):
      let charLen = utf8CharLen(text, i)
      result.add(text[i ..< i + charLen])
      visible.inc
      i.inc(charLen)
    else:
      i.inc
  if result.contains("\27["):
    result.add("\27[0m")

proc progressCell(glyph, colorCode: string; color: bool): string =
  if color: ansi(colorCode, glyph) else: glyph

proc progressBar(completed, total, width: int; color = false;
                 filledColor = "38;5;42"; emptyColor = "38;5;240";
                 filledGlyph = "#"; emptyGlyph = "."): string =
  let safeWidth = max(width, 1)
  let clampedCompleted =
    if total <= 0:
      0
    else:
      min(max(completed, 0), total)
  let filled =
    if total <= 0:
      0
    else:
      min(safeWidth, (clampedCompleted * safeWidth) div total)
  let
    openBracket = if color: ansi("38;5;244", "[") else: "["
    closeBracket = if color: ansi("38;5;244", "]") else: "]"
    filledCell = progressCell(filledGlyph, filledColor, color)
    emptyCell = progressCell(emptyGlyph, emptyColor, color)
  result = openBracket
  for i in 0 ..< safeWidth:
    result.add(if i < filled: filledCell else: emptyCell)
  result.add(closeBracket)

proc fitProgressLine(line: string; width: int): string =
  if width <= 0 or line.visibleLen <= width:
    return line
  if width <= 3:
    return line.takeVisiblePrefix(width)
  line.takeVisiblePrefix(width - 3) & "..."

proc statusLabel(event: BuildProgressEvent): string =
  case event.kind
  of bpkActionStarted:
    "started"
  of bpkActionCompleted:
    case event.status
    of asSucceeded:
      if event.launched: "executed" else: "succeeded"
    of asCacheHit:
      "cache-hit"
    of asUpToDate:
      "up-to-date"
    of asFailed:
      "failed"
    of asBlocked:
      "blocked"
    else:
      $event.status

proc buildProgressPercent(event: BuildProgressEvent): int =
  if event.total <= 0:
    100
  else:
    let checked =
      if event.checked > 0 or event.completed == 0: event.checked
      else: event.completed
    min(100, (max(checked, 0) * 100) div event.total)

proc countWidth(total: int): int =
  max(1, ($max(total, 0)).len)

proc checkedCount(event: BuildProgressEvent): int =
  if event.checked > 0 or event.completed == 0: event.checked
  else: event.completed

proc settledCount(event: BuildProgressEvent): int =
  if event.settled > 0 or event.completed == 0: event.settled
  else: event.completed

proc checkedCounter(event: BuildProgressEvent): string =
  let width = countWidth(event.total)
  "checked=" & align($checkedCount(event), width) & "/" &
    align($event.total, width)

proc builtCounter(event: BuildProgressEvent): string =
  let width = countWidth(event.plannedExecutions)
  "built=" & align($event.completedExecutions, width) & "/" &
    align($event.plannedExecutions, width)

proc buildProgressCounters(event: BuildProgressEvent): string =
  result = checkedCounter(event)
  if event.executionPlanKnown and event.plannedExecutions > 0:
    result.add(" " & builtCounter(event))
  elif event.plannedExecutions > 0 or event.running > 0:
    result.add(" settled=" & align($settledCount(event), countWidth(event.total)) &
      "/" & align($event.total, countWidth(event.total)))

proc buildProgressOverlayBar(event: BuildProgressEvent; width: int;
                             color = false): string =
  let checked =
    if event.checked > 0 or event.completed == 0: event.checked
    else: event.completed
  let settled =
    if event.settled > 0 or event.completed == 0: event.settled
    else: event.completed
  let safeWidth = max(width, 1)
  let executionScale = event.executionPlanKnown and
    event.plannedExecutions > 0 and settled < event.total
  let
    checkedFilled =
      if event.total <= 0: 0
      else: min(safeWidth, (max(checked, 0) * safeWidth) div event.total)
    settledFilled =
      if event.total <= 0: 0
      else: min(safeWidth, (max(settled, 0) * safeWidth) div event.total)
    executedFilled =
      if event.plannedExecutions <= 0: 0
      else: min(safeWidth,
        (max(event.completedExecutions, 0) * safeWidth) div
          event.plannedExecutions)
  let
    openBracket = if color: ansi("38;5;244", "▕") else: "["
    closeBracket = if color: ansi("38;5;244", "▏") else: "]"
    settledGlyph = if color: "█" else: "#"
    checkedGlyph = if color: "▓" else: "+"
    executeGlyph = if color: "█" else: "#"
    emptyGlyph = if color: "░" else: "."
  result = openBracket
  for i in 0 ..< safeWidth:
    if executionScale:
      if i < executedFilled:
        result.add(progressCell(executeGlyph, "38;5;213", color))
      else:
        result.add(progressCell(emptyGlyph, "38;5;240", color))
    elif i < settledFilled:
      result.add(progressCell(settledGlyph, "38;5;39", color))
    elif i < checkedFilled:
      result.add(progressCell(checkedGlyph, "38;5;42", color))
    else:
      result.add(progressCell(emptyGlyph, "38;5;240", color))
  result.add(closeBracket)

proc buildProgressSplitBars(event: BuildProgressEvent; width: int;
                            color = false): string =
  let checked =
    if event.checked > 0 or event.completed == 0: event.checked
    else: event.completed
  let checkWidth =
    if event.plannedExecutions > 0 or event.running > 0:
      max(8, (width * 3) div 5)
    else:
      max(width, 1)
  let execWidth = max(6, width - checkWidth)
  result = progressBar(checked, event.total, checkWidth, color,
    filledColor = "38;5;42", filledGlyph = if color: "█" else: "#",
    emptyGlyph = if color: "░" else: ".")
  if event.plannedExecutions > 0 or event.running > 0:
    result.add(" exec")
    result.add(progressBar(event.completedExecutions, event.plannedExecutions,
      execWidth, color, filledColor = "38;5;213",
      filledGlyph = if color: "█" else: "#",
      emptyGlyph = if color: "░" else: "."))

proc buildProgressBarsWithCounters(event: BuildProgressEvent; width: int;
                                   color = false;
                                   barStyle = bpbsOverlay): string =
  let hasExecBar = barStyle == bpbsSplit and
    (event.plannedExecutions > 0 or event.running > 0)
  let checkedText = checkedCounter(event)
  let builtText =
    if hasExecBar:
      " " & builtCounter(event)
    else:
      ""
  let checkWidth =
    if hasExecBar:
      max(8, (width * 3) div 5)
    else:
      max(width, 1)
  let execWidth = max(6, width - checkWidth)
  case barStyle
  of bpbsOverlay:
    result = buildProgressOverlayBar(event, width, color) & " " & checkedText
    if event.executionPlanKnown and event.plannedExecutions > 0:
      result.add(" " & builtCounter(event))
  of bpbsSplit:
    result = progressBar(checkedCount(event), event.total, checkWidth, color,
      filledColor = "38;5;42", filledGlyph = if color: "█" else: "#",
      emptyGlyph = if color: "░" else: ".") & " " & checkedText
    if hasExecBar:
      result.add(" ")
      result.add(progressBar(event.completedExecutions, event.plannedExecutions,
        execWidth, color, filledColor = "38;5;213",
        filledGlyph = if color: "█" else: "#",
        emptyGlyph = if color: "░" else: "."))
      result.add(builtText)

proc buildProgressBars(event: BuildProgressEvent; width: int;
                       color = false;
                       barStyle = bpbsOverlay): string =
  case barStyle
  of bpbsOverlay:
    buildProgressOverlayBar(event, width, color)
  of bpbsSplit:
    buildProgressSplitBars(event, width, color)

proc buildProgressInvocation(event: BuildProgressEvent): string =
  let invocation =
    if event.currentCommand.len > 0:
      event.currentCommand
    elif event.kind == bpkActionCompleted and not event.launched:
      event.actionId
    elif event.command.len > 0:
      event.command
    else:
      event.actionId
  var singleLine = invocation
  for i in 0 ..< singleLine.len:
    if singleLine[i] in {'\r', '\n', '\t'}:
      singleLine[i] = ' '
  while singleLine.contains("  "):
    singleLine = singleLine.replace("  ", " ")
  if event.currentCommand.len > 0:
    singleLine.strip()
  else:
    statusLabel(event) & " " & singleLine.strip()

proc nativeProgressPercent(event: BuildProgressEvent): int =
  let executionScale = event.executionPlanKnown and
    event.plannedExecutions > 0 and event.settled < event.total
  if executionScale:
    if event.plannedExecutions <= 0: 100
    else:
      min(100, (max(event.completedExecutions, 0) * 100) div
        event.plannedExecutions)
  elif event.total <= 0:
    100
  else:
    let checked =
      if event.checked > 0 or event.completed == 0: event.checked
      else: event.completed
    min(100, (max(checked, 0) * 100) div event.total)

proc writeNativeProgress(renderer: BuildProgressRenderer;
                         event: BuildProgressEvent) =
  if not renderer.nativeProgress:
    return
  let state =
    if event.status == asFailed: 2
    elif event.running > 0 or event.ready > 0 or event.checked < event.total: 1
    else: 1
  stderr.write("\27]9;4;" & $state & ";" & $nativeProgressPercent(event) & "\7")

proc clearNativeProgress(renderer: BuildProgressRenderer) =
  if renderer.nativeProgress:
    stderr.write("\27]9;4;0\7")

proc formatBuildProgressLine*(event: BuildProgressEvent; width = 80;
                              includeBar = true; barWidth = 20;
                              color = false;
                              barStyle = bpbsOverlay): string =
  let prefix =
    if includeBar:
      buildProgressBarsWithCounters(event, barWidth, color, barStyle)
    else:
      buildProgressCounters(event)
  let counters = " running=" & $event.running
  let tail = " " & buildProgressInvocation(event)
  fitProgressLine(prefix & counters & tail, max(width, 20))

proc formatBuildProgressBarLine(event: BuildProgressEvent; width: int;
                                color = false;
                                barStyle = bpbsOverlay): string =
  let suffix = " running=" & $event.running
  let barWidth = max(10, width - suffix.len - 2)
  fitProgressLine(buildProgressBarsWithCounters(event, barWidth, color,
    barStyle) & suffix, max(width, 20))

proc progressLineWidth(): int =
  min(max(terminalWidth(), 40), 160)

proc clearProgressLine(renderer: BuildProgressRenderer) =
  if renderer.ansi:
    stderr.write("\r\27[2K")
  else:
    stderr.write("\r")

proc writeRedrawnProgress(renderer: var BuildProgressRenderer; line: string) =
  renderer.clearProgressLine()
  var outLine = line
  if not renderer.ansi and outLine.len < renderer.lastLen:
    outLine.add(repeat(' ', renderer.lastLen - outLine.len))
  stderr.write(outLine)
  stderr.flushFile()
  renderer.lastLen = line.len

proc renderPhase(renderer: var BuildProgressRenderer; phase: string) =
  if not renderer.enabled:
    return
  renderer.writeRedrawnProgress(fitProgressLine(phase, progressLineWidth()))

proc shouldEmitProgressUnit(event: BuildProgressEvent): bool =
  event.kind == bpkActionCompleted

proc renderProgress(renderer: var BuildProgressRenderer; event: BuildProgressEvent) =
  if not renderer.enabled:
    return
  renderer.writeNativeProgress(event)
  let width = progressLineWidth()
  case renderer.mode
  of bpmQuiet:
    discard
  of bpmLine:
    renderer.writeRedrawnProgress(formatBuildProgressLine(event, width,
      includeBar = false))
  of bpmBarLine:
    renderer.writeRedrawnProgress(formatBuildProgressLine(event, width,
      includeBar = true, barWidth = 24, color = renderer.color,
      barStyle = renderer.barStyle))
  of bpmLines:
    stderr.writeLine(formatBuildProgressLine(event, width, includeBar = false))
    stderr.flushFile()
    renderer.lastLen = 0
  of bpmLinesBar:
    renderer.clearProgressLine()
    stderr.writeLine(formatBuildProgressLine(event, width, includeBar = false))
    renderer.writeRedrawnProgress(formatBuildProgressBarLine(event, width,
      color = renderer.color, barStyle = renderer.barStyle))
  of bpmDots:
    if shouldEmitProgressUnit(event):
      stderr.write(".")
      stderr.flushFile()
      renderer.lastLen.inc

proc finishProgress(renderer: var BuildProgressRenderer) =
  renderer.clearNativeProgress()
  if renderer.enabled and renderer.lastLen > 0:
    stderr.write("\n")
    stderr.flushFile()
    renderer.lastLen = 0

proc tryRenderDaemonProgress(renderer: var BuildProgressRenderer;
                             payloadJson: string): bool =
  ## Re-render a daemon-forwarded progress event through the CLIENT's own
  ## `BuildProgressRenderer` so `--progress` is honored in daemon-hosted mode.
  ## The daemon emits each `BuildProgressEvent` as a `bekDiagnostic` whose
  ## payload carries the structured fields (tagged `"event":"progress"`);
  ## without this the client would print the raw `progress: <kind> <id>`
  ## message verbatim and ignore the requested progress mode. Returns true
  ## (and renders) when `payloadJson` is a progress event.
  if payloadJson.len == 0:
    return false
  var node: JsonNode
  try:
    node = parseJson(payloadJson)
  except CatchableError:
    return false
  if node.kind != JObject or node{"event"}.getStr != "progress":
    return false
  var event: BuildProgressEvent
  try:
    event.kind = parseEnum[BuildProgressKind](node{"kind"}.getStr)
    if node{"status"}.getStr.len > 0:
      event.status = parseEnum[ActionStatus](node{"status"}.getStr)
  except ValueError:
    return false
  event.actionId = node{"actionId"}.getStr
  event.total = node{"total"}.getInt
  event.completed = node{"completed"}.getInt
  event.checked = node{"checked"}.getInt
  event.running = node{"running"}.getInt
  event.ready = node{"ready"}.getInt
  renderer.renderProgress(event)
  true

proc emitFailedActionSummaries(buildResult: BuildRunResult;
                               eventSink: BuildCommandEventSink;
                               renderer: var BuildProgressRenderer) =
  ## Surface each failed action's id, exit code, and stderr to the terminal.
  ## Otherwise the only failure signal is a non-zero exit code (and, over the
  ## daemon protocol, the generic "daemon-hosted build failed" line), which
  ## forces the user to open build-report.json to learn what actually broke.
  for item in buildResult.results:
    if item.status != asFailed:
      continue
    var summary = "repro build: action failed: " & item.id &
      " (exit code " & $item.exitCode & ")"
    if item.stderr.len > 0:
      summary.add('\n')
      summary.add(strip(item.stderr, leading = false))
    if eventSink != nil:
      # The client routes ``"stream":"stderr"`` diagnostics to its stderr.
      eventSink("diagnostic", summary, "{\"stream\":\"stderr\"}")
    else:
      renderer.clearProgressLine()
      stderr.writeLine(summary)
      stderr.flushFile()

proc statStart(enabled: bool): float =
  if enabled:
    epochTime()
  else:
    0.0

proc finishStat(stats: var BuildStats; enabled: bool; name: string;
                started: float) =
  if enabled:
    stats.addMetric(name, (epochTime() - started) * 1_000_000.0)

proc addCounterMetric(stats: var BuildStats; enabled: bool; name: string;
                      count: int) =
  if not enabled:
    return
  for _ in 0 ..< count:
    stats.addMetric(name, 0.0)

proc recordInterfaceArtifactWarmStats(stats: var BuildStats; enabled: bool) =
  let warmStats = consumeInterfaceArtifactWarmStats()
  stats.addCounterMetric(enabled, "repro interface metadata cold read",
    warmStats.metadataColdReads)
  stats.addCounterMetric(enabled, "repro interface metadata warm hit",
    warmStats.metadataWarmHits)
  stats.addCounterMetric(enabled, "repro interface metadata warm miss",
    warmStats.metadataWarmMisses)
  stats.addCounterMetric(enabled, "repro interface metadata source revalidate",
    warmStats.metadataRevalidatedSources)
  stats.addCounterMetric(enabled, "repro interface metadata reprolib revalidate",
    warmStats.metadataRevalidatedReproLibs)
  stats.addCounterMetric(enabled, "repro interface artifact cold read",
    warmStats.artifactColdReads)
  stats.addCounterMetric(enabled, "repro interface artifact warm hit",
    warmStats.artifactWarmHits)
  stats.addCounterMetric(enabled, "repro interface artifact warm miss",
    warmStats.artifactWarmMisses)

proc renderBuildStats*(stats: BuildStats): string =
  let nameWidth = 36
  result = "metric" & repeat(' ', nameWidth - "metric".len) &
    " count   avg (us)        total (ms)\n"
  for metric in stats.metrics:
    let avgUs =
      if metric.count > 0:
        metric.totalUs / float(metric.count)
      else:
        0.0
    let totalMs = metric.totalUs / 1000.0
    let paddedName =
      if metric.name.len < nameWidth:
        metric.name & repeat(' ', nameWidth - metric.name.len)
      else:
        metric.name & " "
    result.add(paddedName & " " &
      align($metric.count, 5) & "   " &
      align(formatFloat(avgUs, ffDecimal, 1), 8) & "        " &
      formatFloat(totalMs, ffDecimal, 1) & "\n")

proc recordStatsForBuildRun(runResult: BuildRunResult) =
  if not statsCaptureActive():
    return
  for metric in runResult.stats.metrics:
    enqueueStatsObservation(scgTiming, "metric", %*{
      "name": metric.name,
      "count": metric.count,
      "totalUs": metric.totalUs
    })
  for traceEvent in runResult.trace:
    enqueueStatsObservation(scgTiming, "scheduler-trace", %*{
      "seq": traceEvent.seq,
      "actionId": traceEvent.actionId,
      "event": traceEvent.event,
      "detail": traceEvent.detail
    })
  for item in runResult.results:
    enqueueStatsObservation(scgSessions, "action-result", %*{
      "actionId": item.id,
      "status": $item.status,
      "launched": item.launched,
      "wouldLaunch": item.wouldLaunch,
      "exitCode": item.exitCode,
      "reason": item.reason
    })
    enqueueStatsObservation(scgCache, "cache-decision", %*{
      "actionId": item.id,
      "cacheDecision": $item.cacheDecision,
      "status": $item.status,
      "launched": item.launched,
      "reason": item.reason
    })
    enqueueStatsObservation(scgRunQuota, "lease-completion", %*{
      "actionId": item.id,
      "launched": item.launched,
      "leaseId": item.leaseId,
      "runQuotaBackend": item.runQuotaBackend,
      "runQuotaSocket": item.runQuotaSocket,
      "exitCode": item.exitCode,
      "status": $item.status
    })
    enqueueStatsObservation(scgDeps, "dependency-evidence", %*{
      "actionId": item.id,
      "policy": $item.dependencyPolicyKind,
      "declaredInputs": item.evidence.declaredInputs.len,
      "declaredOutputs": item.evidence.declaredOutputs.len,
      "depfileInputs": item.evidence.depfileInputs.len,
      "monitorReads": item.evidence.monitorReads.len,
      "monitorWrites": item.evidence.monitorWrites.len,
      "monitorProbes": item.evidence.monitorProbes.len,
      "diagnostics": item.evidence.diagnostics.len
    })

proc cliPathExists(path: string): bool =
  fileExists(extendedPath(path)) or dirExists(extendedPath(path))

proc actionOutputsPresent(action: BuildAction): bool =
  if action.outputs.len == 0:
    return false
  for output in action.outputs:
    let path =
      if output.isAbsolute or action.cwd.len == 0:
        output
      else:
        action.cwd / output
    if not path.cliPathExists():
      return false
  true

proc cmakeGeneratedStateFresh(meta: CmakeRegenerationMetadata;
                              publicCliPath: string): bool =
  if meta.providerFile.len == 0 or meta.providerStateFile.len == 0:
    return false
  if not fileExists(extendedPath(meta.providerFile)) or not fileExists(extendedPath(meta.providerStateFile)):
    return false
  if readFile(extendedPath(meta.providerFile)) != readFile(extendedPath(meta.providerStateFile)):
    return false
  let stamp = getLastModificationTime(extendedPath(meta.providerStateFile))
  for input in cmakeRegenerationInputs(meta, publicCliPath):
    if (fileExists(extendedPath(input)) or dirExists(extendedPath(input))) and
        getLastModificationTime(extendedPath(input)) > stamp:
      return false
  true

proc seedCmakeRegenerationCache(meta: CmakeRegenerationMetadata;
                                publicCliPath, outDir: string): bool =
  let regenerationAction = cmakeRegenerationBuildAction(meta, publicCliPath)
  if not regenerationAction.cacheable:
    return false
  if not regenerationAction.actionOutputsPresent():
    return false
  # CAS + action-cache moved to the user-level shared root in M70 (see
  # Provider-Compile-Tiering.md §"Cache Scope" Phase 1). The project-local
  # cmake-regeneration-cache dir is still used for per-build scratch
  # (runquota-results, monitor depfiles, dependency-evidence files) but the
  # action cache itself lives under the shared root so cross-project hits
  # are possible.
  # The action cache + CAS live under the user-level shared root (Phase 1
  # of Provider-Compile-Tiering.md §"Cache Scope"); the dependency-evidence
  # file stays project-local because it tracks per-project regeneration
  # state, not action result bytes.
  let sharedRoot = currentActionCacheRoot()
  let cmakeCacheRoot = outDir / "cmake-regeneration-cache"
  let cas = openLocalCas(sharedRoot / "cas")
  var cache = openActionCache(sharedRoot / "action-cache")
  defer:
    cache.flushHotIndex()
  let record = cache.recordActionResult(cas, regenerationAction.weakFingerprint,
    regenerationAction.actionCachePolicy, regenerationAction.inputs,
    regenerationAction.outputs, regenerationAction.cwd,
    storeOutputBlobs = false)
  writeActionResultRecordFile(
    dependencyEvidencePath(cmakeCacheRoot, regenerationAction.id), record)
  true

proc executeBuildTarget(target: string; mode: ToolProvisioningMode;
                        publicCliPath: string;
                        selectDefaultAction = false;
                        workRoot = "";
                        progressMode = bpmBarLine;
                        progressBarStyle = bpbsOverlay;
                        statsMode = bsmNone;
                        reportMode = brmFull;
                        logMode = blmActions;
                        diagnosticsPath = "";
                        prepareOnly = false;
                        dryRun = false;
                        forceRebuild = false;
                        skipCmakeRegeneration = false;
                        bypassRunQuotaExplicit = false;
                        benchmarkPath = "";
                        eventSink: BuildCommandEventSink = nil;
                        cancelCheck: BuildCancelCallback = nil;
                        extraNameSelectors: seq[string] = @[]):
    BuildCommandOutcome =
  ## ``extraNameSelectors`` carries the Named-Targets M2 name-shaped
  ## positional arguments AFTER the first positional has been folded
  ## into ``target``. They join the closure union inside
  ## ``lowerProviderSnapshot`` so multi-target ``repro build`` runs in
  ## a single engine pass. Path-shaped positionals stay on the legacy
  ## one-call-per-target path (handled in ``runBuildCommand``).
  # Configure-level aggregation: when REPRO_STATS_DIR is set, each repro
  # build invocation drops a JSON record into that directory. The companion
  # ``scripts/aggregate-stats.py`` script rolls them up into a single
  # per-CMake-configure breakdown. The dir is created lazily on first use.
  # Setting the dir also implicitly opts every spawned repro build into
  # text-mode stat collection so the per-metric breakdown survives — CMake
  # never passes --stats= to its child repro build invocations, so the dir
  # is the only handle we have on enabling them.
  let configureStatsDir = getEnv("REPRO_STATS_DIR")
  let effectiveStatsMode =
    if configureStatsDir.len > 0 and statsMode == bsmNone: bsmText
    else: statsMode
  let statsEnabled = effectiveStatsMode == bsmText or benchmarkPath.len > 0 or
    statsGroupEnabled(scgTiming)
  var buildStats: BuildStats
  discard consumeInterfaceArtifactWarmStats()
  let buildTotalStart = statStart(statsEnabled)
  let invocationWallStart = epochTime()
  var progressRenderer = newBuildProgressRenderer(progressMode,
    progressBarStyle)
  progressRenderer.renderPhase("preparing build")
  defer:
    progressRenderer.finishProgress()
  var invocationFastPath = ""
  var benchmarkExecutedActions = 0
  defer:
    if benchmarkPath.len > 0:
      try:
        writeBuildBenchmark(benchmarkPath, result, buildStats,
          if eventSink == nil: "direct" else: "daemon-worker",
          invocationFastPath, benchmarkExecutedActions)
      except CatchableError:
        discard
  var diagnosticLines: seq[string] = @[]
  proc appendDiagnostic(line: string) =
    if diagnosticsPath.len > 0:
      diagnosticLines.add(line)
  defer:
    if diagnosticsPath.len > 0:
      try:
        let diagnosticsDir = parentDir(diagnosticsPath)
        if diagnosticsDir.len > 0:
          createDir(extendedPath(diagnosticsDir))
        var body = diagnosticLines.join("\n")
        if body.len > 0:
          body.add("\n")
        writeFile(extendedPath(diagnosticsPath), body)
      except CatchableError:
        discard
  defer:
    if configureStatsDir.len > 0:
      try:
        createDir(extendedPath(configureStatsDir))
        let wallMs = (epochTime() - invocationWallStart) * 1000.0
        let stamp = $getCurrentProcessId() & "-" &
          $int(epochTime() * 1_000_000.0)
        let recordPath = configureStatsDir / (stamp & ".json")
        var node = %*{
          "pid": getCurrentProcessId(),
          "target": target,
          "modulePath": result.modulePath,
          "projectRoot": result.projectRoot,
          "outDir": result.outDir,
          "wallMs": wallMs,
          "exitCode": result.exitCode,
          "mode": $mode,
          "fastPath": invocationFastPath,
        }
        var metrics = newJArray()
        for metric in buildStats.metrics:
          metrics.add(%*{
            "name": metric.name,
            "count": metric.count,
            "totalUs": metric.totalUs,
          })
        node["metrics"] = metrics
        writeFile(extendedPath(recordPath), $node)
      except CatchableError:
        # Telemetry is best-effort — never fail a build because we
        # couldn't write a stats record.
        discard
  var parsedTarget = parseBuildTarget(target)
  parsedTarget.modulePath = absolutePath(parsedTarget.modulePath)
  let modulePath = parsedTarget.modulePath
  if not fileExists(extendedPath(modulePath)):
    # Tier 2a: when the CMake generator emits ``trycompile.rbsz`` as the
    # sole project descriptor, no ``reprobuild.nim`` is written. Accept
    # the target as long as that metadata file is present next to the
    # would-be module — the fast path below recognises it explicitly and
    # never tries to compile a per-project provider.
    let trycompileSiblingMeta = parentDir(modulePath) / "trycompile.rbsz"
    if not fileExists(extendedPath(trycompileSiblingMeta)):
      raise newException(IOError, "build target module not found: " & modulePath)

  let outDir = outputDirForTarget(parsedTarget, workRoot)
  result.modulePath = modulePath
  result.projectRoot = projectRootForModule(modulePath)
  result.outDir = outDir
  # When --no-runquota was passed (or the env knob is set), skip the daemon
  # entirely: every action goes through the bypass-spawn path with no lease
  # round-trip. Default is "use runquota when reachable, fall back if not".
  let bypassRunQuota = bypassRunQuotaExplicit
  var fallbackToRunQuotaBypass = mode in {tpmPathOnly, tpmScoop}
  var warnedRunQuotaBypass = false

  template logSummary(line: string) =
    appendDiagnostic(line)
    if eventSink != nil:
      eventSink("diagnostic", line, "{}")
    elif logMode != blmQuiet:
      # Terminate any in-flight progress line on stderr before the stdout
      # echo so captured output (execCmdEx merges stderr+stdout) keeps each
      # diagnostic line on its own physical line. Without this, the
      # progress renderer's `\r`-redrawn phase text on non-ANSI streams
      # accumulates without a newline and gets concatenated with the next
      # `echo` line, breaking helpers like `valueAfter` that look for a
      # line that `startsWith(prefix)`.
      progressRenderer.finishProgress()
      echo line

  template logAction(line: string) =
    appendDiagnostic(line)
    if eventSink != nil and logMode == blmActions:
      eventSink("diagnostic", line, "{}")
    elif logMode == blmActions:
      progressRenderer.finishProgress()
      echo line

  proc usesRunQuotaBypass(runResult: BuildRunResult): bool =
    for item in runResult.results:
      if item.launched and item.runQuotaBackend == "runquota-bypass":
        return true

  proc warnRunQuotaBypassIfUsed(runResult: BuildRunResult) =
    if warnedRunQuotaBypass or not fallbackToRunQuotaBypass:
      return
    if not usesRunQuotaBypass(runResult):
      return
    warnedRunQuotaBypass = true
    logSummary("repro build: WARNING runquotad is not reachable; using " &
      "RunQuota bypass for tool-provisioning=" & mode.modeName &
      " (no quotas/leases enforced). Start `runquotad` and rerun to " &
      "use the real lease coordinator.")

  proc runLoweredGraphBuild(lowered: tuple[actions: seq[BuildAction];
                                          pools: seq[BuildPool]];
                            selectedActionId: string): int =
    if parsedTarget.fragmentKind == tfkActionSelection:
      logSummary("selectedTarget: " & parsedTarget.selectedActionId)
    elif selectDefaultAction and selectedActionId.len > 0:
      logSummary("selectedTarget: " & selectedActionId)
    logSummary("scheduler: actions=" & $lowered.actions.len)
    if lowered.actions.len == 0:
      return 0
    var engineConfig = BuildEngineConfig(
      cacheRoot: outDir / "build-engine-cache",
      actionCacheRoot: currentActionCacheRoot(),
      runQuotaCliPath: publicCliPath,
      monitorCliPath: selfSpawnFsSnoopPath(),
      monitorCliArgs: internalFsSnoopArgs,
      maxParallelism: buildMaxParallelism(),
      stdoutLimit: 1024 * 1024,
      stderrLimit: 1024 * 1024,
      rebuildMissingOutputsOnCacheHit: true,
      deferLocalOutputBlobs: true,
      bypassRunQuota: bypassRunQuota,
      fallbackToRunQuotaBypass: fallbackToRunQuotaBypass,
      inlineRunQuota: true,
      dryRun: dryRun,
      forceRebuild: forceRebuild,
      suppressTrace: reportMode == brmNone,
      skipCacheHitEvidence: reportMode == brmNone and logMode == blmQuiet,
      cancelCallback: cancelCheck)
    engineConfig.statsEnabled = statsEnabled
    if eventSink != nil:
      engineConfig.progressCallback = proc(event: BuildProgressEvent) =
        enqueueStatsObservation(scgSessions, "progress", %*{
          "kind": $event.kind,
          "actionId": event.actionId,
          "status": $event.status,
          "cacheDecision": $event.cacheDecision,
          "total": event.total,
          "completed": event.completed,
          "running": event.running,
          "ready": event.ready
        })
        eventSink("diagnostic", "progress: " & $event.kind & " " &
          event.actionId, $(%*{
            "event": "progress",
            "kind": $event.kind,
            "actionId": event.actionId,
            "status": $event.status,
            "cacheDecision": $event.cacheDecision,
            "total": event.total,
            "completed": event.completed,
            "checked": event.checked,
            "running": event.running,
            "ready": event.ready
          }))
    elif progressRenderer.enabled:
      engineConfig.progressCallback = proc(event: BuildProgressEvent) =
        enqueueStatsObservation(scgSessions, "progress", %*{
          "kind": $event.kind,
          "actionId": event.actionId,
          "status": $event.status,
          "cacheDecision": $event.cacheDecision,
          "total": event.total,
          "completed": event.completed,
          "running": event.running,
          "ready": event.ready
        })
        progressRenderer.renderProgress(event)
    var buildResult: BuildRunResult
    let engineStart = statStart(statsEnabled)
    try:
      progressRenderer.renderPhase("checking graph actions=" &
        $lowered.actions.len)
      buildResult = runBuild(graph(lowered.actions, lowered.pools), engineConfig)
    except CatchableError:
      progressRenderer.finishProgress()
      raise
    finishStat(buildStats, statsEnabled, "repro engine runBuild", engineStart)
    buildStats.mergeStats(buildResult.stats)
    benchmarkExecutedActions = 0
    for item in buildResult.results:
      if item.launched:
        inc benchmarkExecutedActions
    warnRunQuotaBypassIfUsed(buildResult)
    finishStat(buildStats, statsEnabled, "repro build total", buildTotalStart)
    buildResult.stats = buildStats
    let actionLogStart = statStart(statsEnabled)
    for item in buildResult.results:
      logAction("action: " & item.id & " status=" & $item.status &
        " launched=" & $item.launched & " cache=" & $item.cacheDecision &
        " wouldLaunch=" & $item.wouldLaunch &
        (if item.reason.len > 0: " reason=" & item.reason else: "") &
        " runquota=" & item.runQuotaBackend &
        " socket=" & (if item.runQuotaSocket.len >
            0: item.runQuotaSocket else: "default") &
        " lease=" & $item.leaseId &
        " evidence=depfile:" & $item.evidence.depfileInputs.len)
    finishStat(buildStats, statsEnabled, "repro action log render",
      actionLogStart)
    buildResult.stats = buildStats
    recordStatsForBuildRun(buildResult)
    if buildResult.hasFailedActions():
      emitFailedActionSummaries(buildResult, eventSink, progressRenderer)
    # Only dump the text-mode table to stderr when --stats=text was
    # requested explicitly. The implicit enable-via-REPRO_STATS_DIR path
    # uses the JSON dropfile and does not want to spam CMake's child
    # stderr with per-invocation tables.
    if statsMode == bsmText:
      let statsRenderStart = statStart(statsEnabled)
      if eventSink != nil:
        eventSink("diagnostic", renderBuildStats(buildResult.stats), "{}")
      else:
        stderr.write(renderBuildStats(buildResult.stats))
        stderr.flushFile()
      finishStat(buildStats, statsEnabled, "repro stats render",
        statsRenderStart)
    if buildResult.hasFailedActions():
      1
    else:
      0

  var cmakeRegenerationResult: BuildRunResult
  let cmakeMeta = cmakeRegenerationMetadataForModule(modulePath)
  cmakeMeta.applyCmakeProviderEnvironment()
  var cmakeRegenerated = false
  if cmakeMeta.enabled and not skipCmakeRegeneration:
    logSummary("cmakeRegeneration: started")
    progressRenderer.renderPhase("cmake regeneration")
    let cmakeRegenerationStart = statStart(statsEnabled)
    let cmakeRegenerationAction =
      cmakeRegenerationBuildAction(cmakeMeta, publicCliPath)
    let cmakeCacheRoot = outDir / "cmake-regeneration-cache"
    var cmakeFastHit = false
    if reportMode == brmNone and logMode == blmQuiet and not forceRebuild:
      # The CMake regeneration action's cache lives under the shared
      # user-level action cache root, matching the runBuild() path below
      # (Provider-Compile-Tiering.md §"Cache Scope" Phase 1).
      let sharedRoot = currentActionCacheRoot()
      var cmakeCache = openActionCache(sharedRoot / "action-cache")
      defer:
        cmakeCache.flushHotIndex()
      let outputStatStart = statStart(statsEnabled)
      let outputsPresent = cmakeRegenerationAction.actionOutputsPresent()
      finishStat(buildStats, statsEnabled, "repro output stat", outputStatStart)
      if outputsPresent:
        let lookupStart = statStart(statsEnabled)
        let hot = cmakeCache.lookupHotMetadataRecord(
          cmakeRegenerationAction.weakFingerprint,
          cmakeRegenerationAction.actionCachePolicy)
        if hot.isSome and cmakeCache.hotMetadataInputsUnchanged():
          cmakeFastHit = true
          cmakeRegenerationResult.results.add(ActionResult(
            id: cmakeRegenerationAction.id,
            status: asCacheHit,
            launched: false,
            cacheDecision: cdHit,
            dependencyPolicyKind: cmakeRegenerationAction.dependencyPolicy.kind))
        finishStat(buildStats, statsEnabled, "repro cache lookup", lookupStart)
    if not cmakeFastHit:
      let stateStart = statStart(statsEnabled)
      let stateFresh = cmakeGeneratedStateFresh(cmakeMeta, publicCliPath)
      finishStat(buildStats, statsEnabled, "repro cmake state check",
        stateStart)
      if stateFresh and not forceRebuild:
        discard seedCmakeRegenerationCache(cmakeMeta, publicCliPath, outDir)
        cmakeFastHit = true
        cmakeRegenerationResult.results.add(ActionResult(
          id: cmakeRegenerationAction.id,
          status: asCacheHit,
          launched: false,
          cacheDecision: cdHit,
          dependencyPolicyKind: cmakeRegenerationAction.dependencyPolicy.kind))
    if not cmakeFastHit:
      var cmakeRegenerationConfig = BuildEngineConfig(
        cacheRoot: cmakeCacheRoot,
        actionCacheRoot: currentActionCacheRoot(),
        runQuotaCliPath: publicCliPath,
        monitorCliPath: selfSpawnFsSnoopPath(),
        monitorCliArgs: internalFsSnoopArgs,
        maxParallelism: 1'u32,
        stdoutLimit: 1024 * 1024,
        stderrLimit: 1024 * 1024,
        rebuildMissingOutputsOnCacheHit: true,
        deferLocalOutputBlobs: true,
        bypassRunQuota: bypassRunQuota,
        fallbackToRunQuotaBypass: fallbackToRunQuotaBypass,
        inlineRunQuota: true,
        dryRun: false,
        forceRebuild: forceRebuild,
        suppressTrace: reportMode == brmNone,
        skipCacheHitEvidence: reportMode == brmNone and logMode == blmQuiet,
        cancelCallback: cancelCheck)
      cmakeRegenerationConfig.statsEnabled = statsEnabled
      cmakeRegenerationResult = runBuild(graph([cmakeRegenerationAction]),
        cmakeRegenerationConfig)
      buildStats.mergeStats(cmakeRegenerationResult.stats)
    finishStat(buildStats, statsEnabled, "repro cmake regeneration",
      cmakeRegenerationStart)
    warnRunQuotaBypassIfUsed(cmakeRegenerationResult)
    for item in cmakeRegenerationResult.results:
      logAction("cmakeRegenerationAction: " & item.id & " status=" &
        $item.status & " launched=" & $item.launched & " cache=" &
        $item.cacheDecision & " wouldLaunch=" & $item.wouldLaunch &
        (if item.reason.len > 0: " reason=" & item.reason else: ""))
      if eventSink != nil and logMode != blmQuiet and item.stdout.len > 0:
        eventSink("diagnostic", item.stdout, "{\"stream\":\"stdout\"}")
      elif logMode != blmQuiet and item.stdout.len > 0:
        stdout.write(item.stdout)
        stdout.flushFile()
      if eventSink != nil and logMode != blmQuiet and item.stderr.len > 0:
        eventSink("diagnostic", item.stderr, "{\"stream\":\"stderr\"}")
      elif logMode != blmQuiet and item.stderr.len > 0:
        stderr.write(item.stderr)
        stderr.flushFile()
    if cmakeRegenerationResult.hasFailedActions():
      raise newException(OSError,
        "CMake regeneration edge failed: " &
          providerCompileFailure(cmakeRegenerationResult))
    for item in cmakeRegenerationResult.results:
      if item.launched and item.status == asSucceeded:
        cmakeRegenerated = true

  let pathEnv = getEnv("PATH")
  let cacheSelectedActionId =
    if parsedTarget.selectedActionId.len > 0:
      parsedTarget.selectedActionId
    elif selectDefaultAction and logMode == blmQuiet:
      ""
    else:
      "\0"
  if cmakeMeta.enabled and not cmakeRegenerated and not prepareOnly and
      mode == tpmPathOnly and reportMode == brmNone and
      cacheSelectedActionId != "\0":
    let loweredCacheStart = statStart(statsEnabled)
    progressRenderer.renderPhase("reading lowered graph cache")
    let loweredCache = warmReadFreshLoweredGraphCache(
      loweredGraphCachePath(outDir, cacheSelectedActionId), modulePath,
      result.projectRoot, cacheSelectedActionId, pathEnv, "cmake-pre-provider")
    finishStat(buildStats, statsEnabled, "repro lowered graph cache read",
      loweredCacheStart)
    if loweredCache.isSome:
      logSummary("loweredGraphCache: hit")
      result.exitCode = runLoweredGraphBuild(loweredCache.get(),
        cacheSelectedActionId)
      return

  # Tier 2a fast path: stereotyped CMake try_compile() projects ship a
  # ``trycompile.rbsz`` metadata file emitted by the Reprobuild generator
  # and skip the per-project provider compile entirely. The engine
  # dispatches the pre-built ``repro-cmake-trycompile-provider`` binary
  # which parses the metadata, registers the synthesized actions via the
  # standard DSL primitives, and emits the build graph. The provider
  # artifact id is a constant per ``repro`` release so every TryCompile
  # against the same toolchain shares a cache key.
  # Per Provider-Compile-Tiering.md §"2a — repro-cmake-trycompile-provider".
  let tryCompileMetaPath = result.projectRoot / "trycompile.rbsz"
  let tryCompileProviderBinary = siblingTryCompileProviderPath(publicCliPath)
  if mode == tpmPathOnly and
      fileExists(extendedPath(tryCompileMetaPath)) and
      tryCompileProviderBinary.len > 0:
    invocationFastPath =
      if prepareOnly: "tier2c-direct-prepare"
      else: "tier2a-trycompile-direct"
    logSummary("trycompileDirect: dispatching " & tryCompileProviderBinary)
    logSummary("project: " & TryCompileProviderPackageName)
    logSummary("interface: " & tryCompileMetaPath)
    logSummary("providerBinary: " & tryCompileProviderBinary)
    logSummary("providerArtifact: " & TryCompileProviderArtifactId)
    logSummary("runQuotaSocket: " & runQuotaSocketDiagnostic())
    let synthIdentity = PathOnlyBuildIdentity(
      projectName: TryCompileProviderPackageName,
      interfaceFingerprint: blake3DomainDigest(
        toBytes(TryCompileProviderArtifactId), hdActionFingerprint))
    let providerGraphStart = statStart(statsEnabled)
    progressRenderer.renderPhase("refreshing trycompile provider graph")
    let refresh = refreshProviderGraph(RefreshConfig(
      storeRoot: outDir / "provider-graph",
      providerBinaryPath: tryCompileProviderBinary,
      providerArtifactId: TryCompileProviderArtifactId,
      rootEntryPointId: TryCompileProviderRootEntryPointId,
      rootArguments: result.projectRoot,
      namespace: TryCompileProviderNamespace,
      lockSliceId: digestHex(synthIdentity.interfaceFingerprint),
      activity: "build",
      providerWorkingDir: result.projectRoot))
    finishStat(buildStats, statsEnabled, "repro provider graph refresh",
      providerGraphStart)
    logSummary("providerGraphSnapshot: " & refresh.persistedSnapshotPath)
    logSummary("providerInvocations: " & $refresh.invoked.len)
    var selectedActionId = parsedTarget.selectedActionId
    if selectDefaultAction and selectedActionId.len == 0:
      selectedActionId = defaultBuildActionId(refresh.snapshot)
      if selectedActionId.len > 0:
        logSummary("defaultTarget: " & selectedActionId)
    let graphLowerStart = statStart(statsEnabled)
    progressRenderer.renderPhase("lowering trycompile graph")
    # Named-Targets M2: union the first selector (action id or default)
    # with any extra name-shaped positional selectors so the closure
    # is computed once.
    var selectorList: seq[string] = @[]
    if selectedActionId.len > 0:
      selectorList.add(selectedActionId)
    for extra in extraNameSelectors:
      if extra.len > 0 and selectorList.find(extra) < 0:
        selectorList.add(extra)
    let lowered =
      if selectorList.len == 0:
        lowerProviderSnapshot(refresh.snapshot, synthIdentity,
          result.projectRoot, "")
      else:
        lowerProviderSnapshot(refresh.snapshot, synthIdentity,
          result.projectRoot, selectorList)
    finishStat(buildStats, statsEnabled, "repro graph lower", graphLowerStart)
    if prepareOnly:
      # PrimeProviderMetadata's prepare-only invocation used to compile
      # the per-project provider so subsequent TryCompile probes wouldn't
      # have to. With the direct provider that prep is unnecessary, but
      # the cmake-regeneration state-file snapshot still needs to be
      # written so cmake's regeneration check works on the next configure.
      if cmakeMeta.enabled and not skipCmakeRegeneration and
          fileExists(extendedPath(modulePath)):
        createDir(extendedPath(parentDir(cmakeMeta.providerStateFile)))
        writeFile(extendedPath(cmakeMeta.providerStateFile),
          readFile(extendedPath(modulePath)))
        let seedStart = statStart(statsEnabled)
        discard seedCmakeRegenerationCache(cmakeMeta, publicCliPath, outDir)
        finishStat(buildStats, statsEnabled,
          "repro cmake regeneration cache seed", seedStart)
      result.exitCode = 0
      return
    result.exitCode = runLoweredGraphBuild(lowered, selectedActionId)
    return

  let interfacePath = outDir / "project-interface.rbsz"
  let stubPath = outDir / "project-interface.nim"
  let compileWorkDir = reprobuildLibraryWorkDir()
  let compileScratchDir = outDir / "provider-work"
  let interfaceStart = statStart(statsEnabled)
  progressRenderer.renderPhase("loading project interface")
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath,
    compileWorkDir, compileScratchDir, requireStub = false)
  finishStat(buildStats, statsEnabled, "repro interface extract",
    interfaceStart)
  recordInterfaceArtifactWarmStats(buildStats, statsEnabled)

  var effectiveMode = mode
  if effectiveMode == tpmUnspecified and
      artifact.projectInterface.defaultToolProvisioning.len > 0:
    effectiveMode = parseToolProvisioning(
      artifact.projectInterface.defaultToolProvisioning)
    fallbackToRunQuotaBypass = effectiveMode in {tpmPathOnly, tpmScoop}

  if artifact.projectInterface.toolUses.len > 0 and
      effectiveMode == tpmUnspecified:
    raise newException(ValueError,
      "typed tool provisioning is required for uses declarations; refusing " &
        "implicit PATH fallback. Pass --tool-provisioning=path to use the " &
        "explicit weak local profile.")

  # Tier 2b fast path: a package whose DSL body declared no ``build:``
  # block is eligible for the pre-built ``repro-standard-provider``
  # binary. The provider walks language conventions (Nim/Rust/Go/...) to
  # derive a fine-grained graph fragment without a per-project provider
  # compile. We dispatch only when the standard provider binary is
  # actually shipped next to ``repro``; missing-binary installs fall
  # back to the slow path with a warning so users get a build either
  # way.
  # Per Provider-Compile-Tiering.md §"2b — repro-standard-provider" and
  # reprobuild-specs/Standard-Provider-Implementation.milestones.org §M2.
  if mode == tpmPathOnly and not prepareOnly and
      artifact.projectInterface.standardBuildEligible:
    let standardProviderBinary = siblingStandardProviderPath(publicCliPath)
    if standardProviderBinary.len > 0:
      invocationFastPath = "tier2b-standard-direct"
      logSummary("standardDirect: dispatching " & standardProviderBinary)
      logSummary("project: " & artifact.projectInterface.projectName)
      logSummary("interface: " & interfacePath)
      logSummary("providerBinary: " & standardProviderBinary)
      logSummary("providerArtifact: " & StandardProviderArtifactId)
      logSummary("runQuotaSocket: " & runQuotaSocketDiagnostic())
      let synthIdentity = PathOnlyBuildIdentity(
        projectName: artifact.projectInterface.projectName,
        interfaceFingerprint: artifact.interfaceFingerprint)
      let providerGraphStart = statStart(statsEnabled)
      progressRenderer.renderPhase("refreshing standard provider graph")
      let refresh = refreshProviderGraph(RefreshConfig(
        storeRoot: outDir / "provider-graph",
        providerBinaryPath: standardProviderBinary,
        providerArtifactId: StandardProviderArtifactId,
        rootEntryPointId: StandardProviderRootEntryPointId,
        rootArguments: result.projectRoot,
        namespace: StandardProviderNamespace,
        lockSliceId: digestHex(synthIdentity.interfaceFingerprint),
        activity: "build",
        providerWorkingDir: result.projectRoot))
      finishStat(buildStats, statsEnabled, "repro provider graph refresh",
        providerGraphStart)
      logSummary("providerGraphSnapshot: " & refresh.persistedSnapshotPath)
      logSummary("providerInvocations: " & $refresh.invoked.len)
      var selectedActionId = parsedTarget.selectedActionId
      if selectDefaultAction and selectedActionId.len == 0:
        selectedActionId = defaultBuildActionId(refresh.snapshot)
        if selectedActionId.len > 0:
          logSummary("defaultTarget: " & selectedActionId)
      let graphLowerStart = statStart(statsEnabled)
      progressRenderer.renderPhase("lowering standard provider graph")
      # Named-Targets M2 multi-selector union (see trycompile branch above).
      var selectorList: seq[string] = @[]
      if selectedActionId.len > 0:
        selectorList.add(selectedActionId)
      for extra in extraNameSelectors:
        if extra.len > 0 and selectorList.find(extra) < 0:
          selectorList.add(extra)
      let lowered =
        if selectorList.len == 0:
          lowerProviderSnapshot(refresh.snapshot, synthIdentity,
            result.projectRoot, "")
        else:
          lowerProviderSnapshot(refresh.snapshot, synthIdentity,
            result.projectRoot, selectorList)
      finishStat(buildStats, statsEnabled, "repro graph lower", graphLowerStart)
      result.exitCode = runLoweredGraphBuild(lowered, selectedActionId)
      return
    else:
      logSummary("standardDirect: provider binary missing; falling back to " &
        "per-project provider compile")

  if effectiveMode in {tpmPathOnly, tpmNix, tpmTarball, tpmScoop}:
    let identityStart = statStart(statsEnabled)
    progressRenderer.renderPhase("resolving tool identities")
    let resolved = warmResolveAndWriteIdentity(artifact, outDir, effectiveMode)
    finishStat(buildStats, statsEnabled, "repro tool identity resolve",
      identityStart)
    let identity = resolved.identity
    logSummary("repro build: tool provisioning active (tool-provisioning=" &
      effectiveMode.modeName & ")")
    if effectiveMode == tpmPathOnly:
      logSummary("repro build: provisioning-disabled mode active (tool-provisioning=path)")
    logSummary("project: " & artifact.projectInterface.projectName)
    logSummary("interface: " & interfacePath)
    logSummary("toolIdentity: " & resolved.identityPath)
    logSummary("inspection: " & resolved.inspectionPath)
    let portability =
      if effectiveMode == tpmNix:
        "portable"
      elif effectiveMode == tpmTarball:
        "portable"
      elif effectiveMode == tpmScoop:
        # Scoop receipts may be cache-portable or cache-local depending on
        # the practical hardening tier. Read the resolved identity to find
        # out, defaulting to local-only when no profiles are present.
        var anyLocal = false
        var anyPortable = false
        for profile in identity.profiles:
          if profile.cachePortability == cpPortable:
            anyPortable = true
          else:
            anyLocal = true
        if anyPortable and not anyLocal:
          "portable"
        elif anyPortable and anyLocal:
          "mixed"
        else:
          "local-only"
      else:
        "local-only"
    logSummary("cachePortability: " & portability)
    logSummary("runQuotaSocket: " & runQuotaSocketDiagnostic())
    if not moduleHasBuildBlock(modulePath):
      result.exitCode = 0
      return
    let providerBinaryPath = outDir / "provider" / "project-provider"
    let providerArtifactPath = outDir / "provider-compile.rbsz"
    logSummary("providerCompile: started")
    progressRenderer.renderPhase("checking provider compile")
    let providerCompileStart = statStart(statsEnabled)
    var providerCompileResult: BuildRunResult
    var provider: ProviderCompileArtifact
    let cachedProvider =
      if forceRebuild and not dryRun:
        none(ProviderCompileArtifact)
      else:
        readFreshProviderCompileArtifact(providerArtifactPath,
          modulePath, providerBinaryPath, artifact.interfaceFingerprint)
    if cachedProvider.isSome:
      provider = cachedProvider.get()
    else:
      let providerPlan = providerCompilePlan(modulePath, providerBinaryPath,
        artifact.interfaceFingerprint, compileWorkDir, compileScratchDir)
      invalidateStaleProviderCompileArtifact(providerPlan, providerArtifactPath)
      let providerCompileAction = providerCompileBuildAction(providerPlan,
        modulePath, interfacePath, providerArtifactPath, publicCliPath,
        compileWorkDir, compileScratchDir)
      var providerCompileConfig = BuildEngineConfig(
        cacheRoot: outDir / "build-engine-cache",
        actionCacheRoot: currentActionCacheRoot(),
        runQuotaCliPath: publicCliPath,
        maxParallelism: 1'u32,
        stdoutLimit: 1024 * 1024,
        stderrLimit: 1024 * 1024,
        rebuildMissingOutputsOnCacheHit: true,
        deferLocalOutputBlobs: true,
        bypassRunQuota: bypassRunQuota,
        fallbackToRunQuotaBypass: fallbackToRunQuotaBypass,
        inlineRunQuota: true,
        dryRun: false,
        forceRebuild: forceRebuild,
        suppressTrace: reportMode == brmNone,
        skipCacheHitEvidence: reportMode == brmNone and logMode == blmQuiet,
        cancelCallback: cancelCheck)
      providerCompileConfig.statsEnabled = statsEnabled
      providerCompileResult = runBuild(graph([providerCompileAction]),
        providerCompileConfig)
      buildStats.mergeStats(providerCompileResult.stats)
      warnRunQuotaBypassIfUsed(providerCompileResult)
      for item in providerCompileResult.results:
        logAction("providerCompileAction: " & item.id & " status=" &
          $item.status & " launched=" & $item.launched & " cache=" &
          $item.cacheDecision & " wouldLaunch=" & $item.wouldLaunch &
          (if item.reason.len > 0: " reason=" & item.reason else: ""))
      if providerCompileResult.hasFailedActions():
        raise newException(OSError, providerCompileFailure(providerCompileResult))
      if not fileExists(extendedPath(providerArtifactPath)):
        raise newException(IOError,
          "provider compile edge did not write artifact: " & providerArtifactPath)
      provider = readProviderCompileArtifact(providerArtifactPath)
      if not providerCompileArtifactFresh(providerArtifactPath,
          providerPlan.outputBinaryPath, providerPlan.interfaceFingerprint,
          providerPlan.providerFingerprint):
        raise newException(IOError,
          "provider compile artifact is stale after edge execution: " &
            providerArtifactPath)
    finishStat(buildStats, statsEnabled, "repro provider compile",
      providerCompileStart)
    let providerArtifactId = digestHex(provider.providerFingerprint)
    logSummary("providerBinary: " & provider.outputBinaryPath)
    logSummary("providerCompileArtifact: " & providerArtifactPath)
    logSummary("providerArtifact: " & providerArtifactId)

    let projectRoot = result.projectRoot
    let providerGraphStore = outDir / "provider-graph"
    let providerGraphStart = statStart(statsEnabled)
    var refresh: ProviderRefreshReport
    progressRenderer.renderPhase("checking project provider graph snapshot")
    let freshSnapshot =
      if forceRebuild or dryRun:
        none(ProviderGraphSnapshot)
      else:
        warmReadFreshProviderGraphSnapshot(providerGraphStore, providerArtifactId)
    if freshSnapshot.isSome:
      refresh.snapshot = freshSnapshot.get()
      refresh.persistedSnapshotPath = providerSnapshotPath(providerGraphStore)
    else:
      progressRenderer.renderPhase("refreshing project provider graph")
      refresh = refreshProviderGraph(RefreshConfig(
        storeRoot: providerGraphStore,
        providerBinaryPath: provider.outputBinaryPath,
        providerArtifactId: providerArtifactId,
        rootEntryPointId: artifact.projectInterface.packageName & ".root",
        rootArguments: projectRoot,
        namespace: "project",
        lockSliceId: digestHex(artifact.interfaceFingerprint),
        activity: "build",
        providerWorkingDir: projectRoot))
    finishStat(buildStats, statsEnabled, "repro provider graph refresh",
      providerGraphStart)
    logSummary("providerGraphSnapshot: " & refresh.persistedSnapshotPath)
    logSummary("providerInvocations: " & $refresh.invoked.len)

    var selectedActionId = parsedTarget.selectedActionId
    if selectDefaultAction and selectedActionId.len == 0:
      selectedActionId = defaultBuildActionId(refresh.snapshot)
      if selectedActionId.len > 0:
        logSummary("defaultTarget: " & selectedActionId)

    # Named-Targets M2: union the first selector with any extra
    # name-shaped positional selectors for the lowering pass. The
    # lowered-graph cache is keyed by a single ``selectedActionId``, so
    # when extra selectors are present we skip the cache and recompute
    # — the cache schema upgrade to keyed-on-selector-set is M5 work.
    var selectorList: seq[string] = @[]
    if selectedActionId.len > 0:
      selectorList.add(selectedActionId)
    for extra in extraNameSelectors:
      if extra.len > 0 and selectorList.find(extra) < 0:
        selectorList.add(extra)
    let multiTarget = extraNameSelectors.len > 0

    # Named-Targets M5: classify every user-supplied selector against
    # the project-scoped target-export table so the build report records
    # the resolver's outcome (``resolved`` / ``ambiguous`` / ``unknown``)
    # under ``targetResolution``. This is descriptive — the engine has
    # already used the selectors to assemble ``selectorList`` above.
    # Ambiguous / unknown selectors that survive to this point are the
    # action-id / explicit-target labels the user passed directly (the
    # M2 dispatch would have raised a typed exception for unresolvable
    # name selectors before reaching here).
    var targetResolutions: seq[TargetResolutionRecord] = @[]
    block computeTargetResolutions:
      let exportTable = aggregateTargetExportTable(refresh.snapshot)
      var actionIds: seq[string] = @[]
      var explicitTargets: seq[string] = @[]
      var seenAction = initHashSet[string]()
      var seenExplicit = initHashSet[string]()
      for fragment in refresh.snapshot.fragments:
        for node in fragment.nodes:
          if node.kind == gnkAction:
            let payload = decodeBuildActionPayload(toBytes(node.payload))
            if not seenAction.containsOrIncl(payload.id):
              actionIds.add(payload.id)
          elif node.kind == gnkMetadata and
              node.stableName == "reprobuild.build-target.v1":
            let targetDef = decodeBuildTargetPayload(toBytes(node.payload))
            if not seenExplicit.containsOrIncl(targetDef.name):
              explicitTargets.add(targetDef.name)
      var userSelectors: seq[string] = @[]
      if parsedTarget.fragmentKind == tfkActionSelection and
          parsedTarget.selectedActionId.len > 0:
        userSelectors.add(parsedTarget.selectedActionId)
      for extra in extraNameSelectors:
        if extra.len > 0 and userSelectors.find(extra) < 0:
          userSelectors.add(extra)
      for sel in userSelectors:
        targetResolutions.add(resolveTargetExportSelector(exportTable,
          actionIds, explicitTargets, sel))

    let graphCacheKey = loweredGraphCacheKey(artifact, effectiveMode,
      providerArtifactId, refresh.persistedSnapshotPath, pathEnv)
    let graphCacheReadStart = statStart(statsEnabled)
    progressRenderer.renderPhase("reading lowered graph cache")
    let cachedLowered =
      if forceRebuild or multiTarget:
        none(tuple[actions: seq[BuildAction]; pools: seq[BuildPool]])
      else:
        warmReadFreshLoweredGraphCache(loweredGraphCachePath(outDir, selectedActionId),
          modulePath, projectRoot, selectedActionId, pathEnv, graphCacheKey)
    finishStat(buildStats, statsEnabled, "repro lowered graph cache read",
      graphCacheReadStart)
    let lowered =
      if cachedLowered.isSome:
        logSummary("loweredGraphCache: hit")
        cachedLowered.get()
      else:
        let graphLowerStart = statStart(statsEnabled)
        progressRenderer.renderPhase("lowering project graph")
        let computed =
          if selectorList.len == 0:
            lowerProviderSnapshot(refresh.snapshot, identity,
              projectRoot, "")
          else:
            lowerProviderSnapshot(refresh.snapshot, identity,
              projectRoot, selectorList)
        finishStat(buildStats, statsEnabled, "repro graph lower", graphLowerStart)
        let cacheWriteStart = statStart(statsEnabled)
        if not multiTarget:
          writeLoweredGraphCache(loweredGraphCachePath(outDir, selectedActionId),
            modulePath, projectRoot, selectedActionId, pathEnv, graphCacheKey,
            computed)
          if selectDefaultAction and parsedTarget.selectedActionId.len == 0:
            writeLoweredGraphCache(loweredGraphCachePath(outDir, ""), modulePath,
              projectRoot, "", pathEnv, graphCacheKey, computed)
        finishStat(buildStats, statsEnabled, "repro lowered graph cache write",
          cacheWriteStart)
        computed
    if prepareOnly:
      if cmakeMeta.enabled:
        createDir(extendedPath(parentDir(cmakeMeta.providerStateFile)))
        writeFile(extendedPath(cmakeMeta.providerStateFile), readFile(extendedPath(modulePath)))
        let seedStart = statStart(statsEnabled)
        discard seedCmakeRegenerationCache(cmakeMeta, publicCliPath, outDir)
        finishStat(buildStats, statsEnabled,
          "repro cmake regeneration cache seed", seedStart)
      finishStat(buildStats, statsEnabled, "repro build total",
        buildTotalStart)
      if statsMode == bsmText:
        let statsRenderStart = statStart(statsEnabled)
        if eventSink != nil:
          eventSink("diagnostic", renderBuildStats(buildStats), "{}")
        else:
          stderr.write(renderBuildStats(buildStats))
          stderr.flushFile()
          finishStat(buildStats, statsEnabled, "repro stats render",
            statsRenderStart)
      result.exitCode = 0
      return
    if parsedTarget.fragmentKind == tfkActionSelection:
      logSummary("selectedTarget: " & parsedTarget.selectedActionId)
    elif selectDefaultAction and selectedActionId.len > 0:
      logSummary("selectedTarget: " & selectedActionId)
    logSummary("scheduler: actions=" & $lowered.actions.len)
    if lowered.actions.len == 0:
      result.exitCode = 0
      return
    var engineConfig = BuildEngineConfig(
      cacheRoot: outDir / "build-engine-cache",
      actionCacheRoot: currentActionCacheRoot(),
      runQuotaCliPath: publicCliPath,
      monitorCliPath: selfSpawnFsSnoopPath(),
      monitorCliArgs: internalFsSnoopArgs,
      maxParallelism: buildMaxParallelism(),
      stdoutLimit: 1024 * 1024,
      stderrLimit: 1024 * 1024,
      rebuildMissingOutputsOnCacheHit: true,
      deferLocalOutputBlobs: true,
      bypassRunQuota: bypassRunQuota,
      fallbackToRunQuotaBypass: fallbackToRunQuotaBypass,
      inlineRunQuota: true,
      dryRun: dryRun,
      forceRebuild: forceRebuild,
      suppressTrace: reportMode == brmNone,
      skipCacheHitEvidence: reportMode == brmNone and logMode == blmQuiet,
      cancelCallback: cancelCheck)
    engineConfig.statsEnabled = statsEnabled
    if eventSink != nil:
      engineConfig.progressCallback = proc(event: BuildProgressEvent) =
        enqueueStatsObservation(scgSessions, "progress", %*{
          "kind": $event.kind,
          "actionId": event.actionId,
          "status": $event.status,
          "cacheDecision": $event.cacheDecision,
          "total": event.total,
          "completed": event.completed,
          "running": event.running,
          "ready": event.ready
        })
        eventSink("diagnostic", "progress: " & $event.kind & " " &
          event.actionId, $(%*{
            "event": "progress",
            "kind": $event.kind,
            "actionId": event.actionId,
            "status": $event.status,
            "cacheDecision": $event.cacheDecision,
            "total": event.total,
            "completed": event.completed,
            "checked": event.checked,
            "running": event.running,
            "ready": event.ready
          }))
    elif progressRenderer.enabled:
      engineConfig.progressCallback = proc(event: BuildProgressEvent) =
        enqueueStatsObservation(scgSessions, "progress", %*{
          "kind": $event.kind,
          "actionId": event.actionId,
          "status": $event.status,
          "cacheDecision": $event.cacheDecision,
          "total": event.total,
          "completed": event.completed,
          "running": event.running,
          "ready": event.ready
        })
        progressRenderer.renderProgress(event)
    var buildResult: BuildRunResult
    let engineStart = statStart(statsEnabled)
    try:
      progressRenderer.renderPhase("checking graph actions=" &
        $lowered.actions.len)
      buildResult = runBuild(graph(lowered.actions, lowered.pools), engineConfig)
    except CatchableError:
      progressRenderer.finishProgress()
      raise
    finishStat(buildStats, statsEnabled, "repro engine runBuild", engineStart)
    buildStats.mergeStats(buildResult.stats)
    benchmarkExecutedActions = 0
    for item in buildResult.results:
      if item.launched:
        inc benchmarkExecutedActions
    warnRunQuotaBypassIfUsed(buildResult)
    finishStat(buildStats, statsEnabled, "repro build total", buildTotalStart)
    buildResult.stats = buildStats
    let reportPath = outDir / "build-report.json"
    if reportMode == brmFull:
      let reportStart = statStart(statsEnabled)
      writeBuildReport(reportPath, provider, refresh, cmakeRegenerationResult,
        providerCompileResult, buildResult,
        targetResolutions = targetResolutions)
      finishStat(buildStats, statsEnabled, "repro report write", reportStart)
      buildResult.stats = buildStats
      result.buildReportPath = reportPath
    let actionLogStart = statStart(statsEnabled)
    for item in buildResult.results:
      logAction("action: " & item.id & " status=" & $item.status &
        " launched=" & $item.launched & " cache=" & $item.cacheDecision &
        " wouldLaunch=" & $item.wouldLaunch &
        (if item.reason.len > 0: " reason=" & item.reason else: "") &
        " runquota=" & item.runQuotaBackend &
        " socket=" & (if item.runQuotaSocket.len >
            0: item.runQuotaSocket else: "default") &
        " lease=" & $item.leaseId &
        " evidence=depfile:" & $item.evidence.depfileInputs.len)
    if reportMode == brmFull:
      logSummary("buildReport: " & reportPath)
    finishStat(buildStats, statsEnabled, "repro action log render",
      actionLogStart)
    buildResult.stats = buildStats
    recordStatsForBuildRun(buildResult)
    if buildResult.hasFailedActions():
      emitFailedActionSummaries(buildResult, eventSink, progressRenderer)
    if statsMode == bsmText:
      let statsRenderStart = statStart(statsEnabled)
      if eventSink != nil:
        eventSink("diagnostic", renderBuildStats(buildResult.stats), "{}")
      else:
        stderr.write(renderBuildStats(buildResult.stats))
        stderr.flushFile()
      finishStat(buildStats, statsEnabled, "repro stats render",
        statsRenderStart)
    result.exitCode =
      if buildResult.hasFailedActions():
        1
      else:
        0
    return

  logSummary("repro build: no external tools requested")
  logSummary("interface: " & interfacePath)
  result.exitCode = 0

proc isUnderReproDir(path: string): bool =
  for part in path.split({'/', '\\'}):
    if part == ".repro":
      return true

proc addWatchCandidate(paths: var HashSet[string]; projectRoot, path: string) =
  if path.len == 0:
    return
  var candidate =
    if path.isAbsolute:
      path
    else:
      projectRoot / path
  candidate = os.normalizedPath(candidate)
  if candidate.isUnderReproDir():
    return
  paths.incl(candidate)
  let parent = parentDir(candidate)
  if parent.len > 0 and not parent.isUnderReproDir():
    paths.incl(parent)

proc watchPathsFromReport(outcome: BuildCommandOutcome): seq[string] =
  var paths = initHashSet[string]()
  addWatchCandidate(paths, outcome.projectRoot, outcome.modulePath)
  if outcome.buildReportPath.len > 0 and fileExists(extendedPath(outcome.buildReportPath)):
    let report = parseFile(outcome.buildReportPath)
    for action in report{"actions"}:
      let evidence = action{"evidence"}
      for key in ["declaredInputs", "depfileInputs", "monitorReads",
          "monitorProbes"]:
        for item in evidence{key}:
          addWatchCandidate(paths, outcome.projectRoot, item.getStr())
  result = toSeq(paths)
  result.sort()

proc flushStdout() =
  stdout.flushFile()

proc binDirsForDevelop(identity: PathOnlyBuildIdentity): seq[string] =
  for profile in identity.profiles:
    if profile.installMethod == "nix":
      for storePath in profile.realizedStorePaths:
        let binDir = storePath / "bin"
        if dirExists(extendedPath(binDir)) and not result.contains(binDir):
          result.add(binDir)
    else:
      for binDir in profile.pathSearchList:
        if binDir.len > 0 and dirExists(extendedPath(binDir)) and not result.contains(binDir):
          result.add(binDir)

proc runInDevelopEnvironment(command: openArray[string]; projectRoot: string;
                             identity: PathOnlyBuildIdentity;
                             identityPath, inspectionPath,
                             interfacePath: string): int =
  if command.len == 0:
    raise newException(ValueError, "develop command is empty")
  # Canonicalize projectRoot before plumbing it through both the child's
  # working-directory and REPRO_PROJECT_ROOT. On macOS the system temp
  # roots (/tmp, /var/folders/...) are symlinks into /private/..., and
  # after the child shell chdirs into the working directory it sets PWD
  # from getcwd(), which returns the realpath form. If the env var
  # disagreed with PWD the user-visible contract (REPRO_PROJECT_ROOT =
  # the shell's cwd) would break for any path that traverses a symlink.
  let canonicalProjectRoot =
    try:
      expandFilename(projectRoot)
    except OSError:
      projectRoot
  let profileBinDirs = binDirsForDevelop(identity)
  let pathValue =
    if profileBinDirs.len > 0:
      profileBinDirs.join($PathSep) & $PathSep & getEnv("PATH")
    else:
      getEnv("PATH")
  let artifact = DevEnvArtifact(
    projectRoot: canonicalProjectRoot,
    selectedActivities: @["develop"],
    shellOps: @[
      DevEnvShellOp(kind: deskSetEnv, name: "PATH", value: pathValue),
      DevEnvShellOp(kind: deskSetEnv, name: "REPRO_TOOL_PROFILE_ARTIFACT",
        value: identityPath),
      DevEnvShellOp(kind: deskSetEnv, name: "REPRO_TOOL_PROFILE_INSPECTION",
        value: inspectionPath),
      DevEnvShellOp(kind: deskSetEnv, name: "REPRO_PROJECT_INTERFACE",
        value: interfacePath),
      DevEnvShellOp(kind: deskSetEnv, name: "REPRO_PROJECT_ROOT",
        value: canonicalProjectRoot)
    ])
  runActivatedCommand(artifact, "", command, canonicalProjectRoot)

proc valueAfterFlag(args: openArray[string]; flag: string): string =
  var i = 0
  while i < args.len:
    if args[i] == flag and i + 1 < args.len:
      return args[i + 1]
    inc i
  ""

proc navigatorStatsJson(stats: DevEnvNavigatorStats): JsonNode =
  %*{
    "envelopeBytesChecked": stats.envelopeBytesChecked,
    "payloadBytesHashed": stats.payloadBytesHashed,
    "payloadHeaderBytesRead": stats.payloadHeaderBytesRead,
    "shellOpRecordsDecoded": stats.shellOpRecordsDecoded,
    "taskRecordsDecoded": stats.taskRecordsDecoded,
    "serviceRecordsDecoded": stats.serviceRecordsDecoded,
    "maxDecodedPayloadOffset": stats.maxDecodedPayloadOffset,
    "shellOpsSectionStart": stats.shellOpsSectionStart,
    "shellOpsSectionEnd": stats.shellOpsSectionEnd,
    "tasksSectionStart": stats.tasksSectionStart,
    "servicesSectionStart": stats.servicesSectionStart
  }

proc runProviderCompileHelper(args: openArray[string]): int =
  let modulePath = valueAfterFlag(args, "--module")
  let outputPath = valueAfterFlag(args, "--out")
  let artifactPath = valueAfterFlag(args, "--artifact")
  let interfacePath = valueAfterFlag(args, "--interface")
  let workDir = valueAfterFlag(args, "--work-dir")
  let scratchDir = valueAfterFlag(args, "--scratch-dir")
  for (name, value) in [
    ("--module", modulePath),
    ("--out", outputPath),
    ("--artifact", artifactPath),
    ("--interface", interfacePath),
    ("--work-dir", workDir)
  ]:
    if value.len == 0:
      stderr.writeLine("repro provider compile: missing " & name)
      return 2
  try:
    let interfaceArtifact = readInterfaceArtifact(interfacePath)
    discard compileProviderBinary(modulePath, outputPath,
      interfaceArtifact.interfaceFingerprint, artifactPath, workDir, scratchDir)
    return 0
  except CatchableError as err:
    stderr.writeLine("repro provider compile: error: " & err.msg)
    return 1

proc splitDevEnvActivities(value: string): seq[string] =
  let source = if value.len > 0: value else: "default"
  for raw in source.split(','):
    let item = raw.strip()
    if item.len > 0:
      result.add(item)
  if result.len == 0:
    result.add("default")

proc descriptorById(manifest: ProviderManifest; id: string):
    Option[GraphEntryPointDescriptor] =
  for descriptor in manifest.entryPoints:
    if descriptor.id == id:
      return some(descriptor)
  none(GraphEntryPointDescriptor)

proc validateDevEnvManifest(manifest: ProviderManifest;
                            providerArtifactId: string) =
  if manifest.protocolVersion != ProviderProtocolVersion:
    raise newException(ValueError, "unsupported provider protocol version " &
      $manifest.protocolVersion)
  if providerArtifactId.len > 0 and
      manifest.providerArtifactId != providerArtifactId:
    raise newException(ValueError,
      "provider manifest artifact mismatch: expected " &
        providerArtifactId & ", got " & manifest.providerArtifactId)

proc runStableProviderProtocol(binaryPath, protocolRoot, stem, cwd: string;
                               request: ProviderGraphRequest):
                               ProviderGraphResponse =
  createDir(extendedPath(protocolRoot))
  let requestPath = protocolRoot / (stem & ".request.rbpg")
  let responsePath = protocolRoot / (stem & ".response.rbpg")
  writeProviderRequestFile(requestPath, request)
  if fileExists(extendedPath(responsePath)):
    removeFile(extendedPath(responsePath))
  let argv = @[
    binaryPath,
    "--repro-provider-request", requestPath,
    "--repro-provider-response", responsePath]
  # M8 stderr-truncation fix: previously used
  # ``startProcess + outputStream.readAll + waitForExit`` to drive the
  # provider here too, with the same symptom — diagnostics from the
  # standard provider arrived truncated to a single byte on Windows.
  # See the matching switch in
  # ``libs/repro_provider_runtime/src/repro_provider_runtime/runtime.nim``
  # for the full audit. ``execCmdEx`` drains incrementally via
  # ``readLine`` + ``peekExitCode``.
  #
  # Windows grandchild evidence: ``startProcess`` here used to spawn
  # the provider through Nim's ``winlean.createProcessW`` (a
  # ``nimGetProcAddr``-resolved pointer that bypasses the shim's IAT
  # hook), so the provider grandchild ran naked and its CRT-mediated
  # ``CreateFileW`` calls never recorded into the fragment dir. M72
  # closes that gap at the shim layer by inline-detouring
  # ``kernel32!CreateProcessW`` (``ct_inline_hook_install``); every
  # call to CreateProcessW — IAT-routed, dynlib-resolved, or anything
  # else — now lands in ``trampolineCreateProcessW``, whose
  # ``snoopCreateProcessW`` re-injects the shim into the grandchild
  # via the same ``CreateRemoteThread(LoadLibraryW)`` flow
  # ``repro-fs-snoop`` uses to seed the top-level child. No
  # subprocess-spawn-site rewrite needed here.
  let (output, exitCode) = execCmdEx(quoteShellCommand(argv),
    options = {poStdErrToStdOut, poUsePath},
    workingDir = cwd)
  if exitCode != 0:
    raise newException(OSError,
      "provider exited with code " & $exitCode & ": " & output)
  if not fileExists(extendedPath(responsePath)):
    raise newException(IOError, "provider did not write response: " &
      responsePath)
  readProviderResponseFile(responsePath)

proc runDevEnvIntrospectionHelper(args: openArray[string]): int =
  let providerBinary = valueAfterFlag(args, "--provider-binary")
  let providerArtifactId = valueAfterFlag(args, "--provider-artifact-id")
  let projectRoot = valueAfterFlag(args, "--project-root")
  let artifactPath = valueAfterFlag(args, "--out")
  let protocolRoot = valueAfterFlag(args, "--protocol-root")
  let entryPointId = valueAfterFlag(args, "--entry-point")
  let activity = valueAfterFlag(args, "--activity")
  let lockSliceId = valueAfterFlag(args, "--lock-slice")
  let developOverridesPath = valueAfterFlag(args, "--develop-overrides")
  for (name, value) in [
    ("--provider-binary", providerBinary),
    ("--provider-artifact-id", providerArtifactId),
    ("--project-root", projectRoot),
    ("--out", artifactPath),
    ("--protocol-root", protocolRoot)
  ]:
    if value.len == 0:
      stderr.writeLine("repro dev-env introspection: missing " & name)
      return 2
  try:
    if developOverridesPath.len > 0:
      putEnv("REPRO_DEVELOP_OVERRIDES_FILE", developOverridesPath)
    let cwd = if projectRoot.len > 0: projectRoot else: getCurrentDir()
    let manifestResponse = runStableProviderProtocol(providerBinary,
      protocolRoot, "manifest", cwd, ProviderGraphRequest(
        kind: prkManifest,
        providerArtifactId: providerArtifactId,
        reason: girExplicitUserRequest))
    if manifestResponse.kind != pskManifest:
      raise newException(ValueError,
        "provider manifest request returned non-manifest response")
    validateDevEnvManifest(manifestResponse.manifest, providerArtifactId)

    var selectedEntryPoint = entryPointId
    if selectedEntryPoint.len == 0:
      for descriptor in manifestResponse.manifest.entryPoints:
        if descriptor.kind == gpkDevEnvIntrospection:
          selectedEntryPoint = descriptor.id
          break
    if selectedEntryPoint.len == 0:
      raise newException(ValueError,
        "provider manifest does not expose dev-env introspection")
    let descriptorOpt = manifestResponse.manifest.descriptorById(
      selectedEntryPoint)
    if descriptorOpt.isNone:
      raise newException(ValueError,
        "dev-env entry point is missing from provider manifest")
    let descriptor = descriptorOpt.get()
    if descriptor.kind != gpkDevEnvIntrospection:
      raise newException(ValueError,
        "entry point is not dev-env introspection: " & selectedEntryPoint)

    let selectedActivity = if activity.len > 0: activity else: "default"
    let request = ProviderGraphRequest(
      kind: prkDevEnvIntrospection,
      providerArtifactId: providerArtifactId,
      entryPointId: selectedEntryPoint,
      entryPointBodyHash: descriptor.bodyHash,
      reason: girExplicitUserRequest,
      arguments: projectRoot,
      lockSliceId: lockSliceId,
      activity: selectedActivity)
    let response = runStableProviderProtocol(providerBinary, protocolRoot,
      "dev-env", cwd, request)
    if response.kind != pskDevEnvResult:
      raise newException(ValueError,
        "provider dev-env request did not return a dev-env result")
    validateDevEnvManifest(response.manifest, providerArtifactId)
    if response.devEnv.providerArtifactId != providerArtifactId:
      raise newException(ValueError, "provider artifact mismatch in dev-env result")
    if response.devEnv.providerEntryPointId != selectedEntryPoint:
      raise newException(ValueError, "provider entry point mismatch in dev-env result")
    if response.devEnv.providerEntryPointBodyHash != descriptor.bodyHash:
      raise newException(ValueError, "provider body hash mismatch in dev-env result")
    if response.devEnv.projectRoot != projectRoot:
      raise newException(ValueError, "project root mismatch in dev-env result")
    if response.devEnv.lockSliceId != lockSliceId:
      raise newException(ValueError, "lock slice mismatch in dev-env result")
    if response.devEnv.selectedActivities !=
        splitDevEnvActivities(selectedActivity):
      raise newException(ValueError, "activity selection mismatch in dev-env result")

    writeDevEnvArtifact(artifactPath, artifactFromDevEnvResult(response.devEnv))
    return 0
  except CatchableError as err:
    stderr.writeLine("repro dev-env introspection: error: " & err.msg)
    return 1

proc runDevEnvShellRenderHelper(args: openArray[string]): int =
  let artifactPath = valueAfterFlag(args, "--artifact")
  let outputPath = valueAfterFlag(args, "--out")
  let navigatorStatsPath = valueAfterFlag(args, "--navigator-stats")
  for (name, value) in [
    ("--artifact", artifactPath),
    ("--out", outputPath)
  ]:
    if value.len == 0:
      stderr.writeLine("repro dev-env shell render: missing " & name)
      return 2
  try:
    var navigatorStats: DevEnvNavigatorStats
    let ops = shellOpsFromNavigatorFile(artifactPath, navigatorStats)
    createDir(extendedPath(parentDir(outputPath)))
    writeFile(extendedPath(outputPath), renderDevEnvShellOps(ops, depPosix))
    if navigatorStatsPath.len > 0:
      createDir(extendedPath(parentDir(navigatorStatsPath)))
      writeFile(extendedPath(navigatorStatsPath),
        pretty(navigatorStatsJson(navigatorStats)) & "\n")
    return 0
  except CatchableError as err:
    stderr.writeLine("repro dev-env shell render: error: " & err.msg)
    return 1

type
  DevelopOverrideEntry = object
    node: string
    path: string

  DevEnvCliSelection = object
    selector: string
    modulePath: string
    projectRoot: string
    outDir: string
    workRoot: string
    activity: string
    lockSliceId: string
    developOverridesPath: string
    statsPath: string

  ParsedDevEnvExec = object
    selection: DevEnvCliSelection
    command: seq[string]

  ParsedDevEnvShell = object
    selection: DevEnvCliSelection
    printEnv: bool
    printFormat: DevEnvPrintFormat
    shellPath: string

proc valueFromFlag(args: openArray[string]; i: var int; flag: string): string =
  let arg = args[i]
  if arg.startsWith(flag & "="):
    return arg.split("=", maxsplit = 1)[1]
  if arg == flag:
    if i + 1 >= args.len:
      raise newException(ValueError, flag & " requires a value")
    inc i
    return args[i]
  ""

proc appendActivitySelection(current: var string; value: string) =
  for raw in value.split(','):
    let item = raw.strip()
    if item.len == 0:
      continue
    if current.len == 0:
      current = item
    elif current.split(',').find(item) < 0:
      current.add("," & item)

proc gitDirForProjectRoot(projectRoot: string): string =
  let dotGit = projectRoot / ".git"
  if dirExists(extendedPath(dotGit)):
    return dotGit
  if fileExists(extendedPath(dotGit)):
    let content = readFile(extendedPath(dotGit)).strip()
    const prefix = "gitdir:"
    if content.normalize().startsWith(prefix):
      let raw = content[prefix.len .. ^1].strip()
      if raw.isAbsolute:
        return os.normalizedPath(raw)
      return os.normalizedPath(projectRoot / raw)
  ""

proc developOverridesMetadataPath(projectRoot: string): string =
  let gitDir = gitDirForProjectRoot(projectRoot)
  if gitDir.len > 0:
    return gitDir / "reprobuild" / "develop-overrides.json"
  projectRoot / ".repro" / "local" / "develop-overrides.json"

proc readDevelopOverrides(path: string): seq[DevelopOverrideEntry] =
  if path.len == 0 or not fileExists(extendedPath(path)):
    return @[]
  let root = parseFile(extendedPath(path))
  if root.kind != JObject or not root.hasKey("overrides"):
    return @[]
  for item in root["overrides"]:
    if item.kind != JObject:
      continue
    let node = item{"node"}.getStr()
    let localPath = item{"path"}.getStr()
    if node.len > 0 and localPath.len > 0:
      result.add(DevelopOverrideEntry(node: node, path: localPath))

proc writeDevelopOverrides(path, projectRoot: string;
                           entries: openArray[DevelopOverrideEntry]) =
  var sorted = @entries
  sorted.sort(proc (a, b: DevelopOverrideEntry): int = cmp(a.node, b.node))
  var overrides = newJArray()
  for entry in sorted:
    overrides.add(%*{
      "node": entry.node,
      "path": entry.path
    })
  let payload = %*{
    "schemaId": "reprobuild.develop-overrides.v1",
    "projectRoot": projectRoot,
    "overrides": overrides
  }
  createDir(extendedPath(parentDir(path)))
  let tmp = path & ".tmp"
  writeFile(extendedPath(tmp), pretty(payload) & "\n")
  if fileExists(extendedPath(path)):
    removeFile(extendedPath(path))
  moveFile(extendedPath(tmp), extendedPath(path))

proc findDevEnvProjectRoot(startPath: string): string

proc activeProjectRootFromCwd(): string =
  result = findDevEnvProjectRoot(getCurrentDir())
  if result.len == 0:
    raise newException(ValueError,
      "repro develop requires a current project containing " &
        CanonicalProjectFileName & " (or legacy " &
        LegacyProjectFileName & ")")

proc resolveDevelopOverrideCheckout(dependency, intoPath: string): string =
  if intoPath.len == 0:
    raise newException(ValueError,
      "repro develop <dependency> requires --into=PATH for local overrides")
  let intoAbs = os.normalizedPath(absolutePath(intoPath))
  var candidates = @[intoAbs]
  let (_, tail) = splitPath(intoAbs)
  if tail != dependency:
    candidates.add(intoAbs / safePathSegment(dependency, "dependency"))
  for candidate in candidates:
    # Project-file alias: probe for either ``repro.nim`` or
    # ``reprobuild.nim``.
    if resolveProjectFile(candidate).path.len > 0:
      return os.normalizedPath(candidate)
  raise newException(IOError,
    "develop override checkout for " & dependency &
      " must already exist and contain " & CanonicalProjectFileName &
      " (or legacy " & LegacyProjectFileName & ") under " &
      candidates.join(" or "))

proc upsertDevelopOverride(projectRoot, dependency, localPath: string): string =
  result = developOverridesMetadataPath(projectRoot)
  var entries = readDevelopOverrides(result)
  var replaced = false
  for entry in entries.mitems:
    if entry.node == dependency:
      entry.path = localPath
      replaced = true
  if not replaced:
    entries.add(DevelopOverrideEntry(node: dependency, path: localPath))
  writeDevelopOverrides(result, projectRoot, entries)

proc devEnvActivitySegment(activity: string): string =
  safePathSegment(if activity.len > 0: activity else: "default", "default")

proc defaultDevEnvOutDir(modulePath, workRoot, activity: string): string =
  let scopedRoot = scopedWorktreeRoot(modulePath, workRoot)
  if scopedRoot.len > 0:
    return scopedRoot / "dev-env" / devEnvActivitySegment(activity)
  parentDir(modulePath) / ".repro" / "dev-env" /
    devEnvActivitySegment(activity)

proc resolveDevEnvSelection(selection: var DevEnvCliSelection) =
  if selection.selector.len == 0:
    selection.selector = "."
  if selection.activity.len == 0:
    selection.activity = "default"
  selection.modulePath = absolutePath(moduleForTarget(selection.selector))
  if not fileExists(extendedPath(selection.modulePath)):
    raise newException(IOError,
      "dev-env target module not found: " & selection.modulePath)
  selection.projectRoot = projectRootForModule(selection.modulePath)
  selection.developOverridesPath =
    developOverridesMetadataPath(selection.projectRoot)
  selection.outDir = defaultDevEnvOutDir(selection.modulePath,
    selection.workRoot, selection.activity)

proc parseDevEnvExecArgs(args: openArray[string]): ParsedDevEnvExec =
  var selection = DevEnvCliSelection()
  var afterSeparator = false
  var i = 0
  while i < args.len:
    let arg = args[i]
    if afterSeparator:
      result.command.add(arg)
    elif arg == "--":
      afterSeparator = true
    elif arg == "--activity" or arg.startsWith("--activity="):
      selection.activity.appendActivitySelection(valueFromFlag(args, i,
        "--activity"))
    elif arg == "--work-root" or arg.startsWith("--work-root="):
      selection.workRoot = valueFromFlag(args, i, "--work-root")
    elif arg == "--lock-slice" or arg.startsWith("--lock-slice="):
      selection.lockSliceId = valueFromFlag(args, i, "--lock-slice")
    elif arg == "--dev-env-stats" or arg.startsWith("--dev-env-stats="):
      selection.statsPath = valueFromFlag(args, i, "--dev-env-stats")
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported exec flag: " & arg)
    elif selection.selector.len == 0:
      selection.selector = arg
    else:
      raise newException(ValueError,
        "unexpected exec argument before --: " & arg)
    inc i
  if result.command.len == 0:
    raise newException(ValueError,
      "repro exec requires -- <command> [args...]")
  selection.resolveDevEnvSelection()
  result.selection = selection

proc parseDevEnvShellArgs(args: openArray[string]): ParsedDevEnvShell =
  var selection = DevEnvCliSelection()
  result.printFormat = depPosix
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--activity" or arg.startsWith("--activity="):
      selection.activity.appendActivitySelection(valueFromFlag(args, i,
        "--activity"))
    elif arg == "--work-root" or arg.startsWith("--work-root="):
      selection.workRoot = valueFromFlag(args, i, "--work-root")
    elif arg == "--lock-slice" or arg.startsWith("--lock-slice="):
      selection.lockSliceId = valueFromFlag(args, i, "--lock-slice")
    elif arg == "--dev-env-stats" or arg.startsWith("--dev-env-stats="):
      selection.statsPath = valueFromFlag(args, i, "--dev-env-stats")
    elif arg == "--shell" or arg.startsWith("--shell="):
      result.shellPath = valueFromFlag(args, i, "--shell")
    elif arg == "--print-env" or arg.startsWith("--print-env="):
      result.printEnv = true
      result.printFormat = parseDevEnvPrintFormat(valueFromFlag(args, i,
        "--print-env"))
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported shell flag: " & arg)
    elif selection.selector.len == 0:
      selection.selector = arg
    else:
      raise newException(ValueError,
        "unexpected shell argument: " & arg)
    inc i
  selection.resolveDevEnvSelection()
  result.selection = selection

proc publicDevEnvFsSnoop(publicCliPath: string):
    tuple[path: string, args: seq[string]] =
  ## Executable-Consolidation M1: the dev-env monitor self-spawns the ``repro``
  ## image (``internal fs-snoop`` selector returned in ``args``, threaded via
  ## ``DevEnvEdgeConfig.monitorCliArgs``) rather than locating a standalone
  ## ``repro-fs-snoop`` binary. ``REPRO_FS_SNOOP`` is still honored as an
  ## override escape hatch for tests / custom monitor drivers; when set it is a
  ## standalone driver path used with NO extra subcommand args.
  let override = getEnv("REPRO_FS_SNOOP")
  if override.len > 0:
    return (override, @[])
  (selfSpawnFsSnoopPath(), internalFsSnoopArgs)

proc computePublicDevEnv(selection: DevEnvCliSelection;
                         publicCliPath: string;
                         renderShell = false): DevEnvEdgeResult =
  let monitor = publicDevEnvFsSnoop(publicCliPath)
  computeDevEnvEdge(DevEnvEdgeConfig(
    modulePath: selection.modulePath,
    projectRoot: selection.projectRoot,
    outDir: selection.outDir,
    workDir: reprobuildLibraryWorkDir(),
    publicCliPath: publicCliPath,
    monitorCliPath: monitor.path,
    monitorCliArgs: monitor.args,
    monitorShimLibPath: getEnv("REPRO_MONITOR_SHIM_LIB"),
    activity: selection.activity,
    lockSliceId: selection.lockSliceId,
    developOverridesPath: selection.developOverridesPath,
    renderShell: renderShell,
    statsEnabled: selection.statsPath.len > 0))

proc devEnvPerformanceEvidenceJson(edge: DevEnvEdgeResult): JsonNode =
  let devStats = edge.devEnvResult.stats
  let compileStats = edge.providerCompileResult.stats
  let introspectionInputs = edge.introspectionAction.evidence.evidenceInputCount()
  let shellInputs = edge.shellRenderAction.evidence.evidenceInputCount()
  let shellRenderPresent = edge.shellRenderAction.actionPresent()
  %*{
    "schemaId": "reprobuild.dev-env.performance-evidence.v1",
    "providerBuild": {
      "checks": 1,
      "launched": edge.stats.providerBuildLaunched,
      "skippedFresh": edge.stats.providerBuildSkippedFresh,
      "cacheHit": edge.stats.providerBuildCacheHit,
      "actionPresent": edge.providerCompileAction.actionPresent(),
      "actionStatus": $edge.providerCompileAction.status,
      "cacheLookupCount": compileStats.metricCount("repro cache lookup"),
      "cacheLookupTotalUs": compileStats.metricTotalUs("repro cache lookup"),
      "hotInputScanCount": compileStats.metricCount("repro hot input scan"),
      "outputStatCount": compileStats.metricCount("repro output stat"),
      "runBuildTotalUs": compileStats.metricTotalUs("repro scheduler total")
    },
    "providerIntrospection": {
      "actions": 1,
      "launched": edge.stats.providerIntrospectionLaunched,
      "cacheHit": edge.stats.providerIntrospectionCacheHit,
      "actionStatus": $edge.introspectionAction.status,
      "cacheDecision": $edge.introspectionAction.cacheDecision,
      "evidenceInputPathCount": introspectionInputs,
      "declaredInputCount": edge.introspectionAction.evidence.declaredInputs.len,
      "monitorReadCount": edge.introspectionAction.evidence.monitorReads.len,
      "monitorProbeCount": edge.introspectionAction.evidence.monitorProbes.len
    },
    "artifactLookup": {
      "artifactPath": edge.artifactPath,
      "artifactBytes": edge.artifactPath.fileSizeOrZero(),
      "artifactWriteLaunched": edge.stats.artifactWriteLaunched,
      "artifactWriteSkipped": edge.stats.artifactWriteSkipped,
      "introspectionCacheHit": edge.stats.providerIntrospectionCacheHit
    },
    "invalidation": {
      "cacheLookupCount": devStats.metricCount("repro cache lookup"),
      "cacheLookupTotalUs": devStats.metricTotalUs("repro cache lookup"),
      "hotRecordLookupCount": devStats.metricCount("repro hot record lookup"),
      "hotRecordLookupTotalUs": devStats.metricTotalUs("repro hot record lookup"),
      "hotInputScanCount": devStats.metricCount("repro hot input scan"),
      "hotInputScanTotalUs": devStats.metricTotalUs("repro hot input scan"),
      "fastNoopScanCount": devStats.metricCount("repro fast noop scan"),
      "fastNoopScanTotalUs": devStats.metricTotalUs("repro fast noop scan"),
      "outputStatCount": devStats.metricCount("repro output stat"),
      "checkedInputPathCount": introspectionInputs + shellInputs,
      "cacheHitResultMaterializeCount":
        devStats.metricCount("repro cache hit result materialize")
    },
    "shellRender": {
      "actions": if shellRenderPresent: 1 else: 0,
      "launched": edge.stats.shellRenderingLaunched,
      "cacheHit": edge.stats.shellRenderingCacheHit,
      "skipped": edge.stats.shellRenderingSkipped,
      "actionStatus": $edge.shellRenderAction.status,
      "cacheDecision": $edge.shellRenderAction.cacheDecision,
      "evidenceInputPathCount": shellInputs,
      "shellFragmentPath": edge.shellFragmentPath,
      "shellFragmentBytes": edge.shellFragmentPath.fileSizeOrZero(),
      "navigatorStatsPath": edge.shellNavigatorStatsPath,
      "navigatorStatsBytes": edge.shellNavigatorStatsPath.fileSizeOrZero()
    }
  }

proc devEnvStatsJson(edge: DevEnvEdgeResult; commandName: string): JsonNode =
  let navigatorStats =
    if edge.shellNavigatorStatsPath.len > 0 and fileExists(
        extendedPath(edge.shellNavigatorStatsPath)):
      parseFile(extendedPath(edge.shellNavigatorStatsPath))
    else:
      newJNull()
  %*{
    "schemaId": "reprobuild.dev-env.cli-stats.v1",
    "command": commandName,
    "artifactPath": edge.artifactPath,
    "shellFragmentPath": edge.shellFragmentPath,
    "shellNavigatorStatsPath": edge.shellNavigatorStatsPath,
    "shellNavigatorStats": navigatorStats,
    "providerArtifactPath": edge.providerArtifactPath,
    "providerBinaryPath": edge.providerBinaryPath,
    "providerArtifactId": edge.providerArtifactId,
    "stats": {
      "providerBuildLaunched": edge.stats.providerBuildLaunched,
      "providerBuildSkippedFresh": edge.stats.providerBuildSkippedFresh,
      "providerBuildCacheHit": edge.stats.providerBuildCacheHit,
      "providerIntrospectionLaunched": edge.stats.providerIntrospectionLaunched,
      "providerIntrospectionCacheHit": edge.stats.providerIntrospectionCacheHit,
      "artifactWriteLaunched": edge.stats.artifactWriteLaunched,
      "artifactWriteSkipped": edge.stats.artifactWriteSkipped,
      "shellRenderingLaunched": edge.stats.shellRenderingLaunched,
      "shellRenderingCacheHit": edge.stats.shellRenderingCacheHit,
      "shellRenderingSkipped": edge.stats.shellRenderingSkipped
    },
    "providerCompileAction": actionResultJson(edge.providerCompileAction),
    "introspectionAction": actionResultJson(edge.introspectionAction),
    "shellRenderAction": actionResultJson(edge.shellRenderAction),
    "providerCompileRunStats": statsJson(edge.providerCompileResult.stats),
    "devEnvRunStats": statsJson(edge.devEnvResult.stats),
    "performance": devEnvPerformanceEvidenceJson(edge)
  }

proc writeDevEnvStats(path: string; edge: DevEnvEdgeResult;
                      commandName: string) =
  if path.len == 0:
    return
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), $devEnvStatsJson(edge, commandName) & "\n")

proc emitDevEnvDiagnostics(artifact: DevEnvArtifact): bool =
  ## Returns true when an error diagnostic was emitted.
  for diagnostic in artifact.diagnostics:
    if diagnostic.severity == dedsInfo:
      continue
    let prefix =
      case diagnostic.severity
      of dedsInfo: "info"
      of dedsWarning: "warning"
      of dedsError: "error"
    stderr.writeLine("repro dev-env: " & prefix & ": " &
      diagnostic.message)
    if diagnostic.severity == dedsError:
      result = true

proc runReproExecCommand(args: openArray[string];
                         publicCliPath: string): int =
  let parsed = parseDevEnvExecArgs(args)
  let edge = computePublicDevEnv(parsed.selection, publicCliPath)
  writeDevEnvStats(parsed.selection.statsPath, edge, "exec")
  let artifact = readDevEnvArtifact(edge.artifactPath)
  if emitDevEnvDiagnostics(artifact):
    return 1
  runActivatedCommand(artifact, edge.artifactPath, parsed.command,
    parsed.selection.projectRoot)

proc defaultInteractiveShell(): string =
  when defined(windows):
    let comspec = getEnv("COMSPEC")
    if comspec.len > 0:
      return comspec
    let pwsh = findExe("pwsh")
    if pwsh.len > 0:
      return pwsh
    "powershell"
  else:
    getEnv("SHELL", "/bin/sh")

proc runReproShellCommand(args: openArray[string];
                          publicCliPath: string): int =
  let parsed = parseDevEnvShellArgs(args)
  let edge = computePublicDevEnv(parsed.selection, publicCliPath)
  writeDevEnvStats(parsed.selection.statsPath, edge, "shell")
  let artifact = readDevEnvArtifact(edge.artifactPath)
  if emitDevEnvDiagnostics(artifact):
    return 1
  if parsed.printEnv:
    stdout.write(renderDevEnvArtifact(artifact, edge.artifactPath,
      parsed.printFormat))
    return 0
  let shellPath =
    if parsed.shellPath.len > 0:
      parsed.shellPath
    else:
      defaultInteractiveShell()
  spawnActivatedShell(artifact, edge.artifactPath, shellPath,
    parsed.selection.projectRoot)

# M74 — ``repro dev-env export <shell>``.
#
# This is the inner CLI of the Shell-Direnv-Hook plan. The fast-path
# cache-key check arrives in M77; this milestone always walks the
# dev-env edge. The architecture is:
#
#   1. Parse positional ``<shell>`` first (so unknown shells fail with
#      exit 2 BEFORE we touch the filesystem).
#   2. Parse flags (``--project-root``, ``--activity``,
#      ``--develop-overrides``, ``--allow-stale``).
#   3. Resolve project root: explicit flag wins; else walk up from
#      ``$PWD`` for ``repro.nim`` / ``reprobuild.nim`` / ``.repro/``.
#   4. Walk the dev-env edge via ``computePublicDevEnv``.
#   5. Read the RBDE artifact, convert to ``ExportPlan``, append the
#      ``__REPRO_APPLIED`` marker, format, write to stdout.
type
  ParsedDevEnvExport = object
    shell: ShellKind
    projectRoot: string
    activity: string
    developOverridesPath: string
    allowStale: bool
    preActivationEnvPath: string

proc parseDevEnvExportArgs(args: openArray[string]): ParsedDevEnvExport =
  if args.len == 0:
    raise newException(ValueError,
      "repro dev-env export requires a shell argument " &
        "(bash|zsh|fish|nushell|pwsh)")
  result.shell = parseShellKind(args[0])
  var i = 1
  while i < args.len:
    let arg = args[i]
    if arg == "--project-root" or arg.startsWith("--project-root="):
      result.projectRoot = valueFromFlag(args, i, "--project-root")
    elif arg == "--activity" or arg.startsWith("--activity="):
      result.activity = valueFromFlag(args, i, "--activity")
    elif arg == "--develop-overrides" or
        arg.startsWith("--develop-overrides="):
      result.developOverridesPath =
        valueFromFlag(args, i, "--develop-overrides")
    elif arg == "--allow-stale":
      result.allowStale = true
    elif arg == "--pre-activation-env" or
        arg.startsWith("--pre-activation-env="):
      # M75 — shell hook writes its env to this file before calling
      # ``export`` so the rollback manifest captures the SHELL's env,
      # not the spawned child's env. Optional; when absent we fall
      # back to the child process's own env (graceful-degradation
      # path used by direct CLI invocation outside the hook).
      result.preActivationEnvPath =
        valueFromFlag(args, i, "--pre-activation-env")
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported dev-env export flag: " & arg)
    else:
      raise newException(ValueError,
        "unexpected dev-env export argument: " & arg)
    inc i
  if result.activity.len == 0:
    result.activity = "default"

proc artifactIdFingerprint(artifact: DevEnvArtifact): string =
  ## Deterministic, content-derived. The artifact's ``artifactId`` is
  ## the canonical SSZ hash the codec computes; same bytes -> same
  ## fingerprint across runs / hosts.
  result = newStringOfCap(64)
  for b in artifact.artifactId:
    result.add(toHex(int(b), 2).toLowerAscii())

proc runDevEnvExportCommand(args: openArray[string];
                            publicCliPath: string): int =
  ## ``repro dev-env export <shell>`` dispatch arm. Exit codes:
  ##   0 — success
  ##   1 — engine error (project not found, edge failure, ...)
  ##   2 — usage error (unknown shell, bad flag)
  var parsed: ParsedDevEnvExport
  try:
    parsed = parseDevEnvExportArgs(args)
  except ExportPlanError as err:
    stderr.writeLine("repro dev-env export: " & err.msg)
    return 2
  except ValueError as err:
    stderr.writeLine("repro dev-env export: " & err.msg)
    return 2

  if parsed.projectRoot.len == 0:
    parsed.projectRoot = findDevEnvProjectRoot(getCurrentDir())
    if parsed.projectRoot.len == 0:
      stderr.writeLine("repro dev-env export: no project root found; " &
        "expected " & CanonicalProjectFileName & " or " &
        LegacyProjectFileName &
        " in the current directory or one of its parents")
      return 1
  else:
    parsed.projectRoot = os.normalizedPath(absolutePath(parsed.projectRoot))

  # M77 — cache-key fast path. BEFORE the project file is even
  # resolved or the selection's heavy ``resolveDevEnvSelection`` runs,
  # hash the cache-key inputs and compare against ``$__REPRO_APPLIED``.
  # On a match, emit the per-shell no-op script and exit 0 without
  # touching the build engine, the project-interface extractor, or
  # the develop-overrides resolver.
  #
  # Variable choice: the spec memo separates ``REPRO_APPLIED`` (the
  # fast-path env var) from ``__REPRO_APPLIED`` (the activation
  # marker). M77 collapses them onto the single ``__REPRO_APPLIED``
  # name: the marker the activation script sets IS the cache key, the
  # hook never has to copy it across env vars, and there is no
  # observable difference between "applied" and "would short-circuit".
  # The cost is one env-var slot of namespace overhead on the user's
  # shell, which is already paid for by the marker.
  let fastPathOverridesPath =
    if parsed.developOverridesPath.len > 0:
      os.normalizedPath(absolutePath(parsed.developOverridesPath))
    else:
      developOverridesMetadataPath(parsed.projectRoot)
  let fastPathConfig = DevEnvEdgeConfig(
    projectRoot: parsed.projectRoot,
    activity:
      if parsed.activity.len > 0: parsed.activity else: "default",
    developOverridesPath: fastPathOverridesPath)
  let candidateKey = computeDevEnvEdgeCacheKey(fastPathConfig)
  let activeKey = getEnv("__REPRO_APPLIED")
  if not parsed.allowStale and activeKey.len > 0 and
      candidateKey == activeKey:
    stdout.write(emitFastPathNoOpScript(parsed.shell))
    return 0

  let resolved = resolveProjectFile(parsed.projectRoot)
  if resolved.path.len == 0:
    stderr.writeLine("repro dev-env export: " & parsed.projectRoot &
      " does not contain " & CanonicalProjectFileName & " or " &
      LegacyProjectFileName)
    return 1

  var selection = DevEnvCliSelection(
    selector: parsed.projectRoot,
    activity: parsed.activity)
  try:
    selection.resolveDevEnvSelection()
  except CatchableError as err:
    stderr.writeLine("repro dev-env export: " & err.msg)
    return 1
  if parsed.developOverridesPath.len > 0:
    selection.developOverridesPath =
      os.normalizedPath(absolutePath(parsed.developOverridesPath))

  let edge =
    try:
      computePublicDevEnv(selection, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro dev-env export: " & err.msg)
      return 1
  let artifact = readDevEnvArtifact(edge.artifactPath)
  if not parsed.allowStale and emitDevEnvDiagnostics(artifact):
    return 1

  var plan = devEnvArtifactToExportPlan(edge.artifactPath)
  # M77 — emit the cache-key as the ``__REPRO_APPLIED`` marker. The
  # next prompt's fast path re-derives the same key from on-disk
  # inputs and compares; a match short-circuits without any build
  # engine work. Using the cache key (not the SSZ artifact ID) is what
  # makes the fast path actually fast.
  let fingerprint = candidateKey
  let manifestPath = rollbackManifestPath(edge.artifactPath)
  # M75 — emit the manifest path as a marker BEFORE the
  # ``__REPRO_APPLIED`` fingerprint so the hook's deactivation arm
  # can locate the manifest via ``$__REPRO_ACTIVE_MANIFEST`` on the
  # next cd-out.
  plan.appendReproActiveManifestMarker(manifestPath)
  plan.appendReproAppliedMarker(fingerprint)
  let activationScript = formatExportPlan(plan, parsed.shell)

  # M75 — write the rollback manifest alongside the RBDE artifact.
  let preEnv =
    if parsed.preActivationEnvPath.len > 0:
      try:
        readPreActivationEnv(parsed.preActivationEnvPath)
      except CatchableError as err:
        stderr.writeLine("repro dev-env export: " & err.msg)
        return 1
    else:
      snapshotProcessEnv()
  let manifest = buildRollbackManifest(plan, preEnv, fingerprint,
    activationScript, parsed.shell)
  try:
    writeRollbackManifest(manifestPath, manifest)
  except CatchableError as err:
    stderr.writeLine("repro dev-env export: " & err.msg)
    return 1

  stdout.write(activationScript)
  0

# M75 — ``repro dev-env deactivate <rollback-manifest>``.
#
# Reads the manifest, walks its ``vars`` array in REVERSE order, and
# emits a per-shell script that restores the pre-activation values
# of every var the matching activation touched. Tamper detection:
# the deactivation emitter re-derives the activation script from the
# manifest's referenced RBDE artifact and re-hashes it; mismatch
# means the user has presumably edited their env manually since
# activation. In that case we emit a no-op script + a stderr
# diagnostic and exit with code 3 (distinct from 0 / 1 / 2 so the
# shell hook can branch on it).
type
  ParsedDevEnvDeactivate = object
    manifestPath: string
    shell: ShellKind
    shellSet: bool

proc parseDevEnvDeactivateArgs(args: openArray[string]):
    ParsedDevEnvDeactivate =
  result.shell = skBash
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--shell" or arg.startsWith("--shell="):
      result.shell = parseShellKind(valueFromFlag(args, i, "--shell"))
      result.shellSet = true
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported dev-env deactivate flag: " & arg)
    elif result.manifestPath.len == 0:
      result.manifestPath = arg
    else:
      raise newException(ValueError,
        "unexpected dev-env deactivate argument: " & arg)
    inc i
  if result.manifestPath.len == 0:
    raise newException(ValueError,
      "repro dev-env deactivate requires a rollback manifest path")

proc runDevEnvDeactivateCommand(args: openArray[string]): int =
  ## ``repro dev-env deactivate <rollback-manifest> [--shell=<shell>]``
  ## dispatch arm. Exit codes:
  ##   0 — success
  ##   1 — engine error (manifest / artifact missing or corrupt)
  ##   2 — usage error (unknown shell, missing argument)
  ##   3 — tamper detected (activation hash mismatch)
  var parsed: ParsedDevEnvDeactivate
  try:
    parsed = parseDevEnvDeactivateArgs(args)
  except ExportPlanError as err:
    stderr.writeLine("repro dev-env deactivate: " & err.msg)
    return 2
  except ValueError as err:
    stderr.writeLine("repro dev-env deactivate: " & err.msg)
    return 2

  let manifest =
    try:
      readRollbackManifest(parsed.manifestPath)
    except CatchableError as err:
      stderr.writeLine("repro dev-env deactivate: " & err.msg)
      return 1

  # Locate the RBDE artifact. By construction the manifest path is
  # ``<artifact>.rollback.json``, so strip the suffix to find the
  # artifact. We use this only for the tamper-detection re-hash; the
  # actual rollback data is fully self-contained in the manifest.
  if not parsed.manifestPath.endsWith(".rollback.json"):
    stderr.writeLine("repro dev-env deactivate: manifest path must end " &
      "with '.rollback.json': " & parsed.manifestPath)
    return 1
  let artifactPath = parsed.manifestPath[0 ..< parsed.manifestPath.len -
    ".rollback.json".len]
  if not fileExists(artifactPath):
    stderr.writeLine("repro dev-env deactivate: RBDE artifact missing " &
      "(cannot verify tamper seal): " & artifactPath)
    return 1

  # Tamper detection: re-derive the activation script bytes from the
  # on-disk artifact and re-hash, using the SHELL recorded in the
  # manifest (NOT ``parsed.shell`` — the deactivation caller may
  # request a different shell's deactivation syntax, e.g. user-side
  # ``--shell=pwsh`` against a bash-activated manifest, and the hash
  # seal must compare against the activation-time shell).
  var rederivedPlan = devEnvArtifactToExportPlan(artifactPath)
  rederivedPlan.appendReproActiveManifestMarker(parsed.manifestPath)
  rederivedPlan.appendReproAppliedMarker(manifest.artifact)
  let rederivedScript =
    formatExportPlan(rederivedPlan, manifest.activationShell)
  let rederivedHash = computeActivationScriptHash(rederivedScript)
  if rederivedHash != manifest.activationScriptHash:
    stderr.writeLine("repro dev-env deactivate: tamper detected — " &
      "activation_script_hash mismatch (manifest: " &
      manifest.activationScriptHash & ", recomputed: " &
      rederivedHash & "). Env left as-is.")
    stdout.write(emitNoOpScript(parsed.shell))
    return 3

  stdout.write(formatDeactivate(manifest, parsed.shell))
  0

# M76 — ``repro shell hook <shell>``.
#
# Emits the per-shell hook installation script. The user sources the
# output ONCE at shell start (from ``~/.bashrc`` /
# ``~/.config/fish/config.fish`` / ``$PROFILE`` / etc.). The emitted
# script defines a ``__repro_shell_hook`` function that runs per
# prompt / per cd, walks up from ``$PWD`` for the project root, and
# composes the M74 ``dev-env export`` + M75 ``dev-env deactivate``
# arms to drive activation/deactivation on cd.
#
# This is distinct from ``repro hooks`` (CLI/hooks.md), which manages
# rc-file ENTRIES; ``repro shell hook`` only EMITS the per-shell
# snippet that the user adds to their rc file (or pipes through
# ``eval`` / ``source`` / ``Out-String | Invoke-Expression`` directly).
#
# Exit codes:
#   0 — success
#   2 — usage error (missing/unknown shell argument)
type
  ParsedShellHook = object
    shell: ShellKind
    reproBin: string  ## explicit path; otherwise we autodetect

proc parseShellHookArgs(args: openArray[string]): ParsedShellHook =
  if args.len == 0:
    raise newException(ValueError,
      "repro shell hook requires a shell argument " &
        "(bash|zsh|fish|nushell|pwsh)")
  result.shell = parseShellKind(args[0])
  var i = 1
  while i < args.len:
    let arg = args[i]
    if arg == "--repro-bin" or arg.startsWith("--repro-bin="):
      # Escape hatch for the test surface — embed an explicit absolute
      # path to ``repro.exe`` so the hook does not depend on PATH
      # resolution. Default (empty) means "use the bare ``repro``
      # name and rely on PATH".
      result.reproBin = valueFromFlag(args, i, "--repro-bin")
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported shell hook flag: " & arg)
    else:
      raise newException(ValueError,
        "unexpected shell hook argument: " & arg)
    inc i

proc runShellHookCommand(args: openArray[string]): int =
  ## ``repro shell hook <shell>`` dispatch arm.
  var parsed: ParsedShellHook
  try:
    parsed = parseShellHookArgs(args)
  except ExportPlanError as err:
    stderr.writeLine("repro shell hook: " & err.msg)
    return 2
  except ValueError as err:
    stderr.writeLine("repro shell hook: " & err.msg)
    return 2

  let script =
    case parsed.shell
    of skBash: renderBashHook(parsed.reproBin)
    of skZsh: renderZshHook(parsed.reproBin)
    of skFish: renderFishHook(parsed.reproBin)
    of skNushell: renderNushellHook(parsed.reproBin)
    of skPwsh: renderPwshHook(parsed.reproBin)
  stdout.write(script)
  0

type
  ParsedDevSessionCommand = object
    selection: DevEnvCliSelection
    foreground: bool
    httpBind: string
    debounceMs: int
    force: bool

proc parseDevSessionArgs(args: openArray[string]; commandName: string):
    ParsedDevSessionCommand =
  var selection = DevEnvCliSelection()
  result.httpBind = "127.0.0.1:0"
  result.debounceMs = 250
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--activity" or arg.startsWith("--activity="):
      selection.activity.appendActivitySelection(valueFromFlag(args, i,
        "--activity"))
    elif arg == "--work-root" or arg.startsWith("--work-root="):
      selection.workRoot = valueFromFlag(args, i, "--work-root")
    elif arg == "--lock-slice" or arg.startsWith("--lock-slice="):
      selection.lockSliceId = valueFromFlag(args, i, "--lock-slice")
    elif arg == "--foreground":
      result.foreground = true
    elif arg == "--force":
      result.force = true
    elif arg == "--http" or arg.startsWith("--http="):
      result.httpBind = valueFromFlag(args, i, "--http")
    elif arg == "--debounce-ms" or arg.startsWith("--debounce-ms="):
      result.debounceMs = parseInt(valueFromFlag(args, i, "--debounce-ms"))
      if result.debounceMs < 0:
        raise newException(ValueError, "--debounce-ms must be non-negative")
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported " & commandName & " flag: " & arg)
    elif selection.selector.len == 0:
      selection.selector = arg
    else:
      raise newException(ValueError,
        "unexpected " & commandName & " argument: " & arg)
    inc i
  selection.resolveDevEnvSelection()
  result.selection = selection

proc supervisorConfig(parsed: ParsedDevSessionCommand;
                      edge: DevEnvEdgeResult;
                      publicCliPath: string;
                      mode: DevSessionMode): DevSessionSupervisorConfig =
  DevSessionSupervisorConfig(
    mode: mode,
    foreground: parsed.foreground,
    projectRoot: parsed.selection.projectRoot,
    modulePath: parsed.selection.modulePath,
    outDir: parsed.selection.outDir,
    workDir: reprobuildLibraryWorkDir(),
    publicCliPath: publicCliPath,
    monitorCliPath: publicDevEnvFsSnoop(publicCliPath).path,
    monitorShimLibPath: getEnv("REPRO_MONITOR_SHIM_LIB"),
    artifactPath: edge.artifactPath,
    activity: parsed.selection.activity,
    lockSliceId: parsed.selection.lockSliceId,
    developOverridesPath: parsed.selection.developOverridesPath,
    httpBind: parsed.httpBind,
    debounceMs: parsed.debounceMs)

proc supervisorCliArgs(config: DevSessionSupervisorConfig): seq[string] =
  result = @[
    "__repro-dev-session-supervisor",
    "--mode", config.mode.modeName,
    "--project-root", config.projectRoot,
    "--module", config.modulePath,
    "--out-dir", config.outDir,
    "--work-dir", config.workDir,
    "--artifact", config.artifactPath,
    "--activity", config.activity,
    "--lock-slice", config.lockSliceId,
    "--develop-overrides", config.developOverridesPath,
    "--monitor-cli", config.monitorCliPath,
    "--monitor-shim", config.monitorShimLibPath,
    "--http", config.httpBind,
    "--debounce-ms", $config.debounceMs
  ]
  if config.foreground:
    result.add("--foreground")

proc startBackgroundSupervisor(config: DevSessionSupervisorConfig) =
  createDir(extendedPath(config.outDir.sessionDir))
  let logPath = config.outDir.sessionDir / "supervisor.log"
  when defined(windows):
    discard startProcess(config.publicCliPath,
      args = config.supervisorCliArgs(),
      workingDir = config.projectRoot,
      options = {poUsePath, poDaemon, poParentStreams})
  else:
    var fdsToClose: seq[string] = @[]
    for fd in 3 .. 64:
      fdsToClose.add($fd)
    let closeInheritedFds = "for fd in " & fdsToClose.join(" ") &
      "; do eval \"exec $fd>&-\"; done; "
    let command = "(cd " & q(config.projectRoot) & " && " &
      closeInheritedFds &
      "exec " &
      shellCommand(@[config.publicCliPath] & config.supervisorCliArgs()) &
      ") </dev/null >> " & q(logPath) & " 2>&1 &"
    let exitCode = execShellCmd(command)
    if exitCode != 0:
      raise newException(OSError,
        "failed to launch dev session supervisor: " & command)

proc runUpOrDevCommand(args: openArray[string]; publicCliPath: string;
                       mode: DevSessionMode): int =
  let commandName = if mode == dsmDev: "dev" else: "up"
  var parsed = parseDevSessionArgs(args, commandName)
  let edge = computePublicDevEnv(parsed.selection, publicCliPath)
  let config = supervisorConfig(parsed, edge, publicCliPath, mode)
  if parsed.foreground:
    return runDevSessionSupervisor(config)
  config.startBackgroundSupervisor()
  let status = waitForDevSessionReady(config)
  echo "repro " & commandName & ": session " &
    status["sessionId"].getStr() & " " & status["status"].getStr() &
    " " & status["httpBind"].getStr()
  0

proc runDownCommand(args: openArray[string]): int =
  let parsed = parseDevSessionArgs(args, "down")
  let metadataPath = parsed.selection.outDir.sessionMetadataPath()
  if not fileExists(extendedPath(metadataPath)):
    raise newException(IOError,
      "no authoritative Reprobuild dev session metadata at " & metadataPath)
  # readJsonFileResilient retries past the brief `writeFile(O_TRUNC)`
  # window the dev-session supervisor produces every time it republishes
  # session.json (status transitions, service events, etc.). Without the
  # retry a parallel reader (us, plus the e2e test polling every 100 ms)
  # observes a zero-byte file and raises `session.json(1, 0) Error: {
  # expected`. See readJsonFileResilient for the race rationale.
  let metadata = readJsonFileResilient(metadataPath)
  let httpBindValue = metadata{"httpBind"}.getStr()
  if httpBindValue.len == 0:
    raise newException(ValueError,
      "dev session metadata is missing httpBind: " & metadataPath)
  try:
    let response = httpRequest(httpBindValue, "/session/stop",
      httpMethod = "POST")
    if response.status < 200 or response.status >= 300:
      raise newException(IOError,
        "session stop request failed with HTTP " & $response.status &
          ": " & response.body)
  except CatchableError as err:
    if not parsed.force:
      raise
    writeFile(extendedPath(parsed.selection.outDir.sessionDir /
      StopRequestFile), "{\"source\":\"force-file\"}\n")
    stderr.writeLine("repro down: HTTP stop failed; wrote stop request file: " &
      err.msg)
  var waited = 0
  while waited <= 10000:
    if fileExists(extendedPath(metadataPath)):
      let current = readJsonFileResilient(metadataPath)
      if current{"status"}.getStr() == "down":
        echo "repro down: session " & current{"sessionId"}.getStr() &
          " down"
        return 0
    sleep(100)
    waited.inc(100)
  raise newException(IOError,
    "timed out waiting for dev session to stop: " & metadataPath)

proc runDevSessionSupervisorHelper(args: openArray[string];
                                   publicCliPath: string): int =
  let modeText = valueAfterFlag(args, "--mode")
  let mode =
    case modeText
    of "dev": dsmDev
    of "up", "": dsmUp
    else:
      raise newException(ValueError, "unsupported dev session mode: " & modeText)
  let debounceText = valueAfterFlag(args, "--debounce-ms")
  let config = DevSessionSupervisorConfig(
    mode: mode,
    foreground: args.find("--foreground") >= 0,
    projectRoot: valueAfterFlag(args, "--project-root"),
    modulePath: valueAfterFlag(args, "--module"),
    outDir: valueAfterFlag(args, "--out-dir"),
    workDir: valueAfterFlag(args, "--work-dir"),
    publicCliPath: publicCliPath,
    monitorCliPath: valueAfterFlag(args, "--monitor-cli"),
    monitorShimLibPath: valueAfterFlag(args, "--monitor-shim"),
    artifactPath: valueAfterFlag(args, "--artifact"),
    activity: valueAfterFlag(args, "--activity"),
    lockSliceId: valueAfterFlag(args, "--lock-slice"),
    developOverridesPath: valueAfterFlag(args, "--develop-overrides"),
    httpBind: valueAfterFlag(args, "--http"),
    debounceMs: if debounceText.len > 0: parseInt(debounceText) else: 250)
  runDevSessionSupervisor(config)

proc runDevSessionHttpHelper(args: openArray[string]): int =
  let portText = valueAfterFlag(args, "--port")
  runDevSessionHttpServer(DevSessionHttpConfig(
    sessionDir: valueAfterFlag(args, "--session-dir"),
    host: valueAfterFlag(args, "--host"),
    port: if portText.len > 0: parseInt(portText) else: 0))

const
  DirenvManagedBlockId = "repro-dev-env-direnv"
  DirenvActivationGuard = "REPRO_DIRENV_ACTIVATING"
  NativeShellManagedBlockPrefix = "repro-dev-env-native-"
  NativeShellActivationGuard = "REPRO_NATIVE_SHELL_HOOK_RUNNING"
  VcsDispatcherMarker = "reprobuild hook dispatcher"
  # M17: full VCS-hook bundle the workspace publication gate (M18)
  # and the manifest auto-refresh hook (M19a) depend on. Order matters
  # only for the deterministic JSON-report iteration.
  VcsHookNames = ["pre-push", "post-commit", "post-merge", "post-checkout"]

type
  HookActionKind = enum
    hakEnsure
    hakReinstall
    hakUninstall

  NativeShellKind = enum
    nskBash
    nskZsh
    nskFish
    nskPowerShell

  ParsedHooksCommand = object
    action: HookActionKind
    targetPath: string
    shellDirenv: bool
    vcs: bool
    nativeShells: seq[NativeShellKind]
    workspaceRoot: string  ## M17: explicit --workspace-root override.
    json: bool             ## M17: emit JSON to stdout in addition to the report file.

  NativeShellActivationRequest = object
    cwd: string
    shell: NativeShellKind
    previousArtifact: string
    previousProjectRoot: string
    statsPath: string

proc nativeShellName(shell: NativeShellKind): string =
  case shell
  of nskBash: "bash"
  of nskZsh: "zsh"
  of nskFish: "fish"
  of nskPowerShell: "powershell"

proc parseNativeShell(value: string): NativeShellKind =
  case value.normalize()
  of "bash":
    nskBash
  of "zsh":
    nskZsh
  of "fish":
    nskFish
  of "powershell", "pwsh", "ps1":
    nskPowerShell
  else:
    raise newException(ValueError,
      "unsupported shell for repro hooks --shell: " & value)

proc nativeShellFormat(shell: NativeShellKind): DevEnvPrintFormat =
  case shell
  of nskBash, nskZsh:
    depPosix
  of nskFish:
    depFish
  of nskPowerShell:
    depPowerShell

proc nativeShellBlockId(shell: NativeShellKind): string =
  NativeShellManagedBlockPrefix & shell.nativeShellName()

proc nativeShellRcPath(shell: NativeShellKind; homeDir = getEnv("HOME")): string =
  case shell
  of nskBash:
    homeDir / ".bashrc"
  of nskZsh:
    homeDir / ".zshrc"
  of nskFish:
    let xdg = getEnv("XDG_CONFIG_HOME")
    if xdg.len > 0:
      xdg / "fish" / "config.fish"
    else:
      homeDir / ".config" / "fish" / "config.fish"
  of nskPowerShell:
    when defined(windows):
      let profileHome = getEnv("USERPROFILE", homeDir)
      profileHome / "Documents" / "PowerShell" /
        "Microsoft.PowerShell_profile.ps1"
    else:
      homeDir / ".config" / "powershell" /
        "Microsoft.PowerShell_profile.ps1"

proc containsNixStoreSegment(path: string): bool =
  let normalized = path.replace('\\', '/')
  normalized.startsWith("/nix/store/") or normalized.contains("/nix/store/")

proc absoluteSymlinkTarget(linkPath: string): string =
  let rawTarget = expandSymlink(extendedPath(linkPath))
  if rawTarget.isAbsolute:
    os.normalizedPath(rawTarget)
  else:
    os.normalizedPath(parentDir(linkPath) / rawTarget)

proc rcFileWritePath(rcPath: string): string =
  ## Return the file to edit for a shell rc managed block. Refuses Nix-managed
  ## read-only symlinks instead of replacing the symlink with a regular file.
  let expandedRc = extendedPath(rcPath)
  if symlinkExists(expandedRc):
    let target = absoluteSymlinkTarget(rcPath)
    if target.containsNixStoreSegment():
      raise newException(ValueError,
        "refusing to write shell rc file " & rcPath &
          ": it is a Nix-managed symlink into the Nix store (" & target &
          "). Edit the source file in your dotfiles/home-manager " &
          "configuration and rebuild with home-switch.")
    if fileExists(extendedPath(target)):
      let permissions = getFilePermissions(extendedPath(target))
      if fpUserWrite notin permissions:
        raise newException(ValueError,
          "refusing to write shell rc file " & rcPath &
            ": it points at a read-only file (" & target &
            "). Edit the owning source file instead.")
    return target
  if expandedRc.containsNixStoreSegment():
    raise newException(ValueError,
      "refusing to write shell rc file in the Nix store: " & rcPath &
        ". Edit the source file in your dotfiles/home-manager configuration " &
        "and rebuild with home-switch.")
  if fileExists(expandedRc):
    let permissions = getFilePermissions(expandedRc)
    if fpUserWrite notin permissions:
      raise newException(ValueError,
        "refusing to write read-only shell rc file " & rcPath &
          ". Edit the owning source file instead.")
  rcPath

proc posixLiteral(value: string): string =
  result = "'"
  for ch in value:
    if ch == '\'':
      result.add("'\\''")
    else:
      result.add(ch)
  result.add("'")

proc fishLiteral(value: string): string =
  result = "'"
  for ch in value:
    case ch
    of '\'':
      result.add("\\'")
    of '\\':
      result.add("\\\\")
    else:
      result.add(ch)
  result.add("'")

proc powerShellLiteral(value: string): string =
  "'" & value.replace("'", "''") & "'"

const NativeMetadataNames = [
  "REPRO_DEV_ENV_ARTIFACT",
  "REPRO_DEV_ENV_PROJECT_ROOT",
  "REPRO_DEV_ENV_SELECTED_ACTIVITIES",
  "REPRO_DEV_ENV_TASKS",
  "REPRO_DEV_ENV_SERVICES"
]

proc sortedUnique(values: seq[string]): seq[string] =
  var seen: HashSet[string]
  for value in values:
    if value.len > 0 and value notin seen:
      seen.incl(value)
      result.add(value)
  result.sort()

proc nativeUnsetNames(artifact: DevEnvArtifact): seq[string] =
  var names: seq[string] = @[]
  for op in artifact.shellOps:
    case op.kind
    of deskSetEnv, deskSetPathList, deskUnsetEnv:
      names.add(op.name)
    of deskPrependPath, deskAppendPath, deskSetWorkingDirectory:
      discard
  for name in NativeMetadataNames:
    names.add(name)
  names.sortedUnique()

proc nativePathRemovals(artifact: DevEnvArtifact):
    seq[tuple[name, value, separator: string]] =
  var seen: HashSet[string]
  for op in artifact.shellOps:
    case op.kind
    of deskPrependPath, deskAppendPath:
      let sep = if op.separator.len > 0: op.separator else: $PathSep
      let key = op.name & "\0" & op.value & "\0" & sep
      if key notin seen:
        seen.incl(key)
        result.add((name: op.name, value: op.value, separator: sep))
    else:
      discard

proc renderPosixDevEnvUnload(artifact: DevEnvArtifact): string =
  result = "# Reprobuild native shell unload\n"
  let removals = nativePathRemovals(artifact)
  if removals.len > 0:
    result.add("__repro_native_remove_path() {\n")
    result.add("  __repro_native_var=$1\n")
    result.add("  __repro_native_remove=$2\n")
    result.add("  __repro_native_sep=$3\n")
    result.add("  eval \"__repro_native_value=\\${$__repro_native_var-}\"\n")
    result.add("  __repro_native_out=\n")
    result.add("  __repro_native_old_ifs=$IFS\n")
    result.add("  IFS=$__repro_native_sep\n")
    result.add("  for __repro_native_part in $__repro_native_value; do\n")
    result.add("    if [ \"$__repro_native_part\" != \"$__repro_native_remove\" ]; then\n")
    result.add("      if [ -n \"$__repro_native_out\" ]; then\n")
    result.add("        __repro_native_out=$__repro_native_out$__repro_native_sep$__repro_native_part\n")
    result.add("      else\n")
    result.add("        __repro_native_out=$__repro_native_part\n")
    result.add("      fi\n")
    result.add("    fi\n")
    result.add("  done\n")
    result.add("  IFS=$__repro_native_old_ifs\n")
    result.add("  export \"$__repro_native_var=$__repro_native_out\"\n")
    result.add("}\n")
    for removal in removals:
      result.add("__repro_native_remove_path " & posixLiteral(removal.name) &
        " " & posixLiteral(removal.value) & " " &
        posixLiteral(removal.separator) & "\n")
    result.add("unset -f __repro_native_remove_path 2>/dev/null || true\n")
    result.add("unset __repro_native_var __repro_native_remove __repro_native_sep __repro_native_value __repro_native_out __repro_native_old_ifs __repro_native_part\n")
  let names = nativeUnsetNames(artifact)
  if names.len > 0:
    result.add("unset " & names.join(" ") & "\n")

proc renderFishDevEnvUnload(artifact: DevEnvArtifact): string =
  result = "# Reprobuild native shell unload\n"
  let removals = nativePathRemovals(artifact)
  if removals.len > 0:
    result.add("function __repro_native_remove_path\n")
    result.add("  set -l __repro_native_var $argv[1]\n")
    result.add("  set -l __repro_native_remove $argv[2]\n")
    result.add("  set -l __repro_native_kept\n")
    result.add("  for __repro_native_part in $$__repro_native_var\n")
    result.add("    if test \"$__repro_native_part\" != \"$__repro_native_remove\"\n")
    result.add("      set __repro_native_kept $__repro_native_kept \"$__repro_native_part\"\n")
    result.add("    end\n")
    result.add("  end\n")
    result.add("  if test (count $__repro_native_kept) -gt 0\n")
    result.add("    set -gx $__repro_native_var $__repro_native_kept\n")
    result.add("  else\n")
    result.add("    set -e $__repro_native_var\n")
    result.add("  end\n")
    result.add("end\n")
    for removal in removals:
      result.add("__repro_native_remove_path " & fishLiteral(removal.name) &
        " " & fishLiteral(removal.value) & "\n")
    result.add("functions -e __repro_native_remove_path\n")
  for name in nativeUnsetNames(artifact):
    result.add("set -e " & name & "\n")

proc renderPowerShellDevEnvUnload(artifact: DevEnvArtifact): string =
  result = "# Reprobuild native shell unload\n"
  let removals = nativePathRemovals(artifact)
  if removals.len > 0:
    result.add("function __ReproNativeRemovePath($Name, $Value, $Sep) {\n")
    result.add("  $current = [Environment]::GetEnvironmentVariable($Name, 'Process')\n")
    result.add("  if ($null -eq $current) { return }\n")
    result.add("  $kept = @()\n")
    result.add("  foreach ($part in $current -split [regex]::Escape($Sep)) {\n")
    result.add("    if ($part -ne $Value) { $kept += $part }\n")
    result.add("  }\n")
    result.add("  if ($kept.Count -gt 0) { Set-Item -Path \"Env:$Name\" -Value ($kept -join $Sep) }\n")
    result.add("  else { Remove-Item -Path \"Env:$Name\" -ErrorAction SilentlyContinue }\n")
    result.add("}\n")
    for removal in removals:
      result.add("__ReproNativeRemovePath " &
        powerShellLiteral(removal.name) & " " &
        powerShellLiteral(removal.value) & " " &
        powerShellLiteral(removal.separator) & "\n")
    result.add("Remove-Item Function:__ReproNativeRemovePath -ErrorAction SilentlyContinue\n")
  for name in nativeUnsetNames(artifact):
    result.add("Remove-Item Env:" & name & " -ErrorAction SilentlyContinue\n")

proc renderDevEnvUnload(artifact: DevEnvArtifact;
                        format: DevEnvPrintFormat): string =
  case format
  of depPosix:
    renderPosixDevEnvUnload(artifact)
  of depFish:
    renderFishDevEnvUnload(artifact)
  of depPowerShell:
    renderPowerShellDevEnvUnload(artifact)
  of depJson:
    raise newException(ValueError,
      "json is not a native shell activation format")

proc renderNativeShellTransition(previousArtifactPath: string;
                                 nextArtifact: Option[DevEnvArtifact];
                                 nextArtifactPath: string;
                                 format: DevEnvPrintFormat): string =
  if previousArtifactPath.len > 0 and
      fileExists(extendedPath(previousArtifactPath)):
    result.add(renderDevEnvUnload(readDevEnvArtifact(previousArtifactPath),
      format))
  elif previousArtifactPath.len > 0:
    for name in NativeMetadataNames:
      case format
      of depPosix:
        result.add("unset " & name & "\n")
      of depFish:
        result.add("set -e " & name & "\n")
      of depPowerShell:
        result.add("Remove-Item Env:" & name &
          " -ErrorAction SilentlyContinue\n")
      of depJson:
        discard
  if nextArtifact.isSome:
    result.add(renderDevEnvArtifact(nextArtifact.get(), nextArtifactPath,
      format))

proc findDevEnvProjectRoot(startPath: string): string =
  var cursor = os.normalizedPath(absolutePath(startPath))
  if fileExists(extendedPath(cursor)) and not dirExists(extendedPath(cursor)):
    cursor = parentDir(cursor)
  while cursor.len > 0:
    # Project-file alias: a directory containing either ``repro.nim`` or
    # ``reprobuild.nim`` is a valid project root.
    let match = resolveProjectFile(cursor)
    if match.path.len > 0:
      return cursor
    let parent = parentDir(cursor)
    if parent == cursor or parent.len == 0:
      break
    cursor = parent
  ""

proc direnvOpenSentinel(): string =
  ResourceOpenSentinelPrefix & DirenvManagedBlockId & ResourceOpenSentinelSuffix

proc direnvCloseSentinel(): string =
  ResourceCloseSentinelPrefix & DirenvManagedBlockId &
    ResourceCloseSentinelSuffix

proc direnvManagedBlockContent(): string =
  let guard = DirenvActivationGuard
  result = "# Generated by repro hooks ensure --shell-direnv. Do not edit this block.\n"
  result.add("_repro_direnv_activate() {\n")
  result.add("  if [ -n \"${" & guard & ":-}\" ]; then\n")
  result.add("    return 0\n")
  result.add("  fi\n")
  result.add("  export " & guard & "=1\n")
  result.add("  local repro_cmd=\"${REPROBUILD_REPRO:-repro}\"\n")
  result.add("  if ! command -v \"$repro_cmd\" >/dev/null 2>&1 && [ ! -x \"$repro_cmd\" ]; then\n")
  result.add("    echo \"repro hooks: repro CLI not found; set REPROBUILD_REPRO or put repro on PATH\" >&2\n")
  result.add("    unset " & guard & "\n")
  result.add("    return 1\n")
  result.add("  fi\n")
  result.add("  \"$repro_cmd\" hooks ensure --vcs \"$PWD\" >/dev/null 2>&1 || true\n")
  result.add("  local repro_status=0\n")
  result.add("  if [ -n \"${REPRO_DIRENV_STATS:-}\" ]; then\n")
  result.add("    eval \"$(\"$repro_cmd\" __repro-direnv-activate \"$PWD\" --dev-env-stats \"$REPRO_DIRENV_STATS\")\" || repro_status=$?\n")
  result.add("  else\n")
  result.add("    eval \"$(\"$repro_cmd\" __repro-direnv-activate \"$PWD\")\" || repro_status=$?\n")
  result.add("  fi\n")
  result.add("  unset " & guard & "\n")
  result.add("  return \"$repro_status\"\n")
  result.add("}\n")
  result.add("_repro_direnv_activate\n")
  result.add("_repro_direnv_status=$?\n")
  result.add("unset -f _repro_direnv_activate\n")
  result.add("return \"$_repro_direnv_status\"\n")

proc resolveHooksTarget(path: string): string =
  let raw = if path.len > 0: path else: "."
  result = os.normalizedPath(absolutePath(raw))
  if fileExists(extendedPath(result)) and not dirExists(extendedPath(result)):
    result = parentDir(result)

proc managedBlockMalformed(content: string): bool =
  let openIdx = content.find(direnvOpenSentinel())
  let closeIdx = content.find(direnvCloseSentinel())
  (openIdx >= 0 and closeIdx < 0) or (openIdx < 0 and closeIdx >= 0) or
    (openIdx >= 0 and closeIdx >= 0 and closeIdx <= openIdx)

proc contentOutsideManagedBlock(content: string): string =
  let openS = direnvOpenSentinel()
  let closeS = direnvCloseSentinel()
  let openIdx = content.find(openS)
  let closeIdx = content.find(closeS)
  if openIdx < 0 or closeIdx < 0 or closeIdx <= openIdx:
    return content
  var openLineStart = openIdx
  while openLineStart > 0 and content[openLineStart - 1] != '\n':
    dec openLineStart
  var closeLineEnd = closeIdx + closeS.len
  if closeLineEnd < content.len and content[closeLineEnd] == '\n':
    inc closeLineEnd
  content[0 ..< openLineStart] & content[closeLineEnd .. ^1]

proc hasUnmanagedDirenvConflict(content: string): bool =
  let outside = content.contentOutsideManagedBlock().toLowerAscii()
  for marker in [
    "__repro-direnv-activate",
    "repro shell",
    "repro exec",
    "repro_dev_env_",
    "repro_direnv_",
    "reprobuild_repro"
  ]:
    if outside.contains(marker):
      return true

proc validateEnvrcForEnsure(envrcPath: string) =
  if not fileExists(extendedPath(envrcPath)):
    return
  let content = readFile(extendedPath(envrcPath))
  if content.managedBlockMalformed():
    raise newException(ValueError,
      "conflicting .envrc: found an incomplete Reprobuild managed block in " &
        envrcPath & "; repair or remove the sentinels before running ensure")
  if content.hasUnmanagedDirenvConflict():
    raise newException(ValueError,
      "conflicting unmanaged .envrc in " & envrcPath &
        ": existing user-owned content appears to activate Reprobuild. " &
        "Move that logic into the Reprobuild-managed block by removing it " &
        "or run uninstall first.")

proc ensureDirenvHook(targetPath: string; reinstall = false) =
  let projectRoot = resolveHooksTarget(targetPath)
  createDir(extendedPath(projectRoot))
  let envrcPath = projectRoot / ".envrc"
  if reinstall:
    destroyManagedBlockResource(envrcPath, DirenvManagedBlockId)
  validateEnvrcForEnsure(envrcPath)
  discard applyManagedBlockResource(envrcPath, DirenvManagedBlockId,
    direnvManagedBlockContent())
  echo "repro hooks: ensured direnv .envrc block at " & envrcPath

proc uninstallDirenvHook(targetPath: string) =
  let projectRoot = resolveHooksTarget(targetPath)
  let envrcPath = projectRoot / ".envrc"
  if fileExists(extendedPath(envrcPath)) and
      readFile(extendedPath(envrcPath)).managedBlockMalformed():
    raise newException(ValueError,
      "conflicting .envrc: found an incomplete Reprobuild managed block in " &
        envrcPath & "; refusing to edit user-owned content")
  destroyManagedBlockResource(envrcPath, DirenvManagedBlockId)
  echo "repro hooks: removed direnv .envrc block from " & envrcPath

proc nativePosixHookContent(shell: NativeShellKind): string =
  let shellName = shell.nativeShellName()
  let shellArg = if shell == nskZsh: "zsh" else: "bash"
  result = "# Generated by repro hooks ensure --shell " & shellName &
    ". Do not edit this block.\n"
  result.add("__repro_native_shell_hook() {\n")
  result.add("  if [ -n \"${" & NativeShellActivationGuard & ":-}\" ]; then\n")
  result.add("    return 0\n")
  result.add("  fi\n")
  result.add("  export " & NativeShellActivationGuard & "=1\n")
  result.add("  local __repro_native_repro=\"${REPROBUILD_REPRO:-repro}\"\n")
  result.add("  if ! command -v \"$__repro_native_repro\" >/dev/null 2>&1 && [ ! -x \"$__repro_native_repro\" ]; then\n")
  result.add("    echo \"repro hooks: repro CLI not found; set REPROBUILD_REPRO or put repro on PATH\" >&2\n")
  result.add("    unset " & NativeShellActivationGuard & "\n")
  result.add("    return 1\n")
  result.add("  fi\n")
  result.add("  local __repro_native_status=0\n")
  result.add("  local __repro_native_script\n")
  result.add("  if [ -n \"${REPRO_NATIVE_SHELL_STATS:-}\" ]; then\n")
  result.add("    __repro_native_script=\"$(\"$__repro_native_repro\" __repro-native-shell-activate \"$PWD\" --shell " & shellArg & " --previous-artifact \"${REPRO_DEV_ENV_ARTIFACT:-}\" --previous-project-root \"${REPRO_DEV_ENV_PROJECT_ROOT:-}\" --dev-env-stats \"$REPRO_NATIVE_SHELL_STATS\")\" || __repro_native_status=$?\n")
  result.add("  else\n")
  result.add("    __repro_native_script=\"$(\"$__repro_native_repro\" __repro-native-shell-activate \"$PWD\" --shell " & shellArg & " --previous-artifact \"${REPRO_DEV_ENV_ARTIFACT:-}\" --previous-project-root \"${REPRO_DEV_ENV_PROJECT_ROOT:-}\")\" || __repro_native_status=$?\n")
  result.add("  fi\n")
  result.add("  if [ \"$__repro_native_status\" -eq 0 ]; then\n")
  result.add("    eval \"$__repro_native_script\"\n")
  result.add("  else\n")
  result.add("    printf '%s\\n' \"$__repro_native_script\" >&2\n")
  result.add("  fi\n")
  result.add("  unset " & NativeShellActivationGuard & "\n")
  result.add("  unset __repro_native_repro __repro_native_script\n")
  result.add("  return \"$__repro_native_status\"\n")
  result.add("}\n")
  case shell
  of nskBash:
    result.add("cd() { builtin cd \"$@\" || return $?; __repro_native_shell_hook; }\n")
    result.add("pushd() { builtin pushd \"$@\" || return $?; __repro_native_shell_hook; }\n")
    result.add("popd() { builtin popd \"$@\" || return $?; __repro_native_shell_hook; }\n")
  of nskZsh:
    result.add("autoload -Uz add-zsh-hook\n")
    result.add("add-zsh-hook chpwd __repro_native_shell_hook\n")
  else:
    discard
  result.add("__repro_native_shell_hook\n")

proc nativeFishHookContent(): string =
  result = "# Generated by repro hooks ensure --shell fish. Do not edit this block.\n"
  result.add("function __repro_native_shell_hook --on-variable PWD\n")
  result.add("  if set -q " & NativeShellActivationGuard & "\n")
  result.add("    return 0\n")
  result.add("  end\n")
  result.add("  set -gx " & NativeShellActivationGuard & " 1\n")
  result.add("  set -l __repro_native_repro \"$REPROBUILD_REPRO\"\n")
  result.add("  if test -z \"$__repro_native_repro\"\n")
  result.add("    set __repro_native_repro repro\n")
  result.add("  end\n")
  result.add("  if not test -x \"$__repro_native_repro\"; and not type -q \"$__repro_native_repro\"\n")
  result.add("    echo \"repro hooks: repro CLI not found; set REPROBUILD_REPRO or put repro on PATH\" >&2\n")
  result.add("    set -e " & NativeShellActivationGuard & "\n")
  result.add("    return 1\n")
  result.add("  end\n")
  result.add("  set -l __repro_native_tmp (mktemp)\n")
  result.add("  if set -q REPRO_NATIVE_SHELL_STATS\n")
  result.add("    \"$__repro_native_repro\" __repro-native-shell-activate \"$PWD\" --shell fish --previous-artifact \"$REPRO_DEV_ENV_ARTIFACT\" --previous-project-root \"$REPRO_DEV_ENV_PROJECT_ROOT\" --dev-env-stats \"$REPRO_NATIVE_SHELL_STATS\" > \"$__repro_native_tmp\"\n")
  result.add("  else\n")
  result.add("    \"$__repro_native_repro\" __repro-native-shell-activate \"$PWD\" --shell fish --previous-artifact \"$REPRO_DEV_ENV_ARTIFACT\" --previous-project-root \"$REPRO_DEV_ENV_PROJECT_ROOT\" > \"$__repro_native_tmp\"\n")
  result.add("  end\n")
  result.add("  set -l __repro_native_status $status\n")
  result.add("  if test $__repro_native_status -eq 0\n")
  result.add("    source \"$__repro_native_tmp\"\n")
  result.add("  else\n")
  result.add("    cat \"$__repro_native_tmp\" >&2\n")
  result.add("  end\n")
  result.add("  rm -f \"$__repro_native_tmp\"\n")
  result.add("  set -e " & NativeShellActivationGuard & "\n")
  result.add("  return $__repro_native_status\n")
  result.add("end\n")
  result.add("__repro_native_shell_hook\n")

proc nativePowerShellHookContent(): string =
  result = "# Generated by repro hooks ensure --shell powershell. Do not edit this block.\n"
  result.add("function Invoke-ReproNativeShellHook {\n")
  result.add("  if ($env:" & NativeShellActivationGuard & ") { return }\n")
  result.add("  $env:" & NativeShellActivationGuard & " = '1'\n")
  result.add("  $reproCmd = if ($env:REPROBUILD_REPRO) { $env:REPROBUILD_REPRO } else { 'repro' }\n")
  result.add("  $args = @('__repro-native-shell-activate', (Get-Location).Path, '--shell', 'powershell', '--previous-artifact', $env:REPRO_DEV_ENV_ARTIFACT, '--previous-project-root', $env:REPRO_DEV_ENV_PROJECT_ROOT)\n")
  result.add("  if ($env:REPRO_NATIVE_SHELL_STATS) { $args += @('--dev-env-stats', $env:REPRO_NATIVE_SHELL_STATS) }\n")
  result.add("  $script = & $reproCmd @args\n")
  result.add("  if ($LASTEXITCODE -eq 0) { Invoke-Expression ($script -join \"`n\") }\n")
  result.add("  else { [Console]::Error.WriteLine(($script -join \"`n\")) }\n")
  result.add("  Remove-Item Env:" & NativeShellActivationGuard & " -ErrorAction SilentlyContinue\n")
  result.add("}\n")
  result.add("function Set-Location {\n")
  result.add("  Microsoft.PowerShell.Management\\Set-Location @args\n")
  result.add("  if ($?) { Invoke-ReproNativeShellHook }\n")
  result.add("}\n")
  result.add("Set-Alias cd Set-Location -Option AllScope\n")
  result.add("Set-Alias chdir Set-Location -Option AllScope\n")
  result.add("Set-Alias sl Set-Location -Option AllScope\n")
  result.add("Invoke-ReproNativeShellHook\n")

proc nativeShellHookContent(shell: NativeShellKind): string =
  case shell
  of nskBash, nskZsh:
    nativePosixHookContent(shell)
  of nskFish:
    nativeFishHookContent()
  of nskPowerShell:
    nativePowerShellHookContent()

proc ensureNativeShellHook(shell: NativeShellKind; reinstall = false) =
  let rcPath = nativeShellRcPath(shell)
  let writePath = rcFileWritePath(rcPath)
  if reinstall:
    destroyManagedBlockResource(writePath, nativeShellBlockId(shell))
  discard applyManagedBlockResource(writePath, nativeShellBlockId(shell),
    nativeShellHookContent(shell))
  echo "repro hooks: ensured native " & shell.nativeShellName() &
    " shell block at " & rcPath

proc uninstallNativeShellHook(shell: NativeShellKind) =
  let rcPath = nativeShellRcPath(shell)
  let writePath = rcFileWritePath(rcPath)
  destroyManagedBlockResource(writePath, nativeShellBlockId(shell))
  echo "repro hooks: removed native " & shell.nativeShellName() &
    " shell block from " & rcPath

proc gitTopLevel(targetPath: string): string =
  let res = execCmdEx(shellCommand(@["git", "-C", resolveHooksTarget(targetPath),
    "rev-parse", "--show-toplevel"]))
  if res.exitCode == 0:
    result = os.normalizedPath(res.output.strip())

proc gitHooksDir(targetPath: string): string =
  let repoRoot = gitTopLevel(targetPath)
  if repoRoot.len == 0:
    raise newException(ValueError,
      "VCS hook target is not inside a Git repository: " &
        resolveHooksTarget(targetPath))
  let res = execCmdEx(shellCommand(@["git", "-C", repoRoot, "rev-parse",
    "--absolute-git-dir"]))
  if res.exitCode != 0:
    raise newException(ValueError,
      "could not locate Git hooks directory for " & repoRoot & ": " &
        res.output.strip())
  result = os.normalizedPath(res.output.strip()) / "hooks"

proc hookPath(hooksDir, hookName: string): string =
  hooksDir / hookName

proc localHookPath(hooksDir, hookName: string): string =
  hooksDir / (hookName & ".repro-local")

proc managedHookPath(hooksDir, hookName: string): string =
  hooksDir / (hookName & ".repro-managed")

proc fileContains(path, marker: string): bool =
  fileExists(extendedPath(path)) and readFile(extendedPath(path)).contains(marker)

proc isReprobuildVcsHook(path, hookName: string): bool =
  fileContains(path, VcsDispatcherMarker) or
    fileContains(path, "reprobuild managed " & hookName & " hook")

proc ensureExecutable(path: string) =
  if not fileExists(extendedPath(path)):
    return
  var permissions = getFilePermissions(extendedPath(path))
  permissions.incl(fpUserExec)
  permissions.incl(fpGroupExec)
  permissions.incl(fpOthersExec)
  setFilePermissions(extendedPath(path), permissions)

proc writeExecutableIfChanged(path, content: string): bool =
  if fileExists(extendedPath(path)) and readFile(extendedPath(path)) == content:
    ensureExecutable(path)
    return false
  writeFile(extendedPath(path), content)
  ensureExecutable(path)
  true

proc removeFileIfExists(path: string): bool =
  if fileExists(extendedPath(path)):
    removeFile(extendedPath(path))
    return true
  false

proc moveFileReplacing(source, dest: string) =
  if fileExists(extendedPath(dest)):
    removeFile(extendedPath(dest))
  moveFile(extendedPath(source), extendedPath(dest))

proc vcsDispatcherContent(hookName: string): string =
  result = "#!/usr/bin/env sh\n"
  result.add("# " & VcsDispatcherMarker & "\n")
  result.add("# Dispatches preserved user hooks and Reprobuild-managed " &
    hookName & " logic.\n")
  result.add("set -eu\n\n")
  result.add("HOOK_DIR=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)\n")
  result.add("LOCAL_HOOK=\"$HOOK_DIR/" & hookName & ".repro-local\"\n")
  result.add("MANAGED_HOOK=\"$HOOK_DIR/" & hookName & ".repro-managed\"\n\n")
  if hookName == "pre-push":
    result.add("TMP_FILE=$(mktemp \"${TMPDIR:-/tmp}/reprobuild-pre-push.XXXXXX\")\n")
    result.add("trap 'rm -f \"$TMP_FILE\"' EXIT HUP INT TERM\n")
    result.add("cat > \"$TMP_FILE\"\n")
    result.add("if [ -x \"$LOCAL_HOOK\" ]; then \"$LOCAL_HOOK\" \"$@\" < \"$TMP_FILE\" || exit $?; fi\n")
    result.add("if [ -x \"$MANAGED_HOOK\" ]; then \"$MANAGED_HOOK\" \"$@\" < \"$TMP_FILE\" || exit $?; fi\n")
  else:
    result.add("if [ -x \"$LOCAL_HOOK\" ]; then \"$LOCAL_HOOK\" \"$@\" || exit $?; fi\n")
    result.add("if [ -x \"$MANAGED_HOOK\" ]; then \"$MANAGED_HOOK\" \"$@\" || exit $?; fi\n")
  result.add("exit 0\n")

proc vcsManagedHookContent(hookName: string): string =
  ## Canonical managed-hook body. M17 wires the dispatch path as
  ## ``repro hooks dispatch <name>`` (no-op until later milestones
  ## register a body). Drift detection compares the on-disk file to
  ## this exact string, so any future change to the body bumps every
  ## installed hook on the next ``ensure``.
  result = "#!/usr/bin/env sh\n"
  result.add("# reprobuild managed " & hookName & " hook\n")
  result.add("# managed-by: reprobuild hooks ensure\n")
  result.add("# dispatches to: repro hooks dispatch " & hookName & "\n")
  result.add("set -eu\n\n")
  result.add("find_repro_cmd() {\n")
  result.add("  if [ -n \"${REPROBUILD_REPRO:-}\" ] && [ -x \"$REPROBUILD_REPRO\" ]; then\n")
  result.add("    printf '%s\\n' \"$REPROBUILD_REPRO\"\n")
  result.add("    return 0\n")
  result.add("  fi\n")
  result.add("  if command -v repro >/dev/null 2>&1; then\n")
  result.add("    command -v repro\n")
  result.add("    return 0\n")
  result.add("  fi\n")
  result.add("  return 1\n")
  result.add("}\n\n")
  result.add("REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)\n")
  result.add("cd \"$REPO_ROOT\"\n")
  result.add("if REPRO_CMD=$(find_repro_cmd); then\n")
  if hookName == "pre-push":
    result.add("  REFS_FILE=$(mktemp \"${TMPDIR:-/tmp}/reprobuild-pre-push-backend.XXXXXX\")\n")
    result.add("  trap 'rm -f \"$REFS_FILE\"' EXIT HUP INT TERM\n")
    result.add("  cat > \"$REFS_FILE\"\n")
    result.add("  \"$REPRO_CMD\" hooks dispatch " & hookName &
      " --repo-root \"$REPO_ROOT\" --refs-file \"$REFS_FILE\" -- \"$@\"\n")
  else:
    result.add("  \"$REPRO_CMD\" hooks dispatch " & hookName &
      " --repo-root \"$REPO_ROOT\" -- \"$@\"\n")
  result.add("  exit $?\n")
  result.add("fi\n")
  result.add("echo \"repro hooks: repro CLI not found on PATH; skipping " &
    hookName & "\" >&2\n")
  result.add("exit 0\n")

type
  VcsHookEnsureOutcome* = enum
    ## M17 status codes for ``repro hooks ensure --vcs``. Distinct from
    ## the M18+ runtime outcomes the dispatcher itself can return.
    vheoAlreadyUpToDate     ## Dispatcher + managed body already match canonical content.
    vheoInstalled           ## A fresh install or a missing file was created.
    vheoChainedUserHook     ## A pre-existing non-managed hook was preserved as ``<name>.repro-local``.
    vheoRefreshedDrifted    ## Sentinel present but body diverged; rewrote canonical content.

proc ensureVcsHookDetailed(hooksDir, hookName: string): VcsHookEnsureOutcome =
  ## Idempotent installer for one (hooksDir, hookName) pair. Returns a
  ## structured outcome so callers can surface per-repo per-hook status
  ## in the JSON report and the human-readable summary line.
  ##
  ## Outcome priority (the higher-impact change wins when several apply):
  ##   chained-user-hook  >  refreshed-drifted  >  installed  >  already-up-to-date
  createDir(extendedPath(hooksDir))
  let standard = hookPath(hooksDir, hookName)
  let local = localHookPath(hooksDir, hookName)
  let managed = managedHookPath(hooksDir, hookName)

  var chainedUser = false
  var anyChange = false
  var refreshedDrift = false

  # Stale sentinel-marked local file from an earlier `uninstall` run.
  if fileExists(extendedPath(local)) and isReprobuildVcsHook(local, hookName):
    anyChange = removeFileIfExists(local) or anyChange

  # Pre-existing user-owned hook at the canonical path: chain it.
  if fileExists(extendedPath(standard)) and
      not isReprobuildVcsHook(standard, hookName):
    if fileExists(extendedPath(local)):
      raise newException(ValueError,
        "cannot install " & hookName & ": " & standard &
          " is user-owned and " & local & " already exists")
    moveFileReplacing(standard, local)
    ensureExecutable(local)
    chainedUser = true
    anyChange = true

  # Detect drift: file exists, sentinel matches, body diverges from canonical.
  let canonicalManaged = vcsManagedHookContent(hookName)
  if fileExists(extendedPath(managed)) and
      isReprobuildVcsHook(managed, hookName) and
      readFile(extendedPath(managed)) != canonicalManaged:
    refreshedDrift = true
  let canonicalDispatcher = vcsDispatcherContent(hookName)
  if fileExists(extendedPath(standard)) and
      isReprobuildVcsHook(standard, hookName) and
      readFile(extendedPath(standard)) != canonicalDispatcher:
    refreshedDrift = true

  let managedChanged = writeExecutableIfChanged(managed, canonicalManaged)
  let dispatcherChanged = writeExecutableIfChanged(standard, canonicalDispatcher)
  anyChange = anyChange or managedChanged or dispatcherChanged

  if chainedUser:
    return vheoChainedUserHook
  if refreshedDrift:
    return vheoRefreshedDrifted
  if anyChange:
    return vheoInstalled
  vheoAlreadyUpToDate

proc ensureVcsHook(hooksDir, hookName: string): bool =
  ## Back-compat single-hook installer that reports a single
  ## "changed / unchanged" boolean. Retained so the legacy single-repo
  ## ``runVcsHooksCommand`` path (used by ``repro hooks reinstall`` and
  ## ``repro hooks uninstall``) keeps the same shape it had before
  ## the workspace-aware M17 ``ensure`` path was added.
  let outcome = ensureVcsHookDetailed(hooksDir, hookName)
  outcome != vheoAlreadyUpToDate

type
  VcsHookEntry* = object
    ## One per (repo, hookName) pair in the M17 JSON report. ``outcome``
    ## is the lowercased ``vheo*`` string (``installed`` /
    ## ``already-up-to-date`` / ``chained-user-hook`` /
    ## ``refreshed-drifted``); ``hookPath`` and ``managedPath`` are the
    ## absolute paths the installer touched (or would touch).
    repo*: string
    repoPath*: string
    hook*: string
    outcome*: string
    hookPath*: string
    managedPath*: string

  HooksEnsureReport* = object
    ## Structured outcome of one ``repro hooks ensure --vcs`` invocation
    ## written to ``<workspaceRoot>/.repo/workspace/hooks-report.json``.
    workspaceRoot*: string
    mode*: string                  ## ``workspace`` or ``single-repo``.
    project*: string               ## resolved project name (workspace mode).
    repos*: seq[string]            ## participating repo names.
    entries*: seq[VcsHookEntry]
    summary*: Table[string, int]   ## outcome → count, e.g. {"installed": 8}.
    exitCode*: int

proc vcsHookOutcomeTag(outcome: VcsHookEnsureOutcome): string =
  case outcome
  of vheoAlreadyUpToDate: "already-up-to-date"
  of vheoInstalled: "installed"
  of vheoChainedUserHook: "chained-user-hook"
  of vheoRefreshedDrifted: "refreshed-drifted"

proc toJsonNode*(report: HooksEnsureReport): JsonNode =
  result = newJObject()
  result["workspaceRoot"] = %report.workspaceRoot
  result["mode"] = %report.mode
  result["project"] = %report.project
  var reposNode = newJArray()
  for r in report.repos:
    reposNode.add(%r)
  result["repos"] = reposNode
  var entriesNode = newJArray()
  for e in report.entries:
    var obj = newJObject()
    obj["repo"] = %e.repo
    obj["repoPath"] = %e.repoPath
    obj["hook"] = %e.hook
    obj["outcome"] = %e.outcome
    obj["hookPath"] = %e.hookPath
    obj["managedPath"] = %e.managedPath
    entriesNode.add(obj)
  result["entries"] = entriesNode
  var summaryNode = newJObject()
  # Sorted summary keys for stable JSON diffs.
  var keys: seq[string]
  for k in report.summary.keys: keys.add(k)
  keys.sort()
  for k in keys:
    summaryNode[k] = %report.summary[k]
  result["summary"] = summaryNode
  result["exitCode"] = %report.exitCode

# --- M17: workspace-wide participating-repo enumeration ------------------
#
# The installer must touch every repo declared by the active project /
# variant. Reuse the same composer-or-resolver dispatch the M9-M16
# subcommands use:
#
#   1. ``.repo/workspace.toml`` is compositional (M8 mode) → run the
#      composer.
#   2. otherwise look up the project name (from a metadata-only M13
#      workspace.toml, then fall back to a single ``projects/*.toml``
#      under ``.repo/manifests/projects/``).
#   3. failing that, treat ``targetPath`` (or cwd) as a single git
#      repo — same fallback path the legacy single-repo ``ensure``
#      command used before M17.

type
  HookRepoTarget = object
    name: string
    repoPath: string  ## absolute path to the repo's working tree.

proc detectWorkspaceProjectName(workspaceRoot: string): string =
  ## When ``workspace.toml`` is metadata-only the project name lives in
  ## ``[workspace].project``; when neither workspace.toml nor that field
  ## is present we look for exactly one ``projects/*.toml`` under
  ## ``.repo/manifests/projects/`` and use its stem.
  let workspaceToml = workspaceRoot / ".repo" / "workspace.toml"
  if fileExists(workspaceToml):
    try:
      let recorded =
        readWorkspaceLocal(absolutePath(workspaceToml)).workspace.project
      if recorded.len > 0:
        return recorded
    except WorkspaceManifestParseError:
      discard
  let projectsDir = workspaceRoot / ".repo" / "manifests" / "projects"
  if dirExists(projectsDir):
    var single = ""
    var count = 0
    for kind, path in walkDir(projectsDir):
      if kind == pcFile and path.endsWith(".toml"):
        inc count
        single = path
    if count == 1:
      return extractFilename(single).changeFileExt("")
  ""

proc enumerateParticipatingRepos(workspaceRoot: string):
    tuple[mode: string; projectName: string;
          repos: seq[HookRepoTarget]] =
  ## Returns ``(mode, projectName, repos)``. ``mode`` is
  ## ``"workspace"`` when the workspace shell (workspace.toml or a
  ## resolvable project file) is present, ``"single-repo"`` otherwise.
  if isCompositionalWorkspaceToml(workspaceRoot):
    let workspaceToml = absolutePath(
      workspaceRoot / ".repo" / "workspace.toml")
    let resolved = composeManifestLayersFromFile(workspaceToml)
    result.mode = "workspace"
    result.projectName = resolved.projectName
    for repo in resolved.repos:
      result.repos.add(HookRepoTarget(name: repo.name,
        repoPath: workspaceRoot / repo.path))
    return
  let projectName = detectWorkspaceProjectName(workspaceRoot)
  if projectName.len > 0:
    let manifestsRoot = workspaceRoot / ".repo" / "manifests"
    let projectFile = manifestsRoot / "projects" / (projectName & ".toml")
    let variantFile = manifestsRoot / "variants" / (projectName & ".toml")
    var resolved: ResolvedProject
    if fileExists(projectFile):
      resolved = resolveProject(projectFile)
    elif fileExists(variantFile):
      resolved = resolveVariant(variantFile)
    else:
      resolved.projectName = ""
    if resolved.projectName.len > 0:
      result.mode = "workspace"
      result.projectName = resolved.projectName
      for repo in resolved.repos:
        result.repos.add(HookRepoTarget(name: repo.name,
          repoPath: workspaceRoot / repo.path))
      return
  result.mode = "single-repo"
  result.projectName = ""
  # The single-repo path leaves ``repos`` empty; the caller falls back to
  # ``gitHooksDir(targetPath)`` exactly like the pre-M17 implementation.

proc ensureWorkspaceHooks(workspaceRoot: string): HooksEnsureReport =
  ## M17 workspace-aware ``ensure`` driver. Walks every participating
  ## repo, installs the four canonical VCS hooks per repo, and returns
  ## a structured report. Exit code follows: 0 when every entry is
  ## ``installed`` / ``already-up-to-date`` / ``refreshed-drifted`` /
  ## ``chained-user-hook`` (all "success" outcomes — no failure
  ## classification exists for ensure on M17 since the installer either
  ## writes the bytes or raises).
  result.workspaceRoot = workspaceRoot
  let enumerated = enumerateParticipatingRepos(workspaceRoot)
  result.mode = enumerated.mode
  result.project = enumerated.projectName
  for repo in enumerated.repos:
    result.repos.add(repo.name)
  for repo in enumerated.repos:
    if not dirExists(repo.repoPath / ".git"):
      # Skip repos that the operator hasn't materialized yet — same
      # rule the legacy repo-workspaces installer used.
      continue
    let hooksDir = gitHooksDir(repo.repoPath)
    for hookName in VcsHookNames:
      let outcome = ensureVcsHookDetailed(hooksDir, hookName)
      let tag = vcsHookOutcomeTag(outcome)
      result.entries.add(VcsHookEntry(
        repo: repo.name,
        repoPath: repo.repoPath,
        hook: hookName,
        outcome: tag,
        hookPath: hookPath(hooksDir, hookName),
        managedPath: managedHookPath(hooksDir, hookName)))
      result.summary[tag] = result.summary.getOrDefault(tag, 0) + 1
  result.exitCode = 0

proc writeHooksEnsureReport(report: HooksEnsureReport) =
  let reportDir = report.workspaceRoot / ".repo" / "workspace"
  createDir(reportDir)
  let reportPath = reportDir / "hooks-report.json"
  writeFile(reportPath, pretty(report.toJsonNode(), indent = 2) & "\n")

proc uninstallVcsHook(hooksDir, hookName: string): bool =
  let standard = hookPath(hooksDir, hookName)
  let local = localHookPath(hooksDir, hookName)
  let managed = managedHookPath(hooksDir, hookName)
  if fileExists(extendedPath(standard)) and
      isReprobuildVcsHook(standard, hookName):
    result = removeFileIfExists(standard) or result
    if fileExists(extendedPath(local)):
      moveFileReplacing(local, standard)
      ensureExecutable(standard)
      result = true
  elif fileExists(extendedPath(standard)) and
      fileExists(extendedPath(managed)):
    raise newException(ValueError,
      "refusing to uninstall " & hookName & ": " & standard &
        " is not Reprobuild-managed")
  result = removeFileIfExists(managed) or result
  if fileExists(extendedPath(local)) and isReprobuildVcsHook(local, hookName):
    result = removeFileIfExists(local) or result

proc resolveHooksWorkspaceRoot(parsed: ParsedHooksCommand): string =
  ## Pick the workspace root for M17 enumeration. Priority:
  ##   1. ``--workspace-root=PATH`` (explicit override).
  ##   2. the positional ``[path]`` argument, when supplied.
  ##   3. the current working directory.
  ## The chosen path is normalised to an absolute path. We do NOT
  ## require that it resolves to a workspace — single-repo targets
  ## still flow through the legacy ``gitHooksDir`` fallback below.
  var raw =
    if parsed.workspaceRoot.len > 0: parsed.workspaceRoot
    elif parsed.targetPath.len > 0: parsed.targetPath
    else: getCurrentDir()
  result = os.normalizedPath(absolutePath(raw))

proc runVcsHooksCommand(action: HookActionKind; parsed: ParsedHooksCommand) =
  ## Single-repo legacy path for ``reinstall`` / ``uninstall``. ``ensure``
  ## now runs through the workspace-aware ``ensureWorkspaceHooks``
  ## driver below; this proc handles the single-repo subset the older
  ## actions still target.
  let targetPath = parsed.targetPath
  let hooksDir = gitHooksDir(targetPath)
  let actionName =
    case action
    of hakEnsure: "ensure"
    of hakReinstall: "reinstall"
    of hakUninstall: "uninstall"
  var changed = false
  if action == hakReinstall:
    for hookName in VcsHookNames:
      changed = uninstallVcsHook(hooksDir, hookName) or changed
  case action
  of hakEnsure, hakReinstall:
    for hookName in VcsHookNames:
      changed = ensureVcsHook(hooksDir, hookName) or changed
  of hakUninstall:
    for hookName in VcsHookNames:
      changed = uninstallVcsHook(hooksDir, hookName) or changed
  let status = if changed: "updated" else: "already current"
  echo "repro hooks: VCS hooks " & actionName & " " & status & " at " &
    hooksDir

proc runVcsHooksEnsureCommand(parsed: ParsedHooksCommand): int =
  ## M17 entry point for ``repro hooks ensure --vcs``. Resolves the
  ## workspace root, enumerates participating repos, installs the four
  ## canonical VCS hooks per repo, writes ``hooks-report.json`` and (on
  ## ``--json``) echoes the same JSON to stdout. Falls back to the
  ## legacy single-repo path when the target is not inside a workspace
  ## shell — that path is what ``.envrc`` triggers from non-workspace
  ## projects.
  let workspaceRoot = resolveHooksWorkspaceRoot(parsed)
  let enumerated = enumerateParticipatingRepos(workspaceRoot)
  if enumerated.mode == "single-repo":
    # Single-repo fallback. Mirror the legacy stdout line so callers
    # (notably ``.envrc``) don't lose their idempotent activation
    # signal.
    var single = parsed
    if single.targetPath.len == 0:
      single.targetPath = workspaceRoot
    runVcsHooksCommand(hakEnsure, single)
    return 0
  var report = ensureWorkspaceHooks(workspaceRoot)
  writeHooksEnsureReport(report)
  if parsed.json:
    stdout.writeLine(pretty(report.toJsonNode(), indent = 2))
  else:
    echo "repro hooks: ensured " & $report.entries.len &
      " VCS hook(s) across " & $report.repos.len &
      " repo(s) in workspace " & workspaceRoot
    var keys: seq[string]
    for k in report.summary.keys: keys.add(k)
    keys.sort()
    for k in keys:
      echo "  " & k & ": " & $report.summary[k]
  report.exitCode

proc parseHooksCommand(args: openArray[string]): ParsedHooksCommand =
  if args.len == 0:
    raise newException(ValueError,
      "repro hooks requires ensure, reinstall, or uninstall")
  case args[0]
  of "ensure":
    result.action = hakEnsure
  of "reinstall":
    result.action = hakReinstall
  of "uninstall":
    result.action = hakUninstall
  else:
    raise newException(ValueError,
      "unsupported hooks action: " & args[0])
  var i = 1
  while i < args.len:
    let arg = args[i]
    case arg
    of "--shell-direnv":
      result.shellDirenv = true
    of "--vcs":
      result.vcs = true
    of "--shell-autocomplete":
      raise newException(ValueError,
        "repro hooks --shell-autocomplete is not implemented yet")
    of "--shell":
      result.nativeShells.add(parseNativeShell(valueFromFlag(args, i,
        "--shell")))
    of "--workspace-root":
      result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
    of "--json":
      result.json = true
    else:
      if arg.startsWith("--shell="):
        var value = arg["--shell=".len .. ^1]
        if value.len == 0:
          raise newException(ValueError,
            "missing value for --shell")
        result.nativeShells.add(parseNativeShell(value))
      elif arg.startsWith("--workspace-root="):
        result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
      elif arg.startsWith("-"):
        raise newException(ValueError, "unsupported hooks flag: " & arg)
      elif result.targetPath.len > 0:
        raise newException(ValueError,
          "repro hooks accepts at most one path argument")
      else:
        result.targetPath = arg
    inc i
  if not result.shellDirenv and not result.vcs and
      result.nativeShells.len == 0:
    result.shellDirenv = true
    result.vcs = true

# Forward declaration: M18 wires ``pre-push`` dispatch through the
# ``repro check --mode=pre-push`` gate; the implementation lives further
# down (after ``runWorkspaceLockCommand``, which the gate calls to
# create / refresh the workspace lock).
proc runCheckCommand*(args: openArray[string]): int
proc runPostCommitLockCommand*(args: openArray[string]): int
proc runManifestRefreshHookCommand*(hookName: string;
                                    args: openArray[string]): int

proc runHooksDispatchCommand(args: openArray[string]): int =
  ## ``repro hooks dispatch <hook-name> [--repo-root=PATH]
  ## [--refs-file=PATH] -- [hook args...]``. Invoked by the managed
  ## VCS-hook scripts the M17 installer drops into every participating
  ## repo. M17 wired this as a no-op; M18 replaces the ``pre-push``
  ## arm with a call into ``repro check --mode=pre-push``; M19 replaces
  ## the ``post-commit`` arm with an in-process call to the best-effort
  ## lock refresh. M19a will register the post-merge / post-checkout
  ## bodies on top of the same contract.
  if args.len == 0:
    raise newException(ValueError,
      "repro hooks dispatch requires a hook name (one of: " &
      VcsHookNames.join(", ") & ")")
  let hookName = args[0]
  var found = false
  for known in VcsHookNames:
    if known == hookName:
      found = true
      break
  if not found:
    raise newException(ValueError,
      "unsupported hook name for dispatch: " & hookName &
        " (expected one of: " & VcsHookNames.join(", ") & ")")
  # Parse the standard dispatch argv shape: ``--repo-root=PATH`` and
  # (for pre-push) ``--refs-file=PATH``, optionally followed by ``--``
  # and the hook's own positional arguments. The values are forwarded
  # to the body via the documented ``repro check`` flag names so the
  # gate logic stays oblivious to the dispatch wrapper.
  var repoRoot = ""
  var refsFile = ""
  var i = 1
  while i < args.len:
    let arg = args[i]
    if arg == "--":
      break
    if arg == "--repo-root" or arg.startsWith("--repo-root="):
      repoRoot = valueFromFlag(args, i, "--repo-root")
    elif arg == "--refs-file" or arg.startsWith("--refs-file="):
      refsFile = valueFromFlag(args, i, "--refs-file")
    inc i
  case hookName
  of "pre-push":
    # M18 publication gate. Translate the dispatch argv into the
    # documented ``repro check`` surface and propagate the exit code
    # verbatim so the installed hook script can hand it back to git.
    #
    # When refsFile is empty the hook was invoked with no refs to
    # push (or invoked without git context, as in M17's
    # dispatch-noop test). git itself only fires pre-push when refs
    # exist, so an empty refs file means "nothing to gate" — return
    # 0 so dispatch stays a no-op until something is actually pushed.
    if refsFile.len == 0:
      return 0
    var checkArgs = @["--mode=pre-push"]
    if repoRoot.len > 0:
      checkArgs.add("--current-repo=" & repoRoot)
    checkArgs.add("--pushed-refs=" & refsFile)
    return runCheckCommand(checkArgs)
  of "post-commit":
    # M19 best-effort lock refresh. Always exits 0 even when the lock
    # writer refuses, no workspace.toml exists, or the workspace is
    # dirty: a commit must never be blocked by hook failure. The
    # wrapper itself logs all error paths to
    # ``<workspace>/.repro/workspace/post-commit-lock.log`` and writes
    # the JSON report to ``post-commit-report.json`` so the operator
    # can introspect the latest outcome.
    var postArgs: seq[string]
    if repoRoot.len > 0:
      postArgs.add("--current-repo=" & repoRoot)
    return runPostCommitLockCommand(postArgs)
  of "post-merge", "post-checkout":
    # M19a best-effort manifest-layer refresh. Always exits 0 — git
    # must not see a non-zero hook status. The dispatcher peels the
    # ``--repo-root`` flag off; the hook-supplied positional args
    # (post-checkout: ``<prev> <new> <flag>``; post-merge: the squash
    # flag) appear after ``--`` and are forwarded so the wrapper can
    # short-circuit when ``prev == new``.
    var refreshArgs: seq[string]
    if repoRoot.len > 0:
      refreshArgs.add("--current-repo=" & repoRoot)
    # Find the ``--`` separator in the original args and forward
    # everything after it as the hook-supplied positional argv.
    var j = 1
    while j < args.len and args[j] != "--":
      inc j
    if j < args.len:
      refreshArgs.add("--")
      for k in (j + 1) ..< args.len:
        refreshArgs.add(args[k])
    return runManifestRefreshHookCommand(hookName, refreshArgs)
  else:
    # M17 ground state for any remaining hook names: accept argv,
    # return 0, emit nothing. (All four canonical hooks are now wired,
    # so this branch is currently dead; it stays as a defensive
    # fallback when ``VcsHookNames`` later grows.)
    return 0

proc runHooksCommand(args: openArray[string]): int =
  if args.len > 0 and args[0] == "dispatch":
    let dispatchArgs =
      if args.len > 1: args[1 .. ^1]
      else: @[]
    return runHooksDispatchCommand(dispatchArgs)
  let parsed = parseHooksCommand(args)
  case parsed.action
  of hakEnsure:
    if parsed.shellDirenv:
      ensureDirenvHook(parsed.targetPath)
    if parsed.vcs:
      let code = runVcsHooksEnsureCommand(parsed)
      if code != 0:
        return code
    for shell in parsed.nativeShells:
      ensureNativeShellHook(shell)
  of hakReinstall:
    if parsed.shellDirenv:
      ensureDirenvHook(parsed.targetPath, reinstall = true)
    if parsed.vcs:
      runVcsHooksCommand(parsed.action, parsed)
    for shell in parsed.nativeShells:
      ensureNativeShellHook(shell, reinstall = true)
  of hakUninstall:
    if parsed.shellDirenv:
      uninstallDirenvHook(parsed.targetPath)
    if parsed.vcs:
      runVcsHooksCommand(parsed.action, parsed)
    for shell in parsed.nativeShells:
      uninstallNativeShellHook(shell)
  0

proc parseNativeShellActivationRequest(args: openArray[string]):
    NativeShellActivationRequest =
  if args.len == 0:
    raise newException(ValueError,
      "__repro-native-shell-activate requires a directory argument")
  result.cwd = args[0]
  result.shell = nskBash
  var i = 1
  while i < args.len:
    let arg = args[i]
    if arg == "--shell" or arg.startsWith("--shell="):
      result.shell = parseNativeShell(valueFromFlag(args, i, "--shell"))
    elif arg == "--previous-artifact" or
        arg.startsWith("--previous-artifact="):
      result.previousArtifact = valueFromFlag(args, i,
        "--previous-artifact")
    elif arg == "--previous-project-root" or
        arg.startsWith("--previous-project-root="):
      result.previousProjectRoot = valueFromFlag(args, i,
        "--previous-project-root")
    elif arg == "--dev-env-stats" or arg.startsWith("--dev-env-stats="):
      result.statsPath = valueFromFlag(args, i, "--dev-env-stats")
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported native shell activation flag: " & arg)
    else:
      raise newException(ValueError,
        "unexpected native shell activation argument: " & arg)
    inc i

proc runReproNativeShellActivationHelper(args: openArray[string];
                                         publicCliPath: string): int =
  let request = parseNativeShellActivationRequest(args)
  let format = nativeShellFormat(request.shell)
  let projectRoot = findDevEnvProjectRoot(request.cwd)
  if projectRoot.len == 0:
    stdout.write(renderNativeShellTransition(request.previousArtifact,
      none(DevEnvArtifact), "", format))
    return 0
  var selection = DevEnvCliSelection(
    selector: projectRoot,
    activity: "default",
    statsPath: request.statsPath)
  selection.resolveDevEnvSelection()
  let edge = computePublicDevEnv(selection, publicCliPath, renderShell = true)
  writeDevEnvStats(selection.statsPath, edge, "hooks shell-native")
  let artifact = readDevEnvArtifact(edge.artifactPath)
  if emitDevEnvDiagnostics(artifact):
    return 1
  stdout.write(renderNativeShellTransition(request.previousArtifact,
    some(artifact), edge.artifactPath, format))
  return 0

proc runReproDirenvActivationHelper(args: openArray[string];
                                    publicCliPath: string): int =
  var selection = DevEnvCliSelection()
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--activity" or arg.startsWith("--activity="):
      selection.activity.appendActivitySelection(valueFromFlag(args, i,
        "--activity"))
    elif arg == "--work-root" or arg.startsWith("--work-root="):
      selection.workRoot = valueFromFlag(args, i, "--work-root")
    elif arg == "--lock-slice" or arg.startsWith("--lock-slice="):
      selection.lockSliceId = valueFromFlag(args, i, "--lock-slice")
    elif arg == "--dev-env-stats" or arg.startsWith("--dev-env-stats="):
      selection.statsPath = valueFromFlag(args, i, "--dev-env-stats")
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported direnv activation flag: " & arg)
    elif selection.selector.len == 0:
      selection.selector = arg
    else:
      raise newException(ValueError,
        "unexpected direnv activation argument: " & arg)
    inc i
  selection.resolveDevEnvSelection()
  let edge = computePublicDevEnv(selection, publicCliPath, renderShell = true)
  writeDevEnvStats(selection.statsPath, edge, "hooks shell-direnv")
  stdout.write(readFile(extendedPath(edge.shellFragmentPath)))
  stdout.write(renderDevEnvShellOps([
    DevEnvShellOp(kind: deskSetEnv, name: "REPRO_DEV_ENV_ARTIFACT",
      value: edge.artifactPath),
    DevEnvShellOp(kind: deskSetEnv, name: "REPRO_DEV_ENV_PROJECT_ROOT",
      value: selection.projectRoot),
    DevEnvShellOp(kind: deskSetEnv, name: "REPRO_DEV_ENV_SELECTED_ACTIVITIES",
      value: selection.activity)
  ], depPosix))
  0

proc sourceLocation(file: string): SourceLocation =
  SourceLocation(file: file, line: 1)

proc cmakeNixExecutable(name: string): string =
  # Windows: Nix store binaries have a `.exe` suffix. The forked CMake build
  # tree from `metacraft-labs/reprobuild-cmake` also produces `cmake.exe`,
  # `cc.exe`, etc. Emit relative paths with `.exe` on Windows so the path-only
  # / Nix executablePath actually points at a runnable file.
  when defined(windows):
    case name
    of "cmake":
      "bin/cmake.exe"
    of "cc":
      "bin/cc.exe"
    of "c++":
      "bin/c++.exe"
    else:
      "bin/" & name & ".exe"
  else:
    case name
    of "cmake":
      "bin/cmake"
    of "cc":
      "bin/cc"
    of "c++":
      "bin/c++"
    else:
      "bin/" & name

proc cmakeNixSelector(name: string): string =
  case name
  of "cmake":
    "nixpkgs#cmake"
  of "cc", "c++":
    "nixpkgs#clang"
  else:
    "nixpkgs#" & name

proc cmakeToolUse(sourceRoot, name: string): InterfaceToolUse =
  let loc = sourceLocation(sourceRoot / "CMakeLists.txt")
  InterfaceToolUse(
    rawConstraint: name & " >=1.0 <2.0",
    packageSelector: name,
    executableName: name,
    nixProvisioning: @[InterfaceNixProvisioning(
      packageName: name,
      selector: cmakeNixSelector(name),
      executablePath: cmakeNixExecutable(name),
      packageId: cmakeNixSelector(name),
      lockIdentity: cmakeNixSelector(name),
      location: loc)],
    location: loc)

proc cmakeDevelopArtifact(sourceRoot: string): ProjectInterfaceArtifact =
  artifactFor(ProjectInterface(
    projectName: "cmakeDevelop",
    packageName: "cmakeDevelop",
    toolUses: @[
      cmakeToolUse(sourceRoot, "cmake"),
      cmakeToolUse(sourceRoot, "cc"),
      cmakeToolUse(sourceRoot, "c++")
    ],
    location: sourceLocation(sourceRoot / "CMakeLists.txt")))

proc cmakeDevelopOutDir(sourceRoot, workRoot: string): string =
  let scopedRoot = scopedWorktreeRoot(sourceRoot / "CMakeLists.txt", workRoot)
  if scopedRoot.len > 0:
    scopedRoot / "develop-cmake"
  else:
    sourceRoot / ".repro" / "develop-cmake"

proc profileFor(identity: PathOnlyBuildIdentity; executableName: string):
    PathOnlyToolProfile =
  for profile in identity.profiles:
    if profile.executableName == executableName:
      return profile
  raise newException(ValueError,
    "cmake develop profile did not resolve required tool: " & executableName)

proc pathListJoin(values: openArray[string]; separator: char): string =
  var filtered: seq[string] = @[]
  for value in values:
    if value.len > 0 and not filtered.contains(value):
      filtered.add(value)
  filtered.join($separator)

proc profilePrefixes(identity: PathOnlyBuildIdentity): seq[string] =
  for profile in identity.profiles:
    if profile.selectedStorePath.len > 0 and dirExists(
        extendedPath(profile.selectedStorePath)):
      if not result.contains(profile.selectedStorePath):
        result.add(profile.selectedStorePath)
    let binDir = parentDir(profile.resolvedExecutablePath)
    if binDir.len > 0:
      let prefix = parentDir(binDir)
      if prefix.len > 0 and dirExists(extendedPath(prefix)) and not result.contains(prefix):
        result.add(prefix)

proc pkgConfigPaths(prefixes: openArray[string]): seq[string] =
  for prefix in prefixes:
    for suffix in ["lib/pkgconfig", "share/pkgconfig"]:
      let candidate = prefix / suffix
      if dirExists(extendedPath(candidate)) and not result.contains(candidate):
        result.add(candidate)

proc cmakeEscape(value: string): string =
  value.replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$")

proc cmakeSet(name, kind, value: string; force = true): string =
  if value.len == 0:
    return ""
  "set(" & name & " \"" & cmakeEscape(value) & "\" CACHE " & kind &
    " \"Generated by repro develop --cmake\"" &
    (if force: " FORCE" else: "") & ")\n"

proc sdkRootForCMake(): string =
  let explicit = getEnv("SDKROOT")
  if explicit.len > 0 and dirExists(extendedPath(explicit)):
    return explicit

proc writeCMakeToolchain(path: string; identity: PathOnlyBuildIdentity;
                         mode: ToolProvisioningMode; identityPath,
                         inspectionPath: string) =
  let cProfile = identity.profileFor("cc")
  let cxxProfile = identity.profileFor("c++")
  let prefixes = profilePrefixes(identity)
  let prefixValue = pathListJoin(prefixes, ';')
  let pkgValue = pathListJoin(pkgConfigPaths(prefixes), PathSep)
  let sdkRoot = sdkRootForCMake()
  var content = "# Generated by repro develop --cmake. Do not edit.\n"
  content.add(cmakeSet("CMAKE_C_COMPILER", "FILEPATH",
    cProfile.resolvedExecutablePath))
  content.add(cmakeSet("CMAKE_CXX_COMPILER", "FILEPATH",
    cxxProfile.resolvedExecutablePath))
  content.add(cmakeSet("CMAKE_PREFIX_PATH", "STRING", prefixValue))
  when defined(macosx):
    content.add(cmakeSet("CMAKE_OSX_SYSROOT", "PATH", sdkRoot))
  elif defined(windows):
    # Windows: MSVC has no sysroot concept; the Windows SDK is selected
    # implicitly via the toolchain (vcvars / VS install), so we deliberately
    # omit both CMAKE_SYSROOT and CMAKE_OSX_SYSROOT here. Proper Windows SDK
    # pinning is a follow-up.
    discard
  else:
    content.add(cmakeSet("CMAKE_SYSROOT", "PATH", sdkRoot))
  content.add(cmakeSet("REPROBUILD_CMAKE_TOOL_PORTABILITY", "STRING",
    mode.modeName))
  content.add(cmakeSet("REPROBUILD_TOOL_PROFILE_ARTIFACT", "FILEPATH",
    identityPath))
  content.add(cmakeSet("REPROBUILD_TOOL_PROFILE_INSPECTION", "FILEPATH",
    inspectionPath))
  if pkgValue.len > 0:
    content.add("set(ENV{PKG_CONFIG_PATH} \"" & cmakeEscape(pkgValue) & "\")\n")
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), content)

proc shellAssign(name, value: string): string =
  name & "=" & q(value) & "\n"

proc resolveCMakeExecutable(candidate: string): string =
  # Windows: the resolved executable path may be recorded without the .exe
  # suffix (for example when it came from a Nix-style "bin/cmake" entry).
  # Probe for a .exe variant first so the wrapper actually points at a
  # runnable file. POSIX paths are returned unchanged.
  when defined(windows):
    if candidate.len == 0:
      return candidate
    if fileExists(extendedPath(candidate)):
      return candidate
    if not candidate.endsWith(".exe"):
      let withExe = candidate & ".exe"
      if fileExists(extendedPath(withExe)):
        return withExe
    candidate
  else:
    candidate

proc ps1SingleQuote(value: string): string =
  # Windows: emit a PowerShell single-quoted literal. PS single-quoted strings
  # do not expand variables and only escape the single quote itself by
  # doubling it.
  "'" & value.replace("'", "''") & "'"

proc writeCMakeConfigureWrapperPosix(path: string;
                                     selectedCmake, toolchainPath,
                                     identityPath, inspectionPath, sourceRoot,
                                     reproPath, sourceRepoRoot, prefixValue,
                                     pkgValue, sdkRoot,
                                     modeName: string) =
  var content = "#!/bin/sh\nset -eu\n"
  content.add(shellAssign("cmake_bin", selectedCmake))
  content.add(shellAssign("toolchain_file", toolchainPath))
  content.add(shellAssign("prefix_path", prefixValue))
  content.add(shellAssign("pkg_config_path", pkgValue))
  content.add(shellAssign("sdk_root", sdkRoot))
  content.add(shellAssign("repro_cli", reproPath))
  content.add(shellAssign("repro_source_root", sourceRepoRoot))
  content.add("export REPROBUILD_REPRO=\"$repro_cli\"\n")
  content.add("export REPROBUILD_SOURCE_ROOT=\"$repro_source_root\"\n")
  content.add("export REPRO_TOOL_PROFILE_ARTIFACT=" & q(identityPath) & "\n")
  content.add("export REPRO_TOOL_PROFILE_INSPECTION=" & q(inspectionPath) & "\n")
  content.add("export REPRO_PROJECT_ROOT=" & q(sourceRoot) & "\n")
  content.add("if [ -n \"$pkg_config_path\" ]; then\n")
  content.add("  if [ -n \"${PKG_CONFIG_PATH:-}\" ]; then\n")
  content.add("    export PKG_CONFIG_PATH=\"$pkg_config_path:$PKG_CONFIG_PATH\"\n")
  content.add("  else\n")
  content.add("    export PKG_CONFIG_PATH=\"$pkg_config_path\"\n")
  content.add("  fi\n")
  content.add("fi\n")
  content.add("extra_sysroot_args=\n")
  content.add("if [ -n \"$sdk_root\" ]; then\n")
  when defined(macosx):
    content.add("  extra_sysroot_args=\"-DCMAKE_OSX_SYSROOT=$sdk_root\"\n")
  else:
    content.add("  extra_sysroot_args=\"-DCMAKE_SYSROOT=$sdk_root\"\n")
  content.add("fi\n")
  content.add("exec \"$cmake_bin\" -G Reprobuild ")
  content.add("-DCMAKE_TOOLCHAIN_FILE=\"$toolchain_file\" ")
  content.add("-DCMAKE_PREFIX_PATH=\"$prefix_path\" ")
  content.add("-DREPROBUILD_CMAKE_TOOL_PORTABILITY=" & modeName & " ")
  content.add("-DREPROBUILD_TOOL_PROFILE_ARTIFACT=" & q(identityPath) & " ")
  content.add("-DREPROBUILD_TOOL_PROFILE_INSPECTION=" & q(inspectionPath) & " ")
  content.add("$extra_sysroot_args \"$@\"\n")
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), content)
  setFilePermissions(extendedPath(path), {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc writeCMakeConfigureWrapperWindows(path: string;
                                       selectedCmake, toolchainPath,
                                       identityPath, inspectionPath, sourceRoot,
                                       reproPath, sourceRepoRoot, prefixValue,
                                       pkgValue,
                                       modeName: string) =
  # Windows: emit a PowerShell wrapper instead of a POSIX `sh` script. The
  # script behaviour mirrors the POSIX wrapper: define the same variables,
  # export the same REPRO_* environment, prepend PKG_CONFIG_PATH if any, and
  # invoke the forked cmake.exe with -G Reprobuild plus any caller args.
  # CMAKE_(OSX_)SYSROOT is intentionally omitted: MSVC has no sysroot concept
  # and the Windows SDK is selected implicitly by the active toolchain.
  var content = "# Generated by repro develop --cmake. Do not edit.\n"
  content.add("$ErrorActionPreference = 'Stop'\n")
  content.add("$cmake_bin = " & ps1SingleQuote(selectedCmake) & "\n")
  content.add("$toolchain_file = " & ps1SingleQuote(toolchainPath) & "\n")
  content.add("$prefix_path = " & ps1SingleQuote(prefixValue) & "\n")
  content.add("$pkg_config_path = " & ps1SingleQuote(pkgValue) & "\n")
  content.add("$repro_cli = " & ps1SingleQuote(reproPath) & "\n")
  content.add("$repro_source_root = " & ps1SingleQuote(sourceRepoRoot) & "\n")
  content.add("$env:REPROBUILD_REPRO = $repro_cli\n")
  content.add("$env:REPROBUILD_SOURCE_ROOT = $repro_source_root\n")
  content.add("$env:REPRO_TOOL_PROFILE_ARTIFACT = " &
    ps1SingleQuote(identityPath) & "\n")
  content.add("$env:REPRO_TOOL_PROFILE_INSPECTION = " &
    ps1SingleQuote(inspectionPath) & "\n")
  content.add("$env:REPRO_PROJECT_ROOT = " & ps1SingleQuote(sourceRoot) & "\n")
  # Windows: $env:PATH uses ';' as separator; use [IO.Path]::PathSeparator
  # so the wrapper stays correct even if cross-shelled later.
  content.add("if ($pkg_config_path) {\n")
  content.add("  $sep = [IO.Path]::PathSeparator\n")
  content.add("  if ($env:PKG_CONFIG_PATH) {\n")
  content.add("    $env:PKG_CONFIG_PATH = \"$pkg_config_path$sep$($env:PKG_CONFIG_PATH)\"\n")
  content.add("  } else {\n")
  content.add("    $env:PKG_CONFIG_PATH = $pkg_config_path\n")
  content.add("  }\n")
  content.add("}\n")
  # Build the cmake argv as a PowerShell array. We store the identity and
  # inspection paths in $env:... already and re-reference them here via
  # PowerShell variables so each array element is a single value PS-side
  # (avoids `+` concatenation surprises that CMake mis-parsed as extra
  # source-dir paths).
  content.add("$tool_profile_artifact = " &
    ps1SingleQuote(identityPath) & "\n")
  content.add("$tool_profile_inspection = " &
    ps1SingleQuote(inspectionPath) & "\n")
  content.add("$cmake_args = @(\n")
  content.add("  '-G', 'Reprobuild',\n")
  content.add("  \"-DCMAKE_TOOLCHAIN_FILE=$toolchain_file\",\n")
  content.add("  \"-DCMAKE_PREFIX_PATH=$prefix_path\",\n")
  content.add("  '-DREPROBUILD_CMAKE_TOOL_PORTABILITY=" & modeName & "',\n")
  content.add("  \"-DREPROBUILD_TOOL_PROFILE_ARTIFACT=$tool_profile_artifact\",\n")
  content.add("  \"-DREPROBUILD_TOOL_PROFILE_INSPECTION=$tool_profile_inspection\"\n")
  content.add(")\n")
  content.add("& $cmake_bin @cmake_args @args\n")
  content.add("exit $LASTEXITCODE\n")
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), content)

proc cmakeConfigureWrapperBaseName(): string =
  # Windows: emit a `.ps1` wrapper instead of an extensionless shell script so
  # PowerShell (and the develop runner) picks the right interpreter.
  when defined(windows):
    "repro-cmake-configure.ps1"
  else:
    "repro-cmake-configure"

proc writeCMakeConfigureWrapper(path: string; identity: PathOnlyBuildIdentity;
                                mode: ToolProvisioningMode; cmakeBinary,
                                toolchainPath, identityPath, inspectionPath,
                                sourceRoot, reproPath, sourceRepoRoot: string) =
  let cmakeProfile = identity.profileFor("cmake")
  let rawSelected =
    if cmakeBinary.len > 0:
      absolutePath(cmakeBinary)
    else:
      cmakeProfile.resolvedExecutablePath
  let selectedCmake = resolveCMakeExecutable(rawSelected)
  let prefixes = profilePrefixes(identity)
  # CMake list values (CMAKE_PREFIX_PATH and friends) ALWAYS use ';' as the
  # separator, independent of host platform. PKG_CONFIG_PATH uses the host
  # shell's PATH separator (`PathSep` is ';' on Windows, ':' on POSIX).
  let prefixValue = pathListJoin(prefixes, ';')
  let pkgValue = pathListJoin(pkgConfigPaths(prefixes), PathSep)
  when defined(windows):
    # Windows: the SDK / sysroot concept does not apply to MSVC.
    writeCMakeConfigureWrapperWindows(path, selectedCmake, toolchainPath,
      identityPath, inspectionPath, sourceRoot, reproPath, sourceRepoRoot,
      prefixValue, pkgValue, mode.modeName)
  else:
    let sdkRoot = sdkRootForCMake()
    writeCMakeConfigureWrapperPosix(path, selectedCmake, toolchainPath,
      identityPath, inspectionPath, sourceRoot, reproPath, sourceRepoRoot,
      prefixValue, pkgValue, sdkRoot, mode.modeName)

proc runCMakeDevelopCommand(target: string; mode: ToolProvisioningMode;
                            command: openArray[string]; workRoot,
                            cmakeBinary: string): int =
  if mode notin {tpmPathOnly, tpmNix}:
    raise newException(ValueError,
      "repro develop --cmake requires --tool-provisioning=path|nix")
  let sourceRoot = absolutePath(target)
  if not dirExists(extendedPath(sourceRoot)):
    raise newException(IOError, "cmake source directory not found: " & sourceRoot)
  if not fileExists(extendedPath(sourceRoot / "CMakeLists.txt")):
    raise newException(IOError,
      "cmake source directory does not contain CMakeLists.txt: " & sourceRoot)
  if cmakeBinary.len > 0 and not fileExists(extendedPath(cmakeBinary)):
    raise newException(IOError, "cmake binary not found: " & cmakeBinary)

  let outDir = cmakeDevelopOutDir(sourceRoot, workRoot)
  let interfacePath = outDir / "cmake-develop-interface.rbsz"
  let artifact = cmakeDevelopArtifact(sourceRoot)
  writeInterfaceArtifact(interfacePath, artifact)
  let resolved = warmResolveAndWriteIdentity(artifact, outDir, mode)
  let toolchainPath = outDir / "reprobuild-cmake-toolchain.cmake"
  # Windows: filename includes .ps1 so PowerShell will execute it directly.
  let wrapperPath = outDir / "bin" / cmakeConfigureWrapperBaseName()
  writeCMakeToolchain(toolchainPath, resolved.identity, mode,
    resolved.identityPath, resolved.inspectionPath)
  writeCMakeConfigureWrapper(wrapperPath, resolved.identity, mode, cmakeBinary,
    toolchainPath, resolved.identityPath, resolved.inspectionPath, sourceRoot,
    stablePublicCliPath(), reprobuildLibraryWorkDir())

  echo "repro develop: compatibility cmake dev-env path active " &
    "(provider-driven artifact integration pending, tool-provisioning=" &
    mode.modeName & ")"
  echo "project: " & artifact.projectInterface.projectName
  echo "interface: " & interfacePath
  echo "toolIdentity: " & resolved.identityPath
  echo "inspection: " & resolved.inspectionPath
  echo "toolchain: " & toolchainPath
  echo "configureWrapper: " & wrapperPath
  echo "cachePortability: " & (if mode == tpmNix: "portable" else: "local-only")
  echo "binDirs: " & binDirsForDevelop(resolved.identity).join($PathSep)
  for profile in resolved.identity.profiles:
    echo "tool: " & profile.executableName & " " &
      profile.resolvedExecutablePath

  if command.len == 0:
    return 0
  var devCommand = @["sh", "-c",
    "PATH=" & q(parentDir(wrapperPath) & $PathSep &
      binDirsForDevelop(resolved.identity).join($PathSep) & $PathSep &
      getEnv("PATH")) & " " & shellCommand(command)]
  runInDevelopEnvironment(devCommand, sourceRoot, resolved.identity,
    resolved.identityPath, resolved.inspectionPath, interfacePath)

proc autoRunQuotaEnabled(): bool =
  getEnv("REPROBUILD_AUTO_RUNQUOTA", "1").normalize notin
    ["0", "false", "no", "off"]

const
  ## Explicit env-var whitelist forwarded from the user-facing CLI invocation
  ## across the daemon protocol into the daemon-hosted build executor. These are
  ## process-control / lookup-control variables that must follow the user, not
  ## the persistent daemon: the daemon may have been launched by launchd (macOS)
  ## or systemd-user (Linux) at login, so it does not naturally see the user's
  ## current shell environment.
  DaemonExplicitForwardedEnvVars* = [
    "PATH", "HOME", "USER", "TMPDIR", "TEMP", "TMP",
    "RUNQUOTA_SOCKET", "REPROBUILD_STORE_ROOT",
    "REPROBUILD_ACTION_CACHE_ROOT", "REPROBUILD_MAX_PARALLELISM",
    "REPRO_STATS_DIR", "REPROBUILD_NO_RUNQUOTA",
    "REPROBUILD_AUTO_RUNQUOTA",
    "REPRO_DAEMON_TEST_STATS_FLUSH_DELAY_MS",
    # Reprobuild's own build-time env vars consumed by config.nims and the
    # interface-extraction nim subprocesses. Without these, config.nims
    # defaults to vendored-hash mode and tries to compile from
    # references/mold/, which is gitignored and so missing in CI checkouts.
    "REPROBUILD_USE_SYSTEM_HASH_LIBS",
    "BLAKE3_PREFIX", "XXHASH_PREFIX", "SQLITE_PREFIX",
    "NIMCRYPTO_SRC", "RUNQUOTA_SRC", "BEARSSL_SRC", "CT_TEST_SRC",
    # CT_INTERPOSE_SRC threads the ct_interpose package (monitor hooks /
    # SIP-rewrite helpers) onto config.nims's --path. REPROBUILD_SOURCE_ROOT
    # lets reprobuildLibraryWorkDir() locate reprobuild's OWN libs
    # (repro_interface_artifacts, repro_project_dsl, ...) when compiling the
    # interface extractor and providers — the compiled-in source path points
    # at the now-deleted build sandbox, so without this env var the daemon
    # falls back to the project dir and the extractor fails with
    # "cannot open file: repro_interface_artifacts".
    "CT_INTERPOSE_SRC", "REPROBUILD_SOURCE_ROOT"
  ]

  ## Well-known toolchain env vars that must also be forwarded to the daemon
  ## when present in the user's shell. On Nix systems (especially macOS where
  ## ``-liconv`` must resolve to ``libiconv`` from the Nix store) the cc-wrapper
  ## consumes these to inject the correct ``-L``/``-isystem`` paths into clang/
  ## ld invocations driven by cargo/rustc. Without forwarding, a daemon spawned
  ## by launchd has none of them and cargo actions like
  ## ``db-replay-server-cargo`` fail at the rustc link step. Values are NEVER
  ## hardcoded; they are read live from the launching shell's environment.
  DaemonNixToolchainEnvVars* = [
    # Nix cc-wrapper inputs — consumed by the wrapper to extend the underlying
    # clang/ld invocation with the correct -L/-isystem paths.
    "NIX_LDFLAGS",
    "NIX_LDFLAGS_FOR_TARGET",
    "NIX_CFLAGS_COMPILE",
    "NIX_CFLAGS_COMPILE_FOR_TARGET",
    "NIX_CFLAGS_LINK",
    "NIX_CFLAGS_LINK_FOR_TARGET",
    "NIX_CXXSTDLIB_COMPILE",
    "NIX_CXXSTDLIB_LINK",
    "NIX_HARDENING_ENABLE",
    "NIX_NO_SELF_RPATH",
    "NIX_DEBUG_INFO_DIRS",
    "NIX_COREFOUNDATION_RPATH",
    "NIX_DONT_SET_RPATH",
    "NIX_DONT_SET_RPATH_FOR_TARGET",
    "NIX_ENFORCE_NO_NATIVE",
    "NIX_IGNORE_LD_THROUGH_GCC",
    "NIX_SSL_CERT_FILE",
    "SSL_CERT_FILE",
    # Loader search paths used by clang/ld during link, and by dyld at runtime.
    "LIBRARY_PATH",
    "LD_LIBRARY_PATH",
    "DYLD_LIBRARY_PATH",
    "DYLD_FALLBACK_LIBRARY_PATH",
    # macOS SDK selection (cc-wrapper uses SDKROOT to gate --sysroot).
    "SDKROOT",
    "MACOSX_DEPLOYMENT_TARGET",
    # Pkgconfig + Cargo toolchain configuration that the user expects to flow
    # into cargo invocations under nix-develop.
    "PKG_CONFIG_PATH",
    "PKG_CONFIG_PATH_FOR_TARGET",
    "CARGO_HOME",
    "RUSTUP_HOME",
    "RUSTUP_TOOLCHAIN",
    "RUSTFLAGS",
    "CARGO_BUILD_TARGET",
    "CARGO_NET_OFFLINE"
  ]

  ## Env-var name prefixes forwarded wholesale. The cc-wrapper synthesizes
  ## per-tuple variables of the form
  ## ``NIX_LDFLAGS_<HOST>_<TARGET>``/``NIX_CFLAGS_COMPILE_<HOST>_<TARGET>`` /
  ## ``NIX_BINTOOLS_WRAPPER_TARGET_HOST_<triple>`` whose suffixes vary by host
  ## triple (e.g. ``aarch64_apple_darwin``). Forwarding them by prefix avoids
  ## host-specific allowlist drift.
  DaemonNixToolchainEnvPrefixes* = [
    "NIX_LDFLAGS_",
    "NIX_CFLAGS_",
    "NIX_BINTOOLS_",
    "NIX_CC_",
    "NIX_BUILD_CORES",
    "NIX_STORE",
    "NIX_USER_PROFILE_DIR",
    "NIX_PROFILES"
  ]

proc daemonCarriedEnvironment*(): seq[string] =
  ## Snapshot of the user-facing CLI process environment forwarded to the
  ## daemon-hosted build/watch executor. The daemon installs each entry via
  ## ``putEnv`` before running the build session, so subsequent child actions
  ## (rustc, cargo, clang, ld via cc-wrapper, ...) inherit the user's
  ## toolchain configuration even when the daemon itself was launched without
  ## that configuration (e.g. by launchd/systemd at login).
  ##
  ## The set is intentionally union-of-three:
  ##  * explicit operational whitelist (PATH/HOME/RUNQUOTA_SOCKET/...);
  ##  * well-known Nix cc-wrapper + loader variables;
  ##  * host-triple-suffixed Nix variables matched by prefix (so we do not
  ##    have to bake the host triple into source).
  ##
  ## All values are read live from the current process environment; nothing
  ## is hardcoded. On non-Nix hosts the Nix entries simply contribute zero
  ## additional values because none are set.
  var seen = initHashSet[string]()
  for key, value in envPairs():
    if key.len == 0 or seen.contains(key):
      continue
    var matched = false
    if key in DaemonExplicitForwardedEnvVars:
      matched = true
    elif key in DaemonNixToolchainEnvVars:
      matched = true
    else:
      for prefix in DaemonNixToolchainEnvPrefixes:
        if key.startsWith(prefix):
          matched = true
          break
    if matched:
      seen.incl(key)
      result.add(key & "=" & value)

proc startAutoRunQuotaIfNeeded(bypassRunQuota: bool): owned(Process) =
  if bypassRunQuota or getEnv("RUNQUOTA_SOCKET", "").len > 0 or
      not autoRunQuotaEnabled():
    return nil
  var runquotad = getEnv("RUNQUOTAD_BIN", "")
  if runquotad.len == 0:
    runquotad = findExe("runquotad")
  if runquotad.len == 0:
    return nil
  let socket = getTempDir() / ("reprobuild-runquota-" &
    $getCurrentProcessId() & ".sock")
  if fileExists(socket):
    removeFile(socket)
  result = startProcess(runquotad, args = [
    "--socket", socket,
    "--cpu-milli", $int(buildMaxParallelism() * 1000'u32),
    "--memory-bytes", "17179869184"
  ], options = {poUsePath})
  putEnv("RUNQUOTA_SOCKET", socket)
  for _ in 0 ..< 300:
    if isRunQuotaDaemonReachable():
      return
    if not result.running:
      break
    sleep(50)
  try:
    result.terminate()
    discard result.waitForExit()
    result.close()
  except CatchableError:
    discard
  putEnv("RUNQUOTA_SOCKET", "")
  raise newException(OSError,
    "runquotad did not become reachable at " & socket)

proc runDepsRefreshCommand(args: openArray[string]): int =
  ## Implements ``repro deps refresh`` — the Mode 3 scanner CLI.
  ##
  ## Three behaviours, selected by flag:
  ##   * default      : scan, write ``repro.scanned-deps.nim`` atomically
  ##                    (temp file + rename), return 0.
  ##   * ``--check``  : scan, compare to on-disk file, return 0 if
  ##                    up-to-date or 1 if drifted. Never writes.
  ##   * ``--dry-run``: scan, print what the new file would contain to
  ##                    stdout (and the unified diff against the on-disk
  ##                    file as a comment header). Never writes.
  ##
  ## Project resolution: a single positional argument (or ``--project=PATH``)
  ## is used as the workspace root; default is the current working dir.
  ## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"`repro
  ## deps refresh` CLI" for the contract.
  var projectArg = ""
  var checkOnly = false
  var dryRun = false
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--help" or arg == "-h":
      echo "usage: repro deps refresh [--check] [--dry-run] [--project=PATH] [PATH]"
      return 0
    elif arg == "--check":
      checkOnly = true
    elif arg == "--dry-run":
      dryRun = true
    elif arg == "--project":
      if i + 1 >= args.len:
        raise newException(ValueError, "--project requires a value")
      projectArg = args[i + 1]
      inc i
    elif arg.startsWith("--project="):
      projectArg = arg["--project=".len .. ^1]
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported deps refresh flag: " & arg)
    elif projectArg.len == 0:
      projectArg = arg
    else:
      raise newException(ValueError,
        "unexpected deps refresh argument: " & arg)
    inc i

  let workspaceRoot =
    if projectArg.len == 0:
      getCurrentDir()
    else:
      absolutePath(projectArg)
  if not dirExists(workspaceRoot):
    raise newException(ValueError,
      "deps refresh: workspace root does not exist: " & workspaceRoot)

  # Mode 3 multi-language scan: combine the Nim and the C/C++ scanner
  # outputs into a single deterministic ``ScanResult``. ``scanWorkspaceAll``
  # lives in ``repro_core/cpp_dep_scanner`` and unions both scanners'
  # member + edge seqs with per-key dedup so a mixed-language workspace
  # produces a byte-stable ``repro.scanned-deps.nim``.
  let scan = scanWorkspaceAll(workspaceRoot)
  let rendered = renderScannedDepsFile(scan.edges, ReprobuildVersion,
    scan.members, workspaceRoot)

  # The output file lives next to the project file; we honour
  # whichever name the user has on disk (repro.nim vs reprobuild.nim).
  let projectMatch = resolveProjectFile(workspaceRoot)
  let outputPath = workspaceRoot / "repro.scanned-deps.nim"

  if dryRun:
    echo "# DRY RUN — would write to ", outputPath
    if projectMatch.path.len == 0:
      echo "# warning: no repro.nim / reprobuild.nim found at ",
        workspaceRoot,
        " — the generated file will only be useful once one is created."
    stdout.write(rendered)
    return 0

  let existing = readExistingScannedDeps(outputPath)
  if existing == rendered:
    if checkOnly:
      return 0
    # Up-to-date already; nothing to write. Idempotent re-run.
    return 0

  if checkOnly:
    stderr.writeLine("repro deps refresh --check: " &
      "repro.scanned-deps.nim is out of date at " & outputPath)
    stderr.writeLine("  run `repro deps refresh` to regenerate.")
    return 1

  # Atomic write: temp file in the same dir, then rename. The same-dir
  # rule is what guarantees atomicity on Windows + POSIX (cross-volume
  # renames silently fall back to copy+delete).
  let tempPath = outputPath & ".tmp"
  try:
    writeFile(tempPath, rendered)
    moveFile(tempPath, outputPath)
  except CatchableError as err:
    if fileExists(tempPath):
      try:
        removeFile(tempPath)
      except CatchableError:
        discard
    raise newException(ValueError,
      "deps refresh: failed to write " & outputPath & ": " & err.msg)

  echo "wrote ", outputPath, " (", scan.edges.len, " edges across ",
    scan.members.len, " targets)"
  0

const
  KnownConventionRegistry* = [
    "nim",
    "rust",
    "go",
    "python",
    "javascript-typescript",
    "c-cpp-autotools",
    "c-cpp-cmake",
    "c-cpp-meson",
    "c-cpp-make",
    "java-maven",
    "kotlin-gradle",
    "csharp-dotnet",
    "swift-swiftpm",
    "c-cpp-direct",
    "rust-direct",
    "go-direct",
    "python-direct",
    "jsts-direct",
    "fortran-direct",
    "zig-direct",
    "d-direct",
    "ada-direct",
    "pascal-direct",
    "crystal",
    "erlang-rebar3",
    "elixir-mix",
    "ocaml-dune",
    "haskell-cabal",
    "ruby-bundler",
    "php-composer",
  ]
    ## The convention list ``repro show-conventions`` prints when asked
    ## for the registry order. Mirrors the registration order in
    ## ``apps/repro-standard-provider/repro_standard_provider.nim`` (which
    ## is the binary that actually holds the populated
    ## ``defaultConventionRegistry`` — the ``repro`` CLI itself doesn't
    ## link the per-language plugins, so we expose a static
    ## hand-maintained list here for diagnostics rather than touching
    ## the registry on disk).
    ##
    ## **Order matters.** The c-cpp triple must list ``c-cpp-autotools``
    ## BEFORE ``c-cpp-cmake`` BEFORE ``c-cpp-make`` to mirror the
    ## registration order in the standard-provider binary (a project
    ## carrying both a Makefile and ``configure.ac`` is routed through
    ## Autotools because it ``recognize``-matches first; a project
    ## carrying CMakeLists.txt routes through ``c-cpp-cmake`` (M38) ahead
    ## of the Make convention which separately rejects CMakeLists.txt
    ## presence). The order documented here is the order users see in
    ## ``repro show-conventions`` and must match reality. If the standard
    ## provider binary changes registration order, update this constant
    ## to match — the pin test in
    ## ``libs/repro_standard_provider/tests/test_known_convention_registry_pin.nim``
    ## fails loudly when the two drift.

proc renderShowConventionsText(workspaceRoot: string;
                               projectMatch: ProjectFileMatch;
                               members: seq[WorkspaceMember];
                               scanned: seq[DepEdge];
                               manual: seq[ManualDepEdge];
                               targetFilter: string): string =
  ## Pretty-printer for ``repro show-conventions``. Output shape is
  ## documented in ``reprobuild-specs/Three-Mode-Convention-System.md``
  ## §"Observability"; this is the human-readable projection (the JSON
  ## projection lives in ``renderShowConventionsJson``).
  ##
  ## **Attribution / toolchain / no-match** (the three M-deferred items):
  ## the "Language convention" line for each target is now computed by
  ## ``attributeConvention`` (manifest detection + extension census; the
  ## heuristic is documented in ``repro_core/convention_attribution.nim``,
  ## option 1c — the pragmatic CLI-side approximation). After the
  ## per-target section, ``findUnclaimedDirectories`` adds a "No-match
  ## diagnostics" block listing target-shaped dirs the heuristic couldn't
  ## claim. Each detected convention's toolchain version is probed (at
  ## most once per convention per process) via ``probeToolchain`` and
  ## printed next to the target's convention line.
  result = "Project: " & workspaceRoot & "\n"
  if projectMatch.path.len == 0:
    result.add("Project file: (none — no repro.nim or reprobuild.nim " &
      "in this directory)\n")
  else:
    let canonical = projectMatch.fileName == CanonicalProjectFileName
    let suffix = if canonical: " (canonical)" else: " (legacy alias)"
    result.add("Project file: " & projectMatch.fileName & suffix & "\n")
  result.add("\n")

  # Track which conventions appeared at least once so the toolchain
  # probe summary can iterate the right set.
  var conventionsSeen: HashSet[string]

  if members.len == 0:
    result.add("No targets discovered.\n")
    result.add("  (the scanner walks for ``executable`` / ``library`` " &
      "declarations under apps/, libs/, or the workspace root; none " &
      "matched)\n\n")
  else:
    # Index scanned edges + manual edges by source package for fast
    # per-target rendering.
    var scannedByFrom: Table[string, seq[DepEdge]]
    for edge in scanned:
      scannedByFrom.mgetOrPut(edge.fromPackage, @[]).add(edge)
    var manualByFrom: Table[string, seq[ManualDepEdge]]
    for edge in manual:
      manualByFrom.mgetOrPut(edge.fromPackage, @[]).add(edge)
    var matched = 0
    for member in members:
      if targetFilter.len > 0 and member.member != targetFilter and
          member.package != targetFilter:
        continue
      inc matched
      # Attribute the convention from the member's project-root
      # directory. Default to ``"nim"`` when the heuristic abstains
      # (the scanner only finds Nim-declared members today, so an
      # abstain on a discovered member means "no clearer signal than
      # the existence of repro.nim itself" — fall back to ``nim``).
      let attribution = attributeConvention(member.projectRoot)
      let conventionName =
        if attribution.convention.len > 0:
          attribution.convention
        else:
          "nim"
      conventionsSeen.incl(conventionName)
      result.add("Target: " & member.package & "." & member.member & "\n")
      if attribution.evidence.len > 0:
        result.add("  Language convention: " & conventionName &
          " (" & attribution.evidence & ")\n")
      else:
        result.add("  Language convention: " & conventionName & "\n")
      if member.sourceFile.len > 0:
        var relSource =
          try:
            relativePath(member.sourceFile, workspaceRoot)
          except OSError:
            member.sourceFile
        relSource = relSource.replace('\\', '/')
        result.add("  Source layout: " & relSource & "\n")
      else:
        result.add("  Source layout: (no src/" & member.member &
          ".nim on disk)\n")
      var relProjectFile =
        try:
          relativePath(member.projectFile, workspaceRoot)
        except OSError:
          member.projectFile
      relProjectFile = relProjectFile.replace('\\', '/')
      result.add("  Project file: " & relProjectFile & "\n")
      let scannedEdges = scannedByFrom.getOrDefault(member.package, @[])
      # The scanner emits edges keyed by package, not by member —
      # filter to UNIQUE (toPackage, evidence) pairs so two members of
      # the same package don't double-print every edge.
      result.add("  Workspace deps (from scanner):\n")
      if scannedEdges.len == 0:
        result.add("    (no edges)\n")
      else:
        var seen: HashSet[string]
        for edge in scannedEdges:
          let key = edge.toPackage & "\x1f" & edge.evidence
          if key in seen:
            continue
          seen.incl(key)
          result.add("    - " & edge.toPackage & " (evidence: " &
            edge.evidence & ")\n")
      let manualEdges = manualByFrom.getOrDefault(member.package, @[])
      result.add("  Workspace deps (manual, from project file):\n")
      if manualEdges.len == 0:
        result.add("    (none)\n")
      else:
        var seen: HashSet[string]
        for edge in manualEdges:
          let key = edge.toPackage & "\x1f" & $edge.sourceLine
          if key in seen:
            continue
          seen.incl(key)
          result.add("    - " & edge.toPackage & " (declared at " &
            relProjectFile & ":" & $edge.sourceLine & ")\n")
      result.add("\n")
    if targetFilter.len > 0 and matched == 0:
      result.add("(no target named ``" & targetFilter &
        "`` discovered in this workspace)\n\n")

  # No-match diagnostics. Only when the user didn't ask for a single
  # target (the diagnostic is workspace-wide).
  if targetFilter.len == 0:
    var claimedPaths: seq[string] = @[]
    for member in members:
      if member.projectRoot.len > 0:
        claimedPaths.add(member.projectRoot)
    let unclaimed = findUnclaimedDirectories(workspaceRoot, claimedPaths)
    result.add("No-match diagnostics:\n")
    if unclaimed.len == 0:
      result.add("  (no unclaimed target-shaped directories)\n")
    else:
      for entry in unclaimed:
        var line = "  " & entry.relPath & "/ — " & entry.reason
        if entry.sampleFiles.len > 0:
          line.add(" (files: ")
          for i, f in entry.sampleFiles:
            if i > 0: line.add(", ")
            line.add(f)
          line.add(")")
        line.add("\n")
        result.add(line)
    result.add("\n")

  # Toolchain probe summary. We probe each convention that appeared as
  # a per-target claim. Misses print the "not on PATH (skipped)"
  # variant, matching the spec's example output.
  if targetFilter.len == 0 and conventionsSeen.len > 0:
    result.add("Toolchain probes:\n")
    # Iterate the known registry order so the output is deterministic
    # across runs even if the conventions hash to different buckets.
    for name in KnownConventionRegistry:
      if name notin conventionsSeen:
        continue
      let probe = probeToolchain(name)
      if probe.available:
        let suffix =
          if probe.path.len > 0:
            " [" & probe.path.replace('\\', '/') & "]"
          else:
            ""
        result.add("  " & name & ": " & probe.version & suffix & "\n")
      else:
        result.add("  " & name & ": not on PATH (skipped)\n")
    result.add("\n")

  result.add("Conventions registered (in dispatch order):\n")
  for name in KnownConventionRegistry:
    result.add("  - " & name & "\n")
  result.add("\n")
  result.add("Note: the convention registry above is the static list " &
    "the standard-provider binary registers at startup; the per-target " &
    "claim attribution above is a CLI-side heuristic (manifest detection " &
    "plus extension census; see ``repro_core/convention_attribution.nim`` " &
    "option 1c). The standard-provider's actual ``recognize`` is the " &
    "source of truth at build time.\n")

proc renderShowConventionsJson(workspaceRoot: string;
                               projectMatch: ProjectFileMatch;
                               members: seq[WorkspaceMember];
                               scanned: seq[DepEdge];
                               manual: seq[ManualDepEdge];
                               targetFilter: string): JsonNode =
  ## JSON projection of the same data the text renderer prints.
  ## Stable shape: top-level object with ``project``, ``projectFile``,
  ## ``targets[]``, ``conventions[]``. Each target carries its own
  ## ``scannedDeps[]`` and ``manualDeps[]`` arrays.
  result = newJObject()
  result["project"] = %workspaceRoot
  if projectMatch.path.len == 0:
    result["projectFile"] = newJNull()
  else:
    let pfNode = newJObject()
    pfNode["fileName"] = %projectMatch.fileName
    pfNode["canonical"] = %(projectMatch.fileName == CanonicalProjectFileName)
    result["projectFile"] = pfNode
  var scannedByFrom: Table[string, seq[DepEdge]]
  for edge in scanned:
    scannedByFrom.mgetOrPut(edge.fromPackage, @[]).add(edge)
  var manualByFrom: Table[string, seq[ManualDepEdge]]
  for edge in manual:
    manualByFrom.mgetOrPut(edge.fromPackage, @[]).add(edge)
  var conventionsSeen: HashSet[string]
  let targets = newJArray()
  for member in members:
    if targetFilter.len > 0 and member.member != targetFilter and
        member.package != targetFilter:
      continue
    let entry = newJObject()
    entry["package"] = %member.package
    entry["member"] = %member.member
    # Per-target convention attribution (manifest detection + extension
    # census; see ``repro_core/convention_attribution.nim`` option 1c).
    # The heuristic abstains for projects with only a project file (no
    # manifest, no source extensions matched); fall back to ``"nim"``
    # for the scanner-discovered targets because the scanner itself is
    # the Nim-only Mode-3 pilot today.
    let attribution = attributeConvention(member.projectRoot)
    let conventionName =
      if attribution.convention.len > 0:
        attribution.convention
      else:
        "nim"
    conventionsSeen.incl(conventionName)
    entry["convention"] = %conventionName
    let attrNode = newJObject()
    attrNode["convention"] = %conventionName
    attrNode["evidence"] = %attribution.evidence
    entry["attribution"] = attrNode
    if member.sourceFile.len > 0:
      var relSource =
        try:
          relativePath(member.sourceFile, workspaceRoot)
        except OSError:
          member.sourceFile
      relSource = relSource.replace('\\', '/')
      entry["sourceFile"] = %relSource
    else:
      entry["sourceFile"] = newJNull()
    var relProjectFile =
      try:
        relativePath(member.projectFile, workspaceRoot)
      except OSError:
        member.projectFile
    relProjectFile = relProjectFile.replace('\\', '/')
    entry["projectFile"] = %relProjectFile
    let scannedNode = newJArray()
    var seenScan: HashSet[string]
    for edge in scannedByFrom.getOrDefault(member.package, @[]):
      let key = edge.toPackage & "\x1f" & edge.evidence
      if key in seenScan:
        continue
      seenScan.incl(key)
      let e = newJObject()
      e["to"] = %edge.toPackage
      e["evidence"] = %edge.evidence
      scannedNode.add(e)
    entry["scannedDeps"] = scannedNode
    let manualNode = newJArray()
    var seenManual: HashSet[string]
    for edge in manualByFrom.getOrDefault(member.package, @[]):
      let key = edge.toPackage & "\x1f" & $edge.sourceLine
      if key in seenManual:
        continue
      seenManual.incl(key)
      let e = newJObject()
      e["to"] = %edge.toPackage
      e["sourceLine"] = %edge.sourceLine
      manualNode.add(e)
    entry["manualDeps"] = manualNode
    targets.add(entry)
  result["targets"] = targets
  # No-match diagnostics (only when not filtering to a single target).
  let unclaimedNode = newJArray()
  if targetFilter.len == 0:
    var claimedPaths: seq[string] = @[]
    for member in members:
      if member.projectRoot.len > 0:
        claimedPaths.add(member.projectRoot)
    for entry in findUnclaimedDirectories(workspaceRoot, claimedPaths):
      let n = newJObject()
      n["path"] = %entry.relPath
      n["reason"] = %entry.reason
      let samples = newJArray()
      for s in entry.sampleFiles:
        samples.add(%s)
      n["sampleFiles"] = samples
      unclaimedNode.add(n)
  result["unclaimedDirectories"] = unclaimedNode
  # Toolchain probes (only when not filtering to a single target).
  let toolchainNode = newJArray()
  if targetFilter.len == 0:
    for name in KnownConventionRegistry:
      if name notin conventionsSeen:
        continue
      let probe = probeToolchain(name)
      let n = newJObject()
      n["convention"] = %name
      n["available"] = %probe.available
      n["version"] = %probe.version
      if probe.path.len > 0:
        n["path"] = %probe.path.replace('\\', '/')
      else:
        n["path"] = newJNull()
      toolchainNode.add(n)
  result["toolchainProbes"] = toolchainNode
  let conventionsNode = newJArray()
  for name in KnownConventionRegistry:
    conventionsNode.add(%name)
  result["conventions"] = conventionsNode

# ----------------------------------------------------------------------
# M48 — Mode 1 show-conventions renderers. Output prefix ``[Mode 1 —
# inferred from layout]`` so users can tell when they're seeing
# Mode 1 inference vs Mode 3 scanned output. See the M48 section of
# Mode3-Language-Expansion.milestones.org.
# ----------------------------------------------------------------------

proc renderMode1ShowConventionsText(ws: Mode1Workspace;
                                    targetFilter: string): string =
  ## Human-readable Mode 1 show-conventions output. Sibling of
  ## ``renderShowConventionsText`` for the Mode 1 case.
  result = "[Mode 1 — inferred from layout]\n"
  result.add("Project: " & ws.workspaceRoot & "\n")
  result.add("Project file: (none — Mode 1 synthesises in-memory)\n")
  if ws.syntheticProjectFile.len > 0:
    result.add("Synthesised under: " & ws.syntheticProjectFile & "\n")
  result.add("\n")
  if ws.ambiguousImports.len > 0:
    result.add("AMBIGUOUS IMPORTS — Mode 1 cannot proceed:\n")
    for incident in ws.ambiguousImports:
      var rel =
        try:
          relativePath(incident.sourceFile, ws.workspaceRoot)
        except OSError:
          incident.sourceFile
      rel = rel.replace('\\', '/')
      result.add("  - " & rel & ":" & $incident.lineNumber &
        ": import '" & incident.importHead &
        "' resolves to: " & incident.candidates.join(", ") & "\n")
    result.add("\n")
    result.add("Resolve by graduating to Mode 3: write a repro.nim " &
      "with explicit depends_on edges.\n\n")
    return
  if ws.targets.len == 0:
    result.add("No Mode 1 targets discovered.\n")
    result.add("  (the loader scanned apps/, libs/, tools/, cmd/, " &
      "pkg/, bin/ and the workspace's src/ — none matched)\n\n")
    return
  result.add("Inferred targets:\n")
  for target in ws.targets:
    if targetFilter.len > 0 and target.name != targetFilter:
      continue
    let kindLabel =
      if target.kind == m1tkExecutable: "executable" else: "library"
    result.add("  - " & target.name & " (" & kindLabel & ")\n")
    result.add("    Source dir: " & target.relDir & "\n")
    result.add("    Language: " & languageName(target.language) & "\n")
    if target.entrySource.len > 0:
      var rel =
        try:
          relativePath(target.entrySource, ws.workspaceRoot)
        except OSError:
          target.entrySource
      rel = rel.replace('\\', '/')
      result.add("    Entry source: " & rel & "\n")
    var censusKeys: seq[string] = @[]
    for ext, _ in target.extensionCensus.pairs:
      censusKeys.add(ext)
    censusKeys.sort(system.cmp[string])
    var censusParts: seq[string] = @[]
    for ext in censusKeys:
      censusParts.add(ext & "=" & $target.extensionCensus[ext])
    result.add("    Extension census: " & censusParts.join(", ") & "\n")
  result.add("\n")
  if ws.edges.len > 0:
    result.add("Inferred dep edges (scanner):\n")
    for edge in ws.edges:
      result.add("  - " & edge.fromPackage & " -> " & edge.toPackage &
        " (evidence: " & edge.evidence & ")\n")
  else:
    result.add("Inferred dep edges (scanner): (no in-workspace edges)\n")
  result.add("\n")
  if ws.diagnostics.len > 0:
    result.add("Diagnostics:\n")
    for d in ws.diagnostics:
      if d.target.len > 0:
        result.add("  - [" & d.target & "] " & d.message & "\n")
      else:
        result.add("  - " & d.message & "\n")
    result.add("\n")
  result.add("Persistence policy: Mode 1 does NOT write " &
    "repro.scanned-deps.nim to the workspace root.\n")

proc renderMode1ShowConventionsJson(ws: Mode1Workspace;
                                    targetFilter: string): JsonNode =
  ## JSON projection of the Mode 1 show-conventions output.
  result = newJObject()
  result["mode"] = %"mode1"
  result["project"] = %ws.workspaceRoot
  if ws.syntheticProjectFile.len > 0:
    result["synthesisedProjectFile"] = %ws.syntheticProjectFile
  else:
    result["synthesisedProjectFile"] = newJNull()
  let targetsNode = newJArray()
  for target in ws.targets:
    if targetFilter.len > 0 and target.name != targetFilter:
      continue
    let entry = newJObject()
    entry["name"] = %target.name
    entry["relDir"] = %target.relDir
    entry["kind"] =
      %(if target.kind == m1tkExecutable: "executable" else: "library")
    entry["language"] = %languageName(target.language)
    if target.entrySource.len > 0:
      var rel =
        try:
          relativePath(target.entrySource, ws.workspaceRoot)
        except OSError:
          target.entrySource
      rel = rel.replace('\\', '/')
      entry["entrySource"] = %rel
    else:
      entry["entrySource"] = newJNull()
    let censusNode = newJObject()
    for ext, count in target.extensionCensus.pairs:
      censusNode[ext] = %count
    entry["extensionCensus"] = censusNode
    targetsNode.add(entry)
  result["targets"] = targetsNode
  let edgesNode = newJArray()
  for edge in ws.edges:
    let e = newJObject()
    e["from"] = %edge.fromPackage
    e["to"] = %edge.toPackage
    e["evidence"] = %edge.evidence
    edgesNode.add(e)
  result["edges"] = edgesNode
  let diagsNode = newJArray()
  for d in ws.diagnostics:
    let n = newJObject()
    n["target"] = %d.target
    n["message"] = %d.message
    diagsNode.add(n)
  result["diagnostics"] = diagsNode
  let ambNode = newJArray()
  for incident in ws.ambiguousImports:
    let n = newJObject()
    n["fromTarget"] = %incident.fromTarget
    n["importHead"] = %incident.importHead
    n["sourceFile"] = %incident.sourceFile
    n["lineNumber"] = %incident.lineNumber
    n["rawLine"] = %incident.rawLine
    let candsNode = newJArray()
    for c in incident.candidates:
      candsNode.add(%c)
    n["candidates"] = candsNode
    ambNode.add(n)
  result["ambiguousImports"] = ambNode

proc runShowConventionsCommand(args: openArray[string]): int =
  ## Implements ``repro show-conventions`` — step 3 of the Three-Mode
  ## Convention System sequencing plan
  ## (``reprobuild-specs/Three-Mode-Convention-System.md``
  ## §"Observability"). Prints the resolved convention stack for a
  ## project: detected targets, the convention claiming each, the
  ## scanner-inferred edges, and the manual ``depends_on`` overrides.
  ##
  ## Flags:
  ##   * ``--project=PATH`` — workspace root (default: cwd; or a
  ##     positional argument if present).
  ##   * ``--target=NAME``  — only print details for the named member /
  ##     package.
  ##   * ``--json``         — emit a JSON document instead of the
  ##     human-readable text shape.
  ##
  ## Honest scope:
  ##   * Per-target convention attribution uses the heuristic from
  ##     ``repro_core/convention_attribution.nim`` (option 1c — manifest
  ##     detection plus extension census). The standard-provider's
  ##     actual ``recognize`` remains the source of truth at build time;
  ##     this is a CLI-side approximation good enough for the 95% case
  ##     (``Cargo.toml`` → Rust, ``pyproject.toml`` → Python, ...). The
  ##     follow-on milestone replaces the heuristic with either a shared
  ##     introspection library (option 1b) or a query-mode IPC to the
  ##     standard-provider binary (option 1a).
  ##   * The ``Conventions registered`` list is a static mirror of
  ##     the standard-provider binary's registration order. A test
  ##     fails loudly if the two drift.
  ##   * No-match diagnostics surface every target-shaped directory
  ##     (``apps/<x>``, ``libs/<x>``, ``cmd/<x>``, ``tools/<x>``,
  ##     ``pkg/<x>``, plus the workspace root when no parent directory
  ##     contains target slots) the heuristic couldn't claim.
  ##   * Toolchain probes run ``<tool> --version`` (or ``go version``)
  ##     for every convention that appears as a per-target claim, at
  ##     most once per convention per process invocation.
  var projectArg = ""
  var jsonOut = false
  var targetFilter = ""
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--help" or arg == "-h":
      echo "usage: repro show-conventions [--project=PATH] " &
        "[--target=NAME] [--json] [PATH]"
      return 0
    elif arg == "--json":
      jsonOut = true
    elif arg == "--project":
      if i + 1 >= args.len:
        raise newException(ValueError, "--project requires a value")
      projectArg = args[i + 1]
      inc i
    elif arg.startsWith("--project="):
      projectArg = arg["--project=".len .. ^1]
    elif arg == "--target":
      if i + 1 >= args.len:
        raise newException(ValueError, "--target requires a value")
      targetFilter = args[i + 1]
      inc i
    elif arg.startsWith("--target="):
      targetFilter = arg["--target=".len .. ^1]
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported show-conventions flag: " & arg)
    elif projectArg.len == 0:
      projectArg = arg
    else:
      raise newException(ValueError,
        "unexpected show-conventions argument: " & arg)
    inc i

  let workspaceRoot =
    if projectArg.len == 0:
      getCurrentDir()
    else:
      absolutePath(projectArg)
  if not dirExists(workspaceRoot):
    raise newException(ValueError,
      "show-conventions: workspace root does not exist: " & workspaceRoot)

  let projectMatch = resolveProjectFile(workspaceRoot)

  # M48 — Mode 1 detection. When the workspace has NO project file
  # AND NO Mode 2 manifest, run the Mode 1 loader and render its
  # output with the ``[Mode 1 — inferred from layout]`` prefix so the
  # user sees the difference from Mode 3.
  if projectMatch.path.len == 0 and
      not hasMode2Manifest(workspaceRoot):
    let ws = loadMode1Workspace(workspaceRoot)
    if ws.targets.len > 0 or ws.ambiguousImports.len > 0:
      if jsonOut:
        let doc = renderMode1ShowConventionsJson(ws, targetFilter)
        echo doc.pretty()
      else:
        stdout.write(renderMode1ShowConventionsText(ws, targetFilter))
      if ws.ambiguousImports.len > 0:
        # Surface the hard-error diagnostic even in show-conventions
        # so users running ``repro show-conventions`` to debug see
        # the exit-non-zero signal that ``repro build`` would emit.
        return 1
      return 0

  # ``scanWorkspaceAll`` unions the Nim + C/C++ scanners so a mixed-
  # language workspace surfaces every member, not just the Nim ones.
  let scan = scanWorkspaceAll(workspaceRoot)
  # Collect manual ``depends_on`` edges from every project file the
  # scanner discovered (a workspace can hold several — apps/<name>/
  # repro.nim, libs/<name>/repro.nim, ...). We dedup by project-file
  # path so we don't double-emit when two members share a file.
  var manual: seq[ManualDepEdge] = @[]
  var seenProjectFiles: HashSet[string]
  for member in scan.members:
    if member.projectFile.len == 0:
      continue
    if member.projectFile in seenProjectFiles:
      continue
    seenProjectFiles.incl(member.projectFile)
    for edge in extractManualDependsOnFromProjectFile(member.projectFile):
      manual.add(edge)
  # Also consider the top-level project file in case there are no
  # members discovered (manual-only configuration).
  if projectMatch.path.len > 0 and
      projectMatch.path notin seenProjectFiles:
    for edge in extractManualDependsOnFromProjectFile(projectMatch.path):
      manual.add(edge)

  if jsonOut:
    let doc = renderShowConventionsJson(workspaceRoot, projectMatch,
      scan.members, scan.edges, manual, targetFilter)
    echo doc.pretty()
  else:
    stdout.write(renderShowConventionsText(workspaceRoot, projectMatch,
      scan.members, scan.edges, manual, targetFilter))
  0

proc runDepsCommand(args: openArray[string]): int =
  ## Dispatch ``repro deps <subcommand>``. Today the only subcommand is
  ## ``refresh``; the spec leaves room for ``deps show`` /
  ## ``deps explain`` as part of the ``repro show-conventions`` follow-on
  ## work (step 3 of the sequencing plan in
  ## ``Three-Mode-Convention-System.md`` §"Sequencing plan").
  if args.len == 0:
    stderr.writeLine("repro deps: missing subcommand (expected: refresh)")
    stderr.writeLine("usage: repro deps refresh [--check] [--dry-run] " &
      "[--project=PATH] [PATH]")
    return 2
  let sub = args[0]
  let rest =
    if args.len > 1:
      args[1 .. ^1]
    else:
      @[]
  case sub
  of "refresh":
    return runDepsRefreshCommand(rest)
  of "--help", "-h", "help":
    echo "usage: repro deps refresh [--check] [--dry-run] " &
      "[--project=PATH] [PATH]"
    return 0
  else:
    stderr.writeLine("repro deps: unknown subcommand: " & sub)
    return 2

# Named-Targets M5 forward declaration: the actual definition lives after
# ``prepareBuildGraphInspection`` (which the implementation calls) further
# down in this file.
proc runListTargetsCommand(target: string; mode: ToolProvisioningMode;
                           publicCliPath, workRoot: string;
                           asJson: bool; packageFilter: string;
                           bypassRunQuota: bool): int

proc runBuildCommand(args: openArray[string]; publicCliPath: string;
                     forceDirect = false;
                     daemonHosted = false;
                     eventSink: BuildCommandEventSink = nil;
                     cancelCheck: BuildCancelCallback = nil): int =
  let originalArgs = @args
  var target = ""
  var positionalSelectors: seq[string] = @[]
  var mode = tpmUnspecified
  var workRoot = ""
  var daemonMode = bdmAuto
  var daemonModeExplicit = false
  var progressMode = configuredBuildProgressMode()
  var progressBarStyle = configuredBuildProgressBarStyle()
  var statsMode = configuredBuildStatsMode()
  var reportMode = configuredBuildReportMode()
  var logMode = configuredBuildLogMode()
  var diagnosticsPath = ""
  var benchmarkPath = ""
  var statsCapture = StatsCaptureConfig()
  var prepareOnly = false
  var dryRun = false
  var forceRebuild = false
  var skipCmakeRegeneration = false
  var logModeExplicit = false
  var statsModeExplicit = false
  # Default: use runquota when reachable; --no-runquota forces full bypass.
  var bypassRunQuota = getEnv("REPROBUILD_NO_RUNQUOTA").normalize in
    ["1", "true", "yes", "on"]
  # Named-Targets M5: ``--list-targets`` enumerates every implicit /
  # explicit target name visible in the current project's target-export
  # table. ``--list-targets-json`` is the JSON view; ``--list-targets``
  # alone prints a text table. ``--package=NAME`` filters the output to
  # one owning package.
  var listTargets = false
  var listTargetsJson = false
  var listTargetsPackage = ""
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--daemon" or arg.startsWith("--daemon="):
      daemonMode = parseBuildDaemonMode(valueFromFlag(args, i, "--daemon"),
        "--daemon")
      daemonModeExplicit = true
    elif arg == "--list-targets":
      listTargets = true
    elif arg == "--list-targets-json":
      listTargets = true
      listTargetsJson = true
    elif arg == "--json" and listTargets:
      # ``repro build --list-targets --json`` is the spec-mandated
      # shape; accept ``--json`` as a follower of ``--list-targets``
      # without consuming the flag for any other build subcommand
      # surface. The ordering check above keeps the bare ``--json``
      # token unrecognised for non-list-targets invocations so the
      # legacy "unsupported build flag" error still fires.
      listTargetsJson = true
    elif arg == "--package" or arg.startsWith("--package="):
      listTargetsPackage = valueFromFlag(args, i, "--package")
    elif arg == "--tool-provisioning" or arg.startsWith("--tool-provisioning="):
      mode = parseToolProvisioning(valueFromFlag(args, i,
        "--tool-provisioning"))
    elif arg == "--work-root" or arg.startsWith("--work-root="):
      workRoot = valueFromFlag(args, i, "--work-root")
    elif arg == "--action-cache-root" or arg.startsWith("--action-cache-root="):
      # Phase 1 cache-scope split: user-level action cache + CAS root.
      # See Provider-Compile-Tiering.md §"Cache Scope". When omitted, we
      # resolve from ${REPROBUILD_STORE_ROOT}/action-cache or the platform
      # default user cache dir at engine config build time.
      setActionCacheRootOverride(valueFromFlag(args, i,
        "--action-cache-root"))
    elif arg == "--progress" or arg.startsWith("--progress="):
      progressMode = parseBuildProgressMode(valueFromFlag(args, i,
        "--progress"))
    elif arg == "--progress-bars" or arg.startsWith("--progress-bars="):
      progressBarStyle = parseBuildProgressBarStyle(valueFromFlag(args, i,
        "--progress-bars"))
    elif arg == "--diagnostics" or arg.startsWith("--diagnostics="):
      diagnosticsPath = valueFromFlag(args, i, "--diagnostics")
    elif arg == "--benchmark" or arg.startsWith("--benchmark="):
      benchmarkPath = valueFromFlag(args, i, "--benchmark")
    elif arg == "--stats-capture" or arg.startsWith("--stats-capture="):
      statsCapture = parseStatsCaptureGroups(valueFromFlag(args, i,
        "--stats-capture"))
    elif arg.startsWith("--stats="):
      statsMode = parseBuildStatsMode(arg.split("=", maxsplit = 1)[1])
      statsModeExplicit = true
    elif arg == "--stats":
      if i + 1 < args.len and args[i + 1] in ["text", "none"]:
        inc i
        statsMode = parseBuildStatsMode(args[i])
      else:
        statsMode = bsmText
      statsModeExplicit = true
    elif arg == "--report" or arg.startsWith("--report="):
      reportMode = parseBuildReportMode(valueFromFlag(args, i, "--report"))
    elif arg == "--log" or arg.startsWith("--log="):
      logMode = parseBuildLogMode(valueFromFlag(args, i, "--log"))
      logModeExplicit = true
    elif arg == "-v" or arg == "--verbose":
      logMode = blmSummary
      logModeExplicit = true
    elif arg == "-vv" or arg == "--very-verbose":
      logMode = blmActions
      logModeExplicit = true
    elif arg == "--prepare-only":
      prepareOnly = true
    elif arg == "--dry-run":
      dryRun = true
    elif arg in ["--force-rebuild", "--rebuild"]:
      forceRebuild = true
    elif arg == "--skip-cmake-regeneration":
      skipCmakeRegeneration = true
    elif arg == "--no-runquota":
      bypassRunQuota = true
    elif arg == "--runquota":
      bypassRunQuota = false
    elif arg == "--variant" or arg.startsWith("--variant="):
      # Spec-Implementation M1 — ``--variant name=value`` registers a
      # ``prSet`` contribution against the named solver-participating
      # Configurable before evaluation begins. The accumulated set is
      # exported as the ``REPRO_VARIANTS`` env var so it survives the
      # CLI -> provider process hop; both halves of the contract live
      # in ``repro_dsl_stdlib/configurables/variants.nim``.
      #
      # M1 explicitly defers solver integration to M2; here the flag
      # only feeds the priority lattice (``prDefault < prSet <
      # prOverride < prForce``) the existing ``Configurable`` system
      # already implements.
      let spec = valueFromFlag(args, i, "--variant")
      if spec.find('=') <= 0:
        raise newException(ValueError,
          "--variant expects name=value (got: " & spec & ")")
      var existing = getEnv("REPRO_VARIANTS")
      if existing.len > 0:
        existing.add(',')
      existing.add(spec)
      putEnv("REPRO_VARIANTS", existing)
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported build flag: " & arg)
    else:
      # Named-Targets M2: collect every positional. Classification into
      # path vs. name selectors happens below so the build dispatch can
      # fold name-shaped selectors into one engine pass.
      positionalSelectors.add(arg)
    inc i

  # ----------------------------------------------------------------
  # Named-Targets M2 positional resolution lives in the shared M3
  # ``parseAndResolveSelectors`` helper so ``runBuildCommand`` and
  # ``runWatchCommand`` cannot drift. The helper classifies every
  # selector via ``classifyBuildSelector``; the first path-shaped
  # selector (or the current directory when there's none) becomes the
  # engine's project anchor, and every name-shaped selector contributes
  # its closure to ``extraNameSelectors`` so the build runs in one
  # pass.
  # ----------------------------------------------------------------
  let resolved = parseAndResolveSelectors(positionalSelectors, "repro build")
  target = resolved.target
  var extraNameSelectors: seq[string] = resolved.extraNameSelectors
  let targetWasOmitted = resolved.targetWasOmitted
  if target.len == 0:
    target = "."

  # Named-Targets M5: ``--list-targets`` short-circuits the engine pass.
  # The flag's job is to list every implicit / explicit target name
  # visible in the project's aggregated target-export table so users can
  # discover what `repro build NAME` accepts. Implementation lives in
  # ``runListTargetsCommand`` (declared further down so it can call
  # ``prepareBuildGraphInspection``).
  if listTargets:
    return runListTargetsCommand(target, mode, publicCliPath, workRoot,
      listTargetsJson, listTargetsPackage, bypassRunQuota)

  if not daemonModeExplicit:
    daemonMode = configuredBuildDaemonMode()

  if progressMode == bpmQuiet:
    if not logModeExplicit:
      logMode = blmQuiet
    if not statsModeExplicit:
      statsMode = bsmNone

  # ----------------------------------------------------------------
  # M48 — Mode 1 (layout-as-manifest) fallback.
  # When the target points at a directory that has NO repro.nim /
  # reprobuild.nim AND NO Mode 2 ecosystem manifest, attempt to load
  # the workspace from layout. The loader synthesises a repro.nim +
  # repro.scanned-deps.nim under <workspaceRoot>/.repro/mode1-synth/
  # and we redirect the build target to that path. Per spec, NOTHING
  # is written to the workspace root itself — the synth dir is plain
  # build scratch.
  # ----------------------------------------------------------------
  let parts = splitTarget(target)
  if dirExists(extendedPath(parts.base)):
    let workspaceCandidate = absolutePath(parts.base)
    if not hasAnyProjectFile(workspaceCandidate) and
        not hasMode2Manifest(workspaceCandidate):
      var ws = loadMode1Workspace(workspaceCandidate)
      if ws.ambiguousImports.len > 0:
        stderr.writeLine(renderAmbiguousImportError(ws))
        return 2
      if ws.targets.len > 0:
        # Mixed-language Mode 1 surfaces a diagnostic with empty
        # target field; surface as a hard error.
        for d in ws.diagnostics:
          if d.target.len == 0 and
              d.message.contains("mixed-language workspace"):
            stderr.writeLine("repro build: error: " & d.message)
            return 2
        let synth = materializeMode1ProjectFile(ws)
        if synth.len > 0:
          # Redirect the target: preserve any ``#fragment`` selector
          # the user passed (``#default`` etc.).
          if parts.fragment.len > 0:
            target = synth & "#" & parts.fragment
          else:
            target = synth

  if statsCapture.enabled and (forceDirect or daemonMode == bdmOff) and
      not daemonHosted:
    raise newException(ValueError,
      "--stats-capture requires daemon-hosted build; direct-mode persistent " &
        "capture is not implemented")

  proc runDirectBuild(): int =
    if statsCapture.enabled and daemonHosted:
      let nowTime = getTime()
      let runId = "build-" & $getCurrentProcessId() & "-" &
        $nowTime.toUnix & "-" & $nowTime.nanosecond
      let projectRoot =
        try:
          projectRootForModule(absolutePath(parseBuildTarget(target).modulePath))
        except CatchableError:
          getCurrentDir()
      beginStatsCapture(runId, runId, projectRoot, "build", target,
        statsCapture)
      enqueueStatsObservation(scgSessions, "build-start", %*{
        "captureGroups": statsCapture.captureGroupsText,
        "daemonHosted": true
      })
    var autoRunQuota = startAutoRunQuotaIfNeeded(bypassRunQuota)
    try:
      result = executeBuildTarget(target, mode, publicCliPath,
        selectDefaultAction = targetWasOmitted,
        workRoot = workRoot,
        progressMode = progressMode,
        progressBarStyle = progressBarStyle,
        statsMode = statsMode,
        reportMode = reportMode,
        logMode = logMode,
        diagnosticsPath = diagnosticsPath,
        prepareOnly = prepareOnly,
        dryRun = dryRun,
        forceRebuild = forceRebuild,
        skipCmakeRegeneration = skipCmakeRegeneration,
        bypassRunQuotaExplicit = bypassRunQuota,
        benchmarkPath = benchmarkPath,
        eventSink = eventSink,
        cancelCheck = cancelCheck,
        extraNameSelectors = extraNameSelectors).exitCode
      if statsCapture.enabled and daemonHosted:
        enqueueStatsObservation(scgSessions, "build-finish", %*{
          "exitCode": result
        })
    finally:
      if autoRunQuota != nil:
        try:
          autoRunQuota.terminate()
          discard autoRunQuota.waitForExit()
          autoRunQuota.close()
        except CatchableError:
          discard

  proc buildRunId(): string =
    let nowTime = getTime()
    "build-" & $getCurrentProcessId() & "-" & $nowTime.toUnix & "-" &
      $nowTime.nanosecond

  proc requestProjectRoot(): string =
    try:
      projectRootForModule(absolutePath(parseBuildTarget(target).modulePath))
    except CatchableError:
      getCurrentDir()

  proc daemonBuildEnvironment(): seq[string] =
    # Delegates to the shared ``daemonCarriedEnvironment`` so that the build
    # and watch sessions agree on the env-forwarding contract, and so that
    # cargo/rustc actions launched by the daemon see Nix cc-wrapper variables
    # (NIX_LDFLAGS et al) from the user's nix-develop shell.
    daemonCarriedEnvironment()

  proc runDaemonBuild(): int =
    # Auto-spawn the daemon in dev (self-restart) mode. The daemon is a
    # persistent process that can outlive the `repro` that started it; when
    # `repro` is rebuilt to a new version, a frozen daemon keeps decoding
    # build-target payloads with its old engine and the build fails with
    # `unsupported build target payload version`. In dev mode the idle daemon
    # notices its on-disk image changed and self-restarts to the new build —
    # see `restartCandidateReady`, which only fires on a real hash change,
    # debounces, and defers while any session is active. `repro-daemon`
    # launched directly (no `--dev`) still defaults to the frozen regime.
    let config = defaultUserDaemonConfig(devMode = true)
    let projectRoot = requestProjectRoot()
    discard startUserDaemon(publicCliPath, config)
    # Honor --progress in daemon-hosted mode. The daemon forwards each
    # BuildProgressEvent as a tagged diagnostic; render it through the
    # client's own renderer so the requested mode (bar-line/etc.) is applied
    # instead of dumping the raw "progress: <kind> <id>" line.
    var clientProgress = newBuildProgressRenderer(progressMode,
      progressBarStyle)
    let request = UserDaemonBuildRequest(
      runId: buildRunId(),
      target: target,
      workingDir: getCurrentDir(),
      projectRoot: projectRoot,
      toolProvisioning: mode.modeName,
      workRoot: workRoot,
      publicCliPath: publicCliPath,
      rawArgs: originalArgs,
      environment: daemonBuildEnvironment(),
      attached: true,
      cancelOnDisconnect: true)
    let daemonResult = requestUserDaemonBuild(request, config.endpoint,
      proc(event: UserDaemonBuildEvent) =
        # Progress events carry the structured BuildProgressEvent in their
        # payload — render them through the client renderer and stop.
        if event.kind == bekDiagnostic and
            tryRenderDaemonProgress(clientProgress, event.payloadJson):
          return
        # Daemon-side error paths (e.g. the "refusing implicit PATH
        # fallback" ValueError when --tool-provisioning is omitted)
        # surface as a single bekFinished event with severity=error
        # whose message carries "daemon-hosted build failed: <inner>".
        # Without printing those, the CLI exits non-zero with no
        # diagnostic at all — and tests like
        # t_e2e_codetracer_build_subset_without_tup that gate on the
        # error text (`refusing implicit PATH fallback`) can't see it.
        let isError = event.kind in {bekFinished, bekCancelled,
            bekUnsupported} and event.severity == "error"
        if (event.kind == bekDiagnostic or isError) and
            event.message.len > 0:
          # Clear any in-progress bar line so the message lands cleanly.
          clientProgress.clearProgressLine()
          if isError or
              event.payloadJson.contains("\"stream\":\"stderr\""):
            stderr.write(event.message)
            if not event.message.endsWith("\n"):
              stderr.writeLine("")
          else:
            stdout.write(event.message)
            if not event.message.endsWith("\n"):
              stdout.writeLine(""))
    clientProgress.finishProgress()
    if not daemonResult.supported:
      raise newException(DaemonBuildUnsupported, daemonResult.message)
    updateBenchmarkDaemonConnection(benchmarkPath, daemonResult.connectionUs)
    daemonResult.exitCode

  if forceDirect or daemonMode == bdmOff:
    return runDirectBuild()
  try:
    return runDaemonBuild()
  except DaemonBuildUnsupported as err:
    if daemonMode == bdmRequire:
      raise newException(ValueError,
        "daemon mode required but repro-daemon cannot execute builds: " &
          err.msg)
    if statsCapture.enabled:
      raise newException(ValueError,
        "daemon-hosted stats capture requested but repro-daemon cannot " &
          "execute builds: " & err.msg)
    if logMode != blmQuiet:
      stderr.writeLine("repro build: daemon build unsupported; falling " &
        "back to direct mode: " & err.msg)
    if statsCapture.enabled:
      raise newException(ValueError,
        "daemon-hosted stats capture requested but repro-daemon is unavailable: " &
          err.msg)
    return runDirectBuild()
  except CatchableError as err:
    if daemonMode == bdmRequire:
      raise newException(ValueError,
        "daemon mode required but repro-daemon is unavailable: " & err.msg)
    if statsCapture.enabled:
      raise newException(ValueError,
        "daemon-hosted stats capture requested but repro-daemon is unavailable: " &
          err.msg)
    if logMode != blmQuiet:
      stderr.writeLine("repro build: daemon unavailable; falling back to " &
        "direct mode: " & err.msg)
    return runDirectBuild()

type
  GraphOutputFormat = enum
    gofText
    gofJson
    gofDot

  BuildGraphInspection = object
    target: string
    modulePath: string
    projectRoot: string
    outDir: string
    interfacePath: string
    toolProvisioning: ToolProvisioningMode
    toolIdentityPath: string
    toolInspectionPath: string
    providerBinaryPath: string
    providerCompileArtifactPath: string
    providerArtifactId: string
    providerGraphSnapshotPath: string
    providerInvocations: int
    providerCompileCacheHit: bool
    providerGraphCacheHit: bool
    loweredGraphCachePath: string
    loweredGraphCacheHit: bool
    selectedActionId: string
    defaultActionId: string
    actions: seq[BuildAction]
    pools: seq[BuildPool]
    targetExportTable: TargetExportTable
      ## Named-Targets M5: cross-fragment aggregate of every package's
      ## ``reprobuild.target-export-table.v1`` metadata node. Populated by
      ## ``prepareBuildGraphInspection`` and used by ``runGraphCommand``
      ## / ``runWhyCommand`` / ``--list-targets`` so the inspection
      ## surface honours implicit / explicit target names without a
      ## second pass over the snapshot.
    explicitTargetNames: seq[string]
      ## Named-Targets M5: every explicit ``target "name", handle`` label
      ## visible in the lowered graph, captured before lowering so
      ## ``resolveTargetExportSelector`` can pass it through.

proc parseGraphOutputFormat(value: string; allowDot: bool): GraphOutputFormat =
  case value.normalize()
  of "text":
    gofText
  of "json":
    gofJson
  of "dot":
    if allowDot:
      gofDot
    else:
      raise newException(ValueError, "unsupported format for this command: dot")
  else:
    raise newException(ValueError,
      "unsupported format: " & value &
        (if allowDot: " (expected text, json, or dot)"
        else: " (expected text or json)"))

proc buildActionById(actions: openArray[BuildAction]): Table[string, BuildAction] =
  for action in actions:
    result[action.id] = action

proc availableActionIds(actions: openArray[BuildAction]): seq[string] =
  for action in actions:
    result.add(action.id)
  result.sort()

proc requireAction(actions: openArray[BuildAction]; id: string): BuildAction =
  for action in actions:
    if action.id == id:
      return action
  let available = availableActionIds(actions)
  raise newException(ValueError,
    "unknown build action: " & id &
      (if available.len > 0:
        " (available: " & available.join(", ") & ")"
      else:
        " (graph contains no build actions)"))

proc directDependents(actions: openArray[BuildAction]; id: string): seq[string] =
  for action in actions:
    if action.deps.contains(id):
      result.add(action.id)
  result.sort()

proc directDependencies(actions: openArray[BuildAction]; id: string): seq[string] =
  let action = requireAction(actions, id)
  result = action.deps
  result.sort()

proc commandDisplay(action: BuildAction): string =
  if action.argv.len > 0:
    shellCommand(action.argv)
  else:
    case action.kind
    of bakCopyFile:
      "builtin copyFile"
    of bakEnsureDir:
      "builtin ensureDir"
    of bakWriteText:
      "builtin writeText"
    of bakStamp:
      "builtin stamp"
    of bakPreserveTree:
      "builtin preserveTree"
    else:
      "builtin action"

proc expectedDependencyFileJson(item: ExpectedDependencyFile): JsonNode =
  %*{
    "logicalName": item.logicalName,
    "path": item.path,
    "required": item.required
  }

proc expectedDependencyFilesJson(
    items: openArray[ExpectedDependencyFile]): JsonNode =
  result = newJArray()
  for item in items:
    result.add(expectedDependencyFileJson(item))

proc processSpecJson(process: ProcessSpec): JsonNode =
  var env = newJArray()
  for item in process.env:
    env.add(%*{"name": item.name, "value": item.value})
  %*{
    "kind": $process.kind,
    "executable": process.executable.value,
    "args": jsonStringSeq(process.args),
    "cwd": process.cwd.value,
    "env": env,
    "stdin": $process.stdinPolicy,
    "stdout": $process.stdoutPolicy,
    "stderr": $process.stderrPolicy
  }

proc dependencyPolicyJson(policy: DependencyGatheringPolicy): JsonNode =
  var reports = newJArray()
  for report in policy.recognizedReports:
    reports.add(%*{
      "formatName": $report.formatName,
      "outputs": expectedDependencyFilesJson(report.outputs),
      "completeness": $report.completeness
    })
  var converters = newJArray()
  for converterSpec in policy.postBuildConverters:
    converters.add(%*{
      "converterProcess": processSpecJson(converterSpec.converterProcess),
      "inputs": expectedDependencyFilesJson(converterSpec.inputs),
      "outputs": expectedDependencyFilesJson(converterSpec.outputs),
      "outputKind": $converterSpec.outputKind,
      "outputFormatName": $converterSpec.outputFormatName,
      "completeness": $converterSpec.completeness
    })
  %*{
    "kind": $policy.kind,
    "completeness": $policy.completeness,
    "recognizedReports": reports,
    "postBuildConverters": converters,
    "ignoredInputPrefixes": jsonStringSeq(policy.ignoredInputPrefixes)
  }

proc buildPoolJson(pool: BuildPool): JsonNode =
  %*{"name": pool.name, "capacity": pool.capacity}

proc buildPoolsJson(pools: openArray[BuildPool]): JsonNode =
  result = newJArray()
  for pool in pools:
    result.add(buildPoolJson(pool))

proc buildActionJson(action: BuildAction): JsonNode =
  %*{
    "id": action.id,
    "kind": $action.kind,
    "deps": jsonStringSeq(action.deps),
    "inputs": jsonStringSeq(action.inputs),
    "outputs": jsonStringSeq(action.outputs),
    "argv": jsonStringSeq(action.argv),
    "cwd": action.cwd,
    "env": jsonStringSeq(action.env),
    "pool": action.pool,
    "poolUnits": action.poolUnits,
    "cpuMilli": action.cpuMilli,
    "memoryBytes": $action.memoryBytes,
    "commandStatsId": action.commandStatsId,
    "cacheable": action.cacheable,
    "weakFingerprint": digestHex(action.weakFingerprint),
    "actionCachePolicy": $action.actionCachePolicy,
    "depfile": action.depfile,
    "dynamicDepsFile": action.dynamicDepsFile,
    "monitorDepfile": action.monitorDepfile,
    "dependencyPolicy": dependencyPolicyJson(action.dependencyPolicy),
    "builtinText": action.builtinText,
    "builtinEntries": jsonStringSeq(action.builtinEntries)
  }

proc buildActionsJson(actions: openArray[BuildAction]): JsonNode =
  result = newJArray()
  for action in actions:
    result.add(buildActionJson(action))

proc buildGraphInspectionJson(info: BuildGraphInspection): JsonNode =
  %*{
    "schemaId": "reprobuild.graph.build.v1",
    "target": info.target,
    "modulePath": info.modulePath,
    "projectRoot": info.projectRoot,
    "outDir": info.outDir,
    "interfacePath": info.interfacePath,
    "toolProvisioning": info.toolProvisioning.modeName,
    "toolIdentityPath": info.toolIdentityPath,
    "toolInspectionPath": info.toolInspectionPath,
    "providerBinaryPath": info.providerBinaryPath,
    "providerCompileArtifactPath": info.providerCompileArtifactPath,
    "providerArtifactId": info.providerArtifactId,
    "providerGraphSnapshotPath": info.providerGraphSnapshotPath,
    "providerInvocations": info.providerInvocations,
    "providerCompileCacheHit": info.providerCompileCacheHit,
    "providerGraphCacheHit": info.providerGraphCacheHit,
    "loweredGraphCachePath": info.loweredGraphCachePath,
    "loweredGraphCacheHit": info.loweredGraphCacheHit,
    "selectedActionId": info.selectedActionId,
    "defaultActionId": info.defaultActionId,
    "pools": buildPoolsJson(info.pools),
    "actions": buildActionsJson(info.actions)
  }

proc loweredGraphRecordJson(record: LoweredGraphCacheRecord): JsonNode =
  %*{
    "schemaId": "reprobuild.debug.lowered-graph-cache.v1",
    "modulePath": record.modulePath,
    "projectRoot": record.projectRoot,
    "selectedActionId": record.selectedActionId,
    "pathEnv": record.pathEnv,
    "cacheKey": record.cacheKey,
    "pools": buildPoolsJson(record.pools),
    "actions": buildActionsJson(record.actions)
  }

proc renderActionDetail(action: BuildAction): string =
  var lines: seq[string] = @[]
  lines.add("action " & action.id)
  lines.add("  kind: " & $action.kind)
  lines.add("  deps: " & (if action.deps.len > 0: action.deps.join(", ") else: "-"))
  lines.add("  inputs: " & $action.inputs.len)
  for item in action.inputs:
    lines.add("    input: " & item)
  lines.add("  outputs: " & $action.outputs.len)
  for item in action.outputs:
    lines.add("    output: " & item)
  lines.add("  cwd: " & action.cwd)
  lines.add("  command: " & commandDisplay(action))
  if action.env.len > 0:
    lines.add("  env:")
    for item in action.env:
      lines.add("    " & item)
  if action.pool.len > 0:
    lines.add("  pool: " & action.pool & " units=" & $action.poolUnits)
  lines.add("  cacheable: " & $action.cacheable)
  lines.add("  cachePolicy: " & $action.actionCachePolicy)
  lines.add("  dependencyPolicy: " & $action.dependencyPolicy.kind &
    " completeness=" & $action.dependencyPolicy.completeness)
  if action.depfile.len > 0:
    lines.add("  depfile: " & action.depfile)
  if action.dynamicDepsFile.len > 0:
    lines.add("  dynamicDepsFile: " & action.dynamicDepsFile)
  if action.monitorDepfile.len > 0:
    lines.add("  monitorDepfile: " & action.monitorDepfile)
  lines.join("\n")

proc renderBuildGraphText(info: BuildGraphInspection; focus = ""): string =
  var lines: seq[string] = @[]
  lines.add("build graph")
  lines.add("target: " & info.target)
  lines.add("projectRoot: " & info.projectRoot)
  lines.add("modulePath: " & info.modulePath)
  lines.add("outDir: " & info.outDir)
  lines.add("toolProvisioning: " & info.toolProvisioning.modeName)
  if info.selectedActionId.len > 0:
    lines.add("selectedAction: " & info.selectedActionId)
  elif info.defaultActionId.len > 0:
    lines.add("defaultAction: " & info.defaultActionId)
  lines.add("actions: " & $info.actions.len)
  lines.add("pools: " & $info.pools.len)
  lines.add("providerCompileCacheHit: " & $info.providerCompileCacheHit)
  lines.add("providerGraphCacheHit: " & $info.providerGraphCacheHit)
  lines.add("loweredGraphCacheHit: " & $info.loweredGraphCacheHit)
  if focus.len > 0:
    let action = requireAction(info.actions, focus)
    lines.add("")
    lines.add(renderActionDetail(action))
    let deps = directDependencies(info.actions, focus)
    let dependents = directDependents(info.actions, focus)
    lines.add("  directDependencies: " &
      (if deps.len > 0: deps.join(", ") else: "-"))
    lines.add("  directDependents: " &
      (if dependents.len > 0: dependents.join(", ") else: "-"))
    return lines.join("\n")
  for action in info.actions:
    lines.add("- " & action.id &
      " deps=[" & action.deps.join(", ") & "]" &
      " outputs=" & $action.outputs.len &
      " policy=" & $action.dependencyPolicy.kind &
      " command=" & commandDisplay(action))
  lines.join("\n")

proc dotQuote(value: string): string =
  "\"" & value.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc focusNodeSet(actions: openArray[BuildAction]; focus: string): HashSet[string] =
  result.incl(focus)
  let action = requireAction(actions, focus)
  for dep in action.deps:
    result.incl(dep)
  for dependent in directDependents(actions, focus):
    result.incl(dependent)

proc renderBuildGraphDot(info: BuildGraphInspection; focus = ""): string =
  var lines = @["digraph repro_build {"]
  let shown =
    if focus.len > 0:
      focusNodeSet(info.actions, focus)
    else:
      initHashSet[string]()
  for action in info.actions:
    if focus.len > 0 and not shown.contains(action.id):
      continue
    lines.add("  " & dotQuote(action.id) & " [label=" &
      dotQuote(action.id) & "];")
  for action in info.actions:
    if focus.len > 0 and not shown.contains(action.id):
      continue
    for dep in action.deps:
      if focus.len == 0 or shown.contains(dep):
        lines.add("  " & dotQuote(dep) & " -> " & dotQuote(action.id) & ";")
  lines.add("}")
  lines.join("\n")

proc prepareBuildGraphInspection(target: string; mode: ToolProvisioningMode;
                                 publicCliPath: string;
                                 selectDefaultAction = false;
                                 workRoot = "";
                                 forceRefresh = false): BuildGraphInspection =
  var parsedTarget = parseBuildTarget(target)
  parsedTarget.modulePath = absolutePath(parsedTarget.modulePath)
  let modulePath = parsedTarget.modulePath
  if not fileExists(extendedPath(modulePath)):
    raise newException(IOError, "build target module not found: " & modulePath)
  let outDir = outputDirForTarget(parsedTarget, workRoot)
  let projectRoot = projectRootForModule(modulePath)
  result.target = target
  result.modulePath = modulePath
  result.projectRoot = projectRoot
  result.outDir = outDir

  let interfacePath = outDir / "project-interface.rbsz"
  let stubPath = outDir / "project-interface.nim"
  let compileWorkDir = reprobuildLibraryWorkDir()
  let compileScratchDir = outDir / "provider-work"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath,
    compileWorkDir, compileScratchDir, requireStub = false)
  result.interfacePath = interfacePath

  var effectiveMode = mode
  if effectiveMode == tpmUnspecified and
      artifact.projectInterface.defaultToolProvisioning.len > 0:
    effectiveMode = parseToolProvisioning(
      artifact.projectInterface.defaultToolProvisioning)
  if artifact.projectInterface.toolUses.len > 0 and
      effectiveMode == tpmUnspecified:
    raise newException(ValueError,
      "typed tool provisioning is required for uses declarations; refusing " &
        "implicit PATH fallback. Pass --tool-provisioning=path to use the " &
        "explicit weak local profile.")
  result.toolProvisioning = effectiveMode

  var identity = PathOnlyBuildIdentity(
    projectName: artifact.projectInterface.projectName,
    interfaceFingerprint: artifact.interfaceFingerprint)
  if effectiveMode in {tpmPathOnly, tpmNix, tpmTarball, tpmScoop}:
    let resolved = warmResolveAndWriteIdentity(artifact, outDir, effectiveMode)
    identity = resolved.identity
    result.toolIdentityPath = resolved.identityPath
    result.toolInspectionPath = resolved.inspectionPath

  if not moduleHasBuildBlock(modulePath):
    return

  let providerBinaryPath = outDir / "provider" / "project-provider"
  let providerArtifactPath = outDir / "provider-compile.rbsz"
  result.providerBinaryPath = providerBinaryPath
  result.providerCompileArtifactPath = providerArtifactPath

  var provider: ProviderCompileArtifact
  let cachedProvider =
    if forceRefresh:
      none(ProviderCompileArtifact)
    else:
      readFreshProviderCompileArtifact(providerArtifactPath,
        modulePath, providerBinaryPath, artifact.interfaceFingerprint)
  if cachedProvider.isSome:
    provider = cachedProvider.get()
    result.providerCompileCacheHit = true
  else:
    let providerPlan = providerCompilePlan(modulePath, providerBinaryPath,
      artifact.interfaceFingerprint, compileWorkDir, compileScratchDir)
    invalidateStaleProviderCompileArtifact(providerPlan, providerArtifactPath)
    let providerCompileAction = providerCompileBuildAction(providerPlan,
      modulePath, interfacePath, providerArtifactPath, publicCliPath,
      compileWorkDir, compileScratchDir)
    var providerCompileConfig = BuildEngineConfig(
      cacheRoot: outDir / "build-engine-cache",
      actionCacheRoot: currentActionCacheRoot(),
      runQuotaCliPath: publicCliPath,
      maxParallelism: 1'u32,
      stdoutLimit: 1024 * 1024,
      stderrLimit: 1024 * 1024,
      rebuildMissingOutputsOnCacheHit: true,
      deferLocalOutputBlobs: true,
      bypassRunQuota: false,
      fallbackToRunQuotaBypass: effectiveMode in {tpmPathOnly, tpmScoop},
      inlineRunQuota: true,
      dryRun: false,
      forceRebuild: forceRefresh,
      suppressTrace: true,
      skipCacheHitEvidence: true)
    let providerCompileResult = runBuild(graph([providerCompileAction]),
      providerCompileConfig)
    if providerCompileResult.hasFailedActions():
      raise newException(OSError, providerCompileFailure(providerCompileResult))
    if not fileExists(extendedPath(providerArtifactPath)):
      raise newException(IOError,
        "provider compile edge did not write artifact: " & providerArtifactPath)
    provider = readProviderCompileArtifact(providerArtifactPath)
    if not providerCompileArtifactFresh(providerArtifactPath,
        providerPlan.outputBinaryPath, providerPlan.interfaceFingerprint,
        providerPlan.providerFingerprint):
      raise newException(IOError,
        "provider compile artifact is stale after edge execution: " &
          providerArtifactPath)

  result.providerArtifactId = digestHex(provider.providerFingerprint)
  result.providerBinaryPath = provider.outputBinaryPath

  let providerGraphStore = outDir / "provider-graph"
  var refresh: ProviderRefreshReport
  let freshSnapshot =
    if forceRefresh:
      none(ProviderGraphSnapshot)
    else:
      warmReadFreshProviderGraphSnapshot(providerGraphStore, result.providerArtifactId)
  if freshSnapshot.isSome:
    refresh.snapshot = freshSnapshot.get()
    refresh.persistedSnapshotPath = providerSnapshotPath(providerGraphStore)
    result.providerGraphCacheHit = true
  else:
    refresh = refreshProviderGraph(RefreshConfig(
      storeRoot: providerGraphStore,
      providerBinaryPath: provider.outputBinaryPath,
      providerArtifactId: result.providerArtifactId,
      rootEntryPointId: artifact.projectInterface.packageName & ".root",
      rootArguments: projectRoot,
      namespace: "project",
      lockSliceId: digestHex(artifact.interfaceFingerprint),
      activity: "build",
      providerWorkingDir: projectRoot))
  result.providerGraphSnapshotPath = refresh.persistedSnapshotPath
  result.providerInvocations = refresh.invoked.len
  result.defaultActionId = defaultBuildActionId(refresh.snapshot)

  var selectedActionId = parsedTarget.selectedActionId
  if selectDefaultAction and selectedActionId.len == 0:
    selectedActionId = result.defaultActionId
  result.selectedActionId = selectedActionId

  let pathEnv = getEnv("PATH")
  let graphCacheKey = loweredGraphCacheKey(artifact, effectiveMode,
    result.providerArtifactId, refresh.persistedSnapshotPath, pathEnv)
  let cachePath = loweredGraphCachePath(outDir, selectedActionId)
  result.loweredGraphCachePath = cachePath
  let cachedLowered =
    if forceRefresh:
      none(tuple[actions: seq[BuildAction]; pools: seq[BuildPool]])
    else:
      warmReadFreshLoweredGraphCache(cachePath, modulePath, projectRoot,
        selectedActionId, pathEnv, graphCacheKey)
  let lowered =
    if cachedLowered.isSome:
      result.loweredGraphCacheHit = true
      cachedLowered.get()
    else:
      let computed = lowerProviderSnapshot(refresh.snapshot, identity,
        projectRoot, selectedActionId)
      writeLoweredGraphCache(cachePath, modulePath, projectRoot,
        selectedActionId, pathEnv, graphCacheKey, computed)
      computed
  result.actions = lowered.actions
  result.pools = lowered.pools
  # Named-Targets M5: surface the project-scoped target-export table and
  # the explicit-target labels so ``runGraphCommand`` / ``runWhyCommand``
  # / ``--list-targets`` can route name-shaped selectors through the
  # shared ``resolveTargetExportSelector`` helper without a second pass
  # over the snapshot.
  result.targetExportTable = aggregateTargetExportTable(refresh.snapshot)
  for fragment in refresh.snapshot.fragments:
    for node in fragment.nodes:
      if node.kind == gnkMetadata and
          node.stableName == "reprobuild.build-target.v1":
        let target = decodeBuildTargetPayload(toBytes(node.payload))
        if result.explicitTargetNames.find(target.name) < 0:
          result.explicitTargetNames.add(target.name)

proc runListTargetsCommand(target: string; mode: ToolProvisioningMode;
                           publicCliPath, workRoot: string;
                           asJson: bool; packageFilter: string;
                           bypassRunQuota: bool): int =
  ## Named-Targets M5: enumerate every implicit / explicit target name
  ## carried by the project's aggregated target-export table. Entries
  ## are sorted by ``(package, name)`` for deterministic CLI output and
  ## JSON consumers. ``packageFilter`` (if non-empty) restricts the
  ## listing to one owning package.
  var effectiveMode = mode
  if effectiveMode == tpmUnspecified:
    effectiveMode = tpmPathOnly
  var autoRunQuota = startAutoRunQuotaIfNeeded(bypassRunQuota)
  try:
    let info = prepareBuildGraphInspection(target, effectiveMode,
      publicCliPath, selectDefaultAction = false, workRoot = workRoot)
    var entries: seq[TargetExportEntry] = @[]
    for entry in info.targetExportTable.entries:
      if packageFilter.len > 0 and entry.owningPackage != packageFilter:
        continue
      entries.add(entry)
    entries.sort(proc(a, b: TargetExportEntry): int =
      let pkgCmp = cmp(a.owningPackage, b.owningPackage)
      if pkgCmp != 0: pkgCmp else: cmp(a.name, b.name))
    # Spec-Implementation M5: ``--list-targets`` JSON / text formatter
    # extended with the new ``aggregate`` and ``collection`` row kinds
    # per Build-Graph-Collections.md §"Persistence and the Target-Export
    # Table" / §"--list-targets". The text formatter widens the ``kind``
    # column so the longer ``collection`` label aligns.
    proc kindToText(k: TargetExportKind): string =
      case k
      of tekImplicit: "implicit"
      of tekExplicit: "explicit"
      of tekAggregate: "aggregate"
      of tekCollection: "collection"
    if asJson:
      var arr = newJArray()
      for entry in entries:
        arr.add(%*{
          "name": entry.name,
          "kind": kindToText(entry.kind),
          "package": entry.owningPackage,
          "actionId": entry.actionId,
          "source-file": entry.sourceFile,
          "source-line": entry.sourceLine
        })
      var node = %*{
        "schemaId": "reprobuild.list-targets.v1",
        "projectRoot": info.projectRoot,
        "modulePath": info.modulePath,
        "targets": arr
      }
      if packageFilter.len > 0:
        node["package"] = %packageFilter
      echo $node
    else:
      if entries.len == 0:
        if packageFilter.len > 0:
          echo "repro build --list-targets: no targets for package=" &
            packageFilter
        else:
          echo "repro build --list-targets: no named targets in this project"
      else:
        echo "kind        package                   name                      source"
        for entry in entries:
          let source = entry.sourceFile & ":" & $entry.sourceLine
          echo kindToText(entry.kind) & "  " & entry.owningPackage & "  " &
            entry.name & "  " & source
    return 0
  finally:
    if autoRunQuota != nil:
      try:
        autoRunQuota.terminate()
        discard autoRunQuota.waitForExit()
        autoRunQuota.close()
      except CatchableError:
        discard

proc renderFocusedGraphJson(info: BuildGraphInspection; focus: string): JsonNode =
  let action = requireAction(info.actions, focus)
  %*{
    "schemaId": "reprobuild.graph.build.focus.v1",
    "graph": buildGraphInspectionJson(info),
    "focus": focus,
    "action": buildActionJson(action),
    "directDependencies": jsonStringSeq(directDependencies(info.actions, focus)),
    "directDependents": jsonStringSeq(directDependents(info.actions, focus))
  }

type
  StatsOutputFormat = enum
    sofText
    sofJson

  StatsActionRollup = object
    actionId: string
    target: string
    resultSamples: int
    cacheSamples: int
    cacheHits: int
    cacheMisses: int
    launched: int
    inputSamples: int
    maxInputCount: int
    maxOutputCount: int

  StatsTargetRollup = object
    target: string
    runIds: HashSet[string]
    observations: int
    actionSamples: int
    launched: int
    cacheSamples: int
    cacheHits: int
    cacheMisses: int
    buildTotalUs: float
    buildTotalSamples: int

  StatsWindow = object
    observationCount: int
    runIds: HashSet[string]
    firstMs: int64
    lastMs: int64

proc nowUnixMsCli(): int64 =
  let current = getTime()
  current.toUnix * 1000 + int64(current.nanosecond div 1_000_000)

proc parseStatsOutputFormat(value: string): StatsOutputFormat =
  case value.normalize()
  of "text":
    sofText
  of "json":
    sofJson
  else:
    raise newException(ValueError,
      "unsupported stats format: " & value & " (expected text or json)")

proc safeSnapshotLabel(label: string): string =
  if label.len == 0:
    raise newException(ValueError, "--label requires a non-empty value")
  for ch in label:
    if not (ch.isAlphaNumeric or ch in {'-', '_', '.'}):
      raise newException(ValueError,
        "unsupported snapshot label: " & label &
          " (use letters, digits, '.', '-', or '_')")
  if label == "." or label == ".." or label.contains(".."):
    raise newException(ValueError, "unsupported snapshot label: " & label)
  label

proc statsSnapshotPath(projectRoot, label: string): string =
  defaultStatsSnapshotDir(projectRoot) / (safeSnapshotLabel(label) & ".json")

proc statsWindow(nodes: openArray[JsonNode]): StatsWindow =
  result.firstMs = int64.high
  for node in nodes:
    inc result.observationCount
    let runId = node{"runId"}.getStr()
    if runId.len > 0:
      result.runIds.incl(runId)
    let occurred = node{"occurredAtUnixMs"}.getBiggestInt(0)
    if occurred > 0:
      result.firstMs = min(result.firstMs, occurred)
      result.lastMs = max(result.lastMs, occurred)
  if result.firstMs == int64.high:
    result.firstMs = 0

proc statsWindowJson(window: StatsWindow): JsonNode =
  %*{
    "observationCount": window.observationCount,
    "runCount": window.runIds.len,
    "firstObservationUnixMs": window.firstMs,
    "lastObservationUnixMs": window.lastMs
  }

proc cacheDecisionKind(value: string): string =
  let v = value.normalize()
  if v.contains("hit"):
    "hit"
  elif v.contains("miss"):
    "miss"
  elif v.contains("reject"):
    "rejected"
  elif v.contains("notcache"):
    "not-cacheable"
  else:
    "other"

proc actionRollups(nodes: openArray[JsonNode]): Table[string, StatsActionRollup] =
  for node in nodes:
    let fields = node{"fields"}
    let actionId = fields{"actionId"}.getStr()
    if actionId.len == 0:
      continue
    var item = result.getOrDefault(actionId)
    item.actionId = actionId
    if item.target.len == 0:
      item.target = node{"target"}.getStr()
    case node{"kind"}.getStr()
    of "action-result":
      inc item.resultSamples
      if fields{"launched"}.getBool(false):
        inc item.launched
    of "cache-decision":
      inc item.cacheSamples
      case cacheDecisionKind(fields{"cacheDecision"}.getStr())
      of "hit":
        inc item.cacheHits
      of "miss":
        inc item.cacheMisses
      else:
        discard
    of "dependency-evidence":
      inc item.inputSamples
      let inputCount =
        fields{"declaredInputs"}.getInt(0) +
        fields{"depfileInputs"}.getInt(0) +
        fields{"monitorReads"}.getInt(0) +
        fields{"monitorProbes"}.getInt(0)
      item.maxInputCount = max(item.maxInputCount, inputCount)
      item.maxOutputCount = max(item.maxOutputCount,
        fields{"declaredOutputs"}.getInt(0) +
        fields{"monitorWrites"}.getInt(0))
    else:
      discard
    result[actionId] = item

proc targetRollups(nodes: openArray[JsonNode]): Table[string, StatsTargetRollup] =
  for node in nodes:
    let target = node{"target"}.getStr("default")
    var item = result.getOrDefault(target)
    item.target = target
    inc item.observations
    let runId = node{"runId"}.getStr()
    if runId.len > 0:
      item.runIds.incl(runId)
    let fields = node{"fields"}
    case node{"kind"}.getStr()
    of "action-result":
      inc item.actionSamples
      if fields{"launched"}.getBool(false):
        inc item.launched
    of "cache-decision":
      inc item.cacheSamples
      case cacheDecisionKind(fields{"cacheDecision"}.getStr())
      of "hit":
        inc item.cacheHits
      of "miss":
        inc item.cacheMisses
      else:
        discard
    of "metric":
      if fields{"name"}.getStr() == "repro build total":
        item.buildTotalUs += fields{"totalUs"}.getFloat(0.0)
        inc item.buildTotalSamples
    else:
      discard
    result[target] = item

proc graphActionMap(info: BuildGraphInspection): Table[string, BuildAction] =
  for action in info.actions:
    result[action.id] = action

proc graphMetadataJson(info: BuildGraphInspection): JsonNode =
  %*{
    "target": info.target,
    "projectRoot": info.projectRoot,
    "modulePath": info.modulePath,
    "outDir": info.outDir,
    "providerCompileCacheHit": info.providerCompileCacheHit,
    "providerGraphCacheHit": info.providerGraphCacheHit,
    "loweredGraphCacheHit": info.loweredGraphCacheHit,
    "loweredGraphCachePath": info.loweredGraphCachePath
  }

proc unavailableStatsJson(command, scope, metric, projectRoot, storePath,
                          reason: string; window: StatsWindow): JsonNode =
  %*{
    "schemaId": "reprobuild.stats.rank.v1",
    "command": command,
    "scope": scope,
    "metric": metric,
    "projectRoot": projectRoot,
    "storePath": storePath,
    "window": statsWindowJson(window),
    "sampleCount": 0,
    "availability": {"available": false, "reason": reason},
    "rows": newJArray()
  }

proc outputSizeForAction(projectRoot: string; action: BuildAction): BiggestInt =
  for output in action.outputs:
    let path = materialProjectPath(projectRoot, output)
    if fileExists(extendedPath(path)):
      result += getFileSize(extendedPath(path))

proc actionRankJson(projectRoot, storePath, metric: string; top: int;
                    nodes: openArray[JsonNode];
                    graphInfo: Option[BuildGraphInspection]): JsonNode =
  let window = statsWindow(nodes)
  let rollups = actionRollups(nodes)
  let graphById =
    if graphInfo.isSome: graphActionMap(graphInfo.get())
    else: initTable[string, BuildAction]()
  let unavailable = {
    "build-time": "M7 records run-level timing but not per-action durations",
    "critical-path": "critical-path contribution needs per-action dynamic timings",
    "duration-variance": "duration variance needs multiple per-action duration samples",
    "peak-memory": "peak memory is not captured by the M7 stats store",
    "queue-time": "queue time is not captured by the M7 stats store"
  }.toTable
  if unavailable.hasKey(metric):
    return unavailableStatsJson("stats rank", "actions", metric, projectRoot,
      storePath, unavailable[metric], window)

  var rows = newJArray()
  type Row = tuple[id: string; value: float; samples: int; evidence: JsonNode]
  var raw: seq[Row] = @[]
  case metric
  of "cache-hit-ratio":
    for id, item in rollups:
      if item.cacheSamples > 0:
        raw.add((id, float(item.cacheHits) / float(item.cacheSamples),
          item.cacheSamples, %*{
            "cacheHits": item.cacheHits,
            "cacheMisses": item.cacheMisses,
            "cacheSamples": item.cacheSamples
          }))
    raw.sort(proc(a, b: Row): int = cmp(a.value, b.value))
  of "cache-miss-count":
    for id, item in rollups:
      raw.add((id, float(item.cacheMisses), item.cacheSamples, %*{
        "cacheMisses": item.cacheMisses,
        "cacheSamples": item.cacheSamples
      }))
    raw.sort(proc(a, b: Row): int = cmp(b.value, a.value))
  of "input-count":
    for id, item in rollups:
      raw.add((id, float(item.maxInputCount), item.inputSamples, %*{
        "maxInputCount": item.maxInputCount,
        "inputSamples": item.inputSamples
      }))
    raw.sort(proc(a, b: Row): int = cmp(b.value, a.value))
  of "output-size":
    if graphInfo.isNone:
      return unavailableStatsJson("stats rank", "actions", metric, projectRoot,
        storePath, "output-size needs a materialized build graph", window)
    for id, action in graphById:
      raw.add((id, float(outputSizeForAction(projectRoot, action)), 1, %*{
        "outputs": jsonStringSeq(action.outputs)
      }))
    raw.sort(proc(a, b: Row): int = cmp(b.value, a.value))
  else:
    raise newException(ValueError,
      "unsupported actions metric: " & metric)

  let limit = if top <= 0: raw.len else: min(top, raw.len)
  for index in 0 ..< limit:
    let row = raw[index]
    var node = %*{
      "rank": index + 1,
      "id": row.id,
      "actionId": row.id,
      "value": row.value,
      "sampleCount": row.samples,
      "evidence": row.evidence,
      "nextCommand": "repro stats show --scope=actions --id " & row.id
    }
    if graphById.hasKey(row.id):
      node["commandStatsId"] = %graphById[row.id].commandStatsId
      node["graphCommand"] = %("repro graph --view=neighborhood --focus " & row.id)
    rows.add(node)
  result = %*{
    "schemaId": "reprobuild.stats.rank.v1",
    "command": "stats rank",
    "scope": "actions",
    "metric": metric,
    "projectRoot": projectRoot,
    "storePath": storePath,
    "window": statsWindowJson(window),
    "sampleCount": rows.len,
    "availability": {"available": rows.len > 0, "reason": ""},
    "rows": rows
  }
  if graphInfo.isSome:
    result["graph"] = graphMetadataJson(graphInfo.get())
  if rows.len == 0:
    result["availability"]["reason"] = %"no matching action observations"

proc inputDependents(info: BuildGraphInspection; path: string): HashSet[string]
proc downstreamClosure(info: BuildGraphInspection; roots: HashSet[string]): HashSet[string]

proc inputRankJson(projectRoot, storePath, metric: string; top: int;
                   nodes: openArray[JsonNode];
                   graphInfo: Option[BuildGraphInspection]): JsonNode =
  let window = statsWindow(nodes)
  if metric in ["change-frequency", "critical-path-impact"]:
    return unavailableStatsJson("stats rank", "inputs", metric, projectRoot,
      storePath,
      if metric == "change-frequency":
        "M7 records dependency evidence counts but not changed input paths"
      else:
        "critical-path impact needs per-action dynamic timings and input paths",
      window)
  if graphInfo.isNone:
    return unavailableStatsJson("stats rank", "inputs", metric, projectRoot,
      storePath, "input ranking needs a materialized build graph", window)
  if metric notin ["blast-radius", "fanout"]:
    raise newException(ValueError, "unsupported inputs metric: " & metric)

  let info = graphInfo.get()
  var paths = initHashSet[string]()
  for action in info.actions:
    for input in action.inputs:
      if input.len > 0:
        paths.incl(input)
  type Row = tuple[path: string; value: int; direct: int]
  var raw: seq[Row] = @[]
  for path in paths:
    let direct = inputDependents(info, path)
    let closure = downstreamClosure(info, direct)
    raw.add((path, if metric == "fanout": direct.len else: closure.len,
      direct.len))
  raw.sort(proc(a, b: Row): int =
    let byValue = cmp(b.value, a.value)
    if byValue != 0: byValue else: cmp(a.path, b.path))
  let limit = if top <= 0: raw.len else: min(top, raw.len)
  var rows = newJArray()
  for index in 0 ..< limit:
    let row = raw[index]
    rows.add(%*{
      "rank": index + 1,
      "path": row.path,
      "value": row.value,
      "sampleCount": 1,
      "evidence": {
        "directDependents": row.direct,
        "source": "build-graph-structure"
      },
      "graphCommand": "repro graph --view=blast-radius --path " & row.path
    })
  %*{
    "schemaId": "reprobuild.stats.rank.v1",
    "command": "stats rank",
    "scope": "inputs",
    "metric": metric,
    "projectRoot": projectRoot,
    "storePath": storePath,
    "window": statsWindowJson(window),
    "sampleCount": rows.len,
    "availability": {
      "available": rows.len > 0,
      "reason": if rows.len == 0: "graph contains no declared inputs" else: ""
    },
    "graph": graphMetadataJson(info),
    "rows": rows
  }

proc targetRankJson(projectRoot, storePath, metric: string; top: int;
                    nodes: openArray[JsonNode]): JsonNode =
  let window = statsWindow(nodes)
  if metric == "critical-path":
    return unavailableStatsJson("stats rank", "targets", metric, projectRoot,
      storePath, "critical path needs per-action dynamic timings", window)
  let rollups = targetRollups(nodes)
  type Row = tuple[target: string; value: float; samples: int; evidence: JsonNode]
  var raw: seq[Row] = @[]
  case metric
  of "build-time":
    for target, item in rollups:
      if item.buildTotalSamples > 0:
        raw.add((target, item.buildTotalUs / float(item.buildTotalSamples),
          item.buildTotalSamples, %*{
            "buildTotalUs": item.buildTotalUs,
            "buildTotalSamples": item.buildTotalSamples
          }))
    raw.sort(proc(a, b: Row): int = cmp(b.value, a.value))
  of "cache-hit-ratio":
    for target, item in rollups:
      if item.cacheSamples > 0:
        raw.add((target, float(item.cacheHits) / float(item.cacheSamples),
          item.cacheSamples, %*{
            "cacheHits": item.cacheHits,
            "cacheMisses": item.cacheMisses,
            "cacheSamples": item.cacheSamples
          }))
    raw.sort(proc(a, b: Row): int = cmp(a.value, b.value))
  of "rebuild-count":
    for target, item in rollups:
      raw.add((target, float(item.launched), item.actionSamples, %*{
        "launchedActions": item.launched,
        "actionSamples": item.actionSamples
      }))
    raw.sort(proc(a, b: Row): int = cmp(b.value, a.value))
  else:
    raise newException(ValueError, "unsupported targets metric: " & metric)
  let limit = if top <= 0: raw.len else: min(top, raw.len)
  var rows = newJArray()
  for index in 0 ..< limit:
    let row = raw[index]
    rows.add(%*{
      "rank": index + 1,
      "target": row.target,
      "value": row.value,
      "sampleCount": row.samples,
      "evidence": row.evidence
    })
  %*{
    "schemaId": "reprobuild.stats.rank.v1",
    "command": "stats rank",
    "scope": "targets",
    "metric": metric,
    "projectRoot": projectRoot,
    "storePath": storePath,
    "window": statsWindowJson(window),
    "sampleCount": rows.len,
    "availability": {
      "available": rows.len > 0,
      "reason": if rows.len == 0: "no target observations for metric" else: ""
    },
    "rows": rows
  }

proc toolRankJson(projectRoot, storePath, metric: string; top: int;
                  nodes: openArray[JsonNode];
                  graphInfo: Option[BuildGraphInspection]): JsonNode =
  let window = statsWindow(nodes)
  if metric in ["build-time", "queue-time", "duration-variance", "peak-memory"]:
    return unavailableStatsJson("stats rank", "tools", metric, projectRoot,
      storePath, "M7 does not capture per-action resource/timing by tool", window)
  if metric != "cache-hit-ratio":
    raise newException(ValueError, "unsupported tools metric: " & metric)
  if graphInfo.isNone:
    return unavailableStatsJson("stats rank", "tools", metric, projectRoot,
      storePath, "tool ranking needs a materialized build graph", window)
  let actions = actionRollups(nodes)
  let graphById = graphActionMap(graphInfo.get())
  type Tool = object
    id: string
    samples: int
    hits: int
    misses: int
    actions: HashSet[string]
  var tools = initTable[string, Tool]()
  for actionId, rollup in actions:
    if not graphById.hasKey(actionId) or rollup.cacheSamples == 0:
      continue
    var toolId = graphById[actionId].commandStatsId
    if toolId.len == 0:
      toolId = "unknown-command-shape"
    var item = tools.getOrDefault(toolId)
    item.id = toolId
    item.samples += rollup.cacheSamples
    item.hits += rollup.cacheHits
    item.misses += rollup.cacheMisses
    item.actions.incl(actionId)
    tools[toolId] = item
  type Row = tuple[id: string; value: float; item: Tool]
  var raw: seq[Row] = @[]
  for id, item in tools:
    if item.samples > 0:
      raw.add((id, float(item.hits) / float(item.samples), item))
  raw.sort(proc(a, b: Row): int = cmp(a.value, b.value))
  let limit = if top <= 0: raw.len else: min(top, raw.len)
  var rows = newJArray()
  for index in 0 ..< limit:
    let row = raw[index]
    var actionIds: seq[string] = @[]
    for actionId in row.item.actions:
      actionIds.add(actionId)
    actionIds.sort()
    rows.add(%*{
      "rank": index + 1,
      "toolId": row.id,
      "value": row.value,
      "sampleCount": row.item.samples,
      "evidence": {
        "cacheHits": row.item.hits,
        "cacheMisses": row.item.misses,
        "actions": jsonStringSeq(actionIds)
      }
    })
  %*{
    "schemaId": "reprobuild.stats.rank.v1",
    "command": "stats rank",
    "scope": "tools",
    "metric": metric,
    "projectRoot": projectRoot,
    "storePath": storePath,
    "window": statsWindowJson(window),
    "sampleCount": rows.len,
    "availability": {
      "available": rows.len > 0,
      "reason": if rows.len == 0: "no tool/cache observations" else: ""
    },
    "graph": graphMetadataJson(graphInfo.get()),
    "rows": rows
  }

proc renderStatsRankText(node: JsonNode): string =
  var lines: seq[string] = @[]
  let scope = node{"scope"}.getStr()
  let metric = node{"metric"}.getStr()
  let window = node{"window"}
  lines.add("Stats rank: scope=" & scope & " by=" & metric &
    " runs=" & $window{"runCount"}.getInt(0) &
    " observations=" & $window{"observationCount"}.getInt(0))
  if not node{"availability"}{"available"}.getBool(false):
    lines.add("unavailable: " & node{"availability"}{"reason"}.getStr())
    return lines.join("\n") & "\n"
  for row in node{"rows"}:
    let name =
      if row.hasKey("actionId"): row{"actionId"}.getStr()
      elif row.hasKey("path"): row{"path"}.getStr()
      elif row.hasKey("target"): row{"target"}.getStr()
      elif row.hasKey("toolId"): row{"toolId"}.getStr()
      else: row{"id"}.getStr()
    lines.add(align($row{"rank"}.getInt(), 2) & "  " & name &
      "  value=" & formatFloat(row{"value"}.getFloat(), ffDecimal, 3) &
      "  samples=" & $row{"sampleCount"}.getInt(0))
  if node{"rows"}.len > 0:
    let first = node{"rows"}[0]
    if first.hasKey("graphCommand"):
      lines.add("next: " & first{"graphCommand"}.getStr())
    elif first.hasKey("nextCommand"):
      lines.add("next: " & first{"nextCommand"}.getStr())
  lines.join("\n") & "\n"

proc showActionStatsJson(projectRoot, storePath, actionId: string;
                         nodes: openArray[JsonNode];
                         graphInfo: Option[BuildGraphInspection]): JsonNode =
  let window = statsWindow(nodes)
  let rollups = actionRollups(nodes)
  if not rollups.hasKey(actionId):
    raise newException(ValueError, "unknown action in stats store: " & actionId)
  let item = rollups[actionId]
  var recent = newJArray()
  for node in nodes:
    if node{"fields"}{"actionId"}.getStr() == actionId:
      recent.add(node)
  result = %*{
    "schemaId": "reprobuild.stats.show.v1",
    "command": "stats show",
    "scope": "actions",
    "projectRoot": projectRoot,
    "storePath": storePath,
    "window": statsWindowJson(window),
    "id": actionId,
    "actionId": actionId,
    "rollup": {
      "resultSamples": item.resultSamples,
      "cacheSamples": item.cacheSamples,
      "cacheHits": item.cacheHits,
      "cacheMisses": item.cacheMisses,
      "launched": item.launched,
      "maxInputCount": item.maxInputCount,
      "maxOutputCount": item.maxOutputCount,
      "cacheHitRatio": if item.cacheSamples > 0:
        float(item.cacheHits) / float(item.cacheSamples) else: 0.0
    },
    "recentObservations": recent,
    "unavailableMetrics": jsonStringSeq([
      "per-action build-time",
      "critical-path contribution",
      "duration variance",
      "peak memory",
      "queue time"
    ]),
    "graphCommand": "repro graph --view=neighborhood --focus " & actionId
  }
  if graphInfo.isSome:
    let byId = graphActionMap(graphInfo.get())
    if byId.hasKey(actionId):
      result["graph"] = graphMetadataJson(graphInfo.get())
      result["action"] = buildActionJson(byId[actionId])

proc renderStatsShowText(node: JsonNode): string =
  var lines: seq[string] = @[]
  if node{"scope"}.getStr() == "actions":
    let rollup = node{"rollup"}
    lines.add("Stats action: " & node{"actionId"}.getStr())
    lines.add("samples: results=" & $rollup{"resultSamples"}.getInt(0) &
      " cache=" & $rollup{"cacheSamples"}.getInt(0) &
      " launched=" & $rollup{"launched"}.getInt(0))
    lines.add("cache: hits=" & $rollup{"cacheHits"}.getInt(0) &
      " misses=" & $rollup{"cacheMisses"}.getInt(0) &
      " ratio=" & formatFloat(rollup{"cacheHitRatio"}.getFloat(0.0),
        ffDecimal, 3))
    lines.add("dependency counts: inputs=" & $rollup{"maxInputCount"}.getInt(0) &
      " outputs=" & $rollup{"maxOutputCount"}.getInt(0))
    lines.add("next: " & node{"graphCommand"}.getStr())
  else:
    lines.add("Stats input: " & node{"path"}.getStr())
    lines.add("directDependents: " &
      $node{"rollup"}{"directDependents"}.getInt(0) &
      " blastRadius: " & $node{"rollup"}{"blastRadius"}.getInt(0))
    lines.add("observed change frequency: unavailable (M7 does not record changed input paths)")
    lines.add("next: " & node{"graphCommand"}.getStr())
  lines.join("\n") & "\n"

proc actionIdsJson(values: HashSet[string]): JsonNode =
  var ids: seq[string] = @[]
  for value in values:
    ids.add(value)
  ids.sort()
  jsonStringSeq(ids)

proc showInputStatsJson(projectRoot, storePath, path: string;
                        nodes: openArray[JsonNode];
                        graphInfo: Option[BuildGraphInspection]): JsonNode =
  let window = statsWindow(nodes)
  if graphInfo.isNone:
    return %*{
      "schemaId": "reprobuild.stats.show.v1",
      "command": "stats show",
      "scope": "inputs",
      "projectRoot": projectRoot,
      "storePath": storePath,
      "window": statsWindowJson(window),
      "path": path,
      "availability": {
        "available": false,
        "reason": "input show needs a materialized build graph"
      }
    }
  let direct = inputDependents(graphInfo.get(), path)
  let closure = downstreamClosure(graphInfo.get(), direct)
  %*{
    "schemaId": "reprobuild.stats.show.v1",
    "command": "stats show",
    "scope": "inputs",
    "projectRoot": projectRoot,
    "storePath": storePath,
    "window": statsWindowJson(window),
    "path": path,
    "availability": {"available": true, "reason": ""},
    "rollup": {
      "directDependents": direct.len,
      "blastRadius": closure.len,
      "observedChangeFrequency": newJNull(),
      "observedCriticalPathImpact": newJNull()
    },
    "directDependentActionIds": actionIdsJson(direct),
    "blastRadiusActionIds": actionIdsJson(closure),
    "graph": graphMetadataJson(graphInfo.get()),
    "graphCommand": "repro graph --view=blast-radius --path " & path
  }

proc snapshotJson(projectRoot, storePath, label: string;
                  nodes: openArray[JsonNode];
                  graphInfo: Option[BuildGraphInspection]): JsonNode =
  let window = statsWindow(nodes)
  let actions = actionRankJson(projectRoot, storePath, "cache-miss-count", 0,
    nodes, graphInfo)
  let targets = targetRankJson(projectRoot, storePath, "build-time", 0, nodes)
  result = %*{
    "schemaId": "reprobuild.stats.snapshot.v1",
    "label": label,
    "createdAtUnixMs": nowUnixMsCli(),
    "projectRoot": projectRoot,
    "storePath": storePath,
    "window": statsWindowJson(window),
    "rollups": {
      "actionsByCacheMissCount": actions{"rows"},
      "targetsByBuildTime": targets{"rows"}
    },
    "unavailableMetrics": jsonStringSeq([
      "per-action build-time",
      "critical-path",
      "duration-variance",
      "peak-memory",
      "queue-time",
      "input change-frequency",
      "input critical-path-impact"
    ])
  }
  if graphInfo.isSome:
    result["graph"] = graphMetadataJson(graphInfo.get())

proc renderSnapshotText(node: JsonNode; path: string): string =
  "stats snapshot: " & node{"label"}.getStr() &
    " observations=" & $node{"window"}{"observationCount"}.getInt(0) &
    " runs=" & $node{"window"}{"runCount"}.getInt(0) &
    "\npath: " & path & "\n"

proc rollupDeltaRows(baseRows, candRows: JsonNode; keyField: string): JsonNode =
  var baseByKey = initTable[string, JsonNode]()
  var candByKey = initTable[string, JsonNode]()
  var keys: seq[string] = @[]
  proc remember(key: string) =
    if key.len > 0 and keys.find(key) < 0:
      keys.add(key)
  if baseRows.kind == JArray:
    for row in baseRows:
      let key = row{keyField}.getStr()
      if key.len > 0:
        baseByKey[key] = row
        remember(key)
  if candRows.kind == JArray:
    for row in candRows:
      let key = row{keyField}.getStr()
      if key.len > 0:
        candByKey[key] = row
        remember(key)
  keys.sort()
  result = newJArray()
  for key in keys:
    let hasBase = baseByKey.hasKey(key)
    let hasCand = candByKey.hasKey(key)
    let baseValue = if hasBase: baseByKey[key]{"value"}.getFloat(0.0) else: 0.0
    let candValue = if hasCand: candByKey[key]{"value"}.getFloat(0.0) else: 0.0
    let baseSamples =
      if hasBase: baseByKey[key]{"sampleCount"}.getInt(0) else: 0
    let candSamples =
      if hasCand: candByKey[key]{"sampleCount"}.getInt(0) else: 0
    var row = newJObject()
    row[keyField] = %key
    row["baselineValue"] = if hasBase: %baseValue else: newJNull()
    row["candidateValue"] = if hasCand: %candValue else: newJNull()
    row["deltaValue"] = if hasBase and hasCand: %(candValue - baseValue) else: newJNull()
    row["baselineSampleCount"] = %baseSamples
    row["candidateSampleCount"] = %candSamples
    row["deltaSampleCount"] = %(candSamples - baseSamples)
    result.add(row)

proc compareSnapshotsJson(projectRoot, baseline, candidate: string): JsonNode =
  let baselinePath = statsSnapshotPath(projectRoot, baseline)
  let candidatePath = statsSnapshotPath(projectRoot, candidate)
  if not fileExists(baselinePath):
    raise newException(IOError, "stats snapshot not found: " & baseline)
  if not fileExists(candidatePath):
    raise newException(IOError, "stats snapshot not found: " & candidate)
  let base = parseFile(baselinePath)
  let cand = parseFile(candidatePath)
  %*{
    "schemaId": "reprobuild.stats.compare.v1",
    "command": "stats compare",
    "projectRoot": projectRoot,
    "baseline": {
      "label": baseline,
      "path": baselinePath,
      "window": base{"window"}
    },
    "candidate": {
      "label": candidate,
      "path": candidatePath,
      "window": cand{"window"}
    },
    "deltas": {
      "observationCount": cand{"window"}{"observationCount"}.getInt(0) -
        base{"window"}{"observationCount"}.getInt(0),
      "runCount": cand{"window"}{"runCount"}.getInt(0) -
        base{"window"}{"runCount"}.getInt(0),
      "actionCacheMissRows": cand{"rollups"}{"actionsByCacheMissCount"}.len -
        base{"rollups"}{"actionsByCacheMissCount"}.len,
      "targetBuildTimeRows": cand{"rollups"}{"targetsByBuildTime"}.len -
        base{"rollups"}{"targetsByBuildTime"}.len
    },
    "rollupDeltas": {
      "actionsByCacheMissCount": rollupDeltaRows(
        base{"rollups"}{"actionsByCacheMissCount"},
        cand{"rollups"}{"actionsByCacheMissCount"},
        "actionId"),
      "targetsByBuildTime": rollupDeltaRows(
        base{"rollups"}{"targetsByBuildTime"},
        cand{"rollups"}{"targetsByBuildTime"},
        "target")
    },
    "notes": jsonStringSeq([
      "Compare uses current M7 rollups; per-action timing/resource deltas are unavailable until those metrics are captured."
    ])
  }

proc renderCompareText(node: JsonNode): string =
  let deltas = node{"deltas"}
  "stats compare: " & node{"baseline"}{"label"}.getStr() & " -> " &
    node{"candidate"}{"label"}.getStr() & "\n" &
    "delta observations: " & $deltas{"observationCount"}.getInt(0) & "\n" &
    "delta runs: " & $deltas{"runCount"}.getInt(0) & "\n" &
    "note: " & node{"notes"}[0].getStr() & "\n"

proc maybePrepareStatsGraph(projectRoot, target, publicCliPath, workRoot: string;
                            mode: ToolProvisioningMode): Option[BuildGraphInspection] =
  let graphTarget = if target.len > 0: target else: projectRoot
  try:
    return some(prepareBuildGraphInspection(graphTarget, mode, publicCliPath,
      selectDefaultAction = true, workRoot = workRoot))
  except CatchableError:
    return none(BuildGraphInspection)

proc defaultMetricForScope(scope: string): string =
  case scope
  of "actions":
    "cache-miss-count"
  of "inputs":
    "blast-radius"
  of "targets":
    "build-time"
  of "tools":
    "cache-hit-ratio"
  else:
    raise newException(ValueError, "unsupported stats scope: " & scope)

proc runStatsCommand(args: openArray[string]; publicCliPath: string): int =
  var view = "overview"
  var scope = ""
  var metric = ""
  var actionId = ""
  var inputPath = ""
  var label = ""
  var baseline = ""
  var candidate = ""
  var projectRoot = getCurrentDir()
  var target = ""
  var workRoot = ""
  var mode = tpmUnspecified
  var top = 10
  var format = sofText
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg in ["status", "overview", "rank", "show", "snapshot", "compare"]:
      view = arg
    elif arg == "--scope" or arg.startsWith("--scope="):
      scope = valueFromFlag(args, i, "--scope")
    elif arg == "--by" or arg.startsWith("--by="):
      metric = valueFromFlag(args, i, "--by")
    elif arg == "--id" or arg.startsWith("--id="):
      actionId = valueFromFlag(args, i, "--id")
    elif arg == "--path" or arg.startsWith("--path="):
      inputPath = valueFromFlag(args, i, "--path")
    elif arg == "--label" or arg.startsWith("--label="):
      label = valueFromFlag(args, i, "--label")
    elif arg == "--baseline" or arg.startsWith("--baseline="):
      baseline = valueFromFlag(args, i, "--baseline")
    elif arg == "--candidate" or arg.startsWith("--candidate="):
      candidate = valueFromFlag(args, i, "--candidate")
    elif arg == "--project-root" or arg.startsWith("--project-root="):
      projectRoot = valueFromFlag(args, i, "--project-root")
    elif arg == "--target" or arg.startsWith("--target="):
      target = valueFromFlag(args, i, "--target")
    elif arg == "--work-root" or arg.startsWith("--work-root="):
      workRoot = valueFromFlag(args, i, "--work-root")
    elif arg == "--tool-provisioning" or arg.startsWith("--tool-provisioning="):
      mode = parseToolProvisioning(valueFromFlag(args, i, "--tool-provisioning"))
    elif arg == "--action-cache-root" or arg.startsWith("--action-cache-root="):
      setActionCacheRootOverride(valueFromFlag(args, i, "--action-cache-root"))
    elif arg == "--top" or arg.startsWith("--top="):
      top = parseInt(valueFromFlag(args, i, "--top"))
    elif arg == "--json":
      format = sofJson
    elif arg == "--format" or arg.startsWith("--format="):
      format = parseStatsOutputFormat(valueFromFlag(args, i, "--format"))
    elif arg == "--help" or arg == "-h":
      echo "usage: repro stats [status|overview|rank|show|snapshot|compare] [--format=text|json] [--project-root=PATH]"
      return 0
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported stats flag: " & arg)
    else:
      raise newException(ValueError, "unsupported stats view: " & arg)
    inc i

  projectRoot = absolutePath(projectRoot)
  let storePath = defaultStatsStorePath(projectRoot)
  let nodes = readStatsObservations(projectRoot)
  case view
  of "status":
    stdout.write(statsStatusText(projectRoot))
  of "overview":
    stdout.write(statsOverviewText(projectRoot))
  of "rank":
    if scope.len == 0:
      raise newException(ValueError, "stats rank requires --scope")
    if metric.len == 0:
      metric = defaultMetricForScope(scope)
    let needsGraph = scope in ["inputs", "tools"] or
      (scope == "actions" and metric == "output-size")
    let graphInfo =
      if needsGraph:
        maybePrepareStatsGraph(projectRoot, target, publicCliPath, workRoot, mode)
      else:
        none(BuildGraphInspection)
    let outputNode =
      case scope
      of "actions":
        actionRankJson(projectRoot, storePath, metric, top, nodes, graphInfo)
      of "inputs":
        inputRankJson(projectRoot, storePath, metric, top, nodes, graphInfo)
      of "targets":
        targetRankJson(projectRoot, storePath, metric, top, nodes)
      of "tools":
        toolRankJson(projectRoot, storePath, metric, top, nodes, graphInfo)
      else:
        raise newException(ValueError, "unsupported stats scope: " & scope)
    if format == sofJson:
      echo $outputNode
    else:
      stdout.write(renderStatsRankText(outputNode))
  of "show":
    if scope.len == 0:
      raise newException(ValueError, "stats show requires --scope")
    let needsGraph = scope == "inputs"
    let graphInfo =
      if needsGraph or actionId.len > 0:
        maybePrepareStatsGraph(projectRoot, target, publicCliPath, workRoot, mode)
      else:
        none(BuildGraphInspection)
    let outputNode =
      case scope
      of "actions":
        if actionId.len == 0:
          raise newException(ValueError, "stats show --scope=actions requires --id")
        showActionStatsJson(projectRoot, storePath, actionId, nodes, graphInfo)
      of "inputs":
        if inputPath.len == 0:
          raise newException(ValueError, "stats show --scope=inputs requires --path")
        showInputStatsJson(projectRoot, storePath, inputPath, nodes, graphInfo)
      else:
        raise newException(ValueError, "unsupported stats show scope: " & scope)
    if format == sofJson:
      echo $outputNode
    else:
      stdout.write(renderStatsShowText(outputNode))
  of "snapshot":
    if label.len == 0:
      raise newException(ValueError, "stats snapshot requires --label")
    let graphInfo = maybePrepareStatsGraph(projectRoot, target, publicCliPath,
      workRoot, mode)
    let outputNode = snapshotJson(projectRoot, storePath, safeSnapshotLabel(label),
      nodes, graphInfo)
    let path = statsSnapshotPath(projectRoot, label)
    createDir(parentDir(path))
    writeFile(path, pretty(outputNode))
    if format == sofJson:
      echo $outputNode
    else:
      stdout.write(renderSnapshotText(outputNode, path))
  of "compare":
    if baseline.len == 0 or candidate.len == 0:
      raise newException(ValueError,
        "stats compare requires --baseline and --candidate")
    let outputNode = compareSnapshotsJson(projectRoot, baseline, candidate)
    if format == sofJson:
      echo $outputNode
    else:
      stdout.write(renderCompareText(outputNode))
  else:
    raise newException(ValueError, "unsupported stats view: " & view)
  0

proc normalizedGraphPath(projectRoot, path: string): string =
  let material = materialProjectPath(projectRoot, path)
  try:
    os.normalizedPath(material)
  except CatchableError:
    material.replace('\\', '/')

proc pathMatches(projectRoot, candidate, query: string): bool =
  if candidate == query:
    return true
  normalizedGraphPath(projectRoot, candidate) == normalizedGraphPath(projectRoot, query)

proc actionUsesPath(info: BuildGraphInspection; action: BuildAction;
                    path: string): bool =
  for input in action.inputs:
    if pathMatches(info.projectRoot, input, path):
      return true
  if action.depfile.len > 0 and pathMatches(info.projectRoot, action.depfile, path):
    return true
  if action.dynamicDepsFile.len > 0 and
      pathMatches(info.projectRoot, action.dynamicDepsFile, path):
    return true
  if action.monitorDepfile.len > 0 and
      pathMatches(info.projectRoot, action.monitorDepfile, path):
    return true

proc inputDependents(info: BuildGraphInspection; path: string): HashSet[string] =
  for action in info.actions:
    if actionUsesPath(info, action, path):
      result.incl(action.id)

proc downstreamClosure(info: BuildGraphInspection; roots: HashSet[string]): HashSet[string] =
  var queue: seq[string] = @[]
  for root in roots:
    if not result.contains(root):
      result.incl(root)
      queue.add(root)
  var head = 0
  while head < queue.len:
    let current = queue[head]
    inc head
    for dependent in directDependents(info.actions, current):
      if not result.contains(dependent):
        result.incl(dependent)
        queue.add(dependent)

proc edgeJson(fromId, toId, kind: string): JsonNode =
  %*{"from": fromId, "to": toId, "kind": kind}

proc analysisBaseJson(info: BuildGraphInspection; view: string): JsonNode =
  %*{
    "schemaId": "reprobuild.graph.analysis-view.v1",
    "command": "graph",
    "view": view,
    "target": info.target,
    "projectRoot": info.projectRoot,
    "graph": graphMetadataJson(info)
  }

proc graphNeighborhoodJson(info: BuildGraphInspection; focus: string): JsonNode =
  let action = requireAction(info.actions, focus)
  let deps = directDependencies(info.actions, focus)
  let dependents = directDependents(info.actions, focus)
  var nodes = newJArray()
  var edges = newJArray()
  nodes.add(buildActionJson(action))
  for dep in deps:
    nodes.add(buildActionJson(requireAction(info.actions, dep)))
    edges.add(edgeJson(dep, focus, "dependency"))
  for dependent in dependents:
    nodes.add(buildActionJson(requireAction(info.actions, dependent)))
    edges.add(edgeJson(focus, dependent, "dependency"))
  result = analysisBaseJson(info, "neighborhood")
  result["focus"] = %focus
  result["actions"] = nodes
  result["edges"] = edges
  result["directDependencies"] = jsonStringSeq(deps)
  result["directDependents"] = jsonStringSeq(dependents)

proc graphInputsJson(info: BuildGraphInspection; focus: string): JsonNode =
  let action = requireAction(info.actions, focus)
  result = analysisBaseJson(info, "inputs")
  result["focus"] = %focus
  result["actionId"] = %focus
  result["inputs"] = jsonStringSeq(action.inputs)
  result["outputs"] = jsonStringSeq(action.outputs)
  result["depfile"] = %action.depfile
  result["dynamicDepsFile"] = %action.dynamicDepsFile
  result["monitorDepfile"] = %action.monitorDepfile
  result["dependencyPolicy"] = dependencyPolicyJson(action.dependencyPolicy)
  result["note"] = %"This graph view reports static graph inputs and dependency policy; dynamic path identities require captured dependency reports."

proc graphDependentsJson(info: BuildGraphInspection; path: string): JsonNode =
  let direct = inputDependents(info, path)
  let closure = downstreamClosure(info, direct)
  result = analysisBaseJson(info, "dependents")
  result["path"] = %path
  result["directDependentActionIds"] = actionIdsJson(direct)
  result["dependentActionIds"] = actionIdsJson(closure)
  result["directDependentCount"] = %direct.len
  result["dependentCount"] = %closure.len

proc graphBlastRadiusJson(info: BuildGraphInspection; path: string): JsonNode =
  let direct = inputDependents(info, path)
  let closure = downstreamClosure(info, direct)
  var targetOutputs = newJArray()
  for action in info.actions:
    if closure.contains(action.id):
      for output in action.outputs:
        targetOutputs.add(%*{"actionId": action.id, "path": output})
  result = analysisBaseJson(info, "blast-radius")
  result["path"] = %path
  result["directDependentActionIds"] = actionIdsJson(direct)
  result["blastRadiusActionIds"] = actionIdsJson(closure)
  result["directDependentCount"] = %direct.len
  result["blastRadiusCount"] = %closure.len
  result["affectedOutputs"] = targetOutputs
  result["note"] = %"Structural graph blast radius; historical observed impact belongs to repro stats rank --scope=inputs --by=blast-radius."

proc latestStatsRunId(projectRoot: string): string =
  for node in readStatsObservations(projectRoot):
    let runId = node{"runId"}.getStr()
    if runId.len > 0:
      result = runId

proc graphCriticalPathJson(info: BuildGraphInspection; run: string): JsonNode =
  let selectedRun =
    if run == "last": latestStatsRunId(info.projectRoot) else: run
  result = analysisBaseJson(info, "critical-path")
  result["run"] = %run
  result["selectedRunId"] = %selectedRun
  result["availability"] = %*{
    "available": false,
    "reason": "M7 stats do not capture per-action dynamic durations required for critical path reconstruction"
  }
  result["criticalPath"] = newJArray()
  result["sampleCount"] = %0

proc graphPartitionCandidatesJson(info: BuildGraphInspection; kind: string): JsonNode =
  result = analysisBaseJson(info, "partition-candidates")
  result["kind"] = %kind
  result["availability"] = %*{
    "available": false,
    "reason": "deferred/experimental: linker-level object and symbol evidence is not collected yet"
  }
  result["candidates"] = newJArray()

proc renderGraphAnalysisText(node: JsonNode): string =
  var lines: seq[string] = @[]
  let view = node{"view"}.getStr()
  lines.add("graph view: " & view)
  case view
  of "neighborhood":
    lines.add("focus: " & node{"focus"}.getStr())
    lines.add("directDependencies: " &
      (if node{"directDependencies"}.len > 0:
        node{"directDependencies"}.getElems().mapIt(it.getStr()).join(", ")
      else: "-"))
    lines.add("directDependents: " &
      (if node{"directDependents"}.len > 0:
        node{"directDependents"}.getElems().mapIt(it.getStr()).join(", ")
      else: "-"))
  of "inputs":
    lines.add("focus: " & node{"focus"}.getStr())
    lines.add("inputs: " & $node{"inputs"}.len)
    for item in node{"inputs"}:
      lines.add("  input: " & item.getStr())
    lines.add("outputs: " & $node{"outputs"}.len)
  of "dependents":
    lines.add("path: " & node{"path"}.getStr())
    lines.add("directDependents: " & $node{"directDependentCount"}.getInt(0))
    lines.add("dependents: " & $node{"dependentCount"}.getInt(0))
  of "blast-radius":
    lines.add("path: " & node{"path"}.getStr())
    lines.add("directDependents: " & $node{"directDependentCount"}.getInt(0))
    lines.add("blastRadius: " & $node{"blastRadiusCount"}.getInt(0))
  of "critical-path":
    lines.add("run: " & node{"selectedRunId"}.getStr())
    lines.add("unavailable: " & node{"availability"}{"reason"}.getStr())
  of "partition-candidates":
    lines.add("kind: " & node{"kind"}.getStr())
    lines.add("deferred: " & node{"availability"}{"reason"}.getStr())
  else:
    lines.add("unsupported view")
  lines.join("\n") & "\n"

proc runGraphCommand(args: openArray[string]; publicCliPath: string): int =
  var target = ""
  var view = "actions"
  var focus = ""
  var path = ""
  var runId = ""
  var kind = ""
  var mode = tpmUnspecified
  var workRoot = ""
  var format = gofText
  var positionals: seq[string] = @[]
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--build":
      inc i
    elif arg == "--view" or arg.startsWith("--view="):
      view = valueFromFlag(args, i, "--view")
      inc i
    elif arg in ["--lock", "--infra", "--all"]:
      raise newException(ValueError,
        arg & " is not implemented yet; use repro lock visualize/debug for " &
          "solved package graph inspection")
    elif arg.startsWith("--focus="):
      focus = arg.split("=", maxsplit = 1)[1]
      inc i
    elif arg == "--focus":
      if i + 1 >= args.len:
        raise newException(ValueError, "--focus requires a value")
      focus = args[i + 1]
      inc i, 2
    elif arg == "--path" or arg.startsWith("--path="):
      path = valueFromFlag(args, i, "--path")
      inc i
    elif arg == "--run" or arg.startsWith("--run="):
      runId = valueFromFlag(args, i, "--run")
      inc i
    elif arg == "--kind" or arg.startsWith("--kind="):
      kind = valueFromFlag(args, i, "--kind")
      inc i
    elif arg == "--target" or arg.startsWith("--target="):
      target = valueFromFlag(args, i, "--target")
      inc i
    elif arg == "--json":
      format = gofJson
      inc i
    elif arg == "--dot":
      format = gofDot
      inc i
    elif arg.startsWith("--format="):
      format = parseGraphOutputFormat(arg.split("=", maxsplit = 1)[1],
        allowDot = true)
      inc i
    elif arg == "--format":
      if i + 1 >= args.len:
        raise newException(ValueError, "--format requires a value")
      format = parseGraphOutputFormat(args[i + 1], allowDot = true)
      inc i, 2
    elif arg.startsWith("--tool-provisioning="):
      mode = parseToolProvisioning(arg.split("=", maxsplit = 1)[1])
      inc i
    elif arg == "--tool-provisioning":
      if i + 1 >= args.len:
        raise newException(ValueError, "--tool-provisioning requires a value")
      mode = parseToolProvisioning(args[i + 1])
      inc i, 2
    elif arg.startsWith("--work-root="):
      workRoot = arg.split("=", maxsplit = 1)[1]
      inc i
    elif arg == "--work-root":
      if i + 1 >= args.len:
        raise newException(ValueError, "--work-root requires a value")
      workRoot = args[i + 1]
      inc i, 2
    elif arg.startsWith("--action-cache-root="):
      setActionCacheRootOverride(arg.split("=", maxsplit = 1)[1])
      inc i
    elif arg == "--action-cache-root":
      if i + 1 >= args.len:
        raise newException(ValueError, "--action-cache-root requires a value")
      setActionCacheRootOverride(args[i + 1])
      inc i, 2
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported graph flag: " & arg)
    else:
      positionals.add(arg)
      inc i

  if positionals.len > 2:
    raise newException(ValueError,
      "unexpected graph arguments: " & positionals[2 .. ^1].join(" "))
  if positionals.len >= 1:
    target = positionals[0]
  if positionals.len >= 2:
    focus = positionals[1]
  let targetWasOmitted = target.len == 0
  # Named-Targets M5: if the first positional is a bare or
  # qualified name (not a path/fragment selector), route it through
  # the shared resolver. The project anchor stays the current
  # directory; the resolved action id flows into ``focus`` so the
  # downstream `--view=neighborhood`/`--view=inputs` paths and the
  # `actions` / `text` renderers receive it as their focal action.
  var nameSelector = ""
  if not targetWasOmitted:
    let classified = classifyBuildSelector(target)
    if classified.kind in {bskName, bskQualified}:
      nameSelector = target
      target = "."
  if target.len == 0:
    target = "."

  var autoRunQuota = startAutoRunQuotaIfNeeded(false)
  try:
    let info = prepareBuildGraphInspection(target, mode, publicCliPath,
      selectDefaultAction = targetWasOmitted or nameSelector.len > 0,
      workRoot = workRoot)
    if nameSelector.len > 0:
      var actionIds: seq[string] = @[]
      for action in info.actions:
        actionIds.add(action.id)
      let resolution = resolveTargetExportSelector(info.targetExportTable,
        actionIds, info.explicitTargetNames, nameSelector)
      case resolution.kind
      of trkResolved:
        focus = resolution.actionId
      of trkAmbiguous:
        var err = newException(BuildTargetAmbiguousError,
          "target '" & nameSelector &
            "' is exported by multiple packages: " &
            resolution.candidates.join(", ") &
            " — re-run with the qualified <package>:<name> form")
        err.selectorName = nameSelector
        err.candidates = resolution.candidates
        raise err
      of trkUnknown:
        var err = newException(BuildTargetUnknownError,
          "unknown build target: " & nameSelector)
        err.selectorName = nameSelector
        err.suggestions = resolution.suggestions
        raise err
    if view == "actions":
      discard
    elif view == "neighborhood":
      if focus.len == 0:
        focus = info.selectedActionId
      if focus.len == 0:
        raise newException(ValueError, "--view=neighborhood requires --focus")
      let outputNode = graphNeighborhoodJson(info, focus)
      if format == gofJson:
        echo $outputNode
      elif format == gofDot:
        echo renderBuildGraphDot(info, focus)
      else:
        stdout.write(renderGraphAnalysisText(outputNode))
      return 0
    elif view == "inputs":
      if focus.len == 0:
        focus = info.selectedActionId
      if focus.len == 0:
        raise newException(ValueError, "--view=inputs requires --focus")
      let outputNode = graphInputsJson(info, focus)
      if format == gofJson:
        echo $outputNode
      elif format == gofDot:
        raise newException(ValueError, "dot format is not supported for --view=inputs")
      else:
        stdout.write(renderGraphAnalysisText(outputNode))
      return 0
    elif view == "dependents":
      if path.len == 0:
        raise newException(ValueError, "--view=dependents requires --path")
      let outputNode = graphDependentsJson(info, path)
      if format == gofJson:
        echo $outputNode
      elif format == gofDot:
        raise newException(ValueError, "dot format is not supported for --view=dependents")
      else:
        stdout.write(renderGraphAnalysisText(outputNode))
      return 0
    elif view == "blast-radius":
      if path.len == 0:
        raise newException(ValueError, "--view=blast-radius requires --path")
      let outputNode = graphBlastRadiusJson(info, path)
      if format == gofJson:
        echo $outputNode
      elif format == gofDot:
        raise newException(ValueError, "dot format is not supported for --view=blast-radius")
      else:
        stdout.write(renderGraphAnalysisText(outputNode))
      return 0
    elif view == "critical-path":
      if runId.len == 0:
        raise newException(ValueError, "--view=critical-path requires --run")
      let outputNode = graphCriticalPathJson(info, runId)
      if format == gofJson:
        echo $outputNode
      elif format == gofDot:
        raise newException(ValueError, "dot format is not supported for --view=critical-path")
      else:
        stdout.write(renderGraphAnalysisText(outputNode))
      return 0
    elif view == "partition-candidates":
      if kind.len == 0:
        kind = "dylib"
      let outputNode = graphPartitionCandidatesJson(info, kind)
      if format == gofJson:
        echo $outputNode
      elif format == gofDot:
        raise newException(ValueError, "dot format is not supported for --view=partition-candidates")
      else:
        stdout.write(renderGraphAnalysisText(outputNode))
      return 0
    else:
      raise newException(ValueError, "unsupported graph view: " & view)
    case format
    of gofText:
      echo renderBuildGraphText(info, focus)
    of gofJson:
      if focus.len > 0:
        echo $renderFocusedGraphJson(info, focus)
      else:
        echo $buildGraphInspectionJson(info)
    of gofDot:
      echo renderBuildGraphDot(info, focus)
    return 0
  finally:
    if autoRunQuota != nil:
      try:
        autoRunQuota.terminate()
        discard autoRunQuota.waitForExit()
        autoRunQuota.close()
      except CatchableError:
        discard

proc latestReportAction(info: BuildGraphInspection; actionId: string): Option[JsonNode] =
  let reportPath = info.outDir / "build-report.json"
  if not fileExists(extendedPath(reportPath)):
    return none(JsonNode)
  try:
    let report = parseFile(extendedPath(reportPath))
    for section in ["actions", "providerCompileActions", "cmakeRegenerationActions"]:
      for action in report{section}:
        if action{"id"}.getStr() == actionId:
          return some(action)
  except CatchableError:
    return none(JsonNode)

proc shortestActionPath(actions: openArray[BuildAction];
                        roots: openArray[string];
                        subject: string): seq[string] =
  let byId = buildActionById(actions)
  if not byId.hasKey(subject):
    discard requireAction(actions, subject)
  var queue: seq[string] = @[]
  var parent = initTable[string, string]()
  var seen = initHashSet[string]()
  for root in roots:
    if root.len > 0 and byId.hasKey(root) and not seen.contains(root):
      queue.add(root)
      seen.incl(root)
      parent[root] = ""
  var head = 0
  while head < queue.len:
    let current = queue[head]
    inc head
    if current == subject:
      var node = current
      while node.len > 0:
        result.add(node)
        node = parent[node]
      result.reverse()
      return
    for dep in byId[current].deps:
      if byId.hasKey(dep) and not seen.contains(dep):
        seen.incl(dep)
        parent[dep] = current
        queue.add(dep)

proc jsonArrayLength(node: JsonNode; key: string): int =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JArray:
    node[key].len
  else:
    0

proc evidenceCountsJsonFromReport(action: JsonNode): JsonNode =
  let evidence = action{"evidence"}
  %*{
    "declaredInputs": evidence.jsonArrayLength("declaredInputs"),
    "declaredOutputs": evidence.jsonArrayLength("declaredOutputs"),
    "depfileInputs": evidence.jsonArrayLength("depfileInputs"),
    "monitorReads": evidence.jsonArrayLength("monitorReads"),
    "monitorWrites": evidence.jsonArrayLength("monitorWrites"),
    "monitorProbes": evidence.jsonArrayLength("monitorProbes"),
    "diagnostics": evidence.jsonArrayLength("diagnostics")
  }

proc whyActionJson(info: BuildGraphInspection; actionId: string): JsonNode =
  let action = requireAction(info.actions, actionId)
  let roots =
    if info.selectedActionId.len > 0:
      @[info.selectedActionId]
    else:
      newSeq[string]()
  let path = shortestActionPath(info.actions, roots, actionId)
  let report = latestReportAction(info, actionId)
  var node = %*{
    "schemaId": "reprobuild.why.action.v1",
    "subjectKind": "action",
    "subject": actionId,
    "selectedActionId": info.selectedActionId,
    "defaultActionId": info.defaultActionId,
    "path": jsonStringSeq(path),
    "directDependencies": jsonStringSeq(directDependencies(info.actions, actionId)),
    "directDependents": jsonStringSeq(directDependents(info.actions, actionId)),
    "action": buildActionJson(action)
  }
  if report.isSome:
    let item = report.get()
    node["lastResult"] = item
    node["evidenceCounts"] = evidenceCountsJsonFromReport(item)
  else:
    node["lastResult"] = newJNull()
    node["evidenceCounts"] = newJNull()
  node

proc optionalReportField(action: JsonNode; key: string): string =
  if action.kind == JObject and action.hasKey(key):
    let value = action[key]
    case value.kind
    of JString:
      result = value.getStr()
    of JInt:
      result = $value.getInt()
    of JFloat:
      result = $value.getFloat()
    of JBool:
      result = $value.getBool()
    of JNull:
      result = ""
    else:
      result = $value

proc renderWhyActionText(info: BuildGraphInspection; actionId: string): string =
  let action = requireAction(info.actions, actionId)
  let roots =
    if info.selectedActionId.len > 0:
      @[info.selectedActionId]
    else:
      newSeq[string]()
  let path = shortestActionPath(info.actions, roots, actionId)
  var lines: seq[string] = @[]
  lines.add("why action " & actionId)
  if info.selectedActionId.len > 0:
    lines.add("selectedAction: " & info.selectedActionId)
  elif info.defaultActionId.len > 0:
    lines.add("defaultAction: " & info.defaultActionId)
  if path.len > 0:
    lines.add("path: " & path.join(" -> "))
  else:
    lines.add("path: not rooted by the selected action; present in full graph")
  let deps = directDependencies(info.actions, actionId)
  let dependents = directDependents(info.actions, actionId)
  lines.add("directDependencies: " &
    (if deps.len > 0: deps.join(", ") else: "-"))
  lines.add("directDependents: " &
    (if dependents.len > 0: dependents.join(", ") else: "-"))
  lines.add("command: " & commandDisplay(action))
  lines.add("dependencyPolicy: " & $action.dependencyPolicy.kind &
    " completeness=" & $action.dependencyPolicy.completeness)
  let report = latestReportAction(info, actionId)
  if report.isSome:
    let item = report.get()
    lines.add("lastResult: status=" & item.optionalReportField("status") &
      " cache=" & item.optionalReportField("cacheDecision") &
      " launched=" & item.optionalReportField("launched") &
      " wouldLaunch=" & item.optionalReportField("wouldLaunch") &
      (if item.optionalReportField("reason").len > 0:
        " reason=" & item.optionalReportField("reason")
      else:
        ""))
    let counts = evidenceCountsJsonFromReport(item)
    lines.add("evidenceCounts: declaredInputs=" &
      $counts["declaredInputs"].getInt() &
      " declaredOutputs=" & $counts["declaredOutputs"].getInt() &
      " depfileInputs=" & $counts["depfileInputs"].getInt() &
      " monitorReads=" & $counts["monitorReads"].getInt() &
      " monitorWrites=" & $counts["monitorWrites"].getInt() &
      " monitorProbes=" & $counts["monitorProbes"].getInt() &
      " diagnostics=" & $counts["diagnostics"].getInt())
  else:
    lines.add("lastResult: no build-report.json entry")
  lines.join("\n")

proc runWhyCommand(args: openArray[string]; publicCliPath: string): int =
  var subject = ""
  var target = ""
  var mode = tpmUnspecified
  var workRoot = ""
  var format = gofText
  var explicitAction = false
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg.startsWith("--action="):
      subject = arg.split("=", maxsplit = 1)[1]
      explicitAction = true
      inc i
    elif arg == "--action":
      if i + 1 >= args.len:
        raise newException(ValueError, "--action requires a value")
      subject = args[i + 1]
      explicitAction = true
      inc i, 2
    elif arg == "--json":
      format = gofJson
      inc i
    elif arg.startsWith("--format="):
      format = parseGraphOutputFormat(arg.split("=", maxsplit = 1)[1],
        allowDot = false)
      inc i
    elif arg == "--format":
      if i + 1 >= args.len:
        raise newException(ValueError, "--format requires a value")
      format = parseGraphOutputFormat(args[i + 1], allowDot = false)
      inc i, 2
    elif arg.startsWith("--tool-provisioning="):
      mode = parseToolProvisioning(arg.split("=", maxsplit = 1)[1])
      inc i
    elif arg == "--tool-provisioning":
      if i + 1 >= args.len:
        raise newException(ValueError, "--tool-provisioning requires a value")
      mode = parseToolProvisioning(args[i + 1])
      inc i, 2
    elif arg.startsWith("--work-root="):
      workRoot = arg.split("=", maxsplit = 1)[1]
      inc i
    elif arg == "--work-root":
      if i + 1 >= args.len:
        raise newException(ValueError, "--work-root requires a value")
      workRoot = args[i + 1]
      inc i, 2
    elif arg.startsWith("--action-cache-root="):
      setActionCacheRootOverride(arg.split("=", maxsplit = 1)[1])
      inc i
    elif arg == "--action-cache-root":
      if i + 1 >= args.len:
        raise newException(ValueError, "--action-cache-root requires a value")
      setActionCacheRootOverride(args[i + 1])
      inc i, 2
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported why flag: " & arg)
    elif explicitAction:
      if target.len == 0:
        target = arg
        inc i
      else:
        raise newException(ValueError, "unexpected why argument: " & arg)
    elif subject.len == 0:
      subject = arg
      inc i
    elif target.len == 0:
      target = arg
      inc i
    else:
      raise newException(ValueError, "unexpected why argument: " & arg)

  if subject.len == 0:
    raise newException(ValueError,
      "missing why subject; use repro why <package-or-action> or " &
        "repro why --action=<action-id>")
  # Named-Targets M5: when the second positional is a path or a bare
  # name, the user may have intended the *name* to be the subject. The
  # legacy single-positional form already worked because the subject
  # came first and the target was current directory. The two-positional
  # ``repro why subject target`` form keeps the ambiguity. We classify
  # ``target``: a name-shaped value is rejected to keep behaviour
  # predictable — the user should re-run as ``repro why <name>`` with
  # one positional.
  let targetClassified =
    if target.len == 0: ClassifiedBuildSelector(kind: bskPath)
    else: classifyBuildSelector(target)
  if target.len > 0 and targetClassified.kind in {bskName, bskQualified}:
    raise newException(ValueError,
      "repro why: the second positional must be a path or fragment " &
        "selector; got the name-shaped value '" & target &
        "' (re-run as `repro why " & target & "` with one positional)")
  if target.len == 0:
    target = "."

  var autoRunQuota = startAutoRunQuotaIfNeeded(false)
  try:
    let info = prepareBuildGraphInspection(target, mode, publicCliPath,
      selectDefaultAction = true,
      workRoot = workRoot)
    # Named-Targets M5: route the subject through the shared
    # ``resolveTargetExportSelector`` helper so the bare implicit name
    # and qualified ``<package>:<name>`` forms reach the same action id
    # they would have via ``repro build NAME``. Action ids and explicit
    # ``target "..."`` labels still resolve via the legacy
    # ``requireAction`` lookup; only the name forms need translation.
    if not explicitAction:
      let subjClassified = classifyBuildSelector(subject)
      if subjClassified.kind in {bskName, bskQualified}:
        var actionIds: seq[string] = @[]
        for action in info.actions:
          actionIds.add(action.id)
        let resolution = resolveTargetExportSelector(info.targetExportTable,
          actionIds, info.explicitTargetNames, subject)
        case resolution.kind
        of trkResolved:
          subject = resolution.actionId
        of trkAmbiguous:
          var err = newException(BuildTargetAmbiguousError,
            "target '" & subject &
              "' is exported by multiple packages: " &
              resolution.candidates.join(", ") &
              " — re-run with the qualified <package>:<name> form")
          err.selectorName = subject
          err.candidates = resolution.candidates
          raise err
        of trkUnknown:
          # Fall through to the legacy ``requireAction`` lookup below
          # so action ids that happen to lack a path/fragment shape
          # still work without surfacing the diagnostic. The
          # ``requireAction`` failure will raise its own ValueError
          # with the candidate-action list.
          discard
    try:
      discard requireAction(info.actions, subject)
    except ValueError:
      if explicitAction:
        raise
      raise newException(ValueError,
        "package-level why is not implemented for this project context yet, " &
          "and no build action named " & subject & " exists")
    case format
    of gofText:
      echo renderWhyActionText(info, subject)
    of gofJson:
      echo $whyActionJson(info, subject)
    of gofDot:
      discard
    return 0
  finally:
    if autoRunQuota != nil:
      try:
        autoRunQuota.terminate()
        discard autoRunQuota.waitForExit()
        autoRunQuota.close()
      except CatchableError:
        discard

proc renderLoweredGraphRecordText(record: LoweredGraphCacheRecord): string =
  var lines: seq[string] = @[]
  lines.add("lowered graph cache")
  lines.add("modulePath: " & record.modulePath)
  lines.add("projectRoot: " & record.projectRoot)
  lines.add("selectedActionId: " &
    (if record.selectedActionId.len > 0: record.selectedActionId else: "-"))
  lines.add("actions: " & $record.actions.len)
  lines.add("pools: " & $record.pools.len)
  for action in record.actions:
    lines.add("- " & action.id &
      " deps=[" & action.deps.join(", ") & "]" &
      " outputs=" & $action.outputs.len &
      " command=" & commandDisplay(action))
  lines.join("\n")

proc runDebugArtifactCommand(args: openArray[string]): int =
  var path = ""
  var format = gofText
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--json":
      format = gofJson
      inc i
    elif arg.startsWith("--format="):
      format = parseGraphOutputFormat(arg.split("=", maxsplit = 1)[1],
        allowDot = false)
      inc i
    elif arg == "--format":
      if i + 1 >= args.len:
        raise newException(ValueError, "--format requires a value")
      format = parseGraphOutputFormat(args[i + 1], allowDot = false)
      inc i, 2
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported debug artifact flag: " & arg)
    elif path.len == 0:
      path = arg
      inc i
    else:
      raise newException(ValueError,
        "unexpected debug artifact argument: " & arg)
  if path.len == 0:
    raise newException(ValueError, "debug artifact requires a path")
  let record = decodeLoweredGraphCache(toBytes(readFile(extendedPath(path))))
  case format
  of gofText:
    echo renderLoweredGraphRecordText(record)
  of gofJson:
    echo $loweredGraphRecordJson(record)
  of gofDot:
    discard
  0

proc parsePositiveIntFlag(flagName, value: string): int =
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(ValueError, flagName & " must be an integer")
  if result <= 0:
    raise newException(ValueError, flagName & " must be greater than zero")

const CodetracerHcrSupportProfile =
  "macos-arm64-direct-hcr-in-codetracer-v1"

type
  HcrWatchConfig = object
    targetName: string
      ## Named-Targets M4: the target name this HCR config attaches to.
      ## Empty for the legacy single-target convenience surface (the
      ## ``--hcr-agent-socket`` / ``--hcr-artifacts`` / ``--hcr-metadata``
      ## flag triad). For the multi-target surface added in M4, every
      ## ``--hcr-target=NAME:SOCKET:ARTIFACTS[:METADATA]`` flag produces a
      ## ``HcrWatchConfig`` whose ``targetName`` is the selector spelling
      ## the user passed on the CLI (matching the M3
      ## ``parseAndResolveSelectors`` output). The target name appears in
      ## every HCR event payload (§3.4 SSE event table) so consumers can
      ## route events back to a specific target.
    socketPath: string
    artifacts: string
    metadataPath: string

  HcrWatchPatchMetadata* = object
    functionName*: string
    targetSymbol*: string
    objectSymbol*: string
    objectPath*: string
    sourcePath*: string

  HcrWatchObjectBaseline* = object
    objectPath*: string
    sourcePath*: string
    generation0Object*: string

  HcrWatchInferredPatch* = object
    metadata*: HcrWatchPatchMetadata
    oldObject*: string
    newObject*: string

  HcrWatchSession = object
    enabled: bool
    config: HcrWatchConfig
    metadata: HcrWatchPatchMetadata
    inferredBaselines: seq[HcrWatchObjectBaseline]
    listener: HcrAgentUnixListener
    connection: HcrAgentSocketConnection
    client: HcrCoordinatorClient
    connected: bool
    oldObject: string
    newObject: string
    baselineSourceDigest: string
      ## Named-Targets M4 (metadata mode): the digest of the metadata
      ## source file at baseline time. Used by ``deliverHcrWatchPatch``
      ## to detect "this target's source did NOT change this cycle" so
      ## the per-target patch lifecycle can silently skip (raise
      ## ``HcrWatchNoChange``) rather than delivering a no-op patch.
      ## Multi-target HCR (HCR §3.2) needs this so a multi-target run
      ## "no patch is delivered to b" when b's closure didn't change.
    fallbackOnly: bool
      ## Named-Targets M4 per-target failure isolation: when a session's
      ## baseline / patch lifecycle raises, this flag is flipped and the
      ## session falls back to the ordinary rebuild path for the rest of
      ## the watch loop. ``hcr/patchFailed`` is emitted exactly once on
      ## the failing target so SSE consumers see the failure exactly
      ## once. Other sessions in the seq are unaffected (per HCR
      ## §3.2 "Multi-Target HCR" — "a failure to inject the agent into
      ## one target does not stop the others").

proc writeJsonFile(path: string; node: JsonNode) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), pretty(node))

proc hcrSourceDigest(path: string): string =
  byteDigest(readFile(extendedPath(path)).bytesOf())

proc objectFunctionBytes(objectPath, symbolName: string): seq[byte] =
  let graph = parseMachOArm64Object(objectPath)
  let symbol = graph.findSymbol(symbolName)
  result = graph.functionBytes(symbol)
  if result.len == 0:
    raise newException(ValueError,
      "could not extract function bytes for " & symbolName & " from " &
        objectPath)

proc hcrWatchEnabled(config: HcrWatchConfig): bool =
  config.socketPath.len > 0 or config.artifacts.len > 0 or
    config.metadataPath.len > 0

proc hcrEventTargetLabel(config: HcrWatchConfig): string =
  ## Named-Targets M4: the ``target`` value carried in every HCR SSE
  ## payload. Falls back to ``"default"`` for the legacy single-target
  ## ``--hcr-agent-socket`` surface so the JSON schema stays uniform
  ## across single- and multi-target runs.
  if config.targetName.len > 0:
    config.targetName
  else:
    "default"

proc hcrEventPayload(config: HcrWatchConfig; extra: JsonNode = nil):
    string =
  ## Named-Targets M4 §3.4 (HCR SSE event payloads gain a ``target``
  ## field): build the JSON payload for an ``hcr/*`` watch event.
  ## ``extra`` may contribute additional fields per the SSE event table
  ## (``patchId``, ``error``, etc.). The ``target`` field is always
  ## present so multi-target SSE consumers can route every event.
  var node = %*{
    "target": hcrEventTargetLabel(config)
  }
  if extra != nil and extra.kind == JObject:
    for key, value in extra.pairs:
      node[key] = value
  $node

proc validateHcrWatchConfig(config: HcrWatchConfig) =
  if not config.hcrWatchEnabled:
    return
  if config.socketPath.len == 0:
    raise newException(ValueError,
      "--hcr-agent-socket is required when HCR watch mode is enabled")
  if config.artifacts.len == 0:
    raise newException(ValueError,
      "--hcr-artifacts is required when HCR watch mode is enabled")

proc resolveProjectPath(projectRoot, path: string): string =
  if path.len == 0:
    return ""
  result =
    if path.isAbsolute:
      path
    else:
      projectRoot / path
  result = os.normalizedPath(result)

proc requiredJsonString(node: JsonNode; key, context: string): string =
  if node.kind != JObject or not node.hasKey(key):
    raise newException(ValueError, context & " missing required field " & key)
  result = node[key].getStr()
  if result.len == 0:
    raise newException(ValueError, context & " field " & key &
      " must not be empty")

proc optionalJsonString(node: JsonNode; key: string): string =
  if node.kind == JObject and node.hasKey(key):
    result = node[key].getStr()

proc defaultObjectSymbol(functionName: string): string =
  when defined(macosx):
    "_" & functionName
  else:
    functionName

proc readHcrWatchPatchMetadata(projectRoot, metadataPath: string):
    HcrWatchPatchMetadata =
  let resolvedMetadataPath = resolveProjectPath(projectRoot, metadataPath)
  if not fileExists(extendedPath(resolvedMetadataPath)):
    raise newException(ValueError,
      "HCR watch metadata does not exist: " & resolvedMetadataPath)
  let root = parseFile(resolvedMetadataPath)
  var patch: JsonNode = nil
  if root.kind == JObject and root.hasKey("patches") and
      root["patches"].kind == JArray and root["patches"].len > 0:
    patch = root["patches"][0]
  else:
    patch = root

  result.functionName = patch.requiredJsonString("function", "HCR patch metadata")
  result.targetSymbol = patch.optionalJsonString("targetSymbol")
  if result.targetSymbol.len == 0:
    result.targetSymbol = result.functionName
  result.objectSymbol = patch.optionalJsonString("objectSymbol")
  if result.objectSymbol.len == 0:
    result.objectSymbol = defaultObjectSymbol(result.functionName)
  result.objectPath = resolveProjectPath(
    projectRoot, patch.requiredJsonString("object", "HCR patch metadata"))
  result.sourcePath = resolveProjectPath(
    projectRoot, patch.requiredJsonString("source", "HCR patch metadata"))

proc jsonStringSeqField(node: JsonNode; key: string): seq[string] =
  let values = node{key}
  if values.kind != JArray:
    return
  for value in values:
    if value.kind == JString and value.getStr().len > 0:
      result.add value.getStr()

proc materialReportPath(projectRoot, path: string): string =
  if path.len == 0:
    return ""
  result =
    if path.isAbsolute:
      path
    else:
      projectRoot / path
  result = os.normalizedPath(result)

proc isCxxSource(path: string): bool =
  splitFile(path).ext.toLowerAscii in [".c", ".cc", ".cpp", ".cxx"]

proc isObjectFile(path: string): bool =
  splitFile(path).ext.toLowerAscii in [".o", ".obj"]

proc stripObjectSymbolPrefix(symbol: string): string =
  if symbol.startsWith("_") and symbol.len > 1:
    symbol[1 .. ^1]
  else:
    symbol

proc hcrWatchObjectCandidatesFromReport*(projectRoot, buildReportPath: string):
    seq[HcrWatchObjectBaseline] =
  if buildReportPath.len == 0 or not fileExists(extendedPath(buildReportPath)):
    raise newException(ValueError,
      "HCR watch inference requires a build report")
  let report = parseFile(buildReportPath)
  for action in report{"actions"}:
    let evidence = action{"evidence"}
    if evidence.kind != JObject:
      continue

    var inputs: seq[string]
    for key in ["declaredInputs", "depfileInputs", "monitorReads"]:
      for path in evidence.jsonStringSeqField(key):
        inputs.addUnique(projectRoot.materialReportPath(path))
    var sourceInputs: seq[string]
    for path in inputs:
      if path.isCxxSource and fileExists(extendedPath(path)):
        sourceInputs.addUnique(path)
    if sourceInputs.len != 1:
      continue

    for path in evidence.jsonStringSeqField("declaredOutputs"):
      let objectPath = projectRoot.materialReportPath(path)
      if objectPath.isObjectFile and fileExists(extendedPath(objectPath)):
        result.add HcrWatchObjectBaseline(
          objectPath: objectPath,
          sourcePath: sourceInputs[0])

proc captureInferredHcrWatchBaseline*(projectRoot, buildReportPath,
                                      artifacts: string):
    seq[HcrWatchObjectBaseline] =
  result = hcrWatchObjectCandidatesFromReport(projectRoot, buildReportPath)
  if result.len == 0:
    raise newException(ValueError,
      "HCR watch could not infer any C/C++ object outputs from the build report")
  createDir(extendedPath(artifacts))
  for i in 0 ..< result.len:
    let objectSegment = safePathSegment(result[i].objectPath, "object")
    result[i].generation0Object =
      artifacts / ("generation0-" & align($i, 4, '0') & "-" & objectSegment)
    copyFile(extendedPath(result[i].objectPath),
      extendedPath(result[i].generation0Object))

type
  HcrWatchNoChange* = object of CatchableError
    ## Named-Targets M4: raised by ``inferHcrWatchPatch`` when none of
    ## the baselines saw a code change in this cycle. Per-target multi-
    ## target HCR catches this distinctly from real injection failures:
    ## a no-change cycle is silent (the target's source didn't change,
    ## so there is nothing to patch), while a real failure (missing
    ## metadata, agent disconnect, malformed object) emits
    ## ``hcr/patchFailed`` and falls back.

proc inferHcrWatchPatch*(baselines: openArray[HcrWatchObjectBaseline];
                         artifacts: string; cycle: int):
    HcrWatchInferredPatch =
  type Candidate = object
    baseline: HcrWatchObjectBaseline
    objectSymbol: string

  var candidates: seq[Candidate]
  for baseline in baselines:
    if not fileExists(extendedPath(baseline.generation0Object)) or
        not fileExists(extendedPath(baseline.objectPath)):
      continue
    let oldGraph = parseMachOArm64Object(baseline.generation0Object)
    let newGraph = parseMachOArm64Object(baseline.objectPath)
    let diff = diffFunctions(oldGraph, newGraph)
    for entry in diff.functions:
      case entry.kind
      of fckUnchanged:
        discard
      of fckRemoved:
        raise newException(ValueError,
          "HCR watch does not support removed function " & entry.name)
      of fckChangedCode, fckRelocationSignatureChanged, fckAdded:
        candidates.add Candidate(
          baseline: baseline,
          objectSymbol: entry.name)

  if candidates.len == 0:
    raise newException(HcrWatchNoChange,
      "HCR watch did not find a changed function in rebuilt object outputs")
  if candidates.len > 1:
    var names: seq[string]
    for candidate in candidates:
      names.add candidate.objectSymbol
    raise newException(ValueError,
      "HCR watch currently requires exactly one changed function; found " &
        names.join(", "))

  let candidate = candidates[0]
  let functionName = stripObjectSymbolPrefix(candidate.objectSymbol)
  let newObject = artifacts /
    (safePathSegment(functionName, "patch") & "-generation" &
      $(cycle - 1) & ".o")
  copyFile(extendedPath(candidate.baseline.objectPath), extendedPath(newObject))
  result = HcrWatchInferredPatch(
    metadata: HcrWatchPatchMetadata(
      functionName: functionName,
      targetSymbol: functionName,
      objectSymbol: candidate.objectSymbol,
      objectPath: candidate.baseline.objectPath,
      sourcePath: candidate.baseline.sourcePath),
    oldObject: candidate.baseline.generation0Object,
    newObject: newObject)

type
  WatchHcrEventEmit = proc(eventKind: string; message: string;
                           payloadJson: string) {.closure.}
    ## Named-Targets M4: per-target HCR SSE emit hook handed to the
    ## ``captureHcrWatchBaseline`` / ``deliverHcrWatchPatch`` procs by
    ## ``runWatchCommand``. The hook is wired to the shared watch SSE
    ## event stream (``emitWatchLine``) so every HCR event lands in the
    ## same stream as ``cycle-start`` / ``rebuild-queued`` and carries a
    ## ``target`` field per HCR/CLI-Integration §3.4.

proc emitHcrEvent(emit: WatchHcrEventEmit; config: HcrWatchConfig;
                  eventKind, message: string; extra: JsonNode = nil) =
  if emit == nil:
    return
  emit(eventKind, message, hcrEventPayload(config, extra))

proc initHcrWatchSession(config: HcrWatchConfig): HcrWatchSession =
  config.validateHcrWatchConfig()
  result.enabled = config.hcrWatchEnabled
  result.config = config
  if result.enabled:
    createDir(extendedPath(config.artifacts))
    result.listener = listenHcrAgentUnixSocket(config.socketPath)
    result.client = initHcrCoordinatorClient(CodetracerHcrSupportProfile)

proc closeHcrWatchSession(session: var HcrWatchSession) =
  if session.enabled:
    if session.connected:
      try: session.connection.close()
      except CatchableError: discard
      session.connected = false
    try: session.listener.close()
    except CatchableError: discard
    # Named-Targets M4: ``runDirectWatch`` may call this early via the
    # per-target failure-isolation block AND again in the final defer.
    # Mark ``enabled = false`` so the second call is a cheap no-op.
    session.enabled = false

proc targetLogSuffix(config: HcrWatchConfig): string =
  ## Named-Targets M4: stdout suffix that names which target the HCR
  ## log line belongs to. Empty string for single-target runs so the
  ## legacy log shape (used by existing tests like
  ## ``t_e2e_hcr_watch_inference``) keeps its byte layout.
  if config.targetName.len > 0:
    " target=" & config.targetName
  else:
    ""

proc captureHcrWatchBaseline(session: var HcrWatchSession;
                             outcome: BuildCommandOutcome;
                             emit: WatchHcrEventEmit = nil) =
  if not session.enabled:
    return
  if session.config.metadataPath.len > 0:
    session.metadata = readHcrWatchPatchMetadata(
      outcome.projectRoot, session.config.metadataPath)
    if not fileExists(extendedPath(session.metadata.objectPath)):
      raise newException(ValueError,
        "HCR watch object does not exist after initial build: " &
          session.metadata.objectPath)
    session.oldObject = session.config.artifacts /
      (safePathSegment(session.metadata.functionName, "patch") & "-generation0.o")
    copyFile(extendedPath(session.metadata.objectPath),
      extendedPath(session.oldObject))
    # Named-Targets M4: record baseline source digest so multi-target
    # metadata-mode runs can detect "this target's source did not
    # change this cycle" and skip patch delivery silently.
    if fileExists(extendedPath(session.metadata.sourcePath)):
      session.baselineSourceDigest =
        hcrSourceDigest(session.metadata.sourcePath)
    writeJsonFile(session.config.artifacts / "hcr-watch-baseline.json", %*{
      "schemaId": "reprobuild.hcr.watch-baseline.v1",
      "supportProfile": CodetracerHcrSupportProfile,
      "mode": "metadata",
      "function": session.metadata.functionName,
      "targetSymbol": session.metadata.targetSymbol,
      "objectSymbol": session.metadata.objectSymbol,
      "object": session.metadata.objectPath,
      "source": session.metadata.sourcePath,
      "generation0Object": session.oldObject
    })
    echo "repro watch: hcr baseline captured object=" &
      session.metadata.objectPath & targetLogSuffix(session.config)
  else:
    session.inferredBaselines = captureInferredHcrWatchBaseline(
      outcome.projectRoot, outcome.buildReportPath, session.config.artifacts)
    var objects = newJArray()
    for baseline in session.inferredBaselines:
      objects.add %*{
        "object": baseline.objectPath,
        "source": baseline.sourcePath,
        "generation0Object": baseline.generation0Object
      }
    writeJsonFile(session.config.artifacts / "hcr-watch-baseline.json", %*{
      "schemaId": "reprobuild.hcr.watch-baseline.v1",
      "supportProfile": CodetracerHcrSupportProfile,
      "mode": "inferred",
      "objects": objects
    })
    echo "repro watch: hcr baseline inferred objects=" &
      $session.inferredBaselines.len & targetLogSuffix(session.config)
  echo "repro watch: hcr waiting for agent socket=" &
    session.config.socketPath & targetLogSuffix(session.config)
  flushStdout()
  # Named-Targets M4: emit the baseline event into the shared SSE stream
  # so per-target HCR consumers see the agent-injection lifecycle as it
  # progresses, even on the cycle-1 baseline.
  emit.emitHcrEvent(session.config, "hcr/agentWaiting",
    "repro watch: hcr waiting for agent socket=" & session.config.socketPath,
    %*{"socket": session.config.socketPath})
  session.connection = acceptHcrAgentConnection(session.listener)
  session.connected = true
  discard session.client.receiveAgentMessage(session.connection)
  session.client.sendCoordinatorMessage(
    session.connection, session.client.coordinatorHelloAckMessage())
  echo "repro watch: hcr agent connected" & targetLogSuffix(session.config)
  flushStdout()
  emit.emitHcrEvent(session.config, "hcr/agentConnected",
    "repro watch: hcr agent connected")

proc deliverHcrWatchPatch(session: var HcrWatchSession;
                          outcome: BuildCommandOutcome; cycle: int;
                          emit: WatchHcrEventEmit = nil) =
  if not session.enabled:
    return
  if not session.connected:
    raise newException(ValueError,
      "HCR watch cannot deliver a patch before the target agent connects")
  if session.config.metadataPath.len > 0:
    session.metadata = readHcrWatchPatchMetadata(
      outcome.projectRoot, session.config.metadataPath)
    if not fileExists(extendedPath(session.metadata.objectPath)):
      raise newException(ValueError,
        "HCR watch object does not exist after rebuild: " &
          session.metadata.objectPath)
    # Named-Targets M4: in multi-target metadata-mode runs, the source
    # digest comparison tells us this target's owned closure did NOT
    # change this cycle (the rebuild was a cache hit for our target).
    # Per HCR §3.2, a target whose closure didn't change MUST NOT
    # receive a patch — raise ``HcrWatchNoChange`` so the per-target
    # lifecycle loop silently skips delivery for this cycle.
    if session.config.targetName.len > 0 and
        session.baselineSourceDigest.len > 0 and
        fileExists(extendedPath(session.metadata.sourcePath)):
      let nowDigest = hcrSourceDigest(session.metadata.sourcePath)
      if nowDigest == session.baselineSourceDigest:
        raise newException(HcrWatchNoChange,
          "HCR watch: target '" & session.config.targetName &
            "' source unchanged this cycle")
    session.newObject = session.config.artifacts /
      (safePathSegment(session.metadata.functionName, "patch") & "-generation" &
        $(cycle - 1) & ".o")
    copyFile(extendedPath(session.metadata.objectPath),
      extendedPath(session.newObject))
  else:
    let inferred = inferHcrWatchPatch(
      session.inferredBaselines, session.config.artifacts, cycle)
    session.metadata = inferred.metadata
    session.oldObject = inferred.oldObject
    session.newObject = inferred.newObject
    echo "repro watch: hcr inferred changed function=" &
      session.metadata.functionName & " object=" & session.metadata.objectPath &
      targetLogSuffix(session.config)
  if not fileExists(extendedPath(session.metadata.sourcePath)):
    raise newException(ValueError,
      "HCR watch source does not exist after rebuild: " &
        session.metadata.sourcePath)

  let patchBytes = objectFunctionBytes(session.newObject,
    session.metadata.objectSymbol)
  let sourceGeneration = HcrSourceGenerationEntry(
    sourcePath: session.metadata.sourcePath,
    generation: uint32(cycle - 1),
    snapshotDigest: hcrSourceDigest(session.metadata.sourcePath),
    lineTableDigest: byteDigest(patchBytes))
  let objectBytes = readFile(extendedPath(session.newObject)).bytesOf()
  let plan = directPatchPlanFromBytes(
    session.metadata.functionName, patchBytes,
    supportProfile = CodetracerHcrSupportProfile,
    snapshotId = "repro-watch-hcr-generation-" & $(cycle - 1))
  let request = directPatchRequest(
    patchId = "repro-watch-hcr-patch-" & align($(cycle - 1), 4, '0'),
    supportProfile = CodetracerHcrSupportProfile,
    changedFunctions = [session.metadata.functionName],
    targetSymbols = [session.metadata.targetSymbol],
    directPatchBytes = patchBytes,
    debugObjectBytes = objectBytes,
    unwindMetadataBytes = minimalAarch64EhFrameTemplate(),
    sourceGenerationMap = [sourceGeneration])
  # Named-Targets M4 §3.4: emit ``hcr/patchCompiling`` for the SSE
  # consumer before the patch is sent to the agent. ``target`` is the
  # per-target label set on the config.
  emit.emitHcrEvent(session.config, "hcr/patchCompiling",
    "repro watch: hcr patch compiling patchId=" & request.patchId,
    %*{
      "patchId": request.patchId,
      "files": %*[session.metadata.sourcePath]
    })
  session.client.sendCoordinatorMessage(
    session.connection, session.client.coordinatorPatchRequestMessage(request))
  while session.client.session.state == hssPatchRequested:
    discard session.client.receiveAgentMessage(session.connection)

  let delivery = HcrCoordinatorDelivery(
    session: session.client.session,
    transcript: session.client.transcript,
    patchApplied: session.client.patchApplied,
    patchFailed: session.client.patchFailed)
  writeJsonFile(session.config.artifacts / "hcr-coordinator-report.json",
    coordinatorDeliveryJson(delivery))
  writeJsonFile(session.config.artifacts / "agent-protocol-transcript.json",
    transcriptJson(session.client.transcript))
  writeJsonFile(session.config.artifacts / "patch-bundle-metadata.json", %*{
    "schemaId": "reprobuild.hcr.codetracer-patch-bundle-metadata.v1",
    "supportProfile": CodetracerHcrSupportProfile,
    "patchId": request.patchId,
    "changedFunction": session.metadata.functionName,
    "targetSymbol": session.metadata.targetSymbol,
    "objectSymbol": session.metadata.objectSymbol,
    "oldObject": session.oldObject,
    "newObject": session.newObject,
    "patchByteCount": patchBytes.len,
    "patchDigest": byteDigest(patchBytes),
    "debugObjectDigest": request.debugObjectPayload.digest,
    "unwindMetadataDigest": request.unwindMetadataPayload.digest,
    "sourceGeneration": %*{
      "sourcePath": sourceGeneration.sourcePath,
      "generation": sourceGeneration.generation,
      "snapshotDigest": sourceGeneration.snapshotDigest,
      "lineTableDigest": sourceGeneration.lineTableDigest
    },
    "patchPlan": patchPlanJson(plan),
    "watch": {
      "cycle": cycle,
      "sourceEditObservedByFilesystemWatcher": true
    }
  })

  if session.client.patchFailed.isSome:
    raise newException(ValueError,
      "HCR watch patch failed: " & session.client.patchFailed.get().message)
  if session.client.patchApplied.isNone:
    raise newException(ValueError,
      "HCR watch did not receive a patchApplied response")
  echo "repro watch: hcr patch applied patchId=" & request.patchId &
    targetLogSuffix(session.config)
  flushStdout()
  # Named-Targets M4 §3.4: ``hcr/patchApplied`` carries ``target`` so
  # SSE consumers can route per-target events.
  var functions = newJArray()
  functions.add(%session.metadata.functionName)
  emit.emitHcrEvent(session.config, "hcr/patchApplied",
    "repro watch: hcr patch applied patchId=" & request.patchId,
    %*{
      "patchId": request.patchId,
      "functions": functions
    })

proc runWatchCommand(args: openArray[string]; publicCliPath: string;
                     forceDirect = false;
                     daemonHosted = false;
                     eventSink: WatchCommandEventSink = nil;
                     cancelCheck: BuildCancelCallback = nil): int =
  let originalArgs = @args
  var target = ""
  var positionalSelectors: seq[string] = @[]
  var mode = tpmUnspecified
  var maxCycles = 0
  var debounceMs = 250
  var workRoot = ""
  var hcrConfig: HcrWatchConfig
  # Named-Targets M4: per-target HCR config seq, populated by the
  # repeatable ``--hcr-target=NAME:SOCKET:ARTIFACTS[:METADATA]`` flag.
  # The legacy single-target triad (``--hcr-agent-socket`` etc.)
  # populates ``hcrConfig`` above; M4 keeps that surface for backward
  # compatibility (the existing ``t_e2e_hcr_watch_inference`` test
  # exercises it).
  var hcrTargetConfigs: seq[HcrWatchConfig] = @[]
  var daemonMode = bdmAuto
  var daemonModeExplicit = false
  var detach = false
  var attachSessionId = ""
  var stopSessionId = ""
  var statsCapture = StatsCaptureConfig()

  for arg in args:
    if arg.startsWith("--tool-provisioning="):
      mode = parseToolProvisioning(arg.split("=", maxsplit = 1)[1])
    elif arg == "--tool-provisioning":
      raise newException(ValueError,
        "--tool-provisioning requires an inline value, for example " &
          "--tool-provisioning=path")
    elif arg.startsWith("--work-root="):
      workRoot = arg.split("=", maxsplit = 1)[1]
    elif arg == "--work-root":
      raise newException(ValueError,
        "--work-root requires an inline value, for example --work-root=.repro")
    elif arg.startsWith("--max-cycles="):
      maxCycles = parsePositiveIntFlag("--max-cycles",
        arg.split("=", maxsplit = 1)[1])
    elif arg.startsWith("--debounce-ms="):
      debounceMs = parsePositiveIntFlag("--debounce-ms",
        arg.split("=", maxsplit = 1)[1])
    elif arg.startsWith("--daemon="):
      daemonMode = parseBuildDaemonMode(arg.split("=", maxsplit = 1)[1],
        "--daemon")
      daemonModeExplicit = true
    elif arg == "--daemon":
      raise newException(ValueError,
        "--daemon requires an inline value, for example --daemon=require")
    elif arg == "--detach":
      detach = true
    elif arg.startsWith("--stats-capture="):
      statsCapture = parseStatsCaptureGroups(arg.split("=", maxsplit = 1)[1])
    elif arg == "--stats-capture":
      raise newException(ValueError,
        "--stats-capture requires an inline value, for example " &
          "--stats-capture=timing,cache")
    elif arg.startsWith("--attach="):
      attachSessionId = arg.split("=", maxsplit = 1)[1]
    elif arg == "--attach":
      raise newException(ValueError,
        "--attach requires an inline session id, for example --attach=watch-...")
    elif arg.startsWith("--stop="):
      stopSessionId = arg.split("=", maxsplit = 1)[1]
    elif arg == "--stop":
      raise newException(ValueError,
        "--stop requires an inline session id, for example --stop=watch-...")
    elif arg.startsWith("--hcr-agent-socket="):
      hcrConfig.socketPath = arg.split("=", maxsplit = 1)[1]
    elif arg == "--hcr-agent-socket":
      raise newException(ValueError,
        "--hcr-agent-socket requires an inline value, for example " &
          "--hcr-agent-socket=/tmp/repro-hcr.sock")
    elif arg.startsWith("--hcr-artifacts="):
      hcrConfig.artifacts = arg.split("=", maxsplit = 1)[1]
    elif arg == "--hcr-artifacts":
      raise newException(ValueError,
        "--hcr-artifacts requires an inline value, for example " &
          "--hcr-artifacts=.repro/hcr")
    elif arg.startsWith("--hcr-metadata="):
      hcrConfig.metadataPath = arg.split("=", maxsplit = 1)[1]
    elif arg == "--hcr-metadata":
      raise newException(ValueError,
        "--hcr-metadata requires an inline value, for example " &
          "--hcr-metadata=build/hcr-metadata.json")
    elif arg.startsWith("--hcr-target="):
      # Named-Targets M4 + M5: repeatable per-target HCR binding.
      # Two shapes are accepted (the parser picks based on the first
      # token):
      #   1. Legacy colon-delimited NAME:SOCKET:ARTIFACTS[:METADATA].
      #      Fine when NAME is a bare implicit name with no ``:``.
      #   2. M5 key=value form ``name=NAME,socket=SOCKET,artifacts=
      #      ARTIFACTS[,metadata=METADATA]`` so a qualified
      #      ``<package>:<name>`` target like ``pkgA:cli`` survives
      #      without colliding with the SOCKET position. The key=value
      #      shape is recognised when the raw value starts with
      #      ``name=`` — any other input falls through to the colon
      #      parser so existing CLI invocations stay byte-compatible.
      let raw = arg.split("=", maxsplit = 1)[1]
      var perTarget: HcrWatchConfig
      if raw.startsWith("name="):
        # M5 structured form. Split on ``,`` and unpack each
        # ``key=value`` pair. Required keys: ``name``, ``socket``,
        # ``artifacts``; optional: ``metadata``. Whitespace inside
        # values is preserved, but the parser does not unescape ``,``
        # (paths should not contain literal commas; if that ever
        # bites we can promote to a JSON form).
        var nameVal = ""
        var socketVal = ""
        var artifactsVal = ""
        var metadataVal = ""
        for pair in raw.split(','):
          let eq = pair.find('=')
          if eq <= 0:
            raise newException(ValueError,
              "--hcr-target: expected key=value pair, got '" & pair & "'")
          let key = pair[0 ..< eq]
          let value = pair[eq + 1 .. ^1]
          case key
          of "name": nameVal = value
          of "socket": socketVal = value
          of "artifacts": artifactsVal = value
          of "metadata": metadataVal = value
          else:
            raise newException(ValueError,
              "--hcr-target: unknown key '" & key &
                "' (expected name|socket|artifacts|metadata)")
        if nameVal.len == 0 or socketVal.len == 0 or artifactsVal.len == 0:
          raise newException(ValueError,
            "--hcr-target structured form requires non-empty " &
              "name=, socket=, and artifacts= keys (got '" & raw & "')")
        perTarget.targetName = nameVal
        perTarget.socketPath = socketVal
        perTarget.artifacts = artifactsVal
        perTarget.metadataPath = metadataVal
      else:
        # Legacy colon-delimited NAME:SOCKET:ARTIFACTS[:METADATA].
        let parts = raw.split(':')
        if parts.len < 3 or parts.len > 4 or parts[0].len == 0 or
            parts[1].len == 0 or parts[2].len == 0:
          raise newException(ValueError,
            "--hcr-target expects NAME:SOCKET:ARTIFACTS[:METADATA] " &
              "or name=NAME,socket=SOCKET,artifacts=ARTIFACTS" &
              "[,metadata=METADATA] (got '" & raw & "')")
        perTarget.targetName = parts[0]
        perTarget.socketPath = parts[1]
        perTarget.artifacts = parts[2]
        if parts.len == 4:
          perTarget.metadataPath = parts[3]
      hcrTargetConfigs.add(perTarget)
    elif arg == "--hcr-target":
      raise newException(ValueError,
        "--hcr-target requires an inline value, for example " &
          "--hcr-target=alpha:/tmp/a.sock:.repro/hcr-alpha " &
          "or --hcr-target=name=pkgA:cli,socket=/tmp/a.sock," &
          "artifacts=.repro/hcr-alpha")
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported watch flag: " & arg)
    else:
      # Named-Targets M3: watch inherits the M2 multi-selector surface.
      # Classification into path vs. name selectors happens below via
      # the shared ``parseAndResolveSelectors`` helper.
      positionalSelectors.add(arg)

  if not daemonModeExplicit:
    daemonMode = configuredBuildDaemonMode()

  if statsCapture.enabled and (forceDirect or daemonMode == bdmOff) and
      not daemonHosted:
    raise newException(ValueError,
      "--stats-capture requires daemon-hosted watch; direct-mode persistent " &
        "capture is not implemented")

  proc renderDaemonWatchEvent(event: UserDaemonBuildEvent) =
    if event.message.len == 0 or event.kind == bekAccepted:
      return
    if event.message.startsWith("repro watch: "):
      stdout.writeLine(event.message)
    else:
      stdout.writeLine("repro watch: " & event.message)
    flushStdout()

  proc runDaemonAttach(): int =
    let config = defaultUserDaemonConfig(devMode = true)
    discard startUserDaemon(publicCliPath, config)
    let result = requestUserDaemonWatchAttach(attachSessionId, config.endpoint,
      renderDaemonWatchEvent)
    if result.message == "daemon-hosted watch stopped":
      return 0
    result.exitCode

  proc runDaemonStop(): int =
    let config = defaultUserDaemonConfig(devMode = true)
    discard startUserDaemon(publicCliPath, config)
    let result = requestUserDaemonWatchStop(stopSessionId, config.endpoint)
    echo "repro watch: " & result.message & " session=" & result.sessionId
    0

  if attachSessionId.len > 0:
    if daemonMode == bdmOff:
      raise newException(ValueError,
        "--attach requires --daemon=auto|require or REPRO_DAEMON=auto|require")
    if positionalSelectors.len > 0:
      raise newException(ValueError,
        "--attach is incompatible with positional target selectors")
    return runDaemonAttach()
  if stopSessionId.len > 0:
    if daemonMode == bdmOff:
      raise newException(ValueError,
        "--stop requires --daemon=auto|require or REPRO_DAEMON=auto|require")
    if positionalSelectors.len > 0:
      raise newException(ValueError,
        "--stop is incompatible with positional target selectors")
    return runDaemonStop()

  # ----------------------------------------------------------------
  # Named-Targets M3: watch inherits the M2 multi-selector resolver via
  # the shared ``parseAndResolveSelectors`` helper. The resolver turns
  # ``repro watch name1 name2`` into the project anchor + the union of
  # every name's dependency closure; ``lowerProviderSnapshot`` then
  # builds them in one engine pass and ``watchPathsFromReport`` unions
  # the inputs so the watcher monitors every selected closure.
  # ----------------------------------------------------------------
  let resolved = parseAndResolveSelectors(positionalSelectors, "repro watch")
  target = resolved.target
  let extraNameSelectors = resolved.extraNameSelectors
  let targetWasOmitted = resolved.targetWasOmitted
  if target.len == 0:
    target = "."
  if mode notin {tpmPathOnly, tpmNix, tpmTarball, tpmScoop}:
    raise newException(ValueError,
      "repro watch requires --tool-provisioning=path|nix|tarball|scoop")
  # Windows: kqueue gate dropped — Windows now reaches the live watch loop
  # via ReadDirectoryChangesW in repro_cli_support/watch. Linux still
  # surfaces the deferred-backend OSError from openFilesystemWatcher.

  proc watchRunId(): string =
    let nowTime = getTime()
    "watch-" & $getCurrentProcessId() & "-" & $nowTime.toUnix & "-" &
      $nowTime.nanosecond

  proc requestProjectRoot(): string =
    try:
      projectRootForModule(absolutePath(parseBuildTarget(target).modulePath))
    except CatchableError:
      getCurrentDir()

  proc daemonWatchEnvironment(): seq[string] =
    # See ``daemonBuildEnvironment``; we share one carried-env contract across
    # build and watch so daemon-hosted compilers see the same toolchain
    # configuration the user expects from their nix-develop shell.
    daemonCarriedEnvironment()

  proc runDaemonWatch(): int =
    if hcrConfig.hcrWatchEnabled or hcrTargetConfigs.len > 0:
      # Named-Targets M4: per-target HCR bindings inherit the same
      # daemon-hosted HCR limitation as the legacy single-target HCR
      # surface — both flavours fall back to direct mode under
      # ``--daemon=off``.
      raise newException(DaemonBuildUnsupported,
        "daemon-hosted HCR watch is deferred; use --daemon=off")
    let config = defaultUserDaemonConfig(devMode = true)
    let projectRoot = requestProjectRoot()
    discard startUserDaemon(publicCliPath, config)
    # Named-Targets M3: ``selectedRoots`` carries the full user-facing
    # selector list (path anchor + every name selector) so observers of
    # the daemon session register can see what the cycle is watching.
    # The daemon-side executor re-runs ``runWatchCommand`` against the
    # request's ``rawArgs``, so the shared resolver runs once on the
    # client and once on the worker — both invocations are pure and
    # produce identical resolutions.
    var selectedRoots = @[target]
    for sel in extraNameSelectors:
      if selectedRoots.find(sel) < 0:
        selectedRoots.add(sel)
    let request = UserDaemonWatchRequest(
      runId: watchRunId(),
      target: target,
      workingDir: getCurrentDir(),
      projectRoot: projectRoot,
      toolProvisioning: mode.modeName,
      workRoot: workRoot,
      publicCliPath: publicCliPath,
      rawArgs: originalArgs,
      environment: daemonWatchEnvironment(),
      attached: not detach,
      detached: detach,
      cancelOnDisconnect: not detach,
      debounceMs: debounceMs,
      maxCycles: maxCycles,
      selectedRoots: selectedRoots)
    let daemonResult = requestUserDaemonWatchStart(request, config.endpoint,
      renderDaemonWatchEvent)
    if detach:
      echo "repro watch: detached session=" & daemonResult.sessionId
    daemonResult.exitCode

  proc emitWatchLine(line: string; payloadJson = ""; terminal = false;
                     exitCode = 0; watchedPaths: seq[string] = @[];
                     lastResult = "") =
    echo line
    flushStdout()
    if eventSink != nil:
      eventSink("diagnostic", line, payloadJson, terminal, exitCode,
        watchedPaths, lastResult)

  proc runDirectWatch(): int =
    if statsCapture.enabled and daemonHosted:
      let runId = watchRunId()
      beginStatsCapture(runId, runId, requestProjectRoot(), "watch", target,
        statsCapture)
      enqueueStatsObservation(scgSessions, "watch-start", %*{
        "captureGroups": statsCapture.captureGroupsText,
        "daemonHosted": true,
        "maxCycles": maxCycles
      })
    let anyHcrEnabled = hcrConfig.hcrWatchEnabled or hcrTargetConfigs.len > 0
    echo "repro watch: target=" & target & " tool-provisioning=" &
      mode.modeName & " debounceMs=" & $debounceMs &
      (if maxCycles > 0: " maxCycles=" & $maxCycles else: " maxCycles=unbounded") &
      (if anyHcrEnabled: " hcr=enabled" else: " hcr=disabled") &
      (if hcrTargetConfigs.len > 0:
         " hcr-targets=" & $hcrTargetConfigs.len
       else:
         "")
    flushStdout()

    # Named-Targets M4 ----------------------------------------------------
    # Each ``--hcr-target=NAME:SOCKET:ARTIFACTS[:METADATA]`` adds one HCR
    # session to ``hcrSessions``. The legacy single-target triad still
    # contributes one anonymous-target session so existing single-target
    # tests stay untouched. Per HCR §3.2 "Multi-Target HCR", every
    # session's patch lifecycle runs independently; a failure on one
    # session does NOT stop the others (see the per-session try/except
    # below).
    # --------------------------------------------------------------------
    var hcrSessions: seq[HcrWatchSession] = @[]
    if hcrConfig.hcrWatchEnabled:
      hcrSessions.add(initHcrWatchSession(hcrConfig))
    for cfg in hcrTargetConfigs:
      hcrSessions.add(initHcrWatchSession(cfg))
    defer:
      for i in 0 ..< hcrSessions.len:
        hcrSessions[i].closeHcrWatchSession()

    # The shared SSE emit hook for HCR events — wires each per-target
    # ``hcr/*`` event into the watch event stream so SSE consumers can
    # route by ``target`` (HCR/CLI-Integration §3.4).
    let hcrEmit: WatchHcrEventEmit =
      proc(eventKind, message, payloadJson: string) =
        emitWatchLine(message, payloadJson = payloadJson)

    var cycle = 0
    while true:
      if cancelCheck != nil and cancelCheck():
        return 130
      cycle.inc
      emitWatchLine("repro watch: cycle " & $cycle & " start" &
        (if cycle == 1: " initial" else: " rebuild"),
        payloadJson = "{\"watchEvent\":\"cycle-start\",\"cycle\":" & $cycle &
          "}")
      # Adapter: executeBuildTarget speaks the build-event shape; the watch
      # caller's eventSink takes additional terminal/exitCode/path fields.
      # Forwarding nested logSummary / logAction lines through the daemon
      # protocol is required so user-visible echoes (selectedTarget=,
      # scheduler=, defaultTarget=) reach the CLI instead of vanishing into
      # the daemon log when this watch runs daemon-hosted.
      let buildEventSink: BuildCommandEventSink =
        if eventSink == nil:
          nil
        else:
          proc(kind, message, payloadJson: string) =
            eventSink(kind, message, payloadJson, false, 0, @[], "")
      let outcome = executeBuildTarget(target, mode, publicCliPath,
        selectDefaultAction = targetWasOmitted,
        workRoot = workRoot,
        eventSink = buildEventSink,
        cancelCheck = cancelCheck,
        extraNameSelectors = extraNameSelectors)
      emitWatchLine("repro watch: cycle " & $cycle & " result exitCode=" &
        $outcome.exitCode,
        payloadJson = "{\"watchEvent\":\"cycle-result\",\"cycle\":" & $cycle &
          ",\"exitCode\":" & $outcome.exitCode & "}",
        exitCode = outcome.exitCode,
        lastResult = "cycle=" & $cycle & " exitCode=" & $outcome.exitCode)
      if outcome.exitCode != 0:
        return outcome.exitCode
      # Named-Targets M4: per-target HCR session lifecycle. Each enabled
      # session runs its own baseline (cycle 1) or patch delivery (cycle
      # N>1). A failure on any single session is isolated: the session
      # is marked ``fallbackOnly`` (no further HCR patches, plain
      # rebuilds only) and ``hcr/patchFailed`` is emitted exactly once
      # carrying ``target: NAME``. Other sessions in the seq keep going
      # — HCR §3.2 "Multi-Target HCR": "a failure to inject the agent
      # into one target does not stop the others".
      for i in 0 ..< hcrSessions.len:
        if not hcrSessions[i].enabled or hcrSessions[i].fallbackOnly:
          continue
        try:
          if cycle == 1:
            hcrSessions[i].captureHcrWatchBaseline(outcome, hcrEmit)
          else:
            hcrSessions[i].deliverHcrWatchPatch(outcome, cycle, hcrEmit)
        except HcrWatchNoChange:
          # Named-Targets M4: this target's source files did not change
          # this cycle. The rebuild was a cache hit for the target's
          # closure; per HCR §3.2 "patch lifecycles are independent",
          # we silently skip patch delivery (no SSE event) and leave
          # the session ready for the next cycle.
          discard
        except CatchableError as err:
          hcrSessions[i].fallbackOnly = true
          let errMsg = err.msg
          let targetLabel = hcrEventTargetLabel(hcrSessions[i].config)
          emitWatchLine("repro watch: hcr patch failed target=" &
              targetLabel & " error=" & errMsg & " (falling back to rebuilds)",
            payloadJson = hcrEventPayload(hcrSessions[i].config, %*{
              "error": errMsg,
              "fallback": "rebuild"
            }))
          # Close the failing session's listener / connection so the
          # socket file is released; subsequent cycles short-circuit
          # the lifecycle calls via ``fallbackOnly``.
          hcrSessions[i].closeHcrWatchSession()
      if maxCycles > 0 and cycle >= maxCycles:
        emitWatchLine("repro watch: max cycles reached",
          payloadJson = "{\"watchEvent\":\"max-cycles\"}", terminal = true,
          watchedPaths = @[], lastResult = "max-cycles")
        if statsCapture.enabled and daemonHosted:
          enqueueStatsObservation(scgSessions, "watch-finish", %*{
            "exitCode": 0,
            "cycles": cycle,
            "reason": "max-cycles"
          })
        return 0

      let paths = watchPathsFromReport(outcome)
      var watcher = openFilesystemWatcher(paths)
      try:
        emitWatchLine("repro watch: watching paths=" &
          $watcher.watchedPathCount,
          payloadJson = "{\"watchEvent\":\"watching\",\"pathCount\":" &
            $watcher.watchedPathCount & "}",
          watchedPaths = paths)
        let event = watcher.waitForEvent(
          proc(): bool = cancelCheck != nil and cancelCheck())
        emitWatchLine("repro watch: event seen path=" & event.path &
          " detail=" & event.detail,
          payloadJson = "{\"watchEvent\":\"filesystem\",\"path\":\"" &
            event.path.replace("\\", "\\\\").replace("\"", "\\\"") &
            "\",\"detail\":\"" &
            event.detail.replace("\\", "\\\\").replace("\"", "\\\"") &
            "\"}",
          watchedPaths = paths)
        let coalesced = watcher.drainDebouncedEvents(debounceMs)
        emitWatchLine("repro watch: debounce complete coalesced=" & $coalesced,
          payloadJson = "{\"watchEvent\":\"debounce\",\"coalesced\":" &
            $coalesced & "}",
          watchedPaths = paths)
        emitWatchLine("repro watch: rebuild cycle after filesystem event",
          payloadJson = "{\"watchEvent\":\"rebuild-queued\"}",
          watchedPaths = paths)
      finally:
        watcher.closeFilesystemWatcher()

  if forceDirect or daemonMode == bdmOff:
    return runDirectWatch()

  try:
    return runDaemonWatch()
  except DaemonBuildUnsupported as err:
    if daemonMode == bdmRequire:
      raise newException(ValueError,
        "daemon mode required but repro-daemon cannot execute watch: " &
          err.msg)
    if statsCapture.enabled:
      raise newException(ValueError,
        "daemon-hosted stats capture requested but repro-daemon cannot " &
          "execute watch: " & err.msg)
    stderr.writeLine("repro watch: daemon watch unsupported; falling back " &
      "to direct mode: " & err.msg)
    return runDirectWatch()
  except CatchableError as err:
    if daemonMode == bdmRequire:
      raise newException(ValueError,
        "daemon mode required but repro-daemon is unavailable: " & err.msg)
    if statsCapture.enabled:
      raise newException(ValueError,
        "daemon-hosted stats capture requested but repro-daemon is unavailable: " &
          err.msg)
    stderr.writeLine("repro watch: daemon unavailable; falling back to " &
      "direct mode: " & err.msg)
    return runDirectWatch()

# ---- M22: `repro develop <pkg>` (workspace-overlay form) ------------------
#
# M22 adds the workspace-overlay form documented in
# ``reprobuild-specs/CLI/develop.md``: a bare positional ``<pkg>`` whose
# resolution targets the M6/M7/M8 resolver's package set (the
# ``ResolvedRepo.name`` of every repo declared by the active workspace).
#
# Two outcomes per invocation:
#
#   - ``--source=PATH`` provided: just register the override pointing at
#     the existing on-disk checkout. No VCS clone is scheduled.
#   - no ``--source``: clone the package's upstream URL into a workspace-
#     local conventional location (``<workspaceRoot>/develop/<pkg>``)
#     using the M2 ``bakWorkspaceVcs`` clone action, then register the
#     override pointing at the freshly-cloned tree.
#
# In both cases the override entry is appended via the M20 immutable
# ``addOverride`` helper and persisted with ``writeDevelopOverridesFile``.
# The engine-rebuild step is deferred along with the M21 engine wiring;
# the next ``repro build`` will pick up the override via the M21 resolver
# contract once that wiring lands. M22 is purely the operator-visible
# piece (clone + register + report).
#
# Exit codes (see ``CLI/develop.md`` Conflict And Reuse Rules):
#   - 0  success: clone + register, register-only, or idempotent re-develop
#         of the same package at the same source.
#   - 1  IO / VCS / resolution failure (e.g. unknown package in project,
#         missing ``--source`` path, clone failure, malformed manifest).
#   - 2  refused: an override already exists for the package at a
#         DIFFERENT on-disk source path. The operator must run
#         ``repro develop --drop <pkg>`` (future M22b) or hand-edit the
#         file before re-developing.
#
# JSON report path:
#   ``<workspaceRoot>/.repro/workspace/develop-report.json``.

type
  WorkspaceDevelopReport* = object
    ## Structured outcome of one ``repro develop <pkg>`` invocation in
    ## the M22 workspace-overlay form. ``mode`` is one of:
    ##
    ##   - ``cloned``       — no ``--source`` provided; the dispatcher
    ##                         cloned the package's upstream URL into
    ##                         ``<workspaceRoot>/develop/<pkg>`` and
    ##                         registered the override pointing at it.
    ##   - ``registered``   — ``--source=PATH`` provided; the dispatcher
    ##                         registered the override pointing at the
    ##                         pre-existing checkout, with no clone.
    ##   - ``idempotent``   — an override already existed for ``pkg`` at
    ##                         the SAME on-disk path; the dispatcher
    ##                         re-emitted the report and returned 0.
    ##   - ``refused``      — an override already existed for ``pkg`` at
    ##                         a DIFFERENT on-disk path; the dispatcher
    ##                         did NOT modify the file and returned 2.
    ##   - ``error``        — IO / VCS / resolve failure; the dispatcher
    ##                         returned 1.
    package*: string
    source*: string
    mode*: string
    workspaceRoot*: string
    project*: string
    overridePackage*: string
    overrideLocalPath*: string
    overrideState*: string
    overrideCreatedAt*: string
    overrideProvenance*: string
    diagnostic*: string
    exitCode*: int

proc toJsonNode*(report: WorkspaceDevelopReport): JsonNode =
  result = newJObject()
  result["pkg"] = %report.package
  result["source"] = %report.source
  result["mode"] = %report.mode
  result["workspaceRoot"] = %report.workspaceRoot
  result["project"] = %report.project
  var entry = newJObject()
  entry["package"] = %report.overridePackage
  entry["local_path"] = %report.overrideLocalPath
  entry["state"] = %report.overrideState
  entry["created_at"] = %report.overrideCreatedAt
  if report.overrideProvenance.len > 0:
    entry["provenance"] = %report.overrideProvenance
  result["overrideEntry"] = entry
  if report.diagnostic.len > 0:
    result["diagnostic"] = %report.diagnostic
  result["exitCode"] = %report.exitCode

proc renderDevelopTextLines*(report: WorkspaceDevelopReport): seq[string] =
  case report.mode
  of "cloned":
    result.add("repro develop: cloned " & report.package & " into " &
      report.overrideLocalPath)
    result.add("repro develop: registered override for " & report.package &
      " (next build will pick it up via the M21 resolver)")
  of "registered":
    result.add("repro develop: registered override for " & report.package &
      " → " & report.overrideLocalPath &
      " (next build will pick it up via the M21 resolver)")
  of "idempotent":
    result.add("repro develop: " & report.package &
      " already in develop mode at " & report.overrideLocalPath &
      " (no change)")
  of "refused":
    result.add("repro develop: refused — override for " & report.package &
      " already points at a different path: " & report.overrideLocalPath)
    if report.diagnostic.len > 0:
      result.add("repro develop: " & report.diagnostic)
  else:
    if report.diagnostic.len > 0:
      result.add("repro develop: error — " & report.diagnostic)

type
  WorkspaceDevelopArgs = object
    package: string
    sourcePath: string
    workspaceRoot: string
    toolProvisioning: ToolProvisioningMode
    json: bool
    explicitWorkspaceRoot: bool
    explicitSource: bool

proc parseDevelopArgs*(args: openArray[string]): WorkspaceDevelopArgs =
  ## ``repro develop <pkg> [--source=PATH] [--workspace-root=PATH]
  ## [--tool-provisioning=path|nix|tarball|scoop] [--json]``.
  ##
  ## Mirrors the M9 ``parseWorkspaceInitArgs`` shape. The positional
  ## ``<pkg>`` is required and must NOT be combined with ``--``,
  ## ``--cmake``, ``--list``, or ``--into`` (those route to the existing
  ## pre-M22 develop forms). ``--source`` and ``--workspace-root`` accept
  ## both ``flag=value`` and ``flag value`` forms.
  result.toolProvisioning = tpmPathOnly
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--source" or arg.startsWith("--source="):
      result.sourcePath = valueFromFlag(args, i, "--source")
      result.explicitSource = true
    elif arg == "--workspace-root" or arg.startsWith("--workspace-root="):
      result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
      result.explicitWorkspaceRoot = true
    elif arg == "--tool-provisioning" or
        arg.startsWith("--tool-provisioning="):
      result.toolProvisioning = parseToolProvisioning(
        valueFromFlag(args, i, "--tool-provisioning"))
    elif arg == "--json":
      result.json = true
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported `repro develop` flag in M22 workspace-overlay form: " &
          arg)
    elif result.package.len == 0:
      result.package = arg
    else:
      raise newException(ValueError,
        "unexpected positional argument to `repro develop <pkg>`: " & arg)
    inc i
  if result.package.len == 0:
    raise newException(ValueError,
      "`repro develop <pkg>` requires a package name")
  if result.workspaceRoot.len == 0:
    result.workspaceRoot = getCurrentDir()
  result.workspaceRoot = absolutePath(result.workspaceRoot)

proc resolveDevelopWorkspaceProject(
    workspaceRoot: string): ResolvedProject =
  ## M22 reuses the M9/M10 dispatch rule. Composer wins when
  ## ``.repo/workspace.toml`` declares layers; otherwise we look up the
  ## single recorded project name (via the M13 metadata-only
  ## workspace.toml) or fall back to a single ``projects/*.toml`` if
  ## exactly one exists. A workspace with no resolvable project surfaces
  ## as a ``ValueError`` so the dispatcher exits 1 with a clear message.
  let workspaceToml = workspaceRoot / ".repo" / "workspace.toml"
  if isCompositionalWorkspaceToml(workspaceRoot):
    return composeManifestLayersFromFile(workspaceToml)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  if fileExists(workspaceToml):
    try:
      let recorded = readWorkspaceLocal(absolutePath(workspaceToml))
      if recorded.workspace.project.len > 0:
        let projectFile = manifestsRoot / "projects" /
          (recorded.workspace.project & ".toml")
        let variantFile = manifestsRoot / "variants" /
          (recorded.workspace.project & ".toml")
        if fileExists(projectFile):
          return resolveProject(projectFile)
        if fileExists(variantFile):
          return resolveVariant(variantFile)
    except WorkspaceManifestParseError:
      discard
  # Last resort: a workspace with exactly one ``projects/*.toml`` and no
  # metadata file. M22's primary callers always have a workspace.toml
  # (M9 init writes one) so this arm mostly serves tests that pre-seed
  # only the project file.
  let projectsDir = manifestsRoot / "projects"
  if dirExists(projectsDir):
    var candidates: seq[string]
    for kind, path in walkDir(projectsDir):
      if kind == pcFile and path.endsWith(".toml"):
        candidates.add(path)
    if candidates.len == 1:
      return resolveProject(candidates[0])
  raise newException(ValueError,
    "`repro develop` could not resolve a project from workspace root '" &
      workspaceRoot & "' (no .repo/workspace.toml and no single " &
      "projects/*.toml under .repo/manifests/)")

proc safeDevelopPathSegment(value: string): string =
  ## File-system safe segment for the develop subdir. Mirrors
  ## ``safeRepoIdSegment`` (only ASCII letters/digits and a couple of
  ## punctuation chars survive untouched) but with a different name so
  ## the two helpers can diverge later if needed.
  for ch in value:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('-')
  if result.len == 0:
    result = "pkg"

proc cloneForDevelop(workspaceRoot, pkg, fetchUrl, revision: string;
                    identity: GitToolIdentity): tuple[ok: bool; path: string;
                                                    diagnostic: string] =
  ## Schedule a one-shot ``bakWorkspaceVcs`` clone of ``fetchUrl`` into
  ## ``<workspaceRoot>/develop/<pkg>``. The target directory must NOT
  ## pre-exist (the clone action refuses to clone into a non-empty
  ## path); the dispatcher checks for collisions before reaching here.
  ## Returns the absolute target path on success.
  let relTarget = "develop" / safeDevelopPathSegment(pkg)
  let absTarget = workspaceRoot / relTarget
  if dirExists(absTarget):
    return (ok: false, path: absTarget,
      diagnostic: "develop clone target already exists: " & absTarget)
  let receiptDir = workspaceRoot / ".repro" / "workspace" / "receipts"
  createDir(receiptDir)
  let receiptRel = ".repro" / "workspace" / "receipts" /
    ("develop-clone-" & safeDevelopPathSegment(pkg) & ".receipt")
  let actionId = "workspace-develop-clone-" & safeDevelopPathSegment(pkg)
  var action = gitCloneAction(actionId, identity,
    remoteUrl = fetchUrl,
    repoPath = relTarget,
    receiptPath = receiptRel,
    revision = revision)
  action.cwd = workspaceRoot
  let cacheRoot = workspaceRoot / ".repro" / "workspace" / "engine-cache"
  var config = defaultBuildEngineConfig(cacheRoot)
  config.suppressTrace = true
  let res = runBuild(graph([action]), config)
  if res.results.len == 0:
    return (ok: false, path: absTarget,
      diagnostic: "build engine returned no results for develop clone")
  let outcome = res.results[0]
  if outcome.status notin {asSucceeded, asCacheHit, asUpToDate}:
    return (ok: false, path: absTarget,
      diagnostic: "develop clone failed: status=" & $outcome.status &
        " reason=" & outcome.reason &
        (if outcome.stderr.len > 0: " stderr=" & outcome.stderr else: ""))
  (ok: true, path: absTarget, diagnostic: "")

proc currentRfc3339Timestamp(): string =
  ## ISO-8601 UTC timestamp formatted as ``YYYY-MM-DDTHH:MM:SSZ`` so the
  ## M20 strict reader's ``created_at`` field round-trips byte-for-byte.
  let t = utc(now())
  t.format("yyyy-MM-dd'T'HH:mm:ss") & "Z"

proc executeWorkspaceDevelop(args: WorkspaceDevelopArgs):
    WorkspaceDevelopReport =
  ## End-to-end M22 driver. (1) Resolve the active project. (2) Check
  ## that ``args.package`` is declared as a ``ResolvedRepo.name``;
  ## otherwise exit 1 naming the project file. (3) Decide between
  ## clone-and-register and just-register. (4) Read the existing M20
  ## override file (if any) and detect idempotent / collision arms.
  ## (5) Persist the updated override via ``writeDevelopOverridesFile``.
  result.package = args.package
  result.workspaceRoot = args.workspaceRoot

  # Step 1: resolve the workspace's active project.
  var resolved: ResolvedProject
  try:
    resolved = resolveDevelopWorkspaceProject(args.workspaceRoot)
  except CatchableError as err:
    result.mode = "error"
    result.diagnostic = err.msg
    result.exitCode = 1
    return result
  result.project = resolved.projectName

  # Step 2: verify the package is declared.
  var matched: ResolvedRepo
  var found = false
  for repo in resolved.repos:
    if repo.name == args.package:
      matched = repo
      found = true
      break
  if not found:
    result.mode = "error"
    result.diagnostic = "package '" & args.package &
      "' is not declared in project '" & resolved.projectName &
      "' (project file: " & resolved.projectFile & ")"
    result.exitCode = 1
    return result

  # Step 3: determine the on-disk source path.
  var sourcePath = ""
  var willClone = false
  if args.explicitSource:
    if args.sourcePath.len == 0:
      result.mode = "error"
      result.diagnostic = "`--source` requires a path value"
      result.exitCode = 1
      return result
    sourcePath = absolutePath(args.sourcePath)
    if not dirExists(sourcePath):
      result.mode = "error"
      result.diagnostic = "`--source` path does not exist: " & sourcePath
      result.exitCode = 1
      return result
  else:
    sourcePath = absolutePath(
      args.workspaceRoot / "develop" / safeDevelopPathSegment(args.package))
    willClone = true
  result.source = sourcePath

  # Step 4: load the existing override file (if any) and check the
  # idempotent / collision arms BEFORE doing any side-effecting work.
  var existingFile: DevelopOverrides
  let existingOpt =
    try:
      readDevelopOverridesFile(args.workspaceRoot)
    except WorkspaceManifestParseError as e:
      result.mode = "error"
      result.diagnostic = "failed to read existing develop-overrides.toml: " &
        e.msg
      result.exitCode = 1
      return result
  if existingOpt.isSome:
    existingFile = existingOpt.get()
  else:
    existingFile = newDevelopOverrides()

  let priorOpt = findOverride(existingFile, args.package)
  if priorOpt.isSome:
    let prior = priorOpt.get()
    let priorAbs = absolutePath(prior.local_path)
    if priorAbs == sourcePath:
      # Idempotent: same package, same path → no-op (exit 0).
      result.mode = "idempotent"
      result.overridePackage = prior.package
      result.overrideLocalPath = prior.local_path
      result.overrideState = prior.state
      result.overrideCreatedAt = prior.created_at
      if prior.provenance.isSome:
        result.overrideProvenance = prior.provenance.get()
      result.exitCode = 0
      return result
    else:
      # Collision: same package, different path → refuse (exit 2).
      result.mode = "refused"
      result.overridePackage = prior.package
      result.overrideLocalPath = prior.local_path
      result.overrideState = prior.state
      result.overrideCreatedAt = prior.created_at
      if prior.provenance.isSome:
        result.overrideProvenance = prior.provenance.get()
      result.diagnostic = "existing override at " & prior.local_path &
        " does not match requested source " & sourcePath &
        "; drop or relocate the existing override before re-developing"
      result.exitCode = 2
      return result

  # Step 5: clone if needed.
  if willClone:
    var identity: GitToolIdentity
    try:
      identity = ensureGitToolResolvable(args.toolProvisioning, getEnv("PATH"))
      installGitVcsExecutor()
    except CatchableError as err:
      result.mode = "error"
      result.diagnostic = "git tool not resolvable: " & err.msg
      result.exitCode = 1
      return result
    let cloneRes = cloneForDevelop(args.workspaceRoot, args.package,
      matched.fetchUrl, matched.revision, identity)
    if not cloneRes.ok:
      result.mode = "error"
      result.diagnostic = cloneRes.diagnostic
      result.exitCode = 1
      return result
    sourcePath = cloneRes.path
    result.source = sourcePath

  # Step 6: register the override.
  let stability = "editable"
  let createdAt = currentRfc3339Timestamp()
  let provenance = "repro develop " & args.package
  var entry: repro_workspace_manifests.DevelopOverrideEntry
  entry.package = args.package
  entry.local_path = sourcePath
  entry.state = stability
  entry.created_at = createdAt
  entry.provenance = some(provenance)
  let updated = addOverride(existingFile, entry)
  try:
    writeDevelopOverridesFile(args.workspaceRoot, updated)
  except CatchableError as err:
    result.mode = "error"
    result.diagnostic = "failed to write develop-overrides.toml: " & err.msg
    result.exitCode = 1
    return result

  result.mode =
    if willClone: "cloned"
    else: "registered"
  result.overridePackage = entry.package
  result.overrideLocalPath = entry.local_path
  result.overrideState = entry.state
  result.overrideCreatedAt = entry.created_at
  result.overrideProvenance = provenance
  result.exitCode = 0

proc writeWorkspaceDevelopReport(report: WorkspaceDevelopReport) =
  ## Persist the JSON view alongside the other workspace dispatcher
  ## reports (``init-report.json``, ``sync-report.json`` etc.) so
  ## downstream tooling can read one well-known location.
  if report.workspaceRoot.len == 0:
    return
  let reportDir = report.workspaceRoot / ".repro" / "workspace"
  try:
    createDir(reportDir)
  except CatchableError:
    return
  let reportPath = reportDir / "develop-report.json"
  try:
    writeFile(reportPath, pretty(report.toJsonNode(), indent = 2) & "\n")
  except CatchableError:
    discard

proc runWorkspaceDevelopCommand*(args: openArray[string]): int =
  ## ``repro develop <pkg> [--source=PATH] [--workspace-root=PATH]
  ## [--tool-provisioning=path|nix|tarball|scoop] [--json]``.
  ##
  ## M22 workspace-overlay dispatcher: clone the package (via M2 VCS
  ## actions) or just register the override (when ``--source`` points at
  ## a pre-existing checkout), then persist the entry in
  ## ``<workspaceRoot>/.repro/develop-overrides.toml`` via M20.
  let parsed = parseDevelopArgs(args)
  let report = executeWorkspaceDevelop(parsed)
  writeWorkspaceDevelopReport(report)
  if parsed.json:
    stdout.writeLine(pretty(report.toJsonNode(), indent = 2))
  else:
    for line in renderDevelopTextLines(report):
      if report.exitCode == 0:
        stdout.writeLine(line)
      else:
        stderr.writeLine(line)
  report.exitCode

proc looksLikeWorkspaceDevelopArgs(args: openArray[string]): bool =
  ## Decide whether the argv looks like the M22 workspace-overlay form
  ## (``repro develop <pkg> [--source=...] [--workspace-root=...]
  ## [--json]``) as opposed to the pre-M22 surfaces (``--list``,
  ## ``<dependency> --into=PATH``, ``<target> -- <command>``,
  ## ``--cmake``). Returns true when at least one M22-distinctive
  ## marker is present AND none of the pre-M22 markers are present.
  ##
  ## The M22-distinctive markers are: ``--source[=...]``, ``--json``,
  ## ``--workspace-root[=...]``. The pre-M22 markers are: ``--list``,
  ## ``--into[=...]``, ``--cmake``, ``--cmake-binary[=...]``,
  ## ``--work-root[=...]``, ``--tool-provisioning[=...]``, ``--``
  ## (the command separator).
  var hasM22Marker = false
  for arg in args:
    if arg == "--source" or arg.startsWith("--source=") or
        arg == "--json" or
        arg == "--workspace-root" or arg.startsWith("--workspace-root="):
      hasM22Marker = true
    if arg == "--list" or
        arg == "--into" or arg.startsWith("--into=") or
        arg == "--cmake" or
        arg == "--cmake-binary" or arg.startsWith("--cmake-binary=") or
        arg == "--work-root" or arg.startsWith("--work-root=") or
        arg == "--tool-provisioning" or arg.startsWith("--tool-provisioning=") or
        arg == "--":
      return false
  hasM22Marker

proc runDevelopCommand(args: openArray[string]): int =
  # M22 routing: when the argv carries an M22-distinctive flag
  # (``--source``, ``--workspace-root``, ``--json``) and none of the
  # pre-M22 markers (``--list``, ``--into``, ``--cmake``,
  # ``--tool-provisioning``, ``--work-root``, ``--``), dispatch to the
  # workspace-overlay form documented in ``CLI/develop.md``.
  if looksLikeWorkspaceDevelopArgs(args):
    return runWorkspaceDevelopCommand(args)
  var target = ""
  var mode = tpmUnspecified
  var command: seq[string] = @[]
  var afterSeparator = false
  var workRoot = ""
  var cmakeMode = false
  var cmakeBinary = ""
  var listOverrides = false
  var intoPath = ""
  var i = 0
  while i < args.len:
    let arg = args[i]
    if afterSeparator:
      command.add(arg)
    elif arg == "--":
      afterSeparator = true
    elif arg == "--cmake":
      cmakeMode = true
    elif arg == "--list":
      listOverrides = true
    elif arg == "--into" or arg.startsWith("--into="):
      intoPath = valueFromFlag(args, i, "--into")
    elif arg.startsWith("--tool-provisioning="):
      mode = parseToolProvisioning(arg.split("=", maxsplit = 1)[1])
    elif arg == "--tool-provisioning":
      raise newException(ValueError,
        "--tool-provisioning requires an inline value, for example " &
        "--tool-provisioning=nix")
    elif arg.startsWith("--cmake-binary="):
      cmakeBinary = arg.split("=", maxsplit = 1)[1]
    elif arg == "--cmake-binary":
      raise newException(ValueError,
        "--cmake-binary requires an inline value, for example " &
          "--cmake-binary=/path/to/cmake")
    elif arg.startsWith("--work-root="):
      workRoot = arg.split("=", maxsplit = 1)[1]
    elif arg == "--work-root":
      raise newException(ValueError,
        "--work-root requires an inline value, for example --work-root=.repro")
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported develop flag: " & arg)
    elif target.len == 0:
      target = arg
    else:
      raise newException(ValueError, "unexpected develop argument before --: " & arg)
    inc i

  if listOverrides:
    if target.len > 0 or intoPath.len > 0 or command.len > 0 or cmakeMode:
      raise newException(ValueError,
        "repro develop --list does not accept a target, --into, --cmake, or a command")
    let projectRoot = activeProjectRootFromCwd()
    for entry in readDevelopOverrides(developOverridesMetadataPath(projectRoot)):
      echo entry.node & "\t" & entry.path
    return 0

  if intoPath.len > 0:
    if cmakeMode or mode != tpmUnspecified or command.len > 0:
      raise newException(ValueError,
        "repro develop <dependency> --into=PATH cannot be combined with " &
          "--cmake, --tool-provisioning, or -- <command>")
    if target.len == 0:
      raise newException(ValueError,
        "repro develop --into=PATH requires a dependency name")
    let projectRoot = activeProjectRootFromCwd()
    let localPath = resolveDevelopOverrideCheckout(target, intoPath)
    let metadataPath = upsertDevelopOverride(projectRoot, target, localPath)
    echo target & "\t" & localPath
    echo "metadata\t" & metadataPath
    return 0

  if target.len == 0:
    raise newException(ValueError, "missing develop target")

  if cmakeMode:
    if mode == tpmUnspecified:
      raise newException(ValueError,
        "repro develop --cmake requires --tool-provisioning=path|nix")
    return runCMakeDevelopCommand(target, mode, command, workRoot, cmakeBinary)

  let modulePath = absolutePath(moduleForTarget(target))
  if not fileExists(extendedPath(modulePath)):
    raise newException(IOError, "develop target module not found: " & modulePath)

  let scopedRoot = scopedWorktreeRoot(modulePath, workRoot)
  let outDir =
    if scopedRoot.len > 0:
      scopedRoot / "develop"
    else:
      parentDir(modulePath) / ".repro" / "develop"
  let interfacePath = outDir / "project-interface.rbsz"
  let stubPath = outDir / "project-interface.nim"
  let compileWorkDir = reprobuildLibraryWorkDir()
  let compileScratchDir = outDir / "provider-work"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath,
    compileWorkDir, compileScratchDir)

  var effectiveMode = mode
  if effectiveMode == tpmUnspecified and
      artifact.projectInterface.defaultToolProvisioning.len > 0:
    effectiveMode = parseToolProvisioning(
      artifact.projectInterface.defaultToolProvisioning)

  if artifact.projectInterface.toolUses.len > 0 and
      effectiveMode == tpmUnspecified:
    raise newException(ValueError,
      "typed tool provisioning is required for uses declarations; refusing " &
        "implicit PATH fallback. Pass --tool-provisioning=path for the weak " &
        "local profile, or --tool-provisioning=nix|tarball for a provisioned " &
        "development environment.")

  if effectiveMode == tpmUnspecified:
    echo "repro develop: compatibility dev-env path active (provider-driven " &
      "artifact integration pending); no external tools requested"
    if command.len == 0:
      return 0
    return runInDevelopEnvironment(command, projectRootForModule(modulePath),
      PathOnlyBuildIdentity(projectName: artifact.projectInterface.projectName,
        interfaceFingerprint: artifact.interfaceFingerprint),
      "", "", interfacePath)

  if effectiveMode notin {tpmPathOnly, tpmNix, tpmTarball, tpmScoop}:
    raise newException(ValueError,
      "unsupported develop tool provisioning mode: " & effectiveMode.modeName)

  let resolved = warmResolveAndWriteIdentity(artifact, outDir, effectiveMode)
  echo "repro develop: compatibility dev-env path active (provider-driven " &
    "artifact integration pending, tool-provisioning=" & effectiveMode.modeName & ")"
  echo "project: " & artifact.projectInterface.projectName
  echo "interface: " & interfacePath
  echo "toolIdentity: " & resolved.identityPath
  echo "inspection: " & resolved.inspectionPath
  echo "binDirs: " & binDirsForDevelop(resolved.identity).join($PathSep)

  if command.len == 0:
    for profile in resolved.identity.profiles:
      echo "tool: " & profile.executableName & " " &
        profile.resolvedExecutablePath
    return 0

  runInDevelopEnvironment(command, projectRootForModule(modulePath),
    resolved.identity, resolved.identityPath, resolved.inspectionPath,
    interfacePath)

proc runStoreDaemonCommand(args: seq[string]): int =
  if args.len == 0:
    echo "usage: repro store daemon {start | status | stop} --dev " &
      "[--store-root <path>]"
    return 2
  let action = args[0]
  let rest = if args.len > 1: args[1 .. ^1] else: @[]
  if "--dev" notin rest:
    stderr.writeLine("repro store daemon: only --dev is implemented in " &
      "this pass; production service hardening is not implemented")
    return 2
  var filtered: seq[string] = @[]
  for arg in rest:
    if arg != "--dev":
      filtered.add(arg)
  try:
    let parsed = parseDevConfig(filtered)
    if parsed.rest.len > 0:
      stderr.writeLine("repro store daemon: unexpected argument: " &
        parsed.rest[0])
      return 2
    case action
    of "start":
      let status = startDevDaemon(stablePublicCliPath(), parsed.config)
      echo renderStatus(status)
      return 0
    of "status":
      echo renderStatus(queryDevStatus(parsed.config.endpoint))
      return 0
    of "stop":
      let status = queryDevStatus(parsed.config.endpoint)
      if not status.running:
        echo renderStatus(status)
        return 0
      stopDevDaemon(parsed.config.endpoint)
      echo "repro store daemon: stopped"
      return 0
    else:
      stderr.writeLine("repro store daemon: unknown action: " & action)
      return 2
  except CatchableError as err:
    stderr.writeLine("repro store daemon " & action & ": error: " & err.msg)
    return 1

proc runStoreCommand*(args: seq[string]): int =
  ## Implements `repro store <subcommand>` for the M56 unified local
  ## content-addressed store. Supported subcommands:
  ##
  ##   gc       — eager garbage collection (SQL dead-set query plus a
  ##              filesystem move into `gc/pending-deletion/` and a
  ##              post-grace unlink sweep).
  ##   recover  — `PRAGMA quick_check`, sweep `tmp/`, and reconcile
  ##              on-disk `prefixes/...` directories against the
  ##              SQLite index.
  ##   roots    — list the currently-registered roots.
  ##   list     — list every realized prefix recorded in the index.
  ##
  ## Each subcommand accepts an optional `--store-root=PATH` to
  ## override the per-user default; the `$REPRO_STORE_ROOT` env var
  ## is honoured otherwise.
  if args.len == 0:
    echo "usage: repro store {gc | recover | roots | list} " &
      "[--store-root=PATH] [--grace-seconds=N]"
    return 2
  if args[0] == "daemon":
    let daemonArgs = if args.len > 1: args[1 .. ^1] else: @[]
    return runStoreDaemonCommand(daemonArgs)
  var storeRootOverride = ""
  var graceSeconds = DefaultGcGraceSeconds
  var sub = ""
  for raw in args:
    if raw.startsWith("--store-root="):
      storeRootOverride = raw[len("--store-root=") .. ^1]
    elif raw.startsWith("--grace-seconds="):
      graceSeconds = parseInt(raw[len("--grace-seconds=") .. ^1])
    elif raw.startsWith("--"):
      stderr.writeLine("repro store: unknown flag: " & raw)
      return 2
    elif sub.len == 0:
      sub = raw
    else:
      stderr.writeLine("repro store: unexpected argument: " & raw)
      return 2
  if sub.len == 0:
    stderr.writeLine("repro store: missing subcommand")
    return 2

  let root = resolveStoreRoot(storeRootOverride)
  try:
    case sub
    of "gc":
      var store = openStore(root)
      defer: store.close()
      let report = store.gc(graceSeconds = graceSeconds)
      echo "repro store gc: store-root=" & root
      echo "quarantined: " & $report.quarantined.len
      for row in report.quarantined:
        echo "  - " & row.adapter & " " & row.packageName & " " &
          row.version
      echo "reclaimed: " & $report.reclaimed.len
      for path in report.reclaimed:
        echo "  - " & path
      return 0
    of "recover":
      let report = recoverStoreRoot(root)
      echo "repro store recover: store-root=" & root
      echo "index rebuilt: " & (if report.indexRebuilt: "yes" else: "no")
      if report.indexRebuilt:
        echo "index recovery reason: " & report.indexRecoveryReason
        echo "index quarantine: " & report.indexQuarantineDir
        echo "quarantined index files: " & $report.quarantinedIndexFiles.len
        for path in report.quarantinedIndexFiles: echo "  - " & path
      echo "quick_check: " & report.quickCheck
      echo "swept staging dirs: " & $report.sweptStagingDirs.len
      for path in report.sweptStagingDirs: echo "  - " & path
      echo "reinserted prefixes: " & $report.reinsertedPrefixes.len
      for path in report.reinsertedPrefixes: echo "  - " & path
      echo "quarantined prefixes: " & $report.quarantinedPrefixes.len
      for path in report.quarantinedPrefixes: echo "  - " & path
      return 0
    of "roots":
      var store = openStore(root)
      defer: store.close()
      echo "repro store roots: store-root=" & root
      for row in store.listRoots():
        echo "  - " & row.rootId & " (" & row.kind & ")"
      return 0
    of "list":
      var store = openStore(root)
      defer: store.close()
      echo "repro store list: store-root=" & root
      for row in store.listPrefixes():
        echo "  - " & row.adapter & " " & row.packageName & " " &
          row.version & " " & row.realizedPath
      return 0
    else:
      stderr.writeLine("repro store: unknown subcommand: " & sub)
      return 2
  except CatchableError as err:
    stderr.writeLine("repro store " & sub & ": error: " & err.msg)
    return 1

proc runUserDaemonCliCommand(args: seq[string]): int =
  if args.len == 0:
    echo "usage: repro daemon {status | start | stop | restart | logs | sessions} " &
      "[--foreground] [--dev] [--endpoint PATH] [--state-dir PATH] " &
      "[--log PATH]"
    return 2
  let action = args[0]
  let rest = if args.len > 1: args[1 .. ^1] else: @[]
  try:
    let parsed = parseUserDaemonConfigFlags(rest)
    if parsed.rest.len > 0:
      stderr.writeLine("repro daemon: unexpected argument: " &
        parsed.rest[0])
      return 2
    let config = parsed.config
    case action
    of "status":
      let status = queryUserDaemonStatus(config.endpoint)
      if not status.running:
        discard cleanupStaleUserDaemonDiscovery(config)
      echo renderUserDaemonStatus(status)
      return 0
    of "start":
      if config.foreground:
        return runUserDaemonForeground(config)
      let status = startUserDaemon(stablePublicCliPath(), config)
      echo renderUserDaemonStatus(status)
      return 0
    of "stop":
      let status = queryUserDaemonStatus(config.endpoint)
      if not status.running:
        discard cleanupStaleUserDaemonDiscovery(config)
        echo renderUserDaemonStatus(status)
        return 0
      stopUserDaemon(config.endpoint)
      cleanupPlatformBackgroundRegistration(config)
      discard cleanupStaleUserDaemonDiscovery(config)
      echo "repro daemon: stopped"
      return 0
    of "restart":
      let status = queryUserDaemonStatus(config.endpoint)
      if status.running:
        stopUserDaemon(config.endpoint)
        cleanupPlatformBackgroundRegistration(config)
        let deadline = epochTime() + 10.0
        while epochTime() < deadline:
          if not queryUserDaemonStatus(config.endpoint).running:
            break
          sleep(25)
        discard cleanupStaleUserDaemonDiscovery(config)
      let started = startUserDaemon(stablePublicCliPath(), config)
      echo renderUserDaemonStatus(started)
      return 0
    of "logs":
      let logs = renderUserDaemonLogs(config)
      stdout.write(logs)
      if not logs.endsWith("\n"):
        stdout.writeLine("")
      return 0
    of "sessions":
      let status = queryUserDaemonStatus(config.endpoint)
      if not status.running:
        discard cleanupStaleUserDaemonDiscovery(config)
        stderr.writeLine("repro daemon sessions: daemon is not running")
        return 1
      echo renderUserDaemonSessions(requestUserDaemonSessions(config.endpoint))
      return 0
    else:
      stderr.writeLine("repro daemon: unknown action: " & action)
      return 2
  except CatchableError as err:
    stderr.writeLine("repro daemon " & action & ": error: " & err.msg)
    return 1

proc runLaunchPlanCommand*(args: seq[string]): int =
  ## Implements `repro launch-plan <subcommand>`. v1 subcommands:
  ##
  ##   show <hex-id>      Render the LaunchPlan stored in the local M56
  ##                      CAS as a JSON inspection view. The JSON form
  ##                      is debug output only — the canonical record is
  ##                      the binary RBLP envelope.
  ##   id <path>          Compute the BLAKE3-256 launchPlanId of a
  ##                      LaunchPlan envelope on disk without opening
  ##                      the store. Useful when verifying activation
  ##                      artifacts.
  ##
  ## Both subcommands accept `--store-root=PATH` and honour
  ## `$REPRO_STORE_ROOT` exactly as `repro store ...` does.
  if args.len == 0:
    echo "usage: repro launch-plan {show <hex-id> | id <path>} " &
      "[--store-root=PATH]"
    return 2
  var storeRootOverride = ""
  var positional: seq[string] = @[]
  for raw in args:
    if raw.startsWith("--store-root="):
      storeRootOverride = raw[len("--store-root=") .. ^1]
    elif raw.startsWith("--"):
      stderr.writeLine("repro launch-plan: unknown flag: " & raw)
      return 2
    else:
      positional.add(raw)
  if positional.len == 0:
    stderr.writeLine("repro launch-plan: missing subcommand")
    return 2
  let sub = positional[0]
  case sub
  of "show":
    if positional.len < 2:
      stderr.writeLine("repro launch-plan show: missing <hex-id>")
      return 2
    let hex = positional[1].toLowerAscii
    if hex.len != 64:
      stderr.writeLine(
        "repro launch-plan show: expected 64-char hex digest, got " &
        $hex.len & " chars")
      return 2
    let root = resolveStoreRoot(storeRootOverride)
    try:
      var store = openStore(root)
      defer: store.close()
      var id: PrefixIdBytes
      for i in 0 ..< 32:
        let hi = parseHexInt($hex[i * 2])
        let lo = parseHexInt($hex[i * 2 + 1])
        id[i] = byte((hi shl 4) or lo)
      let plan = store.loadLaunchPlan(id)
      echo launchPlanToJson(plan)
      return 0
    except CatchableError as err:
      stderr.writeLine("repro launch-plan show: error: " & err.msg)
      return 1
  of "id":
    if positional.len < 2:
      stderr.writeLine("repro launch-plan id: missing <path>")
      return 2
    let path = positional[1]
    try:
      let raw = readFile(extendedPath(path))
      var buf = newSeq[byte](raw.len)
      for i, ch in raw: buf[i] = byte(ord(ch))
      let plan = decodeLaunchPlan(buf)
      echo launchPlanIdHex(plan)
      return 0
    except CatchableError as err:
      stderr.writeLine("repro launch-plan id: error: " & err.msg)
      return 1
  else:
    stderr.writeLine("repro launch-plan: unknown subcommand: " & sub)
    return 2

type
  HcrCoordinateArgs = object
    project: string
    target: string
    socketPath: string
    sourceEditDriver: string
    artifacts: string
    patchFunction: string

proc parseHcrCoordinateArgs(args: seq[string]): HcrCoordinateArgs =
  result.patchFunction = "reprobuild_hcr_patchable_value"
  var index = 0
  while index < args.len:
    let arg = args[index]
    proc valueFor(flag: string): string =
      let prefix = flag & "="
      if arg.startsWith(prefix):
        return arg[prefix.len .. ^1]
      if arg == flag:
        if index + 1 >= args.len:
          raise newException(ValueError, flag & " requires a value")
        index.inc
        return args[index]
      raise newException(ValueError, "internal HCR argument parse error")

    if arg == "--project" or arg.startsWith("--project="):
      result.project = valueFor("--project")
    elif arg == "--target" or arg.startsWith("--target="):
      result.target = valueFor("--target")
    elif arg == "--socket" or arg.startsWith("--socket="):
      result.socketPath = valueFor("--socket")
    elif arg == "--source-edit-driver" or
        arg.startsWith("--source-edit-driver="):
      result.sourceEditDriver = valueFor("--source-edit-driver")
    elif arg == "--artifacts" or arg.startsWith("--artifacts="):
      result.artifacts = valueFor("--artifacts")
    elif arg == "--patch-function" or arg.startsWith("--patch-function="):
      result.patchFunction = valueFor("--patch-function")
    else:
      raise newException(ValueError, "unsupported HCR coordinate flag: " & arg)
    index.inc

proc requireHcrArg(value, name: string) =
  if value.len == 0:
    raise newException(ValueError, name & " is required")

proc requireHcrFile(path, name: string) =
  requireHcrArg(path, name)
  if not fileExists(extendedPath(path)):
    raise newException(ValueError, name & " does not exist: " & path)

proc requireHcrDir(path, name: string) =
  requireHcrArg(path, name)
  if not dirExists(extendedPath(path)):
    raise newException(ValueError, name & " does not exist: " & path)

proc runHcrBuildCycle(project, target, logPath: string): string =
  let targetArg = project & "#" & target
  let command = shellCommand([
    getAppFilename(), "build", targetArg,
    "--tool-provisioning=path",
    "--progress=none",
    "--log=actions"])
  let res = execCmdEx(command, workingDir = project)
  result = res.output
  createDir(extendedPath(parentDir(logPath)))
  writeFile(extendedPath(logPath), res.output)
  if res.exitCode != 0:
    raise newException(ValueError,
      "repro build failed during HCR coordination with exit code " &
        $res.exitCode & "\n" & res.output)

type HcrPrepareObjectArgs = object
  input: string
  output: string
  functionName: string
  segmentName: string
  allCodeSections: bool

proc parseHcrPrepareObjectArgs(args: seq[string]): HcrPrepareObjectArgs =
  result.segmentName = "__HCR"
  var index = 0
  proc valueFor(name: string): string =
    let arg = args[index]
    let prefix = name & "="
    if arg.startsWith(prefix):
      arg[prefix.len .. ^1]
    else:
      index.inc
      if index >= args.len:
        raise newException(ValueError, name & " requires a value")
      args[index]

  while index < args.len:
    let arg = args[index]
    if arg == "--input" or arg.startsWith("--input="):
      result.input = valueFor("--input")
    elif arg == "--output" or arg.startsWith("--output="):
      result.output = valueFor("--output")
    elif arg == "--function" or arg.startsWith("--function="):
      result.functionName = valueFor("--function")
    elif arg == "--all-code":
      result.allCodeSections = true
    elif arg == "--segment" or arg.startsWith("--segment="):
      result.segmentName = valueFor("--segment")
    else:
      raise newException(ValueError,
        "unsupported HCR prepare-object flag: " & arg)
    index.inc

proc runHcrPrepareObjectCommand(args: seq[string]): int =
  let parsed = parseHcrPrepareObjectArgs(args)
  requireHcrFile(parsed.input, "--input")
  requireHcrArg(parsed.output, "--output")
  if parsed.functionName.len == 0 and not parsed.allCodeSections:
    raise newException(ValueError, "--function or --all-code is required")
  if parsed.functionName.len > 0 and parsed.allCodeSections:
    raise newException(ValueError, "--function and --all-code are mutually exclusive")
  requireHcrArg(parsed.segmentName, "--segment")
  createDir(extendedPath(parentDir(parsed.output)))
  if parsed.allCodeSections:
    let count = rewriteMachOArm64CodeSectionSegments(
      parsed.input, parsed.output, parsed.segmentName)
    echo "repro hcr prepare-object: output=" & parsed.output &
      " codeSections=" & $count & " segment=" & parsed.segmentName
  else:
    rewriteMachOArm64FunctionSectionSegment(
      parsed.input, parsed.output, parsed.functionName, parsed.segmentName)
    echo "repro hcr prepare-object: output=" & parsed.output &
      " function=" & parsed.functionName & " segment=" & parsed.segmentName
  0

proc runHcrCoordinateCommand(args: seq[string]): int =
  if args.len == 0:
    stderr.writeLine(
      "repro hcr coordinate --project PATH --target NAME --socket PATH " &
      "--source-edit-driver PATH --artifacts PATH\n" &
      "repro hcr prepare-object --input PATH --output PATH " &
      "(--function NAME|--all-code) " &
      "[--segment NAME]")
    return 2
  if args[0] == "prepare-object":
    return runHcrPrepareObjectCommand(args[1 .. ^1])
  if args[0] != "coordinate":
    stderr.writeLine("repro hcr: unknown subcommand: " & args[0])
    return 2

  var parsed = parseHcrCoordinateArgs(args[1 .. ^1])
  requireHcrDir(parsed.project, "--project")
  requireHcrArg(parsed.target, "--target")
  requireHcrArg(parsed.socketPath, "--socket")
  requireHcrFile(parsed.sourceEditDriver, "--source-edit-driver")
  requireHcrArg(parsed.artifacts, "--artifacts")
  createDir(extendedPath(parsed.artifacts))

  let patchObject = parsed.project / "build" / "patchable.o"
  requireHcrFile(patchObject, "initial patchable object")
  let oldObject = parsed.artifacts / "patchable-generation0.o"
  copyFile(extendedPath(patchObject), extendedPath(oldObject))

  var listener = listenHcrAgentUnixSocket(parsed.socketPath)
  defer: listener.close()
  var connection = acceptHcrAgentConnection(listener)
  defer: connection.close()

  var client = initHcrCoordinatorClient(CodetracerHcrSupportProfile)
  discard client.receiveAgentMessage(connection)
  client.sendCoordinatorMessage(connection, client.coordinatorHelloAckMessage())

  let edit = execCmdEx(shellCommand([parsed.sourceEditDriver, parsed.project]),
    workingDir = parsed.project)
  writeFile(extendedPath(parsed.artifacts / "source-edit-driver.log"), edit.output)
  if edit.exitCode != 0:
    raise newException(ValueError,
      "source edit driver failed with exit code " & $edit.exitCode &
        "\n" & edit.output)

  discard runHcrBuildCycle(parsed.project, parsed.target,
    parsed.artifacts / "reprobuild-build-report.txt")
  requireHcrFile(patchObject, "rebuilt patchable object")
  let newObject = parsed.artifacts / "patchable-generation1.o"
  copyFile(extendedPath(patchObject), extendedPath(newObject))

  let symbolName = "_" & parsed.patchFunction
  let patchBytes = objectFunctionBytes(newObject, symbolName)
  let sourcePath = parsed.project / "src" / "patchable.c"
  let sourceGeneration = HcrSourceGenerationEntry(
    sourcePath: sourcePath,
    generation: 1'u32,
    snapshotDigest: hcrSourceDigest(sourcePath),
    lineTableDigest: byteDigest(patchBytes))
  let objectBytes = readFile(extendedPath(newObject)).bytesOf()
  let plan = directPatchPlanFromBytes(parsed.patchFunction, patchBytes,
    supportProfile = CodetracerHcrSupportProfile,
    snapshotId = "codetracer-hcr-generation-1")
  let request = directPatchRequest(
    patchId = "codetracer-hcr-patch-0001",
    supportProfile = CodetracerHcrSupportProfile,
    changedFunctions = [parsed.patchFunction],
    targetSymbols = [parsed.patchFunction],
    directPatchBytes = patchBytes,
    debugObjectBytes = objectBytes,
    unwindMetadataBytes = minimalAarch64EhFrameTemplate(),
    sourceGenerationMap = [sourceGeneration])
  client.sendCoordinatorMessage(connection,
    client.coordinatorPatchRequestMessage(request))
  while client.session.state == hssPatchRequested:
    discard client.receiveAgentMessage(connection)

  let delivery = HcrCoordinatorDelivery(
    session: client.session,
    transcript: client.transcript,
    patchApplied: client.patchApplied,
    patchFailed: client.patchFailed)
  writeJsonFile(parsed.artifacts / "hcr-coordinator-report.json",
    coordinatorDeliveryJson(delivery))
  writeJsonFile(parsed.artifacts / "agent-protocol-transcript.json",
    transcriptJson(client.transcript))
  writeJsonFile(parsed.artifacts / "patch-bundle-metadata.json", %*{
    "schemaId": "reprobuild.hcr.codetracer-patch-bundle-metadata.v1",
    "supportProfile": CodetracerHcrSupportProfile,
    "patchId": request.patchId,
    "changedFunction": parsed.patchFunction,
    "targetSymbol": parsed.patchFunction,
    "objectSymbol": symbolName,
    "oldObject": oldObject,
    "newObject": newObject,
    "patchByteCount": patchBytes.len,
    "patchDigest": byteDigest(patchBytes),
    "debugObjectDigest": request.debugObjectPayload.digest,
    "unwindMetadataDigest": request.unwindMetadataPayload.digest,
    "sourceGeneration": %*{
      "sourcePath": sourceGeneration.sourcePath,
      "generation": sourceGeneration.generation,
      "snapshotDigest": sourceGeneration.snapshotDigest,
      "lineTableDigest": sourceGeneration.lineTableDigest
    },
    "patchPlan": patchPlanJson(plan)
  })

  if client.patchFailed.isSome:
    stderr.writeLine("repro hcr coordinate: agent patch failed: " &
      client.patchFailed.get().message)
    return 1
  if client.patchApplied.isNone:
    stderr.writeLine("repro hcr coordinate: no patchApplied response")
    return 1
  0

proc runPrivilegedBrokerMode(args: openArray[string]): int =
  ## The hidden `repro --privileged-broker --channel <name> --token
  ## <nonce> [--file-prefix <dir>]` entrypoint (M81 deliverable 3).
  ## The broker is the SAME `repro` binary re-execed; this mode
  ## connects back to the launching parent over the authenticated
  ## RBEB channel and services the closed, typed `PrivilegedOperation`
  ## stream. It is one-shot — it exits when the parent sends `Done`.
  try:
    let parsed = parseBrokerModeArgs(args)
    doAssert parsed.isBrokerMode
    let ctx = FixtureContext(filePrefix: parsed.filePrefix)
    return runBrokerSession(parsed.token, ctx)
  except EElevation as err:
    stderr.writeLine("repro --privileged-broker: " & err.msg)
    return 7
  except CatchableError as err:
    stderr.writeLine("repro --privileged-broker: error: " & err.msg)
    return 7

proc prewarmBuildFileMetadata(info: BuildGraphInspection) =
  if info.actions.len == 0:
    return
  var cache = openActionCache(currentActionCacheRoot() / "action-cache")
  var metadataCache = initFileMetadataCache()
  var probes: seq[HotMetadataProbe] = @[]
  for action in info.actions:
    if action.cacheable and action.dynamicDepsFile.len == 0:
      probes.add(HotMetadataProbe(
        weakFingerprint: action.weakFingerprint,
        policy: action.actionCachePolicy))
  if probes.len == 0:
    return
  let scan = cache.scanHotIndexMetadataInputsUnchanged(probes,
    addr metadataCache)
  if scan.status != hmssUnavailable:
    return

  var records: seq[ActionResultRecord] = @[]
  for action in info.actions:
    if not action.cacheable or action.dynamicDepsFile.len > 0:
      continue
    let record = cache.lookupHotMetadataRecord(action.weakFingerprint,
      action.actionCachePolicy)
    if record.isSome:
      records.add(record.get())
  if records.len > 0:
    discard hotMetadataRecordInputsUnchanged(records, addr metadataCache)

proc prewarmBuildCommand(args: openArray[string]; publicCliPath: string) =
  var target = ""
  var mode = tpmUnspecified
  var workRoot = ""
  var targetWasOmitted = true
  var forceRefresh = false
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--tool-provisioning" or arg.startsWith("--tool-provisioning="):
      mode = parseToolProvisioning(valueFromFlag(args, i,
        "--tool-provisioning"))
    elif arg == "--work-root" or arg.startsWith("--work-root="):
      workRoot = valueFromFlag(args, i, "--work-root")
    elif arg == "--action-cache-root" or arg.startsWith("--action-cache-root="):
      setActionCacheRootOverride(valueFromFlag(args, i,
        "--action-cache-root"))
    elif arg == "--force-rebuild" or arg == "--rebuild" or arg == "--dry-run":
      forceRefresh = true
    elif arg in ["--daemon", "--progress", "--progress-bars", "--diagnostics",
        "--stats", "--report", "--log", "--benchmark", "--stats-capture"]:
      discard valueFromFlag(args, i, arg)
    elif arg.startsWith("--daemon=") or arg.startsWith("--progress=") or
        arg.startsWith("--progress-bars=") or arg.startsWith("--diagnostics=") or
        arg.startsWith("--stats=") or arg.startsWith("--report=") or
        arg.startsWith("--log=") or arg.startsWith("--benchmark=") or
        arg.startsWith("--stats-capture="):
      discard
    elif arg in ["-v", "--verbose", "-vv", "--very-verbose",
        "--prepare-only", "--skip-cmake-regeneration", "--no-runquota",
        "--runquota"]:
      discard
    elif not arg.startsWith("-") and target.len == 0:
      target = arg
      targetWasOmitted = false
    inc i
  if forceRefresh:
    return
  if target.len == 0:
    target = "."
  let info = prepareBuildGraphInspection(target, mode, publicCliPath,
    selectDefaultAction = targetWasOmitted, workRoot = workRoot,
    forceRefresh = false)
  prewarmBuildFileMetadata(info)

proc installUserDaemonBuildPrewarmer() =
  setUserDaemonBuildPrewarmer(proc(request: UserDaemonBuildRequest) =
    let previousCwd = getCurrentDir()
    var previousEnv: seq[tuple[key: string; value: string; present: bool]] = @[]
    try:
      for item in request.environment:
        let split = item.find('=')
        if split < 0:
          continue
        let key = item[0 ..< split]
        let value = item[split + 1 .. ^1]
        previousEnv.add((key: key, value: getEnv(key), present: existsEnv(key)))
        putEnv(key, value)
      if request.workingDir.len > 0:
        setCurrentDir(request.workingDir)
      let cliPath =
        if request.publicCliPath.len > 0: request.publicCliPath
        else: stablePublicCliPath()
      prewarmBuildCommand(request.rawArgs, cliPath)
    finally:
      try:
        setCurrentDir(previousCwd)
      except CatchableError:
        discard
      for item in previousEnv:
        if item.present:
          putEnv(item.key, item.value)
        else:
          delEnv(item.key))

proc installUserDaemonBuildExecutor() =
  setUserDaemonBuildExecutor(proc(request: UserDaemonBuildRequest;
      emit: UserDaemonBuildEmit;
      cancelCheck: UserDaemonBuildCancelCheck): int =
    let previousCwd = getCurrentDir()
    var previousEnv: seq[tuple[key: string; value: string; present: bool]] = @[]
    try:
      for item in request.environment:
        let split = item.find('=')
        if split < 0:
          continue
        let key = item[0 ..< split]
        let value = item[split + 1 .. ^1]
        previousEnv.add((key: key, value: getEnv(key), present: existsEnv(key)))
        putEnv(key, value)
      if request.workingDir.len > 0:
        setCurrentDir(request.workingDir)
      let cliPath =
        if request.publicCliPath.len > 0: request.publicCliPath
        else: stablePublicCliPath()
      proc emitBuildCommandEvent(kind, message, payloadJson: string) =
        if cancelCheck != nil and cancelCheck():
          raise newException(IOError, "build cancelled")
        let eventKind =
          case kind
          of "diagnostic": bekDiagnostic
          else: bekDiagnostic
        emit(eventKind, message, false, 0, "info", payloadJson)
      proc buildCancelRequested(): bool =
        cancelCheck != nil and cancelCheck()
      try:
        result = runBuildCommand(request.rawArgs, cliPath,
          forceDirect = true,
          daemonHosted = true,
          eventSink = emitBuildCommandEvent,
          cancelCheck = buildCancelRequested)
      except BuildTargetAmbiguousError as err:
        # Named-Targets M2: mirror the top-level CLI dispatch arm's
        # ``target_ambiguous`` translation inside the daemon-side
        # executor so the daemon-hosted path produces identical exit
        # code 2 + stderr text. The diagnostic is emitted as a
        # ``bekDiagnostic`` event carrying ``"stream":"stderr"`` in
        # its payload; the client-side ``runDaemonBuild`` event
        # handler routes such events verbatim to stderr. The
        # following ``bekFinished`` is emitted with ``terminal=true``
        # and exit code 2 so the daemon's terminal-emit guard
        # suppresses the generic "daemon-hosted build failed" line
        # that would otherwise tail the diagnostic.
        emit(bekDiagnostic, renderAmbiguousTargetDiagnostic(err[]),
          false, 0, "error",
          "{\"stream\":\"stderr\",\"diagnostic\":\"target_ambiguous\"}")
        emit(bekFinished, "", true, 2, "error",
          "{\"diagnostic\":\"target_ambiguous\"}")
        result = 2
      except BuildTargetUnknownError as err:
        # Named-Targets M2: same translation for the
        # ``unknown_target`` diagnostic. Shared formatter keeps the
        # daemon-hosted and direct-mode emissions byte-identical.
        emit(bekDiagnostic, renderUnknownTargetDiagnostic(err[]),
          false, 0, "error",
          "{\"stream\":\"stderr\",\"diagnostic\":\"unknown_target\"}")
        emit(bekFinished, "", true, 2, "error",
          "{\"diagnostic\":\"unknown_target\"}")
        result = 2
    finally:
      try:
        setCurrentDir(previousCwd)
      except CatchableError:
        discard
      for item in previousEnv:
        if item.present:
          putEnv(item.key, item.value)
        else:
          delEnv(item.key))

proc installUserDaemonWatchExecutor() =
  setUserDaemonWatchExecutor(proc(request: UserDaemonWatchRequest;
      emit: UserDaemonWatchEmit;
      cancelCheck: UserDaemonWatchCancelCheck): int =
    let previousCwd = getCurrentDir()
    var previousEnv: seq[tuple[key: string; value: string; present: bool]] = @[]
    try:
      for item in request.environment:
        let split = item.find('=')
        if split < 0:
          continue
        let key = item[0 ..< split]
        let value = item[split + 1 .. ^1]
        previousEnv.add((key: key, value: getEnv(key), present: existsEnv(key)))
        putEnv(key, value)
      if request.workingDir.len > 0:
        setCurrentDir(request.workingDir)
      let cliPath =
        if request.publicCliPath.len > 0: request.publicCliPath
        else: stablePublicCliPath()
      proc emitWatchCommandEvent(kind, message, payloadJson: string;
                                 terminal: bool; exitCode: int;
                                 watchedPaths: seq[string];
                                 lastResult: string) =
        if cancelCheck != nil and cancelCheck():
          raise newException(IOError, "watch cancelled")
        let eventKind =
          if kind == "accepted":
            bekAccepted
          else:
            bekDiagnostic
        emit(eventKind, message, false, exitCode, "info", payloadJson,
          watchedPaths, lastResult)
      proc watchCancelRequested(): bool =
        cancelCheck != nil and cancelCheck()
      try:
        result = runWatchCommand(request.rawArgs, cliPath,
          forceDirect = true,
          daemonHosted = true,
          eventSink = emitWatchCommandEvent,
          cancelCheck = watchCancelRequested)
      except BuildTargetAmbiguousError as err:
        # Named-Targets M3: mirror the M2 ``installUserDaemonBuildExecutor``
        # arm so daemon-hosted watch produces the same exit code 2 +
        # stderr text as the direct-mode CLI dispatch. The diagnostic is
        # emitted as a ``bekDiagnostic`` event with ``"stream":"stderr"``;
        # the client-side ``runDaemonWatch`` event renderer routes it to
        # stderr verbatim. The terminal ``bekFinished`` carries exit code
        # 2 so the daemon's terminal-emit guard suppresses the generic
        # "daemon-hosted watch failed" status line.
        emit(bekDiagnostic, renderAmbiguousTargetDiagnostic(err[]),
          false, 0, "error",
          "{\"stream\":\"stderr\",\"diagnostic\":\"target_ambiguous\"}",
          @[], "")
        emit(bekFinished, "", true, 2, "error",
          "{\"diagnostic\":\"target_ambiguous\"}", @[], "")
        result = 2
      except BuildTargetUnknownError as err:
        # Named-Targets M3: same translation for ``unknown_target``. The
        # shared ``renderUnknownTargetDiagnostic`` keeps the daemon-hosted
        # and direct-mode emissions byte-identical with ``repro build``.
        emit(bekDiagnostic, renderUnknownTargetDiagnostic(err[]),
          false, 0, "error",
          "{\"stream\":\"stderr\",\"diagnostic\":\"unknown_target\"}",
          @[], "")
        emit(bekFinished, "", true, 2, "error",
          "{\"diagnostic\":\"unknown_target\"}", @[], "")
        result = 2
    finally:
      try:
        setCurrentDir(previousCwd)
      except CatchableError:
        discard
      for item in previousEnv:
        if item.present:
          putEnv(item.key, item.value)
        else:
          delEnv(item.key))

# ---- M9: `repro workspace init` -------------------------------------------
#
# Drive the M6 single-project resolver (or M7 variant composer, or M8
# manifest-layer composer when ``.repo/workspace.toml`` is present) into
# a ``bakWorkspaceVcs.clone`` build plan that materialises missing repos.
# Existing repos are inspected via the M2 observation-only
# ``headShaQuery`` and classified as ``up-to-date`` or ``divergence``;
# the milestone deliberately does NOT auto-modify divergent checkouts —
# the user resolves them by hand and re-runs ``repro workspace init``
# (or, once M10 lands, ``repro workspace sync``).

type
  WorkspaceInitClonedEntry* = object
    name*: string
    path*: string
    remote*: string
    revision*: string

  WorkspaceInitUpToDateEntry* = object
    name*: string
    path*: string
    headSha*: string

  WorkspaceInitDivergenceEntry* = object
    name*: string
    path*: string
    expected*: string
    observed*: string

  WorkspaceInitSkippedLayerEntry* = object
    ## M25 — one per manifest layer that was dropped because the
    ## operator passed ``--allow-missing-layers`` and the layer's URL
    ## was unreachable. The four fields mirror
    ## ``repro_workspace_manifests.SkippedLayer``. ``visibility`` is
    ## the canonical lowercase tier label ("public" / "org" / "team" /
    ## "private") so the JSON consumer can filter on it without
    ## reinventing the enum string mapping.
    index*: int
    provenance*: string
    visibility*: string
    diagnostic*: string

  WorkspaceInitReport* = object
    ## Structured outcome of one ``repro workspace init`` invocation.
    ## ``project`` carries the ``ResolvedProject.projectName`` (the
    ## variant's or project's resolved name); ``workspaceRoot`` is the
    ## absolute path of the directory containing ``.repo/``. The three
    ## per-repo lists are emitted both as stdout text lines and as the
    ## ``.repro/workspace/init-report.json`` machine-readable artifact.
    ##
    ## ``skippedLayers`` (M25) is the list of manifest layers the
    ## composer dropped because the operator passed
    ## ``--allow-missing-layers`` and the layer's URL was unreachable.
    ## A non-empty list does NOT raise the exit code on its own — the
    ## operator opted into the skip explicitly — but downstream
    ## inspection can tell which part of the workspace is missing.
    project*: string
    workspaceRoot*: string
    cloned*: seq[WorkspaceInitClonedEntry]
    upToDate*: seq[WorkspaceInitUpToDateEntry]
    divergences*: seq[WorkspaceInitDivergenceEntry]
    skippedLayers*: seq[WorkspaceInitSkippedLayerEntry]

  WorkspaceInitOutcome* = object
    ## Internal aggregate the dispatcher consumes to compute the exit
    ## code. ``cloneFailures > 0`` raises the exit code to 1; any
    ## ``divergences`` (with no clone failure) raises it to 2.
    report*: WorkspaceInitReport
    cloneFailures*: int

proc toJsonNode*(report: WorkspaceInitReport): JsonNode =
  result = newJObject()
  result["project"] = %report.project
  result["workspaceRoot"] = %report.workspaceRoot
  var cloned = newJArray()
  for entry in report.cloned:
    var obj = newJObject()
    obj["name"] = %entry.name
    obj["path"] = %entry.path
    obj["remote"] = %entry.remote
    obj["revision"] = %entry.revision
    cloned.add(obj)
  result["cloned"] = cloned
  var upToDate = newJArray()
  for entry in report.upToDate:
    var obj = newJObject()
    obj["name"] = %entry.name
    obj["path"] = %entry.path
    obj["headSha"] = %entry.headSha
    upToDate.add(obj)
  result["upToDate"] = upToDate
  var divergences = newJArray()
  for entry in report.divergences:
    var obj = newJObject()
    obj["name"] = %entry.name
    obj["path"] = %entry.path
    obj["expected"] = %entry.expected
    obj["observed"] = %entry.observed
    divergences.add(obj)
  result["divergences"] = divergences
  var skipped = newJArray()
  for entry in report.skippedLayers:
    var obj = newJObject()
    obj["index"] = %entry.index
    obj["provenance"] = %entry.provenance
    obj["visibility"] = %entry.visibility
    obj["diagnostic"] = %entry.diagnostic
    skipped.add(obj)
  result["skippedLayers"] = skipped

proc renderInitTextLines*(report: WorkspaceInitReport): seq[string] =
  for entry in report.skippedLayers:
    result.add("workspace init: skipped manifest layer " &
      entry.provenance & " (visibility=" & entry.visibility &
      ") — " & entry.diagnostic)
  for entry in report.cloned:
    result.add("workspace init: cloned " & entry.path & " from " &
      entry.remote & " @ " & entry.revision)
  for entry in report.upToDate:
    result.add("workspace init: up-to-date " & entry.path)
  for entry in report.divergences:
    result.add("workspace init: divergence " & entry.path &
      " expected=" & entry.expected &
      " observed=" & entry.observed)

type
  WorkspaceInitArgs = object
    projectName: string
    workspaceRoot: string
    toolProvisioning: ToolProvisioningMode
    allowMissingLayers: bool
      ## M25 — when set, the composer downgrades unreachable URL-backed
      ## manifest layers from a fatal diagnostic to a structured
      ## ``WorkspaceInitSkippedLayerEntry``. Used by public-only users
      ## of a mixed workspace so they can still init the public subset.

  WorkspaceInitResolution = object
    project: ResolvedProject
    skippedLayers: seq[WorkspaceInitSkippedLayerEntry]

proc parseWorkspaceInitArgs(args: openArray[string]): WorkspaceInitArgs =
  ## Parse ``repro workspace init`` argv. The single positional is the
  ## project-or-variant bare name. Optional flags:
  ##   ``--workspace-root=PATH``
  ##   ``--tool-provisioning=path|nix|tarball|scoop``
  ##   ``--allow-missing-layers`` (M25)
  result.workspaceRoot = ""
  result.toolProvisioning = tpmPathOnly
  result.allowMissingLayers = false
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--workspace-root" or arg.startsWith("--workspace-root="):
      result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
    elif arg == "--tool-provisioning" or
        arg.startsWith("--tool-provisioning="):
      result.toolProvisioning = parseToolProvisioning(
        valueFromFlag(args, i, "--tool-provisioning"))
    elif arg == "--allow-missing-layers":
      # M25 — opt-in flag. Public-only users pass this when a workspace
      # lists a private manifest layer they cannot fetch; the composer
      # drops the unreachable layer and the init proceeds with the
      # public subset.
      result.allowMissingLayers = true
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported `repro workspace init` flag: " & arg)
    elif result.projectName.len == 0:
      result.projectName = arg
    else:
      raise newException(ValueError,
        "unexpected positional argument to `repro workspace init`: " & arg)
    inc i
  if result.projectName.len == 0:
    raise newException(ValueError,
      "`repro workspace init` requires a <project-or-variant> name")
  if result.workspaceRoot.len == 0:
    result.workspaceRoot = getCurrentDir()
  result.workspaceRoot = absolutePath(result.workspaceRoot)

proc visibilityLabel(v: WorkspaceVisibility): string =
  ## Lowercase tier label used in the structured init report so the
  ## downstream JSON consumer can filter on visibility without having
  ## to know the enum's stringification.
  case v
  of wvPublic: "public"
  of wvOrg: "org"
  of wvTeam: "team"
  of wvPersonal: "private"

proc resolveWorkspaceInitProject(parsed: WorkspaceInitArgs):
    WorkspaceInitResolution =
  ## Pick the right resolver / composer entry point. The composer wins
  ## when ``<workspaceRoot>/.repo/workspace.toml`` declares at least one
  ## ``[[manifest]]`` layer (M8 semantics); otherwise we look up the
  ## named project / variant under ``<workspaceRoot>/.repo/manifests/``
  ## (M6 / M7 semantics). A metadata-only workspace.toml (M13 — written
  ## by single-project init to record the active branch) routes to the
  ## single-project path because the composer requires manifest layers.
  ## A missing name in either place surfaces as a structured
  ## ``ValueError`` naming both candidate paths the user should look at.
  ##
  ## When ``parsed.allowMissingLayers`` is set (M25), the compositional
  ## path uses the extended composer entry point so an unreachable
  ## URL-backed layer is dropped and reported back to the caller rather
  ## than aborting the whole init.
  let workspaceToml = parsed.workspaceRoot / ".repo" / "workspace.toml"
  if isCompositionalWorkspaceToml(parsed.workspaceRoot):
    let options = ComposeOptions(
      skipInaccessibleLayers: parsed.allowMissingLayers)
    let composed = composeManifestLayersFromFileWithOptions(
      workspaceToml, options)
    result.project = composed.project
    for sl in composed.skippedLayers:
      result.skippedLayers.add(WorkspaceInitSkippedLayerEntry(
        index: sl.index,
        provenance: sl.provenance,
        visibility: visibilityLabel(sl.visibility),
        diagnostic: sl.diagnostic))
    return
  let manifestsRoot = parsed.workspaceRoot / ".repo" / "manifests"
  let projectFile = manifestsRoot / "projects" /
    (parsed.projectName & ".toml")
  let variantFile = manifestsRoot / "variants" /
    (parsed.projectName & ".toml")
  if fileExists(projectFile):
    result.project = resolveProject(projectFile)
    return
  if fileExists(variantFile):
    result.project = resolveVariant(variantFile)
    return
  raise newException(ValueError,
    "no project or variant named '" & parsed.projectName &
      "' found under '" & manifestsRoot &
      "' (looked for '" & projectFile & "' and '" & variantFile & "')")

proc localHeadOrEmpty(identity: GitToolIdentity; repoPath: string): string =
  ## Best-effort HEAD-SHA query. A failed observation returns the empty
  ## string so the dispatcher can still emit a structured divergence
  ## diagnostic (with ``observed=<empty>``) rather than abort the run.
  let res = queryGitState(headShaQuery(repoPath), identity)
  if res.status == gqsOk:
    res.headSha
  else:
    ""

proc revParse(identity: GitToolIdentity;
              repoPath, refSpec: string): string =
  ## Run ``git -C <repo> rev-parse <ref>`` and return the resolved SHA.
  ## Returns the empty string on failure. The divergence check uses
  ## this both for the local branch tip AND the remote-tracking branch
  ## (typically ``origin/<branch>``) so a local checkout that has
  ## diverged from the manifest's pinned remote tip surfaces correctly.
  if refSpec.len == 0:
    return ""
  let res = execCmdEx(
    quoteShell(identity.binaryPath) & " -C " & quoteShell(repoPath) &
      " rev-parse " & quoteShell(refSpec),
    options = {poStdErrToStdOut, poUsePath})
  if res.exitCode == 0:
    res.output.strip()
  else:
    ""

proc expectedBranchTip(identity: GitToolIdentity;
                       repoPath, branch: string): string =
  ## Resolve the *expected* tip for a branch-pinned manifest. The
  ## divergence check is "does the working tree's HEAD match what the
  ## upstream branch points at" — we therefore consult the
  ## remote-tracking branch first (``refs/remotes/origin/<branch>``
  ## after a fresh clone) and fall back to the local branch only when
  ## no remote-tracking ref exists. Any other arrangement would
  ## misclassify a checkout that has local-only commits beyond the
  ## manifest pin (which is exactly the divergence M9 must surface).
  let remoteTip = revParse(identity, repoPath, "refs/remotes/origin/" & branch)
  if remoteTip.len > 0:
    return remoteTip
  revParse(identity, repoPath, branch)

proc looksLikeSha(value: string): bool =
  ## Heuristic for the branch-vs-SHA divergence test. Git SHA-1s are
  ## 40-character lowercase hex; SHA-256 builds extend to 64. A user
  ## abbreviation of 7-39 hex characters is also accepted so an
  ## explicit short SHA in the manifest is not misclassified as a
  ## branch name.
  if value.len < 7 or value.len > 64:
    return false
  for ch in value:
    if ch notin {'0'..'9', 'a'..'f'}:
      return false
  true

proc classifyExistingRepo(
    identity: GitToolIdentity;
    workspaceRoot: string;
    repo: ResolvedRepo;
    upToDate: var seq[WorkspaceInitUpToDateEntry];
    divergences: var seq[WorkspaceInitDivergenceEntry]) =
  ## A repo directory exists at ``<workspaceRoot>/<repo.path>``. Decide
  ## whether it matches the manifest's declared revision (record as
  ## up-to-date) or diverges (record as a structured divergence). The
  ## milestone explicitly forbids auto-modifying a divergent checkout —
  ## we observe and report.
  let repoPath = workspaceRoot / repo.path
  let headSha = localHeadOrEmpty(identity, repoPath)
  if repo.revision.len == 0:
    # Manifest didn't pin a revision; any non-empty HEAD is treated as
    # up-to-date. An empty HEAD (bare directory? broken clone?) is a
    # divergence so the user fixes it.
    if headSha.len > 0:
      upToDate.add(WorkspaceInitUpToDateEntry(
        name: repo.name, path: repo.path, headSha: headSha))
    else:
      divergences.add(WorkspaceInitDivergenceEntry(
        name: repo.name, path: repo.path,
        expected: "<unspecified>", observed: ""))
    return
  if looksLikeSha(repo.revision):
    if headSha.startsWith(repo.revision) or repo.revision.startsWith(headSha):
      upToDate.add(WorkspaceInitUpToDateEntry(
        name: repo.name, path: repo.path, headSha: headSha))
    else:
      divergences.add(WorkspaceInitDivergenceEntry(
        name: repo.name, path: repo.path,
        expected: repo.revision, observed: headSha))
  else:
    # Branch name. The repo matches when the local HEAD's SHA equals
    # the remote-tracking branch's tip — i.e. ``origin/<branch>``.
    # ``expectedBranchTip`` prefers the remote-tracking ref and falls
    # back to the local branch when no remote-tracking ref exists.
    # Any other state (detached HEAD, ahead of origin, behind origin)
    # is a divergence: the user has work to do.
    let branchTip = expectedBranchTip(identity, repoPath, repo.revision)
    if branchTip.len > 0 and branchTip == headSha:
      upToDate.add(WorkspaceInitUpToDateEntry(
        name: repo.name, path: repo.path, headSha: headSha))
    else:
      divergences.add(WorkspaceInitDivergenceEntry(
        name: repo.name, path: repo.path,
        expected: (if branchTip.len > 0: branchTip else: repo.revision),
        observed: headSha))

proc safeRepoIdSegment(value: string): string =
  for ch in value:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('-')
  if result.len == 0:
    result = "repo"

proc executeWorkspaceInit(args: WorkspaceInitArgs): WorkspaceInitOutcome =
  ## End-to-end driver. Resolves the named project / variant, classifies
  ## each declared repo against the on-disk workspace, schedules a
  ## ``bakWorkspaceVcs.clone`` build plan for the missing ones, then
  ## emits the structured report.
  let resolution = resolveWorkspaceInitProject(args)
  let resolved = resolution.project
  var report: WorkspaceInitReport
  report.project = resolved.projectName
  report.workspaceRoot = args.workspaceRoot
  report.skippedLayers = resolution.skippedLayers
  var cloneFailures = 0

  # M9 requires git tool resolution before we can either query existing
  # checkouts OR schedule a clone. Raising ``EGitToolUnresolved`` here
  # surfaces the M1 structured error directly to the dispatcher.
  let identity = ensureGitToolResolvable(args.toolProvisioning, getEnv("PATH"))
  installGitVcsExecutor()

  var cloneActions: seq[BuildAction]
  var cloneEntries: seq[WorkspaceInitClonedEntry]
  for idx, repo in resolved.repos:
    let absPath = args.workspaceRoot / repo.path
    if dirExists(absPath):
      classifyExistingRepo(identity, args.workspaceRoot, repo,
        report.upToDate, report.divergences)
      continue
    # Missing — schedule a clone. The receipt lives next to the working
    # tree under a hidden ``.repro/workspace/receipts/`` subtree so the
    # action cache has a stable per-repo output path that does not
    # collide with anything inside the repo itself.
    let receiptDir = args.workspaceRoot / ".repro" / "workspace" / "receipts"
    createDir(receiptDir)
    let receiptRel = ".repro" / "workspace" / "receipts" /
      ("clone-" & safeRepoIdSegment(repo.name) & "-" & $idx & ".receipt")
    let cloneId = "workspace-init-clone-" & safeRepoIdSegment(repo.name) &
      "-" & $idx
    var action = gitCloneAction(cloneId, identity,
      remoteUrl = repo.fetchUrl,
      repoPath = repo.path,
      receiptPath = receiptRel,
      revision = repo.revision)
    action.cwd = args.workspaceRoot
    cloneActions.add(action)
    cloneEntries.add(WorkspaceInitClonedEntry(
      name: repo.name, path: repo.path,
      remote: repo.fetchUrl, revision: repo.revision))

  if cloneActions.len > 0:
    let cacheRoot = args.workspaceRoot / ".repro" / "workspace" /
      "engine-cache"
    var config = defaultBuildEngineConfig(cacheRoot)
    config.suppressTrace = true
    let res = runBuild(graph(cloneActions), config)
    # The build engine returns outcomes in completion order. Re-key
    # them by id so we can map each back to its source entry without
    # depending on the engine's emission order.
    var outcomeById = initTable[string, ActionResult]()
    for outcome in res.results:
      outcomeById[outcome.id] = outcome
    for i, action in cloneActions:
      let outcome = outcomeById.getOrDefault(action.id)
      if outcome.status notin {asSucceeded, asCacheHit, asUpToDate}:
        inc cloneFailures
        stderr.writeLine("workspace init: clone failed for " &
          cloneEntries[i].path & ": status=" & $outcome.status &
          " reason=" & outcome.reason &
          (if outcome.stderr.len > 0: " stderr=" & outcome.stderr else: ""))
      else:
        report.cloned.add(cloneEntries[i])

  result.report = report
  result.cloneFailures = cloneFailures

  # M13: record the active workspace branch in .repo/workspace.toml so
  # downstream commands (``repro workspace status``, M14 ``repro branch``,
  # M15 ``repro checkout``) can read it back as a single source of truth.
  # The branch value is the resolver's ``trunk`` (the manifest's
  # documented default branch); when ``trunk`` is empty we fall back to
  # ``defaultRevision``. We only write when we have a meaningful value
  # AND no clone failures (writing on a half-broken init would record a
  # branch the workspace cannot honor). The write is idempotent — if the
  # composer mode already produced a workspace.toml with a branch, this
  # call is a no-op (the writer preserves any pre-existing branch when
  # we pass the same value, and the value comes from the same composed
  # ``resolved.trunk``).
  if cloneFailures == 0:
    let branchValue =
      if resolved.trunk.len > 0: resolved.trunk
      elif resolved.defaultRevision.len > 0: resolved.defaultRevision
      else: ""
    if branchValue.len > 0:
      try:
        writeWorkspaceBranch(args.workspaceRoot,
          project = resolved.projectName, branch = branchValue)
      except WorkspaceManifestParseError as e:
        # A malformed pre-existing workspace.toml shouldn't break init
        # — surface a structured diagnostic on stderr and continue.
        stderr.writeLine(
          "workspace init: could not record active branch: " & e.msg)

proc writeWorkspaceInitReport(report: WorkspaceInitReport) =
  let reportDir = report.workspaceRoot / ".repro" / "workspace"
  createDir(reportDir)
  let reportPath = reportDir / "init-report.json"
  writeFile(reportPath, pretty(report.toJsonNode(), indent = 2) & "\n")

proc runWorkspaceInitCommand*(args: openArray[string]): int =
  ## ``repro workspace init <project-or-variant> [--workspace-root=PATH]
  ## [--tool-provisioning=path|nix|tarball|scoop]``.
  ##
  ## Exit codes (per M9 design):
  ##   - 0 — every missing repo cloned successfully AND no divergences.
  ##   - 1 — at least one clone action failed (e.g. unreachable remote,
  ##         malformed URL, the underlying git tool refused).
  ##   - 2 — there were divergences in pre-existing checkouts. We did
  ##         NOT auto-modify them; the user has work to do. Distinct
  ##         from exit-1 ("init blew up") so scripts can tell the two
  ##         apart.
  let parsed = parseWorkspaceInitArgs(args)
  let outcome = executeWorkspaceInit(parsed)
  writeWorkspaceInitReport(outcome.report)
  for line in renderInitTextLines(outcome.report):
    stdout.writeLine(line)
  if outcome.cloneFailures > 0:
    return 1
  if outcome.report.divergences.len > 0:
    return 2
  0

# ---- M10: `repro workspace sync` ------------------------------------------
#
# The M10 dispatcher mirrors M9's structure: parse argv, resolve the project
# (or compose layers), inspect the local checkout of each ``ResolvedRepo``,
# and emit a structured report. The decision-making (the seven sync corner
# cases from ``Workspace-And-Develop-Mode.md`` §"Sync Corner Cases") is
# delegated to the pure-policy ``planSync`` proc in
# ``repro_workspace_manifests/sync_planner``; this dispatcher's job is to
# gather the per-repo observation and, once the plan is known, drive the
# minimal mutating actions through the M2 ``bakWorkspaceVcs`` executor.
#
# Before any per-repo work the dispatcher fast-forwards the manifest layers
# themselves (via ``refreshManifestLayers``) so the resolver reads the
# freshest manifest data. The same proc is what the M19a auto-refresh hook
# will eventually call.

type
  WorkspaceSyncManifestLayerEntry* = object
    ## One per manifest layer encountered during the pre-sync refresh.
    ## Mirrors ``ManifestLayerRefreshEntry`` 1:1; we keep a separate
    ## CLI-side record so the JSON shape stays stable even if the
    ## refresh helper later adds fields.
    index*: int
    provenance*: string
    layerPath*: string
    status*: string
    beforeSha*: string
    afterSha*: string
    diagnostic*: string

  WorkspaceSyncRepoEntry* = object
    ## One per ``ResolvedRepo`` after sync. ``syncCase`` is the
    ## snake_case tag of the planner's decision; ``action`` is the
    ## scheduled mutating-action tag (``none`` for refuse-and-report or
    ## no-op outcomes); ``executionStatus`` is the post-execution
    ## summary (``noop`` / ``refused`` / ``succeeded`` / ``failed``)
    ## the dispatcher fills in once the plan has run.
    name*: string
    path*: string
    syncCase*: string
    action*: string
    expected*: string
    observed*: string
    branch*: string
    message*: string
    refusalReason*: string
    executionStatus*: string
    executionDiagnostic*: string

  WorkspaceSyncReport* = object
    ## Structured outcome of one ``repro workspace sync`` invocation.
    ## ``project`` carries the ``ResolvedProject.projectName``;
    ## ``workspaceRoot`` is the absolute path of the directory
    ## containing ``.repo/``; ``manifestLayers`` records the
    ## pre-reconciliation refresh; ``repos`` carries the planner's
    ## seven-case classification per declared repo.
    project*: string
    workspaceRoot*: string
    manifestLayers*: seq[WorkspaceSyncManifestLayerEntry]
    repos*: seq[WorkspaceSyncRepoEntry]
    exitCode*: int

  WorkspaceSyncOutcome* = object
    report*: WorkspaceSyncReport

proc toJsonNode*(report: WorkspaceSyncReport): JsonNode =
  result = newJObject()
  result["project"] = %report.project
  result["workspaceRoot"] = %report.workspaceRoot
  var layers = newJArray()
  for entry in report.manifestLayers:
    var obj = newJObject()
    obj["index"] = %entry.index
    obj["provenance"] = %entry.provenance
    obj["layerPath"] = %entry.layerPath
    obj["status"] = %entry.status
    obj["beforeSha"] = %entry.beforeSha
    obj["afterSha"] = %entry.afterSha
    obj["diagnostic"] = %entry.diagnostic
    layers.add(obj)
  result["manifestLayers"] = layers
  var repos = newJArray()
  for entry in report.repos:
    var obj = newJObject()
    obj["name"] = %entry.name
    obj["path"] = %entry.path
    obj["syncCase"] = %entry.syncCase
    obj["action"] = %entry.action
    obj["expected"] = %entry.expected
    obj["observed"] = %entry.observed
    obj["branch"] = %entry.branch
    obj["message"] = %entry.message
    obj["refusalReason"] = %entry.refusalReason
    obj["executionStatus"] = %entry.executionStatus
    obj["executionDiagnostic"] = %entry.executionDiagnostic
    repos.add(obj)
  result["repos"] = repos
  result["exitCode"] = %report.exitCode

proc renderSyncTextLines*(report: WorkspaceSyncReport): seq[string] =
  for entry in report.manifestLayers:
    result.add("workspace sync: manifest-layer " & entry.provenance &
      " status=" & entry.status &
      (if entry.beforeSha.len > 0 and entry.afterSha.len > 0 and
          entry.beforeSha != entry.afterSha:
        " " & entry.beforeSha & " → " & entry.afterSha
       else: ""))
  for entry in report.repos:
    var line = "workspace sync: " & entry.path & " case=" & entry.syncCase &
      " action=" & entry.action
    if entry.executionStatus.len > 0 and entry.executionStatus != "noop":
      line.add(" → " & entry.executionStatus)
    if entry.refusalReason.len > 0:
      line.add(" (" & entry.refusalReason & ")")
    elif entry.message.len > 0:
      line.add(" — " & entry.message)
    result.add(line)

type
  WorkspaceSyncArgs = object
    workspaceRoot: string
    projectName: string
    toolProvisioning: ToolProvisioningMode

proc parseWorkspaceSyncArgs(args: openArray[string]): WorkspaceSyncArgs =
  ## ``repro workspace sync`` argv parser. Unlike M9's ``init`` there is
  ## no required positional: sync operates on the existing workspace
  ## root. An optional positional ``<project>`` is accepted so the
  ## non-composer (M6 / M7) path still works in a workspace that lacks
  ## a ``.repo/workspace.toml`` — the milestone spec says sync works on
  ## "the existing workspace", which in single-project mode requires
  ## the project name to find ``projects/<name>.toml``.
  result.workspaceRoot = ""
  result.toolProvisioning = tpmPathOnly
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--workspace-root" or arg.startsWith("--workspace-root="):
      result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
    elif arg == "--tool-provisioning" or
        arg.startsWith("--tool-provisioning="):
      result.toolProvisioning = parseToolProvisioning(
        valueFromFlag(args, i, "--tool-provisioning"))
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported `repro workspace sync` flag: " & arg)
    elif result.projectName.len == 0:
      result.projectName = arg
    else:
      raise newException(ValueError,
        "unexpected positional argument to `repro workspace sync`: " & arg)
    inc i
  if result.workspaceRoot.len == 0:
    result.workspaceRoot = getCurrentDir()
  result.workspaceRoot = absolutePath(result.workspaceRoot)

proc resolveWorkspaceSyncProject(parsed: WorkspaceSyncArgs): ResolvedProject =
  ## Same dispatch rule as M9: prefer ``.repo/workspace.toml`` when it
  ## declares at least one ``[[manifest]]`` layer (composer mode),
  ## otherwise look up the named project / variant under
  ## ``.repo/manifests/``. A metadata-only workspace.toml (M13 — only
  ## carrying ``[workspace].project`` / ``[workspace].branch``) is
  ## treated as single-project mode because the composer requires
  ## manifest layers. A missing workspace.toml AND a missing project
  ## argument is a structured error.
  let workspaceToml = parsed.workspaceRoot / ".repo" / "workspace.toml"
  if isCompositionalWorkspaceToml(parsed.workspaceRoot):
    return composeManifestLayersFromFile(workspaceToml)
  if parsed.projectName.len == 0:
    # If a metadata-only workspace.toml records the project name, we
    # can still resolve in single-project mode without the user having
    # to repeat the project on the command line. The M5 reader has
    # already validated that the file is well-formed by the time we
    # get here (``isCompositionalWorkspaceToml`` parses it and treats
    # any parse error as "fall back to single-project mode").
    if fileExists(workspaceToml):
      try:
        let recordedProject =
          readWorkspaceLocal(absolutePath(workspaceToml)).workspace.project
        if recordedProject.len > 0:
          var withProject = parsed
          withProject.projectName = recordedProject
          return resolveWorkspaceSyncProject(withProject)
      except WorkspaceManifestParseError:
        discard
    raise newException(ValueError,
      "`repro workspace sync` requires either `.repo/workspace.toml` " &
        "or a <project> argument; neither was present at " &
        parsed.workspaceRoot)
  let manifestsRoot = parsed.workspaceRoot / ".repo" / "manifests"
  let projectFile = manifestsRoot / "projects" /
    (parsed.projectName & ".toml")
  let variantFile = manifestsRoot / "variants" /
    (parsed.projectName & ".toml")
  if fileExists(projectFile):
    return resolveProject(projectFile)
  if fileExists(variantFile):
    return resolveVariant(variantFile)
  raise newException(ValueError,
    "no project or variant named '" & parsed.projectName &
      "' found under '" & manifestsRoot &
      "' (looked for '" & projectFile & "' and '" & variantFile & "')")

proc gitRunPlain(identity: GitToolIdentity;
                 args: openArray[string]): tuple[code: int; output: string] =
  ## Tiny ``execCmdEx`` wrapper used by the sync observation gatherer.
  ## Shares the same shape as ``revParse`` above but takes an argv so
  ## callers don't have to quoteShell every arg.
  var cmd = quoteShell(identity.binaryPath)
  for arg in args:
    cmd.add(" ")
    cmd.add(quoteShell(arg))
  let res = execCmdEx(cmd, options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)

proc observeRepoForSync(identity: GitToolIdentity;
                        repoPath: string;
                        resolved: ResolvedRepo): RepoSyncObservation =
  ## Gather everything the M10 planner needs about ONE checkout. A
  ## missing directory short-circuits with ``exists=false``; every
  ## other observation field is filled in best-effort (a failed probe
  ## leaves the field empty so the planner's tolerant-compare logic
  ## degrades to "divergent_feature_branch" rather than crashing).
  if not dirExists(repoPath / ".git"):
    result.exists = false
    return
  result.exists = true
  let headRes = queryGitState(headShaQuery(repoPath), identity)
  if headRes.status == gqsOk:
    result.headSha = headRes.headSha
  let cleanRes = queryGitState(isCleanQuery(repoPath), identity)
  if cleanRes.status == gqsOk:
    result.isClean = cleanRes.isClean
  else:
    # Treat an un-probable status as "not clean" — refuse-and-report
    # is the safer choice when we cannot prove cleanliness.
    result.isClean = false

  # Current branch (empty when detached). Use ``symbolic-ref --short``
  # so the value is the bare branch name like ``main``.
  let branchRes = gitRunPlain(identity,
    ["-C", repoPath, "symbolic-ref", "--short", "-q", "HEAD"])
  if branchRes.code == 0:
    result.currentBranch = branchRes.output.strip()

  # Branch tips (local + remote-tracking).
  if result.currentBranch.len > 0:
    result.localBranchTip = revParse(identity, repoPath,
      "refs/heads/" & result.currentBranch)
    result.remoteBranchTip = revParse(identity, repoPath,
      "refs/remotes/origin/" & result.currentBranch)

  # Where does the manifest's revision actually point in this clone?
  # SHA pin → itself; branch pin → ``origin/<branch>`` (matches M9's
  # ``expectedBranchTip``).
  if resolved.revision.len > 0:
    if looksLikeSha(resolved.revision):
      result.lockedRevisionTip = resolved.revision
    else:
      result.lockedRevisionTip = expectedBranchTip(identity, repoPath,
        resolved.revision)

  # Unpublished commits: the M2 ``isPublished`` query already answers
  # "is HEAD on any remote tracking branch". We also fall back to the
  # local-vs-remote tip compare when ``isPublished`` cannot be probed
  # (e.g. brand-new branch with no upstream).
  let pubRes = queryGitState(
    isPublishedQuery(repoPath, "origin"), identity)
  if pubRes.status == gqsOk:
    result.hasUnpublishedCommits = not pubRes.isPublished
  else:
    # If we can't tell published-vs-not, only flag when there is a
    # concrete local-vs-remote disagreement we can attribute to local
    # work (i.e. local tip strictly ahead of remote tip).
    if result.remoteBranchTip.len > 0 and result.headSha.len > 0 and
        result.remoteBranchTip != result.headSha:
      # ``hasUnpublishedCommits`` is "local has commits beyond remote".
      # The planner does not require an exact ahead-count; it only
      # needs to know that the operator owns work we shouldn't touch.
      let ancestorRes = gitRunPlain(identity, ["-C", repoPath,
        "merge-base", "--is-ancestor", result.headSha, result.remoteBranchTip])
      result.hasUnpublishedCommits = ancestorRes.code != 0

proc executeSyncPlanForRepo(
    identity: GitToolIdentity;
    workspaceRoot: string;
    resolved: ResolvedRepo;
    decision: RepoSyncDecision;
    repoIdx: int): tuple[status: string; diagnostic: string] =
  ## Translate one planner decision into a mutating ``bakWorkspaceVcs``
  ## invocation. Returns the post-execution status string the JSON
  ## report carries (``noop`` / ``refused`` / ``succeeded`` / ``failed``)
  ## plus a diagnostic when ``failed``.
  case decision.action
  of saNone:
    if decision.syncCase in {scDirty, scLocallyUnpublished}:
      return ("refused", decision.refusalReason)
    return ("noop", "")
  of saClone:
    let receiptDir = workspaceRoot / ".repro" / "workspace" / "receipts"
    createDir(receiptDir)
    let receiptRel = ".repro" / "workspace" / "receipts" /
      ("sync-clone-" & safeRepoIdSegment(resolved.name) & "-" &
        $repoIdx & ".receipt")
    let actionId = "workspace-sync-clone-" &
      safeRepoIdSegment(resolved.name) & "-" & $repoIdx
    var action = gitCloneAction(actionId, identity,
      remoteUrl = resolved.fetchUrl,
      repoPath = resolved.path,
      receiptPath = receiptRel,
      revision = resolved.revision)
    action.cwd = workspaceRoot
    let cacheRoot = workspaceRoot / ".repro" / "workspace" /
      "engine-cache"
    var config = defaultBuildEngineConfig(cacheRoot)
    config.suppressTrace = true
    let res = runBuild(graph([action]), config)
    if res.results.len == 0:
      return ("failed", "build engine returned no results for clone action")
    let outcome = res.results[0]
    if outcome.status notin {asSucceeded, asCacheHit, asUpToDate}:
      return ("failed", "clone status=" & $outcome.status &
        " reason=" & outcome.reason &
        (if outcome.stderr.len > 0: " stderr=" & outcome.stderr else: ""))
    return ("succeeded", "")
  of saFetchFastForward:
    # The dispatcher already issued a pre-classification fetch against
    # ``origin`` so the remote-tracking ref is current. All that's
    # left here is the merge. The planner established that HEAD is an
    # ancestor of ``origin/<branch>`` (so the merge is a strict
    # fast-forward) and that the working tree is clean (so the merge
    # cannot disturb operator state). ``merge --ff-only`` is the safe
    # primitive.
    let repoAbsPath = workspaceRoot / resolved.path
    let mergeRes = gitRunPlain(identity, ["-C", repoAbsPath,
      "merge", "--ff-only", "refs/remotes/origin/" & decision.branch])
    if mergeRes.code != 0:
      return ("failed", "merge --ff-only refused: " &
        mergeRes.output.strip())
    return ("succeeded", "")
  of saAttachBranch:
    # Detached HEAD at the locked revision — re-attach by ``git switch
    # --detach=false`` to the manifest's pinned branch. We assume the
    # manifest names a branch (the detached case only applies when the
    # locked tip matches HEAD; the planner already established that
    # match holds). If the manifest pins a SHA we fall back to
    # ``checkout -B`` on a synthetic branch derived from the SHA — but
    # the seven-case spec explicitly limits ``attach_branch`` to
    # branch-pinned manifests, so production hits the simple arm.
    let repoAbsPath = workspaceRoot / resolved.path
    let targetBranch =
      if resolved.revision.len > 0 and not looksLikeSha(resolved.revision):
        resolved.revision
      else:
        "main"
    let switchRes = gitRunPlain(identity, ["-C", repoAbsPath,
      "switch", targetBranch])
    if switchRes.code != 0:
      return ("failed", "git switch '" & targetBranch & "' refused: " &
        switchRes.output.strip())
    return ("succeeded", "")

proc executeWorkspaceSync(args: WorkspaceSyncArgs): WorkspaceSyncOutcome =
  ## End-to-end driver. (1) Refresh manifest layers so the composer
  ## reads the freshest manifest data. (2) Resolve the project / compose
  ## layers. (3) Gather an observation for every declared repo. (4) Run
  ## the planner. (5) Execute the resulting actions through M2's
  ## executor. (6) Emit the structured report.
  var report: WorkspaceSyncReport
  report.workspaceRoot = args.workspaceRoot

  # Step 1: manifest-layer refresh.
  let refresh = refreshManifestLayers(args.workspaceRoot)
  for entry in refresh.layers:
    report.manifestLayers.add(WorkspaceSyncManifestLayerEntry(
      index: entry.index,
      provenance: entry.provenance,
      layerPath: entry.layerPath,
      status: manifestLayerStatusTag(entry.status),
      beforeSha: entry.beforeSha,
      afterSha: entry.afterSha,
      diagnostic: entry.diagnostic))

  # Step 2: resolve (or compose) the project.
  let resolved = resolveWorkspaceSyncProject(args)
  report.project = resolved.projectName

  # Step 3: resolve the git identity once.
  let identity = ensureGitToolResolvable(
    args.toolProvisioning, getEnv("PATH"))
  installGitVcsExecutor()

  # Step 3a: pre-fetch every existing repo so the post-fetch
  # ``origin/<branch>`` ref reflects the remote's current tip BEFORE
  # the planner classifies. Without this step, a clone that's strictly
  # behind a now-advanced ``origin/main`` would be misclassified as
  # "clean_at_locked_revision" — the local view of the lock would
  # match HEAD because nobody told the local clone the upstream had
  # advanced.
  #
  # A pre-fetch on a dirty / locally-unpublished checkout is safe: it
  # only updates ``refs/remotes/origin/*``, never the working tree
  # itself. Refuse-and-report classifications are still made AFTER
  # this pass, so the operator's working state is preserved.
  for repo in resolved.repos:
    let repoPath = args.workspaceRoot / repo.path
    if dirExists(repoPath / ".git"):
      discard gitRunPlain(identity, ["-C", repoPath, "fetch",
        "--quiet", "origin"])

  # Step 3b: observe each repo (now with fresh remote-tracking refs).
  # Read the workspace metadata once and propagate it onto every
  # observation so the M16 planner arm has the started flag + the
  # marked branch name when classifying each repo.
  var featureStarted = false
  var workspaceBranchName = ""
  try:
    featureStarted = readWorkspaceFeatureStarted(args.workspaceRoot)
    let recordedBranch = readWorkspaceBranch(args.workspaceRoot)
    if recordedBranch.isSome:
      workspaceBranchName = recordedBranch.get()
  except WorkspaceManifestParseError:
    # Malformed metadata: degrade gracefully — the M10 baseline policy
    # still applies (the started-mark is just not honored).
    featureStarted = false
    workspaceBranchName = ""
  var observations: seq[RepoSyncObservation]
  for repo in resolved.repos:
    let repoPath = args.workspaceRoot / repo.path
    var obs = observeRepoForSync(identity, repoPath, repo)
    obs.workspaceFeatureStarted = featureStarted
    obs.workspaceBranch = workspaceBranchName
    observations.add(obs)

  # Step 4: planner.
  let planned = planSync(resolved.repos, observations)

  # Step 5: execute.
  var anyRefusal = false
  var anyFailure = false
  for repoIdx, decision in planned.report.decisions:
    let resolvedRepo = resolved.repos[repoIdx]
    let (status, diagnostic) = executeSyncPlanForRepo(
      identity, args.workspaceRoot, resolvedRepo, decision, repoIdx)
    if status == "refused":
      anyRefusal = true
    elif status == "failed":
      anyFailure = true
    report.repos.add(WorkspaceSyncRepoEntry(
      name: decision.name,
      path: decision.path,
      syncCase: syncCaseTag(decision.syncCase),
      action: syncActionTag(decision.action),
      expected: decision.expected,
      observed: decision.observed,
      branch: decision.branch,
      message: decision.message,
      refusalReason: decision.refusalReason,
      executionStatus: status,
      executionDiagnostic: diagnostic))

  # Step 6: exit code.
  if anyFailure:
    report.exitCode = 1
  elif anyRefusal:
    report.exitCode = 2
  else:
    report.exitCode = 0
  result.report = report

proc writeWorkspaceSyncReport(report: WorkspaceSyncReport) =
  let reportDir = report.workspaceRoot / ".repro" / "workspace"
  createDir(reportDir)
  let reportPath = reportDir / "sync-report.json"
  writeFile(reportPath, pretty(report.toJsonNode(), indent = 2) & "\n")

proc runWorkspaceSyncCommand*(args: openArray[string]): int =
  ## ``repro workspace sync [<project>] [--workspace-root=PATH]
  ## [--tool-provisioning=path|nix|tarball|scoop]``.
  ##
  ## Exit codes (per M10 design):
  ##   - 0 — every repo is at its locked revision, was cleanly
  ##         fast-forwarded, was re-attached to its branch, was
  ##         cloned successfully, or is a divergent-feature-branch
  ##         report-only case.
  ##   - 1 — at least one mutating action (clone, fetch, fast-forward,
  ##         branch attach) failed.
  ##   - 2 — at least one repo was in a refuse-and-report state
  ##         (``dirty`` or ``locally_unpublished``). The operator has
  ##         manual work to do. Distinct from exit-1 ("sync blew up")
  ##         so scripts can tell the two apart.
  let parsed = parseWorkspaceSyncArgs(args)
  let outcome = executeWorkspaceSync(parsed)
  writeWorkspaceSyncReport(outcome.report)
  for line in renderSyncTextLines(outcome.report):
    stdout.writeLine(line)
  outcome.report.exitCode

# ---- M11: `repro workspace lock` ------------------------------------------
#
# Generate ``locks/<project>/<trigger>-<short-sha>.toml`` from the live
# VCS state of the workspace, per Workspace-Manifests.md
# §"locks/<project>/<sha>.toml". The same code path is invoked by the
# M16 post-commit hook with an explicit ``--sha=<commit>`` so a fresh
# commit lands as its own lock entry.
#
# Steady-state semantics:
#   1. Resolve the project (single-project M6 path) or compose layers
#      (M8 path), exactly as M9/M10 do. The composer returns the live
#      ``ResolvedRepo`` list — the same tuple the planner already
#      consumes.
#   2. Pick the manifest layer that will OWN the lock file. The lock
#      lives in the manifest repo (per spec), and a workspace with
#      multiple layers picks the FIRST layer (the "anchor" layer —
#      typically the public manifest). The operator can override with
#      ``--manifest-layer-root=PATH`` to target an internal/private
#      layer instead.
#   3. For every declared repo, gather a fresh observation: HEAD SHA
#      via the M2 ``headShaQuery`` adapter; clean/dirty via
#      ``isCleanQuery``; current branch via ``symbolic-ref --short``.
#      A repo whose checkout is dirty short-circuits to refuse-and-
#      report (exit 2). A locked snapshot of a dirty tree would lie:
#      its recorded SHA wouldn't reproduce the working tree.
#   4. Build the in-memory ``WorkspaceLockFile`` and the matching
#      ``WorkspaceLockIndexEntry``, write the lock TOML, update the
#      index, emit the structured stdout + ``lock-report.json``.
#
# Exit codes:
#   0 — lock + index written (or already up-to-date).
#   1 — IO failure, VCS query failure, or a missing trigger repo.
#   2 — at least one declared checkout is dirty.

type
  WorkspaceLockRepoEntry* = object
    ## One per locked repo in the JSON report. The ``branch`` field
    ## is the advisory current branch (empty when the working tree is
    ## detached); the lock TOML carries the same value.
    name*: string
    path*: string
    remote*: string
    revision*: string
    branch*: string

  WorkspaceLockDirtyEntry* = object
    ## One per repo whose live checkout was DIRTY when the lock was
    ## attempted. Carried separately from the locked entries so the
    ## report has a per-case enumeration of refuse-and-report
    ## outcomes.
    name*: string
    path*: string
    reason*: string

  WorkspaceLockReport* = object
    ## Structured outcome of one ``repro workspace lock`` invocation.
    ## ``lockFilePath`` and ``indexFilePath`` are the absolute paths
    ## the writer landed on; ``triggerRepo`` + ``triggerSha`` reflect
    ## the (repo, commit) tuple that anchored the lock filename.
    ## ``replacedExistingEntry`` is true when the index updater
    ## overwrote a pre-existing entry rather than appending — the
    ## idempotent re-lock case.
    project*: string
    workspaceRoot*: string
    manifestLayerRoot*: string
    lockFilePath*: string
    indexFilePath*: string
    triggerRepo*: string
    triggerSha*: string
    createdAt*: string
    workspaceBranch*: string
    replacedExistingEntry*: bool
    repos*: seq[WorkspaceLockRepoEntry]
    dirty*: seq[WorkspaceLockDirtyEntry]
    exitCode*: int

  WorkspaceLockOutcome* = object
    report*: WorkspaceLockReport

proc toJsonNode*(report: WorkspaceLockReport): JsonNode =
  result = newJObject()
  result["project"] = %report.project
  result["workspaceRoot"] = %report.workspaceRoot
  result["manifestLayerRoot"] = %report.manifestLayerRoot
  result["lockFilePath"] = %report.lockFilePath
  result["indexFilePath"] = %report.indexFilePath
  result["triggerRepo"] = %report.triggerRepo
  result["triggerSha"] = %report.triggerSha
  result["createdAt"] = %report.createdAt
  result["workspaceBranch"] = %report.workspaceBranch
  result["replacedExistingEntry"] = %report.replacedExistingEntry
  var repos = newJArray()
  for entry in report.repos:
    var obj = newJObject()
    obj["name"] = %entry.name
    obj["path"] = %entry.path
    obj["remote"] = %entry.remote
    obj["revision"] = %entry.revision
    obj["branch"] = %entry.branch
    repos.add(obj)
  result["repos"] = repos
  var dirty = newJArray()
  for entry in report.dirty:
    var obj = newJObject()
    obj["name"] = %entry.name
    obj["path"] = %entry.path
    obj["reason"] = %entry.reason
    dirty.add(obj)
  result["dirty"] = dirty
  result["exitCode"] = %report.exitCode

proc renderLockTextLines*(report: WorkspaceLockReport): seq[string] =
  if report.exitCode == 0:
    result.add("workspace lock: wrote " & report.lockFilePath &
      " (trigger=" & report.triggerRepo & "@" &
      report.triggerSha & ")")
    for entry in report.repos:
      result.add("workspace lock: locked " & entry.path & " @ " &
        entry.revision &
        (if entry.branch.len > 0: " (branch " & entry.branch & ")" else: ""))
    if report.replacedExistingEntry:
      result.add("workspace lock: replaced existing index entry for (" &
        report.triggerRepo & ", " & report.triggerSha & ")")
  for entry in report.dirty:
    result.add("workspace lock: refused — '" & entry.path &
      "' is dirty (" & entry.reason & ")")

type
  WorkspaceLockArgs = object
    workspaceRoot: string
    projectName: string
    manifestLayerRoot: string
    triggerRepo: string
    triggerSha: string
    toolProvisioning: ToolProvisioningMode

proc parseWorkspaceLockArgs(args: openArray[string]): WorkspaceLockArgs =
  ## ``repro workspace lock`` argv parser. The single optional
  ## positional is the project name (only required when no
  ## ``.repo/workspace.toml`` is present — same dispatch rule as
  ## M10's sync command). Optional flags:
  ##   ``--workspace-root=PATH``
  ##   ``--manifest-layer-root=PATH``
  ##   ``--sha=SHA``           — explicit trigger commit (M16 hook)
  ##   ``--trigger-repo=NAME``  — explicit trigger repo
  ##   ``--tool-provisioning=path|nix|tarball|scoop``
  result.workspaceRoot = ""
  result.toolProvisioning = tpmPathOnly
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--workspace-root" or arg.startsWith("--workspace-root="):
      result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
    elif arg == "--manifest-layer-root" or
        arg.startsWith("--manifest-layer-root="):
      result.manifestLayerRoot = valueFromFlag(args, i,
        "--manifest-layer-root")
    elif arg == "--sha" or arg.startsWith("--sha="):
      result.triggerSha = valueFromFlag(args, i, "--sha")
    elif arg == "--trigger-repo" or arg.startsWith("--trigger-repo="):
      result.triggerRepo = valueFromFlag(args, i, "--trigger-repo")
    elif arg == "--tool-provisioning" or
        arg.startsWith("--tool-provisioning="):
      result.toolProvisioning = parseToolProvisioning(
        valueFromFlag(args, i, "--tool-provisioning"))
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported `repro workspace lock` flag: " & arg)
    elif result.projectName.len == 0:
      result.projectName = arg
    else:
      raise newException(ValueError,
        "unexpected positional argument to `repro workspace lock`: " & arg)
    inc i
  if result.workspaceRoot.len == 0:
    result.workspaceRoot = getCurrentDir()
  result.workspaceRoot = absolutePath(result.workspaceRoot)
  if result.manifestLayerRoot.len > 0:
    result.manifestLayerRoot = absolutePath(result.manifestLayerRoot)

proc resolveWorkspaceLockProject(parsed: WorkspaceLockArgs):
    tuple[resolved: ResolvedProject; workspaceLocal: Option[WorkspaceLocal]] =
  ## Same dispatch rule as M10: prefer ``.repo/workspace.toml`` when it
  ## declares at least one ``[[manifest]]`` layer (composer mode),
  ## otherwise look up the named project / variant under
  ## ``.repo/manifests/``. A metadata-only workspace.toml (M13) routes
  ## to single-project mode. Also returns the parsed
  ## ``WorkspaceLocal`` (when composer mode applies) so the caller can
  ## pick the anchor manifest layer for the lock destination.
  let workspaceToml = parsed.workspaceRoot / ".repo" / "workspace.toml"
  if isCompositionalWorkspaceToml(parsed.workspaceRoot):
    let absToml = absolutePath(workspaceToml)
    let workspaceLocal = readWorkspaceLocal(absToml)
    let resolved = composeManifestLayers(
      workspaceLocal, parsed.workspaceRoot, absToml)
    return (resolved, some(workspaceLocal))
  if parsed.projectName.len == 0:
    # Allow a metadata-only workspace.toml to supply the project name.
    if fileExists(workspaceToml):
      try:
        let recordedProject =
          readWorkspaceLocal(absolutePath(workspaceToml)).workspace.project
        if recordedProject.len > 0:
          var withProject = parsed
          withProject.projectName = recordedProject
          return resolveWorkspaceLockProject(withProject)
      except WorkspaceManifestParseError:
        discard
    raise newException(ValueError,
      "`repro workspace lock` requires either `.repo/workspace.toml` " &
        "or a <project> argument; neither was present at " &
        parsed.workspaceRoot)
  let manifestsRoot = parsed.workspaceRoot / ".repo" / "manifests"
  let projectFile = manifestsRoot / "projects" /
    (parsed.projectName & ".toml")
  let variantFile = manifestsRoot / "variants" /
    (parsed.projectName & ".toml")
  if fileExists(projectFile):
    return (resolveProject(projectFile), none(WorkspaceLocal))
  if fileExists(variantFile):
    return (resolveVariant(variantFile), none(WorkspaceLocal))
  raise newException(ValueError,
    "no project or variant named '" & parsed.projectName &
      "' found under '" & manifestsRoot &
      "' (looked for '" & projectFile & "' and '" & variantFile & "')")

proc pickManifestLayerRoot(parsed: WorkspaceLockArgs;
                           workspaceLocal: Option[WorkspaceLocal]): string =
  ## Resolve the directory that will OWN the lock file. Priority:
  ##   1. The explicit ``--manifest-layer-root`` flag (M16 callers,
  ##      multi-tier setups).
  ##   2. The first ``[[manifest]]`` layer in
  ##      ``.repo/workspace.toml`` (composer mode). For ``local_path``
  ##      layers the path is taken verbatim (relative to the
  ##      workspace root); for ``url`` layers it's the on-disk
  ##      checkout the composer materialised at
  ##      ``<workspaceRoot>/.repo/manifests-<i>-<sanitized>``.
  ##   3. ``<workspaceRoot>/.repo/manifests`` (single-project mode,
  ##      matching M9/M10's resolver dispatch).
  if parsed.manifestLayerRoot.len > 0:
    return parsed.manifestLayerRoot
  if workspaceLocal.isSome:
    let local = workspaceLocal.get()
    if local.manifest.len > 0:
      let first = local.manifest[0]
      if first.local_path.isSome and first.local_path.get().len > 0:
        let raw = first.local_path.get()
        if isAbsolute(raw):
          return raw
        return parsed.workspaceRoot / raw
      if first.url.isSome and first.url.get().len > 0:
        # Mirror the composer's directory-naming convention so the
        # lock lands inside the same on-disk checkout the composer
        # acquired the layer at.
        let sanitizedSegments = block:
          var raw1 = ""
          for ch in first.url.get():
            case ch
            of 'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_': raw1.add(ch)
            else: raw1.add('-')
          var collapsed = ""
          var prevDash = false
          for ch in raw1:
            if ch == '-':
              if not prevDash: collapsed.add(ch)
              prevDash = true
            else:
              collapsed.add(ch)
              prevDash = false
          if collapsed.len > 80:
            collapsed.setLen(80)
          collapsed.strip(chars = {'-'},
            leading = true, trailing = true)
        let suffix =
          if sanitizedSegments.len > 0: sanitizedSegments
          else: "layer"
        return parsed.workspaceRoot / ".repo" /
          ("manifests-0-" & suffix)
  parsed.workspaceRoot / ".repo" / "manifests"

proc pickTriggerRepo(resolved: ResolvedProject;
                     explicit: string): ResolvedRepo =
  ## Choose the repo whose HEAD anchors the lock filename. The
  ## explicit ``--trigger-repo=NAME`` flag wins; otherwise default to
  ## the repo whose ``name`` matches the project name (the
  ## "project-named anchor" pattern the spec example uses —
  ## ``[[repo]] name = "reprobuild"`` in the ``reprobuild`` project
  ## anchors lock files at ``locks/reprobuild/reprobuild-<sha>.toml``).
  ## If no name match exists we fall back to the first declared repo.
  if explicit.len > 0:
    for repo in resolved.repos:
      if repo.name == explicit:
        return repo
    raise newException(ValueError,
      "trigger repo '" & explicit &
        "' is not declared in project '" & resolved.projectName & "'")
  for repo in resolved.repos:
    if repo.name == resolved.projectName:
      return repo
  if resolved.repos.len == 0:
    raise newException(ValueError,
      "project '" & resolved.projectName &
        "' declares no repos; cannot pick a trigger anchor")
  resolved.repos[0]

proc executeWorkspaceLock(args: WorkspaceLockArgs): WorkspaceLockOutcome =
  ## End-to-end driver. (1) Resolve the project / compose layers.
  ## (2) Pick the manifest layer that owns the lock. (3) Gather
  ## live HEAD-SHA + clean/dirty + current-branch observations for
  ## every declared repo. (4) Refuse on any dirty checkout. (5)
  ## Build the lock model + index entry. (6) Write both files and
  ## emit the structured report.
  var report: WorkspaceLockReport
  report.workspaceRoot = args.workspaceRoot

  let (resolved, workspaceLocal) = resolveWorkspaceLockProject(args)
  report.project = resolved.projectName

  let manifestLayerRoot = pickManifestLayerRoot(args, workspaceLocal)
  report.manifestLayerRoot = manifestLayerRoot

  let identity = ensureGitToolResolvable(
    args.toolProvisioning, getEnv("PATH"))
  installGitVcsExecutor()

  # Observation pass. We gather all three values for every repo in
  # one walk so the dirty refusal can land alongside the trigger-
  # resolution check below.
  var headShas = initTable[string, string]()
  var currentBranches = initTable[string, string]()
  var dirtyEntries: seq[WorkspaceLockDirtyEntry]
  for repo in resolved.repos:
    let repoPath = args.workspaceRoot / repo.path
    if not dirExists(repoPath / ".git"):
      raise newException(ValueError,
        "repo '" & repo.path &
          "' has no on-disk checkout at '" & repoPath &
          "'; run `repro workspace init` or `repro workspace sync` first")
    let headRes = queryGitState(headShaQuery(repoPath), identity)
    if headRes.status != gqsOk:
      raise newException(ValueError,
        "could not query HEAD SHA for repo '" & repo.path &
          "': " & headRes.diagnostic)
    headShas[repo.path] = headRes.headSha
    let cleanRes = queryGitState(isCleanQuery(repoPath), identity)
    let isClean =
      if cleanRes.status == gqsOk: cleanRes.isClean
      else: false
    if not isClean:
      let reason =
        if cleanRes.status != gqsOk:
          "clean/dirty probe failed: " & cleanRes.diagnostic
        else:
          "working tree has uncommitted changes"
      dirtyEntries.add(WorkspaceLockDirtyEntry(
        name: repo.name, path: repo.path, reason: reason))
    let branchRes = gitRunPlain(identity,
      ["-C", repoPath, "symbolic-ref", "--short", "-q", "HEAD"])
    if branchRes.code == 0:
      let branch = branchRes.output.strip()
      if branch.len > 0:
        currentBranches[repo.path] = branch

  # Refuse-and-report path: a lock at a dirty tree would lie about
  # what the recorded SHA reproduces.
  if dirtyEntries.len > 0:
    report.dirty = dirtyEntries
    report.exitCode = 2
    result.report = report
    return

  let triggerRepo = pickTriggerRepo(resolved, args.triggerRepo)
  let triggerSha =
    if args.triggerSha.len > 0: args.triggerSha
    else: headShas[triggerRepo.path]
  if triggerSha.len == 0:
    raise newException(ValueError,
      "could not determine trigger SHA for repo '" &
        triggerRepo.name & "' at path '" & triggerRepo.path & "'")

  let createdAt = isoTimestampNow()
  let createdBy = "repro workspace lock"
  var workspaceBranch = ""
  if workspaceLocal.isSome and workspaceLocal.get().workspace.branch.isSome:
    workspaceBranch = workspaceLocal.get().workspace.branch.get()
  elif resolved.trunk.len > 0:
    workspaceBranch = resolved.trunk

  var lock = buildLockFromLiveState(
    project = resolved.projectName,
    workspaceBranch = workspaceBranch,
    createdAt = createdAt,
    createdBy = createdBy,
    resolved = resolved.repos,
    headShasByPath = headShas,
    currentBranchesByPath = currentBranches)

  let lockPath = lockFilePath(manifestLayerRoot, resolved.projectName,
    triggerRepo.name, triggerSha)
  writeLockFile(lock, lockPath)
  report.lockFilePath = lockPath

  let indexPath = lockIndexPath(manifestLayerRoot, resolved.projectName)
  let indexUpdate = updateLockIndex(indexPath,
    WorkspaceLockIndexEntry(
      triggerRepo: triggerRepo.name,
      triggerSha: triggerSha,
      lockFile: lockFileRepoRelativePath(resolved.projectName,
        triggerRepo.name, triggerSha),
      createdAt: createdAt))
  report.indexFilePath = indexPath
  report.replacedExistingEntry = indexUpdate.replaced
  report.triggerRepo = triggerRepo.name
  report.triggerSha = triggerSha
  report.createdAt = createdAt
  report.workspaceBranch = workspaceBranch

  for entry in lock.repos:
    report.repos.add(WorkspaceLockRepoEntry(
      name: entry.name,
      path: entry.path,
      remote: entry.remoteName,
      revision: entry.revision,
      branch: entry.branch))
  report.exitCode = 0
  result.report = report

proc writeWorkspaceLockReport(report: WorkspaceLockReport) =
  let reportDir = report.workspaceRoot / ".repro" / "workspace"
  createDir(reportDir)
  let reportPath = reportDir / "lock-report.json"
  writeFile(reportPath, pretty(report.toJsonNode(), indent = 2) & "\n")

proc runWorkspaceLockCommand*(args: openArray[string]): int =
  ## ``repro workspace lock [<project>] [--workspace-root=PATH]
  ## [--manifest-layer-root=PATH] [--sha=SHA] [--trigger-repo=NAME]
  ## [--tool-provisioning=path|nix|tarball|scoop]``.
  ##
  ## Exit codes (per M11 design):
  ##   - 0 — lock TOML written; index updated.
  ##   - 1 — IO failure, VCS query failure, or a mis-specified
  ##         trigger repo / SHA. Distinct from refuse-and-report.
  ##   - 2 — at least one declared repo has a dirty working tree.
  ##         The lock would lie about what the recorded SHA
  ##         reproduces; the operator must commit, stash, or
  ##         discard first.
  let parsed = parseWorkspaceLockArgs(args)
  let outcome = executeWorkspaceLock(parsed)
  writeWorkspaceLockReport(outcome.report)
  for line in renderLockTextLines(outcome.report):
    stdout.writeLine(line)
  outcome.report.exitCode

# ---- M19: post-commit lock refresh (best-effort) -------------------------
#
# The M17-installed post-commit hook dispatcher routes here via
# ``repro hooks dispatch post-commit --repo-root <repo>``. Semantics are
# strictly non-blocking: post-commit MUST exit 0 even when the lock
# writer refuses, no workspace metadata is present, the workspace is
# dirty, or any subprocess errors. The operator-facing trace lives in
# ``<workspaceRoot>/.repro/workspace/post-commit-lock.log`` (append-only)
# and in ``<workspaceRoot>/.repro/workspace/post-commit-report.json``
# (overwritten on each run with the latest result).
#
# Design choice: a separate ``runPostCommitLockCommand`` wrapper around
# the strict M11 ``runWorkspaceLockCommand`` was preferred over adding a
# ``--best-effort`` flag to the workspace command itself. The strict
# command keeps its 0/1/2 contract intact; the wrapper concentrates the
# "downgrade every failure to exit 0 + a log line" policy in one place,
# adds the M19-specific log/report layout, and avoids leaking the
# best-effort surface into the operator-facing ``repro workspace lock``.

type
  PostCommitOutcome* = enum
    pcoOk                ## Lock TOML + index updated.
    pcoSkippedDirty      ## At least one sibling repo is dirty; strict
                         ## M11 would have refused with exit 2. The
                         ## post-commit policy is to skip silently.
    pcoSkippedNoWorkspace ## No ``.repo/workspace.toml`` or no resolvable
                          ## project; common in a freshly-cloned repo
                          ## that has not been initialised.
    pcoFailed            ## Lock writer raised (IO error, VCS query
                         ## failure, etc.). Logged and downgraded.

  PostCommitReport* = object
    workspaceRoot*: string
    currentRepo*: string
    project*: string
    outcome*: string
    lockFilePath*: string
    indexFilePath*: string
    triggerRepo*: string
    triggerSha*: string
    diagnostic*: string
    timestamp*: string
    exitCode*: int

proc postCommitOutcomeTag(outcome: PostCommitOutcome): string =
  case outcome
  of pcoOk: "ok"
  of pcoSkippedDirty: "skipped-dirty"
  of pcoSkippedNoWorkspace: "skipped-no-workspace"
  of pcoFailed: "failed"

proc toJsonNode*(report: PostCommitReport): JsonNode =
  result = newJObject()
  result["workspaceRoot"] = %report.workspaceRoot
  result["currentRepo"] = %report.currentRepo
  result["project"] = %report.project
  result["outcome"] = %report.outcome
  result["lockFilePath"] = %report.lockFilePath
  result["indexFilePath"] = %report.indexFilePath
  result["triggerRepo"] = %report.triggerRepo
  result["triggerSha"] = %report.triggerSha
  result["diagnostic"] = %report.diagnostic
  result["timestamp"] = %report.timestamp
  result["exitCode"] = %report.exitCode

proc resolvePostCommitWorkspaceRoot(currentRepo, workspaceRoot: string): string =
  ## Walk up from ``--current-repo`` to find ``.repo/``. Matches the M18
  ## ``parseCheckArgs`` heuristic so the dispatch wiring stays uniform.
  if workspaceRoot.len > 0:
    return absolutePath(workspaceRoot)
  if currentRepo.len > 0:
    var probe = absolutePath(currentRepo)
    while probe.len > 1:
      if dirExists(probe / ".repo"):
        return probe
      let parent = parentDir(probe)
      if parent == probe: break
      probe = parent
  ""

proc writePostCommitReport(workspaceRoot: string;
                           report: PostCommitReport) =
  ## Best-effort write of the JSON report. Never raises (a failing
  ## report write is itself just logged below).
  try:
    let reportDir = workspaceRoot / ".repro" / "workspace"
    createDir(reportDir)
    let reportPath = reportDir / "post-commit-report.json"
    writeFile(reportPath, pretty(report.toJsonNode(), indent = 2) & "\n")
  except CatchableError:
    discard

proc appendPostCommitLog(workspaceRoot, line: string) =
  ## Append a single line to ``post-commit-lock.log``. Never raises —
  ## a failed log write must not block the commit.
  try:
    let reportDir = workspaceRoot / ".repro" / "workspace"
    createDir(reportDir)
    let logPath = reportDir / "post-commit-lock.log"
    var f: File
    if open(f, logPath, fmAppend):
      f.writeLine(line)
      f.close()
  except CatchableError:
    discard

proc parsePostCommitArgs(args: openArray[string]):
    tuple[currentRepo, workspaceRoot, triggerSha, triggerRepo: string;
          toolProvisioning: ToolProvisioningMode] =
  ## Minimal argv parser for the post-commit wrapper. The dispatcher
  ## installs ``--current-repo=PATH``; the rest are pass-throughs the
  ## operator can supply when invoking ``repro workspace post-commit``
  ## manually. Unknown flags are silently ignored — post-commit must
  ## never raise on argv shape.
  result.toolProvisioning = tpmPathOnly
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--":
      inc i
      continue
    if arg == "--current-repo" or arg.startsWith("--current-repo="):
      try: result.currentRepo = valueFromFlag(args, i, "--current-repo")
      except CatchableError: discard
    elif arg == "--workspace-root" or arg.startsWith("--workspace-root="):
      try: result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
      except CatchableError: discard
    elif arg == "--sha" or arg.startsWith("--sha="):
      try: result.triggerSha = valueFromFlag(args, i, "--sha")
      except CatchableError: discard
    elif arg == "--trigger-repo" or arg.startsWith("--trigger-repo="):
      try: result.triggerRepo = valueFromFlag(args, i, "--trigger-repo")
      except CatchableError: discard
    elif arg == "--tool-provisioning" or
        arg.startsWith("--tool-provisioning="):
      try:
        result.toolProvisioning = parseToolProvisioning(
          valueFromFlag(args, i, "--tool-provisioning"))
      except CatchableError: discard
    inc i

proc runPostCommitLockCommand*(args: openArray[string]): int =
  ## ``repro hooks dispatch post-commit --repo-root=<repo>`` (and the
  ## operator-facing manual entry point) routes here. The M19 policy is
  ## "best-effort": every failure is captured into the JSON report +
  ## the log file, and the process exits 0 so the originating commit
  ## never sees a non-zero hook status.
  let parsed = parsePostCommitArgs(args)
  let timestamp = isoTimestampNow()
  let workspaceRoot = resolvePostCommitWorkspaceRoot(
    parsed.currentRepo, parsed.workspaceRoot)

  var report: PostCommitReport
  report.workspaceRoot = workspaceRoot
  report.currentRepo = parsed.currentRepo
  report.timestamp = timestamp
  report.exitCode = 0

  # No workspace metadata reachable → skip silently, log once.
  if workspaceRoot.len == 0 or
      not fileExists(workspaceRoot / ".repo" / "workspace.toml"):
    report.outcome = postCommitOutcomeTag(pcoSkippedNoWorkspace)
    report.diagnostic =
      if workspaceRoot.len == 0:
        "no workspace root found from --current-repo=" & parsed.currentRepo
      else:
        "no .repo/workspace.toml at " & workspaceRoot
    if workspaceRoot.len > 0:
      writePostCommitReport(workspaceRoot, report)
      appendPostCommitLog(workspaceRoot,
        timestamp & " " & report.outcome & " " & report.diagnostic)
    return 0

  # Build the strict M11 args from the dispatched argv and invoke the
  # M11 executor in-process. Any raise is downgraded to ``pcoFailed``.
  var lockArgs: WorkspaceLockArgs
  lockArgs.workspaceRoot = workspaceRoot
  lockArgs.triggerSha = parsed.triggerSha
  lockArgs.triggerRepo = parsed.triggerRepo
  lockArgs.toolProvisioning = parsed.toolProvisioning

  var raised = false
  var raisedDiagnostic = ""
  var outcome: WorkspaceLockOutcome
  try:
    outcome = executeWorkspaceLock(lockArgs)
  except CatchableError as err:
    raised = true
    raisedDiagnostic = err.msg

  if raised:
    report.outcome = postCommitOutcomeTag(pcoFailed)
    report.diagnostic = raisedDiagnostic
    writePostCommitReport(workspaceRoot, report)
    appendPostCommitLog(workspaceRoot,
      timestamp & " " & report.outcome & " " & raisedDiagnostic)
    return 0

  report.project = outcome.report.project
  report.lockFilePath = outcome.report.lockFilePath
  report.indexFilePath = outcome.report.indexFilePath
  report.triggerRepo = outcome.report.triggerRepo
  report.triggerSha = outcome.report.triggerSha

  case outcome.report.exitCode
  of 0:
    report.outcome = postCommitOutcomeTag(pcoOk)
    report.diagnostic = "wrote " & outcome.report.lockFilePath
    # Best-effort write of the M11 lock-report.json so a manual
    # invocation matches the operator-facing surface.
    try: writeWorkspaceLockReport(outcome.report)
    except CatchableError: discard
  of 2:
    # Strict M11 exit-2 = dirty working tree. The post-commit policy
    # is "skip silently" — the operator already saw the diff during
    # the just-completed commit and may have intentionally left
    # sibling repos untouched.
    report.outcome = postCommitOutcomeTag(pcoSkippedDirty)
    var dirtyNames: seq[string]
    for e in outcome.report.dirty: dirtyNames.add(e.path)
    report.diagnostic = "dirty sibling(s): " & dirtyNames.join(", ")
  else:
    report.outcome = postCommitOutcomeTag(pcoFailed)
    report.diagnostic = "executeWorkspaceLock returned exit code " &
      $outcome.report.exitCode

  writePostCommitReport(workspaceRoot, report)
  appendPostCommitLog(workspaceRoot,
    timestamp & " " & report.outcome & " " & report.diagnostic)
  return 0

# ---- M19a: post-merge / post-checkout manifest auto-refresh ---------------
#
# The M17-installed post-merge and post-checkout hook dispatchers route
# here via ``repro hooks dispatch <hook-name> --repo-root <repo> --
# <hook-args>``. Semantics mirror M19's post-commit wrapper:
#
#   - The hook NEVER blocks the originating git operation. Every error,
#     skip, or success is captured as one line in
#     ``$HOME/.cache/repro/manifest-refresh.log`` and the process exits
#     0 unconditionally.
#   - For ``post-checkout``, git supplies three positional args:
#     ``<prev-head> <new-head> <flag>``. When ``prev == new`` the
#     participating repo's HEAD did NOT move (a path-only checkout)
#     and the spec mandates we skip SILENTLY — no log line.
#   - For ``post-merge``, git supplies one positional arg (the squash
#     flag). It is not load-bearing for the refresh decision; we accept
#     it and ignore.
#   - When the workspace root cannot be located (the participating repo
#     is outside any ``.repo/``-rooted workspace), we skip silently with
#     a single log line so the operator can correlate against the log.
#   - The actual fast-forward semantics live in M10's
#     ``refreshManifestLayers``; this wrapper just downgrades raises and
#     translates per-layer ``ManifestLayerRefreshStatus`` values into
#     append-only log lines.

const manifestRefreshLogFile = "manifest-refresh.log"

proc manifestRefreshCacheLogPath(): string =
  ## ``$HOME/.cache/repro/manifest-refresh.log`` on POSIX; the
  ## XDG-style cache root on every host. ``getHomeDir`` already returns
  ## the right value on Windows (``%USERPROFILE%``), so the same
  ## layout works there.
  let xdg = getEnv("XDG_CACHE_HOME")
  let cacheRoot =
    if xdg.len > 0: xdg
    else: getHomeDir() / ".cache"
  cacheRoot / "repro" / manifestRefreshLogFile

proc appendManifestRefreshLog(line: string) =
  ## Append a single line to the manifest-refresh log. Never raises —
  ## a failed log write must not block the originating git operation.
  try:
    let logPath = manifestRefreshCacheLogPath()
    createDir(parentDir(logPath))
    var f: File
    if open(f, logPath, fmAppend):
      f.writeLine(line)
      f.close()
  except CatchableError:
    discard

proc parseManifestRefreshArgs(args: openArray[string]):
    tuple[currentRepo, workspaceRoot: string; positional: seq[string]] =
  ## Minimal argv parser for the post-merge / post-checkout wrappers.
  ## The dispatcher in ``runHooksDispatchCommand`` has already peeled
  ## off ``--repo-root`` (and any other flag the canonical hook body
  ## forwards), then placed the remaining hook-supplied positional
  ## args (``post-merge`` ``<squash-flag>`` / ``post-checkout``
  ## ``<prev> <new> <flag>``) after ``--``. Unknown flags are silently
  ## ignored — the hook must never raise on argv shape.
  var sawDoubleDash = false
  var i = 0
  while i < args.len:
    let arg = args[i]
    if not sawDoubleDash:
      if arg == "--":
        sawDoubleDash = true
        inc i
        continue
      if arg == "--current-repo" or arg.startsWith("--current-repo="):
        try: result.currentRepo = valueFromFlag(args, i, "--current-repo")
        except CatchableError: discard
      elif arg == "--workspace-root" or arg.startsWith("--workspace-root="):
        try: result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
        except CatchableError: discard
      # Tolerate other flags (forward-compat) without recording them.
    else:
      result.positional.add(arg)
    inc i

proc runManifestRefreshHookCommand*(hookName: string;
                                    args: openArray[string]): int =
  ## Best-effort manifest-layer refresh for ``post-merge`` /
  ## ``post-checkout`` dispatch. Always returns 0 — the originating git
  ## operation must never see a non-zero hook status. The operator-facing
  ## trace lives in ``$HOME/.cache/repro/manifest-refresh.log``.
  let parsed = parseManifestRefreshArgs(args)
  let timestamp = isoTimestampNow()

  # post-checkout short-circuit: when git reports
  # ``<prev-head> <new-head> <flag>`` with ``prev == new``, the
  # participating repo's HEAD did NOT move and the spec says skip
  # SILENTLY (no log line).
  if hookName == "post-checkout" and parsed.positional.len >= 2:
    let prev = parsed.positional[0]
    let newer = parsed.positional[1]
    if prev.len > 0 and prev == newer:
      return 0

  let workspaceRoot = resolvePostCommitWorkspaceRoot(
    parsed.currentRepo, parsed.workspaceRoot)

  if workspaceRoot.len == 0:
    appendManifestRefreshLog(timestamp & " " & hookName &
      " skipped: no workspace root reachable from --current-repo=" &
      parsed.currentRepo)
    return 0

  if not fileExists(workspaceRoot / ".repo" / "workspace.toml"):
    # No workspace.toml means M6/M7 single-project mode (or a freshly-
    # initialised .repo): nothing to refresh. Log once so the operator
    # can correlate; never raise.
    appendManifestRefreshLog(timestamp & " " & hookName &
      " skipped: no .repo/workspace.toml at " & workspaceRoot)
    return 0

  var report: ManifestRefreshReport
  try:
    report = refreshManifestLayers(workspaceRoot)
  except CatchableError as err:
    appendManifestRefreshLog(timestamp & " " & hookName &
      " fetch failed: " & err.msg & " (workspace=" & workspaceRoot & ")")
    return 0

  if report.layers.len == 0:
    # workspace.toml exists but declares no [[manifest]] layers — the
    # M9-init single-project metadata-only shape. Nothing to do; emit
    # one log line so the operator can audit hook activity.
    appendManifestRefreshLog(timestamp & " " & hookName &
      " noop: workspace declares no manifest layers (" &
      workspaceRoot & ")")
    return 0

  for entry in report.layers:
    let tag = manifestLayerStatusTag(entry.status)
    case entry.status
    of mrsRefreshed:
      appendManifestRefreshLog(timestamp & " " & hookName & " " & tag &
        " manifest refreshed: " & entry.beforeSha & " -> " &
        entry.afterSha & " (layer=" & entry.provenance & ")")
    of mrsUpToDate:
      appendManifestRefreshLog(timestamp & " " & hookName & " " & tag &
        " manifest already current at " & entry.afterSha &
        " (layer=" & entry.provenance & ")")
    of mrsSkippedLocal:
      # Local-path layers are operator-maintained; the spec says they
      # are not the workspace's job to refresh. Stay quiet — no log
      # line — so the cache log stays focused on actionable signals.
      discard
    of mrsSkippedAbsent:
      appendManifestRefreshLog(timestamp & " " & hookName & " " & tag &
        " layer checkout not present yet (layer=" & entry.provenance &
        "); next `repro workspace sync` will materialise it")
    of mrsSkippedDirty:
      appendManifestRefreshLog(timestamp & " " & hookName & " " & tag &
        " manifest dirty, refresh deferred (layer=" & entry.provenance &
        "): " & entry.diagnostic)
    of mrsSkippedDivergent:
      appendManifestRefreshLog(timestamp & " " & hookName & " " & tag &
        " manifest diverged, refresh deferred (layer=" & entry.provenance &
        "): " & entry.diagnostic)
    of mrsFailed:
      appendManifestRefreshLog(timestamp & " " & hookName & " " & tag &
        " fetch failed (layer=" & entry.provenance & "): " &
        entry.diagnostic)

  return 0

# ---- M18 / M23 / M26: `repro check --mode=pre-push` (publication gate) ----
#
# The installed pre-push hook (M17 dispatcher) routes into the gate by
# calling ``repro check --mode=pre-push --current-repo=PATH
# --pushed-refs=FILE``. The gate runs six checks in order; the first
# failure short-circuits with a structured ``CheckFailure`` record:
#
#   1. ``branch-mismatch``  — pushed local branch != active workspace
#                             branch (M13 metadata).
#   2. ``dirty``            — any sibling repo has a dirty working tree
#                             (M4 ``isCleanQuery`` evidence).
#   3. ``unpublished``      — any sibling repo's HEAD is not reachable
#                             on a remote (M4 ``isPublishedQuery``).
#   4. ``develop_override_*`` — M23: every M20 develop-mode override
#                             must exist on disk, have a clean working
#                             tree, and have its HEAD published.
#                             Properties:
#                               ``develop_override_missing``
#                               ``develop_override_dirty``
#                               ``develop_override_unpublished``.
#                             Absent ``.repro/develop-overrides.toml``
#                             skips this stage entirely so the gate
#                             stays bit-compatible with workspaces that
#                             have never run ``repro develop``.
#   5. ``lock-stale`` /     — workspace lock missing or any repo's
#      ``lock-failure``        HEAD differs from the locked SHA;
#                             the gate creates / refreshes the lock
#                             (via the M11 ``executeWorkspaceLock``
#                             driver) and only fails when creation
#                             itself fails.
#   6. ``lock_references_private_repo`` — M26: when the push touches
#                             one or more ``locks/<project>/<file>.toml``
#                             files in the current-repo (a manifest-layer
#                             repo) AND that manifest layer is declared
#                             ``visibility = "public"`` in
#                             ``.repo/workspace.toml``, every repo
#                             referenced by the touched locks must be
#                             declared by at least one public manifest
#                             layer. A repo declared ONLY in non-public
#                             layers makes the lock unreproducible for
#                             public-only operators; the gate refuses
#                             the push so the operator either drops
#                             the private references or publishes a
#                             non-public lock instead.
#
# The exit-code contract matches the milestone:
#   - 0 — every check passed (and the lock was created / refreshed
#         if it had been missing or stale).
#   - 2 — any of the six publication-gate checks failed.
#   - 1 — IO / resolve / VCS-tool failure unrelated to the gate logic.

type
  CheckMode* = enum
    cmPrePush

  CheckFailure* = object
    ## One structured failure record per gate failure. ``repo`` is the
    ## workspace-relative path of the offending repo (or the empty
    ## string when the failure is workspace-wide, e.g. a missing
    ## ``--current-repo`` for the branch-mismatch case); ``property``
    ## is the short tag the spec mandates (``branch-mismatch`` /
    ## ``dirty`` / ``unpublished`` / ``lock-stale`` /
    ## ``lock-failure`` / ``develop_override_dirty`` /
    ## ``develop_override_unpublished`` / ``develop_override_missing`` /
    ## ``lock_references_private_repo``);
    ## ``remediation`` is the operator-facing next-step the JSON report
    ## and text diagnostic surface. ``source`` is populated by the M23
    ## develop-override stage with the override's filesystem path so
    ## the operator can locate the offending checkout without having to
    ## re-read the override file, and by the M26 lock-visibility stage
    ## with the manifest-layer-relative path of the offending lock file.
    ## For the four M18 sibling-repo stages ``source`` is left empty.
    repo*: string
    property*: string
    remediation*: string
    evidence*: string
    source*: string

  CheckLockUpdateKind* = enum
    cluNone           ## No lock action taken (e.g. a pre-push check that
                      ## short-circuited before the lock pass).
    cluAlreadyCurrent ## Lock present and every repo's HEAD matches.
    cluCreated        ## No prior lock existed; the gate created one.
    cluRefreshed      ## Lock existed but was stale; the gate refreshed it.
    cluFailed         ## Lock creation or refresh raised. The failure
                      ## entry carries the structured reason; the gate
                      ## exits with code 2.

  CheckLockUpdate* = object
    kind*: CheckLockUpdateKind
    lockFilePath*: string
    indexFilePath*: string
    triggerRepo*: string
    triggerSha*: string
    diagnostic*: string

  CheckReport* = object
    ## Structured outcome of one ``repro check`` invocation. The JSON
    ## form is written to ``<workspaceRoot>/.repro/workspace/check-report.json``
    ## and (with ``--json``) also echoed to stdout.
    mode*: string
    workspaceRoot*: string
    project*: string
    activeBranch*: string
    currentRepo*: string
    pushedBranch*: string
    pushedRefsPath*: string
    failures*: seq[CheckFailure]
    lockUpdate*: CheckLockUpdate
    exitCode*: int

proc lockUpdateKindTag(kind: CheckLockUpdateKind): string =
  case kind
  of cluNone: "none"
  of cluAlreadyCurrent: "already-current"
  of cluCreated: "created"
  of cluRefreshed: "refreshed"
  of cluFailed: "failed"

proc toJsonNode*(report: CheckReport): JsonNode =
  result = newJObject()
  result["mode"] = %report.mode
  result["workspaceRoot"] = %report.workspaceRoot
  result["project"] = %report.project
  result["activeBranch"] = %report.activeBranch
  result["currentRepo"] = %report.currentRepo
  result["pushedBranch"] = %report.pushedBranch
  result["pushedRefsPath"] = %report.pushedRefsPath
  var failures = newJArray()
  for failure in report.failures:
    var obj = newJObject()
    obj["repo"] = %failure.repo
    obj["property"] = %failure.property
    obj["remediation"] = %failure.remediation
    obj["evidence"] = %failure.evidence
    obj["source"] = %failure.source
    failures.add(obj)
  result["failures"] = failures
  var lockObj = newJObject()
  lockObj["kind"] = %lockUpdateKindTag(report.lockUpdate.kind)
  lockObj["lockFilePath"] = %report.lockUpdate.lockFilePath
  lockObj["indexFilePath"] = %report.lockUpdate.indexFilePath
  lockObj["triggerRepo"] = %report.lockUpdate.triggerRepo
  lockObj["triggerSha"] = %report.lockUpdate.triggerSha
  lockObj["diagnostic"] = %report.lockUpdate.diagnostic
  result["lockUpdate"] = lockObj
  result["exitCode"] = %report.exitCode

proc renderCheckTextLines*(report: CheckReport): seq[string] =
  result.add("repro check: mode=" & report.mode &
    " project=" & report.project &
    " branch=" & (if report.activeBranch.len > 0:
                    report.activeBranch
                  else: "<none>"))
  for failure in report.failures:
    var line = "repro check: " &
      (if failure.repo.len > 0: failure.repo & ": " else: "") &
      failure.property
    if failure.remediation.len > 0:
      line.add(" — " & failure.remediation)
    if failure.evidence.len > 0:
      line.add(" [" & failure.evidence & "]")
    result.add(line)
  case report.lockUpdate.kind
  of cluNone:
    discard
  of cluAlreadyCurrent:
    result.add("repro check: lock already current at " &
      report.lockUpdate.lockFilePath)
  of cluCreated:
    result.add("repro check: lock created at " &
      report.lockUpdate.lockFilePath)
  of cluRefreshed:
    result.add("repro check: lock refreshed at " &
      report.lockUpdate.lockFilePath)
  of cluFailed:
    result.add("repro check: lock update FAILED: " &
      report.lockUpdate.diagnostic)
  if report.exitCode == 0 and report.failures.len == 0:
    result.add("repro check: OK")

type
  CheckArgs* = object
    mode*: CheckMode
    workspaceRoot*: string
    currentRepo*: string
    pushedRefsPath*: string
    json*: bool
    toolProvisioning*: ToolProvisioningMode

proc parseCheckMode(value: string): CheckMode =
  case value
  of "pre-push": cmPrePush
  else:
    raise newException(ValueError,
      "unsupported --mode value for `repro check`: " & value &
        " (expected: pre-push)")

proc parseCheckArgs*(args: openArray[string]): CheckArgs =
  ## ``repro check --mode=pre-push [--workspace-root=PATH]
  ## [--current-repo=PATH] [--pushed-refs=FILE]
  ## [--tool-provisioning=path|nix|tarball|scoop] [--json]``. ``--mode``
  ## is REQUIRED — there is no implicit mode in the M18 surface.
  result.toolProvisioning = tpmPathOnly
  var modeSet = false
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--mode" or arg.startsWith("--mode="):
      result.mode = parseCheckMode(valueFromFlag(args, i, "--mode"))
      modeSet = true
    elif arg == "--workspace-root" or arg.startsWith("--workspace-root="):
      result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
    elif arg == "--current-repo" or arg.startsWith("--current-repo="):
      result.currentRepo = valueFromFlag(args, i, "--current-repo")
    elif arg == "--pushed-refs" or arg.startsWith("--pushed-refs="):
      result.pushedRefsPath = valueFromFlag(args, i, "--pushed-refs")
    elif arg == "--tool-provisioning" or
        arg.startsWith("--tool-provisioning="):
      result.toolProvisioning = parseToolProvisioning(
        valueFromFlag(args, i, "--tool-provisioning"))
    elif arg == "--json":
      result.json = true
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported `repro check` flag: " & arg)
    else:
      raise newException(ValueError,
        "unexpected positional argument to `repro check`: " & arg)
    inc i
  if not modeSet:
    raise newException(ValueError,
      "`repro check` requires --mode=pre-push (no other modes are " &
        "supported yet)")
  if result.workspaceRoot.len == 0:
    # When invoked from inside a participating repo (the usual hook
    # call site) we walk up from ``--current-repo`` to discover the
    # workspace root. Failing that, fall back to the process cwd.
    if result.currentRepo.len > 0:
      var probe = absolutePath(result.currentRepo)
      while probe.len > 1:
        if dirExists(probe / ".repo"):
          result.workspaceRoot = probe
          break
        let parent = parentDir(probe)
        if parent == probe: break
        probe = parent
    if result.workspaceRoot.len == 0:
      result.workspaceRoot = getCurrentDir()
  result.workspaceRoot = absolutePath(result.workspaceRoot)
  if result.currentRepo.len > 0:
    result.currentRepo = absolutePath(result.currentRepo)
  if result.pushedRefsPath.len > 0:
    result.pushedRefsPath = absolutePath(result.pushedRefsPath)

proc resolveCheckProject(parsed: CheckArgs):
    tuple[resolved: ResolvedProject;
          workspaceLocal: Option[WorkspaceLocal]] =
  ## Same dispatch rule as M11 / M12: composer mode when
  ## ``.repo/workspace.toml`` declares ``[[manifest]]`` layers,
  ## otherwise single-project mode. A metadata-only workspace.toml (M13)
  ## supplies the project name for the single-project branch.
  let workspaceToml = parsed.workspaceRoot / ".repo" / "workspace.toml"
  if isCompositionalWorkspaceToml(parsed.workspaceRoot):
    let absToml = absolutePath(workspaceToml)
    let workspaceLocal = readWorkspaceLocal(absToml)
    let resolved = composeManifestLayers(
      workspaceLocal, parsed.workspaceRoot, absToml)
    return (resolved, some(workspaceLocal))
  var projectName = ""
  if fileExists(workspaceToml):
    try:
      let recorded =
        readWorkspaceLocal(absolutePath(workspaceToml)).workspace.project
      if recorded.len > 0:
        projectName = recorded
    except WorkspaceManifestParseError:
      discard
  if projectName.len == 0:
    raise newException(ValueError,
      "`repro check --mode=pre-push` requires `.repo/workspace.toml` " &
        "or a project name recoverable from one; neither was present at " &
        parsed.workspaceRoot)
  let manifestsRoot = parsed.workspaceRoot / ".repo" / "manifests"
  let projectFile = manifestsRoot / "projects" / (projectName & ".toml")
  let variantFile = manifestsRoot / "variants" / (projectName & ".toml")
  if fileExists(projectFile):
    return (resolveProject(projectFile), none(WorkspaceLocal))
  if fileExists(variantFile):
    return (resolveVariant(variantFile), none(WorkspaceLocal))
  raise newException(ValueError,
    "no project or variant named '" & projectName &
      "' found under '" & manifestsRoot &
      "' (looked for '" & projectFile & "' and '" & variantFile & "')")

proc parsePushedBranchFromRefs(refsPath: string): string =
  ## Parse a git ``pre-push`` refs stream. Each line carries
  ## ``<local-ref> <local-sha> <remote-ref> <remote-sha>``; we return
  ## the FIRST non-deleting local branch's short name (``refs/heads/X``
  ## → ``X``). An empty file / a file consisting only of deletions
  ## (``local-sha`` is all zeroes) yields the empty string — the gate
  ## treats that as "no branch claim" and skips the active-branch
  ## comparison. Non-existent files also yield the empty string so the
  ## hook stays robust against an empty stdin redirect.
  if refsPath.len == 0 or not fileExists(refsPath):
    return ""
  let zeroSha = "0000000000000000000000000000000000000000"
  for rawLine in readFile(refsPath).splitLines():
    let line = rawLine.strip()
    if line.len == 0:
      continue
    let parts = line.split(' ')
    if parts.len < 2:
      continue
    let localRef = parts[0]
    let localSha = parts[1]
    if localSha == zeroSha:
      # Branch deletion push — no source ref to attribute to the
      # workspace branch.
      continue
    if localRef.startsWith("refs/heads/"):
      return localRef["refs/heads/".len .. ^1]
    return localRef
  ""

proc deriveCheckActiveBranch(parsed: CheckArgs;
    workspaceLocal: Option[WorkspaceLocal];
    resolved: ResolvedProject): string =
  ## Mirror of M12's ``deriveActiveBranch`` but without per-repo
  ## fallback: the pre-push gate must trust the recorded value rather
  ## than guess from an in-flight checkout. Precedence:
  ##   1. ``.repo/workspace.toml``'s ``[workspace].branch`` (M13).
  ##   2. The ``workspaceLocal`` we already loaded (composer-mode
  ##      shortcut that avoids re-reading the file).
  ##   3. The resolver's ``trunk``.
  try:
    let recorded = readWorkspaceBranch(parsed.workspaceRoot)
    if recorded.isSome:
      return recorded.get()
  except WorkspaceManifestParseError:
    discard
  if workspaceLocal.isSome and
      workspaceLocal.get().workspace.branch.isSome and
      workspaceLocal.get().workspace.branch.get().len > 0:
    return workspaceLocal.get().workspace.branch.get()
  resolved.trunk

# ---- M26 helpers: lock-visibility classification --------------------------
#
# The publication gate's sixth stage inspects the manifest-layer repo
# the operator is pushing FROM. The three load-bearing pieces are:
#
#   (a) The on-disk path of every ``[[manifest]]`` layer the workspace
#       declares — needed to (i) tell whether ``--current-repo`` IS one
#       of those layer repos and (ii) read each layer's
#       ``projects/<p>.toml`` to discover which repos the layer declares.
#       Mirrors ``compose.layerDirName`` / ``compose.sanitizeForPath``
#       for ``url``-backed layers and the in-tree path for ``local_path``
#       layers (matching ``pickManifestLayerRoot``'s convention).
#
#   (b) A per-repo-path visibility classification — which manifest layer
#       tiers (``public`` / ``org`` / ``team`` / ``private``) declare
#       each repo path. The M8 composer's merge rule overwrites earlier
#       declarations when the same triple appears again, so we cannot
#       rely on ``ResolvedRepo.visibility`` alone — we re-resolve each
#       layer's project file and aggregate the tier set per path.
#
#   (c) Which lock files in ``locks/<project>/<file>.toml`` are touched
#       by the pushed commits. Computed with ``git diff --name-only``
#       between the remote-sha and the local-sha for each pushed ref;
#       branch-creation pushes (zero remote-sha) fall back to a
#       ``ls-tree`` enumeration of every lock file at the local-sha.

type
  ManifestLayerLocation* = object
    ## One entry per ``[[manifest]]`` layer declared in
    ## ``.repo/workspace.toml``. ``absPath`` is the on-disk directory
    ## that owns the layer's project files and (for the first layer)
    ## the lock files. ``visibility`` is the tier declared on the
    ## ``[[manifest]]`` entry. ``provenance`` is the URL or local-path
    ## string the layer was declared with — used in M26 diagnostics so
    ## the operator can identify the offending layer at a glance.
    index*: int
    absPath*: string
    provenance*: string
    visibility*: WorkspaceVisibility

proc sanitizeManifestUrlForPath(raw: string): string =
  ## Mirror of ``compose.sanitizeForPath`` — the dotted alphanumeric +
  ## dash subset, runs of dashes collapsed, capped at 80 chars, leading
  ## / trailing dashes stripped. Lives here so M26 doesn't take a hard
  ## dependency on a compose-private helper.
  var raw1 = newStringOfCap(raw.len)
  for ch in raw:
    case ch
    of 'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_': raw1.add(ch)
    else: raw1.add('-')
  var collapsed = newStringOfCap(raw1.len)
  var prevDash = false
  for ch in raw1:
    if ch == '-':
      if not prevDash: collapsed.add(ch)
      prevDash = true
    else:
      collapsed.add(ch)
      prevDash = false
  if collapsed.len > 80:
    collapsed.setLen(80)
  result = collapsed.strip(chars = {'-'}, leading = true, trailing = true)
  if result.len == 0:
    result = "layer"

proc enumerateManifestLayerLocations(workspaceRoot: string;
    workspaceLocal: Option[WorkspaceLocal]):
      seq[ManifestLayerLocation] =
  ## Build a list of on-disk locations for every ``[[manifest]]`` layer
  ## in ``workspaceLocal``. ``url``-backed layers map to
  ## ``<workspaceRoot>/.repo/manifests-<i>-<sanitized>/`` (the same
  ## directory ``compose.acquireUrlLayer`` materialises); ``local_path``
  ## layers map to their literal path (resolved against the workspace
  ## root when relative). The ``visibility`` string from the TOML maps
  ## via the same accept-set the composer uses (``private`` and
  ## ``personal`` collapse to ``wvPersonal``).
  if workspaceLocal.isNone:
    return
  let local = workspaceLocal.get()
  for layerIdx, entry in local.manifest:
    var loc = ManifestLayerLocation(index: layerIdx)
    let visStr = entry.visibility.toLowerAscii()
    case visStr
    of "public": loc.visibility = wvPublic
    of "org": loc.visibility = wvOrg
    of "team": loc.visibility = wvTeam
    of "private", "personal": loc.visibility = wvPersonal
    else:
      # An unknown tier means the workspace.toml is malformed; we still
      # emit an entry (with the default ``wvPublic``) so subsequent gate
      # logic doesn't crash. The strict reader path will surface the
      # actual error to the operator separately.
      loc.visibility = wvPublic
    let hasUrl = entry.url.isSome and entry.url.get().len > 0
    let hasLocal = entry.local_path.isSome and entry.local_path.get().len > 0
    if hasUrl:
      let url = entry.url.get()
      loc.provenance = url
      let suffix = sanitizeManifestUrlForPath(url)
      loc.absPath = workspaceRoot / ".repo" /
        ("manifests-" & $layerIdx & "-" & suffix)
    elif hasLocal:
      let raw = entry.local_path.get()
      loc.provenance = raw
      if isAbsolute(raw):
        loc.absPath = raw
      else:
        loc.absPath = absolutePath(workspaceRoot / raw)
    else:
      # Malformed entry — keep going so other layers can still be
      # inspected; the strict reader will surface the actual error.
      continue
    result.add(loc)

proc classifyRepoPathVisibility(workspaceRoot: string;
    layerLocations: openArray[ManifestLayerLocation];
    projectName: string): Table[string, set[WorkspaceVisibility]] =
  ## For each ``ResolvedRepo.path`` declared across the union of
  ## manifest layers, return the set of visibility tiers that declare
  ## the path. The result is a path-keyed map ``path -> {tiers}``. A
  ## repo path declared exclusively in non-public tiers (the set
  ## doesn't include ``wvPublic``) is what M26 considers
  ## "private-only" — pushing such a path under a public-layer lock is
  ## the violation the spec blocks.
  result = initTable[string, set[WorkspaceVisibility]]()
  for loc in layerLocations:
    if not dirExists(loc.absPath):
      continue
    let projectFile = loc.absPath / "projects" / (projectName & ".toml")
    if not fileExists(projectFile):
      continue
    var layerResolved: ResolvedProject
    try:
      layerResolved = resolveProject(projectFile)
    except CatchableError:
      # Re-resolution failure here is non-fatal for M26: the strict
      # composer path (the rest of the gate) would already have surfaced
      # any structural issue. Skipping the layer in the visibility map
      # treats it as "no declarations" which is the conservative
      # interpretation — a repo only declared here would NOT be marked
      # as having public visibility, which is the safer default.
      continue
    for repo in layerResolved.repos:
      if repo.path notin result:
        result[repo.path] = {}
      result[repo.path].incl(loc.visibility)

proc visibilityTierLabelLocal(v: WorkspaceVisibility): string =
  ## Local mirror of ``compose.visibilityTierLabel`` — kept private to
  ## this module so M26 diagnostics use the same canonical lowercase
  ## labels the M25 init diagnostics use (``private`` rather than
  ## ``personal``).
  case v
  of wvPublic: "public"
  of wvOrg: "org"
  of wvTeam: "team"
  of wvPersonal: "private"

proc visibilitySetLabel(tiers: set[WorkspaceVisibility]): string =
  ## Render a tier set as a stable ``visibility=<a>+<b>`` string for the
  ## evidence field of the structured failure record. Tier order is
  ## fixed by the enum order so the rendered string is byte-stable
  ## across runs.
  var parts: seq[string]
  for v in [wvPublic, wvOrg, wvTeam, wvPersonal]:
    if v in tiers:
      parts.add(visibilityTierLabelLocal(v))
  parts.join("+")

proc lockPathsTouchedInPush(identity: GitToolIdentity;
    currentRepo, refsPath, projectName: string): seq[string] =
  ## Inspect the git ``pre-push`` refs stream and return the list of
  ## ``locks/<project>/<file>.toml`` paths that the pushed commits
  ## introduce or modify in ``currentRepo``. The lock-index TOML
  ## (``index.toml``) is excluded — it's metadata, not a workspace
  ## state record, and pruning it keeps M26's failure surface tight.
  ##
  ## Each ref-stream line is ``<local-ref> <local-sha> <remote-ref>
  ## <remote-sha>``. We treat the line specially when:
  ##
  ##   - ``local-sha`` is all-zero (a deletion push) — nothing to
  ##     inspect, skip the line.
  ##   - ``remote-sha`` is all-zero (the branch is being created on
  ##     the remote for the first time) — every lock file present at
  ##     ``local-sha`` is "added" by this push, so we enumerate them
  ##     with ``git ls-tree -r local-sha``.
  ##   - Otherwise, we run ``git diff --name-only remote-sha
  ##     local-sha`` and filter the output to the
  ##     ``locks/<project>/`` prefix.
  ##
  ## Paths returned are repository-root-relative with forward slashes
  ## (the form ``git`` emits). The caller resolves them against
  ## ``currentRepo`` to read the lock file from disk.
  if refsPath.len == 0 or not fileExists(refsPath):
    return
  if currentRepo.len == 0 or not dirExists(currentRepo / ".git"):
    return
  let zeroSha = "0000000000000000000000000000000000000000"
  let lockPrefix = "locks/" & projectName & "/"
  var seen = initHashSet[string]()
  for rawLine in readFile(refsPath).splitLines():
    let line = rawLine.strip()
    if line.len == 0:
      continue
    let parts = line.split(' ')
    if parts.len < 4:
      continue
    let localSha = parts[1]
    let remoteSha = parts[3]
    if localSha == zeroSha:
      continue
    var emitted: seq[string]
    if remoteSha == zeroSha:
      # Branch creation: every lock file at local-sha is "added".
      let lsRes = gitRunPlain(identity,
        ["-C", currentRepo, "ls-tree", "-r", "--name-only", localSha])
      if lsRes.code != 0:
        continue
      for raw in lsRes.output.splitLines():
        let p = raw.strip()
        if p.startsWith(lockPrefix) and p.endsWith(".toml") and
            not p.endsWith("/index.toml") and p != lockPrefix & "index.toml":
          emitted.add(p)
    else:
      let diffRes = gitRunPlain(identity,
        ["-C", currentRepo, "diff", "--name-only", remoteSha, localSha])
      if diffRes.code != 0:
        # A diff failure (e.g. the remote-sha is not in the local repo)
        # falls back to enumerating every lock file at local-sha — the
        # conservative answer is "treat every present lock as touched".
        let lsRes = gitRunPlain(identity,
          ["-C", currentRepo, "ls-tree", "-r", "--name-only", localSha])
        if lsRes.code != 0:
          continue
        for raw in lsRes.output.splitLines():
          let p = raw.strip()
          if p.startsWith(lockPrefix) and p.endsWith(".toml") and
              not p.endsWith("/index.toml") and p != lockPrefix & "index.toml":
            emitted.add(p)
      else:
        for raw in diffRes.output.splitLines():
          let p = raw.strip()
          if p.startsWith(lockPrefix) and p.endsWith(".toml") and
              not p.endsWith("/index.toml") and p != lockPrefix & "index.toml":
            emitted.add(p)
    for p in emitted:
      if p notin seen:
        seen.incl(p)
        result.add(p)

proc executeCheckPrePush(parsed: CheckArgs): CheckReport =
  ## Drive the six-stage gate. Each stage short-circuits on the first
  ## failure — the spec is explicit that the gate names ONE failure at
  ## a time so the operator's next step is unambiguous. M23 inserted
  ## the develop-override cleanliness stage between the sibling-repo
  ## ``unpublished`` stage and the lock-currency stage; the stage is a
  ## no-op when no ``.repro/develop-overrides.toml`` exists. M26 adds
  ## the sixth ``lock_references_private_repo`` stage after the lock-
  ## currency stage; the stage is a no-op when the current-repo is not
  ## a manifest-layer repo or when no lock files are being pushed.
  result.mode = "pre-push"
  result.workspaceRoot = parsed.workspaceRoot
  result.currentRepo = parsed.currentRepo
  result.pushedRefsPath = parsed.pushedRefsPath

  let (resolved, workspaceLocal) = resolveCheckProject(parsed)
  result.project = resolved.projectName
  result.activeBranch = deriveCheckActiveBranch(
    parsed, workspaceLocal, resolved)

  let identity = ensureGitToolResolvable(
    parsed.toolProvisioning, getEnv("PATH"))
  installGitVcsExecutor()
  let toolDigest = digestHex(identity)
  let observedAt = getTime().toUnix * 1000

  # Build a name-keyed lookup of the offending repo. The ``--current-repo``
  # flag is the directory the hook was invoked in; convert it to the
  # workspace-relative path so all the per-repo gate stages report
  # consistent identifiers.
  var currentRepoPath = ""
  var currentRepoName = ""
  if parsed.currentRepo.len > 0:
    for repo in resolved.repos:
      let abs = absolutePath(parsed.workspaceRoot / repo.path)
      if abs == parsed.currentRepo:
        currentRepoPath = repo.path
        currentRepoName = repo.name
        break

  # ---- 1. branch-mismatch ------------------------------------------------
  result.pushedBranch = parsePushedBranchFromRefs(parsed.pushedRefsPath)
  if result.activeBranch.len > 0 and result.pushedBranch.len > 0 and
      result.pushedBranch != result.activeBranch:
    let repoLabel =
      if currentRepoPath.len > 0: currentRepoPath
      elif parsed.currentRepo.len > 0: parsed.currentRepo
      else: ""
    result.failures.add(CheckFailure(
      repo: repoLabel,
      property: "branch-mismatch",
      remediation: "run 'repro checkout " & result.activeBranch &
        "' or push the active workspace branch instead",
      evidence: "pushed=" & result.pushedBranch &
        " active=" & result.activeBranch))
    result.exitCode = 2
    return

  # Walk the participating repos for the cleanliness + publication
  # passes. We gather the M4 evidence triple for every repo so the
  # second / third stages can short-circuit cleanly while preserving
  # the full observed state for the lock stage.
  type
    RepoObs = object
      name: string
      path: string
      absPath: string
      headSha: string
      isClean: bool
      isPublished: bool
      cleanDiagnostic: string
      pubDiagnostic: string
      branch: string
      hasGit: bool
  var observations: seq[RepoObs]
  for repo in resolved.repos:
    let absRepo = parsed.workspaceRoot / repo.path
    var obs = RepoObs(name: repo.name, path: repo.path, absPath: absRepo)
    if not dirExists(absRepo / ".git"):
      observations.add(obs)
      continue
    obs.hasGit = true
    let headRes = queryGitState(headShaQuery(absRepo), identity)
    if headRes.status == gqsOk:
      obs.headSha = headRes.headSha
    let cleanRes = queryGitState(isCleanQuery(absRepo), identity)
    if cleanRes.status == gqsOk:
      obs.isClean = cleanRes.isClean
    else:
      obs.cleanDiagnostic = cleanRes.diagnostic
    let pubRes = queryGitState(
      isPublishedQuery(absRepo, "origin"), identity)
    if pubRes.status == gqsOk:
      obs.isPublished = pubRes.isPublished
    else:
      obs.pubDiagnostic = pubRes.diagnostic
    let branchRes = gitRunPlain(identity,
      ["-C", absRepo, "symbolic-ref", "--short", "-q", "HEAD"])
    if branchRes.code == 0:
      obs.branch = branchRes.output.strip()
    observations.add(obs)
  # M4 evidence records are intentionally not folded into the gate
  # report yet — the gate carries its own short-circuiting structure
  # and the unified evidence is already exposed by ``repro workspace
  # status`` for general inspection. ``toolDigest`` and ``observedAt``
  # are retained in scope so a future caller wishing to fold the
  # observation triple into ``WorkspaceVcsEvidence`` can do so without
  # re-querying the M1 identity binding.
  discard toolDigest
  discard observedAt
  discard currentRepoName

  # ---- 2. dirty ----------------------------------------------------------
  for obs in observations:
    if not obs.hasGit:
      continue
    if not obs.isClean:
      let evidence =
        if obs.cleanDiagnostic.len > 0:
          "clean-probe-failed: " & obs.cleanDiagnostic
        else: "working tree has uncommitted changes"
      result.failures.add(CheckFailure(
        repo: obs.path,
        property: "dirty",
        remediation: "commit or stash changes in " & obs.path,
        evidence: evidence))
      result.exitCode = 2
      return

  # ---- 3. unpublished ----------------------------------------------------
  for obs in observations:
    if not obs.hasGit:
      continue
    if not obs.isPublished:
      let evidence =
        if obs.pubDiagnostic.len > 0:
          "publish-probe-failed: " & obs.pubDiagnostic
        else: "HEAD " & obs.headSha & " not on any remote-tracking branch"
      result.failures.add(CheckFailure(
        repo: obs.path,
        property: "unpublished",
        remediation: "run 'git push' in " & obs.path & " first",
        evidence: evidence))
      result.exitCode = 2
      return

  # ---- 4. develop-mode override cleanliness (M23) ------------------------
  # The blocking condition reproduces
  # ``Workspace-And-Develop-Mode.md`` §"Reproducibility And `repro check`":
  # a develop-mode dependency with uncommitted modifications, or one
  # that points at commits not pushed to an agreed remote, must not
  # silently be folded into a published workspace lock. The stage is a
  # no-op when ``.repro/develop-overrides.toml`` is absent (the common
  # state for workspaces that have never run ``repro develop``).
  let overridesOpt =
    try:
      readDevelopOverridesFile(parsed.workspaceRoot)
    except WorkspaceManifestParseError as err:
      # Surface the parse failure as a gate refusal rather than letting
      # the outer ``try`` translate it into a generic exit-1. A
      # malformed override file is the operator's problem and refusing
      # the push is the only safe answer.
      result.failures.add(CheckFailure(
        repo: "",
        property: "develop_override_missing",
        remediation:
          "fix '.repro/develop-overrides.toml' parse error before pushing",
        evidence: err.msg,
        source: developOverridesPath(parsed.workspaceRoot)))
      result.exitCode = 2
      return
  if overridesOpt.isSome:
    for entry in listOverrides(overridesOpt.get()):
      let sourcePath =
        if isAbsolute(entry.local_path): entry.local_path
        else: absolutePath(parsed.workspaceRoot / entry.local_path)
      if not dirExists(sourcePath):
        result.failures.add(CheckFailure(
          repo: entry.package,
          property: "develop_override_missing",
          remediation: "the develop-override at " & sourcePath &
            " no longer exists; run 'repro develop " & entry.package &
            " --source=PATH' to update it",
          evidence: "override source path does not exist",
          source: sourcePath))
        result.exitCode = 2
        return
      # Skip non-git overrides — the M20 schema accepts overrides that
      # point at any directory (the CLI even has a "register-only" arm
      # that does not require a VCS root). Treat the absence of ``.git``
      # the same way the M18 sibling-repo stages do: cleanliness and
      # publication are vacuously satisfied because there is no VCS
      # state to compare against. A future milestone can tighten this
      # if non-git overrides become disallowed.
      if not dirExists(sourcePath / ".git"):
        continue
      let cleanRes = queryGitState(isCleanQuery(sourcePath), identity)
      if cleanRes.status != gqsOk:
        result.failures.add(CheckFailure(
          repo: entry.package,
          property: "develop_override_dirty",
          remediation: "commit or stash changes in " & sourcePath,
          evidence: "clean-probe-failed: " & cleanRes.diagnostic,
          source: sourcePath))
        result.exitCode = 2
        return
      if not cleanRes.isClean:
        result.failures.add(CheckFailure(
          repo: entry.package,
          property: "develop_override_dirty",
          remediation: "commit or stash changes in " & sourcePath,
          evidence: "working tree has uncommitted changes",
          source: sourcePath))
        result.exitCode = 2
        return
      let pubRes = queryGitState(
        isPublishedQuery(sourcePath, "origin"), identity)
      if pubRes.status != gqsOk:
        result.failures.add(CheckFailure(
          repo: entry.package,
          property: "develop_override_unpublished",
          remediation: "run 'git push' in " & sourcePath & " first",
          evidence: "publish-probe-failed: " & pubRes.diagnostic,
          source: sourcePath))
        result.exitCode = 2
        return
      if not pubRes.isPublished:
        let headRes = queryGitState(headShaQuery(sourcePath), identity)
        let headSha =
          if headRes.status == gqsOk: headRes.headSha
          else: ""
        let evidence =
          if headSha.len > 0:
            "HEAD " & headSha & " not on any remote-tracking branch"
          else: "HEAD not on any remote-tracking branch"
        result.failures.add(CheckFailure(
          repo: entry.package,
          property: "develop_override_unpublished",
          remediation: "run 'git push' in " & sourcePath & " first",
          evidence: evidence,
          source: sourcePath))
        result.exitCode = 2
        return

  # ---- 5. lock currency --------------------------------------------------
  # Pick the manifest-layer root the way M11 / M12 do, then read the
  # latest locked SHA per repo path. If the locked map covers every
  # participating repo and matches every observed HEAD, the lock is
  # ``already-current``. Otherwise the gate creates or refreshes the
  # lock by delegating to the M11 driver — its refusal arm (a dirty
  # sibling, exit 2) is unreachable here because stage 2 already
  # short-circuited on any dirty tree. Stage 4 (M23 develop-override
  # cleanliness) also has to have passed: a dirty or unpublished
  # override would otherwise be silently encoded into the lock.
  var lockArgs = WorkspaceLockArgs(
    workspaceRoot: parsed.workspaceRoot,
    toolProvisioning: parsed.toolProvisioning)
  let manifestLayerRoot = pickManifestLayerRoot(lockArgs, workspaceLocal)
  let indexPath = lockIndexPath(manifestLayerRoot, resolved.projectName)
  let hasLockIndex = fileExists(indexPath)
  let lockedShas =
    if hasLockIndex:
      readLatestLockedShasByPath(manifestLayerRoot, resolved.projectName)
    else:
      initTable[string, string]()
  var lockMissing = not hasLockIndex
  var lockStale = false
  if not lockMissing:
    if lockedShas.len == 0:
      lockMissing = true
    else:
      for obs in observations:
        if not obs.hasGit:
          continue
        if obs.path notin lockedShas:
          lockStale = true
          break
        if lockedShas[obs.path] != obs.headSha:
          lockStale = true
          break
  if not lockMissing and not lockStale:
    result.lockUpdate.kind = cluAlreadyCurrent
    # Surface the most-recent lock file path so the operator can audit
    # which lock backed the check.
    let lockedIndex = loadLockIndex(indexPath)
    let latest = latestLockIndexEntry(lockedIndex)
    if latest.isSome:
      let rel = latest.get().lockFile.replace('/', DirSep)
      result.lockUpdate.lockFilePath = manifestLayerRoot / rel
      result.lockUpdate.indexFilePath = indexPath
      result.lockUpdate.triggerRepo = latest.get().triggerRepo
      result.lockUpdate.triggerSha = latest.get().triggerSha
  else:
    # Create or refresh the lock via the M11 driver. The driver writes
    # the lock TOML, updates the index, and returns a structured report
    # carrying the new lock-file path. The driver's own ``exitCode == 2``
    # arm fires only on a dirty tree (which stage 2 above already ruled
    # out), so any non-zero exit here is genuinely lock-failure.
    var lockOutcome: WorkspaceLockOutcome
    try:
      lockOutcome = executeWorkspaceLock(lockArgs)
    except CatchableError as err:
      result.lockUpdate.kind = cluFailed
      result.lockUpdate.diagnostic = err.msg
      result.failures.add(CheckFailure(
        repo: "",
        property: "lock-failure",
        remediation:
          "investigate the lock writer error and re-run 'repro check'",
        evidence: err.msg))
      result.exitCode = 2
      return
    if lockOutcome.report.exitCode != 0:
      result.lockUpdate.kind = cluFailed
      let diag =
        if lockOutcome.report.dirty.len > 0:
          "lock writer refused: dirty siblings"
        else: "lock writer exited with code " & $lockOutcome.report.exitCode
      result.lockUpdate.diagnostic = diag
      result.failures.add(CheckFailure(
        repo: "",
        property: "lock-failure",
        remediation: "re-run 'repro workspace lock' to diagnose",
        evidence: diag))
      result.exitCode = 2
      return
    result.lockUpdate.lockFilePath = lockOutcome.report.lockFilePath
    result.lockUpdate.indexFilePath = lockOutcome.report.indexFilePath
    result.lockUpdate.triggerRepo = lockOutcome.report.triggerRepo
    result.lockUpdate.triggerSha = lockOutcome.report.triggerSha
    result.lockUpdate.kind =
      if lockMissing: cluCreated else: cluRefreshed

  # ---- 6. M26: lock visibility (public locks must not reference -----------
  # private-only repos) ----------------------------------------------------
  # The stage is a no-op unless ALL of the following hold:
  #
  #   - The workspace is compositional (``workspaceLocal.isSome``).
  #   - ``--current-repo`` is one of the manifest-layer roots declared
  #     in ``workspace.toml`` AND that layer is declared
  #     ``visibility = "public"``. Pushes from a private manifest-layer
  #     repo are out of scope: a private lock CAN reference private
  #     repos, that's literally the point of a private manifest.
  #   - The pushed refs introduce or modify at least one
  #     ``locks/<project>/<file>.toml`` path in the current-repo (the
  #     git-diff probe above). The lock-index TOML (``index.toml``) is
  #     deliberately not treated as a "lock change" — it's metadata
  #     about which locks exist, not the lock state itself.
  #
  # When triggered, the stage reads each touched lock file via the M5
  # strict ``readLock`` reader, gathers the set of declared repo paths,
  # and looks up each path in the per-path visibility map. A path that
  # exists only in non-public layers (``wvPublic notin tiers``) is a
  # violation: the lock cannot be reproduced by a public-only operator
  # who cannot acquire the private layer, which is exactly the
  # condition ``Workspace-And-Develop-Mode.md §"Interaction with
  # Locking and Publication"`` proscribes.
  let layerLocations = enumerateManifestLayerLocations(
    parsed.workspaceRoot, workspaceLocal)
  if layerLocations.len == 0:
    result.exitCode = 0
    return
  if parsed.currentRepo.len == 0:
    result.exitCode = 0
    return
  let currentRepoAbs = parsed.currentRepo
  # Robust same-path test. Bare ``==`` is too brittle on Windows: the
  # workspace.toml's ``local_path`` may be written with forward
  # slashes (the test fixtures do, to avoid TOML basic-string ``\U``
  # escape collisions on Windows paths), while ``--current-repo`` is
  # passed in native backslashed form. The same on-disk directory
  # would then compare unequal and the gate would silently skip the
  # visibility check. Normalise separators, casing, and absolute form
  # before comparing.
  proc samePath(a, b: string): bool =
    if a == b: return true
    let
      aN = os.normalizedPath(absolutePath(a)).replace('\\', '/')
      bN = os.normalizedPath(absolutePath(b)).replace('\\', '/')
    when defined(windows):
      aN.toLowerAscii == bN.toLowerAscii
    else:
      aN == bN
  var currentLayer = none(ManifestLayerLocation)
  for loc in layerLocations:
    if samePath(loc.absPath, currentRepoAbs):
      currentLayer = some(loc)
      break
  if currentLayer.isNone:
    result.exitCode = 0
    return
  if currentLayer.get().visibility != wvPublic:
    # A non-public layer pushing locks is allowed to reference any
    # tier. The spec only blocks public-lock references to private-only
    # repos.
    result.exitCode = 0
    return
  let touchedLocks = lockPathsTouchedInPush(
    identity, currentRepoAbs, parsed.pushedRefsPath, resolved.projectName)
  if touchedLocks.len == 0:
    # No lock changes in this push — the rule is vacuously satisfied.
    result.exitCode = 0
    return
  let pathVisibility = classifyRepoPathVisibility(
    parsed.workspaceRoot, layerLocations, resolved.projectName)
  for relLockPath in touchedLocks:
    let absLockPath = currentRepoAbs / relLockPath.replace('/', DirSep)
    if not fileExists(absLockPath):
      # The touched-lock probe reported a path the diff included but
      # which is no longer on disk (e.g. a renamed file). Treat as a
      # gate refusal so the operator investigates rather than silently
      # passing — the conservative answer.
      result.failures.add(CheckFailure(
        repo: "",
        property: "lock_references_private_repo",
        remediation: "investigate the touched lock file at " & relLockPath &
          " — it appears in the pushed diff but is not on disk",
        evidence: "lock-file-missing-on-disk: " & relLockPath,
        source: relLockPath))
      result.exitCode = 2
      return
    var parsedLock: Lock
    try:
      parsedLock = readLock(absLockPath)
    except CatchableError as err:
      # A malformed lock about to be pushed is itself a refusal-worthy
      # condition — exit-1 (IO/parse) would mask the gate intent. We
      # emit a structured failure with the parse error in the evidence.
      result.failures.add(CheckFailure(
        repo: "",
        property: "lock_references_private_repo",
        remediation: "fix lock-file parse error at " & relLockPath &
          " before pushing",
        evidence: "lock-parse-failed: " & err.msg,
        source: relLockPath))
      result.exitCode = 2
      return
    for lockedRepo in parsedLock.repo:
      let tiers =
        if lockedRepo.path in pathVisibility:
          pathVisibility[lockedRepo.path]
        else: {}
      # An unknown path (not declared by any layer's project file) is
      # treated as "private-only": no public layer publishes it, so a
      # public-only operator cannot reproduce the entry. Skipping such
      # paths silently would defeat the spec rule.
      if wvPublic notin tiers:
        let tierLabel =
          if tiers.len > 0: visibilitySetLabel(tiers)
          else: "<undeclared>"
        let layerProv = currentLayer.get().provenance
        result.failures.add(CheckFailure(
          repo: lockedRepo.path,
          property: "lock_references_private_repo",
          remediation:
            "remove the private-only repo '" & lockedRepo.path &
            "' from the lock '" & relLockPath &
            "' before publishing it to the public manifest layer '" &
            layerProv & "', or publish the lock under a non-public " &
            "manifest layer instead",
          evidence: "lock=" & relLockPath &
            " repo=" & lockedRepo.path &
            " visibility=" & tierLabel,
          source: relLockPath))
        result.exitCode = 2
        return
  result.exitCode = 0

proc writeCheckReport(report: CheckReport) =
  ## Persist the structured JSON report at the spec-mandated location.
  let reportDir = report.workspaceRoot / ".repro" / "workspace"
  createDir(reportDir)
  let reportPath = reportDir / "check-report.json"
  writeFile(reportPath, pretty(report.toJsonNode(), indent = 2) & "\n")

proc runCheckCommand*(args: openArray[string]): int =
  ## ``repro check --mode=pre-push [--workspace-root=PATH]
  ## [--current-repo=PATH] [--pushed-refs=FILE]
  ## [--tool-provisioning=path|nix|tarball|scoop] [--json]``.
  ##
  ## Exit codes (per M18 / M23 design):
  ##   - 0 — every gate check passed; the lock was created / refreshed
  ##         when it was missing or stale.
  ##   - 2 — a publication-gate check (branch / clean / published /
  ##         develop-override cleanliness / lock) failed. Git aborts
  ##         the push.
  ##   - 1 — IO / resolve / VCS-tool failure unrelated to the gate.
  let parsed =
    try:
      parseCheckArgs(args)
    except ValueError as err:
      stderr.writeLine("repro check: " & err.msg)
      return 1
  case parsed.mode
  of cmPrePush:
    var report: CheckReport
    try:
      report = executeCheckPrePush(parsed)
    except CatchableError as err:
      stderr.writeLine("repro check: error: " & err.msg)
      return 1
    writeCheckReport(report)
    if parsed.json:
      stdout.writeLine(pretty(report.toJsonNode(), indent = 2))
    else:
      for line in renderCheckTextLines(report):
        stdout.writeLine(line)
    return report.exitCode

# ---- M12: `repro workspace status / list / manifests` ---------------------
#
# Three read-only introspection commands per
# ``reprobuild-specs/CLI/workspace.md``:
#
#   * ``status``    — consumes the M4 evidence schema. Walks every repo
#                     the resolver (or M8 composer) declares, gathers a
#                     fresh ``WorkspaceVcsEvidence`` triple (head-sha,
#                     is-clean, is-published), and compares each live
#                     HEAD against the most-recently-locked SHA in the
#                     M11 lock-index (when one is present). Emits a
#                     workspace-level header (project, active branch,
#                     manifest-layer drift flag) plus a per-repo body.
#
#   * ``list``      — walks the M6 resolver result and prints the
#                     declared (name, path, remote, revision) tuples
#                     plus M8 layer provenance / visibility tags. No
#                     live VCS queries: this is purely "what does the
#                     manifest say my workspace should contain".
#
#   * ``manifests`` — enumerates the M8 layer set declared in
#                     ``.repo/workspace.toml``: per-layer URL or
#                     local_path, visibility tier, the layer's on-disk
#                     checkout path, and the list of composed repos
#                     each layer ultimately contributed to. When no
#                     workspace.toml is present, prints a single
#                     "no layered workspace" line and exits 0.
#
# All three follow the M9/M10/M11 convention: parse argv, build a
# typed report, render text lines, write the JSON artifact at
# ``<workspaceRoot>/.repro/workspace/<command>-report.json``. Exit
# codes are 0 on success and 1 on IO / resolve failure; there is no
# refuse-and-report branch (these are read-only commands).
#
# ``--json`` mode: when set, suppress the text rendering and print
# only the JSON report to stdout (in addition to writing it under
# ``.repro/workspace/``). Convenient for scripts that want a single
# parseable payload without the human-readable noise.

# ---- M12 shared visibility-tag helper -------------------------------------

proc visibilityTag(visibility: WorkspaceVisibility): string =
  ## Stable string tag for a ``WorkspaceVisibility`` value, used by
  ## both ``list`` and ``manifests`` for their JSON shape and text
  ## rendering. Mirrors the strings the workspace.toml schema accepts
  ## (with "personal" as the canonical name for the per-developer
  ## tier; "private" is treated as a synonym in compose.nim).
  case visibility
  of wvPublic: "public"
  of wvOrg: "org"
  of wvTeam: "team"
  of wvPersonal: "personal"

# ---- M12.A: `repro workspace status` --------------------------------------

type
  WorkspaceStatusRepoEntry* = object
    ## One per declared repo in the live workspace. ``lockState`` is
    ## the three-valued comparison vs the most-recently-locked SHA:
    ## ``at-lock`` / ``drifted-from-lock`` / ``no-lock-recorded``.
    ## ``checkoutState`` is one of ``missing`` / ``dirty`` / ``clean``
    ## and is derived from the M4 evidence ``isClean`` field plus a
    ## directory-existence pre-check.
    name*: string
    path*: string
    branch*: string
    headSha*: string
    isClean*: bool
    isPublished*: bool
    diagnostic*: string
    expectedRevision*: string
    checkoutState*: string
    lockedRevision*: string
    lockState*: string
    manifestLayer*: string

  WorkspaceStatusManifestEntry* = object
    ## One per refreshed manifest layer (M10's ``refreshManifestLayers``
    ## output). M12 mirrors the M10 sync report's shape so the JSON
    ## stays uniform.
    index*: int
    provenance*: string
    layerPath*: string
    status*: string
    beforeSha*: string
    afterSha*: string
    diagnostic*: string

  WorkspaceStatusReport* = object
    ## Structured outcome of one ``repro workspace status`` invocation.
    ## ``activeBranch`` is the workspace's advisory branch — see the
    ## comment on ``deriveActiveBranch`` for the heuristic M12 uses
    ## (M13 will replace this with a metadata-backed value).
    project*: string
    workspaceRoot*: string
    activeBranch*: string
    manifestLayerRoot*: string
    lockIndexPath*: string
    hasLockIndex*: bool
    manifestLayers*: seq[WorkspaceStatusManifestEntry]
    repos*: seq[WorkspaceStatusRepoEntry]
    summary*: tuple[clean, dirty, missing, drifted, atLock,
      noLockRecorded: int]
    exitCode*: int

proc toJsonNode*(report: WorkspaceStatusReport): JsonNode =
  result = newJObject()
  result["project"] = %report.project
  result["workspaceRoot"] = %report.workspaceRoot
  result["activeBranch"] = %report.activeBranch
  result["manifestLayerRoot"] = %report.manifestLayerRoot
  result["lockIndexPath"] = %report.lockIndexPath
  result["hasLockIndex"] = %report.hasLockIndex
  var layers = newJArray()
  for entry in report.manifestLayers:
    var obj = newJObject()
    obj["index"] = %entry.index
    obj["provenance"] = %entry.provenance
    obj["layerPath"] = %entry.layerPath
    obj["status"] = %entry.status
    obj["beforeSha"] = %entry.beforeSha
    obj["afterSha"] = %entry.afterSha
    obj["diagnostic"] = %entry.diagnostic
    layers.add(obj)
  result["manifestLayers"] = layers
  var repos = newJArray()
  for entry in report.repos:
    var obj = newJObject()
    obj["name"] = %entry.name
    obj["path"] = %entry.path
    obj["branch"] = %entry.branch
    obj["headSha"] = %entry.headSha
    obj["isClean"] = %entry.isClean
    obj["isPublished"] = %entry.isPublished
    obj["diagnostic"] = %entry.diagnostic
    obj["expectedRevision"] = %entry.expectedRevision
    obj["checkoutState"] = %entry.checkoutState
    obj["lockedRevision"] = %entry.lockedRevision
    obj["lockState"] = %entry.lockState
    obj["manifestLayer"] = %entry.manifestLayer
    repos.add(obj)
  result["repos"] = repos
  var summary = newJObject()
  summary["clean"] = %report.summary.clean
  summary["dirty"] = %report.summary.dirty
  summary["missing"] = %report.summary.missing
  summary["drifted"] = %report.summary.drifted
  summary["atLock"] = %report.summary.atLock
  summary["noLockRecorded"] = %report.summary.noLockRecorded
  result["summary"] = summary
  result["exitCode"] = %report.exitCode

proc renderStatusTextLines*(report: WorkspaceStatusReport): seq[string] =
  result.add("workspace status: project=" & report.project &
    " branch=" & (if report.activeBranch.len > 0:
                    report.activeBranch
                  else: "<none>"))
  if report.hasLockIndex:
    result.add("workspace status: lock-index=" & report.lockIndexPath)
  else:
    result.add("workspace status: no lock-index recorded")
  for entry in report.manifestLayers:
    result.add("workspace status: manifest-layer " & entry.provenance &
      " status=" & entry.status)
  for entry in report.repos:
    var line = "workspace status: " & entry.path & " " &
      entry.checkoutState
    if entry.branch.len > 0:
      line.add(" branch=" & entry.branch)
    if entry.headSha.len > 0:
      line.add(" head=" & entry.headSha[0 ..< min(8, entry.headSha.len)])
    line.add(" lock=" & entry.lockState)
    if entry.diagnostic.len > 0:
      line.add(" (" & entry.diagnostic & ")")
    result.add(line)
  result.add("workspace status: summary clean=" & $report.summary.clean &
    " dirty=" & $report.summary.dirty &
    " missing=" & $report.summary.missing &
    " drifted=" & $report.summary.drifted &
    " atLock=" & $report.summary.atLock &
    " noLockRecorded=" & $report.summary.noLockRecorded)

type
  WorkspaceStatusArgs = object
    workspaceRoot: string
    projectName: string
    json: bool
    toolProvisioning: ToolProvisioningMode

proc parseWorkspaceStatusArgs(args: openArray[string]): WorkspaceStatusArgs =
  ## ``repro workspace status`` argv parser. The single optional
  ## positional is the project name (only required when no
  ## ``.repo/workspace.toml`` is present — same dispatch rule as
  ## M10's sync and M11's lock commands). Optional flags:
  ##   ``--workspace-root=PATH``
  ##   ``--tool-provisioning=path|nix|tarball|scoop``
  ##   ``--json``  — print the JSON report to stdout in place of text.
  result.workspaceRoot = ""
  result.toolProvisioning = tpmPathOnly
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--workspace-root" or arg.startsWith("--workspace-root="):
      result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
    elif arg == "--tool-provisioning" or
        arg.startsWith("--tool-provisioning="):
      result.toolProvisioning = parseToolProvisioning(
        valueFromFlag(args, i, "--tool-provisioning"))
    elif arg == "--json":
      result.json = true
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported `repro workspace status` flag: " & arg)
    elif result.projectName.len == 0:
      result.projectName = arg
    else:
      raise newException(ValueError,
        "unexpected positional argument to `repro workspace status`: " &
          arg)
    inc i
  if result.workspaceRoot.len == 0:
    result.workspaceRoot = getCurrentDir()
  result.workspaceRoot = absolutePath(result.workspaceRoot)

proc resolveWorkspaceStatusProject(parsed: WorkspaceStatusArgs):
    tuple[resolved: ResolvedProject;
          workspaceLocal: Option[WorkspaceLocal]] =
  ## Same dispatch rule as M10 / M11: prefer ``.repo/workspace.toml``
  ## when it declares at least one ``[[manifest]]`` layer (composer
  ## mode), otherwise look up the named project / variant. A
  ## metadata-only workspace.toml (M13) routes to single-project mode.
  let workspaceToml = parsed.workspaceRoot / ".repo" / "workspace.toml"
  if isCompositionalWorkspaceToml(parsed.workspaceRoot):
    let absToml = absolutePath(workspaceToml)
    let workspaceLocal = readWorkspaceLocal(absToml)
    let resolved = composeManifestLayers(
      workspaceLocal, parsed.workspaceRoot, absToml)
    return (resolved, some(workspaceLocal))
  if parsed.projectName.len == 0:
    # Allow a metadata-only workspace.toml to supply the project name.
    if fileExists(workspaceToml):
      try:
        let recordedProject =
          readWorkspaceLocal(absolutePath(workspaceToml)).workspace.project
        if recordedProject.len > 0:
          var withProject = parsed
          withProject.projectName = recordedProject
          return resolveWorkspaceStatusProject(withProject)
      except WorkspaceManifestParseError:
        discard
    raise newException(ValueError,
      "`repro workspace status` requires either `.repo/workspace.toml` " &
        "or a <project> argument; neither was present at " &
        parsed.workspaceRoot)
  let manifestsRoot = parsed.workspaceRoot / ".repo" / "manifests"
  let projectFile = manifestsRoot / "projects" /
    (parsed.projectName & ".toml")
  let variantFile = manifestsRoot / "variants" /
    (parsed.projectName & ".toml")
  if fileExists(projectFile):
    return (resolveProject(projectFile), none(WorkspaceLocal))
  if fileExists(variantFile):
    return (resolveVariant(variantFile), none(WorkspaceLocal))
  raise newException(ValueError,
    "no project or variant named '" & parsed.projectName &
      "' found under '" & manifestsRoot &
      "' (looked for '" & projectFile & "' and '" & variantFile & "')")

proc pickStatusManifestLayerRoot(workspaceRoot: string;
    workspaceLocal: Option[WorkspaceLocal]): string =
  ## Resolve the manifest-layer root that OWNS the lock-index for
  ## status's drift comparison. Mirrors M11's ``pickManifestLayerRoot``
  ## but without the ``--manifest-layer-root`` override (status is
  ## read-only and uses the same anchor M11 wrote to).
  if workspaceLocal.isSome:
    let local = workspaceLocal.get()
    if local.manifest.len > 0:
      let first = local.manifest[0]
      if first.local_path.isSome and first.local_path.get().len > 0:
        let raw = first.local_path.get()
        if isAbsolute(raw):
          return raw
        return workspaceRoot / raw
      if first.url.isSome and first.url.get().len > 0:
        # Mirror the composer's directory-naming convention so the
        # status reader finds the lock written by the M11 dispatcher
        # at the same on-disk path.
        let sanitizedSegments = block:
          var raw1 = ""
          for ch in first.url.get():
            case ch
            of 'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_': raw1.add(ch)
            else: raw1.add('-')
          var collapsed = ""
          var prevDash = false
          for ch in raw1:
            if ch == '-':
              if not prevDash: collapsed.add(ch)
              prevDash = true
            else:
              collapsed.add(ch)
              prevDash = false
          if collapsed.len > 80:
            collapsed.setLen(80)
          collapsed.strip(chars = {'-'},
            leading = true, trailing = true)
        let suffix =
          if sanitizedSegments.len > 0: sanitizedSegments
          else: "layer"
        return workspaceRoot / ".repo" / ("manifests-0-" & suffix)
  workspaceRoot / ".repo" / "manifests"

proc deriveActiveBranch(workspaceRoot: string;
    workspaceLocal: Option[WorkspaceLocal];
    resolved: ResolvedProject; repos: seq[WorkspaceStatusRepoEntry]): string =
  ## M13 — Workspace-metadata-backed active branch, with the original
  ## M12 heuristic preserved as a fallback for workspaces created
  ## before M13 landed (no recorded ``[workspace].branch``). Precedence:
  ##   1. ``.repo/workspace.toml``'s ``[workspace].branch`` field. M13
  ##      writes this during ``repro workspace init`` (single-project
  ##      mode) and the M8 composer-mode workspaces already carry it
  ##      from the user's own metadata. Reading via
  ##      ``readWorkspaceBranch`` covers BOTH composer- and
  ##      single-project-mode workspaces uniformly, so we no longer
  ##      need a separate composer-mode check before this branch.
  ##   2. The first repo whose live HEAD reports a non-empty branch
  ##      (the original M12 heuristic — typical case: a clean
  ##      workspace where every repo is on the same branch). Used for
  ##      legacy workspaces created before M13 wrote the metadata.
  ##   3. The resolver's ``trunk`` field (the manifest's documented
  ##      default branch, e.g. ``main``). Used when no live repo
  ##      checkout reports a current branch.
  ##   4. Empty string.
  try:
    let recorded = readWorkspaceBranch(workspaceRoot)
    if recorded.isSome:
      return recorded.get()
  except WorkspaceManifestParseError:
    # A malformed workspace.toml: fall back to the M12 heuristic so
    # ``status`` still produces a useful answer. The dispatcher will
    # have already surfaced the structured diagnostic if needed.
    discard
  # Composer-mode workspaces that pre-date M13 and never re-ran init
  # carry their branch directly on the parsed ``WorkspaceLocal`` — the
  # ``readWorkspaceBranch`` path above already covers them, but we
  # leave this defensive check in place for parity with the M12
  # heuristic when the strict reader had to bail out.
  if workspaceLocal.isSome and
      workspaceLocal.get().workspace.branch.isSome and
      workspaceLocal.get().workspace.branch.get().len > 0:
    return workspaceLocal.get().workspace.branch.get()
  for entry in repos:
    if entry.branch.len > 0:
      return entry.branch
  resolved.trunk

proc executeWorkspaceStatus(args: WorkspaceStatusArgs): WorkspaceStatusReport =
  var report: WorkspaceStatusReport
  report.workspaceRoot = args.workspaceRoot

  let (resolved, workspaceLocal) = resolveWorkspaceStatusProject(args)
  report.project = resolved.projectName

  # Pre-resolution: gather the manifest-layer refresh result the
  # M10 helper exposes. This populates the structured per-layer
  # ``status`` field even when there is no workspace.toml (the helper
  # returns an empty report in that case, which yields no entries).
  # Note: we DO NOT mutate any layer here — the M10 helper only
  # fetches + fast-forwards, which is the read-only behaviour M12's
  # status command needs.
  try:
    let refresh = refreshManifestLayers(args.workspaceRoot)
    for entry in refresh.layers:
      report.manifestLayers.add(WorkspaceStatusManifestEntry(
        index: entry.index,
        provenance: entry.provenance,
        layerPath: entry.layerPath,
        status: manifestLayerStatusTag(entry.status),
        beforeSha: entry.beforeSha,
        afterSha: entry.afterSha,
        diagnostic: entry.diagnostic))
  except CatchableError:
    # A refresh failure is non-fatal for read-only status: leave the
    # manifestLayers slice empty and continue. The per-repo
    # observation pass below still works.
    discard

  let manifestLayerRoot = pickStatusManifestLayerRoot(
    args.workspaceRoot, workspaceLocal)
  report.manifestLayerRoot = manifestLayerRoot

  let indexPath = lockIndexPath(manifestLayerRoot, resolved.projectName)
  report.lockIndexPath = indexPath
  report.hasLockIndex = fileExists(indexPath)
  let lockedShas =
    if report.hasLockIndex:
      readLatestLockedShasByPath(manifestLayerRoot, resolved.projectName)
    else:
      initTable[string, string]()

  let identity = ensureGitToolResolvable(
    args.toolProvisioning, getEnv("PATH"))
  installGitVcsExecutor()
  let toolDigest = digestHex(identity)
  let observedAt = getTime().toUnix * 1000

  for repo in resolved.repos:
    let repoAbsPath = args.workspaceRoot / repo.path
    var entry: WorkspaceStatusRepoEntry
    entry.name = repo.name
    entry.path = repo.path
    entry.expectedRevision = repo.revision
    entry.manifestLayer = repo.manifestLayer

    if not dirExists(repoAbsPath / ".git"):
      entry.checkoutState = "missing"
      entry.lockState =
        if repo.path in lockedShas: "missing-but-locked"
        elif report.hasLockIndex: "no-lock-recorded"
        else: "no-lock-recorded"
      inc report.summary.missing
      report.repos.add(entry)
      continue

    let headRes = queryGitState(headShaQuery(repoAbsPath), identity)
    let cleanRes = queryGitState(isCleanQuery(repoAbsPath), identity)
    let pubRes = queryGitState(
      isPublishedQuery(repoAbsPath, "origin"), identity)
    # Build the M4 evidence triple — head-sha / is-clean / is-published —
    # so a future caller that wants the unified record can construct it
    # from the same observation set we use here. We do not persist the
    # SSZ envelope inside the M12 report (the JSON view is what status
    # needs), but the three queries are what the M4 schema folds.
    let evHeadSha = workspaceVcsEvidence.evidenceFor(
      headRes, repo.path, wvqHeadSha, toolDigest, observedAt)
    let evIsClean = workspaceVcsEvidence.evidenceFor(
      cleanRes, repo.path, wvqIsClean, toolDigest, observedAt)
    let evIsPub = workspaceVcsEvidence.evidenceFor(
      pubRes, repo.path, wvqIsPublished, toolDigest, observedAt)

    entry.headSha = evHeadSha.headSha
    entry.isClean = evIsClean.status == wvesResolved and evIsClean.isClean
    entry.isPublished = evIsPub.status == wvesResolved and evIsPub.isPublished

    var diagnostic = ""
    if evHeadSha.status == wvesFailed: diagnostic.add(evHeadSha.diagnostic)
    if evIsClean.status == wvesFailed:
      if diagnostic.len > 0: diagnostic.add("; ")
      diagnostic.add(evIsClean.diagnostic)
    entry.diagnostic = diagnostic

    let branchRes = gitRunPlain(identity,
      ["-C", repoAbsPath, "symbolic-ref", "--short", "-q", "HEAD"])
    if branchRes.code == 0:
      entry.branch = branchRes.output.strip()

    if not entry.isClean:
      entry.checkoutState = "dirty"
      inc report.summary.dirty
    else:
      entry.checkoutState = "clean"
      inc report.summary.clean

    if not report.hasLockIndex:
      entry.lockState = "no-lock-recorded"
      inc report.summary.noLockRecorded
    elif repo.path notin lockedShas:
      # Index exists but does not name this repo (e.g. the project's
      # repo set has changed since the most recent lock).
      entry.lockState = "no-lock-recorded"
      inc report.summary.noLockRecorded
    else:
      entry.lockedRevision = lockedShas[repo.path]
      if entry.lockedRevision == entry.headSha:
        entry.lockState = "at-lock"
        inc report.summary.atLock
      else:
        entry.lockState = "drifted-from-lock"
        inc report.summary.drifted

    report.repos.add(entry)

  report.activeBranch = deriveActiveBranch(
    args.workspaceRoot, workspaceLocal, resolved, report.repos)
  report.exitCode = 0
  result = report

proc writeWorkspaceStatusReport(report: WorkspaceStatusReport) =
  let reportDir = report.workspaceRoot / ".repro" / "workspace"
  createDir(reportDir)
  let reportPath = reportDir / "status-report.json"
  writeFile(reportPath, pretty(report.toJsonNode(), indent = 2) & "\n")

proc runWorkspaceStatusCommand*(args: openArray[string]): int =
  ## ``repro workspace status [<project>] [--workspace-root=PATH]
  ## [--tool-provisioning=path|nix|tarball|scoop] [--json]``.
  ##
  ## Exit codes (per M12 design — read-only command):
  ##   - 0 — status gathered (with whatever drift the live workspace
  ##         exhibits — drift is information, not a failure).
  ##   - 1 — IO failure, missing project, or resolver error.
  let parsed = parseWorkspaceStatusArgs(args)
  let report = executeWorkspaceStatus(parsed)
  writeWorkspaceStatusReport(report)
  if parsed.json:
    stdout.writeLine(pretty(report.toJsonNode(), indent = 2))
  else:
    for line in renderStatusTextLines(report):
      stdout.writeLine(line)
  report.exitCode

# ---- M12.B: `repro workspace list` ----------------------------------------

type
  WorkspaceListRepoEntry* = object
    ## One per declared repo in the resolved project. Mirrors the
    ## ``ResolvedRepo`` field set the M6 resolver / M8 composer emit
    ## without doing any live-VCS observation.
    name*: string
    path*: string
    remote*: string
    fetchUrl*: string
    revision*: string
    vcs*: string
    stability*: string
    manifestLayer*: string
    visibility*: string
    fragmentPath*: string

  WorkspaceListReport* = object
    ## Structured outcome of one ``repro workspace list`` invocation.
    project*: string
    workspaceRoot*: string
    projectFile*: string
    defaultRevision*: string
    trunk*: string
    repos*: seq[WorkspaceListRepoEntry]
    exitCode*: int

proc toJsonNode*(report: WorkspaceListReport): JsonNode =
  result = newJObject()
  result["project"] = %report.project
  result["workspaceRoot"] = %report.workspaceRoot
  result["projectFile"] = %report.projectFile
  result["defaultRevision"] = %report.defaultRevision
  result["trunk"] = %report.trunk
  var repos = newJArray()
  for entry in report.repos:
    var obj = newJObject()
    obj["name"] = %entry.name
    obj["path"] = %entry.path
    obj["remote"] = %entry.remote
    obj["fetchUrl"] = %entry.fetchUrl
    obj["revision"] = %entry.revision
    obj["vcs"] = %entry.vcs
    obj["stability"] = %entry.stability
    obj["manifestLayer"] = %entry.manifestLayer
    obj["visibility"] = %entry.visibility
    obj["fragmentPath"] = %entry.fragmentPath
    repos.add(obj)
  result["repos"] = repos
  result["exitCode"] = %report.exitCode

proc renderListTextLines*(report: WorkspaceListReport): seq[string] =
  result.add("workspace list: project=" & report.project &
    (if report.trunk.len > 0: " trunk=" & report.trunk else: ""))
  for entry in report.repos:
    var line = "workspace list: " & entry.path & " name=" & entry.name &
      " remote=" & entry.remote & " revision=" & entry.revision
    if entry.manifestLayer.len > 0:
      line.add(" layer=" & entry.manifestLayer)
    line.add(" visibility=" & entry.visibility)
    result.add(line)

type
  WorkspaceListArgs = object
    workspaceRoot: string
    projectName: string
    json: bool

proc parseWorkspaceListArgs(args: openArray[string]): WorkspaceListArgs =
  ## ``repro workspace list`` argv parser. Same dispatch rules as
  ## status — optional positional ``<project>`` for single-project
  ## mode, ``--workspace-root=PATH``, ``--json``. No
  ## ``--tool-provisioning``: list does no live VCS work.
  result.workspaceRoot = ""
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--workspace-root" or arg.startsWith("--workspace-root="):
      result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
    elif arg == "--json":
      result.json = true
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported `repro workspace list` flag: " & arg)
    elif result.projectName.len == 0:
      result.projectName = arg
    else:
      raise newException(ValueError,
        "unexpected positional argument to `repro workspace list`: " & arg)
    inc i
  if result.workspaceRoot.len == 0:
    result.workspaceRoot = getCurrentDir()
  result.workspaceRoot = absolutePath(result.workspaceRoot)

proc resolveWorkspaceListProject(parsed: WorkspaceListArgs):
    ResolvedProject =
  ## Same dispatch rule as M9/M10/M11/status: prefer
  ## ``.repo/workspace.toml`` when it declares at least one
  ## ``[[manifest]]`` layer (composer mode), otherwise look up the
  ## named project / variant. A metadata-only workspace.toml (M13)
  ## routes to single-project mode.
  let workspaceToml = parsed.workspaceRoot / ".repo" / "workspace.toml"
  if isCompositionalWorkspaceToml(parsed.workspaceRoot):
    return composeManifestLayersFromFile(workspaceToml)
  if parsed.projectName.len == 0:
    # Allow a metadata-only workspace.toml to supply the project name.
    if fileExists(workspaceToml):
      try:
        let recordedProject =
          readWorkspaceLocal(absolutePath(workspaceToml)).workspace.project
        if recordedProject.len > 0:
          var withProject = parsed
          withProject.projectName = recordedProject
          return resolveWorkspaceListProject(withProject)
      except WorkspaceManifestParseError:
        discard
    raise newException(ValueError,
      "`repro workspace list` requires either `.repo/workspace.toml` " &
        "or a <project> argument; neither was present at " &
        parsed.workspaceRoot)
  let manifestsRoot = parsed.workspaceRoot / ".repo" / "manifests"
  let projectFile = manifestsRoot / "projects" /
    (parsed.projectName & ".toml")
  let variantFile = manifestsRoot / "variants" /
    (parsed.projectName & ".toml")
  if fileExists(projectFile):
    return resolveProject(projectFile)
  if fileExists(variantFile):
    return resolveVariant(variantFile)
  raise newException(ValueError,
    "no project or variant named '" & parsed.projectName &
      "' found under '" & manifestsRoot &
      "' (looked for '" & projectFile & "' and '" & variantFile & "')")

proc executeWorkspaceList(args: WorkspaceListArgs): WorkspaceListReport =
  var report: WorkspaceListReport
  report.workspaceRoot = args.workspaceRoot
  let resolved = resolveWorkspaceListProject(args)
  report.project = resolved.projectName
  report.projectFile = resolved.projectFile
  report.defaultRevision = resolved.defaultRevision
  report.trunk = resolved.trunk
  for repo in resolved.repos:
    report.repos.add(WorkspaceListRepoEntry(
      name: repo.name,
      path: repo.path,
      remote: repo.remoteName,
      fetchUrl: repo.fetchUrl,
      revision: repo.revision,
      vcs: repo.vcs,
      stability: repo.stability,
      manifestLayer: repo.manifestLayer,
      visibility: visibilityTag(repo.visibility),
      fragmentPath: repo.fragmentPath))
  report.exitCode = 0
  result = report

proc writeWorkspaceListReport(report: WorkspaceListReport) =
  let reportDir = report.workspaceRoot / ".repro" / "workspace"
  createDir(reportDir)
  let reportPath = reportDir / "list-report.json"
  writeFile(reportPath, pretty(report.toJsonNode(), indent = 2) & "\n")

proc runWorkspaceListCommand*(args: openArray[string]): int =
  ## ``repro workspace list [<project>] [--workspace-root=PATH]
  ## [--json]``.
  ##
  ## Exit codes (per M12 design — read-only command):
  ##   - 0 — repo list emitted.
  ##   - 1 — IO failure, missing project, or resolver error.
  let parsed = parseWorkspaceListArgs(args)
  let report = executeWorkspaceList(parsed)
  writeWorkspaceListReport(report)
  if parsed.json:
    stdout.writeLine(pretty(report.toJsonNode(), indent = 2))
  else:
    for line in renderListTextLines(report):
      stdout.writeLine(line)
  report.exitCode

# ---- M12.C: `repro workspace manifests` -----------------------------------

type
  WorkspaceManifestsLayerEntry* = object
    ## One per layer in ``.repo/workspace.toml``. ``url`` and
    ## ``localPath`` are mutually exclusive (M5 enforces this at parse
    ## time); ``layerCheckoutPath`` is the on-disk directory the
    ## composer materialised (for ``url`` layers) or pointed at (for
    ## ``local_path`` layers). ``contributedRepos`` lists the repo
    ## names this layer ultimately contributed to the composed result
    ## — i.e. the names whose ``manifestLayer`` field matches this
    ## layer's provenance after the composer's shadow-merge resolved.
    index*: int
    url*: string
    localPath*: string
    visibility*: string
    branch*: string
    provenance*: string
    layerCheckoutPath*: string
    contributedRepos*: seq[string]

  WorkspaceManifestsReport* = object
    ## Structured outcome of one ``repro workspace manifests``
    ## invocation. ``hasLayeredWorkspace`` is false when no
    ## ``.repo/workspace.toml`` is present; in that case ``layers`` is
    ## empty and the renderer prints a single "no layered workspace"
    ## line. Otherwise ``layers`` carries one entry per declared layer
    ## in source order.
    workspaceRoot*: string
    workspaceTomlPath*: string
    hasLayeredWorkspace*: bool
    project*: string
    layers*: seq[WorkspaceManifestsLayerEntry]
    exitCode*: int

proc toJsonNode*(report: WorkspaceManifestsReport): JsonNode =
  result = newJObject()
  result["workspaceRoot"] = %report.workspaceRoot
  result["workspaceTomlPath"] = %report.workspaceTomlPath
  result["hasLayeredWorkspace"] = %report.hasLayeredWorkspace
  result["project"] = %report.project
  var layers = newJArray()
  for entry in report.layers:
    var obj = newJObject()
    obj["index"] = %entry.index
    obj["url"] = %entry.url
    obj["localPath"] = %entry.localPath
    obj["visibility"] = %entry.visibility
    obj["branch"] = %entry.branch
    obj["provenance"] = %entry.provenance
    obj["layerCheckoutPath"] = %entry.layerCheckoutPath
    var contributed = newJArray()
    for name in entry.contributedRepos:
      contributed.add(%name)
    obj["contributedRepos"] = contributed
    layers.add(obj)
  result["layers"] = layers
  result["exitCode"] = %report.exitCode

proc renderManifestsTextLines*(report: WorkspaceManifestsReport):
    seq[string] =
  if not report.hasLayeredWorkspace:
    result.add("workspace manifests: no layered workspace " &
      "(.repo/workspace.toml not present at " & report.workspaceRoot & ")")
    return
  result.add("workspace manifests: project=" & report.project &
    " layers=" & $report.layers.len)
  for entry in report.layers:
    var line = "workspace manifests: layer[" & $entry.index & "] " &
      entry.provenance & " visibility=" & entry.visibility
    if entry.branch.len > 0:
      line.add(" branch=" & entry.branch)
    if entry.layerCheckoutPath.len > 0:
      line.add(" checkout=" & entry.layerCheckoutPath)
    line.add(" repos=" & $entry.contributedRepos.len)
    result.add(line)

type
  WorkspaceManifestsArgs = object
    workspaceRoot: string
    json: bool

proc parseWorkspaceManifestsArgs(args: openArray[string]):
    WorkspaceManifestsArgs =
  ## ``repro workspace manifests`` argv parser. No project positional
  ## (the workspace.toml carries the project name); accepts only
  ## ``--workspace-root=PATH`` and ``--json``.
  result.workspaceRoot = ""
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--workspace-root" or arg.startsWith("--workspace-root="):
      result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
    elif arg == "--json":
      result.json = true
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported `repro workspace manifests` flag: " & arg)
    else:
      raise newException(ValueError,
        "unexpected positional argument to `repro workspace manifests`: " &
          arg)
    inc i
  if result.workspaceRoot.len == 0:
    result.workspaceRoot = getCurrentDir()
  result.workspaceRoot = absolutePath(result.workspaceRoot)

proc layerProvenanceString(entry: ManifestLayer): string =
  ## Mirror compose.nim's ``layerLabel`` so this report's
  ## ``provenance`` field matches the value M8 stamped onto each
  ## composed ``ResolvedRepo.manifestLayer``.
  if entry.url.isSome and entry.url.get().len > 0:
    entry.url.get()
  elif entry.local_path.isSome and entry.local_path.get().len > 0:
    entry.local_path.get()
  else:
    "<unknown manifest layer>"

proc layerCheckoutPathFor(workspaceRoot: string; layerIdx: int;
    entry: ManifestLayer): string =
  ## Compute the on-disk checkout path the composer would have
  ## materialised this layer at. For ``local_path`` layers this is
  ## just the (resolved-relative-to-workspaceRoot) path the operator
  ## supplied. For ``url`` layers we reproduce the composer's
  ## directory naming so the path printed by this command matches
  ## whatever M8 actually placed on disk.
  if entry.local_path.isSome and entry.local_path.get().len > 0:
    let raw = entry.local_path.get()
    if isAbsolute(raw): return raw
    return workspaceRoot / raw
  if entry.url.isSome and entry.url.get().len > 0:
    let sanitizedSegments = block:
      var raw1 = ""
      for ch in entry.url.get():
        case ch
        of 'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_': raw1.add(ch)
        else: raw1.add('-')
      var collapsed = ""
      var prevDash = false
      for ch in raw1:
        if ch == '-':
          if not prevDash: collapsed.add(ch)
          prevDash = true
        else:
          collapsed.add(ch)
          prevDash = false
      if collapsed.len > 80:
        collapsed.setLen(80)
      collapsed.strip(chars = {'-'}, leading = true, trailing = true)
    let suffix =
      if sanitizedSegments.len > 0: sanitizedSegments
      else: "layer"
    return workspaceRoot / ".repo" /
      ("manifests-" & $layerIdx & "-" & suffix)
  ""

proc executeWorkspaceManifests(args: WorkspaceManifestsArgs):
    WorkspaceManifestsReport =
  var report: WorkspaceManifestsReport
  report.workspaceRoot = args.workspaceRoot
  let workspaceToml = args.workspaceRoot / ".repo" / "workspace.toml"
  report.workspaceTomlPath = workspaceToml
  if not fileExists(workspaceToml):
    report.hasLayeredWorkspace = false
    report.exitCode = 0
    return report
  # M13: a metadata-only workspace.toml (zero ``[[manifest]]`` entries —
  # written by M9 init in single-project mode to record the active
  # branch) is NOT a layered workspace. Mirror the dispatch sites in
  # init / sync / lock / status / list and treat such a file the same
  # way we treat a missing workspace.toml.
  let absToml = absolutePath(workspaceToml)
  let workspaceLocal = readWorkspaceLocal(absToml)
  if workspaceLocal.manifest.len == 0:
    report.hasLayeredWorkspace = false
    report.project = workspaceLocal.workspace.project
    report.exitCode = 0
    return report
  report.hasLayeredWorkspace = true
  report.project = workspaceLocal.workspace.project

  # Compose the layers to learn which repo each layer ultimately
  # contributed to the result (after the shadow-merge resolved).
  # A composition failure (missing layer, bad URL) leaves the
  # ``contributedRepos`` slice empty for the affected layer entries
  # but still lets us emit the declared structure.
  var contributedByProvenance = initTable[string, seq[string]]()
  try:
    let resolved = composeManifestLayers(
      workspaceLocal, args.workspaceRoot, absToml)
    for repo in resolved.repos:
      let key =
        if repo.manifestLayer.len > 0: repo.manifestLayer
        else: "<unknown manifest layer>"
      var current =
        if key in contributedByProvenance: contributedByProvenance[key]
        else: @[]
      current.add(repo.name)
      contributedByProvenance[key] = current
  except CatchableError:
    # Treat composition failures as "we know the declared layers but
    # not the contribution map". The report still ships with the
    # declared layer set so the operator sees the workspace shape.
    discard

  for layerIdx, entry in workspaceLocal.manifest:
    let provenance = layerProvenanceString(entry)
    var layerEntry = WorkspaceManifestsLayerEntry(
      index: layerIdx,
      url:
        if entry.url.isSome: entry.url.get()
        else: "",
      localPath:
        if entry.local_path.isSome: entry.local_path.get()
        else: "",
      visibility: entry.visibility,
      branch:
        if entry.branch.isSome: entry.branch.get()
        else: "",
      provenance: provenance,
      layerCheckoutPath: layerCheckoutPathFor(
        args.workspaceRoot, layerIdx, entry))
    if provenance in contributedByProvenance:
      layerEntry.contributedRepos = contributedByProvenance[provenance]
    report.layers.add(layerEntry)
  report.exitCode = 0
  result = report

proc writeWorkspaceManifestsReport(report: WorkspaceManifestsReport) =
  let reportDir = report.workspaceRoot / ".repro" / "workspace"
  createDir(reportDir)
  let reportPath = reportDir / "manifests-report.json"
  writeFile(reportPath, pretty(report.toJsonNode(), indent = 2) & "\n")

proc runWorkspaceManifestsCommand*(args: openArray[string]): int =
  ## ``repro workspace manifests [--workspace-root=PATH] [--json]``.
  ##
  ## Exit codes (per M12 design — read-only command):
  ##   - 0 — layer set emitted (also when no workspace.toml is
  ##         present; the report carries ``hasLayeredWorkspace =
  ##         false`` and the text renderer prints the single
  ##         "no layered workspace" line).
  ##   - 1 — IO failure or malformed workspace.toml.
  let parsed = parseWorkspaceManifestsArgs(args)
  let report = executeWorkspaceManifests(parsed)
  writeWorkspaceManifestsReport(report)
  if parsed.json:
    stdout.writeLine(pretty(report.toJsonNode(), indent = 2))
  else:
    for line in renderManifestsTextLines(report):
      stdout.writeLine(line)
  report.exitCode

# ---- M14: `repro branch` (show / create) ----------------------------------
#
# Per ``reprobuild-specs/CLI/branch.md`` and Phase 4 of
# ``reprobuild-specs/Workspace-Management.milestones.org``. Unlike the
# M9–M12 family this is a TOP-LEVEL subcommand (``repro branch``, not
# ``repro workspace branch``) — branch operations are the most frequent
# workspace coordination commands and earn a short alias.
#
# Two forms:
#
#   * ``repro branch`` (no positional)
#       Read-only show form. Returns the recorded
#       ``[workspace].branch`` value from M13 metadata via
#       ``readWorkspaceBranch``. Prints a clear "no active branch"
#       diagnostic and still exits 0 when neither metadata nor a
#       resolver result is available — the operator's question
#       ("what branch am I on?") has a legitimate "none recorded"
#       answer in a fresh workspace that pre-dates M13.
#
#   * ``repro branch <name>`` (create form)
#       Per-repo plan: refuse-and-report when ANY participating repo
#       is dirty (exit 2, no repo modified), refuse-and-report when
#       ANY repo already carries a branch by that name at a different
#       SHA (exit 2 — branch-name collision), idempotently treat a
#       pre-existing branch by that name at the same HEAD as success,
#       and otherwise schedule a ``gitBranchCreate`` action per repo.
#       On success update the M13 metadata's ``[workspace].branch`` to
#       ``<name>``.
#
# Exit codes:
#   * 0 — show form succeeded; or create form succeeded (including
#         the idempotent re-create case).
#   * 1 — IO / VCS / resolve failure that wasn't a refuse-and-report.
#   * 2 — at least one repo was dirty, OR at least one repo had a
#         pre-existing branch by that name pointing at a different
#         SHA (operator has manual work).

type
  BranchRepoOutcome* = enum
    broCreated         ## ``gitBranchCreate`` ran successfully.
    broAlreadyAtHead   ## Pre-existing branch at HEAD — idempotent.
    broDirtyRefused    ## Repo was dirty; nothing scheduled.
    broCollisionRefused
                       ## Pre-existing branch at a different SHA.
    broActionFailed    ## ``gitBranchCreate`` action returned non-OK.

  BranchRepoEntry* = object
    ## Per-repo line in the JSON report. ``existingSha`` carries the
    ## SHA the colliding branch pointed at (empty unless ``outcome``
    ## is ``collision_refused``); ``dirtyReason`` carries the
    ## human-facing reason when ``outcome`` is ``dirty_refused``.
    name*: string
    path*: string
    headSha*: string
    outcome*: string
    existingSha*: string
    dirtyReason*: string
    diagnostic*: string

  BranchReport* = object
    ## Structured outcome of one ``repro branch`` invocation.
    ## ``form`` is ``show`` for the read-only path and ``create`` for
    ## the workspace-wide creation path; ``branch`` is the value the
    ## show form returned, or the requested name on the create path.
    ## ``recordedBranch`` is the value of ``[workspace].branch`` AFTER
    ## the command finished (so a successful create reflects the new
    ## value; a refuse-and-report reflects whatever was already there).
    project*: string
    workspaceRoot*: string
    form*: string
    branch*: string
    recordedBranch*: string
    repos*: seq[BranchRepoEntry]
    exitCode*: int

proc branchOutcomeTag(outcome: BranchRepoOutcome): string =
  case outcome
  of broCreated: "created"
  of broAlreadyAtHead: "already_at_head"
  of broDirtyRefused: "dirty_refused"
  of broCollisionRefused: "collision_refused"
  of broActionFailed: "action_failed"

proc toJsonNode*(report: BranchReport): JsonNode =
  result = newJObject()
  result["project"] = %report.project
  result["workspaceRoot"] = %report.workspaceRoot
  result["form"] = %report.form
  result["branch"] = %report.branch
  result["recordedBranch"] = %report.recordedBranch
  var repos = newJArray()
  for entry in report.repos:
    var obj = newJObject()
    obj["name"] = %entry.name
    obj["path"] = %entry.path
    obj["headSha"] = %entry.headSha
    obj["outcome"] = %entry.outcome
    obj["existingSha"] = %entry.existingSha
    obj["dirtyReason"] = %entry.dirtyReason
    obj["diagnostic"] = %entry.diagnostic
    repos.add(obj)
  result["repos"] = repos
  result["exitCode"] = %report.exitCode

proc renderBranchTextLines*(report: BranchReport): seq[string] =
  if report.form == "show":
    if report.branch.len > 0:
      result.add("workspace branch: " & report.branch)
    else:
      result.add("workspace branch: <none recorded>")
    return
  # create form
  for entry in report.repos:
    var line = "workspace branch: " & entry.path & " " & entry.outcome
    if entry.headSha.len > 0:
      line.add(" head=" &
        entry.headSha[0 ..< min(8, entry.headSha.len)])
    if entry.existingSha.len > 0:
      line.add(" existing=" &
        entry.existingSha[0 ..< min(8, entry.existingSha.len)])
    if entry.dirtyReason.len > 0:
      line.add(" (" & entry.dirtyReason & ")")
    elif entry.diagnostic.len > 0:
      line.add(" (" & entry.diagnostic & ")")
    result.add(line)
  if report.exitCode == 0:
    result.add("workspace branch: '" & report.branch &
      "' created across " & $report.repos.len & " repos; metadata=" &
      report.recordedBranch)

type
  BranchArgs = object
    workspaceRoot: string
    projectName: string
    branchName: string
    json: bool
    toolProvisioning: ToolProvisioningMode

proc parseBranchArgs*(args: openArray[string]): BranchArgs =
  ## ``repro branch [<name>] [--workspace-root=PATH]
  ## [--tool-provisioning=path|nix|tarball|scoop] [--json]``.
  ## The positional, when present, is the new branch name. ``project``
  ## is intentionally NOT a positional here — the M14 spec is a single
  ## ``<name>`` slot, and the active project is recovered either from
  ## a composer-mode ``.repo/workspace.toml`` or from a metadata-only
  ## workspace.toml's ``[workspace].project`` field (the M13 schema).
  result.workspaceRoot = ""
  result.toolProvisioning = tpmPathOnly
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--workspace-root" or arg.startsWith("--workspace-root="):
      result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
    elif arg == "--tool-provisioning" or
        arg.startsWith("--tool-provisioning="):
      result.toolProvisioning = parseToolProvisioning(
        valueFromFlag(args, i, "--tool-provisioning"))
    elif arg == "--json":
      result.json = true
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported `repro branch` flag: " & arg)
    elif result.branchName.len == 0:
      result.branchName = arg
    else:
      raise newException(ValueError,
        "unexpected positional argument to `repro branch`: " & arg)
    inc i
  if result.workspaceRoot.len == 0:
    result.workspaceRoot = getCurrentDir()
  result.workspaceRoot = absolutePath(result.workspaceRoot)

proc resolveBranchProject(parsed: BranchArgs):
    tuple[resolved: ResolvedProject;
          workspaceLocal: Option[WorkspaceLocal]] =
  ## Same dispatch rule as M9–M13: composer mode when
  ## ``.repo/workspace.toml`` declares ``[[manifest]]`` layers,
  ## single-project mode otherwise. The single-project path needs a
  ## project name; we recover it from a metadata-only workspace.toml's
  ## ``[workspace].project`` field rather than asking the user to
  ## repeat it (M13's contract).
  let workspaceToml = parsed.workspaceRoot / ".repo" / "workspace.toml"
  if isCompositionalWorkspaceToml(parsed.workspaceRoot):
    let absToml = absolutePath(workspaceToml)
    let workspaceLocal = readWorkspaceLocal(absToml)
    let resolved = composeManifestLayers(
      workspaceLocal, parsed.workspaceRoot, absToml)
    return (resolved, some(workspaceLocal))
  var projectName = parsed.projectName
  if projectName.len == 0 and fileExists(workspaceToml):
    try:
      let recorded =
        readWorkspaceLocal(absolutePath(workspaceToml)).workspace.project
      if recorded.len > 0:
        projectName = recorded
    except WorkspaceManifestParseError:
      discard
  if projectName.len == 0:
    raise newException(ValueError,
      "`repro branch <name>` requires either `.repo/workspace.toml` " &
        "or a project name recoverable from one; neither was present at " &
        parsed.workspaceRoot)
  let manifestsRoot = parsed.workspaceRoot / ".repo" / "manifests"
  let projectFile = manifestsRoot / "projects" / (projectName & ".toml")
  let variantFile = manifestsRoot / "variants" / (projectName & ".toml")
  if fileExists(projectFile):
    return (resolveProject(projectFile), none(WorkspaceLocal))
  if fileExists(variantFile):
    return (resolveVariant(variantFile), none(WorkspaceLocal))
  raise newException(ValueError,
    "no project or variant named '" & projectName &
      "' found under '" & manifestsRoot &
      "' (looked for '" & projectFile & "' and '" & variantFile & "')")

proc executeBranchShow(parsed: BranchArgs): BranchReport =
  ## Read-only path. Returns the value recorded in M13 metadata. We
  ## intentionally do NOT consult the live HEAD heuristic that
  ## ``deriveActiveBranch`` falls back on — the M13 contract makes the
  ## metadata-recorded value authoritative, and a workspace that has
  ## never been initialised under M13 legitimately has no recorded
  ## branch.
  result.form = "show"
  result.workspaceRoot = parsed.workspaceRoot
  try:
    let recorded = readWorkspaceBranch(parsed.workspaceRoot)
    if recorded.isSome:
      result.branch = recorded.get()
      result.recordedBranch = recorded.get()
  except WorkspaceManifestParseError as err:
    result.recordedBranch = ""
    result.exitCode = 1
    # Surface the parse diagnostic via a synthetic repo entry so
    # ``--json`` callers don't have to scrape stderr.
    result.repos.add(BranchRepoEntry(
      outcome: "metadata_unreadable",
      diagnostic: err.msg))
    return
  # Best-effort project name recovery for the JSON report's
  # ``project`` field. The show form never fails when no project is
  # recoverable; we just leave the field empty.
  if fileExists(parsed.workspaceRoot / ".repo" / "workspace.toml"):
    try:
      let local = readWorkspaceLocal(
        absolutePath(parsed.workspaceRoot / ".repo" / "workspace.toml"))
      if local.workspace.project.len > 0:
        result.project = local.workspace.project
    except WorkspaceManifestParseError:
      discard
  result.exitCode = 0

proc executeBranchCreate(parsed: BranchArgs): BranchReport =
  ## Workspace-wide create planner. Two-pass:
  ##
  ##   1. Observation pass — for every declared repo gather HEAD SHA,
  ##      clean/dirty, and (if the branch already exists) the
  ##      existing branch tip. Classify into:
  ##      ``ready`` (clean, branch absent), ``ready-idempotent`` (clean,
  ##      branch already at HEAD), ``collision`` (branch at a different
  ##      SHA), ``dirty`` (working tree dirty).
  ##
  ##   2. Decision pass — if ANY repo classified as ``dirty`` or
  ##      ``collision`` we refuse-and-report (exit 2). Otherwise we
  ##      schedule ``gitBranchCreate`` actions for the ``ready`` repos
  ##      and produce ``broCreated`` / ``broAlreadyAtHead`` per repo.
  ##
  ## On success the M13 metadata's ``[workspace].branch`` is updated
  ## via ``writeWorkspaceBranch``. We perform the write AFTER the
  ## per-repo plan succeeds so a refuse-and-report leaves the
  ## metadata exactly as it was.
  result.form = "create"
  result.workspaceRoot = parsed.workspaceRoot
  result.branch = parsed.branchName

  let (resolved, _) = resolveBranchProject(parsed)
  result.project = resolved.projectName

  let identity = ensureGitToolResolvable(
    parsed.toolProvisioning, getEnv("PATH"))
  installGitVcsExecutor()

  # Observation pass.
  type
    RepoStateKind = enum
      rsReady, rsReadyIdempotent, rsCollision, rsDirty, rsProbeFailed
    RepoState = object
      kind: RepoStateKind
      repo: ResolvedRepo
      repoPath: string
      headSha: string
      existingSha: string
      reason: string

  var states: seq[RepoState]
  for repo in resolved.repos:
    var state: RepoState
    state.repo = repo
    state.repoPath = parsed.workspaceRoot / repo.path
    if not dirExists(state.repoPath / ".git"):
      state.kind = rsProbeFailed
      state.reason = "no on-disk checkout at '" & state.repoPath &
        "'; run `repro workspace init` or `repro workspace sync` first"
      states.add(state)
      continue
    let headRes = queryGitState(headShaQuery(state.repoPath), identity)
    if headRes.status != gqsOk:
      state.kind = rsProbeFailed
      state.reason = "head-sha probe failed: " & headRes.diagnostic
      states.add(state)
      continue
    state.headSha = headRes.headSha
    let cleanRes = queryGitState(isCleanQuery(state.repoPath), identity)
    if cleanRes.status != gqsOk:
      state.kind = rsProbeFailed
      state.reason = "clean/dirty probe failed: " & cleanRes.diagnostic
      states.add(state)
      continue
    if not cleanRes.isClean:
      state.kind = rsDirty
      state.reason = "working tree has uncommitted changes"
      states.add(state)
      continue
    # Probe whether the branch already exists locally. ``git rev-parse
    # --verify --quiet refs/heads/<name>`` exits 0 + emits the SHA
    # when it does, exits 1 + emits nothing when it does not.
    let probe = gitRunPlain(identity,
      ["-C", state.repoPath, "rev-parse", "--verify", "--quiet",
       "refs/heads/" & parsed.branchName])
    if probe.code == 0:
      let existing = probe.output.strip()
      if existing == state.headSha:
        state.kind = rsReadyIdempotent
        state.existingSha = existing
      else:
        state.kind = rsCollision
        state.existingSha = existing
        state.reason = "branch '" & parsed.branchName &
          "' already exists at " & existing & " (≠ HEAD " &
          state.headSha & ")"
    elif probe.output.strip().len == 0:
      state.kind = rsReady
    else:
      state.kind = rsProbeFailed
      state.reason = "git rev-parse --verify exited " & $probe.code &
        ": " & probe.output.strip()
    states.add(state)

  # Decision pass.
  var dirtyCount = 0
  var collisionCount = 0
  var probeFailures = 0
  for state in states:
    case state.kind
    of rsDirty: inc dirtyCount
    of rsCollision: inc collisionCount
    of rsProbeFailed: inc probeFailures
    else: discard

  if probeFailures > 0:
    # Probe failure is a hard error: we cannot reason about the
    # workspace's state at all. Distinct from dirty/collision (which
    # are operator-visible policy outcomes).
    for state in states:
      var entry = BranchRepoEntry(
        name: state.repo.name,
        path: state.repo.path,
        headSha: state.headSha,
        existingSha: state.existingSha)
      case state.kind
      of rsProbeFailed:
        entry.outcome = "probe_failed"
        entry.diagnostic = state.reason
      of rsDirty:
        entry.outcome = branchOutcomeTag(broDirtyRefused)
        entry.dirtyReason = state.reason
      of rsCollision:
        entry.outcome = branchOutcomeTag(broCollisionRefused)
        entry.diagnostic = state.reason
      of rsReady:
        entry.outcome = "ready"
      of rsReadyIdempotent:
        entry.outcome = branchOutcomeTag(broAlreadyAtHead)
      result.repos.add(entry)
    result.exitCode = 1
    # Recorded branch is whatever the metadata currently has.
    let recorded = readWorkspaceBranch(parsed.workspaceRoot)
    if recorded.isSome:
      result.recordedBranch = recorded.get()
    return

  if dirtyCount > 0 or collisionCount > 0:
    # Refuse-and-report. Surface the per-repo classification but
    # mutate nothing — even the clean repos sit untouched so the
    # operator's "fix the blockers and re-run" loop is atomic.
    for state in states:
      var entry = BranchRepoEntry(
        name: state.repo.name,
        path: state.repo.path,
        headSha: state.headSha,
        existingSha: state.existingSha)
      case state.kind
      of rsDirty:
        entry.outcome = branchOutcomeTag(broDirtyRefused)
        entry.dirtyReason = state.reason
      of rsCollision:
        entry.outcome = branchOutcomeTag(broCollisionRefused)
        entry.diagnostic = state.reason
      of rsReady:
        entry.outcome = "ready"
      of rsReadyIdempotent:
        entry.outcome = branchOutcomeTag(broAlreadyAtHead)
      of rsProbeFailed:
        entry.outcome = "probe_failed"
        entry.diagnostic = state.reason
      result.repos.add(entry)
    result.exitCode = 2
    let recorded = readWorkspaceBranch(parsed.workspaceRoot)
    if recorded.isSome:
      result.recordedBranch = recorded.get()
    return

  # Execute pass: schedule a ``gitBranchCreate`` action for every
  # repo classified as ``rsReady``. The idempotent ``rsReadyIdempotent``
  # repos already point their branch at HEAD; the executor would just
  # short-circuit (already-at-head) so we skip scheduling at the
  # planner level too — fewer actions in the engine graph.
  var actions: seq[BuildAction]
  var actionRepoIndex = initTable[string, int]()
  let receiptDir = parsed.workspaceRoot / ".repro" / "workspace" / "receipts"
  createDir(receiptDir)
  for idx, state in states:
    if state.kind != rsReady:
      continue
    let receiptRel = ".repro" / "workspace" / "receipts" /
      ("branch-create-" & safeRepoIdSegment(state.repo.name) & "-" &
       $idx & ".receipt")
    let actionId = "workspace-branch-create-" &
      safeRepoIdSegment(state.repo.name) & "-" & $idx
    var action = gitBranchCreate(actionId, identity,
      branchName = parsed.branchName,
      repoPath = state.repo.path,
      receiptPath = receiptRel)
    action.cwd = parsed.workspaceRoot
    actions.add(action)
    actionRepoIndex[actionId] = idx

  var perRepoOutcome = initTable[int, tuple[outcome: BranchRepoOutcome;
                                            diagnostic: string]]()
  if actions.len > 0:
    let cacheRoot = parsed.workspaceRoot / ".repro" / "workspace" /
      "engine-cache"
    var config = defaultBuildEngineConfig(cacheRoot)
    config.suppressTrace = true
    let res = runBuild(graph(actions), config)
    var outcomeById = initTable[string, ActionResult]()
    for outcome in res.results:
      outcomeById[outcome.id] = outcome
    for action in actions:
      let outcome = outcomeById.getOrDefault(action.id)
      let idx = actionRepoIndex[action.id]
      if outcome.status notin {asSucceeded, asCacheHit, asUpToDate}:
        var diag = "status=" & $outcome.status &
          " reason=" & outcome.reason
        if outcome.stderr.len > 0:
          diag.add(" stderr=" & outcome.stderr)
        perRepoOutcome[idx] = (outcome: broActionFailed, diagnostic: diag)
      else:
        perRepoOutcome[idx] = (outcome: broCreated, diagnostic: "")

  var actionFailures = 0
  for idx, state in states:
    var entry = BranchRepoEntry(
      name: state.repo.name,
      path: state.repo.path,
      headSha: state.headSha,
      existingSha: state.existingSha)
    case state.kind
    of rsReadyIdempotent:
      entry.outcome = branchOutcomeTag(broAlreadyAtHead)
    of rsReady:
      let r = perRepoOutcome.getOrDefault(idx,
        (outcome: broActionFailed,
         diagnostic: "internal: missing action outcome"))
      entry.outcome = branchOutcomeTag(r.outcome)
      entry.diagnostic = r.diagnostic
      if r.outcome == broActionFailed:
        inc actionFailures
    else:
      # Unreachable here (probe-failed and refuse-and-report paths
      # returned early above); keep the case exhaustive so a future
      # state addition stays compile-safe.
      entry.outcome = "internal_unexpected_state"
    result.repos.add(entry)

  if actionFailures > 0:
    # An action failure under the engine is exit 1 (engine blew up),
    # not exit 2 (operator policy). Record the metadata state we
    # actually achieved — none.
    result.exitCode = 1
    let recorded = readWorkspaceBranch(parsed.workspaceRoot)
    if recorded.isSome:
      result.recordedBranch = recorded.get()
    return

  # Metadata update — write only after every per-repo action
  # succeeded (or the idempotent re-run case classified them all as
  # already-at-head).
  try:
    writeWorkspaceBranch(parsed.workspaceRoot,
      project = resolved.projectName, branch = parsed.branchName)
    result.recordedBranch = parsed.branchName
  except WorkspaceManifestParseError as err:
    # We made VCS-level branches; surfacing the metadata-write error
    # as a non-zero exit is the safer signal so the operator notices
    # and reconciles workspace.toml.
    result.exitCode = 1
    result.recordedBranch = ""
    result.repos.add(BranchRepoEntry(
      outcome: "metadata_write_failed",
      diagnostic: err.msg))
    return

  result.exitCode = 0

proc writeBranchReport(report: BranchReport) =
  let reportDir = report.workspaceRoot / ".repro" / "workspace"
  createDir(reportDir)
  let reportPath = reportDir / "branch-report.json"
  writeFile(reportPath, pretty(report.toJsonNode(), indent = 2) & "\n")

proc runBranchCommand*(args: openArray[string]): int =
  ## ``repro branch [<name>] [--workspace-root=PATH]
  ## [--tool-provisioning=path|nix|tarball|scoop] [--json]``.
  ##
  ## See the M14 block comment above for the contract. Always
  ## writes a ``branch-report.json`` artifact under
  ## ``<workspaceRoot>/.repro/workspace/`` so a script consumer has a
  ## parseable record of what happened, in addition to the
  ## stdout-formatted text lines.
  let parsed = parseBranchArgs(args)
  let report =
    if parsed.branchName.len == 0:
      executeBranchShow(parsed)
    else:
      executeBranchCreate(parsed)
  writeBranchReport(report)
  if parsed.json:
    stdout.writeLine(pretty(report.toJsonNode(), indent = 2))
  else:
    for line in renderBranchTextLines(report):
      stdout.writeLine(line)
  report.exitCode

# --- M15: `repro checkout <branch>` ---------------------------------------
#
# Top-level subcommand per ``reprobuild-specs/CLI/checkout.md``. Same
# convention deviation flagged by M9—M14: the milestone description hints
# at a separate planner module, but the actual implementation lives here
# alongside ``runBranchCommand`` so we reuse the M9/M10/M11/M12/M14
# resolver-and-composer dispatch helpers without a third copy.
#
# Two-pass design (mirrors M14 ``executeBranchCreate``):
#
#   Pass 1 — per-repo observation. For each declared repo gather HEAD
#     SHA, clean/dirty, current branch (so we can detect the no-op
#     ``already-on-branch`` case), local-branch existence, and (if the
#     branch does not exist locally) remote-tracking existence on the
#     standard ``origin`` remote.
#
#     Classification (in priority order):
#       - ``rsRefMissing`` — no on-disk checkout / probe failed.
#       - ``rsDirty`` — working tree has uncommitted changes.
#       - ``rsAlreadyOnBranch`` — clean and ``HEAD`` is the requested
#         branch (no action needed).
#       - ``rsReadyLocal`` — clean, the requested branch already exists
#         as ``refs/heads/<name>`` locally; we can call
#         ``gitSwitchAction`` directly.
#       - ``rsReadyFetchAndTrack`` — clean, branch is absent locally but
#         present on ``origin``; we need ``gitFetchAction`` first, then
#         ``gitSwitchAction`` (git ``switch`` DWIMs the tracking branch
#         when ``refs/remotes/origin/<name>`` is present).
#       - ``rsBranchMissing`` — clean, branch absent both locally AND on
#         every configured remote (refuse).
#
#   Pass 2 — decision. If ANY repo is ``rsBranchMissing``, ``rsDirty``,
#     or ``rsRefMissing`` we refuse-and-report with exit 2 (or exit 1
#     for the probe-failed case) and mutate NOTHING (matching M14's
#     atomicity rule). Otherwise:
#       - ``rsReadyLocal`` repos get a ``gitSwitchAction``.
#       - ``rsReadyFetchAndTrack`` repos get a chained
#         ``gitFetchAction`` then ``gitSwitchAction``. The switch
#         action declares the fetch's receipt as a dep so they run in
#         order in the build graph.
#       - ``rsAlreadyOnBranch`` repos schedule no action.
#     On full success we update ``[workspace].branch`` via
#     ``writeWorkspaceBranch`` so M13 metadata follows the on-disk
#     state.
#
# Exit codes:
#   0 — success (every repo switched / fetched-and-switched /
#       already-on-branch).
#   1 — IO / VCS / probe / engine failure.
#   2 — operator-visible refuse (any dirty repo, OR the requested
#       branch is missing in any repo locally and remotely).
#
# The JSON report at ``<workspaceRoot>/.repro/workspace/checkout-report.json``
# carries the per-repo classification, previous branch, new branch, and
# the post-command ``recordedBranch`` (the M13 metadata value).

type
  CheckoutRepoOutcome* = enum
    croSwitched           ## Local branch existed; ``git switch`` ran.
    croFetchedAndSwitched ## Remote-only branch; fetched + tracked.
    croAlreadyOnBranch    ## Already on the requested branch (no-op).
    croDirtyRefused       ## Repo dirty; nothing scheduled.
    croBranchMissingRefused
                          ## Branch absent locally AND on every remote.
    croProbeFailed        ## Pre-pass probe failed for this repo.
    croActionFailed       ## A scheduled action returned non-OK.

  CheckoutRepoEntry* = object
    ## Per-repo line in the JSON report. ``previousBranch`` is the
    ## branch the repo was on going into the command (empty when
    ## detached); ``newBranch`` is what it is on after — typically the
    ## requested branch on success, the unchanged ``previousBranch`` on
    ## a refuse.
    name*: string
    path*: string
    headSha*: string
    previousBranch*: string
    newBranch*: string
    outcome*: string
    remoteHadBranch*: bool
    localHadBranch*: bool
    dirtyReason*: string
    diagnostic*: string

  CheckoutReport* = object
    ## Structured outcome of one ``repro checkout`` invocation.
    ## ``branch`` is the requested branch; ``recordedBranch`` is what
    ## ``[workspace].branch`` carries AFTER the command finished (the
    ## new branch on success, the pre-existing value on refuse).
    project*: string
    workspaceRoot*: string
    branch*: string
    recordedBranch*: string
    repos*: seq[CheckoutRepoEntry]
    exitCode*: int

proc checkoutOutcomeTag(outcome: CheckoutRepoOutcome): string =
  case outcome
  of croSwitched: "switched"
  of croFetchedAndSwitched: "fetched_and_switched"
  of croAlreadyOnBranch: "already_on_branch"
  of croDirtyRefused: "dirty_refused"
  of croBranchMissingRefused: "branch_missing_refused"
  of croProbeFailed: "probe_failed"
  of croActionFailed: "action_failed"

proc toJsonNode*(report: CheckoutReport): JsonNode =
  result = newJObject()
  result["project"] = %report.project
  result["workspaceRoot"] = %report.workspaceRoot
  result["branch"] = %report.branch
  result["recordedBranch"] = %report.recordedBranch
  var repos = newJArray()
  for entry in report.repos:
    var obj = newJObject()
    obj["name"] = %entry.name
    obj["path"] = %entry.path
    obj["headSha"] = %entry.headSha
    obj["previousBranch"] = %entry.previousBranch
    obj["newBranch"] = %entry.newBranch
    obj["outcome"] = %entry.outcome
    obj["remoteHadBranch"] = %entry.remoteHadBranch
    obj["localHadBranch"] = %entry.localHadBranch
    obj["dirtyReason"] = %entry.dirtyReason
    obj["diagnostic"] = %entry.diagnostic
    repos.add(obj)
  result["repos"] = repos
  result["exitCode"] = %report.exitCode

proc renderCheckoutTextLines*(report: CheckoutReport): seq[string] =
  for entry in report.repos:
    var line = "workspace checkout: " & entry.path & " " & entry.outcome
    if entry.previousBranch.len > 0 and entry.newBranch.len > 0 and
        entry.previousBranch != entry.newBranch:
      line.add(" " & entry.previousBranch & " -> " & entry.newBranch)
    elif entry.newBranch.len > 0:
      line.add(" branch=" & entry.newBranch)
    if entry.dirtyReason.len > 0:
      line.add(" (" & entry.dirtyReason & ")")
    elif entry.diagnostic.len > 0:
      line.add(" (" & entry.diagnostic & ")")
    result.add(line)
  if report.exitCode == 0:
    result.add("workspace checkout: '" & report.branch &
      "' active across " & $report.repos.len &
      " repos; metadata=" & report.recordedBranch)

type
  CheckoutArgs = object
    workspaceRoot: string
    projectName: string
    branchName: string
    json: bool
    toolProvisioning: ToolProvisioningMode

proc parseCheckoutArgs*(args: openArray[string]): CheckoutArgs =
  ## ``repro checkout <branch> [--workspace-root=PATH]
  ## [--tool-provisioning=path|nix|tarball|scoop] [--json]``. The
  ## positional ``<branch>`` is REQUIRED — unlike ``repro branch`` the
  ## argument-less form is not a defined surface for M15.
  result.workspaceRoot = ""
  result.toolProvisioning = tpmPathOnly
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--workspace-root" or arg.startsWith("--workspace-root="):
      result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
    elif arg == "--tool-provisioning" or
        arg.startsWith("--tool-provisioning="):
      result.toolProvisioning = parseToolProvisioning(
        valueFromFlag(args, i, "--tool-provisioning"))
    elif arg == "--json":
      result.json = true
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported `repro checkout` flag: " & arg)
    elif result.branchName.len == 0:
      result.branchName = arg
    else:
      raise newException(ValueError,
        "unexpected positional argument to `repro checkout`: " & arg)
    inc i
  if result.branchName.len == 0:
    raise newException(ValueError,
      "`repro checkout` requires a branch name positional argument")
  if result.workspaceRoot.len == 0:
    result.workspaceRoot = getCurrentDir()
  result.workspaceRoot = absolutePath(result.workspaceRoot)

proc resolveCheckoutProject(parsed: CheckoutArgs):
    tuple[resolved: ResolvedProject;
          workspaceLocal: Option[WorkspaceLocal]] =
  ## Same dispatch rule as M14 ``resolveBranchProject``: composer mode
  ## when ``.repo/workspace.toml`` declares ``[[manifest]]`` layers,
  ## single-project mode otherwise. The single-project path recovers
  ## the project name from a metadata-only workspace.toml's
  ## ``[workspace].project`` field (the M13 schema).
  let workspaceToml = parsed.workspaceRoot / ".repo" / "workspace.toml"
  if isCompositionalWorkspaceToml(parsed.workspaceRoot):
    let absToml = absolutePath(workspaceToml)
    let workspaceLocal = readWorkspaceLocal(absToml)
    let resolved = composeManifestLayers(
      workspaceLocal, parsed.workspaceRoot, absToml)
    return (resolved, some(workspaceLocal))
  var projectName = parsed.projectName
  if projectName.len == 0 and fileExists(workspaceToml):
    try:
      let recorded =
        readWorkspaceLocal(absolutePath(workspaceToml)).workspace.project
      if recorded.len > 0:
        projectName = recorded
    except WorkspaceManifestParseError:
      discard
  if projectName.len == 0:
    raise newException(ValueError,
      "`repro checkout <branch>` requires either `.repo/workspace.toml` " &
        "or a project name recoverable from one; neither was present at " &
        parsed.workspaceRoot)
  let manifestsRoot = parsed.workspaceRoot / ".repo" / "manifests"
  let projectFile = manifestsRoot / "projects" / (projectName & ".toml")
  let variantFile = manifestsRoot / "variants" / (projectName & ".toml")
  if fileExists(projectFile):
    return (resolveProject(projectFile), none(WorkspaceLocal))
  if fileExists(variantFile):
    return (resolveVariant(variantFile), none(WorkspaceLocal))
  raise newException(ValueError,
    "no project or variant named '" & projectName &
      "' found under '" & manifestsRoot &
      "' (looked for '" & projectFile & "' and '" & variantFile & "')")

proc executeCheckout(parsed: CheckoutArgs): CheckoutReport =
  result.workspaceRoot = parsed.workspaceRoot
  result.branch = parsed.branchName

  let (resolved, _) = resolveCheckoutProject(parsed)
  result.project = resolved.projectName

  let identity = ensureGitToolResolvable(
    parsed.toolProvisioning, getEnv("PATH"))
  installGitVcsExecutor()

  # Observation pass.
  type
    RepoStateKind = enum
      rsReadyLocal, rsReadyFetchAndTrack, rsAlreadyOnBranch,
      rsBranchMissing, rsDirty, rsProbeFailed
    RepoState = object
      kind: RepoStateKind
      repo: ResolvedRepo
      repoPath: string
      headSha: string
      previousBranch: string
      localHadBranch: bool
      remoteHadBranch: bool
      reason: string

  var states: seq[RepoState]
  for repo in resolved.repos:
    var state: RepoState
    state.repo = repo
    state.repoPath = parsed.workspaceRoot / repo.path
    if not dirExists(state.repoPath / ".git"):
      state.kind = rsProbeFailed
      state.reason = "no on-disk checkout at '" & state.repoPath &
        "'; run `repro workspace init` or `repro workspace sync` first"
      states.add(state)
      continue
    let headRes = queryGitState(headShaQuery(state.repoPath), identity)
    if headRes.status != gqsOk:
      state.kind = rsProbeFailed
      state.reason = "head-sha probe failed: " & headRes.diagnostic
      states.add(state)
      continue
    state.headSha = headRes.headSha
    # Current branch (empty when detached). ``symbolic-ref --short -q``
    # prints the branch name and exits non-zero in the detached state
    # rather than emitting an error to stderr.
    let branchRes = gitRunPlain(identity,
      ["-C", state.repoPath, "symbolic-ref", "--short", "-q", "HEAD"])
    if branchRes.code == 0:
      state.previousBranch = branchRes.output.strip()
    let cleanRes = queryGitState(isCleanQuery(state.repoPath), identity)
    if cleanRes.status != gqsOk:
      state.kind = rsProbeFailed
      state.reason = "clean/dirty probe failed: " & cleanRes.diagnostic
      states.add(state)
      continue
    if not cleanRes.isClean:
      state.kind = rsDirty
      state.reason = "working tree has uncommitted changes"
      states.add(state)
      continue
    # No-op short circuit: already on the requested branch.
    if state.previousBranch == parsed.branchName:
      state.kind = rsAlreadyOnBranch
      state.localHadBranch = true
      states.add(state)
      continue
    # Probe local branch.
    let localProbe = gitRunPlain(identity,
      ["-C", state.repoPath, "rev-parse", "--verify", "--quiet",
       "refs/heads/" & parsed.branchName])
    if localProbe.code == 0 and localProbe.output.strip().len > 0:
      state.localHadBranch = true
      state.kind = rsReadyLocal
      states.add(state)
      continue
    if localProbe.code != 0 and localProbe.output.strip().len != 0:
      # Genuine probe failure (not just "missing ref"): bail.
      state.kind = rsProbeFailed
      state.reason = "git rev-parse --verify exited " &
        $localProbe.code & ": " & localProbe.output.strip()
      states.add(state)
      continue
    # Local branch missing — probe the configured remote. We ask
    # ``git ls-remote --heads <remote> <branch>`` rather than relying
    # on the remote-tracking ref (which may be stale) so we get a
    # truthful answer even before any fetch. The standard remote name
    # after ``git clone`` is ``origin``.
    let remoteName =
      if repo.remoteName.len > 0: "origin" else: "origin"
    let lsRemote = gitRunPlain(identity,
      ["-C", state.repoPath, "ls-remote", "--heads", remoteName,
       parsed.branchName])
    if lsRemote.code != 0:
      # Network / config failure: treat as probe-failed so the
      # operator sees the real diagnostic rather than a misleading
      # "branch missing" verdict.
      state.kind = rsProbeFailed
      state.reason = "git ls-remote --heads " & remoteName & " " &
        parsed.branchName & " exited " & $lsRemote.code & ": " &
        lsRemote.output.strip()
      states.add(state)
      continue
    if lsRemote.output.strip().len == 0:
      state.kind = rsBranchMissing
      state.reason = "branch '" & parsed.branchName &
        "' is absent locally and not present on remote '" &
        remoteName & "'"
      states.add(state)
      continue
    state.remoteHadBranch = true
    state.kind = rsReadyFetchAndTrack
    states.add(state)

  # Decision pass.
  var dirtyCount = 0
  var missingCount = 0
  var probeFailures = 0
  for state in states:
    case state.kind
    of rsDirty: inc dirtyCount
    of rsBranchMissing: inc missingCount
    of rsProbeFailed: inc probeFailures
    else: discard

  if probeFailures > 0 or dirtyCount > 0 or missingCount > 0:
    # Refuse-and-report path: mutate nothing, surface the per-repo
    # classification. ``rsReadyLocal`` / ``rsReadyFetchAndTrack`` repos
    # report ``ready_*`` (the work was scheduled-then-cancelled by the
    # decision pass) rather than the post-success tag.
    for state in states:
      var entry = CheckoutRepoEntry(
        name: state.repo.name,
        path: state.repo.path,
        headSha: state.headSha,
        previousBranch: state.previousBranch,
        remoteHadBranch: state.remoteHadBranch,
        localHadBranch: state.localHadBranch)
      case state.kind
      of rsAlreadyOnBranch:
        entry.outcome = checkoutOutcomeTag(croAlreadyOnBranch)
        entry.newBranch = parsed.branchName
      of rsDirty:
        entry.outcome = checkoutOutcomeTag(croDirtyRefused)
        entry.dirtyReason = state.reason
        entry.newBranch = state.previousBranch
      of rsBranchMissing:
        entry.outcome = checkoutOutcomeTag(croBranchMissingRefused)
        entry.diagnostic = state.reason
        entry.newBranch = state.previousBranch
      of rsProbeFailed:
        entry.outcome = checkoutOutcomeTag(croProbeFailed)
        entry.diagnostic = state.reason
        entry.newBranch = state.previousBranch
      of rsReadyLocal:
        entry.outcome = "ready_local"
        entry.newBranch = state.previousBranch
      of rsReadyFetchAndTrack:
        entry.outcome = "ready_fetch_and_track"
        entry.newBranch = state.previousBranch
      result.repos.add(entry)
    result.exitCode =
      if probeFailures > 0: 1
      else: 2
    let recorded = readWorkspaceBranch(parsed.workspaceRoot)
    if recorded.isSome:
      result.recordedBranch = recorded.get()
    return

  # Execute pass: schedule a ``gitFetchAction`` (for the
  # fetch-and-track group) chained to a ``gitSwitchAction``, and a
  # bare ``gitSwitchAction`` for the local-ready group. The
  # ``rsAlreadyOnBranch`` repos schedule no action — the executor
  # would refuse to no-op a ``switch`` to the current branch with
  # any noisier diagnostic than necessary, so we just skip it.
  var actions: seq[BuildAction]
  var switchActionByIdx = initTable[int, string]()
  let receiptDir = parsed.workspaceRoot / ".repro" / "workspace" / "receipts"
  createDir(receiptDir)
  for idx, state in states:
    case state.kind
    of rsReadyLocal:
      let receiptRel = ".repro" / "workspace" / "receipts" /
        ("checkout-switch-" & safeRepoIdSegment(state.repo.name) &
         "-" & $idx & ".receipt")
      let actionId = "workspace-checkout-switch-" &
        safeRepoIdSegment(state.repo.name) & "-" & $idx
      var action = gitSwitchAction(actionId, identity,
        branchName = parsed.branchName,
        repoPath = state.repo.path,
        receiptPath = receiptRel)
      action.cwd = parsed.workspaceRoot
      actions.add(action)
      switchActionByIdx[idx] = actionId
    of rsReadyFetchAndTrack:
      let fetchReceiptRel = ".repro" / "workspace" / "receipts" /
        ("checkout-fetch-" & safeRepoIdSegment(state.repo.name) &
         "-" & $idx & ".receipt")
      let fetchActionId = "workspace-checkout-fetch-" &
        safeRepoIdSegment(state.repo.name) & "-" & $idx
      var fetchAction = gitFetchAction(fetchActionId, identity,
        remoteName = "origin",
        repoPath = state.repo.path,
        receiptPath = fetchReceiptRel)
      fetchAction.cwd = parsed.workspaceRoot
      actions.add(fetchAction)
      let switchReceiptRel = ".repro" / "workspace" / "receipts" /
        ("checkout-switch-" & safeRepoIdSegment(state.repo.name) &
         "-" & $idx & ".receipt")
      let switchActionId = "workspace-checkout-switch-" &
        safeRepoIdSegment(state.repo.name) & "-" & $idx
      # The switch declares the fetch action's id as a dep so the
      # engine orders them. ``git switch`` DWIMs the tracking branch
      # off the ``origin/<name>`` ref the fetch just populated.
      var switchAction = gitSwitchAction(switchActionId, identity,
        branchName = parsed.branchName,
        repoPath = state.repo.path,
        receiptPath = switchReceiptRel,
        deps = @[fetchActionId])
      switchAction.cwd = parsed.workspaceRoot
      actions.add(switchAction)
      switchActionByIdx[idx] = switchActionId
    else:
      discard

  var perRepoOutcome = initTable[int, tuple[outcome: CheckoutRepoOutcome;
                                            diagnostic: string]]()
  if actions.len > 0:
    let cacheRoot = parsed.workspaceRoot / ".repro" / "workspace" /
      "engine-cache"
    var config = defaultBuildEngineConfig(cacheRoot)
    config.suppressTrace = true
    let res = runBuild(graph(actions), config)
    var outcomeById = initTable[string, ActionResult]()
    for outcome in res.results:
      outcomeById[outcome.id] = outcome
    for idx, state in states:
      if not switchActionByIdx.hasKey(idx):
        continue
      let switchId = switchActionByIdx[idx]
      let outcome = outcomeById.getOrDefault(switchId)
      if outcome.status notin {asSucceeded, asCacheHit, asUpToDate}:
        var diag = "status=" & $outcome.status &
          " reason=" & outcome.reason
        if outcome.stderr.len > 0:
          diag.add(" stderr=" & outcome.stderr)
        perRepoOutcome[idx] = (outcome: croActionFailed, diagnostic: diag)
      else:
        let tag =
          if state.kind == rsReadyFetchAndTrack: croFetchedAndSwitched
          else: croSwitched
        perRepoOutcome[idx] = (outcome: tag, diagnostic: "")

  var actionFailures = 0
  for idx, state in states:
    var entry = CheckoutRepoEntry(
      name: state.repo.name,
      path: state.repo.path,
      headSha: state.headSha,
      previousBranch: state.previousBranch,
      remoteHadBranch: state.remoteHadBranch,
      localHadBranch: state.localHadBranch)
    case state.kind
    of rsAlreadyOnBranch:
      entry.outcome = checkoutOutcomeTag(croAlreadyOnBranch)
      entry.newBranch = parsed.branchName
    of rsReadyLocal, rsReadyFetchAndTrack:
      let r = perRepoOutcome.getOrDefault(idx,
        (outcome: croActionFailed,
         diagnostic: "internal: missing action outcome"))
      entry.outcome = checkoutOutcomeTag(r.outcome)
      entry.diagnostic = r.diagnostic
      entry.newBranch =
        if r.outcome == croActionFailed: state.previousBranch
        else: parsed.branchName
      if r.outcome == croActionFailed:
        inc actionFailures
    else:
      # Unreachable: refuse / probe-failed paths returned early above.
      entry.outcome = "internal_unexpected_state"
      entry.newBranch = state.previousBranch
    result.repos.add(entry)

  if actionFailures > 0:
    result.exitCode = 1
    let recorded = readWorkspaceBranch(parsed.workspaceRoot)
    if recorded.isSome:
      result.recordedBranch = recorded.get()
    return

  # Metadata update — only after every per-repo action succeeded.
  # M16: the feature-started mark is a per-workspace flag tied to the
  # CURRENT recorded branch. Switching to a different branch implicitly
  # leaves the "started" feature, so the mark is CLEARED unless the
  # checkout target matches the branch that was already marked started
  # (the no-op-style re-checkout case, where we keep the mark).
  var preserveStartedMark = false
  try:
    if readWorkspaceFeatureStarted(parsed.workspaceRoot):
      let recordedBranch = readWorkspaceBranch(parsed.workspaceRoot)
      if recordedBranch.isSome and recordedBranch.get() == parsed.branchName:
        preserveStartedMark = true
  except WorkspaceManifestParseError:
    preserveStartedMark = false
  try:
    writeWorkspaceBranchWithStarted(parsed.workspaceRoot,
      project = resolved.projectName, branch = parsed.branchName,
      featureStarted = preserveStartedMark)
    result.recordedBranch = parsed.branchName
  except WorkspaceManifestParseError as err:
    result.exitCode = 1
    result.recordedBranch = ""
    result.repos.add(CheckoutRepoEntry(
      outcome: "metadata_write_failed",
      diagnostic: err.msg))
    return

  result.exitCode = 0

proc writeCheckoutReport(report: CheckoutReport) =
  let reportDir = report.workspaceRoot / ".repro" / "workspace"
  createDir(reportDir)
  let reportPath = reportDir / "checkout-report.json"
  writeFile(reportPath, pretty(report.toJsonNode(), indent = 2) & "\n")

proc runCheckoutCommand*(args: openArray[string]): int =
  ## ``repro checkout <branch> [--workspace-root=PATH]
  ## [--tool-provisioning=path|nix|tarball|scoop] [--json]``.
  ##
  ## See the M15 block comment above for the contract. Always writes a
  ## ``checkout-report.json`` artifact under
  ## ``<workspaceRoot>/.repro/workspace/`` so a script consumer has a
  ## parseable record of what happened, in addition to the
  ## stdout-formatted text lines.
  let parsed = parseCheckoutArgs(args)
  let report = executeCheckout(parsed)
  writeCheckoutReport(report)
  if parsed.json:
    stdout.writeLine(pretty(report.toJsonNode(), indent = 2))
  else:
    for line in renderCheckoutTextLines(report):
      stdout.writeLine(line)
  report.exitCode

# --- M16: `repro workspace start <branch>` --------------------------------
#
# Per ``reprobuild-specs/Workspace-Management.milestones.org`` §M16.
# Combination of M14 ``branch create`` + M15 ``checkout`` + the M16
# "feature started" mark in workspace metadata. The mark is what tells
# the M10 sync planner to NO-OP the "clean fast-forwardable" arm on
# repos that sit on the marked workspace branch, so the operator's
# feature work is preserved when the lock pins a different SHA.
#
# Behavior — three cases distinguished in observation:
#
#   1. The branch already exists on EVERY participating repo (locally,
#      or via the standard ``origin`` remote): switch to it
#      (M15 semantics) and set the mark.
#   2. The branch is ABSENT on every participating repo (no local
#      branch, no remote branch with that name): create it across
#      every repo at current HEAD (M14 semantics), switch to it, and
#      set the mark.
#   3. Mixed: refuse-and-report (exit 2). Cleaning this up is
#      operator work.
#
# In every case the started mark is the load-bearing M16 addition.
# Refuses (exit 2) on any dirty repo (matches M14/M15 policy).
#
# Implementation strategy: rather than duplicate the M14 / M15
# observation+execute machinery, we DELEGATE to ``executeBranchCreate``
# or ``executeCheckout`` depending on the observation, then layer the
# started-mark write on top. The metadata write inside those helpers
# is overridden by a follow-up ``writeWorkspaceBranchWithStarted``
# call so the started flag lands correctly even when the inner helper
# wrote a metadata file that omitted the mark.

type
  WorkspaceStartRepoEntry* = object
    ## One per-repo line in the start-report.json. Carries the
    ## inner-helper's outcome tag (``created`` / ``switched`` /
    ## ``already_at_head`` / ``already_on_branch`` / etc.) so the
    ## report shape unifies the M14 and M15 vocabularies.
    name*: string
    path*: string
    headSha*: string
    previousBranch*: string
    newBranch*: string
    outcome*: string
    dirtyReason*: string
    diagnostic*: string

  WorkspaceStartReport* = object
    ## Structured outcome of one ``repro workspace start`` invocation.
    ## ``mode`` is ``create`` when the branch was absent everywhere
    ## (M14 path), ``switch`` when it was present everywhere (M15
    ## path), or ``refused`` when neither full-create nor full-switch
    ## applied. ``featureStarted`` is the recorded value of the
    ## ``[workspace].feature_started`` flag AFTER the command finished.
    project*: string
    workspaceRoot*: string
    branch*: string
    mode*: string
    recordedBranch*: string
    featureStarted*: bool
    repos*: seq[WorkspaceStartRepoEntry]
    exitCode*: int

proc toJsonNode*(report: WorkspaceStartReport): JsonNode =
  result = newJObject()
  result["project"] = %report.project
  result["workspaceRoot"] = %report.workspaceRoot
  result["branch"] = %report.branch
  result["mode"] = %report.mode
  result["recordedBranch"] = %report.recordedBranch
  result["featureStarted"] = %report.featureStarted
  var repos = newJArray()
  for entry in report.repos:
    var obj = newJObject()
    obj["name"] = %entry.name
    obj["path"] = %entry.path
    obj["headSha"] = %entry.headSha
    obj["previousBranch"] = %entry.previousBranch
    obj["newBranch"] = %entry.newBranch
    obj["outcome"] = %entry.outcome
    obj["dirtyReason"] = %entry.dirtyReason
    obj["diagnostic"] = %entry.diagnostic
    repos.add(obj)
  result["repos"] = repos
  result["exitCode"] = %report.exitCode

proc renderWorkspaceStartTextLines*(report: WorkspaceStartReport): seq[string] =
  for entry in report.repos:
    var line = "workspace start: " & entry.path & " " & entry.outcome
    if entry.previousBranch.len > 0 and entry.newBranch.len > 0 and
        entry.previousBranch != entry.newBranch:
      line.add(" " & entry.previousBranch & " -> " & entry.newBranch)
    elif entry.newBranch.len > 0:
      line.add(" branch=" & entry.newBranch)
    if entry.dirtyReason.len > 0:
      line.add(" (" & entry.dirtyReason & ")")
    elif entry.diagnostic.len > 0:
      line.add(" (" & entry.diagnostic & ")")
    result.add(line)
  if report.exitCode == 0:
    let markedSuffix =
      if report.featureStarted: " [feature_started=true]"
      else: ""
    result.add("workspace start: '" & report.branch &
      "' active across " & $report.repos.len & " repos; metadata=" &
      report.recordedBranch & markedSuffix)

type
  WorkspaceStartArgs = object
    workspaceRoot: string
    projectName: string
    branchName: string
    json: bool
    toolProvisioning: ToolProvisioningMode

proc parseWorkspaceStartArgs*(args: openArray[string]): WorkspaceStartArgs =
  ## ``repro workspace start <branch> [--workspace-root=PATH]
  ## [--tool-provisioning=path|nix|tarball|scoop] [--json]``. Positional
  ## ``<branch>`` is REQUIRED.
  result.workspaceRoot = ""
  result.toolProvisioning = tpmPathOnly
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--workspace-root" or arg.startsWith("--workspace-root="):
      result.workspaceRoot = valueFromFlag(args, i, "--workspace-root")
    elif arg == "--tool-provisioning" or
        arg.startsWith("--tool-provisioning="):
      result.toolProvisioning = parseToolProvisioning(
        valueFromFlag(args, i, "--tool-provisioning"))
    elif arg == "--json":
      result.json = true
    elif arg.startsWith("-"):
      raise newException(ValueError,
        "unsupported `repro workspace start` flag: " & arg)
    elif result.branchName.len == 0:
      result.branchName = arg
    else:
      raise newException(ValueError,
        "unexpected positional argument to `repro workspace start`: " & arg)
    inc i
  if result.branchName.len == 0:
    raise newException(ValueError,
      "`repro workspace start` requires a branch name positional argument")
  if result.workspaceRoot.len == 0:
    result.workspaceRoot = getCurrentDir()
  result.workspaceRoot = absolutePath(result.workspaceRoot)

proc executeWorkspaceStart(parsed: WorkspaceStartArgs): WorkspaceStartReport =
  result.workspaceRoot = parsed.workspaceRoot
  result.branch = parsed.branchName

  # Observation pass: walk every declared repo, classify (a) dirty
  # (any-dirty refuses immediately), (b) branch present locally, (c)
  # branch present on origin. We reuse ``resolveCheckoutProject`` so
  # the dispatch rules stay aligned with M14/M15.
  let parsedCheckout = CheckoutArgs(
    workspaceRoot: parsed.workspaceRoot,
    projectName: parsed.projectName,
    branchName: parsed.branchName,
    toolProvisioning: parsed.toolProvisioning)
  let (resolved, _) = resolveCheckoutProject(parsedCheckout)
  result.project = resolved.projectName

  let identity = ensureGitToolResolvable(
    parsed.toolProvisioning, getEnv("PATH"))
  installGitVcsExecutor()

  type
    StartRepoState = object
      repo: ResolvedRepo
      repoPath: string
      headSha: string
      previousBranch: string
      isClean: bool
      localHadBranch: bool
      remoteHadBranch: bool
      probeFailed: bool
      probeReason: string

  var states: seq[StartRepoState]
  var anyDirty = false
  var anyProbeFailed = false
  var allHaveBranch = true   # local OR remote on EVERY repo
  var noneHaveBranch = true  # neither local NOR remote on ANY repo
  for repo in resolved.repos:
    var state: StartRepoState
    state.repo = repo
    state.repoPath = parsed.workspaceRoot / repo.path
    state.isClean = true
    if not dirExists(state.repoPath / ".git"):
      state.probeFailed = true
      state.probeReason = "no on-disk checkout at '" & state.repoPath &
        "'; run `repro workspace init` or `repro workspace sync` first"
      anyProbeFailed = true
      states.add(state)
      continue
    let headRes = queryGitState(headShaQuery(state.repoPath), identity)
    if headRes.status != gqsOk:
      state.probeFailed = true
      state.probeReason = "head-sha probe failed: " & headRes.diagnostic
      anyProbeFailed = true
      states.add(state)
      continue
    state.headSha = headRes.headSha
    let branchRes = gitRunPlain(identity,
      ["-C", state.repoPath, "symbolic-ref", "--short", "-q", "HEAD"])
    if branchRes.code == 0:
      state.previousBranch = branchRes.output.strip()
    let cleanRes = queryGitState(isCleanQuery(state.repoPath), identity)
    if cleanRes.status != gqsOk:
      state.probeFailed = true
      state.probeReason = "clean/dirty probe failed: " & cleanRes.diagnostic
      anyProbeFailed = true
      states.add(state)
      continue
    state.isClean = cleanRes.isClean
    if not state.isClean:
      anyDirty = true
      states.add(state)
      continue
    # Probe local branch.
    let localProbe = gitRunPlain(identity,
      ["-C", state.repoPath, "rev-parse", "--verify", "--quiet",
       "refs/heads/" & parsed.branchName])
    if localProbe.code == 0 and localProbe.output.strip().len > 0:
      state.localHadBranch = true
    # Probe remote branch (origin).
    let remoteProbe = gitRunPlain(identity,
      ["-C", state.repoPath, "ls-remote", "--heads", "origin",
       parsed.branchName])
    if remoteProbe.code == 0 and remoteProbe.output.strip().len > 0:
      state.remoteHadBranch = true
    if state.localHadBranch or state.remoteHadBranch:
      noneHaveBranch = false
    else:
      allHaveBranch = false
    states.add(state)

  # Decision tree:
  #
  #   - Any probe failed → exit 1.
  #   - Any repo dirty → exit 2, refuse and report.
  #   - Branch present everywhere → SWITCH path (delegate to
  #     ``executeCheckout``).
  #   - Branch absent everywhere → CREATE path (delegate to
  #     ``executeBranchCreate``).
  #   - Mixed → exit 2 (refuse-and-report; the operator needs to
  #     reconcile manually).
  let recordedBranchPre = readWorkspaceBranch(parsed.workspaceRoot)
  let recordedFeatureStartedPre =
    try: readWorkspaceFeatureStarted(parsed.workspaceRoot)
    except WorkspaceManifestParseError: false
  if anyProbeFailed:
    for state in states:
      var entry = WorkspaceStartRepoEntry(
        name: state.repo.name,
        path: state.repo.path,
        headSha: state.headSha,
        previousBranch: state.previousBranch,
        newBranch: state.previousBranch)
      if state.probeFailed:
        entry.outcome = "probe_failed"
        entry.diagnostic = state.probeReason
      elif not state.isClean:
        entry.outcome = "dirty_refused"
        entry.dirtyReason = "working tree has uncommitted changes"
      else:
        entry.outcome = "ready"
      result.repos.add(entry)
    result.exitCode = 1
    result.mode = "refused"
    if recordedBranchPre.isSome:
      result.recordedBranch = recordedBranchPre.get()
    result.featureStarted = recordedFeatureStartedPre
    return
  if anyDirty:
    for state in states:
      var entry = WorkspaceStartRepoEntry(
        name: state.repo.name,
        path: state.repo.path,
        headSha: state.headSha,
        previousBranch: state.previousBranch,
        newBranch: state.previousBranch)
      if not state.isClean:
        entry.outcome = "dirty_refused"
        entry.dirtyReason = "working tree has uncommitted changes"
      else:
        entry.outcome = "ready"
      result.repos.add(entry)
    result.exitCode = 2
    result.mode = "refused"
    if recordedBranchPre.isSome:
      result.recordedBranch = recordedBranchPre.get()
    result.featureStarted = recordedFeatureStartedPre
    return
  if not allHaveBranch and not noneHaveBranch:
    # Mixed: some repos have the branch, some don't. Refuse cleanly.
    for state in states:
      var entry = WorkspaceStartRepoEntry(
        name: state.repo.name,
        path: state.repo.path,
        headSha: state.headSha,
        previousBranch: state.previousBranch,
        newBranch: state.previousBranch)
      if state.localHadBranch:
        entry.outcome = "ready_local"
      elif state.remoteHadBranch:
        entry.outcome = "ready_remote"
      else:
        entry.outcome = "branch_missing"
        entry.diagnostic = "branch '" & parsed.branchName &
          "' absent locally and on remote 'origin' for this repo; " &
          "`repro workspace start` requires either CREATE (absent " &
          "everywhere) or SWITCH (present everywhere)"
      result.repos.add(entry)
    result.exitCode = 2
    result.mode = "refused"
    if recordedBranchPre.isSome:
      result.recordedBranch = recordedBranchPre.get()
    result.featureStarted = recordedFeatureStartedPre
    return

  if allHaveBranch:
    # SWITCH path — delegate to executeCheckout, then layer the
    # started mark on top.
    result.mode = "switch"
    let checkoutReport = executeCheckout(parsedCheckout)
    for centry in checkoutReport.repos:
      result.repos.add(WorkspaceStartRepoEntry(
        name: centry.name,
        path: centry.path,
        headSha: centry.headSha,
        previousBranch: centry.previousBranch,
        newBranch: centry.newBranch,
        outcome: centry.outcome,
        dirtyReason: centry.dirtyReason,
        diagnostic: centry.diagnostic))
    if checkoutReport.exitCode != 0:
      result.exitCode = checkoutReport.exitCode
      result.recordedBranch = checkoutReport.recordedBranch
      result.featureStarted = recordedFeatureStartedPre
      return
    # Set the started mark.
    try:
      writeWorkspaceBranchWithStarted(parsed.workspaceRoot,
        project = resolved.projectName, branch = parsed.branchName,
        featureStarted = true)
      result.recordedBranch = parsed.branchName
      result.featureStarted = true
      result.exitCode = 0
    except WorkspaceManifestParseError as err:
      result.exitCode = 1
      result.recordedBranch = checkoutReport.recordedBranch
      result.featureStarted = recordedFeatureStartedPre
      result.repos.add(WorkspaceStartRepoEntry(
        outcome: "metadata_write_failed",
        diagnostic: err.msg))
    return

  # CREATE path — branch is absent on every repo. Delegate to
  # executeBranchCreate, then layer the started mark on top.
  result.mode = "create"
  let branchParsed = BranchArgs(
    workspaceRoot: parsed.workspaceRoot,
    projectName: parsed.projectName,
    branchName: parsed.branchName,
    toolProvisioning: parsed.toolProvisioning)
  let createReport = executeBranchCreate(branchParsed)
  for centry in createReport.repos:
    # The M14 create report lacks ``previousBranch`` / ``newBranch``
    # fields — fill them from the M16 observation states so the start
    # report shape stays uniform.
    var previousBranch = ""
    for state in states:
      if state.repo.name == centry.name:
        previousBranch = state.previousBranch
        break
    var newBranch = ""
    if createReport.exitCode == 0:
      newBranch = parsed.branchName
    else:
      newBranch = previousBranch
    result.repos.add(WorkspaceStartRepoEntry(
      name: centry.name,
      path: centry.path,
      headSha: centry.headSha,
      previousBranch: previousBranch,
      newBranch: newBranch,
      outcome: centry.outcome,
      dirtyReason: centry.dirtyReason,
      diagnostic: centry.diagnostic))
  if createReport.exitCode != 0:
    result.exitCode = createReport.exitCode
    result.recordedBranch = createReport.recordedBranch
    result.featureStarted = recordedFeatureStartedPre
    return
  # The M14 create form created the branch from HEAD but did NOT
  # switch to it. M16's "start" semantics expect the workspace to be
  # ON the new branch afterwards. Run executeCheckout to switch every
  # repo onto the freshly created branch.
  let switchReport = executeCheckout(parsedCheckout)
  if switchReport.exitCode != 0:
    # Translate the switch failure into the start report.
    result.repos.setLen(0)
    for centry in switchReport.repos:
      result.repos.add(WorkspaceStartRepoEntry(
        name: centry.name,
        path: centry.path,
        headSha: centry.headSha,
        previousBranch: centry.previousBranch,
        newBranch: centry.newBranch,
        outcome: centry.outcome,
        dirtyReason: centry.dirtyReason,
        diagnostic: centry.diagnostic))
    result.exitCode = switchReport.exitCode
    result.recordedBranch = switchReport.recordedBranch
    result.featureStarted = recordedFeatureStartedPre
    return
  # Now set the started mark.
  try:
    writeWorkspaceBranchWithStarted(parsed.workspaceRoot,
      project = resolved.projectName, branch = parsed.branchName,
      featureStarted = true)
    result.recordedBranch = parsed.branchName
    result.featureStarted = true
    result.exitCode = 0
  except WorkspaceManifestParseError as err:
    result.exitCode = 1
    result.recordedBranch = createReport.recordedBranch
    result.featureStarted = recordedFeatureStartedPre
    result.repos.add(WorkspaceStartRepoEntry(
      outcome: "metadata_write_failed",
      diagnostic: err.msg))

proc writeWorkspaceStartReport(report: WorkspaceStartReport) =
  let reportDir = report.workspaceRoot / ".repro" / "workspace"
  createDir(reportDir)
  let reportPath = reportDir / "start-report.json"
  writeFile(reportPath, pretty(report.toJsonNode(), indent = 2) & "\n")

proc runWorkspaceStartCommand*(args: openArray[string]): int =
  ## ``repro workspace start <branch> [--workspace-root=PATH]
  ## [--tool-provisioning=path|nix|tarball|scoop] [--json]``.
  ##
  ## M16 — combination of ``repro branch <name>`` + ``repro checkout
  ## <name>`` + a "feature started" mark in metadata so future
  ## ``repro workspace sync`` runs preserve the workspace branch even
  ## when the lock pins different SHAs on it. See the M16 block
  ## comment above for the contract.
  let parsed = parseWorkspaceStartArgs(args)
  let report = executeWorkspaceStart(parsed)
  writeWorkspaceStartReport(report)
  if parsed.json:
    stdout.writeLine(pretty(report.toJsonNode(), indent = 2))
  else:
    for line in renderWorkspaceStartTextLines(report):
      stdout.writeLine(line)
  report.exitCode

## ----------------------------------------------------------------------------
## CI-Sharding M2 — ``repro test`` shard runner.
##
## This block implements the user-facing surface specified in
## ``reprobuild-specs/CI-Sharding.md`` §"CLI Surface" and wired up
## end-to-end in milestone M2 of
## ``reprobuild-specs/CI-Sharding.milestones.org``:
##
##   repro test --shard <k>/<N>
##              [--partition-strategy <slice|hash|duration|joint-duration>]
##              [--peer-cache=<none|lan://CIDR|remote://URL>]
##              [--emit-partition-plan=<path>] [--plan-from=<path>]
##              [<test-selectors>...]
##
## Test-edge discovery is intentionally pluggable: when the workspace
## already carries an aggregated target-export table the CLI will
## eventually walk it (that is M2-followup work; see the planner
## docstring), but for the M2 verification tests and for the
## first-end-to-end demo a JSON fixture path can be supplied via
## ``--fixture-from=<path>``.  The fixture format is:
##
##   {
##     "buildActions": [
##       { "id": <int>, "commandStatsId": <str>, "deps": [<int>, ...],
##         "buildCmd": [<argv>, ...] }, ...
##     ],
##     "testEdges": [
##       { "id": <int>, "selector": <str>, "historyKey": <str>,
##         "buildDeps": [<int>, ...], "runCmd": [<argv>, ...],
##         "testName": "<binary>::<suite>::<test>" }, ...
##     ],
##     "fallbackBuildCostNs": <int>,
##     "fallbackTestCostNs": <int>,
##     "historyDir": <str>, "estimateDbPath": <str>,
##     "estimateScope": <str>, "policy": "independent"|"shared"
##   }
##
## The M2 per-shard report lives at
## ``test-logs/shard-<k>-of-<N>.json`` and carries the fields specified
## in CI-Sharding.milestones.org M2 "Per-shard report writer".

type
  ReproTestFixtureAction = object
    id: NodeId
    commandStatsId: string
    deps: seq[NodeId]
    buildCmd: seq[string]

  ReproTestFixtureEdge = object
    id: NodeId
    selector: string
    historyKey: string
    buildDeps: seq[NodeId]
    runCmd: seq[string]
    testName: string  # ``<binary>::<suite>::<test>`` or just ``<binary>``

  ReproTestFixture = object
    actions: seq[ReproTestFixtureAction]
    edges: seq[ReproTestFixtureEdge]
    fallbackBuildCostNs: int64
    fallbackTestCostNs: int64
    historyDir: string
    estimateDbPath: string
    estimateScope: string
    policy: SharedInputPolicy
    refinementPasses: int

  ReproTestShardOpts = object
    shardIndex: int                # 1-indexed; 0 means none parsed
    shardCount: int
    strategy: string               # "joint-duration" | "slice" | "hash" | "duration"
    peerCacheSpec: string          # raw text
    emitPlanPath: string
    planFromPath: string
    selectors: seq[string]
    fixturePath: string
    binDir: string
    reportPath: string
    toolProvisioning: ToolProvisioningMode
      ## Workspace-mode discovery needs typed tool provisioning when the
      ## project's interface declares ``uses:`` blocks (the default for any
      ## real reprobuild workspace).  ``tpmUnspecified`` defers to the
      ## project-interface's declared default; if there is none the engine
      ## raises the documented "pass --tool-provisioning=path" diagnostic.

proc emitShardDiagnostic(msg: string) =
  stderr.writeLine("repro test: error: " & msg)

type
  PeerCacheSpecKind* = enum
    pcsNone, pcsLan, pcsRemote

  PeerCacheSpecResult* = object
    ## Peer-Cache M2: structured result of parsing ``--peer-cache=...``.
    ## ``ok`` is ``false`` for structurally invalid specs (the CLI
    ## emits a diagnostic in that case). ``kind`` distinguishes the
    ## three spec forms reserved in
    ## ``CI-Sharding.md`` §"CLI Surface". For ``pcsLan``, ``config``
    ## carries the fully-populated ``PeerCacheConfig`` (CIDR
    ## allowlist + multicast group) ready to thread through to the
    ## peer-cache server / client.
    ok*: bool
    kind*: PeerCacheSpecKind
    rawArg*: string
    config*: PeerCacheConfig

proc modeName*(kind: PeerCacheSpecKind): string =
  case kind
  of pcsNone: "none"
  of pcsLan: "lan"
  of pcsRemote: "remote"

proc parsePeerCache*(spec: string): PeerCacheSpecResult =
  ## Peer-Cache M2: parser for the ``--peer-cache=`` flag. Recognises
  ## the three forms documented in
  ## ``CI-Sharding.md`` §"CLI Surface":
  ##
  ##   - ``none`` / empty string — ``pcsNone``.
  ##   - ``remote://<url>`` — ``pcsRemote``, ``rawArg`` is the URL.
  ##   - ``lan://<CIDR>[:port]`` — ``pcsLan``, ``config`` is populated
  ##     with ``discoveryMode = pdmMulticast``, the parsed CIDR in
  ##     ``cidrAllowlistRaw``, and the multicast group address
  ##     ``224.0.0.123:<port>`` (default 7654; the test suite uses
  ##     ``17654`` to avoid kernel filtering on low ports).
  ##
  ## Returns ``ok=false`` for structurally invalid specs.
  result.ok = false
  result.kind = pcsNone
  result.rawArg = ""
  if spec.len == 0 or spec == "none":
    result.ok = true
    result.kind = pcsNone
    return
  if spec.startsWith("remote://"):
    result.ok = true
    result.kind = pcsRemote
    result.rawArg = spec[len("remote://") .. ^1]
    return
  if spec.startsWith("lan://"):
    var arg = spec[len("lan://") .. ^1]
    # Peer-Cache-BearSSL M4: strip an optional ``?tls=1`` query knob
    # before parsing the CIDR + port. When present, populate the
    # ``tlsCertPath`` / ``tlsKeyPath`` / ``tlsTrustAnchorsPath`` fields
    # from ``XDG_STATE_HOME/repro-peer-cache/tls/`` and flip the trust
    # mode to ``tmTls``. Any other query knob is rejected.
    var enableTls = false
    let queryIdx = arg.find('?')
    if queryIdx >= 0:
      let query = arg[queryIdx + 1 .. ^1]
      arg = arg[0 ..< queryIdx]
      for piece in query.split('&'):
        case piece
        of "tls=1":
          enableTls = true
        of "tls=0", "":
          discard
        else:
          result.ok = false
          return
    # ``lan://<CIDR>[:port]`` — split on the *last* colon so the CIDR
    # itself (which may contain dots and a single ``/`` for the
    # prefix length) is preserved verbatim. A trailing ``:port`` is
    # optional; missing ⇒ the spec default (7654).
    var cidrPart = arg
    var port = Port(DefaultMulticastPort)
    let lastColon = arg.rfind(':')
    if lastColon >= 0:
      let portStr = arg[lastColon + 1 .. ^1]
      try:
        let parsed = parseInt(portStr)
        if parsed >= 1 and parsed <= 65535:
          port = Port(uint16(parsed))
          cidrPart = arg[0 ..< lastColon]
      except ValueError:
        # Not a port — leave the whole ``arg`` as the CIDR and use
        # the default port. The CIDR validator below will reject
        # anything truly malformed.
        discard
    # Validate the CIDR by running it through ``parseCidrV4`` so we
    # fail closed at parse time (rather than at service start). The
    # validated value isn't kept here; the server side calls
    # ``parseCidrV4`` again at start time so the failure surface for
    # CIDR errors is a single code path.
    try:
      discard parseCidrV4(cidrPart)
    except CatchableError:
      result.ok = false
      return
    result.ok = true
    result.kind = pcsLan
    result.rawArg = arg
    var cfg = PeerCacheConfig(
      discoveryMode: pdmMulticast,
      seedPeers: @[],
      multicastGroup: MulticastGroup(
        address: parseIpAddress(DefaultMulticastAddress),
        port: port,
        interfaceIp: parseIpAddress("0.0.0.0")),
      cidrAllowlistRaw: @[cidrPart],
      advertiseIntervalMs: DefaultAdvertiseIntervalMs,
      pingIntervalMs: DefaultPingIntervalMs,
      maxBlobBytes: DefaultMaxBlobBytes)
    if enableTls:
      let envState = getEnv("XDG_STATE_HOME")
      let stateRoot =
        if envState.len > 0: envState
        else: getHomeDir() / ".local" / "state"
      let tlsDir = stateRoot / "repro-peer-cache" / "tls"
      cfg.trustMode = tmTls
      cfg.tlsCertPath = tlsDir / "peer.crt"
      cfg.tlsKeyPath = tlsDir / "peer.key"
      cfg.tlsTrustAnchorsPath = tlsDir / "anchors"
    result.config = cfg
    return
  # Unrecognised prefix.
  result.ok = false

# ---------------------------------------------------------------------------
# Peer-Cache M2: thin wiring helper called from ``runReproTestCommand``
# before the partition planner runs. Constructs and starts a
# `PeerCacheServer` + `PeerCacheClient` from a parsed `PeerCacheConfig`
# (`pdmMulticast` mode). The returned tuple is held by the caller for
# the lifetime of the shard so a subsequent `stop()` cleans up.
#
# This is the thinnest possible wiring: the partition planner doesn't
# yet consult the peer cache (that's an action-cache reader
# concern, tracked in Peer-Cache M1 Outstanding Tasks), but per the
# milestone spec the services must start so the M2 CLI verification
# test can assert `server.started == true`.
# ---------------------------------------------------------------------------

type
  PeerCacheRuntime* = object
    server*: PeerCacheServer
    client*: PeerCacheClient
    registry*: PeerRegistry

var lastStartedPeerCacheRuntime*: PeerCacheRuntime
  ## Peer-Cache M2 test seam: the most recent `PeerCacheRuntime` started
  ## by `runReproTestCommand` is captured here so the
  ## `t_peer_cache_cli_lan_spec_enables_multicast` test can assert
  ## `server.started == true` after `runReproTestCommand` returns. The
  ## production code path doesn't read this variable; it exists purely
  ## for in-process introspection from the verification harness.

proc startPeerCacheServices*(config: PeerCacheConfig;
                            selfPeerId: PeerId;
                            listenAddr: string = "0.0.0.0"):
                            PeerCacheRuntime =
  ## Boots the peer-cache TCP server + multicast receiver and the
  ## client-side multicast broadcaster from a parsed `PeerCacheConfig`.
  ## The CIDR allowlist is converted from the parser's raw strings to
  ## typed `CidrV4` values here so any drift between the parser and
  ## the server's matcher surfaces as a single diagnostic at start
  ## time.
  let endpoint = initEndpoint(listenAddr, Port(0))
  result.registry = newPeerRegistry(selfPeerId, endpoint)
  var allowlist: seq[CidrV4] = @[]
  for cidrStr in config.cidrAllowlistRaw:
    allowlist.add(parseCidrV4(cidrStr))
  result.server = newPeerCacheServer(
    selfPeerId = selfPeerId,
    listenAddr = listenAddr,
    listenPort = Port(0),
    registry = result.registry,
    cidrAllowlist = allowlist,
    maxBlobBytes = config.maxBlobBytes)
  result.server.start()
  if config.discoveryMode == pdmMulticast:
    result.server.multicastListen(config.multicastGroup)
  result.client = newPeerCacheClient(
    selfPeerId = selfPeerId,
    listenPort = uint16(result.server.actualPort),
    registry = result.registry,
    seedPeers = config.seedPeers,
    cidrAllowlist = allowlist,
    advertiseIntervalMs = config.advertiseIntervalMs)
  if config.discoveryMode == pdmMulticast:
    result.client.multicastBroadcast(config.multicastGroup)

proc parseShardSpec(value: string): tuple[ok: bool; k, n: int] =
  let parts = value.split('/')
  if parts.len != 2:
    return (false, 0, 0)
  try:
    let k = parseInt(parts[0])
    let n = parseInt(parts[1])
    if n <= 0 or k < 1 or k > n:
      return (false, 0, 0)
    return (true, k, n)
  except ValueError:
    return (false, 0, 0)

proc parseReproTestFlags(args: openArray[string]): ReproTestShardOpts =
  result.strategy = "joint-duration"
  result.binDir = "build/test-bin"
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--shard" or arg.startsWith("--shard="):
      let v = valueFromFlag(args, i, "--shard")
      let parsed = parseShardSpec(v)
      if not parsed.ok:
        raise newException(ValueError,
          "invalid --shard value: " & v & " (expected <k>/<N>, 1-indexed)")
      result.shardIndex = parsed.k
      result.shardCount = parsed.n
    elif arg == "--partition-strategy" or arg.startsWith("--partition-strategy="):
      result.strategy = valueFromFlag(args, i, "--partition-strategy")
    elif arg == "--peer-cache" or arg.startsWith("--peer-cache="):
      result.peerCacheSpec = valueFromFlag(args, i, "--peer-cache")
    elif arg == "--emit-partition-plan" or
        arg.startsWith("--emit-partition-plan="):
      result.emitPlanPath = valueFromFlag(args, i, "--emit-partition-plan")
    elif arg == "--plan-from" or arg.startsWith("--plan-from="):
      result.planFromPath = valueFromFlag(args, i, "--plan-from")
    elif arg == "--fixture-from" or arg.startsWith("--fixture-from="):
      result.fixturePath = valueFromFlag(args, i, "--fixture-from")
    elif arg == "--bin-dir" or arg.startsWith("--bin-dir="):
      result.binDir = valueFromFlag(args, i, "--bin-dir")
    elif arg == "--report" or arg.startsWith("--report="):
      result.reportPath = valueFromFlag(args, i, "--report")
    elif arg == "--tool-provisioning" or arg.startsWith("--tool-provisioning="):
      result.toolProvisioning = parseToolProvisioning(
        valueFromFlag(args, i, "--tool-provisioning"))
    elif arg == "--variant" or arg.startsWith("--variant="):
      # Spec-Implementation M1 — relay through ``runBuildCommand``'s
      # contract: ``--variant name=value`` is appended to the
      # ``REPRO_VARIANTS`` env var so the provider process picks it up
      # via ``repro_dsl_stdlib/configurables/variants.nim``. The CLI
      # surface mirrors the ``repro build`` arm so ``repro test``
      # inherits the same flag automatically.
      let spec = valueFromFlag(args, i, "--variant")
      if spec.find('=') <= 0:
        raise newException(ValueError,
          "--variant expects name=value (got: " & spec & ")")
      var existing = getEnv("REPRO_VARIANTS")
      if existing.len > 0:
        existing.add(',')
      existing.add(spec)
      putEnv("REPRO_VARIANTS", existing)
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported repro test flag: " & arg)
    else:
      result.selectors.add(arg)
    inc i

proc loadReproTestFixture(path: string): ReproTestFixture =
  if not fileExists(path):
    raise newException(IOError, "fixture file not found: " & path)
  let raw = readFile(path)
  let parsed = parseJson(raw)
  result.fallbackBuildCostNs =
    if parsed.hasKey("fallbackBuildCostNs"):
      parsed["fallbackBuildCostNs"].getBiggestInt().int64
    else: 1_000_000'i64
  result.fallbackTestCostNs =
    if parsed.hasKey("fallbackTestCostNs"):
      parsed["fallbackTestCostNs"].getBiggestInt().int64
    else: 1_000_000'i64
  result.historyDir =
    if parsed.hasKey("historyDir"): parsed["historyDir"].getStr()
    else: ""
  result.estimateDbPath =
    if parsed.hasKey("estimateDbPath"): parsed["estimateDbPath"].getStr()
    else: ""
  result.estimateScope =
    if parsed.hasKey("estimateScope"): parsed["estimateScope"].getStr()
    else: ""
  result.policy =
    if parsed.hasKey("policy") and parsed["policy"].getStr() == "shared":
      sipShared
    else: sipIndependent
  result.refinementPasses =
    if parsed.hasKey("refinementPasses"):
      parsed["refinementPasses"].getInt()
    else: DefaultRefinementPasses
  if parsed.hasKey("buildActions"):
    for a in parsed["buildActions"].elems:
      var deps: seq[NodeId] = @[]
      if a.hasKey("deps"):
        for d in a["deps"].elems:
          deps.add(nodeId(uint64(d.getInt())))
      var buildCmd: seq[string] = @[]
      if a.hasKey("buildCmd"):
        for s in a["buildCmd"].elems:
          buildCmd.add(s.getStr())
      result.actions.add(ReproTestFixtureAction(
        id: nodeId(uint64(a["id"].getInt())),
        commandStatsId:
          if a.hasKey("commandStatsId"): a["commandStatsId"].getStr() else: "",
        deps: deps,
        buildCmd: buildCmd))
  if parsed.hasKey("testEdges"):
    for e in parsed["testEdges"].elems:
      var buildDeps: seq[NodeId] = @[]
      if e.hasKey("buildDeps"):
        for d in e["buildDeps"].elems:
          buildDeps.add(nodeId(uint64(d.getInt())))
      var runCmd: seq[string] = @[]
      if e.hasKey("runCmd"):
        for s in e["runCmd"].elems:
          runCmd.add(s.getStr())
      result.edges.add(ReproTestFixtureEdge(
        id: nodeId(uint64(e["id"].getInt())),
        selector:
          if e.hasKey("selector"): e["selector"].getStr() else: "",
        historyKey:
          if e.hasKey("historyKey"): e["historyKey"].getStr() else: "",
        buildDeps: buildDeps,
        runCmd: runCmd,
        testName:
          if e.hasKey("testName"): e["testName"].getStr() else: ""))

proc fixtureToShardPlanRequest(f: ReproTestFixture; shardCount: int;
                               selectors: seq[string]): ShardPlanRequest =
  result.shardCount = shardCount
  result.targetSelectors = selectors
  result.policy = f.policy
  result.historyDir = f.historyDir
  result.estimateDbPath = f.estimateDbPath
  result.estimateScope = f.estimateScope
  result.fallbackBuildCostNs = f.fallbackBuildCostNs
  result.fallbackTestCostNs = f.fallbackTestCostNs
  result.refinementPasses = f.refinementPasses
  for a in f.actions:
    result.buildActions.add(ShardBuildAction(
      id: a.id,
      commandStatsId: a.commandStatsId,
      deps: a.deps))
  for e in f.edges:
    result.testEdges.add(ShardTestEdge(
      id: e.id,
      selector: e.selector,
      historyKey: e.historyKey,
      buildDeps: e.buildDeps))

proc shardAssignmentIds(plan: ShardPlan; shardIndex: int): seq[NodeId] =
  for a in plan.partition.assignments:
    if a.shardIndex == shardIndex:
      result.add(a.root)

proc closureActionsForShard(fixture: ReproTestFixture; rootIds: seq[NodeId]):
    seq[ReproTestFixtureAction] =
  var actionById = initTable[NodeId, ReproTestFixtureAction]()
  for a in fixture.actions:
    actionById[a.id] = a
  var edgeById = initTable[NodeId, ReproTestFixtureEdge]()
  for e in fixture.edges:
    edgeById[e.id] = e
  var visited = initHashSet[NodeId]()
  var ordered: seq[NodeId] = @[]

  proc dfs(id: NodeId) =
    if id in visited:
      return
    visited.incl(id)
    if actionById.hasKey(id):
      for dep in actionById[id].deps:
        dfs(dep)
      ordered.add(id)

  for root in rootIds:
    if edgeById.hasKey(root):
      for dep in edgeById[root].buildDeps:
        dfs(dep)
  for id in ordered:
    result.add(actionById[id])

proc runFixtureCmd(cmd: seq[string]; cwd: string): tuple[code: int; output: string] =
  if cmd.len == 0:
    return (0, "")
  # Redirect the child's stdout+stderr to a temp file rather than a pipe.
  # A pipe-based ``readLine`` loop blocks indefinitely when a test forks
  # a long-lived subprocess that keeps the inherited stdout fd open past
  # the test's own exit (a reproducible failure mode in the CI-sharding
  # M4 demonstration harness on the real reprobuild suite — multiple
  # tests spawn sibling daemons / monitors that survive the test).
  # File-backed IO has no liveness coupling: ``waitForExit`` on the
  # leader returns as soon as the leader is gone regardless of any
  # grandchild state.
  let logPath = getTempDir() / ("repro-test-fixture-" &
    $epochTime() & "-" & $getCurrentProcessId() & ".log")
  # Build an argv that pipes the original command through ``sh -c`` with
  # explicit stdout/stderr redirection.  When the caller already wraps
  # in ``sh -c``, we append the redirection to the existing -c body.
  var argv: seq[string] = @[]
  if cmd.len >= 3 and cmd[0] == "sh" and cmd[1] == "-c":
    let body = cmd[2] & " >'" & logPath & "' 2>&1"
    argv = @["sh", "-c", body]
  else:
    var quoted: seq[string] = @[]
    for s in cmd:
      quoted.add(quoteShell(s))
    let body = quoted.join(" ") & " >'" & logPath & "' 2>&1"
    argv = @["sh", "-c", body]
  let process = startProcess(argv[0],
    workingDir = cwd,
    args = argv[1 .. ^1],
    options = {poUsePath, poStdErrToStdOut})
  defer: process.close()
  let code = process.waitForExit(timeout = -1)
  var buf = ""
  if fileExists(logPath):
    try:
      buf = readFile(logPath)
    except CatchableError:
      discard
    try:
      removeFile(logPath)
    except OSError:
      discard
  return (code, buf)

proc writePartitionFile(path: string; edges: seq[ReproTestFixtureEdge]) =
  var lines: seq[string] = @[]
  lines.add("# CI-Sharding M2 partition file — one fully-qualified test per line.")
  for e in edges:
    if e.testName.len > 0:
      lines.add(e.testName)
    elif e.selector.len > 0:
      lines.add(e.selector)
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  writeFile(path, lines.join("\n") & "\n")

proc edgesAssignedToShard(fixture: ReproTestFixture;
                          plan: ShardPlan;
                          shardIndex: int): seq[ReproTestFixtureEdge] =
  var byId = initTable[NodeId, ReproTestFixtureEdge]()
  for e in fixture.edges:
    byId[e.id] = e
  for a in plan.partition.assignments:
    if a.shardIndex == shardIndex and byId.hasKey(a.root):
      result.add(byId[a.root])

proc predictedShardCostNs(plan: ShardPlan; shardIndex: int): int64 =
  let idx = shardIndex - 1
  if idx < 0 or idx >= plan.partition.perShardCost.len:
    return 0
  plan.partition.perShardCost[idx].inNanoseconds

proc writeShardReport(path: string; meta: JsonNode) =
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  writeFile(path, meta.pretty() & "\n")

## ----------------------------------------------------------------------------
## CI-Sharding M2 deviation fix — workspace-driven discovery, build, and
## ct-test-runner handoff. Replaces the M2 ``--fixture-from=<JSON>`` deviation
## with the real reprobuild integration the M3 benchmark milestone depends on.
##
## The three helpers below mirror the M2 follow-up bullets in
## ``CI-Sharding.milestones.org``:
##
##   1. ``discoverTestEdgesFromWorkspace`` — walks the engine's normalised
##      graph artefact (via ``prepareBuildGraphInspection``) and returns one
##      ``ShardTestEdge`` per declared ``NimUnittestBinary`` action plus the
##      build-action graph that backs the edges' closures.
##   2. ``buildClosureForShard`` — delegates to ``runBuildCommand`` (the
##      Named-Targets M2 resolver) to build the ``:test`` aggregate.  The
##      simpler whole-aggregate path is acceptable here because the M3
##      benchmark milestone is the one that optimises build-phase
##      parallelism.
##   3. ``invokeCtTestRunner`` — locates the sibling ct-test-runner (mirroring
##      ``scripts/run_tests.sh``'s cut-over rule from Test-Edges M4) or the
##      fallback ``tools/test-runner/repro_test_runner`` and invokes it with
##      the assigned binary paths as positional arguments — that gives
##      whole-binary sharding without requiring per-test protocol probing.

type
  WorkspaceTestDiscovery = object
    actions: seq[ShardBuildAction]
    edges: seq[ShardTestEdge]
    edgeBinaryPath: Table[NodeId, string]
      ## Maps each test-edge root id to the binary stem (``build/test-bin/<stem>``)
      ## the engine emits for that edge.  Populated from ``typedOutputs.path``.

proc stableNodeIdFromString(value: string): NodeId =
  ## Deterministic 64-bit id derived from an action id string.  We use the
  ## std/hashes ``Hash`` (which mixes the bytes) and reinterpret it as
  ## ``uint64`` so the resulting ``NodeId`` is stable across runs and
  ## reproducible across shards (every shard recomputes the plan locally,
  ## per CI-Sharding.md §"CI Sharding").
  nodeId(cast[uint64](hashes.hash(value)))

proc isNimUnittestBinaryEdge(action: BuildAction): bool =
  for typedOutput in action.typedOutputs:
    for typeName in typedOutput.types:
      if typeName == "NimUnittestBinary":
        return true
  false

proc nimUnittestBinaryPath(action: BuildAction): string =
  for typedOutput in action.typedOutputs:
    for typeName in typedOutput.types:
      if typeName == "NimUnittestBinary":
        return typedOutput.path
  ""

proc discoverTestEdgesFromWorkspace(projectRoot: string;
                                    publicCliPath: string;
                                    mode: ToolProvisioningMode = tpmUnspecified):
    WorkspaceTestDiscovery =
  ## Walks the engine's normalised graph artefact for ``projectRoot`` and
  ## returns one ``ShardTestEdge`` per action whose typed-output type is
  ## ``NimUnittestBinary``.  The whole build-action graph is returned as
  ## ``actions`` so the planner can walk the dependency closures when
  ## costing each edge.
  result.edgeBinaryPath = initTable[NodeId, string]()
  let info = prepareBuildGraphInspection(projectRoot, mode,
    publicCliPath, selectDefaultAction = false)
  # Build a unique-id table so we don't double-add an action that appears
  # multiple times in ``info.actions`` (the engine returns one entry per
  # action id but defensive code is cheap).
  var seenIds = initHashSet[NodeId]()
  for action in info.actions:
    let nid = stableNodeIdFromString(action.id)
    if nid in seenIds:
      continue
    seenIds.incl(nid)
    var deps: seq[NodeId] = @[]
    for depId in action.deps:
      deps.add(stableNodeIdFromString(depId))
    result.actions.add(ShardBuildAction(
      id: nid,
      commandStatsId: action.commandStatsId,
      deps: deps))
  # Test edges: actions whose typedOutputs declare ``NimUnittestBinary``.
  # Use a separate id space for the edge root (hash of "test:" + actionId)
  # so the planner's ``PartitionRoot.id`` and the build-graph node id never
  # collide on the same NodeId — the bridge node the planner adds for the
  # root would otherwise overwrite the action's real node.
  for action in info.actions:
    if not isNimUnittestBinaryEdge(action):
      continue
    let buildActionId = stableNodeIdFromString(action.id)
    let edgeId = stableNodeIdFromString("test::" & action.id)
    let binaryPath = nimUnittestBinaryPath(action)
    result.edges.add(ShardTestEdge(
      id: edgeId,
      selector: action.id,
      historyKey: extractFilename(binaryPath),
      buildDeps: @[buildActionId]))
    result.edgeBinaryPath[edgeId] = binaryPath

proc writeWorkspacePartitionFile(path: string;
                                 binaryPaths: openArray[string]) =
  ## Writes the per-shard partition file in the ct-test-runner format:
  ## one fully-qualified test name per line.  For the workspace path we
  ## record the binary stem (whole-binary sharding) which the runner
  ## treats as an opaque-binary entry; this matches the documented format
  ## while still being trivial to author from the test-edge metadata.
  var lines: seq[string] = @[]
  lines.add(
    "# CI-Sharding M2 workspace partition file " &
    "— one fully-qualified test per line.")
  for binPath in binaryPaths:
    let stem = splitFile(binPath).name
    if stem.len > 0:
      lines.add(stem)
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  writeFile(path, lines.join("\n") & "\n")

proc buildClosureForShard(assignedSelectors: seq[string];
                          publicCliPath: string;
                          mode: ToolProvisioningMode = tpmUnspecified):
    tuple[code: int; output: string] =
  ## Builds the closure of the assigned test edges via ``runBuildCommand``.
  ## The strategy note in the milestone documents the trade-off: building
  ## the whole ``:test`` aggregate is simpler than computing the union of
  ## per-shard closures and lets the engine's existing dedup do its job;
  ## M3 will optimise this once the benchmark milestone is on the table.
  if assignedSelectors.len == 0:
    return (0, "")
  let bin =
    if publicCliPath.len > 0 and fileExists(publicCliPath): publicCliPath
    else: stablePublicCliPath()
  doAssert fileExists(bin), "repro binary missing at " & bin
  var buildArgs = @["build", "test"]
  if mode != tpmUnspecified:
    buildArgs.add("--tool-provisioning=" & modeName(mode))
  let p = startProcess(bin,
    workingDir = getCurrentDir(),
    args = buildArgs,
    options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  var buf = ""
  let outp = p.outputStream
  var line = newStringOfCap(120)
  while true:
    if outp.readLine(line):
      buf.add(line)
      buf.add("\n")
    else:
      let code = p.peekExitCode()
      if code != -1:
        return (code, buf)

proc locateCtTestRunner(): string =
  ## Mirrors ``scripts/run_tests.sh``'s Test-Edges M4 cut-over rule:
  ## prefer ``../ct-test/build/bin/ct-test-runner`` when present,
  ## otherwise fall back to ``tools/test-runner/repro_test_runner`` (the
  ## M3 internal protocol-level runner).  Returns ``""`` when neither is
  ## available — the caller surfaces a diagnostic.
  let exeExt = when defined(windows): ".exe" else: ""
  let primary = ".." / "ct-test" / "build" / "bin" / "ct-test-runner" & exeExt
  if fileExists(primary):
    return absolutePath(primary)
  let fallback = "build" / "bin" / "repro_test_runner" & exeExt
  if fileExists(fallback):
    return absolutePath(fallback)
  let toolsFallback = "tools" / "test-runner" / "repro_test_runner" & exeExt
  if fileExists(toolsFallback):
    return absolutePath(toolsFallback)
  ""

proc invokeCtTestRunner(runnerBin, binDir, partitionFile, summaryJson,
                        resultsDir: string;
                        threads: int;
                        assignedBinaryPaths: seq[string]):
    tuple[code: int; output: string] =
  ## Spawns the located runner with the per-shard parameters.  Passes
  ## assigned binary paths positionally (the runner skips ``--bin-dir``
  ## scanning when positionals are supplied, per its ``main`` proc).  We
  ## pass ``--partition`` too so the run is documented end-to-end even
  ## when positionals would otherwise have selected the same set — that
  ## keeps the partition file as a load-bearing input rather than a
  ## post-hoc record.
  var args: seq[string] = @[]
  args.add("run")
  args.add("--bin-dir=" & binDir)
  args.add("--summary-json=" & summaryJson)
  args.add("--results-dir=" & resultsDir)
  if threads > 0:
    args.add("--threads=" & $threads)
  args.add("--no-build")  # Build phase already completed via repro build.
  for binPath in assignedBinaryPaths:
    args.add(binPath)
  let p = startProcess(runnerBin,
    workingDir = getCurrentDir(),
    args = args,
    options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  var buf = ""
  let outp = p.outputStream
  var line = newStringOfCap(120)
  while true:
    if outp.readLine(line):
      buf.add(line)
      buf.add("\n")
    else:
      let code = p.peekExitCode()
      if code != -1:
        return (code, buf)

proc discoveryToShardPlanRequest(disc: WorkspaceTestDiscovery;
                                 shardCount: int;
                                 selectors: seq[string]): ShardPlanRequest =
  result.shardCount = shardCount
  result.targetSelectors = selectors
  result.policy = sipIndependent
  result.fallbackBuildCostNs = 1_000_000_000'i64
  result.fallbackTestCostNs = 1_000_000_000'i64
  result.refinementPasses = DefaultRefinementPasses
  result.buildActions = disc.actions
  result.testEdges = disc.edges

proc edgesAssignedToShardWorkspace(disc: WorkspaceTestDiscovery;
                                   plan: ShardPlan;
                                   shardIndex: int): seq[ShardTestEdge] =
  var byId = initTable[NodeId, ShardTestEdge]()
  for e in disc.edges:
    byId[e.id] = e
  for a in plan.partition.assignments:
    if a.shardIndex == shardIndex and byId.hasKey(a.root):
      result.add(byId[a.root])

proc loadSummaryJsonOrNull(path: string): JsonNode =
  if path.len == 0 or not fileExists(path):
    return newJNull()
  try:
    return parseJson(readFile(path))
  except CatchableError:
    return newJNull()

proc summarizeTestResults(summary: JsonNode): tuple[passed, failed: int] =
  ## Reads ``summary["summary"]["passed"]`` / ``["failed"]`` (the schema the
  ## ct-test-runner / repro_test_runner writes).  Returns ``(0, 0)`` on a
  ## null / malformed document so callers can still write a report.
  if summary.isNil or summary.kind != JObject:
    return (0, 0)
  if not summary.hasKey("summary"):
    return (0, 0)
  let s = summary["summary"]
  if s.kind != JObject:
    return (0, 0)
  result.passed =
    if s.hasKey("passed") and s["passed"].kind == JInt: s["passed"].getInt()
    else: 0
  result.failed =
    if s.hasKey("failed") and s["failed"].kind == JInt: s["failed"].getInt()
    else: 0

proc runFixtureModeShard(opts: ReproTestShardOpts;
                         peer: PeerCacheSpecResult): int =
  ## The M2 fixture path, preserved verbatim for the existing M2 e2e
  ## tests.  Behaviour is unchanged from the original
  ## ``runReproTestCommand`` body — the workspace-mode dispatch above
  ## simply forwards here when ``--fixture-from`` is supplied.
  var fixture: ReproTestFixture
  try:
    fixture = loadReproTestFixture(opts.fixturePath)
  except CatchableError as exc:
    emitShardDiagnostic("failed to load fixture: " & exc.msg)
    return 2

  var plan: ShardPlan
  var planMeta: ShardPlanRequest
  if opts.planFromPath.len > 0:
    try:
      let loaded = readPartitionPlanJson(opts.planFromPath)
      plan = loaded.plan
      planMeta = loaded.meta
    except PartitionPlanReadError as exc:
      emitShardDiagnostic("failed to read partition plan: " & exc.msg)
      return 2
  else:
    let shardCount =
      if opts.shardCount > 0: opts.shardCount
      else: 1
    let req = fixtureToShardPlanRequest(fixture, shardCount, opts.selectors)
    plan = planTestShards(req)
    planMeta = req

  if opts.emitPlanPath.len > 0:
    try:
      writePartitionPlanJson(plan, opts.emitPlanPath, planMeta)
    except CatchableError as exc:
      emitShardDiagnostic("failed to write partition plan: " & exc.msg)
      return 1
    return 0

  if opts.shardCount == 0:
    emitShardDiagnostic("--shard <k>/<N> is required for an actual run")
    return 2

  let peerCacheMode = modeName(peer.kind)
  let assignedRoots = shardAssignmentIds(plan, opts.shardIndex)
  let assignedEdges = edgesAssignedToShard(fixture, plan, opts.shardIndex)
  let actionsClosure = closureActionsForShard(fixture, assignedRoots)

  let buildStart = epochTime()
  var buildFailed = false
  var buildOutput = ""
  for a in actionsClosure:
    let res = runFixtureCmd(a.buildCmd, getCurrentDir())
    buildOutput.add(res.output)
    if res.code != 0:
      buildFailed = true
      stderr.writeLine("repro test: build action failed: " &
        $a.id.value & " — exit " & $res.code)
      break
  let buildElapsedNs = int64((epochTime() - buildStart) * 1_000_000_000.0)

  let partitionFilePath =
    "test-logs" / ("partition-" & $opts.shardIndex & "-of-" &
      $opts.shardCount & ".txt")
  writePartitionFile(partitionFilePath, assignedEdges)

  let testStart = epochTime()
  var testResults = newJArray()
  var passed = 0
  var failed = 0
  if not buildFailed:
    for e in assignedEdges:
      let res = runFixtureCmd(e.runCmd, getCurrentDir())
      var node = newJObject()
      node["edge_id"] = %int(e.id.value)
      node["selector"] = %e.selector
      node["test_name"] = %e.testName
      node["status"] = %(if res.code == 0: "PASS" else: "FAIL")
      node["exit_code"] = %res.code
      node["output"] = %res.output
      testResults.add(node)
      if res.code == 0:
        inc passed
      else:
        inc failed
  let testElapsedNs = int64((epochTime() - testStart) * 1_000_000_000.0)

  let predictedNs = predictedShardCostNs(plan, opts.shardIndex)
  let actualNs = buildElapsedNs + testElapsedNs
  let delta =
    if predictedNs > 0:
      (float(actualNs) - float(predictedNs)) / float(predictedNs)
    else:
      0.0
  let driftThreshold = 0.5
  let drift = abs(delta) > driftThreshold

  var report = newJObject()
  report["schemaId"] = %"reprobuild.shard-report.v1"
  report["shard"] = %opts.shardIndex
  report["shardCount"] = %opts.shardCount
  report["strategy"] = %opts.strategy
  report["peer_cache"] = %peerCacheMode
  report["fixture_path"] = %opts.fixturePath
  var assignedNames = newJArray()
  for e in assignedEdges:
    assignedNames.add(%e.selector)
  report["assigned_selectors"] = assignedNames
  report["predicted_shard_cost_ns"] = %predictedNs
  report["predicted_build_time_ns"] = %0
  report["predicted_test_time_ns"] = %0
  report["actual_build_time_ns"] = %buildElapsedNs
  report["actual_test_time_ns"] = %testElapsedNs
  report["actual_total_time_ns"] = %actualNs
  report["cost_model_delta"] = %delta
  report["cost_model_drift"] = %drift
  report["build_failed"] = %buildFailed
  report["tests"] = testResults
  report["test_pass_count"] = %passed
  report["test_fail_count"] = %failed
  report["partition_file"] = %partitionFilePath
  report["degraded_plan"] = %plan.degraded
  report["unknown_build_count"] = %plan.unknownBuildCount
  report["unknown_test_count"] = %plan.unknownTestCount

  let reportPath =
    if opts.reportPath.len > 0: opts.reportPath
    else:
      "test-logs" / ("shard-" & $opts.shardIndex & "-of-" &
        $opts.shardCount & ".json")
  writeShardReport(reportPath, report)

  if buildFailed:
    return 1
  if failed > 0:
    return 1
  0

proc runWorkspaceModeShard(opts: ReproTestShardOpts;
                           peer: PeerCacheSpecResult;
                           publicCliPath: string): int =
  ## Workspace-driven shard runner.  Discovers real test edges via the
  ## engine's normalised graph artefact, builds the closure via
  ## ``repro build test``, and hands off to ct-test-runner with the
  ## assigned binaries.  Replaces the M2 ``--fixture-from`` deviation
  ## for the on-the-suite case the M3 benchmark milestone depends on.
  var disc: WorkspaceTestDiscovery
  try:
    disc = discoverTestEdgesFromWorkspace(".", publicCliPath,
      opts.toolProvisioning)
  except CatchableError as exc:
    emitShardDiagnostic(
      "workspace test-edge discovery failed: " & exc.msg)
    return 2
  if disc.edges.len == 0:
    emitShardDiagnostic(
      "workspace test-edge discovery returned no NimUnittestBinary " &
      "edges; nothing to shard.  (Did you mean to pass --fixture-from?)")
    return 2

  var plan: ShardPlan
  var planMeta: ShardPlanRequest
  if opts.planFromPath.len > 0:
    try:
      let loaded = readPartitionPlanJson(opts.planFromPath)
      plan = loaded.plan
      planMeta = loaded.meta
    except PartitionPlanReadError as exc:
      emitShardDiagnostic("failed to read partition plan: " & exc.msg)
      return 2
  else:
    let shardCount =
      if opts.shardCount > 0: opts.shardCount
      else: 1
    let req = discoveryToShardPlanRequest(disc, shardCount, opts.selectors)
    plan = planTestShards(req)
    planMeta = req

  if opts.emitPlanPath.len > 0:
    try:
      writePartitionPlanJson(plan, opts.emitPlanPath, planMeta)
    except CatchableError as exc:
      emitShardDiagnostic("failed to write partition plan: " & exc.msg)
      return 1
    return 0

  if opts.shardCount == 0:
    emitShardDiagnostic("--shard <k>/<N> is required for an actual run")
    return 2

  let peerCacheMode = modeName(peer.kind)
  let assignedEdges =
    edgesAssignedToShardWorkspace(disc, plan, opts.shardIndex)
  var assignedBinaryPaths: seq[string] = @[]
  var assignedSelectors: seq[string] = @[]
  for e in assignedEdges:
    assignedSelectors.add(e.selector)
    if disc.edgeBinaryPath.hasKey(e.id):
      assignedBinaryPaths.add(disc.edgeBinaryPath[e.id])

  # ----- Build phase: build the :test aggregate.  See the milestone
  # strategy note for why we don't compute per-shard closures here.
  let buildStart = epochTime()
  var buildFailed = false
  let buildRes = buildClosureForShard(assignedSelectors, publicCliPath,
    opts.toolProvisioning)
  if buildRes.code != 0:
    buildFailed = true
    stderr.writeLine("repro test: workspace build phase failed " &
      "(exit " & $buildRes.code & ")")
    stderr.write(buildRes.output)
  let buildElapsedNs = int64((epochTime() - buildStart) * 1_000_000_000.0)

  # ----- Partition file: written before the test phase so the
  # per-shard report can reference it even when the runner skips it.
  let partitionFilePath =
    "test-logs" / ("partition-" & $opts.shardIndex & "-of-" &
      $opts.shardCount & ".txt")
  writeWorkspacePartitionFile(partitionFilePath, assignedBinaryPaths)

  # ----- Test phase: locate ct-test-runner (preferring the sibling),
  # invoke with the assigned binary set.
  let summaryJson =
    "test-logs" / ("shard-" & $opts.shardIndex & "-of-" &
      $opts.shardCount & "-summary.json")
  let resultsDir =
    "test-logs" / ("shard-" & $opts.shardIndex & "-of-" &
      $opts.shardCount & "-results")
  if not dirExists(resultsDir):
    createDir(resultsDir)
  let runnerBin = locateCtTestRunner()
  let testStart = epochTime()
  var runnerOutput = ""
  var runnerCode = 0
  var runnerInvoked = false
  if buildFailed:
    discard
  elif runnerBin.len == 0:
    stderr.writeLine("repro test: no ct-test-runner located " &
      "(checked ../ct-test/build/bin/ct-test-runner, " &
      "build/bin/repro_test_runner, tools/test-runner/repro_test_runner). " &
      "Build a runner before sharding.")
    runnerCode = 1
  elif assignedBinaryPaths.len == 0:
    # Nothing assigned to this shard — still write a summary record.
    discard
  else:
    runnerInvoked = true
    let invocation = invokeCtTestRunner(runnerBin,
      "build/test-bin", partitionFilePath, summaryJson, resultsDir,
      0, assignedBinaryPaths)
    runnerCode = invocation.code
    runnerOutput = invocation.output
  let testElapsedNs = int64((epochTime() - testStart) * 1_000_000_000.0)

  let runnerSummary = loadSummaryJsonOrNull(summaryJson)
  let counts = summarizeTestResults(runnerSummary)

  let predictedNs = predictedShardCostNs(plan, opts.shardIndex)
  let actualNs = buildElapsedNs + testElapsedNs
  let delta =
    if predictedNs > 0:
      (float(actualNs) - float(predictedNs)) / float(predictedNs)
    else:
      0.0
  let driftThreshold = 0.5
  let drift = abs(delta) > driftThreshold

  # Build the per-test results array from the runner's summary, so the
  # per-shard report carries per-test outcomes (not just aggregate
  # counts).
  var testResults = newJArray()
  if runnerSummary.kind == JObject and runnerSummary.hasKey("tests") and
      runnerSummary["tests"].kind == JArray:
    for entry in runnerSummary["tests"].elems:
      testResults.add(entry)

  var report = newJObject()
  report["schemaId"] = %"reprobuild.shard-report.v1"
  report["shard"] = %opts.shardIndex
  report["shardCount"] = %opts.shardCount
  report["strategy"] = %opts.strategy
  report["peer_cache"] = %peerCacheMode
  report["fixture_path"] = %""  # workspace mode — no fixture
  report["mode"] = %"workspace"
  report["runner_binary"] = %runnerBin
  report["runner_invoked"] = %runnerInvoked
  report["runner_exit_code"] = %runnerCode
  report["summary_json"] = %summaryJson
  if not runnerSummary.isNil and runnerSummary.kind != JNull:
    report["runner_summary"] = runnerSummary
  else:
    report["runner_summary"] = newJNull()
  var assignedNames = newJArray()
  for sel in assignedSelectors:
    assignedNames.add(%sel)
  report["assigned_selectors"] = assignedNames
  var assignedBins = newJArray()
  for p in assignedBinaryPaths:
    assignedBins.add(%p)
  report["assigned_binaries"] = assignedBins
  report["predicted_shard_cost_ns"] = %predictedNs
  report["predicted_build_time_ns"] = %0
  report["predicted_test_time_ns"] = %0
  report["actual_build_time_ns"] = %buildElapsedNs
  report["actual_test_time_ns"] = %testElapsedNs
  report["actual_total_time_ns"] = %actualNs
  report["cost_model_delta"] = %delta
  report["cost_model_drift"] = %drift
  report["build_failed"] = %buildFailed
  report["tests"] = testResults
  report["test_pass_count"] = %counts.passed
  report["test_fail_count"] = %counts.failed
  report["partition_file"] = %partitionFilePath
  report["degraded_plan"] = %plan.degraded
  report["unknown_build_count"] = %plan.unknownBuildCount
  report["unknown_test_count"] = %plan.unknownTestCount

  let reportPath =
    if opts.reportPath.len > 0: opts.reportPath
    else:
      "test-logs" / ("shard-" & $opts.shardIndex & "-of-" &
        $opts.shardCount & ".json")
  writeShardReport(reportPath, report)

  if buildFailed:
    return 1
  if counts.failed > 0 or runnerCode != 0:
    return 1
  0

proc runReproTestCommand*(args: openArray[string];
                          publicCliPath: string): int =
  ## ``repro test`` entry point with the CI-sharding flag surface from
  ## ``CI-Sharding.md`` §"CLI Surface".  See the block comment above
  ## for the per-flag semantics.
  var opts: ReproTestShardOpts
  try:
    opts = parseReproTestFlags(args)
  except ValueError as exc:
    emitShardDiagnostic(exc.msg)
    return 2

  # ``--peer-cache=lan://CIDR[:port]`` — Peer-Cache M2 wires this
  # through to the multicast discovery plane. The CI-Sharding M3
  # benchmark consumes the resulting peer-cache via the
  # action-cache-reader seam (which is opt-in at the engine level
  # until the digest impedance from Peer-Cache.milestones.org §M1
  # Outstanding Tasks is resolved).
  let peer = parsePeerCache(opts.peerCacheSpec)
  if not peer.ok:
    emitShardDiagnostic(
      "invalid --peer-cache spec: " & opts.peerCacheSpec &
      " (expected ``none``, ``lan://<CIDR>``, or ``remote://<URL>``)")
    return 2
  if peer.kind == pcsLan:
    # Generate a transient peer ID for this shard. The CLI doesn't
    # yet persist a peer ID to ``peer_cache.peer_id_path`` from the
    # spec's configuration surface — that lands once M3 introduces a
    # multi-host setup. For M2's loopback validation the transient
    # ID is sufficient.
    var raw: array[32, byte]
    raw[0] = byte(ord('R'))  # ``R`` for repro test, distinct from
                             # the loopback helper's ``L``.
    let nowSeconds = uint64(epochTime())
    for i in 0 ..< 8:
      raw[1 + i] = byte((nowSeconds shr uint64(i * 8)) and 0xff'u64)
    let cliPeerId = peerIdFromBytes(raw)
    try:
      lastStartedPeerCacheRuntime =
        startPeerCacheServices(peer.config, cliPeerId,
                              listenAddr = "127.0.0.1")
    except CatchableError as exc:
      emitShardDiagnostic(
        "failed to start peer-cache services: " & exc.msg)
      return 2

  # ``--partition-strategy hash`` / ``duration`` — recognised by the
  # parser but the wired strategies in M2 are ``joint-duration`` (the
  # planner-driven path) and ``slice`` (a planner cold-cache fallback).
  case opts.strategy
  of "joint-duration", "slice":
    discard
  of "hash", "duration":
    emitShardDiagnostic(
      "--partition-strategy=" & opts.strategy &
      " is not implemented in this milestone — see CI-Sharding " &
      "M3+ for the duration/hash strategies.")
    return 2
  else:
    emitShardDiagnostic(
      "unknown --partition-strategy value: " & opts.strategy)
    return 2

  if opts.shardCount == 0 and opts.emitPlanPath.len == 0 and
      opts.planFromPath.len == 0:
    emitShardDiagnostic(
      "--shard <k>/<N> is required when not using --emit-partition-plan " &
      "or --plan-from")
    return 2

  # Two code paths from here:
  #   (a) ``--fixture-from=<path>`` — the M2 fixture path, kept for
  #       backwards compatibility with the existing M2 e2e tests.  See
  #       ``runFixtureModeShard`` below.
  #   (b) Workspace mode — discover real test edges via the engine's
  #       normalised graph artefact, build the closure, and hand off to
  #       ct-test-runner.  This is the CI-Sharding M2 follow-up that
  #       this milestone fix delivers.
  if opts.fixturePath.len > 0:
    return runFixtureModeShard(opts, peer)
  return runWorkspaceModeShard(opts, peer, publicCliPath)

# --------------------------------------------------------------------
# Spec-Implementation M2e — `repro lock explain <variant>` subcommand
# --------------------------------------------------------------------
#
# Surfaces the M2e structured ``ExplainChain`` (for chosen-variant
# justifications) and the assumption-interface unsat-core (for
# unsatisfiable solves) on the operator-facing CLI. The verb lives
# under the ``repro lock`` namespace per Locking-And-Solver.md
# §"CLI Surface" (which earmarks ``repro lock solve``, ``debug``, and
# ``visualize`` for the same namespace; ``explain`` is the M2e sibling).
#
# The subcommand operates in two modes:
#
#   1. **Fixture mode** (``--fixture <path>``): the fixture file is a
#      tiny declarative format describing variants + packages so the
#      command is testable without a full project on disk. The format
#      is line-oriented and intentionally minimal — it is NOT a
#      replacement for the project DSL.
#
#   2. **Default mode**: when no fixture is supplied, the command
#      reports an error explaining that workspace-driven explain
#      requires an active build context (M3+ wiring; M2e ships the
#      fixture mode so the diagnostic surface is testable on its
#      own).
#
# Output: human-readable text by default; ``--json`` emits a
# machine-readable JSON document.

type
  FixtureParserState = object
    variants: seq[variant_encoder.VariantDecl]
    packages: seq[PackageDecl]
    currentKind: string
    currentName: string
    vKind: VariantKind
    vValues: seq[string]
    vContribs: seq[VariantContribution]
    vConstraints: seq[ConstraintExpr]
    pVersions: seq[string]
    pDepends: seq[DependencyDecl]

proc flushFixtureBlock(s: var FixtureParserState) =
  if s.currentKind == "variant":
    s.variants.add(variant_encoder.VariantDecl(
      name: s.currentName, kind: s.vKind,
      allowedValues: s.vValues,
      contributions: s.vContribs,
      constraints: s.vConstraints))
  elif s.currentKind == "package":
    s.packages.add(PackageDecl(
      name: s.currentName, versions: s.pVersions,
      depends: s.pDepends, variants: @[]))
  s.currentKind = ""
  s.currentName = ""
  s.vKind = vkEnum
  s.vValues = @[]
  s.vContribs = @[]
  s.vConstraints = @[]
  s.pVersions = @[]
  s.pDepends = @[]

proc parseExplainFixture(text: string): tuple[
    variants: seq[variant_encoder.VariantDecl],
    packages: seq[PackageDecl]] =
  ## Parse the M2e fixture format. The format is a sequence of blocks
  ## separated by blank lines; each block declares one variant or one
  ## package. Variant blocks start with ``variant <name>``; package
  ## blocks start with ``package <name>``. Inside a variant block:
  ##
  ##   kind: bool|enum
  ##   values: a, b, c          (enum only)
  ##   default: <value>
  ##   set: <value>             (vpSet contribution)
  ##   override: <value>        (vpOverride contribution)
  ##   force: <value>           (vpForce contribution)
  ##   requires: <src> -> <target> = <value>
  ##   conflicts: <src> -> <target> = <value>
  ##   propagates: <src> -> <target> = <value>
  ##
  ## Inside a package block:
  ##
  ##   versions: 1.0.0, 1.1.0
  ##   depends: <name> <range>
  ##   depends: <name> <range> when <variant>=<value>
  var s = FixtureParserState(
    variants: @[], packages: @[],
    currentKind: "", currentName: "",
    vKind: vkEnum, vValues: @[],
    vContribs: @[], vConstraints: @[],
    pVersions: @[], pDepends: @[])

  for rawLine in text.splitLines():
    let line = rawLine.strip()
    if line.len == 0:
      if s.currentKind.len > 0:
        flushFixtureBlock(s)
      continue
    if line.startsWith("#"):
      continue
    if line.startsWith("variant "):
      if s.currentKind.len > 0: flushFixtureBlock(s)
      s.currentKind = "variant"
      s.currentName = line[len("variant ") .. ^1].strip()
      continue
    if line.startsWith("package "):
      if s.currentKind.len > 0: flushFixtureBlock(s)
      s.currentKind = "package"
      s.currentName = line[len("package ") .. ^1].strip()
      continue
    let colonAt = line.find(':')
    if colonAt < 0: continue
    let key = line[0 ..< colonAt].strip()
    let val = line[colonAt + 1 .. ^1].strip()
    case s.currentKind
    of "variant":
      case key
      of "kind":
        if val == "bool":
          s.vKind = vkBool
          s.vValues = @["true", "false"]
        else:
          s.vKind = vkEnum
      of "values":
        s.vKind = vkEnum
        s.vValues = @[]
        for piece in val.split(','):
          s.vValues.add(piece.strip())
      of "default":
        s.vContribs.add(contribution(vpDefault, val))
      of "set":
        s.vContribs.add(contribution(vpSet, val))
      of "override":
        s.vContribs.add(contribution(vpOverride, val))
      of "force":
        s.vContribs.add(contribution(vpForce, val))
      of "requires", "conflicts", "propagates":
        # Format: "<sourceValue> -> <target> = <value>"
        let arrow = val.find("->")
        if arrow < 0: continue
        let sourceValue = val[0 ..< arrow].strip()
        let rhs = val[arrow + 2 .. ^1].strip()
        let eq = rhs.find('=')
        if eq < 0: continue
        let target = rhs[0 ..< eq].strip()
        let targetValue = rhs[eq + 1 .. ^1].strip()
        case key
        of "requires":
          s.vConstraints.add(requiresExpr(sourceValue, target, targetValue))
        of "conflicts":
          s.vConstraints.add(conflictsExpr(sourceValue, target, targetValue))
        of "propagates":
          s.vConstraints.add(propagatesExpr(sourceValue, target, targetValue))
        else: discard
      else: discard
    of "package":
      case key
      of "versions":
        s.pVersions = @[]
        for piece in val.split(','):
          s.pVersions.add(piece.strip())
      of "depends":
        # "name range" or "name range when variant=value"
        let whenAt = val.find(" when ")
        var head = val
        var gateVariant = ""
        var gateValue = ""
        if whenAt >= 0:
          head = val[0 ..< whenAt].strip()
          let gate = val[whenAt + len(" when ") .. ^1].strip()
          let eq = gate.find('=')
          if eq >= 0:
            gateVariant = gate[0 ..< eq].strip()
            gateValue = gate[eq + 1 .. ^1].strip()
        let firstSpace = head.find(' ')
        if firstSpace < 0:
          s.pDepends.add(newDependency(head.strip(), ""))
        else:
          let depName = head[0 ..< firstSpace].strip()
          let depRange = head[firstSpace + 1 .. ^1].strip()
          if gateVariant.len > 0:
            s.pDepends.add(newConditionalDependency(
              depName, depRange, gateVariant, gateValue))
          else:
            s.pDepends.add(newDependency(depName, depRange))
      else: discard
    else: discard
  if s.currentKind.len > 0:
    flushFixtureBlock(s)
  result = (variants: s.variants, packages: s.packages)

proc renderExplainChainText(chain: ExplainChain): string =
  ## Human-readable rendering of an ExplainChain. Mirrors the shape
  ## of Spack's ``spack spec --explain`` output: one block per
  ## evidence kind, each prefixed by the variant name and the chosen
  ## value at the top.
  result = ""
  result.add("variant: " & chain.variant & "\n")
  result.add("chosen: " & chain.chosen & "\n")
  result.add("contributions:\n")
  if chain.contributions.len == 0:
    result.add("  (none)\n")
  else:
    for c in chain.contributions:
      let pName = case c.priority
        of vpDefault: "default"
        of vpSet: "set"
        of vpOverride: "override"
        of vpForce: "force"
      result.add("  - " & pName & " -> " & c.value & "\n")
  result.add("gating constraints:\n")
  if chain.gatingConstraints.len == 0:
    result.add("  (none)\n")
  else:
    for g in chain.gatingConstraints:
      let kindStr = case g.kind
        of crkRequires: "requires"
        of crkConflicts: "conflicts"
        of crkPropagates: "propagates"
      result.add("  - " & kindStr & ": " & g.sourceValue & " -> " &
                 g.target & "=" & g.targetValue & "\n")
  result.add("parent influences:\n")
  if chain.parentInfluences.len == 0:
    result.add("  (none)\n")
  else:
    for p in chain.parentInfluences:
      result.add("  - " & p.parentPackage & "." & p.parentVariant &
                 "==" & p.parentValue & "\n")

proc renderExplainChainJson(chain: ExplainChain): JsonNode =
  result = newJObject()
  result["variant"] = %chain.variant
  result["chosen"] = %chain.chosen
  let contribs = newJArray()
  for c in chain.contributions:
    let cj = newJObject()
    cj["priority"] = %(
      case c.priority
      of vpDefault: "default"
      of vpSet: "set"
      of vpOverride: "override"
      of vpForce: "force")
    cj["value"] = %c.value
    contribs.add(cj)
  result["contributions"] = contribs
  let gates = newJArray()
  for g in chain.gatingConstraints:
    let gj = newJObject()
    gj["kind"] = %(case g.kind
      of crkRequires: "requires"
      of crkConflicts: "conflicts"
      of crkPropagates: "propagates")
    gj["sourceValue"] = %g.sourceValue
    gj["target"] = %g.target
    gj["targetValue"] = %g.targetValue
    gates.add(gj)
  result["gatingConstraints"] = gates
  let parents = newJArray()
  for p in chain.parentInfluences:
    let pj = newJObject()
    pj["parentPackage"] = %p.parentPackage
    pj["parentVariant"] = %p.parentVariant
    pj["parentValue"] = %p.parentValue
    parents.add(pj)
  result["parentInfluences"] = parents

proc renderUnsatCoreText(entries: seq[UnsatCoreEntry];
                         programText: string): string =
  result = "UNSAT — minimal core:\n"
  if entries.len == 0:
    result.add("  (no minimal core produced; falling back to " &
               "best-effort participants)\n")
  else:
    for e in entries:
      result.add("  - [" & e.kind & "] " & e.source & "\n")

proc renderUnsatCoreJson(entries: seq[UnsatCoreEntry];
                        programText: string): JsonNode =
  result = newJObject()
  result["status"] = %"unsat"
  let arr = newJArray()
  for e in entries:
    let j = newJObject()
    j["kind"] = %e.kind
    j["source"] = %e.source
    j["atom"] = %e.atom
    arr.add(j)
  result["core"] = arr

proc runReproLockCommand*(args: openArray[string]): int =
  ## Top-level dispatcher for ``repro lock <verb> ...``. M2e ships the
  ## ``explain`` verb; future milestones land ``solve``, ``debug``,
  ## ``visualize`` per Locking-And-Solver.md §"CLI Surface".
  if args.len == 0:
    stderr.writeLine("repro lock: error: missing verb (try `explain`)")
    return 2
  case args[0]
  of "explain":
    let rest =
      if args.len > 1: args[1 .. ^1]
      else: @[]
    var variantName = ""
    var fixturePath = ""
    var asJson = false
    var i = 0
    while i < rest.len:
      let arg = rest[i]
      if arg == "--json":
        asJson = true
        inc i
      elif arg == "--fixture" or arg.startsWith("--fixture="):
        if arg.startsWith("--fixture="):
          fixturePath = arg["--fixture=".len .. ^1]
        else:
          if i + 1 >= rest.len:
            stderr.writeLine("repro lock explain: --fixture requires a path")
            return 2
          fixturePath = rest[i + 1]
          inc i
        inc i
      elif arg.startsWith("--"):
        stderr.writeLine("repro lock explain: unknown flag " & arg)
        return 2
      else:
        if variantName.len > 0:
          stderr.writeLine("repro lock explain: at most one variant " &
                           "positional accepted")
          return 2
        variantName = arg
        inc i
    if variantName.len == 0:
      stderr.writeLine("repro lock explain: missing <variant> positional")
      return 2
    if fixturePath.len == 0:
      stderr.writeLine("repro lock explain: --fixture <path> is required " &
                       "in M2e (workspace-driven explain lands in M3+)")
      return 2
    if not fileExists(fixturePath):
      stderr.writeLine("repro lock explain: fixture not found: " & fixturePath)
      return 1
    let text = readFile(fixturePath)
    let parsed = parseExplainFixture(text)
    var sol: UnifiedSolution
    var unsatErr: ref EUnsatisfiable = nil
    try:
      sol = solve(parsed.variants, parsed.packages)
    except EUnsatisfiable as e:
      unsatErr = (ref EUnsatisfiable)()
      unsatErr.msg = e.msg
      unsatErr.programText = e.programText
      unsatErr.unsatCore = e.unsatCore
      unsatErr.coreAtoms = e.coreAtoms
    if unsatErr != nil:
      let entries = explainUnsat(unsatErr.coreAtoms, parsed.variants,
                                  parsed.packages)
      if asJson:
        echo $renderUnsatCoreJson(entries, unsatErr.programText)
      else:
        stdout.write(renderUnsatCoreText(entries, unsatErr.programText))
      return 3  # exit code 3 reserved for "unsat"
    try:
      let chain = explainChosen(sol, variantName, parsed.variants,
                                parsed.packages)
      if asJson:
        echo $renderExplainChainJson(chain)
      else:
        stdout.write(renderExplainChainText(chain))
      return 0
    except EVariantNotInSolution as e:
      stderr.writeLine("repro lock explain: " & e.msg)
      return 1
  else:
    stderr.writeLine("repro lock: unknown verb '" & args[0] & "'")
    return 2

const internalHelperAliases = {
  # Documented ``repro internal <name>`` spellings (Executable-Consolidation
  # M1) mapped to the historical ``__repro-<name>`` argument forms. The
  # ``__``-prefixed forms remain accepted as compatibility aliases for one
  # release; both route to the identical handler. ``fs-snoop`` is handled
  # separately because it has no ``__repro-`` form (its user-facing spelling
  # is ``repro debug fs-snoop``).
  "runquota-helper": "__repro-runquota-helper",
  "compile-provider": "__repro-compile-provider",
  "compile-profile": "__repro-compile-profile",
  "dev-env-introspect": "__repro-dev-env-introspect",
  "render-dev-env-shell": "__repro-render-dev-env-shell",
  "direnv-activate": "__repro-direnv-activate",
  "native-shell-activate": "__repro-native-shell-activate",
  "dev-session-supervisor": "__repro-dev-session-supervisor",
  "dev-session-http": "__repro-dev-session-http",
  "cmake-regenerate": "__repro-cmake-regenerate",
}.toTable

proc normalizeInternalArgs(args: seq[string]): seq[string] =
  ## Map ``internal <name> <rest…>`` onto the same argument vector the
  ## ``__repro-<name>`` helper forms use, so the documented ``internal``
  ## namespace and the historical ``__``-prefixed aliases share one set of
  ## handlers below. Subcommands without a ``__repro-`` equivalent (``fs-snoop``,
  ## usage/help) are left untouched for the dedicated ``internal`` arm in
  ## ``runThinApp`` to handle.
  if args.len >= 1 and args[0] == "internal" and args.len >= 2 and
      internalHelperAliases.hasKey(args[1]):
    result = @[internalHelperAliases[args[1]]]
    if args.len > 2:
      result.add(args[2 .. ^1])
  else:
    result = args

proc runThinApp*(programName: string): int =
  let args = normalizeInternalArgs(commandLineParams())
  let publicCliPath = stablePublicCliPath()
  if programName == "repro" and args.len > 0 and
      args[0] == BrokerModeFlag:
    return runPrivilegedBrokerMode(args)
  if wantsVersion(args):
    echo renderVersion(programName)
    return 0
  if wantsHelp(args):
    # Explicit help request — print usage to stdout, exit 0 so the
    # output is pipeable / scriptable. Bare / unknown commands still
    # fall through to the stderr-+-exit-2 path at the end of this
    # proc.
    echo renderUsage(programName)
    return 0
  if programName == "reprostored":
    return runReprostoredCommand(args)
  if programName == "repro-daemon":
    installUserDaemonBuildPrewarmer()
    installUserDaemonBuildExecutor()
    installUserDaemonWatchExecutor()
    return runUserDaemonCommand(args)
  if programName == "repro-fs-snoop":
    return runFsSnoopCli(programName, args)
  # Documented ``repro internal …`` namespace (Executable-Consolidation M1).
  # ``internal <helper>`` spellings for the role helpers were already rewritten
  # to their ``__repro-<helper>`` argument form by ``normalizeInternalArgs``
  # above, so any ``internal`` argv still reaching here is either ``fs-snoop``
  # (which has no ``__repro-`` form), an explicit ``--help``, or an
  # unknown/bare subcommand — all handled by this arm. ``repro internal`` is
  # intentionally absent from the primary ``repro help`` body; it is documented
  # via ``renderInternalUsage`` (and ``CLI/internal/`` in the specs).
  if args.len > 0 and args[0] == "internal":
    if args.len >= 2 and args[1] == "fs-snoop":
      # Mirror ``repro debug fs-snoop``: forward the remaining args to the
      # shared fs-snoop CLI. This is the spelling the internal monitor spawn
      # self-spawns (``getAppFilename() internal fs-snoop …``).
      let fsArgs =
        if args.len > 2:
          args[2 .. ^1]
        else:
          @[]
      return runFsSnoopCli("repro internal fs-snoop", fsArgs)
    # Bare ``repro internal``, ``repro internal --help``, or an unrecognized
    # subcommand: print the internal-namespace usage. Exit 0 for an explicit
    # help request (pipeable), exit 2 for an unknown/missing subcommand —
    # matching the stdout/exit-0 vs stderr/exit-2 convention used elsewhere.
    if args.len == 1 or (args.len >= 2 and args[1] in ["help", "--help", "-h"]):
      echo renderInternalUsage(programName)
      return 0
    stderr.writeLine(renderInternalUsage(programName))
    return 2
  if args.len > 0 and args[0] == "__repro-runquota-helper":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runRunQuotaHelperCli(helperArgs)
  if args.len > 0 and args[0] == "__repro-compile-provider":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runProviderCompileHelper(helperArgs)
  if args.len > 0 and args[0] == "__repro-compile-profile":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runProfileCompileHelper(helperArgs)
  if args.len > 0 and args[0] == "__repro-dev-env-introspect":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runDevEnvIntrospectionHelper(helperArgs)
  if args.len > 0 and args[0] == "__repro-render-dev-env-shell":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runDevEnvShellRenderHelper(helperArgs)
  if args.len > 0 and args[0] == "__repro-direnv-activate":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    try:
      return runReproDirenvActivationHelper(helperArgs, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro direnv activate: error: " & err.msg)
      return 1
  if args.len > 0 and args[0] == "__repro-native-shell-activate":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    try:
      return runReproNativeShellActivationHelper(helperArgs, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro native shell activate: error: " & err.msg)
      return 1
  if args.len > 0 and args[0] == "__repro-dev-session-supervisor":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    try:
      return runDevSessionSupervisorHelper(helperArgs, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro dev-session supervisor: error: " & err.msg)
      return 1
  if args.len > 0 and args[0] == "__repro-dev-session-http":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    try:
      return runDevSessionHttpHelper(helperArgs)
    except CatchableError as err:
      stderr.writeLine("repro dev-session http: error: " & err.msg)
      return 1
  if args.len > 0 and args[0] == "__repro-cmake-regenerate":
    let helperArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    try:
      return runCmakeRegenerationHelper(helperArgs)
    except CatchableError as err:
      stderr.writeLine("repro cmake regeneration: error: " & err.msg)
      return 1
  if programName == "repro" and args.len >= 2 and args[0] == "debug" and
      args[1] == "fs-snoop":
    let fsArgs =
      if args.len > 2:
        args[2 .. ^1]
      else:
        @[]
    return runFsSnoopCli("repro debug fs-snoop", fsArgs)
  if programName == "repro" and args.len >= 2 and args[0] == "debug" and
      args[1] == "artifact":
    try:
      let artifactArgs =
        if args.len > 2:
          args[2 .. ^1]
        else:
          @[]
      return runDebugArtifactCommand(artifactArgs)
    except CatchableError as err:
      stderr.writeLine("repro debug artifact: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "capabilities":
    try:
      let capabilityArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runCapabilitiesCommand(capabilityArgs)
    except CatchableError as err:
      stderr.writeLine("repro capabilities: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "graph":
    try:
      let graphArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runGraphCommand(graphArgs, publicCliPath)
    except BuildTargetAmbiguousError as err:
      # Named-Targets M5 ``target_ambiguous`` diagnostic for the
      # graph arm. Same shape as ``repro build`` so JSON consumers
      # and test harnesses can rely on the unified text.
      stderr.write(renderAmbiguousTargetDiagnostic(err[]))
      return 2
    except BuildTargetUnknownError as err:
      # Named-Targets M5 ``unknown_target`` diagnostic with the M2
      # Levenshtein candidates.
      stderr.write(renderUnknownTargetDiagnostic(err[]))
      return 2
    except CatchableError as err:
      stderr.writeLine("repro graph: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "why":
    try:
      let whyArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runWhyCommand(whyArgs, publicCliPath)
    except BuildTargetAmbiguousError as err:
      stderr.write(renderAmbiguousTargetDiagnostic(err[]))
      return 2
    except BuildTargetUnknownError as err:
      stderr.write(renderUnknownTargetDiagnostic(err[]))
      return 2
    except CatchableError as err:
      stderr.writeLine("repro why: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "deps":
    try:
      let depsArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runDepsCommand(depsArgs)
    except CatchableError as err:
      stderr.writeLine("repro deps: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and
      args[0] == "show-conventions":
    try:
      let scArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runShowConventionsCommand(scArgs)
    except CatchableError as err:
      stderr.writeLine("repro show-conventions: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "build":
    try:
      let buildArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runBuildCommand(buildArgs, publicCliPath)
    except BuildTargetAmbiguousError as err:
      # Named-Targets M2 ``target_ambiguous`` diagnostic. Exit 2 per the
      # CLI-build §"Target Selection" contract; the message names the
      # qualified candidates so the user can re-run with the
      # ``<package>:<name>`` form. The diagnostic text is rendered by a
      # shared helper so the daemon-side translation in
      # ``installUserDaemonBuildExecutor`` produces identical bytes.
      stderr.write(renderAmbiguousTargetDiagnostic(err[]))
      return 2
    except BuildTargetUnknownError as err:
      # Named-Targets M2 ``unknown_target`` diagnostic. Exit 2 with
      # Levenshtein top-3 suggestions when the project's target-export
      # table has near-matches. Text rendered by the shared helper that
      # the daemon-side hook also calls.
      stderr.write(renderUnknownTargetDiagnostic(err[]))
      return 2
    except CatchableError as err:
      stderr.writeLine("repro build: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "test":
    # CI-Sharding M2 — ``repro test --shard k/N [...]``.  Implementation
    # in ``runReproTestCommand`` above; see the block comment there for
    # the user-visible flag surface and the fixture / plan I/O shape.
    #
    # Spec-Implementation M0 alias contract: ``repro test`` is also the
    # CLI verb alias for ``repro build test`` per Build-Graph-Collections.md
    # §"Verb Aliases for Conventional Collections". The CI-sharding
    # implementation already maps to ``repro build test`` internally
    # (see ``buildArgs = @["build", "test"]`` at the head of this file),
    # so the alias is satisfied without further dispatch routing.
    try:
      let testArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runReproTestCommand(testArgs, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro test: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "bench":
    # Spec-Implementation M0: ``repro bench`` is a CLI verb alias for
    # ``repro build bench`` per Build-Graph-Collections.md §"Verb Aliases
    # for Conventional Collections" and CLI/bench.md. The alias is a
    # one-arg rewrite that delegates to ``runBuildCommand``; the bench
    # build graph collection itself is the project's responsibility to
    # declare (via ``collect("bench", ...)`` or the M1-era
    # ``aggregate("bench", ...)`` interim form). When no collection
    # named ``bench`` exists the standard ``unknown_target`` diagnostic
    # from Named-Targets M2 surfaces — no special "no benchmarks" case.
    try:
      let benchArgs =
        if args.len > 1:
          @["bench"] & args[1 .. ^1]
        else:
          @["bench"]
      return runBuildCommand(benchArgs, publicCliPath)
    except BuildTargetAmbiguousError as err:
      stderr.write(renderAmbiguousTargetDiagnostic(err[]))
      return 2
    except BuildTargetUnknownError as err:
      stderr.write(renderUnknownTargetDiagnostic(err[]))
      return 2
    except CatchableError as err:
      stderr.writeLine("repro bench: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "lint":
    # Spec-Implementation M0: ``repro lint`` is a CLI verb alias for
    # ``repro build lint`` per Build-Graph-Collections.md §"Verb Aliases
    # for Conventional Collections" and CLI/lint.md. Mirror shape of the
    # ``bench`` alias above.
    try:
      let lintArgs =
        if args.len > 1:
          @["lint"] & args[1 .. ^1]
        else:
          @["lint"]
      return runBuildCommand(lintArgs, publicCliPath)
    except BuildTargetAmbiguousError as err:
      stderr.write(renderAmbiguousTargetDiagnostic(err[]))
      return 2
    except BuildTargetUnknownError as err:
      stderr.write(renderUnknownTargetDiagnostic(err[]))
      return 2
    except CatchableError as err:
      stderr.writeLine("repro lint: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "stats":
    try:
      let statsArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runStatsCommand(statsArgs, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro stats: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "exec":
    try:
      let execArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runReproExecCommand(execArgs, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro exec: error: " & err.msg)
      return 1
  if programName == "repro" and args.len >= 2 and args[0] == "shell" and
      args[1] == "hook":
    # M76 — ``repro shell hook <shell>``. Distinct from ``repro hooks``
    # (rc-file entry management) and from ``repro shell`` (the M3/M4
    # selector-then-flags activated-subshell). The dispatch order
    # matters: we MUST match ``shell hook`` BEFORE the generic
    # ``shell`` arm below, otherwise ``runReproShellCommand`` would
    # interpret ``hook`` as a selector and explode.
    let hookArgs =
      if args.len > 2:
        args[2 .. ^1]
      else:
        @[]
    return runShellHookCommand(hookArgs)
  if programName == "repro" and args.len > 0 and args[0] == "shell":
    try:
      let shellArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runReproShellCommand(shellArgs, publicCliPath)
    except CatchableError as err:
      stderr.writeLine("repro shell: error: " & err.msg)
      return 1
  if programName == "repro" and args.len >= 2 and args[0] == "dev-env" and
      args[1] == "export":
    # M74 — ``repro dev-env export <shell>``. New parent command
    # ``dev-env`` for the Shell-Direnv-Hook plan (M74-M77). The
    # ``export`` arm uses its own argv parser (positional ``<shell>``
    # first, then ``--project-root`` / ``--activity`` /
    # ``--develop-overrides`` / ``--allow-stale``), distinct from the
    # legacy ``repro shell --print-env=...`` surface which lives off
    # the ``shell`` parent and keeps its M3/M4 selector-then-flags
    # idiom.
    let exportArgs =
      if args.len > 2:
        args[2 .. ^1]
      else:
        @[]
    return runDevEnvExportCommand(exportArgs, publicCliPath)
  if programName == "repro" and args.len >= 2 and args[0] == "dev-env" and
      args[1] == "deactivate":
    # M75 — ``repro dev-env deactivate <rollback-manifest>``. Reads
    # the manifest written by the matching ``export`` invocation and
    # emits the per-shell rollback script. Tamper-detection: if the
    # manifest's ``activation_script_hash`` differs from what the arm
    # would re-derive from the same RBDE artifact, exit 3 with a
    # no-op script + stderr diagnostic. The shell hook (M76) treats
    # exit 3 as "leave env as-is and move on" per the spec.
    let deactivateArgs =
      if args.len > 2:
        args[2 .. ^1]
      else:
        @[]
    return runDevEnvDeactivateCommand(deactivateArgs)
  if programName == "repro" and args.len > 0 and args[0] == "up":
    try:
      let upArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runUpOrDevCommand(upArgs, publicCliPath, dsmUp)
    except CatchableError as err:
      stderr.writeLine("repro up: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "down":
    try:
      let downArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runDownCommand(downArgs)
    except CatchableError as err:
      stderr.writeLine("repro down: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "dev":
    try:
      let devArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runUpOrDevCommand(devArgs, publicCliPath, dsmDev)
    except CatchableError as err:
      stderr.writeLine("repro dev: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "hooks":
    try:
      let hookArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runHooksCommand(hookArgs)
    except CatchableError as err:
      stderr.writeLine("repro hooks: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "lock":
    # Spec-Implementation M2e — ``repro lock <verb>``. M2e ships the
    # ``explain`` verb under this namespace per
    # Locking-And-Solver.md §"CLI Surface" (which earmarks
    # ``solve`` / ``debug`` / ``visualize`` for the same family).
    try:
      let lockArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runReproLockCommand(lockArgs)
    except CatchableError as err:
      stderr.writeLine("repro lock: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "check":
    # M18 — top-level `repro check` subcommand per CLI/check.md. The
    # M17 pre-push dispatcher routes through this same entry point so
    # the gate logic stays in one place and the operator can invoke
    # it manually for diagnosis.
    try:
      let checkArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runCheckCommand(checkArgs)
    except CatchableError as err:
      stderr.writeLine("repro check: error: " & err.msg)
      return 1
  if programName == "repro" and args.len >= 2 and args[0] == "workspace" and
      args[1] == "init":
    # M9 — `repro workspace init <project-or-variant>`. The milestone
    # spec names the path ``apps/repro/subcmds/workspace_init.nim``;
    # this repo's convention is "subcommands live in repro_cli_support,
    # apps/<x>.nim stays a single-line shim", so the implementation
    # lives in this file as ``runWorkspaceInitCommand`` instead.
    try:
      let initArgs =
        if args.len > 2:
          args[2 .. ^1]
        else:
          @[]
      return runWorkspaceInitCommand(initArgs)
    except CatchableError as err:
      stderr.writeLine("repro workspace init: error: " & err.msg)
      return 1
  if programName == "repro" and args.len >= 2 and args[0] == "workspace" and
      args[1] == "sync":
    # M10 — `repro workspace sync`. Sibling of the M9 ``init`` hook
    # immediately above: the spec names a file path
    # ``apps/repro/subcmds/workspace_sync.nim`` for symmetry but the
    # repo convention places the implementation here in
    # ``repro_cli_support`` so the dispatcher reaches it via
    # ``runWorkspaceSyncCommand``.
    try:
      let syncArgs =
        if args.len > 2:
          args[2 .. ^1]
        else:
          @[]
      return runWorkspaceSyncCommand(syncArgs)
    except CatchableError as err:
      stderr.writeLine("repro workspace sync: error: " & err.msg)
      return 1
  if programName == "repro" and args.len >= 2 and args[0] == "workspace" and
      args[1] == "lock":
    # M11 — `repro workspace lock`. Follows the same convention as
    # M9/M10: the milestone spec names
    # ``apps/repro/subcmds/workspace_lock.nim`` but the implementation
    # lives in ``repro_cli_support`` for symmetry, reachable via
    # ``runWorkspaceLockCommand``.
    try:
      let lockArgs =
        if args.len > 2:
          args[2 .. ^1]
        else:
          @[]
      return runWorkspaceLockCommand(lockArgs)
    except CatchableError as err:
      stderr.writeLine("repro workspace lock: error: " & err.msg)
      return 1
  if programName == "repro" and args.len >= 2 and args[0] == "workspace" and
      args[1] == "status":
    # M12 — `repro workspace status`. Same dispatch convention as
    # M9/M10/M11: the milestone spec names
    # ``apps/repro/subcmds/workspace_status.nim`` but the implementation
    # lives in ``repro_cli_support`` so the dispatcher reaches it via
    # ``runWorkspaceStatusCommand``.
    try:
      let statusArgs =
        if args.len > 2:
          args[2 .. ^1]
        else:
          @[]
      return runWorkspaceStatusCommand(statusArgs)
    except CatchableError as err:
      stderr.writeLine("repro workspace status: error: " & err.msg)
      return 1
  if programName == "repro" and args.len >= 2 and args[0] == "workspace" and
      args[1] == "list":
    # M12 — `repro workspace list`. Sibling of the status hook. See
    # ``runWorkspaceListCommand`` for the implementation.
    try:
      let listArgs =
        if args.len > 2:
          args[2 .. ^1]
        else:
          @[]
      return runWorkspaceListCommand(listArgs)
    except CatchableError as err:
      stderr.writeLine("repro workspace list: error: " & err.msg)
      return 1
  if programName == "repro" and args.len >= 2 and args[0] == "workspace" and
      args[1] == "start":
    # M16 — `repro workspace start <branch>`. Combination of M14
    # ``branch create`` + M15 ``checkout`` + a "feature started"
    # mark in workspace metadata. Same dispatch convention as M9–M12:
    # the milestone spec gestures at a planner path but the
    # implementation lives in ``repro_cli_support`` so the dispatcher
    # reaches it via ``runWorkspaceStartCommand``.
    try:
      let startArgs =
        if args.len > 2:
          args[2 .. ^1]
        else:
          @[]
      return runWorkspaceStartCommand(startArgs)
    except CatchableError as err:
      stderr.writeLine("repro workspace start: error: " & err.msg)
      return 1
  if programName == "repro" and args.len >= 2 and args[0] == "workspace" and
      args[1] == "manifests":
    # M12 — `repro workspace manifests`. Last of the three M12 hooks;
    # implementation in ``runWorkspaceManifestsCommand``.
    try:
      let manifestsArgs =
        if args.len > 2:
          args[2 .. ^1]
        else:
          @[]
      return runWorkspaceManifestsCommand(manifestsArgs)
    except CatchableError as err:
      stderr.writeLine("repro workspace manifests: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "branch":
    # M14 — `repro branch [<name>]`. Top-level subcommand per
    # ``reprobuild-specs/CLI/branch.md``: NOT under ``repro workspace``.
    # Same convention deviation as M9–M12: the milestone spec names a
    # planner path but the implementation lives in ``repro_cli_support``
    # for symmetry, reachable via ``runBranchCommand``.
    try:
      let branchArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runBranchCommand(branchArgs)
    except CatchableError as err:
      stderr.writeLine("repro branch: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and
      (args[0] == "checkout" or args[0] == "co"):
    # M15 — `repro checkout <branch>` (and the `co` alias per
    # CLI/checkout.md). Top-level subcommand: switches every
    # participating repo to the named branch and updates M13 metadata.
    try:
      let checkoutArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runCheckoutCommand(checkoutArgs)
    except CatchableError as err:
      stderr.writeLine("repro " & args[0] & ": error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "watch":
    try:
      let watchArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runWatchCommand(watchArgs, publicCliPath)
    except BuildTargetAmbiguousError as err:
      # Named-Targets M3: watch inherits the shared M2 resolver, so the
      # ``target_ambiguous`` diagnostic surfaces identically. The shared
      # ``renderAmbiguousTargetDiagnostic`` helper keeps the watch and
      # build emissions byte-identical at the resolver seam.
      stderr.write(renderAmbiguousTargetDiagnostic(err[]))
      return 2
    except BuildTargetUnknownError as err:
      # Named-Targets M3: same translation for the ``unknown_target``
      # diagnostic. The daemon-side translation lives in
      # ``installUserDaemonWatchExecutor``; both paths render via
      # ``renderUnknownTargetDiagnostic``.
      stderr.write(renderUnknownTargetDiagnostic(err[]))
      return 2
    except CatchableError as err:
      stderr.writeLine("repro watch: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "hcr":
    try:
      let hcrArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runHcrCoordinateCommand(hcrArgs)
    except CatchableError as err:
      stderr.writeLine("repro hcr: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "develop":
    try:
      let developArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runDevelopCommand(developArgs)
    except CatchableError as err:
      stderr.writeLine("repro develop: error: " & err.msg)
      return 1
  if programName == "repro" and args.len > 0 and args[0] == "store":
    let storeArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runStoreCommand(storeArgs)
  if programName == "repro" and args.len > 0 and args[0] == "daemon":
    let daemonArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    # Executable-Consolidation M2: `repro daemon serve` is the daemon PROCESS
    # entry — the role formerly carried by the standalone `repro-daemon` binary
    # (whose program name stays a compatibility alias below). Every other
    # `daemon` subcommand (status / start / stop / restart / logs / sessions)
    # is a client control command.
    if daemonArgs.len > 0 and daemonArgs[0] == "serve":
      installUserDaemonBuildPrewarmer()
      installUserDaemonBuildExecutor()
      installUserDaemonWatchExecutor()
      return runUserDaemonCommand(daemonArgs[1 .. ^1])
    return runUserDaemonCliCommand(daemonArgs)
  if programName == "repro" and args.len > 0 and args[0] == "launch-plan":
    let lpArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runLaunchPlanCommand(lpArgs)
  if programName == "repro" and args.len > 0 and args[0] == "__remote-activate":
    let remoteArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runHomeCommand(@["__remote-activate"] & remoteArgs)
  if programName == "repro" and args.len > 0 and args[0] == "home":
    let homeArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runHomeCommand(homeArgs)
  if programName == "repro" and args.len > 0 and args[0] == "infra":
    let infraArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runInfraCommand(infraArgs)
  if programName == "repro" and args.len > 0 and args[0] == "system":
    let systemArgs =
      if args.len > 1:
        args[1 .. ^1]
      else:
        @[]
    return runSystemCommand(systemArgs)
  stderr.writeLine(renderUsage(programName))
  2
