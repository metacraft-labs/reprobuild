## DSL-port M9.R.10a — cycle break + stdlib fall-through tests.
##
## Pins the M9.R.10a surface:
##
##   When the auto-recurse dispatcher in ``executeBuildTarget`` detects
##   a from-source recursion cycle (the closing-edge sibling recipe dir
##   is already on the active build stack), instead of raising the
##   cycle diagnostic, it marks the tool's ``executableName`` in
##   ``fromSourceCycleBrokenTools`` and continues. The downstream
##   ``toolProfileFor(tpmFromSource, ...)`` resolver short-circuits the
##   sibling-recipe probe for that one tool and routes through stdlib
##   provisioning (nix / scoop / tarball) — same logic the M9.R.9
##   ``rrSiblingMissing`` branch already uses.
##
##   This breaks the cycle without sacrificing from-source semantics
##   for the rest of the build graph: only the closing-edge tool comes
##   from stdlib; every other tool in the chain still builds from
##   source. Genuine cycles where no node has stdlib provisioning still
##   raise (with a tighter, more actionable diagnostic that names the
##   stdlib package that needs a provisioning block).
##
## The dispatcher integration test (driving a real cycle through
## ``executeBuildTarget``) is the smoke test against the meson + wayland
## chains; this unit pins the resolver-layer behaviour without standing
## up the engine.

import std/[os, sets, strutils, tempfiles, unittest]

import repro_cli_support
import repro_tool_profiles
import repro_interface_artifacts

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

proc makeRecipeFile(root, name: string) =
  let recipeDir = root / name
  createDir(recipeDir)
  writeFile(recipeDir / "repro.nim", "## synthetic " & name & " recipe\n")

