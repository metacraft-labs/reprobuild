## t_provider_refresh_rechecks_env_and_scoped_scans — the provider-graph
## refresh re-checks two kinds of evaluation input a convention reports when
## it keys its graph on what an emit-time tool was observed to read
## (the Nim and Go conventions' emit-time runs):
##
##   * an environment variable, reported as the host fact ``env:<NAME>``
##     (Project-Provider-Graph-Protocol.md §"Evaluation Inputs"). Changing,
##     setting or unsetting it re-invokes the entry point that read it;
##     leaving it alone does not. Before, the refresh ignored host facts, so
##     a graph derived from an environment variable outlived every change to
##     it;
##   * a pattern-scoped directory scan (the io monitor's record of a glob
##     such as Nim's search of a module's ancestors for ``*.nimble``),
##     reported under the directory's pattern-scoped name. Only an entry that
##     matches the pattern re-invokes; any other entry created in the
##     directory does not, which is what makes a scan of ``/nix/store`` a
##     usable input at all.
##
## Mocks: none in the engine. The provider is a real binary compiled from a
## fixture written here, spoken to over the real provider protocol, and the
## refresh is the engine's own ``refreshProviderGraph`` against a real store.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_provider_runtime
import repro_local_store/pattern_scoped_enumeration

import lints/ambient_execution

const
  RootEntryPoint = "fixture.root"
  RootBodyHash = "root-body-v1"
  ArtifactId = "fixture-env-scan-provider-v1"
  ProbeVar = "REPRO_HOSTFACT_REFRESH_PROBE"

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc writeFixtureProvider(path: string) =
  ## The root fragment reads ``ProbeVar`` and scans its argument directory
  ## for ``*.nimble``, and records an invocation in the counts file.
  writeFile(path, """
import std/os
import repro_provider_runtime
import repro_local_store/pattern_scoped_enumeration

proc manifest(): ProviderManifest =
  ProviderManifest(
    providerArtifactId: "$1",
    protocolVersion: ProviderProtocolVersion,
    entryPoints: @[GraphEntryPointDescriptor(
      id: "$2", kind: gpkProjectRoot, stableName: "root",
      bodyHash: "$3", argumentSchemaId: "root-args-v1",
      outputSchemaId: "fragment-v1")])

when isMainModule:
  let args = commandLineParams()
  let paths = parseProviderProtocolArgs(args)
  let request = readProviderRequestFile(paths.requestPath)
  case request.kind
  of prkManifest:
    writeProviderResponseFile(paths.responsePath, manifestResponse(manifest()))
  of prkGraphInvocation:
    let counts = args[args.find("--fixture-counts") + 1]
    writeFile(counts, readFile(counts) & "root\n")
    var fragment = GraphFragment(
      entryPointId: request.entryPointId,
      entryPointBodyHash: request.entryPointBodyHash,
      arguments: request.arguments,
      namespace: request.namespace,
      nodes: @[GraphNode(id: request.namespace & ":root", kind: gnkAction,
        stableName: "root", payload: getEnv("$4"))],
      evaluationInputs: @[
        environmentInput("$4"),
        directoryEnumerationInput(
          patternScopedEnumerationPath(request.arguments, "*.nimble"), "",
          "")])
    fragment.fragmentDigest = computeGraphFragmentDigest(fragment)
    writeProviderResponseFile(paths.responsePath,
      graphResponse(manifest(), fragment))
  of prkDevEnvIntrospection:
    quit("not implemented by this fixture", 2)
""" % [ArtifactId, RootEntryPoint, RootBodyHash, ProbeVar])

proc invocations(path: string): int =
  readFile(path).splitLines.filterIt(it.strip.len > 0).len

suite "provider refresh re-checks environment and pattern-scoped inputs":
  test "an environment variable and a *.nimble scan invalidate only on change":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-env-scan-refresh", "")
    let fixtureDir = repoRoot / "build" / "provider-fixtures" /
      splitPath(tempRoot).tail
    let hadProbe = existsEnv(ProbeVar)
    let savedProbe = getEnv(ProbeVar)
    defer:
      removeDir(tempRoot)
      removeDir(fixtureDir)
      if hadProbe: putEnv(ProbeVar, savedProbe)
      else: delEnv(ProbeVar)
    createDir(fixtureDir)
    let scanned = tempRoot / "scanned"
    let store = tempRoot / "store"
    let counts = tempRoot / "counts.log"
    createDir(scanned)
    createDir(store)
    writeFile(counts, "")
    let source = fixtureDir / "env_scan_provider.nim"
    writeFixtureProvider(source)
    let provider = tempRoot / "bin" / "env-scan-provider"
    createDir(parentDir(provider))
    # Compiling the fixture with the host Nim is the bootstrap-tier boundary
    # this test needs; marked so the ambient-execution lint leaves it alone.
    let compile = uncontrolledExecCmdEx(@["nim", "c", "--verbosity:0",
      "--hints:off", "--nimcache:" & tempRoot / "nimcache",
      "--out:" & provider, source].mapIt(q(it)).join(" "),
      workingDir = repoRoot)
    checkpoint compile.output
    require compile.exitCode == 0

    proc refresh(): ProviderRefreshReport =
      refreshProviderGraph(RefreshConfig(
        storeRoot: store,
        projectId: "fixture",
        providerBinaryPath: provider,
        providerArtifactId: ArtifactId,
        rootEntryPointId: RootEntryPoint,
        rootArguments: scanned,
        namespace: "workspace",
        lockSliceId: "lock-v1",
        activity: "build",
        providerExtraArgs: @["--fixture-counts", counts],
        providerWorkingDir: repoRoot))

    putEnv(ProbeVar, "one")
    discard refresh()
    check invocations(counts) == 1
    discard refresh()
    checkpoint "nothing changed"
    check invocations(counts) == 1

    putEnv(ProbeVar, "two")
    discard refresh()
    checkpoint "the variable changed"
    check invocations(counts) == 2
    delEnv(ProbeVar)
    discard refresh()
    checkpoint "the variable was unset"
    check invocations(counts) == 3
    discard refresh()
    check invocations(counts) == 3
    putEnv(ProbeVar, "")
    discard refresh()
    checkpoint "the variable was set, to the empty string"
    check invocations(counts) == 4

    writeFile(scanned / "notes.txt", "not a package file\n")
    createDir(scanned / "build")
    discard refresh()
    checkpoint "entries the scan's pattern does not match appeared"
    check invocations(counts) == 4
    writeFile(scanned / "pkg.nimble", "version = \"0.1.0\"\n")
    discard refresh()
    checkpoint "an entry the scan's pattern matches appeared"
    check invocations(counts) == 5
    removeFile(scanned / "pkg.nimble")
    discard refresh()
    checkpoint "it went again"
    check invocations(counts) == 6

  test "a host fact this build cannot evaluate never reads as unchanged":
    check hostFactDigest("os:linux") == ""
    check hostFactDigest("env:") == ""
    check environmentInput("PATH").digest == hostFactDigest("env:PATH")
    check environmentInput("PATH").digest != getEnv("PATH")
