## Source-from-tarball libseat recipe — the LATEST from-source
## production recipe to close M9.R.57's wlroots session-backend gap.
##
## Follows the wlroots (single library), libinput (library + executable),
## pixman (single library), and dbus-broker (executables only)
## precedents: a meson/ninja build of upstream seatd (which ships both
## the ``libseat`` shared library AND the optional ``seatd`` server
## daemon) fed by a vendored tarball whose sha256 is pinned here for
## deterministic offline test reproduction.
##
## ## Why libseat matters for the NDE-H Sway session-backend story
##
## wlroots 0.19+ conditionally compiles its session support on the
## presence of libseat at meson-setup time: without a pkg-config
## visible ``libseat`` the meson build silently disables the session
## code path and every wlroots-based compositor (Sway, labwc, ...)
## boots with:
##
##   ``[wlr] Cannot create session: disabled at compile-time``
##
## M9.R.56.8's boot-smoke evidence
## (``recipes/reproos-image/run-evidence/m9r56/m9r56_8_wayland-session.log``)
## caught exactly this failure inside SDDM's Wayland session launch
## chain. Adding libseat as a sibling from-source recipe + declaring
## it as a wlroots ``buildDeps`` entry closes the last compile-time
## gap in the sddm → pam → wayland-session → sway chain.
##
## ## Upstream project — seatd (contains both libseat + seatd daemon)
##
## Kenny Levinsen's ``seatd`` upstream at
## ``https://git.sr.ht/~kennylevinsen/seatd`` ships a single meson
## project that produces THREE build products:
##
##   * ``libseat.so``  — the seat-management client library that
##                       wlroots / KWin / Mutter link against to
##                       reserve DRM devices + tty ownership.
##   * ``seatd``       — the optional standalone seat-management
##                       daemon that hands out DRM device fds to
##                       compositors when systemd-logind is not
##                       available.
##   * ``seatd-launch``— a small helper that spawns the seatd daemon
##                       with a private socket.
##
## For the M9.R.57 NDE-H sway story we ONLY need ``libseat.so``. The
## ReproOS image already runs systemd (M9.R.56 line), so libseat's
## builtin backend (bundled seatd-equivalent driven inside the
## compositor process itself) is sufficient. We disable the standalone
## ``seatd`` server daemon + the ``libseat-logind`` link to systemd
## to keep the dependency surface small; the builtin backend covers
## the Sway compositor's needs.
##
## ## Version choice — 0.9.1 (matches Debian / wlroots 0.19 requirement)
##
## seatd's upstream ship cadence is approximately one point-release per
## quarter; 0.9.1 is the current-line stable that wlroots 0.19 was
## written against (wlroots' meson probe accepts any ABI-compat
## ``libseat >=0.6.0``, so 0.9.1 is safely forward-compatible).
## nixpkgs currently pins ``seatd = 0.9.1`` at
## ``pkgs/os-specific/linux/seatd/default.nix`` as well.
##
## sha256 = 819979c922a0be258aed133d93920bce6a3d3565a60588d6d372ce9db2712cd3
##  (computed locally over the vendored ``seatd-0.9.1.tar.gz``,
##  41,968 bytes; downloaded once from the upstream sr.ht archive URL
##  recorded in ``versions:`` above).
##
## ## Tarball-source note — sr.ht archive vs upstream release
##
## Upstream ``seatd`` does NOT publish a "release dist" tarball the
## way freedesktop.org projects do; releases are tagged in the git
## repo and the canonical distribution format is sr.ht's per-tag
## ``archive.tar.gz`` (git-archive-equivalent). nixpkgs consumes the
## same URL. The vendored copy at
## ``recipes/packages/source/libseat/vendor/seatd-0.9.1.tar.gz`` is
## byte-identical to what sr.ht serves; the recipe references it via
## a file:// URL for offline reproduction.
##
## ## Build shape
##
## The c_cpp_meson convention (M9.K) reads the ``fetch:`` block and
## the inline ``mesonOptions`` (via the M9.R.5b explicit ``build:``
## block) and lowers them into fetch + configure + compile + install
## BuildActions. The recipe declares a single ``library libseat``
## artifact for ``libseat.so``; the M9.L install glue resolves it to
## ``$prefix/lib/libseat.so*``.
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to a
## minimal-libseat baseline per the M9.R.57 task brief:
##
##   * ``libseat-seatd=disabled``  — skip the external seatd daemon
##                                    IPC backend; we don't ship the
##                                    daemon on the ReproOS image.
##   * ``libseat-logind=disabled`` — skip the systemd-logind backend
##                                    link; keeps libseat.so from
##                                    linking libsystemd (which would
##                                    pull in a large transitive
##                                    dependency graph). The builtin
##                                    backend covers Sway's needs.
##   * ``libseat-builtin=enabled`` — enable the builtin backend
##                                    (bundled seatd equivalent
##                                    inside libseat itself); this is
##                                    the ONLY backend the recipe
##                                    ships.
##   * ``server=disabled``         — skip the standalone seatd server
##                                    executable + seatd-launch.
##   * ``examples=disabled``       — skip the example seat clients.
##   * ``man-pages=disabled``      — skip man page generation (no
##                                    scdoc dependency).
##   * ``--buildtype=release``     — release-mode optimisation;
##                                    matches the sibling from-source
##                                    recipes.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libseatSource:
  ## From-source libseat — closes the M9.R.57 wlroots session gap.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the M9.R.5b inlined mesonOptions and lowers them into fetch +
  ## configure BuildActions wired with the right URL + hash + flags.
  ## Single library artifact ``libseat.so``.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the sr.ht archive
    ## URL so a future maintainer running ``repro update-source`` can
    ## re-fetch from upstream; the live ``fetch:`` block below points
    ## at the vendored copy for deterministic offline test
    ## reproduction.
    ##
    ## ``sourceRepository`` points at the upstream sr.ht project ---
    ## seatd's canonical home.
    "0.9.1":
      sourceRevision = "0.9.1"
      sourceUrl = "https://git.sr.ht/~kennylevinsen/seatd/archive/0.9.1.tar.gz"
      sourceRepository = "https://git.sr.ht/~kennylevinsen/seatd"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 41,968-byte tarball
    ## downloaded once from the upstream sr.ht archive URL recorded
    ## in ``versions:`` above.
    url: "https://git.sr.ht/~kennylevinsen/seatd/archive/0.9.1.tar.gz"
    sha256: "819979c922a0be258aed133d93920bce6a3d3565a60588d6d372ce9db2712cd3"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``.
    "meson >=0.59"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — seatd is plain C11 with modest
    ## compiler-flag surface.
    "gcc >=7"
    ## pkg-config is required by libseat's meson probe for libsystemd
    ## (activated by M9.R.57.5's libseat-logind=systemd flip). Matches
    ## the same fix M9.R.57.2b landed on wlroots.
    "pkg-config"

  buildDeps:
    ## libseat's builtin backend uses evdev for input device
    ## enumeration; it links against libudev to walk /dev/input and
    ## reserve device fds for the seat0 owner.
    "libudev >=232"
    ## libsystemd is required for the systemd-logind backend so libseat
    ## can delegate seat / VT / DRM device management to logind when
    ## the process is launched under a logind user session (SDDM +
    ## PAM's pam_systemd.so path). Without this, the compiled-out
    ## logind backend forces libseat's fallback chain onto the
    ## ``builtin`` backend, which needs cap_sys_admin / video-group
    ## ownership + direct tty0 seizure — SDDM has already claimed the
    ## tty at that point, so ``Could not open target tty:
    ## Permission denied`` bubbles out of every wlr_session probe.
    ## M9.R.57.5 (this edit) flips the compile-time gate: the meson
    ## `libseat-logind=systemd` option makes libseat prefer logind
    ## when the runtime env exposes ``/run/systemd/seats/``.
    "libsystemd"

  config:
    ## No prefix lifted from `mesonOptions:`; flags inlined in the `build:` block.
    discard

  library libseat:
    ## ``libseat.so`` — the seat-management client library wlroots'
    ## session backend links against to reserve DRM devices + tty
    ## ownership. v1 records the artifact only; the per-artifact
    ## build body lands in M9.L when the convention's ninja-spawn +
    ## install-glue closes.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `meson_package(...)` constructor.
    setCurrentOwningPackageOverride("libseatSource")
    try:
      let opts = @[
        "libseat-seatd=disabled",
        # M9.R.57.5 — flip logind ON. The builtin backend fallback
        # collides with SDDM's tty0 seizure inside a Wayland session
        # (Could not open target tty: Permission denied); logind
        # delegates seat + VT + DRM device management through the
        # PAM pam_systemd.so path SDDM already uses.
        "libseat-logind=systemd",
        "libseat-builtin=enabled",
        "server=disabled",
        "examples=disabled",
        "man-pages=disabled",
        # M9.R.57.4 — pin libdir=lib for sibling-consumer path stability
        # (wlroots' pkg-config probe searches lib/pkgconfig on every
        # sibling install-mirror path).
        "libdir=lib",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libseat")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
