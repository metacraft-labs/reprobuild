## M9.L.2 verification: from-source Autotools (Tier 2b) convention.
##
## Pins the wiring between:
##
##   * the M9.H ``registeredFetchSpec`` registry (fetch: block) → fetch
##     BuildAction emitted by the shared
##     ``conventions/fetch_action.emitFetchAction`` helper;
##   * the M9.I ``registeredBuildFlags`` registry on the ``"configure"``
##     channel (configureFlags: block) → configure BuildAction's argv;
##   * the per-recipe ``executable``/``library`` declarations →
##     per-artifact stage-copy BuildAction one per declared member.
##
## The test runs against the **real production expat recipe** under
## ``recipes/packages/source/expat/`` (vendored tarball) and exercises
## ``recognize`` + ``emitFragment`` end-to-end. expat is the first
## autotools-driven recipe in the suite (~493 KB tarball, 1 library
## ``libExpat``, 5 configureFlags — wait, the recipe declares 4
## configureFlags; the brief's "5" is a count typo. The assertions
## below pin the exact 4 production flags.).
##
## Tool availability (``make`` / ``gcc`` on PATH) is intentionally NOT
## a precondition: the convention emits the action graph regardless so
## the wiring assertions run identically on hosts that don't have a C
## toolchain installed. The actual end-to-end build run is gated by
## ``scripts/validate-from-source-autotools-expat.ps1``.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/from_source_autotools as
  from_source_autotools_convention

# Side-effect import: triggers the expat recipe's package macro which
# registers the fetch spec + configure flags + library artifact under
# the ``expatSource`` key at module init time. The path is relative to
# this test file's location; ``../../..`` lands at the reprobuild repo
# root, and ``recipes/...`` from there.
import "../../../recipes/packages/source/expat/repro"

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_from_source_autotools_convention.nim``
  ## lands at the reprobuild repo root.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  ExpatRecipe =
    ReprobuildRoot / "recipes" / "packages" / "source" / "expat"

proc dummyRequest(projectRoot: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "standardProvider.root",
    entryPointBodyHash: "test-body-hash",
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    namespace: "project")

proc inlineArgvOf(action: BuildActionDef): seq[string] =
  for arg in action.call.arguments:
    if arg.name == "argv":
      if arg.encodedValue.len == 0:
        return @[]
      return arg.encodedValue.split("\x1f")
  @[]

proc extractActions(fragment: GraphFragment): seq[BuildActionDef] =
  for node in fragment.nodes:
    if node.kind != gnkAction:
      continue
    result.add(decodeBuildActionPayload(toBytes(node.payload)))

proc findById(actions: seq[BuildActionDef]; id: string): BuildActionDef =
  for a in actions:
    if a.id == id:
      return a
  raise newException(ValueError, "action not found: " & id)

