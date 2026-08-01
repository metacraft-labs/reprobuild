import std/[strutils, unittest]
import repro_project_dsl
import ./repro

suite "libicalSource source recipe":
  test "pins the verified upstream release":
    let spec = registeredFetchSpec("libicalSource")
    check spec.url.endsWith("libical-3.0.19.tar.gz")
    check spec.hashHex == "6a1e7f0f50a399cbad826bcc286ce10d7151f3df7cc103f641de15160523c73f"

  test "registers the calendar libraries and GLib closure":
    let artifacts = registeredArtifacts("libicalSource")
    check artifacts.len == 4
    check "glib2 >=2.70" in registeredBuildDeps("libicalSource")
    check "libxml2 >=2.10" in registeredBuildDeps("libicalSource")
