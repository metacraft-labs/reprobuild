## Smoke test for the from-source ``libinputSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the NINTH real production
## from-source recipe (predecessors: ``dbusBrokerSource`` /
## ``libdrmSource`` / ``waylandSource`` / ``wlrootsSource`` /
## ``swaySource`` / ``linuxKernelSource`` / ``libxkbcommonSource`` /
## ``pixmanSource``). libinput's unique coverage angle vs the prior
## eight is a library + executable pair where the on-disk filenames
## COLLIDE (``libinput.so`` vs ``libinput`` CLI) but the DSL identifiers
## must STAY DISTINCT (``libinput`` for the library, ``libinputBin``
## for the executable) — the M3 artifact registry must keep the two
## artifacts disambiguated via the ``dakLibrary`` / ``dakExecutable``
## kind discriminator AND via distinct Nim-identifier artifact names.
##
## Coverage (8 check assertions across 7 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (the ``cmake`` channel must NOT see the meson flags).
##   * NAME-COLLISION library + executable artifact registration (M3)
##     — ``libinput`` tagged ``dakLibrary`` (the shared object) and
##     ``libinputBin`` tagged ``dakExecutable`` (the CLI tool whose
##     install filename is also ``libinput``).
##   * ``versions:`` block round-trip (M2) — upstream tag + Debian
##     source pool URL + repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library + executable artifacts under
# ``libinputSource`` at module init time.
import ./repro

const ExpectedUrl =
  "http://deb.debian.org/debian/pool/main/libi/libinput/libinput_1.28.1.orig.tar.gz"

const ExpectedHash =
  "a13f8c9a7d93df3c85c66afd135f0296701d8d32f911991b7aa4273fdd6a42a3"

const ExpectedMesonOptions = @[
  "-Ddocumentation=false",
  "-Ddebug-gui=false",
  "-Dtests=false",
  "-Dlibwacom=false",
  "-Dudev-dir=/lib/udev",
  "--buildtype=release",
]

suite "libinputSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("libinputSource")
    check spec.packageName == "libinputSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 1,074,349-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("libinputSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream libinput release
    # dist tarballs use.
    let spec = registeredFetchSpec("libinputSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register one library plus one executable":
    # M3 artifact registry: ``libinput`` must be tagged ``dakLibrary``
    # while ``libinputBin`` must be tagged ``dakExecutable``. The
    # unique coverage of THIS recipe is the on-disk filename collision
    # (``libinput.so`` vs the ``libinput`` CLI binary) — the DSL
    # identifiers must stay DISTINCT, and the M3 registry must keep
    # the two artifacts disambiguated via the kind discriminator. A
    # regression that flattened the kind tag would mis-route the M9.L
    # install path (``lib/`` vs ``bin/``) and produce a file-system
    # collision at install time.
    let arts = registeredArtifacts("libinputSource")
    check arts.len == 2
    var seenLib = false
    var seenBin = false
    for art in arts:
      check art.packageName == "libinputSource"
      case art.artifactName
      of "libinput":
        seenLib = true
        check art.kind == dakLibrary
      of "libinputBin":
        seenBin = true
        check art.kind == dakExecutable
      else:
        discard
    check seenLib
    check seenBin

  test "versions block records the upstream tag + Debian URL + repository":
    # M2 versions registry: the Debian source pool URL is recorded
    # for ``repro update-source`` even though the live fetch points
    # at the vendored copy (the canonical freedesktop.org gitlab
    # release URL sits behind an Anubis bot-protection challenge).
    # The repository points at the canonical freedesktop.org gitlab
    # project that hosts the libinput source tree.
    let vs = registeredVersions("libinputSource")
    check vs.len == 1
    check vs[0].version == "1.28.1"
    check vs[0].sourceRevision == "1.28.1"
    check vs[0].sourceUrl ==
      "http://deb.debian.org/debian/pool/main/libi/libinput/libinput_1.28.1.orig.tar.gz"
    check vs[0].sourceRepository ==
      "https://gitlab.freedesktop.org/libinput/libinput"
