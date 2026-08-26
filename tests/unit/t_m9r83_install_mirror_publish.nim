## M9.R.83 — hashed install-mirror emit side.
##
## Pins the producer-side store publication path: a completed install
## mirror is published through the Layer-2 store, the sidecar records
## the store-registered relative path, hashed reads resolve through the
## sidecar, and legacy mode continues to use the mutable mirror path.

import std/[algorithm, envvars, os, osproc, streams, strutils, tempfiles,
  unittest]

import repro_local_store
import repro_project_dsl/install_mirror_resolver
import repro_project_dsl/install_mirror_publish

import "../../apps/repro-install-mirror-publish/repro_install_mirror_publish"

const MirrorStoreRootEnv = "REPRO_STORE_ROOT"
const WritePermissions = {fpUserWrite, fpGroupWrite, fpOthersWrite}

template withEnv(name, value: string; body: untyped) =
  block:
    let oldSet = existsEnv(name)
    let oldValue = getEnv(name)
    putEnv(name, value)
    try:
      body
    finally:
      if oldSet:
        putEnv(name, oldValue)
      else:
        delEnv(name)

template withoutEnv(name: string; body: untyped) =
  block:
    let oldSet = existsEnv(name)
    let oldValue = getEnv(name)
    delEnv(name)
    try:
      body
    finally:
      if oldSet:
        putEnv(name, oldValue)
      else:
        delEnv(name)

proc runBashScript(scriptPath: string): tuple[exitCode: int; output: string] =
  let process = startProcess("bash", args = @["-e", scriptPath],
    options = {poUsePath, poStdErrToStdOut})
  result.output = process.outputStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()

proc addWritePermissions(path: string) =
  if not fileExists(path) and not dirExists(path):
    return
  var permissions = getFilePermissions(path)
  for permission in WritePermissions:
    permissions.incl(permission)
  setFilePermissions(path, permissions)

proc makeTreeWritable(root: string) =
  if not dirExists(root):
    return
  var dirs = @[root]
  for entry in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile, pcDir},
                          relative = true):
    let path = root / entry
    if dirExists(path):
      dirs.add(path)
    else:
      addWritePermissions(path)
  dirs.sort(proc (a, b: string): int = cmp(b.len, a.len))
  for dir in dirs:
    addWritePermissions(dir)

proc removeScratch(root: string) =
  try:
    makeTreeWritable(root)
    removeDir(root)
  except OSError:
    discard

proc assertNoWritePermissions(path: string) =
  let permissions = getFilePermissions(path)
  check fpUserWrite notin permissions
  check fpGroupWrite notin permissions
  check fpOthersWrite notin permissions

proc writeTinyMirror(root: string) =
  createDir(root / "usr" / "bin")
  createDir(root / "usr" / "lib")
  writeFile(root / "usr" / "bin" / "hello", "hello\n")
  writeFile(root / "usr" / "lib" / "libhello.so", "library\n")
  var helloPermissions = getFilePermissions(root / "usr" / "bin" / "hello")
  helloPermissions.incl(fpUserRead)
  helloPermissions.incl(fpUserWrite)
  when not defined(windows):
    helloPermissions.incl(fpUserExec)
    helloPermissions.incl(fpGroupRead)
    helloPermissions.incl(fpGroupWrite)
    helloPermissions.incl(fpGroupExec)
    helloPermissions.incl(fpOthersRead)
    helloPermissions.incl(fpOthersWrite)
    helloPermissions.incl(fpOthersExec)
  setFilePermissions(root / "usr" / "bin" / "hello", helloPermissions)

