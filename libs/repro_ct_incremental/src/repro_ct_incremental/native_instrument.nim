## Native call trace via compile-time instrumentation — the M14 deliverable of
## the Trace-Based-Incremental-Testing campaign (Phase 4).
##
## This module is the native runtime dependency-discovery source for hosts that
## have NO Intel PT / RR / MCR emulator (notably arm64-macOS). It drives the
## small C call-recorder runtime (`csrc/ct_instrument_runtime.c`) which uses the
## `-finstrument-functions` ABI (`__cyg_profile_func_enter` /
## `__cyg_profile_func_exit`) to capture, at runtime, the SET of functions a
## native test actually entered. See:
##
##   * `codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md` §16.7
##     — the executed-function set drives incremental test selection.
##   * MCR-Calltrace-Design §22d — the compile-time-instrumentation alternative
##     this implements.
##   * `csrc/ct_instrument_runtime.c` — the runtime + the output file format
##     (one function name per line, de-duplicated, NUL-free, `\n`-terminated).
##
## # What this module does
##
##   1. `instrumentAndRun` — compile+link a C source (and the recorder runtime)
##      with `-finstrument-functions`, run the produced binary with
##      `CT_INSTRUMENT_OUT` pointing into a trace dir, and leave the captured
##      name log there. (An ALREADY-instrumented binary can be run directly with
##      `runInstrumented`.)
##   2. `readExecutedFunctionsInstrumented` — read the captured name log back as
##      the de-duplicated executed-function SET (`seq[ExecutedFunction]`),
##      best-effort resolving each name's source file / defLine.
##
## # The native `ExecutedFunction` convention (shared with native_trace.nim)
##
## Native dependencies key on (function NAME + owning BINARY), NOT on a source
## file + line: a native function's identity is its compiled instruction bytes
## (spec §16.7.1), located in the binary by symbol NAME and hashed by
## `native_hash.shallowHashNative`. So, exactly as `native_trace.nim` documents:
##
##   * `name`    = the executed function's name (leading Mach-O underscore
##                 stripped so it matches `native_hash`'s symbol table keys).
##   * `file`    = the owning BINARY path (NOT a source path) — the native
##                 `ShallowHasher` reads `dep.file` as the binary. This keeps the
##                 cache schema unchanged.
##   * `defLine` = 0 for native (no source line in instruction-byte identity).
##
## The spec for M14 also asks for a BEST-EFFORT source file/defLine resolution.
## Where the binary's symbol/debug info lets us locate a function in the symbol
## table we still keep `defLine = 0` (the engine's native hash is instruction-
## byte based, not source-based, so the NAME is the dependency identity); the
## `name` is always the load-bearing key. If a name cannot be resolved at all it
## is simply dropped (it is not a trackable dependency), mirroring
## `native_trace.nim`'s handling of the `??` sentinel.
##
## # Fail-safe invariant (carried over from Phase 1 / M5)
##
## ANY error — a compile/link failure, a missing or empty output log, a run that
## produced nothing — yields an `Err`. The engine turns that into a re-run,
## NEVER a silent skip. No proc here raises.

import std/[os, osproc, sets, sequtils, algorithm, strutils, tables, strtabs, streams]
import results

import trace_reader  # ExecutedFunction
import native_hash   # nativeFunctionTable (best-effort symbol resolution)

export results

const
  InstrumentOutFile* = "native_instrument_calls.log"
    ## The default name of the captured executed-function log inside a trace dir.
    ## One function name per line, de-duplicated by the C runtime; the reader
    ## de-dups again defensively. `CT_INSTRUMENT_OUT` is set to
    ## `<traceDir>/<InstrumentOutFile>` when running an instrumented binary.

  InstrumentOutEnvVar* = "CT_INSTRUMENT_OUT"
    ## The environment variable the C runtime reads its output path from (see
    ## `csrc/ct_instrument_runtime.c`).

# ---------------------------------------------------------------------------
# Locating the C recorder runtime
# ---------------------------------------------------------------------------

proc instrumentRuntimeSource*(): string =
  ## Absolute path to the committed C call-recorder runtime
  ## (`csrc/ct_instrument_runtime.c`). Resolved relative to THIS module's source
  ## file so it works regardless of the caller's working directory.
  ##
  ## Layout: this file is `src/repro_ct_incremental/native_instrument.nim`; the
  ## runtime is `csrc/ct_instrument_runtime.c` at the library root — two parents
  ## up from this module's directory.
  let here = currentSourcePath()
  let libRoot = here.parentDir.parentDir.parentDir  # …/libs/repro_ct_incremental
  libRoot / "csrc" / "ct_instrument_runtime.c"

# ---------------------------------------------------------------------------
# Compile + run
# ---------------------------------------------------------------------------

type
  InstrumentRun* = object
    ## The artifacts of one instrumentation capture.
    binary*: string   ## The instrumented binary that was built and run.
    outFile*: string  ## The captured name log (`<traceDir>/InstrumentOutFile`).

