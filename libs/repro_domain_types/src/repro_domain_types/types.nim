import cbor
import repro_core
import repro_hash

type
  DomainEnvelopeKind* = enum
    dekRepositoryMetadata
    dekActionSpec
    dekContentDigestEnvelope

  RepositoryMetadata* = object
    repositoryId*: StableId
    displayName*: string
    formatVersion*: uint32
    metadata*: DynamicValue

  ActionSpec* = object
    actionId*: StableId
    process*: ProcessSpec
    dependencyPolicy*: DependencyGatheringPolicy
    metadata*: DynamicValue

  ContentDigestEnvelope* = object
    digest*: ContentDigest
    size*: uint64

  DomainValue* = object
    case kind*: DomainEnvelopeKind
    of dekRepositoryMetadata:
      repositoryMetadata*: RepositoryMetadata
    of dekActionSpec:
      actionSpec*: ActionSpec
    of dekContentDigestEnvelope:
      contentDigest*: ContentDigestEnvelope

proc repositoryValue*(value: RepositoryMetadata): DomainValue =
  DomainValue(kind: dekRepositoryMetadata, repositoryMetadata: value)

proc actionValue*(value: ActionSpec): DomainValue =
  DomainValue(kind: dekActionSpec, actionSpec: value)

proc contentDigestValue*(value: ContentDigestEnvelope): DomainValue =
  DomainValue(kind: dekContentDigestEnvelope, contentDigest: value)

proc `==`*(a, b: DomainValue): bool {.noSideEffect.} =
  if a.kind != b.kind:
    return false
  case a.kind
  of dekRepositoryMetadata:
    a.repositoryMetadata == b.repositoryMetadata
  of dekActionSpec:
    a.actionSpec == b.actionSpec
  of dekContentDigestEnvelope:
    a.contentDigest == b.contentDigest
