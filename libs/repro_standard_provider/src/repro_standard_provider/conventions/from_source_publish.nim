## Shared M9.L.4 binary-cache publish-action emitter for the four
## from-source conventions (``from_source_meson`` / ``from_source_cmake``
## / ``from_source_autotools`` / ``from_source_make``).
##
## Each convention's pipeline ends with a best-effort publish action that
## uploads the install staging tree to ``repro-cache`` (see
## ``apps/repro-binary-cache-client/`` and
## ``recipes/cache/scripts/cache-helper.sh`` §cache_phase_publish for the
## CLI shape). The action's argv wraps the CLI call in
## ``sh -c ".. || true"`` so an unreachable cache / missing key+cert env
## vars / CLI failure does NOT abort the build. The CLI itself short-
## circuits 0 on ``REPRO_CACHE_DISABLE=1`` and when the key/cert env vars
## are unset, so this helper does not duplicate that logic.
##
## ## Why a shared module?
##
## The 4 from-source conventions used to carry duplicated source-parsing
## helpers (``readReprobuildSource`` / ``usesIncludesXxx`` /
## ``extractMembers`` / ``extractFirstPackageName``) because those need
## byte-identical recognise behaviour vis-a-vis the in-tree sibling
## conventions which keep their own copies private. The M9.L.4 publish
## emitter is a different shape: it has no in-tree analogue, its inputs
## (projectRoot, packageName, staging-prefix path, convention tag) are
## stateless, and lifting the cache-key composition into one module
## avoids 4 copies of the BLAKE3 + identity-tuple wiring drifting
## independently in future maintenance. The trade-off is one extra
## import per convention; the alternative (4 duplicates of ~130 lines)
## would be the documented "duplicated source helpers" pattern carried
## one milestone too far.
##
## ## Cache-key composition (v1 — partial identity)
##
## ``deriveCacheKeyHex`` composes the M9.L.4 v1 ``CacheEntryIdentity``
## tuple and derives the 64-char hex entry key via
## ``cache_key.deriveCacheEntryKeyHex``. The identity populates:
##
##   * ``packageName`` (from the recipe's ``package <name>:`` header).
##   * ``packageVersion`` (the last entry of ``registeredVersions(pkg)``
##     — empty when no ``versions:`` block exists).
##   * ``providerRevision`` (BLAKE3 hex of the recipe file bytes,
##     truncated to 32 lowercase-hex chars).
##   * A hardcoded Linux x86_64 / GNU / glibc ``PlatformTriple`` (host
##     detection deferred).
##   * A ``ToolchainIdentity`` whose ``name`` is the convention tag
##     (``"meson"`` / ``"cmake"`` / ``"autotools"`` / ``"make"``);
##     version + host-ldso left empty (detection deferred).
##
## Deferred slots (intentionally empty for v1, will shift the key when
## populated): ``sortedOptions`` (M9.I per-channel flag projection),
## ``sortedDepClosureDigest`` (cross-recipe dep resolution).
##
## ## Action-id schema
##
## The emitter produces an action with id
## ``from-source-<convention>-publish-<sanitisedPackageName>`` and stats
## id ``from-source-<convention>.publish``. The convention parameter is
## inserted verbatim — callers pass ``"meson"`` / ``"cmake"`` /
## ``"autotools"`` / ``"make"``.
##
## ## See also
##
##   * ``from_source_meson.nim`` — first convention to wire publish in
##     M9.L.4.0.
##   * ``reprobuild-specs/M9-DSL-Port-Engine-Provider.milestones.org``
##     §M9.L for the milestone history.

