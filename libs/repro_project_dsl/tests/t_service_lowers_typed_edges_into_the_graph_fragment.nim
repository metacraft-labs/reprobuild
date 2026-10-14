## Shared-Development-Services L1 — a ``service`` lowers into the provider
## graph fragment as a ``gnkService`` node carrying typed executable, args
## and runtime-file EDGES, not a metadata string.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The fragment is produced by the real ``buildPackageFragment`` over the
## real ``package`` macro's output, and the node payload is decoded by the
## real codec. The dev-env half runs the real ``buildPackageDevEnv``. A
## hand-built fragment would test nothing: what is under test is what the
## provider emits.
##
## Compiled with ``--define:reproProviderMode`` (registered in
## ``scripts/generate_test_edges.nim``'s ``isProviderModePath``) because
## ``buildPackageFragment``, ``buildPackageDevEnv`` and
## ``servicePlaceholder`` only exist in that mode. Fixtures live in
## ``service_fragment_fixtures.nim`` so the auto-generated
## ``runPackageProvider`` shim's ``isMainModule`` guard doesn't fire here.
##
## Governing spec text:
##
## * ``Shared-Development-Services.md`` §1 — "A dev-env service is
##   declared with ``servicePlaceholder(name, metadata, activities)`` — a
##   name, an activity list and an **opaque metadata string** the engine
##   interprets. There is no composition, no typed reference".
## * ``Package-Model.md`` §Collections — the ``executable`` / ``args`` /
##   ``runtimeFile`` / ``on <trigger>:`` setter list.
## * ``Shared-Development-Services.milestones.org`` L1 ``:gate:`` — "the
##   service's lowered record carries typed executable + args +
##   runtime-file edges rather than a metadata string" and
##   "``servicePlaceholder`` keeps working unchanged".

import std/[strutils, unittest]

from repro_core/codec import toBytes
import repro_project_dsl

import service_fragment_fixtures

proc fixturePackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "fixture package missing: " & name)

proc graphRequest(pkg: PackageDef): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: pkg.packageName & ".root",
    entryPointBodyHash: pkg.packageName & ".build.v1",
    reason: girExplicitUserRequest,
    arguments: "/tmp/sso-fragment-fixture-root",
    namespace: "project-" & pkg.packageName)

proc devEnvRequest(pkg: PackageDef; activity: string):
    ProviderGraphRequest =
  result = graphRequest(pkg)
  result.entryPointId = pkg.packageName & ".dev-env"
  result.activity = activity

let fixture = fixturePackage("ssoFragmentPkg")
let fragment = buildPackageFragment(fixture, graphRequest(fixture),
  buildSsoFragmentPkgPackage, includeDefault = false)

proc serviceNodes(): seq[GraphNode] =
  for node in fragment.nodes:
    if node.kind == gnkService:
      result.add(node)

proc actionNodeId(actionId: string): string =
  for node in fragment.nodes:
    if node.kind == gnkAction and node.stableName == actionId:
      return node.id
  raise newException(ValueError, "no action node for " & actionId)

proc outputNodeId(path: string): string =
  for node in fragment.nodes:
    if node.kind == gnkGeneratedOutput and node.stableName == path:
      return node.id
  raise newException(ValueError, "no output node for " & path)

proc edgesFrom(nodeId: string; kind: GraphEdgeKind):
    seq[repro_provider_runtime.GraphEdge] =
  for edge in fragment.edges:
    if edge.fromNode == nodeId and edge.kind == kind:
      result.add(edge)

suite "L1 — the fragment carries one gnkService node per service":

  test "gnkService is emitted at all — nothing ever emitted one before":
    let nodes = serviceNodes()
    check nodes.len == 1
    check nodes[0].kind == gnkService
    check nodes[0].stableName == "sso"
    check nodes[0].id == "project-ssoFragmentPkg:service:sso"

  test "the payload decodes to the typed record, not to a string":
    let decoded = decodeServicePayload(toBytes(serviceNodes()[0].payload))
    check decoded.packageName == "ssoFragmentPkg"
    check decoded.serviceName == "sso"
    check decoded.executableTyped.kind == sxkArtifact
    check decoded.executableTyped.executableName == "zitadelBin"
    check decoded.args == @["start-from-init", "--config", ConfigPath]
    check decoded.typedArgs[0].kind == svakLiteral
    check decoded.typedArgs[1].kind == svakLiteral
    check decoded.typedArgs[2].kind == svakBuildOutput
    check decoded.typedArgs[2].producerActionId == RenderConfigActionId
    check decoded.typedArgs[2].producerPath == ConfigPath
    check decoded.runtimeFiles.len == 1
    check decoded.runtimeFiles[0].path == StepsPath
    check decoded.runtimeFiles[0].producerActionId == RenderStepsActionId
    check decoded.triggers.len == 1
    check decoded.triggers[0].kind == stkChangeOutput
    check decoded.triggers[0].subject == ConfigPath
    check decoded.triggers[0].producerActionId == RenderConfigActionId
    check decoded.triggers[0].actions[0].kind == stakSendSignal
    check decoded.triggers[0].actions[0].argument == "SIGHUP"

