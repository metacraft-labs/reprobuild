## Edge determinism classes, HTTP-style cache retention, and the rebuild
## selectors that consume them (`Edge-Determinism-And-Soft-Rebuild.md`).
##
## This module is the CONSUMER-SIDE half of a property that already existed
## but did nothing. `repro_home_resources`' `ResourceDeterminism` populates a
## class on every registered resource type, and both that module and
## `builtin_registrations.nim` said in a comment that "soft-rebuild
## consumption is a later slice". This is that slice: the same four classes,
## lifted into the BUILD-GRAPH lane so a cache read, a cache write, a
## cross-machine substitution and a `repro build` rebuild flag can all act on
## them.
##
## ## Why a second enum rather than importing the first
##
## `repro_home_resources` sits above `repro_core` in the dependency order (it
## pulls in blake3 and the home-scope resource model), and the build engine
## must not grow that closure to learn what four constants mean. The same
## reason produced `repro_interface_artifacts`'
## `InterfaceResourceDeterminism`. `EdgeDeterminism` is the THIRD member of
## that family and carries the same invariant the other two do:
##
##   RP4 INVARIANT (restated here so it is visible from this side too):
##   `edStrong = 0 .. edVolatile = 3` is ordinal-aligned with
##   `ResourceDeterminism` (`rdStrong .. rdVolatile`) and with
##   `InterfaceResourceDeterminism` (`irdStrong .. irdVolatile`). The three
##   are mapped across by `int(ord(...))`. Reordering or inserting a case in
##   any one of them without updating the others silently corrupts a lifted
##   class. Do not reorder.
##
## The ordinal order is ALSO the strictness order of §1.4
## (`strong < weak < host-bound < volatile`), which is why composition of a
## consumer with its producers is exactly `max` over the ordinals. That is not
## a coincidence to be preserved by luck: `strictest` below is the only place
## that relies on it, and it is asserted by test.
##
## ## The default is `weak`, and it is NOT the zero value
##
## §2.1: "When the directive is absent, the tool defaults to `weak` with a
## build-time warning." The zero value of this enum is `edStrong`, which is
## the OPPOSITE of a conservative default — `strong` is the one class the
## trust model lets cross a machine boundary unverified. So an action's
## declared class is an `Option[EdgeDeterminism]`, `none` means "unlabelled",
## and `effectiveDeterminism` resolves `none` to `edWeak`. A silently
## defaulted `edStrong` would be a latent over-promise the moment binary-cache
## publication starts reading this field.

import std/[options, strutils]

type
  EdgeDeterminism* = enum
    ## The four classes of `Edge-Determinism-And-Soft-Rebuild.md` §1.
    ## Ordinal-aligned with `ResourceDeterminism` / `InterfaceResourceDeterminism`
    ## AND ordered by §1.4 strictness. See the module docstring before touching.
    edStrong        ## bytewise reproducible everywhere; freely substitutable
    edWeak          ## reproducible up to a documented normalizer; the default
    edHostBound     ## stable per host, unbounded across hosts; NO cross-machine
                    ## substitution
    edVolatile      ## unstable even on one host; needs a `cacheRetention`
                    ## clause and NO cross-machine substitution

  CacheRetentionKind* = enum
    ## The `cacheRetention` vocabulary of §2.2, which follows HTTP
    ## `Cache-Control`. `crkForever` is not part of that vocabulary — it is
    ## the absence of a clause, which is what every non-`volatile` class has
    ## ("cache forever" / "cache forever, per host" in §1's table).
    crkForever
    crkMaxAge                ## `max-age = N` — valid for N seconds after write
    crkNoCache               ## cache but always revalidate before serving
    crkNoStore               ## never cache; every read is a miss
    crkThisBuild             ## valid for this `repro build` invocation only
    crkStaleWhileRevalidate  ## serve stale past expiry AND trigger a re-run

  CacheRetention* = object
    ## A parsed `cacheRetention` clause. `seconds` is meaningful only for
    ## `crkMaxAge` and `crkStaleWhileRevalidate`.
    kind*: CacheRetentionKind
    seconds*: int64

  RetentionVerdict* = enum
    ## What a retention clause says about one cached entry, right now.
    rvFresh                  ## serve the cached bytes
    rvExpired                ## treat as a miss and re-run
    rvRevalidate             ## `no-cache`: re-run, but the entry may be kept
    rvStaleServed            ## `stale-while-revalidate`: serve stale AND re-run
    rvUnknownWriteTime       ## the entry carries no write time; fail closed

  RebuildClass* = enum
    ## Which classes a `repro build` invocation invalidates on the
    ## path-to-target (§4.1 – §4.3). `rbNone` is the no-flag default (§4.4).
    rbNone
    rbSoft                   ## `--soft-rebuild`     — volatile only
    rbHostBound              ## `--rebuild-host-bound` — volatile + host-bound
    rbHard                   ## `--hard-rebuild`     — everything

