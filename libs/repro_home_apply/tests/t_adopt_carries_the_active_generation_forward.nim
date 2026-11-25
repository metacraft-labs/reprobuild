## `repro home adopt` claims an existing object without changing it, so its
## generation is the active generation plus the adopted binding
## (the `repro home adopt` specification, § Carry-forward): only the packages that own the adopted addresses are touched,
## and every other package, launcher and binding of the active generation
## carries over as recorded.
##
## This test drives the two production functions the pipeline composes the
## adopt generation from -- `carryForwardManifest` and `copyCarriedLaunchers`
## -- over real manifest values and a real scratch directory. The pipeline
## wiring itself (the realize, file, block and resource steps an adopt run
## skips) is covered end to end by `t_e2e_home_adopt_realizes_only_what_is_adopted`.
## No mocks.

import std/[options, os, sets, strutils, tempfiles, unittest]

import repro_home_generations
import repro_home_apply/adopt_carry

proc pkg(id: string; seed: byte): RealizedPackage =
  result.packageId = id
  result.adapter = "builtin"
  for i in 0 ..< result.realizedPrefixId.len:
    result.realizedPrefixId[i] = seed

proc cmd(name: string): ExportedCommand =
  ExportedCommand(commandName: name, binDirRelativePath: name,
    binDirArtifactKind: "launcher-script")

proc binding(address, payload: string): ResourceBinding =
  ResourceBinding(resourceAddress: address, providerIdentity: "repro.builtin",
    postWriteDigest: default(Digest256), payloadBytes: @[byte(ord(payload[0]))])

suite "adopt carries the active generation forward":
  test "an application-bundle address names the package to realize":
    check adoptedPackageIds(["home.package.claude-desktop.app",
      "home.package.cursor.app"]) == ["claude-desktop", "cursor"].toHashSet
    check adoptedPackageIds(["home.file.zshrc", "fs.userFile.x"]).len == 0

  test "other packages, launchers and bindings carry over unchanged":
    var prev = ActivationManifest(schemaVersion: ManifestSchemaVersion)
    prev.realizedPackages = @[pkg("figma", 1), pkg("claude-desktop", 2),
      pkg("ripgrep", 3)]
    prev.exportedCommands = @[cmd("figma"), cmd("claude"), cmd("rg")]
    prev.resourceBindings = @[binding("home.package.figma.app", "f"),
      binding("home.fs.keep", "k")]
    prev.concernsDeclared = true
    prev.ownedConcerns = @["applications"]
    let got = carryForwardManifest(some(prev),
      ["claude-desktop"].toHashSet, ["claude"].toHashSet,
      @[pkg("claude-desktop", 9)], @[cmd("claude")],
      @[binding("home.package.claude-desktop.app", "c")])
    # figma and ripgrep: the very records of the active generation.
    check got.realizedPackages.len == 3
    check got.realizedPackages[0].packageId == "figma"
    check got.realizedPackages[0].realizedPrefixId == prev.realizedPackages[0].realizedPrefixId
    check got.realizedPackages[1].packageId == "ripgrep"
    check got.realizedPackages[2].packageId == "claude-desktop"
    check got.realizedPackages[2].realizedPrefixId[0] == 9
    check got.exportedCommands.len == 3
    check got.resourceBindings.len == 3
    check got.resourceBindings[0].resourceAddress == "home.package.figma.app"
    check got.resourceBindings[1].resourceAddress == "home.fs.keep"
    check got.resourceBindings[2].resourceAddress == "home.package.claude-desktop.app"
    # The concerns the active generation recorded stay.
    check got.concernsDeclared
    check got.ownedConcerns == @["applications"]

  test "a command the adopted package no longer plans is dropped; a rebinding replaces":
    var prev = ActivationManifest(schemaVersion: ManifestSchemaVersion)
    prev.realizedPackages = @[pkg("app", 1)]
    prev.exportedCommands = @[cmd("app"), cmd("app-old"), cmd("other")]
    prev.resourceBindings = @[binding("home.package.app.app", "o")]
    let got = carryForwardManifest(some(prev), ["app"].toHashSet,
      ["app", "app-old"].toHashSet, @[pkg("app", 2)], @[cmd("app")],
      @[binding("home.package.app.app", "n")])
    check got.exportedCommands.len == 2
    check got.exportedCommands[0].commandName == "other"
    check got.exportedCommands[1].commandName == "app"
    check got.resourceBindings.len == 1
    check got.resourceBindings[0].payloadBytes == @[byte(ord('n'))]

  test "with no active generation the generation holds only the adopted packages":
    let got = carryForwardManifest(none(ActivationManifest),
      ["app"].toHashSet, initHashSet[string](), @[pkg("app", 1)], @[],
      @[binding("home.package.app.app", "n")])
    check got.realizedPackages.len == 1
    check got.exportedCommands.len == 0
    check got.resourceBindings.len == 1

  test "the launchers other packages own are copied from the active bin dir":
    let root = createTempDir("adopt_carry_", "")
    defer: removeDir(root)
    let prevBin = root / "prev" / "bin"
    let newBin = root / "new" / "bin"
    createDir(prevBin)
    writeFile(prevBin / "rg", "#!/bin/sh\necho rg\n")
    setFilePermissions(prevBin / "rg", {fpUserRead, fpUserWrite, fpUserExec})
    writeFile(prevBin / "claude", "old claude")
    var prev = ActivationManifest(schemaVersion: ManifestSchemaVersion)
    prev.exportedCommands = @[cmd("rg"), cmd("claude")]
    let carried = carriedCommands(prev, @[cmd("claude")])
    check carried.len == 1
    copyCarriedLaunchers(prevBin, newBin, carried)
    check readFile(newBin / "rg") == "#!/bin/sh\necho rg\n"
    check fpUserExec in getFilePermissions(newBin / "rg")
    check not fileExists(newBin / "claude")

  test "a carried launcher the active bin dir lacks is refused, naming it":
    let root = createTempDir("adopt_carry_", "")
    defer: removeDir(root)
    createDir(root / "prev")
    expect IOError:
      copyCarriedLaunchers(root / "prev", root / "new", @[cmd("gone")])

  test "a carried launcher path that leaves the bin directory is refused":
    let root = createTempDir("adopt_carry_", "")
    defer: removeDir(root)
    createDir(root / "prev")
    writeFile(root / "secret", "x")
    var c = cmd("evil")
    c.binDirRelativePath = "../secret"
    expect IOError:
      copyCarriedLaunchers(root / "prev", root / "new", @[c])
    check not fileExists(root / "new" / "secret")
