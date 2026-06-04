## M75 — deactivation-aware rollback manifest.
##
## When ``repro dev-env export <shell> --project-root <P>`` runs, it
## now ALSO writes ``<artifact-path>.rollback.json`` alongside the
## RBDE artifact. The manifest captures, for every var the activation
## touches:
##
## * ``op`` — the operation kind (set / unset / prepend / append /
##   marker).
## * ``name`` / ``value`` / ``segment`` — the activation-side payload.
## * ``previous`` — the pre-activation value of the var, snapshotted
##   from the calling shell's env (passed via ``--pre-activation-env``).
## * ``was_set`` — distinguishes "unset" from "set to the empty
##   string"; the deactivation emitter uses this to decide between
##   ``unset NAME`` and ``export NAME=''``.
##
## A SEPARATE ``repro dev-env deactivate <manifest>`` arm reads the
## manifest, walks its ``vars`` array in REVERSE order, and emits the
## per-shell script that restores the pre-activation env.
##
## Tamper detection: the activation hash (``activation_script_hash``)
## is sealed inside the manifest at write time. The deactivation
## emitter re-derives the activation script from the same RBDE
## artifact and compares the new hash against the manifest's seal.
## If they differ the user has presumably edited their env manually;
## the deactivation arm emits a no-op script + a stderr diagnostic
## and exits with code 3.
##
## Exit codes (matching ``runDevEnvDeactivateCommand``):
##
## * 0 — success (deactivation script emitted, env restorable)
## * 1 — engine error (manifest missing, artifact missing, JSON
##   broken, ...)
## * 2 — usage error (unknown shell, bad flag)
## * 3 — tamper detected (activation hash mismatch)
##
## The pre-activation env file format is documented in
## ``readPreActivationEnv``: a sequence of NUL-terminated
## ``NAME=VALUE`` records. NUL is illegal inside an env var on every
## platform we ship to, so it is a safe record separator that
## preserves embedded newlines / spaces / `=` after the first one in
## the value. The file MAY be empty (no records).

import std/[json, os, strutils, tables]

import repro_hash
import dev_env_shell_export

# ---------------------------------------------------------------------
# Pre-activation env snapshot
# ---------------------------------------------------------------------

type
  PreActivationEnv* = object
    ## A captured snapshot of the calling shell's environment at the
    ## instant ``repro dev-env export`` was invoked. Membership ==
    ## "was_set"; the empty string is a legal set-value distinct from
    ## absent.
    table*: Table[string, string]

proc initPreActivationEnv*(): PreActivationEnv =
  result.table = initTable[string, string]()

proc snapshotProcessEnv*(): PreActivationEnv =
  ## Graceful-degradation source when ``--pre-activation-env`` is not
  ## passed: snapshot the export command's own process environment.
  ## M76's shell hook will always pass the flag so the manifest
  ## reflects the SHELL's env rather than the spawned child's env;
  ## without the hook the two are effectively the same.
  result = initPreActivationEnv()
  for k, v in envPairs():
    result.table[k] = v

proc readPreActivationEnv*(path: string): PreActivationEnv =
  ## Parse a pre-activation env file written by the shell hook.
  ##
  ## File format (binary-safe):
  ##
  ##   NAME1=VALUE1\0NAME2=VALUE2\0...
  ##
  ## Each record is a NUL-terminated ``NAME=VALUE`` string. The first
  ## ``=`` in the record separates name from value. NULs are illegal
  ## inside env-var contents on POSIX (string terminator) and on
  ## Windows (treated similarly), so NUL is a safe record separator
  ## that preserves embedded newlines, spaces, tabs, and additional
  ## ``=`` characters in the value.
  ##
  ## A trailing NUL (no final empty record after it) is allowed. An
  ## empty file means "no captured vars" — which the manifest will
  ## render as ``previous: null, was_set: false`` for every set/unset
  ## op.
  result = initPreActivationEnv()
  if path.len == 0:
    return
  if not fileExists(path):
    raise newException(IOError,
      "pre-activation env file not found: " & path)
  let blob = readFile(path)
  var i = 0
  while i < blob.len:
    var j = i
    while j < blob.len and blob[j] != '\0':
      inc j
    if j > i:
      let record = blob[i ..< j]
      let eq = record.find('=')
      if eq < 0:
        raise newException(ValueError,
          "pre-activation env record missing '=': " & record)
      let name = record[0 ..< eq]
      let value = record[(eq + 1) .. ^1]
      result.table[name] = value
    i = j + 1

# ---------------------------------------------------------------------
# Rollback manifest schema (JSON-on-disk + in-memory)
# ---------------------------------------------------------------------

