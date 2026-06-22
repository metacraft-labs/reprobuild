## M13 live-recording test-support harness.
##
## The Phase-1/2 tests fed the engine HAND-CRAFTED traces; M12 fed it one
## committed REAL `.ct` bundle. M13 closes the loop: this module drives the REAL
## production recorders (native Ruby Rust extension, the Python maturin recorder,
## the JS SWC recorder, the native ct-mcr recorder) in THEIR OWN dev shells via
## `direnv exec <recorder-repo> ...`, records a given program LIVE into a modern
## CTFS `.ct` bundle, and hands the bundle's directory back to the engine.
##
## # Why a subprocess-into-the-recorder-dev-shell harness?
##
## Each recorder builds and runs in its own Nix dev shell (its toolchain — Rust,
## maturin/uv, node/napi, Nim — is not present in reprobuild's shell). The
## codetracer build-siblings strategy is exactly `direnv exec <sibling-repo>
## <cmd>`: it enters the sibling's dev shell and runs the command there. This
## harness follows that strategy for BOTH building a recorder and recording with
## it.
##
## # Build caching (idempotent, build-once)
##
## Recorder builds are slow (minutes). Each recorder exposes a cheap *built-marker*
## (the on-disk artefact a successful build produces). `ensureRecorderBuilt`
## checks the marker first and only runs the (heavy) build command when the marker
## is absent — so the build happens at most once per host, and re-running the
## tests reuses the prior build. `ct-print` reuses the SAME known-build-path
## caching the M12 test used (`/tmp/ctprint_build/ct-print`).
##
## # No silent skips
##
## A recorder that genuinely cannot build/record on THIS host (e.g. a broken
## nixpkgs package in its pinned flake, or ct-mcr's known arm64-macOS SIGBUS)
## does NOT yield a `unittest.skip`. The harness returns a `RecorderOutcome` that
## distinguishes a SUCCESS (a real `.ct` path) from a GATED failure carrying the
## EXACT captured diagnostic; the per-language tests assert on that outcome and
## emit a LOUD documented platform-gate when gated. The decision of skip-vs-gate
## lives in the test, never hidden here.

import std/[os, osproc, strutils, times]

import repro_ct_incremental  # M14 native instrumentation: instrumentAndRun, etc.

proc detectWorkspaceRoot(): string =
  ## The metacraft workspace root that holds reprobuild + the recorder repos as
  ## siblings (CodeTracer build-siblings strategy). Resolution order:
  ##   1. ``$REPRO_WORKSPACE_ROOT`` (explicit override — set by CI or when the
  ##      reprobuild checkout is a worktree outside the workspace tree).
  ##   2. The parent of the reprobuild checkout root, located by walking up from
  ##      this file (``<workspaceRoot>/<reprobuild>/libs/repro_ct_incremental/
  ##      tests/live_record.nim``) — the canonical sibling layout on any machine.
  ## This replaces the former hardcoded ``/Users/zahary/m/dev`` which only
  ## resolved on the author's macOS checkout.
  let override = getEnv("REPRO_WORKSPACE_ROOT")
  if override.len > 0:
    return override
  result = currentSourcePath()
  for _ in 0 ..< 5:
    result = result.parentDir

let
  WorkspaceRoot* = detectWorkspaceRoot()
  RubyRecorderRepo* = WorkspaceRoot / "codetracer-ruby-recorder"
  PythonRecorderRepo* = WorkspaceRoot / "codetracer-python-recorder"
  JsRecorderRepo* = WorkspaceRoot / "codetracer-js-recorder"
  NativeRecorderRepo* = WorkspaceRoot / "codetracer-native-recorder"
  TraceFormatRepo* = WorkspaceRoot / "codetracer-trace-format-nim"

const
  CtPrintKnownBuildPath* = "/tmp/ctprint_build/ct-print"
    ## The known build path the harness builds `ct-print` into (shared with the
    ## M12 test). `readExecutedFunctionsCtfs` falls back to this path when neither
    ## `$CT_PRINT` nor a `ct-print` on PATH resolves.

type
  RecorderOutcomeKind* = enum
    ## How a live recording attempt ended.
    roSuccess    ## A real `.ct` bundle was produced; `ctPath`/`traceDir` are set.
    roGated      ## The recorder genuinely could not build/record on this host;
                 ## `diagnostic` carries the EXACT captured failure. NOT a skip.

  RecorderOutcome* = object
    ## The result of `recordLive` — a live `.ct` path or a loud, documented gate.
    case kind*: RecorderOutcomeKind
    of roSuccess:
      traceDir*: string  ## Directory holding the produced `.ct` bundle.
      ctPath*: string    ## The produced `.ct` bundle itself.
    of roGated:
      diagnostic*: string  ## The exact failure observed (build/record output).

