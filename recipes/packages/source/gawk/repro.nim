## Source-from-tarball GNU awk recipe — the SEVENTY-FOURTH real
## from-source production recipe to exercise the M9.H/I/K trio. GNU
## awk (gawk) is THE canonical AWK implementation on every modern
## Linux distribution — ``/usr/bin/awk`` is what every shell pipeline
## / every Makefile field-extract rule / every log-analysis script /
## every report-generation pipeline invokes to run AWK programs
## against text streams.
##
## GNU awk joins ``tarSource`` + ``grepSource`` + ``sedSource`` in
## the GNU text-processing + archiving CLI batch — the four pillar
## GNU userland binaries every shell script + every Makefile + every
## install script consumes.
##
## ## Why GNU awk matters for the v1 desktop story
##
## awk is the foundation of every shell-driven field-extract / log-
## summarize / report-generate pipeline on Linux. Concrete consumers:
##
##   * Every shell pipeline that does ``cmd | awk '{ print $2 }'`` —
##     interactive sessions, sysadmin scripts, every Makefile recipe
##     that extracts fields from tool output.
##   * Log analysis — every sysadmin one-liner that summarises
##     access logs (``awk '$9 == 500 { count++ } END { print count }'
##     /var/log/nginx/access.log``).
##   * Configuration probing — every ``ps`` / ``netstat`` / ``ss``
##     pipeline that filters columns by predicate
##     (``ps -ef | awk '$3 == 1 { print $2 }'`` for direct children
##     of init).
##   * Build-system probes — every Makefile that does ``$(shell ...
##     | awk '...')`` to compute version strings, file counts,
##     timestamp deltas.
##   * Report generation — every sysadmin script that formats
##     summary tables (``awk 'BEGIN { printf "%-20s %s\n", ... }
##     ...'``) for stdout / email digest output.
##
## ## sha256 strategy
##
## Per the network + audio batch convention (matching the recent-
## batch precedent), we point the live ``fetch:`` URL at upstream
## directly (no vendoring), and pin the sha256 over the upstream
## tarball bytes.
##
## ## Version choice — 5.3.0 (per task brief)
##
## GNU awk releases are cut on ftp.gnu.org under
## ``https://ftp.gnu.org/gnu/gawk/gawk-<X>.<Y>.<Z>.tar.xz`` and 5.3.0
## is the pinned target per the task brief. The ``awk`` CLI grammar
## (POSIX AWK + GNU extensions) has been stable since the 5.0 cut;
## any ``>=5.0`` covers every consumer's pinning.
##
## sha256 = ca9c16d3d11d0ff8c69d79dc0b47267e1329a69b39b799895604ed447d3ca90b
##  (canonical published ``sha256sum`` of the upstream
##  ``gawk-5.3.0.tar.xz`` tarball at ftp.gnu.org/gnu/gawk/. nixpkgs
##  currently records the SRI-form hash for gawk 5.4.0 — one minor
##  bump ahead of this brief's pinned 5.3.0 target — so the cross-
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
## GNU awk's autotools build emits one load-bearing binary from a
## single ``./configure`` + ``make`` invocation:
##
##   * ``awk`` — ``/usr/bin/awk`` (provided by ``gawk`` upstream) the
##                canonical AWK interpreter CLI. The upstream binary
##                ships as ``gawk`` and is symlinked to ``awk`` by the
##                install step on most distributions; v1 records the
##                canonical short name ``awk`` per the task brief.
##
## NOTE: gawk also installs auxiliary helpers (``gawkbug`` /
## ``pgawk`` profiling variant / ``igawk`` include-aware front-end)
## + a small set of extension libraries under
## ``$libexecdir/awk/``; v1 only records the canonical interpreter
## binary. Downstream recipes that need ``pgawk`` would lift the
## artifact registration in a follow-up batch.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-extensions``  — skip the dynamic-loading extension
##                                  modules (``filefuncs`` / ``fnmatch``
##                                  / ``ordchr`` / ...). The v1 desktop
##                                  story has no consumer for the
##                                  extension surface — every AWK
##                                  consumer uses the built-in builtins.
##   * ``--disable-mpfr``        — skip the libgmp + libmpfr arbitrary-
##                                  precision-arithmetic dependency.
##                                  v1 AWK consumers use IEEE-754
##                                  double-precision floats which the
##                                  built-in C ``double`` covers.
##   * ``--disable-libsigsegv``  — skip the libsigsegv stack-overflow
##                                  detection dependency. AWK programs
##                                  rarely recurse deep enough to
##                                  exhaust the default stack; the
##                                  standard SIGSEGV behaviour is
##                                  acceptable for v1.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package gawkSource:
  ## From-source GNU awk (gawk) — seventy-fourth M9.H/I/K production
  ## recipe. THE canonical AWK implementation on every modern Linux
  ## distribution — every shell pipeline + every Makefile field-
  ## extract rule + every log-analysis script + every report-
  ## generation pipeline shells out to ``/usr/bin/awk``.
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
    ## mirror that hosts the gawk source tree.
    "5.3.0":
      sourceRevision = "gawk-5.3.0"
      sourceUrl = "https://ftp.gnu.org/gnu/gawk/gawk-5.3.0.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/git/gawk.git"

  fetch:
    ## Upstream ftp.gnu.org release-tarball URL — out-of-band fetch on
    ## first build, then cached by the M9.K fetch action keyed on
    ## (url, sha256, extractStrip). Matches the kernel-precedent
    ## pattern of NOT vendoring tarballs.
    ##
    ## sha256 is the canonical published ``sha256sum`` of the upstream
    ## ``gawk-5.3.0.tar.xz`` tarball — nixpkgs records the SRI-form
    ## hash for gawk 5.4.0 (one minor bump ahead) so the cross-check
    ## here is against the upstream-published canonical hash directly.
    url: "https://ftp.gnu.org/gnu/gawk/gawk-5.3.0.tar.xz"
    sha256: "ca9c16d3d11d0ff8c69d79dc0b47267e1329a69b39b799895604ed447d3ca90b"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``. gawk's release
    ## tarball pre-generates ``configure`` but the convention's
    ## fallback re-runs ``autoconf`` if the script is missing.
    "autoconf"
    ## automake provides the ``Makefile.in`` templates the release
    ## tarball pre-generates.
    "automake"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — gawk is C99 + GNU extensions.
    "gcc >=11"

  configureFlags:
    ## Flag set per the task brief.
    ##
    ## ``--disable-extensions`` skips the dynamic-loading extension
    ##                          modules (``filefuncs`` / ``fnmatch`` /
    ##                          ``ordchr`` / ...).
    ## ``--disable-mpfr`` skips the libgmp + libmpfr arbitrary-
    ##                    precision-arithmetic dependency.
    ## ``--disable-libsigsegv`` skips the libsigsegv stack-overflow
    ##                          detection dependency.
    "--disable-extensions"
    "--disable-mpfr"
    "--disable-libsigsegv"

  executable awk:
    ## ``/usr/bin/awk`` — the canonical AWK interpreter CLI consumed
    ## by every shell pipeline + every Makefile field-extract rule +
    ## every log-analysis script + every report-generation pipeline.
    ## The upstream binary ships as ``gawk`` and is symlinked to
    ## ``awk`` on install; v1 records the canonical short name
    ## ``awk`` per the task brief (the install-glue is the M9.L
    ## responsibility once the convention's make-spawn closes).
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
