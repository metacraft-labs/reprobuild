## Source-from-tarball kmod recipe — the FORTY-SEVENTH real
## from-source production recipe to exercise the M9.H/I/K trio.
## kmod is the canonical Linux kernel-module userland — every
## modprobe / depmod / insmod / rmmod call on every modern Linux
## distribution flows through the libkmod ABI this recipe lifts.
##
## ## Why kmod matters for the v1 desktop story
##
## kmod is the userland half of the kernel-module loader stack. The
## binaries this recipe registers are the load-bearing surface every
## init system, every udev rule, and every container runtime depends
## on at boot:
##
##   * ``modprobe`` resolves a module name (``snd-hda-intel``) into
##     its dependency closure (``snd-hda-codec`` + ``snd-pcm`` + ...)
##     and asks the kernel to load them in order. systemd's
##     ``systemd-modules-load.service`` shells into ``modprobe`` for
##     every entry in ``/etc/modules-load.d/*.conf``; udev rules emit
##     ``modprobe`` calls when a matching device shows up; the v1
##     desktop's GPU + audio + bluetooth + wifi stacks all autoload
##     this way.
##   * ``lsmod`` is the canonical "what modules are loaded" CLI; every
##     sysadmin diagnostic playbook starts here.
##   * ``insmod`` is the raw single-module loader (no dependency
##     resolution); used by initramfs scripts and recovery shells.
##   * ``rmmod`` is the unload counterpart; used at suspend / resume
##     by power-management hooks (e.g. unload + reload of the bcm-wifi
##     driver across a sleep cycle).
##
## ``libkmod.so`` is the C library every modern dbus-activated module-
## management consumer (``ModemManager``, ``NetworkManager``'s wifi
## probe path) links against rather than re-implementing the
## ``/lib/modules/<kver>/`` walk + signature-check.
##
## ## sha256 strategy
##
## We vendor the upstream kmod-33 .tar.xz at
## ``recipes/packages/source/kmod/vendor/kmod-33.tar.xz`` and reference
## it via a ``file://`` URL. The kernel.org release URL is recorded as
## ``sourceUrl`` in the ``versions:`` block for documentation and
## future-bump purposes, but the live ``fetch:`` block points at the
## vendored copy so the convention layer's emitted fetch action is
## offline-reproducible.
##
## ## Version choice — 33 (current upstream stable)
##
## kmod releases are cut on kernel.org under tags of the form
## ``kmod-<X>``. 33 is the current stable as of mid-2026 and the libkmod
## ABI has been stable across the 29-33 cuts — anything ``>=29`` covers
## the systemd + udev + ModemManager + NetworkManager consumption.
##
## sha256 = dc768b3155172091f56dc69430b5481f2d76ecd9ccb54ead8c2540dbcf5ea9bc
##  (computed locally over the vendored ``kmod-33.tar.xz``,
##  514,428 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``./configure`` + ``make``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the five artifacts via the ``library`` +
## ``executable`` blocks so the M9.K artifact registry already knows
## what shared object + binaries to expect.
##
## ## Artifacts
##
## kmod's autotools build emits five load-bearing outputs from a single
## ``./configure`` + ``make`` invocation:
##
##   * ``modprobe`` — ``/sbin/modprobe`` the dependency-resolving
##                    module loader.
##   * ``lsmod``    — ``/sbin/lsmod`` the loaded-module enumerator.
##   * ``insmod``   — ``/sbin/insmod`` the raw single-module loader.
##   * ``rmmod``    — ``/sbin/rmmod`` the module unloader.
##   * ``libKmod``  — ``libkmod.so`` the module-management C library
##                    consumed by ModemManager + NetworkManager.
##
## The upstream SONAME ``kmod`` is PascalCased to ``libKmod`` per the
## libExpat / libZ / libGlib2 / libCap precedent of preserving the
## canonical ``lib`` prefix while PascalCasing the SONAME body. The
## binary names (``modprobe``, ``lsmod``, ``insmod``, ``rmmod``) are
## already unambiguous and used bare.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``       — skip the static archive (not used
##                                   by the v1 desktop story; libs are
##                                   dynamic).
##   * ``--disable-manpages``     — skip the manpage build (heavy
##                                   xsltproc + docbook-xsl dependency
##                                   surface, not needed at runtime).
##   * ``--disable-test-modules`` — skip the in-tree test-module build
##                                   used by the upstream test suite
##                                   (requires kernel headers + a
##                                   running kernel to actually
##                                   exercise; v1 builds the userland
##                                   bits only).
##   * ``--without-openssl``      — skip the OpenSSL dependency for the
##                                   module-signature-verification
##                                   path (v1 desktop's signed-module
##                                   policy lives in the kernel; the
##                                   userland tools don't need to
##                                   re-verify).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package kmodSource:
  ## From-source kmod — forty-seventh M9.H/I/K production recipe.
  ## The canonical Linux kernel-module userland: ``modprobe`` + ``lsmod``
  ## + ``insmod`` + ``rmmod`` + ``libkmod.so`` all built from one
  ## autotools ``./configure`` + ``make`` invocation.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Four executable + one library artifact
  ## recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## kernel.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical mirror on
    ## git.kernel.org that hosts the kmod source tree.
    "33":
      sourceRevision = "v33"
      sourceUrl = "https://www.kernel.org/pub/linux/utils/kernel/kmod/kmod-33.tar.xz"
      sourceRepository = "https://git.kernel.org/pub/scm/utils/kernel/kmod/kmod.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 514,428-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/kmod/vendor/kmod-33.tar.xz"
    sha256: "dc768b3155172091f56dc69430b5481f2d76ecd9ccb54ead8c2540dbcf5ea9bc"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac`` (the upstream
    ## tarball does ship a pre-generated ``configure`` but we list
    ## autoconf so the convention layer can re-bootstrap if the tarball
    ## gets re-archived without ``configure``).
    "autoconf"
    ## automake provides the upstream ``Makefile.in`` templates the
    ## release tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--disable-static`` to honour the shared-only build
    ## semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — kmod is C11 + GNU extensions.
    "gcc >=11"
    ## pkg-config is used by the autotools configure step to probe for
    ## zlib + xz (used by libkmod's compressed-module-image support).
    "pkg-config"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  executable modprobe:
    ## ``/sbin/modprobe`` — the dependency-resolving module loader
    ## consumed by ``systemd-modules-load.service``, udev rules, and
    ## every initramfs script that loads block-device drivers before
    ## mounting root. v1 records the artifact only; the per-artifact
    ## build body lands in M9.L when the convention's make-spawn +
    ## install-glue closes.
    discard

  executable lsmod:
    ## ``/sbin/lsmod`` — the loaded-module enumerator consumed by every
    ## sysadmin diagnostic playbook + the kernel-info applets in GNOME
    ## Tweaks / Plasma Info Center. v1 records the artifact only.
    discard

  executable insmod:
    ## ``/sbin/insmod`` — the raw single-module loader consumed by
    ## initramfs scripts and recovery shells when the dependency-
    ## resolving ``modprobe`` path isn't usable. v1 records the artifact
    ## only.
    discard

  executable rmmod:
    ## ``/sbin/rmmod`` — the module unloader consumed by power-
    ## management hooks (e.g. unload + reload of the bcm-wifi driver
    ## across a sleep cycle) and the suspend/resume path. v1 records
    ## the artifact only.
    discard

  library libKmod:
    ## ``libkmod.so`` — the module-management C library consumed by
    ## ModemManager (modem-driver probing) + NetworkManager (wifi
    ## firmware autoload) + every dbus-activated module-management
    ## consumer that doesn't want to re-implement the
    ## ``/lib/modules/<kver>/`` walk + signature-check. The upstream
    ## SONAME ``kmod`` is PascalCased to ``libKmod`` per the libExpat /
    ## libZ / libGlib2 / libCap precedent of preserving the canonical
    ## ``lib`` prefix while PascalCasing the SONAME body. v1 records
    ## the artifact only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("kmodSource")
    try:
      let opts = @[
        "--disable-static",
        "--disable-manpages",
        "--disable-test-modules",
        "--without-openssl",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("modprobe")
      discard pkg.executable("lsmod")
      discard pkg.executable("insmod")
      discard pkg.executable("rmmod")
      discard pkg.library("libKmod")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
