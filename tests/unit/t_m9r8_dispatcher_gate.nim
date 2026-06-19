## M9.R.8 — dispatcher gate + buildDeps fallthrough + cache connectivity.
##
## This test pins the three small end-to-end execution gaps the Gap A
## smoke surfaced, exercised at the resolver / dispatcher layer only
## (no engine compile / no recipe build).
##
## ## What this test pins
##
##   1. ``parseToolProvisioning("from-source")`` round-trips through the
##      enum — sanity for the env-var + CLI flag path (the M9.Q
##      acceptance test already covers all three spelling aliases; we
##      reaffirm the canonical hyphenated form here so a future enum
##      reshuffle that breaks the dispatcher gate is caught even when
##      the M9.Q test changes shape).
##
##   2. ``shouldEnterBuildPipeline(tpmFromSource) == true`` — the
##      extracted predicate Part 1 introduces. Previously the dispatcher
##      gates lived as three inline ``in {tpmPathOnly, tpmNix,
##      tpmTarball, tpmScoop}`` literal sets at three sites; the M9.Q
##      ``tpmFromSource`` mode landed in the resolver but missed all
##      three gates so ``--tool-provisioning=from-source`` builds
##      short-circuited to "no external tools requested" (the symptom
##      the Gap A smoke captured at
##      ``D:/metacraft/gap-a-wayland.stdout.log``).
##
##      The same predicate also covers the four pre-existing modes so
##      the gate stays in sync if a future ``ToolProvisioningMode`` is
##      added (the M9.Q oversight was that the new enum missed three
##      independent literal sets).
##
##   3. buildDeps fallthrough — when ``tpmFromSource`` is active and a
##      ``buildDeps:`` entry (here ``"expat >=2.4"``) names a library
##      whose sibling recipe exists at
##      ``recipes/packages/source/<name>/repro.nim``, the resolver
##      routes through ``resolveFromSourceTool`` (NOT the
##      "expat does not declare provisioning: nixPackage metadata"
##      error path the Gap A nix/tarball/scoop smokes hit). The exact
##      M9.Q hard-fail on missing artefact still surfaces, but the
##      provisioning-declaration error is gone — the recipe is the
##      provisioning channel.
##
##   4. Non-from-source modes unchanged — pinning ``tpmTarball`` against
##      a useDef WITHOUT provisioning metadata still raises the
##      "does not declare provisioning: tarball metadata" diagnostic,
##      ensuring the M9.R.8 change scoped strictly to ``tpmFromSource``
##      and did NOT relax the existing error surface for the four
##      legacy modes.

import std/[os, strutils, tempfiles, unittest]

import repro_cli_support
import repro_tool_profiles
import repro_interface_artifacts

proc makeRecipeFile(root, name: string) =
  let recipeDir = root / name
  createDir(recipeDir)
  writeFile(recipeDir / "repro.nim", "## synthetic " & name & " recipe\n")

proc syntheticUseDef(name, constraint: string): InterfaceToolUse =
  InterfaceToolUse(
    rawConstraint: constraint,
    packageSelector: name,
    executableName: name)