const
  DefaultEdgeDeterminism* = edWeak
    ## §2.1's default for an unlabelled tool. Deliberately not the enum's
    ## zero value; see the module docstring.

# ---------------------------------------------------------------------------
# Classification helpers.
# ---------------------------------------------------------------------------

proc effectiveDeterminism*(declared: Option[EdgeDeterminism]): EdgeDeterminism =
  ## Resolve an edge's declared class. `none` — no `determinism` directive on
  ## the tool and no per-edge override — is §2.1's unlabelled case and
  ## resolves to `edWeak`.
  if declared.isSome: declared.get else: DefaultEdgeDeterminism

proc strictest*(a, b: EdgeDeterminism): EdgeDeterminism =
  ## §1.4 composition: a composite edge inherits the STRICTEST class on the
  ## path. Because the enum's ordinal order IS the strictness order, this is
  ## `max`; `t_edge_determinism_vocabulary` pins that so a reorder cannot
  ## quietly turn composition into nonsense.
  if ord(a) >= ord(b): a else: b

proc allowsCrossMachineSubstitution*(cls: EdgeDeterminism): bool =
  ## §3's third column and §5. `host-bound` and `volatile` are FORBIDDEN
  ## across machines — the cached bytes are one host's realization and no
  ## auditor on another host can verify them. `weak` is "allowed
  ## conditionally" in §3; the condition (the substituter verified the
  ## equivalence relation) is a property of the substituter, not of the
  ## class, so the class-level gate admits it and the substituter's own
  ## check stays where it is.
  cls in {edStrong, edWeak}

proc requiresRetentionClause*(cls: EdgeDeterminism): bool =
  ## §2.2: "A `volatile` tool MUST declare a `cacheRetention` clause; it is
  ## an error otherwise." This is the predicate behind
  ## `L:determinism/volatile-without-retention`.
  cls == edVolatile

proc isWeakeningOverride*(toolDefault, edgeOverride: EdgeDeterminism): bool =
  ## §2.3 / `L:determinism/weakening-override`. An edge may only STRENGTHEN
  ## (move left in `strong < weak < host-bound < volatile`). Weakening would
  ## let a caller relabel a `strong` invocation `volatile` and make the
  ## `strong` cache contract unsound.
  ord(edgeOverride) > ord(toolDefault)

# ---------------------------------------------------------------------------
# Retention vocabulary — parsing and formatting.
# ---------------------------------------------------------------------------

proc forever*(): CacheRetention =
  CacheRetention(kind: crkForever, seconds: 0)

proc maxAge*(seconds: int64): CacheRetention =
  CacheRetention(kind: crkMaxAge, seconds: seconds)

proc staleWhileRevalidate*(seconds: int64): CacheRetention =
  CacheRetention(kind: crkStaleWhileRevalidate, seconds: seconds)

proc `$`*(r: CacheRetention): string =
  ## The canonical spelling of a clause, round-tripping with
  ## `parseCacheRetention`.
  case r.kind
  of crkForever: "forever"
  of crkMaxAge: "max-age = " & $r.seconds
  of crkNoCache: "no-cache"
  of crkNoStore: "no-store"
  of crkThisBuild: "this-build"
  of crkStaleWhileRevalidate: "stale-while-revalidate = " & $r.seconds

