## NDE0-K: native kernel package — Tier-1 native.
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE0-K.
## This ``repro.nim`` is the user-facing package declaration; the actual
## implementation lives at
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/de_foundation/
## kernel.nim`` (precedent: NDE0-G / NDE0-D / NDE0-S all use the same
## ``recipes/packages/<de-foundation>/<name>/repro.nim`` + ``libs/
## repro_dsl_stdlib/.../de_foundation/<name>.nim`` split).
##
## ## NDE-E: DSL-port migration to typed fs.* + M9.F cross-artifact wiring
##
## NDE-E (fifth NDE rewrite, after NDE-A/B/C/D) migrates this recipe from
## the previous "shim does everything, recipe is a config: shell" pattern
## to the spec'd typed surface. NDE-E is the FIRST recipe to exercise
## the M9.F cross-artifact output() / toolBuild surface (closed by the
## ``2db1553`` DSL-port milestone): the spec's worked example wires the
## bzImage's ``config`` input to the configFile's output, which v8
## modelled as ``input configFile.output`` + ``kernelCompile.build(
## config = configFile.output, ...)``. M9.F lowers this to the flat
## ``outputOf("reproosKernel", "configFile")`` + ``toolBuild(
## "kernelCompile", inputs, outputPath)`` pair.
##
##   files configFile:
##     build:
##       output("/build/config-used")           # M4 + M9.F typed registry
##       fs.configFile(                          # M8/M9.A on-disk emit
##         path = "/build/config-used",
##         content = renderKernelConfig(cfg))
##
##   executable bzImage:
##     build:
##       toolBuild(                              # M9.F: cross-artifact
##         "kernelCompile",
##         @[("config", outputOf("reproosKernel", "configFile"))],
##         "build/bzImage")
##       fs.configFile(                          # v1 stub content via M9.A
##         path = "/build/bzImage",
##         content = renderBzImageStub(cfg, configFileHashOf(cfg)))
##
##   files systemMap: ...   files kernelRelease: ...
##
## The bzImage is the only ``executable`` artifact in the recipe — it is
## the kernel image (the spec example's ``output = "build/bzImage"``).
## The other three artifacts are ``files:`` records: configFile (the
## .config snapshot), systemMap (the v1 stub System.map), kernelRelease
## (the KERNELRELEASE text file the activation layer reads).
##
## The shim module still owns the render* template procs verbatim — only
## the on-disk emission path moved (the shim's deprecated
## ``materializeKernel`` + ``plantStub`` emitters stay reachable for
## back-compat callers but the recipe no longer invokes them; all on-disk
## materialisation now flows through the DSL's M8 / M9.A path).
##
## ## Configurables
##
## Per the spec NDE0-K section. Each maps to a field on
## ``KernelConfig`` in the impl module. Toggling any of them invalidates
## only the outputs that consume it (the DSL's per-artifact
## ``configFileSha256Of`` hash propagates the change atomically through
## ``consumeConfigFile``; the unaffected artifacts stay cached).
##
##   * ``enableDrm`` — flips ``CONFIG_DRM`` between ``=y`` and
##     ``# CONFIG_DRM is not set`` in the planted /build/config-used.
##   * ``enableHypervDrm`` — flips ``CONFIG_DRM_HYPERV``. This is the
##     load-bearing knob the spec's acceptance #2 calls out (toggle it
##     to demonstrate closure-sharing: only kernel + initramfs
##     rebuild).
##   * ``enableFramebuffer`` — flips ``CONFIG_FB``.
##   * ``enableUserNs`` — flips ``CONFIG_USER_NS``. Needed by
##     container-style sandboxes (steam-run pattern, FHS user-namespace
##     wrappers).
##   * ``enableOverlayFs`` — flips ``CONFIG_OVERLAY_FS``. Needed by
##     overlay-mount generation-switching.
##   * ``enableVirtioGpu`` — flips ``CONFIG_VIRTIO_GPU``. Needed for
##     virtio-gpu accelerated rendering inside Hyper-V / QEMU guests.
##   * ``kernelVersion`` — the R8-pinned version string ``"6.6.142"``.
##     Part of every cache key + the only input ``kernelRelease``
##     depends on (so toggling enable* knobs leaves kernelRelease
##     cached — that's the asymmetry the cache-key isolation test
##     exercises).
##   * ``baseConfigVariant`` — ``"x86_64-hyperv"`` (default). Records
##     which Tier-2 ``.config`` file template the configurable
##     overrides apply to. The Tier-2 reference is
##     ``recipes/bootstrap/kernel/configs/x86_64-hyperv.config``.
##
## ## Honest deferrals
##
## * **Real Linux kernel source-build is DEFERRED.** The spec's
##   worked example shows ``kernelCompile.build(source = linuxSource.
##   tree, config = configFile.output, output = "build/bzImage")`` —
##   i.e., a full Linux source build that runs make targets against
##   the kernel source tree, deterministic via SOURCE_DATE_EPOCH +
##   KBUILD_BUILD_TIMESTAMP + KBUILD_BUILD_USER + KBUILD_BUILD_HOST.
##   The Tier-2 reference at
##   ``recipes/bootstrap/kernel/configs/x86_64-hyperv.config`` is
##   rebuilt by the Tier-2 work in 73 seconds in a specific WSL distro
##   using jammy gcc 11.4 + binutils 2.38, with 16+ byte-pinned
##   outputs governed by
##   ``recipes/bootstrap/tcc-chain/OUTPUTS-SHA256SUMS-r8.txt``. That
##   entire substantial infrastructure is NOT lifted into the Tier-1
##   native package in v1 — it remains in the Tier-2 shell pipeline.
##   v1 ships the DECLARATIVE front end (configurables + config-used
##   emission + content-addressed bzImage stub) so downstream packages
##   can already ``uses: "reproos-kernel >=0.1.0"`` + consume the
##   output handles; the compilation back end migrates to the native
##   package in a follow-up NDEM milestone. NDE-E's M9.F toolBuild
##   wiring already records the producer-consumer edge so the
##   compilation back end can swap in without touching the recipe.
##
## * **bzImage is a v1 STUB.** The emitted bzImage file is a text
##   marker recording (kernel source pin, config-used hash,
##   "deferred-binary-build" note). This mirrors NDE0-G's
##   ``bundleStubHash`` pattern: the content-addressed store path
##   participates honestly in the cache-key chain (toggling any of
##   the 6 enable* configurables invalidates configFile, which
##   invalidates bzImage), so the v1 invalidation contract is the
##   same as a real build would have. When the kernel compilation
##   lands, the stub's hash derivation stays — only the file content
##   (text marker → ELF bzImage bytes) changes.
##
## * **Bootloader-menu integration**: spec acceptance #3 ("Bootloader
##   menu offers both as boot options") is NDEM1 work. The system-
##   generation switching layer is what reads every active kernel
##   package's bzImage + KERNELRELEASE outputs and writes the GRUB /
##   systemd-boot menu entries. v1 of NDE0-K emits the output handles;
##   the consumer that turns them into menu entries is NDEM1.
##
## * **enable* knob documentary effect in v1**: each of the 6
##   enable* configurables flips a single ``CONFIG_X=y`` line to
##   ``# CONFIG_X is not set`` in the emitted /build/config-used. v1's
##   effect is the cache-key + emitted-content propagation; the
##   actual kernel binary differences materialise when the kernel
##   compilation lands (and the configurable's =y vs =n controls
##   whether the matching driver builds in). The cache-key
##   propagation is the load-bearing v1 contract.