var liveTempCounter = 0

proc freshLiveDir*(prefix: string): string =
  ## A unique temp directory for a live recording's output (CTFS bundle) or
  ## source mirror. Uniqueness combines a microsecond timestamp and a process-
  ## local counter so concurrent/sequential recordings never collide.
  inc liveTempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let dir = getTempDir() / (prefix & $stamp & "_" & $liveTempCounter)
  createDir(dir)
  dir

proc runInRecorderShell*(repo, command: string): tuple[output: string, code: int] =
  ## Run `command` inside `repo`'s Nix dev shell via `direnv exec`, with the
  ## working directory set to `repo` (direnv exec resets cwd, so the command
  ## explicitly `cd`s into the repo first). Returns combined stdout+stderr and
  ## the exit code. Never raises — a launch failure is reported as a non-zero
  ## code with the exception text as output (so callers always get a diagnostic).
  let wrapped =
    "direnv exec " & quoteShell(repo) & " bash -c " &
    quoteShell("cd " & quoteShell(repo) & " && " & command)
  try:
    let (output, exitCode) = execCmdEx(wrapped)
    result = (output, exitCode)
  except CatchableError as e:
    result = ("failed to launch recorder shell for " & repo & ": " & e.msg, 127)
  except Exception as e:
    result = ("failed to launch recorder shell for " & repo & ": " & e.msg, 127)

proc ensureCtPrintBuilt*(): tuple[ok: bool, diagnostic: string] =
  ## Make `ct-print` resolvable at the known build path (idempotent). If the
  ## binary already exists it is reused; otherwise it is built ONCE in the
  ## trace-format-nim dev shell. Returns `(true, "")` on success, or
  ## `(false, <captured output>)` if it cannot be built — callers turn that into
  ## a hard error (ct-print is required to read any CTFS bundle).
  if fileExists(CtPrintKnownBuildPath):
    return (true, "")
  if not dirExists(TraceFormatRepo):
    return (false, "codetracer-trace-format-nim sibling not found at " &
      TraceFormatRepo)
  createDir(CtPrintKnownBuildPath.parentDir)
  let buildCmd =
    "nim c -d:release --mm:arc -p:src " &
    "--passC:\"$(pkg-config --cflags libzstd)\" " &
    "--passL:\"$(pkg-config --libs libzstd)\" " &
    "-o:" & quoteShell(CtPrintKnownBuildPath) & " src/codetracer_ct_print.nim"
  let (output, code) = runInRecorderShell(TraceFormatRepo, buildCmd)
  if code != 0 or not fileExists(CtPrintKnownBuildPath):
    return (false, "failed to build ct-print (exit " & $code & "):\n" & output)
  (true, "")

# ---------------------------------------------------------------------------
# Per-recorder build + record drivers.
#
# Each driver is structured the same way:
#   * a BUILT-MARKER predicate (cheap; reused so the build runs at most once),
#   * a BUILD command (heavy; run only when the marker is absent),
#   * a RECORD command that emits a `.ct` into a fresh out-dir.
# Any failure at any step is captured verbatim and returned as a `roGated`
# outcome (the loud, honest gate) — never swallowed.
# ---------------------------------------------------------------------------

proc rubyRecorderBin(): string =
  RubyRecorderRepo / "gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder"

proc rubyRecorderBuilt(): bool =
  ## The native Ruby recorder is a Rust extension; `just build` compiles the
  ## cdylib the bin loads (`require 'codetracer_ruby_recorder'`) into
  ## `gems/codetracer-ruby-recorder/ext/native_tracer/target/release/`. The built
  ## marker we probe is a compiled `.so` / `.dylib` / `.bundle` there — its
  ## presence means a prior `just build` succeeded, so the build is skipped.
  let targetRelease =
    RubyRecorderRepo / "gems/codetracer-ruby-recorder/ext/native_tracer/target/release"
  if not dirExists(targetRelease): return false
  for kind, path in walkDir(targetRelease):
    if kind in {pcFile, pcLinkToFile} and
        (path.endsWith(".dylib") or path.endsWith(".so") or
         path.endsWith(".bundle")):
      return true
  false

