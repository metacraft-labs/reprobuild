import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_core
import repro_provider_runtime

import lints/ambient_execution
import repro_test_support

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
  # This test intentionally compiles a generated fixture with the host Nim.
  # Mark that bootstrap-tier boundary explicitly so the ambient-execution
  # linter does not rewrite this sequence-expression call inside the compiler.
  let res = uncontrolledExecCmdEx(args.mapIt(q(it)).join(" "),
    workingDir = cwd)
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
    "  MemberBodyHash = when defined(memberBodyV2) or defined(binaryOnlyV2): \"" & MemberBodyHashV2 &
      "\" else: \"" & MemberBodyHashV1 & "\"\n" &
    "  ProviderArtifact = when defined(memberBodyV2) or defined(providerArtifactV2): \"" & ArtifactV2 &
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
    # A provider is a separate process and its response is decoded from
    # bytes, so a child spec with NO project root is something the engine
    # can be handed however well-behaved its own callers are. This define
    # is what gives the engine's per-plan refusal a reachable input.
    "    arguments: (when defined(childWithoutArguments): \"\" " &
      "else: dir / member),\n" &
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

proc providerSources(fragment: StoredGraphFragment): seq[GraphEvaluationInput] =
  for input in fragment.evaluationInputs:
    if input.kind == gevProviderSource:
      result.add(input)

proc memberIndex(snapshot: ProviderGraphSnapshot; member: string): int =
  for i, fragment in snapshot.fragments:
    if fragment.entryPointId == MemberEntryPoint and
        splitPath(fragment.arguments).tail == member:
      return i
  -1

proc everyFragmentRecordsSource(snapshot: ProviderGraphSnapshot;
                                artifactId, binaryDigest: string): bool =
  ## Every stored fragment -- the root AND each member -- records exactly
  ## one provider-source input, naming this artifact and this binary.
  if snapshot.fragments.len == 0:
    return false
  for fragment in snapshot.fragments:
    let sources = providerSources(fragment)
    checkpoint(fragment.entryPointId & " " & fragment.arguments &
      " provider sources: " & $sources.len)
    if sources.len != 1 or sources[0].identity != artifactId or
        sources[0].digest != binaryDigest:
      return false
  true

