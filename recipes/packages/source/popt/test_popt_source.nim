import std/unittest

import repro_project_dsl

import ./repro

const
  ExpectedUrl =
    "https://ftp.osuosl.org/pub/rpm/popt/releases/popt-1.x/popt-1.19.tar.gz"
  ExpectedHash =
    "c25a4838fc8e4c1c8aacb8bd620edb3084a3d63bf8987fdad3ca2758c63240f9"

suite "poptSource from-source recipe":
  test "fetch metadata pins the upstream release":
    let spec = registeredFetchSpec("poptSource")
    check spec.packageName == "poptSource"
    check spec.url == ExpectedUrl
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "build tools and artifact are registered":
    # AUTHORED, not the full row: reprobuild's fetch and install-mirror
    # emitters append the commands their generated scripts run (``sh``,
    # ``curl``, ``tar``, ``patchelf``, …) to every ``fetch:``-bearing
    # recipe. What this case states is what the RECIPE declared, so it
    # reads the authored accessor. The appended half is pinned on one
    # real recipe only, by ``gdiskSource``'s "emitter-contributed build
    # tools are exact"; it is NOT pinned here or by
    # ``t_source_fetch_tool_metadata`` / ``t_install_mirror_tool_metadata``.
    check registeredAuthoredNativeBuildDeps("poptSource") == @[
      "make", "gcc >=11", "pkg-config",
    ]
    let artifacts = registeredArtifacts("poptSource")
    check artifacts.len == 1
    check artifacts[0].artifactName == "libPopt"
    check artifacts[0].kind == dakLibrary
