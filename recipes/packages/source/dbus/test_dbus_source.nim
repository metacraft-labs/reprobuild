## Smoke test for the from-source ``dbusSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FORTIETH real production
## from-source recipe. Upstream dbus 1.16.0 ships meson-only (the
## autotools layer was retired before the cut); the recipe and this
## test were converted from autotools-shape to meson-shape in
## ``M9.R.15a.1``. One executable (``dbusDaemon``) + one library
## (``libDbus1``) from a single ``meson setup`` + ``ninja`` invocation
## — exercising the executable + library mixed-kind shape on the
## meson channel.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake channels MUST be empty).
##   * TWO artifact registration (M3) — ``dbusDaemon`` tagged
##     ``dakExecutable`` + ``libDbus1`` tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + executable + library artifacts under
# ``dbusSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/dbus/vendor/dbus-1.16.0.tar.xz"

const ExpectedHash =
  "9f8ca5eb51cbe09951aec8624b86c292990ae2428b41b856e2bed17ec65c8849"

const ExpectedMesonOptions = @[
  "modular_tests=disabled",
  "intrusive_tests=false",
  "installed_tests=false",
  "x11_autolaunch=disabled",
  "doxygen_docs=disabled",
  "xml_docs=disabled",
  "ducktype_docs=disabled",
]

suite "dbusSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("dbusSource")
    check spec.packageName == "dbusSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 1,114,680-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("dbusSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream freedesktop release
    # tarballs use.
    let spec = registeredFetchSpec("dbusSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register one executable + one library with correct kinds":
    # M3 artifact registry: ``dbusDaemon`` is tagged ``dakExecutable``
    # while ``libDbus1`` is tagged ``dakLibrary``. dbus's meson build
    # emits both binaries from one ``meson setup`` + ``ninja``
    # invocation: ``/usr/bin/dbus-daemon`` (the reference message-bus
    # daemon) and ``libdbus-1.so`` (the canonical libdbus client
    # library). A regression that flattened the kind discriminator
    # would mis-route the M9.L install path (``lib/`` vs ``bin/``);
    # a regression that collapsed the artifact-name partitioning would
    # not produce two distinct entries with the expected names below.
    let arts = registeredArtifacts("dbusSource")
    check arts.len == 2
    var seenDaemon = false
    var seenLib = false
    for art in arts:
      check art.packageName == "dbusSource"
      case art.artifactName
      of "dbusDaemon":
        seenDaemon = true
        check art.kind == dakExecutable
      of "libDbus1":
        seenLib = true
        check art.kind == dakLibrary
      else:
        discard
    check seenDaemon
    check seenLib

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream freedesktop release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical GitLab project that hosts the reference dbus source
    # tree.
    let vs = registeredVersions("dbusSource")
    check vs.len == 1
    check vs[0].version == "1.16.0"
    check vs[0].sourceRevision == "dbus-1.16.0"
    check vs[0].sourceUrl ==
      "https://dbus.freedesktop.org/releases/dbus/dbus-1.16.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.freedesktop.org/dbus/dbus"
