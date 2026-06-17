## Source-from-tarball gdm recipe — the SEVENTEENTH real from-source
## production recipe to exercise the M9.H/I/K trio and the SECOND
## recipe in the GNOME stack batch (mutter / gdm / gnome-shell).
##
## Prior sixteen from-source recipes — thirteen meson (dbus-broker,
## libdrm, wayland, wlroots, sway, libxkbcommon, pixman, libinput,
## cairo, pango, gdk-pixbuf, glib2, mutter), one make (linux-kernel),
## one CMake (json-c), one autotools (expat) — collectively covered
## every M9.I flag-injection channel at least once. gdm is the second
## autotools-driven recipe (expat was the first) and the first
## autotools recipe to ship TWO executable artifacts from a single
## ``package`` macro: the GDM daemon (``gdm``) and the greeter session
## binary (``gdm-greeter-session``). The unique coverage angle vs
## expat (single-library autotools) is twofold: (a) two ``executable``
## blocks under one ``package``, and (b) a richer
## ``configureFlags:`` set exercising both ``--disable-*`` and
## ``--without-*`` and ``--with-*`` and ``--enable-*`` autotools-flag
## conventions in one sequence.
##
## ## Why gdm matters for the v1 desktop story
##
## gdm (GNOME Display Manager) is the login-screen daemon NDE-G1 ships
## as its session entry point. The systemd ``gdm.service`` unit
## ``ExecStart``s the gdm daemon, which in turn spawns the greeter
## (PAM-authenticated login screen) and on successful login launches
## a per-user gnome-shell session under the user's UID. NDE-G1's
## ``display-manager.service`` symlinks to ``gdm.service``.
##
## ## sha256 strategy
##
## We vendor the upstream 47.0 .tar.xz at
## ``recipes/packages/source/gdm/vendor/gdm-47.0.tar.xz`` and
## reference it via a ``file://`` URL. The download.gnome.org release
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Version choice — 47.0 (current upstream stable in the 47.x line)
##
## download.gnome.org publishes gdm releases at
## ``https://download.gnome.org/sources/gdm/`` and 47.0 is the
## current stable in the 47.x line as of mid-2026 (gdm follows the
## GNOME release cadence but ships fewer point releases than mutter /
## gnome-shell). Matching the 47.x major line keeps the gdm <-> mutter
## <-> gnome-shell ABI trio coherent.
##
## sha256 = c5858326bfbcc8ace581352e2be44622dc0e9e5c2801c8690fd2eed502607f84
##  (computed locally over the vendored ``gdm-47.0.tar.xz``,
##  936,172 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H
## ``fetch:`` block and the M9.I ``configureFlags:`` block off this
## package's registries and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``./configure`` BuildAction that depends on the fetch action
##      and passes every flag in ``configureFlags:`` to the upstream
##      configure script, in declared order.
##   3. a ``make`` compile BuildAction (M9.L).
##   4. install/output collection actions for the executable artifacts
##      (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ``make`` + install glue lands in M9.L; the recipe
## records the executable artifacts via two ``executable`` blocks so
## the M9.K artifact registry already knows what binaries to expect.
##
## ## Executable artifacts
##
## gdm's autotools build emits two binaries:
##
##   * ``gdm`` — the daemon that ``gdm.service`` ``ExecStart``s; the
##                long-running display-manager process that owns the
##                login VT and spawns greeter / session children.
##   * ``gdm-greeter-session`` — the PAM-authenticated greeter binary
##                                gdm spawns as the login-screen UI;
##                                runs as the unprivileged gdm user.
##
## We register the daemon under the package-level identifier ``gdm``
## (the upstream binary name matches the package name; no
## disambiguation needed because the package identifier here is
## ``gdmSource``, not ``gdm``), and the greeter under
## ``gdmGreeterSession`` (camelCased from the hyphenated upstream
## binary name per the gdk-pixbuf -> gdkPixbuf precedent).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``         — skip the static archive (not
##                                     used by the v1 desktop story;
##                                     cuts build time + cache size).
##                                     Matches the expat precedent.
##   * ``--without-plymouth``       — skip the Plymouth boot-splash
##                                     integration (Plymouth is not
##                                     in the v1 NDE-G1 dep set).
##   * ``--without-systemdsystemunitdir`` — disable upstream's
##                                          automatic systemd unit
##                                          install path probing
##                                          (NDE-G1's manifest layer
##                                          owns the unit-install
##                                          path explicitly).
##   * ``--with-default-pam-config=none`` — opt out of upstream's
##                                          per-distro PAM config
##                                          templating (NDE-G1's
##                                          PAM-config layer owns
##                                          ``/etc/pam.d/gdm`` etc).
##   * ``--disable-wayland-support=false`` — enable Wayland session
##                                            launching (the v1 NDE-G1
##                                            is pure-Wayland; the
##                                            ``=false`` flips the
##                                            ``--disable-*``
##                                            polarity ON, the
##                                            autotools idiom for
##                                            opting INTO a feature
##                                            via a ``--disable``
##                                            flag).
##   * ``--enable-gdm-xsession``    — enable the gdm-xsession wrapper
##                                     script that the greeter
##                                     invokes to launch a session
##                                     (named with a historical
##                                     ``xsession`` prefix; in
##                                     pure-Wayland mode it still
##                                     wires the Wayland session
##                                     entry).
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a Plymouth-enabled variant
## that flips ``--with-plymouth`` for splash-enabled bundles).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package gdmSource:
  ## From-source gdm — seventeenth M9.H/I/K production recipe and the
  ## SECOND autotools-driven from-source recipe (expat was the first).
  ## First autotools recipe to ship TWO executable artifacts from a
  ## single ``package`` macro.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention
  ## layer reads the ``fetch:`` block (registered via
  ## ``registeredFetchSpec``) and the ``configureFlags:`` block
  ## (registered via ``registeredBuildFlags`` on the ``"configure"``
  ## channel) and lowers them into fetch + configure BuildActions
  ## wired with the right URL + hash + flags. Two executable
  ## artifact recipe.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.gnome.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream GNOME gitlab
    ## project --- gdm's canonical home.
    "47.0":
      sourceRevision = "47.0"
      sourceUrl = "https://download.gnome.org/sources/gdm/47/gdm-47.0.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/gdm"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 936,172-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/gdm/vendor/gdm-47.0.tar.xz"
    sha256: "c5858326bfbcc8ace581352e2be44622dc0e9e5c2801c8690fd2eed502607f84"
    extractStrip: 1

  uses:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``.
    "autoconf"
    ## automake provides the upstream ``Makefile.in`` templates the
    ## release tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--disable-static`` to honour the shared-only build
    ## semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools
    ## convention's compile action invokes ``make`` after
    ## ``./configure``.
    "make"
    ## gcc is the host C toolchain — gdm is C11 with light use of
    ## autoconf macros.
    "gcc >=11"
    ## glib2 is the foundation library gdm's daemon + greeter consume
    ## (GMainLoop event loop, GDBus client/server for accountsservice
    ## + logind IPC, GSettings for configuration). The sibling
    ## ``glib2Source`` recipe vendors 2.82.5 to match.
    "glib2 >=2.62"
    ## pam is the authentication-stack library gdm's greeter consumes
    ## to authenticate logins against ``/etc/pam.d/gdm``.
    "pam >=1.5"
    ## libxkbcommon is the keyboard-keymap library gdm's greeter
    ## consumes to handle layout selection / password entry input.
    "libxkbcommon >=1.5"

  configureFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: the ``./configure`` script
    ## evaluates options left-to-right and the ``--enable-gdm-xsession``
    ## sentinel lives at the tail so any override (e.g. a future
    ## xsession-disabled variant) can append ``--disable-gdm-xsession``
    ## later without re-ordering this block.
    ##
    ## ``--disable-static`` skips the static archive.
    ## ``--without-plymouth`` skips the Plymouth integration.
    ## ``--without-systemdsystemunitdir`` disables automatic systemd
    ## unit install path probing.
    ## ``--with-default-pam-config=none`` opts out of per-distro PAM
    ## config templating.
    ## ``--disable-wayland-support=false`` enables Wayland session
    ## launching.
    ## ``--enable-gdm-xsession`` enables the gdm-xsession wrapper
    ## script.
    "--disable-static"
    "--without-plymouth"
    "--without-systemdsystemunitdir"
    "--with-default-pam-config=none"
    "--disable-wayland-support=false"
    "--enable-gdm-xsession"

  executable gdm:
    ## ``/usr/sbin/gdm`` — the GNOME Display Manager daemon. The
    ## long-running display-manager process that owns the login VT
    ## and spawns greeter / session children. NDE-G1's
    ## ``gdm.service`` unit ``ExecStart``s this binary directly.
    ## v1 records the artifact only; the per-artifact build body
    ## lands in M9.L when the convention's make-spawn + install-glue
    ## closes.
    discard

  executable gdmGreeterSession:
    ## ``/usr/libexec/gdm-greeter-session`` — the PAM-authenticated
    ## greeter binary gdm spawns as the login-screen UI; runs as the
    ## unprivileged ``gdm`` system user, displays the login form,
    ## hands off to the user session on successful authentication.
    discard
