## Implicit target names emitted while a ``build:`` body runs at module
## init belong to the package whose body made the call, not to the package
## that declares the typed tool.
##
## Package-Model.md §"Scope and Ambiguity": "Implicit names are scoped to
## the package that owns the call site." Outside provider mode the
## ``package`` macro runs every ``build:`` body at module init (the M4
## ``beginBuildContext`` / ``endBuildContext`` emission). That path used to
## leave the owning-package override unset, so each typed-tool edge fell
## back to the owner the wrapper macro baked in -- the TOOL's package. Two
## recipes that each configured into the same directory then registered two
## different actions under one ``<tool>:<dir>`` name, and the within-package
## collision rule raised at module init. That is how
## ``tests/unit/t_install_mirror_tool_metadata`` died on the stdlib ``cmake``
## package when built without ``-d:reproInterfaceMode``:
##
##   duplicate implicit target name 'build' within package 'cmake'
##
## The consumers here call the tool once from a package-level ``build:`` body
## and once from an artifact-scoped one, so both module-init emitters are
## covered. Without the fix the binary aborts before the suite starts. The
## directory name is unique to this file because grouped test sources share
## one binary, and therefore one target-export registry.
##
## No mocks: the fixtures are real ``package`` declarations and the
## assertions read the real target-export registry.

import std/[algorithm, sequtils, unittest]

import repro_project_dsl

package owcTool:
  executable owcBin:
    cli:
      subcmd "configure":
        flag srcDir is string,
          alias = "-S",
          format = separate,
          role = input
        flag buildDir is string,
          alias = "-B",
          format = separate,
          role = output
        outputs buildDir

package owcConsumerA:
  build:
    discard owcTool.configure(srcDir = "consumer-a", buildDir = "owc-build")

package owcConsumerB:
  executable owcConsumerBApp:
    build:
      discard owcTool.configure(srcDir = "consumer-b", buildDir = "owc-build")

suite "module-init build bodies own their implicit targets":
  test "each consumer owns its own implicit 'owc-build' target":
    let rows = registeredTargetExports().entries.filterIt(it.name == "owc-build")
    check rows.mapIt(it.owningPackage).sorted() ==
      @["owcConsumerA", "owcConsumerB"]
    check rows.allIt(it.kind == tekImplicit)
    check rows.mapIt(it.actionId).deduplicate().len == 2

  test "the shared unqualified name is ambiguous, not a collision":
    let ambiguities = registeredTargetExports().ambiguities.filterIt(
      it.name == "owc-build")
    require ambiguities.len == 1
    check ambiguities[0].candidates.sorted() ==
      @["owcConsumerA:owc-build", "owcConsumerB:owc-build"]

  test "the override does not outlive the module-init bodies":
    check currentOwningPackage() == ""
