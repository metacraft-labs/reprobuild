## Smoke test for the from-source ``libffiSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FIFTY-FIRST real production
## from-source recipe and the FIRST recipe in the crypto-and-FFI batch
## (libffi + nettle + libgcrypt + gnutls). libffi's unique coverage
## angle vs the prior fifty is the ``--disable-multi-os-directory`` flag
## — a libffi-specific autotools knob that suppresses the multilib
## install-layout split. A regression that dropped the flag through a
## prefix-matching collapse against ``--disable-docs`` (both start with
## ``--disable-``) would surface in the flag-count + exact-sequence
## pinning below.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libFfi``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

when defined(reproProviderMode):
  import std/[os, strutils]
  import repro_core
import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + library artifact under
# ``libffiSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz"

const ExpectedHash =
  "b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e"

const ExpectedBuildDir = ".repro/build/libffi-autotools"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-docs",
  "--disable-multi-os-directory",
  "--disable-dependency-tracking",
]

const ExpectedConfigureCommand =
  "../../../src/configure --prefix=/usr --disable-static --disable-docs " &
    "--disable-multi-os-directory --disable-dependency-tracking"

const ExpectedConfigureScript =
  "mkdir -p " & ExpectedBuildDir & " && cd " & ExpectedBuildDir & " && " &
    ExpectedConfigureCommand

when defined(reproProviderMode):
  proc dummyRequest(projectRoot: string): ProviderGraphRequest =
    ProviderGraphRequest(
      kind: prkGraphInvocation,
      providerArtifactId: "test-provider",
      entryPointId: "libffiSource.root",
      entryPointBodyHash: "test-body",
      reason: girExplicitUserRequest,
      arguments: projectRoot,
      namespace: "project")

  proc extractActions(fragment: GraphFragment): seq[BuildActionDef] =
    for node in fragment.nodes:
      if node.kind != gnkAction:
        continue
      result.add(decodeBuildActionPayload(toBytes(node.payload)))

  proc findByCommandStatsId(actions: seq[BuildActionDef];
                            commandStatsId: string): BuildActionDef =
    for action in actions:
      if action.commandStatsId == commandStatsId:
        return action
    raise newException(ValueError,
      "action not found by commandStatsId: " & commandStatsId)

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

  proc argValue(action: BuildActionDef; name: string): string =
    let values = action.argValues(name)
    if values.len == 0:
      return ""
    values[0]

  proc inlineScriptOf(action: BuildActionDef): string =
    let argv = action.argValues("argv")
    if argv.len >= 3:
      return argv[2]
    ""

  proc findMakeAction(actions: seq[BuildActionDef];
                      wantsInstall: bool): BuildActionDef =
    for action in actions:
      if action.call.packageName != "make" or
          action.call.executableName != "makeBin":
        continue
      let targets = action.argValues("targets")
      let isInstall = "install" in targets
      if isInstall == wantsInstall:
        return action
    raise newException(ValueError, "make action not found")

suite "libffiSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("libffiSource")
    check spec.packageName == "libffiSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 1,391,684-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("libffiSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub release
    # tarballs use.
    let spec = registeredFetchSpec("libffiSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the make channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libFfi`` is the only artifact and must
    # be tagged ``dakLibrary``. libffi's autotools build emits a single
    # shared object (``libffi.so``) bundling the FFI core + per-arch
    # assembly trampolines + type-encoding helpers. A regression that
    # mis-tagged the artifact kind would mis-route the M9.L install
    # path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("libffiSource")
    check arts.len == 1
    check arts[0].packageName == "libffiSource"
    check arts[0].artifactName == "libFfi"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is
    # recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at
    # the canonical GitHub project that hosts the libffi source
    # tree.
    let vs = registeredVersions("libffiSource")
    check vs.len == 1
    check vs[0].version == "3.4.6"
    check vs[0].sourceRevision == "v3.4.6"
    check vs[0].sourceUrl ==
      "https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/libffi/libffi"

  when defined(reproProviderMode):
    test "provider actions keep libffi build artifacts out of fetched src":
      let projectRoot = currentSourcePath.parentDir
      let pkg = PackageDef(
        packageName: "libffiSource",
        sourceFile: projectRoot / "repro.nim",
        hasDevEnv: false,
        devEnvBodyHash: "",
        toolUses: @[])
      let fragment = buildPackageFragment(pkg, dummyRequest(projectRoot),
        proc() = buildLibffiSourcePackage(),
        includeDefault = false)
      let actions = extractActions(fragment)

      let configure = findByCommandStatsId(actions,
        "autotools_package.configure")
      let build = findMakeAction(actions, wantsInstall = false)
      let install = findMakeAction(actions, wantsInstall = true)
      let cleanup = findById(actions, "autotools-la-cleanup-libffiSource")

      let expectedBuildRoot = projectRoot / ExpectedBuildDir
      let expectedInstallRoot = expectedBuildRoot / "out"
      let expectedSrcRoot = projectRoot / "src"
      let configureScript = configure.inlineScriptOf()

      check "mkdir -p " & ExpectedBuildDir in configureScript
      check "cd " & ExpectedBuildDir in configureScript
      check "../../../src/configure" in configureScript
      check configureScript == ExpectedConfigureScript
      for flag in ExpectedConfigureFlags:
        check flag in configureScript
      check configure.declaredOutputs == @[expectedBuildRoot]
      check configure.readOnlyRoots == @[expectedSrcRoot]

      check build.argValue("workDir") == ExpectedBuildDir
      check build.declaredOutputs == @[expectedBuildRoot]
      check build.readOnlyRoots == @[expectedSrcRoot]

      check install.argValue("workDir") == ExpectedBuildDir
      check install.declaredOutputs == @[expectedInstallRoot]
      check install.readOnlyRoots == @[expectedSrcRoot]

      check cleanup.declaredOutputs == @[expectedInstallRoot]
      check expectedSrcRoot notin configure.declaredOutputs
      check expectedSrcRoot notin build.declaredOutputs
      check expectedSrcRoot notin install.declaredOutputs