suite "L1 — the typed references are graph EDGES":

  test "one gekDependsOn per distinct producing action":
    let svcNodeId = serviceNodes()[0].id
    let deps = edgesFrom(svcNodeId, gekDependsOn)
    check deps.len == 2
    var targets: seq[string] = @[]
    for edge in deps:
      targets.add(edge.toNode)
    check actionNodeId(RenderConfigActionId) in targets
    check actionNodeId(RenderStepsActionId) in targets

  test "one gekConsumes per referenced output, pointing at its own node":
    let svcNodeId = serviceNodes()[0].id
    let consumes = edgesFrom(svcNodeId, gekConsumes)
    # The config is referenced twice -- on argv and by the `on change`
    # watch -- and that is ONE consumed output, not two.
    check consumes.len == 2
    var targets: seq[string] = @[]
    for edge in consumes:
      targets.add(edge.toNode)
    check outputNodeId(ConfigPath) in targets
    check outputNodeId(StepsPath) in targets

  test "the control: a path with no producer gets no edge":
    # Every edge emitted must correspond to an action that is actually in
    # this fragment, so a literal argument cannot acquire one.
    let svcNodeId = serviceNodes()[0].id
    let total = edgesFrom(svcNodeId, gekDependsOn).len +
      edgesFrom(svcNodeId, gekConsumes).len
    check total == 4
    let decoded = decodeServicePayload(toBytes(serviceNodes()[0].payload))
    check decoded.typedArgs[0].producerActionId == ""
    check decoded.typedArgs[1].producerActionId == ""

suite "L1 — why the service body is re-evaluated after the build body":

  test "at module init the handle was unassigned; the fragment's is not":
    # In provider mode ``emitM4BuildActions`` gates the ``build:`` splice
    # on ``not defined(reproProviderMode)``, so at module-init time the
    # rendered config does not exist yet and the service's argv records an
    # EMPTY path. This is the measurement behind
    # ``rerunServiceDeclarators``: without the re-run the lowered record
    # would carry that empty path and nothing would say so.
    check servicesAtModuleInit.len == 1
    check servicesAtModuleInit[0].serviceName == "sso"
    check servicesAtModuleInit[0].typedArgs[2].value == ""
    check servicesAtModuleInit[0].typedArgs[2].producerActionId == ""
    let decoded = decodeServicePayload(toBytes(serviceNodes()[0].payload))
    check decoded.typedArgs[2].value == ConfigPath
    check decoded.typedArgs[2].producerActionId == RenderConfigActionId

  test "a structural-iterator MEMBER fragment carries no service node":
    # ``foreachDispatch`` routes through ``buildPackageFragment`` once per
    # member (``foreachDispatchCode`` in ``macros_b.nim``) with the member's
    # entry-point id and the ROOT's namespace. Emitting the service there
    # would put N+1 copies of the same node, under the same id, into one
    # snapshot -- and would re-record the service body against whatever the
    # last root invocation left in the module-level handles. A service
    # belongs to the package, so it is emitted where the package's own
    # build is and nowhere else.
    var memberRequest = graphRequest(fixture)
    memberRequest.entryPointId = "ssoFragmentPkg.foreach.member"
    let memberFragment = buildPackageFragment(fixture, memberRequest,
      buildSsoFragmentPkgPackage, includeDefault = false)
    var memberServiceNodes = 0
    for node in memberFragment.nodes:
      if node.kind == gnkService:
        inc memberServiceNodes
    check memberServiceNodes == 0
    # The control: the ROOT request against the same fixture still emits
    # one, so this is a statement about the entry point and not about the
    # fixture having lost its service.
    let rootAgain = buildPackageFragment(fixture, graphRequest(fixture),
      buildSsoFragmentPkgPackage, includeDefault = false)
    var rootServiceNodes = 0
    for node in rootAgain.nodes:
      if node.kind == gnkService:
        inc rootServiceNodes
    check rootServiceNodes == 1

  test "re-lowering the same package twice is idempotent":
    let again = buildPackageFragment(fixture, graphRequest(fixture),
      buildSsoFragmentPkgPackage, includeDefault = false)
    var againNodes: seq[GraphNode] = @[]
    for node in again.nodes:
      if node.kind == gnkService:
        againNodes.add(node)
    check againNodes.len == 1
    check againNodes[0].payload == serviceNodes()[0].payload
    check again.fragmentDigest == fragment.fragmentDigest

suite "L1 — servicePlaceholder keeps working unchanged":

  test "the dev-env result still carries the opaque metadata string":
    let devEnv = buildPackageDevEnv(fixture,
      devEnvRequest(fixture, "stack"), devEnvSsoFragmentPkgPackage)
    check devEnv.services.len == 1
    check devEnv.services[0].name == "legacy-stack"
    check devEnv.services[0].activityRequirements == @["stack"]
    check devEnv.services[0].metadata.contains(
      "reprobuild.dev-session.service.v1")
    check devEnv.services[0].metadata.contains("scripts/stack.sh")

  test "a placeholder is activity-gated exactly as before":
    let devEnv = buildPackageDevEnv(fixture,
      devEnvRequest(fixture, ""), devEnvSsoFragmentPkgPackage)
    check devEnv.declaredActivities == @["stack"]
    check devEnv.services.len == 0

  test "the typed service lane and the placeholder lane are disjoint":
    # The dev-env result must NOT have grown the typed service, and the
    # fragment must NOT have grown the placeholder. L1 is additive: the
    # two surfaces coexist rather than one shadowing the other.
    let devEnv = buildPackageDevEnv(fixture,
      devEnvRequest(fixture, "stack"), devEnvSsoFragmentPkgPackage)
    for service in devEnv.services:
      check service.name != "sso"
    for node in serviceNodes():
      check node.stableName != "legacy-stack"
