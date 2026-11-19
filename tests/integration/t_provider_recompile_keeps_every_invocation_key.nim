## A provider recompile keeps every invocation key.
##
## Protects the rule of Project-Provider-Graph-Protocol.md §"Graph Fragment":
## a stored fragment's invocation key names WHICH INVOCATION owns it -- the
## project, the entry point, the argument digest, the lock slice, the
## activity and the namespace -- and never which build of the provider
## produced it. The provider artifact and the entry point body hash are
## validity attributes: a mismatch re-runs the invocation, and the fragment
## it returns is stored under the SAME key and replaces the previous one.
## That is what makes early cutoff, stale-edge pruning and stale-effect
## cleanup comparable across a recompile, and what keeps the old and the
## new provider's copies of one invocation from both claiming its outputs.
##
## Recorded as reprobuild-pm
## issues/2026-11-12-graphinvocationkey-contains-providerartifactid.md: the
## key used to begin with the provider artifact id and carry the body hash,
## so every recompile re-keyed every fragment, and the refresh found the
## previous fragment again only through an attribute-matching fallback.
##
## The cases, each against the real ``refreshProviderGraph`` driving a real
## provider binary compiled from a generated fixture (no mocks):
##
## * a recompile to a different artifact id, and one that also changes the
##   member body hash, reproducing the same graph: every key is kept, every
##   fragment early-cuts off under that key, nothing is pruned or stale, and
##   the snapshot holds one fragment per invocation;
## * a different lock slice or activity IS a different invocation, with the
##   same provider and across a recompile: the previous fragments are pruned
##   and their effects reported stale, but output cleanup leaves every one
##   in place because a surviving fragment claims it (``ocoSkippedShared``);
## * a different root argument is a different root invocation, even with the
##   provider held fixed: the root is invoked again for the new argument and
##   the previous root's fragments are pruned;
## * the key names the project, and a refresh without one is refused;
## * a snapshot persisted with keys of the old shape is re-evaluated once,
##   its outputs protected the same way, and is warm afterwards.

import std/[algorithm, os, sequtils, strutils, tables, tempfiles, unittest]

import repro_provider_runtime

import lints/ambient_execution
import repro_test_support

const
  ProjectId = "fixture"
  RootEntryPoint = "fixture.root"
  MemberEntryPoint = "fixture.member"
  RootBodyHash = "root-body-v1"
  MemberBodyHashV1 = "member-body-v1"
  MemberBodyHashV2 = "member-body-v2"
  ArtifactV1 = "fixture-provider-artifact-v1"
  ArtifactV2 = "fixture-provider-artifact-v2"
  ArtifactV3 = "fixture-provider-artifact-v3"
  Namespace = "workspace"

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc requireNimSuccess(args: openArray[string]) =
  # The fixture provider is compiled with the host Nim, a bootstrap-tier
  # boundary; marked so the ambient-execution lint leaves the call alone.
  let res = uncontrolledExecCmdEx(args.mapIt(q(it)).join(" "))
  if res.exitCode != 0:
    checkpoint(res.output)
    raise newException(OSError, "nim command failed with code " &
      $res.exitCode)

