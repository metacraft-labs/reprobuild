## Smoke test for the from-source ``systemdSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the THIRTY-FIRST real
## production from-source recipe. systemd's unique coverage angle vs
## the prior thirty is the SIX-ARTIFACT (mixed-kind) single-package
## shape: four executables (``systemdInit`` + ``systemctl`` +
## ``journalctl`` + ``systemdLogind``) PLUS two libraries
## (``libSystemd`` + ``libUdev``) all built from one meson invocation.
## Every prior multi-artifact recipe shipped at most six (qt6-base's
## SIX libs, all of one kind) or three (sddm's two-exec + one-lib
## mixed-kind) — systemd is the FIRST recipe to ship a four-exec +
## two-lib mixed-kind shape from a single ``package`` macro. A
## regression that collapsed the artifact-name partitioning at the
## six-artifact mixed-kind cardinality would surface here, and a
## regression that mis-tagged any of the six individual kind
## discriminants (exec vs lib) would surface too.
##
## Coverage (14 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (cmake + configure channels MUST be empty).
##   * SIX artifact registration (M3) — ``systemdInit`` + ``systemctl``
##     + ``journalctl`` + ``systemdLogind`` tagged ``dakExecutable``,
##     ``libSystemd`` + ``libUdev`` tagged ``dakLibrary``, all in the
##     same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + four executable + two library
# artifacts under ``systemdSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://github.com/systemd/systemd/archive/refs/tags/v257.tar.gz"

const ExpectedHash =
  "14f6907eb5e289d8c39cbe1ef891ca54d8a0e3582c986a9ef5844b3f29add43b"

const ExpectedMesonOptions = @[
  "mode=release",
  "tests=false",
  "man=disabled",
  "translations=false",
  "xdg-autostart=false",
  "networkd=false",
  "resolve=false",
  "timesyncd=false",
  "homed=false",
  "userdb=false",
  "importd=false",
  "portabled=false",
  "polkit=false",
  "pam=true",
  "mount-path=/usr/bin/mount",
  "umount-path=/usr/bin/umount",
  "kmod-path=/usr/bin/kmod",
  "kexec-path=/usr/sbin/kexec",
  "sulogin-path=/usr/sbin/sulogin",
  "loadkeys-path=/usr/bin/loadkeys",
  "setfont-path=/usr/bin/setfont",
  "nologin-path=/usr/sbin/nologin",
  "quotaon-path=/usr/sbin/quotaon",
  "quotacheck-path=/usr/sbin/quotacheck",
]

suite "systemdSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("systemdSource")
    check spec.packageName == "systemdSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 16,184,128-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("systemdSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub release
    # tarballs use.
    let spec = registeredFetchSpec("systemdSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``meson_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("systemdSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedMesonOptions
    check buildBlockConstructors("systemdSource") == @["meson_package"]
  test "mesonOptions does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("systemdSource")
  test "mesonOptions does not leak into the configure channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the configure channel would
    # surface as a ``autotools_package(...)`` call here.
    check "autotools_package" notin buildBlockConstructors("systemdSource")
  test "artifacts register four executables + two libraries with correct kinds":
    # M3 artifact registry: ``systemdInit`` + ``systemctl`` +
    # ``journalctl`` + ``systemdLogind`` are tagged ``dakExecutable``
    # while ``libSystemd`` + ``libUdev`` are tagged ``dakLibrary``.
    # The unique coverage of THIS recipe is that it's the first recipe
    # to ship SIX artifacts of MIXED kinds from a single package. A
    # regression that flattened the kind discriminator would mis-route
    # the M9.L install path (``lib/`` vs ``bin/``); a regression that
    # collapsed the artifact-name partitioning at the six-artifact
    # cardinality would not produce six distinct entries with the
    # expected names below.
    let arts = registeredArtifacts("systemdSource")
    check arts.len == 6
    var seenInit = false
    var seenSystemctl = false
    var seenJournalctl = false
    var seenLogind = false
    var seenLibSystemd = false
    var seenLibUdev = false
    for art in arts:
      check art.packageName == "systemdSource"
      case art.artifactName
      of "systemdInit":
        seenInit = true
        check art.kind == dakExecutable
      of "systemctl":
        seenSystemctl = true
        check art.kind == dakExecutable
      of "journalctl":
        seenJournalctl = true
        check art.kind == dakExecutable
      of "systemdLogind":
        seenLogind = true
        check art.kind == dakExecutable
      of "libSystemd":
        seenLibSystemd = true
        check art.kind == dakLibrary
      of "libUdev":
        seenLibUdev = true
        check art.kind == dakLibrary
      else:
        discard
    check seenInit
    check seenSystemctl
    check seenJournalctl
    check seenLogind
    check seenLibSystemd
    check seenLibUdev

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is
    # recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at
    # the canonical GitHub project that hosts the systemd source
    # tree.
    let vs = registeredVersions("systemdSource")
    check vs.len == 1
    check vs[0].version == "257"
    check vs[0].sourceRevision == "v257"
    check vs[0].sourceUrl ==
      "https://github.com/systemd/systemd/archive/refs/tags/v257.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/systemd/systemd"