proc ensureRubyRecorderBuilt*(): tuple[ok: bool, diagnostic: string] =
  ## Build the native Ruby recorder once (idempotent via `rubyRecorderBuilt`).
  if rubyRecorderBuilt():
    return (true, "")
  let (output, code) = runInRecorderShell(RubyRecorderRepo, "just build")
  if code != 0 or not rubyRecorderBuilt():
    return (false, "failed to build the native Ruby recorder (exit " & $code &
      "):\n" & output)
  (true, "")

proc findCtBundle(dir: string): string =
  ## Return the single `.ct` bundle in `dir`, or "" if absent/ambiguous.
  var found: seq[string]
  if dirExists(dir):
    for kind, path in walkDir(dir):
      if kind in {pcFile, pcLinkToFile} and path.toLowerAscii().endsWith(".ct"):
        found.add path
  if found.len == 1: found[0] else: ""

proc findCtBundleRec(dir: string): string =
  ## Like `findCtBundle` but searches `dir` recursively, returning the single
  ## `.ct` bundle anywhere beneath it (or "" if absent/ambiguous). The JS
  ## recorder nests its bundle one level down (`<out-dir>/trace-N/<prog>.ct`)
  ## rather than writing it directly into `--out-dir` like the Ruby/Python
  ## recorders, so its driver needs the recursive search.
  var found: seq[string]
  if dirExists(dir):
    for path in walkDirRec(dir):
      if path.toLowerAscii().endsWith(".ct"):
        found.add path
  if found.len == 1: found[0] else: ""

proc markCtfsInterpreted*(traceDir: string) =
  ## Stamp an INTERPRETED-language CTFS trace dir with the explicit
  ## `recorder_backend: "ctfs-interpreted"` metadata signal, so `detectBackend`
  ## routes the bundle through the `tbSourceCtfs` backend (CTFS dependency
  ## discovery + SOURCE-TEXT shallow hashing) rather than the default native-`.ct`
  ## classification (instruction-byte hashing). Recorders for interpreted
  ## languages (Ruby/Python/JS) emit source-language CTFS, so this is the correct
  ## routing — exactly as the M12 test did for its committed Ruby `.ct`. The
  ## NATIVE recorder does NOT call this: a bare native `.ct` correctly detects as
  ## `tbNativeDwarf`.
  writeFile(traceDir / "trace_db_metadata.json",
    """{"format":"ctfs","recorder_backend":"ctfs-interpreted"}""")

proc recordRubyLive*(program: string): RecorderOutcome =
  ## Record a Ruby `program` LIVE with the native Ruby recorder into a fresh
  ## CTFS bundle. On success returns `roSuccess{traceDir, ctPath}`; any
  ## build/record failure returns `roGated{diagnostic}` (the honest gate).
  let built = ensureRubyRecorderBuilt()
  if not built.ok:
    return RecorderOutcome(kind: roGated, diagnostic: built.diagnostic)
  let outDir = freshLiveDir("repro_ct_live_ruby_")
  let cmd =
    quoteShell(rubyRecorderBin()) & " --out-dir " & quoteShell(outDir) & " " &
    quoteShell(program)
  let (output, code) = runInRecorderShell(RubyRecorderRepo, cmd)
  let bundle = findCtBundle(outDir)
  if code != 0 and bundle.len == 0:
    return RecorderOutcome(kind: roGated,
      diagnostic: "ruby recording failed (exit " & $code & "):\n" & output)
  if bundle.len == 0:
    return RecorderOutcome(kind: roGated,
      diagnostic: "ruby recording produced no .ct bundle in " & outDir &
        ":\n" & output)
  markCtfsInterpreted(outDir)  # interpreted CTFS ⇒ source-text hashing
  RecorderOutcome(kind: roSuccess, traceDir: outDir, ctPath: bundle)

proc pythonVenvPython(): string =
  ## The CPython interpreter inside the recorder's dev venv. `just venv 3.13 dev`
  ## creates a top-level `.venv` in the repo root and installs the recorder into
  ## it editable, so the `__main__` entry (`python -m codetracer_python_recorder`)
  ## resolves from this interpreter.
  PythonRecorderRepo / ".venv/bin/python"

