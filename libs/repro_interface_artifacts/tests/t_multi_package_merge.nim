## Multi-package artifact merge: when a single ``repro.nim`` declares
## two or more ``package`` blocks, ``artifactFromRegisteredDsl`` must
## collapse the resulting registry entries into a single
## ``ProjectInterfaceArtifact`` whose ``publicExecutables`` /
## ``publicLibraries`` aggregate across every package in the file.
##
## Until M12-marker-fix landed this code path raised
## ``ValueError("expected one root package in <file>, got <N>")`` because
## the DSL macro couldn't compile two ``package`` blocks in one file at
## all — so the artifact layer never had to handle the case. The marker
## guard fix in ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim``
## unlocks the multi-package shape; this test pins the corresponding
## artifact-layer behaviour so a future refactor of
## ``mergeProjectInterfaces`` in
## ``libs/repro_interface_artifacts/src/repro_interface_artifacts.nim``
## doesn't silently drop a member.
##
## The two ``package`` blocks below mirror the converted
## ``reprobuild-examples/nim/mode3-pilot`` fixture: one library-bearing
## package and one executable-bearing package, both declared in the same
## Nim module (this file).

import std/[unittest]

import repro_interface_artifacts
import repro_project_dsl
import repro_dsl_stdlib/types

# Clear the registry so packages declared by earlier link units (in
# this same binary) don't leak into the assertions below.
resetPackageRegistry()

package multiArtifactGreet:
  uses:
    "nim >=2.2 <3.0"
  library greet

package multiArtifactHello:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard

suite "ProjectInterfaceArtifact multi-package merge":

  test "two packages in one file collapse into a single artifact":
    # ``rootSourceFile = ""`` picks up every registered package and
    # exercises the ``packages.len != 1`` merge branch in
    # ``artifactFromRegisteredDsl`` — the same branch the build pipeline
    # hits when the engine doesn't pass a root hint.
    let artifact = artifactFromRegisteredDsl()
    let pi = artifact.projectInterface
    # The first package in source order seeds the envelope's identity.
    check pi.projectName == "multiArtifactGreet"
    check pi.packageName == "multiArtifactGreet"
    # ...but both packages contribute their members.
    check pi.publicLibraries.len == 1
    check pi.publicLibraries[0].name == "greet"
    check pi.publicExecutables.len == 1
    check pi.publicExecutables[0].binaryName == "hello"
    # Tool-uses dedup: both packages declare the same ``nim`` constraint
    # so the merged envelope should expose ONE entry, not two.
    check pi.toolUses.len == 1
    check pi.toolUses[0].packageSelector == "nim"
