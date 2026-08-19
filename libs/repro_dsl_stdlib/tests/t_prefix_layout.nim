## The prefix-layout vocabulary, and its use from inside a DSL declaration.
##
## Two things are being pinned here, and the second is the point.
##
## 1. The layout values themselves, checked against the paths that are known to
##    work in production rather than against the module's own claims:
##    `Library/bin/clingo.dll` is where the conda-forge win-64 package really
##    puts it (see `windows/ensure-clingo.ps1`, which produces a byte-identical
##    DLL), and `lib/libclingo.so` is the nixpkgs shape.
##
## 2. That a call to one of these funcs can be written directly in a DSL setter
##    and reaches the registry as its VALUE. That is what makes the vocabulary
##    usable at all — a helper the DSL cannot accept is just a comment.

import std/[unittest]

import repro_project_dsl
import repro_dsl_stdlib/prefix_layout
import repro_dsl_stdlib/types

package prefixLayoutPkg:
  library layoutLib:
    kind: shared
    # The reason this module exists: a named layout instead of a pasted string.
    exportedPath: runtimeLibDir(plConda)

  provisioning:
    # The clingo case that motivated the vocabulary, spelled the intended way.
    tarball url = "https://conda.anaconda.org/conda-forge/win-64/x-1.0.conda",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "conda",
      executablePath = binDir(plConda) & "/x.exe"

suite "prefix layout vocabulary":
  test "runtimeLibDir is the BIN dir on Windows-shaped layouts":
    # The distinction the module exists to encode. A recipe reaching for "the
    # lib directory" to find a DLL finds nothing.
    check runtimeLibDir(plConda) == "Library/bin"
    check runtimeLibDir(plWindowsTree) == "bin"
    check runtimeLibDir(plUnix) == "lib"

  test "linkLibDir differs from runtimeLibDir exactly on Windows layouts":
    check linkLibDir(plUnix) == runtimeLibDir(plUnix)
    check linkLibDir(plConda) != runtimeLibDir(plConda)
    check linkLibDir(plConda) == "Library/lib"
    check linkLibDir(plWindowsTree) == "lib"

  test "the clingo paths match what production actually uses":
    # conda-forge win-64 ships Library\bin\clingo.dll — the path
    # windows/ensure-clingo.ps1 stages from.
    check runtimeLibDir(plConda) & "/" & sharedLibName(plConda, "clingo") ==
      "Library/bin/clingo.dll"
    # nixpkgs ships lib/libclingo.so.
    check runtimeLibDir(plUnix) & "/" & sharedLibName(plUnix, "clingo") ==
      "lib/libclingo.so"

  test "binDir, includeDir and pkgConfigDir follow the same axis":
    check binDir(plConda) == "Library/bin"
    check binDir(plUnix) == "bin"
    check includeDir(plConda) == "Library/include"
    check pkgConfigDir(plUnix) == "lib/pkgconfig"
    check pkgConfigDir(plConda) == "Library/lib/pkgconfig"

  test "a flat layout resolves everything to the prefix root":
    check binDir(plFlat) == "."
    check runtimeLibDir(plFlat) == "."
    check linkLibDir(plFlat) == "."

suite "the vocabulary is usable from inside a DSL declaration":
  var pkg: PackageDef
  for p in registeredPackages():
    if p.packageName == "prefixLayoutPkg":
      pkg = p

  test "a func call in exportedPath: reaches the registry as its value":
    check pkg.libraries.len == 1
    check pkg.libraries[0].exportedPath == "Library/bin"

  test "a func call composes with a literal in a provisioning setter":
    check pkg.tarballProvisioning.len == 1
    check pkg.tarballProvisioning[0].executablePath == "Library/bin/x.exe"
