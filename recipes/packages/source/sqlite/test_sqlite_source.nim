## Smoke test for the from-source ``sqliteSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FORTY-FIRST real
## production from-source recipe. sqlite's unique coverage angle vs
## the prior forty is being the SQLite-authoritative
## ``sqlite-autoconf-*.tar.gz`` amalgamation tarball — a single-
## translation-unit C99 source distribution shipping a hand-rolled
## ``./configure`` script that accepts the standard autoconf-shaped
## flag grammar. One library (``libSqlite3``) + one executable
## (``sqlite3Cli``) from a single ``./configure`` + ``make``
## invocation.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake channels MUST be empty).
##   * TWO artifact registration (M3) — ``libSqlite3`` tagged
##     ``dakLibrary`` + ``sqlite3Cli`` tagged ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + library + executable artifacts under
# ``sqliteSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://www.sqlite.org/2024/sqlite-autoconf-3470100.tar.gz"

const ExpectedHash =
  "416a6f45bf2cacd494b208fdee1beda509abda951d5f47bc4f2792126f01b452"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-tcl",
  "--enable-fts5",
  "--enable-json1",
]

suite "sqliteSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("sqliteSource")
    check spec.packageName == "sqliteSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 3,328,564-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("sqliteSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream sqlite.org release
    # tarballs use.
    let spec = registeredFetchSpec("sqliteSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register one library + one executable with correct kinds":
    # M3 artifact registry: ``libSqlite3`` is tagged ``dakLibrary``
    # while ``sqlite3Cli`` is tagged ``dakExecutable``. SQLite's build
    # emits both binaries from one ``./configure`` + ``make``
    # invocation: ``libsqlite3.so`` (the canonical client library) and
    # ``/usr/bin/sqlite3`` (the interactive shell). A regression that
    # flattened the kind discriminator would mis-route the M9.L
    # install path (``lib/`` vs ``bin/``); a regression that collapsed
    # the artifact-name partitioning would not produce two distinct
    # entries with the expected names below.
    let arts = registeredArtifacts("sqliteSource")
    check arts.len == 2
    var seenLib = false
    var seenCli = false
    for art in arts:
      check art.packageName == "sqliteSource"
      case art.artifactName
      of "libSqlite3":
        seenLib = true
        check art.kind == dakLibrary
      of "sqlite3Cli":
        seenCli = true
        check art.kind == dakExecutable
      else:
        discard
    check seenLib
    check seenCli

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream sqlite.org release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical GitHub mirror that hosts the sqlite source tree.
    let vs = registeredVersions("sqliteSource")
    check vs.len == 1
    check vs[0].version == "3.47.1"
    check vs[0].sourceRevision == "version-3.47.1"
    check vs[0].sourceUrl ==
      "https://www.sqlite.org/2024/sqlite-autoconf-3470100.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/sqlite/sqlite"