suite "integration_provider_fragment_refresh_and_pruning":
  when isNixSupported:
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
                   store = storeRoot; lockSlice = "lock-v1";
                   members = srcDir; working = repoRoot): ProviderRefreshReport =
        var extraArgs = @["--fixture-counts", countsPath]
        if malformed:
          extraArgs.add("--malformed-response")
        refreshProviderGraph(RefreshConfig(
          storeRoot: store,
          projectId: "fixture",
          providerBinaryPath: providerPath,
          providerArtifactId: artifactId,
          rootEntryPointId: RootEntryPoint,
          rootArguments: members,
          namespace: "workspace",
          lockSliceId: lockSlice,
          activity: "build",
          providerExtraArgs: extraArgs,
          providerWorkingDir: working))

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

      # M84: materialize the "built" outputs each member fragment claims, so the
      # removal below can be shown to actually reclaim the orphaned file (not
      # merely report it as stale, which is all this milestone did before).
      let outRoot = tempRoot / "outputs"
      for name in ["a.txt", "b.txt", "c.txt"]:
        let built = outRoot / "build" / (name & ".out")
        createDir(built.parentDir)
        writeFile(built, "built:" & name)

      removeFile(srcDir / "b.txt")
      resetCounts(countsPath)
      let removedMember = refresh(providerV1, ArtifactV1)
      check nonEmptyLines(countsPath).len == 0
      check removedMember.prunedInvocationKeys.len == 1
      check removedMember.effectIdentities().contains("build/b.txt.out")
      check removedMember.edgeIds().contains("workspace:edge:b.txt")
      check memberFragmentCount(removedMember.snapshot) == 2

      # M84: the executor turns the reported stale effect into an actual
      # deletion. Only the orphaned output goes; outputs still claimed by the
      # surviving a.txt / c.txt fragments are retained.
      let cleanup = applyOutputCleanup(removedMember, outRoot)
      check cleanup.deleted == 1
      check not fileExists(outRoot / "build" / "b.txt.out")
      check fileExists(outRoot / "build" / "a.txt.out")
      check fileExists(outRoot / "build" / "c.txt.out")

      let providerSameBodiesV2Artifact = compileProvider(providerSource,
        binDir / "provider-artifact-v2", tempRoot / "nimcache-provider-artifact-v2",
        ["providerArtifactV2"])
      let artifactStore = tempRoot / "artifact-store"
      createDir(artifactStore)
      resetCounts(countsPath)
      discard refresh(providerV1, ArtifactV1, store = artifactStore)
      resetCounts(countsPath)
      let artifactChanged = refresh(providerSameBodiesV2Artifact, ArtifactV2,
        store = artifactStore)
      check nonEmptyLines(countsPath) == @["root", "member:a.txt", "member:c.txt"]
      check artifactChanged.invoked.len == 3
      check artifactChanged.invoked[0].reason == girProviderArtifactChanged
      check artifactChanged.invoked[1 .. ^1].allIt(it.reason == girNoPriorFragment)
      check memberFragmentCount(artifactChanged.snapshot) == 2

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
      check nonEmptyLines(countsPath) == @["root", "member:a.txt", "member:c.txt"]
      check lockChanged.invoked.len == 3
      check lockChanged.invoked[0].reason == girProviderArtifactChanged
      check lockChanged.invoked[1 .. ^1].allIt(it.reason == girNoPriorFragment)
      check memberFragmentCount(lockChanged.snapshot) == 2

      resetCounts(countsPath)
      let bodyChanged = refresh(providerV2, ArtifactV2)
      check nonEmptyLines(countsPath) == @["root", "member:a.txt", "member:c.txt"]
      check bodyChanged.invoked.len == 3
      check bodyChanged.invoked[0].reason == girProviderArtifactChanged
      check bodyChanged.invoked[1 .. ^1].allIt(it.reason == girNoPriorFragment)
      check memberBodyHashes(bodyChanged.snapshot).allIt(it == MemberBodyHashV2)

      writeFile(srcDir / "a.txt", "alpha graph-shape unchanged\n")
      resetCounts(countsPath)
      let cutoff = refresh(providerV2, ArtifactV2)
      check nonEmptyLines(countsPath) == @["member:a.txt"]
      check cutoff.invoked.len == 1
      check cutoff.earlyCutoffs.len == 1

      # Change the actual executable and its manifest, but retain ArtifactV1.
      # A stale manifest would dispatch the member with its old body hash.
      let binaryStore = tempRoot / "binary-store"
      let binaryMembers = tempRoot / "binary-members"
      let binaryOutputs = tempRoot / "binary-outputs"
      createDir(binaryMembers)
      createDir(binaryOutputs / "build")
      for name in ["a.txt", "b.txt"]:
        writeFile(binaryMembers / name, name)
        writeFile(binaryOutputs / "build" / (name & ".out"), name)
      let mutableProvider = binDir / "mutable-provider"
      copyFileWithPermissions(providerV1, mutableProvider)
      let binaryCold = refresh(mutableProvider, ArtifactV1,
        store = binaryStore, members = binaryMembers)
      check providerSnapshotBinaryFresh(binaryCold.snapshot, mutableProvider)
      let binaryWarm = refresh(mutableProvider, ArtifactV1,
        store = binaryStore, members = binaryMembers)
      check binaryWarm.invoked.len == 0
      let relativeWarm = refresh(relativePath(mutableProvider, repoRoot), ArtifactV1,
        store = binaryStore, members = binaryMembers)
      check relativeWarm.invoked.len == 0
      let aliasPath = binDir / "provider-alias"
      createSymlink(mutableProvider, aliasPath)
      let previousPath = getEnv("PATH")
      try:
        putEnv("PATH", binDir & PathSep & previousPath)
        let pathWarm = refresh(mutableProvider.extractFilename(), ArtifactV1,
          store = binaryStore, members = binaryMembers)
        check pathWarm.invoked.len == 0
        let aliasCold = refresh(aliasPath.extractFilename(), ArtifactV1,
          store = tempRoot / "alias-store", members = binaryMembers)
        check providerSnapshotBinaryFresh(aliasCold.snapshot, aliasPath)
        let aliasWarm = refresh(aliasPath.extractFilename(), ArtifactV1,
          store = tempRoot / "alias-store", members = binaryMembers)
        check aliasWarm.invoked.len == 0
        putEnv("PATH", relativePath(binDir, tempRoot) & PathSep & previousPath)
        let relativePathWarm = refresh(mutableProvider.extractFilename(), ArtifactV1,
          store = binaryStore, members = binaryMembers, working = tempRoot)
        check relativePathWarm.invoked.len == 0
        let relativePathCold = refresh(mutableProvider.extractFilename(), ArtifactV1,
          store = tempRoot / "relative-path-store", members = binaryMembers,
          working = tempRoot)
        check relativePathCold.invoked.len > 0
        check providerSnapshotBinaryFresh(relativePathCold.snapshot, mutableProvider)
        let blockedDir = tempRoot / "blocked-bin"
        createDir(blockedDir)
        let blockedBinary = blockedDir / mutableProvider.extractFilename()
        writeFile(blockedBinary, "not an executable")
        setFilePermissions(blockedBinary, {fpUserRead, fpUserWrite})
        putEnv("PATH", blockedDir & PathSep & binDir & PathSep & previousPath)
        let blockedPathCold = refresh(mutableProvider.extractFilename(), ArtifactV1,
          store = tempRoot / "blocked-path-store", members = binaryMembers)
        check providerSnapshotBinaryFresh(blockedPathCold.snapshot, mutableProvider)
        putEnv("PATH", $PathSep & previousPath)
        let emptyPathCold = refresh(mutableProvider.extractFilename(), ArtifactV1,
          store = tempRoot / "empty-path-store", members = binaryMembers,
          working = binDir)
        check providerSnapshotBinaryFresh(emptyPathCold.snapshot, mutableProvider)
        let literalDir = tempRoot / "~"
        createDir(literalDir)
        let literalBinary = literalDir / mutableProvider.extractFilename()
        createSymlink(mutableProvider, literalBinary)
        putEnv("PATH", "~" & PathSep & previousPath)
        let literalPathCold = refresh(mutableProvider.extractFilename(), ArtifactV1,
          store = tempRoot / "literal-path-store", members = binaryMembers,
          working = tempRoot)
        check providerSnapshotBinaryFresh(literalPathCold.snapshot, literalBinary)
      finally:
        putEnv("PATH", previousPath)
      discard compileProvider(providerSource, mutableProvider,
        tempRoot / "nimcache-binary-only", ["binaryOnlyV2"])
      check not providerSnapshotBinaryFresh(binaryCold.snapshot, mutableProvider)
      removeFile(binaryMembers / "b.txt")
      let binaryChanged = refresh(mutableProvider, ArtifactV1,
        store = binaryStore, members = binaryMembers)
      check binaryChanged.invoked.len == 2
      check binaryChanged.snapshot.providerArtifactId == ArtifactV1
      check memberBodyHashes(binaryChanged.snapshot).allIt(it == MemberBodyHashV2)
      check providerSnapshotBinaryFresh(binaryChanged.snapshot, mutableProvider)
      check binaryChanged.effectIdentities().contains("build/b.txt.out")
      let binaryCleanup = applyOutputCleanup(binaryChanged, binaryOutputs)
      check binaryCleanup.deleted == 1
      check fileExists(binaryOutputs / "build" / "a.txt.out")
      check not fileExists(binaryOutputs / "build" / "b.txt.out")

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

    test "a stored fragment is reused only when the current provider source produced it":
      ## Reproduces reprobuild-pm
      ## issues/2026-11-12-reusing-fragments-by-body-hash-is-unsound-and-production-doesnt-use-symbodyhash.md.
      ##
      ## The spec used to let the engine KEEP a stored fragment across a
      ## provider change when its entry point id and body hash were
      ## unchanged. That is unsound, because the body hashes the DSL ships
      ## are not closure-complete: the root's is the constant
      ## `<package>.build.v1`, and a foreach body's is a digest of its
      ## untyped syntax, which a change to a helper proc it calls, a
      ## package-scope flag or a global leaves untouched. The rule the
      ## engine now enforces is that a fragment is reused only when it
      ## was produced by the CURRENT provider source, which it records as
      ## a `gevProviderSource` evaluation input on every fragment.
      ##
      ## The fragment the old permission would have kept is exactly a
      ## stored member whose entry point id, body hash, arguments and
      ## every other input are unchanged while the provider that produced
      ## it is a different one. This case builds that fragment by editing
      ## ONLY the member's provider-source record in the persisted
      ## snapshot, then shows the refresh re-produces it rather than
      ## serving it. A legacy snapshot, written before the record existed,
      ## is the same situation with the record absent.
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-provider-source-reuse", "")
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
      let provider = compileProvider(providerSource, binDir / "provider",
        tempRoot / "nimcache-provider")
      let binaryDigest = fileContentDigest(provider)
      # Another provider's source identity: what a fragment the old
      # permission kept across a provider change would still be carrying.
      let otherBinary = tempRoot / "other-provider-binary"
      writeFile(otherBinary, "a different provider build")
      let foreignSource = GraphEvaluationInput(kind: gevProviderSource,
        identity: ArtifactV2, digest: fileContentDigest(otherBinary))
      check foreignSource.digest != binaryDigest

      proc refresh(): ProviderRefreshReport =
        refreshProviderGraph(RefreshConfig(
          storeRoot: storeRoot,
          projectId: "fixture",
          providerBinaryPath: provider,
          providerArtifactId: ArtifactV1,
          rootEntryPointId: RootEntryPoint,
          rootArguments: srcDir,
          namespace: "workspace",
          lockSliceId: "lock-v1",
          activity: "build",
          providerExtraArgs: @["--fixture-counts", countsPath],
          providerWorkingDir: repoRoot))

      # (a) A cold refresh records the provider source on EVERY fragment,
      # in the report and in what it persisted.
      let cold = refresh()
      check nonEmptyLines(countsPath) == @["root", "member:a.txt", "member:b.txt"]
      check cold.snapshot.fragments.len == 3
      check everyFragmentRecordsSource(cold.snapshot, ArtifactV1, binaryDigest)
      check everyFragmentRecordsSource(loadProviderGraphSnapshot(storeRoot),
        ArtifactV1, binaryDigest)
      check providerSnapshotBinaryFresh(loadProviderGraphSnapshot(storeRoot),
        provider)

      # THE CONTROL: an untampered warm refresh invokes nothing. Without it
      # the cases below would be satisfied by a refresh that always re-runs.
      resetCounts(countsPath)
      let warm = refresh()
      check warm.invoked.len == 0
      check nonEmptyLines(countsPath).len == 0

      # (b) The fragment the old permission would have kept: member a.txt
      # with its id, body hash, arguments, invocation key and every other
      # input unchanged, but produced by a different provider.
      block foreignProvider:
        var stored = loadProviderGraphSnapshot(storeRoot)
        let index = memberIndex(stored, "a.txt")
        require index >= 0
        let before = stored.fragments[index]
        var inputs: seq[GraphEvaluationInput] = @[]
        for input in before.evaluationInputs:
          if input.kind != gevProviderSource:
            inputs.add(input)
        inputs.add(foreignSource)
        stored.fragments[index].evaluationInputs = inputs
        check stored.fragments[index].invocationKey == before.invocationKey
        check stored.fragments[index].entryPointBodyHash == before.entryPointBodyHash
        check stored.fragments[index].fragmentDigest == before.fragmentDigest
        saveProviderGraphSnapshot(storeRoot, stored)
        check not providerSnapshotBinaryFresh(loadProviderGraphSnapshot(storeRoot),
          provider)

        resetCounts(countsPath)
        let refreshed = refresh()
        checkpoint("invoked after foreign-source tamper: " &
          $refreshed.invoked.mapIt(it.entryPointId & " " & it.arguments))
        check "member:a.txt" in nonEmptyLines(countsPath)
        check refreshed.invoked.anyIt(it.entryPointId == MemberEntryPoint and
          splitPath(it.arguments).tail == "a.txt")
        check refreshed.snapshot.fragments.len == 3
        check everyFragmentRecordsSource(refreshed.snapshot, ArtifactV1,
          binaryDigest)
        check everyFragmentRecordsSource(loadProviderGraphSnapshot(storeRoot),
          ArtifactV1, binaryDigest)

      # (c) A legacy snapshot: member b.txt carries no provider-source
      # record at all. It is evaluated once, and then warm again.
      block legacySnapshot:
        var stored = loadProviderGraphSnapshot(storeRoot)
        let index = memberIndex(stored, "b.txt")
        require index >= 0
        var inputs: seq[GraphEvaluationInput] = @[]
        for input in stored.fragments[index].evaluationInputs:
          if input.kind != gevProviderSource:
            inputs.add(input)
        stored.fragments[index].evaluationInputs = inputs
        saveProviderGraphSnapshot(storeRoot, stored)
        check not providerSnapshotBinaryFresh(loadProviderGraphSnapshot(storeRoot),
          provider)

        resetCounts(countsPath)
        let refreshed = refresh()
        checkpoint("invoked after legacy tamper: " &
          $refreshed.invoked.mapIt(it.entryPointId & " " & it.arguments))
        check "member:b.txt" in nonEmptyLines(countsPath)
        check refreshed.invoked.anyIt(it.entryPointId == MemberEntryPoint and
          splitPath(it.arguments).tail == "b.txt")
        check everyFragmentRecordsSource(loadProviderGraphSnapshot(storeRoot),
          ArtifactV1, binaryDigest)

        resetCounts(countsPath)
        let warmAgain = refresh()
        check warmAgain.invoked.len == 0
        check nonEmptyLines(countsPath).len == 0

    test "a CHILD plan with no project root is refused, naming the child":
      ## The per-plan refusal in `executePlan`, given the input it lacked.
      ##
      ## `refreshProviderGraph` already refuses a refresh whose ROOT
      ## arguments are empty, and until now that was the only thing any
      ## gate reached: removing the per-plan check left every case green,
      ## which is the recurring shape in this repository's refusals — a
      ## rule with no reachable input.
      ##
      ## It does have one. Plans are not all derived from the config: a
      ## child plan's arguments come out of the PROVIDER's response, which
      ## is a separate process' bytes, and stored-fragment plans come off
      ## disk. So the engine can be handed an empty root for a child while
      ## the root it was configured with is perfectly good — and an empty
      ## root that travels on reaches a recipe and surfaces as whatever
      ## that recipe's first path resolution happens to raise, naming
      ## neither the invocation nor the package.
      ##
      ## The fixture below is exactly that: a provider whose root fragment
      ## declares children with no arguments. The root plan is fine, so
      ## the refusal cannot be the configured-root one, and the assertion
      ## on the entry-point NAME is what makes that measurable rather
      ## than assumed.
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-child-no-root", "")
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
      createDir(srcDir)
      createDir(binDir)
      createDir(storeRoot)
      writeFile(srcDir / "a.txt", "alpha\n")

      let providerSource = fixtureSourceDir / "fixture_provider.nim"
      writeFixtureProvider(providerSource)

      proc refreshWith(providerPath: string): ProviderRefreshReport =
        refreshProviderGraph(RefreshConfig(
          storeRoot: storeRoot,
          projectId: "fixture",
          providerBinaryPath: providerPath,
          providerArtifactId: ArtifactV1,
          rootEntryPointId: RootEntryPoint,
          rootArguments: srcDir,      # the ROOT's root is fine.
          namespace: "workspace",
          lockSliceId: "lock-v1",
          activity: "build",
          providerWorkingDir: repoRoot))

      # The control first: the same fixture, same root, children with real
      # arguments — accepted. Without this the case below is satisfied by
      # a refresh that refuses everything.
      let healthy = compileProvider(providerSource, binDir / "provider-ok",
        tempRoot / "nimcache-ok")
      let ok = refreshWith(healthy)
      check ok.snapshot.fragments.len == 2
      check ok.invoked.len == 2

      let defective = compileProvider(providerSource,
        binDir / "provider-child-no-root", tempRoot / "nimcache-child",
        defines = ["childWithoutArguments"])
      var raised = ""
      try:
        discard refreshWith(defective)
      except CatchableError as err:
        raised = err.msg
      checkpoint("refusal: " & raised)
      check raised.len > 0
      check "no project root" in raised
      # The CHILD, not the root. The configured root was non-empty, so a
      # message naming the root entry point would mean the refusal came
      # from the other call site and this fixture proved nothing.
      check MemberEntryPoint in raised
      check RootEntryPoint notin raised