import repro_project_dsl
import repro_project_dsl/fs as fs
# DSL-port M9.R.2c — pulls ``Executable`` into scope for the typed
# slot var injected for ``executable bzImage:`` below.
import repro_dsl_stdlib/types/executable

# The stdlib impl module that owns the render* template procs +
# KernelConfig type + the Nde0kPackageName / Nde0kDefault* constants.
# Imported under an alias so the recipe-side call sites stay readable
# (``kernelImpl.renderKernelConfig()``). The shim's
# ``materializeKernel`` orchestrator + ``plantStub`` on-disk emitter are
# still available to legacy callers but the recipe no longer invokes
# them — all on-disk materialisation now flows through the DSL's M8 /
# M9.A path.
import repro_dsl_stdlib/packages/de_foundation/kernel as kernelImpl
export kernelImpl

# ---------------------------------------------------------------------------
# Configurable accessor
# ---------------------------------------------------------------------------

const ReproosKernelPackageId* = "reproosKernel"
  ## The Nim identifier the ``package`` macro registers. Shared between
  ## the recipe's fs.* call sites + the test fixtures so a future rename
  ## propagates in one place. NB: this differs from
  ## ``kernelImpl.Nde0kPackageName`` (= ``"reproos-kernel"``); the
  ## kebab-cased form is the catalog-facing package name segment
  ## downstream Tier-1 packages reference via ``uses:
  ## "reproos-kernel >=0.1.0"`` while ``ReproosKernelPackageId`` is the
  ## DSL-side package identifier the M3 registry indexes by.