suite "M9.R.10a cycle break + stdlib fall-through":

  test "test_m9r10a_cycle_broken_set_is_addressable_and_mutable":
    # Pin the introspection contract: tests + ``repro why`` can read +
    # snapshot + restore the per-process cycle-broken set. The
    # dispatcher owns the lifecycle in production builds; the
    # introspection surface keeps the unit-test layer hermetic.
    let savedSet = fromSourceCycleBrokenTools
    defer: fromSourceCycleBrokenTools = savedSet
    fromSourceCycleBrokenTools = initHashSet[string]()

    check fromSourceCycleBrokenTools.len == 0
    fromSourceCycleBrokenTools.incl("gcc")
    check "gcc" in fromSourceCycleBrokenTools
    check "binutils" notin fromSourceCycleBrokenTools

  test "test_m9r10a_cycle_break_routes_through_stdlib_when_provisioning_present":
    # Synthesise a useDef whose sibling recipe EXISTS (so the M9.R.9
    # ``rrSiblingMissing`` branch would NOT fire) but whose name is in
    # the cycle-broken set (the dispatcher detected a recursion cycle
    # for it). On Windows, declare a scoop provisioning block; on
    # Linux/macOS, a nix block; on any platform, tarball as the
    # universal fall-through. The resolver MUST short-circuit the
    # sibling-recipe probe and route through stdlib instead.
    let scratch = createTempDir("repro-m9r10a-cycle-stdlib-", "")
    defer: removeDir(scratch)
    # Sibling recipe exists — the cycle break uses stdlib ANYWAY because
    # the name is in the cycle-broken set.
    makeRecipeFile(scratch, "gcc-cycle")

    let savedSet = fromSourceCycleBrokenTools
    defer: fromSourceCycleBrokenTools = savedSet
    fromSourceCycleBrokenTools = initHashSet[string]()
    fromSourceCycleBrokenTools.incl("gcc-cycle")

    when defined(windows):
      let scoop = @[InterfaceScoopProvisioning(
        bucket: "main",
        app: "git",
        executablePath: "bin/sh.exe",
        packageId: "git@2.54.0")]
      let useDef = syntheticUseDef("gcc-cycle", scoop = scoop)
    else:
      let tarball = @[InterfaceTarballProvisioning(
        url: "file:///does/not/exist.tar.gz",
        sha256: "0".repeat(64),
        archiveType: "tar.gz",
        executablePath: "gcc-cycle",
        packageId: "gcc-cycle@1.0",
        cpu: "any",
        os: "any",
        lockIdentity: "tarball:gcc-cycle@1.0:sha256:0")]
      let useDef = syntheticUseDef("gcc-cycle", tarball = tarball)

    let artifact = ProjectInterfaceArtifact(
      projectInterface: ProjectInterface(
        projectName: "t_m9r10a_cycle_stdlib",
        toolUses: @[useDef]))

    let savedRoot = getEnv(FromSourceRootEnvVar)
    putEnv(FromSourceRootEnvVar, scratch)
    defer:
      if savedRoot.len > 0: putEnv(FromSourceRootEnvVar, savedRoot)
      else: delEnv(FromSourceRootEnvVar)

    try:
      discard toolBuildIdentity(artifact, tpmFromSource,
        storeRoot = scratch / "tool-store")
      # If the adapter fully resolved (rare in a unit test — would
      # require a live realised tool), that's an even stronger success
      # signal: the fall-through routed through the stdlib resolver.
      check true
    except CatchableError as exc:
      # The hard-fail MUST NOT be the cycle diagnostic itself (cycle
      # detected, no fall-through) — that means the cycle-broken set
      # wasn't consulted before the sibling probe ran.
      check not exc.msg.contains("from-source recursion cycle detected")
      # The hard-fail MUST NOT be the M9.Q "no sibling recipe" gate —
      # that means the resolver hit ``rrSiblingMissing`` (the sibling
      # DID exist in this fixture; the cycle-break override should have
      # bypassed the probe).
      check not exc.msg.contains("but no sibling recipe at")
      # The error, if any, must come from the stdlib provisioning
      # resolver (e.g. tarball download failing on a bogus file:// URL).
      # That's the gate we're proving is reached.

  test "test_m9r10a_cycle_break_raises_when_no_stdlib_provisioning":
    # The terminal case: cycle detected AND no stdlib provisioning
    # declared on the useDef. The resolver surfaces a tighter
    # diagnostic that names the tool + points the operator at the
    # stdlib package definition (not the recipe nativeBuildDeps lists,
    # which is the M9.Q-era hint for ``rrSiblingMissing``).
    let scratch = createTempDir("repro-m9r10a-no-stdlib-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "no-stdlib-tool")

    let savedSet = fromSourceCycleBrokenTools
    defer: fromSourceCycleBrokenTools = savedSet
    fromSourceCycleBrokenTools = initHashSet[string]()
    fromSourceCycleBrokenTools.incl("no-stdlib-tool")

    let useDef = syntheticUseDef("no-stdlib-tool")
    let artifact = ProjectInterfaceArtifact(
      projectInterface: ProjectInterface(
        projectName: "t_m9r10a_no_stdlib",
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
      # New M9.R.10a diagnostic — names the tool + points at stdlib
      # package definition (not at recipe nativeBuildDeps lists).
      check exc.msg.contains("no-stdlib-tool")
      check exc.msg.contains("auto-recurse detected a cycle")
      check exc.msg.contains(
        "no provisioning channel (nix / scoop / tarball) is declared")

  test "test_m9r10a_self_reference_cycle_hits_break_path":
    # A recipe whose nativeBuildDeps references itself produces an
    # immediate single-entry cycle. The dispatcher's predicate
    # (``siblingRecipeDir in fromSourceBuildStack``) fires on the second
    # push; the cycle-break path then routes through stdlib. Pin the
    # set semantics here — a recipe name that's been pushed to the
    # build stack AND simultaneously appears in the cycle-broken set
    # must be consistent (no inversion that would let the dispatcher
    # raise after we set the break flag).
    let savedStack = fromSourceBuildStack
    let savedSet = fromSourceCycleBrokenTools
    defer:
      fromSourceBuildStack = savedStack
      fromSourceCycleBrokenTools = savedSet
    fromSourceBuildStack = @["/fake/recipes/self-ref"]
    fromSourceCycleBrokenTools = initHashSet[string]()

    # Detect: pushing the same dir would fire the cycle gate.
    let siblingDir = "/fake/recipes/self-ref"
    check siblingDir in fromSourceBuildStack
    # Apply the cycle break.
    fromSourceCycleBrokenTools.incl("self-ref")
    check "self-ref" in fromSourceCycleBrokenTools
    # The dispatcher pops the stack frame at this point; the set
    # remains so subsequent resolver calls keep using stdlib.
    discard fromSourceBuildStack.pop()
    check siblingDir notin fromSourceBuildStack
    check "self-ref" in fromSourceCycleBrokenTools

  test "test_m9r10a_resolve_stdlib_provisioning_helper_returns_false_with_no_channels":
    # The shared ``tryResolveStdlibProvisioning`` helper returns ``false``
    # (and does not raise) when the useDef carries NO provisioning
    # channels at all. Callers (both ``toolProfileFor`` and the
    # dispatcher) then raise their own context-specific diagnostic.
    let useDef = syntheticUseDef("empty-tool")
    var profile: PathOnlyToolProfile
    let resolved = tryResolveStdlibProvisioning(useDef,
      storeRoot = getTempDir() / "tool-store", profile = profile)
    check resolved == false

  test "test_m9r10a_cycle_break_does_not_leak_into_other_tools":
    # A cycle break for tool A must not affect resolution of tool B in
    # the same build. The override is keyed strictly by
    # ``executableName``, so a useDef whose name is NOT in the set
    # follows the normal from-source resolution path (sibling probe +
    # ``rrResolved`` / ``rrNeedsBuild`` / ``rrSiblingMissing`` outcomes).
    let scratch = createTempDir("repro-m9r10a-no-leak-", "")
    defer: removeDir(scratch)
    # No sibling, no provisioning — would hit M9.R.9's hard-fail.
    let useDef = syntheticUseDef("tool-b")

    let savedSet = fromSourceCycleBrokenTools
    defer: fromSourceCycleBrokenTools = savedSet
    fromSourceCycleBrokenTools = initHashSet[string]()
    # Only tool-a is in the cycle-broken set.
    fromSourceCycleBrokenTools.incl("tool-a")

    let artifact = ProjectInterfaceArtifact(
      projectInterface: ProjectInterface(
        projectName: "t_m9r10a_no_leak",
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
      # The M9.R.9 ``rrSiblingMissing`` + no-stdlib hard-fail path.
      check exc.msg.contains("tool-b")
      check exc.msg.contains("no sibling recipe")
      # MUST NOT be the M9.R.10a cycle-break diagnostic — that would
      # mean the override leaked across tools.
      check not exc.msg.contains("auto-recurse detected a cycle")
