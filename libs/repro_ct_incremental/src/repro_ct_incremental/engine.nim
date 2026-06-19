## Deep-hash invalidation engine — the M1 deliverable of the
## Trace-Based-Incremental-Testing prototype campaign.
##
## Given a test's executed functions (discovered from a CodeTracer trace by
## `trace_reader`) and the *current* source tree, this module decides whether
## the test can be skipped ("skipped (unchanged)") or must be re-run. The
## algorithm follows `codetracer-specs/Planned-Features/`
## `Nim-Parallel-Test-Framework.md`:
##
## * §16.7.1 — *shallow hash*: a per-function hash of the function's body text.
## * §16.7.3 — *deep hash*: hash of the sorted-by-name concatenation of the
##   shallow hashes of the test's executed functions.
## * §16.7.4 — *workflow*: between runs we compare the *cached* dependency set
##   against the *current* source. We only re-trace and `record` when the test
##   is actually re-run.
##
## # Source extraction (language-agnostic; M3)
##
## Per-function source extraction is delegated to a `FunctionBodyExtractor`
## selected purely by file extension (see `extractors.nim`). The engine itself
## contains NO per-language logic: it asks `extractors.extractFunctionBody` for
## the body given the source file path, the source lines, and the 1-based
## `defLine`. Ruby (`.rb`) and Python (`.py`) use an indentation heuristic;
## JavaScript (`.js`) uses brace matching. An unknown extension yields an
## `Err`, which the engine maps to the reserved `"missing"` shallow hash so the
## test fail-safes to a re-run (never a silent wrong hash). The exact boundary
## rule matters only for stability, not correctness of the skip/re-run
## decision: as long as the same physical lines are captured for an unchanged
## function and different lines/text for a changed one, the engine is correct.
##
## # Normalization (documented)
##
## Before hashing, `shallowHash` normalizes the body text by:
##   * splitting into lines on `\n` (a trailing `\r` per line is stripped, so
##     CRLF and LF sources hash identically),
##   * stripping *trailing* whitespace from each line (trailing spaces/tabs are
##     not significant), and
##   * re-joining with `\n` and stripping a trailing newline.
##
## Leading whitespace (indentation) IS significant — it is part of the body in
## indentation-structured languages. Comments and blank lines inside the body
## ARE significant (this is the conservative choice: a comment edit triggers a
## re-run rather than risking a false skip). A whitespace/comment-insensitive
## AST mode is deferred to the tree-sitter milestone (M3+).
##
## # Missing functions
##
## If a function named in the cached dependency set no longer exists at its
## recorded `defLine` (the file is shorter than `defLine`, or the extractor
## cannot read a body there), or its source file's extension has no registered
## extractor, the body extraction returns an `Err`. The engine maps that to the
## reserved `"missing"` shallow hash. The deep hash therefore changes versus the
## recorded one, so `decide` returns `idRerunChanged` with the missing function
## listed — a removed/unreadable dependency is treated as changed and is never
## silently skipped (see `removed_executed_function_reruns`).

import std/[json, os, algorithm, hashes, strutils, tables]
import results

import trace_reader
import extractors

export trace_reader
export extractors

type
  IncrementalDecisionKind* = enum
    idRunFresh        ## No cache entry for this test — run it and record.
    idSkipUnchanged   ## Deep hash unchanged — the test may be skipped.
    idRerunChanged    ## At least one executed function changed/was removed.

  IncrementalDecision* = object
    ## The skip/re-run verdict for a single test.
    case kind*: IncrementalDecisionKind
    of idRunFresh, idSkipUnchanged:
      discard
    of idRerunChanged:
      changedFuncs*: seq[string]
        ## Names of executed functions whose shallow hash changed (or which are
        ## now missing from the source) since the cache was recorded.

  CachedDep* = object
    ## A single recorded dependency: the executed function plus the shallow
    ## hash it had at record time. Persisting the per-dep shallow hash lets
    ## `decide` pinpoint exactly which functions changed (not just that *some*
    ## did), giving function-level precision in the changed-set report.
    fn*: ExecutedFunction
    shallow*: string

  CachedTest* = object
    ## A cache entry for one test: its recorded deep hash and the executed
    ## functions (dependency set) it was computed from, each with its recorded
    ## shallow hash.
    deepHash*: string
    deps*: seq[CachedDep]

  IncrementalCache* = object
    ## In-memory map of `testId -> CachedTest`, with JSON persistence.
    path*: string                       ## Backing JSON file path.
    entries*: Table[string, CachedTest] ## testId -> cache entry.

const
  DefaultCacheDir* = ".repro-ct-incremental"
  DefaultCacheFile* = "cache.json"

# ---------------------------------------------------------------------------
# Decision constructors
# ---------------------------------------------------------------------------

