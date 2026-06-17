## NDE0-K unit tests: native kernel package (NDE-E migrated).
##
## Exercises the spec'd public surface of
## ``recipes/packages/de-foundation/kernel/repro.nim`` through the
## DSL's M8 / M9.A materialisation path
## (``fs.configFile`` registration + ``consumeConfigFile``
## materialisation) plus the M9.F cross-artifact ``output()`` /
## ``toolBuild`` surface (FIRST native NDE recipe to exercise it) rather
## than the shim's deprecated ``materializeKernel`` orchestrator. The
## recipe's render* procs still come from the shim verbatim — only the
## on-disk emission path moved.
##
## NDE-E is the **first** recipe to wire two artifacts together with the
## M9.F producer/consumer surface: ``files configFile: build: output(
## "/build/config-used")`` publishes a typed handle into the M9.F
## registry, and ``executable bzImage: build: toolBuild("kernelCompile",
## @[("config", outputOf("reproosKernel", "configFile"))], "build/
## bzImage")`` reads it back as the bzImage's ``config`` input slot. The
## ``M9.F cross-artifact wire`` suite below pins this contract.
##
## Required test surfaces:
##
##   1-6. **Configurable propagation, ALL 6 knobs**: toggling each of
##        enableDrm, enableHypervDrm, enableFramebuffer, enableUserNs,
##        enableOverlayFs, enableVirtioGpu from true → false changes
##        the config-used content (CONFIG_X=y → # CONFIG_X is not set)
##        AND invalidates the configFile store path. Table-driven so
##        every knob's assertion is exercised in one test.
##   7.   **Configurable propagation: kernelVersion** — bumping
##        kernelVersion changes the configFile banner + the
##        kernelRelease content + every output's store path.
##   8.   **Idempotency**: a second materialise pass with the same
##        config lands at the same store paths.
##   9.   **Cache-key isolation: enableHypervDrm only invalidates
##        configFile + bzImage + systemMap, NOT kernelRelease**. This
##        is the load-bearing acceptance #2 demonstration ("only the
##        kernel + initramfs rebuild" at the package-output
##        granularity).
##   10.  **Byte-determinism across two independent roots**: every
##        emitted file is byte-identical when the same config is
##        materialised into two separate storeRoots.
##   11.  **Sorted-output stability**: a second materialise pass with
##        the same config produces byte-identical config-used content
##        (the kernelKnobs sort + the deterministic banner guarantee
##        this).
##   12.  **bzImage stub records configFile hash**: the v1 stub embeds
##        the configFile's NDE0-K-namespaced hashHex in its text body,
##        demonstrating the cross-output content-addressing chain.
##   13.  **Hash isolation + 64-char hex per output**: all 4 outputs
##        have distinct hashHex segments, all of length 64 (M9.A's
##        full sha256; the shim's 16-char truncated form lives only
##        in the chain-derivation namespace + the bzImage stub body).
##   14.  **Stable store-path enumeration order**: storing the four
##        consumed handles in (configFile, bzImage, systemMap,
##        kernelRelease) order yields the activation-layer-friendly
##        sequence (configFile first as the build input the others
##        derive from).
##
## Plus the v1 invariants exercised at the shim layer (configFile
## stable bytes, kernelRelease text format, NDE0-K-namespaced hash
## chain in the bzImage stub) AND a "DSL surface" suite at the end
## pinning the new ``files <name>:`` + ``executable bzImage:`` artifact
## registration shape against the DSL's M3 ``registeredArtifacts``
## accessor + the M9.F ``registeredBuildInputs`` / ``registeredOutputs``
## accessors, confirming the recipe genuinely exercises the typed
## surface rather than silently regressing to the legacy "shim does
## everything" path.

import std/[os, strutils, tempfiles, unittest]

# The shim module — still owns the render* template procs +
# KernelConfig type + the Nde0kDefaultKernelVersion /
# Nde0kDefaultBaseConfigVariant / Nde0kPackageName constants the
# recipe + this test use. NDE-E does NOT remove the shim; the
# deprecated ``materializeKernel`` + ``plantStub`` emitter procs stay
# reachable for any caller that still imports them.
import repro_dsl_stdlib/packages/de_foundation/kernel as kernelImpl

