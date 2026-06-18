## Smoke test for the from-source ``wireplumberSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTY-NINTH real
## production from-source recipe. wireplumber is THE session/policy
## manager for pipewire: implements the Lua-scripted session-policy
## layer that decides device-to-role mappings + per-application audio
## routing on top of pipewire's multimedia graph.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (cmake + configure channels MUST be empty).
##   * MIXED artifact registration (M3) — one executable
##     (``dakExecutable``) + one library (``dakLibrary``) attributed
##     to ``wireplumberSource`` with kind discriminators preserved
##     per-artifact.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + one executable + one library artifact
# under ``wireplumberSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://gitlab.freedesktop.org/pipewire/wireplumber/-/archive/0.5.14/wireplumber-0.5.14.tar.gz"

# Placeholder hash — see recipe header for context on why this is
# zeros (nixpkgs records the NAR-form hash of the extracted directory,
# not the tarball bytes; a future maintainer must download once +
# sha256sum to replace).
const ExpectedHash =
  "0000000000000000000000000000000000000000000000000000000000000000"

const ExpectedMesonOptions = @[
  "-Ddocumentation=disabled",
  "-Dintrospection=disabled",
  "-Dsystem-lua=true",
  "-Dtests=false",
  "--buildtype=release",
]

suite "wireplumberSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("wireplumberSource")
    check spec.packageName == "wireplumberSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # Length + algorithm check guards against a future bump that
    # forgets to widen the hash alongside the URL. The placeholder
    # value is the all-zeros sentinel a future maintainer must replace
    # with the actual tarball sha256.
    let spec = registeredFetchSpec("wireplumberSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream gitlab archive
    # tarballs use.
    let spec = registeredFetchSpec("wireplumberSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    # M9.I exact-order round-trip on the meson channel — a regression
    # that reorders, drops, or duplicates the flag sequence would
    # silently flip whether the docs / introspection / system-lua /
    # tests paths are built.
    let flags = registeredBuildFlags("wireplumberSource", "", "meson")
    check flags == ExpectedMesonOptions
    check flags.len == 5

  test "mesonOptions does not leak into the cmake channel":
    # Cross-channel isolation — guards against a regression that
    # flattens the per-channel registries.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("wireplumberSource", "", "cmake") == emptyStrSeq

  test "mesonOptions does not leak into the configure channel":
    # Cross-channel isolation #2 — guards against a regression that
    # merges the meson + autotools channels.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("wireplumberSource", "", "configure") == emptyStrSeq

  test "artifacts register one executable + one library mixed-kind":
    # M3 artifact registry: ``wireplumber`` is tagged
    # ``dakExecutable`` while ``libWireplumber`` is tagged
    # ``dakLibrary``. The MIXED meson shape where a single
    # ``meson setup`` + ``ninja`` emits BOTH kinds — a regression
    # that flattened the kind discriminator at the meson convention
    # layer would mis-route the M9.L install path (``lib/`` vs
    # ``bin/``) for one of the two.
    let arts = registeredArtifacts("wireplumberSource")
    check arts.len == 2
    var seenDaemon = false
    var seenLib = false
    for art in arts:
      check art.packageName == "wireplumberSource"
      case art.artifactName
      of "wireplumber":
        seenDaemon = true
        check art.kind == dakExecutable
      of "libWireplumber":
        seenLib = true
        check art.kind == dakLibrary
      else:
        discard
    check seenDaemon
    check seenLib

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream gitlab.freedesktop.org
    # release tag is recorded for ``repro update-source``. The
    # repository points at the canonical gitlab project that hosts
    # the wireplumber source tree.
    let vs = registeredVersions("wireplumberSource")
    check vs.len == 1
    check vs[0].version == "0.5.14"
    check vs[0].sourceRevision == "0.5.14"
    check vs[0].sourceUrl ==
      "https://gitlab.freedesktop.org/pipewire/wireplumber/-/archive/0.5.14/wireplumber-0.5.14.tar.gz"
    check vs[0].sourceRepository ==
      "https://gitlab.freedesktop.org/pipewire/wireplumber"
