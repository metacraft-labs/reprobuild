## M12 verification: the DSL ``library`` member parses into
## ``PackageDef.libraries`` with the correct ``LibraryKind``.
##
## The DSL is a compile-time macro layered on top of a runtime registry,
## so the natural test idiom is: declare a ``package`` block that
## contains ``library`` members, and then inspect ``registeredPackages()``
## from runtime code to assert the parsed shape.
##
## The ``package`` macro generates a top-level
## ``reprobuildPackageMarker`` proc, so successive ``package`` blocks in
## the same module conflict. We sidestep that by piling every test case
## into a single ``package`` block — multiple ``library`` members in one
## package are exactly what M12 promises.
##
## Compile with ``-d:reproProviderMode`` so the provider-mode runtime
## glue (which the DSL exports unconditionally) is on the link line.

import std/[unittest]

import repro_project_dsl

package libraryMacroTestPackage:
  uses:
    "nim >=2.2 <3.0"

  # Case 1: bare ``library foo`` (no body) defaults to lkStatic.
  library lib_static_default

  # Case 2: ``library foo:`` block with ``discard`` body, also lkStatic.
  library lib_static_discard:
    discard

  # Case 3: ``library foo:`` with ``kind: shared`` (lkShared).
  library lib_shared_kind:
    kind: shared

  # Case 4: ``library foo:`` with ``kind: both`` (lkBoth).
  library lib_both_kind:
    kind: both

  # Case 5: ``library foo:`` with ``kind: header-only`` (lkHeaderOnly).
  # Nim parses ``header-only`` as an infix; quote it to keep one ident.
  library lib_header_only:
    kind: `header-only`

  # Case 6: ``library foo:`` with ``kind: static`` explicit.
  library lib_static_explicit:
    kind: static

suite "DSL library macro M12":
  let packages = registeredPackages()
  var pkg: PackageDef
  for p in packages:
    if p.packageName == "libraryMacroTestPackage":
      pkg = p
      break

  proc libByName(name: string): LibraryDef =
    for lib in pkg.libraries:
      if lib.name == name:
        return lib
    raise newException(ValueError, "library not found: " & name)

  test "registry sees the test package":
    check pkg.packageName == "libraryMacroTestPackage"
    check pkg.libraries.len == 6
    check pkg.executables.len == 0

  test "bare library defaults to lkStatic":
    let lib = libByName("lib_static_default")
    check lib.name == "lib_static_default"
    check lib.kind == lkStatic

  test "library with `discard` body defaults to lkStatic":
    let lib = libByName("lib_static_discard")
    check lib.kind == lkStatic

  test "kind: shared maps to lkShared":
    let lib = libByName("lib_shared_kind")
    check lib.kind == lkShared

  test "kind: both maps to lkBoth":
    let lib = libByName("lib_both_kind")
    check lib.kind == lkBoth

  test "kind: `header-only` maps to lkHeaderOnly":
    let lib = libByName("lib_header_only")
    check lib.kind == lkHeaderOnly

  test "kind: static (explicit) maps to lkStatic":
    let lib = libByName("lib_static_explicit")
    check lib.kind == lkStatic

  test "library declarations carry source location":
    let lib = libByName("lib_static_default")
    check lib.sourceFile.len > 0
    check lib.sourceLine > 0
