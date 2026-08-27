import std/unittest

import repro_project_dsl
import repro_dsl_stdlib/packages/system_tools

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

suite "host system tool provisioning":
  test "find uses the pinned Nix findutils provider":
    let pkg = findPackage("find")
    check pkg.nixProvisioning.len == 1
    check pkg.nixProvisioning[0].selector == "nixpkgs#findutils"
    check pkg.nixProvisioning[0].executablePath == "bin/find"

  test "configure comparison tools use the pinned Nix diffutils provider":
    for tool in ["cmp", "diff"]:
      let pkg = findPackage(tool)
      check pkg.nixProvisioning.len == 1
      check pkg.nixProvisioning[0].selector == "nixpkgs#diffutils"
      check pkg.nixProvisioning[0].executablePath == "bin/" & tool
