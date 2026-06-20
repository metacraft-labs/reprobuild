## Smoke test for the from-source ``gobjectIntrospectionSource`` recipe
## (M9.R.15b).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.gnome.org/sources/gobject-introspection/1.86/gobject-introspection-1.86.0.tar.xz"

const ExpectedHash =
  "920d1a3fcedeadc32acff95c2e203b319039dd4b4a08dd1a2dfd283d19c0b9ae"

suite "gobjectIntrospectionSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("gobjectIntrospectionSource")
    check spec.packageName == "gobjectIntrospectionSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("gobjectIntrospectionSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("gobjectIntrospectionSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "one library + two executable artifacts registered":
    let arts = registeredArtifacts("gobjectIntrospectionSource")
    check arts.len == 3
    var seenGirepository = false
    var seenScanner = false
    var seenCompiler = false
    for art in arts:
      check art.packageName == "gobjectIntrospectionSource"
      case art.artifactName
      of "libGirepository":
        seenGirepository = true
        check art.kind == dakLibrary
      of "gIrScanner":
        seenScanner = true
        check art.kind == dakExecutable
      of "gIrCompiler":
        seenCompiler = true
        check art.kind == dakExecutable
      else:
        discard
    check seenGirepository
    check seenScanner
    check seenCompiler

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("gobjectIntrospectionSource")
    check vs.len == 1
    check vs[0].version == "1.86.0"
    check vs[0].sourceRevision == "1.86.0"
    check vs[0].sourceUrl == ExpectedUrl
    check vs[0].sourceRepository ==
      "https://gitlab.gnome.org/GNOME/gobject-introspection"