func runFresh*(): IncrementalDecision =
  IncrementalDecision(kind: idRunFresh)

func skipUnchanged*(): IncrementalDecision =
  IncrementalDecision(kind: idSkipUnchanged)

func rerunChanged*(changedFuncs: seq[string]): IncrementalDecision =
  IncrementalDecision(kind: idRerunChanged, changedFuncs: changedFuncs)

# ---------------------------------------------------------------------------
# Source extraction + shallow hash (§16.7.1)
# ---------------------------------------------------------------------------

func hexOfHash(h: Hash): string =
  ## Render a `std/hashes.Hash` as a fixed-width lowercase hex string. We cast
  ## through `uint` to take the raw bit pattern (the sign bit must not trigger a
  ## range error), then `toHex` on the unsigned value.
  toHex(cast[uint](h)).toLowerAscii()

func normalizeBody(funcSource: string): string =
  ## Apply the documented normalization: strip trailing whitespace per line
  ## (including a stray `\r` from CRLF sources), keep leading indentation,
  ## re-join with `\n`, and drop a trailing newline.
  var outLines: seq[string]
  for rawLine in funcSource.split('\n'):
    outLines.add rawLine.strip(leading = false, trailing = true)
  outLines.join("\n").strip(leading = false, trailing = true)

proc shallowHash*(funcSource: string): string =
  ## Stable per-function hash (§16.7.1) of a function's body text, after the
  ## documented normalization. The empty body (missing function) hashes to a
  ## distinct, reserved value so a removed function is representable and never
  ## collides with a real body.
  ##
  ## The returned value is a lowercase hex string of `std/hashes.hash`. It is
  ## deterministic for a given Nim build/process and — because `hash(string)`
  ## in `std/hashes` is a fixed Farm-hash-derived algorithm seeded only by the
  ## input bytes — stable across processes of the same binary. (Cryptographic
  ## strength is not required, per §16.7 / the spec's hash-algorithm note: this
  ## is change detection on trusted local data.)
  let normalized = normalizeBody(funcSource)
  if normalized.len == 0:
    # Reserved sentinel for a missing/empty function body. Distinct from any
    # hash of real content so the deep hash necessarily changes.
    return "missing"
  hexOfHash(hash(normalized))

# ---------------------------------------------------------------------------
# Per-dependency shallow hashing against current source
# ---------------------------------------------------------------------------

proc resolveSourcePath(sourceRoot, file: string): string =
  ## Resolve a trace-recorded `file` against `sourceRoot`. Trace paths are
  ## typically absolute-looking (e.g. `/fixtures/.../x.rb`); we join them under
  ## `sourceRoot` after stripping a leading path separator so a fixture trace
  ## recorded with an absolute-looking path resolves under the test's temp dir.
  var rel = file
  while rel.len > 0 and (rel[0] == '/' or rel[0] == '\\'):
    rel = rel[1 .. ^1]
  sourceRoot / rel

proc readSourceLines(path: string): Result[seq[string], string] =
  ## Read a source file and split into lines on `\n`. A missing/unreadable file
  ## is an Err (the caller turns that into a changed/missing dependency).
  if not fileExists(path):
    return err("source file not found: " & path)
  var raw: string
  try:
    raw = readFile(path)
  except CatchableError as e:
    return err("failed to read " & path & ": " & e.msg)
  ok(raw.split('\n'))

proc shallowHashOfDep(dep: ExecutedFunction; sourceRoot: string): string =
  ## Compute the current shallow hash of a single executed function against the
  ## source under `sourceRoot`. A missing file, a missing function, OR an
  ## unsupported source extension yields the reserved `"missing"` shallow hash
  ## (via `shallowHash` of an empty body), so a removed/unreadable dependency is
  ## treated as changed — never silently skipped, never hashed with the wrong
  ## extractor. The extractor is chosen purely by `dep.file`'s extension.
  let path = resolveSourcePath(sourceRoot, dep.file)
  let linesRes = readSourceLines(path)
  if linesRes.isErr:
    return shallowHash("")  # missing file => missing function => "missing"
  # `dep.file` (the trace-recorded path) carries the extension that selects the
  # extractor; `path` is only where the bytes live under the temp sourceRoot.
  let bodyRes = extractFunctionBody(dep.file, linesRes.value, dep.defLine)
  if bodyRes.isErr:
    return shallowHash("")  # unknown ext / out-of-range / unmatched => "missing"
  shallowHash(bodyRes.value)

# ---------------------------------------------------------------------------
# Deep hash (§16.7.3)
# ---------------------------------------------------------------------------

