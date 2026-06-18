## M9.L.3 verification: from-source plain-Make / kbuild (Tier 2b)
## convention.
##
## Pins the wiring between:
##
##   * the M9.H ``registeredFetchSpec`` registry (fetch: block) →
##     fetch BuildAction emitted by the shared
##     ``conventions/fetch_action.emitFetchAction`` helper;
##   * the M9.I ``registeredBuildFlags`` registry on the ``"make"``
##     channel (makeFlags: block) → build + install BuildActions'
##     argv;
##   * the per-recipe ``executable`` / ``library`` / ``files``
##     declarations → per-artifact stage-copy BuildAction one per
##     declared member.
##
## The test runs against TWO real production recipes:
##
##   * ``libcapSource`` (``recipes/packages/source/libcap/``) — the
##     straight-install case (``make install
##     DESTDIR=<staging>``). Library member ``libCap`` lands at
##     ``<staging>/usr/lib/libcap.so``; executables ``capsh`` /
##     ``getcap`` / ``setcap`` land at ``<staging>/usr/sbin/``.
##   * ``kernelSource`` (``recipes/packages/source/kernel/``) — the
##     in-source-artefacts case. ``bzImage`` lives at
##     ``<src>/arch/x86/boot/bzImage`` (executable); ``vmlinux`` /
##     ``systemMap`` / ``kernelRelease`` are ``files`` members that
##     live at the source root or under ``include/config/``.
##
## Tool availability (``make`` / ``gcc`` on PATH) is intentionally
## NOT a precondition: the convention emits the action graph
## regardless so the wiring assertions run identically on hosts that
## don't have a C toolchain installed. The actual end-to-end build
## run for libcap is gated by
## ``scripts/validate-from-source-make-libcap.ps1``.

