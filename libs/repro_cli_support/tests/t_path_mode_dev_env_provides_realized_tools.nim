## A path-mode dev environment provides the tools the path-mode resolver
## realizes, and leaves alone the ones the caller's PATH already supplies.
##
## THE DEFECT. Under ``defaultToolProvisioning "path"`` the resolver looks a
## declared tool up on the caller's PATH and, when it is not there and its
## package declares a release archive, realizes it from that archive -- which
## is how ``repro build`` obtains it. The activation surfaces (``repro exec``,
## ``repro shell``, the shell hook) skipped path mode outright and contributed
## no PATH entry at all, so they provided less than the build they are the
## environment for. reprobuild's own Windows shell, entered from a minimal
## PATH, had neither ``just`` nor anything else its ``uses:`` declares, and
## ``just lint`` could not start.
##
## THE TWO CASES, and why both are needed:
##
##   1. A tool ABSENT from the caller's PATH, with an archive, is realized and
##      its directory is prepended. Before the fix there was no op at all.
##   2. A tool PRESENT on the caller's PATH contributes nothing, although it
##      has an archive too. This is the half of path mode's contract that must
##      not move: "resolve against the caller's PATH" -- a fix that simply
##      realized every declared tool would pass case 1 and fail here.
##
## The recipe also declares a third tool that is on no PATH and has nothing to
## be realized from -- reprobuild's own recipe has several (`runquotad`, the
## source-library producers). That makes the batch resolution fail and the
## activation fall back to resolving tool by tool, which is the path a real
## Windows shell takes; case 1 then also holds that one absent tool does not
## cost the shell the tools that WERE realized.
##
## No mocks. The archive is a real file served through the resolver's own
## ``file://`` arm, realized into a real tool store under a temporary root, and
## the ops are the ones ``repro dev-env export`` renders.

import std/[os, strutils, tempfiles, unittest]

import repro_cli_support
import repro_interface_artifacts
import repro_provider_runtime
import repro_local_store
import repro_tool_profiles
import repro_core/paths

const ExeSuffix = when defined(windows): ".exe" else: ""

proc writeExecutable(path, body: string) =
  createDir(parentDir(path))
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc rawTarballUse(root, name: string): InterfaceToolUse =
  ## `name`, declared with one raw-executable archive served from `root`.
  let payload = root / "archives" / (name & "-payload")
  writeExecutable(payload, "#!/bin/sh\necho " & name & "\n")
  result = InterfaceToolUse(rawConstraint: name, packageSelector: name,
    executableName: name)
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    url: "file://" & payload, sha256: fileSha256Hex(payload), archiveType: "raw",
    executablePath: name & ExeSuffix, packageId: name & "@1",
    cpu: "any", os: "any", lockIdentity: "fixture:" & name & "@1")]

when defined(windows):
  import std/winlean

proc removeTree(root: string) =
  ## A realized prefix is made read-only, and on Windows the activation routes
  ## it through a short directory junction under the store. The junctions are
  ## unlinked first (never recursed through), then everything is made writable
  ## and removed.
  ## Everything goes through `extendedPath`: the store's action-cache records
  ## sit past Windows' MAX_PATH under a temporary directory.
  let root = extendedPath(root)
  if not dirExists(root):
    return
  var links: seq[string] = @[]
  for path in walkDirRec(root, yieldFilter = {pcLinkToDir}):
    links.add(path)
  for link in links:
    when defined(windows):
      discard setFileAttributesW(newWideCString(link), FILE_ATTRIBUTE_NORMAL)
      discard removeDirectoryW(newWideCString(link))
    else:
      removeFile(link)
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    try:
      setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError:
      discard
  removeDir(root)

proc listing(dir: string): seq[string] =
  for kind, path in walkDir(dir):
    result.add(path.extractFilename)

proc prependedPaths(ops: openArray[DevEnvShellOp]): seq[string] =
  for op in ops:
    if op.kind == deskPrependPath and op.name == "PATH":
      result.add(op.value)

suite "path-mode dev environment":
  setup:
    let root = createTempDir("repro-path-mode-dev-env-", "")
    let savedPath = getEnv("PATH")
    let savedStore = getEnv(StoreRootEnvVar)
    let savedMode = getEnv("REPRO_TOOL_PROVISIONING")
    let savedCacheDisable = getEnv("REPRO_CACHE_DISABLE")
    putEnv(StoreRootEnvVar, root / "store")
    # No shared cache: a fixture prefix must never be published anywhere.
    putEnv("REPRO_CACHE_DISABLE", "1")
    delEnv("REPRO_TOOL_PROVISIONING")
    # The caller's PATH holds exactly one of the two tools.
    let ambient = root / "ambient"
    writeExecutable(ambient / ("present" & ExeSuffix), "#!/bin/sh\nexit 0\n")
    putEnv("PATH", ambient)
    let outDir = root / "out"
    createDir(outDir)
    let interfacePath = outDir / "project-interface.rbsz"
    writeInterfaceArtifact(interfacePath, artifactFor(ProjectInterface(
      projectName: "consumer", packageName: "consumer",
      defaultToolProvisioning: "path",
      toolUses: @[rawTarballUse(root, "absent"),
                  rawTarballUse(root, "present"),
                  InterfaceToolUse(rawConstraint: "unprovisioned",
                    packageSelector: "unprovisioned",
                    executableName: "unprovisioned")])))

  teardown:
    putEnv("PATH", savedPath)
    if savedStore.len > 0: putEnv(StoreRootEnvVar, savedStore)
    else: delEnv(StoreRootEnvVar)
    if savedMode.len > 0: putEnv("REPRO_TOOL_PROVISIONING", savedMode)
    if savedCacheDisable.len > 0: putEnv("REPRO_CACHE_DISABLE", savedCacheDisable)
    else: delEnv("REPRO_CACHE_DISABLE")
    removeTree(root)

  test "a tool missing from PATH is realized and prepended":
    let prepended = prependedPaths(devEnvToolShellOpsAt(interfacePath, outDir))
    checkpoint("prepended: " & $prepended)
    var providing: seq[string] = @[]
    for dir in prepended:
      checkpoint(dir & ": " & $listing(dir))
      if fileExists(dir / ("absent" & ExeSuffix)):
        providing.add(dir)
    check providing.len == 1

  test "a tool already on PATH contributes nothing":
    let prepended = prependedPaths(devEnvToolShellOpsAt(interfacePath, outDir))
    checkpoint("prepended: " & $prepended)
    for dir in prepended:
      check not fileExists(dir / ("present" & ExeSuffix))
      check os.normalizedPath(dir) != os.normalizedPath(ambient)
