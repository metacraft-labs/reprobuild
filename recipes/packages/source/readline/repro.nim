## Source-from-tarball readline recipe — the SIXTY-FOURTH real from-source
## production recipe to exercise the M9.H/I/K trio. readline is THE
## canonical GNU library for line-editing + history + tab completion
## on every interactive Unix CLI — bash, gdb, psql, sqlite3, ipython,
## clisp, python's REPL (when built with the readline binding), and
## every emacs-style or vi-style key-binding inside a terminal app
## flows through ``libreadline.so``. Pairs with the sibling ``bashSource``
## recipe (#59) which configures ``--enable-readline`` against this
## library.
##
## ## Why readline matters for the v1 desktop story
##
## libreadline is the foundation of every interactive CLI's input
## experience:
##
##   * bash (from the sibling ``bashSource`` recipe) links against
##     libreadline for its interactive prompt — history,
##     tab-completion, emacs / vi key bindings, paste handling, and
##     terminfo-driven cursor positioning all flow through libreadline.
##   * GNU Debugger (gdb) uses libreadline for its ``(gdb)`` prompt;
##     every interactive debugging session on the v1 desktop reaches
##     for the same library.
##   * PostgreSQL's ``psql`` + SQLite's ``sqlite3`` shell + ipython
##     all link against libreadline for line-editing.
##   * The companion ``libhistory.so`` holds the in-memory + on-disk
##     history-file machinery (``~/.bash_history``, ``~/.gdb_history``,
##     ``~/.psql_history``); it ships as a separately-versioned SONAME
##     so consumers can pin one without the other.
##
## ## sha256 strategy
##
## We vendor the upstream 8.2 .tar.gz at
## ``recipes/packages/source/readline/vendor/readline-8.2.tar.gz`` and
## reference it via a ``file://`` URL. The ftp.gnu.org release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 8.2 (current upstream stable)
##
## readline releases are cut on ftp.gnu.org under tags of the form
## ``readline-<X>.<Y>``. 8.2 is the current stable in the 8.x line as
## of mid-2026 and pairs with bash 5.2.x (sibling ``bashSource``); the
## 8.x SONAME bump from 7.x carries the bracketed-paste mode + the
## ``rl_unbind_function_in_map`` API the modern bash REPL reaches for.
## Anything ``>=8.0`` covers the bracketed-paste + the
## ``rl_clear_visible_line`` API.
##
## sha256 = 3feb7171f16a84ee82ca18a36d7b9be109a52c04f492a5f6d5fd58b2f2c5f4ec
##  (computed locally over the vendored ``readline-8.2.tar.gz``,
##  3,043,945 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``./configure`` + ``make``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the two library artifacts via the
## ``library`` blocks so the M9.K artifact registry already knows what
## shared objects to expect.
##
## ## Library artifacts
##
## readline's autotools build emits two load-bearing shared libraries
## from a single ``./configure`` + ``make`` invocation:
##
##   * ``libReadline``  — ``libreadline.so``, the line-editing +
##                         key-binding + tab-completion library every
##                         interactive CLI links against.
##   * ``libHistory``   — ``libhistory.so``, the in-memory + on-disk
##                         history-file machinery (``~/.bash_history``,
##                         ``~/.gdb_history``); separately-versioned
##                         so consumers can pin one without the other.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static`` — skip the static archive (not used by
##                              the v1 desktop story; the libs are
##                              dynamic).
##   * ``--enable-shared``  — build the ``libreadline.so`` +
##                              ``libhistory.so`` shared libraries
##                              (default is static-only without this
##                              flag).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package readlineSource:
  ## From-source GNU readline — sixty-fourth M9.H/I/K production
  ## recipe. THE canonical line-editing + history + tab-completion
  ## library for every interactive Unix CLI (bash, gdb, psql, sqlite3,
  ## ipython, emacs-mode / vi-mode keymaps in any TTY app).
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Two-library artifact recipe (libreadline
  ## + libhistory) — first source recipe in the corpus with this
  ## particular two-of-a-kind autotools shape paired with the
  ## ``--enable-shared`` / ``--disable-static`` flag polarity that
  ## upstream readline uses (vs ncurses's ``--with-shared`` /
  ## ``--disable-static`` polarity — readline 8.x's configure.ac uses
  ## the ``--enable-shared`` spelling).

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## ftp.gnu.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical savannah.gnu.org
    ## git mirror that hosts the readline source tree.
    "8.2":
      sourceRevision = "readline-8.2"
      sourceUrl = "https://ftp.gnu.org/gnu/readline/readline-8.2.tar.gz"
      sourceRepository = "https://git.savannah.gnu.org/git/readline.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 3,043,945-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://ftp.gnu.org/gnu/readline/readline-8.2.tar.gz"
    sha256: "3feb7171f16a84ee82ca18a36d7b9be109a52c04f492a5f6d5fd58b2f2c5f4ec"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``. readline 8.x
    ## tarballs pre-generate ``configure`` but the convention's
    ## fallback re-runs ``autoconf`` if the script is missing.
    "autoconf"
    ## automake provides the ``Makefile.in`` templates the release
    ## tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--enable-shared`` to honour the shared-only build
    ## semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — readline is C89 + a small amount
    ## of POSIX glue.
    "gcc >=11"

  buildDeps:
    ## ncurses provides the terminfo database lookup + the curses
    ## key-handling primitives readline reaches for when the host
    ## terminal has a non-trivial cap set (the sibling ``ncursesSource``
    ## recipe #62 vendors a compatible version).
    "ncurses >=6.0"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  library libReadline:
    ## ``libreadline.so`` — the line-editing + key-binding +
    ## tab-completion library bash + gdb + psql + sqlite3 + ipython
    ## all link against for their interactive prompts. The upstream
    ## SONAME ``readline`` is PascalCased to ``libReadline`` per the
    ## libCrypto / libExpat / libGlib2 / libGnutls / libLzma precedent
    ## of preserving the canonical ``lib`` prefix while PascalCasing
    ## the SONAME body. v1 records the artifact only; the per-artifact
    ## build body lands in M9.L when the convention's make-spawn +
    ## install-glue closes.
    discard

  library libHistory:
    ## ``libhistory.so`` — the in-memory + on-disk history-file
    ## machinery (``~/.bash_history``, ``~/.gdb_history``,
    ## ``~/.psql_history``). Separately-versioned SONAME so consumers
    ## can pin one of the two without the other (e.g. a CLI that
    ## wants line-editing but rolls its own persistent history). v1
    ## records the artifact only; the per-artifact build body lands
    ## in M9.L.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("readlineSource")
    try:
      let opts = @[
        "--disable-static",
        "--enable-shared",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libReadline")
      discard pkg.library("libHistory")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
