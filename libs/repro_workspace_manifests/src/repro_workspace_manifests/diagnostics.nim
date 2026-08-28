# repro_workspace_manifests/diagnostics.nim
#
# Helpers that build `WorkspaceManifestParseError` instances and parse the
# strict-mode parser's error message into a structured `keyPath`. Centralised
# here so every read* proc raises the same diagnostic shape.

import std/[os, strutils]
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

proc extractStrictModeRecordName*(message: string): string =
  ## Extract the record type name from the same strict-mode parser error
  ## `extractStrictModeKeyPath` reads:
  ##   "(line, col) Unexpected field 'X' while deserializing 'TypeName'"
  ## Returns the empty string if the marker substring is not present.
  const marker = "while deserializing '"
  let start = message.find(marker)
  if start < 0:
    return ""
  let nameStart = start + marker.len
  let nameEnd = message.find('\'', nameStart)
  if nameEnd < 0:
    return ""
  result = message[nameStart ..< nameEnd]

proc runningToolPath*(): string =
  ## Path of the binary currently executing, or "" when the platform
  ## refuses to report it. Used only to make tool/manifest version skew
  ## visible in a diagnostic, so a failure here is not worth propagating.
  try:
    result = getAppFilename()
  except CatchableError, Defect:
    result = ""

proc schemaSkewMessage*(path, fieldName, recordName: string): string =
  ## Inner message for the one strict-mode failure that is almost never the
  ## manifest's fault: an UNKNOWN FIELD.
  ##
  ## Strict decoding is load-bearing — a manifest key this build does not
  ## understand is a key whose meaning it would silently drop — so the parser
  ## must keep rejecting it. But the raw parser text ("Unexpected field
  ## 'member_sets' while deserializing 'ProjectManifest'") describes the
  ## mechanism, not the cause, and reads as "your manifest is broken". The
  ## overwhelmingly common cause is the opposite: the manifests grew a field
  ## that a STALE `repro` earlier on `PATH` than the workspace-pinned build
  ## has never heard of. Because the workspace's managed pre-push hook shells
  ## out to `repro check`, that skew surfaces as a blocked push, which is
  ## further still from the actual remedy.
  ##
  ## So the unknown-field arm — and only that arm — is rewritten to name the
  ## skew, the field, the file and the fix. Every other strict-mode failure
  ## (malformed TOML, wrong value type, missing required key) keeps its
  ## existing diagnostic, because for those the manifest really is at fault.
  result = "this `repro` is older than the workspace manifests it is " &
    "reading; the manifest is not malformed."
  if path.len > 0:
    result.add " `"
    result.add path
    result.add "`"
  else:
    result.add " The manifest"
  result.add " declares `"
  result.add fieldName
  result.add "`, a key this build of `repro` does not know"
  if recordName.len > 0:
    result.add " (record `"
    result.add recordName
    result.add "`)"
  result.add ". Pick up the workspace-pinned `repro` and retry: run " &
    "`direnv reload`, or leave and re-enter the dev shell with " &
    "`nix develop`, so the workspace build comes first on PATH."
  let self = runningToolPath()
  if self.len > 0:
    result.add " Currently running `"
    result.add self
    result.add "`"
    result.add " (`repro --version` reports its build)."
  else:
    result.add " (`repro --version` reports the build now running.)"
  result.add " If that is already the pinned build, then `"
  result.add fieldName
  result.add "` is genuinely not part of this schema — check the spelling."
