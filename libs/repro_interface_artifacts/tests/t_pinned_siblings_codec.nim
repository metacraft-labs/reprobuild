## ``ProjectInterface.pinnedSiblings`` (the recipe's ``pinned:`` block,
## Unified-Locking-And-Hooks.md §14.2 item 4) reaches the interface artifact,
## survives its round trip, and changes the interface fingerprint, so a recipe
## that gains or loses a pin is re-read rather than served from a cache.
##
## Test-double policy: NO mocks, doubles or fakes. The real
## ``toProjectInterface`` projection, the real envelope codec, the real
## multi-package merge.

import std/unittest

import repro_interface_artifacts
import repro_project_dsl

# Two real `package` blocks, so the merge under test is the one the
# extractor runs. The registry is cleared first: packages declared by other
# link units of this binary must not leak into the assertion.
resetPackageRegistry()

package `pinnedMergeFirst`:
  library pinnedMergeFirst
  pinned:
    "a"
    "b"

package `pinnedMergeSecond`:
  library pinnedMergeSecond
  pinned:
    "b"
    "c"

suite "the pinned siblings of a recipe reach its interface artifact":

  test "toProjectInterface carries the pins and no tool use for them":
    let projection = toProjectInterface(PackageDef(
      packageName: "consumer",
      pinnedSiblings: @["codetracer", "codetracer-vscode-extension"],
      toolUses: @[PackageUseDef(rawConstraint: "nim >=2",
        packageSelector: "nim", executableName: "nim")]))
    check projection.pinnedSiblings ==
      @["codetracer", "codetracer-vscode-extension"]
    # The point of the declaration: a pin is not a use.
    check projection.toolUses.len == 1
    check projection.toolUses[0].packageSelector == "nim"

  test "the artifact round trip keeps them in declaration order":
    let artifact = artifactFor(toProjectInterface(PackageDef(
      packageName: "consumer",
      pinnedSiblings: @["zeta", "alpha"])))
    let decoded = decodeProjectInterfaceArtifact(
      encodeProjectInterfaceArtifact(artifact))
    check decoded.projectInterface.pinnedSiblings == @["zeta", "alpha"]
    check decoded.interfaceFingerprint == artifact.interfaceFingerprint

  test "a pin moves the fingerprint; an empty list does not":
    let none = toProjectInterface(PackageDef(packageName: "consumer"))
    let one = toProjectInterface(PackageDef(packageName: "consumer",
      pinnedSiblings: @["codetracer"]))
    check interfaceFingerprint(none) != interfaceFingerprint(one)
    check none.pinnedSiblings.len == 0

  test "a file of two packages unions their pins once each":
    let artifact = artifactFromRegisteredDsl(currentSourcePath())
    check artifact.projectInterface.pinnedSiblings == @["a", "b", "c"]
