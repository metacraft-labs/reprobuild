## Source-from-tarball procps recipe — the FORTY-EIGHTH real
## from-source production recipe to exercise the M9.H/I/K trio.
## procps is the canonical Linux process-utilities userland — every
## ``ps`` / ``top`` / ``free`` / ``kill`` / ``uptime`` call on every
## modern Linux distribution flows through the libproc2 ABI this
## recipe lifts.
##
## ## Why procps matters for the v1 desktop story
##
## procps (upstream branded as ``procps-ng``) is the GNU/Linux process-
## utilities suite. The binaries this recipe registers are the load-
## bearing surface every shell session, every monitoring agent, and
## every sysadmin diagnostic playbook depends on:
##
##   * ``ps`` is the canonical process-state CLI; every shell session
##     uses it (``ps aux | grep ...``), every monitoring agent shells
##     into it to gather process-state snapshots, and every container-
##     runtime debug path enumerates PIDs through it.
##   * ``top`` is the interactive process-monitor TUI; sysadmins run
##     it on first contact with a hot box.
##   * ``free`` is the memory-summary CLI consumed by every "is the
##     box swapping" diagnostic.
##   * ``kill`` is the signal-delivery CLI consumed by every shutdown
##     script + every supervisor (s6 / runit / systemd-when-not-using-
##     systemctl) at termination time.
##   * ``uptime`` is the load-average CLI consumed by every health-
##     check script.
##
## ``libproc2.so`` is the C library every modern monitoring tool
## (``htop``, ``glances``, ``btop``) links against rather than parsing
## ``/proc/<pid>/`` directly.
##
## ## sha256 strategy
##
## We vendor the upstream v4.0.5 GitLab archive .tar.gz at
## ``recipes/packages/source/procps/vendor/procps-v4.0.5.tar.gz`` and
## reference it via a ``file://`` URL. The gitlab.com archive URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 4.0.5 (current upstream stable)
##
## procps-ng releases are cut on gitlab.com under tags of the form
## ``v<X>.<Y>.<Z>``. 4.0.5 is the current stable in the 4.x line as of
## mid-2026 and the libproc2 ABI has been stable since the 4.0 cut
## (the 3.x -> 4.x bump renamed ``libprocps.so`` to ``libproc2.so`` and
## reshaped the API; anything ``>=4.0`` covers the htop + glances + btop
## consumption).
##
## sha256 = 2c6d7ed9f2acde1d4dd4602c6172fe56eff86953fe8639bd633dbd22cc18f5db
##  (computed locally over the vendored ``procps-v4.0.5.tar.gz``,
##  2,392,641 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape — custom autoreconf
##
## procps's GitLab archive ships ``configure.ac`` but NO pre-generated
## ``configure`` script (unlike the kernel.org release tarballs that
## pre-generate it). The c_cpp_autotools convention's lowering runs
## ``autoreconf -fi`` (via the ``autoconf`` tool dependency declared in
## ``uses:``) before invoking ``./configure``. The ``--disable-nls``
## flag elides the gettext dependency surface that the
## ``autoreconf`` pass would otherwise activate.
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``autoreconf`` +
## ``./configure`` + ``make`` BuildActions; the per-artifact build body
## + install glue lands in M9.L; the recipe records the six artifacts
## via the ``library`` + ``executable`` blocks so the M9.K artifact
## registry already knows what shared object + binaries to expect.
##
## ## Artifacts
##
## procps's autotools build emits six load-bearing outputs from a
## single ``./configure`` + ``make`` invocation:
##
##   * ``ps``       — ``/bin/ps`` the process-state CLI.
##   * ``top``      — ``/usr/bin/top`` the interactive process-monitor.
##   * ``free``     — ``/usr/bin/free`` the memory-summary CLI.
##   * ``kill``     — ``/bin/kill`` the signal-delivery CLI.
##   * ``uptime``   — ``/usr/bin/uptime`` the load-average CLI.
##   * ``libProc``  — ``libproc2.so`` the process-introspection C
##                    library consumed by htop + glances + btop.
##
## The upstream SONAME ``proc2`` is PascalCased to ``libProc`` per the
## task brief (matches the libCap / libExpat / libGlib2 precedent of
## preserving the canonical ``lib`` prefix while PascalCasing the
## SONAME body, with the ``2`` version-suffix folded into the
## convention layer's lib-versioning metadata). The binary names
## (``ps``, ``top``, ``free``, ``kill``, ``uptime``) are already
## unambiguous and used bare.
##
## NOTE: ``kill`` here is the procps-ng ``kill`` not the util-linux
## ``kill``; coreutils's ``--enable-no-install-program=kill`` flag
## (forty-third recipe) defers to this binary at install time, so the
## two recipes do not produce conflicting artifacts at the desktop's
## ``/usr/bin/kill`` slot.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``   — skip the static archive (not used by
##                               the v1 desktop story; libs are
##                               dynamic).
##   * ``--disable-nls``      — skip the native-language-support
##                               gettext dependency surface (heavy
##                               .mo/.po pipeline, not needed for the
##                               v1 desktop's English-locale default).
##   * ``--with-systemd=no``  — skip the libsystemd dependency at
##                               configure time; procps is a systemd
##                               dependency in the other direction
##                               (systemctl shells into ``ps`` for
##                               unit-state probes). Avoids a cyclic
##                               uses graph between systemd + procps.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package procpsSource:
  ## From-source procps-ng — forty-eighth M9.H/I/K production recipe.
  ## The canonical Linux process-utilities userland: ``ps`` + ``top`` +
  ## ``free`` + ``kill`` + ``uptime`` + ``libproc2.so`` all built from
  ## one autotools ``./configure`` + ``make`` invocation. FIRST recipe
  ## in the corpus to consume the GitLab archive endpoint
  ## (``/-/archive/<tag>/<name>-<tag>.tar.gz``); the prior forty-seven
  ## from-source recipes used kernel.org / freedesktop / GitHub / GNOME
  ## / KDE / freedesktop endpoints.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + autoreconf + configure BuildActions wired
  ## with the right URL + hash + flags. Five executable + one library
  ## artifact recipe.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## gitlab.com archive URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical procps-ng project
    ## on gitlab.com.
    "4.0.5":
      sourceRevision = "v4.0.5"
      sourceUrl = "https://gitlab.com/procps-ng/procps/-/archive/v4.0.5/procps-v4.0.5.tar.gz"
      sourceRepository = "https://gitlab.com/procps-ng/procps"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 2,392,641-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/procps/vendor/procps-v4.0.5.tar.gz"
    sha256: "2c6d7ed9f2acde1d4dd4602c6172fe56eff86953fe8639bd633dbd22cc18f5db"
    extractStrip: 1

  uses:
    ## autoconf is REQUIRED (not just a fallback): procps's GitLab
    ## archive ships ``configure.ac`` but NO pre-generated
    ## ``configure`` script, so the convention layer runs
    ## ``autoreconf -fi`` before ``./configure``.
    "autoconf"
    ## automake provides the ``Makefile.in`` templates the
    ## ``autoreconf`` pass generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--disable-static`` to honour the shared-only build
    ## semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — procps is C11 + GNU extensions.
    "gcc >=11"
    ## pkg-config is used by the autotools configure step to probe for
    ## ncurses (used by ``top``'s TUI).
    "pkg-config"

  configureFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: the ``./configure`` script
    ## evaluates options left-to-right and the ``--with-systemd=no``
    ## sentinel lives at the tail so any override (e.g. a future
    ## systemd-edition variant) can append ``--with-systemd=yes``
    ## later without re-ordering this block.
    ##
    ## ``--disable-static`` skips the static archive.
    ## ``--disable-nls`` skips the native-language-support gettext
    ##                    dependency surface.
    ## ``--with-systemd=no`` skips the libsystemd dependency (avoids
    ##                        cyclic uses with the systemd recipe).
    "--disable-static"
    "--disable-nls"
    "--with-systemd=no"

  executable ps:
    ## ``/bin/ps`` — the process-state CLI consumed by every shell
    ## session, every monitoring agent, every container-runtime debug
    ## path. v1 records the artifact only; the per-artifact build body
    ## lands in M9.L when the convention's make-spawn + install-glue
    ## closes.
    discard

  executable top:
    ## ``/usr/bin/top`` — the interactive process-monitor TUI sysadmins
    ## run on first contact with a hot box. v1 records the artifact
    ## only.
    discard

  executable free:
    ## ``/usr/bin/free`` — the memory-summary CLI consumed by every
    ## "is the box swapping" diagnostic. v1 records the artifact only.
    discard

  executable kill:
    ## ``/bin/kill`` — the signal-delivery CLI consumed by every
    ## shutdown script. NOTE: procps-ng ``kill`` not util-linux
    ## ``kill``; coreutils's ``--enable-no-install-program=kill`` flag
    ## (forty-third recipe) defers to THIS binary at install time. v1
    ## records the artifact only.
    discard

  executable uptime:
    ## ``/usr/bin/uptime`` — the load-average CLI consumed by every
    ## health-check script. v1 records the artifact only.
    discard

  library libProc:
    ## ``libproc2.so`` — the process-introspection C library consumed
    ## by htop + glances + btop. The upstream SONAME ``proc2`` is
    ## PascalCased to ``libProc`` per the task brief (matches the
    ## libCap / libExpat / libGlib2 precedent of preserving the
    ## canonical ``lib`` prefix while PascalCasing the SONAME body,
    ## with the ``2`` version-suffix folded into the convention layer's
    ## lib-versioning metadata). v1 records the artifact only.
    discard
