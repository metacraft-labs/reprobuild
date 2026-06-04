## repro_workspace_manifests/override_resolution.nim
##
## M21 — Override resolution in the build graph.
##
## When the engine resolves a package name to its source identity, the
## develop-mode override map (M20) shadows the upstream binding. The
## override is folded into the action fingerprint so an action that
## depends on an overridden package cannot collide with the cache key
## a remote worker would compute from the upstream artifact alone
## (per ``Workspace-And-Develop-Mode.md`` §"Remote Execution
## Interaction").
##
## Scope:
##
## - **Resolver hook** (``resolvePackageWithOverrides``): pure function
##   that takes an upstream binding (an ``M6`` ``ResolvedRepo``-shaped
##   identity, modelled here as ``UpstreamPackageBinding`` so callers
##   that have only the fetch URL + revision tuple can use it without
##   round-tripping through M6) plus the loaded ``DevelopOverrides``
##   value, and returns a ``ResolvedPackageBinding`` that either
##   forwards the upstream binding unchanged or carries the local-path
##   override. The proc is total: callers do not need to special-case
##   ``none(DevelopOverrides)`` (a helper overload handles that).
##
## - **Content identity** (``computeOverrideContentIdentity``):
##   deterministic hex digest that an action fingerprint can fold in
##   alongside the upstream identity. The digest covers the override
##   entry's salient fields (package, absolute local_path, state) plus
##   the local-path root's last-modification time. This is the
##   intentionally-cheap scheme:
##
##     - The absolute path differs from any upstream identity, so the
##       digest is guaranteed to differ from the upstream's fingerprint
##       even when the operator has not yet modified any source file.
##       That is the "no silent fallback" property the spec calls for.
##     - The mtime catches "the operator edited the override" without
##       walking the directory tree. Heavier per-file content hashing
##       can be layered on top later without changing the digest's
##       framing (the schema string carries a version tag so the cache
##       key changes when we upgrade the scheme).
##
##   The spec (``Workspace-And-Develop-Mode.md`` §"Remote Execution
##   Interaction") does NOT pin a specific scheme — it requires that
##   "local override state must become part of action identity where
##   relevant". This proc satisfies that requirement at the resolver
##   boundary; a follow-up can swap in a directory-content hash without
##   changing the resolver's signature.
##
## - **Fingerprint folder** (``foldOverridesIntoFingerprint``):
##   convenience that takes an existing weak action fingerprint plus
##   the resolved bindings for the action's package dependencies and
##   returns a new ``ContentDigest`` that combines the two. The build
##   engine adopts this in a follow-up — see the deferred-engine-wiring
##   note in the M21 milestone drawer.
##
## Engine integration scope (M21):
##
## This milestone delivers the resolver-level contract + tests. The
## build engine itself does not yet have a "resolve package binding"
## hook to plug into — that hook does not exist as a single
## entry point today, because individual actions construct their own
## inputs from explicit on-disk paths. Wiring the override into a
## specific subsystem (e.g. dev-env activation, workspace VCS actions,
## or the project DSL's package-import surface) is deferred to M22,
## which will land the ``repro develop`` CLI and the smallest set of
## adopting call sites it needs. M21 ships the resolver, the content
## identity, and the fingerprint folder so M22 (and later M23) can
## adopt them without re-deciding the contract.
##
## See ``Workspace-Management.milestones.org`` §M21 for the milestone
## entry; the deviation note there records the deferral.

import std/[options, os, strutils, times]

import repro_hash

