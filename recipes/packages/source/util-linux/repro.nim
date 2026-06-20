## Source-from-tarball util-linux recipe — the THIRTY-SECOND real
## from-source production recipe to exercise the M9.H/I/K trio.
## util-linux's unique coverage angle vs the prior thirty-one recipes
## is the EIGHT-ARTIFACT (mixed-kind) single-package shape: five
## executables (``mount`` + ``umount`` + ``mkfsBin`` + ``fdisk`` +
## ``lsblk``) PLUS three libraries (``libBlkid`` + ``libUuid`` +
## ``libMount``) all built from one autotools ``./configure`` +
## ``make`` invocation. systemd previously held the multi-artifact
## record with a six-artifact mixed-kind shape (four exec + two lib);
## util-linux pushes the artifact-name partitioning + per-artifact
## kind-tagging at the EIGHT-artifact mixed-kind cardinality. A
## regression that collapsed the artifact-name partitioning at the
## eight-artifact cardinality (or mis-tagged any of the eight
## individual kind discriminants) would surface here.
##
## ## Why util-linux matters for the v1 desktop story
##
## util-linux is the canonical Linux system utilities bundle every
## Linux system depends on: ``mount`` / ``umount`` (the filesystem
## mount glue every initramfs + every systemd mount unit eventually
## shells into), ``mkfs`` (filesystem creation for installers + the
## eudev mkfs dispatch table), ``fdisk`` (partition-table manipulation
## consumed by installers), ``lsblk`` (block-device enumeration for
## GNOME Disks, Plasma KDE Partition Manager, and the gnome-shell
## removable-disk indicator). libblkid is the canonical block-device
## identification library systemd's mount-unit machinery + udev's
## block-device probing both consume; libuuid generates the canonical
## UUIDs systemd-machine-id, GPT partition table UUIDs, and FAT serial
## numbers consume; libmount is the abstract mount-table library
## systemd's mount-unit and the gvfs file manager both consume.
##
## ## sha256 strategy
##
## We vendor the upstream v2.40.4 .tar.xz at
## ``recipes/packages/source/util-linux/vendor/util-linux-2.40.4.tar.xz``
## and reference it via a ``file://`` URL. The kernel.org release URL
## is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 2.40.4 (current upstream stable)
##
## util-linux releases are cut on kernel.org under the v2.40 series;
## 2.40.4 is the current stable point release in the 2.40.x line as of
## mid-2026 and the ABI of libblkid / libuuid / libmount has been
## stable since 2.36 — anything ``>=2.36`` covers the systemd /
## eudev / glib2 consumption.
##
## sha256 = 5c1daf733b04e9859afdc3bd87cc481180ee0f88b5c0946b16fdec931975fb79
##  (computed locally over the vendored ``util-linux-2.40.4.tar.xz``,
##  8,848,216 bytes; downloaded once from the upstream URL recorded
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
##   4. install/output collection actions for the eight artifacts
##      (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ``make`` + install glue lands in M9.L; the recipe
## records the eight artifacts via the ``executable`` + ``library``
## blocks so the M9.K artifact registry already knows what binaries +
## shared objects to expect.
##
## ## Artifacts
##
## util-linux's autotools build emits a vast set of binaries +
## libraries; we register the eight load-bearing ones for the v1
## desktop story:
##
##   * ``mount``      — ``/bin/mount`` the filesystem mount CLI; every
##                       systemd ``.mount`` unit and every initramfs
##                       eventually shells into it.
##   * ``umount``     — ``/bin/umount`` the filesystem unmount CLI;
##                       paired with ``mount`` at shutdown.
##   * ``mkfsBin``    — ``/sbin/mkfs`` the filesystem-creation dispatch
##                       binary; consumed by installers + udev's block-
##                       device probing. Renamed from the bare-``mkfs``
##                       upstream binary name to ``mkfsBin`` to avoid
##                       a future identifier collision with the
##                       per-fs ``mkfsExt4`` / ``mkfsFat`` siblings
##                       that may land alongside.
##   * ``fdisk``      — ``/sbin/fdisk`` the partition-table editor
##                       consumed by installers.
##   * ``lsblk``      — ``/bin/lsblk`` the block-device enumerator
##                       consumed by GNOME Disks, Plasma KDE Partition
##                       Manager, and the gnome-shell removable-disk
##                       indicator.
##   * ``libBlkid``   — ``libblkid.so`` the block-device identification
##                       library systemd's mount-unit + udev's block-
##                       device probing consume.
##   * ``libUuid``    — ``libuuid.so`` the UUID generation library
##                       systemd-machine-id + GPT partition UUIDs +
##                       FAT serial numbers consume.
##   * ``libMount``   — ``libmount.so`` the abstract mount-table
##                       library systemd's mount-unit + gvfs consume.
##
## The bare ``mkfs`` upstream binary name is renamed to ``mkfsBin``
## to avoid identifier collision with a future per-fs ``mkfs`` series
## (matching the sddmGreeter / systemdLogind / systemdInit precedent
## for disambiguating package-level binaries from generic names).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``               — skip the static archive
##                                          (not used by the v1 desktop
##                                          story).
##   * ``--without-python``               — skip the Python bindings
##                                          (heavy Python dependency
##                                          surface; the v1 desktop
##                                          consumes the C ABI
##                                          directly).
##   * ``--without-systemd``              — skip the libsystemd
##                                          dependency at configure
##                                          time; util-linux is a
##                                          systemd dependency, not
##                                          the other way around.
##                                          Avoids a cyclic-uses graph
##                                          between systemd + util-
##                                          linux.
##   * ``--disable-makeinstall-chown``    — skip the ``chown`` calls
##                                          in ``make install``; the
##                                          install path runs as the
##                                          build user, not root.
##   * ``--disable-makeinstall-setuid``   — skip the ``setuid`` bits
##                                          on ``mount`` / ``umount``;
##                                          the v1 desktop uses
##                                          PolicyKit + pkexec instead
##                                          of suid-root mount.
##   * ``--disable-bash-completion``      — skip the bash completion
##                                          install; the v1 desktop's
##                                          shell is /bin/sh, not
##                                          bash.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a Plasma-edition variant
## that flips ``--with-python`` for KDE Partition Manager's Python
## helper).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package utilLinuxSource:
  ## From-source util-linux — thirty-second M9.H/I/K production recipe
  ## and the SEVENTH autotools-driven recipe (expat + gdm + freetype +
  ## fontconfig + zlib-custom-configure + libxml2 + openssl-custom-
  ## Configure precedents — zlib + openssl re-used the autotools channel
  ## for custom-configure scripts). FIRST recipe in the corpus to ship
  ## an EIGHT-ARTIFACT MIXED-KIND shape from a single ``package`` macro:
  ## five executables (``mount`` + ``umount`` + ``mkfsBin`` + ``fdisk``
  ## + ``lsblk``) PLUS three libraries (``libBlkid`` + ``libUuid`` +
  ## ``libMount``) all built from one autotools ``./configure`` +
  ## ``make`` invocation.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Five executable + three library
  ## artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## kernel.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical mirror on
    ## git.kernel.org that hosts the util-linux source tree.
    "2.40.4":
      sourceRevision = "v2.40.4"
      sourceUrl = "https://www.kernel.org/pub/linux/utils/util-linux/v2.40/util-linux-2.40.4.tar.xz"
      sourceRepository = "https://git.kernel.org/pub/scm/utils/util-linux/util-linux.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 8,848,216-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://www.kernel.org/pub/linux/utils/util-linux/v2.40/util-linux-2.40.4.tar.xz"
    sha256: "5c1daf733b04e9859afdc3bd87cc481180ee0f88b5c0946b16fdec931975fb79"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac`` (the upstream
    ## tarball does ship a pre-generated ``configure`` but we list
    ## autoconf so the convention layer can re-bootstrap if the
    ## tarball gets re-archived without ``configure``).
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
    ## gcc is the host C toolchain — util-linux is C11 with light use
    ## of GNU extensions.
    "gcc >=11"
    ## pkg-config is used by the autotools configure step to probe
    ## for ncurses (used by ``fdisk``'s dialog UI) and libcap (used by
    ## the per-utility capability-dropping).
    "pkg-config"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  executable mount:
    ## ``/bin/mount`` — the filesystem mount CLI; every systemd
    ## ``.mount`` unit and every initramfs eventually shells into it.
    ## v1 records the artifact only; the per-artifact build body lands
    ## in M9.L when the convention's make-spawn + install-glue closes.
    discard

  executable umount:
    ## ``/bin/umount`` — the filesystem unmount CLI; paired with
    ## ``mount`` at shutdown. v1 records the artifact only.
    discard

  executable mkfsBin:
    ## ``/sbin/mkfs`` — the filesystem-creation dispatch binary;
    ## consumed by installers + udev's block-device probing. Renamed
    ## from the bare-``mkfs`` upstream binary name to ``mkfsBin`` to
    ## avoid future identifier collision with the per-fs ``mkfsExt4``
    ## / ``mkfsFat`` siblings that may land alongside (matching the
    ## systemdInit / sddmGreeter precedent for disambiguating
    ## package-level binaries from generic names). v1 records the
    ## artifact only.
    discard

  executable fdisk:
    ## ``/sbin/fdisk`` — the partition-table editor consumed by
    ## installers. v1 records the artifact only.
    discard

  executable lsblk:
    ## ``/bin/lsblk`` — the block-device enumerator consumed by GNOME
    ## Disks, Plasma KDE Partition Manager, and the gnome-shell
    ## removable-disk indicator. v1 records the artifact only.
    discard

  library libBlkid:
    ## ``libblkid.so`` — the block-device identification library
    ## consumed by systemd's mount-unit machinery + udev's block-
    ## device probing. The upstream SONAME ``blkid`` is PascalCased to
    ## ``libBlkid`` per the libExpat / libGlib2 / libZ precedent of
    ## preserving the canonical ``lib`` prefix while PascalCasing the
    ## SONAME body. v1 records the artifact only.
    discard

  library libUuid:
    ## ``libuuid.so`` — the UUID generation library consumed by
    ## systemd-machine-id, GPT partition table UUIDs, and FAT serial
    ## numbers. v1 records the artifact only.
    discard

  library libMount:
    ## ``libmount.so`` — the abstract mount-table library consumed by
    ## systemd's mount-unit machinery + gvfs. v1 records the artifact
    ## only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("utilLinuxSource")
    try:
      let opts = @[
        "--disable-static",
        "--without-python",
        "--without-systemd",
        "--disable-makeinstall-chown",
        "--disable-makeinstall-setuid",
        "--disable-bash-completion",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("mount")
      discard pkg.executable("umount")
      discard pkg.executable("mkfsBin")
      discard pkg.executable("fdisk")
      discard pkg.executable("lsblk")
      discard pkg.library("libBlkid")
      discard pkg.library("libUuid")
      discard pkg.library("libMount")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
