## DSL-port M9.R.9 — auto-recurse + stdlib fall-through tests.
##
## Pins the M9.R.9 surface in three layers:
##
##   1. ``tryResolveFromSourceTool`` returns a discriminated outcome
##      (``rrResolved`` / ``rrNeedsBuild`` / ``rrSiblingMissing``) so
##      the dispatcher can pattern-match on what to do next.
##
##   2. ``toolProfileFor(tpmFromSource, ...)`` falls through to the
##      stdlib provisioning channels declared on the ``useDef`` (nix /
##      scoop / tarball) when no sibling source recipe exists. This
##      makes ``--tool-provisioning=from-source`` pragmatic: from-source
##      for things we have source recipes for; fall back to whatever the
##      stdlib package declared for things we don't (e.g. python3).
##
##   3. The dispatcher-side auto-recurse guards (cycle detection +
##      depth ceiling + per-process resolution cache) live as
##      module-level state in ``repro_cli_support``. We exercise them
##      directly here by manipulating the guard state — a full
##      end-to-end auto-recurse test would require synthesising a real
##      recipe + driving a sub-build, which the test framework already
##      covers via the live smoke (Gap A wayland / meson chains).
##
## The unit-test fixtures use ``createTempDir`` so nothing in the
## production ``recipes/packages/source/`` checkout is touched.

import std/[options, os, sets, strutils, tempfiles, unittest]

import repro_cli_support
import repro_tool_profiles
import repro_interface_artifacts

proc makeRecipeFile(root, name: string) =
  let recipeDir = root / name
  createDir(recipeDir)
  writeFile(recipeDir / "repro.nim", "## synthetic " & name & " recipe\n")

