## M71 Phase B gate: local cross-host evaluation for activation bundles.
##
## This deliberately stays local-only. It drives the internal
## `repro home __build-bundle --evaluate` CLI twice with different
## explicit target facts, then decodes the resulting CAS bundles
## through the strict activation-bundle reader.

import std/[algorithm, os, osproc, streams, strtabs, strutils,
  tempfiles, unittest]

import repro_home_generations
import repro_local_store

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

const AllPackages = [
  "common-base",
  "not-macos-host",
  "linux-host-activity",
  "linux-predicate",
  "leaked-macos-build",
  "macos-host-activity",
  "macos-predicate",
  "leaked-linux-build"]

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc writeFixtureExe(path, packageId: string) =
  when defined(windows):
    writeFile(path,
      "@echo off\r\n" &
      "echo m71-phase-b " & packageId & "\r\n")
  else:
    writeFile(path,
      "#!/bin/sh\n" &
      "set -eu\n" &
      "echo m71-phase-b " & packageId & "\n")
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc runRepro(envOverrides: openArray[tuple[k, v: string]];
              args: openArray[string]):
    tuple[exitCode: int; output: string] =
  var processEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    processEnv[k] = v
  for kv in envOverrides:
    processEnv[kv.k] = kv.v
  let p = startProcess(reproBinary(), args = @args, env = processEnv,
    options = {poUsePath, poStdErrToStdOut})
  let stream = p.outputStream()
  var combined = ""
  while not stream.atEnd():
    let chunk = stream.readAll()
    if chunk.len == 0:
      break
    combined.add(chunk)
  let code = p.waitForExit()
  p.close()
  (exitCode: code, output: combined)

proc fieldValue(output, name: string): string =
  let prefix = name & ": "
  for line in output.splitLines():
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  doAssert false, "missing field " & name & " in output:\n" & output

proc parseHexNibble(c: char): int =
  case c
  of '0' .. '9': int(ord(c) - ord('0'))
  of 'a' .. 'f': int(ord(c) - ord('a') + 10)
  of 'A' .. 'F': int(ord(c) - ord('A') + 10)
  else:
    raise newException(ValueError, "not a hex nibble: " & $c)

proc parsePrefixIdHex(hex: string): PrefixIdBytes =
  doAssert hex.len == 64, "expected 64 hex chars, got " & $hex.len
  for i in 0 ..< 32:
    result[i] = byte((parseHexNibble(hex[2 * i]) shl 4) or
      parseHexNibble(hex[2 * i + 1]))

proc sortedPackageIds(manifest: ActivationManifest): seq[string] =
  for pkg in manifest.realizedPackages:
    result.add(pkg.packageId)
  result.sort()

proc sortedResourceAddresses(manifest: ActivationManifest): seq[string] =
  for binding in manifest.resourceBindings:
    if binding.resourceKind.len > 0:
      result.add(binding.resourceAddress)
  result.sort()

proc readBundleManifest(storeRoot, output: string):
    tuple[bundle: ActivationBundle; manifest: ActivationManifest] =
  let digestHex = fieldValue(output, "bundleDigest")
  let bundlePath = fieldValue(output, "bundlePath")
  check fileExists(bundlePath)
  var store = openStore(storeRoot)
  defer:
    try: store.close() except CatchableError: discard
  let bundleDigest = parsePrefixIdHex(digestHex)
  let bundleBytes = readCasBlob(store, bundleDigest)
  let bundle = decodeActivationBundleBytes(bundleBytes, bundlePath)
  let manifest = decodeManifestBytes(bundle.activationManifestBytes)
  (bundle: bundle, manifest: manifest)

