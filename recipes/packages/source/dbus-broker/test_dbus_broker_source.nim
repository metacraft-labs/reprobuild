## Smoke test for the from-source ``dbusBrokerSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on a real production recipe (the
## FIRST from-source production recipe to consume the trio).
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check.
##   * ``executable`` artifact registration (M3) — both binaries
##     present, both tagged ``dakExecutable``, both attributed to the
##     correct package.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + executable artifacts under
# ``dbusBrokerSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/dbus-broker/vendor/dbus-broker-v36.tar.gz"

const ExpectedHash =
  "5058a81eea8086636ef09a670d103e35e650a6f0200aadc2f59f3fb6e76c37b8"

const ExpectedMesonOptions = @[
  "-Daudit=false",
  "-Dlauncher=true",
  "-Dlinux-4-17=true",
  "-Dreference-test=false",
  "-Dselinux=false",
  "-Dapparmor=false",
  "--buildtype=release",
]

suite "dbusBrokerSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("dbusBrokerSource")
    check spec.packageName == "dbusBrokerSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 241,290-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("dbusBrokerSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream uses for GitHub
    # tag tarballs.
    let spec = registeredFetchSpec("dbusBrokerSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    # M9.I exact-order round-trip — meson evaluates options
    # left-to-right and a regression that reorders this seq would
    # silently change build behaviour (release/debug, audit on/off).
    let flags = registeredBuildFlags("dbusBrokerSource", "", "meson")
    check flags == ExpectedMesonOptions
    check flags.len == 7

  test "mesonOptions does not leak into the cmake channel":
    # Channel-isolation spot-check — a regression that flattens the
    # per-channel registries would surface here.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("dbusBrokerSource", "", "cmake") == emptyStrSeq

  test "executable artifacts register both broker binaries":
    # M3 artifact registry: BOTH ``dbusBroker`` and
    # ``dbusBrokerLaunch`` must be present so the convention layer's
    # install/output collection knows which binaries to harvest.
    let arts = registeredArtifacts("dbusBrokerSource")
    check arts.len == 2
    var seenBroker = false
    var seenLaunch = false
    for art in arts:
      if art.artifactName == "dbusBroker":
        seenBroker = true
        check art.kind == dakExecutable
        check art.packageName == "dbusBrokerSource"
      elif art.artifactName == "dbusBrokerLaunch":
        seenLaunch = true
        check art.kind == dakExecutable
        check art.packageName == "dbusBrokerSource"
    check seenBroker
    check seenLaunch

  test "versions block records the upstream tag + URL":
    # M2 versions registry: the upstream GitHub tag is recorded for
    # ``repro update-source`` even though the live fetch points at the
    # vendored copy.
    let vs = registeredVersions("dbusBrokerSource")
    check vs.len == 1
    check vs[0].version == "36"
    check vs[0].sourceRevision == "refs/tags/v36"
    check vs[0].sourceUrl ==
      "https://github.com/bus1/dbus-broker/archive/refs/tags/v36.tar.gz"
    check vs[0].sourceRepository == "https://github.com/bus1/dbus-broker"
