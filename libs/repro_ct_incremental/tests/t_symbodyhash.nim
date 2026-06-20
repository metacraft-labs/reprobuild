## M11 tests — the compile-time `symBodyHash` DEEP path + the tiered selector,
## with the runtime SHALLOW path retained and proven intact.
##
## # Catalog source (path 1b — documented, cited)
##
## The in-tree CodeTracer unit-testing library (`ct_test_unittest_parallel`)
## does NOT emit a `bodyHash`/`symBodyHash` field in its `--list-json` catalog —
## its `emitListJson` carries only `name`/`suite`/`file`/`line`
## (`libs/ct_test_unittest_parallel/src/ct_test_unittest_parallel.nim`). So the
## §3.6 "Full" tier (`bodyHash` in `--list-json`) is NOT available out of the
## box, and M11 catalog source path (1a) is unavailable here. We take path (1b):
## produce a REAL `symBodyHash` catalog with `std/macros.symBodyHash` (§16.2) via
## the `symbodyhash_catalog` helper, then drive the engine's deep path against
## those GENUINE compile-time hashes. The "test bodies" are the procs below; the
## catalog maps a test id to `symBodyHash(theProc)`. Changing which proc a test
## maps to (or the proc's transitive callee) changes the genuine hash exactly as
## a real source edit between builds would.
##
## # What these four tests prove (the M11 acceptance)
##
##   * catalog_bodyhash_unchanged_skips_without_a_trace — an unchanged catalog
##     hash ⇒ `idSkipUnchanged` via the DEEP path with NO trace dir and NO
##     shallow hashing. To PROVE the deep path ran (and the shallow path did
##     NOT), the tiered selector is given a deliberately-broken traceDir AND
##     sourceRoot that would force a fail-safe re-run / changed decision if the
##     shallow path were consulted — yet it still skips.
##   * catalog_bodyhash_changed_reruns — a changed catalog hash ⇒
##     `idRerunChanged`.
##   * no_catalog_falls_back_to_shallow_path — with NO catalog bodyHash for the
##     test, the tiered selector decides EXACTLY as the existing `decide` does
##     (run the same real m0 case both ways, assert byte-identical decisions),
##     proving the shallow path is intact and used.
##   * deep_preferred_over_shallow_when_both_available — when BOTH a catalog
##     bodyHash and a real trace exist, the DEEP path is taken (asserted), and a
##     static over-estimate is a SAFE re-run, never a false skip.

import std/[unittest, os, strutils, times]
import repro_ct_incremental
import ./symbodyhash_catalog

# ---------------------------------------------------------------------------
# Genuine-symBodyHash fixture "test" procs (path 1b)
# ---------------------------------------------------------------------------
#
# These are ordinary procs. Their `symBodyHash` is a real compile-time deep hash
# over their transitive call graph. `testProcVariantOne` and
# `testProcVariantTwo` differ in body (and callee), so their genuine hashes
# differ — that is how we simulate "the same test changed between builds".

proc helperLeaf(): int = 41

proc testProcVariantOne(): int =
  ## "Build A" body of a test: calls `helperLeaf`, returns 1 more.
  helperLeaf() + 1

proc testProcVariantTwo(): int =
  ## "Build B" body of the SAME test, materially changed (different arithmetic
  ## and a different transitive shape) ⇒ a different genuine `symBodyHash`.
  helperLeaf() * 2 - 5

# ---------------------------------------------------------------------------
# Shallow-path fixture (the real m0 Ruby fixture, reused verbatim from M1)
# ---------------------------------------------------------------------------

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  threeFuncsFixture = fixturesDir / "m0_three_funcs"
  threeFuncsTrace = threeFuncsFixture / "trace"
  relSourcePath = "fixtures/m0_three_funcs/src/three_funcs.rb"

var tempCounter = 0

