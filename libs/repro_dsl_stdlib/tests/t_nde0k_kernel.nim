## NDE0-K unit tests: native kernel package.
##
## Exercises the spec'd public surface of
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/de_foundation/
## kernel.nim`` against synthetic configurations. Mirrors the NDE0-G +
## NDE0-D + NDE0-S test layout (per-output ``ManagedFiles`` round-trip +
## per-configurable propagation + cache-key isolation + byte-determinism).
##
## Required test surfaces (per the NDE0-K sub-agent prompt §"Unit tests"
## + the spec acceptance criteria):
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
##   8.   **Idempotency**: a second materializeKernel() with the same
##        config lands at the same store paths.
##   9.   **Cache-key isolation: enableHypervDrm only invalidates
##        configFile + bzImage + systemMap, NOT kernelRelease**. This
##        is the load-bearing acceptance #2 demonstration ("only the
##        kernel + initramfs rebuild" at the package-output
##        granularity).
##   10.  **Byte-determinism across two independent roots**: every
##        emitted file is byte-identical when the same config is
##        materialised into two separate storeRoots.
##   11.  **Sorted-output stability**: calling materializeKernel twice
##        with the same config produces byte-identical config-used
##        content (the kernelKnobs sort + the deterministic banner
##        guarantee this).
##   12.  **bzImage stub records configFile hash**: the v1 stub embeds
##        the configFile's hashHex in its text body, demonstrating the
##        cross-output content-addressing chain.
##   13.  **Hash isolation + 16-char hex per output**: all 4 outputs
##        have distinct hashHex segments, all of length 16.
##   14.  **Stable storePaths enumeration order**: storePaths(outs)
##        returns [configFile, bzImage, systemMap, kernelRelease] in
##        that order.
##
## No try/except swallows. Failure paths use ``expect`` where
## applicable; this module's primitives are infallible by design (mirror
## of NDE0-S/D/G), so most assertions use ``check``.