import types
import diagnostics
import develop_overrides

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  UpstreamPackageBinding* = object
    ## The upstream identity the workspace would resolve a package to
    ## absent any override. Modeled as the same tuple M6 already
    ## produces in ``ResolvedRepo`` (``fetchUrl`` + ``revision``) plus
    ## the package's logical name, so callers can build it from either
    ## a ``ResolvedRepo`` (engine-side) or a hand-constructed value
    ## (test fixtures, M22's CLI before it has loaded the full
    ## ``ResolvedProject``).
    packageName*: string
      ## Logical package name the build graph will look up. MUST match
      ## ``DevelopOverrideEntry.package`` for the override to apply.
    fetchUrl*: string
      ## The remote URL the upstream binding fetches from. Empty when
      ## the package is sourced from a non-VCS upstream (catalog
      ## artifact, etc.). Recorded verbatim in the resolved binding so
      ## the cache key disambiguates two packages that share a logical
      ## name but live on different remotes.
    revision*: string
      ## The pinned upstream revision (commit SHA, tag, or branch
      ## name). Empty values are tolerated for the same reason
      ## ``ResolvedRepo.revision`` may be empty after M6 resolution.

  ResolvedPackageBindingKind* = enum
    rpbkUpstream
      ## The override map was consulted and did not match. The caller
      ## should consume ``upstream`` as the source identity.
    rpbkOverride
      ## The override map matched. The caller MUST consume the local
      ## path in ``override`` AND fold ``contentIdentity`` into the
      ## action's fingerprint so a remote worker building the same
      ## action does not silently reuse the upstream artifact.

  ResolvedPackageBinding* = object
    ## The output of ``resolvePackageWithOverrides``. ``upstream`` is
    ## always populated (it is the caller's input, threaded through
    ## verbatim) so a caller that wants to log "shadowed X with Y" can
    ## describe both sides without a second lookup.
    case kind*: ResolvedPackageBindingKind
    of rpbkUpstream:
      upstream*: UpstreamPackageBinding
    of rpbkOverride:
      shadowed*: UpstreamPackageBinding
        ## The upstream binding that would have been used absent the
        ## override.
      override*: DevelopOverrideEntry
        ## The override entry that shadowed ``shadowed``.
      localPathAbsolute*: string
        ## Absolute, normalized path of the override's local checkout.
        ## Already resolved against the workspace root by the resolver
        ## so downstream callers don't reproduce the lookup.
      contentIdentity*: string
        ## Hex digest produced by
        ## ``computeOverrideContentIdentity``. Folded into the action
        ## fingerprint by ``foldOverridesIntoFingerprint`` so the
        ## cache key for an overridden action differs from the
        ## upstream-bound action's cache key.

  OverrideResolutionDiagnostic* = object
    ## Structured failure returned by ``resolvePackageWithOverrides``
    ## when the override matches in name but the override entry is
    ## not usable. Returned via ``OverrideResolutionResult.diagnostic``
    ## rather than raised because the resolver is on the per-package
    ## hot path and callers commonly aggregate diagnostics across many
    ## packages before deciding to fail the build.
    packageName*: string
    overridePath*: string
    reason*: string

  OverrideResolutionResultKind* = enum
    orrkOk
    orrkError

  OverrideResolutionResult* = object
    ## Either a successfully resolved binding or a structured
    ## diagnostic. ``resolvePackageWithOverrides`` returns this shape
    ## so the engine integration in M22 can collect every per-package
    ## failure without a try/except per call site.
    case kind*: OverrideResolutionResultKind
    of orrkOk:
      binding*: ResolvedPackageBinding
    of orrkError:
      diagnostic*: OverrideResolutionDiagnostic

const
  overrideContentIdentityVersion* = "reprobuild.workspace.override-content-identity.v1"
    ## Version tag prepended to the content-identity payload. Bumping
    ## this string invalidates every override-affected action's cache
    ## key on purpose, so a future swap (e.g. to a directory-content
    ## hash) is opt-in and visible.

  fingerprintFoldVersion* = "reprobuild.workspace.action-override-fold.v1"
    ## Version tag prepended to the fingerprint-fold payload. Same
    ## opt-in rule as ``overrideContentIdentityVersion``.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc resolveOverrideAbsolutePath*(workspaceRoot: string;
                                  entry: DevelopOverrideEntry): string =
  ## Resolve ``entry.local_path`` against ``workspaceRoot``. Override
  ## entries store relative paths so the file survives moving the
  ## workspace; the resolver normalizes them to absolute form once,
  ## then threads the normalized value through ``ResolvedPackageBinding``
  ## so every downstream consumer sees the same canonical string.
  ##
  ## ``workspaceRoot`` MUST already be absolute (callers come from
  ## ``readDevelopOverridesFile(workspaceRoot)``, which is the path
  ## ``workspace init`` recorded). The normalization is plain
  ## lexical — we do NOT call ``expandFilename`` because the override
  ## path may legitimately point at a directory that is missing on
  ## disk right now (the M22 CLI may register the override before the
  ## clone completes).
  let raw = entry.local_path
  let joined =
    if isAbsolute(raw): raw
    else: workspaceRoot / raw
  result = normalizedPath(joined)