suite "from-source-autotools convention M9.L.2 — expat":

  test "convention name is 'from-source-autotools'":
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    check conv.name == "from-source-autotools"

  test "recognize: positive — expat source recipe":
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    # Sanity: the production recipe must exist at the expected path —
    # a regression that moves the recipe should fail loudly here, not
    # silently turn the assertion into a no-op.
    check fileExists(ExpatRecipe / "repro.nim")
    # Sanity: the recipe import must have populated the M9.H fetch
    # registry. If this fails, the relative-path import didn't reach
    # the side-effect macro and recognise will return false for the
    # wrong reason.
    let spec = registeredFetchSpec("expatSource")
    check spec.url.len > 0
    # Sanity: the configureFlags channel must be non-empty — that's the
    # convention's discriminator. A regression that drops the M9.I
    # configure-channel registration would surface here BEFORE the
    # recognise assertion confuses the diagnosis.
    let configureFlags = registeredBuildFlags("expatSource", "", "configure")
    check configureFlags.len > 0
    # No in-tree configure.ac / Makefile.am at projectRoot — otherwise
    # the existing M17/M28 ``c-cpp-autotools`` convention claims it and
    # the from-source variant intentionally yields.
    check not fileExists(extendedPath(ExpatRecipe / "configure.ac"))
    check not fileExists(extendedPath(ExpatRecipe / "Makefile.am"))
    let request = dummyRequest(ExpatRecipe)
    check conv.recognize(ExpatRecipe, request)

  test "recognize: negative — projectRoot carries in-tree configure.ac":
    # If ``configure.ac`` is present at the root, the existing M17/M28
    # ``c-cpp-autotools`` convention claims the project; the from-source
    # variant intentionally yields.
    let scratch = getTempDir() /
      "test_from_source_autotools_convention_intree_configure_ac"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "configure.ac",
      "AC_INIT([intree], [1.0])\n")
    writeFile(scratch / "Makefile.am",
      "bin_PROGRAMS = foo\nfoo_SOURCES = foo.c\n")
    writeFile(scratch / "repro.nim",
      "import repro_project_dsl\n" &
      "package fromSourceAutotoolsIntreePkg:\n" &
      "  fetch:\n" &
      "    url: \"https://example.com/foo.tar.gz\"\n" &
      "    sha256: \"abc\" & repeat(\"0\", 61)\n" &
      "  uses:\n" &
      "    \"autoconf\"\n" &
      "    \"automake\"\n" &
      "    \"make\"\n" &
      "  configureFlags:\n" &
      "    \"--disable-static\"\n" &
      "  executable foo:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no fetch: block registered":
    # A recipe with ``uses: autoconf`` + a configureFlags: channel but no
    # fetch spec must NOT be claimed by the from-source variant (no
    # source to fetch).
    let scratch = getTempDir() /
      "test_from_source_autotools_convention_no_fetch"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "repro.nim",
      "import repro_project_dsl\n" &
      "package fromSourceAutotoolsNoFetchPkg:\n" &
      "  uses:\n" &
      "    \"autoconf\"\n" &
      "  executable foo:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    # The fetch registry is per-thread; the test recipe is NOT imported
    # (no module-level macro run) so the registry slot stays empty. The
    # recognize gate must reject.
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: produces fetch + configure + build + install + stage-copy + publish chain":
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    require conv.recognize(ExpatRecipe, request)
    let fragment = conv.emitFragment(ExpatRecipe, request)
    let actions = extractActions(fragment)

    # The pipeline emits at least 6 actions: fetch + configure + build
    # + install + 1 stage-copy (one per declared library) +
    # 1 binary-cache publish action (M9.L.4.2).
    check actions.len >= 6

    var sawFetch = false
    var sawConfigure = false
    var sawBuild = false
    var sawInstall = false
    var sawStageLib = false
    var sawPublish = false
    for a in actions:
      if a.id == "ccpp-fetch-expatSource":
        sawFetch = true
      elif a.id == "from-source-autotools-configure":
        sawConfigure = true
      elif a.id == "from-source-autotools-build":
        sawBuild = true
      elif a.id == "from-source-autotools-install":
        sawInstall = true
      elif a.id == "from-source-autotools-stage-libExpat":
        sawStageLib = true
      elif a.id == "from-source-autotools-publish-expatSource":
        sawPublish = true
    check sawFetch
    check sawConfigure
    check sawBuild
    check sawInstall
    check sawStageLib
    check sawPublish

  test "emitFragment: configure argv carries ./configure + --prefix + configureFlags":
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    let fragment = conv.emitFragment(ExpatRecipe, request)
    let actions = extractActions(fragment)
    let configure = findById(actions, "from-source-autotools-configure")
    let argvJoined = inlineArgvOf(configure).join(" ")

    # Anchor flags
    check argvJoined.contains("./configure")
    check argvJoined.contains("--prefix=/usr")

    # M9.I-registered configureFlags from the expat recipe — every
    # production flag must round-trip into the configure argv. Order is
    # not asserted here (the test_expat_source.nim test already pins
    # declaration-order preservation against the same registry); the
    # presence check is sufficient at this layer. The brief mentioned
    # "5 configureFlags" but the recipe declares 4 — we assert the
    # actual 4.
    check argvJoined.contains("--disable-static")
    check argvJoined.contains("--without-docbook")
    check argvJoined.contains("--without-examples")
    check argvJoined.contains("--without-tests")

  test "emitFragment: build depends on configure; install depends on build":
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    let fragment = conv.emitFragment(ExpatRecipe, request)
    let actions = extractActions(fragment)
    let build = findById(actions, "from-source-autotools-build")
    let install = findById(actions, "from-source-autotools-install")
    check build.deps == @["from-source-autotools-configure"]
    check install.deps == @["from-source-autotools-build"]

  test "emitFragment: stage-copy actions depend on install":
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    let fragment = conv.emitFragment(ExpatRecipe, request)
    let actions = extractActions(fragment)
    let stageLib = findById(actions,
      "from-source-autotools-stage-libExpat")
    check stageLib.deps == @["from-source-autotools-install"]

  test "emitFragment: stage-copy output paths land under .repro/output/<member>/":
    # The canonical per-artifact output schema — engine output
    # collection keys off this path shape.
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    let fragment = conv.emitFragment(ExpatRecipe, request)
    let actions = extractActions(fragment)
    let stageLib = findById(actions,
      "from-source-autotools-stage-libExpat")
    check stageLib.outputs.len == 1
    let unified = stageLib.outputs[0].replace('\\', '/')
    check unified.contains(".repro/output/libExpat/")

  test "emitFragment: configure depends on fetch action":
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    let fragment = conv.emitFragment(ExpatRecipe, request)
    let actions = extractActions(fragment)
    let configure = findById(actions, "from-source-autotools-configure")
    var sawFetchDep = false
    for dep in configure.deps:
      if dep == "ccpp-fetch-expatSource":
        sawFetchDep = true
    check sawFetchDep

  test "emitFragment: fetch action's argv carries the recipe's URL + sha256":
    # M9.H/M9.K round-trip: the fetch action's argv must embed the
    # vendored URL and the 64-hex sha256 from the expat recipe.
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    let fragment = conv.emitFragment(ExpatRecipe, request)
    let actions = extractActions(fragment)
    let fetch = findById(actions, "ccpp-fetch-expatSource")
    let argvJoined = inlineArgvOf(fetch).join(" ")
    check argvJoined.contains("expat-2.7.0.tar.xz")
    check argvJoined.contains(
      "25df13dd2819e85fb27a1ce0431772b7047d72af81ae78dc26b4c6e0805f48d1")

  test "emitFragment: build action's argv invokes make":
    # The convention's build step must call ``make`` from the extracted
    # source dir so the autotools-generated Makefile drives compilation.
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    let fragment = conv.emitFragment(ExpatRecipe, request)
    let actions = extractActions(fragment)
    let build = findById(actions, "from-source-autotools-build")
    let argvJoined = inlineArgvOf(build).join(" ")
    check argvJoined.contains("make")

  test "emitFragment: install action's argv invokes make install DESTDIR=<staging>":
    # The install step must call ``make install DESTDIR=<stagingDir>``
    # so the engine collects artifacts from a known location regardless
    # of the recipe's configure-time --prefix.
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    let fragment = conv.emitFragment(ExpatRecipe, request)
    let actions = extractActions(fragment)
    let install = findById(actions, "from-source-autotools-install")
    let argvJoined = inlineArgvOf(install).join(" ")
    check argvJoined.contains("make")
    check argvJoined.contains("install")
    check argvJoined.contains("DESTDIR=")
    let unified = argvJoined.replace('\\', '/')
    check unified.contains("from-source-autotools/staging")

  test "emitFragment: publish action depends on every stage-copy action (M9.L.4.2)":
    # M9.L.4.2 — the binary-cache publish action MUST wait for the install
    # tree to be fully materialised before uploading. Its declared deps
    # must contain every per-artifact stage-copy action's id.
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    let fragment = conv.emitFragment(ExpatRecipe, request)
    let actions = extractActions(fragment)
    let publish = findById(actions,
      "from-source-autotools-publish-expatSource")
    var sawStageLibDep = false
    for dep in publish.deps:
      if dep == "from-source-autotools-stage-libExpat":
        sawStageLibDep = true
    check sawStageLibDep
    # And no stale dep on the install action — that's a transitive
    # dep via the stage-copy actions, NOT a direct one.
    for dep in publish.deps:
      check dep != "from-source-autotools-install"

  test "emitFragment: publish action argv carries publish + 64-hex key + soft-fail wrapper (M9.L.4.2)":
    # M9.L.4.2 — the publish action shells out to the binary-cache CLI
    # via ``sh -c "<cli> publish <hex> <prefix> --package-name=...
    # --package-version=... || true"``. The argv must contain the
    # literal ``publish`` token, a 64-char lowercase hex cache-entry
    # key derived via ``cache_key.deriveCacheEntryKeyHex``, the
    # ``--package-name=expatSource`` identity flag, and the
    # ``|| true`` soft-fail wrapper.
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    let fragment = conv.emitFragment(ExpatRecipe, request)
    let actions = extractActions(fragment)
    let publish = findById(actions,
      "from-source-autotools-publish-expatSource")
    let argv = inlineArgvOf(publish)
    let argvJoined = argv.join(" ")

    # The CLI subcommand literal MUST appear so the action actually
    # publishes (and isn't a no-op).
    check argvJoined.contains("publish")
    # M9.L.4.2 identity-flag wiring — package name MUST be the recipe's
    # ``package <name>:`` header (the same name the M9.H fetch
    # registry is keyed on).
    check argvJoined.contains("--package-name=")
    check argvJoined.contains("expatSource")
    # ``registeredVersions("expatSource")`` registers
    # ``DslVersionInfo(version: "2.7.0", ...)`` via the recipe's
    # ``versions:`` block. The publish argv MUST thread the last
    # version through ``--package-version=``.
    check argvJoined.contains("--package-version=")
    check argvJoined.contains("2.7.0")
    # The ``|| true`` soft-fail wrapper makes the action always exit 0.
    check argvJoined.contains("|| true")
    # The autotools convention's publish prefix is ``<staging>/usr`` —
    # autoconf's default ``--prefix=/usr`` anchor + ``DESTDIR=
    # <staging>`` lays artefacts under ``<staging>/usr/{bin,lib,sbin}/``.
    let argvUnified = argvJoined.replace('\\', '/')
    check argvUnified.contains("from-source-autotools/staging/usr")
    # The cache-entry hex key MUST be the canonical 64-char lowercase
    # BLAKE3 digest. Scan the argv tokens for a 64-hex-char token.
    var sawHex64 = false
    for tok in argvJoined.split({' ', '"'}):
      if tok.len != 64:
        continue
      var allHex = true
      for ch in tok:
        if ch notin {'0'..'9', 'a'..'f'}:
          allHex = false
          break
      if allHex:
        sawHex64 = true
        break
    check sawHex64

  test "emitFragment: publish action's deriveCacheEntryKeyHex output stays stable across calls (M9.L.4.2)":
    # M9.L.4.2 — the cache-entry key is a pure function of the recipe
    # identity tuple. Re-emitting the fragment on the same recipe MUST
    # yield the same hex; a regression that smuggles a non-deterministic
    # input (timestamp, RNG, pid, ...) into the identity would surface
    # here as drifting hexes between calls.
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    let fragmentA = conv.emitFragment(ExpatRecipe, request)
    let fragmentB = conv.emitFragment(ExpatRecipe, request)
    let publishA = findById(extractActions(fragmentA),
      "from-source-autotools-publish-expatSource")
    let publishB = findById(extractActions(fragmentB),
      "from-source-autotools-publish-expatSource")
    check inlineArgvOf(publishA) == inlineArgvOf(publishB)