proc writeFixtureProvider(path: string) =
  ## A root that enumerates a directory and spawns one member invocation per
  ## entry; each member claims one output file. ``providerArtifactV2``
  ## changes only the artifact id; ``memberBodyV2`` changes the artifact id
  ## AND the member body hash. Neither changes the graph produced.
  writeFile(path,
    "import std/os\n" &
    "import repro_provider_runtime\n\n" &
    "const\n" &
    "  RootEntryPoint = \"" & RootEntryPoint & "\"\n" &
    "  MemberEntryPoint = \"" & MemberEntryPoint & "\"\n" &
    "  RootBodyHash = \"" & RootBodyHash & "\"\n" &
    "  MemberBodyHash = when defined(memberBodyV2): \"" & MemberBodyHashV2 &
      "\" else: \"" & MemberBodyHashV1 & "\"\n" &
    "  ProviderArtifact = when defined(memberBodyV2): \"" & ArtifactV3 &
      "\" elif defined(providerArtifactV2): \"" & ArtifactV2 &
      "\" else: \"" & ArtifactV1 & "\"\n\n" &
    "proc fixtureManifest(): ProviderManifest =\n" &
    "  ProviderManifest(\n" &
    "    providerArtifactId: ProviderArtifact,\n" &
    "    protocolVersion: ProviderProtocolVersion,\n" &
    "    entryPoints: @[\n" &
    "      GraphEntryPointDescriptor(id: RootEntryPoint, kind: gpkProjectRoot,\n" &
    "        stableName: \"root\", bodyHash: RootBodyHash,\n" &
    "        argumentSchemaId: \"root-args-v1\", outputSchemaId: \"fragment-v1\"),\n" &
    "      GraphEntryPointDescriptor(id: MemberEntryPoint,\n" &
    "        kind: gpkStructuralIteratorBody, stableName: \"member\",\n" &
    "        bodyHash: MemberBodyHash, argumentSchemaId: \"member-args-v1\",\n" &
    "        outputSchemaId: \"fragment-v1\")])\n\n" &
    "proc rootFragment(request: ProviderGraphRequest): GraphFragment =\n" &
    "  result = GraphFragment(\n" &
    "    entryPointId: request.entryPointId,\n" &
    "    entryPointBodyHash: request.entryPointBodyHash,\n" &
    "    arguments: request.arguments,\n" &
    "    namespace: request.namespace,\n" &
    "    nodes: @[GraphNode(id: request.namespace & \":root\",\n" &
    "      kind: gnkDirectoryEnumeration, stableName: \"root\",\n" &
    "      payload: request.arguments)],\n" &
    "    evaluationInputs: @[directoryEnumerationInput(request.arguments,\n" &
    "      MemberEntryPoint, MemberBodyHash,\n" &
    "      memberArgumentRoot = request.arguments,\n" &
    "      memberNamespace = request.namespace)])\n" &
    "  for member in directoryMemberNames(request.arguments):\n" &
    "    result.childEntryPoints.add(GraphEntryPointInvocationSpec(\n" &
    "      entryPointId: MemberEntryPoint, entryPointBodyHash: MemberBodyHash,\n" &
    "      arguments: request.arguments / member, namespace: request.namespace,\n" &
    "      stableName: \"member:\" & member))\n" &
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
    "        stableName: \"output:\" & name,\n" &
    "        payload: \"build/\" & name & \".out\")],\n" &
    "    edges: @[GraphEdge(id: request.namespace & \":edge:\" & name,\n" &
    "      kind: gekProduces, fromNode: actionNode, toNode: outputNode)],\n" &
    "    effectClaims: @[OwnedEffectClaim(kind: oekFile,\n" &
    "      stableName: \"output:\" & name,\n" &
    "      identity: \"build/\" & name & \".out\",\n" &
    "      cleanupPolicy: cplDeleteWhenUnclaimed, payload: request.arguments)],\n" &
    "    evaluationInputs: @[fileReadInput(request.arguments)])\n" &
    "  result.fragmentDigest = computeGraphFragmentDigest(result)\n\n" &
    "when isMainModule:\n" &
    "  let paths = parseProviderProtocolArgs(commandLineParams())\n" &
    "  let request = readProviderRequestFile(paths.requestPath)\n" &
    "  let manifest = fixtureManifest()\n" &
    "  case request.kind\n" &
    "  of prkManifest:\n" &
    "    writeProviderResponseFile(paths.responsePath, manifestResponse(manifest))\n" &
    "  of prkGraphInvocation:\n" &
    "    if request.entryPointId == RootEntryPoint:\n" &
    "      writeProviderResponseFile(paths.responsePath,\n" &
    "        graphResponse(manifest, rootFragment(request)))\n" &
    "    elif request.entryPointId == MemberEntryPoint:\n" &
    "      writeProviderResponseFile(paths.responsePath,\n" &
    "        graphResponse(manifest, memberFragment(request)))\n" &
    "    else:\n" &
    "      quit(\"unknown entry point\", 2)\n" &
    "  of prkDevEnvIntrospection:\n" &
    "    quit(\"dev-env introspection is not implemented by this fixture\", 2)\n")

