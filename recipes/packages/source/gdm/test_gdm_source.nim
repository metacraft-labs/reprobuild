## Smoke test for the from-source ``gdmSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SEVENTEENTH real production
## from-source recipe and the SECOND recipe in the GNOME stack batch.
## gdm's unique coverage angle is that it ships TWO executable
## artifacts from one ``package`` macro.
##
## CHANNEL CHANGE (recorded here because the gutted assertions hid it):
## this recipe was autotools when the test was written and its flag
## expectations were named ``ExpectedConfigureFlags``. It is now driven
## by ``meson_package(...)`` with an entirely different option set. The
## test's ``check true`` placeholders meant the switch never had to
## update a single expectation, so the change went unrecorded until the
## assertions were re-armed. The channel-isolation pins below now check
## the CONFIGURE and CMAKE channels stay empty, not the meson one.
##
## Coverage (12 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * meson option round-trip — exact-order sequence equality on the
##     production option set as declared in the recipe's ``build:``
##     block + channel-isolation spot-check (configure + cmake channels
##     MUST be empty).
##   * TWO executable artifact registration (M3) — ``gdm`` +
##     ``gdmGreeterSession`` both tagged ``dakExecutable`` under the
##     same package.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + executable artifacts under
# ``gdmSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://download.gnome.org/sources/gdm/47/gdm-47.0.tar.xz"

const ExpectedHash =
  "c5858326bfbcc8ace581352e2be44622dc0e9e5c2801c8690fd2eed502607f84"

const ExpectedMesonOptions = @[
  "plymouth=disabled",
  "selinux=disabled",
  "systemd-journal=false",
  "default-pam-config=none",
  "wayland-support=true",
  "x11-support=false",
  "user-display-server=true",
  "gdm-xsession=true",
  "run-dir=/run/gdm",
  "profiling=false",
  "libaudit=disabled",
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

  test "mesonOptions registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``meson_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("gdmSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedMesonOptions
    check buildBlockConstructors("gdmSource") == @["meson_package"]
  test "mesonOptions does not leak into the configure channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the configure channel would
    # surface as a ``autotools_package(...)`` call here.
    check "autotools_package" notin buildBlockConstructors("gdmSource")
  test "mesonOptions does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("gdmSource")
  test "artifacts register two executables under the same package":
    # M3 artifact registry: both ``gdm`` and ``gdmSessionWorker``
    # must be present and tagged ``dakExecutable``. gdm 47.x's meson
    # build emits two binaries: the daemon (``gdm``) and the
    # PAM-authenticated session worker
    # (``/usr/libexec/gdm-session-worker``). M9.R.16.5: the legacy
    # ``gdm-greeter-session`` binary no longer exists in gdm 47.x (the
    # greeter is now gnome-shell run in ``--gdm-mode``); the
    # session-worker is the load-bearing libexec binary for the v1
    # login path. A regression that lost either binary would mis-route
    # the M9.L install path (the corresponding binary would never get
    # harvested into the package output); a regression that mis-tagged
    # the kind would route the binary to ``lib/`` instead of ``bin/`` /
    # ``libexec/``.
    let arts = registeredArtifacts("gdmSource")
    check arts.len == 2
    var seenGdm = false
    var seenWorker = false
    for art in arts:
      check art.packageName == "gdmSource"
      check art.kind == dakExecutable
      case art.artifactName
      of "gdm":
        seenGdm = true
      of "gdmSessionWorker":
        seenWorker = true
      else:
        discard
    check seenGdm
    check seenWorker

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
