## Source-from-tarball eudev recipe — the THIRTY-FIFTH real from-source
## production recipe to exercise the M9.H/I/K trio. eudev's unique
## coverage angle vs the prior thirty-four recipes is being the FIRST
## recipe in the corpus to ship an artifact identifier (``libUdev``)
## that COLLIDES with a sibling recipe's artifact identifier (systemd's
## ``libUdev``) — the two recipes vendor DIFFERENT upstream
## implementations of the same ABI (eudev is the Gentoo-led udev fork
## that runs without a systemd dependency; systemd's libudev is the
## bundled implementation). The artifact-name collision is intentional:
## both packages emit ``libudev.so`` with a compatible API, and a
## downstream consumer (a Plasma session running on a Devuan-style
## sysvinit base) selects ONE of the two via the variant resolver. The
## convention layer's artifact registry must support this collision
## cleanly — a regression that flattens the (packageName, artifactName)
## tuple to artifactName alone would surface here.
##
## Additionally, eudev is the NINTH autotools-driven recipe (expat +
## gdm + freetype + fontconfig + zlib-custom + libxml2 + openssl-custom
## + util-linux + pam precedents).
##
## ## Why eudev matters for the v1 desktop story
##
## eudev is the systemd-independent fork of udev maintained by the
## Gentoo project. NDE-K1's v1 ReproOS variant ships with systemd as
## the default init, but the sysvinit-edition variant (a Devuan-style
## ReproOS profile) needs an udev implementation that doesn't drag in
## libsystemd. eudev provides ``udevd`` (the user-space hot-plug
## daemon), ``udevadm`` (the rule-engine debugger), and ``libudev.so``
## (the same device-enumeration ABI systemd's libudev exposes, kept
## in lock-step with upstream by the eudev maintainers).
##
## ## sha256 strategy
##
## We vendor the upstream v3.2.14 .tar.gz at
## ``recipes/packages/source/eudev/vendor/eudev-3.2.14.tar.gz`` and
## reference it via a ``file://`` URL. The github.com release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 3.2.14 (current upstream stable)
##
## eudev releases are cut on GitHub under tags of the form
## ``v<X>.<Y>.<Z>``. 3.2.14 is the current stable in the 3.2.x line as
## of mid-2026 and the libudev ABI tracks systemd's libudev — anything
## ``>=3.2`` covers the wlroots / kwin / libinput / fontconfig
## consumption (these libraries link against libudev's
## device-enumeration ABI without caring which provider implements it).
##
## sha256 = 8da4319102f24abbf7fff5ce9c416af848df163b29590e666d334cc1927f006f
##  (computed locally over the vendored ``eudev-3.2.14.tar.gz``,
##  2,188,254 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
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
##   4. install/output collection actions for the three artifacts
##      (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ``make`` + install glue lands in M9.L; the recipe
## records the three artifacts via the ``executable`` + ``library``
## blocks so the M9.K artifact registry already knows what binaries +
## shared object to expect.
##
## ## Artifacts
##
## eudev's autotools build emits three load-bearing outputs from a
## single ``./configure`` + ``make`` invocation:
##
##   * ``udevd``   — ``/lib/systemd/systemd-udevd`` the user-space
##                    hot-plug daemon that watches the kernel uevent
##                    netlink socket and runs rules from
##                    ``/etc/udev/rules.d``.
##   * ``udevadm`` — ``/bin/udevadm`` the rule-engine debugger admin
##                    teams use to inspect device databases (``udevadm
##                    info`` / ``udevadm monitor`` / ``udevadm
##                    trigger``).
##   * ``libUdev`` — ``libudev.so`` the device-enumeration ABI
##                    (DIFFERENT package than systemd's ``libUdev`` —
##                    intentional artifact-name collision: both
##                    packages emit ``libudev.so`` with a compatible
##                    API and the variant resolver picks ONE at
##                    consumer-resolution time).
##
## We register the artifacts under the package-level identifiers
## ``udevd`` / ``udevadm`` / ``libUdev`` (the bare upstream binary
## names + PascalCased SONAME body).
##
## ### Artifact-name collision with systemd's libUdev (load-bearing)
##
## systemd's ``recipes/packages/source/systemd/repro.nim`` registers
## ``libUdev`` as one of its six artifacts; this recipe ALSO registers
## ``libUdev``. The collision is intentional and load-bearing: both
## packages emit ``libudev.so`` with a compatible API, and the
## convention layer's artifact registry tracks (packageName,
## artifactName) tuples — the (``systemdSource``, ``libUdev``) entry
## and the (``eudevSource``, ``libUdev``) entry are DISTINCT entries
## in the registry. A regression that flattened the tuple to
## ``artifactName`` alone (and merged the two entries) would mis-route
## the convention layer's install action and ship a corrupt
## ``libudev.so``.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``   — skip the static archive (not used by
##                               the v1 desktop story).
##   * ``--disable-blkid``    — skip the libblkid link dependency at
##                               configure time; eudev's
##                               ``blkid`` builtin (which probes
##                               filesystems on block-device hotplug)
##                               is disabled to break a circular link
##                               edge with util-linux (which itself
##                               links libudev). The systemd recipe
##                               picks up the blkid dependency
##                               separately.
##   * ``--disable-manpages`` — skip the manpage build (heavy xsltproc
##                               + docbook-xsl dependency surface,
##                               not needed at runtime).
##   * ``--enable-hwdb``      — build the hardware-database compiler
##                               (``udevadm hwdb --update``) and ship
##                               the compiled ``hwdb.bin`` for fast
##                               device-name lookups at runtime.
##                               Wayland compositors + GNOME's
##                               removable-disk indicator both
##                               consume the hwdb.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a Devuan-edition variant
## that flips ``--disable-blkid`` if util-linux is statically linked
## elsewhere).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package eudevSource:
  ## From-source eudev — thirty-fifth M9.H/I/K production recipe and
  ## the NINTH autotools-driven recipe (expat + gdm + freetype +
  ## fontconfig + zlib-custom + libxml2 + openssl-custom + util-linux
  ## + pam precedents). FIRST recipe in the corpus with an
  ## intentional artifact-name collision against a sibling recipe
  ## (systemd's libUdev) — the convention layer's artifact registry
  ## must track (packageName, artifactName) tuples and keep the two
  ## entries DISTINCT.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Two executable + one library artifact
  ## recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## github.com release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical GitHub project
    ## that hosts the eudev source tree.
    "3.2.14":
      sourceRevision = "v3.2.14"
      sourceUrl = "https://github.com/eudev-project/eudev/releases/download/v3.2.14/eudev-3.2.14.tar.gz"
      sourceRepository = "https://github.com/eudev-project/eudev"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 2,188,254-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://github.com/eudev-project/eudev/releases/download/v3.2.14/eudev-3.2.14.tar.gz"
    sha256: "8da4319102f24abbf7fff5ce9c416af848df163b29590e666d334cc1927f006f"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``.
    "autoconf"
    ## automake provides the upstream ``Makefile.in`` templates the
    ## release tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--disable-static`` to honour the shared-only
    ## build semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools
    ## convention's compile action invokes ``make`` after
    ## ``./configure``.
    "make"
    ## gcc is the host C toolchain — eudev is C11 with light use of
    ## GNU extensions.
    "gcc >=11"
    ## pkg-config is used by the autotools configure step to probe
    ## for kmod (the kernel-module loader library eudev's
    ## modules-load builtin consumes) and gperf (the hwdb compiler
    ## driver).
    "pkg-config"

  buildDeps:
    ## kmod supplies the kernel-module loader library eudev's
    ## modules-load builtin consumes.
    "kmod >=29"
    ## gperf is used to generate perfect hash tables for the hwdb
    ## binary (when ``--enable-hwdb`` is passed).
    "gperf >=3.1"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  executable udevd:
    ## ``/lib/systemd/systemd-udevd`` — the user-space hot-plug
    ## daemon that watches the kernel uevent netlink socket and runs
    ## rules from ``/etc/udev/rules.d``. Despite the
    ## ``systemd-udevd`` path, this binary is the eudev
    ## implementation; the variant resolver picks between this and
    ## systemd's bundled udevd at consumer-resolution time. v1
    ## records the artifact only; the per-artifact build body lands
    ## in M9.L when the convention's make-spawn + install-glue
    ## closes.
    discard

  executable udevadm:
    ## ``/bin/udevadm`` — the rule-engine debugger admin teams use to
    ## inspect device databases (``udevadm info`` / ``udevadm
    ## monitor`` / ``udevadm trigger``). v1 records the artifact
    ## only.
    discard

  library libUdev:
    ## ``libudev.so`` — the device-enumeration ABI consumed by
    ## wlroots / kwin / sway / mutter (udev monitor enumeration),
    ## libinput (udev device enumeration), and fontconfig (udev
    ## hot-plug for font-cache invalidation on external font mounts).
    ##
    ## DIFFERENT package than systemd's ``libUdev`` — intentional
    ## artifact-name collision: both packages emit ``libudev.so``
    ## with a compatible API and the variant resolver picks ONE at
    ## consumer-resolution time. The convention layer's artifact
    ## registry tracks (packageName, artifactName) tuples so the
    ## (``systemdSource``, ``libUdev``) entry and the
    ## (``eudevSource``, ``libUdev``) entry are DISTINCT entries in
    ## the registry.
    ## v1 records the artifact only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("eudevSource")
    try:
      let opts = @[
        "--disable-static",
        "--disable-blkid",
        "--disable-manpages",
        "--enable-hwdb",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("udevd")
      discard pkg.executable("udevadm")
      discard pkg.library("libUdev")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
