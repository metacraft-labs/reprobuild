import std/[strutils]
import cbor
import repro_core
import repro_hash
import repro_domain_types/types

proc esc(text: string): string =
  result = newStringOfCap(text.len)
  for ch in text:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    else: result.add(ch)

proc q(text: string): string =
  "\"" & esc(text) & "\""

proc stableIdJson(id: StableId): string =
  q($id)

proc digestJson(digest: ContentDigest): string =
  q(toHex(digest.bytes))

proc envJson(env: openArray[EnvVar]): string =
  var parts: seq[string] = @[]
  for item in env:
    parts.add("{\"name\":" & q(item.name) & ",\"value\":" & q(item.value) & "}")
  "[" & parts.join(",") & "]"

proc processJson(process: ProcessSpec): string =
  var args: seq[string] = @[]
  for arg in process.args:
    args.add(q(arg))
  "{\"kind\":" & q($process.kind) &
    ",\"executable\":" & q($process.executable) &
    ",\"args\":[" & args.join(",") & "]" &
    ",\"env\":" & envJson(process.env) &
    ",\"cwd\":" & q($process.cwd) & "}"

proc dependencyPolicyJson(policy: DependencyGatheringPolicy): string =
  "{\"kind\":" & q($policy.kind) &
    ",\"completeness\":" & q($policy.completeness) & "}"

proc toJsonInspection*(value: DomainValue): string =
  case value.kind
  of dekRepositoryMetadata:
    "{\"kind\":\"repositoryMetadata\"" &
      ",\"repositoryId\":" & stableIdJson(value.repositoryMetadata.repositoryId) &
      ",\"displayName\":" & q(value.repositoryMetadata.displayName) &
      ",\"formatVersion\":" & $value.repositoryMetadata.formatVersion &
      ",\"metadata\":" & toJson(value.repositoryMetadata.metadata) & "}"
  of dekActionSpec:
    "{\"kind\":\"actionSpec\"" &
      ",\"actionId\":" & stableIdJson(value.actionSpec.actionId) &
      ",\"process\":" & processJson(value.actionSpec.process) &
      ",\"dependencyPolicy\":" & dependencyPolicyJson(value.actionSpec.dependencyPolicy) &
      ",\"metadata\":" & toJson(value.actionSpec.metadata) & "}"
  of dekContentDigestEnvelope:
    "{\"kind\":\"contentDigest\"" &
      ",\"algorithm\":" & q($value.contentDigest.digest.algorithm) &
      ",\"domain\":" & q($value.contentDigest.digest.domain) &
      ",\"digest\":" & digestJson(value.contentDigest.digest) &
      ",\"size\":" & $value.contentDigest.size & "}"
