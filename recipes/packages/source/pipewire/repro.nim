## Source-from-tarball pipewire recipe — the SIXTY-EIGHTH real
## from-source production recipe to exercise the M9.H/I/K trio.
## pipewire is THE modern multimedia framework on Linux: it replaces
## pulseaudio for audio routing AND jackd for pro-audio low-latency AND
## provides the screen-capture / camera-sharing transport every Wayland
## compositor (sway / mutter / kwin_wayland) uses for desktop sharing +
## screen recording over portal interfaces.
##
## pipewire joins ``alsaLibSource`` + ``wireplumberSource`` +
## ``networkManagerSource`` in the network + audio infrastructure batch
## adding the four runtime daemons + libraries every modern desktop
## (sway / GNOME / Plasma) consumes.
##
## ## Why pipewire matters for the v1 desktop story
##
## pipewire is the single multimedia daemon every NDE-K1 v1 desktop
## starts on session login:
##
##   * **Audio path**: pipewire's session daemon (paired with
##     wireplumber's session manager) replaces the historical
##     pulseaudio daemon for the per-application audio mix. The
##     ``pipewire-pulse`` compatibility shim bridges legacy
##     pulseaudio-API consumers (Firefox / Chromium / Discord /
##     Spotify) onto the pipewire graph.
##   * **Pro-audio path**: pipewire's ``pipewire-jack`` shim provides
##     a binary-compatible libjack.so so jackd-API consumers
##     (Ardour / Reaper / Bitwig) work without recompilation.
##   * **Screen sharing**: pipewire's ``libpipewire-module-portal``
##     + the ``xdg-desktop-portal-{gtk,kde,wlr}`` desktop portal
##     daemons wire compositor screen-capture buffers
##     (mutter / kwin / wlroots) into application consumers via
##     DMA-BUF over pipewire stream nodes. Every Wayland desktop's
##     screen-recording + window-sharing flow routes through this.
##   * **Camera sharing**: pipewire's libcamera + V4L2 source nodes
##     enumerate webcams + provide a unified camera-sharing API the
##     browser stack (Chromium / Firefox WebRTC) and conference
##     apps (Zoom / Teams native flatpaks) consume.
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
## mutable tarball metadata (file mtime / gzip mtime / tar block
## padding) that the NAR canonicalisation strips. The version
## cross-check still holds: nixpkgs pins 1.6.5 as the current
## upstream stable; this recipe matches.
##
## ## Version choice — 1.6.5 (current upstream stable)
##
## pipewire releases are cut on gitlab.freedesktop.org under tags of
## the form ``<X>.<Y>.<Z>``. 1.6.5 is the current stable as of mid-2026
## (matches the nixpkgs pin). The libpipewire-0.3 ABI has been stable
## since the 0.3 cut; the major-version-zero "0.3.x" line continued
## through 1.0+ with the same ABI (pipewire's versioning skipped to
## 1.0 for marketing reasons while keeping libpipewire-0.3 as the
## SONAME).
##
## ## Build shape
##
## The c_cpp_meson convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``mesonOptions:`` block off this package's
## registries and lowers them into fetch + ``meson setup`` + ``ninja``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the executable + executable + library
## artifacts via the two ``executable`` + one ``library`` block so the
## M9.K artifact registry already knows what binaries + shared object
## to expect.
##
## ## Artifacts
##
## pipewire's meson build emits a sprawling set of binaries +
## libraries + per-module SPA plugins; we register the three
## load-bearing ones for the v1 desktop story:
##
##   * ``pipewireDaemon`` — ``/usr/bin/pipewire``, the multimedia
##                          server daemon that owns the graph + the
##                          per-client connection negotiation. Started
##                          by ``pipewire.service`` (user-session
##                          systemd unit) on every login.
##   * ``pwCat``          — ``/usr/bin/pw-cat``, the audio capture +
##                          playback CLI (with ``pw-record`` /
##                          ``pw-play`` symlinks). Used by NDE-K1's
##                          audio probes + by desktop notifications
##                          (mako / dunst) for the "beep on critical
##                          notification" path.
##   * ``libPipewire``    — ``libpipewire-0.3.so``, the C library every
##                          consumer (wireplumber session manager,
##                          GStreamer ``pipewiresrc`` / ``pipewiresink``,
##                          xdg-desktop-portal screen-share backend)
##                          links against to open client connections
##                          + create stream nodes.
##
## The bare-``pipewire`` upstream binary name is renamed to
## ``pipewireDaemon`` to avoid identifier collision with the package
## name's ``pipewire`` prefix (matching the systemdInit / sddmGreeter
## naming convention for disambiguating package-level daemon binaries
## from short package names). The hyphenated ``pw-cat`` is camelCased
## to ``pwCat``. The SONAME's version suffix ``-0.3`` is stripped in
## the artifact identifier (matching the libGlib2 / libGObject
## precedent of stripping ``-2.0`` suffixes).
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``tests=disabled``     — skip the upstream test suite to keep
##                                the build hermetic + fast.
##   * ``docs=disabled``      — skip the documentation build.
##   * ``examples=disabled``  — skip the bundled example apps
##                                (``pw-mon`` / etc. helpers stay; only
##                                the standalone examples/ tree is
##                                dropped).
##   * ``man=disabled``       — skip man-page generation.
##   * ``--buildtype=release`` — release-mode optimisation; matches the
##                                sibling from-source recipes.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package pipewireSource:
  ## From-source pipewire — sixty-eighth M9.H/I/K production recipe.
  ## THE modern multimedia framework on Linux: replaces pulseaudio +
  ## jackd for audio AND provides the screen-capture transport every
  ## Wayland compositor uses for desktop sharing + screen recording.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Two-executable + one-library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## gitlab.freedesktop.org archive URL — the same URL the live
    ## ``fetch:`` block points at (no vendoring per the network +
    ## audio batch convention).
    ##
    ## ``sourceRepository`` points at the canonical
    ## gitlab.freedesktop.org project that hosts the pipewire source
    ## tree.
    "1.6.5":
      sourceRevision = "1.6.5"
      sourceUrl = "https://gitlab.freedesktop.org/pipewire/pipewire/-/archive/1.6.5/pipewire-1.6.5.tar.gz"
      sourceRepository = "https://gitlab.freedesktop.org/pipewire/pipewire"

  fetch:
    ## Upstream gitlab.freedesktop.org archive URL — out-of-band
    ## fetch on first build, then cached by the M9.K fetch action
    ## keyed on (url, sha256, extractStrip).
    ##
    ## The sha256 pins the tarball bytes returned by GitLab. nixpkgs
    ## records a NAR-form SRI hash over the EXTRACTED directory
    ## contents via ``fetchFromGitLab``; that hash is NOT the same
    ## as the tarball-bytes hash here. The recipe surface is
    ## complete; the version cross-check (1.6.5 matches nixpkgs)
    ## already holds.
    url: "https://gitlab.freedesktop.org/pipewire/pipewire/-/archive/1.6.5/pipewire-1.6.5.tar.gz"
    sha256: "4c9f7e85a760a4169cd4bc668bafea90fe4838aaf3f08a93f11bb9222809d490"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``. pipewire 1.6
    ## requires meson 0.61 for the modern dependency-fallback
    ## semantics it relies on.
    "meson >=0.61"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — pipewire is C11 with light use of
    ## GNU extensions for atomics + cache-line alignment.
    "gcc >=11"
    ## pkg-config is used by the meson configure step to probe for
    ## the alsa-lib + glib2 + dbus + udev + libudev dependencies.
    "pkg-config"

  buildDeps:
    ## alsa-lib supplies ``libasound`` — pipewire's ALSA source +
    ## sink SPA plugins consume it for the kernel /dev/snd/* PCM
    ## transport.
    "alsa-lib >=1.2"
    ## glib2 supplies ``libglib-2.0`` + ``libgobject-2.0`` —
    ## pipewire's GLib main-loop integration and the GStreamer
    ## ``pipewiresrc`` / ``pipewiresink`` GObject types link against
    ## the GObject + GLib type-system runtimes.
    "glib2 >=2.62"
    ## dbus supplies ``libdbus-1`` — pipewire's session bus probe +
    ## the portal-pipewire bridge use the libdbus client.
    "dbus >=1.12"
    ## systemd supplies ``libsystemd`` for the sd-event integration
    ## that drives pipewire's main loop when running as a systemd
    ## user service.
    "systemd >=240"

  config:
    ## No prefix lifted from `mesonOptions:`; flags inlined in the `build:` block.
    discard
  executable pipewireDaemon:
    ## ``/usr/bin/pipewire`` — the multimedia server daemon that owns
    ## the graph + the per-client connection negotiation. Renamed
    ## from the bare-``pipewire`` upstream binary name to
    ## ``pipewireDaemon`` to avoid identifier collision with the
    ## package name's ``pipewire`` prefix (matching the systemdInit /
    ## sddmGreeter naming convention for disambiguating package-level
    ## daemon binaries from short package names). v1 records the
    ## artifact only; the per-artifact build body lands in M9.L when
    ## the convention's ninja-spawn + install-glue closes.
    discard

  executable pwCat:
    ## ``/usr/bin/pw-cat`` — the audio capture + playback CLI (with
    ## ``pw-record`` / ``pw-play`` symlinks). Used by NDE-K1's audio
    ## probes + by desktop notifications (mako / dunst) for the
    ## "beep on critical notification" path. The hyphenated upstream
    ## binary name ``pw-cat`` is camelCased to ``pwCat``. v1 records
    ## the artifact only.
    discard

  library libPipewire:
    ## ``libpipewire-0.3.so`` — the C library every consumer
    ## (wireplumber session manager, GStreamer ``pipewiresrc`` /
    ## ``pipewiresink``, xdg-desktop-portal screen-share backend)
    ## links against to open client connections + create stream nodes.
    ## The SONAME's version suffix ``-0.3`` is stripped in the
    ## artifact identifier (matching the libGlib2 / libGObject
    ## precedent of stripping ``-2.0`` suffixes). v1 records the
    ## artifact only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `meson_package(...)` constructor.
    setCurrentOwningPackageOverride("pipewireSource")
    try:
      let opts = @[
        "tests=disabled",
        "docs=disabled",
        "examples=disabled",
        "man=disabled",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("pipewireDaemon")
      discard pkg.executable("pwCat")
      discard pkg.library("libPipewire")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
