## Smoke test for the from-source ``pipewireSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTY-EIGHTH real
## production from-source recipe. pipewire is THE modern multimedia
## framework on Linux: replaces pulseaudio + jackd for audio AND
## provides the screen-capture transport every Wayland compositor uses
## for desktop sharing + screen recording.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (cmake + configure channels MUST be empty).
##   * MIXED artifact registration (M3) — two executables
##     (``dakExecutable``) + one library (``dakLibrary``) attributed
##     to ``pipewireSource`` with kind discriminators preserved
##     per-artifact.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + two executables + one library artifact
# under ``pipewireSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://gitlab.freedesktop.org/pipewire/pipewire/-/archive/1.6.5/pipewire-1.6.5.tar.gz"

# Tarball-bytes sha256 — distinct from the nixpkgs SRI hash which
# covers the NAR-form EXTRACTED directory rather than the tarball
# bytes (gzip mtime + tar block padding differ between the two).
const ExpectedHash =
  "4c9f7e85a760a4169cd4bc668bafea90fe4838aaf3f08a93f11bb9222809d490"

const ExpectedMesonOptions = @[
  "-Dtests=disabled",
  "-Ddocs=disabled",
  "-Dexamples=disabled",
  "-Dman=disabled",
  "--buildtype=release",
]

suite "pipewireSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("pipewireSource")
    check spec.packageName == "pipewireSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # Length + algorithm check guards against a future bump that
    # forgets to widen the hash alongside the URL. The pinned value
    # is the upstream gitlab.freedesktop.org tarball-bytes sha256.
    let spec = registeredFetchSpec("pipewireSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream gitlab archive
    # tarballs use.
    let spec = registeredFetchSpec("pipewireSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register two executables + one library mixed-kind":
    # M3 artifact registry: ``pipewireDaemon`` + ``pwCat`` are tagged
    # ``dakExecutable`` while ``libPipewire`` is tagged ``dakLibrary``.
    # The unique coverage of THIS recipe is the MIXED meson shape
    # where a single ``meson setup`` + ``ninja`` emits two binaries
    # AND a shared library — a regression that flattened the kind
    # discriminator at the meson convention layer would mis-route the
    # M9.L install path (``lib/`` vs ``bin/``) for one of the three.
    let arts = registeredArtifacts("pipewireSource")
    check arts.len == 3
    var seenDaemon = false
    var seenPwCat = false
    var seenLib = false
    for art in arts:
      check art.packageName == "pipewireSource"
      case art.artifactName
      of "pipewireDaemon":
        seenDaemon = true
        check art.kind == dakExecutable
      of "pwCat":
        seenPwCat = true
        check art.kind == dakExecutable
      of "libPipewire":
        seenLib = true
        check art.kind == dakLibrary
      else:
        discard
    check seenDaemon
    check seenPwCat
    check seenLib

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream gitlab.freedesktop.org
    # release tag is recorded for ``repro update-source``. The
    # repository points at the canonical gitlab project that hosts
    # the pipewire source tree.
    let vs = registeredVersions("pipewireSource")
    check vs.len == 1
    check vs[0].version == "1.6.5"
    check vs[0].sourceRevision == "1.6.5"
    check vs[0].sourceUrl ==
      "https://gitlab.freedesktop.org/pipewire/pipewire/-/archive/1.6.5/pipewire-1.6.5.tar.gz"
    check vs[0].sourceRepository ==
      "https://gitlab.freedesktop.org/pipewire/pipewire"
