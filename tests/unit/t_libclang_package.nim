## ``libclang`` is a bundled stdlib package that provisions Clang's C library
## through every output of nixpkgs' ``libclang`` (``^*``), keyed on a header
## so a realization without the library's development output is refused by
## name. bindgen-using Cargo build scripts (rb-sys) load ``libclang`` at run
## time and failed with "Unable to find libclang" when a recipe could only
## declare the ``clang`` driver.
##
## No mocks: the registered package set and the real selector table.

import std/unittest

import repro_project_dsl
import repro_dsl_stdlib/packages/libclang
import repro_dsl_stdlib/nixpkgs_pin

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

suite "libclang stdlib package":
  test "provisions every output of nixpkgs' libclang, keyed on Index.h":
    let pkg = findPackage("libclang")
    require pkg.nixProvisioning.len == 1
    check pkg.nixProvisioning[0].selector == "nixpkgs#libclang^*"
    check pkg.nixProvisioning[0].executablePath == "include/clang-c/Index.h"
    check pkg.nixProvisioning[0].nixpkgsRev == CanonicalNixpkgsRev
    check pkg.nixProvisioning[0].nixpkgsNarHash == CanonicalNixpkgsNarHash

  test "a bare uses: line reaches it":
    check "libclang" in BundledStdlibSelectors
