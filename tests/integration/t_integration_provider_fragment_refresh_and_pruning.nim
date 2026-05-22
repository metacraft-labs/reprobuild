import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_core
import repro_provider_runtime

const
  RootEntryPoint = "fixture.root"
  MemberEntryPoint = "fixture.member"
  RootBodyHash = "root-body-v1"
  MemberBodyHashV1 = "member-body-v1"
  MemberBodyHashV2 = "member-body-v2"
  ArtifactV1 = "fixture-provider-artifact-v1"
  ArtifactV2 = "fixture-provider-artifact-v2"

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc runNim(args: openArray[string]; cwd = getCurrentDir()):
    tuple[code: int; output: string] =
  let res = execCmdEx(args.mapIt(q(it)).join(" "), workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireNimSuccess(args: openArray[string]; cwd = getCurrentDir()): string =
  let res = runNim(args, cwd)
  if res.code != 0:
    checkpoint(res.output)
    raise newException(OSError, "nim command failed with code " & $res.code)
  check res.code == 0
  res.output

proc writeFixtureProvider(path: string) =
  writeFile(path,
    "import std/[os, strutils]\n" &
    "import repro_provider_runtime\n\n" &
    "const\n" &
    "  RootEntryPoint = \"" & RootEntryPoint & "\"\n" &
    "  MemberEntryPoint = \"" & MemberEntryPoint & "\"\n" &
    "  RootBodyHash = \"" & RootBodyHash & "\"\n" &
    "  MemberBodyHash = when defined(memberBodyV2): \"" & MemberBodyHashV2 &
      "\" else: \"" & MemberBodyHashV1 & "\"\n" &
    "  ProviderArtifact = when defined(memberBodyV2): \"" & ArtifactV2 &
      "\" else: \"" & ArtifactV1 & "\"\n\n" &
    "proc flagValue(args: openArray[string]; flag: string): string =\n" &
    "  var i = 0\n" &
    "  while i < args.len:\n" &
    "    if args[i] == flag and i + 1 < args.len:\n" &
    "      return args[i + 1]\n" &
    "    inc i\n" &
    "  \"\"\n\n" &
    "proc hasFlag(args: openArray[string]; flag: string): bool =\n" &
    "  for arg in args:\n" &
    "    if arg == flag:\n" &
    "      return true\n" &
    "  false\n\n" &
    "proc record(countPath, line: string) =\n" &
    "  if countPath.len > 0:\n" &
    "    writeFile(countPath, readFile(countPath) & line & \"\\n\")\n\n" &
    "proc fixtureManifest(): ProviderManifest =\n" &
    "  ProviderManifest(\n" &
    "    providerArtifactId: ProviderArtifact,\n" &
    "    protocolVersion: ProviderProtocolVersion,\n" &
    "    entryPoints: @[\n" &
    "      GraphEntryPointDescriptor(\n" &
    "        id: RootEntryPoint,\n" &
    "        kind: gpkProjectRoot,\n" &
    "        stableName: \"root\",\n" &
    "        bodyHash: RootBodyHash,\n" &
    "        argumentSchemaId: \"root-args-v1\",\n" &
    "        outputSchemaId: \"fragment-v1\"),\n" &
    "      GraphEntryPointDescriptor(\n" &
    "        id: MemberEntryPoint,\n" &
    "        kind: gpkStructuralIteratorBody,\n" &
    "        stableName: \"member\",\n" &
    "        bodyHash: MemberBodyHash,\n" &
    "        argumentSchemaId: \"member-args-v1\",\n" &
    "        outputSchemaId: \"fragment-v1\")])\n\n" &
    "proc memberSpec(dir, member, namespace: string): GraphEntryPointInvocationSpec =\n" &
    "  GraphEntryPointInvocationSpec(\n" &
    "    entryPointId: MemberEntryPoint,\n" &
    "    entryPointBodyHash: MemberBodyHash,\n" &
    "    arguments: dir / member,\n" &
    "    namespace: namespace,\n" &
    "    stableName: \"member:\" & member)\n\n" &
    "proc rootFragment(request: ProviderGraphRequest): GraphFragment =\n" &
    "  let members = directoryMemberNames(request.arguments)\n" &
    "  result = GraphFragment(\n" &
    "    entryPointId: request.entryPointId,\n" &
    "    entryPointBodyHash: request.entryPointBodyHash,\n" &
    "    arguments: request.arguments,\n" &
    "    namespace: request.namespace,\n" &
    "    nodes: @[\n" &
    "      GraphNode(\n" &
    "        id: request.namespace & \":root\",\n" &
    "        kind: gnkDirectoryEnumeration,\n" &
    "        stableName: \"root\",\n" &
    "        payload: request.arguments)],\n" &
    "    evaluationInputs: @[\n" &
    "      directoryEnumerationInput(request.arguments, MemberEntryPoint,\n" &
    "        MemberBodyHash, memberArgumentRoot = request.arguments,\n" &
    "        memberNamespace = request.namespace)])\n" &
    "  for member in members:\n" &
    "    result.childEntryPoints.add(memberSpec(request.arguments, member,\n" &
    "      request.namespace))\n" &
    "  result.fragmentDigest = computeGraphFragmentDigest(result)\n\n" &
    "proc memberFragment(request: ProviderGraphRequest): GraphFragment =\n" &
    "  let name = splitPath(request.arguments).tail\n" &
    "  let actionNode = request.namespace & \":action:\" & name\n" &
    "  let outputNode = request.namespace & \":output:\" & name\n" &
    "  result = GraphFragment(\n" &
    "    entryPointId: request.entryPointId,\n" &
    "    entryPointBodyHash: request.entryPointBodyHash,\n" &
    "    arguments: request.arguments,\n" &
    "    namespace: request.namespace,\n" &
    "    nodes: @[\n" &
    "      GraphNode(id: actionNode, kind: gnkAction,\n" &
    "        stableName: \"action:\" & name, payload: name),\n" &
    "      GraphNode(id: outputNode, kind: gnkGeneratedOutput,\n" &
    "        stableName: \"output:\" & name, payload: \"build/\" & name & \".out\")],\n" &
    "    edges: @[\n" &
    "      GraphEdge(id: request.namespace & \":edge:\" & name,\n" &
    "        kind: gekProduces, fromNode: actionNode, toNode: outputNode)],\n" &
    "    effectClaims: @[\n" &
    "      OwnedEffectClaim(kind: oekFile, stableName: \"output:\" & name,\n" &
    "        identity: \"build/\" & name & \".out\",\n" &
    "        cleanupPolicy: cplDeleteWhenUnclaimed,\n" &
    "        payload: request.arguments)],\n" &
    "    evaluationInputs: @[fileReadInput(request.arguments)])\n" &
    "  result.fragmentDigest = computeGraphFragmentDigest(result)\n\n" &
    "when isMainModule:\n" &
    "  let args = commandLineParams()\n" &
    "  let paths = parseProviderProtocolArgs(args)\n" &
    "  if hasFlag(args, \"--malformed-response\"):\n" &
    "    writeFile(paths.responsePath, \"not-a-provider-response\")\n" &
    "    quit(0)\n" &
    "  let request = readProviderRequestFile(paths.requestPath)\n" &
    "  let manifest = fixtureManifest()\n" &
    "  let counts = flagValue(args, \"--fixture-counts\")\n" &
    "  case request.kind\n" &
    "  of prkManifest:\n" &
    "    writeProviderResponseFile(paths.responsePath, manifestResponse(manifest))\n" &
    "  of prkGraphInvocation:\n" &
    "    if request.entryPointId == RootEntryPoint:\n" &
    "      record(counts, \"root\")\n" &
    "      writeProviderResponseFile(paths.responsePath,\n" &
    "        graphResponse(manifest, rootFragment(request)))\n" &
    "    elif request.entryPointId == MemberEntryPoint:\n" &
    "      record(counts, \"member:\" & splitPath(request.arguments).tail)\n" &
    "      writeProviderResponseFile(paths.responsePath,\n" &
    "        graphResponse(manifest, memberFragment(request)))\n" &
    "    else:\n" &
    "      quit(\"unknown entry point\", 2)\n" &
    "  of prkDevEnvIntrospection:\n" &
    "    quit(\"dev-env introspection is not implemented by this fixture\", 2)\n")

proc compileProvider(sourcePath, outputPath, nimcache: string;
                     defines: openArray[string] = []): string =
  createDir(parentDir(outputPath))
  createDir(nimcache)
  var args = @["nim", "c", "--verbosity:0", "--hints:off",
    "--nimcache:" & nimcache, "--out:" & outputPath]
  for define in defines:
    args.add("-d:" & define)
  args.add(sourcePath)
  discard requireNimSuccess(args)
  outputPath

proc nonEmptyLines(path: string): seq[string] =
  if not fileExists(path):
    return @[]
  for line in readFile(path).splitLines:
    let stripped = line.strip()
    if stripped.len > 0:
      result.add(stripped)

proc resetCounts(path: string) =
  writeFile(path, "")

proc effectIdentities(report: ProviderRefreshReport): seq[string] =
  for stale in report.staleEffects:
    result.add(stale.claim.identity)

proc edgeIds(report: ProviderRefreshReport): seq[string] =
  for stale in report.staleEdges:
    result.add(stale.edge.id)

proc memberFragmentCount(snapshot: ProviderGraphSnapshot): int =
  for fragment in snapshot.fragments:
    if fragment.entryPointId == MemberEntryPoint:
      inc result

proc memberBodyHashes(snapshot: ProviderGraphSnapshot): seq[string] =
  for fragment in snapshot.fragments:
    if fragment.entryPointId == MemberEntryPoint:
      result.add(fragment.entryPointBodyHash)

suite "integration_provider_fragment_refresh_and_pruning":
  test "provider runtime refreshes minimal fragments and prunes stale ownership":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m18-provider-runtime", "")
    defer: removeDir(tempRoot)
    let fixtureSourceDir = repoRoot / "build" / "provider-fixtures" /
      splitPath(tempRoot).tail
    createDir(fixtureSourceDir)
    defer:
      if dirExists(fixtureSourceDir):
        removeDir(fixtureSourceDir)

    let srcDir = tempRoot / "src"
    let binDir = tempRoot / "bin"
    let storeRoot = tempRoot / "store"
    let countsPath = tempRoot / "counts.log"
    createDir(srcDir)
    createDir(binDir)
    createDir(storeRoot)
    resetCounts(countsPath)

    writeFile(srcDir / "a.txt", "alpha\n")
    writeFile(srcDir / "b.txt", "bravo\n")

    let providerSource = fixtureSourceDir / "fixture_provider.nim"
    writeFixtureProvider(providerSource)
    let providerV1 = compileProvider(providerSource, binDir / "provider-v1",
      tempRoot / "nimcache-provider-v1")

    proc refresh(providerPath, artifactId: string; malformed = false;
                 store = storeRoot; lockSlice = "lock-v1"): ProviderRefreshReport =
      var extraArgs = @["--fixture-counts", countsPath]
      if malformed:
        extraArgs.add("--malformed-response")
      refreshProviderGraph(RefreshConfig(
        storeRoot: store,
        providerBinaryPath: providerPath,
        providerArtifactId: artifactId,
        rootEntryPointId: RootEntryPoint,
        rootArguments: srcDir,
        namespace: "workspace",
        lockSliceId: lockSlice,
        activity: "build",
        providerExtraArgs: extraArgs,
        providerWorkingDir: repoRoot))

    let cold = refresh(providerV1, ArtifactV1)
    check nonEmptyLines(countsPath) == @["root", "member:a.txt", "member:b.txt"]
    check cold.snapshot.fragments.len == 3
    check memberFragmentCount(cold.snapshot) == 2
    check fileExists(providerSnapshotPath(storeRoot))
    let rawSnapshot = readFile(providerSnapshotPath(storeRoot))
    check rawSnapshot.len > 12
    check rawSnapshot[0 .. 3] == "RBPG"
    check rawSnapshot[0] != '{'

    writeFile(srcDir / "a.txt", "alpha changed\n")
    resetCounts(countsPath)
    let changedMember = refresh(providerV1, ArtifactV1)
    check nonEmptyLines(countsPath) == @["member:a.txt"]
    check changedMember.invoked.len == 1
    check changedMember.invoked[0].reason == girEvaluationInputChanged
    check changedMember.earlyCutoffs.len == 1
    check memberFragmentCount(changedMember.snapshot) == 2

    writeFile(srcDir / "c.txt", "charlie\n")
    resetCounts(countsPath)
    let addedMember = refresh(providerV1, ArtifactV1)
    check nonEmptyLines(countsPath) == @["member:c.txt"]
    check addedMember.invoked.len == 1
    check addedMember.invoked[0].reason == girDirectoryMembershipChanged
    check memberFragmentCount(addedMember.snapshot) == 3

    removeFile(srcDir / "b.txt")
    resetCounts(countsPath)
    let removedMember = refresh(providerV1, ArtifactV1)
    check nonEmptyLines(countsPath).len == 0
    check removedMember.prunedInvocationKeys.len == 1
    check removedMember.effectIdentities().contains("build/b.txt.out")
    check removedMember.edgeIds().contains("workspace:edge:b.txt")
    check memberFragmentCount(removedMember.snapshot) == 2

    let providerV2 = compileProvider(providerSource, binDir / "provider-v2",
      tempRoot / "nimcache-provider-v2", ["memberBodyV2"])

    let lockStore = tempRoot / "lock-store"
    createDir(lockStore)
    resetCounts(countsPath)
    discard refresh(providerV1, ArtifactV1, store = lockStore,
      lockSlice = "lock-v1")
    resetCounts(countsPath)
    let lockChanged = refresh(providerV2, ArtifactV2, store = lockStore,
      lockSlice = "lock-v2")
    check nonEmptyLines(countsPath) == @["member:a.txt", "member:c.txt"]
    check lockChanged.invoked.len == 2
    check lockChanged.invoked.allIt(it.reason == girEntryPointBodyChanged)
    check memberFragmentCount(lockChanged.snapshot) == 2

    resetCounts(countsPath)
    let bodyChanged = refresh(providerV2, ArtifactV2)
    check nonEmptyLines(countsPath) == @["member:a.txt", "member:c.txt"]
    check bodyChanged.invoked.len == 2
    check bodyChanged.invoked.allIt(it.reason == girEntryPointBodyChanged)
    check not nonEmptyLines(countsPath).contains("root")
    check bodyChanged.earlyCutoffs.len == 2
    check memberBodyHashes(bodyChanged.snapshot).allIt(it == MemberBodyHashV2)

    writeFile(srcDir / "a.txt", "alpha graph-shape unchanged\n")
    resetCounts(countsPath)
    let cutoff = refresh(providerV2, ArtifactV2)
    check nonEmptyLines(countsPath) == @["member:a.txt"]
    check cutoff.invoked.len == 1
    check cutoff.earlyCutoffs.len == 1

    let beforeMalformed = readFile(providerSnapshotPath(storeRoot))
    writeFile(srcDir / "a.txt", "malformed response should not publish\n")
    resetCounts(countsPath)
    expect EnvelopeError:
      discard refresh(providerV2, ArtifactV2, malformed = true)
    check readFile(providerSnapshotPath(storeRoot)) == beforeMalformed
    check nonEmptyLines(countsPath).len == 0

    let badStore = tempRoot / "bad-store"
    createDir(badStore)
    writeFile(providerSnapshotPath(badStore), "corrupt-store")
    resetCounts(countsPath)
    expect EnvelopeError:
      discard refresh(providerV2, ArtifactV2, store = badStore)
    check readFile(providerSnapshotPath(badStore)) == "corrupt-store"
    check nonEmptyLines(countsPath).len == 0
