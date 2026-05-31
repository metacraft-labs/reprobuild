## M71 Phase A gate: local-only activation bundle format + writer.
##
## This intentionally stops before SSH, remote activation, and
## cross-host evaluation. It drives the public `repro home apply` path
## to create a real generation and realized prefix, then drives the
## internal CLI writer twice and decodes the CAS-resident bundle through
## the strict binary reader.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations
import repro_local_store

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc writeFixtureExe(path: string): string =
  when defined(windows):
    result =
      "@echo off\r\n" &
      "echo m71-fixture phase-a\r\n"
    writeFile(path, result)
  else:
    result =
      "#!/bin/sh\n" &
      "set -eu\n" &
      "echo m71-fixture phase-a\n"
    writeFile(path, result)
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

proc fileEntry(bundle: ActivationBundle; rel: string):
    tuple[found: bool; entry: ActivationBundleFileEntry] =
  for closure in bundle.prefixes:
    for entry in closure.files:
      if entry.relativePath == rel:
        return (true, entry)
  (false, ActivationBundleFileEntry())

proc bytesToString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

suite "M71 Phase A: local activation bundle format and writer":
  test "bundle writer is idempotent and captures realized prefix closure":
    let tempRoot = createTempDir("repro-m71-bundle-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard

    let stateDir = tempRoot / "state"
    let storeRoot = tempRoot / "store"
    let profileDir = tempRoot / "profile"
    let homeDir = tempRoot / "home"
    let fixtureDir = tempRoot / "fixture"
    createDir(stateDir)
    createDir(storeRoot)
    createDir(profileDir)
    createDir(homeDir)
    createDir(fixtureDir)

    writeFile(profileDir / "home.nim",
      "import repro_profile\n\n" &
      "profile \"m71-phase-a\":\n" &
      "  activity default:\n" &
      "    `m71-fixture`\n")

    let exeName = when defined(windows): "m71-fixture.cmd" else: "m71-fixture"
    let exePath = fixtureDir / exeName
    let exeContent = writeFixtureExe(exePath)

    let env = @[
      (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
      (k: "REPRO_HOME_STATE_DIR", v: stateDir),
      (k: "REPRO_STORE_ROOT", v: storeRoot),
      (k: "HOME", v: homeDir),
      (k: "USERPROFILE", v: homeDir),
      (k: "REPRO_HOST", v: "m71-source-host"),
      (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m71-fixture"),
      (k: "REPRO_TEST_PACKAGE_SOURCE", v: "m71-fixture=" & exePath)]

    let apply = runRepro(env, ["home", "apply"])
    check apply.exitCode == 0
    check apply.output.contains("applied generation ")

    let activeId = readCurrentGenerationId(stateDir)
    check activeId.len == 32
    let pointerFile = pointerPath(stateDir, activeId)
    check fileExists(pointerFile)
    let pointer = readPointerFile(pointerFile)
    check pointer.hostIdentity == "m71-source-host"
    check pointer.realizedPrefixIds.len == 1

    let first = runRepro(env, ["home", "__build-bundle"])
    check first.exitCode == 0
    let second = runRepro(env, ["home", "__build-bundle",
      "--generation=" & activeId, "--state-dir", stateDir,
      "--store-root", storeRoot])
    check second.exitCode == 0

    let digestHex = fieldValue(first.output, "bundleDigest")
    let bundlePath = fieldValue(first.output, "bundlePath")
    check digestHex == fieldValue(second.output, "bundleDigest")
    check bundlePath == fieldValue(second.output, "bundlePath")
    check fileExists(bundlePath)

    var store = openStore(storeRoot)
    defer: store.close()
    let bundleDigest = parsePrefixIdHex(digestHex)
    let bundleBytes = readCasBlob(store, bundleDigest)
    check bundleBytes.len > 0
    let bundle = decodeActivationBundleBytes(bundleBytes, bundlePath)

    check generationIdHex(bundle.sourceGenerationId) == activeId
    check bundle.hostIdentity == "m71-source-host"
    check bundle.activationTimestamp == pointer.activationTimestamp
    check bundle.pointerEnvelopeBytes.len > 0
    check decodePointerBytes(bundle.pointerEnvelopeBytes).hostIdentity ==
      "m71-source-host"
    check bundle.activationManifestBytes.len > 0
    check bundle.intentSnapshotBytes.len > 0
    check bundle.configurableGraphBytes.len > 0
    check bundle.configurableGraphBytes == bundle.activationManifestBytes
    check bundle.activationRuntimeKind == ActivationRuntimePlaceholderKind

    let manifest = decodeManifestBytes(bundle.activationManifestBytes)
    check manifest.realizedPackages.len == 1
    check manifest.realizedPackages[0].packageId == "m71-fixture"
    check manifest.realizedPackages[0].adapter == "path"
    let snapshot = decodeSnapshotBytes(bundle.intentSnapshotBytes)
    check snapshot.files.len == 1
    check snapshot.files[0].path == "home.nim"

    check bundle.prefixes.len == 1
    let closure = bundle.prefixes[0]
    check closure.prefixId == pointer.realizedPrefixIds[0]
    check closure.storeRelativePath.startsWith("prefixes/")
    check closure.receiptBytes.len > 0
    let receipt = decodeReceipt(closure.receiptBytes)
    check receipt.packageName == "m71-fixture"
    check receipt.adapter == "path"

    let receiptEntry = fileEntry(bundle, ReceiptFileName)
    check receiptEntry.found
    check receiptEntry.entry.contentBytes == closure.receiptBytes
    let exeEntry = fileEntry(bundle, exeName)
    check exeEntry.found
    check bytesToString(exeEntry.entry.contentBytes) == exeContent
