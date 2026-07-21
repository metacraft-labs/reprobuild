import std/[strutils, unittest]
import repro_project_dsl
import ./repro

suite "gsettingsDesktopSchemasSource source recipe":
  test "registers the GNOME 47 source":
    let spec = registeredFetchSpec("gsettingsDesktopSchemasSource")
    check spec.hashHex.len == 64
    check spec.url.endsWith("gsettings-desktop-schemas-47.1.tar.xz")

  test "declares GLib as a build and runtime dependency":
    check "glib2 >=2.70" in registeredBuildDeps("gsettingsDesktopSchemasSource")
    check "glib2 >=2.70" in registeredRuntimeDeps("gsettingsDesktopSchemasSource")
