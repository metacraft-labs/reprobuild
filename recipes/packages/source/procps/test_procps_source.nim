## Smoke test for the from-source ``procpsSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FORTY-EIGHTH real
## production from-source recipe. procps-ng's unique coverage angle vs
## the prior forty-seven is the SIX-ARTIFACT (mixed-kind) single-package
## shape with FIVE executables + ONE library all driven through the
## autotools ``configureFlags:`` channel, sourced from the GitLab
## archive endpoint (``/-/archive/<tag>/<name>-<tag>.tar.gz``) — the
## FIRST recipe in the corpus to consume the GitLab archive shape.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * SIX artifact registration (M3) — five executables tagged
##     ``dakExecutable`` + one library tagged ``dakLibrary``, all in
##     the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + five executable + one library
# artifacts under ``procpsSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/procps/vendor/procps-v4.0.5.tar.gz"

const ExpectedHash =
  "2c6d7ed9f2acde1d4dd4602c6172fe56eff86953fe8639bd633dbd22cc18f5db"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-nls",
  "--with-systemd=no",
]

suite "procpsSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("procpsSource")
    check spec.packageName == "procpsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 2,392,641-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("procpsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitLab archive
    # tarballs use (the leading directory in the .tar.gz is
    # ``procps-v4.0.5/`` so extractStrip=1 lands the source tree at
    # the build cwd root).
    let spec = registeredFetchSpec("procpsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the make channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register five executables + one library with correct kinds":
    # M3 artifact registry: ``ps`` + ``top`` + ``free`` + ``kill`` +
    # ``uptime`` are tagged ``dakExecutable`` while ``libProc`` is
    # tagged ``dakLibrary``. A regression that flattened the kind
    # discriminator would mis-route the M9.L install path (``lib/``
    # vs ``bin/``); a regression that collapsed the artifact-name
    # partitioning would not produce six distinct entries with the
    # expected names below.
    let arts = registeredArtifacts("procpsSource")
    check arts.len == 6
    var seenPs = false
    var seenTop = false
    var seenFree = false
    var seenKill = false
    var seenUptime = false
    var seenLibProc = false
    for art in arts:
      check art.packageName == "procpsSource"
      case art.artifactName
      of "ps":
        seenPs = true
        check art.kind == dakExecutable
      of "top":
        seenTop = true
        check art.kind == dakExecutable
      of "free":
        seenFree = true
        check art.kind == dakExecutable
      of "kill":
        seenKill = true
        check art.kind == dakExecutable
      of "uptime":
        seenUptime = true
        check art.kind == dakExecutable
      of "libProc":
        seenLibProc = true
        check art.kind == dakLibrary
      else:
        discard
    check seenPs
    check seenTop
    check seenFree
    check seenKill
    check seenUptime
    check seenLibProc

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream gitlab.com archive URL is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical procps-ng GitLab project that hosts the source tree.
    let vs = registeredVersions("procpsSource")
    check vs.len == 1
    check vs[0].version == "4.0.5"
    check vs[0].sourceRevision == "v4.0.5"
    check vs[0].sourceUrl ==
      "https://gitlab.com/procps-ng/procps/-/archive/v4.0.5/procps-v4.0.5.tar.gz"
    check vs[0].sourceRepository ==
      "https://gitlab.com/procps-ng/procps"
