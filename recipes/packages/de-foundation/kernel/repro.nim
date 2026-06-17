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
## ## Why this layout
##
## The spec worked example uses two DSL block forms not yet recognised
## by ``parsePackageDef`` at
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim``:
##
##   files configFile:
##     build:
##       fs.configFile(
##         path = "/build/config-used",
##         content = kernelConfigContent:
##           CONFIG_DRM = if config.enableDrm: "y" else: "n"
##           CONFIG_DRM_HYPERV = if config.enableHypervDrm: "y" else: "n"
##           # ... full config table ...
##       )
##
##   executable bzImage:
##     build:
##       input configFile.output
##       kernelCompile.build(
##         source = linuxSource.tree,
##         config = configFile.output,
##         output = "build/bzImage"
##       )
##
## ``parsePackageDef`` currently recognises only ``executable`` /
## ``library`` / ``uses`` / ``config`` / ``outputs`` section heads —
## ``files <name>:`` block form, ``executable <name>: build:`` block
## form with non-trivial body, and the ``kernelConfigContent:`` /
## ``kernelCompile.build()`` calls inside them are pure DSL spec at
## this point. NDE0-A + NDE0-S + NDE0-D + NDE0-G all documented the
## same limitation. The runtime semantics of these blocks live in the
## planted config-used + bzImage stub files emitted by the impl module.
##
## ## Configurables
##
## Per the spec NDE0-K section. Each maps to a field on
## ``KernelConfig`` in the impl module. Toggling any of them invalidates
## only the outputs that consume it (the impl module's per-output
## hash-derivation chain propagates the change atomically; the
## unaffected outputs stay cached). See the impl module's
## ``KernelOutputs`` docstring for the full invalidation matrix.
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
##   package in a follow-up NDEM milestone.
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
##
## * **``files configFile:`` + ``executable bzImage:`` DSL blocks**:
##   pure DSL spec at this point. Semantics encoded directly in the
##   Nim helpers exported from the impl module.

import repro_project_dsl

# The stdlib impl module that owns the emission helpers + the rendered
# config-used / bzImage stub text. Imported here so it is in scope for
# downstream packages that ``uses: "reproos-kernel >=0.1.0"`` and inline
# a ``build:`` block invoking the procs directly.
import repro_dsl_stdlib/packages/de_foundation/kernel as kernelImpl
export kernelImpl

package reproosKernel:
  ## NDE0-K native kernel package.
  ##
  ## Downstream Tier-1 packages (NDEM1 system-generation switching)
  ## ``uses:`` this and consume the exported ``materializeKernel``
  ## proc to obtain the emission outputs (the /build/config-used
  ## .config snapshot at content-addressed path; the /build/bzImage v1
  ## stub; the /build/System.map v1 stub; the /build/KERNELRELEASE
  ## file with the resolved release string).
  ##
  ## Conceptual DSL declarations (surface not yet implemented;
  ## semantics encoded directly in the impl module's helpers):
  ##
  ##   files configFile:
  ##     build:
  ##       fs.configFile(
  ##         path = "/build/config-used",
  ##         content = kernelConfigContent:
  ##           CONFIG_DRM = if config.enableDrm: "y" else: "n"
  ##           CONFIG_DRM_HYPERV = if config.enableHypervDrm: "y" else: "n"
  ##           CONFIG_FB = if config.enableFramebuffer: "y" else: "n"
  ##           CONFIG_USER_NS = if config.enableUserNs: "y" else: "n"
  ##           CONFIG_OVERLAY_FS = if config.enableOverlayFs: "y" else: "n"
  ##           CONFIG_VIRTIO_GPU = if config.enableVirtioGpu: "y" else: "n"
  ##       )
  ##
  ##   executable bzImage:
  ##     build:
  ##       input configFile.output
  ##       kernelCompile.build(
  ##         source = linuxSource.tree,
  ##         config = configFile.output,
  ##         output = "build/bzImage"
  ##       )

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
    ## ``configFile`` / ``ManagedFiles`` / ``DefaultStoreRoot``
    ## helpers (re-exported via kernel.nim's import chain). When the
    ## spec'd ``fs.configFile`` surface lands as a standalone module,
    ## NDE0-K + NDE0-S + NDE0-D + NDE0-G all migrate to that
    ## together.
    "systemd-session >=0.1.0"
