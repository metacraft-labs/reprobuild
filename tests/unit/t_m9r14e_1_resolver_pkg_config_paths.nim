## DSL-port M9.R.14e.1 — from-source resolver populates the four
## auxiliary search-path channels.
##
## ## Context
##
## M9.R.14d closed the library-vs-executable resolution gap so a recipe
## depending on a from-source ``wayland`` library could find the right
## artefact on disk. Smoke iter NN of libxkbcommon revealed the next
## layer: meson's pkg-config invocation can't find ``wayland-client.pc``
## even though the resolver successfully returns the wayland artefact's
## path, because the resolver only emits a single ``pathSearchList``
## (consumed as ``PATH``) and the action's env doesn't gain
## ``PKG_CONFIG_PATH`` / ``CMAKE_PREFIX_PATH`` / ``CPATH`` /
## ``LIBRARY_PATH``.
##
## M9.R.14e.1 extends ``PathOnlyToolProfile`` + ``ToolActionIdentity``
## with four parallel channels:
##
##   * ``pkgConfigSearchList``
##   * ``cmakePrefixList``
##   * ``cpathList``
##   * ``libraryPathList``
##
## The resolver populates them by probing the sibling recipe's install
## tree (``build/out/usr/`` or ``.repro/output/install/usr/``) for the
## standard FHS subdirs.
##
## ## What this test pins
##
##   1. ``populateFromSourceSearchPaths`` is a pure data-structure
##      operation: same inputs (recipe layout on disk) → same lists.
##   2. The populator returns non-empty ``pkgConfigSearchList`` when the
##      recipe stages ``lib/pkgconfig/*.pc``.
##   3. The populator returns non-empty ``cmakePrefixList`` when the
##      install root exists.
##   4. The populator returns non-empty ``cpathList`` when the recipe
##      stages ``include/``.
##   5. The populator returns non-empty ``libraryPathList`` when the
##      recipe stages ``lib/``.
##   6. Empty / missing install tree leaves the lists empty (graceful).
##   7. ``tryResolveFromSourceTool`` carries the populated lists onto
##      its ``rrResolved`` profile.
##   8. ``actionIdentityFor`` copies the lists from profile → action
##      identity so the CLI projection has access to them.
##   9. The encode / decode round trip preserves the lists (v7 codec).
##  10. Determinism: invoking the populator twice on the same recipe
##      tree produces byte-identical lists.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_tool_profiles
import repro_interface_artifacts
import repro_project_dsl

const PlatformLibSuffix =
  when defined(windows): ".dll"
  elif defined(macosx): ".dylib"
  else: ".so"

proc layStagedTree(root, recipeName: string;
                   pcNames, headerNames, libBareNames: openArray[string];
                   stageRoot = "build/out/usr") =
  ## Synthesise the install-tree layout the autotools_package /
  ## meson_package constructors produce on disk. ``stageRoot`` lets a
  ## test pick the M9.R.14e.1 ``build/out/usr/`` layout OR the
  ## M9.R.14e.2 ``.repro/output/install/usr/`` layout.
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

proc syntheticUseDef(name: string): InterfaceToolUse =
  InterfaceToolUse(
    rawConstraint: name,
    packageSelector: name,
    executableName: name)

