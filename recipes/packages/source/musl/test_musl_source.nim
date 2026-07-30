import std/unittest

import repro_project_dsl
import ./repro

suite "muslSource recipe":
  test "pins the canonical musl 1.2.6 release":
    let spec = registeredFetchSpec("muslSource")
    check spec.url == "https://musl.libc.org/releases/musl-1.2.6.tar.gz"
    check spec.hashHex ==
      "d585fd3b613c66151fc3249e8ed44f77020cb5e6c1e635a616d3f9f82460512a"
    check spec.hashAlg == dshaSha256
    check spec.extractStrip == 1

  test "exposes the compiler wrapper":
    let artifacts = registeredArtifacts("muslSource")
    check artifacts.len == 1
    check artifacts[0].artifactName == "musl"
    check artifacts[0].kind == dakExecutable

  test "records the upstream version metadata":
    let versions = registeredVersions("muslSource")
    check versions.len == 1
    check versions[0].version == "1.2.6"
    check versions[0].sourceRevision == "v1.2.6"
    check versions[0].sourceRepository ==
      "https://git.musl-libc.org/cgit/musl"