proc currentKernelCfg*(): kernelImpl.KernelConfig =
  ## Read every configurable cell into a ``KernelConfig`` record the
  ## shim's render* procs can consume. Uses the M9.D fallback-flavour
  ## of ``readConfigurable`` so this proc is callable even when the
  ## package has not yet registered its defaults (e.g. from a unit test
  ## that imported the recipe but is exercising the helper in isolation).
  ##
  ## All 8 configurables — 6 bool enable-flags + ``kernelVersion`` +
  ## ``baseConfigVariant`` — are scalar types supported by the M2/M9.D
  ## ``recordConfigDefault`` surface, so every cell flows through
  ## ``readConfigurable`` and the recipe-level
  ## ``setConfigurable``/``readConfigurable`` round-trip works for the
  ## full configurable surface (no v1 invariant requires the direct
  ## render-call path NDE-D used for ``seq[string]``).
  let defaults = kernelImpl.defaultConfig()
  result = kernelImpl.KernelConfig(
    enableDrm:         readConfigurable[bool](
      "reproosKernel.enableDrm", defaults.enableDrm),
    enableHypervDrm:   readConfigurable[bool](
      "reproosKernel.enableHypervDrm", defaults.enableHypervDrm),
    enableFramebuffer: readConfigurable[bool](
      "reproosKernel.enableFramebuffer", defaults.enableFramebuffer),
    enableUserNs:      readConfigurable[bool](
      "reproosKernel.enableUserNs", defaults.enableUserNs),
    enableOverlayFs:   readConfigurable[bool](
      "reproosKernel.enableOverlayFs", defaults.enableOverlayFs),
    enableVirtioGpu:   readConfigurable[bool](
      "reproosKernel.enableVirtioGpu", defaults.enableVirtioGpu),
    kernelVersion:     readConfigurable[string](
      "reproosKernel.kernelVersion", defaults.kernelVersion),
    baseConfigVariant: readConfigurable[string](
      "reproosKernel.baseConfigVariant", defaults.baseConfigVariant),
    storeRoot:         defaults.storeRoot)

# ---------------------------------------------------------------------------
# Per-artifact registration helpers
# ---------------------------------------------------------------------------
#
# Each helper records one fs.* declaration against the recipe's
# packageName + artifactName. The ``files:`` / ``executable:`` arms below
# call these so the M4 ``beginBuildContext`` push covers the artifact
# name. Tests that want to re-register after toggling a configurable
# call ``registerKernelFiles()`` (below) directly with explicit
# packageName + artifactName so the call works outside a build:
# context.
#
# The configFile + bzImage helpers ALSO emit the M9.F producer/consumer
# wiring (``output()`` + ``toolBuild()``) so the cross-artifact edge is
# observable in the registry; the dedicated ``output()`` call inside
# configFile's build body publishes its path into the M9.F typed-output
# registry, which ``outputOf("reproosKernel", "configFile")`` then looks
# up at the bzImage call site.
# ---------------------------------------------------------------------------