proc parseCacheRetention*(text: string; dest: var CacheRetention): bool =
  ## Parse one §2.2 clause. Accepts `max-age = N`, `max-age=N` and
  ## `max-age N`; the whole clause is case-insensitive because it is authored
  ## by hand in a DSL block. Returns false — rather than raising — so the
  ## linter can report the offending text with its own diagnostic.
  let raw = text.strip()
  if raw.len == 0:
    return false
  var name = raw
  var value = ""
  let eq = raw.find('=')
  if eq >= 0:
    name = raw[0 ..< eq].strip()
    value = raw[eq + 1 .. ^1].strip()
  else:
    # `max-age 3600` — split on the first run of whitespace.
    let parts = raw.splitWhitespace()
    if parts.len == 2:
      name = parts[0]
      value = parts[1]
  case name.toLowerAscii()
  of "forever":
    if value.len > 0: return false
    dest = forever()
  of "no-cache":
    if value.len > 0: return false
    dest = CacheRetention(kind: crkNoCache, seconds: 0)
  of "no-store":
    if value.len > 0: return false
    dest = CacheRetention(kind: crkNoStore, seconds: 0)
  of "this-build":
    if value.len > 0: return false
    dest = CacheRetention(kind: crkThisBuild, seconds: 0)
  of "max-age", "stale-while-revalidate":
    if value.len == 0: return false
    var n: int64
    try:
      n = int64(parseInt(value))
    except ValueError:
      return false
    if n < 0: return false
    dest =
      if name.toLowerAscii() == "max-age": maxAge(n)
      else: staleWhileRevalidate(n)
  else:
    return false
  true

proc isTighterThan*(a, b: CacheRetention): bool =
  ## §2.3: "Cache retention may be TIGHTENED on a `volatile` edge ... but not
  ## relaxed beyond what the tool author allows." Ordering is by how long the
  ## clause lets a cached realization be served: `no-store` (0) is tightest,
  ## `forever` is loosest.
  proc rank(r: CacheRetention): int64 =
    case r.kind
    of crkNoStore: 0
    of crkNoCache: 1
    of crkThisBuild: 2
    of crkMaxAge: 3 + r.seconds
    of crkStaleWhileRevalidate: 3 + r.seconds + 1
    of crkForever: high(int64)
  rank(a) < rank(b)

# ---------------------------------------------------------------------------
# The retention decision.
# ---------------------------------------------------------------------------

proc retentionVerdict*(retention: CacheRetention;
                       entryWriteTimeUnix: int64;
                       nowUnix: int64;
                       entryBuildEpoch = "";
                       currentBuildEpoch = ""): RetentionVerdict =
  ## Decide whether a cached entry written at `entryWriteTimeUnix` may still
  ## be served. §4.4: an expired `volatile` entry becoming a miss is "the only
  ## automatic invalidation the default mode does".
  ##
  ## `entryWriteTimeUnix <= 0` means the entry carries no recorded write time
  ## — a record written before determinism metadata existed, or one whose
  ## sidecar was lost. That is `rvUnknownWriteTime` and the caller must treat
  ## it as a MISS: re-running an action is recoverable, serving a realization
  ## whose age is unknown under a clause that exists precisely to bound its
  ## age is not.
  case retention.kind
  of crkForever:
    return rvFresh
  of crkNoStore, crkNoCache:
    # `no-store` never caches; `no-cache` always revalidates, and revalidation
    # here IS re-running the action (§2.2), so both re-run. They differ in what
    # the GC does with the entry afterwards, not in what the read does.
    return (if retention.kind == crkNoStore: rvExpired else: rvRevalidate)
  of crkThisBuild:
    if currentBuildEpoch.len == 0 or entryBuildEpoch.len == 0:
      return rvUnknownWriteTime
    return (if entryBuildEpoch == currentBuildEpoch: rvFresh else: rvExpired)
  of crkMaxAge, crkStaleWhileRevalidate:
    if entryWriteTimeUnix <= 0:
      return rvUnknownWriteTime
    let age = nowUnix - entryWriteTimeUnix
    if age < 0:
      # The entry claims to have been written in the future. A clock that
      # moved backwards must not extend a realization's life indefinitely.
      return rvExpired
    if age < retention.seconds:
      return rvFresh
    return (if retention.kind == crkMaxAge: rvExpired else: rvStaleServed)

proc servesCachedBytes*(v: RetentionVerdict): bool =
  ## Whether the verdict permits returning the cached bytes to the caller.
  v in {rvFresh, rvStaleServed}

