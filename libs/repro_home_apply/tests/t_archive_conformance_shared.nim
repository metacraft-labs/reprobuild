## Both public conformance APIs must realize installation-class records and
## reject the same invalid primary binding. The exhaustive catalog sweep is
## tests/integration/t_stdlib_catalog_tarball_arms_realize.nim, covering every
## enrolled arm once through the common API. This replaces the former home
## ownership sweep; keeping both would download and extract every arm twice.
## Real tar, pinned file URLs, store
## and probes; no mocks or external network. The primary symlink fixture is
## POSIX-only because creating symlinks on Windows requires host privileges.
import std/[os, osproc, strutils, tempfiles, unittest]
import repro_interface_artifacts
import repro_tool_profiles
import repro_tool_profiles/tarball_conformance
import repro_home_apply/archive_conformance

proc cleanScratch(root: string) =
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    try: setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError: discard
  removeDir(root)

proc archiveFixture(root: string; linked: bool;
    extraTarget = ""): InterfaceTarballProvisioning =
  let source = root / "source"
  createDir(source / "payload")
  let exe = source / "payload" / "tool-real"
  writeFile(exe, "#!/bin/sh\necho shared-conformance\n")
  setFilePermissions(exe, {fpUserRead, fpUserWrite, fpUserExec})
  if linked:
    createSymlink("tool-real", source / "payload" / "tool")
  else:
    copyFileWithPermissions(exe, source / "payload" / "tool")
  if extraTarget.len > 0:
    createSymlink(extraTarget, source / "payload" / "extra")
  let archive = root / "fixture.tar.gz"
  let packed = execCmdEx("tar -czf " & quoteShell(archive) & " -C " &
    quoteShell(source) & " payload")
  doAssert packed.exitCode == 0, packed.output
  result = InterfaceTarballProvisioning(url: "file://" & archive,
    sha256: fileSha256Hex(archive), archiveType: "tar.gz",
    executablePath: "tool", cpu: "any", os: "any")
  result.detail.extractPath = "payload"

suite "home and recipe share tarball conformance":
  let savedCache = getEnv("REPRO_CACHE_DISABLE")
  putEnv("REPRO_CACHE_DISABLE", "1")
  test "flattened archive is checked by both APIs without ownership exemptions":
    let root = createTempDir("shared-conformance-", "")
    defer: cleanScratch(root)
    let arm = archiveFixture(root, false)
    let useDef = InterfaceToolUse(rawConstraint: "shared-conformance",
      packageSelector: "shared-conformance", executableName: "tool",
      tarballProvisioning: @[arm])
    let recipe = conformTarballArm(useDef, arm, root / "store")
    let home = conformArchiveArm("shared-conformance", arm, root / "store")
    checkpoint(recipe.detail)
    checkpoint(home.detail)
    check recipe.verdict == acvOk
    check home.verdict == aacOk
    check recipe.prefix == home.prefix
    check recipe.resolvedExecutablePath == home.resolvedExecutablePath

  when not defined(windows):
    test "extra executable links must stay inside on publication and reuse":
      for escapes in [false, true]:
        let root = createTempDir("shared-conformance-extra-", "")
        defer: cleanScratch(root)
        let outside = root / "outside"
        writeFile(outside, "#!/bin/sh\nexit 0\n")
        setFilePermissions(outside, {fpUserRead, fpUserWrite, fpUserExec})
        var arm = archiveFixture(root, false,
          if escapes: outside else: "tool-real")
        arm.detail.extraExecutables = @["extra"]
        let useDef = InterfaceToolUse(rawConstraint: "extra-conformance",
          packageSelector: "extra-conformance", executableName: "tool",
          tarballProvisioning: @[arm])
        let recipe = conformTarballArm(useDef, arm, root / "store")
        let home = conformArchiveArm("extra-conformance", arm, root / "store")
        if escapes:
          check recipe.verdict == acvRealizeFailed
          check home.verdict == aacRealizeFailed
          check "outside the realized prefix" in recipe.detail
          for receipt in walkFiles(root / "store" / "prefixes" / "*" /
              "*" / ".repro-receipt"):
            checkpoint receipt
            check false
        else:
          check recipe.verdict == acvOk
          check home.verdict == aacOk
          check recipe.prefix == home.prefix
          # Reusing a receipt must revalidate the current extra binding.
          setFilePermissions(recipe.prefix, {fpUserRead, fpUserWrite, fpUserExec})
          removeFile(recipe.prefix / "extra")
          createSymlink(outside, recipe.prefix / "extra")
          let warm = conformTarballArm(useDef, arm, root / "store")
          check warm.verdict == acvRealizeFailed
          check "outside the realized prefix" in warm.detail

    test "flattened archive primary symlink is rejected by both APIs":
      let root = createTempDir("shared-conformance-link-", "")
      defer: cleanScratch(root)
      let arm = archiveFixture(root, true)
      let useDef = InterfaceToolUse(rawConstraint: "shared-conformance",
        packageSelector: "shared-conformance", executableName: "tool",
        tarballProvisioning: @[arm])
      let recipe = conformTarballArm(useDef, arm, root / "store")
      let home = conformArchiveArm("shared-conformance", arm, root / "store")
      check recipe.verdict == acvRealizeFailed
      check home.verdict == aacRealizeFailed
      check recipe.detail == home.detail

  if savedCache.len > 0: putEnv("REPRO_CACHE_DISABLE", savedCache)
  else: delEnv("REPRO_CACHE_DISABLE")
