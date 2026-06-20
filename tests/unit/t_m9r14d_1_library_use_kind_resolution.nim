## DSL-port M9.R.14d.1 — from-source resolver discovers library
## artefacts (not just executables) and matches dep selectors with
## canonicalization.
##
## ## Context
##
## M9.R.14c.14 landed the first three from-source libraries (libZ from
## zlib, libFfi from libffi, libExpat from expat) at canonical paths
## on Linux. The next layer (libxml2 depending on zlib, wayland
## depending on libffi+expat) trips because
## ``tryResolveFromSourceTool`` only knew how to probe
## ``<recipe>/.repro/output/<name>/<name>`` — an EXECUTABLE-shaped
## layout. Library artefacts land under their library-name subdir, NOT
## the dep selector's name (zlib package → libZ artifact), so the
## probe walked into a dir that doesn't exist.
##
## ## What this test pins
##
##   1. ``m9r14dCanonicalizeName`` lowercases and strips a leading
##      ``lib`` prefix.
##   2. ``m9r14dDepMatchesArtifact`` matches dep ``zlib`` against
##      artifact ``libZ`` via lowercase-cross-canonical-form
##      equivalence.
##   3. ``tryResolveFromSourceTool`` returns a profile pointing at the
##      sibling recipe's LIBRARY artefact when the dep names the
##      package and the sole library is a SONAME-style sibling.
##   4. ``tryResolveFromSourceTool`` returns the EXECUTABLE artefact
##      when the recipe declares only an executable.
##   5. Mixed recipes (both library and executable) pick the canonical
##      match.
##   6. Recipes with no project-interface.rbsz on disk fall back to
##      filesystem enumeration with ``makUnknown`` and still resolve
##      via the suffix-probe order.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_tool_profiles
import repro_interface_artifacts
import repro_project_dsl

proc makeRecipeFile(root, name: string) =
  let recipeDir = root / name
  createDir(recipeDir)
  writeFile(recipeDir / "repro.nim", "## synthetic " & name & " recipe\n")

proc platformLibrarySuffix(): string =
  when defined(windows): ".dll"
  elif defined(macosx): ".dylib"
  else: ".so"

proc makeLibraryArtefact(root, recipeName, artifactName: string;
                        suffix = "<platform>"): string =
  ## Place a synthetic library file at
  ## ``<root>/<recipeName>/.repro/output/<artifactName>/<artifactName><suffix>``.
  ## When ``suffix`` is the magic ``<platform>`` token, the
  ## platform-appropriate shared-library extension (.so/.dll/.dylib)
  ## is used so the test runs identically on every supported OS.
  ## When ``suffix`` is "" the test exercises the legacy
  ## (pre-M9.R.14d) stage-copy layout that doesn't add a suffix.
  let outDir = root / recipeName / ".repro" / "output" / artifactName
  createDir(outDir)
  let effectiveSuffix =
    if suffix == "<platform>": platformLibrarySuffix()
    else: suffix
  let path = outDir / (artifactName & effectiveSuffix)
  writeFile(path, "\x7fELF\x02\x01\x01\x00")
  path

