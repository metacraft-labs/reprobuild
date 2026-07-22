import std/[strutils, unittest]
import repro_project_dsl
import ./repro

suite "jsonGlibSource source recipe":
  test "pins the verified GNOME release tarball":
    let spec = registeredFetchSpec("jsonGlibSource")
    check spec.url.endsWith("json-glib-1.10.8.tar.xz")
    check spec.hashHex == "55c5c141a564245b8f8fbe7698663c87a45a7333c2a2c56f06f811ab73b212dd"
    check spec.extractStrip == 1

  test "registers the JSON GLib library and source dependencies":
    let artifacts = registeredArtifacts("jsonGlibSource")
    check artifacts.len == 1
    check artifacts[0].artifactName == "libJsonGlib"
    check "glib2 >=2.70" in registeredBuildDeps("jsonGlibSource")
    check "glib2 >=2.70" in registeredRuntimeDeps("jsonGlibSource")
