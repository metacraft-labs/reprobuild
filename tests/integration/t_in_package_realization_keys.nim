## ``t_in_package_realization_keys`` -- ReproOS-Campaign-Completion M7:
## every field of a tool package's OWN realization (its ``provisioning``,
## declared by the package itself: contributor empty, no contribution
## record) is bound by the keys that cache what it realizes, while the
## package interface fingerprint stays put.
##
## ## The defect this pins
##
## ``interfaceFingerprint`` omits tool-use realizations (since codec v13: a
## realization change is not an interface change). The CLI tool-identity
## cache key (``repro_cli_support.toolIdentityCacheKey``, and through it the
## lowered-graph key) re-bound them from a LIST of fields, and the list
## missed ``packageName``, ``nixpkgsRef`` / ``nixpkgsRev`` /
## ``nixpkgsNarHash``, ``executableAlias``, ``prunePaths``, ``cpu`` and
## ``os``. An imported contribution's realizations were re-bound by
## ``importedProvisioningMetadataDigest``; an in-package realization had
## nothing. So editing only one of those fields was served the STALE cached
## tool identity: a ``cpu`` / ``os`` edit that selects another archive kept
## realizing the old one; an added alias or prune never happened.
##
## One layer down, the tarball realized-prefix path (``unifiedPrefixPath``)
## did not bind ``executableAlias`` or ``prunePaths`` either, so even a
## fresh resolution found the prefix a plan without them had left at the
## same path and returned it unchanged -- the alias missing, the prune not
## applied -- with the tool profile and typed-tool action fingerprints
## (which key on the prefix path) unmoved.
##
## ## What is asserted
##
##   * every field of every realization family, changed alone, moves the
##     tool-identity key in every provisioning mode and the lowered-graph
##     key; the source location moves nothing; the consumer's interface
##     fingerprint moves for none of them. Driven by ``fieldPairs``, so a
##     field added to a realization type is covered (or fails to compile
##     here) without anyone remembering to add it;
##   * the same through the DSL projection (``toProjectInterface`` over the
##     tool package's own ``PackageDef``): the tool package's canonical
##     interface fingerprint and the consumer's never move, the key does,
##     and neither a declaration's source location nor the order packages
##     are declared in moves anything;
##   * the order of two entries of one family IS significant (the planners
##     take the first eligible one) and is bound -- shown by realizing it;
##   * the CLI build path (``warmResolveAndWriteIdentity``) with real
##     archives: X, then only the field changed to Y, re-resolves and
##     realizes Y from the warm table, from a cold process and after a
##     daemon-parent prewarm of X's stamps; back to X uses X's key and X's
##     identity again; a location-only change is a warm hit;
##   * the realized prefix moves with the alias and the prune list, and a
##     prefix an older engine realized with a different prune list or alias
##     at the path a plan now computes is refused, not served.
##
## Built and run on Windows only (WSL was down); the fixtures are portable.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_cli_support
import repro_hash
import repro_interface_artifacts
import repro_local_store/store
import repro_project_dsl
import repro_tool_profiles

package inPkgTool:
  executable inPkgTool:
    name "inpkg-tool"

package inPkgConsumer:
  defaultToolProvisioning "tarball"
  uses:
    "inPkgTool"

const AllModes = [tpmPathOnly, tpmNix, tpmTarball, tpmScoop, tpmFromSource]

proc hx(d: ContentDigest): string =
  d.bytes.mapIt(it.toHex(2)).join().toLowerAscii()

proc changed[T](value: T): T =
  ## A different value of the same type. A field of any other type fails to
  ## compile HERE, which is the point: a new kind of realization field must
  ## be given a mutation before this test builds again.
  when T is string:
    (if value.len == 0: "changed-value" else: value & "-changed")
  elif T is seq[string]:
    value & @["changed-entry"]
  elif T is int:
    value + 1
  elif T is bool:
    not value
  elif T is SourceLocation:
    SourceLocation(file: value.file & "-moved.nim", line: value.line + 7)
  else:
    {.error: "t_in_package_realization_keys: give this field type a mutation".}

# ---------------------------------------------------------------------------
# Interface-level fixtures
# ---------------------------------------------------------------------------