proc isExpired*(retention: CacheRetention; entryWriteTimeUnix, nowUnix: int64;
                entryBuildEpoch = ""; currentBuildEpoch = ""): bool =
  ## The GC's question, which is narrower than the reader's: is this entry
  ## PAST its retention and therefore preferentially evictable? A
  ## `stale-while-revalidate` entry past its window is expired for the GC even
  ## though a reader would still serve it — the GC's job is to make room, and
  ## the next read re-runs the action anyway.
  case retention.kind
  of crkForever:
    false
  of crkNoStore:
    true
  of crkNoCache:
    # `no-cache` entries are re-run on every read but are legitimately KEPT
    # (that is the whole difference from `no-store`), so they are not expired
    # merely by existing.
    false
  of crkThisBuild:
    if currentBuildEpoch.len == 0 or entryBuildEpoch.len == 0: true
    else: entryBuildEpoch != currentBuildEpoch
  of crkMaxAge, crkStaleWhileRevalidate:
    if entryWriteTimeUnix <= 0: true
    else: (nowUnix - entryWriteTimeUnix) >= retention.seconds

# ---------------------------------------------------------------------------
# Rebuild selectors (§4).
# ---------------------------------------------------------------------------

proc invalidates*(rebuild: RebuildClass; cls: EdgeDeterminism): bool =
  ## Does this rebuild verb invalidate an edge of class `cls`?
  ##   * `--soft-rebuild`        → volatile only                    (§4.1)
  ##   * `--rebuild-host-bound`  → volatile AND host-bound          (§4.2)
  ##   * `--hard-rebuild`        → every class                      (§4.3)
  ##   * no flag                 → nothing; retention still applies (§4.4)
  case rebuild
  of rbNone: false
  of rbSoft: cls == edVolatile
  of rbHostBound: cls in {edVolatile, edHostBound}
  of rbHard: true

proc parseRebuildClass*(flag: string; dest: var RebuildClass): bool =
  case flag
  of "--soft-rebuild": dest = rbSoft; true
  of "--rebuild-host-bound": dest = rbHostBound; true
  of "--hard-rebuild": dest = rbHard; true
  else: false

proc flagSpelling*(rebuild: RebuildClass): string =
  case rebuild
  of rbNone: ""
  of rbSoft: "--soft-rebuild"
  of rbHostBound: "--rebuild-host-bound"
  of rbHard: "--hard-rebuild"

# ---------------------------------------------------------------------------
# `--only <pattern>` (§4.5).
# ---------------------------------------------------------------------------

proc matchesGlob(text, pattern: string; ti, pi: int): bool =
  ## Backtracking glob over `*` (any run, including empty) and `?` (one
  ## character). Written out rather than pulled from `std/strutils`'
  ## `nre`/`re` because the engine must not link a regex dependency for a
  ## selector, and `--only 'windows-runner-test-vm.*'` in §4.5 is quoted shell
  ## glob, not a regex.
  var t = ti
  var p = pi
  var starP = -1
  var starT = 0
  while t < text.len:
    if p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t]):
      inc t
      inc p
    elif p < pattern.len and pattern[p] == '*':
      starP = p
      starT = t
      inc p
    elif starP >= 0:
      inc starT
      t = starT
      p = starP + 1
    else:
      return false
  while p < pattern.len and pattern[p] == '*':
    inc p
  p == pattern.len

proc matchesOnlySelector*(patterns: openArray[string];
                          actionId: string;
                          targetNames: openArray[string] = []): bool =
  ## §4.5. An EMPTY pattern list means "no `--only` was given", which selects
  ## EVERYTHING — the rebuild verb then applies to the whole path-to-target,
  ## which is exactly §4.1's unqualified wording. A non-empty list selects an
  ## edge whose action id, or any of whose exported target names, matches any
  ## pattern.
  ##
  ## A pattern containing no glob metacharacter is treated as a SUBSTRING
  ## match, because an action id is a long content-derived string and
  ## `--only 'windows-runner-test-vm'` must not have to spell the rest of it.
  ## A pattern that does contain `*` or `?` is anchored, so an author who
  ## reaches for a glob gets the precision they asked for.
  if patterns.len == 0:
    return true
  for pattern in patterns:
    if pattern.len == 0:
      continue
    let anchored = '*' in pattern or '?' in pattern
    if anchored:
      if matchesGlob(actionId, pattern, 0, 0):
        return true
      for name in targetNames:
        if matchesGlob(name, pattern, 0, 0):
          return true
    else:
      if pattern in actionId:
        return true
      for name in targetNames:
        if pattern in name:
          return true
  false