proc writeStringRecord(buf: var seq[byte]; value: string) =
  ## Length-prefixed string framing so two fields that differ only in
  ## where one ends and the next begins still hash to distinct values.
  ## Mirrors the framing the M2 VCS fingerprint helpers use without
  ## reaching into ``repro_core``.
  let length = uint64(value.len)
  for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
    buf.add(byte((length shr shift) and 0xff'u64))
  for ch in value:
    buf.add(byte(ord(ch)))

proc localPathMtimeIso(localPath: string): string =
  ## Return the override path's last-modification time in ISO-8601
  ## UTC form (precision: seconds) when the path exists, or an empty
  ## string when the path is missing. The mtime captures "the operator
  ## edited the override" cheaply; the empty-string fallback keeps the
  ## resolver usable on overrides that have not been cloned yet (the
  ## absolute path alone is then the entire identity).
  try:
    if not fileExists(localPath) and not dirExists(localPath):
      return ""
    let info = getFileInfo(localPath)
    result = info.lastWriteTime.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  except OSError:
    result = ""

# ---------------------------------------------------------------------------
# Content identity
# ---------------------------------------------------------------------------

proc computeOverrideContentIdentity*(entry: DevelopOverrideEntry;
                                     workspaceRoot: string): string =
  ## Deterministic hex digest of the override's identity-bearing
  ## fields. Folded into action fingerprints so the cache key for an
  ## override-affected action differs from the same action's
  ## upstream-bound cache key.
  ##
  ## Payload (length-prefixed, in order):
  ##
  ##   1. version tag (``overrideContentIdentityVersion``)
  ##   2. ``package`` name
  ##   3. ``state`` (editable / pinned / detached)
  ##   4. absolute, normalized ``local_path``
  ##   5. ISO-8601 mtime of the local path's root (empty when missing)
  ##
  ## ``created_at`` and ``provenance`` are intentionally NOT folded in:
  ## they describe how the override was created, not what its current
  ## source content is. Two operators who develop-mode the same
  ## package at different times should get the same fingerprint
  ## contribution.
  let absPath = resolveOverrideAbsolutePath(workspaceRoot, entry)
  var payload = newSeqOfCap[byte](128 + absPath.len)
  payload.writeStringRecord(overrideContentIdentityVersion)
  payload.writeStringRecord(entry.package)
  payload.writeStringRecord(entry.state)
  payload.writeStringRecord(absPath)
  payload.writeStringRecord(localPathMtimeIso(absPath))
  let digest = blake3DomainDigest(payload, hdActionFingerprint)
  result = toHex(digest.bytes)

# ---------------------------------------------------------------------------
# Resolver
# ---------------------------------------------------------------------------

proc resolvePackageWithOverrides*(upstream: UpstreamPackageBinding;
                                  overrides: Option[DevelopOverrides];
                                  workspaceRoot: string):
    OverrideResolutionResult =
  ## Resolver entry point. Returns the upstream binding unchanged when
  ## no override matches, or a ``rpbkOverride`` binding when the
  ## develop-overrides file carries an entry for ``upstream.packageName``.
  ##
  ## Failure mode: when an override matches but its ``local_path``
  ## (resolved against ``workspaceRoot``) does not exist on disk, the
  ## resolver returns an ``orrkError`` diagnostic rather than silently
  ## falling back to the upstream binding. Silent fallback is exactly
  ## the failure mode the spec's "Remote Execution Interaction"
  ## section warns against — a remote worker that sees the upstream
  ## cache key for what the local operator is treating as an
  ## overridden package would diverge invisibly. The structured
  ## diagnostic lets M22 / M23 surface the operator-visible error
  ## ("override registered for X but ../X does not exist") instead.
  ##
  ## ``overrides`` is ``Option`` so callers that probed
  ## ``readDevelopOverridesFile`` and got ``none`` can pass it through
  ## without unwrapping. ``workspaceRoot`` MUST be absolute when
  ## ``overrides`` is some — see the helper comment in
  ## ``resolveOverrideAbsolutePath``.

  if overrides.isNone:
    return OverrideResolutionResult(
      kind: orrkOk,
      binding: ResolvedPackageBinding(
        kind: rpbkUpstream, upstream: upstream))

  let entry = findOverride(overrides.get(), upstream.packageName)
  if entry.isNone:
    return OverrideResolutionResult(
      kind: orrkOk,
      binding: ResolvedPackageBinding(
        kind: rpbkUpstream, upstream: upstream))

  let resolved = entry.get()
  let absPath = resolveOverrideAbsolutePath(workspaceRoot, resolved)
  if not dirExists(absPath) and not fileExists(absPath):
    return OverrideResolutionResult(
      kind: orrkError,
      diagnostic: OverrideResolutionDiagnostic(
        packageName: upstream.packageName,
        overridePath: absPath,
        reason: "develop-mode override for '" & upstream.packageName &
          "' points at '" & absPath &
          "' which does not exist on disk; refusing to silently fall " &
          "back to the upstream binding (see " &
          "Workspace-And-Develop-Mode.md §\"Remote Execution Interaction\")"))

  let identity = computeOverrideContentIdentity(resolved, workspaceRoot)
  OverrideResolutionResult(
    kind: orrkOk,
    binding: ResolvedPackageBinding(
      kind: rpbkOverride,
      shadowed: upstream,
      override: resolved,
      localPathAbsolute: absPath,
      contentIdentity: identity))

proc resolvePackageWithOverrides*(upstream: UpstreamPackageBinding;
                                  workspaceRoot: string):
    OverrideResolutionResult =
  ## Workspace-rooted convenience: reads
  ## ``<workspaceRoot>/.repro/develop-overrides.toml`` via the M20
  ## reader and delegates to the option-based overload. Returns the
  ## upstream binding when no overrides file exists.
  let overrides =
    if workspaceRoot.len > 0:
      readDevelopOverridesFile(workspaceRoot)
    else:
      none(DevelopOverrides)
  resolvePackageWithOverrides(upstream, overrides, workspaceRoot)

# ---------------------------------------------------------------------------
# Fingerprint folding
# ---------------------------------------------------------------------------

proc foldOverridesIntoFingerprint*(weak: ContentDigest;
                                   bindings: openArray[ResolvedPackageBinding]):
    ContentDigest =
  ## Fold the override identities for an action's package bindings
  ## into the action's existing weak fingerprint, producing a new
  ## ``ContentDigest`` under ``hdActionFingerprint``. Bindings that
  ## point at upstream (``rpbkUpstream``) contribute nothing — only
  ## override bindings shift the fingerprint, which is the property
  ## the spec demands: an action that does NOT consume any
  ## overridden package keeps its existing cache key.
  ##
  ## Determinism: the contribution is order-preserving so two callers
  ## that pass the same bindings in the same order get the same
  ## digest. The build engine is expected to enumerate package
  ## dependencies in a stable order anyway (action graphs are
  ## sorted), so the caller does not have to sort.
  var payload = newSeqOfCap[byte](64 + weak.bytes.len)
  payload.writeStringRecord(fingerprintFoldVersion)
  for b in weak.bytes:
    payload.add(b)
  var overrideCount = 0
  for binding in bindings:
    if binding.kind == rpbkOverride:
      inc overrideCount
      payload.writeStringRecord(binding.override.package)
      payload.writeStringRecord(binding.contentIdentity)
  if overrideCount == 0:
    # No override participated. Returning ``weak`` unchanged is the
    # documented "an action that does not consume any overridden
    # package keeps its existing cache key" property.
    return weak
  blake3DomainDigest(payload, hdActionFingerprint)

# ---------------------------------------------------------------------------
# Diagnostic helpers
# ---------------------------------------------------------------------------

proc raiseDiagnostic*(diag: OverrideResolutionDiagnostic) {.noreturn.} =
  ## Convert a resolution diagnostic into an exception for callers
  ## that prefer the throw-style. Reuses ``WorkspaceManifestParseError``
  ## so existing ``except`` clauses keep working — the override-
  ## resolution failure is structurally "the workspace metadata is
  ## inconsistent", which is the same class M5/M6 errors fall under.
  raiseManifestError(diag.overridePath,
    "override[\"" & diag.packageName & "\"].local_path",
    schemaDevelopOverridesV1, schemaDevelopOverridesV1,
    diag.reason)
