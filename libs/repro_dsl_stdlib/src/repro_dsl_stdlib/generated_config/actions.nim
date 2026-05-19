## High-level generated-configuration-file actions:
##
##   - `applyOwnedFile` for `owned`-policy files (fs.configFile,
##     fs.writeStructured)
##   - `applyManagedBlock` for `merged`-policy partial-ownership files
##   - `applyExternalTemplate` for typed-wrapper external template tools
##
## Each one computes the cache key per `Generated-Configuration-Files.md`,
## stores rendered bytes in the M56 CAS, and only writes the host
## filesystem when the resolved-input set changed (i.e. the cache key
## changed). Re-applies with identical inputs are no-ops.

import std/[os, osproc, strutils, tables]

import repro_local_store

import ./cache_key
import ./managed_block
import ./paths
import ../configurables

type
  OwnedApplyOutcome* = enum
    oaCreated
    oaUpdated
    oaCacheHit
    oaUnchanged

  OwnedApplyResult* = object
    outcome*: OwnedApplyOutcome
    targetPath*: string
    cacheKeyHex*: string
    contentDigestHex*: string
    bytesWritten*: int

  ManagedApplyOutcome* = enum
    maInserted
    maUpdated
    maCacheHit
    maRemoved
    maAbsent

  ManagedApplyResult* = object
    outcome*: ManagedApplyOutcome
    targetPath*: string
    cacheKeyHex*: string
    blockExisted*: bool
    rewroteHostFile*: bool

  TemplateApplyResult* = object
    outcome*: OwnedApplyOutcome
    targetPath*: string
    cacheKeyHex*: string
    contentDigestHex*: string
    capturedImports*: seq[string]
      ## Files the renderer opened at runtime. These are the
      ## "monitor-captured" inputs the spec describes; we capture them
      ## directly via the wrapper for templates.

  ApplyState* = object
    cacheKeys*: Table[string, array[32, byte]]
      ## Identity key (path + optional blockId) -> last computed cache key.
      ## Lives in memory; an on-disk variant would persist this through
      ## the generation log.

proc newApplyState*(): ApplyState =
  ApplyState(cacheKeys: initTable[string, array[32, byte]]())

# ---------------------------------------------------------------------------
# Owned files (fs.configFile / fs.writeStructured)
# ---------------------------------------------------------------------------

proc identityKeyOwned(targetPath: string): string =
  "owned:" & targetPath

proc materializeFromCas(store: var Store; digest: PrefixIdBytes;
                       targetPath: string): bool =
  ## Read the bytes from CAS and atomically rename them into place.
  ## Returns true if the file was actually rewritten (i.e. the bytes
  ## differ from what is already on disk).
  let blob = store.readCasBlob(digest)
  var data = newString(blob.len)
  for i, b in blob: data[i] = char(b)
  if fileExists(targetPath):
    let existing = readFile(targetPath)
    if existing == data:
      return false
  createDir(parentDir(targetPath))
  let tmpPath = targetPath & ".reprotmp." & $getCurrentProcessId()
  writeFile(tmpPath, data)
  if fileExists(targetPath):
    removeFile(targetPath)
  moveFile(tmpPath, targetPath)
  return true

