## A package whose name starts with a digit can be declared under that name.
##
## reprobuild-pm/issues/2026-10-13-package-macro-cannot-declare-a-name-starting-with-a-digit.md:
## the 7-Zip package is registered as ``7zip`` everywhere operators see it,
## but no spelling of that name declared a package. ``package 7zip:`` does not
## lex, and ``package "7zip":`` (or `` package `7 zip`: ``) reached the macro
## and then failed inside it, because the macro emitted the name as the
## package's value and type identifiers and the generated code did not parse.
##
## Package-Model.md §"Package names" settles it: a package name is a selector
## string, written as a string literal when it is not a Nim identifier, and
## every identifier the macro emits is derived through ``selectorModuleName``,
## which prefixes ``pkg_`` to a name that would begin with a digit.
##
## The three declarations below cover the three emission paths that turn the
## name into code: a provisioning-only package (the stdlib 7-Zip shape), a
## package with a typed executable (the legacy ``<Title>Package`` const and
## wrapper path), and a package with no executables whose ``build:`` exports a
## cross-project binding (the ``Package[name]`` const path in
## ``cross_project.nim``). This file failing to compile is the regression.
##
## No mocks: the real ``package`` macro and the real registry.

import std/[unittest]

import repro_project_dsl
import repro_project_dsl/selector_names
import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/types

type
  DigitToolHandle = object
    path: string

# The stdlib 7-Zip shape: platforms plus `tarball` provisioning.
package "7zip":
  platforms [windows]
  provisioning:
    tarball url = "https://example.invalid/7z-test.msi",
      sha256 = "a47ea8dcf8bc08e6de474cae77c828e031fa22cb528f6095defffebf11cd02f2",
      archiveType = "installer-msi",
      executablePath = "7z.exe",
      version = "26.01",
      packageId = "7zip@26.01",
      cpu = "x86_64",
      os = "windows"

# A typed executable: emits the `<Title>Package` type, its value const and
# the typed-tool wrapper procs.
package "2fa":
  executable twoFactor:
    cli:
      subcmd "compile":
        flag source is string
        flag binary is string
        outputs result is DigitToolHandle, binary

# No executables, one exported `build:` binding: emits the v8-shape
# `Package[name]` const directly from the package name.
package "3dProducer":
  build:
    let singleEdge = pkg_2fa.compile(
      source = "tests/digit/single.nim",
      binary = "build/digit/single")

# `depends_on` names a package the way `package` does.
depends_on "3dProducer":
  "7zip"
  "2fa"

proc registered(name: string): bool =
  for p in registeredPackages():
    if p.packageName == name:
      return true
  false

suite "package names starting with a digit":

  test "selectorModuleName never yields an identifier starting with a digit":
    check selectorModuleName("7zip") == "pkg_7zip"
    check selectorModuleName("7-zip") == "pkg_7_zip"
    check selectorModuleName("3dProducer") == "pkg_3d_producer"
    # Names that were already identifiers map exactly as before.
    check selectorModuleName("myEmptyPkg") == "my_empty_pkg"
    check selectorModuleName("dotnet-sdk") == "dotnet_sdk"
    check selectorModuleName("python3") == "python3"
    # `usesImportCode`'s module path for a selector uses the same mapping.
    check bundledStdlibModuleName("7zip") == "pkg_7zip"

  test "the canonical name is registered verbatim":
    check registered("7zip")
    check registered("2fa")
    check registered("3dProducer")
    check not registered("pkg_7zip")
    check not registered("sevenzip")

  test "the provisioning-only package keeps its realizations":
    var found = false
    for p in registeredPackages():
      if p.packageName == "7zip":
        found = true
        check p.declaredPlatforms.len == 1
        check p.tarballProvisioning.len == 1
        if p.tarballProvisioning.len == 1:
          check p.tarballProvisioning[0].packageId == "7zip@26.01"
    check found
    check declaredPackagePlatforms("7zip").declared

  test "the derived value and type identifiers are declared":
    check declared(pkg_7zip)
    check declared(Pkg7zipPackage)
    check declared(pkg_2fa)
    check declared(Pkg2faPackage)
    check declared(twoFactor)
    check declared(pkg_3d_producer)

  test "the cross-project binding resolves through the derived identifier":
    check compiles(pkg_3d_producer.build.singleEdge)
    check compiles(PackageBuild["3dProducer"]().singleEdge)
    check not compiles(pkg_3d_producer.build.noSuchBinding)

  test "depends_on records a quoted package name without its quotes":
    var deps: seq[string] = @[]
    for edge in registeredWorkspaceDeps():
      if edge.package == "3dProducer":
        deps.add edge.dependency
    check deps == @["7zip", "2fa"]
