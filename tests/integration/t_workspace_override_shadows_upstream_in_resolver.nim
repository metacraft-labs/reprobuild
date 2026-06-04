## M21 — Override resolution in the build graph.
##
## Pure-library test for the resolver hook + content identity +
## fingerprint-fold helpers added by ``override_resolution.nim``.
##
## Properties exercised (one test per case):
##
##   1. ``test_m21_resolver_returns_upstream_when_no_override`` — no
##      ``.repro/develop-overrides.toml`` on disk → resolver returns the
##      upstream binding unchanged.
##   2. ``test_m21_resolver_returns_override_when_present`` — override
##      file with one entry → resolver returns a ``rpbkOverride``
##      binding carrying the local path and content identity.
##   3. ``test_m21_override_content_identity_differs_from_upstream`` —
##      the override's content identity is structurally distinct from
##      any hex digest derived from the upstream binding (it embeds the
##      absolute local path, which the upstream binding never carries).
##   4. ``test_m21_resolver_emits_override_diagnostic_when_entry_missing_local_path``
##      — override points at a path that does not exist → resolver
##      returns ``orrkError`` with a structured diagnostic naming the
##      package and the missing path. Replaces the "engine wiring"
##      sub-case from the milestone playbook because M21 ships the
##      resolver only; the engine integration is deferred to M22 (see
##      the milestone drawer).
##   5. ``test_m21_remove_override_restores_upstream`` — after
##      removing the override entry through the M20 mutation helpers,
##      a fresh resolution call returns the upstream binding again.
##
## The test runs entirely in-process; no ``git``, no compiled binary,
## no subprocess.

import std/[options, os, strutils, tempfiles, unittest]

import repro_hash
import repro_workspace_manifests

proc weakFromText(text: string): ContentDigest =
  ## Local helper that mirrors ``repro_build_engine.weakFingerprintFromText``
  ## without pulling the whole engine into the test's link surface.
  ## Hashing under ``hdActionFingerprint`` is the same domain the
  ## engine uses for its action weak fingerprint.
  var bytes = newSeqOfCap[byte](text.len)
  for ch in text:
    bytes.add(byte(ord(ch)))
  blake3DomainDigest(bytes, hdActionFingerprint)

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

proc upstreamCairo(): UpstreamPackageBinding =
  result.packageName = "cairo"
  result.fetchUrl = "https://example.invalid/cairo.git"
  result.revision = "v1.2.3"

proc sampleOverride(pkg, localPath, state: string;
                    createdAt = "2026-06-04T10:00:00Z";
                    provenance = ""): DevelopOverrideEntry =
  result.package = pkg
  result.local_path = localPath
  result.state = state
  result.created_at = createdAt
  if provenance.len > 0:
    result.provenance = some(provenance)
  else:
    result.provenance = none(string)

