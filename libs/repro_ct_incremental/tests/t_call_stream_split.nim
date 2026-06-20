## M17a — the engine extracts the SAME executed set from a SPLIT bundle
## (dedicated `calls.dat` call stream, `has_call_stream` flag set) and a LEGACY
## bundle (no flag), proving the dedicated call stream is a backward-compatible,
## results-preserving storage split.
##
## Fixtures (both under `tests/fixtures/m12_ctfs/`):
##   * `ruby.ct`        — the LEGACY bundle (recorded by the native Ruby
##     recorder; `has_call_stream` clear).  It already carries a `calls.dat`
##     physically (the multi-stream writer always wrote one), but the
##     capability flag was introduced in M17a so the committed legacy fixture
##     leaves it clear.
##   * `ruby_split.ct`  — a byte-for-byte twin with ONLY the `meta.dat`
##     `has_call_stream` flag bit (bit 8, 0x100) SET.  Generated deterministically
##     from `ruby.ct` (flip the single u16 flags field after the unique `CTMD`
##     magic).  Re-generate with:
##       python3 - <<'PY'
##       d=bytearray(open('tests/fixtures/m12_ctfs/ruby.ct','rb').read())
##       i=d.find(b'CTMD'); f=int.from_bytes(d[i+6:i+8],'little')|0x100
##       d[i+6:i+8]=f.to_bytes(2,'little')
##       open('tests/fixtures/m12_ctfs/ruby_split.ct','wb').write(d)
##       PY
##
## Both bundles are read through the SAME `ct-print --json-events` path the
## M12 engine uses (the executed set is extracted from the unified event stream
## for BOTH — M17a does NOT yet read `calls.dat` for discovery; that is M17b),
## so the extracted executed set MUST be identical.  `ctfsHasCallStream` reports
## the flag (true for the split bundle, false for the legacy one); the engine
## DETECTS the dedicated stream here and will PREFER it for discovery in M17b.

import std/[unittest, os, strutils, times, osproc, algorithm]
import repro_ct_incremental

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  ctfsFixture = fixturesDir / "m12_ctfs"
  legacyBundle = ctfsFixture / "ruby.ct"
  splitBundle = ctfsFixture / "ruby_split.ct"
  rubySource = ctfsFixture / "live_demo.rb"
  relSourcePath = "tmp/live_demo.rb"
  traceFormatRepo = "/Users/zahary/m/dev/codetracer-trace-format-nim"

var tempCounter = 0

proc freshTempDir(prefix: string): string =
  inc tempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let dir = getTempDir() / (prefix & $stamp & "_" & $tempCounter)
  createDir(dir)
  dir

proc ensureCtPrint() =
  ## Make `ct-print` resolvable (CT_PRINT / PATH / known build path), building
  ## it once into the known path if absent.  A build failure is a HARD error —
  ## never a silent skip (mirrors the M12 `t_ctfs_reader` setup).
  if resolveCtPrint().isOk:
    return
  doAssert dirExists(traceFormatRepo),
    "codetracer-trace-format-nim sibling not found at " & traceFormatRepo &
    " — cannot build ct-print for the M17a tests"
  createDir("/tmp/ctprint_build")
  let buildCmd =
    "direnv exec " & quoteShell(traceFormatRepo) & " bash -c " &
    quoteShell(
      "cd " & quoteShell(traceFormatRepo) & " && " &
      "nim c -d:release --mm:arc -p:src " &
      "--passC:\"$(pkg-config --cflags libzstd)\" " &
      "--passL:\"$(pkg-config --libs libzstd)\" " &
      "-o:/tmp/ctprint_build/ct-print src/codetracer_ct_print.nim")
  let (output, code) = execCmdEx(buildCmd)
  doAssert code == 0,
    "failed to build ct-print for the M17a tests (exit " & $code & "):\n" & output
  doAssert resolveCtPrint().isOk,
    "ct-print still not resolvable after building:\n" & output

proc namesOf(funcs: seq[ExecutedFunction]): seq[string] =
  for f in funcs: result.add f.name
  result.sort()