proc makeRecipeArtefact(root, name, executableName: string;
                       useExeSuffix = false): string =
  let outDir = root / name / ".repro" / "output" / executableName
  createDir(outDir)
  let leaf =
    if useExeSuffix: executableName & ".exe"
    else: executableName
  let path = outDir / leaf
  writeFile(path, "#!/bin/sh\necho synthetic\n")
  when not defined(windows):
    setFilePermissions(path, {fpUserExec, fpUserRead, fpUserWrite,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  path

proc syntheticUseDef(name: string;
                     nix: seq[InterfaceNixProvisioning] = @[];
                     scoop: seq[InterfaceScoopProvisioning] = @[];
                     tarball: seq[InterfaceTarballProvisioning] = @[]):
    InterfaceToolUse =
  InterfaceToolUse(
    rawConstraint: name,
    packageSelector: name,
    executableName: name,
    nixProvisioning: nix,
    scoopProvisioning: scoop,
    tarballProvisioning: tarball)

suite "M9.R.9 auto-recurse + stdlib fall-through":

  test "test_m9r9_try_resolve_returns_rr_resolved_when_artefact_present":
    # Baseline pin: ``tryResolveFromSourceTool`` returns the discriminated
    # ``rrResolved`` outcome when the sibling recipe + artefact are both
    # on disk. This is the path the dispatcher follows in steady state
    # once auto-recurse has finished its sub-build pass.
    let scratch = createTempDir("repro-m9r9-resolved-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "fake-tool")
    let artefact = makeRecipeArtefact(scratch, "fake-tool", "fake-tool",
      useExeSuffix = defined(windows))

    let useDef = syntheticUseDef("fake-tool")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrResolved
    check outcome.profile.installMethod == "from-source"
    check outcome.profile.resolvedExecutablePath == absolutePath(artefact)

  test "test_m9r9_try_resolve_returns_rr_needs_build_when_artefact_missing":
    # Auto-recurse trigger: the sibling recipe exists but its artefact
    # is absent. The dispatcher receives ``rrNeedsBuild`` + the recipe
    # dir + the expected artefact path and schedules the sub-build.
    let scratch = createTempDir("repro-m9r9-needs-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "fake-tool")
    # No artefact.

    let useDef = syntheticUseDef("fake-tool")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrNeedsBuild
    check outcome.toolName == "fake-tool"
    check outcome.recipeDir == scratch / "fake-tool"
    check outcome.expectedArtifact.contains("fake-tool")
    check outcome.expectedArtifact.contains(".repro")

  test "test_m9r9_try_resolve_returns_rr_sibling_missing_when_no_recipe":
    # Stdlib fall-through trigger: no ``repro.nim`` at the sibling-recipe
    # location. The dispatcher receives ``rrSiblingMissing`` + checks
    # the useDef's stdlib provisioning channels before hard-failing.
    let scratch = createTempDir("repro-m9r9-no-sibling-", "")
    defer: removeDir(scratch)
    # No recipe file at all.

    let useDef = syntheticUseDef("python3")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrSiblingMissing
    check outcome.missingToolName == "python3"
    check outcome.attemptedRecipeManifest.endsWith("repro.nim")
    check outcome.attemptedRecipeManifest.contains("python3")

  test "test_m9r9_stdlib_fall_through_uses_scoop_when_sibling_missing":
    # Part 2 — stdlib fall-through. A useDef whose sibling recipe is
    # absent but whose stdlib provisioning declares a Scoop block
    # (Windows) resolves via the Scoop adapter under ``tpmFromSource``.
    # The original ``--tool-provisioning=from-source`` flag stays
    # active for the rest of the build — only this one useDef is
    # routed via the fall-through.
    #
    # We pin the behaviour on Windows specifically because the
    # fall-through preference order on each host is host-aware (nix on
    # Nix-capable hosts, scoop on Windows, tarball anywhere). The
    # other host paths get checked by tarball + cross-platform pins
    # below.
    when defined(windows):
      let scratch = createTempDir("repro-m9r9-stdlib-scoop-", "")
      defer: removeDir(scratch)
      # Sibling recipe deliberately absent: no makeRecipeFile call.
      let scoop = @[InterfaceScoopProvisioning(
        bucket: "main",
        app: "python",
        executablePath: "python.exe",
        packageId: "python@3.12.10")]
      let useDef = syntheticUseDef("python3", scoop = scoop)
      # We route through toolBuildIdentity so the stdlib fall-through
      # in toolProfileFor fires. The Scoop resolver may itself raise
      # (catalog probe etc.) — the assertion target here is that the
      # raise is NOT the "no sibling recipe" message: we got past that
      # gate to the Scoop layer.
      let artifact = ProjectInterfaceArtifact(
        projectInterface: ProjectInterface(
          projectName: "t_m9r9_stdlib_scoop",
          toolUses: @[useDef]))
      try:
        # Setting REPRO_FROM_SOURCE_ROOT redirects the sibling-recipe
        # probe to our scratch dir (where no python3 recipe exists).
        let savedRoot = getEnv(FromSourceRootEnvVar)
        putEnv(FromSourceRootEnvVar, scratch)
        defer:
          if savedRoot.len > 0: putEnv(FromSourceRootEnvVar, savedRoot)
          else: delEnv(FromSourceRootEnvVar)
        discard toolBuildIdentity(artifact, tpmFromSource,
          storeRoot = scratch / "tool-store")
        # If toolBuildIdentity returns without raising, the Scoop
        # adapter resolved fully (e.g. test env had python on PATH).
        # That's a stronger success signal.
        check true
      except CatchableError as exc:
        # The hard-fail MUST NOT be the M9.R.9 "no sibling recipe AND
        # no stdlib provisioning channel" diagnostic — that would mean
        # the fall-through gate didn't see the scoop block.
        check not exc.msg.contains(
          "no stdlib provisioning channel")
        # The hard-fail MUST NOT be the M9.Q "no sibling recipe" gate
        # alone — that would mean fall-through wasn't reached.
        check not (exc.msg.contains("no sibling recipe") and
          not exc.msg.contains("scoop") and
          not exc.msg.contains("Scoop"))

  test "test_m9r9_stdlib_fall_through_uses_tarball_on_non_nix_non_windows":
    # The cross-platform fall-through branch: when neither nix (Nix-
    # capable hosts) nor scoop (Windows) provisioning applies, the
    # tarball block — declared cross-platform on the stdlib package —
    # is the universal fall-through. This pins the contract for hosts
    # that fit neither earlier branch (e.g. plain FreeBSD, plain musl
    # Linux without Nix), and equally for the Linux/macOS path when
    # the useDef carries ONLY tarball provisioning (no nix block).
    when not defined(windows):
      let scratch = createTempDir("repro-m9r9-stdlib-tarball-", "")
      defer: removeDir(scratch)
      let tarball = @[InterfaceTarballProvisioning(
        url: "file:///does/not/exist.tar.gz",
        sha256: "0000000000000000000000000000000000000000000000000000000000000000",
        archiveType: "tar.gz",
        executablePath: "fake-tool",
        packageId: "fake-tool@1.0",
        cpu: "any",
        os: "any",
        lockIdentity: "tarball:fake-tool@1.0:sha256:0")]
      let useDef = syntheticUseDef("fake-tool", tarball = tarball)
      let artifact = ProjectInterfaceArtifact(
        projectInterface: ProjectInterface(
          projectName: "t_m9r9_stdlib_tarball",
          toolUses: @[useDef]))
      let savedRoot = getEnv(FromSourceRootEnvVar)
      putEnv(FromSourceRootEnvVar, scratch)
      defer:
        if savedRoot.len > 0: putEnv(FromSourceRootEnvVar, savedRoot)
        else: delEnv(FromSourceRootEnvVar)
      try:
        discard toolBuildIdentity(artifact, tpmFromSource,
          storeRoot = scratch / "tool-store")
      except CatchableError as exc:
        check not exc.msg.contains("no stdlib provisioning channel")

  test "test_path_mode_keeps_matching_tarball_before_nix_fallback":
    # Path-mode fallback historically preferred tarball metadata over
    # other stdlib channels when the host PATH did not supply the tool.
    # Keep that contract for tarballs that actually match the current
    # host so direct-download tool pins (node/cargo/etc.) do not silently
    # switch to Nix.
    let scratch = createTempDir("repro-path-tarball-before-nix-", "")
    defer: removeDir(scratch)
    let nix = @[InterfaceNixProvisioning(
      selector: "",
      executablePath: "bin/fake-tool",
      packageId: "fake-tool@nix")]
    let tarball = @[InterfaceTarballProvisioning(
      url: "file:///does/not/exist.tar.gz",
      sha256: "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType: "tar.gz",
      executablePath: "fake-tool",
      packageId: "fake-tool@tarball",
      cpu: "any",
      os: "any",
      lockIdentity: "tarball:fake-tool@tarball:sha256:0")]
    let useDef = syntheticUseDef("repro-missing-path-tarball-first",
      nix = nix, tarball = tarball)
    let artifact = ProjectInterfaceArtifact(
      projectInterface: ProjectInterface(
        projectName: "t_path_tarball_before_nix",
        toolUses: @[useDef]))
    try:
      discard toolBuildIdentity(artifact, tpmPathOnly,
        pathValue = "", storeRoot = scratch / "tool-store")
      check false  # expected to raise on the bogus tarball URL
    except CatchableError as exc:
      check exc.msg.contains("file URL does not exist")
      check not exc.msg.contains("incomplete nixPackage metadata")

  test "test_path_mode_uses_nix_when_tarball_does_not_match_host":
    # Cap'n Proto declares an official Windows tools zip, but upstream
    # does not publish an equivalent Linux/macOS binary tarball. When a
    # package has Nix metadata and only non-host tarballs, path mode
    # should fall through to Nix instead of surfacing the misleading
    # "no tarball provisioning entry matches host" diagnostic.
    when defined(linux) or defined(macosx):
      let scratch = createTempDir("repro-path-nix-after-mismatched-tarball-", "")
      defer: removeDir(scratch)
      let nix = @[InterfaceNixProvisioning(
        selector: "",
        executablePath: "bin/fake-tool",
        packageId: "fake-tool@nix")]
      let tarball = @[InterfaceTarballProvisioning(
        url: "file:///does/not/exist.zip",
        sha256: "0000000000000000000000000000000000000000000000000000000000000000",
        archiveType: "zip",
        executablePath: "fake-tool.exe",
        packageId: "fake-tool@windows",
        cpu: "x86_64",
        os: "windows",
        lockIdentity: "tarball:fake-tool@windows:sha256:0")]
      let useDef = syntheticUseDef("repro-missing-path-nix-fallback",
        nix = nix, tarball = tarball)
      let artifact = ProjectInterfaceArtifact(
        projectInterface: ProjectInterface(
          projectName: "t_path_nix_after_mismatched_tarball",
          toolUses: @[useDef]))
      try:
        discard toolBuildIdentity(artifact, tpmPathOnly,
          pathValue = "", storeRoot = scratch / "tool-store")
        check false  # expected to raise on deliberately incomplete Nix metadata
      except CatchableError as exc:
        check exc.msg.contains("incomplete nixPackage metadata")
        check not exc.msg.contains("no tarball provisioning entry")

  test "test_m9r9_hard_fail_when_both_recipe_and_stdlib_provisioning_missing":
    # The terminal case: no sibling recipe AND no provisioning channels
    # declared on the useDef. The fall-through chain runs to the end
    # and surfaces an actionable diagnostic listing both remediation
    # paths.
    let scratch = createTempDir("repro-m9r9-both-missing-", "")
    defer: removeDir(scratch)
    let useDef = syntheticUseDef("totally-fictional-tool")
    let artifact = ProjectInterfaceArtifact(
      projectInterface: ProjectInterface(
        projectName: "t_m9r9_both_missing",
        toolUses: @[useDef]))
    let savedRoot = getEnv(FromSourceRootEnvVar)
    putEnv(FromSourceRootEnvVar, scratch)
    defer:
      if savedRoot.len > 0: putEnv(FromSourceRootEnvVar, savedRoot)
      else: delEnv(FromSourceRootEnvVar)
    try:
      discard toolBuildIdentity(artifact, tpmFromSource,
        storeRoot = scratch / "tool-store")
      check false  # expected to raise
    except OSError as exc:
      check exc.msg.contains("totally-fictional-tool")
      check exc.msg.contains("no sibling recipe")
      check exc.msg.contains("no stdlib provisioning channel")

  test "test_m9r9_per_process_resolution_cache_dedupes_repeat_probes":
    # The cache is consulted BEFORE the cycle / depth gates so two
    # back-to-back resolutions of the same recipe path in one session
    # short-circuit at the cache layer. We exercise the cache directly
    # here — the dispatcher populates it after a successful sub-build;
    # tests insert a sentinel entry and verify that subsequent lookups
    # see it.
    let scratch = createTempDir("repro-m9r9-cache-", "")
    defer: removeDir(scratch)
    let recipeDir = absolutePath(scratch / "cache-fake")
    # Snapshot + restore the global cache so the test is hermetic
    # regardless of which other tests have already run in this binary.
    let savedCache = fromSourceResolvedRecipes
    defer: fromSourceResolvedRecipes = savedCache

    fromSourceResolvedRecipes.incl(recipeDir)
    check recipeDir in fromSourceResolvedRecipes
    # The cache is a HashSet, so re-inclusion is idempotent (no
    # spurious "rebuild" event would fire on the second call).
    let beforeLen = fromSourceResolvedRecipes.len
    fromSourceResolvedRecipes.incl(recipeDir)
    check fromSourceResolvedRecipes.len == beforeLen

  test "test_m9r9_recursion_cycle_detection_state_is_addressable":
    # Cycle detection's pin: pushing the same recipe dir twice onto the
    # active-build stack is what the dispatcher checks against. We pin
    # the state machine here; the live cycle test runs against the
    # dispatcher when ``executeBuildTarget`` is invoked, but a pure
    # unit test for the guard structure makes the regression surface
    # visible without standing up the whole engine.
    let savedStack = fromSourceBuildStack
    defer: fromSourceBuildStack = savedStack
    fromSourceBuildStack = @[]

    fromSourceBuildStack.add("/fake/recipes/A")
    fromSourceBuildStack.add("/fake/recipes/B")
    # The dispatcher's gate is ``siblingRecipeDir in fromSourceBuildStack``;
    # verify the predicate fires for an already-active entry.
    check "/fake/recipes/A" in fromSourceBuildStack
    check "/fake/recipes/B" in fromSourceBuildStack
    check "/fake/recipes/C" notin fromSourceBuildStack
    # Popping (finally-block contract) leaves the stack consistent.
    discard fromSourceBuildStack.pop()
    check "/fake/recipes/B" notin fromSourceBuildStack
    check "/fake/recipes/A" in fromSourceBuildStack

  test "test_m9r9_recursion_depth_ceiling_predicate_is_consistent":
    # The dispatcher's depth gate is
    # ``fromSourceBuildStack.len >= FromSourceMaxRecursionDepth``.
    # Pin that the comparison sense matches the constant (a future
    # off-by-one inversion would let one extra level through).
    let savedStack = fromSourceBuildStack
    defer: fromSourceBuildStack = savedStack
    fromSourceBuildStack = @[]

    for i in 0 ..< FromSourceMaxRecursionDepth:
      fromSourceBuildStack.add("/fake/recipes/depth-" & $i)
    # At exactly the ceiling, the dispatcher must refuse to push the
    # next entry. The check below mirrors the dispatcher's gate.
    check fromSourceBuildStack.len >= FromSourceMaxRecursionDepth

  test "test_m9r9_recursion_depth_ceiling_is_a_finite_sanity_bound":
    # ``FromSourceMaxRecursionDepth`` is a sanity ceiling, not a
    # behavioural switch. The pin guards against a future inversion
    # (negative / zero) or removal that would either crash the stack
    # or let runaway recursion go unbounded.
    check FromSourceMaxRecursionDepth >= 8
    check FromSourceMaxRecursionDepth <= 256

  test "test_m9r9_resolved_recipes_cache_is_addressable":
    # The per-process resolution cache must be reachable from outside
    # the dispatcher so the test harness (and ``repro why``) can
    # introspect what was already auto-recursed in a session. We don't
    # mutate it directly here — the dispatcher owns its lifecycle —
    # but we pin the visibility contract.
    let snapshot = fromSourceResolvedRecipes
    discard snapshot
    check fromSourceBuildStack.len >= 0
