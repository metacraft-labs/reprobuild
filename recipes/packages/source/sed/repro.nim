## Source-from-tarball GNU sed recipe — the SEVENTY-THIRD real from-
## source production recipe to exercise the M9.H/I/K trio. GNU sed is
## THE canonical stream-editor CLI on every modern Linux distribution
## — ``/usr/bin/sed`` is what every shell pipeline / every Makefile
## substitution rule / every config-rewrite script / every autotools
## ``./configure`` script invokes to perform in-place substitutions
## against text streams.
##
## GNU sed joins ``tarSource`` + ``grepSource`` + ``gawkSource`` in
## the GNU text-processing + archiving CLI batch — the four pillar
## GNU userland binaries every shell script + every Makefile + every
## install script consumes.
##
## ## Why GNU sed matters for the v1 desktop story
##
## sed is the foundation of every shell-driven config-rewrite / log-
## reformat / Makefile-substitution pipeline on Linux. Concrete
## consumers:
##
##   * Every shell pipeline that does ``cmd | sed 's/old/new/g'`` —
##     interactive sessions, sysadmin scripts, dotfiles activation,
##     every Makefile recipe that mangles tool output.
##   * Config-rewrite scripts — every ``/etc`` walk that does
##     ``sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config``
##     and every nixos-rebuild's activation script that patches
##     generated files.
##   * Autotools ``./configure`` runs — the autotools machinery sed-
##     replaces template variables into ``config.h`` + ``Makefile``.
##     EVERY autotools recipe in this corpus's ``./configure`` pass
##     consumes sed.
##   * Build-system probes — every Makefile that conditions a rule
##     on a ``sed -e`` rewrite of intermediate output.
##   * Dotfiles installers — the home-manager-style activation
##     scripts the reprobuild dotfiles adapter generates use sed to
##     stamp per-user values into config templates.
##
## ## sha256 strategy
##
## Per the network + audio batch convention (matching the recent-
## batch precedent), we point the live ``fetch:`` URL at upstream
## directly (no vendoring), and pin the sha256 over the upstream
## tarball bytes. The hash is cross-checked against the nixpkgs
## ``gnused`` recipe at ``pkgs/tools/text/gnused/default.nix`` which
## fetches the same upstream archive via ``mirror://gnu/sed/``.
##
## ## Version choice — 4.9 (current upstream stable)
##
## GNU sed releases are cut on ftp.gnu.org under
## ``https://ftp.gnu.org/gnu/sed/sed-<X>.<Y>.tar.xz`` and 4.9 is the
## current stable as of mid-2026 (matches the nixpkgs pin). The
## ``sed`` CLI grammar (POSIX BRE / ERE + GNU extensions) has been
## stable since the 4.0 cut; any ``>=4.0`` covers every consumer's
## pinning.
##
## sha256 = 6e226b732e1cd739464ad6862bd1a1aba42d7982922da7a53519631d24975181
##  (cross-checked against nixpkgs's SRI-form
##  ``sha256-biJrcy4c1zlGStaGK9Ghq6QteYKSLaelNRljHSSXUYE=`` at
##  ``pkgs/tools/text/gnused/default.nix``, which decodes to the same
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
## GNU sed's autotools build emits one load-bearing binary from a
## single ``./configure`` + ``make`` invocation:
##
##   * ``sed`` — ``/usr/bin/sed`` the canonical stream-editor CLI.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--without-selinux`` — skip the libselinux dependency (v1
##                              desktop is non-SELinux). Matches the
##                              tar / coreutils precedent.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package sedSource:
  ## From-source GNU sed — seventy-third M9.H/I/K production recipe.
  ## THE canonical stream-editor CLI on every modern Linux
  ## distribution — every shell pipeline + every Makefile substitution
  ## rule + every config-rewrite script + every autotools
  ## ``./configure`` run shells out to ``/usr/bin/sed``.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention
  ## layer reads the ``fetch:`` block (registered via
  ## ``registeredFetchSpec``) and the ``configureFlags:`` block
  ## (registered via ``registeredBuildFlags`` on the ``"configure"``
  ## channel) and lowers them into fetch + configure BuildActions
  ## wired with the right URL + hash + flags. Single-executable
  ## artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## ftp.gnu.org release tarball URL — the same URL the live
    ## ``fetch:`` block points at (no vendoring per the network +
    ## audio batch convention).
    ##
    ## ``sourceRepository`` points at the canonical savannah.gnu.org
    ## mirror that hosts the sed source tree.
    "4.9":
      sourceRevision = "v4.9"
      sourceUrl = "https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/git/sed.git"

  fetch:
    ## Upstream ftp.gnu.org release-tarball URL — out-of-band fetch on
    ## first build, then cached by the M9.K fetch action keyed on
    ## (url, sha256, extractStrip). Matches the kernel-precedent
    ## pattern of NOT vendoring tarballs.
    ##
    ## sha256 was cross-checked against nixpkgs's
    ## ``pkgs/tools/text/gnused/default.nix`` SRI-form hash
    ## ``sha256-biJrcy4c1zlGStaGK9Ghq6QteYKSLaelNRljHSSXUYE=`` which
    ## decodes to the hex value pinned below.
    url: "https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz"
    sha256: "6e226b732e1cd739464ad6862bd1a1aba42d7982922da7a53519631d24975181"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``. sed's release
    ## tarball pre-generates ``configure`` but the convention's
    ## fallback re-runs ``autoconf`` if the script is missing.
    "autoconf"
    ## automake provides the ``Makefile.in`` templates the release
    ## tarball pre-generates.
    "automake"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — sed is C99 + GNU extensions.
    "gcc >=11"
    ## perl is required by the build for the help2man pass that
    ## generates the sed manpage.
    "perl >=5.32"

  configureFlags:
    ## Flag set per the task brief.
    ##
    ## ``--without-selinux`` skips the libselinux dependency.
    "--without-selinux"

  executable sed:
    ## ``/usr/bin/sed`` — the canonical stream-editor CLI consumed
    ## by every shell pipeline + every Makefile substitution rule +
    ## every config-rewrite script + every autotools ``./configure``
    ## run. v1 records the artifact only; the per-artifact build
    ## body lands in M9.L when the convention's make-spawn +
    ## install-glue closes.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
