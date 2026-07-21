import std/[strutils, unittest]
import repro_project_dsl
import ./repro

suite "atSpi2CoreSource source recipe":
  test "registers the GNOME 2.54 source":
    let spec = registeredFetchSpec("atSpi2CoreSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("at-spi2-core-2.54.1.tar.xz")

  test "registers the accessibility libraries":
    let artifacts = registeredArtifacts("atSpi2CoreSource")
    check artifacts.len == 3

  test "declares its source-built library dependencies":
    let deps = registeredBuildDeps("atSpi2CoreSource")
    check "glib2 >=2.70" in deps
    check "dbus >=1.14" in deps
    check "libxml2 >=2.10" in deps
