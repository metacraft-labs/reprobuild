## M9.L.0 verification: from-source Meson (Tier 2b) convention.
##
## Pins the wiring between:
##
##   * the M9.H ``registeredFetchSpec`` registry (fetch: block) → fetch
##     BuildAction emitted by the shared
##     ``conventions/fetch_action.emitFetchAction`` helper;
##   * the M9.I ``registeredBuildFlags`` registry on the ``"meson"``
##     channel (mesonOptions: block) → meson-setup BuildAction's argv;
##   * the per-recipe ``executable <name>:`` declarations → per-artifact
##     stage-copy BuildAction one per declared member.
##
## The test runs against the **real production dbus-broker recipe**
## under ``recipes/packages/source/dbus-broker/`` (vendored tarball)
## and exercises ``recognize`` + ``emitFragment`` end-to-end.
##
## Tool availability (``meson`` / ``ninja`` / ``gcc`` on PATH) is
## intentionally NOT a precondition: the convention emits the action
## graph regardless so the wiring assertions run identically on hosts
## that don't have meson installed. The actual end-to-end build run
## is gated by ``scripts/validate-from-source-meson-dbus-broker.ps1``.

import std/[options, os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/from_source_meson as
  from_source_meson_convention

# Side-effect import: triggers the dbus-broker recipe's package macro
# which registers the fetch spec + meson options + executable artifacts
# under the ``dbusBrokerSource`` key at module init time. The path is
# relative to this test file's location; ``../../..`` lands at the
# reprobuild repo root, and ``recipes/...`` from there.
import "../../../recipes/packages/source/dbus-broker/repro"

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_from_source_meson_convention.nim``
  ## lands at the reprobuild repo root.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  DbusBrokerRecipe =
    ReprobuildRoot / "recipes" / "packages" / "source" / "dbus-broker"

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

suite "from-source-meson convention M9.L.0 — dbus-broker":

  test "convention name is 'from-source-meson'":
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    check conv.name == "from-source-meson"

  test "recognize: positive — dbus-broker source recipe":
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    # Sanity: the production recipe must exist at the expected path —
    # a regression that moves the recipe should fail loudly here, not
    # silently turn the assertion into a no-op.
    check fileExists(DbusBrokerRecipe / "repro.nim")
    # Sanity: the recipe import must have populated the M9.H fetch
    # registry. If this fails, the relative-path import didn't reach
    # the side-effect macro and recognise will return false for the
    # wrong reason.
    let spec = registeredFetchSpec("dbusBrokerSource")
    check spec.url.len > 0
    # No in-tree meson.build at projectRoot — otherwise the existing
    # M39 ``c-cpp-meson`` convention claims it and the from-source
    # variant intentionally yields.
    check not fileExists(extendedPath(DbusBrokerRecipe / "meson.build"))
    let request = dummyRequest(DbusBrokerRecipe)
    check conv.recognize(DbusBrokerRecipe, request)

  test "recognize: negative — projectRoot carries in-tree meson.build":
    # If ``meson.build`` is present at the root, the existing M39
    # ``c-cpp-meson`` convention claims the project; the from-source
    # variant intentionally yields.
    let scratch = getTempDir() /
      "test_from_source_meson_convention_intree_meson_build"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "meson.build",
      "project('intree', 'c')\nexecutable('intree', 'main.c')\n")
    writeFile(scratch / "repro.nim",
      "import repro_project_dsl\n" &
      "package fromSourceMesonIntreePkg:\n" &
      "  fetch:\n" &
      "    url: \"https://example.com/foo.tar.gz\"\n" &
      "    sha256: \"abc\" & repeat(\"0\", 61)\n" &
      "  uses:\n" &
      "    \"meson >=1.3\"\n" &
      "  executable foo:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no fetch: block registered":
    # A recipe with ``uses: meson`` but no fetch spec must NOT be
    # claimed by the from-source variant (no source to fetch).
    let scratch = getTempDir() /
      "test_from_source_meson_convention_no_fetch"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "repro.nim",
      "import repro_project_dsl\n" &
      "package fromSourceMesonNoFetchPkg:\n" &
      "  uses:\n" &
      "    \"meson >=1.3\"\n" &
      "  executable foo:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    # The fetch registry is per-thread; the test recipe is NOT
    # imported (no module-level macro run) so the registry slot stays
    # empty. The recognize gate must reject.
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: produces fetch + setup + compile + install + stage-copy chain":
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    require conv.recognize(DbusBrokerRecipe, request)
    let fragment = conv.emitFragment(DbusBrokerRecipe, request)
    let actions = extractActions(fragment)

    # M9.L.4-refactor Step B: the pipeline emits exactly 6 actions for
    # dbus-broker (fetch + setup + compile + install + 2 stage-copy).
    # The Step-A-era binary-cache publish action retired in Step B —
    # the engine's ``BinaryCachePublisher`` hook now publishes
    # transparently after a successful install / stage-copy edge.
    check actions.len >= 6

    var sawFetch = false
    var sawSetup = false
    var sawCompile = false
    var sawInstall = false
    var sawStageBroker = false
    var sawStageLaunch = false
    var sawPublishEdge = false
    for a in actions:
      if a.id == "ccpp-fetch-dbusBrokerSource":
        sawFetch = true
      elif a.id == "from-source-meson-setup":
        sawSetup = true
      elif a.id == "from-source-meson-compile":
        sawCompile = true
      elif a.id == "from-source-meson-install":
        sawInstall = true
      elif a.id == "from-source-meson-stage-dbusBroker":
        sawStageBroker = true
      elif a.id == "from-source-meson-stage-dbusBrokerLaunch":
        sawStageLaunch = true
      elif a.id == "from-source-meson-publish-dbusBrokerSource":
        sawPublishEdge = true
    check sawFetch
    check sawSetup
    check sawCompile
    check sawInstall
    check sawStageBroker
    check sawStageLaunch
    # Step B: NO publish action emitted. The engine's hook publishes
    # via the passive metadata on the install + stage-copy edges.
    check not sawPublishEdge

  test "emitFragment: setup argv carries meson setup + buildtype + mesonOptions":
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    let fragment = conv.emitFragment(DbusBrokerRecipe, request)
    let actions = extractActions(fragment)
    let setup = findById(actions, "from-source-meson-setup")
    let argvJoined = inlineArgvOf(setup).join(" ")

    # Anchor flags
    check argvJoined.contains("meson")
    check argvJoined.contains("setup")
    check argvJoined.contains("--backend=ninja")

    # M9.I-registered mesonOptions from the dbus-broker recipe — every
    # production flag must round-trip into the setup argv. Order is
    # not asserted here (the in-tree c_cpp_meson tests already pin
    # declaration-order preservation against the same registry); the
    # presence check is sufficient at this layer.
    check argvJoined.contains("-Daudit=false")
    check argvJoined.contains("-Dlauncher=true")
    check argvJoined.contains("-Dlinux-4-17=true")
    check argvJoined.contains("-Dreference-test=false")
    check argvJoined.contains("-Dselinux=false")
    check argvJoined.contains("-Dapparmor=false")
    # Recipe's last mesonOption is ``--buildtype=release`` — the
    # convention also pins ``--buildtype=release`` as an anchor, so
    # the literal must appear regardless.
    check argvJoined.contains("--buildtype=release")

  test "emitFragment: compile depends on setup; install depends on compile":
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    let fragment = conv.emitFragment(DbusBrokerRecipe, request)
    let actions = extractActions(fragment)
    let compile = findById(actions, "from-source-meson-compile")
    let install = findById(actions, "from-source-meson-install")
    check compile.deps == @["from-source-meson-setup"]
    check install.deps == @["from-source-meson-compile"]

  test "emitFragment: stage-copy actions depend on install":
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    let fragment = conv.emitFragment(DbusBrokerRecipe, request)
    let actions = extractActions(fragment)
    let stageBroker = findById(actions,
      "from-source-meson-stage-dbusBroker")
    let stageLaunch = findById(actions,
      "from-source-meson-stage-dbusBrokerLaunch")
    check stageBroker.deps == @["from-source-meson-install"]
    check stageLaunch.deps == @["from-source-meson-install"]

  test "emitFragment: stage-copy output paths land under .repro/output/<member>/":
    # The canonical per-artifact output schema — engine output
    # collection keys off this path shape.
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    let fragment = conv.emitFragment(DbusBrokerRecipe, request)
    let actions = extractActions(fragment)
    let stageBroker = findById(actions,
      "from-source-meson-stage-dbusBroker")
    check stageBroker.outputs.len == 1
    let unified = stageBroker.outputs[0].replace('\\', '/')
    check unified.contains(".repro/output/dbusBroker/dbusBroker")

  test "emitFragment: setup depends on fetch action":
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    let fragment = conv.emitFragment(DbusBrokerRecipe, request)
    let actions = extractActions(fragment)
    let setup = findById(actions, "from-source-meson-setup")
    var sawFetchDep = false
    for dep in setup.deps:
      if dep == "ccpp-fetch-dbusBrokerSource":
        sawFetchDep = true
    check sawFetchDep

  test "emitFragment: install action carries publishToBinaryCache + identity (M9.L.4-refactor Step B)":
    # M9.L.4-refactor Step B: the install action stamps the
    # binary-cache identity tuple on its ``BuildActionDef`` so the
    # engine's ``BinaryCachePublisher`` hook fires after a successful
    # install. The convention no longer emits a publish edge — these
    # passive metadata fields are how the engine learns the action
    # contributes to a cache entry.
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    let fragment = conv.emitFragment(DbusBrokerRecipe, request)
    let actions = extractActions(fragment)
    let install = findById(actions, "from-source-meson-install")
    check install.publishToBinaryCache == true
    check install.cacheEntryIdentity.isSome
    let identity = install.cacheEntryIdentity.get()
    # The identity is keyed on the recipe's ``package <name>:`` header.
    check identity.packageName == "dbusBrokerSource"
    # ``registeredVersions("dbusBrokerSource")`` exposes the version
    # ``"36"`` from the recipe's ``versions:`` block.
    check identity.packageVersion == "36"
    # The toolchain identity name MUST be the convention tag so the
    # canonical encoder distinguishes meson- / cmake- / autotools- /
    # make-built artefacts for the same recipe.
    check identity.toolchain.name == "meson"
    # The provider-revision field must be a BLAKE3-derived hex (the
    # ``from_source_identity.providerRevisionHex`` truncates to 32
    # lowercase hex chars; an empty string would indicate the recipe
    # file couldn't be read which is a real regression).
    check identity.providerRevision.len == 32
    for ch in identity.providerRevision:
      check ch in {'0'..'9', 'a'..'f'}

  test "emitFragment: stage-copy actions carry publishToBinaryCache + identity (M9.L.4-refactor Step B)":
    # M9.L.4-refactor Step B: every stage-copy action also carries the
    # same identity tuple. The engine's hook fires per successful
    # action; each contributing edge advertises the cache entry it
    # belongs to via the passive metadata.
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    let fragment = conv.emitFragment(DbusBrokerRecipe, request)
    let actions = extractActions(fragment)
    let stageBroker = findById(actions,
      "from-source-meson-stage-dbusBroker")
    let stageLaunch = findById(actions,
      "from-source-meson-stage-dbusBrokerLaunch")
    check stageBroker.publishToBinaryCache == true
    check stageBroker.cacheEntryIdentity.isSome
    check stageLaunch.publishToBinaryCache == true
    check stageLaunch.cacheEntryIdentity.isSome
    # The stage-copy identities MUST match the install action's
    # identity byte-for-byte — they all contribute to the same logical
    # cache entry. A regression that recomputed the identity per edge
    # (and accidentally picked up timestamps / RNG / pid) would
    # surface here as mismatched packageName / packageVersion /
    # providerRevision fields.
    let install = findById(actions, "from-source-meson-install")
    let installIdy = install.cacheEntryIdentity.get()
    let stageBrokerIdy = stageBroker.cacheEntryIdentity.get()
    let stageLaunchIdy = stageLaunch.cacheEntryIdentity.get()
    check stageBrokerIdy.packageName == installIdy.packageName
    check stageBrokerIdy.packageVersion == installIdy.packageVersion
    check stageBrokerIdy.toolchain.name == installIdy.toolchain.name
    check stageBrokerIdy.providerRevision == installIdy.providerRevision
    check stageLaunchIdy.packageName == installIdy.packageName
    check stageLaunchIdy.packageVersion == installIdy.packageVersion
    check stageLaunchIdy.toolchain.name == installIdy.toolchain.name
    check stageLaunchIdy.providerRevision == installIdy.providerRevision

  test "emitFragment: identity is stable across calls (M9.L.4-refactor Step B)":
    # M9.L.4-refactor Step B: the cache-entry identity is a pure
    # function of recipe identity. Re-emitting the fragment must yield
    # the same packageName / packageVersion / toolchain.name /
    # providerRevision quadruple; a regression that smuggles a non-
    # deterministic input (timestamp, RNG, pid, ...) would surface here
    # as drifting fields between calls.
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    let fragmentA = conv.emitFragment(DbusBrokerRecipe, request)
    let fragmentB = conv.emitFragment(DbusBrokerRecipe, request)
    let installA = findById(extractActions(fragmentA),
      "from-source-meson-install")
    let installB = findById(extractActions(fragmentB),
      "from-source-meson-install")
    let identA = installA.cacheEntryIdentity.get()
    let identB = installB.cacheEntryIdentity.get()
    check identA.packageName == identB.packageName
    check identA.packageVersion == identB.packageVersion
    check identA.toolchain.name == identB.toolchain.name
    check identA.providerRevision == identB.providerRevision

  test "emitFragment: fetch action's argv carries the recipe's URL + sha256":
    # M9.H/M9.K round-trip: the fetch action's argv must embed the
    # vendored URL and the 64-hex sha256 from the dbus-broker recipe.
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    let fragment = conv.emitFragment(DbusBrokerRecipe, request)
    let actions = extractActions(fragment)
    let fetch = findById(actions, "ccpp-fetch-dbusBrokerSource")
    let argvJoined = inlineArgvOf(fetch).join(" ")
    check argvJoined.contains("dbus-broker-v36.tar.gz")
    check argvJoined.contains(
      "5058a81eea8086636ef09a670d103e35e650a6f0200aadc2f59f3fb6e76c37b8")
