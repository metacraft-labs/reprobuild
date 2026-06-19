## Source-from-tarball alsa-lib recipe — the SIXTY-SEVENTH real
## from-source production recipe to exercise the M9.H/I/K trio. alsa-lib
## is the userspace half of the Advanced Linux Sound Architecture: every
## modern Linux audio stack (pipewire / wireplumber / pulseaudio /
## jackd / Plasma's KMix / GNOME's gnome-control-center sound panel)
## ultimately routes through ``libasound.so`` for the kernel /dev/snd/*
## ioctl surface.
##
## alsa-lib joins ``pipewireSource`` + ``wireplumberSource`` +
## ``networkManagerSource`` in the network + audio infrastructure batch
## adding the four runtime daemons + libraries every modern desktop
## (sway / GNOME / Plasma) consumes for sound + networking.
##
## ## Why alsa-lib matters for the v1 desktop story
##
## alsa-lib is the C library half of ALSA — the kernel side ships in
## the Linux kernel's ``sound/`` subtree as the in-tree drivers; the
## userspace side is this library. libasound exposes the PCM / mixer /
## sequencer / control APIs the audio middleware layer (pipewire's
## ``libpipewire-module-alsa-sink``, wireplumber's ALSA session manager
## node) consumes to enumerate devices, set hardware parameters
## (rate / format / channels / period-size / buffer-size), open the
## /dev/snd/pcmCnDp character device, and read/write audio frames.
##
##   * pipewire's ALSA plugin ``libpipewire-module-alsa-source`` /
##     ``libpipewire-module-alsa-sink`` link libasound for the
##     kernel-PCM transport that feeds the pipewire graph.
##   * wireplumber's ``alsa-monitor.lua`` session-policy script
##     enumerates ALSA cards via libasound's ``snd_card_next`` /
##     ``snd_ctl_card_info`` APIs and tags each device with the
##     wireplumber routing-policy metadata.
##   * Pulseaudio's ALSA backend modules
##     (``module-alsa-sink`` / ``module-alsa-source``) consume
##     libasound directly when running in standalone mode (NDE-K1 v1
##     uses pipewire's pulse-bridge so the libasound consumer is
##     pipewire, not standalone pulseaudio).
##   * GStreamer's ``alsasrc`` / ``alsasink`` elements use libasound
##     when the GStreamer pipeline runs on bare-metal ALSA (the
##     pipewire-backed GStreamer pipeline uses ``pipewiresrc`` /
##     ``pipewiresink`` instead).
##
## ## sha256 strategy
##
## Per the network + audio batch convention (matching the kernel +
## recent-batch precedent), we point the live ``fetch:`` URL at upstream
## directly (no vendoring), and pin the sha256 over the upstream
## tarball bytes. The hash is cross-checked against the nixpkgs
## ``alsa-lib`` recipe at ``pkgs/by-name/al/alsa-lib/package.nix`` which
## fetches the same upstream archive via ``mirror://alsa/lib/`` (the
## mirror:// alias resolves to www.alsa-project.org/files/pub/lib/).
##
## ## Version choice — 1.2.15.3 (current upstream stable)
##
## alsa-project.org publishes ALSA releases under
## ``https://www.alsa-project.org/files/pub/lib/alsa-lib-<X>.<Y>.<Z>[.W].tar.bz2``
## and 1.2.15.3 is the current stable in the 1.2.15.x bugfix line as of
## mid-2026 (matches the nixpkgs pin). The libasound ABI has been
## stable since the 1.2.0 cut — any ``>=1.2.0`` covers pipewire +
## wireplumber + pulseaudio consumption.
##
## sha256 = 7b079d614d582cade7ab8db2364e65271d0877a37df8757ac4ac0c8970be861e
##  (cross-checked against nixpkgs's SRI-form
##  ``sha256-ewedYU1YLK3nq42yNk5lJx0Id6N9+HV6xKwMiXC+hh4=`` at
##  ``pkgs/by-name/al/alsa-lib/package.nix``, which decodes to the same
##  hex over the same upstream tarball bytes).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``./configure`` + ``make``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the library artifact via the ``library``
## block so the M9.K artifact registry already knows what shared object
## to expect.
##
## ## Library artifact
##
## alsa-lib's autotools build emits a single load-bearing library:
##
##   * ``libAsound`` — ``libasound.so``, the C library every audio
##                     middleware (pipewire / wireplumber /
##                     pulseaudio / GStreamer-alsa) links against to
##                     reach the kernel /dev/snd/* ioctl surface.
##
## NOTE: alsa-lib also installs the ``alsa-lib`` headers
## (``/usr/include/alsa/*``) + the per-PCM-plugin shared objects
## (``smixer`` / ``plug`` / ``ladspa`` / etc.) under
## ``/usr/lib/alsa-lib/``; v1 only records the canonical libasound
## artifact. Downstream recipes that need the alsa-plugins surface
## would lift the artifact registration in a follow-up batch.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static`` — skip the static archive (not used by the
##                              v1 desktop story; pipewire +
##                              wireplumber link dynamically). Matches
##                              the xz / nettle / libcap-ng precedent.
##   * ``--disable-python``  — skip the optional Python bindings
##                              (``pyalsa``). The v1 desktop story has
##                              no consumer for the Python bindings —
##                              every middleware layer consumes the
##                              native C ABI.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package alsaLibSource:
  ## From-source alsa-lib — sixty-seventh M9.H/I/K production recipe.
  ## The C library half of ALSA — every modern Linux audio stack routes
  ## through ``libasound.so`` for the kernel /dev/snd/* ioctl surface.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Single library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## alsa-project.org release tarball URL — the same URL the live
    ## ``fetch:`` block points at (no vendoring per the network +
    ## audio batch convention).
    ##
    ## ``sourceRepository`` points at the canonical GitHub mirror the
    ## upstream maintainers publish the alsa-lib source tree on
    ## (alsa-project hosts the canonical git tree at
    ## git.alsa-project.org, with GitHub mirroring).
    "1.2.15.3":
      sourceRevision = "v1.2.15.3"
      sourceUrl = "https://www.alsa-project.org/files/pub/lib/alsa-lib-1.2.15.3.tar.bz2"
      sourceRepository = "https://github.com/alsa-project/alsa-lib"

  fetch:
    ## Upstream alsa-project.org URL — out-of-band fetch on first
    ## build, then cached by the M9.K fetch action keyed on
    ## (url, sha256, extractStrip). Matches the kernel-precedent
    ## pattern of NOT vendoring tarballs.
    ##
    ## sha256 was cross-checked against nixpkgs's
    ## ``pkgs/by-name/al/alsa-lib/package.nix`` SRI-form hash
    ## ``sha256-ewedYU1YLK3nq42yNk5lJx0Id6N9+HV6xKwMiXC+hh4=`` which
    ## decodes to the hex value pinned below.
    url: "https://www.alsa-project.org/files/pub/lib/alsa-lib-1.2.15.3.tar.bz2"
    sha256: "7b079d614d582cade7ab8db2364e65271d0877a37df8757ac4ac0c8970be861e"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``. alsa-lib's
    ## release tarball pre-generates ``configure`` but the convention's
    ## fallback re-runs ``autoconf`` if the script is missing.
    "autoconf"
    ## automake provides the ``Makefile.in`` templates the release
    ## tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--disable-static`` to honour the shared-only
    ## build semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools
    ## convention's compile action invokes ``make`` after
    ## ``./configure``.
    "make"
    ## gcc is the host C toolchain — alsa-lib is C99 with light use
    ## of GNU extensions for inline assembly + thread-local storage.
    "gcc >=11"

  configureFlags:
    ## Flag set per the task brief.
    ##
    ## ``--disable-static`` skips the static archive (not used by the
    ## v1 desktop story; pipewire + wireplumber link dynamically).
    ## ``--disable-python`` skips the optional pyalsa Python bindings.
    "--disable-static"
    "--disable-python"

  library libAsound:
    ## ``libasound.so`` — the C library every audio middleware
    ## (pipewire / wireplumber / pulseaudio / GStreamer-alsa) links
    ## against to reach the kernel /dev/snd/* ioctl surface. The
    ## upstream SONAME ``asound`` is camelCased to ``libAsound`` per
    ## the libExpat / libGlib2 / libLzma precedent of preserving the
    ## canonical ``lib`` prefix while PascalCasing the SONAME body.
    ## v1 records the artifact only; the per-artifact build body
    ## lands in M9.L when the convention's make-spawn + install-glue
    ## closes.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