suite "M71 Phase B: local cross-host activation-bundle evaluation":
  test "explicit target facts select host activities, predicates, packages, and resources":
    let tempRoot = createTempDir("repro-m71-cross-host-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard

    let profileDir = tempRoot / "profile"
    let fixtureDir = tempRoot / "fixtures"
    createDir(profileDir)
    createDir(fixtureDir)

    writeFile(profileDir / "home.nim",
      "import repro/profile\n\n" &
      "profile \"m71-phase-b\":\n" &
      "  activity default:\n" &
      "    common-base\n" &
      "    when host != \"target-macos\":\n" &
      "      not-macos-host\n\n" &
      "  activity linux_target:\n" &
      "    linux-host-activity\n" &
      "    when linux and x86_64 and host == \"target-linux\":\n" &
      "      linux-predicate\n" &
      "    when macos:\n" &
      "      leaked-macos-build\n\n" &
      "  activity macos_target:\n" &
      "    macos-host-activity\n" &
      "    when macos and arm64 and host in [\"target-macos\"]:\n" &
      "      macos-predicate\n" &
      "    when linux:\n" &
      "      leaked-linux-build\n\n" &
      "  resources:\n" &
      "    when linux and x86_64 and host == \"target-linux\":\n" &
      "      fs.managedBlock linuxResource:\n" &
      "        hostFile = \"~/.m71-phase-b-resource\"\n" &
      "        blockId = \"m71-linux\"\n" &
      "        content = \"target-linux resource\"\n" &
      "    when macos and arm64 and host in [\"target-macos\"]:\n" &
      "      fs.managedBlock macosResource:\n" &
      "        hostFile = \"~/.m71-phase-b-resource\"\n" &
      "        blockId = \"m71-macos\"\n" &
      "        content = \"target-macos resource\"\n\n" &
      "  hosts:\n" &
      "    \"target-linux\": [linux_target]\n" &
      "    \"target-macos\": [macos_target]\n")

    var packageSourceEntries: seq[string]
    for packageId in AllPackages:
      let exeName = when defined(windows): packageId & ".cmd" else: packageId
      let exePath = fixtureDir / exeName
      writeFixtureExe(exePath, packageId)
      packageSourceEntries.add(packageId & "=" & exePath)

    let baseEnv = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: AllPackages.join(",")),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: packageSourceEntries.join(";"))]

    let linuxStateDir = tempRoot / "linux-state"
    let linuxStoreRoot = tempRoot / "linux-store"
    let linuxHomeDir = tempRoot / "linux-home"
    createDir(linuxHomeDir)
    let linux = runRepro(baseEnv, [
      "home", "__build-bundle",
      "--evaluate",
      "--target-host", "target-linux",
      "--target-platform", "linux",
      "--target-arch", "x86_64",
      "--target-wsl=false",
      "--profile-dir", profileDir,
      "--state-dir", linuxStateDir,
      "--store-root", linuxStoreRoot,
      "--home-dir", linuxHomeDir])
    check linux.exitCode == 0
    check linux.output.contains("generationId: ")
    check linux.output.contains("bundleDigest: ")
    check linux.output.contains("bundlePath: ")

    let macosStateDir = tempRoot / "macos-state"
    let macosStoreRoot = tempRoot / "macos-store"
    let macosHomeDir = tempRoot / "macos-home"
    createDir(macosHomeDir)
    let macos = runRepro(baseEnv, [
      "home", "__build-bundle",
      "--evaluate",
      "--target-host", "target-macos",
      "--target-platform", "macos",
      "--target-arch", "arm64",
      "--profile-dir", profileDir,
      "--state-dir", macosStateDir,
      "--store-root", macosStoreRoot,
      "--home-dir", macosHomeDir])
    check macos.exitCode == 0

    let linuxDecoded = readBundleManifest(linuxStoreRoot, linux.output)
    let macosDecoded = readBundleManifest(macosStoreRoot, macos.output)

    check fieldValue(linux.output, "generationId") !=
      fieldValue(macos.output, "generationId")
    check linuxDecoded.bundle.hostIdentity == "target-linux"
    check macosDecoded.bundle.hostIdentity == "target-macos"
    check decodePointerBytes(linuxDecoded.bundle.pointerEnvelopeBytes)
      .hostIdentity == "target-linux"
    check decodePointerBytes(macosDecoded.bundle.pointerEnvelopeBytes)
      .hostIdentity == "target-macos"

    check sortedPackageIds(linuxDecoded.manifest) == @[
      "common-base",
      "linux-host-activity",
      "linux-predicate",
      "not-macos-host"]
    check sortedPackageIds(macosDecoded.manifest) == @[
      "common-base",
      "macos-host-activity",
      "macos-predicate"]
    check "leaked-macos-build" notin sortedPackageIds(linuxDecoded.manifest)
    check "leaked-linux-build" notin sortedPackageIds(macosDecoded.manifest)

    check sortedResourceAddresses(linuxDecoded.manifest) == @[
      "linuxResource"]
    check sortedResourceAddresses(macosDecoded.manifest) == @[
      "macosResource"]

    check fileExists(linuxHomeDir / ".m71-phase-b-resource")
    check readFile(linuxHomeDir / ".m71-phase-b-resource").contains(
      "target-linux resource")
    check fileExists(macosHomeDir / ".m71-phase-b-resource")
    check readFile(macosHomeDir / ".m71-phase-b-resource").contains(
      "target-macos resource")
