## Smoke test for the from-source ``bashSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FIFTY-NINTH real
## production from-source recipe. bash's unique coverage angle vs the
## prior fifty-eight is being THE canonical POSIX shell — ``/bin/bash``
## is the login shell on every major Linux distribution, the shebang
## target for every ``#!/bin/bash`` script, and the implicit
## interpreter every Makefile recipe + every systemd-unit
## ``ExecStart=`` with shell metacharacters is evaluated under.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production five-flag set + channel-
##     isolation spot-check (meson + cmake + make channels MUST be
##     empty).
##   * SINGLE executable artifact registration (M3) — ``bash`` tagged
##     ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + one executable artifact under
# ``bashSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/bash/vendor/bash-5.2.37.tar.gz"

const ExpectedHash =
  "9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--without-bash-malloc",
  "--enable-readline",
  "--enable-history",
  "--enable-job-control",
]

suite "bashSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("bashSource")
    check spec.packageName == "bashSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 11,128,314-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("bashSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream ftp.gnu.org release
    # tarballs use.
    let spec = registeredFetchSpec("bashSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip on the configure channel — the
    # autotools ``./configure`` script evaluates options left-to-right
    # and a regression that reorders this seq would silently change
    # build behaviour (static on/off, malloc choice, readline /
    # history / job-control feature toggles). The middle flag
    # (``--without-bash-malloc``) pins the ``--without-`` grammar variant
    # alongside the ``--disable-`` + ``--enable-`` neighbours.
    let flags = registeredBuildFlags("bashSource", "", "configure")
    check flags == ExpectedConfigureFlags
    check flags.len == 5

  test "configureFlags does not leak into the meson channel":
    # Cross-channel isolation — guards against a regression that
    # flattens the registries.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("bashSource", "", "meson") == emptyStrSeq

  test "configureFlags does not leak into the cmake channel":
    # Cross-channel isolation #2 — guards against a regression that
    # merges the autotools + CMake channels.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("bashSource", "", "cmake") == emptyStrSeq

  test "configureFlags does not leak into the make channel":
    # Cross-channel isolation #3 — guards against a regression that
    # merges autotools ``configure`` flags onto the raw-Makefile
    # ``make`` channel (libcap-shape would mis-pick these flags).
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("bashSource", "", "make") == emptyStrSeq

  test "artifacts register a single bash executable tagged dakExecutable":
    # M3 artifact registry: ``bash`` is tagged ``dakExecutable``. bash's
    # autotools build emits a single load-bearing binary (the shell
    # interpreter); auxiliary ``bashbug`` helper + loadable builtins
    # are NOT registered in v1. A regression that flattened the kind
    # discriminator would mis-route the M9.L install path; a
    # regression that collapsed the artifact-name partitioning at the
    # one-artifact cardinality would not produce a single entry with
    # the expected name.
    let arts = registeredArtifacts("bashSource")
    check arts.len == 1
    check arts[0].packageName == "bashSource"
    check arts[0].artifactName == "bash"
    check arts[0].kind == dakExecutable

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical savannah.gnu.org mirror that hosts the bash source
    # tree.
    let vs = registeredVersions("bashSource")
    check vs.len == 1
    check vs[0].version == "5.2.37"
    check vs[0].sourceRevision == "bash-5.2.37"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz"
    check vs[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/bash.git"
