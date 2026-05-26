## Standard provider binary for convention-only packages (Tier 2b).
##
## The Reprobuild engine routes any package whose declaration omits a
## ``build:`` block to this binary instead of compiling a per-project
## ``reprobuild.nim``. The binary walks the package's source tree
## following the ecosystem's conventional layout and emits the build
## graph directly.
##
## Per Provider-Compile-Tiering.md §"2b — repro-standard-provider" and
## Language-Conventions/README.md.
##
## **M0 scaffold.** This first revision is a skeleton: it answers
## ``--version`` with a stable string, advertises one placeholder entry
## point in its manifest, and returns an empty ``GraphFragment`` for
## graph-invocation requests. The convention dispatch framework lands
## in M1; per-language fragments land in M3+.

import std/[os]

import repro_provider_runtime
import repro_standard_provider_protocol

const
  StandardProviderVersion = "0.0.1-m0-scaffold"
    ## Bump whenever ``--version`` output should change for release
    ## tracking. Engine routing keys off
    ## ``StandardProviderArtifactId``, not this string — this exists
    ## for humans inspecting the binary.

proc parseEarlyFlags(args: openArray[string]): tuple[wantVersion: bool] =
  for arg in args:
    if arg == "--version":
      result.wantVersion = true
      return

proc placeholderManifest(providerArtifactId: string): ProviderManifest =
  ## Manifest the M0 scaffold advertises. Engine validation requires
  ## the returned ``providerArtifactId`` to match the request when the
  ## request supplied one; falling back to
  ## ``StandardProviderArtifactId`` keeps stand-alone smoke runs
  ## working when the caller leaves it empty.
  ProviderManifest(
    providerArtifactId:
      if providerArtifactId.len > 0: providerArtifactId
      else: StandardProviderArtifactId,
    protocolVersion: ProviderProtocolVersion,
    entryPoints: @[
      GraphEntryPointDescriptor(
        id: "standardProvider.placeholder",
        kind: gpkProjectRoot,
        stableName: StandardProviderPackageName,
        bodyHash: StandardProviderRootBodyHash,
        argumentSchemaId: "reprobuild.project-root.v1",
        outputSchemaId: "reprobuild.graph-fragment.v1")
    ])

proc placeholderFragment(request: ProviderGraphRequest): GraphFragment =
  ## Empty graph fragment — no nodes, no edges — echoing the request's
  ## entry-point + arguments so engine-side validation passes the
  ## structural checks even though there is no real graph to consume.
  ## The digest is recomputed here because callers like
  ## ``invokeProviderEntryPoint`` cross-check it against
  ## ``computeGraphFragmentDigest``.
  result = GraphFragment(
    entryPointId: request.entryPointId,
    entryPointBodyHash: request.entryPointBodyHash,
    arguments: request.arguments,
    namespace: request.namespace)
  result.fragmentDigest = computeGraphFragmentDigest(result)

when defined(reproProviderMode):
  proc runStandardProvider(): int =
    try:
      let args = commandLineParams()
      let early = parseEarlyFlags(args)
      if early.wantVersion:
        stdout.writeLine("repro-standard-provider " &
          StandardProviderVersion)
        return 0
      let paths = parseProviderProtocolArgs(args)
      let request = readProviderRequestFile(paths.requestPath)
      let manifest = placeholderManifest(request.providerArtifactId)
      case request.kind
      of prkManifest:
        writeProviderResponseFile(paths.responsePath,
          manifestResponse(manifest))
      of prkGraphInvocation:
        let fragment = placeholderFragment(request)
        writeProviderResponseFile(paths.responsePath,
          graphResponse(manifest, fragment))
      of prkDevEnvIntrospection:
        stderr.writeLine(
          "repro-standard-provider: dev-env introspection not supported " &
          "in the M0 scaffold")
        return 2
      0
    except CatchableError as err:
      stderr.writeLine("repro-standard-provider: " & err.msg)
      1

  when isMainModule:
    quit runStandardProvider()
else:
  when isMainModule:
    # Allow `--version` even outside provider mode so packaging
    # smoke-tests can identify the binary without enabling the
    # protocol surface. Anything else falls through to a hard error so
    # an accidental release build without ``-d:reproProviderMode``
    # fails loudly.
    let args = commandLineParams()
    let early = parseEarlyFlags(args)
    if early.wantVersion:
      stdout.writeLine("repro-standard-provider " &
        StandardProviderVersion)
      quit 0
    stderr.writeLine(
      "repro-standard-provider must be compiled with -d:reproProviderMode")
    quit 2
