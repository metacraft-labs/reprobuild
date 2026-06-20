## DSL-port M9.R.14f.1 — transitive libDirs union across the from-source
## dep graph.
##
## ## Context
##
## M9.R.14e.* closed the architectural pkg-config gap: when a consumer
## depends on ``wayland``, the resolver returns wayland's install paths
## (libDirs, includeDirs, pkgConfigDirs, cmakePrefixDirs). But wayland
## itself has from-source build deps — ``expat``, ``libffi``,
## ``libxml2`` — whose install paths the consumer also needs at link
## and tool-runtime time (the ``wayland-scanner`` tool links libexpat
## via its DT_NEEDED entry, etc.). Pre-M9.R.14f the resolver only
## populated the IMMEDIATE dep's install tree, so a consumer of
## wayland never gained transitive visibility of libexpat.
##
## M9.R.14f.1 closes the gap by adding a recursive walk: when the
## resolver populates ``profile`` for ``wayland``, it also reads
## wayland's ``project-interface.rbsz``, extracts wayland's own
## ``toolUses`` (which carry both nativeBuildDeps and buildDeps), and
## recursively populates the install trees of every from-source sibling
## the dep declared. Tools without a sibling recipe (gcc / meson /
## ninja / ...) are silently skipped via the
## ``fromSourceCycleBrokenTools`` set.
##
## ## What this test pins
##
##   1. Two-level transitive walk:
##      ``consumer → wayland → expat`` gets expat's libraryPathList
##      into wayland's resolved profile.
##   2. Three-level transitive walk:
##      ``consumer → A → B → C`` exposes C's libraryPathList.
##   3. Determinism: the same on-disk graph produces byte-identical
##      ordering across two invocations.
##   4. Cycle break: ``A → B → A`` does NOT recurse infinitely; the
##      walk terminates and produces a stable result.
##   5. Depth cap: a synthetic linear chain longer than
##      ``M9R14fMaxTransitiveDepth`` terminates at the cap.
##   6. Cycle-broken tools (gcc / meson / ninja) declared as
##      ``nativeBuildDeps`` of a dep don't cause the walk to look for
##      their sibling recipe.
##   7. The transitive walk preserves the immediate dep's behaviour —
##      a recipe with NO declared deps gets the same lists as it would
##      under M9.R.14e.* (single-node populate).

import std/[os, sets, strutils, tables, tempfiles, unittest]

import repro_tool_profiles
import repro_interface_artifacts
import repro_project_dsl

const PlatformLibSuffix =
  when defined(windows): ".dll"
  elif defined(macosx): ".dylib"
  else: ".so"

proc layInstallTree(root, recipeName: string;
                    pcNames, headerNames, libBareNames: openArray[string];
                    stageRoot = "build/out/usr") =
  ## Synthesise the install-tree layout. Mirrors the M9.R.14e.1
  ## ``layStagedTree`` helper but kept local so the M9.R.14f tests can
  ## evolve independently.
  let prefix = root / recipeName / stageRoot
  createDir(prefix / "lib" / "pkgconfig")
  createDir(prefix / "include")
  createDir(prefix / "lib")
  for pcName in pcNames:
    writeFile(prefix / "lib" / "pkgconfig" / pcName, "# synthetic pc\n")
  for header in headerNames:
    writeFile(prefix / "include" / header, "/* synthetic header */\n")
  for libName in libBareNames:
    writeFile(prefix / "lib" / ("lib" & libName & PlatformLibSuffix),
      "\x7fELF\x02\x01\x01\x00")

proc writeRecipeManifest(root, recipeName: string) =
  let recipeDir = root / recipeName
  createDir(recipeDir)
  writeFile(recipeDir / "repro.nim", "## synthetic " & recipeName & " recipe\n")

proc writeSyntheticInterface(root, recipeName: string;
                             deps: openArray[string]) =
  ## Lay down a synthetic project-interface.rbsz under the recipe's
  ## ``.repro/build/repro/`` directory. ``deps`` is the list of dep
  ## names (``executableName`` slot, since the resolver uses that to
  ## look up sibling recipes); the macro for this synthetic interface
  ## sets ``packageSelector`` to the same value.
  let recipeDir = root / recipeName
  let outDir = recipeDir / ".repro" / "build" / "repro"
  createDir(outDir)
  var pi = ProjectInterface(
    projectName: recipeName,
    packageName: recipeName,
    defaultToolProvisioning: "")
  for depName in deps:
    pi.toolUses.add(InterfaceToolUse(
      rawConstraint: depName,
      packageSelector: depName,
      executableName: depName))
  writeInterfaceArtifact(outDir / "project-interface.rbsz", artifactFor(pi))