proc cc(): string =
  ## The C compiler to drive. Honour `CC` if set (the dev shell may set it),
  ## else `cc` on PATH (clang in this dev shell). Matches the M7 fixture's
  ## build.sh convention.
  let fromEnv = getEnv("CC")
  if fromEnv.len > 0: fromEnv else: "cc"

proc dlLinkFlags(): seq[string] =
  ## `dladdr` lives in libdl on Linux (`-ldl`); on macOS it is in libSystem, so
  ## no extra flag is needed (and `-ldl` would be an error). Branch by host OS.
  when defined(macosx):
    @[]
  else:
    @["-ldl"]

proc compileInstrumented*(sourceC, binPath: string):
    Result[string, string] =
  ## Compile+link a C source together with the recorder runtime, with
  ## `-finstrument-functions` applied ONLY to the test source (NOT to the
  ## runtime — the runtime's hooks are additionally `no_instrument_function`,
  ## but keeping the flag off its own TU is cleaner and avoids any chance of the
  ## recorder instrumenting itself).
  ##
  ## Returns the produced binary path, or an `Err` with the compiler output on
  ## any failure (a broken toolchain must surface, never be treated as success).
  if not fileExists(sourceC):
    return err("instrumentation source not found: " & sourceC)
  let runtime = instrumentRuntimeSource()
  if not fileExists(runtime):
    return err("instrumentation runtime not found: " & runtime)

  # Build in two steps so -finstrument-functions applies only to the test TU:
  #   1. compile the runtime WITHOUT instrumentation to an object,
  #   2. compile the test source WITH instrumentation and link the object in.
  let objPath = binPath & ".ct_instrument_runtime.o"

  block compileRuntime:
    var args = @["-O0", "-g", "-c", runtime, "-o", objPath]
    let (output, code) = execCmdEx(quoteShellCommand(@[cc()] & args))
    if code != 0 or not fileExists(objPath):
      return err("failed to compile instrumentation runtime (exit " & $code &
        "):\n" & output)

  block compileTest:
    var args = @[
      "-O0", "-g",
      "-fno-stack-protector", "-fno-asynchronous-unwind-tables",
      "-finstrument-functions",
      sourceC, objPath,
      "-o", binPath]
    args.add dlLinkFlags()
    let (output, code) = execCmdEx(quoteShellCommand(@[cc()] & args))
    if code != 0 or not fileExists(binPath):
      return err("failed to compile instrumented test (exit " & $code &
        "):\n" & output)

  ok(binPath)

proc runInstrumented*(binary, traceDir: string;
    args: openArray[string] = []): Result[InstrumentRun, string] =
  ## Run an ALREADY-instrumented `binary` with `CT_INSTRUMENT_OUT` set to
  ## `<traceDir>/InstrumentOutFile`, capturing the executed-function name log.
  ##
  ## A non-existent binary/trace dir, a launch failure, or a binary that exits
  ## NON-ZERO is an `Err` (the engine re-runs). A zero exit that produced no log
  ## is NOT errored here — `readExecutedFunctionsInstrumented` enforces the
  ## non-empty-log invariant so callers that only run get a clear, single place
  ## for the "empty capture" failure.
  if not fileExists(binary):
    return err("instrumented binary not found: " & binary)
  if not dirExists(traceDir):
    return err("trace dir not found: " & traceDir)
  let outFile = traceDir / InstrumentOutFile
  # Remove any stale log so a failed run cannot be mistaken for a prior capture.
  if fileExists(outFile):
    try: removeFile(outFile)
    except CatchableError as e:
      return err("could not clear stale instrument log " & outFile & ": " & e.msg)

  var p: Process
  try:
    # Inherit the parent environment and add CT_INSTRUMENT_OUT.
    var env = newStringTable()
    for k, v in envPairs():
      env[k] = v
    env[InstrumentOutEnvVar] = outFile
    p = startProcess(
      binary, args = @args, env = env,
      options = {poStdErrToStdOut})
  except CatchableError as e:
    return err("failed to start instrumented binary '" & binary & "': " & e.msg)
  # Drain output (ignored — the capture is the file) and wait.
  var captured = ""
  try:
    captured = p.outputStream.readAll()
  except CatchableError:
    captured = ""
  let code = p.waitForExit()
  p.close()
  if code != 0:
    return err("instrumented binary '" & binary & "' exited with code " &
      $code & ":\n" & captured)
  ok(InstrumentRun(binary: binary, outFile: outFile))

proc instrumentAndRun*(sourceC, traceDir: string;
    args: openArray[string] = []): Result[InstrumentRun, string] =
  ## Compile a C `sourceC` with the recorder runtime + `-finstrument-functions`
  ## into `traceDir`, run it with `CT_INSTRUMENT_OUT` set, and return the run
  ## artifacts. Any compile/link/run failure ⇒ `Err`.
  if not dirExists(traceDir):
    return err("trace dir not found: " & traceDir)
  let binPath = traceDir / "instrumented_prog"
  let compiled = compileInstrumented(sourceC, binPath)
  if compiled.isErr:
    return err(compiled.error)
  runInstrumented(binPath, traceDir, args)