proc applyOwnedFile*(state: var ApplyState; store: var Store;
                    scope: HomeScope;
                    rawPath: string;
                    content: openArray[byte];
                    inputs: seq[ResolvedInput]): OwnedApplyResult =
  ## Apply an `owned`-policy generated configuration file. The bytes
  ## come from a serializer (TOML/INI/JSON/YAML/shellExports/text or an
  ## external template tool); the input set comes from the rendering
  ## logic recording configurable reads.
  result.targetPath = expandPath(scope, rawPath)
  let key = cacheKeyOwned(content, inputs)
  result.cacheKeyHex = toHex(key)
  let idKey = identityKeyOwned(result.targetPath)
  let prior = state.cacheKeys.getOrDefault(idKey)
  let priorMatches = (prior == key)
  # The CAS blob is keyed by the rendered content's BLAKE3.
  var contentSeq = newSeq[byte](content.len)
  for i in 0 ..< content.len: contentSeq[i] = content[i]
  let blobId = store.storeCasBlob(contentSeq)
  result.contentDigestHex = toHex(blobId)
  result.bytesWritten = content.len
  if priorMatches and fileExists(result.targetPath):
    # Verify on-disk content still matches.
    let existing = readFile(result.targetPath)
    var existingSeq = newSeq[byte](existing.len)
    for i, ch in existing: existingSeq[i] = byte(ord(ch))
    if hashContent(existingSeq) == hashContent(contentSeq):
      result.outcome = oaCacheHit
      return
  # Materialize from CAS, then update state.
  let didCreate = not fileExists(result.targetPath)
  let didChange = materializeFromCas(store, blobId, result.targetPath)
  state.cacheKeys[idKey] = key
  if didCreate: result.outcome = oaCreated
  elif didChange: result.outcome = oaUpdated
  else: result.outcome = oaUnchanged

# ---------------------------------------------------------------------------
# Managed blocks (fs.managedBlock)
# ---------------------------------------------------------------------------

proc identityKeyManaged(targetPath, blockId: string): string =
  "managed:" & blockId & ":" & targetPath

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s: result[i] = byte(ord(ch))

proc applyManagedBlock*(state: var ApplyState; store: var Store;
                       scope: HomeScope;
                       rawPath, blockId, content: string;
                       inputs: seq[ResolvedInput]): ManagedApplyResult =
  ## Apply a `merged`-policy partial-ownership managed block. The cache
  ## key derives ONLY from `blockId`, the host path, the block content
  ## bytes (NOT the surrounding bytes), and the resolved inputs.
  result.targetPath = expandPath(scope, rawPath)
  result.cacheKeyHex = toHex(
    cacheKeyManagedBlock(blockId, result.targetPath,
      bytesOf(content), inputs))
  let key = cacheKeyManagedBlock(blockId, result.targetPath,
    bytesOf(content), inputs)
  let idKey = identityKeyManaged(result.targetPath, blockId)
  # Always store the block content in CAS so the home-scope generation
  # log can reference it later.
  discard store.storeCasBlob(bytesOf(content))
  let prior = state.cacheKeys.getOrDefault(idKey)
  let cacheMatches = (prior == key)
  # Read the existing host file to find the current block bytes.
  let hostExists = fileExists(result.targetPath)
  var currentBlockOnDisk = ""
  if hostExists:
    let prior2 = readFile(result.targetPath)
    let range = locateBlock(prior2, blockId)
    if range.found:
      currentBlockOnDisk = prior2.substr(range.blockStart, range.blockEnd - 1)
  let onDiskMatches = (currentBlockOnDisk == content) or
    (currentBlockOnDisk == content & "\n") or
    (content == currentBlockOnDisk & "\n")
  if cacheMatches and onDiskMatches:
    result.outcome = maCacheHit
    result.blockExisted = true
    result.rewroteHostFile = false
    return
  let update = updateManagedBlock(result.targetPath, blockId, content)
  state.cacheKeys[idKey] = key
  result.rewroteHostFile = update.rewroteFile
  result.blockExisted = update.blockExisted
  if update.blockExisted: result.outcome = maUpdated
  else: result.outcome = maInserted

proc removeManagedBlockAction*(state: var ApplyState; scope: HomeScope;
                              rawPath, blockId: string): ManagedApplyResult =
  result.targetPath = expandPath(scope, rawPath)
  result.cacheKeyHex = ""
  let idKey = identityKeyManaged(result.targetPath, blockId)
  state.cacheKeys.del idKey
  if removeManagedBlock(result.targetPath, blockId):
    result.outcome = maRemoved
    result.rewroteHostFile = true
    result.blockExisted = true
  else:
    result.outcome = maAbsent

# ---------------------------------------------------------------------------
# External template tool wrapper
# ---------------------------------------------------------------------------

