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

  test "Git for Windows tools carry a pinned Windows arm":
    # A Windows recipe that `uses:` one of these resolves it from the host
    # PATH in path mode, and otherwise from the host archive; with no Windows
    # arm there was no archive, so a host without Git's `usr/bin` on PATH
    # failed tool resolution ("dirname requested by uses \"dirname\" was not
    # found in PATH"). Versions are those the archive's own binaries report.
    const PortableGitSha =
      "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"
    let expected = {"dirname": "8.32", "basename": "8.32", "readlink": "8.32",
      "head": "8.32", "tail": "8.32", "cat": "8.32", "ls": "8.32",
      "od": "8.32", "tr": "8.32", "wc": "8.32", "cut": "8.32",
      "uname": "8.32", "ln": "8.32", "sort": "8.32", "tee": "8.32",
      "grep": "3.0"}
    for (tool, wanted) in expected:
      checkpoint tool
      let pkg = findPackage(tool)
      let windows = pkg.tarballProvisioning.filterIt(it.os == "windows")
      require windows.len == 1
      check windows[0].cpu == "x86_64"
      check windows[0].sha256 == PortableGitSha
      check windows[0].archiveType == "7z.exe"
      check windows[0].executablePath == "usr/bin/" & tool & ".exe"
      check windows[0].detail.version == wanted
      require pkg.scoopProvisioning.len == 1
      check pkg.scoopProvisioning[0].app == "git"
      check pkg.scoopProvisioning[0].executablePath ==
        "usr/bin/" & tool & ".exe"
      # The Nix arm is unchanged.
      check pkg.nixProvisioning.len == 1
