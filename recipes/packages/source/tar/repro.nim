## Source-from-tarball GNU tar recipe — the SEVENTY-FIRST real from-
## source production recipe to exercise the M9.H/I/K trio. GNU tar is
## THE canonical archive packer/unpacker on every modern Linux
## distribution — ``/usr/bin/tar`` is what every installer / backup
## tool / configuration-management agent / container image builder
## invokes to materialise ``.tar`` / ``.tar.gz`` / ``.tar.xz`` /
## ``.tar.bz2`` archives.
##
## GNU tar joins ``grepSource`` + ``sedSource`` + ``gawkSource`` in the
## GNU text-processing + archiving CLI batch — the four pillar GNU
## userland binaries every shell script + every Makefile + every
## install script consumes.
##
## ## Why GNU tar matters for the v1 desktop story
##
## tar is the foundation of every install / backup / migration / build
## pipeline on Linux. Concrete consumers:
##
##   * Every distribution package manager (apt / dnf / pacman) shells
##     out to ``tar`` to extract its content archives — ``.deb`` is a
##     ``ar`` archive containing two ``.tar.xz`` blobs, ``.rpm`` is a
##     cpio archive whose payload is decompressed via tar in newer
##     dnf/rpm versions, and ``.pkg.tar.zst`` is a raw tar.zst.
##   * The reprobuild engine itself shells out to ``tar -xf`` for every
##     ``fetch:`` action's extract step (the M9.K convention's extract
##     BuildAction).
##   * Container builders (docker build / podman build / buildah) emit
##     ``.tar`` layer blobs via ``tar`` and ingest base images the
##     same way.
##   * Backup tools (rsync's ``--archive`` companion ``rdiff-backup`` /
##     ``duplicity`` / ``borg``) bundle file trees into ``.tar``
##     streams for compression + remote upload.
##   * Configuration-management agents (Ansible / Salt) stream
##     ``.tar.gz`` content drops to managed nodes via ``synchronize``
##     module which shells out to ``tar``.
##
## ## sha256 strategy
##
## Per the network + audio batch convention (matching the recent-
## batch precedent), we point the live ``fetch:`` URL at upstream
## directly (no vendoring), and pin the sha256 over the upstream
## tarball bytes. The hash is cross-checked against the nixpkgs
## ``gnutar`` recipe at ``pkgs/by-name/gn/gnutar/package.nix`` which
## fetches the same upstream archive via ``mirror://gnu/tar/``.
##
## ## Version choice — 1.35 (current upstream stable)
##
## GNU tar releases are cut on ftp.gnu.org under
## ``https://ftp.gnu.org/gnu/tar/tar-<X>.<Y>.tar.xz`` and 1.35 is the
## current stable as of mid-2026 (matches the nixpkgs pin). The
## ``tar`` CLI grammar has been stable since the 1.30 cut; any
## ``>=1.30`` covers every consumer's pinning.
##
## sha256 = 4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16
##  (cross-checked against nixpkgs's SRI-form
##  ``sha256-TWL/NzQux67XSFNTI5MMfPlKz3HDWRiCsmp+pQ8+3BY=`` at
##  ``pkgs/by-name/gn/gnutar/package.nix``, which decodes to the same
##  hex over the same upstream tarball bytes).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``./configure`` + ``make``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the single executable artifact via the
## ``executable`` block so the M9.K artifact registry already knows
## what binary to expect.
##
## ## Artifacts
##
## GNU tar's autotools build emits one load-bearing binary from a
## single ``./configure`` + ``make`` invocation:
##
##   * ``tar``  — ``/usr/bin/tar`` the canonical archive packer/
##                unpacker CLI.
##
## NOTE: tar also installs a ``rmt`` remote-magnetic-tape helper +
## a ``backup`` / ``restore`` companion-script pair; v1 only records
## the canonical archive-CLI binary. Downstream recipes that need
## ``rmt`` would lift the artifact registration in a follow-up batch.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--without-selinux``    — skip the libselinux dependency (v1
##                                  desktop is non-SELinux). Matches
##                                  the coreutils / sed precedent.
##   * ``--without-posix-acls`` — skip the libacl dependency for POSIX
##                                  ACL preservation. v1's filesystem
##                                  story is ext4/btrfs with default
##                                  perm bits; no acl-tagged trees in
##                                  the system image.
##   * ``--without-xattrs``     — skip the libattr dependency for
##                                  extended-attribute preservation.
##                                  v1's filesystem story uses only
##                                  the well-known security.selinux /
##                                  security.capability xattrs which
##                                  the kernel manages directly.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package tarSource:
  ## From-source GNU tar — seventy-first M9.H/I/K production recipe.
  ## THE canonical archive packer/unpacker on every modern Linux
  ## distribution — ``/usr/bin/tar`` is what every installer / backup
  ## tool / configuration-management agent / container image builder
  ## invokes to materialise ``.tar`` / ``.tar.gz`` / ``.tar.xz`` /
  ## ``.tar.bz2`` archives.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Single-executable artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## ftp.gnu.org release tarball URL — the same URL the live
    ## ``fetch:`` block points at (no vendoring per the network +
    ## audio batch convention).
    ##
    ## ``sourceRepository`` points at the canonical savannah.gnu.org
    ## mirror that hosts the tar source tree.
    "1.35":
      sourceRevision = "release_1_35"
      sourceUrl = "https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/git/tar.git"

  fetch:
    ## Upstream ftp.gnu.org release-tarball URL — out-of-band fetch on
    ## first build, then cached by the M9.K fetch action keyed on
    ## (url, sha256, extractStrip). Matches the kernel-precedent
    ## pattern of NOT vendoring tarballs.
    ##
    ## sha256 was cross-checked against nixpkgs's
    ## ``pkgs/by-name/gn/gnutar/package.nix`` SRI-form hash
    ## ``sha256-TWL/NzQux67XSFNTI5MMfPlKz3HDWRiCsmp+pQ8+3BY=`` which
    ## decodes to the hex value pinned below.
    url: "https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz"
    sha256: "4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``. tar's release
    ## tarball pre-generates ``configure`` but the convention's
    ## fallback re-runs ``autoconf`` if the script is missing.
    "autoconf"
    ## automake provides the ``Makefile.in`` templates the release
    ## tarball pre-generates.
    "automake"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — tar is C99 + GNU extensions.
    "gcc >=11"

  configureFlags:
    ## Flag set per the task brief.
    ##
    ## ``--without-selinux`` skips the libselinux dependency.
    ## ``--without-posix-acls`` skips the libacl POSIX-ACL preservation.
    ## ``--without-xattrs`` skips the libattr extended-attribute
    ##                       preservation.
    "--without-selinux"
    "--without-posix-acls"
    "--without-xattrs"

  executable tar:
    ## ``/usr/bin/tar`` — the canonical archive packer/unpacker CLI
    ## consumed by every installer + every backup tool + every
    ## configuration-management agent + every container image
    ## builder. v1 records the artifact only; the per-artifact build
    ## body lands in M9.L when the convention's make-spawn +
    ## install-glue closes.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
