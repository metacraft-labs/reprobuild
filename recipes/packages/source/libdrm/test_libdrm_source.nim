## Smoke test for the from-source ``libdrmSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SECOND real production
## from-source recipe (the first was ``dbusBrokerSource``). Where the
## dbus-broker test exercised executable artifacts, this one exercises
## the M3 ``library`` artifact family — both kinds plug into the same
## artifact registry but the kind discriminator differs (dakLibrary vs
## dakExecutable), so a regression that flattened the kind discriminator
## would surface differently here than in the dbus-broker smoke test.
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (the ``cmake`` channel must NOT see the meson flags).
##   * ``library`` artifact registration (M3) — three libraries, all
##     tagged ``dakLibrary``, all attributed to ``libdrmSource``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library artifacts under
# ``libdrmSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/libdrm/vendor/libdrm-2.4.133.tar.xz"

const ExpectedHash =
  "fc68f9d0ba2ea63c9432a299e14fea09fad7a8a66e8039fcd7802ca59f77b4f5"

const ExpectedMesonOptions = @[
  "-Dintel=disabled",
  "-Dradeon=disabled",
  "-Damdgpu=enabled",
  "-Dnouveau=enabled",
  "-Dvmwgfx=disabled",
  "-Dfreedreno=disabled",
  "-Dvc4=disabled",
  "-Detnaviv=disabled",
  "-Dtegra=disabled",
  "-Dvalgrind=disabled",
  "-Dman-pages=disabled",
  "--buildtype=release",
]

suite "libdrmSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("libdrmSource")
    check spec.packageName == "libdrmSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 436,912-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("libdrmSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream uses for
    # freedesktop.org tag tarballs.
    let spec = registeredFetchSpec("libdrmSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    # M9.I exact-order round-trip — meson evaluates options
    # left-to-right and a regression that reorders this seq would
    # silently change build behaviour (which per-vendor side libraries
    # get built, release/debug, valgrind on/off).
    let flags = registeredBuildFlags("libdrmSource", "", "meson")
    check flags == ExpectedMesonOptions
    check flags.len == 12

  test "mesonOptions does not leak into the cmake channel":
    # Channel-isolation spot-check — a regression that flattens the
    # per-channel registries would surface here.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("libdrmSource", "", "cmake") == emptyStrSeq

  test "library artifacts register all three shared objects":
    # M3 artifact registry: ``libdrm``, ``libdrmAmdgpu``, and
    # ``libdrmNouveau`` must all be present so the convention layer's
    # install/output collection knows which shared objects to harvest.
    # Critically, the kind discriminator must be ``dakLibrary`` (not
    # ``dakExecutable``) — that distinction drives the M9.L install
    # path (``lib/`` rather than ``bin/``) and the per-artifact
    # downstream linkage propagation.
    let arts = registeredArtifacts("libdrmSource")
    check arts.len == 3
    var seenCore = false
    var seenAmdgpu = false
    var seenNouveau = false
    for art in arts:
      check art.packageName == "libdrmSource"
      check art.kind == dakLibrary
      case art.artifactName
      of "libdrm":
        seenCore = true
      of "libdrmAmdgpu":
        seenAmdgpu = true
      of "libdrmNouveau":
        seenNouveau = true
      else:
        discard
    check seenCore
    check seenAmdgpu
    check seenNouveau

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream freedesktop.org tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # gitlab mirror that hosts the Mesa ``drm`` source tree.
    let vs = registeredVersions("libdrmSource")
    check vs.len == 1
    check vs[0].version == "2.4.133"
    check vs[0].sourceRevision == "libdrm-2.4.133"
    check vs[0].sourceUrl ==
      "https://dri.freedesktop.org/libdrm/libdrm-2.4.133.tar.xz"
    check vs[0].sourceRepository == "https://gitlab.freedesktop.org/mesa/drm"
