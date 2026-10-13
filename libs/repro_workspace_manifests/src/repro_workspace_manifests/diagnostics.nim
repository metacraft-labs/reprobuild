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

# ---- set-aside of malformed workspace files (``repro health`` only) --------

type
  MalformedWorkspaceFileKind* = enum
    ## Which workspace file a set-aside diagnostic is about; ``repro health``
    ## reports each kind in a row of its own.
    mwkSettings = "workspace-settings"
      ## ``repro-workspace.toml`` / ``repro-workspace.local.toml`` (or the old
      ## ``.repro-workspace.toml``).
    mwkState = "workspace-state"
      ## ``.repro/workspace-state.toml`` (or the old ``.repro/workspace.toml``).
    mwkManifest = "manifest"
      ## A file of the manifest closure the workspace resolves through — a
      ## ``repos/*.toml`` fragment, a project / variant / repo-set manifest.
      ## Reported in health's existing ``manifest`` row.

  SetAsideWorkspaceFile* = object
    kind*: MalformedWorkspaceFileKind
    message*: string  ## the strict reader's diagnostic: file, key, problem
    path*: string     ## the file the diagnostic is about
    keyPath*: string  ## the offending key; "" for a TOML syntax error

var malformedWorkspaceFilesTolerated {.threadvar.}: bool
var setAsideWorkspaceFiles {.threadvar.}: seq[SetAsideWorkspaceFile]

template toleratingMalformedWorkspaceFiles*(failures, body: untyped) =
  ## Run ``body`` with a state or settings file that does not parse read as
  ## if it recorded / declared nothing, and return the strict readers'
  ## diagnostics in ``failures`` — for ``repro health`` ONLY. Every other verb
  ## refuses such a file; health is the one command whose job is to localize
  ## every broken layer in a single run (CLI/health.md), so it keeps
  ## diagnosing the rest and reports each set-aside file as a failing row of
  ## its own. Nothing set aside here is silent: it is what ``failures``
  ## carries back to be reported.
  let previousTolerated = malformedWorkspaceFilesTolerated
  let previousFailures = setAsideWorkspaceFiles
  malformedWorkspaceFilesTolerated = true
  setAsideWorkspaceFiles = @[]
  try:
    body
  finally:
    failures = setAsideWorkspaceFiles
    malformedWorkspaceFilesTolerated = previousTolerated
    setAsideWorkspaceFiles = previousFailures

proc setAsideMalformedWorkspaceFile*(err: ref WorkspaceManifestParseError;
                                     kind: MalformedWorkspaceFileKind): bool =
  ## Inside ``toleratingMalformedWorkspaceFiles``: record ``err`` for the
  ## caller to report and answer ``true`` (the reader then proceeds as if the
  ## file recorded / declared nothing). Outside it: answer ``false``, and the
  ## reader must re-raise.
  if not malformedWorkspaceFilesTolerated:
    return false
  for seen in setAsideWorkspaceFiles:
    if seen.message == err.msg:
      return true
  setAsideWorkspaceFiles.add(SetAsideWorkspaceFile(kind: kind,
    message: err.msg, path: err.path, keyPath: err.keyPath))
  true
