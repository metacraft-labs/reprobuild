## Smoke test for the from-source ``waylandSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the THIRD real production
## from-source recipe (the first was ``dbusBrokerSource``, the second
## ``libdrmSource``). Where dbus-broker exercised executable artifacts
## only and libdrm exercised library artifacts only, this one
## exercises BOTH kinds off the same package — the M3 artifact registry
## must keep ``dakLibrary`` and ``dakExecutable`` discriminators
## correctly distinguished within a single package's artifact set.
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (the ``cmake`` channel must NOT see the meson flags).
##   * MIXED artifact registration (M3) — three libraries
##     (``dakLibrary``) plus one executable (``dakExecutable``), all
##     attributed to ``waylandSource``, kind discriminators preserved
##     per-artifact (the unique-coverage aspect of this third recipe).
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library + executable artifacts under
# ``waylandSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/wayland/vendor/wayland-1.25.0.tar.xz"

const ExpectedHash =
  "c065f040afdff3177680600f249727e41a1afc22fccf27222f15f5306faa1f03"

const ExpectedMesonOptions = @[
  "-Ddocumentation=false",
  "-Ddtd_validation=false",
  "-Dlibraries=true",
  "-Dscanner=true",
  "-Dtests=false",
  "--buildtype=release",
]

suite "waylandSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("waylandSource")
    check spec.packageName == "waylandSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 609,628-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("waylandSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream uses for
    # freedesktop.org gitlab release tarballs.
    let spec = registeredFetchSpec("waylandSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    # M9.I exact-order round-trip — meson evaluates options
    # left-to-right and a regression that reorders this seq would
    # silently change build behaviour (which artifacts get built,
    # release/debug, documentation on/off, tests on/off).
    let flags = registeredBuildFlags("waylandSource", "", "meson")
    check flags == ExpectedMesonOptions
    check flags.len == 6

  test "mesonOptions does not leak into the cmake channel":
    # Channel-isolation spot-check — a regression that flattens the
    # per-channel registries would surface here.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("waylandSource", "", "cmake") == emptyStrSeq

  test "artifacts register three libraries plus one executable":
    # M3 artifact registry: ``libwaylandClient``, ``libwaylandServer``,
    # ``libwaylandCursor`` must all be tagged ``dakLibrary`` while
    # ``waylandScanner`` must be tagged ``dakExecutable``. The unique
    # coverage of THIS recipe (vs dbus-broker / libdrm) is that the
    # M3 registry keeps ``dakLibrary`` and ``dakExecutable``
    # discriminators correctly distinguished WITHIN a single package's
    # artifact set — a regression that flattened the kind discriminator
    # would mis-route the M9.L install path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("waylandSource")
    check arts.len == 4
    var seenClient = false
    var seenServer = false
    var seenCursor = false
    var seenScanner = false
    for art in arts:
      check art.packageName == "waylandSource"
      case art.artifactName
      of "libwaylandClient":
        seenClient = true
        check art.kind == dakLibrary
      of "libwaylandServer":
        seenServer = true
        check art.kind == dakLibrary
      of "libwaylandCursor":
        seenCursor = true
        check art.kind == dakLibrary
      of "waylandScanner":
        seenScanner = true
        check art.kind == dakExecutable
      else:
        discard
    check seenClient
    check seenServer
    check seenCursor
    check seenScanner

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream freedesktop.org gitlab
    # release tag is recorded for ``repro update-source`` even though
    # the live fetch points at the vendored copy. The repository
    # points at the canonical gitlab project that hosts the Wayland
    # source tree.
    let vs = registeredVersions("waylandSource")
    check vs.len == 1
    check vs[0].version == "1.25.0"
    check vs[0].sourceRevision == "1.25.0"
    check vs[0].sourceUrl ==
      "https://gitlab.freedesktop.org/wayland/wayland/-/releases/1.25.0/downloads/wayland-1.25.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.freedesktop.org/wayland/wayland"