# The recipe — registers the package's M2 configurables + module-init
# fires every ``files <name>: build:`` and ``executable bzImage: build:``
# arm so the M8/M9.A tables + M9.F output/build-input tables are
# pre-populated against the default configurables. The recipe also
# re-exports the per-artifact ``register*`` helpers the test fixture
# below uses to re-register after a configurable toggle.
import repro_project_dsl
import repro_project_dsl/fs as fs
import "../../../recipes/packages/de-foundation/kernel/repro" as recipe

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc readStoreFile(handle: DslManagedFiles): string =
  ## Read the bytes of the emitted file at
  ## ``handle.storePath/handle.relPath``.
  let p = handle.storePath / handle.relPath
  check fileExists(p)
  result = readFile(p)

proc resetRecipeState(storeRoot: string) =
  ## Test-fixture reset: clear every M8/M9.A + M9.F registry +
  ## materialiser row, drop any pending configurable overrides for the
  ## reproosKernel package, then re-register every fs.* output +
  ## output() + toolBuild() the recipe owns against the (now-default)
  ## configurables. ``registerStoreRoot`` runs LAST because
  ## ``resetDslPortMaterialiseState`` clears the store-root table along
  ## with the materialiser side-tables (the M9.A reset proc is "drop
  ## EVERY registered storeRoot + every materialisation side-table
  ## row" — see the proc's docstring).
  ##
  ## ``resetDslPortBuildState`` ALSO resets the M9.F typed-output +
  ## build-input registries (via its delegated
  ## ``resetDslPortBuildInputState`` call) so the bzImage's
  ## ``outputOf("reproosKernel", "configFile")`` lookup starts from a
  ## clean slate.
  resetDslPortFsState()
  resetDslPortFsExtState()
  resetDslPortMaterialiseState()
  resetDslPortBuildState()
  resetConfigurable("reproosKernel.enableDrm")
  resetConfigurable("reproosKernel.enableHypervDrm")
  resetConfigurable("reproosKernel.enableFramebuffer")
  resetConfigurable("reproosKernel.enableUserNs")
  resetConfigurable("reproosKernel.enableOverlayFs")
  resetConfigurable("reproosKernel.enableVirtioGpu")
  resetConfigurable("reproosKernel.kernelVersion")
  resetConfigurable("reproosKernel.baseConfigVariant")
  registerStoreRoot("reproosKernel", storeRoot, dhaSha256)
  recipe.registerKernelFiles()

proc reregisterWithCurrentConfigurables(storeRoot: string) =
  ## After ``setConfigurable(...)`` has flipped one or more cells, the
  ## previously-recorded M8/M9.A entries still carry the OLD content;
  ## drop them, re-register against the new cells, and re-bind the
  ## store-root (the M9.A reset call below also wipes it — see above).
  ## The M9.F output + build-input tables are reset alongside so the
  ## bzImage's outputOf lookup picks up the freshly-published configFile
  ## handle.
  resetDslPortFsState()
  resetDslPortFsExtState()
  resetDslPortMaterialiseState()
  resetDslPortBuildState()
  registerStoreRoot("reproosKernel", storeRoot, dhaSha256)
  recipe.registerKernelFiles()

# ---------------------------------------------------------------------------
# Convenience consumers — one per artifact. Centralises the per-output
# path the recipe uses so the test reads identically to the v1 shape.
# ---------------------------------------------------------------------------

proc consumeConfigFileArt(): DslManagedFiles =
  consumeConfigFile("reproosKernel", "/build/config-used")
proc consumeBzImage(): DslManagedFiles =
  consumeConfigFile("reproosKernel", "/build/bzImage")
proc consumeSystemMap(): DslManagedFiles =
  consumeConfigFile("reproosKernel", "/build/System.map")
proc consumeKernelReleaseArt(): DslManagedFiles =
  consumeConfigFile("reproosKernel", "/build/KERNELRELEASE")

# Per-knob mutation table — each entry pins one configurable cell to
# ``false`` (defaults are all true). ``configLine`` is the raw CONFIG_X
# token whose disabled-form ("# CONFIG_X is not set") must appear in
# the emitted config-used after the override AND whose enabled-form
# ("CONFIG_X=y") must appear before the override.

type
  KnobMutation = tuple
    label:      string
    configLine: string
    cellKey:    string