import std/[options, os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/from_source_make as
  from_source_make_convention

# Side-effect imports: trigger each recipe's package macro which
# registers the fetch spec + make flags + artifacts under the
# respective package key at module init time. The paths are relative
# to this test file's location; ``../../..`` lands at the reprobuild
# repo root, and ``recipes/...`` from there.
import "../../../recipes/packages/source/libcap/repro"
import "../../../recipes/packages/source/kernel/repro"

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_from_source_make_convention.nim``
  ## lands at the reprobuild repo root.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  LibcapRecipe =
    ReprobuildRoot / "recipes" / "packages" / "source" / "libcap"
  KernelRecipe =
    ReprobuildRoot / "recipes" / "packages" / "source" / "kernel"

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

# ---------------------------------------------------------------------------
# Sub-suite A: libcap — vanilla ``make install DESTDIR=<staging>``
# ---------------------------------------------------------------------------

suite "from-source-make convention M9.L.3 — libcap":

  test "convention name is 'from-source-make'":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    check conv.name == "from-source-make"

  test "recognize: positive — libcap source recipe":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    # Sanity: the production recipe must exist at the expected path.
    check fileExists(LibcapRecipe / "repro.nim")
    # Sanity: the recipe import must have populated the M9.H fetch
    # registry. If this fails, the relative-path import didn't reach
    # the side-effect macro and recognise will return false for the
    # wrong reason.
    let spec = registeredFetchSpec("libcapSource")
    check spec.url.len > 0
    # Sanity: the makeFlags channel must be non-empty — that's the
    # convention's discriminator.
    let makeFlags = registeredBuildFlags("libcapSource", "", "make")
    check makeFlags.len > 0
    # The libcap recipe must NOT register any configure / meson /
    # cmake flags (otherwise the from-source siblings would claim
    # it).
    check registeredBuildFlags("libcapSource", "", "configure").len == 0
    check registeredBuildFlags("libcapSource", "", "meson").len == 0
    check registeredBuildFlags("libcapSource", "", "cmake").len == 0
    # No in-tree build-system manifest at projectRoot — otherwise the
    # existing in-tree convention claims it.
    check not fileExists(extendedPath(LibcapRecipe / "Makefile.am"))
    check not fileExists(extendedPath(LibcapRecipe / "configure.ac"))
    check not fileExists(extendedPath(LibcapRecipe / "meson.build"))
    check not fileExists(extendedPath(LibcapRecipe / "CMakeLists.txt"))
    let request = dummyRequest(LibcapRecipe)
    check conv.recognize(LibcapRecipe, request)

  test "recognize: returns true even without make on PATH (M9.N)":
    # M9.N architectural correction: recognize must claim a recipe based
    # on DECLARATION (fetch: + make flags channel non-empty + empty
    # configure/meson/cmake channels), NOT host PATH availability. Tool
    # identity is resolved AFTER recognise by the engine — possibly via
    # cache substitute or source build.
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(LibcapRecipe)
    check fileExists(LibcapRecipe / "repro.nim")
    let makeOnPath = findExe("make").len > 0
    checkpoint "make on PATH: " & $makeOnPath
    check conv.recognize(LibcapRecipe, request)

  test "recognize: negative — projectRoot carries in-tree Makefile.am":
    # If ``Makefile.am`` is present at the root, the existing M28
    # ``c-cpp-autotools`` convention claims the project.
    let scratch = getTempDir() /
      "test_from_source_make_convention_intree_makefile_am"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "Makefile.am",
      "bin_PROGRAMS = foo\nfoo_SOURCES = foo.c\n")
    writeFile(scratch / "repro.nim",
      "import repro_project_dsl\n" &
      "package fromSourceMakeIntreeMakefileAmPkg:\n" &
      "  fetch:\n" &
      "    url: \"https://example.com/foo.tar.gz\"\n" &
      "    sha256: \"abc\" & repeat(\"0\", 61)\n" &
      "  uses:\n" &
      "    \"make\"\n" &
      "  makeFlags:\n" &
      "    \"prefix=/usr\"\n" &
      "  executable foo:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no fetch: block registered":
    # A recipe with ``uses: make`` + a makeFlags: channel but no fetch
    # spec must NOT be claimed by the from-source variant.
    let scratch = getTempDir() /
      "test_from_source_make_convention_no_fetch"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "repro.nim",
      "import repro_project_dsl\n" &
      "package fromSourceMakeNoFetchPkg:\n" &
      "  uses:\n" &
      "    \"make\"\n" &
      "  executable foo:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: produces fetch + build + install + stage-copy chain":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(LibcapRecipe)
    require conv.recognize(LibcapRecipe, request)
    let fragment = conv.emitFragment(LibcapRecipe, request)
    let actions = extractActions(fragment)

    # M9.L.4-refactor Step B: the pipeline emits exactly 7 actions for
    # libcap (fetch + build + install + 4 stage-copies). The Step-A-era
    # binary-cache publish action retired in Step B.
    check actions.len >= 7

    var sawFetch = false
    var sawBuild = false
    var sawInstall = false
    var sawStageLib = false
    var sawStageCapsh = false
    var sawStageGetcap = false
    var sawStageSetcap = false
    var sawPublishEdge = false
    for a in actions:
      if a.id == "ccpp-fetch-libcapSource":
        sawFetch = true
      elif a.id == "from-source-make-build":
        sawBuild = true
      elif a.id == "from-source-make-install":
        sawInstall = true
      elif a.id == "from-source-make-stage-libCap":
        sawStageLib = true
      elif a.id == "from-source-make-stage-capsh":
        sawStageCapsh = true
      elif a.id == "from-source-make-stage-getcap":
        sawStageGetcap = true
      elif a.id == "from-source-make-stage-setcap":
        sawStageSetcap = true
      elif a.id == "from-source-make-publish-libcapSource":
        sawPublishEdge = true
    check sawFetch
    check sawBuild
    check sawInstall
    check sawStageLib
    check sawStageCapsh
    check sawStageGetcap
    check sawStageSetcap
    # Step B: NO publish action emitted. The engine's hook publishes
    # via the passive metadata on the install + stage-copy edges.
    check not sawPublishEdge

  test "emitFragment: build argv carries make + every makeFlag":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(LibcapRecipe)
    let fragment = conv.emitFragment(LibcapRecipe, request)
    let actions = extractActions(fragment)
    let build = findById(actions, "from-source-make-build")
    let argvJoined = inlineArgvOf(build).join(" ")
    check argvJoined.contains("make")
    # Every production makeFlag must round-trip into the build argv.
    check argvJoined.contains("BUILD_CC=gcc")
    check argvJoined.contains("RAISE_SETFCAP=no")
    check argvJoined.contains("lib=lib")
    check argvJoined.contains("prefix=/usr")
    check argvJoined.contains("GOLANG=no")

  test "emitFragment: install argv carries make install DESTDIR=<staging>":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(LibcapRecipe)
    let fragment = conv.emitFragment(LibcapRecipe, request)
    let actions = extractActions(fragment)
    let install = findById(actions, "from-source-make-install")
    let argvJoined = inlineArgvOf(install).join(" ")
    check argvJoined.contains("make")
    check argvJoined.contains("install")
    check argvJoined.contains("DESTDIR=")
    let unified = argvJoined.replace('\\', '/')
    check unified.contains("from-source-make/staging")

  test "emitFragment: dep chain fetch → build → install → stage":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(LibcapRecipe)
    let fragment = conv.emitFragment(LibcapRecipe, request)
    let actions = extractActions(fragment)
    let build = findById(actions, "from-source-make-build")
    let install = findById(actions, "from-source-make-install")
    let stageLib = findById(actions, "from-source-make-stage-libCap")
    var sawFetchDep = false
    for dep in build.deps:
      if dep == "ccpp-fetch-libcapSource":
        sawFetchDep = true
    check sawFetchDep
    check install.deps == @["from-source-make-build"]
    check stageLib.deps == @["from-source-make-install"]

  test "emitFragment: stage-copy output paths land under .repro/output/<member>/":
    # The canonical per-artifact output schema — engine output
    # collection keys off this path shape.
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(LibcapRecipe)
    let fragment = conv.emitFragment(LibcapRecipe, request)
    let actions = extractActions(fragment)
    let stageLib = findById(actions, "from-source-make-stage-libCap")
    check stageLib.outputs.len == 1
    let libUnified = stageLib.outputs[0].replace('\\', '/')
    check libUnified.contains(".repro/output/libCap/")
    let stageCapsh = findById(actions, "from-source-make-stage-capsh")
    check stageCapsh.outputs.len == 1
    let capshUnified = stageCapsh.outputs[0].replace('\\', '/')
    check capshUnified.contains(".repro/output/capsh/")

  test "emitFragment: install action carries publishToBinaryCache + identity (M9.L.4-refactor Step B)":
    # M9.L.4-refactor Step B: the install action stamps the
    # binary-cache identity tuple on its ``BuildActionDef`` so the
    # engine's ``BinaryCachePublisher`` hook fires after a successful
    # install. The convention no longer emits a publish edge.
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(LibcapRecipe)
    let fragment = conv.emitFragment(LibcapRecipe, request)
    let actions = extractActions(fragment)
    let install = findById(actions, "from-source-make-install")
    check install.publishToBinaryCache == true
    check install.cacheEntryIdentity.isSome
    let identity = install.cacheEntryIdentity.get()
    # The identity is keyed on the recipe's ``package <name>:`` header.
    check identity.packageName == "libcapSource"
    # ``registeredVersions("libcapSource")`` exposes the version
    # ``"2.71"`` from the recipe's ``versions:`` block.
    check identity.packageVersion == "2.71"
    # The toolchain identity name MUST be the convention tag so the
    # canonical encoder distinguishes meson- / cmake- / autotools- /
    # make-built artefacts for the same recipe.
    check identity.toolchain.name == "make"
    # The provider-revision field must be a BLAKE3-derived hex (32
    # lowercase hex chars from ``providerRevisionHex``).
    check identity.providerRevision.len == 32
    for ch in identity.providerRevision:
      check ch in {'0'..'9', 'a'..'f'}

  test "emitFragment: stage-copy actions carry publishToBinaryCache + identity (M9.L.4-refactor Step B)":
    # M9.L.4-refactor Step B: every stage-copy action also carries the
    # same identity tuple. The engine's hook fires per successful
    # action; each contributing edge advertises the cache entry it
    # belongs to via the passive metadata. libcap emits 4 stage-copy
    # actions (libCap + capsh + getcap + setcap); we verify the
    # library + one executable here.
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(LibcapRecipe)
    let fragment = conv.emitFragment(LibcapRecipe, request)
    let actions = extractActions(fragment)
    let stageLib = findById(actions, "from-source-make-stage-libCap")
    let stageCapsh = findById(actions, "from-source-make-stage-capsh")
    check stageLib.publishToBinaryCache == true
    check stageLib.cacheEntryIdentity.isSome
    check stageCapsh.publishToBinaryCache == true
    check stageCapsh.cacheEntryIdentity.isSome
    # The stage-copy identities MUST match the install action's
    # identity byte-for-byte — they contribute to the same logical
    # cache entry.
    let install = findById(actions, "from-source-make-install")
    let installIdy = install.cacheEntryIdentity.get()
    let stageLibIdy = stageLib.cacheEntryIdentity.get()
    let stageCapshIdy = stageCapsh.cacheEntryIdentity.get()
    check stageLibIdy.packageName == installIdy.packageName
    check stageLibIdy.packageVersion == installIdy.packageVersion
    check stageLibIdy.toolchain.name == installIdy.toolchain.name
    check stageLibIdy.providerRevision == installIdy.providerRevision
    check stageCapshIdy.packageName == installIdy.packageName
    check stageCapshIdy.packageVersion == installIdy.packageVersion
    check stageCapshIdy.toolchain.name == installIdy.toolchain.name
    check stageCapshIdy.providerRevision == installIdy.providerRevision

  test "emitFragment: identity is stable across calls (M9.L.4-refactor Step B)":
    # M9.L.4-refactor Step B: the cache-entry identity is a pure
    # function of recipe identity. Re-emitting the fragment must yield
    # the same packageName / packageVersion / toolchain.name /
    # providerRevision quadruple.
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(LibcapRecipe)
    let fragmentA = conv.emitFragment(LibcapRecipe, request)
    let fragmentB = conv.emitFragment(LibcapRecipe, request)
    let installA = findById(extractActions(fragmentA),
      "from-source-make-install")
    let installB = findById(extractActions(fragmentB),
      "from-source-make-install")
    let identA = installA.cacheEntryIdentity.get()
    let identB = installB.cacheEntryIdentity.get()
    check identA.packageName == identB.packageName
    check identA.packageVersion == identB.packageVersion
    check identA.toolchain.name == identB.toolchain.name
    check identA.providerRevision == identB.providerRevision

# ---------------------------------------------------------------------------
# Sub-suite B: kernel — in-source artefacts (kbuild)
# ---------------------------------------------------------------------------

suite "from-source-make convention M9.L.3 — kernel":

  test "recognize: positive — kernel source recipe":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    check fileExists(KernelRecipe / "repro.nim")
    let spec = registeredFetchSpec("kernelSource")
    check spec.url.len > 0
    let makeFlags = registeredBuildFlags("kernelSource", "", "make")
    check makeFlags.len > 0
    let request = dummyRequest(KernelRecipe)
    check conv.recognize(KernelRecipe, request)

  test "emitFragment: produces fetch + build + install + 4 stage-copies":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(KernelRecipe)
    let fragment = conv.emitFragment(KernelRecipe, request)
    let actions = extractActions(fragment)

    # The kernel recipe declares 1 executable (bzImage) + 3 files
    # (vmlinux / systemMap / kernelRelease), so 7 actions total.
    check actions.len >= 7

    var sawFetch = false
    var sawBuild = false
    var sawInstall = false
    var sawStageBzImage = false
    var sawStageVmlinux = false
    var sawStageSystemMap = false
    var sawStageKernelRelease = false
    for a in actions:
      if a.id == "ccpp-fetch-kernelSource":
        sawFetch = true
      elif a.id == "from-source-make-build":
        sawBuild = true
      elif a.id == "from-source-make-install":
        sawInstall = true
      elif a.id == "from-source-make-stage-bzImage":
        sawStageBzImage = true
      elif a.id == "from-source-make-stage-vmlinux":
        sawStageVmlinux = true
      elif a.id == "from-source-make-stage-systemMap":
        sawStageSystemMap = true
      elif a.id == "from-source-make-stage-kernelRelease":
        sawStageKernelRelease = true
    check sawFetch
    check sawBuild
    check sawInstall
    check sawStageBzImage
    check sawStageVmlinux
    check sawStageSystemMap
    check sawStageKernelRelease

  test "emitFragment: build argv carries every kernel makeFlag in order":
    # The kbuild ``makeFlags:`` block pins ``ARCH=x86_64`` at the head
    # (kbuild Makefile selection) and ``-j1`` at the tail (job count).
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(KernelRecipe)
    let fragment = conv.emitFragment(KernelRecipe, request)
    let actions = extractActions(fragment)
    let build = findById(actions, "from-source-make-build")
    let argvJoined = inlineArgvOf(build).join(" ")
    check argvJoined.contains("ARCH=x86_64")
    check argvJoined.contains("LOCALVERSION=")
    check argvJoined.contains("KBUILD_BUILD_USER=reprobuild")
    check argvJoined.contains("KBUILD_BUILD_HOST=reprobuild")
    check argvJoined.contains("KBUILD_BUILD_TIMESTAMP=@1577836800")
    check argvJoined.contains("-j1")

  test "emitFragment: bzImage stage-copy probes arch/x86/boot/bzImage":
    # The kernel-specific in-source path probe — the bzImage stage-copy
    # script must check ``<src>/arch/x86/boot/bzImage`` first before
    # falling back to staging-dir candidates.
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(KernelRecipe)
    let fragment = conv.emitFragment(KernelRecipe, request)
    let actions = extractActions(fragment)
    let stage = findById(actions, "from-source-make-stage-bzImage")
    let argvJoined = inlineArgvOf(stage).join(" ")
    let unified = argvJoined.replace('\\', '/')
    check unified.contains("arch/x86/boot/bzImage")

  test "emitFragment: vmlinux stage-copy probes <src>/vmlinux":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(KernelRecipe)
    let fragment = conv.emitFragment(KernelRecipe, request)
    let actions = extractActions(fragment)
    let stage = findById(actions, "from-source-make-stage-vmlinux")
    let argvJoined = inlineArgvOf(stage).join(" ")
    let unified = argvJoined.replace('\\', '/')
    # The src-relative probe path must appear in the script.
    check unified.contains("/src/vmlinux")

  test "emitFragment: systemMap stage-copy probes <src>/System.map":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(KernelRecipe)
    let fragment = conv.emitFragment(KernelRecipe, request)
    let actions = extractActions(fragment)
    let stage = findById(actions, "from-source-make-stage-systemMap")
    let argvJoined = inlineArgvOf(stage).join(" ")
    let unified = argvJoined.replace('\\', '/')
    check unified.contains("System.map")

  test "emitFragment: kernelRelease stage-copy probes include/config/kernel.release":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(KernelRecipe)
    let fragment = conv.emitFragment(KernelRecipe, request)
    let actions = extractActions(fragment)
    let stage = findById(actions, "from-source-make-stage-kernelRelease")
    let argvJoined = inlineArgvOf(stage).join(" ")
    let unified = argvJoined.replace('\\', '/')
    check unified.contains("include/config/kernel.release")

  test "emitFragment: kernel stage-copies output under .repro/output/<member>/":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(KernelRecipe)
    let fragment = conv.emitFragment(KernelRecipe, request)
    let actions = extractActions(fragment)
    let stageBz = findById(actions, "from-source-make-stage-bzImage")
    check stageBz.outputs.len == 1
    let bzUnified = stageBz.outputs[0].replace('\\', '/')
    check bzUnified.contains(".repro/output/bzImage/")
    let stageVm = findById(actions, "from-source-make-stage-vmlinux")
    let vmUnified = stageVm.outputs[0].replace('\\', '/')
    check vmUnified.contains(".repro/output/vmlinux/")

  test "emitFragment: fetch action's argv carries the kernel tarball URL + sha256":
    # M9.H/M9.K round-trip — the fetch action's argv embeds the
    # cdn.kernel.org URL and the 64-hex sha256 from the kernel recipe.
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(KernelRecipe)
    let fragment = conv.emitFragment(KernelRecipe, request)
    let actions = extractActions(fragment)
    let fetch = findById(actions, "ccpp-fetch-kernelSource")
    let argvJoined = inlineArgvOf(fetch).join(" ")
    check argvJoined.contains("linux-6.6.142.tar.xz")
    check argvJoined.contains(
      "b2f6607a75cd27b2e368cf2d25e1637e1e0da9dfed4cda536658879eee6f2b70")

  test "emitFragment: build actions carry toolIdentityRefs (M9.N Batch B)":
    # M9.N Batch B: every emitted action stamps the list of ``uses:``
    # tools it invokes so the engine resolves them at fork time.
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(KernelRecipe)
    let fragment = conv.emitFragment(KernelRecipe, request)
    let actions = extractActions(fragment)
    let build = findById(actions, "from-source-make-build")
    check "make" in build.toolIdentityRefs
    check "gcc" in build.toolIdentityRefs
    check "sh" in build.toolIdentityRefs
    let install = findById(actions, "from-source-make-install")
    check "make" in install.toolIdentityRefs
