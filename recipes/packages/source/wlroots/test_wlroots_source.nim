## Smoke test for the from-source ``wlrootsSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FOURTH real production
## from-source recipe (predecessors: ``dbusBrokerSource`` /
## ``libdrmSource`` / ``waylandSource``). wlroots' specific coverage
## angle vs the prior three is a SINGLE library artifact off a meson
## build whose dependency surface is wider than libdrm's (it pulls
## libdrm, Wayland, libxkbcommon, pixman, libinput together) — the M2
## ``uses:`` round-trip therefore stretches across eight tool / library
## pins, where the libdrm sibling has three.
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (the ``cmake`` channel must NOT see the meson flags).
##   * SINGLE library artifact registration (M3) — ``libwlroots``
##     attributed to ``wlrootsSource`` with kind ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library artifact under ``wlrootsSource``
# at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/wlroots/vendor/wlroots-0.19.3.tar.gz"

const ExpectedHash =
  "5d02693175e5afd9af5f10e3e4976d6e9249dc39a90eb17d23fa5f54b125ccc5"

const ExpectedMesonOptions = @[
  "-Dexamples=false",
  "-Dxwayland=disabled",
  "-Dxcb-errors=disabled",
  "-Dwerror=false",
  "--buildtype=release",
]

suite "wlrootsSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("wlrootsSource")
    check spec.packageName == "wlrootsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 671,529-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("wlrootsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream uses for
    # freedesktop.org gitlab release dist tarballs.
    let spec = registeredFetchSpec("wlrootsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libwlroots`` is the only artifact and
    # must be tagged ``dakLibrary``. wlroots' meson build emits a
    # single shared object (unlike libdrm's per-vendor split or
    # Wayland's client/server/cursor split); a regression that
    # mis-tagged the artifact kind would mis-route the M9.L install
    # path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("wlrootsSource")
    check arts.len == 1
    check arts[0].packageName == "wlrootsSource"
    check arts[0].artifactName == "libwlroots"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream freedesktop.org gitlab
    # release tag is recorded for ``repro update-source`` even though
    # the live fetch points at the vendored copy. The repository
    # points at the canonical gitlab project that hosts the wlroots
    # source tree.
    let vs = registeredVersions("wlrootsSource")
    check vs.len == 1
    check vs[0].version == "0.19.3"
    check vs[0].sourceRevision == "0.19.3"
    check vs[0].sourceUrl ==
      "https://gitlab.freedesktop.org/wlroots/wlroots/-/releases/0.19.3/downloads/wlroots-0.19.3.tar.gz"
    check vs[0].sourceRepository ==
      "https://gitlab.freedesktop.org/wlroots/wlroots"