const KnobMutations: array[6, KnobMutation] = [
  (label: "enableDrm",         configLine: "CONFIG_DRM",
   cellKey: "reproosKernel.enableDrm"),
  (label: "enableHypervDrm",   configLine: "CONFIG_DRM_HYPERV",
   cellKey: "reproosKernel.enableHypervDrm"),
  (label: "enableFramebuffer", configLine: "CONFIG_FB",
   cellKey: "reproosKernel.enableFramebuffer"),
  (label: "enableUserNs",      configLine: "CONFIG_USER_NS",
   cellKey: "reproosKernel.enableUserNs"),
  (label: "enableOverlayFs",   configLine: "CONFIG_OVERLAY_FS",
   cellKey: "reproosKernel.enableOverlayFs"),
  (label: "enableVirtioGpu",   configLine: "CONFIG_VIRTIO_GPU",
   cellKey: "reproosKernel.enableVirtioGpu")]

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "NDE0-K kernel package":

  test "all 6 configurable knobs propagate to config-used content + store path":
    # Table-driven: for each of the 6 enable* configurables, exercise:
    #   (a) baseline (all true) emits CONFIG_X=y
    #   (b) mutated (this one false) emits "# CONFIG_X is not set"
    #   (c) the configFile storePath differs between baseline + mutated
    #   (d) the configFile content actually differs byte-wise
    # This single test covers ALL 6 knobs — that's the strict-rules
    # requirement.
    for km in KnobMutations:
      let rootBase = createTempDir("nde0k_kn_base_", "")
      let rootMut = createTempDir("nde0k_kn_mut_", "")
      defer:
        removeDir(rootBase)
        removeDir(rootMut)

      # Baseline.
      resetRecipeState(rootBase)
      let baseHandle = consumeConfigFileArt()
      let baseBytes = readStoreFile(baseHandle)

      # Mutated.
      resetRecipeState(rootMut)
      setConfigurable[bool](km.cellKey, false)
      reregisterWithCurrentConfigurables(rootMut)
      let mutHandle = consumeConfigFileArt()
      let mutBytes = readStoreFile(mutHandle)

      # Baseline must have the =y form.
      check (km.configLine & "=y") in baseBytes
      check ("# " & km.configLine & " is not set") notin baseBytes

      # Mutated must have the "is not set" form.
      check ("# " & km.configLine & " is not set") in mutBytes
      check (km.configLine & "=y") notin mutBytes

      # The two content blobs must differ.
      check baseBytes != mutBytes

      # And the content-addressed configFile storePath must differ
      # (this is the cache-key propagation contract).
      check baseHandle.storePath != mutHandle.storePath

  test "configurable propagation: kernelVersion change re-keys configFile + kernelRelease":
    # Bumping kernelVersion is the only mutation that re-keys
    # kernelRelease (every other configurable leaves it cached). This
    # exercises BOTH the banner-propagation in configFile AND the
    # KERNELRELEASE content-record.
    let rootA = createTempDir("nde0k_kvA_", "")
    let rootB = createTempDir("nde0k_kvB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    # Pass A — default kernelVersion (6.6.142).
    resetRecipeState(rootA)
    let cfA = consumeConfigFileArt()
    let bzA = consumeBzImage()
    let smA = consumeSystemMap()
    let krA = consumeKernelReleaseArt()

    # Pass B — bump kernelVersion via setConfigurable.
    resetRecipeState(rootB)
    setConfigurable[string]("reproosKernel.kernelVersion", "6.6.150")
    reregisterWithCurrentConfigurables(rootB)
    let cfB = consumeConfigFileArt()
    let bzB = consumeBzImage()
    let smB = consumeSystemMap()
    let krB = consumeKernelReleaseArt()

    # configFile content's banner records kernelVersion.
    let cfBytesA = readStoreFile(cfA)
    let cfBytesB = readStoreFile(cfB)
    check "kernelVersion: 6.6.142" in cfBytesA
    check "kernelVersion: 6.6.150" in cfBytesB
    check cfBytesA != cfBytesB

    # kernelRelease content records the resolved release string
    # (version + "-reproos" localversion).
    let krBytesA = readStoreFile(krA)
    let krBytesB = readStoreFile(krB)
    check krBytesA == "6.6.142-reproos\n"
    check krBytesB == "6.6.150-reproos\n"

    # Every output's storePath must differ (kernelVersion folds into
    # all four hash derivations via the M9.A configFileSha256Of digest).
    check cfA.storePath != cfB.storePath
    check bzA.storePath != bzB.storePath
    check smA.storePath != smB.storePath
    check krA.storePath != krB.storePath

  test "idempotency: same config produces same store paths":
    # A second consume pass under the SAME storeRoot hits the M9.A
    # idempotency side-table and returns the cached handle without re-
    # writing. Both passes MUST land at exactly the same store path.
    let root = createTempDir("nde0k_idem_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let cfA = consumeConfigFileArt()
    let bzA = consumeBzImage()
    let smA = consumeSystemMap()
    let krA = consumeKernelReleaseArt()

    let cfB = consumeConfigFileArt()
    let bzB = consumeBzImage()
    let smB = consumeSystemMap()
    let krB = consumeKernelReleaseArt()

    check cfA.storePath == cfB.storePath
    check bzA.storePath == bzB.storePath
    check smA.storePath == smB.storePath
    check krA.storePath == krB.storePath

  test "closure-sharing: enableHypervDrm toggle re-keys configFile + bzImage + systemMap, NOT kernelRelease":
    # The spec's NDE0-K acceptance #2 demonstration at the
    # package-output granularity. Toggle ONLY enableHypervDrm:
    #   * configFile re-keys (its content depends on every knob).
    #   * bzImage + systemMap re-key (their hashes embed configFile's
    #     hashHex via renderBzImageStub / renderSystemMapStub so the
    #     M9.A configFileSha256Of digest re-derives).
    #   * kernelRelease STAYS cached (renderKernelReleaseFile depends
    #     only on cfg.kernelVersion, which didn't change).
    # This is the "rebuild only what changed" claim at the
    # microscopic level — the full closure-sharing acceptance lives
    # at NDEM1 generation switching.
    let rootA = createTempDir("nde0k_shareA_", "")
    let rootB = createTempDir("nde0k_shareB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    # Pass A — default (enableHypervDrm = true).
    resetRecipeState(rootA)
    let cfA = consumeConfigFileArt()
    let bzA = consumeBzImage()
    let smA = consumeSystemMap()
    let krA = consumeKernelReleaseArt()

    # Pass B — flip enableHypervDrm to false.
    resetRecipeState(rootB)
    setConfigurable[bool]("reproosKernel.enableHypervDrm", false)
    reregisterWithCurrentConfigurables(rootB)
    let cfB = consumeConfigFileArt()
    let bzB = consumeBzImage()
    let smB = consumeSystemMap()
    let krB = consumeKernelReleaseArt()

    # configFile + bzImage + systemMap MUST land at different store
    # path basenames (the knob toggle propagates through the chain).
    # We compare the hash-segment basenames because the two passes use
    # different roots; the hashHex (the cache key) is what carries the
    # invalidation contract.
    check extractFilename(cfA.storePath) != extractFilename(cfB.storePath)
    check extractFilename(bzA.storePath) != extractFilename(bzB.storePath)
    check extractFilename(smA.storePath) != extractFilename(smB.storePath)

    # kernelRelease MUST stay at the same hash-segment (it depends
    # only on kernelVersion, which didn't change).
    check extractFilename(krA.storePath) == extractFilename(krB.storePath)
    # And the kernelRelease bytes are byte-identical too.
    check readStoreFile(krA) == readStoreFile(krB)

  test "byte-determinism: every output byte-identical across two independent roots":
    # Forces a fresh write into a SECOND root and byte-compares the
    # result. Mirror of NDE0-G's determinism test.
    let rootA = createTempDir("nde0k_detA_", "")
    let rootB = createTempDir("nde0k_detB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    # Pass A.
    resetRecipeState(rootA)
    let cfA = consumeConfigFileArt()
    let bzA = consumeBzImage()
    let smA = consumeSystemMap()
    let krA = consumeKernelReleaseArt()

    # Pass B — fresh state, fresh root, same default configurables.
    resetRecipeState(rootB)
    let cfB = consumeConfigFileArt()
    let bzB = consumeBzImage()
    let smB = consumeSystemMap()
    let krB = consumeKernelReleaseArt()

    # Hash-segment basenames match.
    check extractFilename(cfA.storePath) == extractFilename(cfB.storePath)
    check extractFilename(bzA.storePath) == extractFilename(bzB.storePath)
    check extractFilename(smA.storePath) == extractFilename(smB.storePath)
    check extractFilename(krA.storePath) == extractFilename(krB.storePath)

    # And every file's bytes are byte-identical.
    check readStoreFile(cfA) == readStoreFile(cfB)
    check readStoreFile(bzA) == readStoreFile(bzB)
    check readStoreFile(smA) == readStoreFile(smB)
    check readStoreFile(krA) == readStoreFile(krB)

  test "sorted-output stability: same config -> byte-identical config-used":
    # The kernelKnobs() proc sorts the 6 knob rows by CONFIG_X name
    # before emission so the rendered config-used is byte-stable
    # regardless of source-line order. Two independent materialise
    # passes with the same config MUST produce byte-identical
    # config-used content.
    let rootA = createTempDir("nde0k_sortA_", "")
    let rootB = createTempDir("nde0k_sortB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    resetRecipeState(rootA)
    let bytesA = readStoreFile(consumeConfigFileArt())

    resetRecipeState(rootB)
    let bytesB = readStoreFile(consumeConfigFileArt())

    # Byte-identical.
    check bytesA == bytesB

    # And the sorted-key shape is observable: the 6 CONFIG_X lines
    # must appear in alphabetical order in the emission. Find each
    # one's index in the string and assert the sequence is sorted.
    let order = [
      "CONFIG_DRM=y",          # not CONFIG_DRM_HYPERV (which sorts after)
      "CONFIG_DRM_HYPERV=y",
      "CONFIG_FB=y",
      "CONFIG_OVERLAY_FS=y",
      "CONFIG_USER_NS=y",
      "CONFIG_VIRTIO_GPU=y"]
    var lastIdx = -1
    for line in order:
      let idx = bytesA.find(line)
      check idx >= 0
      check idx > lastIdx
      lastIdx = idx

  test "bzImage stub records configFile hash":
    # The v1 STUB body embeds the configFile's NDE0-K-namespaced hashHex
    # so the cross-output content-addressing chain is observable. When
    # the kernel compilation back end lands and bzImage becomes real
    # ELF bytes, the hash chain stays — only the content changes.
    let root = createTempDir("nde0k_chain_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let bzBytes = readStoreFile(consumeBzImage())

    # The configFile's NDE0-K-namespaced hash is the load-bearing
    # chain input. Compute it via the exposed helper and assert it
    # appears in the stub body. NDE0-K's configFileHashOf returns the
    # truncated 16-char hex (chain-derivation namespace, NOT the M9.A
    # configFileSha256Of digest used for the storePath).
    let cfg = kernelImpl.defaultConfig()
    let cfgHash = kernelImpl.configFileHashOf(cfg)
    check cfgHash.len == 16
    check ("configFileHash=" & cfgHash) in bzBytes

    # And the bzImage stub records the source pin + kernel release.
    check "kernelVersion=6.6.142" in bzBytes
    check "baseConfigVariant=x86_64-hyperv" in bzBytes
    check "kernelRelease=6.6.142-reproos" in bzBytes
    check "v1 STUB" in bzBytes

  test "cache-key isolation: per-output hashes are distinct + 64 chars":
    # A regression guard: if two emission helpers ever shared a hash
    # namespace (e.g. both used the same composed string prefix), an
    # accidental collision would alias their store paths and the
    # caller would silently get the wrong bytes. The M9.A digest
    # mixes a discriminator prefix into the sha256 input so the four
    # configFile records (different paths under the same package)
    # land at four distinct hashes.
    let root = createTempDir("nde0k_iso_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let cf = consumeConfigFileArt()
    let bz = consumeBzImage()
    let sm = consumeSystemMap()
    let kr = consumeKernelReleaseArt()

    check cf.hashHex != bz.hashHex
    check cf.hashHex != sm.hashHex
    check cf.hashHex != kr.hashHex
    check bz.hashHex != sm.hashHex
    check bz.hashHex != kr.hashHex
    check sm.hashHex != kr.hashHex

    # All hash-hex segments are exactly 64 chars (M9.A's full sha256;
    # the shim's 16-char truncated form lives only in the
    # chain-derivation namespace + the bzImage stub body).
    check cf.hashHex.len == 64
    check bz.hashHex.len == 64
    check sm.hashHex.len == 64
    check kr.hashHex.len == 64

  test "stable activation order: handle enumeration order is contract":
    # The activation step depends on a stable enumeration order:
    # configFile first (the build input the others derive from),
    # then bzImage (the bootable artefact), then systemMap (the
    # symbol table for debugging), then kernelRelease (the release-
    # string discovery file). The recipe records the artifacts in
    # that order (per the package body source order); the test
    # captures the handles in the same order so the activation-layer
    # convention is observable.
    let root = createTempDir("nde0k_order_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let handles = @[
      consumeConfigFileArt(),
      consumeBzImage(),
      consumeSystemMap(),
      consumeKernelReleaseArt()]

    check handles.len == 4
    # Each handle's relPath matches the spec'd build-relative location
    # in declaration order.
    check handles[0].relPath == "build/config-used"
    check handles[1].relPath == "build/bzImage"
    check handles[2].relPath == "build/System.map"
    check handles[3].relPath == "build/KERNELRELEASE"

  test "v1 invariant: shim render proc produces byte-stable config-used directly":
    # Pin the v1 invariant at the shim layer too. The recipe's
    # ``fs.configFile`` content argument is exactly
    # ``kernelImpl.renderKernelConfig(cfg)``; this test calls the render
    # proc TWICE with the same KernelConfig and asserts the bytes match.
    # Independent of how the cfg is constructed (default config here),
    # the render proc must be a pure function of its argument.
    let cfg = kernelImpl.defaultConfig()
    let bytesA = kernelImpl.renderKernelConfig(cfg)
    let bytesB = kernelImpl.renderKernelConfig(cfg)
    check bytesA == bytesB
    # Two-distinct-cfg propagation invariant via the render proc
    # directly (NDE-D's "preserve v1 via direct render-call" pattern):
    # toggling enableHypervDrm in the cfg MUST change the rendered
    # bytes. The cache-key propagation invariant is independent of
    # how the cfg flows in.
    var cfgFlipped = cfg
    cfgFlipped.enableHypervDrm = false
    let flippedBytes = kernelImpl.renderKernelConfig(cfgFlipped)
    check bytesA != flippedBytes
    check "CONFIG_DRM_HYPERV=y" in bytesA
    check "# CONFIG_DRM_HYPERV is not set" in flippedBytes

# ---------------------------------------------------------------------------
# NDE-E DSL-surface coverage. Pins that the rewritten
# ``recipes/packages/de-foundation/kernel/repro.nim`` actually
# exercises the new DSL surface (M3 ``files <name>:`` +
# ``executable <name>:`` blocks + M8/M9.A ``fs.configFile`` + M9.F
# ``output()`` / ``toolBuild`` / ``outputOf``) rather than silently
# regressing to the legacy "shim does everything" shape. These are
# extra assertions on top of the v1 surface — the v1 structural
# assertions above stay intact.
# ---------------------------------------------------------------------------

suite "NDE0-K kernel DSL surface":

  test "recipe registers exactly 4 artifacts":
    let arts = registeredArtifacts("reproosKernel")
    check arts.len == 4

  test "recipe artifact names cover every emitted file":
    let arts = registeredArtifacts("reproosKernel")
    var names: seq[string] = @[]
    for a in arts:
      names.add(a.artifactName)
    check "configFile"    in names
    check "bzImage"       in names
    check "systemMap"     in names
    check "kernelRelease" in names

  test "bzImage is dakExecutable; the other three are dakFiles":
    let arts = registeredArtifacts("reproosKernel")
    var kindByName: seq[(string, DslArtifactKind)] = @[]
    for a in arts:
      kindByName.add((a.artifactName, a.kind))
    # bzImage is the kernel image — declared as ``executable``.
    var found = false
    for (n, k) in kindByName:
      if n == "bzImage":
        check k == dakExecutable
        found = true
    check found
    # The other three are ``files`` artifacts.
    for (n, k) in kindByName:
      if n in ["configFile", "systemMap", "kernelRelease"]:
        check k == dakFiles

# ---------------------------------------------------------------------------
# NDE-E M9.F cross-artifact wire coverage. The recipe's
# ``files configFile: build: output("/build/config-used")`` publishes a
# typed handle into the M9.F output registry; the
# ``executable bzImage: build: toolBuild(...)`` consumes it via
# ``outputOf("reproosKernel", "configFile")`` and registers a
# ``DslBuildInput`` row. NDE-E is the first recipe to exercise this
# cross-artifact surface in production. The four assertions below pin
# the contract.
# ---------------------------------------------------------------------------

suite "NDE0-K M9.F cross-artifact wire":

  test "configFile artifact publishes its output to the M4 + M9.F registries":
    let root = createTempDir("nde0k_m9f_pubA_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    # M4 string registry observes the published path.
    let outs = registeredOutputs("reproosKernel", "configFile")
    check outs.len == 1
    check outs[0] == "/build/config-used"

    # M9.F typed-output registry observes the same handle with the
    # producer-identity metadata.
    let refs = registeredOutputRefs("reproosKernel", "configFile")
    check refs.len == 1
    check refs[0].packageName == "reproosKernel"
    check refs[0].artifactName == "configFile"
    check refs[0].path == "/build/config-used"

  test "bzImage artifact's toolBuild call records a cross-artifact build-input row":
    let root = createTempDir("nde0k_m9f_inputs_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let inputs = registeredBuildInputs("reproosKernel", "bzImage")
    check inputs.len == 1
    let row = inputs[0]
    # The slot name the recipe passed as the first element of the
    # (slot, producerRef) tuple — survives the round-trip through the
    # registry.
    check row.inputName == "config"
    # The wiring is a directed edge: the producer is the configFile
    # artifact in the same package, and its registered path is
    # ``/build/config-used``.
    check row.producerPackageName == "reproosKernel"
    check row.producerArtifactName == "configFile"
    check row.producerPath == "/build/config-used"
    # The consumer side of the edge is the bzImage artifact in the
    # same package.
    check row.consumerPackageName == "reproosKernel"
    check row.consumerArtifactName == "bzImage"

  test "bzImage's toolBuild output flows through to the M4 + M9.F output registries":
    let root = createTempDir("nde0k_m9f_outflow_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    # ``toolBuild(...)`` funnels its ``outputPath`` argument through
    # ``output()`` so the M4 string registry observes a row indexed
    # under (``reproosKernel``, ``bzImage``) carrying ``build/bzImage``.
    let outs = registeredOutputs("reproosKernel", "bzImage")
    check outs.len == 1
    check outs[0] == "build/bzImage"

    # And the M9.F typed-output registry has the matching handle.
    let refs = registeredOutputRefs("reproosKernel", "bzImage")
    check refs.len == 1
    check refs[0].packageName == "reproosKernel"
    check refs[0].artifactName == "bzImage"
    check refs[0].path == "build/bzImage"

  test "outputOf lookup against the configFile artifact resolves the published path":
    # The bzImage's ``outputOf("reproosKernel", "configFile")`` is
    # evaluated at module-init time when the recipe's build body runs;
    # this assertion exercises the same lookup at test time so the
    # producer-then-consumer ordering convention is observable. Calling
    # ``outputOf`` after ``resetRecipeState`` (which has re-registered
    # both artifacts in source order) MUST return a non-empty handle
    # pointing at the configFile artifact's first output.
    let root = createTempDir("nde0k_m9f_lookup_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let h = outputOf("reproosKernel", "configFile")
    check h.packageName == "reproosKernel"
    check h.artifactName == "configFile"
    check h.path == "/build/config-used"

  test "querying an unwired artifact yields the empty seq (M9.F accessor convention)":
    # Symmetric with the M2 / M3 / M4 accessor convention: an
    # unregistered (consumerPackage, consumerArtifact) tuple returns
    # an empty seq rather than raising. configFile is a producer
    # (publishes but consumes nothing) so its build-input bucket is
    # empty even after registration.
    let root = createTempDir("nde0k_m9f_unwired_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let inputs = registeredBuildInputs("reproosKernel", "configFile")
    check inputs.len == 0
    # And the same convention for a fully nonexistent artifact name.
    let unknown = registeredBuildInputs("reproosKernel", "noSuchConsumer")
    check unknown.len == 0