suite "M9.R.8 dispatcher gate + buildDeps fallthrough":

  test "test_m9r8_parse_tool_provisioning_from_source_canonical_form":
    # The CLI canonical spelling must round-trip — the env-var path
    # (``REPRO_TOOL_PROVISIONING=from-source``) and the
    # ``--tool-provisioning=from-source`` flag both flow through this
    # entry point. The M9.Q test already covers the camelCase /
    # shorthand aliases; this test pins the hyphenated form against
    # the dispatcher gate predicate so a future enum reshuffle that
    # breaks one but not the other is caught.
    check parseToolProvisioning("from-source") == tpmFromSource

  test "test_m9r8_should_enter_build_pipeline_accepts_from_source":
    # The Part 1 predicate. Previously the dispatcher gate was an
    # inline literal set ``in {tpmPathOnly, tpmNix, tpmTarball,
    # tpmScoop}`` repeated at three sites in ``repro_cli_support.nim``
    # (lines 5125, 10503, 14179 pre-M9.R.8). ``tpmFromSource`` missing
    # from all three was the dispatch-time short-circuit gap.
    check shouldEnterBuildPipeline(tpmFromSource)
    # Pre-existing modes — guard against the predicate accidentally
    # excluding any of them on the way to broadening the set.
    check shouldEnterBuildPipeline(tpmPathOnly)
    check shouldEnterBuildPipeline(tpmNix)
    check shouldEnterBuildPipeline(tpmTarball)
    check shouldEnterBuildPipeline(tpmScoop)
    # ``tpmUnspecified`` deliberately stays out — the caller is
    # expected to resolve it via env var / project default before
    # reaching the predicate.
    check not shouldEnterBuildPipeline(tpmUnspecified)

  test "test_m9r8_build_deps_fall_through_to_from_source_resolver":
    # Synthesize a recipe tree with a sibling ``expat`` recipe but NO
    # built artefact. The resolver call mirrors what the dispatcher's
    # tool-identity-resolution pass does for each ``buildDeps:`` entry
    # in ``--tool-provisioning=from-source`` mode: drives the useDef
    # straight into ``resolveFromSourceTool``.
    #
    # Success metric: the raise is the M9.Q "has not produced an
    # artefact" diagnostic (the M9.R.9 auto-recurse target), NOT the
    # "does not declare provisioning" diagnostic the Gap A nix /
    # tarball / scoop smokes hit. Once auto-recurse lands the resolver
    # silently recurses; until then the build-command hint is the
    # operator-visible workaround.
    let scratch = createTempDir("repro-m9r8-fallthrough-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "expat")

    let useDef = syntheticUseDef("expat", "expat >=2.4")
    try:
      discard resolveFromSourceTool(useDef, recipeRoot = scratch)
      check false  # expected to raise (artefact unbuilt)
    except OSError as exc:
      # The hard-fail must NOT be the "does not declare provisioning"
      # error — that would mean the resolver picked the wrong channel.
      check not exc.msg.contains("does not declare provisioning")
      # The hard-fail MUST name the recipe + the M9.Q build hint.
      check exc.msg.contains("from-source")
      check exc.msg.contains("expat")
      check exc.msg.contains("has not produced an artefact")
      check exc.msg.contains("repro build")

  test "test_m9r8_non_from_source_modes_still_require_declared_provisioning":
    # Pin the four legacy modes against the same useDef shape — a
    # library reference with NO provisioning declared. Each of
    # ``toolBuildIdentity`` -> ``toolProfileFor`` -> the
    # mode-specific resolver MUST still surface the
    # "does not declare provisioning: <X> metadata" diagnostic the
    # Gap A nix / tarball / scoop smokes captured. This guards
    # against an over-broad M9.R.8 change that accidentally re-routed
    # those modes through the from-source resolver too.
    let useDef = syntheticUseDef("libfoo", "libfoo")
    let scratch = createTempDir("repro-m9r8-non-fromsource-", "")
    defer: removeDir(scratch)
    let artifact = ProjectInterfaceArtifact(
      projectInterface: ProjectInterface(
        projectName: "t_m9r8_negative",
        toolUses: @[useDef]))
    # ``toolBuildIdentity`` raises ``ValueError`` (NOT ``OSError``) when
    # a useDef lacks the required provisioning metadata for the active
    # mode. The Gap A nix / tarball / scoop smokes all surface this
    # same diagnostic shape — the M9.R.8 dispatcher gate broadening
    # must NOT relax it.
    try:
      discard toolBuildIdentity(artifact, tpmTarball, storeRoot = scratch)
      check false  # expected to raise
    except ValueError as exc:
      check exc.msg.contains("does not declare provisioning")
      check exc.msg.contains("tarball")
    # And again for ``tpmNix`` to ensure the change didn't accidentally
    # flip the nix path either.
    try:
      discard toolBuildIdentity(artifact, tpmNix, storeRoot = scratch)
      check false
    except ValueError as exc:
      check exc.msg.contains("does not declare provisioning")
      check exc.msg.contains("nixPackage")