proc registerConfigFile*() =
  ## /build/config-used — the .config-style snapshot of the 6 spec'd
  ## CONFIG_X knobs plus a deterministic banner recording kernelVersion
  ## + baseConfigVariant. The published M9.F output handle is what the
  ## downstream bzImage artifact wires into its ``config`` input slot.
  ##
  ## The helper pushes a transient build-context frame so the bare
  ## ``output(...)`` call attributes to ``(reproosKernel, configFile)``
  ## even when the test fixture invokes the helper outside the
  ## ``files configFile: build:`` lowering (where the package macro
  ## would push the frame for us).
  let cfg = currentKernelCfg()
  beginBuildContext(ReproosKernelPackageId, "configFile")
  try:
    # Publish the artifact's output into the M4 + M9.F typed-output
    # registry so ``outputOf("reproosKernel", "configFile")`` from the
    # bzImage call site resolves to ``/build/config-used``. The bare
    # statement form is fine — the returned ``DslOutputRef`` is
    # discardable.
    output("/build/config-used")
    fs.configFile(
      path = "/build/config-used",
      content = kernelImpl.renderKernelConfig(cfg),
      packageName = ReproosKernelPackageId,
      artifactName = "configFile")
  finally:
    endBuildContext()

proc registerBzImage*() =
  ## /build/bzImage — the v1 STUB kernel-image content. Records the
  ## M9.F cross-artifact wiring (the ``config`` input slot points at the
  ## configFile artifact's output) AND emits the stub content via
  ## ``fs.configFile`` so the on-disk materialiser plants a real file
  ## the activation layer can hand to the bootloader-menu generator.
  ##
  ## The M9.F ``toolBuild(...)`` call records a ``DslBuildInput`` row
  ## against ``(reproosKernel, bzImage)`` whose ``producerPackageName ==
  ## "reproosKernel"``, ``producerArtifactName == "configFile"``,
  ## ``producerPath == "/build/config-used"`` — that's the load-bearing
  ## M9.F cross-artifact wire NDE-E exercises for the first time in a
  ## recipe.
  let cfg = currentKernelCfg()
  beginBuildContext(ReproosKernelPackageId, "bzImage")
  try:
    # M9.F cross-artifact wire: the kernelCompile tool consumes the
    # configFile artifact's output as the ``config`` input slot and
    # emits ``build/bzImage`` as its output. The DslBuildInput row
    # stamps the producer-identity metadata so a downstream consumer
    # (NDEM1 bootloader-menu generator) can dereference the configFile
    # artifact's registered output path without re-querying the
    # registry.
    toolBuild(
      "kernelCompile",
      @[("config", outputOf(ReproosKernelPackageId, "configFile"))],
      "build/bzImage")
    # v1 stub content. The chain-derivation (sha256 over
    # ``"bzImage" || ... || configFileHash``) lives in the M9.A digest
    # composition; this helper passes the configFile's NDE0-K-namespaced
    # hash as a substring of the stub body so the chain is visible to
    # humans inspecting the planted file.
    fs.configFile(
      path = "/build/bzImage",
      content = kernelImpl.renderBzImageStub(cfg,
                                             kernelImpl.configFileHashOf(cfg)),
      packageName = ReproosKernelPackageId,
      artifactName = "bzImage")
  finally:
    endBuildContext()

