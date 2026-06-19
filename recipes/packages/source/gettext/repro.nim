## Source-from-tarball gettext recipe — the SIXTY-FIFTH real from-source
## production recipe to exercise the M9.H/I/K trio. gettext is THE
## canonical GNU internationalisation / localisation toolchain on
## Linux — every translated message in every GNOME / Plasma / Xfce
## application reaches for ``libintl`` at runtime to look up the
## locale-specific catalog, every ``.po`` translation file in every
## upstream is processed by ``msgfmt`` / ``msgmerge`` at build time,
## and every C source file with a ``_("translatable string")`` macro
## hits ``xgettext`` for catalog extraction.
##
## ## Why gettext matters for the v1 desktop story
##
## gettext is the foundation of every translated user-facing string on
## the v1 desktop:
##
##   * Every GNOME / Plasma / Xfce application that paints a translated
##     menu item / button label / dialog title looks up its catalog at
##     runtime through ``libintl``'s ``gettext("key")`` /
##     ``dgettext("domain", "key")`` API.
##   * Every upstream ships a ``po/`` directory with one ``.po`` file
##     per supported locale; the install-time build step invokes
##     ``msgfmt`` to compile each ``.po`` into a binary ``.mo`` catalog
##     under ``/usr/share/locale/<lang>/LC_MESSAGES/<domain>.mo``.
##   * Every translator pulls upstream's ``msgmerge`` to refresh a
##     stale ``.po`` against the latest ``.pot`` template that
##     ``xgettext`` extracts from the source tree.
##   * glibc's NLS machinery (``setlocale(LC_ALL, "...")``) sets up
##     the environment ``libintl`` consults; modern glibc 2.39+ ships
##     a thin in-tree ``libintl`` stub, but most distros (including
##     the v1 desktop target) install the full GNU gettext-runtime
##     ``libintl.so`` because of feature coverage (NLS plural-forms
##     fallback, ``bind_textdomain_codeset``, ``intl_locale_alias``).
##   * The systemd unit files + journalctl messages flow through
##     ``libintl`` when ``LANG`` is non-C.
##
## ## sha256 strategy
##
## We vendor the upstream 0.22.5 .tar.xz at
## ``recipes/packages/source/gettext/vendor/gettext-0.22.5.tar.xz`` and
## reference it via a ``file://`` URL. The ftp.gnu.org release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 0.22.5 (current upstream stable)
##
## gettext releases are cut on ftp.gnu.org under tags of the form
## ``v<X>.<Y>.<Z>`` with monotonically-increasing minor versions.
## 0.22.5 is the current stable as of mid-2026 and pairs with glibc 2.39+
## (sibling ``glibcSource`` recipe #38); anything ``>=0.21`` covers
## the libintl ABI the v1 desktop's GTK / Qt consumers reach for.
##
## sha256 = fe10c37353213d78a5b83d48af231e005c4da84db5ce88037d88355938259640
##  (computed locally over the vendored ``gettext-0.22.5.tar.xz``,
##  10,329,748 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``./configure`` + ``make``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the three executable + one library
## artifacts via the ``executable`` + ``library`` blocks so the M9.K
## artifact registry already knows what binaries + shared object to
## expect.
##
## ## Artifacts
##
## gettext's autotools build emits four load-bearing outputs from a
## single ``./configure`` + ``make`` invocation:
##
##   * ``msgfmt``    — ``/usr/bin/msgfmt``, compiles a ``.po`` text
##                      catalog into a binary ``.mo`` catalog under
##                      ``/usr/share/locale/<lang>/LC_MESSAGES/``.
##                      Invoked at every upstream's install-time
##                      catalog-build step.
##   * ``msgmerge``  — ``/usr/bin/msgmerge``, refreshes a stale ``.po``
##                      file against the latest ``.pot`` template.
##                      Invoked by translators + by upstream's
##                      ``make update-po`` build target.
##   * ``xgettext``  — ``/usr/bin/xgettext``, extracts translatable
##                      strings from C / C++ / Python / Glade source
##                      files into a ``.pot`` template. Invoked at
##                      every upstream's ``make pot`` target.
##   * ``libIntl``   — ``libintl.so`` (PascalCased from the upstream
##                      SONAME ``intl``), the runtime NLS lookup
##                      library every translated GNOME / Plasma /
##                      Xfce app links against.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``           — skip the static archive (not
##                                       used by the v1 desktop story;
##                                       libs are dynamic).
##   * ``--disable-java``             — skip the Java ABI shim layer
##                                       (heavy JDK dependency surface;
##                                       no v1 desktop consumer reaches
##                                       for it).
##   * ``--disable-csharp``           — skip the C# / mono ABI shim
##                                       layer (heavy mono dependency
##                                       surface; no v1 desktop
##                                       consumer reaches for it).
##   * ``--without-emacs``            — skip the emacs lisp bindings
##                                       (the v1 desktop's interactive
##                                       editor target is vim, not
##                                       emacs).
##   * ``--without-included-libintl`` — use the system glibc-provided
##                                       libintl stub on hosts where
##                                       glibc ships one (vs the
##                                       upstream's bundled fallback
##                                       libintl). On modern glibc
##                                       2.39+ the NLS machinery is
##                                       in-tree but the full feature
##                                       set still ships via this
##                                       package's libintl.so.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package gettextSource:
  ## From-source GNU gettext — sixty-fifth M9.H/I/K production recipe.
  ## THE canonical GNU i18n / l10n toolchain on Linux; every translated
  ## menu item / button label / dialog title on the v1 desktop flows
  ## through ``libintl`` at runtime + every ``.po`` translation file
  ## flows through ``msgfmt`` / ``msgmerge`` / ``xgettext`` at build
  ## time.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Three-executable + one-library mixed-kind
  ## artifact recipe — the FIRST source recipe in the corpus to ship a
  ## three-executable + one-library mixed shape from a single autotools
  ## ``./configure`` + ``make`` invocation (prior precedents capped at
  ## two-of-each).

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## ftp.gnu.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical savannah.gnu.org
    ## git mirror that hosts the gettext source tree.
    "0.22.5":
      sourceRevision = "v0.22.5"
      sourceUrl = "https://ftp.gnu.org/gnu/gettext/gettext-0.22.5.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/git/gettext.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 10,329,748-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/gettext/vendor/gettext-0.22.5.tar.xz"
    sha256: "fe10c37353213d78a5b83d48af231e005c4da84db5ce88037d88355938259640"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``. gettext's
    ## release tarball pre-generates ``configure`` but the convention's
    ## fallback re-runs ``autoconf`` if the script is missing.
    "autoconf"
    ## automake provides the ``Makefile.in`` templates the release
    ## tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--disable-static`` to honour the shared-only build
    ## semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — gettext is C99 + a small amount
    ## of POSIX glue + C++ for the libgettextpo helpers.
    "gcc >=11"
    ## pkg-config is used by the autotools configure step to probe for
    ## libxml2 + ncurses + the libintl probe path.
    "pkg-config"

  buildDeps:
    ## libxml2 is consumed by gettext's ``msgfmt --xml`` codepath that
    ## emits XML-formatted message catalogs for the (deprecated)
    ## glade / qt-linguist consumers.
    "libxml2 >=2.9"

  configureFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: the ``./configure`` script
    ## evaluates options left-to-right and the ``--without-included-libintl``
    ## sentinel lives at the tail so any override (e.g. a future
    ## glibc-stub-only variant) can append ``--with-included-libintl``
    ## later without re-ordering this block. The mixed ``--disable-*``
    ## / ``--without-*`` polarity pins the autotools two-flavour
    ## convention (``--enable-X`` / ``--disable-X`` toggles a boolean
    ## feature; ``--with-X`` / ``--without-X`` toggles a dependency
    ## probe).
    ##
    ## ``--disable-static`` skips the static archive.
    ## ``--disable-java`` skips the Java ABI shim layer.
    ## ``--disable-csharp`` skips the C# / mono ABI shim layer.
    ## ``--without-emacs`` skips the emacs lisp bindings.
    ## ``--without-included-libintl`` uses the system glibc libintl
    ##                                  probe path instead of the
    ##                                  upstream's bundled fallback.
    "--disable-static"
    "--disable-java"
    "--disable-csharp"
    "--without-emacs"
    "--without-included-libintl"

  executable msgfmt:
    ## ``/usr/bin/msgfmt`` — compiles ``.po`` text catalogs into binary
    ## ``.mo`` catalogs under
    ## ``/usr/share/locale/<lang>/LC_MESSAGES/<domain>.mo``. Invoked
    ## at every upstream's install-time catalog-build step. v1 records
    ## the artifact only; the per-artifact build body lands in M9.L
    ## when the convention's make-spawn + install-glue closes.
    discard

  executable msgmerge:
    ## ``/usr/bin/msgmerge`` — refreshes a stale ``.po`` translation
    ## file against the latest ``.pot`` template. Invoked by
    ## translators + by upstream's ``make update-po`` build target.
    discard

  executable xgettext:
    ## ``/usr/bin/xgettext`` — extracts translatable strings (wrapped
    ## in the ``_("...")`` / ``gettext("...")`` / ``N_("...")`` macros)
    ## from C / C++ / Python / Glade / Vala / Lua / Lisp source files
    ## into a ``.pot`` template. Invoked at every upstream's
    ## ``make pot`` target.
    discard

  library libIntl:
    ## ``libintl.so`` — the runtime NLS lookup library every translated
    ## GNOME / Plasma / Xfce app links against; provides the
    ## ``gettext("key")`` / ``dgettext("domain", "key")`` /
    ## ``bind_textdomain_codeset(...)`` API. The upstream SONAME
    ## ``intl`` is PascalCased to ``libIntl`` per the libCrypto /
    ## libExpat / libGlib2 / libGnutls / libLzma / libReadline
    ## precedent of preserving the canonical ``lib`` prefix while
    ## PascalCasing the SONAME body. v1 records the artifact only;
    ## the per-artifact build body lands in M9.L.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
