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
## # Source extraction heuristic (documented)
##
## The fixture language is Ruby; Ruby (like Python) is indentation/`def`/`end`
## structured. `extractFunctionBody` uses a simple, language-agnostic
## indentation heuristic adequate for the M1 fixture (tree-sitter is a later
## milestone, M3):
##
##   * The function starts at `defLine` (1-based, as the trace records it).
##   * Let `indent` be the leading-whitespace width of the `def` line.
##   * The body is the `def` line plus every following line, up to but NOT
##     including the next *non-blank* line whose indentation is `<= indent`
##     (a sibling/closing construct). Blank lines never terminate the body;
##     they are carried along so a blank line inside the body does not truncate
##     it. For a top-level Ruby `def` (indent 0) the terminating line is the
##     matching `end`, which sits at indent 0 — so the `end` line is the first
##     line at `<= indent` and is therefore EXCLUDED. The captured body is the
##     `def` line through the last body statement. This is sufficient for
##     change detection: any edit inside the body (or to the `def` signature)
##     changes the captured text, while edits to *sibling* functions do not.
##
## The exact boundary rule matters only for stability, not correctness of the
## skip/re-run decision: as long as the same physical lines are captured for an
## unchanged function and different lines/text for a changed one, the engine is
## correct. The chosen rule is deterministic and documented here.
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
## recorded `defLine` (the file is shorter than `defLine`, or that line is not
## a function definition we can extract), `shallowHash` of an *empty* extracted
## body is used and the body is flagged via the sentinel produced by
## `extractFunctionBody` returning an empty string. The deep hash therefore
## changes versus the recorded one, so `decide` returns `idRerunChanged` with
## the missing function listed — a removed dependency is treated as changed and
## is never silently skipped (see `removed_executed_function_reruns`).

import std/[json, os, algorithm, hashes, strutils, tables]
import results

import trace_reader

export trace_reader

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

func leadingIndent(line: string): int =
  ## Number of leading whitespace characters (spaces/tabs) on a line.
  for ch in line:
    if ch == ' ' or ch == '\t': inc result
    else: break

proc extractFunctionBody*(sourceLines: seq[string]; defLine: int): string =
  ## Extract the body text of the function defined at `defLine` (1-based) using
  ## the documented indentation heuristic. Returns the captured text (the `def`
  ## line through the last body line). Returns the empty string when no
  ## function can be extracted at `defLine` (line out of range) — the caller
  ## treats that as a removed/changed dependency.
  ##
  ## `sourceLines` is the source file split on `\n`.
  if defLine < 1 or defLine > sourceLines.len:
    return ""
  let startIdx = defLine - 1
  let indent = leadingIndent(sourceLines[startIdx])
  var captured = @[sourceLines[startIdx]]
  var i = startIdx + 1
  while i < sourceLines.len:
    let line = sourceLines[i]
    if line.strip().len == 0:
      # Blank lines never terminate the body; carry them along so an interior
      # blank line does not truncate the function.
      captured.add line
      inc i
      continue
    if leadingIndent(line) <= indent:
      # First non-blank line at sibling-or-shallower indentation ends the body.
      break
    captured.add line
    inc i
  # Drop trailing blank lines that were carried past the last real statement,
  # so trailing blank padding between functions does not affect the hash.
  while captured.len > 0 and captured[^1].strip().len == 0:
    captured.setLen(captured.len - 1)
  captured.join("\n")

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
  ## source under `sourceRoot`. A missing file or missing function yields the
  ## reserved `"missing"` shallow hash (via `shallowHash` of an empty body), so
  ## a removed dependency is treated as changed.
  let path = resolveSourcePath(sourceRoot, dep.file)
  let linesRes = readSourceLines(path)
  if linesRes.isErr:
    return shallowHash("")  # missing file => missing function => "missing"
  let body = extractFunctionBody(linesRes.value, dep.defLine)
  shallowHash(body)

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