proc registerSystemMap*() =
  ## /build/System.map — v1 stub symbol-table file. Same shape as the
  ## bzImage stub but advertises the System.map intent; the kernel
  ## compilation back end will replace this with the real
  ## ``System.map`` file emitted alongside bzImage.
  let cfg = currentKernelCfg()
  beginBuildContext(ReproosKernelPackageId, "systemMap")
  try:
    fs.configFile(
      path = "/build/System.map",
      content = kernelImpl.renderSystemMapStub(cfg,
                                               kernelImpl.configFileHashOf(cfg)),
      packageName = ReproosKernelPackageId,
      artifactName = "systemMap")
  finally:
    endBuildContext()

proc registerKernelRelease*() =
  ## /build/KERNELRELEASE — the resolved ``<kernelVersion>-reproos``
  ## release string. Stable text file the activation layer (NDEM1) can
  ## read to discover the kernel release without re-parsing bzImage.
  ## Depends ONLY on kernelVersion — that asymmetry is the spec
  ## acceptance #2 closure-sharing demonstration (toggling any enable*
  ## knob re-emits configFile + bzImage + systemMap but leaves
  ## kernelRelease cached at the same store path).
  let cfg = currentKernelCfg()
  beginBuildContext(ReproosKernelPackageId, "kernelRelease")
  try:
    fs.configFile(
      path = "/build/KERNELRELEASE",
      content = kernelImpl.renderKernelReleaseFile(cfg),
      packageName = ReproosKernelPackageId,
      artifactName = "kernelRelease")
  finally:
    endBuildContext()

