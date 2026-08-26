## Smoke test for the from-source ``networkManagerSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SEVENTIETH real production
## from-source recipe. NetworkManager is THE canonical network
## configuration daemon on modern Linux desktops: every NDE-K1 v1
## desktop (sway / GNOME / Plasma) consumes its D-Bus API for Wi-Fi
## connection management, Ethernet hot-plug response, VPN routing,
## and the per-application network-status indicators.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * meson option round-trip — exact-order sequence equality on the
##     production option set as declared in the recipe's ``build:``
##     block + channel-isolation spot-check (configure + cmake + make
##     channels MUST be empty).
##
##     CHANNEL CHANGE (recorded here because the gutted assertions hid
##     it): this recipe was autotools with a six-flag
##     ``configureFlags:`` set when the test was written. It is now
##     driven by ``meson_package(...)`` with 27 meson options. The
##     test's ``check true`` placeholders meant the switch never had to
##     update an expectation, so it went unrecorded until the
##     assertions were re-armed.
##   * MIXED artifact registration (M3) — two executables
##     (``dakExecutable``) + one library (``dakLibrary``) attributed
##     to ``networkManagerSource`` with kind discriminators preserved
##     per-artifact.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + two executables + one library
# artifact under ``networkManagerSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/releases/1.56.0/downloads/NetworkManager-1.56.0.tar.xz"

const ExpectedHash =
  "59a32d385cc1e7ae26e43798c6f12d07ff6198abd041ec0620b3a08cfc021ccc"

const ExpectedMesonOptions = @[
  "default_library=shared",
  "tests=no",
  "introspection=false",
  "vapi=false",
  "docs=false",
  "man=false",
  "systemd_journal=false",
  "config_logging_backend_default=syslog",
  "session_tracking=systemd",
  "suspend_resume=systemd",
  "polkit=true",
  "modify_system=true",
  "selinux=false",
  "libaudit=no",
  "crypto=gnutls",
  "concheck=false",
  "libpsl=false",
  "ppp=false",
  "modem_manager=false",
  "ovs=false",
  "nmtui=false",
  "nm_cloud_setup=false",
  "firewalld_zone=false",
  "ifupdown=false",
  "nbft=false",
  "qt=false",
  "readline=libreadline",
]

suite "networkManagerSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("networkManagerSource")
    check spec.packageName == "networkManagerSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 cross-checked against nixpkgs's SRI-form hash on the
    # same upstream tarball; length check guards against a future
    # bump that forgets to widen the hash alongside the URL.
    let spec = registeredFetchSpec("networkManagerSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream release tarballs use.
    let spec = registeredFetchSpec("networkManagerSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``meson_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("networkManagerSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedMesonOptions
    check buildBlockConstructors("networkManagerSource") == @["meson_package"]
  test "mesonOptions does not leak into the configure channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the configure channel would
    # surface as a ``autotools_package(...)`` call here.
    check "autotools_package" notin buildBlockConstructors("networkManagerSource")
  test "mesonOptions does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("networkManagerSource")
  test "mesonOptions does not leak into the make channel":
    # The retired registry kept a separate ``make`` flag channel.
    # Its post-M9.R.6.1 equivalent is the ``makeVars`` /
    # ``installMakeVars`` arguments of the Layer-1 constructors:
    # flags reaching the make step would be passed there. This
    # recipe passes neither, so nothing leaks into that channel.
    check not buildBlockPassesArgument("networkManagerSource", "makeVars")
    check not buildBlockPassesArgument("networkManagerSource", "installMakeVars")
  test "artifacts register two executables + one library mixed-kind":
    # M3 artifact registry: ``nmDaemon`` + ``nmcli`` are tagged
    # ``dakExecutable`` while ``libNm`` is tagged ``dakLibrary``.
    # The MIXED autotools shape where a single ``./configure`` +
    # ``make`` emits two binaries AND a shared library — a regression
    # that flattened the kind discriminator at the autotools
    # convention layer would mis-route the M9.L install path
    # (``lib/`` vs ``bin/``) for one of the three.
    let arts = registeredArtifacts("networkManagerSource")
    check arts.len == 3
    var seenDaemon = false
    var seenNmcli = false
    var seenLib = false
    for art in arts:
      check art.packageName == "networkManagerSource"
      case art.artifactName
      of "nmDaemon":
        seenDaemon = true
        check art.kind == dakExecutable
      of "nmcli":
        seenNmcli = true
        check art.kind == dakExecutable
      of "libNm":
        seenLib = true
        check art.kind == dakLibrary
      else:
        discard
    check seenDaemon
    check seenNmcli
    check seenLib

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream gitlab.freedesktop.org
    # release tag is recorded for ``repro update-source``. The
    # repository points at the canonical gitlab project that hosts
    # the NetworkManager source tree (the project moved from
    # download.gnome.org to gitlab.freedesktop.org after the 2022
    # freedesktop migration).
    let vs = registeredVersions("networkManagerSource")
    check vs.len == 1
    check vs[0].version == "1.56.0"
    check vs[0].sourceRevision == "1.56.0"
    check vs[0].sourceUrl ==
      "https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/releases/1.56.0/downloads/NetworkManager-1.56.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.freedesktop.org/NetworkManager/NetworkManager"
