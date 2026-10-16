## GM7: `buildRollbackPlan` releases, rather than removes, what the current
## generation records in a concern the TARGET generation does not apply, and
## restores what the target generation recorded in a concern the CURRENT
## generation released (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md
## §Concern-scoped apply, "Rollback respects both generations' sets").
##
## `buildRollbackPlan` is a pure function of two manifests; the executor and
## its drift checks are exercised end to end by
## tests/e2e/gm7/t_e2e_home_apply_applies_declared_concerns.nim. Nothing is
## mocked here: the manifests are ordinary in-memory records.

import std/[unittest]

import repro_home_generations
import repro_home_rollback

proc digestOf(b: byte): Digest256 =
  for i in 0 ..< 32: result[i] = b

proc fullManifest(): ActivationManifest =
  ## Every concern: a stow file, a managed block, a user file, a
  ## package's PATH binding and a placed application.
  result.generatedFiles = @[GeneratedFile(absoluteOutputPath: "/h/.zshrc",
    ownershipPolicy: gfoStowSymlink, postWriteDigest: digestOf(1),
    stowSource: "/p/stow/zsh/.zshrc")]
  result.managedBlocks = @[ManagedBlock(hostFilePath: "/h/.bashrc",
    blockId: "gm7", postWriteBlockBytes: @[byte('x')])]
  result.resourceBindings = @[
    ResourceBinding(resourceAddress: "profile.fs.userFile.marker",
      resourceKind: "fs.userFile", postWriteDigest: digestOf(2)),
    ResourceBinding(resourceAddress: "home.package.rg.bin",
      resourceKind: "env.userPath", postWriteDigest: digestOf(3)),
    ResourceBinding(resourceAddress: "home.package.ghostty.app",
      resourceKind: "macos.appBundle", postWriteDigest: digestOf(4))]

proc appsOnly(): ActivationManifest =
  result.concernsDeclared = true
  result.ownedConcerns = @["applications"]
  result.resourceBindings = @[
    ResourceBinding(resourceAddress: "home.package.ghostty.app",
      resourceKind: "macos.appBundle", postWriteDigest: digestOf(4))]

suite "GM7: rollback and the owned concern sets":

  test "rolling back to a generation that does not own a concern " &
       "releases its records":
    let plan = buildRollbackPlan(fullManifest(), appsOnly(), PointerEnvelope())
    check plan.fileOps.len == 0
    check plan.blockOps.len == 0
    check plan.resourceOps.len == 0
    check plan.released == @[
      "generated-file /h/.zshrc",
      "managed-block /h/.bashrc#gm7",
      "resource home.package.rg.bin",
      "resource profile.fs.userFile.marker"]

  test "negative control: a target that owns every concern removes them":
    var target = appsOnly()
    target.concernsDeclared = false
    let plan = buildRollbackPlan(fullManifest(), target, PointerEnvelope())
    check plan.released.len == 0
    check plan.fileOps.len == 1 and plan.fileOps[0].kind == rokRemoveFile
    check plan.blockOps.len == 1 and plan.blockOps[0].kind == rokRemoveBlock
    check plan.resourceOps.len == 2
    for op in plan.resourceOps:
      check op.kind == rokRemoveResource

  test "restoring a concern the current generation released restores the " &
       "target's records":
    # Every restore is drift-checked by the executor (`restoreDrift`), so a
    # restore of a released concern needs no mark of its own: it is a plain
    # restore of each record the target has.
    let plan = buildRollbackPlan(appsOnly(), fullManifest(), PointerEnvelope())
    check plan.released.len == 0
    check plan.fileOps.len == 1
    check plan.fileOps[0].kind == rokRestoreFile
    check plan.blockOps.len == 1 and plan.blockOps[0].kind == rokRestoreBlock
    var restored: seq[string]
    for op in plan.resourceOps:
      check op.kind == rokRestoreResource
      restored.add op.address
    check restored.len == 2
    check "profile.fs.userFile.marker" in restored
    check "home.package.rg.bin" in restored