proc deepHash*(funcs: seq[(string, string)]): string =
  ## Combine per-function `(name, shallowHash)` pairs into a test's deep hash
  ## (§16.7.3): sort by name for determinism, then hash the concatenation of
  ## the shallow hashes. Order-independent and stable: two inputs with the same
  ## set of pairs in any order produce the same deep hash.
  var sorted = funcs
  sorted.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  var buf = ""
  for (name, sh) in sorted:
    # Include the name in the digest input so that two different functions that
    # happen to share a shallow hash (e.g. identical one-line bodies) still
    # produce distinct deep-hash material when their identities differ.
    buf.add name
    buf.add '\x00'
    buf.add sh
    buf.add '\x1f'
  hexOfHash(hash(buf))

proc currentDeps(deps: seq[ExecutedFunction]; sourceRoot: string): seq[CachedDep] =
  ## Compute the current per-dependency shallow hashes against `sourceRoot`.
  for dep in deps:
    result.add CachedDep(fn: dep, shallow: shallowHashOfDep(dep, sourceRoot))

func deepHashOfCachedDeps(deps: seq[CachedDep]): string =
  ## Deep hash of a recorded dependency set (uses the stored shallow hashes).
  var pairs: seq[(string, string)]
  for dep in deps:
    pairs.add (dep.fn.name, dep.shallow)
  deepHash(pairs)

# ---------------------------------------------------------------------------
# Cache type + JSON persistence
# ---------------------------------------------------------------------------

func defaultCachePath*(root = "."): string =
  ## The default cache path: `<root>/.repro-ct-incremental/cache.json`.
  root / DefaultCacheDir / DefaultCacheFile

func initCache*(path = defaultCachePath()): IncrementalCache =
  ## A fresh, empty cache bound to `path`.
  IncrementalCache(path: path, entries: initTable[string, CachedTest]())

proc loadCache*(path = defaultCachePath()): Result[IncrementalCache, string] =
  ## Load a cache from JSON at `path`. A missing file yields an empty cache
  ## (first run). Malformed JSON is an Err — never a crash.
  var cache = initCache(path)
  if not fileExists(path):
    return ok(cache)
  var raw: string
  try:
    raw = readFile(path)
  except CatchableError as e:
    return err("failed to read cache " & path & ": " & e.msg)
  var root: JsonNode
  try:
    root = parseJson(raw)
  except CatchableError as e:
    return err("malformed cache JSON in " & path & ": " & e.msg)
  if root.kind != JObject or not root.hasKey("tests"):
    return err("cache JSON missing 'tests' object")
  let tests = root["tests"]
  if tests.kind != JObject:
    return err("cache 'tests' must be a JSON object")
  for testId, entry in tests.fields:
    if entry.kind != JObject or not entry.hasKey("deepHash") or
        not entry.hasKey("deps"):
      return err("cache entry '" & testId & "' is malformed")
    var ct = CachedTest(deepHash: entry["deepHash"].getStr())
    if entry["deps"].kind != JArray:
      return err("cache entry '" & testId & "' deps must be an array")
    for dep in entry["deps"].elems:
      if dep.kind != JObject or not dep.hasKey("name") or
          not dep.hasKey("file") or not dep.hasKey("defLine") or
          not dep.hasKey("shallow"):
        return err("cache entry '" & testId & "' has a malformed dep")
      ct.deps.add CachedDep(
        fn: ExecutedFunction(
          name: dep["name"].getStr(),
          file: dep["file"].getStr(),
          defLine: int(dep["defLine"].getBiggestInt())),
        shallow: dep["shallow"].getStr())
    cache.entries[testId] = ct
  ok(cache)

proc toJson(cache: IncrementalCache): JsonNode =
  ## Serialize the cache deterministically (test ids sorted) for stable files.
  var tests = newJObject()
  var ids: seq[string]
  for id in cache.entries.keys: ids.add id
  ids.sort()
  for id in ids:
    let ct = cache.entries[id]
    var deps = newJArray()
    for dep in ct.deps:
      var d = newJObject()
      d["name"] = newJString(dep.fn.name)
      d["file"] = newJString(dep.fn.file)
      d["defLine"] = newJInt(dep.fn.defLine)
      d["shallow"] = newJString(dep.shallow)
      deps.add d
    var entry = newJObject()
    entry["deepHash"] = newJString(ct.deepHash)
    entry["deps"] = deps
    tests[id] = entry
  result = newJObject()
  result["version"] = newJInt(1)
  result["tests"] = tests

proc saveCache*(cache: IncrementalCache): Result[void, string] =
  ## Persist the cache to its `path`, creating parent directories.
  try:
    let dir = cache.path.parentDir
    if dir.len > 0:
      createDir(dir)
    writeFile(cache.path, cache.toJson().pretty())
  except CatchableError as e:
    return err("failed to write cache " & cache.path & ": " & e.msg)
  ok()

# ---------------------------------------------------------------------------
# Cache pruning (M4)
# ---------------------------------------------------------------------------

