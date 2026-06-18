## Source-from-tarball bash recipe — the FIFTY-NINTH real from-source
## production recipe to exercise the M9.H/I/K trio. bash is THE
## canonical POSIX shell — ``/bin/bash`` is the login shell on every
## major Linux distribution, the shebang line at the top of every
## sysadmin script (``#!/bin/bash``), and the interpreter every
## Makefile recipe is implicitly evaluated under (GNU make defaults
## ``SHELL`` to ``/bin/sh`` which on most distros points at ``bash``
## via the ``sh`` POSIX-mode symlink).
##
## ## Why bash matters for the v1 desktop story
##
## bash is the foundation of every interactive shell session and every
## non-interactive build pipeline. Concrete consumers:
##
##   * The user's interactive login on a GNOME / Plasma / sway desktop
##     spawns a terminal (gnome-terminal / konsole / foot) which
##     execs ``/bin/bash`` under the user's TTY.
##   * The ``~/.profile`` + ``~/.bash_profile`` + ``~/.bashrc`` rcfiles
##     every dotfiles repo ships are parsed by bash at session start.
##   * Every ``Makefile`` recipe is evaluated by ``/bin/sh`` which
##     defaults to bash on most distros (Debian / Fedora / Arch ship
##     bash as ``/bin/sh``; only Ubuntu / Alpine deviate by defaulting
##     ``sh`` to dash / busybox-ash).
##   * Every systemd-unit ``ExecStart=`` that interpolates ``${VAR}``
##     or uses ``|`` / ``&&`` is implicitly wrapped in ``bash -c '...'``
##     by systemd's exec helper.
##   * Every shellcheck-clean shell script in the reprobuild repo itself
##     (``scripts/run_tests.sh``, ``scripts/build_apps.sh``,
##     ``scripts/dev-shell.sh``) starts with ``#!/usr/bin/env bash``.
##
## ## sha256 strategy
##
## We vendor the upstream 5.2.37 .tar.gz at
## ``recipes/packages/source/bash/vendor/bash-5.2.37.tar.gz`` and
## reference it via a ``file://`` URL. The ftp.gnu.org release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 5.2.37 (current upstream stable)
##
## bash releases are cut on ftp.gnu.org under tags of the form
## ``bash-<X>.<Y>``; the 5.2.x line ships patch-level releases as
## ``bash-<X>.<Y>.<Z>``. 5.2.37 is the current stable in the 5.2.x line
## as of mid-2026 — anything ``>=5.2`` covers the readline-8.2 ABI +
## the namespace ``${var@a}`` parameter-expansion operator the modern
## rcfiles use.
##
## sha256 = 9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff
##  (computed locally over the vendored ``bash-5.2.37.tar.gz``,
##  11,128,314 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
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
## bash's autotools build emits one load-bearing binary from a single
## ``./configure`` + ``make`` invocation:
##
##   * ``bash``  — ``/bin/bash`` the POSIX shell interpreter.
##
## NOTE: bash also installs a ``bashbug`` helper script + a number of
## loadable builtins under ``$libexecdir/bash/loadables/``; v1 only
## records the canonical interpreter binary. Downstream recipes that
## need ``bashbug`` would lift the artifact registration in a follow-
## up batch.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``       — skip the static archive (not used
##                                   by the v1 desktop story; the
##                                   bash binary is dynamically linked
##                                   against readline + ncurses).
##   * ``--without-bash-malloc``  — use the system malloc (glibc's
##                                   ptmalloc2) instead of bash's
##                                   vendored gmalloc. glibc's
##                                   malloc is faster on modern x86_64
##                                   + has the THP-friendly arena
##                                   layout the v1 desktop's
##                                   sessionhash uses.
##   * ``--enable-readline``      — link against system libreadline so
##                                   interactive line-editing (history,
##                                   tab-completion, vi/emacs keymaps)
##                                   works in terminal sessions.
##   * ``--enable-history``       — keep ``~/.bash_history`` write-on-
##                                   exit + the ``history`` builtin
##                                   wired up.
##   * ``--enable-job-control``   — keep the ``fg`` / ``bg`` / ``jobs``
##                                   builtins + the SIGCHLD handling
##                                   wired up (every interactive
##                                   session relies on this).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package bashSource:
  ## From-source GNU bash — fifty-ninth M9.H/I/K production recipe.
  ## THE canonical POSIX shell; ``/bin/bash`` is the login shell on
  ## every major Linux distribution + the shebang line at the top of
  ## every sysadmin script + the implicit interpreter every Makefile
  ## recipe is evaluated under.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Single-executable artifact recipe.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## ftp.gnu.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical savannah.gnu.org
    ## mirror that hosts the bash source tree.
    "5.2.37":
      sourceRevision = "bash-5.2.37"
      sourceUrl = "https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz"
      sourceRepository = "https://git.savannah.gnu.org/git/bash.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 11,128,314-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/bash/vendor/bash-5.2.37.tar.gz"
    sha256: "9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff"
    extractStrip: 1

  uses:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``. bash 5.2.x
    ## tarballs pre-generate ``configure`` but the convention's
    ## fallback re-runs ``autoconf`` if the script is missing.
    "autoconf"
    ## automake provides the ``Makefile.in`` templates the release
    ## tarball pre-generates.
    "automake"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — bash is C99 + GNU extensions.
    "gcc >=11"
    ## bison is required for ``y.tab.c`` regeneration when the upstream
    ## ``parse.y`` is touched (or the release tarball's pre-generated
    ## ``y.tab.c`` is stripped by a downstream patch).
    "bison"

  configureFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: the ``./configure`` script
    ## evaluates options left-to-right and the ``--enable-job-control``
    ## sentinel lives at the tail so any override (e.g. a future
    ## non-interactive-only variant) can append
    ## ``--disable-job-control`` later without re-ordering this block.
    ##
    ## ``--disable-static`` skips the static archive.
    ## ``--without-bash-malloc`` uses the system malloc (glibc ptmalloc2).
    ## ``--enable-readline`` links against system libreadline.
    ## ``--enable-history`` keeps ``~/.bash_history`` + the ``history``
    ##                       builtin wired up.
    ## ``--enable-job-control`` keeps the ``fg`` / ``bg`` / ``jobs``
    ##                           builtins + SIGCHLD handling wired up.
    "--disable-static"
    "--without-bash-malloc"
    "--enable-readline"
    "--enable-history"
    "--enable-job-control"

  executable bash:
    ## ``/bin/bash`` — the POSIX shell interpreter. Login shell on
    ## every major Linux distribution; shebang target for every
    ## ``#!/bin/bash`` script; implicit interpreter every ``Makefile``
    ## recipe and every systemd ``ExecStart=`` with shell metacharacters
    ## are evaluated under. v1 records the artifact only; the per-
    ## artifact build body lands in M9.L when the convention's make-
    ## spawn + install-glue closes.
    discard