import std/[os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl

# M9.L.4 binary-cache publish wiring. ``cache_key`` derives the on-wire
# entry-key hex from a ``CacheEntryIdentity`` tuple; ``types`` carries
# the ``PlatformTriple`` + ``ToolchainIdentity`` shapes the identity
# tuple requires.
import repro_binary_cache_client/cache_key
import repro_binary_cache_server/types as bcs_types
import blake3

proc binaryCacheClientCli*(): string =
  ## Resolve the publish CLI binary. Mirrors
  ## ``cache-helper.sh::cache_repro_binary_cache_client_bin`` shape —
  ## prefer the in-repo ``build/test-bin`` location, fall back to
  ## ``PATH`` lookup. The publish action emits the resolved path
  ## verbatim into the argv; the ``|| true`` wrapper means a missing
  ## CLI degrades to a soft-fail at execution time instead of an abort.
  let resolved = findExe("repro_binary_cache_client_cli")
  if resolved.len > 0:
    return resolved
  # Stable placeholder so ``inlineExecCall`` accepts the argv; the
  # ``|| true`` wrapper swallows the missing-binary failure at run
  # time.
  "repro_binary_cache_client_cli"

proc providerRevisionHex*(projectRoot: string): string =
  ## BLAKE3 of the recipe file bytes, truncated to 32 hex chars. Empty
  ## when the recipe file can't be read (the publish key still derives
  ## via the rest of the identity tuple — the empty string round-trips
  ## through the canonical encoder).
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  let bodyStr =
    try: readFile(extendedPath(match.path))
    except CatchableError: ""
  if bodyStr.len == 0:
    return ""
  let dig = blake3.digest(bodyStr)
  let full = blake3.toHex(dig)
  if full.len >= 32: full[0 ..< 32] else: full

proc m9L4PlatformTriple*(): bcs_types.PlatformTriple =
  ## Hardcoded Linux x86_64 GNU glibc triple — the M9.L.4 vertical-slice
  ## target. A follow-up milestone lifts host detection (Windows / macOS
  ## / aarch64) into a shared helper. The convention DOES populate every
  ## field so the canonical encoder round-trips identically across hosts
  ## that compute the same identity tuple.
  bcs_types.PlatformTriple(
    cpu: "x86_64",
    os: "linux",
    abi: "gnu",
    libcVariant: "glibc")

proc m9L4ToolchainIdentity*(name: string): bcs_types.ToolchainIdentity =
  ## Toolchain identity for the from-source pipeline. The ``name`` is
  ## the convention tag (``"meson"`` / ``"cmake"`` / ``"autotools"`` /
  ## ``"make"``). Version + host-ldso detection are deferred (see
  ## module docstring); the empty strings round-trip through the
  ## canonical encoder so a follow-up that fills them in will produce
  ## a DIFFERENT cache key (intended — the spec mandates toolchain
  ## differences shift the key).
  bcs_types.ToolchainIdentity(
    name: name,
    version: "",
    hostLdSoAbi: "",
    extraFingerprint: "")

proc deriveCacheKeyHex*(projectRoot, packageName, toolchainName: string): string =
  ## Compose the M9.L.4 v1 ``CacheEntryIdentity`` and derive its
  ## 64-char hex key. The deferrals (empty options / empty dep-closure
  ## / hardcoded platform / partial toolchain) are documented in the
  ## module docstring.
  let versionStr = block:
    var v = ""
    let vs = registeredVersions(packageName)
    if vs.len > 0:
      v = vs[^1].version
    v
  var identity = newCacheEntryIdentity(
    packageName = packageName,
    packageVersion = versionStr,
    platform = m9L4PlatformTriple(),
    toolchain = m9L4ToolchainIdentity(toolchainName),
    providerRevision = providerRevisionHex(projectRoot))
  # options + depClosure intentionally empty for v1.
  deriveCacheEntryKeyHex(identity)

proc sanitizeNamePartLocal(value: string): string =
  ## Same sanitisation rule as each convention's local
  ## ``sanitizeNamePart`` — kept private to this module so the publish
  ## action id matches the existing per-convention action-id schemes
  ## byte-for-byte even when imported by all 4 conventions.
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc emitPublishAction*(projectRoot, prefixDir, packageName,
                        conventionTag: string;
                        stageDeps: seq[string];
                        stageOutputs: seq[string]): BuildActionDef =
  ## Emit a best-effort publish action that uploads ``<prefixDir>`` to
  ## ``repro-cache`` via the ``repro_binary_cache_client_cli publish``
  ## subcommand. Depends on every per-artifact stage-copy action so the
  ## publish runs AFTER the install tree is fully populated.
  ##
  ## ``conventionTag`` is the convention identity (``"meson"`` /
  ## ``"cmake"`` / ``"autotools"`` / ``"make"``); it is used both as
  ## the action-id infix (``from-source-<tag>-publish-<pkg>``) and as
  ## the ``ToolchainIdentity.name`` field that feeds the cache key.
  ##
  ## The action's argv is
  ## ``sh -c "<cli> publish <hex> <prefixDir>
  ## --package-name=<pkg> --package-version=<ver> || true"`` — the
  ## ``|| true`` wrapper makes the action always exit 0 so an
  ## unreachable cache / missing key+cert / missing CLI does NOT abort
  ## the build. The CLI itself short-circuits 0 on
  ## ``REPRO_CACHE_DISABLE=1``.
  let cliBin = binaryCacheClientCli()
  let hexKey = deriveCacheKeyHex(projectRoot, packageName, conventionTag)
  let versionStr = block:
    var v = ""
    let vs = registeredVersions(packageName)
    if vs.len > 0:
      v = vs[^1].version
    v
  let shExe = findExe("sh")
  var argv: seq[string]
  if shExe.len > 0:
    let escapedCli = cliBin.replace("\\", "/").replace("\"", "\\\"")
    let escapedPrefix = prefixDir.replace("\\", "/").replace("\"", "\\\"")
    let escapedPkg = packageName.replace("\"", "\\\"")
    let escapedVer = versionStr.replace("\"", "\\\"")
    let script = "\"" & escapedCli & "\" publish " & hexKey & " \"" &
      escapedPrefix & "\" --package-name=\"" & escapedPkg &
      "\" --package-version=\"" & escapedVer & "\" || true"
    argv = @[shExe, "-c", script]
  else:
    # No ``sh`` on PATH — fall back to a direct invocation. The action
    # will exit non-zero on failure (no shell ``|| true`` available),
    # but this branch only triggers on truly minimal Windows hosts
    # without MSYS2 / git-bash sh, which the convention's other
    # actions ALSO require.
    argv = @[cliBin, "publish", hexKey, prefixDir,
      "--package-name=" & packageName,
      "--package-version=" & versionStr]
  buildAction(
    id = "from-source-" & conventionTag & "-publish-" &
      sanitizeNamePartLocal(packageName),
    call = inlineExecCall(argv, projectRoot),
    deps = stageDeps,
    inputs = stageOutputs,
    outputs = @[],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-" & conventionTag & ".publish")