type
  Fixture = object
    repoRoot, tempRoot, sourceDir, srcDir, binDir, outRoot: string
    providerSource: string

proc newFixture(prefix: string): Fixture =
  ## The provider source lives under the checkout's ``build/`` so it
  ## resolves ``repro_provider_runtime`` through the repository's config,
  ## exactly as the sibling refresh tests compile theirs.
  result.repoRoot = getCurrentDir()
  result.tempRoot = createTempDir(prefix, "")
  result.sourceDir = result.repoRoot / "build" / "provider-fixtures" /
    splitPath(result.tempRoot).tail
  createDir(result.sourceDir)
  result.srcDir = result.tempRoot / "src"
  result.binDir = result.tempRoot / "bin"
  result.outRoot = result.tempRoot / "outputs"
  createDir(result.srcDir)
  createDir(result.binDir)
  writeFile(result.srcDir / "a.txt", "alpha\n")
  writeFile(result.srcDir / "b.txt", "bravo\n")
  result.providerSource = result.sourceDir / "fixture_provider.nim"
  writeFixtureProvider(result.providerSource)

proc dispose(fx: Fixture) =
  if dirExists(fx.sourceDir):
    removeDir(fx.sourceDir)
  if dirExists(fx.tempRoot):
    removeDir(fx.tempRoot)

proc compileProvider(fx: Fixture; name: string;
                     defines: openArray[string] = []): string =
  result = fx.binDir / name
  var args = @["nim", "c", "--verbosity:0", "--hints:off",
    "--nimcache:" & (fx.tempRoot / ("nimcache-" & name)), "--out:" & result]
  for define in defines:
    args.add("-d:" & define)
  args.add(fx.providerSource)
  requireNimSuccess(args)

proc refresh(fx: Fixture; store, provider, artifactId: string;
             lockSlice = "lock-v1"; activity = "build";
             projectId = ProjectId;
             rootArguments = ""): ProviderRefreshReport =
  refreshProviderGraph(RefreshConfig(
    storeRoot: store,
    projectId: projectId,
    providerBinaryPath: provider,
    providerArtifactId: artifactId,
    rootEntryPointId: RootEntryPoint,
    rootArguments: (if rootArguments.len > 0: rootArguments else: fx.srcDir),
    namespace: Namespace,
    lockSliceId: lockSlice,
    activity: activity,
    providerWorkingDir: fx.repoRoot))

proc materializeOutputs(fx: Fixture) =
  ## The files the member fragments claim, so cleanup has something real
  ## to delete if it (wrongly) decided to.
  for name in ["a.txt", "b.txt"]:
    let built = fx.outRoot / "build" / (name & ".out")
    createDir(built.parentDir)
    writeFile(built, "built:" & name)

proc outputsIntact(fx: Fixture): bool =
  fileExists(fx.outRoot / "build" / "a.txt.out") and
    fileExists(fx.outRoot / "build" / "b.txt.out")

proc invocation(fragment: StoredGraphFragment): string =
  ## What the invocation IS, independently of the key under test: the entry
  ## point and its arguments (namespace is the same for every fragment).
  fragment.entryPointId & " " & fragment.arguments

proc keysByInvocation(snapshot: ProviderGraphSnapshot): Table[string, string] =
  for fragment in snapshot.fragments:
    result[invocation(fragment)] = fragment.invocationKey

proc sortedKeys(snapshot: ProviderGraphSnapshot): seq[string] =
  result = snapshot.fragments.mapIt(it.invocationKey)
  result.sort()

proc sortedValues(table: Table[string, string]): seq[string] =
  for value in table.values:
    result.add(value)
  result.sort()

proc ascending(items: seq[string]): seq[string] =
  result = items
  result.sort()

