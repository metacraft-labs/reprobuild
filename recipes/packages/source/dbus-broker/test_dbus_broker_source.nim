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

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + executable artifacts under
# ``dbusBrokerSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://github.com/bus1/dbus-broker/releases/download/v36/dbus-broker-36.tar.xz"

const ExpectedHash =
  "d333d99bd2688135b6d6961e7ad1360099d186078781c87102230910ea4e162b"

const ExpectedMesonOptions = @[
  "audit=false",
  "launcher=true",
  "linux-4-17=true",
  "reference-test=false",
  "selinux=false",
  "apparmor=false",
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
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``meson_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("dbusBrokerSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedMesonOptions
    check buildBlockConstructors("dbusBrokerSource") == @["meson_package"]
  test "mesonOptions does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("dbusBrokerSource")
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

  test "declares the linked library closure":
    check registeredBuildDeps("dbusBrokerSource") ==
      @["expat", "systemd >=240"]
    check registeredRuntimeDeps("dbusBrokerSource") ==
      @["expat", "systemd >=240"]

  test "versions block records the upstream tag + URL":
    # M2 versions registry: the upstream GitHub tag is recorded for
    # ``repro update-source`` even though the live fetch points at the
    # vendored copy.
    let vs = registeredVersions("dbusBrokerSource")
    check vs.len == 1
    check vs[0].version == "36"
    check vs[0].sourceRevision == "refs/tags/v36"
    check vs[0].sourceUrl ==
      "https://github.com/bus1/dbus-broker/releases/download/v36/dbus-broker-36.tar.xz"
    check vs[0].sourceRepository == "https://github.com/bus1/dbus-broker"
