import std/unittest

import repro_project_dsl

import ./repro

const
  ExpectedUrl =
    "https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.51.tar.bz2"
  ExpectedHash =
    "be0f1b2db6b93eed55369cdf79f19f72750c8c7c39fc20b577e724545427e6b2"

suite "libgpgErrorSource from-source recipe":
  test "fetch metadata pins the upstream release":
    let spec = registeredFetchSpec("libgpgErrorSource")
    check spec.packageName == "libgpgErrorSource"
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
    check registeredAuthoredNativeBuildDeps("libgpgErrorSource") == @[
      "make", "gcc >=11", "pkg-config",
    ]
    let artifacts = registeredArtifacts("libgpgErrorSource")
    check artifacts.len == 1
    check artifacts[0].artifactName == "libGpgError"
    check artifacts[0].kind == dakLibrary