proc onePerInvocation(snapshot: ProviderGraphSnapshot): bool =
  ## Exactly the three invocations of the fixture graph -- the root and the
  ## two members -- each held once, under keys that are pairwise distinct.
  let invocations = snapshot.fragments.mapIt(invocation(it))
  checkpoint("stored invocations: " & $invocations)
  invocations.len == 3 and invocations.deduplicate().len == 3 and
    snapshot.fragments.mapIt(it.invocationKey).deduplicate().len == 3

proc staleIdentities(report: ProviderRefreshReport): seq[string] =
  result = report.staleEffects.mapIt(it.claim.identity).deduplicate()
  result.sort()

proc checkCleanupProtectsEveryOutput(fx: Fixture;
                                     report: ProviderRefreshReport) =
  ## Every stale effect is still claimed by a surviving fragment, so the
  ## planner keeps it and neither a dry run nor a real cleanup deletes it.
  let plan = planOutputCleanup(report, fx.outRoot)
  checkpoint("cleanup plan: " & $plan.mapIt($it.outcome & " " &
    it.claim.identity))
  check plan.len == 2
  check plan.allIt(it.outcome == ocoSkippedShared)
  let dry = applyOutputCleanup(report, fx.outRoot, dryRun = true)
  check dry.wouldDelete == 0
  check dry.skipped == 2
  let real = applyOutputCleanup(report, fx.outRoot)
  check real.deleted == 0
  check fx.outputsIntact()

proc checkSameInvocationsKept(fx: Fixture; previous: Table[string, string];
                              report: ProviderRefreshReport;
                              artifactId, memberBodyHash: string) =
  ## A recompile that reproduces the graph: same keys, early cutoff under
  ## them, nothing pruned or stale, and the validity attributes updated.
  checkpoint("invoked: " & $report.invoked.mapIt(it.entryPointId & " " &
    $it.reason))
  # THE CONTROL: the recompile really re-produced every fragment. A refresh
  # that served the old snapshot would satisfy every key assertion below.
  check report.invoked.len == 3
  require report.invoked.len > 0
  check report.invoked[0].entryPointId == RootEntryPoint
  check report.invoked[0].reason == girProviderArtifactChanged
  check onePerInvocation(report.snapshot)
  for fragment in report.snapshot.fragments:
    checkpoint("invocation: " & invocation(fragment))
    checkpoint("  previous key: " & previous.getOrDefault(invocation(fragment)))
    checkpoint("  re-produced key: " & fragment.invocationKey)
    check previous.hasKey(invocation(fragment))
    check fragment.invocationKey == previous.getOrDefault(invocation(fragment))
  # Every re-produced fragment has the stored one's digest, and the cutoff
  # names the key both of them are stored under.
  check ascending(report.earlyCutoffs) == sortedValues(previous)
  check report.prunedInvocationKeys.len == 0
  check report.staleEffects.len == 0
  check report.staleEdges.len == 0
  let persisted = loadProviderGraphSnapshot(parentDir(
    report.persistedSnapshotPath))
  check sortedKeys(persisted) == sortedValues(previous)
  check onePerInvocation(persisted)
  # The validity attributes moved to the new build.
  check report.snapshot.fragments.allIt(it.providerArtifactId == artifactId)
  for fragment in report.snapshot.fragments:
    if fragment.entryPointId == MemberEntryPoint:
      check fragment.entryPointBodyHash == memberBodyHash
  let cleanup = applyOutputCleanup(report, fx.outRoot)
  check cleanup.actions.len == 0
  check fx.outputsIntact()

