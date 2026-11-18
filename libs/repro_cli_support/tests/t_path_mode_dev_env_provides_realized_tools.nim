## A path-mode dev environment is the environment of a path-mode build: it
## takes from the caller's PATH what the build takes from it, and realizes
## nothing the build would not.
##
## HISTORY. Under ``defaultToolProvisioning "path"`` the resolver used to look
## a declared tool up on the caller's PATH and, when it was not there and its
## package declared a release archive, realize it from that archive. The
## activation surfaces (``repro exec``, ``repro shell``, the shell hook) were
## taught to contribute those realized directories. On 2026-11-17 the
## operator made path mode strictly PATH-only (reprobuild-pm issue
## 2026-11-12-per-mode-fallback-semantics-disagree, option (b)): a tool absent
## from PATH fails the build, naming the remedy, and is never realized from
## an archive or Nix. The activation follows the build.
##
## THE CASES:
##
##   1. A tool ABSENT from the caller's PATH, although its package declares an
##      archive, is NOT realized: no directory providing it is prepended, and
##      the diagnostic records it as unresolved with the path-mode remedy.
##   2. A tool PRESENT on the caller's PATH contributes nothing, although it
##      has an archive too: "resolve against the caller's PATH".
##   3. In tarball mode the same recipe's archive IS realized and prepended,
##      and a tool that cannot be realized does not cost the shell the ones
##      that were (the per-tool retry), even when the diagnostic file cannot
##      be written.
##
## The recipe also declares a third tool that is on no PATH and has nothing to
## be realized from -- reprobuild's own recipe has several (`runquotad`, the
## source-library producers). Together with the absent tool that makes the
## batch resolution fail and the activation fall back to resolving tool by
## tool, which is the path a real Windows shell takes.
##
## The mixed-resolution case also checks the diagnostic's actual path/hash
## and probe output/status, including a nonzero probe, while the incomplete
## environment must publish no complete identity or cache marker.
##
## No mocks. Tool payloads are copies of this native test executable with a
## bounded --version mode; neither shell scripts named .exe nor mocked probes
## stand in for a Windows process. The archive is a real file served through the resolver's own
## ``file://`` arm, realized into a real tool store under a temporary root, and
## the ops are the ones ``repro dev-env export`` renders.

import std/[algorithm, json, os, sequtils, strutils, tempfiles, unittest]

import repro_cli_support
import repro_interface_artifacts
import repro_provider_runtime
import repro_local_store
import repro_tool_profiles
import repro_tool_profiles/executable_evidence
import repro_core/paths

const ExeSuffix = when defined(windows): ".exe" else: ""

if commandLineParams() == @["--version"]:
  let counter = getEnv("REPRO_TEST_TOOL_PROBE_COUNTER")
  if counter.len > 0:
    let count = if fileExists(counter): parseInt(readFile(counter)) else: 0
    writeFile(counter, $(count + 1))
  echo "fixture-tool 1.0"
  quit(if getAppFilename().extractFilename.startsWith("probe-fails"): 7 else: 0)

