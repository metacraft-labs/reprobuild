import std/[sequtils, unittest]

import repro_interface_artifacts
import repro_project_dsl

package pkgconfConsumer:
  uses:
    "pkgconf"

suite "pkgconf bootstrap provisioning":
  test "plain pkgconf use imports its canonical Nix realization":
    let packages = registeredPackages()
    let consumers = packages.filterIt(it.packageName == "pkgconfConsumer")
    check consumers.len == 1

    let project = toProjectInterface(consumers[0], packages)
    let uses = project.toolUses.filterIt(it.packageSelector == "pkgconf")
    check uses.len == 1
    check uses[0].nixProvisioning.len == 1
    check uses[0].nixProvisioning[0].selector == "nixpkgs#pkgconf"
    check uses[0].nixProvisioning[0].executablePath == "bin/pkgconf"
