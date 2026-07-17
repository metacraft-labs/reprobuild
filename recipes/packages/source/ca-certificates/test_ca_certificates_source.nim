import std/unittest

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://curl.se/ca/cacert-2026-07-16.pem"

const ExpectedHash =
  "3ff344e30b9b1ed2971044eabb438a08f2e2245ddb5f8ab1a3ad8b63ab4eaf91"

suite "caCertificatesSource source recipe":

  test "fetches the pinned Mozilla bundle as a data file":
    let spec = registeredFetchSpec("caCertificatesSource")
    check spec.packageName == "caCertificatesSource"
    check spec.url == ExpectedUrl
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256
    check spec.kind == dfkDataFile
    check spec.extractStrip == 0

  test "declares the data-only build closure":
    check registeredNativeBuildDeps("caCertificatesSource") == @["make"]
    check registeredBuildDeps("caCertificatesSource").len == 0
    check registeredRuntimeDeps("caCertificatesSource").len == 0

  test "registers the trust bundle as files":
    let artifacts = registeredArtifacts("caCertificatesSource")
    check artifacts.len == 1
    check artifacts[0].packageName == "caCertificatesSource"
    check artifacts[0].artifactName == "caBundle"
    check artifacts[0].kind == dakFiles

  test "records the immutable upstream revision":
    let versions = registeredVersions("caCertificatesSource")
    check versions.len == 1
    check versions[0].version == "2026-07-16"
    check versions[0].sourceRevision == "2026-07-16"
    check versions[0].sourceUrl == ExpectedUrl
    check versions[0].sourceRepository ==
      "https://hg.mozilla.org/projects/nss"