proc checkEveryInvocationReplaced(fx: Fixture; previous: Table[string, string];
                                  report: ProviderRefreshReport;
                                  lockSlice, activity: string) =
  ## A different lock slice or activity: every previous fragment is pruned
  ## under its own key, and the new ones are stored under new keys.
  checkpoint("invoked: " & $report.invoked.mapIt(it.entryPointId & " " &
    $it.reason))
  check report.invoked.len == 3
  check report.invoked.anyIt(it.entryPointId == RootEntryPoint)
  check onePerInvocation(report.snapshot)
  for fragment in report.snapshot.fragments:
    checkpoint("invocation: " & invocation(fragment) & " key " &
      fragment.invocationKey)
    check fragment.lockSliceId == lockSlice
    check fragment.activity == activity
    check previous.hasKey(invocation(fragment))
    check fragment.invocationKey != previous.getOrDefault(invocation(fragment))
  checkpoint("pruned: " & $report.prunedInvocationKeys)
  check ascending(report.prunedInvocationKeys) == sortedValues(previous)
  check report.earlyCutoffs.len == 0
  check staleIdentities(report) == @["build/a.txt.out", "build/b.txt.out"]
  let previousKeys = sortedValues(previous)
  check report.staleEffects.allIt(it.invocationKey in previousKeys)
  check report.staleEdges.len == 2
  checkCleanupProtectsEveryOutput(fx, report)