type
  RollbackOpKind* = enum
    rokSet = "set"
    rokUnset = "unset"
    rokPrepend = "prepend"
    rokAppend = "append"
    rokMarker = "marker"

  RollbackVar* = object
    name*: string
    op*: RollbackOpKind
    value*: string             ## populated for rokSet / rokMarker
    segment*: string           ## populated for rokPrepend / rokAppend
    separator*: string         ## populated for rokPrepend / rokAppend
    previous*: string          ## pre-activation value of ``name``
    wasSet*: bool              ## true iff ``name`` was set pre-activation

  RollbackManifest* = object
    artifact*: string                ## RBDE artifact fingerprint
    activationScriptHash*: string    ## seal over the activation script
    activationShell*: ShellKind      ## shell that produced the script
    vars*: seq[RollbackVar]

  RollbackManifestError* = object of CatchableError

proc raiseManifest(msg: string) {.noreturn.} =
  raise newException(RollbackManifestError, msg)

# ---------------------------------------------------------------------
# Activation-script hash (tamper-detection seal)
# ---------------------------------------------------------------------

proc computeActivationScriptHash*(script: string): string =
  ## Hash scheme: blake3-256 over the script bytes framed with the
  ## ``hdMetadataEnvelope`` domain, truncated to 16 hex chars (8
  ## bytes). The spec sketches sha256-truncated-to-16-hex; we use
  ## blake3 because it is already linked via ``repro_hash`` and the
  ## tamper-detection use case is integrity-only (no collision-
  ## resistance attack surface), so any 64-bit cryptographic digest
  ## suffices. The hash is a deterministic function of the script
  ## bytes alone — no salt, no timestamp.
  var bytes = newSeq[byte](script.len)
  for idx, ch in script:
    bytes[idx] = byte(ord(ch))
  let digest = blake3DomainDigest(bytes, hdMetadataEnvelope)
  result = newStringOfCap(16)
  for i in 0 ..< 8:
    result.add(toHex(int(digest.bytes[i]), 2).toLowerAscii())

# ---------------------------------------------------------------------
# Build the rollback manifest from an ExportPlan + pre-activation env
# ---------------------------------------------------------------------

proc buildRollbackVars*(plan: ExportPlan;
                       preEnv: PreActivationEnv): seq[RollbackVar] =
  ## Each ExportOp produces ONE RollbackVar capturing the
  ## activation-side payload + the pre-activation snapshot for the
  ## affected name. Marker ops are emitted as ``rokMarker`` so the
  ## deactivation pass can unset them regardless of pre-state (the
  ## spec mandates ``__REPRO_*`` markers are NOT rolled back to a
  ## prior value — they are simply unset on deactivation).
  result = @[]
  for op in plan:
    var entry = RollbackVar()
    case op.kind
    of opSet:
      entry.name = op.name
      entry.op = rokSet
      entry.value = op.value
    of opUnset:
      entry.name = op.unsetName
      entry.op = rokUnset
    of opPrependPath:
      entry.name = op.pathName
      entry.op = rokPrepend
      entry.segment = op.segment
      entry.separator = op.separator
    of opAppendPath:
      entry.name = op.pathName
      entry.op = rokAppend
      entry.segment = op.segment
      entry.separator = op.separator
    of opMarker:
      entry.name = op.markerName
      entry.op = rokMarker
      entry.value = op.markerValue
    if entry.name in preEnv.table:
      entry.previous = preEnv.table[entry.name]
      entry.wasSet = true
    else:
      entry.previous = ""
      entry.wasSet = false
    result.add(entry)

proc buildRollbackManifest*(plan: ExportPlan;
                            preEnv: PreActivationEnv;
                            artifactFingerprint: string;
                            activationScript: string;
                            activationShell: ShellKind): RollbackManifest =
  result.artifact = artifactFingerprint
  result.activationScriptHash =
    computeActivationScriptHash(activationScript)
  result.activationShell = activationShell
  result.vars = buildRollbackVars(plan, preEnv)

# ---------------------------------------------------------------------
# JSON serialisation
# ---------------------------------------------------------------------

proc shellKindToWire(k: ShellKind): string =
  case k
  of skBash: "bash"
  of skZsh: "zsh"
  of skFish: "fish"
  of skNushell: "nushell"
  of skPwsh: "pwsh"

proc wireToShellKind(s: string): ShellKind =
  case s
  of "bash": skBash
  of "zsh": skZsh
  of "fish": skFish
  of "nushell": skNushell
  of "pwsh": skPwsh
  else: raiseManifest("unknown activation_shell: " & s)

