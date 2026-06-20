## Smoke test for the from-source ``gtk4Source`` recipe (M9.R.15b).

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://download.gnome.org/sources/gtk/4.18/gtk-4.18.5.tar.xz"

const ExpectedHash =
  "bb5267a062f5936947d34c9999390a674b0b2b0d8aa3472fe0d05e2064955abc"

suite "gtk4Source — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("gtk4Source")
    check spec.packageName == "gtk4Source"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("gtk4Source")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("gtk4Source")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "one library + three executable artifacts registered":
    let arts = registeredArtifacts("gtk4Source")
    check arts.len == 4
    var seenLib = false
    var seenLaunch = false
    var seenIconCache = false
    var seenQuerySettings = false
    for art in arts:
      check art.packageName == "gtk4Source"
      case art.artifactName
      of "libGtk4":
        seenLib = true
        check art.kind == dakLibrary
      of "gtk4Launch":
        seenLaunch = true
        check art.kind == dakExecutable
      of "gtk4UpdateIconCache":
        seenIconCache = true
        check art.kind == dakExecutable
      of "gtk4QuerySettings":
        seenQuerySettings = true
        check art.kind == dakExecutable
      else:
        discard
    check seenLib
    check seenLaunch
    check seenIconCache
    check seenQuerySettings

  test "versions block records the upstream tag + URL + repository":
    let vs = registeredVersions("gtk4Source")
    check vs.len == 1
    check vs[0].version == "4.18.5"
    check vs[0].sourceRevision == "4.18.5"
    check vs[0].sourceUrl == ExpectedUrl
    check vs[0].sourceRepository == "https://gitlab.gnome.org/GNOME/gtk"