proc pythonRecorderBuilt(): bool =
  ## The Python recorder is a maturin/PyO3 native extension installed editable
  ## into the repo's `.venv` by `just venv 3.13 dev`. Two facts together prove a
  ## successful prior build:
  ##   * the venv interpreter exists (`<repo>/.venv/bin/python`), and
  ##   * the compiled native extension is present in the (editable-linked) source
  ##     tree — `codetracer-python-recorder/codetracer_python_recorder/
  ##     codetracer_python_recorder.cpython-*.so`.
  ## Probing the source-tree `.so` (rather than walking site-packages, which for
  ## an editable install only contains a `.pth`) is the reliable built-marker.
  if not fileExists(pythonVenvPython()):
    return false
  let pkgDir =
    PythonRecorderRepo / "codetracer-python-recorder/codetracer_python_recorder"
  if dirExists(pkgDir):
    for kind, path in walkDir(pkgDir):
      if kind in {pcFile, pcLinkToFile} and
          path.toLowerAscii().endsWith(".so") and
          "codetracer_python_recorder" in path.extractFilename.toLowerAscii():
        return true
  false

proc ensurePythonRecorderBuilt*(): tuple[ok: bool, diagnostic: string] =
  ## Build the Python recorder once (idempotent via `pythonRecorderBuilt`). The
  ## heavy maturin compile (~1-2 min) runs ONLY when the built-marker is absent;
  ## the build command is `just venv 3.13 dev`, which provisions a Python 3.13
  ## venv and installs the recorder editable into `<repo>/.venv`. The build was
  ## previously WRONGLY reported as impossible on this host — that used the wrong
  ## entry (`just dev` + `uv`); `just venv 3.13 dev` builds and records LIVE here
  ## (after the recorder's flake fix gating `cargo-llvm-cov` off darwin, pushed
  ## upstream).
  if pythonRecorderBuilt():
    return (true, "")
  let (output, code) = runInRecorderShell(PythonRecorderRepo, "just venv 3.13 dev")
  if code != 0 or not pythonRecorderBuilt():
    return (false, "failed to build the Python recorder (exit " & $code &
      "):\n" & output)
  (true, "")

proc recordPythonLive*(program: string): RecorderOutcome =
  ## Record a Python `program` LIVE with the production maturin/PyO3 recorder into
  ## a fresh CTFS bundle. The recorder runs as `python -m codetracer_python_recorder
  ## --out-dir <dir> <prog>` using the venv interpreter (the `__main__` entry); it
  ## writes `<out-dir>/<script-stem>.ct`. Any build/record failure returns a loud
  ## `roGated` — but on this host this path is GENUINELY live (proven).
  let built = ensurePythonRecorderBuilt()
  if not built.ok:
    return RecorderOutcome(kind: roGated, diagnostic: built.diagnostic)
  let outDir = freshLiveDir("repro_ct_live_python_")
  let cmd =
    quoteShell(pythonVenvPython()) &
    " -m codetracer_python_recorder --out-dir " & quoteShell(outDir) &
    " " & quoteShell(program)
  let (output, code) = runInRecorderShell(PythonRecorderRepo, cmd)
  let bundle = findCtBundle(outDir)
  if code != 0 and bundle.len == 0:
    return RecorderOutcome(kind: roGated,
      diagnostic: "python recording failed (exit " & $code & "):\n" & output)
  if bundle.len == 0:
    return RecorderOutcome(kind: roGated,
      diagnostic: "python recording produced no .ct bundle (exit " & $code &
        ") in " & outDir & ":\n" & output)
  markCtfsInterpreted(outDir)  # interpreted CTFS ⇒ source-text hashing
  RecorderOutcome(kind: roSuccess, traceDir: outDir, ctPath: bundle)

proc jsRecorderBuilt(): bool =
  ## The JS recorder is an SWC instrumenter + a napi-rs native runtime. `just
  ## build` builds the native cdylib (`build-native`) and the JS workspace
  ## packages. The built marker is the napi `.node` artefact under
  ## `crates/recorder_native/`.
  let nativeDir = JsRecorderRepo / "crates/recorder_native"
  if dirExists(nativeDir):
    for kind, path in walkDir(nativeDir):
      if kind in {pcFile, pcLinkToFile} and path.toLowerAscii().endsWith(".node"):
        return true
  false

proc ensureJsRecorderBuilt*(): tuple[ok: bool, diagnostic: string] =
  ## Build the JS recorder once (`just build`). Idempotent.
  if jsRecorderBuilt():
    return (true, "")
  let (output, code) = runInRecorderShell(JsRecorderRepo, "just build")
  if code != 0 or not jsRecorderBuilt():
    return (false, "failed to build the JS recorder (exit " & $code & "):\n" &
      output)
  (true, "")