proc makeSourceRoot(): string =
  ## Fresh temp dir with the m0 Ruby source copied to the path the trace expects.
  inc tempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let root = getTempDir() / ("repro_ct_m11_" & $stamp & "_" & $tempCounter)
  let dst = root / relSourcePath
  createDir(dst.parentDir)
  copyFile(threeFuncsFixture / "src" / "three_funcs.rb", dst)
  root

proc editFunctionBody(root, funcName, newBody: string) =
  ## Replace the single-line body of `funcName` in the temp source (m0 layout:
  ## `def <name>\n  <body>\nend`).
  let path = root / relSourcePath
  var lines = readFile(path).split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip() == "def " & funcName:
      doAssert i + 1 < lines.len
      lines[i + 1] = "  " & newBody
      writeFile(path, lines.join("\n"))
      return
  doAssert false, "function not found: " & funcName

# Genuine compile-time hashes (computed ONCE at compile time, embedded as
# literals — exactly how a library would embed a test's bodyHash, §16.3).
const
  hashVariantOne = symBodyHashOf(testProcVariantOne)
  hashVariantTwo = symBodyHashOf(testProcVariantTwo)

suite "M11: symBodyHash deep path + retained shallow path":

  test "genuine_symbodyhash_fixture_is_real_and_discriminating":
    # Guard: the fixture hashes are REAL compile-time symBodyHashes (non-empty)
    # and DISCRIMINATE the two variants — otherwise the changed/unchanged tests
    # below would be vacuous. (symBodyHash digests are MD5-derived hex strings.)
    check hashVariantOne.len > 0
    check hashVariantTwo.len > 0
    check hashVariantOne != hashVariantTwo

  test "catalog_bodyhash_unchanged_skips_without_a_trace":
    # Record a test purely by its genuine deep hash (NO trace, NO deps).
    var cache = initCache(getTempDir() / ("repro_ct_m11_cache_a_" &
      $(epochTime() * 1e6).int64 & ".json"))
    const testId = "Suite::deep_unchanged"
    cache.recordBodyHash(testId, hashVariantOne)

    # Current build reports the SAME genuine hash for this test.
    let catRes = parseBodyHashCatalog(catalogJson({testId: hashVariantOne}))
    check catRes.isOk
    let catalog = catRes.value
    check catalog.hasBodyHash(testId)

    # Deliberately BROKEN trace dir + sourceRoot: if the shallow path were
    # consulted it would fail-safe re-run (missing trace dir) — so a skip here
    # PROVES the deep path ran and the shallow path was never touched.
    let brokenTraceDir = getTempDir() / "repro_ct_m11_does_not_exist_trace"
    let brokenSourceRoot = getTempDir() / "repro_ct_m11_does_not_exist_src"
    doAssert not dirExists(brokenTraceDir)

    let d = decideTiered(testId, catalog, brokenTraceDir, brokenSourceRoot, cache)
    check d.kind == idSkipUnchanged

    # And the direct deep entry point agrees (no trace involved at all).
    check decideByCatalog(testId, catalog, cache).kind == idSkipUnchanged

  test "catalog_bodyhash_changed_reruns":
    var cache = initCache(getTempDir() / ("repro_ct_m11_cache_b_" &
      $(epochTime() * 1e6).int64 & ".json"))
    const testId = "Suite::deep_changed"
    # Recorded against "build A"'s genuine hash...
    cache.recordBodyHash(testId, hashVariantOne)
    # ...but the current build reports "build B"'s genuine hash (the test body
    # / its transitive callee changed) ⇒ re-run.
    let catRes = parseBodyHashCatalog(catalogJson({testId: hashVariantTwo}))
    check catRes.isOk
    let catalog = catRes.value

    let d = decideTiered(testId, catalog, "/nonexistent", "/nonexistent", cache)
    check d.kind == idRerunChanged
    check decideByCatalog(testId, catalog, cache).kind == idRerunChanged

  test "no_catalog_falls_back_to_shallow_path":
    # The shallow-path-intact proof: with NO catalog bodyHash for the test, the
    # tiered selector must decide EXACTLY as the existing `decide` does. We run
    # the same real m0 case both ways and assert byte-identical decisions for
    # (a) an unchanged source ⇒ skip and (b) an executed-function change ⇒ rerun.
    const testId = "Suite::shallow_only"
    let emptyCatRes = parseBodyHashCatalog("{}")
    check emptyCatRes.isOk
    let emptyCatalog = emptyCatRes.value
    check not emptyCatalog.hasBodyHash(testId)

    block unchangedSource:
      let root = makeSourceRoot()
      var cache = initCache(root / "cache.json")
      check record(cache, testId, threeFuncsTrace, root).isOk
      # Tiered (no catalog hash) vs the raw shallow `decide`, same inputs.
      let viaTiered = decideTiered(testId, emptyCatalog, threeFuncsTrace, root, cache)
      let viaShallow = decide(testId, threeFuncsTrace, root, cache)
      check viaShallow.kind == idSkipUnchanged
      check viaTiered.kind == viaShallow.kind

    block executedFunctionChanged:
      let root = makeSourceRoot()
      var cache = initCache(root / "cache.json")
      check record(cache, testId, threeFuncsTrace, root).isOk
      # `used_a` IS executed in the m0 trace ⇒ editing it forces a shallow rerun.
      editFunctionBody(root, "used_a", "99 + 99")
      let viaTiered = decideTiered(testId, emptyCatalog, threeFuncsTrace, root, cache)
      let viaShallow = decide(testId, threeFuncsTrace, root, cache)
      check viaShallow.kind == idRerunChanged
      check viaShallow.changedFuncs == @["used_a"]
      # IDENTICAL decision through the tiered selector — the shallow path is the
      # one that ran, and ran exactly as before.
      check viaTiered.kind == viaShallow.kind
      check viaTiered.changedFuncs == viaShallow.changedFuncs

  test "deep_preferred_over_shallow_when_both_available":
    # BOTH a real catalog bodyHash AND a real trace/source exist. The DEEP path
    # must win. To prove the deep path was taken (not the shallow one), set up a
    # situation where the two paths would DISAGREE:
    #   * Deep: the catalog reports a CHANGED hash ⇒ deep ⇒ idRerunChanged.
    #   * Shallow: the source is UNCHANGED since record ⇒ shallow ⇒ idSkipUnchanged.
    # The tiered selector returning idRerunChanged proves deep was chosen. This
    # is also the static-over-estimate-is-safe case: a static deep hash drives a
    # conservative RE-RUN, never a false skip.
    const testId = "Suite::both_available"
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    # Record BOTH the shallow deps (from the real m0 trace) AND the genuine
    # "build A" deep hash, so the deep path has a baseline to compare against.
    check record(cache, testId, threeFuncsTrace, root,
                 deterministic = true, bodyHash = hashVariantOne).isOk

    # Source is untouched ⇒ the shallow path alone would SKIP.
    check decide(testId, threeFuncsTrace, root, cache).kind == idSkipUnchanged

    # But the current catalog reports a CHANGED deep hash (build B).
    let catRes = parseBodyHashCatalog(catalogJson({testId: hashVariantTwo}))
    check catRes.isOk
    let catalog = catRes.value
    check catalog.hasBodyHash(testId)

    # Deep wins ⇒ rerun (the opposite of the shallow verdict) ⇒ proof of choice.
    let d = decideTiered(testId, catalog, threeFuncsTrace, root, cache)
    check d.kind == idRerunChanged

    # The inverse safety direction: when the catalog reports the SAME (build A)
    # hash, the deep path skips — and a static over-estimate (deep covering more
    # than the dynamic set) could only ever ADD re-runs, never remove the skip's
    # guard. The skip here requires byte-equal recorded/current deep hashes.
    let sameCatRes = parseBodyHashCatalog(catalogJson({testId: hashVariantOne}))
    check sameCatRes.isOk
    check decideTiered(testId, sameCatRes.value, threeFuncsTrace, root, cache).kind ==
      idSkipUnchanged