proc writeExecutable(path: string) =
  createDir(parentDir(path))
  copyFile(getAppFilename(), path)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc rawTarballUse(root, name: string): InterfaceToolUse =
  ## `name`, declared with one raw-executable archive served from `root`.
  let payload = root / "archives" / (name & "-payload")
  writeExecutable(payload)
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
    let savedProbeCounter = getEnv("REPRO_TEST_TOOL_PROBE_COUNTER")
    delEnv("REPRO_TEST_TOOL_PROBE_COUNTER")
    putEnv(StoreRootEnvVar, root / "store")
    # No shared cache: a fixture prefix must never be published anywhere.
    putEnv("REPRO_CACHE_DISABLE", "1")
    delEnv("REPRO_TOOL_PROVISIONING")
    # The caller's PATH holds exactly one of the two archived tools, and the
    # tool whose version probe fails.
    let ambient = root / "ambient"
    writeExecutable(ambient / ("present" & ExeSuffix))
    writeExecutable(ambient / ("probe-fails" & ExeSuffix))
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
    else: delEnv("REPRO_TOOL_PROVISIONING")
    if savedCacheDisable.len > 0: putEnv("REPRO_CACHE_DISABLE", savedCacheDisable)
    else: delEnv("REPRO_CACHE_DISABLE")
    if savedProbeCounter.len > 0:
      putEnv("REPRO_TEST_TOOL_PROBE_COUNTER", savedProbeCounter)
    else: delEnv("REPRO_TEST_TOOL_PROBE_COUNTER")
    removeTree(root)

  test "a tool missing from PATH is not realized from its archive":
    let prepended = prependedPaths(devEnvToolShellOpsAt(interfacePath, outDir))
    checkpoint("prepended: " & $prepended)
    for dir in prepended:
      checkpoint(dir & ": " & $listing(dir))
      check not fileExists(dir / ("absent" & ExeSuffix))
    let doc = parseFile(outDir / "path-only-tool-identities.inspect.json")
    let absent = doc["unresolvedToolUses"].getElems.filterIt(
      it{"packageSelector"}.getStr() == "absent")
    require absent.len == 1
    let reason = absent[0]{"reason"}.getStr()
    checkpoint("reason: " & reason)
    check "was not found in PATH" in reason
    check "--tool-provisioning=tarball" in reason
    check "per-tool provisioning override" in reason

  test "in tarball mode the same archive is realized and prepended":
    putEnv("REPRO_TOOL_PROVISIONING", "tarball")
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

  test "mixed fallback replaces stale inspection with actual partial observations":
    var mixed = readInterfaceArtifact(interfacePath).projectInterface
    # On PATH (setup), so path mode takes it there and probes it.
    mixed.toolUses.add(InterfaceToolUse(rawConstraint: "probe-fails",
      packageSelector: "probe-fails", executableName: "probe-fails"))
    var complete = mixed
    complete.toolUses = complete.toolUses.filterIt(it.packageSelector == "present")
    let inspection = outDir / "path-only-tool-identities.inspect.json"
    let completeOut = root / "complete-out"
    let completeInterface = completeOut / "project-interface.rbsz"
    writeInterfaceArtifact(completeInterface, artifactFor(complete))
    discard devEnvToolShellOpsAt(completeInterface, completeOut)
    let completeFiles = toSeq(walkDirRec(completeOut))
    # The same real path publishes authoritative artifacts when all requests
    # resolve, so the absence checks below cannot pass merely because the
    # fixture disabled identity caching. Only shared-prefix publication is off.
    check completeFiles.anyIt(it.endsWith(".rbtp"))
    check completeFiles.anyIt(it.endsWith(".current-key"))
    copyFile(completeOut / "path-only-tool-identities.inspect.json", inspection)
    writeInterfaceArtifact(interfacePath, artifactFor(mixed))
    discard devEnvToolShellOpsAt(interfacePath, outDir)
    let doc = parseFile(inspection)
    let partial = doc{"partial"}.getBool()
    check partial
    let requested = doc{"requestedToolUses"}
    let hasRequested = not requested.isNil
    require hasRequested
    check requested.getElems.mapIt(it.getStr()).sorted ==
      @["absent", "present", "probe-fails", "unprovisioned"]
    let unresolved = doc{"unresolvedToolUses"}
    let hasUnresolved = not unresolved.isNil
    require hasUnresolved
    check unresolved.getElems.mapIt(it{"packageSelector"}.getStr()).sorted ==
      @["absent", "unprovisioned"]
    for entry in unresolved.getElems:
      check entry{"reason"}.getStr().len > 0
    check doc{"batchFailure"}.getStr().len > 0
    let profiles = doc["profiles"].getElems
    require profiles.len == 2
    for selector in ["present", "probe-fails"]:
      let matches = profiles.filterIt(it{"packageSelector"}.getStr() == selector)
      require matches.len == 1
      let profile = matches[0]
      let path = profile{"resolvedExecutablePath"}.getStr()
      check fileExists(extendedPath(path))
      check profile{"resolvedExecutableDigest"}.getStr() ==
        resolvedExecutableContentDigest(path)
      let probes = profile["probes"].getElems
      require probes.len == 1
      check probes[0]{"args"}.getElems.mapIt(it.getStr()) == @["--version"]
      check probes[0]{"output"}.getStr().strip() == "fixture-tool 1.0"
      check probes[0]{"exitCode"}.getInt() ==
        (if selector == "probe-fails": 7 else: 0)
      check not probes[0]{"timedOut"}.getBool()
      check profile{"installMethod"}.getStr() == "path"
    for path in walkDirRec(outDir):
      check not path.endsWith(".rbtp")
      check not path.endsWith(".current-key")

  test "an inspection write failure does not take away resolved tools":
    # Tarball mode, the mode that realizes `absent` here.
    putEnv("REPRO_TOOL_PROVISIONING", "tarball")
    # A real directory where the diagnostic file belongs makes the atomic
    # replacement fail without depending on root-sensitive permission bits.
    createDir(outDir / "path-only-tool-identities.inspect.json")
    let prepended = prependedPaths(devEnvToolShellOpsAt(interfacePath, outDir))
    check prepended.anyIt(fileExists(extendedPath(it / ("absent" & ExeSuffix))))
    check not fileExists(outDir / "path-only-tool-identities.inspect.json")
    for path in walkDirRec(outDir):
      check not path.endsWith(".rbtp")
      check not path.endsWith(".current-key")

  test "complete cold and warm cache hits restore inspection after partial fallback":
    let probeCounter = root / "probe-counter"
    putEnv("REPRO_TEST_TOOL_PROBE_COUNTER", probeCounter)
    # This fixture needs a stable complete cache. A freshly copied executable
    # legitimately refreshes its racy evidence on a hit; age the owned file
    # before the first resolution rather than bypass that production check.
    sleep(int(RacyWindowNs div 1_000_000) + 10)
    let mixed = readInterfaceArtifact(interfacePath)
    var complete = mixed.projectInterface
    complete.toolUses = complete.toolUses.filterIt(it.packageSelector == "present")
    let completeArtifact = artifactFor(complete)
    for warm in [false, true]:
      let destination = root / (if warm: "warm-transition" else: "cold-transition")
      let iface = destination / "project-interface.rbsz"
      let inspection = destination / "path-only-tool-identities.inspect.json"
      writeInterfaceArtifact(iface, completeArtifact)
      if warm:
        discard warmResolveAndWriteIdentity(completeArtifact, destination, tpmPathOnly)
      else:
        discard devEnvToolShellOpsAt(iface, destination)
      let completeInspection = parseFile(inspection)
      require completeInspection["profiles"].len == 1
      var cacheBytes: seq[tuple[path, digest: string]]
      for path in walkDirRec(destination):
        if path.endsWith(".rbtp") or path.endsWith(".current-key"):
          cacheBytes.add((path, fileSha256Hex(path)))
      require cacheBytes.len >= 3
      writeInterfaceArtifact(iface, mixed)
      discard devEnvToolShellOpsAt(iface, destination)
      require parseFile(inspection){"partial"}.getBool()
      for saved in cacheBytes:
        check fileSha256Hex(saved.path) == saved.digest
      let countAfterPartial = readFile(probeCounter)
      let resolvesBefore = warmBuildCacheCounters.toolIdentityResolves
      writeInterfaceArtifact(iface, completeArtifact)
      if warm:
        discard warmResolveAndWriteIdentity(completeArtifact, destination, tpmPathOnly)
        check warmBuildCacheCounters.toolIdentityResolves == resolvesBefore
      else:
        discard devEnvToolShellOpsAt(iface, destination)
      check readFile(probeCounter) == countAfterPartial
      check parseFile(inspection) == completeInspection
      for saved in cacheBytes:
        check fileSha256Hex(saved.path) == saved.digest
      # An unavailable diagnostic destination must not turn a complete hit
      # into re-resolution or rewrite its authoritative binary/key artifacts.
      removeFile(inspection)
      createDir(inspection)
      if warm:
        discard warmResolveAndWriteIdentity(completeArtifact, destination, tpmPathOnly)
      else:
        discard devEnvToolShellOpsAt(iface, destination)
      check dirExists(inspection)
      check readFile(probeCounter) == countAfterPartial
      for saved in cacheBytes:
        check fileSha256Hex(saved.path) == saved.digest
