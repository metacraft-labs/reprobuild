## Source-from-tarball less recipe — the SIXTIETH real from-source
## production recipe to exercise the M9.H/I/K trio. less is THE
## canonical Unix pager — every ``man <topic>`` invocation pipes its
## output through ``less``, every ``git log`` / ``git diff`` /
## ``git show`` invocation pipes through ``less`` (git's
## ``core.pager`` defaults to ``less -FRX``), and every shell with
## ``PAGER`` set picks ``less`` by convention.
##
## ## Why less matters for the v1 desktop story
##
## less is the foundation of every terminal-side documentation read.
## Concrete consumers:
##
##   * ``man <topic>`` pipes the formatted manpage through ``less`` so
##     the user can scroll / search the output of any installed
##     package's documentation.
##   * git's pager (``core.pager`` defaults to ``less -FRX``) is the
##     read interface for ``git log`` / ``git diff`` / ``git show``
##     / ``git blame``.
##   * systemd's ``systemctl status`` + ``journalctl`` pipe through
##     less when stdout is a TTY (otherwise they bypass).
##   * The user's interactive shell on a GNOME / Plasma / sway desktop
##     defaults ``PAGER=less`` so every CLI tool with a ``--pager`` /
##     ``--paginate`` flag (e.g. ``htop --help``, ``ip --help``,
##     ``bat`` when piping) finds less on PATH.
##
## ## sha256 strategy
##
## We vendor the upstream 668 .tar.gz at
## ``recipes/packages/source/less/vendor/less-668.tar.gz`` and
## reference it via a ``file://`` URL. The greenwoodsoftware.com
## release URL is recorded as ``sourceUrl`` in the ``versions:`` block
## for documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 668 (current upstream stable)
##
## less releases are cut on greenwoodsoftware.com with a single
## monotonically-increasing integer version (no major/minor). 668 is
## the current stable as of mid-2026; anything ``>=600`` covers the
## modern terminfo / wchar / right-prompt features the v1 desktop's
## ``less -RX`` consumption depends on.
##
## sha256 = 2819f55564d86d542abbecafd82ff61e819a3eec967faa36cd3e68f1596a44b8
##  (computed locally over the vendored ``less-668.tar.gz``,
##  649,770 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
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
## less's autotools build emits one load-bearing binary from a single
## ``./configure`` + ``make`` invocation:
##
##   * ``less``  — ``/usr/bin/less`` the canonical Unix pager.
##
## NOTE: less also installs ``lessecho`` + ``lesskey`` helper binaries
## under ``/usr/bin/``; v1 only records the canonical pager binary.
## Downstream recipes that need ``lesskey`` to compile a custom
## keymap at install time would lift the artifact registration in a
## follow-up batch.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flag is hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--with-regex=posix`` — pin the regex engine to the POSIX
##                               implementation (vs PCRE / PCRE2 /
##                               GNU regex). POSIX regex is what every
##                               ``/<pattern>`` search in less uses;
##                               PCRE2 would pull in a heavy library
##                               dependency the v1 desktop doesn't
##                               need.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package lessSource:
  ## From-source GNU-adjacent less — sixtieth M9.H/I/K production
  ## recipe. THE canonical Unix pager; every ``man <topic>`` + every
  ## ``git log`` + every ``systemctl status`` on a TTY pipes through
  ## ``/usr/bin/less``.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Single-executable artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## greenwoodsoftware.com release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical github.com mirror
    ## the upstream maintainer publishes the less source tree on
    ## (greenwoodsoftware.com only hosts release tarballs).
    "668":
      sourceRevision = "v668"
      sourceUrl = "https://www.greenwoodsoftware.com/less/less-668.tar.gz"
      sourceRepository = "https://github.com/gwsw/less.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 649,770-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/less/vendor/less-668.tar.gz"
    sha256: "2819f55564d86d542abbecafd82ff61e819a3eec967faa36cd3e68f1596a44b8"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``. less's release
    ## tarball pre-generates ``configure`` but the convention's
    ## fallback re-runs ``autoconf`` if the script is missing.
    "autoconf"
    ## automake provides the ``Makefile.in`` templates the release
    ## tarball pre-generates.
    "automake"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — less is C99 + a small amount of
    ## terminfo glue.
    "gcc >=11"

  configureFlags:
    ## Single-flag set for less — the ``--with-regex=`` knob is the
    ## only build-time choice that materially changes behaviour.
    ##
    ## ``--with-regex=posix`` pins the regex engine to the POSIX
    ##                         implementation (vs PCRE / PCRE2 / GNU
    ##                         regex). POSIX regex is what every
    ##                         ``/<pattern>`` search in less uses;
    ##                         PCRE2 would pull in a heavy library
    ##                         dependency the v1 desktop doesn't
    ##                         need.
    "--with-regex=posix"

  executable less:
    ## ``/usr/bin/less`` — the canonical Unix pager. Consumed by
    ## ``man`` + git's ``core.pager`` + systemd's ``systemctl
    ## status`` / ``journalctl`` (when stdout is a TTY) + every
    ## interactive shell with ``PAGER=less``. v1 records the artifact
    ## only; the per-artifact build body lands in M9.L when the
    ## convention's make-spawn + install-glue closes.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
