## NDE0-K: native kernel package impl module (Tier-1).
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE0-K.
##
## This module is the build-time implementation backing the package
## declaration at ``recipes/packages/de-foundation/kernel/repro.nim``.
## Mirrors the NDE0-G / NDE0-D / NDE0-S layout: the DSL ``parsePackageDef``
## macro at ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim``
## only recognises ``executable`` / ``library`` / ``uses`` / ``config`` /
## ``outputs`` section heads, so the spec'd ``files configFile:`` block
## form (with ``kernelConfigContent:`` macro body) and the
## ``executable bzImage:`` block form (with ``kernelCompile.build()``
## body) don't yet work and the impl is exposed as ordinary Nim procs.
##
## ## What this package owns
##
## Per spec §NDE0-K, the native package mirrors what the Tier-2 work did
## by hand to ``recipes/bootstrap/kernel/configs/x86_64-hyperv.config``
## (the 6 kernel config knobs flipped directly in the file). The native
## form models them as configurables + emits:
##
##   * ``/build/config-used`` — the deterministic .config-style snapshot
##     of the 6 spec'd knobs (CONFIG_DRM, CONFIG_DRM_HYPERV, CONFIG_FB,
##     CONFIG_USER_NS, CONFIG_OVERLAY_FS, CONFIG_VIRTIO_GPU). Emitted via
##     ``fs.configFile()`` so toggling any of the 6 ``enable*``
##     configurables invalidates the content-addressed store path
##     atomically — that's the spec's NDE0-K acceptance #1.
##   * ``/build/bzImage`` — the v1 STUB output: a text marker file that
##     records the kernel source pin (``kernelVersion`` +
##     ``baseConfigVariant``) + the configFile's hashHex. See honest
##     deferrals below — this is NOT a real Linux kernel build, it is a
##     content-addressed placeholder whose hash chain-derives from the
##     configFile's hash so the v1 cache-key contract still holds.
##   * ``/build/System.map`` — same shape as bzImage (v1 stub).
##   * ``/build/KERNELRELEASE`` — text file containing the resolved
##     kernel release string ``<kernelVersion>-reproos``. This output is
##     keyed ONLY on kernelVersion so toggling enableHypervDrm rebuilds
##     configFile + bzImage + systemMap but NOT KERNELRELEASE. This is
##     the spec's "closure-sharing" acceptance #2 at the package-output
##     granularity.
##
## ## What this package consumes
##
## Per spec NDE0-K ``uses: "linux-source >=6.6 <6.7"``. v1 of NDE0-K does
## NOT exercise the linux-source.tree input directly (the kernel
## compilation that would consume it is deferred — see below). The spec'd
## ``uses: "apt-jammy >=0.1.0"`` analogue for NDE0-K is the linux-source
## input, which the apt-jammy adapter would supply via
## ``installAptDeb(snapshot, debs=@[linux-source-6.6])`` — for v1 the
## kernel-source pin is encoded purely as the ``kernelVersion`` string
## configurable (the R8 pin ``6.6.142``).
##
## ## Reuse from NDE0-S
##
## NDE0-S's ``systemd_session.nim`` exports the minimal-viable
## ``configFile`` / ``ManagedFiles`` / ``DefaultStoreRoot`` helpers + the
## ``BlockScope`` enum. This module imports them directly. Same pattern
## NDE0-D + NDE0-G follow.
##
## ## Honest deferrals
##
## * **Real kernel source build is OUT of scope for v1.** The spec's
##   worked example shows ``kernelCompile.build(source = linuxSource.tree,
##   config = configFile.output, output = "build/bzImage")`` — i.e. a
##   full Linux source build that runs make targets against the kernel
##   source tree, deterministic via SOURCE_DATE_EPOCH +
##   KBUILD_BUILD_TIMESTAMP + KBUILD_BUILD_USER + KBUILD_BUILD_HOST. The
##   Tier-2 reference at ``recipes/bootstrap/kernel/configs/x86_64-hyperv.config``
##   is rebuilt by the Tier-2 work in 73 seconds in a specific WSL distro
##   using jammy gcc 11.4 + binutils 2.38, with 16+ byte-pinned outputs
##   governed by ``recipes/bootstrap/tcc-chain/OUTPUTS-SHA256SUMS-r8.txt``.
##   That entire substantial infrastructure is NOT lifted into the
##   Tier-1 native package in v1 — it remains in the Tier-2 shell
##   pipeline. The native package v1 ships the DECLARATIVE front end
##   (configurables + config-used emission + content-addressed output
##   handles) so downstream packages can already ``uses:
##   "reproos-kernel >=0.1.0"`` and consume the output handles; the
##   compilation back end migrates to the native package in a follow-up
##   NDEM milestone. This same pattern is how NDE0-G defers .deb
##   extraction + NDE0-D defers broker-daemon .deb extraction.
##
## * **bzImage is a v1 STUB.** The emitted bzImage file is a text marker
##   recording (kernel source pin, config-used hash, "deferred-binary-
##   build" note). This mirrors NDE0-G's ``bundleStubHash`` pattern: the
##   content-addressed store path participates honestly in the cache-key
##   chain (toggling any of the 6 enable* configurables invalidates
##   configFile, which invalidates bzImage), so the v1 invalidation
##   contract is the same as a real build would have. When the kernel
##   compilation lands, the stub's hash derivation stays — only the file
##   content (text marker → ELF bzImage bytes) changes.
##
## * **Bootloader-menu integration is NDEM1 work.** The spec's acceptance
##   #3 ("Bootloader menu offers both as boot options") needs the system-
##   generation switching layer to read every active kernel package's
##   bzImage + KERNELRELEASE outputs and write the GRUB / systemd-boot
##   menu entries. v1 of NDE0-K emits the output handles; the consumer
##   that turns them into menu entries is NDEM1.
##
## * **enableHardwareGl-style 1-line documentary configurables**: each
##   of the 6 enable* configurables flips a single CONFIG_X=y line to
##   ``# CONFIG_X is not set`` in the emitted config-used. v1's effect
##   is the cache-key + emitted-content propagation; the actual kernel
##   binary differences materialise when the kernel compilation lands
##   (and the configurable's =y vs =n controls whether the matching
##   driver builds in). The cache-key propagation is the load-bearing
##   v1 contract.
##
## * **``files configFile:`` + ``executable bzImage:`` DSL blocks**: pure
##   DSL spec at this point (``parsePackageDef`` doesn't yet support the
##   ``files`` / ``executable`` block-body shapes the spec example uses
##   with the inline ``kernelConfigContent:`` macro + ``kernelCompile.build()``
##   call). Semantics are encoded directly in the Nim helpers exported
##   from this module + the package preamble.

