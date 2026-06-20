## DSL-port M9.R.15d.2 — python3-with-modules stdlib stub registration test.
##
## Pins the M9.R.15d.2 widening: gobject-introspection's build-time
## scanner (``g-ir-scanner``, ``g-ir-doc-tool``) imports ``setuptools``,
## ``mako`` and ``markdown`` at startup. The bare ``python3`` stdlib
## stub points at ``nixpkgs#python3`` which exposes the interpreter
## alone — none of the three modules ride along.
##
## The ``python3-with-modules`` stdlib stub wraps the interpreter via
## ``nixpkgs#python3.withPackages`` (expressed as a custom Nix
## expression file under ``packages/nix/python3-with-modules-1.0.0/``).
## Without this stub the gobject-introspection from-source build
## short-fails with ``ModuleNotFoundError: No module named 'mako'``.

import std/[os, strutils, unittest]

import repro_project_dsl
# Pull the system-tools aggregator so the M9.R.15d.2 stub registers
# at module-init time and ``registeredPackages()`` can find it.
import repro_dsl_stdlib/packages/system_tools

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

suite "DSL-port M9.R.15d.2 — python3-with-modules stdlib stub":

  test "python3-with-modules registers as a package":
    let pkg = findPackage("python3-with-modules")
    check pkg.packageName == "python3-with-modules"

  test "python3-with-modules declares at least one nix provisioning channel":
    let pkg = findPackage("python3-with-modules")
    check pkg.nixProvisioning.len >= 1

  test "python3-with-modules nix selector matches the expression-file pattern":
    # The selector is a synthetic identifier (not a ``nixpkgs#X``
    # attribute) because the wrapper is materialised by a custom
    # Nix expression. We pin the prefix so a later harvest cannot
    # rename it silently.
    let pkg = findPackage("python3-with-modules")
    var seenSelector = false
    for nix in pkg.nixProvisioning:
      if nix.selector.startsWith("reprobuild-stdlib-python3-with-modules"):
        seenSelector = true
    check seenSelector

  test "python3-with-modules nix executablePath is bin/python3":
    let pkg = findPackage("python3-with-modules")
    var seenSentinel = false
    for nix in pkg.nixProvisioning:
      if nix.executablePath == "bin/python3":
        seenSentinel = true
    check seenSentinel

  test "python3-with-modules points at an existing expression file":
    let pkg = findPackage("python3-with-modules")
    var seenExpr = false
    for nix in pkg.nixProvisioning:
      if nix.expressionFile.len > 0:
        seenExpr = true
        # The macro resolves the expressionFile relative to the
        # stub source file; the path stored on the provisioning
        # def is absolute. Verify the file exists on disk so a
        # future rename of the nix/ subdir surfaces here.
        check fileExists(nix.expressionFile)
    check seenExpr

  test "python3-with-modules lockIdentity records the module set":
    # The lockIdentity is the deterministic cache key for the
    # provisioning channel. Pin that it names the three modules
    # the gobject-introspection scanner needs so a silent module
    # drop is caught by this test.
    let pkg = findPackage("python3-with-modules")
    for nix in pkg.nixProvisioning:
      check nix.lockIdentity.contains("setuptools")
      check nix.lockIdentity.contains("mako")
      check nix.lockIdentity.contains("markdown")
