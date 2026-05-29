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
## **M1 framework.** Manifest requests advertise a single canonical
## entry point — ``StandardProviderRootEntryPointId`` — from the shared
## ``repro_standard_provider_protocol`` library (the manifest's shape
## doesn't depend on conventions — see
## Standard-Provider-Implementation.milestones.org §M1). Graph requests
## dispatch through ``defaultConventionRegistry``; on the first
## ``recognize`` hit the convention's ``emitFragment`` produces the
## fragment, otherwise we exit non-zero with a "no convention matched"
## diagnostic that names the project root and the package's ``uses:``
## hint (parsed heuristically — see project_intro.nim). Per-language
## convention plugins land in M3+.

import std/[options, os, strutils]

import repro_provider_runtime
import repro_standard_provider/convention
import repro_standard_provider/conventions/nim as nim_convention
import repro_standard_provider/conventions/rust as rust_convention
import repro_standard_provider/conventions/rust_direct as rust_direct_convention
import repro_standard_provider/conventions/go as go_convention
import repro_standard_provider/conventions/go_direct as go_direct_convention
import repro_standard_provider/conventions/python as python_convention
import repro_standard_provider/conventions/javascript_typescript as jsts_convention
import repro_standard_provider/conventions/c_cpp_make as c_cpp_make_convention
import repro_standard_provider/conventions/c_cpp_autotools as c_cpp_autotools_convention
import repro_standard_provider/conventions/c_cpp_direct as c_cpp_direct_convention
import repro_standard_provider/project_intro
import repro_standard_provider_protocol

const
  StandardProviderVersion = "0.0.2-m1-framework"
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
  ## Manifest the standard provider advertises. The single canonical
  ## entry point uses ``StandardProviderRootEntryPointId`` — the engine
  ## (M2) dispatches on that id, and the M0/M1 smoke + no-match scripts
  ## now use it too (the legacy ``standardProvider.placeholder`` alias
  ## was dropped after M3 once real conventions are registered). Engine
  ## validation requires the returned ``providerArtifactId`` to match
  ## the request when the request supplied one; falling back to
  ## ``StandardProviderArtifactId`` keeps stand-alone smoke runs working
  ## when the caller leaves it empty.
  ProviderManifest(
    providerArtifactId:
      if providerArtifactId.len > 0: providerArtifactId
      else: StandardProviderArtifactId,
    protocolVersion: ProviderProtocolVersion,
    entryPoints: @[
      GraphEntryPointDescriptor(
        id: StandardProviderRootEntryPointId,
        kind: gpkProjectRoot,
        stableName: StandardProviderPackageName,
        bodyHash: StandardProviderRootBodyHash,
        argumentSchemaId: "reprobuild.project-root.v1",
        outputSchemaId: "reprobuild.graph-fragment.v1")
    ])

proc projectRootFromRequest(request: ProviderGraphRequest): string =
  ## At M1 the engine passes the project root via ``request.arguments``
  ## as a bare path string — same shape the Tier 2c trycompile provider
  ## uses. M2 will replace this with an interface-artifact handle.
  request.arguments.strip()

proc formatUsesHint(uses: seq[string]): string =
  if uses.len == 0:
    "(none declared)"
  else:
    uses.join(", ")

proc noConventionMatchedMessage(projectRoot: string;
                                uses: seq[string]): string =
  ## Diagnostic message emitted when no convention recognises the
  ## project. The substring ``"no convention matched"`` is part of the
  ## contract — ``scripts/validate-standard-provider-no-match.ps1``
  ## greps for it.
  "repro-standard-provider: no convention matched for project root '" &
    projectRoot & "' (uses: " & formatUsesHint(uses) & ")"

