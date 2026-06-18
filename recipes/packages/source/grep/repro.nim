## Source-from-tarball GNU grep recipe — the SEVENTY-SECOND real
## from-source production recipe to exercise the M9.H/I/K trio. GNU
## grep is THE canonical line-matching CLI on every modern Linux
## distribution — ``/usr/bin/grep`` is what every shell pipeline /
## every log scanner / every config-search Makefile rule / every IDE
## file-search backend invokes to filter text streams against regex
## patterns.
##
## GNU grep joins ``tarSource`` + ``sedSource`` + ``gawkSource`` in
## the GNU text-processing + archiving CLI batch — the four pillar
## GNU userland binaries every shell script + every Makefile + every
## install script consumes.
##
## ## Why GNU grep matters for the v1 desktop story
##
## grep is the foundation of every shell-driven text-search / log-
## scan / config-discovery pipeline on Linux. Concrete consumers:
##
##   * Every shell pipeline that does ``cmd | grep pattern`` —
##     interactive sessions, sysadmin scripts, ``~/.bashrc`` setup,
##     every Makefile recipe that filters tool output.
##   * Log scanners (journalctl + grep) — ``journalctl | grep ERROR``
##     is the canonical sysadmin debug pattern.
##   * Configuration discovery — every ``/etc`` walk for a setting
##     (``grep -r "^PermitRootLogin" /etc/ssh/``) and every package
##     listing query (``rpm -qa | grep gnome``).
##   * IDE file-search backends — VS Code's ripgrep-backed "Find in
##     Files" panel falls back to grep when ripgrep is absent; KDE's
##     KFind GUI shells to grep for the regex-mode searches.
##   * Build-system probes — autotools' ``./configure`` script greps
##     for symbol presence in header files (``grep -q "__GLIBC__"``
##     ``unistd.h``), every Makefile that conditions a rule on
##     ``grep -q``.
##
## ## sha256 strategy
##
## Per the network + audio batch convention (matching the recent-
## batch precedent), we point the live ``fetch:`` URL at upstream
## directly (no vendoring), and pin the sha256 over the upstream
## tarball bytes.
##
## ## Version choice — 3.11 (per task brief)
##
## GNU grep releases are cut on ftp.gnu.org under
## ``https://ftp.gnu.org/gnu/grep/grep-<X>.<Y>.tar.xz`` and 3.11 is
## the pinned target per the task brief. The ``grep`` CLI grammar
## (POSIX BRE / ERE + GNU extensions) has been stable since the
## 3.0 cut; any ``>=3.0`` covers every consumer's pinning.
##
## sha256 = 1db2aedde89d0dea42b16d9528f894c8d15dae4e190b59aecc78f5a951276eab
##  (canonical published ``sha256sum`` of the upstream
##  ``grep-3.11.tar.xz`` tarball at ftp.gnu.org/gnu/grep/. nixpkgs
##  currently records the SRI-form hash for grep 3.12 — one minor
##  bump ahead of this brief's pinned 3.11 target — so the cross-
##  check uses the canonical upstream sha256 directly.)
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
## GNU grep's autotools build emits one load-bearing binary from a
## single ``./configure`` + ``make`` invocation:
##
##   * ``grep`` — ``/usr/bin/grep`` the canonical line-matching CLI.
##
## NOTE: grep also installs ``egrep`` + ``fgrep`` POSIX-mandated
## shell wrappers that re-invoke ``grep -E`` / ``grep -F``; v1 only
## records the canonical grep binary. Downstream recipes that need
## ``egrep`` / ``fgrep`` would lift the artifact registration in a
## follow-up batch (nixpkgs's postInstall regenerates these wrappers
## as ``#!/bin/sh exec grep -E "$@"`` shell scripts).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-perl-regexp`` — skip the Perl-compatible regex
##                                  engine (libpcre2 dependency).
##                                  The v1 desktop story only uses
##                                  the POSIX BRE / ERE engines;
##                                  Perl regex (``grep -P``) is not
##                                  consumed by any pin in the
##                                  recipe corpus or the dotfiles
##                                  shell rcfiles.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package grepSource:
  ## From-source GNU grep — seventy-second M9.H/I/K production
  ## recipe. THE canonical line-matching CLI on every modern Linux
  ## distribution — every shell pipeline / every log scanner / every
  ## config-search Makefile rule / every IDE file-search backend
  ## shells out to ``/usr/bin/grep``.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention
  ## layer reads the ``fetch:`` block (registered via
  ## ``registeredFetchSpec``) and the ``configureFlags:`` block
  ## (registered via ``registeredBuildFlags`` on the ``"configure"``
  ## channel) and lowers them into fetch + configure BuildActions
  ## wired with the right URL + hash + flags. Single-executable
  ## artifact recipe.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## ftp.gnu.org release tarball URL — the same URL the live
    ## ``fetch:`` block points at (no vendoring per the network +
    ## audio batch convention).
    ##
    ## ``sourceRepository`` points at the canonical savannah.gnu.org
    ## mirror that hosts the grep source tree.
    "3.11":
      sourceRevision = "v3.11"
      sourceUrl = "https://ftp.gnu.org/gnu/grep/grep-3.11.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/git/grep.git"

  fetch:
    ## Upstream ftp.gnu.org release-tarball URL — out-of-band fetch on
    ## first build, then cached by the M9.K fetch action keyed on
    ## (url, sha256, extractStrip). Matches the kernel-precedent
    ## pattern of NOT vendoring tarballs.
    ##
    ## sha256 is the canonical published ``sha256sum`` of the upstream
    ## ``grep-3.11.tar.xz`` tarball — nixpkgs records the SRI-form
    ## hash for grep 3.12 (one minor bump ahead) so the cross-check
    ## here is against the upstream-published canonical hash directly.
    url: "https://ftp.gnu.org/gnu/grep/grep-3.11.tar.xz"
    sha256: "1db2aedde89d0dea42b16d9528f894c8d15dae4e190b59aecc78f5a951276eab"
    extractStrip: 1

  uses:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``. grep's release
    ## tarball pre-generates ``configure`` but the convention's
    ## fallback re-runs ``autoconf`` if the script is missing.
    "autoconf"
    ## automake provides the ``Makefile.in`` templates the release
    ## tarball pre-generates.
    "automake"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — grep is C99 + GNU extensions.
    "gcc >=11"

  configureFlags:
    ## Flag set per the task brief.
    ##
    ## ``--disable-perl-regexp`` skips the Perl-compatible regex engine
    ##                            (libpcre2 dependency). The v1 desktop
    ##                            story only uses the POSIX BRE / ERE
    ##                            engines.
    "--disable-perl-regexp"

  executable grep:
    ## ``/usr/bin/grep`` — the canonical line-matching CLI consumed
    ## by every shell pipeline + every log scanner + every config-
    ## search Makefile rule + every IDE file-search backend. v1
    ## records the artifact only; the per-artifact build body lands
    ## in M9.L when the convention's make-spawn + install-glue
    ## closes.
    discard