proc jsRecorderCli(): string =
  ## The JS recorder CLI entry (the `record` subcommand). The CLI package ships
  ## a bin; we invoke it through `node` on the built CLI dist.
  JsRecorderRepo / "packages/cli/dist/index.js"

proc recordJsLive*(program: string): RecorderOutcome =
  ## Record a JS `program` LIVE with the SWC recorder into a fresh CTFS bundle.
  ## Uses the `record` subcommand (per Recorder-CLI-Conventions §2: the JS
  ## recorder has a separate instrument step, so recording is `record <app.js>`).
  let built = ensureJsRecorderBuilt()
  if not built.ok:
    return RecorderOutcome(kind: roGated, diagnostic: built.diagnostic)
  let outDir = freshLiveDir("repro_ct_live_js_")
  let cli = jsRecorderCli()
  let cmd =
    "node " & quoteShell(cli) & " record --out-dir " & quoteShell(outDir) &
    " " & quoteShell(program)
  let (output, code) = runInRecorderShell(JsRecorderRepo, cmd)
  # The JS recorder nests the bundle under a `trace-N/` subdir of `--out-dir`
  # (unlike the Ruby/Python recorders), so search recursively and use the
  # bundle's OWN directory as the trace dir the engine reads.
  let bundle = findCtBundleRec(outDir)
  if bundle.len == 0:
    return RecorderOutcome(kind: roGated,
      diagnostic: "js recording produced no .ct bundle (exit " & $code &
        ") in " & outDir & ":\n" & output)
  let bundleDir = bundle.parentDir
  markCtfsInterpreted(bundleDir)  # interpreted CTFS ⇒ source-text hashing
  RecorderOutcome(kind: roSuccess, traceDir: bundleDir, ctPath: bundle)

proc ctMcrBin(): string =
  NativeRecorderRepo / "ct_cli/ct_cli"

proc nativeRecorderBuilt(): bool =
  ## The native recorder's `ct-mcr` (built from `ct_cli`) is the multi-core
  ## recorder. The built marker is the `ct_cli` binary.
  fileExists(ctMcrBin())

proc ensureNativeRecorderBuilt*(): tuple[ok: bool, diagnostic: string] =
  ## Build `ct-mcr` once (`just build-ct-mcr`). Idempotent. On a host where the
  ## build itself fails this returns the captured diagnostic (a gate at build
  ## time); a host where the build SUCCEEDS but recording SIGBUSes gates at
  ## record time (see `recordNativeLive`).
  if nativeRecorderBuilt():
    return (true, "")
  let (output, code) = runInRecorderShell(NativeRecorderRepo, "just build-ct-mcr")
  if code != 0 or not nativeRecorderBuilt():
    return (false, "failed to build ct-mcr (exit " & $code & "):\n" & output)
  (true, "")

proc recordNativeLive*(programBinary: string): RecorderOutcome =
  ## Attempt to record a native `programBinary` LIVE with `ct-mcr`. On Linux with
  ## RR support this records to CTFS; on arm64-macOS `ct-mcr` is known to SIGBUS
  ## (RR is Linux-only and the macOS MCR path is not stable here), in which case
  ## this returns `roGated{diagnostic}` carrying the EXACT failure. The caller
  ## emits the loud platform-gate.
  let built = ensureNativeRecorderBuilt()
  if not built.ok:
    return RecorderOutcome(kind: roGated, diagnostic: built.diagnostic)
  let outDir = freshLiveDir("repro_ct_live_native_")
  # ct-mcr's record CLI is `record -o <out.ct> -- <program> [args...]` (NOT the
  # interpreted recorders' `--out-dir`). The bundle is written to the explicit
  # `-o` path inside `outDir` so `findCtBundle` can locate it.
  let outCt = outDir / "native.ct"
  let cmd =
    quoteShell(ctMcrBin()) & " record -o " & quoteShell(outCt) &
    " -- " & quoteShell(programBinary)
  let (output, code) = runInRecorderShell(NativeRecorderRepo, cmd)
  let bundle = findCtBundle(outDir)
  if bundle.len == 0:
    return RecorderOutcome(kind: roGated,
      diagnostic: "native ct-mcr recording produced no .ct bundle (exit " &
        $code & ") in " & outDir & ":\n" & output)
  RecorderOutcome(kind: roSuccess, traceDir: outDir, ctPath: bundle)

