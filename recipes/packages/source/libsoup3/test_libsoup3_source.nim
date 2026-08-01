import std/[strutils, unittest]
import repro_project_dsl
import ./repro

suite "libsoup3Source source recipe":
  test "pins the verified GNOME release":
    let spec = registeredFetchSpec("libsoup3Source")
    check spec.url.endsWith("libsoup-3.6.5.tar.xz")
    check spec.hashHex == "6891765aac3e949017945c3eaebd8cc8216df772456dc9f460976fbdb7ada234"
  test "registers the HTTP library and mandatory closure":
    check registeredArtifacts("libsoup3Source")[0].artifactName == "libSoup3"
    let deps = registeredBuildDeps("libsoup3Source")
    check "nghttp2 >=1.50" in deps
    check "libpsl >=0.20" in deps
    check "sqlite >=3.40" in deps