import std/[algorithm, os, strutils]

import nimcrypto/sha2 as nc_sha2

import ../apt_jammy
import ./systemd_session

# Re-export the symbols downstream consumers need so a ``uses:
# "reproos-kernel >=0.1.0"`` package can do everything from one import.
export apt_jammy.AptFiles
export systemd_session

# ---------------------------------------------------------------------------
# Version constants — part of every emitted-output fingerprint.
# ---------------------------------------------------------------------------

const
  Nde0kVersion* = "0.1.0"

  ## Canonical package name segment. Matches the ``package`` form's
  ## registered name in
  ## ``recipes/packages/de-foundation/kernel/repro.nim``.
  Nde0kPackageName* = "reproos-kernel"

  ## R8-pinned kernel version. See
  ## ``recipes/bootstrap/tcc-chain/OUTPUTS-SHA256SUMS-r8.txt`` for the
  ## byte-pinned outputs at this version + the Tier-2 reference config
  ## at ``recipes/bootstrap/kernel/configs/x86_64-hyperv.config`` (the
  ## file the Tier-2 work flipped the 6 knobs in).
  Nde0kDefaultKernelVersion* = "6.6.142"

  ## Canonical base-config variant. Matches the Tier-2 file name without
  ## the ``.config`` suffix.
  Nde0kDefaultBaseConfigVariant* = "x86_64-hyperv"

  ## Output paths under ``<storeRoot>/<hash>/`` — match the spec
  ## worked-example ``path = "/build/config-used"`` etc. The canonical
  ## form is POSIX-relative (the ``configFile`` helper canonicalises
  ## leading slashes off).
  Nde0kConfigUsedPath*    = "build/config-used"
  Nde0kBzImagePath*       = "build/bzImage"
  Nde0kSystemMapPath*     = "build/System.map"
  Nde0kKernelReleasePath* = "build/KERNELRELEASE"

