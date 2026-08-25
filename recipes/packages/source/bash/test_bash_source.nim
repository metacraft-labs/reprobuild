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
##   * Executable artifact registration (M3) — ``bash`` and its
##     ``sh`` alias, both tagged ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + one executable artifact under
# ``bashSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz"

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
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("bashSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("bashSource") == @["autotools_package"]
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("bashSource")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("bashSource")
  test "configureFlags does not leak into the make channel":
    # The retired registry kept a separate ``make`` flag channel.
    # Its post-M9.R.6.1 equivalent is the ``makeVars`` /
    # ``installMakeVars`` arguments of the Layer-1 constructors:
    # flags reaching the make step would be passed there. This
    # recipe passes neither, so nothing leaks into that channel.
    check not buildBlockPassesArgument("bashSource", "makeVars")
    check not buildBlockPassesArgument("bashSource", "installMakeVars")
  test "artifacts register the bash interpreter plus its sh alias":
    # M3 artifact registry: bash's autotools build emits one load-
    # bearing binary (the shell interpreter) and the recipe's
    # ``install-sh-alias`` patch additionally plants ``$(bindir)/sh``
    # as a link to it, so the POSIX ``sh`` tool name is provisionable
    # for Ninja / Make command runners that spawn ``/bin/sh -c``.
    # Both are tagged ``dakExecutable``; the auxiliary ``bashbug``
    # helper + loadable builtins are NOT registered in v1. A
    # regression that flattened the kind discriminator would mis-route
    # the M9.L install path; a regression that collapsed the
    # artifact-name partitioning would not produce two distinctly
    # named entries in declaration order.
    let arts = registeredArtifacts("bashSource")
    check arts.len == 2
    check arts[0].packageName == "bashSource"
    check arts[0].artifactName == "bash"
    check arts[0].kind == dakExecutable
    check arts[1].packageName == "bashSource"
    check arts[1].artifactName == "sh"
    check arts[1].kind == dakExecutable

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
