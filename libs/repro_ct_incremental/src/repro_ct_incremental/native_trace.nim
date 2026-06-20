## Native dependency discovery — the M8 deliverable of the
## Trace-Based-Incremental-Testing prototype campaign (Phase 2).
##
## CodeTracer's *native / Multi-Core-Recorder (MCR)* path does NOT emit the
## canonical `Function`/`Call` records the source/interpreted path uses (those
## are read by `trace_reader.readExecutedFunctions`). Instead the executed
## functions come from the native trace's **calltrace**: the MCR/RR emulator
## records flat `CallRecord`s (`tickEnter`, `tickExit`, `callerPc`, `calleePc`)
## while emulating the program, then resolves each `calleePc` to a function name
## via the binary's DWARF (addr2line) when building the hierarchical call tree.
## See the native recorder:
##
##   * `codetracer-native-recorder/ct_emulator/src/ct_emulator/write_log.nim`
##     — `CallRecord {tickEnter, tickExit, callerPc, calleePc}`, the flat
##     call/return stream the emulator appends.
##   * `.../ct_emulator/calltrace_collector.nim` — collects those records during
##     emulation (works for both MCR direct emulation and RR replay).
##   * `.../ct_emulator/calltrace.nim` — `buildCallTree` turns the flat records
##     into a `CallTree` of `CallNode {functionName, sourceFile, sourceLine,
##     calleePc, ...}`, resolving each `calleePc` to a `functionName` with
##     `source_index.resolvePCs` (addr2line over the ELF).
##
## # The native-trace fixture shape (a documented prototype stand-in)
##
## A live MCR/RR run is NOT available in this dev shell (it needs the emulator +
## a recorded process), so — exactly as Phase 1 hand-crafts canonical JSON
## traces in the real `codetracer-trace-format` shape — M8 hand-crafts the
## native calltrace in a JSON shape modeled on the real `CallNode`/`CallRecord`
## structures above. The reader consumes a single file:
##
##   `<traceDir>/native_calltrace.json`
##
## whose shape is a thin, EXPLICITLY-DOCUMENTED JSON projection of the native
## calltrace the recorder produces in memory (there is no canonical on-disk JSON
## form for it upstream yet — the recorder keeps the call tree in memory and the
## persistent write-log is a binary stream — so this JSON is a clearly-labelled
## minimal prototype form, not an invented competing wire format):
##
## ```json
## {
##   "binary": "/abs/or/relative/path/to/the/recorded/executable",
##   "calls": [
##     { "functionName": "used_a", "calleePc": 4096 },
##     { "functionName": "used_b", "calleePc": 4112 },
##     { "functionName": "main",   "calleePc": 4160 }
##   ]
## }
## ```
##
## Mapping to the real native calltrace:
##   * `binary`             ⇐ the ELF/Mach-O the MCR/RR recorder replayed (the
##                            `elfPath` `buildCallTree` resolves PCs against). It
##                            is the OWNING BINARY of every function in `calls`.
##   * `calls[].functionName` ⇐ `CallNode.functionName` (resolved from
##                            `calleePc` via addr2line). This is the
##                            executed-function NAME — the only field the
##                            dependency set needs.
##   * `calls[].calleePc`   ⇐ `CallNode.calleePc` / `CallRecord.calleePc`. Carried
##                            for fidelity/debuggability; the dependency set keys
##                            on the resolved NAME (a real run can have several
##                            PCs resolve to one inlined/duplicated name), so the
##                            reader DE-DUPLICATES by name. `calleePc` is optional.
##
## A real reader would walk the whole `CallTree` (roots + children) collecting
## every node's `functionName`; the executed SET is exactly those names. The flat
## `calls` array here is that same set already flattened — a calltrace's executed
## function set is independent of the tree nesting, so flattening loses nothing
## relevant to dependency discovery.
##
## # The native `ExecutedFunction` convention (DOCUMENTED)
##
## Native dependencies key on (function NAME + owning BINARY), not on a source
## file + definition line (a native function's identity is its compiled
## instruction bytes — spec §16.7.1 — located in the binary by symbol name). So
## the `ExecutedFunction` this reader returns carries:
##
##   * `name`    = the executed function's name (the symbol/DWARF name).
##   * `file`    = the BINARY path (NOT a source path). The native
##                 `ShallowHasher` reads `dep.file` as the binary and calls
##                 `shallowHashNative(dep.file, dep.name)`. Keeping the binary in
##                 `.file` lets the existing cache schema (`{name, file, defLine,
##                 shallow}`) persist native deps with NO schema change — the
##                 binary travels in the same slot a source path would.
##   * `defLine` = 0 (UNUSED for native — there is no source definition line in
##                 instruction-byte identity). Always 0 so the cache is stable.
##
## # Fail-safe invariant (carried over from Phase 1 / M5)
##
## Any structural problem — missing/unreadable `native_calltrace.json`, malformed
## JSON, a non-object root, a missing/empty `binary`, a missing/empty
## `functionName` — yields an `Err`. The engine turns that into a re-run, NEVER a
## silent skip. The reader never raises.

