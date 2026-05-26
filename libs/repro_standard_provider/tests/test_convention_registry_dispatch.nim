## M1 verification: convention registry dispatch.
##
## Register a fake convention with ``recognize=always-true`` and an
## ``emitFragment`` that produces a one-node fragment; assert
## ``firstMatchingConvention`` returns it and that the resulting
## fragment has the expected node.
##
## Also exercises a second case: a convention whose ``recognize``
## returns false is skipped and the second one wins, proving the
## "first match in registration order" contract.

import std/[options, unittest]

import repro_provider_runtime
import repro_standard_provider/convention

const
  TestNodeId = "test:node:1"
  TestStableName = "test"

proc alwaysTrue(projectRoot: string;
                request: ProviderGraphRequest): bool {.gcsafe.} =
  true

proc alwaysFalse(projectRoot: string;
                 request: ProviderGraphRequest): bool {.gcsafe.} =
  false

proc emitOneNode(projectRoot: string;
                 request: ProviderGraphRequest): GraphFragment {.gcsafe.} =
  result = GraphFragment(
    entryPointId: request.entryPointId,
    entryPointBodyHash: request.entryPointBodyHash,
    arguments: request.arguments,
    namespace: request.namespace,
    nodes: @[
      GraphNode(
        id: TestNodeId,
        kind: gnkMetadata,
        stableName: TestStableName,
        payload: "")
    ])
  result.fragmentDigest = computeGraphFragmentDigest(result)

proc dummyRequest(): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    entryPointId: "standardProvider.placeholder",
    entryPointBodyHash: "test-body-hash",
    arguments: "C:/tmp/fake-project",
    namespace: "project")

suite "convention registry dispatch":

  test "first matching convention wins and emitFragment runs":
    var registry: ConventionRegistry
    registerConvention(registry, LanguageConvention(
      name: "alwaysTrue",
      recognize: alwaysTrue,
      emitFragment: emitOneNode))

    let request = dummyRequest()
    let hit = firstMatchingConvention(registry, request.arguments, request)
    check hit.isSome
    check hit.get.name == "alwaysTrue"

    let fragment = hit.get.emitFragment(request.arguments, request)
    check fragment.nodes.len == 1
    check fragment.nodes[0].id == TestNodeId
    check fragment.nodes[0].kind == gnkMetadata
    check fragment.nodes[0].stableName == TestStableName
    check fragment.entryPointId == request.entryPointId

  test "non-matching convention is skipped in favour of the next match":
    var registry: ConventionRegistry
    registerConvention(registry, LanguageConvention(
      name: "alwaysFalse",
      recognize: alwaysFalse,
      emitFragment: emitOneNode))
    registerConvention(registry, LanguageConvention(
      name: "alwaysTrue",
      recognize: alwaysTrue,
      emitFragment: emitOneNode))

    let request = dummyRequest()
    let hit = firstMatchingConvention(registry, request.arguments, request)
    check hit.isSome
    check hit.get.name == "alwaysTrue"

  test "empty registry yields none":
    var registry: ConventionRegistry
    let request = dummyRequest()
    let hit = firstMatchingConvention(registry, request.arguments, request)
    check hit.isNone

  test "all-non-matching registry yields none":
    var registry: ConventionRegistry
    registerConvention(registry, LanguageConvention(
      name: "alwaysFalse",
      recognize: alwaysFalse,
      emitFragment: emitOneNode))
    let request = dummyRequest()
    let hit = firstMatchingConvention(registry, request.arguments, request)
    check hit.isNone

  test "addDefaultConvention populates the module-level registry":
    let baseline = defaultConventionRegistry.conventions.len
    addDefaultConvention(LanguageConvention(
      name: "alwaysTrue",
      recognize: alwaysTrue,
      emitFragment: emitOneNode))
    check defaultConventionRegistry.conventions.len == baseline + 1
    check defaultConventionRegistry.conventions[^1].name == "alwaysTrue"