suite "provider recompile keeps every invocation key":
  when isNixSupported:
    test "a recompile that reproduces the graph keeps every invocation key":
      let fx = newFixture("repro-recompile-keeps-keys")
      defer: fx.dispose()
      let store = fx.tempRoot / "store"
      let providerV1 = fx.compileProvider("provider-v1")
      let providerV2 = fx.compileProvider("provider-artifact-v2",
        ["providerArtifactV2"])
      let providerV3 = fx.compileProvider("provider-body-v2", ["memberBodyV2"])

      let cold = fx.refresh(store, providerV1, ArtifactV1)
      check cold.invoked.len == 3
      check onePerInvocation(cold.snapshot)
      let keys = keysByInvocation(cold.snapshot)
      # The key names the invocation, not the build that produced it.
      for key in keys.values:
        checkpoint("cold key: " & key)
        check ArtifactV1 notin key
        check MemberBodyHashV1 notin key
        check RootBodyHash notin key
      fx.materializeOutputs()

      # (a) Recompiled to a different artifact id, same bodies, same graph.
      let artifactChanged = fx.refresh(store, providerV2, ArtifactV2)
      checkSameInvocationsKept(fx, keys, artifactChanged, ArtifactV2,
        MemberBodyHashV1)

      # (b) Recompiled again, and the member body hash changed too.
      let bodyChanged = fx.refresh(store, providerV3, ArtifactV3)
      checkSameInvocationsKept(fx, keys, bodyChanged, ArtifactV3,
        MemberBodyHashV2)

      # The re-keyed snapshot is the current provider's: a warm refresh
      # invokes nothing.
      let warm = fx.refresh(store, providerV3, ArtifactV3)
      check warm.invoked.len == 0
      check keysByInvocation(warm.snapshot) == keys

    test "a different lock slice or activity is a different invocation":
      let fx = newFixture("repro-lock-slice-is-identity")
      defer: fx.dispose()
      let store = fx.tempRoot / "store"
      let providerV1 = fx.compileProvider("provider-v1")
      let providerV2 = fx.compileProvider("provider-artifact-v2",
        ["providerArtifactV2"])

      let cold = fx.refresh(store, providerV1, ArtifactV1, lockSlice = "lock-v1")
      check onePerInvocation(cold.snapshot)
      fx.materializeOutputs()

      # (a) The same provider binary, a different lock slice. The provider
      # did not change, so only the key can tell the refresh the stored
      # fragments belong to another invocation.
      let lockChanged = fx.refresh(store, providerV1, ArtifactV1,
        lockSlice = "lock-v2")
      checkEveryInvocationReplaced(fx, keysByInvocation(cold.snapshot),
        lockChanged, "lock-v2", "build")
      check lockChanged.invoked.len > 0 and
        lockChanged.invoked[0].reason == girLockOrConfigChanged

      # (b) The same provider, a different activity.
      let activityChanged = fx.refresh(store, providerV1, ArtifactV1,
        lockSlice = "lock-v2", activity = "test")
      checkEveryInvocationReplaced(fx, keysByInvocation(lockChanged.snapshot),
        activityChanged, "lock-v2", "test")

      # (c) A recompiled provider AND a different lock slice: the previous
      # fragments are still pruned, not adopted because their entry point,
      # arguments and namespace match.
      let bothChanged = fx.refresh(store, providerV2, ArtifactV2,
        lockSlice = "lock-v3", activity = "test")
      checkEveryInvocationReplaced(fx, keysByInvocation(activityChanged.snapshot),
        bothChanged, "lock-v3", "test")
      check bothChanged.invoked.len > 0 and
        bothChanged.invoked[0].reason == girProviderArtifactChanged

      # The control: the same invocation again is warm.
      let warm = fx.refresh(store, providerV2, ArtifactV2,
        lockSlice = "lock-v3", activity = "test")
      check warm.invoked.len == 0

    test "a different root argument re-invokes the root":
      ## The root argument (the project root in production) is part of the
      ## root fragment's key through its argument digest, so a refresh for
      ## another root is another invocation (Project-Provider-Graph-Protocol.md
      ## §"Full Versus Fragment Invocation"). The provider binary and its
      ## artifact id are held fixed: this covers a store reused for another
      ## root by a provider whose artifact does not depend on the root, the
      ## case a changed artifact id (``geiProviderSource``) does not catch.
      ##
      ## Recorded as reprobuild-pm issues/2026-11-16-provider-graph-warm-
      ## refresh-ignores-a-changed-root-argument.md: the warm path compared
      ## each stored fragment's key with the key of its OWN stored arguments,
      ## never the stored root's arguments with the requested ones, so it
      ## served the old root's graph and invoked nothing.
      let fx = newFixture("repro-root-argument-is-identity")
      defer: fx.dispose()
      let store = fx.tempRoot / "store"
      let providerV1 = fx.compileProvider("provider-v1")
      let otherRoot = fx.tempRoot / "other-src"
      createDir(otherRoot)
      writeFile(otherRoot / "c.txt", "charlie\n")

      let cold = fx.refresh(store, providerV1, ArtifactV1)
      check onePerInvocation(cold.snapshot)
      let coldKeys = keysByInvocation(cold.snapshot)
      # The control: the same root again is warm, so whatever the next
      # refresh invokes is owed to the root argument alone.
      let warm = fx.refresh(store, providerV1, ArtifactV1)
      check warm.invoked.len == 0

      let moved = fx.refresh(store, providerV1, ArtifactV1,
        rootArguments = otherRoot)
      checkpoint("invoked: " & $moved.invoked.mapIt(it.entryPointId & " " &
        it.arguments & " " & $it.reason))
      require moved.invoked.len == 2
      check moved.invoked[0].entryPointId == RootEntryPoint
      check moved.invoked[0].arguments == otherRoot
      check moved.invoked[0].reason == girLockOrConfigChanged
      check moved.invoked[1].entryPointId == MemberEntryPoint
      check moved.invoked[1].arguments == otherRoot / "c.txt"
      # The snapshot is the new root's graph and nothing of the old one.
      let stored = moved.snapshot.fragments.mapIt(invocation(it)).ascending()
      check stored == @[RootEntryPoint & " " & otherRoot,
        MemberEntryPoint & " " & (otherRoot / "c.txt")].ascending()
      check ascending(moved.prunedInvocationKeys) == sortedValues(coldKeys)
      check staleIdentities(moved) == @["build/a.txt.out", "build/b.txt.out"]
      let persisted = loadProviderGraphSnapshot(store)
      check persisted.fragments.mapIt(invocation(it)).ascending() == stored

      # And the new root is warm in turn.
      let warmAgain = fx.refresh(store, providerV1, ArtifactV1,
        rootArguments = otherRoot)
      check warmAgain.invoked.len == 0

    test "the invocation key names the project, and a refresh needs one":
      let fx = newFixture("repro-key-names-project")
      defer: fx.dispose()
      let providerV1 = fx.compileProvider("provider-v1")

      let alpha = fx.refresh(fx.tempRoot / "store-alpha", providerV1,
        ArtifactV1, projectId = "alpha")
      let alphaAgain = fx.refresh(fx.tempRoot / "store-alpha-again",
        providerV1, ArtifactV1, projectId = "alpha")
      let beta = fx.refresh(fx.tempRoot / "store-beta", providerV1,
        ArtifactV1, projectId = "beta")
      let alphaKeys = keysByInvocation(alpha.snapshot)
      let betaKeys = keysByInvocation(beta.snapshot)
      # The control: the key is a function of the invocation, so the same
      # project in another store gets the same keys.
      check keysByInvocation(alphaAgain.snapshot) == alphaKeys
      for invocationName, key in alphaKeys:
        checkpoint(invocationName & ": alpha " & key & " beta " &
          betaKeys.getOrDefault(invocationName))
        check betaKeys.hasKey(invocationName)
        check betaKeys.getOrDefault(invocationName) != key

      # The same store refreshed for another project: a different invocation.
      fx.materializeOutputs()
      let switched = fx.refresh(fx.tempRoot / "store-alpha", providerV1,
        ArtifactV1, projectId = "beta")
      check switched.invoked.len == 3
      check keysByInvocation(switched.snapshot) == betaKeys
      check ascending(switched.prunedInvocationKeys) == sortedValues(alphaKeys)
      checkCleanupProtectsEveryOutput(fx, switched)

      # A refresh with no project is refused before anything runs, naming
      # what is missing and the entry point it was for.
      let emptyStore = fx.tempRoot / "store-no-project"
      var raised = ""
      try:
        discard fx.refresh(emptyStore, providerV1, ArtifactV1, projectId = "")
      except ProviderRuntimeError as err:
        raised = err.msg
      checkpoint("refusal: " & raised)
      check "no project id" in raised
      check RootEntryPoint in raised
      check not fileExists(providerSnapshotPath(emptyStore))

    test "a snapshot keyed by the provider build is re-evaluated once":
      ## A snapshot persisted before the key lost the provider artifact and
      ## the body hash. Its layout is unchanged -- the key is a string -- so
      ## it decodes; its keys simply name no invocation this refresh makes.
      ## It must be produced again once, with its outputs protected by the
      ## fragments that re-claim them, and then be warm.
      let fx = newFixture("repro-legacy-keys")
      defer: fx.dispose()
      let store = fx.tempRoot / "store"
      let providerV1 = fx.compileProvider("provider-v1")

      let cold = fx.refresh(store, providerV1, ArtifactV1)
      let keys = keysByInvocation(cold.snapshot)
      var legacy = loadProviderGraphSnapshot(store)
      var legacyKeys: Table[string, string]
      for fragment in legacy.fragments.mitems:
        # The shape the key had before: artifact | entry point | body hash |
        # argument digest | lock slice | activity | namespace.
        fragment.invocationKey = fragment.providerArtifactId & "|" &
          fragment.entryPointId & "|" & fragment.entryPointBodyHash & "|" &
          argumentDigest(fragment.arguments) & "|" & fragment.lockSliceId &
          "|" & fragment.activity & "|" & fragment.namespace
        legacyKeys[invocation(fragment)] = fragment.invocationKey
      saveProviderGraphSnapshot(store, legacy)
      fx.materializeOutputs()

      let migrated = fx.refresh(store, providerV1, ArtifactV1)
      checkpoint("invoked: " & $migrated.invoked.mapIt(it.entryPointId))
      check migrated.invoked.len == 3
      check keysByInvocation(migrated.snapshot) == keys
      check onePerInvocation(migrated.snapshot)
      check ascending(migrated.prunedInvocationKeys) == sortedValues(legacyKeys)
      checkCleanupProtectsEveryOutput(fx, migrated)

      let warm = fx.refresh(store, providerV1, ArtifactV1)
      check warm.invoked.len == 0
      check keysByInvocation(warm.snapshot) == keys
