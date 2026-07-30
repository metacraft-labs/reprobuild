## Integration test: file-driven generator fan-out + owned-effect-claim cleanup.
##
## This mirrors the codetracer-marketing video pipeline's model exactly: a single
## editable file (there, `timeline.json`) is read as a *tracked* evaluation input
## and the project root fans out one owning edge per entry in that file (there,
## one audio-clip action per sentence). Everything lives in the ROOT fragment —
## the "eval-time fan-out" model — so on a file change the root re-runs and the
## refresh diffs its owned effect claims. (A child-entry-point-per-line model
## would NOT reconcile add/remove today: only directory enumeration has bespoke
## membership handling; a `gevFileRead` change re-runs just the reading fragment.
## This test pins the model that actually works.)
##
## It uses a real compiled fixture provider driven through the real
## `refreshProviderGraph` protocol — no CodeTracer, no ffmpeg, no bearssl — and
## asserts the properties the user asked about:
##   * edit one entry  -> the generator re-runs, but no output is deleted
##                        (the entry's output identity is unchanged);
##   * add an entry     -> its claim appears, nothing is deleted;
##   * remove an entry  -> its edge's owned output is reported stale AND deleted,
##                        while the surviving entries' outputs are retained.

import std/[algorithm, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_core
import repro_provider_runtime
import repro_test_support

const
  RootEntryPoint = "fixture.root"
  RootBodyHash = "root-body-v1"
  Artifact = "file-fanout-artifact-v1"

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc requireNimSuccess(args: openArray[string]; cwd = getCurrentDir()): string =
  let res = execCmdEx(args.mapIt(q(it)).join(" "), workingDir = cwd)
  if res.exitCode != 0:
    checkpoint(res.output)
    raise newException(OSError, "nim command failed with code " & $res.exitCode)
  res.output

proc writeFixtureProvider(path: string) =
  ## A provider whose ROOT reads the timeline file and emits one action + one
  ## owned file claim per non-empty "id|text" line — the eval-time fan-out.
  writeFile(path, """
import std/[os, strutils]
import repro_provider_runtime

const
  RootEntryPoint = "fixture.root"
  RootBodyHash = "root-body-v1"
  Artifact = "file-fanout-artifact-v1"

proc fixtureManifest(): ProviderManifest =
  ProviderManifest(
    providerArtifactId: Artifact,
    protocolVersion: ProviderProtocolVersion,
    entryPoints: @[
      GraphEntryPointDescriptor(
        id: RootEntryPoint, kind: gpkProjectRoot, stableName: "root",
        bodyHash: RootBodyHash, argumentSchemaId: "root-args-v1",
        outputSchemaId: "fragment-v1")])

proc rootFragment(request: ProviderGraphRequest): GraphFragment =
  let timelinePath = request.arguments
  result = GraphFragment(
    entryPointId: request.entryPointId,
    entryPointBodyHash: request.entryPointBodyHash,
    arguments: request.arguments,
    namespace: request.namespace,
    evaluationInputs: @[fileReadInput(timelinePath)])
  for rawLine in readFile(timelinePath).splitLines:
    let line = rawLine.strip()
    if line.len == 0: continue
    let id = line.split('|', 1)[0].strip()
    let actionNode = request.namespace & ":action:" & id
    let outputNode = request.namespace & ":output:" & id
    result.nodes.add(GraphNode(id: actionNode, kind: gnkAction,
      stableName: "action:" & id, payload: id))
    result.nodes.add(GraphNode(id: outputNode, kind: gnkGeneratedOutput,
      stableName: "output:" & id, payload: "build/clips/" & id & ".wav"))
    result.edges.add(GraphEdge(id: request.namespace & ":edge:" & id,
      kind: gekProduces, fromNode: actionNode, toNode: outputNode))
    result.effectClaims.add(OwnedEffectClaim(kind: oekFile,
      stableName: "output:" & id, identity: "build/clips/" & id & ".wav",
      cleanupPolicy: cplDeleteWhenUnclaimed, payload: id))
  result.fragmentDigest = computeGraphFragmentDigest(result)

when isMainModule:
  let args = commandLineParams()
  let paths = parseProviderProtocolArgs(args)
  let request = readProviderRequestFile(paths.requestPath)
  let manifest = fixtureManifest()
  case request.kind
  of prkManifest:
    writeProviderResponseFile(paths.responsePath, manifestResponse(manifest))
  of prkGraphInvocation:
    writeProviderResponseFile(paths.responsePath,
      graphResponse(manifest, rootFragment(request)))
  of prkDevEnvIntrospection:
    quit("dev-env introspection not implemented", 2)
""")

proc compileProvider(sourcePath, outputPath, nimcache: string): string =
  createDir(parentDir(outputPath))
  createDir(nimcache)
  discard requireNimSuccess(@["nim", "c", "--verbosity:0", "--hints:off",
    "--nimcache:" & nimcache, "--out:" & outputPath, sourcePath])
  outputPath

proc claimIdentities(snapshot: ProviderGraphSnapshot): seq[string] =
  for fragment in snapshot.fragments:
    for claim in fragment.effectClaims:
      result.add(claim.identity)
  result.sort()

proc staleIdentities(report: ProviderRefreshReport): seq[string] =
  for stale in report.staleEffects:
    result.add(stale.claim.identity)

proc rootReran(report: ProviderRefreshReport): bool =
  report.invoked.anyIt(it.entryPointId == RootEntryPoint)

suite "provider file-driven fan-out + cleanup":
  when isNixSupported:
    test "editing/adding/removing timeline entries drives correct cleanup":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-file-fanout", "")
      defer: removeDir(tempRoot)
      let fixtureSourceDir = repoRoot / "build" / "provider-fixtures" /
        splitPath(tempRoot).tail
      createDir(fixtureSourceDir)
      defer:
        if dirExists(fixtureSourceDir): removeDir(fixtureSourceDir)

      let binDir = tempRoot / "bin"
      let storeRoot = tempRoot / "store"
      let outRoot = tempRoot / "out"          # where declared outputs "live"
      createDir(binDir)
      createDir(storeRoot)
      let timelinePath = tempRoot / "timeline.txt"

      let providerSource = fixtureSourceDir / "file_fanout_provider.nim"
      writeFixtureProvider(providerSource)
      let providerBin = compileProvider(providerSource, binDir / "provider",
        tempRoot / "nimcache-provider")

      proc refresh(): ProviderRefreshReport =
        refreshProviderGraph(RefreshConfig(
          storeRoot: storeRoot,
          providerBinaryPath: providerBin,
          providerArtifactId: Artifact,
          rootEntryPointId: RootEntryPoint,
          rootArguments: timelinePath,
          namespace: "project",
          lockSliceId: "lock-v1",
          activity: "build",
          providerWorkingDir: repoRoot))

      proc materialize(id: string) =
        let p = outRoot / "build" / "clips" / (id & ".wav")
        createDir(p.parentDir)
        writeFile(p, "audio:" & id)

      proc clipExists(id: string): bool =
        fileExists(outRoot / "build" / "clips" / (id & ".wav"))

      # --- cold: two entries a, b ---
      writeFile(timelinePath, "a|alpha\nb|bravo\n")
      let cold = refresh()
      check cold.snapshot.fragments.len == 1        # one root fragment
      check claimIdentities(cold.snapshot) ==
        @["build/clips/a.wav", "build/clips/b.wav"]
      materialize("a")
      materialize("b")

      # --- edit entry a's text: root re-runs, but claims are unchanged ---
      writeFile(timelinePath, "a|ALPHA CHANGED\nb|bravo\n")
      let edited = refresh()
      check rootReran(edited)
      check edited.invoked[0].reason == girEvaluationInputChanged
      check edited.staleEffects.len == 0
      let editedClean = applyOutputCleanup(edited, outRoot)
      check editedClean.deleted == 0
      check clipExists("a") and clipExists("b")

      # --- add entry c: new claim appears, nothing deleted ---
      writeFile(timelinePath, "a|ALPHA CHANGED\nb|bravo\nc|charlie\n")
      let added = refresh()
      check rootReran(added)
      check claimIdentities(added.snapshot) ==
        @["build/clips/a.wav", "build/clips/b.wav", "build/clips/c.wav"]
      check added.staleEffects.len == 0
      check applyOutputCleanup(added, outRoot).deleted == 0
      materialize("c")

      # --- remove entry b: its owned output is reported stale AND cleaned up ---
      writeFile(timelinePath, "a|ALPHA CHANGED\nc|charlie\n")
      let removed = refresh()
      check rootReran(removed)
      check claimIdentities(removed.snapshot) ==
        @["build/clips/a.wav", "build/clips/c.wav"]
      check staleIdentities(removed).contains("build/clips/b.wav")
      let removedClean = applyOutputCleanup(removed, outRoot)
      check removedClean.deleted == 1
      check not clipExists("b")                     # orphaned clip reclaimed
      check clipExists("a") and clipExists("c")     # survivors retained