type
  ExternalTemplateSpec* = object
    ## A typed-wrapper recipe for an external template tool. `commandLine`
    ## is the literal argv (template file + var bindings + output path
    ## already materialized from resolved configurables). `toolIdentity`
    ## is the realized package identity (a Jinja version bump produces
    ## a different string and therefore a different cache key).
    commandLine*: seq[string]
    toolIdentity*: string
    declaredInputs*: seq[string]
      ## Files the wrapper KNOWS the tool needs: the entry template
      ## path, plus anything the package's typed-wrapper recipe declares.
      ## Transitive imports are added in `capturedImports` after the run.
    capturedImports*: seq[string]
      ## Populated by the wrapper from the tool's stderr / dependency
      ## file / runtime-monitor output. For Jinja we drive this by
      ## listing every file under the template directory the wrapper
      ## controls.
    outputPath*: string
    workingDir*: string

  TemplateRunError* = object of CatchableError

proc readFileSafe(path: string): string =
  if fileExists(path): readFile(path) else: ""

proc computeTemplateContent*(spec: ExternalTemplateSpec;
                             inputs: seq[ResolvedInput]):
                            tuple[content: seq[byte];
                                  cacheKey: array[32, byte]] =
  ## Run the external template tool. The wrapper records (a) the tool
  ## identity, (b) the contents of every declared / captured input file,
  ## and (c) the resolved configurable inputs as cache-key contributors.
  let processOpts = {poStdErrToStdOut, poUsePath}
  var (output, exitCode) = execCmdEx(spec.commandLine.join(" "),
    options = processOpts, workingDir = spec.workingDir)
  if exitCode != 0:
    raise newException(TemplateRunError,
      "external template tool failed (exit " & $exitCode & "): " & output)
  if not fileExists(spec.outputPath):
    raise newException(TemplateRunError,
      "external template tool did not produce output at " & spec.outputPath)
  let rendered = readFile(spec.outputPath)
  var content = newSeq[byte](rendered.len)
  for i, ch in rendered: content[i] = byte(ord(ch))
  # Build a synthetic ResolvedInput list that includes the tool identity
  # and the contents of every declared + captured input file.
  var allInputs = inputs
  allInputs.add ResolvedInput(name: "$tool-identity",
    value: cvString(spec.toolIdentity))
  var seen = initTable[string, bool]()
  proc absorb(path: string) =
    let key = path.replace('\\', '/')
    if seen.hasKey(key): return
    seen[key] = true
    allInputs.add ResolvedInput(
      name: "$file:" & key,
      value: cvString(readFileSafe(path)))
  for p in spec.declaredInputs: absorb(p)
  for p in spec.capturedImports: absorb(p)
  result.content = content
  result.cacheKey = cacheKeyOwned(content, allInputs)

proc applyExternalTemplate*(state: var ApplyState; store: var Store;
                           scope: HomeScope;
                           rawPath: string;
                           spec: ExternalTemplateSpec;
                           inputs: seq[ResolvedInput]):
                          TemplateApplyResult =
  ## Render via an external template tool, then apply with `owned`
  ## semantics through `applyOwnedFile`. The wrapper's captured-imports
  ## set participates in the cache key directly so that editing a
  ## transitively-included template invalidates the action.
  let expanded = expandPath(scope, rawPath)
  result.targetPath = expanded
  # Compute the rendered bytes + cache key (which includes the full
  # transitive-import file contents and the tool identity string).
  let (content, _) = computeTemplateContent(spec, inputs)
  # Use the FULL ResolvedInput set (configurable inputs +
  # tool-identity + captured file contents) as inputs to applyOwnedFile.
  # We rebuild it here so the cache key matches between the helper and
  # the apply path.
  var allInputs = inputs
  allInputs.add ResolvedInput(name: "$tool-identity",
    value: cvString(spec.toolIdentity))
  var seen = initTable[string, bool]()
  proc absorb(path: string) =
    let key = path.replace('\\', '/')
    if seen.hasKey(key): return
    seen[key] = true
    allInputs.add ResolvedInput(
      name: "$file:" & key,
      value: cvString(readFileSafe(path)))
  for p in spec.declaredInputs: absorb(p)
  for p in spec.capturedImports: absorb(p)
  let owned = applyOwnedFile(state, store, scope, rawPath, content,
    allInputs)
  result.outcome = owned.outcome
  result.cacheKeyHex = owned.cacheKeyHex
  result.contentDigestHex = owned.contentDigestHex
  result.capturedImports = spec.capturedImports