# ---------------------------------------------------------------------------
# sha256 helper (sidecar files; the main emissions go through NDE0-S's
# helpers which embed their own per-output Nde0sVersion in the hash, so
# this helper is only used to compose the bzImage / systemMap /
# kernelRelease stubs).
# ---------------------------------------------------------------------------

proc sha256OfBytes(bytes: openArray[byte]): string =
  var ctx: nc_sha2.sha256
  ctx.init()
  ctx.update(bytes)
  let digest = ctx.finish()
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = digest.data[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

proc sha256OfString(s: string): string =
  if s.len == 0:
    sha256OfBytes(default(array[0, byte]))
  else:
    sha256OfBytes(cast[ptr UncheckedArray[byte]](
      s[0].unsafeAddr).toOpenArray(0, s.len - 1))

# ---------------------------------------------------------------------------
# Configurables + outputs
# ---------------------------------------------------------------------------

type
  KernelConfig* = object
    ## NDE0-K configurables per the spec example. Defaults match the
    ## Tier-2 reference config
    ## ``recipes/bootstrap/kernel/configs/x86_64-hyperv.config`` (each
    ## of the 6 enable* knobs is =y in the Tier-2 file; v1 mirrors that
    ## default).
    enableDrm*: bool
    enableHypervDrm*: bool
    enableFramebuffer*: bool
    enableUserNs*: bool
    enableOverlayFs*: bool
    enableVirtioGpu*: bool

    ## R8-pinned kernel version string. Part of the configFile banner
    ## + the only input the kernelRelease output depends on (this is
    ## what gives NDE0-K its closure-sharing demonstration: toggling
    ## any enable* knob re-emits configFile + bzImage + systemMap but
    ## leaves kernelRelease cached).
    kernelVersion*: string

    ## Base-config variant name (matches the Tier-2 ``.config`` file
    ## stem). The default is ``x86_64-hyperv``; future variants
    ## (``x86_64-generic``, ``aarch64-generic``) lift here without
    ## breaking the cache-key contract.
    baseConfigVariant*: string

    ## Root the helpers write into. Test harnesses override.
    storeRoot*: string

  KernelOutputs* = object
    ## Output handles for every emitted file. Each is a separate
    ## content-addressed ``ManagedFiles`` so the cache keys are
    ## independent.
    ##
    ## **Invalidation matrix** (load-bearing for NDE0-K acceptance #2):
    ##
    ##   * Toggling any of the 6 enable* knobs → re-emits
    ##     ``configFile`` (its content depends on each knob);
    ##     re-emits ``bzImage`` + ``systemMap`` (their hashes
    ##     chain-derive from ``configFile.hashHex``); leaves
    ##     ``kernelRelease`` cached (it depends only on kernelVersion).
    ##   * Toggling ``kernelVersion`` → re-emits ALL four outputs (the
    ##     banner in ``configFile`` includes kernelVersion; bzImage +
    ##     systemMap include kernelVersion directly; kernelRelease
    ##     records it).
    ##   * Toggling ``baseConfigVariant`` → re-emits ``configFile``
    ##     (banner); re-emits ``bzImage`` + ``systemMap`` (chain-
    ##     derive); leaves ``kernelRelease`` cached.
    configFile*:    ManagedFiles
    bzImage*:       ManagedFiles
    systemMap*:     ManagedFiles
    kernelRelease*: ManagedFiles

proc defaultConfig*(): KernelConfig =
  ## The spec'd defaults. Tests use this then mutate one field at a
  ## time to exercise configurable propagation.
  result = KernelConfig(
    enableDrm:         true,
    enableHypervDrm:   true,
    enableFramebuffer: true,
    enableUserNs:      true,
    enableOverlayFs:   true,
    enableVirtioGpu:   true,
    kernelVersion:     Nde0kDefaultKernelVersion,
    baseConfigVariant: Nde0kDefaultBaseConfigVariant,
    storeRoot:         systemd_session.DefaultStoreRoot)

# ---------------------------------------------------------------------------
# Knob table — drives sorted-key emission so the rendered config-used is
# byte-stable across runs (the spec mandates determinism + the
# acceptance includes a per-knob propagation guarantee).
# ---------------------------------------------------------------------------

type
  KernelKnob = tuple
    configName: string
    knobName:   string  # which KernelConfig field controls it

proc kernelKnobs*(cfg: KernelConfig): seq[tuple[name: string; enabled: bool]] =
  ## Sorted-by-CONFIG_X-name enumeration of the 6 spec'd knobs paired
  ## with their resolved enable state. The sort ensures byte-stable
  ## output regardless of source-line order.
  var rows = @[
    (name: "CONFIG_DRM",                  enabled: cfg.enableDrm),
    (name: "CONFIG_DRM_HYPERV",           enabled: cfg.enableHypervDrm),
    (name: "CONFIG_FB",                   enabled: cfg.enableFramebuffer),
    (name: "CONFIG_USER_NS",              enabled: cfg.enableUserNs),
    (name: "CONFIG_OVERLAY_FS",           enabled: cfg.enableOverlayFs),
    (name: "CONFIG_VIRTIO_GPU",           enabled: cfg.enableVirtioGpu)]
  rows.sort(proc(a, b: tuple[name: string; enabled: bool]): int =
    cmp(a.name, b.name))
  result = rows

# ---------------------------------------------------------------------------
# Render the .config-style text emitted at /build/config-used.
# ---------------------------------------------------------------------------

proc renderKernelConfig*(cfg: KernelConfig): string =
  ## Emit the .config-style text with the 6 spec'd knobs encoded as
  ## either ``CONFIG_X=y`` (enabled) or ``# CONFIG_X is not set``
  ## (disabled), per the upstream Linux kbuild ``Kconfig`` convention.
  ## Prefixed by a deterministic banner that records the NDE0-K version
  ## + the resolved kernelVersion + baseConfigVariant strings, so a
  ## ``kernelVersion`` change re-keys the configFile output even if no
  ## ``enable*`` knob was toggled.
  ##
  ## Byte-stability: the knob rows are sorted by CONFIG_X name (see
  ## ``kernelKnobs``) so the output is byte-identical across runs with
  ## the same config. The acceptance test
  ## ``sorted-output stability across two materialize calls`` exercises
  ## this directly.
  result = "# NDE0-K v" & Nde0kVersion & ": reproos-kernel config-used.\n"
  result.add("# kernelVersion: " & cfg.kernelVersion & "\n")
  result.add("# baseConfigVariant: " & cfg.baseConfigVariant & "\n")
  result.add("#\n")
  result.add("# Spec'd configurable knobs (sorted by CONFIG_X name):\n")
  result.add("#\n")
  for knob in kernelKnobs(cfg):
    if knob.enabled:
      result.add(knob.name & "=y\n")
    else:
      result.add("# " & knob.name & " is not set\n")

# ---------------------------------------------------------------------------
# Helpers for the stub outputs (bzImage / systemMap / kernelRelease).
# These mirror NDE0-S's symlinkUnmask helper shape: write a marker file
# whose content + hash are pure functions of the inputs, idempotent via
# a sentinel marker.
# ---------------------------------------------------------------------------

proc plantStub(path, content, sentinel, hash, storeRoot: string): ManagedFiles =
  ## Internal helper: plant ``content`` at ``<storeRoot>/<hash>/<path>``
  ## with idempotency marker ``sentinel``. Mirrors the
  ## ``configFile``/``managedBlock``/``symlinkUnmask`` shape in
  ## systemd_session.nim verbatim.
  let storePath = storeRoot / hash
  let marker = storePath / sentinel
  result.storePath = storePath
  result.relPath = path
  result.hashHex = hash
  if dirExists(storePath) and fileExists(marker):
    let existing = readFile(marker).strip()
    if existing == hash:
      return
  if dirExists(storePath):
    removeDir(storePath)
  createDir(storePath)
  let dest = storePath / path
  createDir(dest.parentDir)
  writeFile(dest, content)
  writeFile(marker, hash)

proc resolvedKernelRelease*(cfg: KernelConfig): string =
  ## The KERNELRELEASE string the kernel build would have produced.
  ## Format mirrors the upstream ``Makefile``'s ``$(KERNELRELEASE)``:
  ## ``<version>-<localversion>``. v1 uses ``-reproos`` as the
  ## localversion so the string is identifiable + stable.
  result = cfg.kernelVersion & "-reproos"

proc renderBzImageStub*(cfg: KernelConfig; configFileHash: string): string =
  ## v1 STUB bzImage content. Text marker that records the kernel
  ## source pin + the configFile hash. The chain-derivation
  ## (sha256("NDE0-K-bzImage" || ... || configFileHash)) lives in
  ## ``materializeKernel`` below; this body just makes the chain
  ## visible to humans inspecting the planted file.
  result = "# NDE0-K v" & Nde0kVersion & ": bzImage v1 STUB.\n" &
           "# Deferred-binary-build: this file is NOT a Linux kernel.\n" &
           "# See the impl-module honest-deferrals for the migration\n" &
           "# path. When the kernelCompile.build() native lift lands,\n" &
           "# the hash chain stays + the content flips to ELF bytes.\n" &
           "#\n" &
           "kernelVersion=" & cfg.kernelVersion & "\n" &
           "baseConfigVariant=" & cfg.baseConfigVariant & "\n" &
           "configFileHash=" & configFileHash & "\n" &
           "kernelRelease=" & resolvedKernelRelease(cfg) & "\n"

proc renderSystemMapStub*(cfg: KernelConfig; configFileHash: string): string =
  ## v1 STUB System.map content. Same shape as bzImage stub but
  ## advertises the System.map intent (a kernel-symbol table). The
  ## kernel compilation back end will replace this with the real
  ## ``System.map`` file emitted alongside bzImage.
  result = "# NDE0-K v" & Nde0kVersion & ": System.map v1 STUB.\n" &
           "# Deferred-binary-build: this file is NOT a real System.map.\n" &
           "# Records the chain-derivation inputs for v1 hash hygiene.\n" &
           "#\n" &
           "kernelVersion=" & cfg.kernelVersion & "\n" &
           "baseConfigVariant=" & cfg.baseConfigVariant & "\n" &
           "configFileHash=" & configFileHash & "\n"

proc renderKernelReleaseFile*(cfg: KernelConfig): string =
  ## /build/KERNELRELEASE content — exactly the resolved release string
  ## with a trailing newline. Stable text file the activation layer
  ## (NDEM1) can read to discover the kernel release without re-parsing
  ## bzImage.
  result = resolvedKernelRelease(cfg) & "\n"

# ---------------------------------------------------------------------------
# Per-output hash composition.
#
# Each hash is a pure function of the inputs that semantically affect
# the output's bytes. The chain-derivation (bzImage / systemMap depend
# on configFile's hash) is the load-bearing v1 contract for acceptance
# #2 "rebuild only what changed":
#
#   * configFile depends on EVERY field of KernelConfig (the rendered
#     content embeds them all via renderKernelConfig).
#   * bzImage + systemMap depend on (kernelVersion, configFileHash) —
#     so a knob toggle re-emits configFile then bzImage + systemMap
#     chain-derive new hashes; a kernelVersion change re-emits all
#     three with new banners + new chain hashes.
#   * kernelRelease depends ONLY on kernelVersion — so knob toggles
#     leave it cached.
# ---------------------------------------------------------------------------

proc configFileHashOf*(cfg: KernelConfig): string =
  ## Hash key for the configFile output. Derives from the rendered
  ## content so any configurable that affects content also affects the
  ## hash (this is the same equivalence NDE0-S's configFileHash relies
  ## on). Prefixed with ``NDE0-K-configFile`` + ``Nde0kVersion`` so the
  ## hash namespace is isolated from NDE0-S/D/G/A.
  let content = renderKernelConfig(cfg)
  let composed = "NDE0-K-configFile" & Nde0kVersion & cfg.kernelVersion &
                 content
  result = sha256OfString(composed)[0 ..< 16]

proc bzImageHashOf*(cfg: KernelConfig; configFileHash: string): string =
  ## Hash key for the bzImage output. Chain-derives from the
  ## configFile's hash so any change that re-keys configFile
  ## propagates here. Also folds in kernelVersion directly so a
  ## version bump with an unrelated configFile content (hypothetical)
  ## still re-keys.
  let composed = "NDE0-K-bzImage" & Nde0kVersion & cfg.kernelVersion &
                 configFileHash
  result = sha256OfString(composed)[0 ..< 16]

proc systemMapHashOf*(cfg: KernelConfig; configFileHash: string): string =
  ## Hash key for the System.map output. Same shape as bzImageHashOf
  ## (separate hash namespace so the per-output isolation guarantee
  ## holds — see the ``cache-key isolation`` test).
  let composed = "NDE0-K-systemMap" & Nde0kVersion & cfg.kernelVersion &
                 configFileHash
  result = sha256OfString(composed)[0 ..< 16]

proc kernelReleaseHashOf*(cfg: KernelConfig): string =
  ## Hash key for the KERNELRELEASE output. Depends ONLY on
  ## kernelVersion — this asymmetry is what gives NDE0-K its closure-
  ## sharing demonstration: an ``enableHypervDrm`` toggle re-emits
  ## configFile + bzImage + systemMap but leaves kernelRelease
  ## cached.
  let composed = "NDE0-K-kernelRelease" & Nde0kVersion & cfg.kernelVersion
  result = sha256OfString(composed)[0 ..< 16]

# ---------------------------------------------------------------------------
# Public materializer — emit every NDE0-K output.
# ---------------------------------------------------------------------------

proc materializeKernel*(cfg: KernelConfig): KernelOutputs =
  ## Emit every NDE0-K output. Each helper invocation is independent
  ## so the cache keys are per-output — see the docstring for
  ## ``KernelOutputs`` for the full invalidation matrix.
  ##
  ## **configFile** is emitted through the NDE0-S exported
  ## ``configFile()`` helper so the content-addressing contract is
  ## byte-compatible with NDE0-S/D/G's other emissions. v1 deliberately
  ## composes its OWN hash via ``configFileHashOf`` and uses it to
  ## chain-derive the bzImage + systemMap hashes; the NDE0-S helper's
  ## inner hash differs (it composes ``"configFile" || Nde0sVersion ||
  ## path || content``) but that's the storePath segment, while the
  ## chain-derivation uses the NDE0-K-namespaced hash. The acceptance
  ## test ``bzImage stub records configFile hash`` exercises the
  ## visible chain.

  let cfgHash = configFileHashOf(cfg)
  let bzHash = bzImageHashOf(cfg, cfgHash)
  let smHash = systemMapHashOf(cfg, cfgHash)
  let krHash = kernelReleaseHashOf(cfg)

  # configFile is the spec'd "fs.configFile(path = '/build/config-used',
  # content = kernelConfigContent: ...)" emission. We use the NDE0-S
  # helper so the content-addressed shape matches every other Tier-1
  # package; the per-output hashHex returned by configFile() is the
  # NDE0-S-namespaced hash, but downstream consumers read the file
  # content (whose hash is the load-bearing thing for cache-key
  # propagation — any knob change that re-emits content re-emits the
  # storePath via the NDE0-S hash too).
  result.configFile = configFile(
    path = Nde0kConfigUsedPath,
    content = renderKernelConfig(cfg),
    storeRoot = cfg.storeRoot)

  # bzImage / systemMap / kernelRelease use the NDE0-K-namespaced
  # chain-derived hashes directly so the chain is observable in the
  # outputs' storePaths (the acceptance test enforces:
  #   - changing only enableHypervDrm re-keys bzImage + systemMap but
  #     leaves kernelRelease unchanged).
  result.bzImage = plantStub(
    path = Nde0kBzImagePath,
    content = renderBzImageStub(cfg, cfgHash),
    sentinel = ".nde0k-bzImage",
    hash = bzHash,
    storeRoot = cfg.storeRoot)

  result.systemMap = plantStub(
    path = Nde0kSystemMapPath,
    content = renderSystemMapStub(cfg, cfgHash),
    sentinel = ".nde0k-systemMap",
    hash = smHash,
    storeRoot = cfg.storeRoot)

  result.kernelRelease = plantStub(
    path = Nde0kKernelReleasePath,
    content = renderKernelReleaseFile(cfg),
    sentinel = ".nde0k-kernelRelease",
    hash = krHash,
    storeRoot = cfg.storeRoot)

# ---------------------------------------------------------------------------
# Convenience: list every output's store paths in a stable order.
# ---------------------------------------------------------------------------

proc storePaths*(outs: KernelOutputs): seq[string] =
  ## Stable enumeration of every emitted store path. Sort discipline
  ## matches the spec'd activation order: configFile first (the build
  ## input the others derive from), then bzImage (the bootable
  ## artefact), then systemMap (the symbol table for debugging), then
  ## kernelRelease (the release-string discovery file).
  result = @[
    outs.configFile.storePath,
    outs.bzImage.storePath,
    outs.systemMap.storePath,
    outs.kernelRelease.storePath]

proc sortedStorePaths*(outs: KernelOutputs): seq[string] =
  ## Lexicographically-sorted variant for byte-cmp scenarios.
  result = storePaths(outs)
  result.sort(cmp[string])
