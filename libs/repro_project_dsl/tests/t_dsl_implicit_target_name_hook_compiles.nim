## Named-Targets M0 verification: an ``executable cmakeFake:`` body
## with an ``implicitTargetName(call: CmakeBuildCall): string`` block
## compiles, and the macro generates a hook proc that round-trips a
## constant call record to the expected name.
##
## The DSL declares the typed call record (``CmakeBuildCall``) before
## the ``package`` block so the macro-emitted hook proc can resolve
## the type. The proc is emitted with a deterministic name —
## ``implicitTargetNameForCmakeFakePackage`` (the title-cased ident form
## of the executable name) — which the test calls directly to verify
## the body shape survives macro expansion.

import std/[unittest]

import repro_project_dsl

type
  CmakeBuildCall* = object
    target*: string

package tDslImplicitTargetNamePkg:
  uses:
    "nim >=2.2 <3.0"

  executable cmakeFake:
    cli:
      subcmd "build":
        flag target is string
        outputs target

    implicitTargetName(call: CmakeBuildCall): string =
      "cmake-" & call.target

suite "t_dsl_implicit_target_name_hook_compiles":
  let packages = registeredPackages()
  var pkg: PackageDef
  for p in packages:
    if p.packageName == "tDslImplicitTargetNamePkg":
      pkg = p
      break

  test "t_dsl_implicit_target_name_hook_compiles":
    check pkg.executables.len == 1
    let exe = pkg.executables[0]
    check exe.exportName == "cmakeFake"
    check exe.hasImplicitTargetNameHook
    # Round-trip the hook with a constant call record. The hook proc
    # name is derived from the executable export name via the
    # ``titleIdent`` rule used elsewhere in the DSL.
    let call = CmakeBuildCall(target: "kernel")
    check implicitTargetNameForCmakeFakePackage(call) == "cmake-kernel"
