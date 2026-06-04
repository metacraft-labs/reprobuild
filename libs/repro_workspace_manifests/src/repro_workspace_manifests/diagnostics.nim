# repro_workspace_manifests/diagnostics.nim
#
# Helpers that build `WorkspaceManifestParseError` instances and parse the
# strict-mode parser's error message into a structured `keyPath`. Centralised
# here so every read* proc raises the same diagnostic shape.

import std/strutils
import types

proc raiseManifestError*(
    path: string;
    keyPath, expectedSchema, observedSchema, innerMessage: string) {.noreturn.} =
  ## Build a `WorkspaceManifestParseError` with the file location, the
  ## structured key path, the expected and observed schema strings, and the
  ## underlying parser message, then raise it.
  var e = newException(WorkspaceManifestParseError, "")
  e.path = path
  e.keyPath = keyPath
  e.expectedSchema = expectedSchema
  e.observedSchema = observedSchema
  e.innerMessage = innerMessage

  var summary = "[" & path & "]"
  if expectedSchema.len > 0 or observedSchema.len > 0:
    summary.add " schema "
    if expectedSchema.len > 0:
      summary.add "expected="
      summary.add expectedSchema
    if observedSchema.len > 0:
      if expectedSchema.len > 0:
        summary.add " "
      summary.add "observed="
      summary.add observedSchema
  if keyPath.len > 0:
    summary.add " at key '"
    summary.add keyPath
    summary.add "'"
  summary.add ": "
  summary.add innerMessage
  e.msg = summary
  raise e

proc extractStrictModeKeyPath*(message: string): string =
  ## Extract the offending top-level key name from a strict-mode parser
  ## error of the form:
  ##   "(line, col) Unexpected field 'X' while deserializing 'TypeName'"
  ## Returns the empty string if the marker substring is not present.
  const marker = "Unexpected field '"
  let start = message.find(marker)
  if start < 0:
    return ""
  let nameStart = start + marker.len
  let nameEnd = message.find('\'', nameStart)
  if nameEnd < 0:
    return ""
  result = message[nameStart ..< nameEnd]
