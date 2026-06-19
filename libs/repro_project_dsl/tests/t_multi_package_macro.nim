## Multi-package DSL surface: a single Nim file may declare two (or
## more) ``package`` blocks. Before this test pinned the contract the
## DSL's ``wrapperCode`` emitted a top-level ``reprobuildPackageMarker``
## proc per package, so two ``package`` blocks in the same file caused
## a Nim "redefinition" error. The marker emission is now guarded by
## ``when not declared(reprobuildPackageMarker)`` so the second (and
## any subsequent) ``package`` block in the same file is a no-op for
## marker purposes while still calling ``registerPackageDef`` — which
## means BOTH packages remain visible to ``registeredPackages()``.
##
## This is the DSL counterpart to the scanner-side multi-package test
## in ``libs/repro_core/tests/t_nim_dep_scanner.nim`` ("two ``package``
## blocks in one project file: scanner partitions members"). Together
## the pair certifies the "one workspace, many packages, single file"
## use case end-to-end:
##
##   * the SCANNER (text-level) partitions members across packages;
##   * the MACRO LAYER (compile-time) accepts the dual declaration
##     without a marker collision and registers both packages.
##
## Compile with ``-d:reproProviderMode`` so the provider-mode runtime
## glue (which the DSL exports unconditionally) is on the link line —
## same convention as the other DSL tests in this directory.

import std/[unittest]

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

# Two ``package`` blocks in ONE Nim module. Before the marker fix,
# the second declaration produced ``redefinition of reprobuildPackageMarker``
# at compile time and this file would not parse. The fact that this
# file compiles AT ALL is the primary regression assertion; the
# ``suite`` below pins the runtime-visibility contract on top.

package multiPkgAlpha:
  uses:
    "nim >=2.2 <3.0"
  library alphaLib

package multiPkgBeta:
  uses:
    "nim >=2.2 <3.0"
  executable betaBin:
    discard

# A third package, to prove the no-op-after-first guard scales beyond
# two emissions in the same file.
package multiPkgGamma:
  uses:
    "nim >=2.2 <3.0"
  library gammaLib

suite "DSL multi-package single-file (marker collision fix)":

  let packages = registeredPackages()

  proc pkgByName(name: string): PackageDef =
    for p in packages:
      if p.packageName == name:
        return p
    raise newException(ValueError, "package not found: " & name)

  test "all three packages register independently":
    # Pre-fix this list would have failed to compile entirely, so the
    # assertion is also a forward-compat guard for future macro changes
    # that might silently drop a registry entry.
    let names = block:
      var acc: seq[string] = @[]
      for p in packages:
        acc.add(p.packageName)
      acc
    check "multiPkgAlpha" in names
    check "multiPkgBeta" in names
    check "multiPkgGamma" in names

  test "alpha owns alphaLib, no executables":
    let p = pkgByName("multiPkgAlpha")
    check p.libraries.len == 1
    check p.libraries[0].name == "alphaLib"
    check p.executables.len == 0

  test "beta owns betaBin, no libraries":
    let p = pkgByName("multiPkgBeta")
    check p.libraries.len == 0
    check p.executables.len == 1
    check p.executables[0].binaryName == "betaBin"

  test "gamma owns gammaLib, no executables":
    let p = pkgByName("multiPkgGamma")
    check p.libraries.len == 1
    check p.libraries[0].name == "gammaLib"
    check p.executables.len == 0

  test "reprobuildPackageMarker proc exists exactly once at module scope":
    # The marker remains a callable sentinel (``usesImportCode`` queries
    # it via ``when compiles(...)``); the fix is "declared once" not
    # "removed". A direct call here would only check it exists at all,
    # but ``when declared`` is the contract the consumer side uses.
    check declared(reprobuildPackageMarker)
    # And it must be callable — i.e. not stubbed out.
    reprobuildPackageMarker()
