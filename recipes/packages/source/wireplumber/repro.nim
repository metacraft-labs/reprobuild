## Source-from-tarball wireplumber recipe — the SIXTY-NINTH real
## from-source production recipe to exercise the M9.H/I/K trio.
## wireplumber is THE session/policy manager for pipewire: where
## pipewire owns the multimedia graph and provides the per-client
## negotiation, wireplumber implements the Lua-scripted session-policy
## layer that decides which devices map to which roles + how
## per-application audio streams get linked to outputs.
##
## wireplumber joins ``alsaLibSource`` + ``pipewireSource`` +
## ``networkManagerSource`` in the network + audio infrastructure batch
## adding the four runtime daemons + libraries every modern desktop
## (sway / GNOME / Plasma) consumes.
##
## ## Why wireplumber matters for the v1 desktop story
##
## pipewire alone is just the multimedia graph — without a session
## manager nothing decides "which mic feeds the default capture
## stream", "which output gets the Firefox tab's audio", or "what
## happens when a USB headset is hot-plugged". wireplumber owns those
## policy decisions:
##
##   * **Session policy**: ``policy-default-nodes.lua`` selects the
##     default audio source / sink per-role (Music / Notification /
##     Communication / etc.). NDE-K1's audio probes verify the default
##     sink picks up after pipewire startup.
##   * **Hot-plug response**: ``alsa-monitor.lua`` listens to udev
##     ALSA device-add / device-remove events and creates pipewire
##     nodes for each kernel PCM device. USB headset plug-in fires
##     this path.
##   * **Per-application routing**: wireplumber's session-policy
##     scripts honour pipewire stream metadata
##     (``media.role`` / ``application.process.machine-id``) for
##     per-application output selection (e.g. routing
##     ``application.id="org.mozilla.firefox"`` to a specific sink).
##   * **Bluetooth audio**: wireplumber's
##     ``bluez-hardware.lua`` policy script maps Bluetooth SCO / A2DP
##     codec profiles onto pipewire nodes. NDE-K1's audio story
##     requires wireplumber for any Bluetooth headset path.
##
## ## sha256 strategy
##
## Per the network + audio batch convention (matching the kernel +
## recent-batch precedent), we point the live ``fetch:`` URL at upstream
## directly (no vendoring), and pin the sha256 over the upstream tarball
## bytes.
##
## The sha256 below pins the upstream gitlab.freedesktop.org tarball
## bytes (downloaded + ``sha256sum``ed). This differs from the
## nixpkgs ``fetchFromGitLab`` SRI hash which is computed over the
## NAR-form EXTRACTED directory contents rather than the tarball
## bytes — GitLab's ``/archive/<tag>/<repo>-<tag>.tar.gz`` carries
## mutable tarball metadata (gzip mtime + tar block padding) that the
## NAR canonicalisation strips. The version cross-check still holds:
## nixpkgs pins 0.5.14 as the current upstream stable; this recipe
## matches.
##
## ## Version choice — 0.5.14 (current upstream stable)
##
## wireplumber releases are cut on gitlab.freedesktop.org under tags of
## the form ``<X>.<Y>.<Z>``. 0.5.14 is the current stable in the 0.5.x
## line as of mid-2026 (matches the nixpkgs pin). The 0.5.x line
## targets pipewire 1.x and the libwireplumber-0.5 SONAME has been
## stable since 0.5.0.
##
## ## Build shape
##
## The c_cpp_meson convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``mesonOptions:`` block off this package's
## registries and lowers them into fetch + ``meson setup`` + ``ninja``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the executable + library artifacts via the
## ``executable`` + ``library`` blocks so the M9.K artifact registry
## already knows what binary + shared object to expect.
##
## ## Artifacts
##
## wireplumber's meson build emits a small set of binaries +
## libraries; we register the two load-bearing ones for the v1
## desktop story:
##
##   * ``wireplumber``     — ``/usr/bin/wireplumber``, the session
##                            manager daemon that runs alongside
##                            pipewire and owns the Lua-scripted
##                            policy layer. Started by
##                            ``wireplumber.service`` (user-session
##                            systemd unit) on every login, after
##                            pipewire.service comes up.
##   * ``libWireplumber``  — ``libwireplumber-0.5.so``, the C library
##                            exposing the WirePlumber Core API
##                            (``WpCore``, ``WpNode``, ``WpSession``)
##                            consumed by the per-policy Lua scripts
##                            + external session-policy plugins.
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``documentation=disabled`` — skip the documentation build
##                                    (heavy hotdoc dependency surface,
##                                    not needed at runtime).
##   * ``introspection=disabled`` — skip GObject Introspection
##                                    (drops the g-ir-scanner toolchain
##                                    dep; matches glib2 +
##                                    plasma-workspace precedents).
##   * ``system-lua=true``         — use system lua (Lua 5.4 from the
##                                    glibc dependency tree) instead of
##                                    building wireplumber's vendored
##                                    Lua sub-project.
##   * ``tests=false``             — skip the upstream test suite.
##   * ``--buildtype=release``     — release-mode optimisation; matches
##                                    the sibling from-source recipes.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package wireplumberSource:
  ## From-source wireplumber — sixty-ninth M9.H/I/K production recipe.
  ## THE session/policy manager for pipewire: implements the
  ## Lua-scripted session-policy layer that decides device-to-role
  ## mappings + per-application audio routing on top of pipewire's
  ## multimedia graph.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. One-executable + one-library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## gitlab.freedesktop.org archive URL — the same URL the live
    ## ``fetch:`` block points at (no vendoring per the network +
    ## audio batch convention).
    ##
    ## ``sourceRepository`` points at the canonical
    ## gitlab.freedesktop.org project that hosts the wireplumber
    ## source tree.
    "0.5.14":
      sourceRevision = "0.5.14"
      sourceUrl = "https://gitlab.freedesktop.org/pipewire/wireplumber/-/archive/0.5.14/wireplumber-0.5.14.tar.gz"
      sourceRepository = "https://gitlab.freedesktop.org/pipewire/wireplumber"

  fetch:
    ## Upstream gitlab.freedesktop.org archive URL — out-of-band
    ## fetch on first build, then cached by the M9.K fetch action
    ## keyed on (url, sha256, extractStrip).
    ##
    ## The sha256 pins the tarball bytes returned by GitLab. nixpkgs
    ## records a NAR-form SRI hash over the EXTRACTED directory
    ## contents via ``fetchFromGitLab``; that hash is NOT the same
    ## as the tarball-bytes hash here. The recipe surface is
    ## complete; the version cross-check (0.5.14 matches nixpkgs)
    ## already holds.
    url: "https://gitlab.freedesktop.org/pipewire/wireplumber/-/archive/0.5.14/wireplumber-0.5.14.tar.gz"
    sha256: "e91f04cd8cec75d72b8a2aaa7e90b1ba0a5e2094b7a882fc3a29a484a48a87e9"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``. wireplumber 0.5
    ## requires meson 0.59 for the modern dependency-fallback
    ## semantics it relies on.
    "meson >=0.59"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — wireplumber is C99 + GObject
    ## with light use of GNU extensions.
    "gcc >=11"
    ## pkg-config is used by the meson configure step to probe for
    ## the pipewire + glib2 + lua + libsystemd dependencies.
    "pkg-config"

  buildDeps:
    ## pipewire supplies ``libpipewire-0.3`` — wireplumber is a
    ## first-party pipewire client and links every WpCore /
    ## WpSession primitive against it.
    "pipewire >=1.0"
    ## glib2 supplies ``libglib-2.0`` + ``libgobject-2.0`` +
    ## ``libgio-2.0`` — the WirePlumber object model is GObject-based
    ## and the session-manager main loop integrates with GMainLoop.
    "glib2 >=2.62"
    ## systemd supplies ``libsystemd`` for the sd-bus integration
    ## that drives wireplumber's portal-bus bridge + the sd-notify
    ## integration with the user-session systemd unit.
    "systemd >=240"

  config:
    ## No prefix lifted from `mesonOptions:`; flags inlined in the `build:` block.
    discard
  executable wireplumber:
    ## ``/usr/bin/wireplumber`` — the session manager daemon that runs
    ## alongside pipewire and owns the Lua-scripted policy layer.
    ## Started by ``wireplumber.service`` (user-session systemd unit)
    ## on every login, after ``pipewire.service`` comes up. v1
    ## records the artifact only; the per-artifact build body lands
    ## in M9.L when the convention's ninja-spawn + install-glue
    ## closes.
    discard

  library libWireplumber:
    ## ``libwireplumber-0.5.so`` — the C library exposing the
    ## WirePlumber Core API (``WpCore``, ``WpNode``, ``WpSession``)
    ## consumed by the per-policy Lua scripts + external
    ## session-policy plugins (e.g. distro overrides at
    ## ``/etc/wireplumber/main.lua.d/``). The SONAME's version suffix
    ## ``-0.5`` is stripped in the artifact identifier (matching the
    ## libPipewire / libGlib2 precedent of stripping version
    ## suffixes). v1 records the artifact only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `meson_package(...)` constructor.
    setCurrentOwningPackageOverride("wireplumberSource")
    try:
      let opts = @[
        "-Ddocumentation=disabled",
        "-Dintrospection=disabled",
        "-Dsystem-lua=true",
        "-Dtests=false",
        "--buildtype=release",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("wireplumber")
      discard pkg.library("libWireplumber")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