proc nixEntry(): InterfaceNixProvisioning =
  InterfaceNixProvisioning(packageName: "inPkgTool",
    selector: "nixpkgs#hello", executablePath: "bin/hello",
    nixpkgsRef: "github:NixOS/nixpkgs/0123456789abcdef",
    nixpkgsRev: "0123456789abcdef0123456789abcdef01234567",
    nixpkgsNarHash: "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    location: SourceLocation(file: "packages/inpkg_tool.nim", line: 3))

proc tarballEntry(): InterfaceTarballProvisioning =
  InterfaceTarballProvisioning(packageName: "inPkgTool",
    url: "https://example.invalid/inpkg-tool.tar.gz",
    sha256: repeat('a', 64), archiveType: "tar.gz",
    executablePath: "bin/inpkg-tool", stripComponents: 1,
    location: SourceLocation(file: "packages/inpkg_tool.nim", line: 5))

proc scoopEntry(): InterfaceScoopProvisioning =
  InterfaceScoopProvisioning(packageName: "inPkgTool", bucket: "main",
    app: "inpkg-tool", version: "1.0.0", executablePath: "inpkg-tool.exe",
    location: SourceLocation(file: "packages/inpkg_tool.nim", line: 7))

proc consumerWith(nix: seq[InterfaceNixProvisioning];
                  tarball: seq[InterfaceTarballProvisioning];
                  scoop: seq[InterfaceScoopProvisioning]):
    ProjectInterfaceArtifact =
  ## A consumer whose one tool use carries the tool package's OWN
  ## realizations (contributor empty) and no contribution record.
  artifactFor(ProjectInterface(projectName: "inPkgConsumer",
    packageName: "inPkgConsumer", defaultToolProvisioning: "tarball",
    toolUses: @[InterfaceToolUse(rawConstraint: "inPkgTool",
      packageSelector: "inPkgTool", executableName: "inpkg-tool",
      nixProvisioning: nix, tarballProvisioning: tarball,
      scoopProvisioning: scoop,
      location: SourceLocation(file: "repro.nim", line: 4))]))

proc cacheKeys(artifact: ProjectInterfaceArtifact): seq[string] =
  ## The tool-identity key in every provisioning mode, then the lowered-graph
  ## key (which folds the tool-identity key in).
  for mode in AllModes:
    result.add(toolIdentityCacheKey(artifact, mode, pathValue = ""))
  result.add(loweredGraphCacheKey(artifact, tpmTarball, "provider-artifact",
    "", ""))

template checkFieldBinding(label, field: string;
                           base, mutated: ProjectInterfaceArtifact) =
  ## A template, not a proc: ``check`` marks the TEST failed only when it
  ## expands inside the test body (in a proc it merely sets the exit code).
  block:
    checkpoint(label & "." & field)
    let before = cacheKeys(base)
    let after = cacheKeys(mutated)
    # Realization metadata never moves the interface fingerprint.
    check mutated.interfaceFingerprint == base.interfaceFingerprint
    if field == "location":
      check after == before
    else:
      for i in 0 ..< before.len:
        check after[i] != before[i]

# ---------------------------------------------------------------------------
# Real archives
# ---------------------------------------------------------------------------

var fixtureRoot = ""

proc toolFile(name: string): string =
  when defined(windows): name & ".cmd" else: name

proc writeTool(path, marker: string) =
  when defined(windows):
    writeFile(path, "@echo off\r\necho " & marker & "\r\n")
  else:
    writeFile(path, "#!/bin/sh\necho " & marker & "\n")
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

type Archive = object
  url: string
  sha256: string
  marker: string

proc buildArchive(name, marker: string): Archive =
  ## ``inpkg-tool-1.0.0/{bin/inpkg-tool, share/doc/readme.txt}``; the
  ## executable prints ``marker``.
  let payload = fixtureRoot / ("payload-" & name)
  let top = payload / "inpkg-tool-1.0.0"
  createDir(top / "bin")
  createDir(top / "share" / "doc")
  writeTool(top / "bin" / toolFile("inpkg-tool"), marker)
  writeFile(top / "share" / "doc" / "readme.txt", marker & "\n")
  let archive = fixtureRoot / (name & ".tar.gz")
  var tarExe = "tar"
  when defined(windows):
    let systemTar = getEnv("SystemRoot", r"C:\Windows") / "System32" /
      "tar.exe"
    tarExe = if fileExists(systemTar): systemTar else: findExe("tar")
  let res = execCmdEx(quoteShell(tarExe) & " -czf " & quoteShell(archive) &
    " -C " & quoteShell(payload) & " inpkg-tool-1.0.0")
  doAssert res.exitCode == 0, "tar failed: " & res.output
  Archive(url: "file://" & archive.replace('\\', '/'),
    sha256: fileSha256Hex(archive).toLowerAscii(), marker: marker)

var archiveA, archiveB: Archive

proc hostOs(): string =
  when defined(windows): "windows"
  elif defined(macosx): "macos"
  else: "linux"

proc hostCpu(): string =
  if hostCPU == "arm64": "aarch64" else: "x86_64"

proc realEntry(archive: Archive; os = "", cpu = ""):
    InterfaceTarballProvisioning =
  InterfaceTarballProvisioning(packageName: "inPkgTool", url: archive.url,
    sha256: archive.sha256, archiveType: "tar.gz",
    executablePath: "bin/" & toolFile("inpkg-tool"), stripComponents: 1,
    packageId: "inpkg-tool@1.0.0", os: os, cpu: cpu,
    location: SourceLocation(file: "packages/inpkg_tool.nim", line: 5))

proc hostSpecificThenCatchAll(): seq[InterfaceTarballProvisioning] =
  ## Entry 1 (archive A) targets this host and is the one selected; entry 2
  ## (archive B) is the catch-all an edit of entry 1's ``cpu`` / ``os``
  ## falls through to.
  @[realEntry(archiveA, hostOs(), hostCpu()), realEntry(archiveB)]

proc marker(identity: PathOnlyBuildIdentity): string =
  for line in readFile(identity.profiles[0].resolvedExecutablePath).
      splitLines():
    if line.startsWith("echo "):
      return line["echo ".len .. ^1].strip()

proc aliasPresent(identity: PathOnlyBuildIdentity; alias: string): bool =
  fileExists(parentDir(identity.profiles[0].resolvedExecutablePath) / alias)

proc docPresent(identity: PathOnlyBuildIdentity): bool =
  dirExists(identity.profiles[0].selectedStorePath / "share" / "doc")

var dirCounter = 0

proc freshDir(label: string): string =
  inc dirCounter
  fixtureRoot / (label & "-" & $dirCounter)

type RealizationEdit = object
  field: string
  apply: proc (entry: var InterfaceTarballProvisioning)
  realizedY: proc (identity: PathOnlyBuildIdentity): bool
    ## True when ``identity`` is a realization of the EDITED entry.

let alias = toolFile("inpkg-alias")

let edits = @[
  RealizationEdit(field: "executableAlias",
    apply: proc (entry: var InterfaceTarballProvisioning) =
      entry.executableAlias = alias,
    realizedY: proc (identity: PathOnlyBuildIdentity): bool =
      identity.aliasPresent(alias)),
  RealizationEdit(field: "prunePaths",
    apply: proc (entry: var InterfaceTarballProvisioning) =
      entry.prunePaths = @["share/doc"],
    realizedY: proc (identity: PathOnlyBuildIdentity): bool =
      not identity.docPresent()),
  RealizationEdit(field: "cpu",
    apply: proc (entry: var InterfaceTarballProvisioning) =
      entry.cpu = (if hostCpu() == "aarch64": "x86_64" else: "aarch64"),
    realizedY: proc (identity: PathOnlyBuildIdentity): bool =
      identity.marker == archiveB.marker),
  RealizationEdit(field: "os",
    apply: proc (entry: var InterfaceTarballProvisioning) =
      entry.os = (if hostOs() == "linux": "windows" else: "linux"),
    realizedY: proc (identity: PathOnlyBuildIdentity): bool =
      identity.marker == archiveB.marker)]

proc edited(edit: RealizationEdit): ProjectInterfaceArtifact =
  var entries = hostSpecificThenCatchAll()
  edit.apply(entries[0])
  consumerWith(@[], entries, @[])

proc receiptPath(prefix: string): string =
  prefix / ".reprobuild-tarball-receipt.json"

# ---------------------------------------------------------------------------

suite "in-package realization keys":
  when defined(windows):
    # The tarball adapter shells out to ``tar``; prefer the System32 bsdtar
    # over an MSYS one, which mis-parses drive-letter paths.
    putEnv("PATH", getEnv("SystemRoot", r"C:\Windows") / "System32" & ";" &
      getEnv("PATH"))
  # Hermetic: never substitute from, or publish to, a shared binary cache.
  putEnv("REPRO_CACHE_DISABLE", "1")
  fixtureRoot = createTempDir("repro-inpkg-keys-", "")
  archiveA = buildArchive("a", "inpkg-tool-from-archive-a")
  archiveB = buildArchive("b", "inpkg-tool-from-archive-b")

  test "every field of an in-package Nix, tarball and Scoop realization moves every tool-identity key, and the location none":
    block:
      let base = consumerWith(@[nixEntry()], @[], @[])
      for name, value in nixEntry().fieldPairs:
        var pi = base.projectInterface
        for field, slot in pi.toolUses[0].nixProvisioning[0].fieldPairs:
          when field == name:
            slot = changed(slot)
        checkFieldBinding("nix", name, base, artifactFor(pi))
    block:
      let base = consumerWith(@[], @[tarballEntry()], @[])
      for name, value in tarballEntry().fieldPairs:
        var pi = base.projectInterface
        for field, slot in pi.toolUses[0].tarballProvisioning[0].fieldPairs:
          when field == name:
            slot = changed(slot)
        checkFieldBinding("tarball", name, base, artifactFor(pi))
    block:
      let base = consumerWith(@[], @[], @[scoopEntry()])
      for name, value in scoopEntry().fieldPairs:
        var pi = base.projectInterface
        for field, slot in pi.toolUses[0].scoopProvisioning[0].fieldPairs:
          when field == name:
            slot = changed(slot)
        checkFieldBinding("scoop", name, base, artifactFor(pi))
    # The fields the v4 key's list missed, named, so a reader of a failure
    # sees them without decoding the loop.
    let tarballBase = consumerWith(@[], @[tarballEntry()], @[])
    for edit in [
        proc (e: var InterfaceTarballProvisioning) = e.executableAlias = "x",
        proc (e: var InterfaceTarballProvisioning) = e.prunePaths = @["doc"],
        proc (e: var InterfaceTarballProvisioning) = e.cpu = "aarch64",
        proc (e: var InterfaceTarballProvisioning) = e.os = "linux",
        proc (e: var InterfaceTarballProvisioning) = e.packageName = "other"]:
      var pi = tarballBase.projectInterface
      edit(pi.toolUses[0].tarballProvisioning[0])
      check toolIdentityCacheKey(artifactFor(pi), tpmTarball) !=
        toolIdentityCacheKey(tarballBase, tpmTarball)
    let nixBase = consumerWith(@[nixEntry()], @[], @[])
    for edit in [
        proc (e: var InterfaceNixProvisioning) = e.nixpkgsRef = "other",
        proc (e: var InterfaceNixProvisioning) = e.nixpkgsRev = "other",
        proc (e: var InterfaceNixProvisioning) = e.nixpkgsNarHash = "other",
        proc (e: var InterfaceNixProvisioning) = e.packageName = "other"]:
      var pi = nixBase.projectInterface
      edit(pi.toolUses[0].nixProvisioning[0])
      check toolIdentityCacheKey(artifactFor(pi), tpmNix) !=
        toolIdentityCacheKey(nixBase, tpmNix)
    var scoopPi = consumerWith(@[], @[], @[scoopEntry()]).projectInterface
    let scoopKey = toolIdentityCacheKey(artifactFor(scoopPi), tpmScoop)
    scoopPi.toolUses[0].scoopProvisioning[0].packageName = "other"
    check toolIdentityCacheKey(artifactFor(scoopPi), tpmScoop) != scoopKey
    # Values are framed, not joined: the v4 key joined ``mirrors`` with a
    # newline, so these two different mirror lists keyed the same.
    var oneMirror = tarballBase.projectInterface
    oneMirror.toolUses[0].tarballProvisioning[0].mirrors =
      @["https://m.invalid/a\nhttps://m.invalid/b"]
    var twoMirrors = tarballBase.projectInterface
    twoMirrors.toolUses[0].tarballProvisioning[0].mirrors =
      @["https://m.invalid/a", "https://m.invalid/b"]
    check toolIdentityCacheKey(artifactFor(oneMirror), tpmTarball) !=
      toolIdentityCacheKey(artifactFor(twoMirrors), tpmTarball)
    # The imported-record binding (``importedProvisioningMetadataDigest``)
    # is kept alongside, and still binds a record no tool use carries.
    var importing = tarballBase.projectInterface
    var record = InterfaceProvisioningContribution(
      targetPackage: "unusedPackage", targetInterfaceFingerprint:
        repeat('c', 64), contributor: "github:example/catalog",
      imported: true, tarballProvisioning: @[tarballEntry()])
    importing.provisioningContributions = @[record]
    let importingKey = toolIdentityCacheKey(artifactFor(importing), tpmTarball)
    let importingFingerprint = artifactFor(importing).interfaceFingerprint
    record.tarballProvisioning[0].prunePaths = @["doc"]
    importing.provisioningContributions = @[record]
    check artifactFor(importing).interfaceFingerprint == importingFingerprint
    check toolIdentityCacheKey(artifactFor(importing), tpmTarball) !=
      importingKey

  test "through the DSL projection the tool package's and the consumer's interface fingerprints never move, the key does, and location and declaration order move nothing":
    proc indexOf(name: string; packages: seq[PackageDef]): int =
      for i, pkg in packages:
        if pkg.packageName == name:
          return i
      raise newException(ValueError, "package not registered: " & name)
    var base = registeredPackages()
    let tool = indexOf("inPkgTool", base)
    base[tool].nixProvisioning = @[NixPackageProvisioningDef(
      selector: "nixpkgs#hello", executablePath: "bin/hello",
      nixpkgsRef: "github:NixOS/nixpkgs/0123", nixpkgsRev: "0123",
      nixpkgsNarHash: "sha256-AAAA", sourceFile: "packages/inpkg_tool.nim",
      sourceLine: 3)]
    base[tool].tarballProvisioning = @[TarballProvisioningDef(
      url: "https://example.invalid/inpkg-tool.tar.gz",
      sha256: repeat('a', 64), archiveType: "tar.gz",
      executablePath: "bin/inpkg-tool", stripComponents: 1,
      sourceFile: "packages/inpkg_tool.nim", sourceLine: 5)]
    base[tool].scoopProvisioning = @[ScoopProvisioningDef(bucket: "main",
      app: "inpkg-tool", version: "1.0.0", executablePath: "inpkg-tool.exe",
      sourceFile: "packages/inpkg_tool.nim", sourceLine: 7)]
    proc identities(packages: seq[PackageDef]): tuple[key, consumer,
        canonical: string] =
      let artifact = artifactFor(toProjectInterface(
        packages[indexOf("inPkgConsumer", packages)], packages))
      # The projection really carries the tool's own realizations.
      doAssert artifact.projectInterface.toolUses[0].tarballProvisioning.len == 1
      (key: toolIdentityCacheKey(artifact, tpmTarball, pathValue = ""),
       consumer: hx(artifact.interfaceFingerprint),
       canonical: canonicalPackageInterfaceFingerprint(
         packages[indexOf("inPkgTool", packages)], packages))
    let before = identities(base)
    template expectEdit(label: string; locationOnly: bool; body: untyped) =
      block:
        checkpoint(label)
        var packages {.inject.} = base
        body
        let after = identities(packages)
        check after.consumer == before.consumer
        check after.canonical == before.canonical
        if locationOnly:
          check after.key == before.key
        else:
          check after.key != before.key
    for name, value in base[tool].nixProvisioning[0].fieldPairs:
      expectEdit("nix." & name, name in ["sourceFile", "sourceLine"]):
        for field, slot in packages[tool].nixProvisioning[0].fieldPairs:
          when field == name:
            slot = changed(slot)
    for name, value in base[tool].tarballProvisioning[0].fieldPairs:
      expectEdit("tarball." & name, name in ["sourceFile", "sourceLine"]):
        for field, slot in packages[tool].tarballProvisioning[0].fieldPairs:
          when field == name:
            slot = changed(slot)
    for name, value in base[tool].scoopProvisioning[0].fieldPairs:
      expectEdit("scoop." & name, name in ["sourceFile", "sourceLine"]):
        for field, slot in packages[tool].scoopProvisioning[0].fieldPairs:
          when field == name:
            slot = changed(slot)
    # Declaring the tool package after the consumer instead of before.
    expectEdit("package declaration order", true):
      let moved = packages[tool]
      packages.delete(tool)
      packages.add(moved)

  test "the order of two eligible entries of one family is bound, because it decides which archive is realized":
    let ab = consumerWith(@[], @[realEntry(archiveA), realEntry(archiveB)], @[])
    let ba = consumerWith(@[], @[realEntry(archiveB), realEntry(archiveA)], @[])
    check ab.interfaceFingerprint == ba.interfaceFingerprint
    check toolIdentityCacheKey(ab, tpmTarball) !=
      toolIdentityCacheKey(ba, tpmTarball)
    check toolBuildIdentity(ab, tpmTarball, storeRoot = freshDir("order")).
      marker == archiveA.marker
    check toolBuildIdentity(ba, tpmTarball, storeRoot = freshDir("order")).
      marker == archiveB.marker

  test "the CLI build path re-realizes an edit of only the alias, the prune list, cpu or os -- warm, cold and after a prewarm -- and serves X again for X":
    let x = consumerWith(@[], hostSpecificThenCatchAll(), @[])
    let keyX = toolIdentityCacheKey(x, tpmTarball)
    for edit in edits:
      checkpoint(edit.field)
      let y = edited(edit)
      check y.interfaceFingerprint == x.interfaceFingerprint
      check toolIdentityCacheKey(y, tpmTarball) != keyX
      # Warm: X is in this process's table.
      let warmDir = freshDir("warm")
      let idX = warmResolveAndWriteIdentity(x, warmDir, tpmTarball).identity
      check idX.marker == archiveA.marker
      check not edit.realizedY(idX)
      let resolvesBefore = warmBuildCacheCounters.toolIdentityResolves
      let warmY = warmResolveAndWriteIdentity(y, warmDir, tpmTarball).identity
      check warmBuildCacheCounters.toolIdentityResolves == resolvesBefore + 1
      check edit.realizedY(warmY)
      # Cold: X only on disk.
      let coldDir = freshDir("cold")
      let coldIdX =
        warmResolveAndWriteIdentity(x, coldDir, tpmTarball).identity
      forgetWarmBuildCaches()
      check edit.realizedY(
        warmResolveAndWriteIdentity(y, coldDir, tpmTarball).identity)
      # Prewarm: the daemon parent loaded X's stamps before the request.
      let prewarmDir = freshDir("prewarm")
      discard warmResolveAndWriteIdentity(x, prewarmDir, tpmTarball)
      forgetWarmBuildCaches()
      check prewarmDaemonParentCaches(prewarmDir).toolIdentities >= 1
      check edit.realizedY(
        warmResolveAndWriteIdentity(y, prewarmDir, tpmTarball).identity)
      # Back to X: X's key, X's identity, and the stamp names X again.
      let backX = warmResolveAndWriteIdentity(x, warmDir, tpmTarball).identity
      check toolIdentityCacheKey(x, tpmTarball) == keyX
      check backX.profiles[0].profileFingerprint ==
        idX.profiles[0].profileFingerprint
      check not edit.realizedY(backX)
      check readFile(warmDir / "tool-identity-cache" / "tarball.current-key").
        strip() == keyX
      forgetWarmBuildCaches()
      let coldX = warmResolveAndWriteIdentity(x, coldDir, tpmTarball).identity
      check coldX.profiles[0].profileFingerprint ==
        coldIdX.profiles[0].profileFingerprint
      check not edit.realizedY(coldX)
      forgetWarmBuildCaches()

  test "a location-only change is served from the warm table, not re-resolved":
    let x = consumerWith(@[], hostSpecificThenCatchAll(), @[])
    var moved = hostSpecificThenCatchAll()
    for entry in moved.mitems:
      entry.location = SourceLocation(file: "packages/elsewhere.nim",
        line: 90)
    let y = consumerWith(@[], moved, @[])
    check toolIdentityCacheKey(y, tpmTarball) ==
      toolIdentityCacheKey(x, tpmTarball)
    let outDir = freshDir("location")
    let idX = warmResolveAndWriteIdentity(x, outDir, tpmTarball).identity
    let resolvesBefore = warmBuildCacheCounters.toolIdentityResolves
    let idY = warmResolveAndWriteIdentity(y, outDir, tpmTarball).identity
    check warmBuildCacheCounters.toolIdentityResolves == resolvesBefore
    check idY.profiles[0].profileFingerprint ==
      idX.profiles[0].profileFingerprint
    forgetWarmBuildCaches()

  test "the realized prefix moves with the alias and the prune list, and an older engine's prefix of another layout is refused":
    let x = consumerWith(@[], @[realEntry(archiveA)], @[])
    var aliased = x.projectInterface
    aliased.toolUses[0].tarballProvisioning[0].executableAlias = alias
    var pruned = x.projectInterface
    pruned.toolUses[0].tarballProvisioning[0].prunePaths = @["share/doc"]
    let store = freshDir("prefix")
    let idX = toolBuildIdentity(x, tpmTarball, storeRoot = store)
    let idAliased = toolBuildIdentity(artifactFor(aliased), tpmTarball,
      storeRoot = store)
    let idPruned = toolBuildIdentity(artifactFor(pruned), tpmTarball,
      storeRoot = store)
    check idAliased.profiles[0].selectedStorePath !=
      idX.profiles[0].selectedStorePath
    check idPruned.profiles[0].selectedStorePath !=
      idX.profiles[0].selectedStorePath
    check idAliased.aliasPresent(alias)
    check not idPruned.docPresent()
    # The store index and the sealed receipt name the path realize used.
    for moved in [idAliased, idPruned]:
      let prefix = moved.profiles[0].selectedStorePath
      check readReceiptFile(prefix / ".repro-receipt").realizedPath ==
        relativePath(prefix, store).replace('\\', '/')
    for moved in [idAliased, idPruned]:
      check moved.profiles[0].profileFingerprint !=
        idX.profiles[0].profileFingerprint
      check moved.actionIdentities[0].actionFingerprint !=
        idX.actionIdentities[0].actionFingerprint
    # X again in the same store: X's prefix, whole and without the alias.
    let again = toolBuildIdentity(x, tpmTarball, storeRoot = store)
    check again.profiles[0].selectedStorePath ==
      idX.profiles[0].selectedStorePath
    check again.docPresent()
    check not again.aliasPresent(alias)
    # The alias and the prune list cannot be mistaken for one another: an
    # alias named like the prune tag, and a prune list that begins with the
    # alias tag, each get a prefix of their own.
    proc variant(aliasName: string; prunes: seq[string]): string =
      var pi = x.projectInterface
      pi.toolUses[0].tarballProvisioning[0].executableAlias = aliasName
      pi.toolUses[0].tarballProvisioning[0].prunePaths = prunes
      toolBuildIdentity(artifactFor(pi), tpmTarball, storeRoot = store).
        profiles[0].selectedStorePath
    check variant("prunePaths", @["share/doc"]) !=
      variant("", @["prunePaths", "share/doc"])
    check variant("share", @[]) != variant("", @["executableAlias", "share"])

    # An older engine keyed the prefix without the prune list, so a PRUNED
    # realization may sit where the unpruned plan now resolves. Its receipt
    # says so; it is refused rather than served with files missing.
    let legacy = freshDir("legacy")
    let whole = toolBuildIdentity(x, tpmTarball, storeRoot = legacy)
    let prefix = whole.profiles[0].selectedStorePath
    let receipt = readFile(receiptPath(prefix))
    removeDir(prefix / "share" / "doc")
    writeFile(receiptPath(prefix), receipt.replace("\"prunePaths\": []",
      "\"prunePaths\": [\"share/doc\"]"))
    check "\"share/doc\"" in readFile(receiptPath(prefix))
    var refusal = ""
    try:
      discard toolBuildIdentity(x, tpmTarball, storeRoot = legacy)
    except OSError as err:
      refusal = err.msg
    check "was realized with prunePaths" in refusal
    # ... and likewise an alias the plan does not declare.
    writeFile(receiptPath(prefix), receipt.replace("\"executableAlias\": \"\"",
      "\"executableAlias\": \"" & alias & "\""))
    check alias in readFile(receiptPath(prefix))
    refusal = ""
    try:
      discard toolBuildIdentity(x, tpmTarball, storeRoot = legacy)
    except OSError as err:
      refusal = err.msg
    check "was realized with executableAlias" in refusal
    # A receipt that records neither (written before either existed) is not
    # evidence of another layout and is still accepted.
    writeFile(receiptPath(prefix), "{\"installMethod\": \"tarball\"}")
    check toolBuildIdentity(x, tpmTarball, storeRoot = legacy).
      profiles[0].selectedStorePath == prefix

  removeDir(fixtureRoot)