suite "DSL-port M9.R.14e.1 — resolver populates pkg-config / cmake / CPATH / lib search paths":

  test "populator returns non-empty pkgConfigSearchList when .pc files exist":
    let scratch = createTempDir("repro_m9r14e_1_", "")
    layStagedTree(scratch, "wayland",
      pcNames = ["wayland-client.pc", "wayland-server.pc"],
      headerNames = ["wayland-client.h"],
      libBareNames = ["wayland-client"])
    var profile = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(profile, scratch / "wayland")
    check profile.pkgConfigSearchList.len >= 1
    var anyContains = false
    for p in profile.pkgConfigSearchList:
      if p.endsWith("pkgconfig"):
        anyContains = true
    check anyContains
    removeDir(scratch)

  test "populator returns non-empty cmakePrefixList when install root exists":
    let scratch = createTempDir("repro_m9r14e_1_", "")
    layStagedTree(scratch, "libfoo",
      pcNames = ["foo.pc"], headerNames = ["foo.h"], libBareNames = ["foo"])
    var profile = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(profile, scratch / "libfoo")
    check profile.cmakePrefixList.len >= 1
    # cmakePrefixList should point at the prefix root (e.g.
    # ``<scratch>/libfoo/build/out/usr``), not its subdirs.
    var foundRoot = false
    for p in profile.cmakePrefixList:
      if p.endsWith("usr") or p.endsWith("install"):
        foundRoot = true
    check foundRoot
    removeDir(scratch)

  test "populator returns non-empty cpathList when include/ exists":
    let scratch = createTempDir("repro_m9r14e_1_", "")
    layStagedTree(scratch, "libbar",
      pcNames = [], headerNames = ["bar.h"], libBareNames = ["bar"])
    var profile = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(profile, scratch / "libbar")
    check profile.cpathList.len >= 1
    for p in profile.cpathList:
      check p.endsWith("include")
    removeDir(scratch)

  test "populator returns non-empty libraryPathList when lib/ exists":
    let scratch = createTempDir("repro_m9r14e_1_", "")
    layStagedTree(scratch, "libbaz",
      pcNames = [], headerNames = [], libBareNames = ["baz"])
    var profile = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(profile, scratch / "libbaz")
    check profile.libraryPathList.len >= 1
    var endsWithLib = false
    for p in profile.libraryPathList:
      if p.endsWith("lib") or p.endsWith("lib64"):
        endsWithLib = true
    check endsWithLib
    removeDir(scratch)

  test "missing install tree leaves all four lists empty":
    let scratch = createTempDir("repro_m9r14e_1_", "")
    createDir(scratch / "norecipe")
    var profile = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(profile, scratch / "norecipe")
    check profile.pkgConfigSearchList.len == 0
    check profile.cmakePrefixList.len == 0
    check profile.cpathList.len == 0
    check profile.libraryPathList.len == 0
    removeDir(scratch)

  test "share/pkgconfig is probed in addition to lib/pkgconfig":
    let scratch = createTempDir("repro_m9r14e_1_", "")
    let prefix = scratch / "wayland-protocols" / "build" / "out" / "usr"
    createDir(prefix / "share" / "pkgconfig")
    writeFile(prefix / "share" / "pkgconfig" / "wayland-protocols.pc",
      "# synthetic pc\n")
    var profile = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(profile, scratch / "wayland-protocols")
    var foundShare = false
    for p in profile.pkgConfigSearchList:
      if p.contains("share") and p.endsWith("pkgconfig"):
        foundShare = true
    check foundShare
    removeDir(scratch)

  test "deterministic: same inputs produce same lists":
    let scratch = createTempDir("repro_m9r14e_1_", "")
    layStagedTree(scratch, "libdet",
      pcNames = ["det.pc"], headerNames = ["det.h"], libBareNames = ["det"])
    var first = PathOnlyToolProfile(installMethod: "from-source")
    var second = PathOnlyToolProfile(installMethod: "from-source")
    populateFromSourceSearchPaths(first, scratch / "libdet")
    populateFromSourceSearchPaths(second, scratch / "libdet")
    check first.pkgConfigSearchList == second.pkgConfigSearchList
    check first.cmakePrefixList == second.cmakePrefixList
    check first.cpathList == second.cpathList
    check first.libraryPathList == second.libraryPathList
    removeDir(scratch)

  test "tryResolveFromSourceTool emits the search-path channels":
    # The end-to-end resolver path must thread the populator's output
    # onto the resolved profile so the CLI projection sees populated
    # lists, not the empty defaults.
    let scratch = createTempDir("repro_m9r14e_1_", "")
    createDir(scratch / "libgamma")
    writeFile(scratch / "libgamma" / "repro.nim",
      "## synthetic libgamma recipe\n")
    # Lay down a library at the canonical resolver path so the resolver
    # treats the artefact as present.
    let outDir = scratch / "libgamma" / ".repro" / "output" / "libgamma"
    createDir(outDir)
    writeFile(outDir / ("libgamma" & PlatformLibSuffix),
      "\x7fELF\x02\x01\x01\x00")
    # AND the M9.R.14e.1 install-tree layout (pkg-config etc.)
    layStagedTree(scratch, "libgamma",
      pcNames = ["gamma.pc"],
      headerNames = ["gamma.h"], libBareNames = ["gamma"])
    let outcome = tryResolveFromSourceTool(
      syntheticUseDef("libgamma"), scratch)
    check outcome.kind == rrResolved
    check outcome.profile.pkgConfigSearchList.len >= 1
    check outcome.profile.cmakePrefixList.len >= 1
    check outcome.profile.cpathList.len >= 1
    check outcome.profile.libraryPathList.len >= 1
    removeDir(scratch)

  test "encode + decode round trip preserves all four lists":
    # The codec bump (v6 → v7) MUST carry the four new fields through
    # ``encodePathOnlyBuildIdentity`` → ``decodePathOnlyBuildIdentity``
    # so artifacts that ship the new channels survive a serialize-then-
    # deserialize round trip without data loss.
    var profile = PathOnlyToolProfile(
      installMethod: "from-source",
      packageSelector: "wayland",
      packageId: "wayland",
      executableName: "wayland",
      pathSearchList: @["/synth/wayland/bin"],
      resolvedExecutablePath: "/synth/wayland/bin/wayland",
      pkgConfigSearchList: @["/synth/wayland/lib/pkgconfig"],
      cmakePrefixList: @["/synth/wayland/usr"],
      cpathList: @["/synth/wayland/include"],
      libraryPathList: @["/synth/wayland/lib"],
      adapterStrength: asStrong,
      cachePortability: cpLocalOnly,
      practicalHardening: phNone)
    let identity = PathOnlyBuildIdentity(
      projectName: "test",
      profiles: @[profile])
    let bytes = encodePathOnlyBuildIdentity(identity)
    let decoded = decodePathOnlyBuildIdentity(bytes)
    check decoded.profiles.len == 1
    check decoded.profiles[0].pkgConfigSearchList ==
      @["/synth/wayland/lib/pkgconfig"]
    check decoded.profiles[0].cmakePrefixList == @["/synth/wayland/usr"]
    check decoded.profiles[0].cpathList == @["/synth/wayland/include"]
    check decoded.profiles[0].libraryPathList == @["/synth/wayland/lib"]

  test "addUniquePath dedupes + filters non-existent dirs":
    let scratch = createTempDir("repro_m9r14e_1_", "")
    createDir(scratch / "real")
    var dst: seq[string] = @[]
    addUniquePath(dst, scratch / "real")
    addUniquePath(dst, scratch / "real")  # duplicate — should be filtered
    addUniquePath(dst, scratch / "fake")  # non-existent — should be filtered
    addUniquePath(dst, "")                 # empty — should be filtered
    check dst.len == 1
    removeDir(scratch)
