## Smoke test for the from-source ``glib2Source`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FIFTEENTH real production
## from-source recipe. glib2's unique coverage angle vs the prior
## fourteen is the FOUR-LIBRARY single-package shape: glib2 emits FOUR
## shared objects from one meson build tree (``libglib-2.0.so`` +
## ``libgobject-2.0.so`` + ``libgio-2.0.so`` + ``libgmodule-2.0.so``)
## all sharing the same SONAME prefix but shipping distinct ABIs. This
## is the third multi-library single-package shape (Wayland was the
## first with two libraries, pango was the second with two libraries),
## and the FIRST to ship four artifacts under one ``package`` macro.
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (cmake + configure channels MUST be empty).
##   * FOUR library artifact registration (M3) — ``libGlib2`` +
##     ``libGObject`` + ``libGio`` + ``libGModule`` all tagged
##     ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[strutils, unittest]

when defined(reproProviderMode):
  import std/os
  import repro_core
import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + four library artifacts under
# ``glib2Source`` at module init time.
import ./repro

const ExpectedUrl =
  "https://download.gnome.org/sources/glib/2.82/glib-2.82.5.tar.xz"

const ExpectedHash =
  "05c2031f9bdf6b5aba7a06ca84f0b4aced28b19bf1b50c6ab25cc675277cbc3f"

const ExpectedMesonConfigureOptions = @[
  # ``meson_package`` prepends ``libdir=lib`` whenever the recipe does
  # not pin a libdir of its own, so the package result and the install
  # mirror both expose libraries from ``usr/lib`` regardless of Meson's
  # host-dependent ``lib/<multiarch>`` default.
  "libdir=lib",
  "tests=false",
  "documentation=false",
  "man-pages=disabled",
  "introspection=disabled",
  "nls=disabled",
  "xattr=false",
  "sysprof=disabled",
]

## ``wrap_mode`` is a Meson built-in and rides the typed ``wrapMode``
## flag, not the project options seq.
const ExpectedMesonWrapMode = "nofallback"

proc argByName(action: BuildActionDef; name: string): PublicCliArg =
  for arg in action.call.arguments:
    if arg.name == name:
      return arg
  raise newException(ValueError, "no argument named '" & name & "'")

proc encodedValues(arg: PublicCliArg): seq[string] =
  if arg.encodedValue.len == 0:
    return @[]
  arg.encodedValue.split("\x1f")

proc findMesonSetupAction(): BuildActionDef =
  for action in registeredBuildActions():
    if action.call.packageName == "meson" and
        action.call.executableName == "mesonBin" and
        action.call.subcommand == "setup":
      return action
  raise newException(ValueError, "meson setup action not found")

when defined(reproProviderMode):
  proc dummyRequest(projectRoot: string): ProviderGraphRequest =
    ProviderGraphRequest(
      kind: prkGraphInvocation,
      providerArtifactId: "test-provider",
      entryPointId: "glib2Source.root",
      entryPointBodyHash: "test-body",
      reason: girExplicitUserRequest,
      arguments: projectRoot,
      namespace: "project")

  proc extractActions(fragment: GraphFragment): seq[BuildActionDef] =
    for node in fragment.nodes:
      if node.kind != gnkAction:
        continue
      result.add(decodeBuildActionPayload(toBytes(node.payload)))

  proc findById(actions: seq[BuildActionDef]; id: string): BuildActionDef =
    for action in actions:
      if action.id == id:
        return action
    raise newException(ValueError, "action not found: " & id)

  proc argValues(action: BuildActionDef; name: string): seq[string] =
    for arg in action.call.arguments:
      if arg.name == name:
        if arg.encodedValue.len == 0:
          return @[]
        return arg.encodedValue.split("\x1f")
    @[]

  proc inlineScriptOf(action: BuildActionDef): string =
    let argv = action.argValues("argv")
    if argv.len >= 3:
      return argv[2]
    ""