proc makeSourceRoot(): string =
  let root = freshTempDir("repro_ct_m17_src_")
  let dst = root / relSourcePath
  createDir(dst.parentDir)
  copyFile(rubySource, dst)
  root

proc traceDirWith(bundle, fileName: string): string =
  ## A fresh trace dir holding a copy of `bundle` plus the ctfs-interpreted
  ## backend signal so `detectBackend` routes to source-CTFS discovery.
  let dir = freshTempDir("repro_ct_m17_trace_")
  copyFile(bundle, dir / fileName)
  writeFile(dir / "trace_db_metadata.json",
    """{"format":"ctfs","recorder_backend":"ctfs-interpreted"}""")
  dir

suite "M17a dedicated call-stream split":

  setup:
    ensureCtPrint()

  test "fixtures_exist":
    check fileExists(legacyBundle)
    check fileExists(splitBundle)

  test "has_call_stream_flag_distinguishes_the_two_bundles":
    # The split bundle advertises the dedicated call stream; the legacy one
    # does not.  (Both physically contain calls.dat — the flag is the gate.)
    let splitFlag = ctfsHasCallStream(splitBundle)
    check splitFlag.isOk
    check splitFlag.get() == true

    let legacyFlag = ctfsHasCallStream(legacyBundle)
    check legacyFlag.isOk
    check legacyFlag.get() == false

  test "engine_extracts_identical_executed_set_split_vs_legacy":
    # The crux of M17a: the executed-function SET is identical whether the
    # bundle advertises the dedicated call stream or not.
    let splitRes = readExecutedFunctionsCtfs(splitBundle)
    let legacyRes = readExecutedFunctionsCtfs(legacyBundle)
    check splitRes.isOk
    check legacyRes.isOk

    let splitFuncs = splitRes.get()
    let legacyFuncs = legacyRes.get()

    # Same names, same count.
    check namesOf(splitFuncs) == namesOf(legacyFuncs)
    check splitFuncs.len == legacyFuncs.len

    # And the FULL records (name + file + defLine) match element-for-element
    # (both are name-sorted by the reader), so nothing about discovery changed
    # beyond the storage layout.
    check splitFuncs.len == legacyFuncs.len
    for i in 0 ..< splitFuncs.len:
      check splitFuncs[i].name == legacyFuncs[i].name
      check splitFuncs[i].file == legacyFuncs[i].file
      check splitFuncs[i].defLine == legacyFuncs[i].defLine

    # Spot-check the known executed set of the fixture program.
    let names = namesOf(splitFuncs)
    check "used_a" in names
    check "used_b" in names
    check "main" in names
    check "unused_c" notin names

  test "engine_decides_identically_over_split_and_legacy_bundles":
    # record() + decide() must reach the SAME verdicts over both bundles:
    #   unchanged source ⇒ skip; editing an executed function ⇒ re-run.
    for (bundle, fileName) in [(legacyBundle, "ruby.ct"), (splitBundle, "ruby_split.ct")]:
      let traceDir = traceDirWith(bundle, fileName)

      # (a) unchanged ⇒ skip
      let rootSkip = makeSourceRoot()
      var cacheSkip = initCache(rootSkip / "cache.json")
      check record(cacheSkip, "ruby_test", traceDir, rootSkip).isOk
      check decide("ruby_test", traceDir, rootSkip, cacheSkip).kind == idSkipUnchanged

      # (b) edit an executed function ⇒ re-run naming it
      let rootRerun = makeSourceRoot()
      var cacheRerun = initCache(rootRerun / "cache.json")
      check record(cacheRerun, "ruby_test", traceDir, rootRerun).isOk
      block:
        let path = rootRerun / relSourcePath
        var lines = readFile(path).split('\n')
        for i in 0 ..< lines.len:
          if lines[i].strip().startsWith("def used_a"):
            lines[i] = "def used_a(x); x + 1000; end"
        writeFile(path, lines.join("\n"))
      let dec = decide("ruby_test", traceDir, rootRerun, cacheRerun)
      check dec.kind == idRerunChanged
      check "used_a" in dec.changedFuncs
      check "used_b" notin dec.changedFuncs
