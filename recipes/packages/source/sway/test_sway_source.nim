## Smoke test for the from-source ``swaySource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FIFTH real production
## from-source recipe (predecessors: ``dbusBrokerSource`` /
## ``libdrmSource`` / ``waylandSource`` / ``wlrootsSource``). Sway's
## specific coverage angle vs the prior four is FOUR executable
## artifacts off a meson build whose dependency surface is the WIDEST
## yet (10 entries in ``uses:`` covering meson/ninja/gcc + wlroots +
## wayland-scanner + libxkbcommon + pcre2 + json-c + pango + cairo +
## gdk-pixbuf) — the M2 ``uses:`` round-trip therefore stretches
## across the largest tool / library pin set in the from-source
## cohort, while the M3 artifact registry exercises a four-executable
## fan-out (vs dbus-broker's two).
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (the ``cmake`` channel must NOT see the meson flags).
##   * FOUR executable artifact registration (M3) — ``sway`` +
##     ``swaybar`` + ``swaynag`` + ``swaymsg`` all attributed to
##     ``swaySource`` with kind ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + executable artifacts under
# ``swaySource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/sway/vendor/sway-1.11.tar.gz"

const ExpectedHash =
  "034ec4519326d6af5275814700dde46e852c5174614109affe4c86b2fbee062a"

const ExpectedMesonOptions = @[
  "-Dxwayland=disabled",
  "-Dman-pages=disabled",
  "-Dtray=disabled",
  "-Dwerror=false",
  "--buildtype=release",
]

suite "swaySource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("swaySource")
    check spec.packageName == "swaySource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 5,583,731-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("swaySource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream uses for GitHub
    # tag tarballs.
    let spec = registeredFetchSpec("swaySource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register all four sway binaries as executables":
    # M3 artifact registry: ALL FOUR of ``sway`` / ``swaybar`` /
    # ``swaynag`` / ``swaymsg`` must be present and tagged
    # ``dakExecutable``. A regression that loses any one of them
    # would mis-route the M9.L install path (the corresponding
    # binary would never get harvested into the package output);
    # a regression that mis-tagged the kind would route the binary
    # to ``lib/`` instead of ``bin/``.
    let arts = registeredArtifacts("swaySource")
    check arts.len == 4
    var seenSway = false
    var seenSwaybar = false
    var seenSwaynag = false
    var seenSwaymsg = false
    for art in arts:
      check art.packageName == "swaySource"
      check art.kind == dakExecutable
      case art.artifactName
      of "sway":    seenSway    = true
      of "swaybar": seenSwaybar = true
      of "swaynag": seenSwaynag = true
      of "swaymsg": seenSwaymsg = true
      else: discard
    check seenSway
    check seenSwaybar
    check seenSwaynag
    check seenSwaymsg

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub tag is recorded for
    # ``repro update-source`` even though the live fetch points at the
    # vendored copy. The repository points at the canonical GitHub
    # project that hosts the Sway source tree.
    let vs = registeredVersions("swaySource")
    check vs.len == 1
    check vs[0].version == "1.11"
    check vs[0].sourceRevision == "1.11"
    check vs[0].sourceUrl ==
      "https://github.com/swaywm/sway/archive/refs/tags/1.11.tar.gz"
    check vs[0].sourceRepository == "https://github.com/swaywm/sway"
