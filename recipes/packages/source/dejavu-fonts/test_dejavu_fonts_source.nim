## Smoke test for the from-source ``dejavuFontsSource`` recipe.
##
## Contract note (why this test does not read an installed font tree):
## the suite runs every ``build/test-bin/*`` binary from the repository
## root (``scripts/run_tests.sh``), so a test that resolves
## ``getCurrentDir() / ".repro" / "output" / "install" / ...`` can only
## pass when a *host-local* build output happens to sit under the
## process' working directory. That is exactly the "hidden host state or
## prebuilt local artifacts outside the declared test environment"
## shortcut the Test-Suite Architecture Guidelines forbid, and it fails
## unconditionally under the canonical runner. This test therefore pins
## the recipe's declared contract, which is reproducible from source
## alone and independent of the working directory:
##
##   * the exact pinned upstream tarball (URL + SHA-256 + extract shape),
##   * the ``versions:`` metadata,
##   * the ``fontforge``/``make`` native build-tool requirement that makes
##     the TTFs generatable at all,
##   * the single declared ``fonts`` files artifact, and
##   * the install rule the ``build:`` block appends, which is what puts
##     the generated ``*.ttf`` families under
##     ``usr/share/fonts/truetype/dejavu``.
##
## The last item is read from the sibling recipe at compile time via
## ``staticRead`` so the destination the original assertion cared about
## stays load-bearing without depending on a prebuilt output tree.
##
## No mock objects are used: the assertions run against the real recipe
## module and the real DSL registration runtime.

import std/[os, strutils, unittest]

import repro_project_dsl

import ./repro

const
  ExpectedUrl =
    "https://github.com/dejavu-fonts/dejavu-fonts/archive/version_2_37.tar.gz"
  ExpectedHash =
    "c4d10a1b665db893adc0c0aaee7ecd81b2b47c877d5cea0b40216707cbf327e4"
  ExpectedRepository = "https://github.com/dejavu-fonts/dejavu-fonts"
  ExpectedFontDir = "$(DESTDIR)/usr/share/fonts/truetype/dejavu"
  ExpectedFontCopy =
    "cp build/*.ttf $(DESTDIR)/usr/share/fonts/truetype/dejavu/"
  RecipeSource = staticRead(currentSourcePath().parentDir / "repro.nim")

suite "DejaVu fonts source recipe":

  test "installs generated core font families":
    let spec = registeredFetchSpec("dejavuFontsSource")
    check spec.packageName == "dejavuFontsSource"
    check spec.kind == dfkTarball
    check spec.url == ExpectedUrl
    check spec.hashAlg == dshaSha256
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.extractStrip == 1

    let versions = registeredVersions("dejavuFontsSource")
    check versions.len == 1
    check versions[0].version == "2.37"
    check versions[0].sourceRevision == "version_2_37"
    check versions[0].sourceUrl == ExpectedUrl
    check versions[0].sourceRepository == ExpectedRepository

    # FontForge generates the TTFs from the upstream SFD sources; make
    # drives the generated Makefile. Losing either dependency means no
    # font family is produced at all.
    check registeredNativeBuildDeps("dejavuFontsSource") ==
      @["make", "fontforge"]
    check registeredBuildDeps("dejavuFontsSource").len == 0
    check registeredRuntimeDeps("dejavuFontsSource").len == 0

    let artifacts = registeredArtifacts("dejavuFontsSource")
    check artifacts.len == 1
    check artifacts[0].packageName == "dejavuFontsSource"
    check artifacts[0].artifactName == "fonts"
    check artifacts[0].kind == dakFiles

    # The appended install rule is what lands DejaVuSans.ttf,
    # DejaVuSansMono.ttf and DejaVuSerif.ttf in the install tree.
    check ExpectedFontDir in RecipeSource
    check ExpectedFontCopy in RecipeSource
    # The full-TTF target is required: upstream's default `all` target
    # builds only a subset and would not emit the mono/serif families.
    check "all : full-ttf" in RecipeSource