# ---------------------------------------------------------------------------
# Reading the captured executed-function set
# ---------------------------------------------------------------------------

proc stripLeadingUnderscore(name: string): string =
  ## Mach-O's C ABI prefixes a leading underscore (`_used_a`) and `dladdr`
  ## reports that mangled form; strip exactly one so names match the C
  ## identifiers `native_hash`'s symbol table keys on (it strips the same way).
  ## On ELF C symbols carry no prefix, so this is a no-op there.
  when defined(macosx):
    if name.len > 0 and name[0] == '_': name[1 .. ^1] else: name
  else:
    name

proc readInstrumentLog*(outFile: string): Result[seq[string], string] =
  ## Read the raw captured name log into a de-duplicated, sorted list of NAMES
  ## (leading Mach-O underscore stripped). One name per line; blank lines are
  ## ignored. A missing or empty (no resolvable names) log ⇒ `Err` (fail-safe).
  if not fileExists(outFile):
    return err("instrument log not found: " & outFile)
  var raw: string
  try:
    raw = readFile(outFile)
  except CatchableError as e:
    return err("failed to read instrument log " & outFile & ": " & e.msg)
  var seen = initHashSet[string]()
  for rawLine in raw.splitLines():
    let line = rawLine.strip()
    if line.len == 0:
      continue
    seen.incl stripLeadingUnderscore(line)
  if seen.len == 0:
    return err("instrument log " & outFile & " contains no function names")
  var names = seen.toSeq()
  names.sort(cmp)
  ok(names)

proc readExecutedFunctionsInstrumented*(traceDir: string):
    Result[seq[ExecutedFunction], string] =
  ## The instrumentation `DependencyDiscovery` implementation: read the
  ## executed-function SET captured by the recorder runtime from
  ## `<traceDir>/InstrumentOutFile`, as a de-duplicated, name-sorted
  ## `seq[ExecutedFunction]`.
  ##
  ## Each entry carries the executed function NAME (`name`) and the owning BINARY
  ## path (`file`); `defLine` is always 0 (native deps key on name+binary — see
  ## the module doc). The owning binary is the instrumented binary the run
  ## produced (`<traceDir>/instrumented_prog`) when present; this is the binary
  ## the native shallow hasher reads each function's instruction bytes from.
  ##
  ## BEST-EFFORT source resolution: if the binary is available we consult
  ## `native_hash.nativeFunctionTable` to confirm each captured name is a real,
  ## locatable code symbol; names absent from the binary's symbol table (e.g. a
  ## libc helper the loader resolved but which is not in THIS binary) are dropped
  ## from the dependency set — they are not functions of the unit under test and
  ## cannot be instruction-byte hashed against this binary. The NAME remains the
  ## dependency identity; file/defLine stay empty/0 per the native convention.
  ##
  ## Any structural problem (missing/empty log, no resolvable functions) ⇒ `Err`.
  if not dirExists(traceDir):
    return err("native instrument trace dir not found: " & traceDir)
  let outFile = traceDir / InstrumentOutFile
  let namesRes = readInstrumentLog(outFile)
  if namesRes.isErr:
    return err(namesRes.error)
  let names = namesRes.get()

  # The owning binary the run produced (if instrumentAndRun built it here). When
  # absent (e.g. a caller that ran a pre-built binary elsewhere) we still return
  # the names keyed on an empty binary path; the engine resolves the binary at
  # decide time. The common path produces the binary in the trace dir.
  let binary = traceDir / "instrumented_prog"
  let haveBinary = fileExists(binary)

  # Best-effort: build the binary's function table so we can confirm each
  # captured name is a locatable code symbol of THIS binary. If the table cannot
  # be built (e.g. tooling unavailable), we DO NOT fail — we keep every captured
  # name (the names are the dependency identity and the C runtime only emits
  # names dladdr resolved). The table only PRUNES names that are not this
  # binary's own functions; it never invents or relaxes the fail-safe.
  var symTable = initTable[string, native_hash.HashSlice]()
  var haveTable = false
  if haveBinary:
    let tblRes = nativeFunctionTable(binary)
    if tblRes.isOk:
      symTable = tblRes.get()
      haveTable = true

  var resultSeq: seq[ExecutedFunction] = @[]
  for name in names:
    if haveTable and name notin symTable:
      # Not a function of the unit under test (a loader/libc symbol dladdr
      # resolved). Drop it: it is not an instruction-byte-hashable dependency of
      # this binary.
      continue
    resultSeq.add ExecutedFunction(
      name: name,
      file: (if haveBinary: binary else: ""),
      defLine: 0)

  if resultSeq.len == 0:
    return err("native instrument capture in " & traceDir &
      " yielded no resolvable executed functions")

  resultSeq.sort(proc (a, b: ExecutedFunction): int = cmp(a.name, b.name))
  ok(resultSeq)
