## Smoke test for the from-source ``gnomeShellSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the EIGHTEENTH real production
## from-source recipe and the CLOSING recipe in the GNOME stack batch.
## gnome-shell's unique coverage angle vs the prior seventeen is that
## it's the FIRST recipe to combine BOTH a multi-word-kebab package
## name (``gnome-shell`` -> ``gnomeShellSource``) AND a mixed-kind
## artifact set (library + executable in the same ``package`` macro):
## the M3 registry's name-mangling + per-package artifact partitioning
## are exercised at the same time. A regression that fumbled the
## multi-word kebab-to-camel translation OR collapsed the kind
## discriminator would surface here.
##
## Coverage (12 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (cmake + configure channels MUST be empty).
##   * Library + executable artifact registration (M3) — ``libGnomeShell``
##     tagged ``dakLibrary`` and ``gnomeShell`` tagged ``dakExecutable``
##     within the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library + executable artifacts under
# ``gnomeShellSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/gnome-shell/vendor/gnome-shell-47.10.tar.xz"

const ExpectedHash =
  "5174d25bb05d35f3612498efc33a1de533fc4e0f39e3eb377fd09591c94a10e6"

const ExpectedMesonOptions = @[
  "-Dgtk_doc=false",
  "-Dtests=false",
  "-Dman=false",
  "-Dnetworkmanager=false",
  "-Dsystemd=false",
  "-Dextensions_app=false",
  "-Dextensions_tool=false",
  "--buildtype=release",
]

suite "gnomeShellSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("gnomeShellSource")
    check spec.packageName == "gnomeShellSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 2,144,616-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("gnomeShellSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream gnome.org release
    # tarballs use.
    let spec = registeredFetchSpec("gnomeShellSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    # M9.I exact-order round-trip — meson evaluates options
    # left-to-right and a regression that reorders this seq would
    # silently change build behaviour (gtk_doc on/off, tests on/off,
    # man on/off, networkmanager on/off, systemd on/off,
    # extensions_app on/off, extensions_tool on/off, release/debug).
    let flags = registeredBuildFlags("gnomeShellSource", "", "meson")
    check flags == ExpectedMesonOptions
    check flags.len == 8

  test "mesonOptions does not leak into the cmake channel":
    # Cross-channel isolation — guards against a regression that
    # flattens the per-channel registries.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("gnomeShellSource", "", "cmake") == emptyStrSeq

  test "mesonOptions does not leak into the configure channel":
    # Cross-channel isolation #2 — guards against a regression that
    # merges the meson + autotools channels (both can carry
    # ``--`` prefixed options at a glance but the convention layer
    # treats them as disjoint inputs to ``meson setup`` vs
    # ``./configure``).
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("gnomeShellSource", "", "configure") == emptyStrSeq

  test "artifacts register an executable + a library with correct kinds":
    # M3 artifact registry: ``gnomeShell`` is tagged ``dakExecutable``
    # while ``libGnomeShell`` is tagged ``dakLibrary``. The unique
    # coverage of THIS recipe is that it combines BOTH the multi-
    # word-kebab package-name mangling (``gnome-shell`` ->
    # ``gnomeShellSource``) AND a mixed-kind artifact set in the same
    # package. A regression that flattened the kind discriminator
    # would mis-route the M9.L install path (``lib/`` vs ``bin/``);
    # a regression that fumbled the kebab-to-camel translation would
    # produce ``gnome_shell`` / ``gnomeshell`` / ``GnomeShell``
    # variants none of which match the assertions below.
    let arts = registeredArtifacts("gnomeShellSource")
    check arts.len == 2
    var seenBin = false
    var seenLib = false
    for art in arts:
      check art.packageName == "gnomeShellSource"
      case art.artifactName
      of "gnomeShell":
        seenBin = true
        check art.kind == dakExecutable
      of "libGnomeShell":
        seenLib = true
        check art.kind == dakLibrary
      else:
        discard
    check seenBin
    check seenLib

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.gnome.org release
    # tag is recorded for ``repro update-source`` even though the
    # live fetch points at the vendored copy. The repository points
    # at the canonical GNOME gitlab project that hosts the
    # gnome-shell source tree.
    let vs = registeredVersions("gnomeShellSource")
    check vs.len == 1
    check vs[0].version == "47.10"
    check vs[0].sourceRevision == "47.10"
    check vs[0].sourceUrl ==
      "https://download.gnome.org/sources/gnome-shell/47/gnome-shell-47.10.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.gnome.org/GNOME/gnome-shell"
