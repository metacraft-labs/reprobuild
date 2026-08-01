import std/unittest

import repro_project_dsl
import repro_dsl_stdlib/packages/system_tools

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

suite "FriBidi development provisioning":
  test "provides compile metadata from the Nix dev output":
    let pkg = findPackage("fribidi")
    check pkg.nixProvisioning.len == 1
    check pkg.nixProvisioning[0].selector == "nixpkgs#fribidi.dev"
    check pkg.nixProvisioning[0].executablePath ==
      "lib/pkgconfig/fribidi.pc"