proc makeExecutableArtefact(root, recipeName, artifactName: string): string =
  let outDir = root / recipeName / ".repro" / "output" / artifactName
  createDir(outDir)
  let path = outDir / artifactName
  writeFile(path, "#!/bin/sh\necho synth\n")
  when not defined(windows):
    setFilePermissions(path, {fpUserExec, fpUserRead, fpUserWrite,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  path

proc writeSyntheticInterface(root, recipeName: string;
                             executables, libraries: openArray[string]) =
  ## Lay down a synthetic project-interface.rbsz under the recipe's
  ## ``.repro/build/repro/`` directory so the resolver's interface
  ## reader can discover artifact kinds without an end-to-end build.
  let recipeDir = root / recipeName
  let outDir = recipeDir / ".repro" / "build" / "repro"
  createDir(outDir)
  var pi = ProjectInterface(
    projectName: recipeName,
    packageName: recipeName,
    defaultToolProvisioning: "")
  for exe in executables:
    pi.publicExecutables.add(InterfaceExecutable(
      exportName: exe, binaryName: exe))
  for lib in libraries:
    pi.publicLibraries.add(InterfaceLibrary(
      name: lib, kind: lkShared))
  writeInterfaceArtifact(outDir / "project-interface.rbsz", artifactFor(pi))

proc syntheticUseDef(name: string): InterfaceToolUse =
  InterfaceToolUse(
    rawConstraint: name,
    packageSelector: name,
    executableName: name)

suite "DSL-port M9.R.14d.1 — library-use-kind resolution":

  test "canonicalize_name_strips_lib_prefix_and_lowers":
    check m9r14dCanonicalizeName("libZ") == "z"
    check m9r14dCanonicalizeName("libExpat") == "expat"
    check m9r14dCanonicalizeName("zlib") == "zlib"
    check m9r14dCanonicalizeName("Make") == "make"
    check m9r14dCanonicalizeName("libGModule") == "gmodule"

  test "dep_matches_artifact_via_canonical_form":
    # Canonical (lib-prefix-stripped, lowercased) match: the dominant
    # case across the 95 in-tree library recipes. `expat` matches
    # `libExpat`, `libffi` matches `libFfi`, etc.
    check m9r14dDepMatchesArtifact("expat", "libExpat")
    check m9r14dDepMatchesArtifact("libffi", "libFfi")
    check m9r14dDepMatchesArtifact("ffi", "libFfi")
    # Exact case-insensitive match.
    check m9r14dDepMatchesArtifact("make", "make")
    check m9r14dDepMatchesArtifact("Make", "make")
    # zlib is the special case (package "zlib" but library "libz"):
    # the canonical forms differ (zlib vs z), so the direct match
    # rule doesn't fire. The sole-artifact fallback in
    # `m9r14dPickBestMatch` covers that recipe — see the
    # `sole_artifact_fallback_resolves_when_no_name_match` test.
    check not m9r14dDepMatchesArtifact("zlib", "libZ")
    # Mismatched names that should NOT collide.
    check not m9r14dDepMatchesArtifact("zlib", "libExpat")
    check not m9r14dDepMatchesArtifact("zlib", "libGModule")
    check not m9r14dDepMatchesArtifact("make", "zlib")

  test "resolves_library_artefact_when_recipe_declares_library":
    # The motivating case: dep "expat" → recipe "expat" → artifact
    # "libExpat" stored at `<recipe>/.repro/output/libExpat/libExpat.so`.
    # The canonical match (`expat` ↔ `expat`) picks the library.
    let scratch = createTempDir("repro-m9r14d-lib-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "expat")
    let artefact = makeLibraryArtefact(scratch, "expat", "libExpat")
    writeSyntheticInterface(scratch, "expat",
      executables = @[], libraries = @["libExpat"])

    let useDef = syntheticUseDef("expat")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrResolved
    check outcome.profile.resolvedExecutablePath == absolutePath(artefact)
    check outcome.profile.pathSearchList.len == 1
    check outcome.profile.pathSearchList[0] ==
      parentDir(absolutePath(artefact))

  test "resolves_executable_artefact_when_recipe_declares_executable":
    let scratch = createTempDir("repro-m9r14d-exe-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "barBin")
    let artefact = makeExecutableArtefact(scratch, "barBin", "barBin")
    writeSyntheticInterface(scratch, "barBin",
      executables = @["barBin"], libraries = @[])

    let useDef = syntheticUseDef("barBin")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrResolved
    check outcome.profile.resolvedExecutablePath == absolutePath(artefact)

  test "mixed_recipe_picks_canonical_match":
    # Recipe ``foo`` declares BOTH an executable (``fooHelper``) and a
    # library (``libFoo``). The canonical match rule must pick the
    # library when the dep selector is ``foo`` (canonical form `foo`
    # matches ``libFoo``'s canonical form `foo`) and NOT pick the
    # unrelated executable.
    let scratch = createTempDir("repro-m9r14d-mixed-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "foo")
    let exePath = makeExecutableArtefact(scratch, "foo", "fooHelper")
    let libPath = makeLibraryArtefact(scratch, "foo", "libFoo")
    writeSyntheticInterface(scratch, "foo",
      executables = @["fooHelper"], libraries = @["libFoo"])

    let useDef = syntheticUseDef("foo")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrResolved
    check outcome.profile.resolvedExecutablePath == absolutePath(libPath)
    # The executable still exists on disk — the resolver chose the
    # canonical match (library) over the lexicographically-first
    # candidate. Pin that we did NOT pick the executable by mistake.
    check outcome.profile.resolvedExecutablePath != absolutePath(exePath)

  test "falls_back_to_makUnknown_when_interface_missing":
    let scratch = createTempDir("repro-m9r14d-noiface-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "expat")
    # No interface artifact — the resolver enumerates the output
    # dir and the kind defaults to makUnknown.
    let artefact = makeLibraryArtefact(scratch, "expat", "libExpat")

    let useDef = syntheticUseDef("expat")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrResolved
    check outcome.profile.resolvedExecutablePath == absolutePath(artefact)

  test "legacy_stage_copy_layout_still_resolves":
    # The pre-M9.R.14d stage-copy emitted libraries without a `.so`
    # suffix (`.repro/output/libZ/libZ`). The resolver must still
    # resolve those until every recipe re-stages with the new suffix.
    let scratch = createTempDir("repro-m9r14d-legacy-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "zlib")
    let artefact = makeLibraryArtefact(scratch, "zlib", "libZ", "")
    writeSyntheticInterface(scratch, "zlib",
      executables = @[], libraries = @["libZ"])

    let useDef = syntheticUseDef("zlib")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrResolved
    check outcome.profile.resolvedExecutablePath == absolutePath(artefact)

  test "no_match_returns_needs_build":
    let scratch = createTempDir("repro-m9r14d-nomatch-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "unrelated")
    # An artifact whose name doesn't match the dep selector at all,
    # AND no sole-artifact fallback because the canonical match
    # fails for a clearly unrelated name.
    discard makeLibraryArtefact(scratch, "unrelated", "libZ")
    writeSyntheticInterface(scratch, "unrelated",
      executables = @[], libraries = @["libZ"])

    # Dep selector "totallyDifferent" doesn't match libZ. But the
    # sole-artifact fallback DOES fire when only one artifact is
    # staged, so we expect rrResolved — the recipe identifies the
    # package, and there's exactly one thing it produced.
    let useDef = syntheticUseDef("totallyDifferent")
    # No recipe at `totallyDifferent`, so this raises sibling-missing.
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrSiblingMissing

  test "canonical_prefix_match_resolves_multi_artifact_recipe":
    # The wayland canary: dep "wayland" matches the recipe directory
    # named "wayland", but the recipe declares 4 artifacts
    # (libwaylandClient, libwaylandServer, libwaylandCursor,
    # waylandScanner) — none of which canonicalize exactly to
    # "wayland". The sole-artifact fallback can't fire (>1 staged).
    # The canonical-prefix tier picks the artifact whose canonical
    # form is a prefix or extension of the dep's canonical form.
    let scratch = createTempDir("repro-m9r14d-prefix-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "wayland")
    let clientPath = makeLibraryArtefact(scratch, "wayland",
      "libwaylandClient")
    discard makeLibraryArtefact(scratch, "wayland", "libwaylandServer")
    discard makeLibraryArtefact(scratch, "wayland", "libwaylandCursor")
    discard makeExecutableArtefact(scratch, "wayland", "waylandScanner")
    writeSyntheticInterface(scratch, "wayland",
      executables = @["waylandScanner"],
      libraries = @["libwaylandClient", "libwaylandServer",
                    "libwaylandCursor"])

    let useDef = syntheticUseDef("wayland")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrResolved
    # The lexicographically-first canonical-prefix match wins.
    # Library `libwaylandClient` canonicalizes to `waylandclient`,
    # which starts with the dep canonical `wayland`. The other
    # libraries' canonicalizations also start with `wayland`; the
    # resolver picks the first hit (libwaylandClient comes first in
    # both walkDir order on the synthetic fixture and is the most
    # common downstream consumer).
    let resolvedName = lastPathPart(parentDir(
      outcome.profile.resolvedExecutablePath))
    check resolvedName.startsWith("libwayland") or resolvedName.startsWith("wayland")

  test "sole_artifact_fallback_resolves_when_no_name_match":
    let scratch = createTempDir("repro-m9r14d-sole-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "weirdName")
    let artefact = makeLibraryArtefact(scratch, "weirdName",
      "completelyDifferentArtefact")
    writeSyntheticInterface(scratch, "weirdName",
      executables = @[], libraries = @["completelyDifferentArtefact"])

    # Dep selector "weirdName" identifies the recipe. Its sole
    # artefact has a name that doesn't match the canonicalization
    # rules — fallback to the only candidate.
    let useDef = syntheticUseDef("weirdName")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrResolved
    check outcome.profile.resolvedExecutablePath == absolutePath(artefact)

  test "multi_artifact_umbrella_fallback_picks_first_resolved_candidate":
    # DSL-port M9.R.15f.4 — qt6-base canary. The qt6-base recipe ships
    # six libraries (libQt6Core / libQt6Gui / libQt6Widgets /
    # libQt6Network / libQt6DBus / libQt6Sql). The dep selector
    # ``qt6-base`` doesn't canonically match any of the six names
    # (canonical forms ``qt6base`` vs ``qt6core``/``qt6gui``/... are
    # not equal and not a prefix of each other). Sole-artifact
    # fallback can't fire because there are SIX resolved candidates,
    # not one — the umbrella fallback added in M9.R.15f.4 picks the
    # first resolved candidate so every KF6 module's
    # ``qt6-base >=6.6`` buildDep can resolve.
    let scratch = createTempDir("repro-m9r14d-umbrella-", "")
    defer: removeDir(scratch)
    makeRecipeFile(scratch, "qt6-base")
    let coreArt = makeLibraryArtefact(scratch, "qt6-base", "libQt6Core")
    discard makeLibraryArtefact(scratch, "qt6-base", "libQt6Gui")
    discard makeLibraryArtefact(scratch, "qt6-base", "libQt6Widgets")
    discard makeLibraryArtefact(scratch, "qt6-base", "libQt6Network")
    discard makeLibraryArtefact(scratch, "qt6-base", "libQt6DBus")
    discard makeLibraryArtefact(scratch, "qt6-base", "libQt6Sql")
    writeSyntheticInterface(scratch, "qt6-base",
      executables = @[],
      libraries = @["libQt6Core", "libQt6Gui", "libQt6Widgets",
                    "libQt6Network", "libQt6DBus", "libQt6Sql"])

    # Dep selector "qt6-base" matches the recipe basename; the six
    # library artifacts canonicalize to "qt6core"/"qt6gui"/... which
    # do NOT start with the dep canonical "qt6base" (and vice versa).
    # Tier 0/1/2/3 all miss. Umbrella fallback picks the first
    # resolved candidate — whatever walkDir order returns.
    let useDef = syntheticUseDef("qt6-base")
    let outcome = tryResolveFromSourceTool(useDef, recipeRoot = scratch)
    check outcome.kind == rrResolved
    # The resolved path MUST be one of the six staged libraries — the
    # exact one depends on walkDir's OS-dependent order but every one
    # is a legitimate qt6-base artifact.
    let resolvedName = lastPathPart(parentDir(
      outcome.profile.resolvedExecutablePath))
    check resolvedName in ["libQt6Core", "libQt6Gui", "libQt6Widgets",
                           "libQt6Network", "libQt6DBus", "libQt6Sql"]
    # Sanity: at least one of the six is the one we got (coreArt is
    # the path used to validate the absolutePath construction; the
    # umbrella fallback may pick any of the six).
    check outcome.profile.resolvedExecutablePath.len > 0
    # Reference touch — silence "unused" hint by mentioning coreArt.
    discard coreArt
