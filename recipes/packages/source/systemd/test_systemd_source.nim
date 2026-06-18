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

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + four executable + two library
# artifacts under ``systemdSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/systemd/vendor/systemd-257.tar.gz"

const ExpectedHash =
  "14f6907eb5e289d8c39cbe1ef891ca54d8a0e3582c986a9ef5844b3f29add43b"

const ExpectedMesonOptions = @[
  "-Dmode=release",
  "-Dtests=false",
  "-Dman=disabled",
  "-Dtranslations=false",
  "-Dxdg-autostart=false",
  "-Dnetworkd=false",
  "-Dresolve=false",
  "-Dtimesyncd=false",
  "-Dhomed=false",
  "-Duserdb=false",
  "-Dimportd=false",
  "-Dportabled=false",
  "-Dpolkit=false",
  "--buildtype=release",
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
    # M9.I exact-order round-trip — meson evaluates options
    # left-to-right and a regression that reorders this seq would
    # silently change build behaviour (mode, tests, man, translations,
    # xdg-autostart, networkd, resolve, timesyncd, homed, userdb,
    # importd, portabled, polkit, release/debug). systemd's flag set
    # is the largest in the corpus (fourteen elements).
    let flags = registeredBuildFlags("systemdSource", "", "meson")
    check flags == ExpectedMesonOptions
    check flags.len == 14

  test "mesonOptions does not leak into the cmake channel":
    # Cross-channel isolation under the six-artifact mixed-kind shape
    # — guards against a regression that simultaneously collapsed the
    # artifact-name partitioning at six-artifact cardinality AND the
    # per-channel build-flag partitioning.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("systemdSource", "", "cmake") == emptyStrSeq

  test "mesonOptions does not leak into the configure channel":
    # Cross-channel isolation #2 — guards against a regression that
    # merges the meson + autotools channels.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("systemdSource", "", "configure") == emptyStrSeq

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