proc dispatchGraphRequest(request: ProviderGraphRequest):
    tuple[fragment: GraphFragment; matched: bool; projectRoot: string;
          uses: seq[string]] =
  ## Look up the first matching convention against
  ## ``defaultConventionRegistry`` and delegate to it. ``matched=false``
  ## tells the caller to emit the diagnostic and exit non-zero.
  let projectRoot = projectRootFromRequest(request)
  let uses = readUsesHint(projectRoot)
  let hit = firstMatchingConvention(defaultConventionRegistry,
    projectRoot, request)
  if hit.isSome:
    var fragment = hit.get.emitFragment(projectRoot, request)
    # Make sure the convention's emitFragment didn't forget to echo
    # back the request's identity — the engine cross-checks these.
    if fragment.entryPointId.len == 0:
      fragment.entryPointId = request.entryPointId
    if fragment.entryPointBodyHash.len == 0:
      fragment.entryPointBodyHash = request.entryPointBodyHash
    if fragment.arguments.len == 0:
      fragment.arguments = request.arguments
    if fragment.namespace.len == 0:
      fragment.namespace = request.namespace
    if fragment.fragmentDigest.len == 0:
      fragment.fragmentDigest = computeGraphFragmentDigest(fragment)
    return (fragment, true, projectRoot, uses)
  let empty = GraphFragment(
    entryPointId: request.entryPointId,
    entryPointBodyHash: request.entryPointBodyHash,
    arguments: request.arguments,
    namespace: request.namespace)
  (empty, false, projectRoot, uses)

when defined(reproProviderMode):
  # Register the language convention plugins this binary ships with.
  # The Nim convention is the first one to land (M3); the Rust
  # convention (M4) follows, the Go convention (M5) after that, the
  # Python convention (M15), the JavaScript/TypeScript convention
  # (M16), and the C/C++ Make + Autotools conventions (M17) close out
  # the milestone series' Mode A first wave. Future milestones add
  # CMake direct / etc. here in registration-order which is also
  # match-order. The list of registered conventions MUST stay in sync
  # with ``RegisteredStandardConventionToolchains`` in
  # ``libs/repro_interface_artifacts/src/repro_interface_artifacts.nim``
  # — the engine should only mark a package as standardBuildEligible
  # when at least one registered convention is plausibly going to match
  # it.
  #
  # Registration order between c-cpp-make and c-cpp-autotools matters:
  # c-cpp-autotools is registered FIRST so a project carrying both a
  # Makefile (generated or hand-written) and ``configure.ac`` /
  # ``Makefile.am`` routes through the Autotools convention. The
  # c-cpp-make ``recognize`` separately rejects projects with Autotools
  # artefacts so the order is defensive in either direction.
  addDefaultConvention(nim_convention.nimConvention())
  addDefaultConvention(rust_convention.rustConvention())
  addDefaultConvention(go_convention.goConvention())
  addDefaultConvention(python_convention.pythonConvention())
  addDefaultConvention(jsts_convention.javaScriptTypeScriptConvention())
  addDefaultConvention(c_cpp_autotools_convention.cCppAutotoolsConvention())
  addDefaultConvention(c_cpp_make_convention.cCppMakeConvention())
  # c_cpp_direct (Mode 3 / no-Makefile) is registered LAST among the
  # C/C++ conventions so a project shipping a Makefile routes through
  # the Make convention first; Mode 3 picks up the no-Makefile case
  # where the user declared their project shape in ``repro.nim`` with
  # no ecosystem manifest at all.
  addDefaultConvention(c_cpp_direct_convention.cCppDirectConvention())
  # rust_direct (Mode 3 / no-Cargo.toml) registered AFTER the Mode 2
  # rust convention so a project shipping a Cargo.toml routes through
  # the Mode 2 path first; Mode 3 picks up the case where the user
  # declared their crate shape in ``repro.nim`` with no Cargo
  # manifest. M30 of Mode3-Language-Expansion.milestones.org.
  addDefaultConvention(rust_direct_convention.rustDirectConvention())
  # go_direct (Mode 3 / no-go.mod) registered AFTER the Mode 2 go
  # convention so a project shipping a go.mod routes through the
  # Mode 2 path first; Mode 3 picks up the case where the user
  # declared their package shape in ``repro.nim`` with no Go module
  # manifest. M31 of Mode3-Language-Expansion.milestones.org.
  addDefaultConvention(go_direct_convention.goDirectConvention())

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
        let outcome = dispatchGraphRequest(request)
        if not outcome.matched:
          stderr.writeLine(noConventionMatchedMessage(outcome.projectRoot,
            outcome.uses))
          return 3
        writeProviderResponseFile(paths.responsePath,
          graphResponse(manifest, outcome.fragment))
      of prkDevEnvIntrospection:
        stderr.writeLine(
          "repro-standard-provider: dev-env introspection not supported " &
          "in the M1 framework")
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
