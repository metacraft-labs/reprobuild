## M9.Q — From-source provisioning resolver tests.
##
## DSL-port M9.R.9 note: this test pins the LOW-LEVEL raising entry
## point ``resolveFromSourceTool``. M9.R.9 added a non-raising twin
## (``tryResolveFromSourceTool`` returning ``FromSourceResolveResult``)
## and an auto-recurse dispatcher pass on top of it, plus a stdlib
## fall-through in ``toolProfileFor`` (see
## ``t_m9r9_auto_recurse.nim``). The raising shim's contract is
## preserved so existing M9.Q assertions hold: callers that bypass the
## dispatcher (e.g. unit tests, ``repro why`` introspection paths) keep
## the same hard-fail diagnostic shape.
##
## Covers the new ``tpmFromSource`` mode end-to-end at the resolver
## layer (no engine / no recipe compile):
##
##   1. ``parseToolProvisioning`` accepts ``from-source`` / ``source``
##      / ``fromSource`` and maps each spelling onto ``tpmFromSource``.
##   2. ``fromSourceArtifactCandidate`` constructs the convention path
##      ``<recipeRoot>/<name>/.repro/output/<name>/<name>`` byte-
##      identical to the ``from-source-custom`` convention's stage-copy
##      target.
##   3. ``resolveFromSourceTool`` finds a synthetic recipe + artefact
##      and returns a profile whose ``resolvedExecutablePath`` is the
##      artefact and whose ``pathSearchList`` carries the artefact's
##      parent dir (so the Step C resolver can thread it into PATH).
##   4. ``resolveFromSourceTool`` raises ``OSError`` with the recipe
##      path and a ``--no-runquota`` build hint when the sibling recipe
##      is missing.
##   5. ``resolveFromSourceTool`` raises ``OSError`` naming both the
##      recipe dir and the expected artefact path when the recipe
##      exists but its artefact hasn't been built.
##   6. ``REPRO_FROM_SOURCE_ROOT`` overrides the default recipe anchor.
##
## The test uses ``createTempDir`` to stand up a synthetic recipe tree
## so it does not depend on the production ``recipes/packages/source/``
## checkout — running this test never builds the real meson recipe.

import std/[os, strutils, tempfiles, unittest]

import repro_cli_support
import repro_tool_profiles
import repro_interface_artifacts

proc makeRecipeFile(root, name: string) =
  ## Lay down a minimal ``recipes/packages/source/<name>/repro.nim``
  ## file so ``resolveFromSourceTool`` accepts the recipe as present.
  let recipeDir = root / name
  createDir(recipeDir)
  writeFile(recipeDir / "repro.nim", "## synthetic " & name & " recipe\n")

proc makeRecipeArtefact(root, name, executableName: string;
                       useExeSuffix = false): string =
  ## Lay down the artefact at ``<root>/<name>/.repro/output/<exe>/<exe>``
  ## (with optional ``.exe`` suffix). Mirrors the
  ## ``from-source-custom`` convention's stage-copy target.
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

proc syntheticUseDef(name: string): InterfaceToolUse =
  InterfaceToolUse(
    rawConstraint: name,
    packageSelector: name,
    executableName: name)

suite "M9.Q from-source provisioning resolver":

  test "test_m9q_parse_tool_provisioning_accepts_from_source_aliases":
    # All three spellings collapse to tpmFromSource. ``parseToolProvisioning``
    # is the helper the CLI flag parser and the
    # ``REPRO_TOOL_PROVISIONING`` env-var path both call.
    check parseToolProvisioning("from-source") == tpmFromSource
    check parseToolProvisioning("fromSource") == tpmFromSource
    check parseToolProvisioning("source") == tpmFromSource
    # Sanity: prior modes still parse — make sure the alias addition
    # did not regress the enum mapping.
    check parseToolProvisioning("path") == tpmPathOnly
    check parseToolProvisioning("tarball") == tpmTarball
    check parseToolProvisioning("scoop") == tpmScoop
    check parseToolProvisioning("nix") == tpmNix

  test "test_m9q_artifact_candidate_path_matches_convention_layout":
    # The candidate path must match the ``from-source-custom`` stage-
    # copy convention exactly (otherwise the resolver looks in the
    # wrong place and pointlessly hard-fails on every build).
    let candidate = fromSourceArtifactCandidate(
      "/work/recipes/packages/source", "meson", "meson")
    let expected = "/work/recipes/packages/source/meson/.repro/output/meson/meson"
    check candidate.replace('\\', '/') == expected

  test "test_m9q_resolves_recipe_with_built_artefact":
    let scratch = createTempDir("repro-m9q-resolves-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "meson")
    let artefact = makeRecipeArtefact(scratch, "meson", "meson",
      useExeSuffix = defined(windows))

    let useDef = syntheticUseDef("meson")
    let profile = resolveFromSourceTool(useDef, recipeRoot = scratch)

    check profile.installMethod == "from-source"
    check profile.executableName == "meson"
    check profile.resolvedExecutablePath == absolutePath(artefact)
    check profile.pathSearchList.len == 1
    check profile.pathSearchList[0] == parentDir(absolutePath(artefact))
    check profile.lockIdentity.startsWith("from-source:meson:recipe:")
    check profile.adapterStrength == asStrong

  test "test_m9q_missing_recipe_raises_actionable_diagnostic":
    let scratch = createTempDir("repro-m9q-no-recipe-", "")
    defer: removeDir(scratch)
    # Note: we do NOT call makeRecipeFile — the recipe dir is absent.

    let useDef = syntheticUseDef("ninja")
    expect OSError:
      discard resolveFromSourceTool(useDef, recipeRoot = scratch)

    try:
      discard resolveFromSourceTool(useDef, recipeRoot = scratch)
    except OSError as exc:
      check exc.msg.contains("from-source")
      check exc.msg.contains("ninja")
      check exc.msg.contains("no sibling recipe")
      check exc.msg.contains("repro.nim")

  test "test_m9q_unbuilt_recipe_raises_with_build_hint":
    let scratch = createTempDir("repro-m9q-unbuilt-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "meson")
    # Note: we do NOT call makeRecipeArtefact — the recipe exists but
    # has not been built.

    let useDef = syntheticUseDef("meson")
    try:
      discard resolveFromSourceTool(useDef, recipeRoot = scratch)
      check false  # expected to raise
    except OSError as exc:
      check exc.msg.contains("from-source")
      check exc.msg.contains("meson")
      check exc.msg.contains("has not produced an artefact")
      check exc.msg.contains("repro build")
      check exc.msg.contains("--no-runquota")

  test "test_m9q_env_var_override_redirects_recipe_root":
    let scratch = createTempDir("repro-m9q-envvar-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "ninja")
    let artefact = makeRecipeArtefact(scratch, "ninja", "ninja",
      useExeSuffix = defined(windows))

    let savedRoot = getEnv(FromSourceRootEnvVar)
    putEnv(FromSourceRootEnvVar, scratch)
    defer:
      if savedRoot.len > 0: putEnv(FromSourceRootEnvVar, savedRoot)
      else: delEnv(FromSourceRootEnvVar)

    # Pass an empty recipeRoot so the env-var override path fires.
    let useDef = syntheticUseDef("ninja")
    let profile = resolveFromSourceTool(useDef)
    check profile.resolvedExecutablePath == absolutePath(artefact)
    check fromSourceRecipeRoot() == scratch
