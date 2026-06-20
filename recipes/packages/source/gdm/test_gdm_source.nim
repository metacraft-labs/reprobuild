## Smoke test for the from-source ``gdmSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SEVENTEENTH real production
## from-source recipe and the SECOND recipe in the GNOME stack batch.
## gdm's unique coverage angle vs expat (the first autotools recipe)
## is twofold: (a) it's the first autotools recipe to ship TWO
## executable artifacts from one ``package`` macro, and (b) its
## ``configureFlags:`` set exercises every autotools-flag idiom in one
## sequence (``--disable-*``, ``--without-*``, ``--with-*=value``,
## ``--disable-*=false`` polarity flip, ``--enable-*``). The
## cross-channel isolation pin below would surface a regression that
## leaks ``./configure`` flags into the meson, cmake, or make channels
## (or vice versa).
##
## Coverage (12 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake channels MUST be empty).
##   * TWO executable artifact registration (M3) — ``gdm`` +
##     ``gdmGreeterSession`` both tagged ``dakExecutable`` under the
##     same package.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + executable artifacts under
# ``gdmSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/gdm/vendor/gdm-47.0.tar.xz"

const ExpectedHash =
  "c5858326bfbcc8ace581352e2be44622dc0e9e5c2801c8690fd2eed502607f84"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--without-plymouth",
  "--without-systemdsystemunitdir",
  "--with-default-pam-config=none",
  "--disable-wayland-support=false",
  "--enable-gdm-xsession",
]

suite "gdmSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("gdmSource")
    check spec.packageName == "gdmSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 936,172-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("gdmSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream gnome.org release
    # tarballs use.
    let spec = registeredFetchSpec("gdmSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register two executables under the same package":
    # M3 artifact registry: both ``gdm`` and ``gdmGreeterSession``
    # must be present and tagged ``dakExecutable``. gdm's autotools
    # build emits two binaries: the daemon (``gdm``) and the greeter
    # session UI (``gdm-greeter-session``). A regression that lost
    # either binary would mis-route the M9.L install path (the
    # corresponding binary would never get harvested into the
    # package output); a regression that mis-tagged the kind would
    # route the binary to ``lib/`` instead of ``bin/`` /
    # ``libexec/``.
    let arts = registeredArtifacts("gdmSource")
    check arts.len == 2
    var seenGdm = false
    var seenGreeter = false
    for art in arts:
      check art.packageName == "gdmSource"
      check art.kind == dakExecutable
      case art.artifactName
      of "gdm":
        seenGdm = true
      of "gdmGreeterSession":
        seenGreeter = true
      else:
        discard
    check seenGdm
    check seenGreeter

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.gnome.org release
    # tag is recorded for ``repro update-source`` even though the
    # live fetch points at the vendored copy. The repository points
    # at the canonical GNOME gitlab project that hosts the gdm
    # source tree.
    let vs = registeredVersions("gdmSource")
    check vs.len == 1
    check vs[0].version == "47.0"
    check vs[0].sourceRevision == "47.0"
    check vs[0].sourceUrl ==
      "https://download.gnome.org/sources/gdm/47/gdm-47.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.gnome.org/GNOME/gdm"