import std/[json, os, algorithm, tables]
import results

import trace_reader  # ExecutedFunction

export results

const
  NativeCalltraceFile* = "native_calltrace.json"
    ## The hand-crafted native calltrace projection a native trace dir carries
    ## in this prototype (see the module doc for the shape + real-recorder
    ## mapping). A native trace dir is additionally marked by `detectBackend`'s
    ## structural signals (an `rr/` subdir, a `*.ct` container, or a
    ## `trace_db_metadata.json`); this file carries the executed-function payload.

proc nativeTraceBinary*(traceDir: string): Result[string, string] =
  ## Read just the `binary` path the native calltrace references (the owning
  ## executable of every function in the trace). Used by the engine at `decide`
  ## time to rebind cached native deps onto the CURRENT binary (the analogue of
  ## the source path resolving deps under the current `sourceRoot`). Any
  ## structural problem ⇒ `Err` (the engine fail-safes to a re-run).
  if not dirExists(traceDir):
    return err("native trace dir not found: " & traceDir)
  let p = traceDir / NativeCalltraceFile
  if not fileExists(p):
    return err("native calltrace file not found: " & p)
  var raw: string
  try:
    raw = readFile(p)
  except CatchableError as e:
    return err("failed to read " & p & ": " & e.msg)
  var root: JsonNode
  try:
    root = parseJson(raw)
  except CatchableError as e:
    return err("malformed JSON in " & p & ": " & e.msg)
  if root.kind != JObject or not root.hasKey("binary") or
      root["binary"].kind != JString:
    return err(NativeCalltraceFile & " must have a string 'binary' field")
  let binary = root["binary"].getStr()
  if binary.len == 0:
    return err(NativeCalltraceFile & " 'binary' must be non-empty")
  ok(binary)

proc readExecutedFunctionsNative*(traceDir: string):
    Result[seq[ExecutedFunction], string] =
  ## The native `DependencyDiscovery` implementation: read the executed-function
  ## SET from a native trace's calltrace (`<traceDir>/native_calltrace.json`).
  ##
  ## Returns the de-duplicated, name-sorted set of `ExecutedFunction`s, each
  ## carrying the executed function NAME (`name`) and the owning BINARY path
  ## (`file`); `defLine` is always 0 (native deps key on name+binary, not a
  ## source line — see the module doc).
  ##
  ## Any structural problem yields an `Err` (⇒ re-run upstream, never a skip).
  if not dirExists(traceDir):
    return err("native trace dir not found: " & traceDir)
  let p = traceDir / NativeCalltraceFile
  if not fileExists(p):
    return err("native calltrace file not found: " & p)
  var raw: string
  try:
    raw = readFile(p)
  except CatchableError as e:
    return err("failed to read " & p & ": " & e.msg)
  var root: JsonNode
  try:
    root = parseJson(raw)
  except CatchableError as e:
    return err("malformed JSON in " & p & ": " & e.msg)
  if root.kind != JObject:
    return err(NativeCalltraceFile & " root must be a JSON object")
  if not root.hasKey("binary") or root["binary"].kind != JString:
    return err(NativeCalltraceFile & " must have a string 'binary' field")
  let binary = root["binary"].getStr()
  if binary.len == 0:
    return err(NativeCalltraceFile & " 'binary' must be non-empty")
  if not root.hasKey("calls") or root["calls"].kind != JArray:
    return err(NativeCalltraceFile & " must have an array 'calls' field")

  # Collect the executed-function NAME set (de-duplicated). A real call tree may
  # resolve several PCs to one name (recursion, multiple call sites); the
  # dependency set is the SET of names, so we de-dup by name and keep the binary
  # as the owning file for every entry.
  var seen = initTable[string, bool]()
  var resultSeq: seq[ExecutedFunction] = @[]
  for i, call in root["calls"].elems:
    if call.kind != JObject:
      return err(NativeCalltraceFile & " calls[" & $i & "] is not an object")
    if not call.hasKey("functionName") or
        call["functionName"].kind != JString:
      return err(NativeCalltraceFile & " calls[" & $i &
        "] missing string 'functionName'")
    let name = call["functionName"].getStr()
    if name.len == 0:
      return err(NativeCalltraceFile & " calls[" & $i &
        "] has an empty 'functionName'")
    # Skip the addr2line "unknown" sentinel a real recorder emits for an
    # unresolved PC ("??"): an unresolved function cannot be hashed by name, so
    # including it would force a perpetual re-run. We DROP it from the set
    # rather than fail the whole read; if the set ends up empty that is handled
    # below. (A real unresolved PC is rare and not a dependency we can track.)
    if name == "??":
      continue
    if not seen.hasKeyOrPut(name, true):
      resultSeq.add ExecutedFunction(name: name, file: binary, defLine: 0)

  if resultSeq.len == 0:
    return err(NativeCalltraceFile & " contains no resolvable executed functions")

  resultSeq.sort(proc (a, b: ExecutedFunction): int = cmp(a.name, b.name))
  ok(resultSeq)
