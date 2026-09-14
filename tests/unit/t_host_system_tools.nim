import std/[sequtils, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_dsl_stdlib/packages/system_tools
import repro_dsl_stdlib/packages/host_system_tools
import repro_dsl_stdlib/nixpkgs_pin

package hostCoreutilsConsumer:
  uses:
    "cut"
    "uname"

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

suite "host system tool provisioning":
  for command in ["cut", "uname"]:
    test command & " selects the pinned host Coreutils executable":
      let pkg = findPackage(command)
      require pkg.nixProvisioning.len == 1
      check pkg.nixProvisioning[0].selector == "nixpkgs#coreutils"
      check pkg.nixProvisioning[0].executablePath == "bin/" & command
      check pkg.nixProvisioning[0].nixpkgsRev == CanonicalNixpkgsRev
      check pkg.nixProvisioning[0].nixpkgsNarHash == CanonicalNixpkgsNarHash

  test "host Coreutils channels reach consumer tool identities":
    let iface = toProjectInterface(findPackage("hostCoreutilsConsumer"),
      registeredPackages())
    require iface.toolUses.len == 2
    for command in ["cut", "uname"]:
      let uses = iface.toolUses.filterIt(it.executableName == command)
      require uses.len == 1
      require uses[0].nixProvisioning.len == 1
      let provider = uses[0].nixProvisioning[0]
      check provider.selector == "nixpkgs#coreutils"
      check provider.executablePath == "bin/" & command
      check provider.nixpkgsRev == CanonicalNixpkgsRev
      check provider.nixpkgsNarHash == CanonicalNixpkgsNarHash

  test "SSH commands select the pinned host OpenSSH executables":
    for tool in ["ssh", "ssh-keygen"]:
      let pkg = findPackage(tool)
      check pkg.nixProvisioning.len == 1
      check pkg.nixProvisioning[0].selector == "nixpkgs#openssh"
      check pkg.nixProvisioning[0].executablePath == "bin/" & tool
      check pkg.nixProvisioning[0].nixpkgsRev == CanonicalNixpkgsRev
      check pkg.nixProvisioning[0].nixpkgsNarHash == CanonicalNixpkgsNarHash

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

  test "staging helpers use the pinned Nix coreutils provider":
    for tool in ["head", "ln", "sort"]:
      let pkg = findPackage(tool)
      check pkg.nixProvisioning.len == 1
      check pkg.nixProvisioning[0].selector == "nixpkgs#coreutils"
      check pkg.nixProvisioning[0].executablePath == "bin/" & tool