suite "M9.R.83 install-mirror store publication":

  test "publishInstallMirrorToStore writes receipt, index row, and sidecar":
    let scratch = createTempDir("m9r83-publish-", "")
    defer: removeScratch(scratch)
    let recipesRoot = scratch / "recipes"
    let sourceRoot = recipesRoot / "tiny" / ".repro" / "output" / "install"
    let storeRoot = scratch / "store"
    writeTinyMirror(sourceRoot)

    withEnv(MirrorStoreRootEnv, storeRoot):
      let published = publishInstallMirrorToStore(recipesRoot, "tiny",
        "1.0.0", sourceRoot, storeRoot)
      check published.realizationHashHex.len == 64
      check published.storeRelativePath ==
        installMirrorStoreRelativePath("tiny", "1.0.0",
          published.realizationHashHex)
      check published.storeRelativePath.endsWith(
        published.realizationHashHex[0 ..< 16])
      check not published.storeRelativePath.endsWith(
        published.realizationHashHex)
      check fileExists(published.absolutePath / "usr" / "bin" / "hello")

      let receipt = readReceiptFile(published.absolutePath / ReceiptFileName)
      check receipt.packageName == "tiny"
      check receipt.version == "1.0.0"
      check prefixIdHex(receipt.realizationHash) ==
        published.realizationHashHex
      check receipt.realizedPath == published.storeRelativePath

      var store = openStore(storeRoot)
      defer: store.close()
      let row = store.lookupPrefix(receipt.realizationHash)
      check row.found
      check row.row.realizedPath == published.storeRelativePath

      let info = readRealizationInfoFile(recipesRoot, "tiny")
      check info.platformTag == currentRealizationPlatformTag()
      check info.version == "1.0.0"
      check info.realizationHashHex == published.realizationHashHex
      check info.storeRelativePath == published.storeRelativePath

      withEnv(InstallMirrorModeEnvVar, "hashed"):
        check packageInstallMirrorRoot(recipesRoot, "tiny") ==
          published.absolutePath
      withEnv(InstallMirrorModeEnvVar, "legacy"):
        check packageInstallMirrorRoot(recipesRoot, "tiny").endsWith(
          "/tiny/.repro/output/install")

  test "publishInstallMirrorToStore makes store prefix read-only":
    let scratch = createTempDir("m9r83-readonly-", "")
    defer: removeScratch(scratch)
    let recipesRoot = scratch / "recipes"
    let sourceRoot = recipesRoot / "tiny" / ".repro" / "output" / "install"
    let storeRoot = scratch / "store"
    writeTinyMirror(sourceRoot)

    withEnv(MirrorStoreRootEnv, storeRoot):
      let published = publishInstallMirrorToStore(recipesRoot, "tiny",
        "1.0.0", sourceRoot, storeRoot)
      let usrDir = published.absolutePath / "usr"
      let binDir = published.absolutePath / "usr" / "bin"
      let libDir = published.absolutePath / "usr" / "lib"
      let executable = binDir / "hello"
      let library = libDir / "libhello.so"

      for path in [published.absolutePath, usrDir, binDir, libDir,
                   executable, library]:
        assertNoWritePermissions(path)

      let executablePermissions = getFilePermissions(executable)
      check fpUserRead in executablePermissions
      when not defined(windows):
        check fpUserExec in executablePermissions
        check fpGroupRead in executablePermissions
        check fpGroupExec in executablePermissions
        check fpOthersRead in executablePermissions
        check fpOthersExec in executablePermissions

      addWritePermissions(published.absolutePath)
      addWritePermissions(usrDir)
      addWritePermissions(binDir)
      addWritePermissions(libDir)
      addWritePermissions(executable)
      addWritePermissions(library)
      for path in [published.absolutePath, usrDir, binDir, libDir,
                   executable, library]:
        let writablePermissions = getFilePermissions(path)
        check fpUserWrite in writablePermissions

      let republished = publishInstallMirrorToStore(recipesRoot, "tiny",
        "1.0.0", sourceRoot, storeRoot)
      check republished.absolutePath == published.absolutePath
      for path in [published.absolutePath, usrDir, binDir, libDir,
                   executable, library]:
        assertNoWritePermissions(path)

  test "malformed sidecar relative path is rejected":
    let scratch = createTempDir("m9r83-badrel-", "")
    defer: removeScratch(scratch)
    let recipesRoot = scratch / "recipes"
    let sidecar = realizationInfoPath(recipesRoot, "tiny")
    let hashHex = repeat("a", 64)
    createDir(parentDir(sidecar))
    writeFile(sidecar, "version=1.0.0\n" &
      "realization-hash=" & hashHex & "\n" &
      "store-relative-path=prefixes/tiny/1.0.0-" & repeat("b", 16) & "\n")
    let info = readRealizationInfoFile(recipesRoot, "tiny")
    check info.version == "1.0.0"
    check info.realizationHashHex == hashHex
    check info.storeRelativePath == ""
    check hashedDepMirrorRoot(recipesRoot, "tiny") == ""

  test "empty legacy sidecar is stale producer metadata":
    let scratch = createTempDir("m9r83-empty-sidecar-", "")
    defer: removeScratch(scratch)
    let recipesRoot = scratch / "recipes"
    let sidecar = realizationInfoPath(recipesRoot, "tiny")
    createDir(parentDir(sidecar))
    writeFile(sidecar, "")

    let info = readRealizationInfoFile(recipesRoot, "tiny")
    check info.platformTag.len == 0
    check info.version.len == 0
    check info.realizationHashHex.len == 0
    check info.storeRelativePath.len == 0
    check hashedDepMirrorRoot(recipesRoot, "tiny") == ""

    let legacyRoot = (recipesRoot / "tiny" / ".repro" / "output" /
      "install").replace("\\", "/")
    withEnv(InstallMirrorModeEnvVar, "hashed"):
      check packageInstallMirrorRoot(recipesRoot, "tiny") == legacyRoot

  test "CLI wrapper publishes and resolves through the sidecar":
    let scratch = createTempDir("m9r83-cli-", "")
    defer: removeScratch(scratch)
    let recipesRoot = scratch / "recipes"
    let sourceRoot = recipesRoot / "cli-tiny" / ".repro" / "output" /
      "install"
    let storeRoot = scratch / "store"
    writeTinyMirror(sourceRoot)

    withEnv(MirrorStoreRootEnv, storeRoot):
      check runInstallMirrorPublishCommand(@[
        "--recipes-root", recipesRoot,
        "--package", "cli-tiny",
        "--version", "2.0.0",
        "--source", sourceRoot,
      ]) == 0
      withEnv(InstallMirrorModeEnvVar, "hashed"):
        let resolved = packageInstallMirrorRoot(recipesRoot, "cli-tiny")
        check resolved.startsWith(storeRoot.replace("\\", "/") &
          "/prefixes/cli-tiny/2.0.0-")
        check fileExists(resolved / ReceiptFileName)

  test "emitted publish snippet is runtime-gated":
    let snippet = emitInstallMirrorStorePublish("/recipes", "pkg", "1.0",
      "/recipes/pkg/.repro/output/install")
    let sidecar = realizationInfoPath("/recipes", "pkg")
    check InstallMirrorPublishToolName in snippet
    check "REPRO_INSTALL_MIRROR_MODE" in snippet
    check "hashed-with-legacy-fallback" in snippet
    check "--source \"/recipes/pkg/.repro/output/install\"" in snippet
    check "platform=" & currentRealizationPlatformTag() in snippet
    check sidecar in snippet

  test "emitted default legacy snippet satisfies sidecar output only":
    let scratch = createTempDir("m9r84-legacy-sidecar-", "")
    defer: removeScratch(scratch)
    let recipesRoot = scratch / "recipes"
    let sourceRoot = recipesRoot / "legacy-tiny" / ".repro" / "output" /
      "install"
    let sidecar = realizationInfoPath(recipesRoot, "legacy-tiny")
    let scriptPath = scratch / "publish-legacy.sh"
    writeTinyMirror(sourceRoot)

    writeFile(scriptPath, emitInstallMirrorStorePublish(recipesRoot,
      "legacy-tiny", "1.0.0", sourceRoot))
    withoutEnv(InstallMirrorModeEnvVar):
      let run = runBashScript(scriptPath)
      check run.exitCode == 0
      checkpoint run.output

    check fileExists(sidecar)
    check getFileSize(sidecar) > 0
    let info = readRealizationInfoFile(recipesRoot, "legacy-tiny")
    check info.platformTag == currentRealizationPlatformTag()
    check info.version == ""
    check info.realizationHashHex == ""
    check info.storeRelativePath == ""
    withEnv(InstallMirrorModeEnvVar, "hashed"):
      check hashedDepMirrorRoot(recipesRoot, "legacy-tiny") == ""
