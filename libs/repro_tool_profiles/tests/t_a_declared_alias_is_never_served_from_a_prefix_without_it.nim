## A tarball package that declares an `executableAlias` is never served from
## a prefix realized without it.
##
## The defect: the local prefix directory was keyed on the archive, the
## executable path, the archive type and the strip depth -- not on the alias.
## Windows `python3` gained `executableAlias = "python3.exe"` after hosts had
## already realized it; on those hosts the prefix directory existed, held
## `python.exe`, and reuse checked nothing else, so the realization kept
## returning the old prefix and `python3` never reached PATH. Measured on a
## Windows workstation: the dev environment put the 2026-09-17 prefix on PATH
## and `command -v python3` answered nothing.
##
## The case realizes one archive twice into one store, first without an
## alias and then with one, exactly the order a host lived through. The
## second realization must expose the alias, and the first prefix must still
## be what a package without the alias resolves to.
##
## No mocks: the realizer's own `file://` arm, a real store under a temporary
## directory, the shared cache switched off so nothing is published.

import std/[os, tempfiles, unittest]

import repro_interface_artifacts
import repro_tool_profiles

const ExeSuffix = when defined(windows): ".exe" else: ""

proc writeExecutable(path, body: string) =
  createDir(parentDir(path))
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc rawUse(payload, alias: string): InterfaceToolUse =
  result = InterfaceToolUse(rawConstraint: "fixture-tool",
    packageSelector: "fixture-tool", executableName: "fixture-tool")
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    url: "file://" & payload, sha256: fileSha256Hex(payload),
    archiveType: "raw", executablePath: "fixture-tool" & ExeSuffix,
    executableAlias: alias, packageId: "fixture-tool@1",
    cpu: "any", os: "any", lockIdentity: "fixture:fixture-tool@1")]

proc removeTree(root: string) =
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    try: setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError: discard
  removeDir(root)

suite "a declared alias is part of the prefix it is served from":
  setup:
    let root = createTempDir("repro-alias-prefix-", "")
    let savedCacheDisable = getEnv("REPRO_CACHE_DISABLE")
    putEnv("REPRO_CACHE_DISABLE", "1")
    let payload = root / "archive" / "fixture-tool-payload"
    writeExecutable(payload, "#!/bin/sh\necho fixture\n")
    let store = root / "store"

  teardown:
    if savedCacheDisable.len > 0: putEnv("REPRO_CACHE_DISABLE", savedCacheDisable)
    else: delEnv("REPRO_CACHE_DISABLE")
    removeTree(root)

  test "adding an alias after a realization yields a prefix that has it":
    let alias = "fixture-tool-alias" & ExeSuffix
    let before = resolveTarballTool(rawUse(payload, ""), store)
    checkpoint("without alias: " & before.selectedStorePath)
    check fileExists(before.selectedStorePath / ("fixture-tool" & ExeSuffix))
    check not fileExists(before.selectedStorePath / alias)

    let after = resolveTarballTool(rawUse(payload, alias), store)
    checkpoint("with alias: " & after.selectedStorePath)
    check fileExists(after.selectedStorePath / alias)

    # The alias-free package still resolves to its own prefix.
    let again = resolveTarballTool(rawUse(payload, ""), store)
    check again.selectedStorePath == before.selectedStorePath
