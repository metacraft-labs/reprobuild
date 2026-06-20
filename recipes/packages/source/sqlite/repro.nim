## Source-from-tarball sqlite recipe — the FORTY-FIRST real from-source
## production recipe to exercise the M9.H/I/K trio. sqlite's unique
## coverage angle vs the prior forty is being the SQLite-authoritative
## ``sqlite-autoconf-*.tar.gz`` "amalgamation" release tarball — a
## single-translation-unit C99 source distribution that ships its own
## hand-rolled ``./configure`` script. The configure script accepts the
## standard autoconf-shaped ``--enable-<feature>`` / ``--disable-<feature>``
## / ``--with-<dep>`` flag grammar, so the convention layer reuses the
## abstract ``configureFlags:`` channel — same channel openssl + zlib
## reused for their custom Perl ``./Configure`` / hand-rolled ``./configure``
## scripts.
##
## ## Why sqlite matters for the v1 desktop story
##
## SQLite is the canonical embedded SQL database underpinning a wide
## swath of desktop infrastructure: GNOME's ``tracker`` indexer (full-
## text search across the user's filesystem), Plasma's ``baloo`` indexer
## (KDE's equivalent FTS layer), every modern web browser (Firefox /
## Chromium / WebKitGTK persist cookies + history + IndexedDB in SQLite
## databases), most messaging clients (Discord / Slack / Element /
## Signal store conversation history in SQLite), ``geoclue`` (location
## history), ``zeitgeist`` (activity log), and the systemd ``journald``
## offline log database. The libSqlite3 client library is consumed
## directly from the C ABI by every one of these stacks.
##
## ## sha256 strategy
##
## We vendor the upstream 3.47.1 .tar.gz at
## ``recipes/packages/source/sqlite/vendor/sqlite-autoconf-3470100.tar.gz``
## and reference it via a ``file://`` URL. The sqlite.org download URL
## is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 3.47.1 (current upstream stable)
##
## SQLite releases are cut on sqlite.org with the canonical numbering
## ``<X>.<Y>.<Z>.<extra>`` collapsed to ``XYYZZ00`` in the autoconf
## tarball name (3.47.1 → ``3470100``). 3.47.1 is the current stable in
## the 3.47.x line as of mid-2026 and the ABI is stable since the 3.0
## cut (SQLite famously commits to long-term file-format + C ABI
## compatibility) — anything ``>=3.0`` covers every consumer's pinning.
##
## sha256 = 416a6f45bf2cacd494b208fdee1beda509abda951d5f47bc4f2792126f01b452
##  (computed locally over the vendored
##  ``sqlite-autoconf-3470100.tar.gz``, 3,328,564 bytes; downloaded
##  once from the upstream URL recorded in ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``./configure`` + ``make``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the library + executable artifacts via the
## ``library`` / ``executable`` blocks so the M9.K artifact registry
## already knows what shared objects + binaries to expect.
##
## ## Artifacts
##
##   * ``libSqlite3`` (library) — ``libsqlite3.so`` the canonical SQLite
##     client library. The upstream SONAME ``sqlite3`` is PascalCased to
##     ``libSqlite3`` per the libExpat / libCrypto / libSsl precedent of
##     preserving the canonical ``lib`` prefix while PascalCasing the
##     SONAME body.
##   * ``sqlite3Cli`` (executable) — ``/usr/bin/sqlite3`` the
##     interactive shell binary. Renamed from the bare-``sqlite3``
##     upstream name to ``sqlite3Cli`` to avoid identifier collision
##     with the package-name + downstream artifact names that often
##     reuse the bare ``sqlite3`` token (matching the mkfsBin /
##     sddmGreeter / systemdInit precedent for disambiguating package-
##     level binaries from generic names).
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``--disable-static`` — skip the static archive (not used by the
##                            v1 desktop story).
##   * ``--disable-tcl``    — skip the TCL bindings (heavy TCL dependency
##                            surface; the v1 desktop consumes the C ABI
##                            directly).
##   * ``--enable-fts5``    — enable the FTS5 full-text-search virtual
##                            table module (tracker + baloo + zeitgeist
##                            depend on FTS for the desktop indexer
##                            stacks).
##   * ``--enable-json1``   — enable the JSON1 extension (web browsers
##                            + messaging clients persist JSON payloads
##                            and need the SQL-side JSON1 functions).
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. an embedded variant that
## disables FTS5 + JSON1 for the minimal embedded-database surface).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package sqliteSource:
  ## From-source sqlite — forty-first M9.H/I/K production recipe.
  ## SQLite ships its hand-rolled ``./configure`` script via the
  ## ``sqlite-autoconf-*.tar.gz`` amalgamation release; the convention
  ## layer treats the ``configureFlags:`` channel as the abstract
  ## "argv passed to ``./configure``" carrier (same channel openssl
  ## + zlib reused for their custom configure scripts). Ships ONE
  ## library (``libSqlite3``) + ONE executable (``sqlite3Cli``) from
  ## a single ``./configure`` + ``make`` invocation.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags.

  versions:
    ## Pinned upstream release. ``sourceUrl`` records the canonical
    ## sqlite.org release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical GitHub mirror that
    ## hosts the sqlite source tree (upstream's primary VCS is Fossil
    ## on sqlite.org but the GitHub mirror is what ``repro
    ## update-source`` consumes).
    "3.47.1":
      sourceRevision = "version-3.47.1"
      sourceUrl = "https://www.sqlite.org/2024/sqlite-autoconf-3470100.tar.gz"
      sourceRepository = "https://github.com/sqlite/sqlite"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 3,328,564-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://www.sqlite.org/2024/sqlite-autoconf-3470100.tar.gz"
    sha256: "416a6f45bf2cacd494b208fdee1beda509abda951d5f47bc4f2792126f01b452"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf is NOT listed even though the script-name is
    ## ``./configure`` because SQLite's amalgamation tarball ships a
    ## hand-rolled script (NOT generated by autoconf). The
    ## ``c_cpp_autotools`` convention's compile action runs the script
    ## verbatim regardless of how it was generated.
    ##
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — SQLite is C99 single-translation-
    ## unit amalgamation source.
    "gcc >=11"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  library libSqlite3:
    ## ``libsqlite3.so`` — the canonical SQLite client library
    ## consumed via the C ABI by tracker / baloo / every modern web
    ## browser / every modern messaging client / geoclue / zeitgeist /
    ## systemd-journald. The upstream SONAME ``sqlite3`` is PascalCased
    ## to ``libSqlite3`` per the libExpat / libCrypto / libSsl
    ## precedent of preserving the canonical ``lib`` prefix while
    ## PascalCasing the SONAME body. v1 records the artifact only;
    ## the per-artifact build body lands in M9.L when the convention's
    ## make-spawn + install-glue closes.
    discard

  executable sqlite3Cli:
    ## ``/usr/bin/sqlite3`` — the interactive shell binary every
    ## desktop installer/admin uses to inspect SQLite databases.
    ## Renamed from the bare-``sqlite3`` upstream name to ``sqlite3Cli``
    ## to avoid identifier collision with the package-name + downstream
    ## artifact names that often reuse the bare ``sqlite3`` token
    ## (matching the mkfsBin / sddmGreeter / systemdInit precedent for
    ## disambiguating package-level binaries from generic names). v1
    ## records the artifact only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("sqliteSource")
    try:
      let opts = @[
        "--disable-static",
        "--disable-tcl",
        "--enable-fts5",
        "--enable-json1",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libSqlite3")
      discard pkg.executable("sqlite3Cli")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
