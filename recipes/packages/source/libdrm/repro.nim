## Source-from-tarball libdrm recipe — the SECOND real from-source
## production recipe to exercise the M9.H/I/K trio
## (fetch: + mesonOptions: + convention-layer fetch-action emission).
##
## Mirrors the dbus-broker source recipe pattern: a meson/ninja build
## of upstream libdrm fed by a vendored tarball whose sha256 is pinned
## here for deterministic offline test reproduction.
##
## ## Why libdrm matters for the NDE-G graphics-stack story
##
## ``recipes/packages/de-foundation/graphics-stack/repro.nim`` ships
## the user-facing graphics-stack config glue (modesetting policy,
## /etc/X11 fragments). libdrm is the user-space DRM ioctl wrapper that
## the entire Mesa stack and the X / Wayland servers consume — without
## it none of the per-card userland drivers can talk to the kernel
## DRM subsystem. This recipe is the upstream-source side of the same
## graphics-stack story; the two recipes are wired into the SAME
## package universe but live at separate paths so the NDE-G config
## emission's cache key stays isolated from the upstream libdrm
## tarball sha256.
##
## ## sha256 strategy
##
## We vendor the upstream 2.4.133 .tar.xz at
## ``recipes/packages/source/libdrm/vendor/libdrm-2.4.133.tar.xz`` and
## reference it via a ``file://`` URL. The upstream
## ``https://dri.freedesktop.org/libdrm/`` URL is recorded as
## ``sourceUrl`` in the ``versions:`` block for documentation and
## future-bump purposes, but the live ``fetch:`` block points at the
## vendored copy so the convention layer's emitted fetch action is
## offline-reproducible.
##
## sha256 = fc68f9d0ba2ea63c9432a299e14fea09fad7a8a66e8039fcd7802ca59f77b4f5
##  (computed locally over the vendored
##  ``libdrm-2.4.133.tar.xz``, 436,912 bytes; matches the
##  ``sha256-/Gj50LoupjyUMqKZ4U/qCfrXqKZugDn814AspZ93tPU=`` SRI hash
##  that nixpkgs ships at ``pkgs/by-name/li/libdrm/package.nix`` —
##  the cross-check confirms the upstream tarball is byte-identical
##  to what the broader ecosystem builds against).
##
## ## Build shape
##
## The c_cpp_meson convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``mesonOptions:`` block off this package's
## registries and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``meson setup`` configure BuildAction that depends on the
##      fetch action and passes every flag in ``mesonOptions:`` to
##      ``meson setup``, in declared order.
##   3. a ``ninja`` compile BuildAction (M9.L).
##   4. install/output collection actions for the three library
##      artifacts (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records the library artifacts via the ``library`` block so the
## M9.K artifact registry already knows what shared objects to
## expect.
##
## ## Library artifacts vs executables
##
## Unlike dbus-broker (which ships two executables), libdrm produces
## ``.so`` shared libraries with no installed CLI binaries. The
## artifact kind is therefore ``library`` (M3 ``dakLibrary``) rather
## than ``executable``. v1 records THREE libraries: the core
## ``libdrm.so`` plus two of the per-vendor side libraries gated on
## the mesonOptions below:
##
##   * ``libdrm.so``         — always built (the core ioctl wrapper).
##   * ``libdrm_amdgpu.so``  — built when ``amdgpu=enabled`` (modern
##                             AMD GPUs; the production default for
##                             desktop targets).
##   * ``libdrm_nouveau.so`` — built when ``nouveau=enabled`` (open
##                             NVIDIA driver).
##
## The other per-vendor side libraries (libdrm_intel, libdrm_radeon,
## libdrm_freedreno, libdrm_vc4, libdrm_etnaviv, libdrm_tegra,
## libdrm_omap, libdrm_exynos) are intentionally disabled in v1 to
## keep the default-target build portable. Per-distro variants would
## flip these toggles via downstream configurables when the
## per-architecture story lands.
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to a
## modern-desktop-baseline set (amdgpu + nouveau on; the legacy /
## embedded / vendor-specific KMS APIs off; man pages + valgrind off
## to keep the build hermetic). Downstream configuration knobs would
## live here when the per-distro variants need different strategies.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libdrmSource:
  ## From-source libdrm — second M9.H/I/K production recipe.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## freedesktop.org tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream gitlab mirror —
    ## libdrm is part of the Mesa project's ``drm`` repository.
    "2.4.133":
      sourceRevision = "libdrm-2.4.133"
      sourceUrl = "https://dri.freedesktop.org/libdrm/libdrm-2.4.133.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/mesa/drm"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 436,912-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above. The same hash is independently shipped by
    ## nixpkgs at ``pkgs/by-name/li/libdrm/package.nix`` (in SRI
    ## form), so a future bump can cross-reference both sources.
    url: "file:///metacraft/reprobuild/recipes/packages/source/libdrm/vendor/libdrm-2.4.133.tar.xz"
    sha256: "fc68f9d0ba2ea63c9432a299e14fea09fad7a8a66e8039fcd7802ca59f77b4f5"
    extractStrip: 1

  uses:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``.
    "meson >=0.59"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — libdrm is plain C11 with no
    ## C++ component, so the C compiler is sufficient.
    "gcc >=7"

  mesonOptions:
    ## Flag set mirroring a modern-desktop baseline. Order is
    ## load-bearing: meson evaluates options left-to-right and the
    ## ``--buildtype=release`` sentinel lives at the tail so any
    ## override (e.g. a future debug-build variant) can append
    ## ``--buildtype=debug`` later without re-ordering this block.
    ##
    ## The per-vendor KMS API toggles are explicit ``enabled`` /
    ## ``disabled`` (libdrm exposes them as meson ``feature`` options
    ## so the tri-state ``auto`` value is the default we override
    ## here for determinism).
    "-Dintel=disabled"
    "-Dradeon=disabled"
    "-Damdgpu=enabled"
    "-Dnouveau=enabled"
    "-Dvmwgfx=disabled"
    "-Dfreedreno=disabled"
    "-Dvc4=disabled"
    "-Detnaviv=disabled"
    "-Dtegra=disabled"
    "-Dvalgrind=disabled"
    "-Dman-pages=disabled"
    "--buildtype=release"

  library libdrm:
    ## ``libdrm.so`` — the core user-space ioctl wrapper. Built
    ## unconditionally from the libdrm meson build.
    ## v1 records the artifact only; the per-artifact build body
    ## lands in M9.L when the convention's ninja-spawn + install-glue
    ## closes.
    discard

  library libdrmAmdgpu:
    ## ``libdrm_amdgpu.so`` — modern-AMD-GPU side library, gated on
    ## ``-Damdgpu=enabled`` above.
    discard

  library libdrmNouveau:
    ## ``libdrm_nouveau.so`` — open NVIDIA driver side library,
    ## gated on ``-Dnouveau=enabled`` above.
    discard