proc setupWorkspaceWithOverride(pkg, localDir, state: string):
    tuple[workspaceRoot: string; overridePath: string] =
  ## Build a temp workspace root that carries a develop-overrides.toml
  ## entry shadowing ``pkg`` with a freshly-created sibling directory.
  ## Returns the absolute workspace root and the absolute local-path
  ## the override resolves to so the caller can assert against it
  ## without re-walking the filesystem.
  let workspaceRoot = createTempDir("repro-m21-resolver-", "")
  let siblingDir = workspaceRoot / localDir
  createDir(siblingDir)
  writeFile(siblingDir / "marker.txt", "develop-mode marker for " & pkg)

  var file = newDevelopOverrides()
  file = file.addOverride(sampleOverride(
    pkg, localDir, state,
    provenance = "test-m21"))
  writeDevelopOverridesFile(workspaceRoot, file)

  result.workspaceRoot = workspaceRoot
  result.overridePath = normalizedPath(siblingDir)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M21 — override resolution in the build graph":

  test "test_m21_resolver_returns_upstream_when_no_override":
    let workspaceRoot = createTempDir("repro-m21-no-override-", "")
    defer: removeDir(workspaceRoot)

    # The workspace has no ``.repro/develop-overrides.toml``. The
    # resolver must short-circuit through the ``none(DevelopOverrides)``
    # branch and return the upstream binding unchanged so a workspace
    # that has never activated develop-mode pays no extra cost.
    let upstream = upstreamCairo()
    let resolution = resolvePackageWithOverrides(upstream, workspaceRoot)
    check resolution.kind == orrkOk
    check resolution.binding.kind == rpbkUpstream
    check resolution.binding.upstream.packageName == upstream.packageName
    check resolution.binding.upstream.fetchUrl == upstream.fetchUrl
    check resolution.binding.upstream.revision == upstream.revision

    # The fingerprint-fold helper must keep the weak fingerprint
    # unchanged when no override binding participates — that's the
    # property that lets cache keys of non-overridden actions stay
    # identical across develop-mode toggles.
    let weak = weakFromText("test_m21.weak.no-override")
    let folded = foldOverridesIntoFingerprint(weak, @[resolution.binding])
    check folded.bytes == weak.bytes

  test "test_m21_resolver_returns_override_when_present":
    let (workspaceRoot, expectedPath) =
      setupWorkspaceWithOverride("cairo", "siblings/cairo", "editable")
    defer: removeDir(workspaceRoot)

    let upstream = upstreamCairo()
    let resolution = resolvePackageWithOverrides(upstream, workspaceRoot)
    check resolution.kind == orrkOk
    check resolution.binding.kind == rpbkOverride
    check resolution.binding.shadowed.fetchUrl == upstream.fetchUrl
    check resolution.binding.shadowed.revision == upstream.revision
    check resolution.binding.override.package == "cairo"
    check resolution.binding.override.state == "editable"
    check resolution.binding.localPathAbsolute == expectedPath
    check resolution.binding.contentIdentity.len > 0
    # The content identity is a hex string (32 bytes -> 64 hex chars
    # under BLAKE3 framing). Anything shorter would indicate a digest
    # algorithm change that needs an explicit version bump.
    check resolution.binding.contentIdentity.len == 64

    # Folding the override into a weak fingerprint must change the
    # digest: that is the cache-key-divergence guarantee the spec's
    # "Remote Execution Interaction" section calls for. Without this
    # property a remote worker could silently reuse the upstream
    # artifact for an action that depends on the overridden package.
    let weak = weakFromText("test_m21.weak.with-override")
    let folded = foldOverridesIntoFingerprint(weak, @[resolution.binding])
    check folded.bytes != weak.bytes

  test "test_m21_override_content_identity_differs_from_upstream":
    let (workspaceRoot, expectedPath) =
      setupWorkspaceWithOverride("cairo", "siblings/cairo", "editable")
    defer: removeDir(workspaceRoot)

    let entries = listOverrides(readDevelopOverridesFile(workspaceRoot).get())
    check entries.len == 1
    let identity = computeOverrideContentIdentity(entries[0], workspaceRoot)
    check identity.len == 64

    # The upstream "identity" any cache key folds is, today, the
    # fetch-URL + revision tuple's framing. The override identity
    # must be structurally distinct from that tuple — it carries the
    # absolute local path, which the upstream tuple never carries.
    # We approximate the upstream digest by hashing the tuple under
    # the same domain and assert non-equality.
    let upstream = upstreamCairo()
    let upstreamWeak = weakFromText(
      "upstream:" & upstream.packageName & ":" & upstream.fetchUrl & ":" &
      upstream.revision)
    let upstreamHex = toHex(upstreamWeak.bytes)
    check identity != upstreamHex

    # And of course the absolute path the resolver normalized must
    # be the one we created above — re-asserting the contract that
    # ``computeOverrideContentIdentity`` and the resolver agree on
    # the local path normalization.
    check resolveOverrideAbsolutePath(workspaceRoot, entries[0]) ==
      expectedPath

  test "test_m21_resolver_emits_override_diagnostic_when_entry_missing_local_path":
    let workspaceRoot = createTempDir("repro-m21-missing-path-", "")
    defer: removeDir(workspaceRoot)

    # Register an override that points at a sibling directory we
    # deliberately do NOT create. The resolver must NOT silently fall
    # back to the upstream binding — that would let a remote worker
    # reuse the upstream artifact for what the local operator believes
    # is a development checkout, exactly the "silent fallback" failure
    # mode the spec forbids.
    var file = newDevelopOverrides()
    file = file.addOverride(sampleOverride(
      "cairo", "siblings/cairo", "editable",
      provenance = "test-m21-missing"))
    writeDevelopOverridesFile(workspaceRoot, file)

    let upstream = upstreamCairo()
    let resolution = resolvePackageWithOverrides(upstream, workspaceRoot)
    check resolution.kind == orrkError
    check resolution.diagnostic.packageName == "cairo"
    check resolution.diagnostic.overridePath.endsWith("siblings/cairo") or
      resolution.diagnostic.overridePath.endsWith("siblings" / "cairo")
    check "does not exist" in resolution.diagnostic.reason
    check "Remote Execution Interaction" in resolution.diagnostic.reason

    # And the exception-style helper must reuse the M5 diagnostic
    # envelope so callers that prefer try/except keep working.
    var raised = false
    try:
      raiseDiagnostic(resolution.diagnostic)
    except WorkspaceManifestParseError as e:
      raised = true
      check "does not exist" in e.innerMessage
      check e.expectedSchema == "reprobuild.workspace.develop-overrides.v1"
    check raised

  test "test_m21_remove_override_restores_upstream":
    let (workspaceRoot, _) =
      setupWorkspaceWithOverride("cairo", "siblings/cairo", "editable")
    defer: removeDir(workspaceRoot)

    # Sanity: the override is currently in effect.
    let upstream = upstreamCairo()
    let withOverride = resolvePackageWithOverrides(upstream, workspaceRoot)
    check withOverride.kind == orrkOk
    check withOverride.binding.kind == rpbkOverride

    # Drop the override through the M20 mutation API and persist the
    # empty file. A fresh resolution call must return the upstream
    # binding again — there is no in-memory caching that could
    # accidentally keep the overridden binding alive.
    let dropped = readDevelopOverridesFile(workspaceRoot).get()
      .removeOverride("cairo")
    writeDevelopOverridesFile(workspaceRoot, dropped)

    let afterRemoval = resolvePackageWithOverrides(upstream, workspaceRoot)
    check afterRemoval.kind == orrkOk
    check afterRemoval.binding.kind == rpbkUpstream
    check afterRemoval.binding.upstream.fetchUrl == upstream.fetchUrl
    check afterRemoval.binding.upstream.revision == upstream.revision