proc toJson*(m: RollbackManifest): JsonNode =
  result = newJObject()
  result["artifact"] = newJString(m.artifact)
  result["activation_script_hash"] =
    newJString(m.activationScriptHash)
  result["activation_shell"] =
    newJString(shellKindToWire(m.activationShell))
  var arr = newJArray()
  for v in m.vars:
    var node = newJObject()
    node["name"] = newJString(v.name)
    node["op"] = newJString($v.op)
    case v.op
    of rokSet, rokMarker:
      node["value"] = newJString(v.value)
    of rokPrepend, rokAppend:
      node["segment"] = newJString(v.segment)
      node["separator"] = newJString(v.separator)
    of rokUnset:
      discard
    if v.wasSet:
      node["previous"] = newJString(v.previous)
    else:
      node["previous"] = newJNull()
    node["was_set"] = newJBool(v.wasSet)
    arr.add(node)
  result["vars"] = arr

proc fromJson*(node: JsonNode): RollbackManifest =
  if node.kind != JObject:
    raiseManifest("rollback manifest root must be a JSON object")
  if not node.hasKey("artifact"):
    raiseManifest("rollback manifest missing 'artifact'")
  if not node.hasKey("activation_script_hash"):
    raiseManifest("rollback manifest missing 'activation_script_hash'")
  if not node.hasKey("vars"):
    raiseManifest("rollback manifest missing 'vars'")
  result.artifact = node["artifact"].getStr()
  result.activationScriptHash = node["activation_script_hash"].getStr()
  if node.hasKey("activation_shell"):
    result.activationShell =
      wireToShellKind(node["activation_shell"].getStr())
  else:
    result.activationShell = skBash
  let varsNode = node["vars"]
  if varsNode.kind != JArray:
    raiseManifest("rollback manifest 'vars' must be an array")
  for entry in varsNode.elems:
    if entry.kind != JObject:
      raiseManifest("rollback manifest var entries must be objects")
    var v = RollbackVar()
    v.name = entry["name"].getStr()
    let opStr = entry["op"].getStr()
    case opStr
    of "set": v.op = rokSet
    of "unset": v.op = rokUnset
    of "prepend": v.op = rokPrepend
    of "append": v.op = rokAppend
    of "marker": v.op = rokMarker
    else:
      raiseManifest("rollback manifest unknown op: " & opStr)
    case v.op
    of rokSet, rokMarker:
      v.value = entry{"value"}.getStr("")
    of rokPrepend, rokAppend:
      v.segment = entry{"segment"}.getStr("")
      v.separator = entry{"separator"}.getStr("")
    of rokUnset:
      discard
    if entry.hasKey("was_set"):
      v.wasSet = entry["was_set"].getBool()
    else:
      v.wasSet = false
    let prev = entry{"previous"}
    if prev != nil and prev.kind == JString:
      v.previous = prev.getStr()
    else:
      v.previous = ""
    result.vars.add(v)

proc rollbackManifestPath*(artifactPath: string): string =
  artifactPath & ".rollback.json"

proc writeRollbackManifest*(path: string; manifest: RollbackManifest) =
  ## Atomic write: serialize to ``<path>.tmp`` then rename. This
  ## matches the ``writeDevEnvArtifact`` pattern used elsewhere in
  ## the dev-env edge so a half-written manifest can never poison
  ## a deactivation.
  let tmpPath = path & ".tmp"
  let blob = pretty(manifest.toJson()) & "\n"
  createDir(parentDir(path))
  writeFile(tmpPath, blob)
  moveFile(tmpPath, path)

proc readRollbackManifest*(path: string): RollbackManifest =
  if not fileExists(path):
    raise newException(IOError,
      "rollback manifest not found: " & path)
  let blob = readFile(path)
  let node = parseJson(blob)
  result = fromJson(node)

# ---------------------------------------------------------------------
# Deactivation emitter — per-shell formatters
# ---------------------------------------------------------------------

proc bashQuoteValue(value: string): string =
  ## Local copy of the bash single-quote rule. Kept identical to the
  ## ``bashQuote`` in ``dev_env_shell_export.nim`` so the deactivation
  ## script honours the same byte-identical contract.
  result = "'"
  for ch in value:
    if ch == '\'':
      result.add("'\\''")
    else:
      result.add(ch)
  result.add("'")

proc fishQuoteValue(value: string): string =
  result = "'"
  for ch in value:
    case ch
    of '\'': result.add("\\'")
    of '\\': result.add("\\\\")
    else: result.add(ch)
  result.add("'")

