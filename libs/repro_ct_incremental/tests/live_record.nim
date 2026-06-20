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

const
  # Recorder sibling repos, resolved relative to this checkout's parent. The
  # reprobuild checkout and the recorder checkouts are siblings in the workspace
  # (see CodeTracer build-siblings strategy), so `../<recorder>` from the
  # reprobuild repo root is the canonical location.
  WorkspaceRoot* = "/Users/zahary/m/dev"
    ## The metacraft workspace root that holds reprobuild + the recorder repos as
    ## siblings. The recorders live at `<WorkspaceRoot>/<recorder-repo>`.

  RubyRecorderRepo* = WorkspaceRoot / "codetracer-ruby-recorder"
  PythonRecorderRepo* = WorkspaceRoot / "codetracer-python-recorder"
  JsRecorderRepo* = WorkspaceRoot / "codetracer-js-recorder"
  NativeRecorderRepo* = WorkspaceRoot / "codetracer-native-recorder"
  TraceFormatRepo* = WorkspaceRoot / "codetracer-trace-format-nim"

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

proc pythonRecorderBuilt(): bool =
  ## The Python recorder is a maturin native extension installed into the repo's
  ## uv venv by `just dev`. The built marker is the compiled `_codetracer_*` /
  ## native module in the venv's site-packages, OR the uv venv with the recorder
  ## importable. We conservatively probe for the venv + a built `.so`.
  let venv = PythonRecorderRepo / "codetracer-python-recorder/.venv"
  if dirExists(venv):
    for path in walkDirRec(venv):
      if path.toLowerAscii().endsWith(".so") and
          "codetracer" in path.toLowerAscii():
        return true
  false

proc ensurePythonRecorderBuilt*(): tuple[ok: bool, diagnostic: string] =
  ## Build the Python recorder once (`just dev`). Idempotent.
  if pythonRecorderBuilt():
    return (true, "")
  let (output, code) = runInRecorderShell(PythonRecorderRepo, "just dev")
  if code != 0 or not pythonRecorderBuilt():
    return (false, "failed to build the Python recorder (exit " & $code &
      "):\n" & output)
  (true, "")

proc recordPythonLive*(program: string): RecorderOutcome =
  ## Record a Python `program` LIVE with the maturin recorder into a fresh CTFS
  ## bundle. The recorder runs as `python -m codetracer_python_recorder
  ## --out-dir <dir> <prog>` inside the repo's uv venv (the `__main__` entry).
  let built = ensurePythonRecorderBuilt()
  if not built.ok:
    return RecorderOutcome(kind: roGated, diagnostic: built.diagnostic)
  let outDir = freshLiveDir("repro_ct_live_python_")
  let cmd =
    "uv run --directory codetracer-python-recorder " &
    "python -m codetracer_python_recorder --out-dir " & quoteShell(outDir) &
    " " & quoteShell(program)
  let (output, code) = runInRecorderShell(PythonRecorderRepo, cmd)
  let bundle = findCtBundle(outDir)
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
  let bundle = findCtBundle(outDir)
  if bundle.len == 0:
    return RecorderOutcome(kind: roGated,
      diagnostic: "js recording produced no .ct bundle (exit " & $code &
        ") in " & outDir & ":\n" & output)
  markCtfsInterpreted(outDir)  # interpreted CTFS ⇒ source-text hashing
  RecorderOutcome(kind: roSuccess, traceDir: outDir, ctPath: bundle)

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
