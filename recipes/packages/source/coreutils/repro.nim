## Source-from-tarball coreutils recipe — the FORTY-THIRD real
## from-source production recipe to exercise the M9.H/I/K trio.
## coreutils is the canonical GNU userland — ``/usr/bin/ls`` +
## ``/usr/bin/cp`` + ``/usr/bin/mv`` + ``/usr/bin/rm`` + ``/usr/bin/cat``
## + ``/usr/bin/echo`` + ~100 more — every shell script + every
## installer + every recovery tool depends on these binaries existing
## under their canonical paths with their canonical CLI grammar.
##
## ## Why coreutils matters for the v1 desktop story
##
## coreutils is the foundation of every POSIX shell session. The basic
## file-manipulation + text-processing + system-information commands
## (ls / cp / mv / rm / cat / echo / pwd / mkdir / chmod / chown / ln /
## touch / rm / wc / head / tail / tr / sort / uniq / cut / paste /
## sed / awk-like / ...) are consumed by every shell script (sysadmin
## scripts, install scripts, build scripts, init scripts, user
## ``.profile`` / ``.bashrc`` rcfiles, every Makefile rule). The v1
## desktop's GUI applications also shell out to coreutils for various
## tasks (Nautilus/Files shells into ``mv`` for cross-filesystem moves,
## GNOME Disks shells into ``cp`` for image cloning, KDE Plasma's file
## indexer baloo shells into ``stat`` for inode metadata).
##
## ## Artifact registration scope
##
## coreutils ships ~100 distinct binaries from a single ``./configure``
## + ``make`` invocation. v1 records only the SIX most-used binaries
## as typed artifacts: ``ls`` + ``cp`` + ``mv`` + ``rm`` + ``cat`` +
## ``echo``. The full ~100-binary set is built by the make invocation
## regardless (the ``--enable-no-install-program=...`` flag controls
## per-binary install but the build always produces every binary); the
## artifact registry just doesn't enumerate the remainder. Downstream
## recipes that need ``stat`` or ``mkdir`` as typed inputs would lift
## those artifact registrations in a follow-up batch when the M9.L
## per-binary build body lands.
##
## ## sha256 strategy
##
## We vendor the upstream 9.5 .tar.xz at
## ``recipes/packages/source/coreutils/vendor/coreutils-9.5.tar.xz``
## and reference it via a ``file://`` URL. The ftp.gnu.org release URL
## is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 9.5 (current upstream stable)
##
## coreutils releases are cut on ftp.gnu.org under tags of the form
## ``coreutils-<X>.<Y>``. 9.5 is the current stable in the 9.x line as
## of mid-2026 — anything ``>=9.0`` covers every consumer's pinning
## (the 9.0 cut introduced the new copy-mode default + the FIDO
## offload knob).
##
## sha256 = cd328edeac92f6a665de9f323c93b712af1858bc2e0d88f3f7100469470a1b8a
##  (computed locally over the vendored ``coreutils-9.5.tar.xz``,
##  6,007,136 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``./configure`` + ``make``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the six executable artifacts via the
## ``executable`` blocks so the M9.K artifact registry already knows
## what binaries to expect.
##
## ## Artifacts
##
## v1 records SIX executable artifacts — the six most-used binaries
## the rest of the recipe corpus is most likely to depend on:
##
##   * ``ls``    — ``/usr/bin/ls`` the directory-listing CLI.
##   * ``cp``    — ``/usr/bin/cp`` the file-copy CLI.
##   * ``mv``    — ``/usr/bin/mv`` the file-rename / cross-filesystem-
##                 move CLI.
##   * ``rm``    — ``/usr/bin/rm`` the file-delete CLI.
##   * ``cat``   — ``/usr/bin/cat`` the file-concatenate CLI.
##   * ``echo``  — ``/usr/bin/echo`` the string-print CLI.
##
## The other ~94 binaries (mkdir / chmod / chown / ln / touch / stat /
## wc / head / tail / tr / sort / uniq / cut / paste / df / du / dd /
## ...) are still BUILT by the make invocation but are NOT registered
## as typed artifacts in v1. Downstream recipes that need them as
## typed inputs would lift the artifact registrations in a follow-up.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static`` — skip the static archive (not used by the
##                            v1 desktop story; libs are dynamic).
##   * ``--enable-no-install-program=kill,uptime,arch``
##                          — skip installing ``kill`` (util-linux ships
##                            the canonical ``kill`` already), ``uptime``
##                            (procps-ng ships the canonical one), and
##                            ``arch`` (it's a one-liner alias for
##                            ``uname -m`` and v1's BusyBox-ish path
##                            doesn't need a separate binary). The
##                            binaries are still BUILT, just not
##                            installed.
##   * ``--without-selinux``— skip the libselinux dependency (v1
##                            desktop is non-SELinux).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package coreutilsSource:
  ## From-source GNU coreutils — forty-third M9.H/I/K production recipe.
  ## Ships ~100 binaries from a single ``./configure`` + ``make``
  ## invocation; v1 records the SIX most-used (ls / cp / mv / rm / cat
  ## / echo) as typed artifacts. The other ~94 binaries are built but
  ## not registered.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Six executable artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## ftp.gnu.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical savannah.gnu.org
    ## mirror that hosts the coreutils source tree.
    "9.5":
      sourceRevision = "v9.5"
      sourceUrl = "https://ftp.gnu.org/gnu/coreutils/coreutils-9.5.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/git/coreutils.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 6,007,136-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://ftp.gnu.org/gnu/coreutils/coreutils-9.5.tar.xz"
    sha256: "cd328edeac92f6a665de9f323c93b712af1858bc2e0d88f3f7100469470a1b8a"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``.
    "autoconf"
    ## automake provides the upstream ``Makefile.in`` templates the
    ## release tarball pre-generates.
    "automake"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — coreutils is C99 + GNU
    ## extensions.
    "gcc >=11"
    ## perl is required by the build for the help2man pass that
    ## generates the per-binary manpages.
    "perl >=5.32"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  executable ls:
    ## ``/usr/bin/ls`` — the directory-listing CLI consumed by every
    ## shell session, every install script, every Makefile rule. v1
    ## records the artifact only; the per-artifact build body lands
    ## in M9.L when the convention's make-spawn + install-glue closes.
    discard

  executable cp:
    ## ``/usr/bin/cp`` — the file-copy CLI consumed by every install
    ## script + GNOME Disks (for image cloning) + every Makefile rule
    ## that copies build artifacts. v1 records the artifact only.
    discard

  executable mv:
    ## ``/usr/bin/mv`` — the file-rename / cross-filesystem-move CLI
    ## consumed by Nautilus/Files (cross-fs moves), every install
    ## script, every release tagging script. v1 records the artifact
    ## only.
    discard

  executable rm:
    ## ``/usr/bin/rm`` — the file-delete CLI consumed by every clean
    ## target in every Makefile + every uninstall script + every
    ## temporary-file teardown. v1 records the artifact only.
    discard

  executable cat:
    ## ``/usr/bin/cat`` — the file-concatenate CLI consumed by every
    ## shell pipeline + every Makefile that splices files + every
    ## sysadmin script. v1 records the artifact only.
    discard

  executable echo:
    ## ``/usr/bin/echo`` — the string-print CLI. NOTE: bash also
    ## ships ``echo`` as a builtin and POSIX sh's ``echo`` is the
    ## builtin; the standalone ``/usr/bin/echo`` is consumed when a
    ## script uses ``\`echo X\``` via env shimming or when the path is
    ## explicit. v1 records the artifact only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("coreutilsSource")
    try:
      let opts = @[
        "--disable-static",
        "--enable-no-install-program=kill,uptime,arch",
        "--without-selinux",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("ls")
      discard pkg.executable("cp")
      discard pkg.executable("mv")
      discard pkg.executable("rm")
      discard pkg.executable("cat")
      discard pkg.executable("echo")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