# ---------------------------------------------------------------------------
# Native LIVE recording via compile-time instrumentation (M15).
#
# Unlike ct-mcr (which needs a Linux MCR/RR host to emit a function-level call
# stream — see `recordNativeLive`), the M14 compile-time-instrumentation path
# produces a GENUINE native call trace on arm64-macOS with no Intel PT / RR /
# MCR. This driver reuses M14's `native_instrument` module (it does NOT
# duplicate the compile/run logic): it compiles a C `programSource` with
# `-finstrument-functions` + the committed C recorder runtime, runs it with
# `CT_INSTRUMENT_OUT` into a fresh trace dir, and stamps the dir with the
# native-instrumented metadata marker so `detectBackend` routes it to the native
# instruction-byte backend (`tbNativeDwarf`).
#
# The produced trace dir carries everything the engine's native backend reads:
#   * the executed-function names log (`native_instrument_calls.log`),
#   * the recorded binary (`instrumented_prog`) — the native shallow hash reads
#     each function's compiled instruction bytes from it, and
#   * `trace_db_metadata.json` (`recorder_backend: "native-instrumented"`).
# ---------------------------------------------------------------------------

proc markNativeInstrumented*(traceDir: string) =
  ## Stamp a native compile-time-instrumentation trace dir with the explicit
  ## `recorder_backend: "native-instrumented"` metadata signal, so
  ## `detectBackend` routes it through the native instruction-byte backend
  ## (`tbNativeDwarf`). The presence of `trace_db_metadata.json` is ALSO a native
  ## structural signal, so this is belt-and-suspenders; the explicit field makes
  ## the intent self-documenting and robust to future structural changes.
  writeFile(traceDir / "trace_db_metadata.json",
    """{"format":"native-instrument","recorder_backend":"native-instrumented"}""")

proc recordNativeInstrumentedLive*(programSource: string): RecorderOutcome =
  ## Record a native C `programSource` LIVE via compile-time instrumentation into
  ## a fresh trace dir, producing the names log + the recorded binary + the
  ## native-instrumented metadata marker the engine's native backend reads.
  ##
  ## On success returns `roSuccess{traceDir, ctPath}` where `ctPath` is the
  ## RECORDED BINARY (`<traceDir>/instrumented_prog`) — the native shallow hash's
  ## input (there is no `.ct` bundle on this path; the native flavour keys on the
  ## binary, not a CTFS container). Any compile/run/read failure returns
  ## `roGated{diagnostic}` (the honest gate); on arm64-macOS this path is
  ## genuinely live, so a gate here is a real toolchain regression, not a platform
  ## limitation.
  let outDir = freshLiveDir("repro_ct_live_native_instr_")
  let src = outDir / "prog.c"
  try:
    writeFile(src, programSource)
  except CatchableError as e:
    return RecorderOutcome(kind: roGated,
      diagnostic: "could not write native instrumentation source " & src &
        ": " & e.msg)
  let runRes = instrumentAndRun(src, outDir)
  if runRes.isErr:
    return RecorderOutcome(kind: roGated,
      diagnostic: "native instrumentation compile/run failed: " & runRes.error)

  # Also build a CLEAN (non-instrumented) binary of the SAME source for SHALLOW
  # HASHING. Instrumentation injects `__cyg_profile_func_*` calls that make every
  # function's bytes relocation-sensitive to unrelated edits, so the hash must be
  # over the real production binary (see `native_trace.instrumentHashBinaryPath`).
  # Use the M7 stability flags so a function's bytes depend only on its own body.
  let cleanBin = outDir / RecordedBinaryName
  let cc = (let e = getEnv("CC"); if e.len > 0: e else: "cc")
  let cleanCmd =
    quoteShell(cc) & " -O0 -g -fno-stack-protector " &
    "-fno-asynchronous-unwind-tables -o " & quoteShell(cleanBin) & " " &
    quoteShell(src)
  let (cleanOut, cleanCode) = execCmdEx(cleanCmd)
  if cleanCode != 0 or not fileExists(cleanBin):
    return RecorderOutcome(kind: roGated,
      diagnostic: "clean (non-instrumented) recorded binary build failed (exit " &
        $cleanCode & "):\n" & cleanOut)

  markNativeInstrumented(outDir)
  RecorderOutcome(kind: roSuccess, traceDir: outDir, ctPath: cleanBin)