# ---------------------------------------------------------------------------
# Narrow built-in template engine: {{name}} + {{#if}} + {{#each}}
# ---------------------------------------------------------------------------
#
# Value-shape contract (Option A from the M59 follow-up):
#
#   - `TplValueKind` distinguishes scalar strings from string lists.
#     `tvString` carries a single `string`; `tvStringList` carries
#     `seq[string]`.
#   - `{{name}}` substitution and `{{#if name}}` work on `tvString` values.
#     A `tvString` whose `str` is empty, "false", or "0" is falsy for `#if`.
#     Referencing a `tvStringList` from `{{name}}` or `{{#if}}` raises
#     `EBuiltinTemplate` with a clear "wrong type" diagnostic.
#   - `{{#each <var> in <list>}}...{{/each}}` iterates a `tvStringList`,
#     binding `<var>` to each element (as a `tvString`) within the body.
#     The loop variable shadows any pre-existing values-map entry of the
#     same name during the body and is restored on loop exit. Referencing
#     a `tvString` from `{{#each}}` raises `EBuiltinTemplate`. An unknown
#     `<list>` name raises `EBuiltinTemplate`.
#
# The existing `Table[string, string]` overload is preserved for the
# back-compat call sites (block-macro renders) and forwards into the
# typed engine after wrapping every value as `tvString`. That overload
# therefore still rejects `{{#each}}` (with the same "wrong type"
# diagnostic), because every value it can carry is `tvString`.

type
  EBuiltinTemplate* = object of CatchableError

  TplValueKind* = enum
    tvString
    tvStringList

  TplValue* = object
    case kind*: TplValueKind
    of tvString: str*: string
    of tvStringList: list*: seq[string]

proc tplString*(v: string): TplValue =
  TplValue(kind: tvString, str: v)

proc tplStringList*(v: seq[string]): TplValue =
  TplValue(kind: tvStringList, list: v)

proc isTruthy(v: TplValue): bool =
  # Only `tvString` is valid here; the `{{#if}}` branch performs an
  # explicit kind check before calling `isTruthy` and raises
  # `EBuiltinTemplate` for `tvStringList`, so the list arm is
  # unreachable. The `tvStringList` arm raises a `Defect` to keep this
  # invariant honest if a future caller forgets the kind gate.
  case v.kind
  of tvString: v.str.len > 0 and v.str != "false" and v.str != "0"
  of tvStringList:
    raise newException(Defect,
      "isTruthy called on tvStringList — caller must kind-check first")