proc registerKernelFiles*() =
  ## Register every fs.* output the recipe owns. Idempotent at the
  ## per-call level only — call ``resetDslPortFsState`` +
  ## ``resetDslPortFsExtState`` + ``resetDslPortMaterialiseState`` +
  ## ``resetDslPortOutputState`` before re-invoking, otherwise each
  ## fs.* + output() + toolBuild() call appends a fresh row to the
  ## registry.
  ##
  ## Used by the unit-test fixture to re-register after a configurable
  ## toggle. The recipe's ``files <name>: build:`` /
  ## ``executable bzImage: build:`` arms below each invoke a single
  ## per-artifact helper so the M4 ``beginBuildContext`` push carries
  ## the spec'd artifact name; the per-artifact helpers' explicit
  ## packageName argument keeps the registration well-formed when
  ## called outside a build: context (as the test fixture does).
  ##
  ## Order matters for the M9.F wire: ``registerConfigFile`` MUST run
  ## before ``registerBzImage`` so the ``outputOf("reproosKernel",
  ## "configFile")`` lookup inside ``registerBzImage`` finds a
  ## published path (returns a placeholder handle with ``path == ""``
  ## otherwise).
  registerConfigFile()
  registerBzImage()
  registerSystemMap()
  registerKernelRelease()

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package reproosKernel:
  ## NDE0-K native kernel package.
  ##
  ## Downstream Tier-1 packages (NDEM1 system-generation switching)
  ## ``uses:`` this and consume the recipe's fs.* artifacts through the
  ## DSL's ``consumeConfigFile`` materialiser. The per-artifact cache
  ## key isolates the downstream invalidation surface: toggling a
  ## per-knob configurable re-emits the affected outputs only; the
  ## ``kernelRelease`` artifact stays cached when only enable* knobs
  ## are flipped (it depends solely on ``kernelVersion``).
  ##
  ## NDE-E is the FIRST recipe to exercise the M9.F cross-artifact
  ## output()/toolBuild surface — the ``executable bzImage:`` arm
  ## wires the configFile artifact's output into the bzImage's
  ## ``config`` input slot via ``outputOf("reproosKernel",
  ## "configFile")``. The kernelCompile tool invocation stays a flat
  ## ``toolBuild(...)`` call (v8's ``<tool>.build(...)`` dot syntax is
  ## DEFERRED — see ``dsl_port_runtime.nim``).

  defaultToolProvisioning "path"

  config:
    ## Toggles CONFIG_DRM=y in /build/config-used. Default true.
    enableDrm: bool = true

    ## Toggles CONFIG_DRM_HYPERV=y. Default true. This is the
    ## load-bearing knob the spec's acceptance #2 calls out.
    enableHypervDrm: bool = true

    ## Toggles CONFIG_FB=y (the framebuffer console).
    enableFramebuffer: bool = true

    ## Toggles CONFIG_USER_NS=y (user namespaces). Default true.
    enableUserNs: bool = true

    ## Toggles CONFIG_OVERLAY_FS=y (overlayfs). Default true.
    enableOverlayFs: bool = true

    ## Toggles CONFIG_VIRTIO_GPU=y. Default true.
    enableVirtioGpu: bool = true

    ## Kernel source version pin. R8 default ``"6.6.142"``. Part of
    ## every cache key; the only input KERNELRELEASE depends on.
    kernelVersion: string = "6.6.142"

    ## Tier-2 base-config variant stem. Default ``"x86_64-hyperv"``;
    ## future variants (``x86_64-generic``, ``aarch64-generic``) lift
    ## here without breaking the cache-key contract.
    baseConfigVariant: string = "x86_64-hyperv"

  uses:
    ## NDE0-A apt-jammy native catalog adapter — supplies the
    ## (deferred) linux-source .deb input. v1 of NDE0-K records this
    ## dependency for fingerprint purposes but does not yet exercise
    ## ``installAptDeb()`` for linux-source (Tier-2 manages the kernel
    ## source via the tcc-chain bootstrap, not via apt).
    "apt-jammy >=0.1.0"

    ## NDE0-S native systemd-session — supplies the minimal-viable
    ## ``ManagedFiles`` / ``DefaultStoreRoot`` helpers + the
    ## ``BlockScope`` enum re-exported via kernel.nim's import chain.
    "systemd-session >=0.1.0"

  # -------------------------------------------------------------------------
  # files: artifacts — one per emitted file. Each ``build:`` body calls
  # the matching per-artifact helper proc declared at module top level;
  # the helper handles the configurable read + the fs.* registration so
  # the recipe stays declarative.
  #
  # The ``executable bzImage:`` arm is the kernel image (M3 executable
  # artifact). Its build body invokes the M9.F ``toolBuild`` wiring
  # against the configFile artifact's published output before
  # ``fs.configFile`` materialises the v1 stub content.
  # -------------------------------------------------------------------------

  files configFile:
    ## /build/config-used — the deterministic .config-style snapshot
    ## of the 6 spec'd CONFIG_X knobs. The ``output()`` statement in
    ## the helper publishes the path into the M9.F typed-output
    ## registry so the bzImage artifact's ``outputOf`` lookup resolves.
    build:
      registerConfigFile()

  executable bzImage:
    ## /build/bzImage — the bootable kernel image. M9.F cross-artifact
    ## wiring: the kernelCompile tool consumes the configFile's
    ## ``/build/config-used`` output as the ``config`` input slot, and
    ## the toolBuild call publishes ``build/bzImage`` into the M4 +
    ## M9.F output registries. v1's content is a text stub recording
    ## the chain-derivation inputs; the activation-layer bootloader-
    ## menu generator (NDEM1) reads the output handle, not the bytes,
    ## so the swap to real ELF bytes in a follow-up milestone is
    ## transparent at the M9.F wire level.
    build:
      registerBzImage()

  files systemMap:
    ## /build/System.map — v1 stub symbol-table file. Chain-derives
    ## from the configFile hash via ``renderSystemMapStub`` so a knob
    ## toggle re-emits both bzImage and systemMap together.
    build:
      registerSystemMap()

  files kernelRelease:
    ## /build/KERNELRELEASE — the resolved release string. Depends
    ## ONLY on ``kernelVersion`` so a knob toggle leaves this artifact
    ## cached (acceptance #2 closure-sharing at the package-output
    ## granularity).
    build:
      registerKernelRelease()