suite "glib2Source — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("glib2Source")
    check spec.packageName == "glib2Source"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 5,554,704-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("glib2Source")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream gnome.org release
    # tarballs use.
    let spec = registeredFetchSpec("glib2Source")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    resetBuildActionRegistry()
    buildGlib2SourcePackage()
    let setupAction = findMesonSetupAction()
    check setupAction.argByName("options").encodedValues() ==
      ExpectedMesonConfigureOptions
  test "mesonOptions does not leak into the cmake channel":
    resetBuildActionRegistry()
    buildGlib2SourcePackage()
    for action in registeredBuildActions():
      check action.call.packageName != "cmake"
  test "mesonOptions does not leak into the configure channel":
    resetBuildActionRegistry()
    buildGlib2SourcePackage()
    for action in registeredBuildActions():
      check action.call.packageName != "autotools"

  test "meson setup forbids fallback subproject writes under fetched src":
    resetBuildActionRegistry()
    buildGlib2SourcePackage()
    let setupAction = findMesonSetupAction()
    let opts = setupAction.argByName("options").encodedValues()
    check setupAction.argByName("wrapMode").encodedValues() ==
      @[ExpectedMesonWrapMode]
    check "wrap_mode=nofallback" notin opts
    check "sysprof=disabled" in opts
    check setupAction.readOnlyRoots == @["./src"]
    check "./src" notin setupAction.declaredOutputs

  test "native build deps include pkg-config for meson dependency probes":
    let native = registeredNativeBuildDeps("glib2Source")
    let deps = registeredBuildDeps("glib2Source")
    check "pkg-config" in native
    check "pcre2 >=10.34" notin native
    check "pcre2 >=10.34" in deps

  test "artifacts register four libraries":
    # M3 artifact registry: FOUR libraries are registered, each
    # tagged ``dakLibrary``. glib2's meson build emits four shared
    # objects from one build tree (``libglib-2.0.so`` +
    # ``libgobject-2.0.so`` + ``libgio-2.0.so`` +
    # ``libgmodule-2.0.so``). A regression that collapsed multi-
    # library packages or dropped one of the four would surface in
    # the artifact-count + per-artifact name pinning below.
    let arts = registeredArtifacts("glib2Source")
    check arts.len == 4
    var seenGlib2 = false
    var seenGObject = false
    var seenGio = false
    var seenGModule = false
    for art in arts:
      check art.packageName == "glib2Source"
      check art.kind == dakLibrary
      case art.artifactName
      of "libGlib2":
        seenGlib2 = true
      of "libGObject":
        seenGObject = true
      of "libGio":
        seenGio = true
      of "libGModule":
        seenGModule = true
      else:
        discard
    check seenGlib2
    check seenGObject
    check seenGio
    check seenGModule

  when defined(reproProviderMode):
    test "stage-copy probes lib64 letters-only SONAME for libGlib2":
      let projectRoot = currentSourcePath.parentDir
      let pkg = PackageDef(
        packageName: "glib2Source",
        sourceFile: projectRoot / "repro.nim",
        hasDevEnv: false,
        devEnvBodyHash: "",
        toolUses: @[])
      let fragment = buildPackageFragment(pkg, dummyRequest(projectRoot),
        proc() = buildGlib2SourcePackage(),
        includeDefault = false)
      let actions = extractActions(fragment)
      let stage = findById(actions,
        "autotools-stage-library-glib2Source-libGlib2")
      let script = stage.inlineScriptOf()
      let usrLib = (projectRoot / "build" / "out" / "usr" / "lib").
        replace("\\", "/")
      let usrLib64 = (projectRoot / "build" / "out" / "usr" / "lib64").
        replace("\\", "/")
      let outputPath = projectRoot / ".repro" / "output" / "libGlib2" /
        "libGlib2"

      check stage.commandStatsId == "autotools_package.stage.library"
      check stage.outputs == @[outputPath]
      check usrLib & "/libglib\"-*.so" in script
      check usrLib64 & "/libglib\"-*.so" in script
      check "no library candidate for libGlib2" in script

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.gnome.org release
    # tag is recorded for ``repro update-source`` even though the
    # live fetch points at the vendored copy. The repository points
    # at the canonical GNOME gitlab project that hosts the glib
    # source tree.
    let vs = registeredVersions("glib2Source")
    check vs.len == 1
    check vs[0].version == "2.82.5"
    check vs[0].sourceRevision == "2.82.5"
    check vs[0].sourceUrl ==
      "https://download.gnome.org/sources/glib/2.82/glib-2.82.5.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.gnome.org/GNOME/glib"
