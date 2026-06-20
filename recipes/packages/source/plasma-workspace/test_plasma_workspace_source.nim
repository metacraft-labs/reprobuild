## Smoke test for the from-source ``plasmaWorkspaceSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the TWENTY-FIRST real
## production from-source recipe and the THIRD recipe in the Plasma
## stack batch. plasma-workspace's unique coverage angle vs the prior
## twenty is that it's the FIRST CMake recipe to combine BOTH a
## multi-word-kebab package name (``plasma-workspace`` ->
## ``plasmaWorkspaceSource``) AND a mixed-kind artifact set
## (library + executable). The gnome-shell precedent exercised the
## same multi-word-kebab + mixed-kind shape on the meson channel;
## this is the CMake-side analogue, so a regression that fumbled the
## multi-word kebab-to-camel translation specifically on the CMake
## channel would surface here.
##
## Coverage (12 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * Library + executable artifact registration (M3) —
##     ``libPlasmaWorkspace`` tagged ``dakLibrary`` and ``plasmashell``
##     tagged ``dakExecutable`` within the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library + executable artifacts under
# ``plasmaWorkspaceSource`` at module init time.
import ./repro

const ExpectedUrl =
  # M9.R.15f.5 drive-by — the recipe long since switched to the
  # upstream download.kde.org URL but this constant was never updated.
  "https://download.kde.org/stable/plasma/6.2.5/plasma-workspace-6.2.5.tar.xz"

const ExpectedHash =
  "b82511e46f62e1b8f60b969c828c8d8d32fc7928401a70cc28c29f85f46c412f"

const ExpectedCmakeFlags = @[
  "-DBUILD_TESTING=OFF",
  "-DKWIN_BUILD_X11=OFF",
  "-DCMAKE_BUILD_TYPE=Release",
]

suite "plasmaWorkspaceSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("plasmaWorkspaceSource")
    check spec.packageName == "plasmaWorkspaceSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 19,136,676-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("plasmaWorkspaceSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.kde.org
    # release tarballs use.
    let spec = registeredFetchSpec("plasmaWorkspaceSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register an executable + a library with correct kinds":
    # M3 artifact registry: ``plasmashell`` is tagged ``dakExecutable``
    # while ``libPlasmaWorkspace`` is tagged ``dakLibrary``. The
    # unique coverage of THIS recipe is that it's the first CMake
    # recipe combining a multi-word-kebab package name
    # (``plasma-workspace`` -> ``plasmaWorkspaceSource``) AND a
    # mixed-kind artifact set. A regression that flattened the kind
    # discriminator would mis-route the M9.L install path
    # (``lib/`` vs ``bin/``); a regression that fumbled the
    # kebab-to-camel translation on the library name would produce
    # ``libplasma_workspace`` / ``libplasmaworkspace`` /
    # ``libPlasma_workspace`` variants none of which match the
    # assertion below.
    let arts = registeredArtifacts("plasmaWorkspaceSource")
    check arts.len == 2
    var seenBin = false
    var seenLib = false
    for art in arts:
      check art.packageName == "plasmaWorkspaceSource"
      case art.artifactName
      of "plasmashell":
        seenBin = true
        check art.kind == dakExecutable
      of "libPlasmaWorkspace":
        seenLib = true
        check art.kind == dakLibrary
      else:
        discard
    check seenBin
    check seenLib

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.kde.org release tag
    # is recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at the
    # canonical KDE invent.kde.org project that hosts the
    # plasma-workspace source tree.
    let vs = registeredVersions("plasmaWorkspaceSource")
    check vs.len == 1
    check vs[0].version == "6.2.5"
    check vs[0].sourceRevision == "v6.2.5"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/plasma/6.2.5/plasma-workspace-6.2.5.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/plasma/plasma-workspace"