import std/[os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/de_foundation/kernel
import repro_dsl_stdlib/packages/de_foundation/systemd_session
  # for ManagedFiles (used in the readStoreFile helper)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc readStoreFile(handle: ManagedFiles): string =
  ## Read the bytes of the emitted file at
  ## ``handle.storePath/handle.relPath``. Mirrors the NDE0-G helper
  ## exactly.
  let p = handle.storePath / handle.relPath
  check fileExists(p)
  result = readFile(p)

proc configWithRoot(storeRoot: string): KernelConfig =
  result = defaultConfig()
  result.storeRoot = storeRoot

type
  KnobMutation = tuple
    label:      string  # human-readable knob label
    configLine: string  # the CONFIG_X line that flips
    mutate:     proc (cfg: var KernelConfig) {.nimcall.}

# Per-knob mutations: each disables exactly one of the 6 enable* knobs
# by setting it to false (defaults are all true). The configLine is the
# raw CONFIG_X token whose disabled-form ("# CONFIG_X is not set") must
# appear in the emitted config-used after the mutation, AND whose
# enabled-form ("CONFIG_X=y") must appear before the mutation.

proc mutateDrm(cfg: var KernelConfig)         {.nimcall.} = cfg.enableDrm = false
proc mutateHypervDrm(cfg: var KernelConfig)   {.nimcall.} = cfg.enableHypervDrm = false
proc mutateFramebuffer(cfg: var KernelConfig) {.nimcall.} = cfg.enableFramebuffer = false
proc mutateUserNs(cfg: var KernelConfig)      {.nimcall.} = cfg.enableUserNs = false
proc mutateOverlayFs(cfg: var KernelConfig)   {.nimcall.} = cfg.enableOverlayFs = false
proc mutateVirtioGpu(cfg: var KernelConfig)   {.nimcall.} = cfg.enableVirtioGpu = false

const KnobMutations: array[6, KnobMutation] = [
  (label: "enableDrm",         configLine: "CONFIG_DRM",         mutate: mutateDrm),
  (label: "enableHypervDrm",   configLine: "CONFIG_DRM_HYPERV",  mutate: mutateHypervDrm),
  (label: "enableFramebuffer", configLine: "CONFIG_FB",          mutate: mutateFramebuffer),
  (label: "enableUserNs",      configLine: "CONFIG_USER_NS",     mutate: mutateUserNs),
  (label: "enableOverlayFs",   configLine: "CONFIG_OVERLAY_FS",  mutate: mutateOverlayFs),
  (label: "enableVirtioGpu",   configLine: "CONFIG_VIRTIO_GPU",  mutate: mutateVirtioGpu)]

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

      var cfgBase = configWithRoot(rootBase)
      let outsBase = materializeKernel(cfgBase)
      let baseBytes = readStoreFile(outsBase.configFile)

      var cfgMut = configWithRoot(rootMut)
      km.mutate(cfgMut)
      let outsMut = materializeKernel(cfgMut)
      let mutBytes = readStoreFile(outsMut.configFile)

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
      check outsBase.configFile.storePath != outsMut.configFile.storePath

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

    var cfgA = configWithRoot(rootA)
    cfgA.kernelVersion = "6.6.142"
    let outsA = materializeKernel(cfgA)

    var cfgB = configWithRoot(rootB)
    cfgB.kernelVersion = "6.6.150"
    let outsB = materializeKernel(cfgB)

    # configFile content's banner records kernelVersion.
    let cfBytesA = readStoreFile(outsA.configFile)
    let cfBytesB = readStoreFile(outsB.configFile)
    check "kernelVersion: 6.6.142" in cfBytesA
    check "kernelVersion: 6.6.150" in cfBytesB
    check cfBytesA != cfBytesB

    # kernelRelease content records the resolved release string
    # (version + "-reproos" localversion).
    let krBytesA = readStoreFile(outsA.kernelRelease)
    let krBytesB = readStoreFile(outsB.kernelRelease)
    check krBytesA == "6.6.142-reproos\n"
    check krBytesB == "6.6.150-reproos\n"

    # Every output's storePath must differ (kernelVersion folds into
    # all four hash derivations).
    check outsA.configFile.storePath    != outsB.configFile.storePath
    check outsA.bzImage.storePath       != outsB.bzImage.storePath
    check outsA.systemMap.storePath     != outsB.systemMap.storePath
    check outsA.kernelRelease.storePath != outsB.kernelRelease.storePath

  test "idempotency: same config produces same store paths":
    # Mirror of NDE0-G's idempotency test. A second invocation with
    # the same args lands at exactly the same store paths via the
    # content-addressed hash function purity.
    let root = createTempDir("nde0k_idem_", "")
    defer: removeDir(root)

    let outsA = materializeKernel(configWithRoot(root))
    let outsB = materializeKernel(configWithRoot(root))

    check outsA.configFile.storePath    == outsB.configFile.storePath
    check outsA.bzImage.storePath       == outsB.bzImage.storePath
    check outsA.systemMap.storePath     == outsB.systemMap.storePath
    check outsA.kernelRelease.storePath == outsB.kernelRelease.storePath

  test "closure-sharing: enableHypervDrm toggle re-keys configFile + bzImage + systemMap, NOT kernelRelease":
    # The spec's NDE0-K acceptance #2 demonstration at the
    # package-output granularity. Toggle ONLY enableHypervDrm:
    #   * configFile re-keys (its content depends on every knob).
    #   * bzImage + systemMap re-key (their hashes chain-derive from
    #     configFileHash).
    #   * kernelRelease STAYS cached (depends only on kernelVersion).
    # This is the "rebuild only what changed" claim at the
    # microscopic level — the full closure-sharing acceptance lives
    # at NDEM1 generation switching.
    let root = createTempDir("nde0k_share_", "")
    defer: removeDir(root)

    var cfgA = configWithRoot(root)
    cfgA.enableHypervDrm = true
    let outsA = materializeKernel(cfgA)

    var cfgB = configWithRoot(root)
    cfgB.enableHypervDrm = false
    let outsB = materializeKernel(cfgB)

    # configFile + bzImage + systemMap MUST land at different store
    # paths (the knob toggle propagates through the chain).
    check outsA.configFile.storePath != outsB.configFile.storePath
    check outsA.bzImage.storePath    != outsB.bzImage.storePath
    check outsA.systemMap.storePath  != outsB.systemMap.storePath

    # kernelRelease MUST stay at the same store path (it depends
    # only on kernelVersion, which didn't change).
    check outsA.kernelRelease.storePath == outsB.kernelRelease.storePath
    # And the kernelRelease bytes are byte-identical too.
    check readStoreFile(outsA.kernelRelease) ==
          readStoreFile(outsB.kernelRelease)

  test "byte-determinism: every output byte-identical across two independent roots":
    # Forces a fresh write into a SECOND root and byte-compares the
    # result. Mirror of NDE0-G's determinism test.
    let rootA = createTempDir("nde0k_detA_", "")
    let rootB = createTempDir("nde0k_detB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    let outsA = materializeKernel(configWithRoot(rootA))
    let outsB = materializeKernel(configWithRoot(rootB))

    # Hash-segment basenames match.
    check extractFilename(outsA.configFile.storePath) ==
          extractFilename(outsB.configFile.storePath)
    check extractFilename(outsA.bzImage.storePath) ==
          extractFilename(outsB.bzImage.storePath)
    check extractFilename(outsA.systemMap.storePath) ==
          extractFilename(outsB.systemMap.storePath)
    check extractFilename(outsA.kernelRelease.storePath) ==
          extractFilename(outsB.kernelRelease.storePath)

    # And every file's bytes are byte-identical.
    check readStoreFile(outsA.configFile)    ==
          readStoreFile(outsB.configFile)
    check readStoreFile(outsA.bzImage)       ==
          readStoreFile(outsB.bzImage)
    check readStoreFile(outsA.systemMap)     ==
          readStoreFile(outsB.systemMap)
    check readStoreFile(outsA.kernelRelease) ==
          readStoreFile(outsB.kernelRelease)

  test "sorted-output stability: same config → byte-identical config-used":
    # The kernelKnobs() proc sorts the 6 knob rows by CONFIG_X name
    # before emission so the rendered config-used is byte-stable
    # regardless of source-line order. Calling materializeKernel
    # TWICE with the same config must produce byte-identical
    # config-used content.
    let rootA = createTempDir("nde0k_sortA_", "")
    let rootB = createTempDir("nde0k_sortB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    let cfgA = configWithRoot(rootA)
    let cfgB = configWithRoot(rootB)

    let outsA = materializeKernel(cfgA)
    let outsB = materializeKernel(cfgB)

    let bytesA = readStoreFile(outsA.configFile)
    let bytesB = readStoreFile(outsB.configFile)

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
    # The v1 STUB body embeds the configFile.hashHex so the cross-
    # output content-addressing chain is observable. When the kernel
    # compilation back end lands and bzImage becomes real ELF bytes,
    # the hash chain stays — only the content changes.
    let root = createTempDir("nde0k_chain_", "")
    defer: removeDir(root)

    let outs = materializeKernel(configWithRoot(root))
    let bzBytes = readStoreFile(outs.bzImage)

    # The configFile's NDE0-K-namespaced hash is the load-bearing
    # chain input. Compute it via the exposed helper and assert it
    # appears in the stub body.
    let cfg = defaultConfig()
    let cfgHash = configFileHashOf(cfg)
    check cfgHash.len == 16
    check ("configFileHash=" & cfgHash) in bzBytes

    # And the bzImage stub records the source pin + kernel release.
    check "kernelVersion=6.6.142" in bzBytes
    check "baseConfigVariant=x86_64-hyperv" in bzBytes
    check "kernelRelease=6.6.142-reproos" in bzBytes
    check "v1 STUB" in bzBytes

  test "cache-key isolation: per-output hashes are distinct + 16 chars":
    # A regression guard: if two emission helpers ever shared a hash
    # namespace (e.g. both used the same composed string prefix), an
    # accidental collision would alias their store paths and the
    # caller would silently get the wrong bytes. Mirrors NDE0-G's
    # isolation test.
    let root = createTempDir("nde0k_iso_", "")
    defer: removeDir(root)

    let outs = materializeKernel(configWithRoot(root))

    check outs.configFile.hashHex    != outs.bzImage.hashHex
    check outs.configFile.hashHex    != outs.systemMap.hashHex
    check outs.configFile.hashHex    != outs.kernelRelease.hashHex
    check outs.bzImage.hashHex       != outs.systemMap.hashHex
    check outs.bzImage.hashHex       != outs.kernelRelease.hashHex
    check outs.systemMap.hashHex     != outs.kernelRelease.hashHex

    # All hash-hex segments are exactly 16 chars (mirrors NDE0-A +
    # NDE0-S + NDE0-D + NDE0-G).
    check outs.configFile.hashHex.len    == 16
    check outs.bzImage.hashHex.len       == 16
    check outs.systemMap.hashHex.len     == 16
    check outs.kernelRelease.hashHex.len == 16

  test "stable activation order: storePaths enumeration order is contract":
    # The activation step depends on a stable enumeration order:
    # configFile first (the build input the others derive from),
    # then bzImage (the bootable artefact), then systemMap (the
    # symbol table for debugging), then kernelRelease (the release-
    # string discovery file).
    let root = createTempDir("nde0k_order_", "")
    defer: removeDir(root)

    let outs = materializeKernel(configWithRoot(root))
    let paths = storePaths(outs)

    check paths.len == 4
    check paths[0] == outs.configFile.storePath
    check paths[1] == outs.bzImage.storePath
    check paths[2] == outs.systemMap.storePath
    check paths[3] == outs.kernelRelease.storePath