proc renderBuiltinTemplate*(source: string;
                            values: Table[string, TplValue]): string =
  ## Tiny built-in engine (typed-values overload). Implements `{{name}}`
  ## substitution, `{{#if name}}...{{/if}}` conditionals, and
  ## `{{#each <var> in <list>}}...{{/each}}` iteration over string lists.
  ## See the file-level value-shape contract above for the typing rules
  ## and exception behavior. The engine is intentionally not a growth
  ## target — see `Generated-Configuration-Files.md` § "built-in engine".
  result = ""
  var i = 0
  while i < source.len:
    if i + 1 < source.len and source[i] == '{' and source[i+1] == '{':
      var endIdx = source.find("}}", start = i + 2)
      if endIdx < 0:
        raise newException(EBuiltinTemplate,
          "unterminated `{{ ... }}` directive starting at position " & $i)
      var directive = source.substr(i + 2, endIdx - 1).strip()
      i = endIdx + 2
      if directive.startsWith("#if "):
        let name = directive[4 .. ^1].strip()
        var endTagIdx = source.find("{{/if}}", start = i)
        if endTagIdx < 0:
          raise newException(EBuiltinTemplate,
            "unterminated `{{#if " & name & "}}` directive")
        let body = source.substr(i, endTagIdx - 1)
        let truthy =
          if values.hasKey(name):
            let v = values[name]
            if v.kind != tvString:
              raise newException(EBuiltinTemplate,
                "`{{#if " & name & "}}`: condition requires a string-typed " &
                "value (kind=" & $v.kind & "); use `{{#each}}` for lists")
            isTruthy(v)
          else: false
        if truthy:
          result.add(renderBuiltinTemplate(body, values))
        i = endTagIdx + "{{/if}}".len
      elif directive.startsWith("#each "):
        # Parse `#each <varName> in <listName>`. Whitespace between the
        # tokens is permitted.
        let rest = directive[6 .. ^1].strip()
        # Find the `in` separator.
        var varName = ""
        var listName = ""
        block parseHeader:
          var parts = rest.split()
          # parts is at least one token; we expect exactly three:
          # <var>, "in", <list>.
          if parts.len != 3 or parts[1] != "in":
            raise newException(EBuiltinTemplate,
              "malformed `{{#each}}` directive — expected " &
              "`{{#each <var> in <list>}}`, got `{{" & directive & "}}`")
          varName = parts[0]
          listName = parts[2]
        # Locate the matching `{{/each}}`. The body must NOT contain
        # nested `{{#each}}` over the same exact closing token; the
        # built-in engine deliberately does not support nested `#each`
        # (Option A keeps the contract small). Nested `{{#if}}` inside
        # a `{{#each}}` body, however, is supported because the inner
        # render call reuses the merged value scope.
        var endTagIdx = source.find("{{/each}}", start = i)
        if endTagIdx < 0:
          raise newException(EBuiltinTemplate,
            "unterminated `{{#each " & varName & " in " & listName &
            "}}` directive")
        let body = source.substr(i, endTagIdx - 1)
        if not values.hasKey(listName):
          raise newException(EBuiltinTemplate,
            "`{{#each}}`: unknown list variable: " & listName)
        let listVal = values[listName]
        if listVal.kind != tvStringList:
          raise newException(EBuiltinTemplate,
            "`{{#each}}`: variable `" & listName & "` is not a " &
            "string list (kind=" & $listVal.kind & ")")
        # Iterate. Bind `varName` to each element as a `tvString`,
        # shadowing any pre-existing values-map entry of the same name
        # during the body and restoring it after the loop. Empty lists
        # emit the body zero times.
        var inner = values
        let hadOuter = inner.hasKey(varName)
        let outer = if hadOuter: inner[varName] else: TplValue(kind: tvString)
        for elem in listVal.list:
          inner[varName] = tplString(elem)
          result.add(renderBuiltinTemplate(body, inner))
        if hadOuter:
          inner[varName] = outer
        else:
          inner.del(varName)
        i = endTagIdx + "{{/each}}".len
      elif directive.startsWith("/"):
        raise newException(EBuiltinTemplate,
          "stray closing directive: " & directive)
      else:
        let name = directive
        if not values.hasKey(name):
          raise newException(EBuiltinTemplate,
            "undefined template variable: " & name)
        let v = values[name]
        if v.kind != tvString:
          raise newException(EBuiltinTemplate,
            "`{{" & name & "}}`: substitution requires a string-typed " &
            "value (kind=" & $v.kind & "); use `{{#each}}` for lists")
        result.add v.str
    else:
      result.add source[i]
      inc i

proc renderBuiltinTemplate*(source: string;
                            values: Table[string, string]): string =
  ## Back-compat overload. Wraps each value as `tvString` and forwards
  ## into the typed engine. `{{#each}}` over a string-only values map
  ## therefore raises `EBuiltinTemplate` (no `tvStringList` entries
  ## exist), which is the expected behavior for the original call
  ## sites; callers that need iteration should call the
  ## `Table[string, TplValue]` overload directly.
  var typed = initTable[string, TplValue]()
  for k, v in values: typed[k] = tplString(v)
  renderBuiltinTemplate(source, typed)
