import std/unittest

import repro_project_dsl
import repro_dsl_stdlib/packages/system_tools

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

suite "shared-mime-info development provisioning":
  test "provides pkg-config metadata from the Nix dev output":
    let pkg = findPackage("shared-mime-info")
    check pkg.nixProvisioning.len == 1
    check pkg.nixProvisioning[0].selector ==
      "nixpkgs#shared-mime-info.dev"
    check pkg.nixProvisioning[0].executablePath ==
      "share/pkgconfig/shared-mime-info.pc"