proc pwshQuoteValue(value: string): string =
  "'" & value.replace("'", "''") & "'"

proc nuQuoteValue(value: string): string =
  if not value.contains('\''):
    return "'" & value & "'"
  result = "\""
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    else: result.add(ch)
  result.add("\"")

proc formatDeactivateBash*(manifest: RollbackManifest): string =
  ## Walk ``vars`` in REVERSE order — last activation op rolls back
  ## first so PATH-style ops compose cleanly with the set-then-unset
  ## ordering the activation used.
  result = ""
  for i in countdown(manifest.vars.high, 0):
    let v = manifest.vars[i]
    case v.op
    of rokSet:
      if v.wasSet:
        result.add("export " & v.name & "=" & bashQuoteValue(v.previous) & "\n")
      else:
        result.add("unset " & v.name & "\n")
    of rokUnset:
      if v.wasSet:
        result.add("export " & v.name & "=" & bashQuoteValue(v.previous) & "\n")
      else:
        result.add("unset " & v.name & "\n")
    of rokPrepend, rokAppend:
      if v.wasSet:
        result.add("export " & v.name & "=" & bashQuoteValue(v.previous) & "\n")
      else:
        result.add("unset " & v.name & "\n")
    of rokMarker:
      # Markers (__REPRO_*) are reprobuild-internal — always unset.
      result.add("unset " & v.name & "\n")

proc formatDeactivateFish*(manifest: RollbackManifest): string =
  result = ""
  for i in countdown(manifest.vars.high, 0):
    let v = manifest.vars[i]
    case v.op
    of rokSet, rokUnset, rokPrepend, rokAppend:
      if v.wasSet:
        result.add("set -gx " & v.name & " " & fishQuoteValue(v.previous) & "\n")
      else:
        result.add("set -e " & v.name & "\n")
    of rokMarker:
      result.add("set -e " & v.name & "\n")

proc formatDeactivatePwsh*(manifest: RollbackManifest): string =
  result = ""
  for i in countdown(manifest.vars.high, 0):
    let v = manifest.vars[i]
    case v.op
    of rokSet, rokUnset, rokPrepend, rokAppend:
      if v.wasSet:
        result.add("$env:" & v.name & " = " & pwshQuoteValue(v.previous) & "\n")
      else:
        result.add("Remove-Item Env:" & v.name &
          " -ErrorAction SilentlyContinue\n")
    of rokMarker:
      result.add("Remove-Item Env:" & v.name &
        " -ErrorAction SilentlyContinue\n")

proc formatDeactivateNushell*(manifest: RollbackManifest): string =
  ## Nushell's reverse-walk: restorations group into a single
  ## ``load-env`` block (when there are any) followed by ``hide-env``
  ## lines for ops whose name was unset pre-activation.
  var setBlock = ""
  var trailer = ""
  for i in countdown(manifest.vars.high, 0):
    let v = manifest.vars[i]
    case v.op
    of rokSet, rokUnset, rokPrepend, rokAppend:
      if v.wasSet:
        setBlock.add("  " & v.name & ": " &
          nuQuoteValue(v.previous) & "\n")
      else:
        trailer.add("hide-env " & v.name & "\n")
    of rokMarker:
      trailer.add("hide-env " & v.name & "\n")
  if setBlock.len > 0:
    result.add("load-env {\n")
    result.add(setBlock)
    result.add("}\n")
  result.add(trailer)

proc formatDeactivate*(manifest: RollbackManifest;
                      shell: ShellKind): string =
  case shell
  of skBash, skZsh: formatDeactivateBash(manifest)
  of skFish: formatDeactivateFish(manifest)
  of skNushell: formatDeactivateNushell(manifest)
  of skPwsh: formatDeactivatePwsh(manifest)

# ---------------------------------------------------------------------
# Public emitter helper used by the dispatch arm
# ---------------------------------------------------------------------

proc emitNoOpScript*(shell: ShellKind): string =
  ## Used by the tamper-detection path: emit a syntactically valid
  ## script that does nothing. The shell hook's caller will still
  ## ``eval`` the output even when we exit with code 3, so the script
  ## must parse cleanly under each shell.
  case shell
  of skBash, skZsh: ": # repro dev-env deactivate: tamper detected, env left as-is\n"
  of skFish: "# repro dev-env deactivate: tamper detected, env left as-is\n"
  of skNushell: "# repro dev-env deactivate: tamper detected, env left as-is\n"
  of skPwsh: "# repro dev-env deactivate: tamper detected, env left as-is\n"
