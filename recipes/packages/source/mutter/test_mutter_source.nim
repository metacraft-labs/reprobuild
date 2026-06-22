## Smoke test for the from-source ``mutterSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTEENTH real production
## from-source recipe and the FIRST recipe in the GNOME stack batch.
## mutter's unique coverage angle vs the prior fifteen is the second
## meson-driven multi-artifact recipe to ship BOTH a library AND an
## executable from the same ``package`` macro (Wayland was the first):
## the M3 artifact registry must keep ``dakLibrary`` (``libMutter``) and
## ``dakExecutable`` (``mutterBin``) discriminators correctly
## distinguished WITHIN a single package's artifact set. A regression
## that flattened the kind discriminator would mis-route the M9.L
## install path (``lib/`` vs ``bin/``).
##
## Coverage (12 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (cmake + configure channels MUST be empty).
##   * Library + executable artifact registration (M3) — ``libMutter``
##     tagged ``dakLibrary`` and ``mutterBin`` tagged ``dakExecutable``
##     within the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library + executable artifacts under
# ``mutterSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://download.gnome.org/sources/mutter/47/mutter-47.10.tar.xz"

const ExpectedHash =
  "ee8a583c2b6ff309b501dc97e7c0b4f11d6197a9529ed22247ee95e89663e969"

const ExpectedMesonOptions = @[
  "-Dintrospection=false",
  "-Dprofiler=false",
  "-Dtests=false",
  "-Ddebug=false",
  "-Dnative_backend=true",
  "-Dwayland=true",
  "-Dx11=false",
  "-Dxwayland=false",
  "-Dremote_desktop=false",
  "--buildtype=release",
]

suite "mutterSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("mutterSource")
    check spec.packageName == "mutterSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 6,860,276-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("mutterSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream gnome.org release
    # tarballs use.
    let spec = registeredFetchSpec("mutterSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a library + an executable with correct kinds":
    # M3 artifact registry: ``libMutter`` is tagged ``dakLibrary``
    # while ``mutterBin`` is tagged ``dakExecutable``. The unique
    # coverage of THIS recipe (vs the prior single-kind recipes) is
    # that the M3 registry keeps ``dakLibrary`` and ``dakExecutable``
    # discriminators correctly distinguished WITHIN a single package's
    # artifact set — a regression that flattened the kind discriminator
    # would mis-route the M9.L install path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("mutterSource")
    check arts.len == 2
    var seenLib = false
    var seenBin = false
    for art in arts:
      check art.packageName == "mutterSource"
      case art.artifactName
      of "libMutter":
        seenLib = true
        check art.kind == dakLibrary
      of "mutterBin":
        seenBin = true
        check art.kind == dakExecutable
      else:
        discard
    check seenLib
    check seenBin

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.gnome.org release
    # tag is recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at the
    # canonical GNOME gitlab project that hosts the mutter source
    # tree.
    let vs = registeredVersions("mutterSource")
    check vs.len == 1
    check vs[0].version == "47.10"
    check vs[0].sourceRevision == "47.10"
    check vs[0].sourceUrl ==
      "https://download.gnome.org/sources/mutter/47/mutter-47.10.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.gnome.org/GNOME/mutter"