proc pruneCache*(cache: var IncrementalCache;
                 liveTestIds: openArray[string]): seq[string] =
  ## Remove cache entries for tests that are no longer part of the live test
  ## set, then PERSIST the pruned cache to disk. Returns the sorted list of
  ## test ids that were removed (empty if nothing was pruned).
  ##
  ## # Semantics
  ##
  ## `liveTestIds` is the authoritative set of tests that currently exist (e.g.
  ## the tests discovered in this run). Any cache entry whose test id is NOT in
  ## that set is deleted: the test was renamed, removed, or is otherwise gone,
  ## so keeping its `{deepHash, deps}` would only waste space and could mislead
  ## a future run that re-introduces the same id with different behaviour.
  ##
  ## This handles the *removed-test* case specifically. The complementary
  ## *removed-function within a still-present test* case needs no pruning: M1
  ## already treats a dependency that no longer exists in source as the
  ## reserved `"missing"` shallow hash, so such a test re-runs (never a silent
  ## skip) and is re-recorded with the current dependency set on that run.
  ##
  ## Pruning is idempotent: a test absent from BOTH the cache and `liveTestIds`
  ## is simply ignored, and an entry already pruned stays pruned. After this
  ## returns, a subsequent `decide` for a pruned test id yields `idRunFresh`
  ## (no entry ⇒ run-and-record), exactly as for a never-seen test.
  ##
  ## The on-disk cache is rewritten via `saveCache`. A persistence failure does
  ## NOT raise: the in-memory cache is still pruned, and the failure surfaces on
  ## the next explicit `saveCache` the caller performs. (Callers that need the
  ## persisted state guaranteed should call `saveCache` and check its Result.)
  var live = initTable[string, bool]()
  for id in liveTestIds:
    live[id] = true
  var removed: seq[string]
  for id in cache.entries.keys:
    if not live.hasKey(id):
      removed.add id
  for id in removed:
    cache.entries.del id
  removed.sort()
  # Persist the pruned cache. Best-effort: see the doc comment above.
  discard saveCache(cache)
  removed

# ---------------------------------------------------------------------------
# record / decide (§16.7.4)
# ---------------------------------------------------------------------------

proc record*(cache: var IncrementalCache; testId, traceDir, sourceRoot: string):
    Result[void, string] =
  ## Record a fresh run: read the trace's executed functions, compute each
  ## one's shallow hash from the CURRENT source under `sourceRoot`, combine into
  ## the deep hash, and store `{deepHash, deps}` for `testId`. Called after a
  ## test is actually executed and re-traced (§16.7.4 step 4).
  let execRes = readExecutedFunctions(traceDir)
  if execRes.isErr:
    return err(execRes.error)
  let deps = currentDeps(execRes.value, sourceRoot)
  cache.entries[testId] = CachedTest(
    deepHash: deepHashOfCachedDeps(deps),
    deps: deps)
  ok()

proc decide*(testId, traceDir, sourceRoot: string;
             cache: IncrementalCache): IncrementalDecision =
  ## Decide skip vs re-run for `testId` (§16.7.4 step 3).
  ##
  ## * If `testId` is absent from the cache ⇒ `idRunFresh`.
  ## * Otherwise recompute each CACHED dependency's shallow hash from the
  ##   CURRENT source (NOT a fresh trace) and compare it to the per-dep shallow
  ##   hash recorded at `record` time. If every dep is unchanged ⇒
  ##   `idSkipUnchanged` (equivalently, the deep hash is unchanged). Otherwise ⇒
  ##   `idRerunChanged` listing exactly the executed functions whose shallow
  ##   hash changed or which are now missing (function-level precision).
  ##
  ## `traceDir` is accepted for API symmetry with `record` and for callers that
  ## want to pass the test's trace location uniformly; the decision itself uses
  ## only the cached deps + current source, exactly as §16.7.4 specifies.
  discard traceDir  # accepted for API symmetry; the decision uses cached deps.
  if not cache.entries.hasKey(testId):
    return runFresh()
  let cached = cache.entries[testId]
  # Recompute each dependency's CURRENT shallow hash against the current source
  # and compare to the per-dep shallow hash recorded at `record` time. A dep is
  # "changed" if its current shallow hash differs from the recorded one — this
  # includes the case where the function was removed (current hash == the
  # `"missing"` sentinel), which is therefore reported as changed and never
  # silently skipped.
  var changed: seq[string]
  for dep in cached.deps:
    let current = shallowHashOfDep(dep.fn, sourceRoot)
    if current != dep.shallow:
      changed.add dep.fn.name
  if changed.len == 0:
    # No executed function's body changed since record() — the deep hash is
    # unchanged, so the test may be skipped.
    return skipUnchanged()
  changed.sort()
  rerunChanged(changed)