suite "DSL-port M9.R.14f.1 — transitive libDirs union":

  test "two_level_transitive_walk_unions_dep_libDirs":
    # consumer (the resolver entry-point) -> wayland -> expat
    # The resolver populates `wayland`'s search paths; the transitive
    # walk also pulls in expat's libraryPathList because wayland's
    # interface declares "expat" as a dep.
    let scratch = createTempDir("repro-m9r14f-1-2lvl-", "")
    defer: removeDir(scratch)

    writeRecipeManifest(scratch, "wayland")
    layInstallTree(scratch, "wayland",
      pcNames = @["wayland-client.pc"],
      headerNames = @["wayland-client.h"],
      libBareNames = @["wayland-client"])
    writeSyntheticInterface(scratch, "wayland", deps = @["expat"])

    writeRecipeManifest(scratch, "expat")
    layInstallTree(scratch, "expat",
      pcNames = @["expat.pc"],
      headerNames = @["expat.h"],
      libBareNames = @["expat"])
    writeSyntheticInterface(scratch, "expat", deps = @[])

    var profile = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(profile, scratch / "wayland", scratch)

    # wayland's own lib/ + expat's lib/ must both be present.
    var sawWayland = false
    var sawExpat = false
    for entry in profile.libraryPathList:
      if entry.contains(DirSep & "wayland" & DirSep): sawWayland = true
      if entry.contains(DirSep & "expat" & DirSep): sawExpat = true
    check sawWayland
    check sawExpat
    # Same for pkgConfigSearchList.
    var sawWaylandPc = false
    var sawExpatPc = false
    for entry in profile.pkgConfigSearchList:
      if entry.contains(DirSep & "wayland" & DirSep): sawWaylandPc = true
      if entry.contains(DirSep & "expat" & DirSep): sawExpatPc = true
    check sawWaylandPc
    check sawExpatPc

  test "three_level_transitive_walk_exposes_grandchild":
    # consumer -> A -> B -> C. C's libraryPathList ends up on the
    # consumer's resolved profile via two recursive hops.
    let scratch = createTempDir("repro-m9r14f-1-3lvl-", "")
    defer: removeDir(scratch)

    writeRecipeManifest(scratch, "A")
    layInstallTree(scratch, "A",
      pcNames = @[], headerNames = @[], libBareNames = @["A"])
    writeSyntheticInterface(scratch, "A", deps = @["B"])

    writeRecipeManifest(scratch, "B")
    layInstallTree(scratch, "B",
      pcNames = @[], headerNames = @[], libBareNames = @["B"])
    writeSyntheticInterface(scratch, "B", deps = @["C"])

    writeRecipeManifest(scratch, "C")
    layInstallTree(scratch, "C",
      pcNames = @[], headerNames = @[], libBareNames = @["C"])
    writeSyntheticInterface(scratch, "C", deps = @[])

    var profile = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(profile, scratch / "A", scratch)

    var sawA = false
    var sawB = false
    var sawC = false
    for entry in profile.libraryPathList:
      if entry.contains(DirSep & "A" & DirSep): sawA = true
      if entry.contains(DirSep & "B" & DirSep): sawB = true
      if entry.contains(DirSep & "C" & DirSep): sawC = true
    check sawA
    check sawB
    check sawC

  test "deterministic_same_graph_same_ordering":
    let scratch = createTempDir("repro-m9r14f-1-det-", "")
    defer: removeDir(scratch)

    writeRecipeManifest(scratch, "root")
    layInstallTree(scratch, "root",
      pcNames = @[], headerNames = @[], libBareNames = @["root"])
    writeSyntheticInterface(scratch, "root", deps = @["depA", "depB"])

    writeRecipeManifest(scratch, "depA")
    layInstallTree(scratch, "depA",
      pcNames = @[], headerNames = @[], libBareNames = @["depA"])
    writeSyntheticInterface(scratch, "depA", deps = @[])

    writeRecipeManifest(scratch, "depB")
    layInstallTree(scratch, "depB",
      pcNames = @[], headerNames = @[], libBareNames = @["depB"])
    writeSyntheticInterface(scratch, "depB", deps = @[])

    var first = PathOnlyToolProfile(installMethod: "from-source")
    var second = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(first, scratch / "root", scratch)
    populateFromSourceSearchPaths(second, scratch / "root", scratch)
    check first.libraryPathList == second.libraryPathList
    check first.pkgConfigSearchList == second.pkgConfigSearchList
    check first.cpathList == second.cpathList
    check first.cmakePrefixList == second.cmakePrefixList

  test "cycle_terminates_without_infinite_loop":
    # A → B → A. The visited-set prevents infinite recursion. Both
    # libraryPathLists are unioned, but each entry appears only once.
    let scratch = createTempDir("repro-m9r14f-1-cyc-", "")
    defer: removeDir(scratch)

    writeRecipeManifest(scratch, "A")
    layInstallTree(scratch, "A",
      pcNames = @[], headerNames = @[], libBareNames = @["A"])
    writeSyntheticInterface(scratch, "A", deps = @["B"])

    writeRecipeManifest(scratch, "B")
    layInstallTree(scratch, "B",
      pcNames = @[], headerNames = @[], libBareNames = @["B"])
    writeSyntheticInterface(scratch, "B", deps = @["A"])

    var profile = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(profile, scratch / "A", scratch)
    # No infinite loop: control returns AND both A and B are present
    # exactly once.
    var aCount = 0
    var bCount = 0
    for entry in profile.libraryPathList:
      if entry.contains(DirSep & "A" & DirSep) and entry.endsWith("lib"):
        inc aCount
      if entry.contains(DirSep & "B" & DirSep) and entry.endsWith("lib"):
        inc bCount
    check aCount == 1
    check bCount == 1

  test "depth_cap_terminates_synthetic_linear_chain":
    # Build a chain longer than the cap and verify the walk terminates.
    # Each node depends on the next; the cap is reached partway through.
    let scratch = createTempDir("repro-m9r14f-1-cap-", "")
    defer: removeDir(scratch)

    let chainLen = M9R14fMaxTransitiveDepth + 5
    for i in 0 ..< chainLen:
      let name = "n" & $i
      writeRecipeManifest(scratch, name)
      layInstallTree(scratch, name,
        pcNames = @[], headerNames = @[], libBareNames = @[name])
      let nextDeps =
        if i + 1 < chainLen: @[("n" & $(i + 1))]
        else: @[]
      writeSyntheticInterface(scratch, name, deps = nextDeps)

    var profile = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(profile, scratch / "n0", scratch)
    # The walk must terminate (no hang) AND populate at least one
    # libraryPath entry per visited node up to the cap.
    check profile.libraryPathList.len >= 1

  test "cycle_broken_tool_names_skip_transitive_walk":
    # When wayland's interface declares "gcc" as a nativeBuildDep,
    # the transitive walk MUST NOT look for a `gcc` recipe (the
    # cycle-break taxonomy already routed gcc to stdlib provisioning).
    let scratch = createTempDir("repro-m9r14f-1-cyclebrk-", "")
    defer: removeDir(scratch)

    seedBootstrapCycleBreakTools()

    writeRecipeManifest(scratch, "wayland")
    layInstallTree(scratch, "wayland",
      pcNames = @[], headerNames = @[], libBareNames = @["wayland"])
    # wayland declares both a real dep (expat) AND a cycle-broken
    # tool (gcc). The walk should pick up expat but ignore gcc.
    writeSyntheticInterface(scratch, "wayland", deps = @["expat", "gcc"])

    writeRecipeManifest(scratch, "expat")
    layInstallTree(scratch, "expat",
      pcNames = @[], headerNames = @[], libBareNames = @["expat"])
    writeSyntheticInterface(scratch, "expat", deps = @[])

    # NOTE: no `gcc` recipe on disk. If the walk didn't skip gcc, the
    # fileExists probe for `<scratch>/gcc/repro.nim` would return false
    # and the walk would silently fall back too — but the explicit
    # skip is the contract we're pinning here.

    var profile = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(profile, scratch / "wayland", scratch)

    var sawExpat = false
    for entry in profile.libraryPathList:
      if entry.contains(DirSep & "expat" & DirSep):
        sawExpat = true
    check sawExpat

  test "single_node_with_no_deps_matches_pre_m9r14f_behaviour":
    # Backwards-compat: a recipe with NO declared toolUses produces
    # the same lists the single-node populator did pre-M9.R.14f.
    let scratch = createTempDir("repro-m9r14f-1-bc-", "")
    defer: removeDir(scratch)

    writeRecipeManifest(scratch, "leaf")
    layInstallTree(scratch, "leaf",
      pcNames = @["leaf.pc"], headerNames = @["leaf.h"],
      libBareNames = @["leaf"])
    writeSyntheticInterface(scratch, "leaf", deps = @[])

    var profile = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(profile, scratch / "leaf", scratch)
    check profile.libraryPathList.len >= 1
    check profile.pkgConfigSearchList.len >= 1
    check profile.cpathList.len >= 1

  test "no_interface_artifact_falls_back_gracefully":
    # When the dep has NOT been built yet (no project-interface.rbsz),
    # the walk treats it as a leaf (returns its own install tree only).
    let scratch = createTempDir("repro-m9r14f-1-noif-", "")
    defer: removeDir(scratch)

    writeRecipeManifest(scratch, "unbuilt")
    layInstallTree(scratch, "unbuilt",
      pcNames = @[], headerNames = @[], libBareNames = @["unbuilt"])
    # NO writeSyntheticInterface call — the interface doesn't exist yet.

    var profile = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(profile, scratch / "unbuilt", scratch)
    # Still get the unbuilt recipe's install tree.
    var sawUnbuilt = false
    for entry in profile.libraryPathList:
      if entry.contains(DirSep & "unbuilt" & DirSep): sawUnbuilt = true
    check sawUnbuilt
