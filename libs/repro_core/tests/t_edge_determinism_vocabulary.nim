## The determinism / retention vocabulary of
## `Edge-Determinism-And-Soft-Rebuild.md` §1–§4.
##
## MOCK POLICY — nothing is mocked and nothing could be: this module is pure
## value logic with no collaborators. Every case calls the production procs
## directly.
##
## These are the cases that pin PROPERTIES the rest of the milestone silently
## relies on, and that a plausible refactor would break without failing
## anything else:
##
##   * the enum's ordinal order IS §1.4's strictness order, so composition is
##     `max`. `strictest` is written as an ordinal comparison; a reorder of
##     the enum would leave it compiling and silently wrong.
##   * the ordinals are the ones `ResourceDeterminism` and
##     `InterfaceResourceDeterminism` are mapped across by `int(ord(...))`.
##   * `weak`, not `strong`, is what an unlabelled edge resolves to.

import std/[options, unittest]

import repro_core

suite "edge determinism vocabulary":

  test "the enum ordinals are the ordinal-aligned mirror's":
    ## The RP4 invariant, from this side — and ONLY from this side. This
    ## module is `repro_core`, which cannot see `repro_home_resources`'
    ## `ResourceDeterminism` or `repro_interface_artifacts`'
    ## `InterfaceResourceDeterminism` (that separation is the whole reason
    ## three mirrors exist), so all this case can pin is that THESE ordinals
    ## are 0..3. A reorder of either mirror would leave it green.
    ##
    ## The cross-enum check that actually falsifies a divergence is
    ## `t_rp4_resource_type_macro`'s "the three determinism enums are
    ## ordinal-aligned", in `repro_resources` — the one place in the tree
    ## that can import all three at once. Do not read this case as covering
    ## that; it covers one of the three sides.
    check ord(edStrong) == 0
    check ord(edWeak) == 1
    check ord(edHostBound) == 2
    check ord(edVolatile) == 3

  test "composition takes the strictest class on the path (§1.4)":
    check strictest(edStrong, edHostBound) == edHostBound
    check strictest(edStrong, edVolatile) == edVolatile
    check strictest(edVolatile, edStrong) == edVolatile
    check strictest(edWeak, edWeak) == edWeak
    check strictest(edHostBound, edWeak) == edHostBound
    # ...and it agrees with the enum order for EVERY pair, which is the
    # property `strictest`'s ordinal implementation actually depends on.
    for a in EdgeDeterminism:
      for b in EdgeDeterminism:
        check ord(strictest(a, b)) == max(ord(a), ord(b))

  test "an unlabelled edge is weak, not strong (§2.1)":
    ## The zero value of the enum is `edStrong`, so this is exactly the
    ## mistake a plain-enum field would have made.
    check effectiveDeterminism(none(EdgeDeterminism)) == edWeak
    check DefaultEdgeDeterminism == edWeak
    check effectiveDeterminism(some(edStrong)) == edStrong
    check effectiveDeterminism(some(edVolatile)) == edVolatile

  test "cross-machine substitution is refused for host-bound and volatile":
    ## §3's third column and §5.
    check allowsCrossMachineSubstitution(edStrong)
    check allowsCrossMachineSubstitution(edWeak)
    check not allowsCrossMachineSubstitution(edHostBound)
    check not allowsCrossMachineSubstitution(edVolatile)

  test "only volatile requires a retention clause (§2.2)":
    check requiresRetentionClause(edVolatile)
    for cls in [edStrong, edWeak, edHostBound]:
      check not requiresRetentionClause(cls)

  test "an override may strengthen but not weaken (§2.3)":
    check isWeakeningOverride(edStrong, edVolatile)
    check isWeakeningOverride(edWeak, edHostBound)
    check not isWeakeningOverride(edWeak, edStrong)
    check not isWeakeningOverride(edVolatile, edStrong)
    check not isWeakeningOverride(edWeak, edWeak)

  test "the retention vocabulary parses and round-trips":
    var r: CacheRetention
    check parseCacheRetention("max-age = 3600", r)
    check r.kind == crkMaxAge
    check r.seconds == 3600
    check $r == "max-age = 3600"
    check parseCacheRetention($r, r)          # round trip
    check r.seconds == 3600

    check parseCacheRetention("max-age=60", r)
    check r.seconds == 60
    check parseCacheRetention("max-age 60", r)
    check r.seconds == 60

    for spelling, kind in {"no-cache": crkNoCache, "no-store": crkNoStore,
                           "this-build": crkThisBuild,
                           "forever": crkForever}.items:
      check parseCacheRetention(spelling, r)
      check r.kind == kind
      check $r == spelling

    check parseCacheRetention("stale-while-revalidate = 30", r)
    check r.kind == crkStaleWhileRevalidate
    check r.seconds == 30
    check $r == "stale-while-revalidate = 30"

    # The negative controls. A parser that accepted these would let a typo
    # become a silent `forever`.
    check not parseCacheRetention("", r)
    check not parseCacheRetention("max-age", r)
    check not parseCacheRetention("max-age = -1", r)
    check not parseCacheRetention("max-age = soon", r)
    check not parseCacheRetention("no-cache = 5", r)
    check not parseCacheRetention("private", r)

  test "retention may be tightened, not relaxed (§2.3)":
    check isTighterThan(maxAge(60), maxAge(3600))
    check isTighterThan(maxAge(3600), forever())
    check isTighterThan(CacheRetention(kind: crkNoStore), maxAge(1))
    check not isTighterThan(maxAge(7200), maxAge(3600))
    check not isTighterThan(forever(), maxAge(3600))

  test "the retention verdict is fail-closed on an unknown write time":
    ## An entry with no recorded write time must be a MISS, never a hit:
    ## re-running is recoverable, serving a realization of unknown age under
    ## a clause that exists to bound its age is not.
    check retentionVerdict(maxAge(60), 0, 1000) == rvUnknownWriteTime
    check not servesCachedBytes(rvUnknownWriteTime)

    # ...and `forever` never consults it at all.
    check retentionVerdict(forever(), 0, 1000) == rvFresh

  test "max-age is a hit before N and a miss after":
    check retentionVerdict(maxAge(60), 1000, 1059) == rvFresh
    check retentionVerdict(maxAge(60), 1000, 1060) == rvExpired
    check retentionVerdict(maxAge(60), 1000, 5000) == rvExpired
    # A clock that moved backwards must not extend the window.
    check retentionVerdict(maxAge(60), 1000, 900) == rvExpired

  test "stale-while-revalidate serves the stale value past expiry":
    check retentionVerdict(staleWhileRevalidate(60), 1000, 1030) == rvFresh
    let past = retentionVerdict(staleWhileRevalidate(60), 1000, 1100)
    check past == rvStaleServed
    check servesCachedBytes(past)
    # ...but the GC treats it as evictable, which is the asymmetry §2.2
    # implies and the reason `isExpired` is a separate predicate.
    check isExpired(staleWhileRevalidate(60), 1000, 1100)

  test "no-store, no-cache and this-build":
    check retentionVerdict(CacheRetention(kind: crkNoStore), 1000, 1000) ==
      rvExpired
    check retentionVerdict(CacheRetention(kind: crkNoCache), 1000, 1000) ==
      rvRevalidate
    # `no-cache` re-runs on every read but is KEPT; `no-store` is garbage the
    # moment it exists. Collapsing the two is the mistake this pins.
    check not isExpired(CacheRetention(kind: crkNoCache), 1000, 1000)
    check isExpired(CacheRetention(kind: crkNoStore), 1000, 1000)

    let tb = CacheRetention(kind: crkThisBuild)
    check retentionVerdict(tb, 1000, 1000, entryBuildEpoch = "a",
      currentBuildEpoch = "a") == rvFresh
    check retentionVerdict(tb, 1000, 1000, entryBuildEpoch = "a",
      currentBuildEpoch = "b") == rvExpired
    check retentionVerdict(tb, 1000, 1000) == rvUnknownWriteTime

  test "rebuild verbs invalidate exactly the classes §4.1-§4.3 name":
    for cls in EdgeDeterminism:
      check not rbNone.invalidates(cls)
      check rbHard.invalidates(cls)
    check rbSoft.invalidates(edVolatile)
    for cls in [edStrong, edWeak, edHostBound]:
      check not rbSoft.invalidates(cls)
    check rbHostBound.invalidates(edVolatile)
    check rbHostBound.invalidates(edHostBound)
    check not rbHostBound.invalidates(edStrong)
    check not rbHostBound.invalidates(edWeak)

  test "rebuild verb spellings parse and round-trip":
    var cls: RebuildClass
    check parseRebuildClass("--soft-rebuild", cls)
    check cls == rbSoft
    check parseRebuildClass("--rebuild-host-bound", cls)
    check cls == rbHostBound
    check parseRebuildClass("--hard-rebuild", cls)
    check cls == rbHard
    check not parseRebuildClass("--force-rebuild", cls)
    check not parseRebuildClass("--rebuild", cls)
    for verb in [rbSoft, rbHostBound, rbHard]:
      var back: RebuildClass
      check parseRebuildClass(verb.flagSpelling, back)
      check back == verb
    check rbNone.flagSpelling == ""

  test "the --only selector (§4.5)":
    ## An EMPTY pattern list selects everything, so an unqualified rebuild
    ## verb applies to the whole path-to-target.
    check matchesOnlySelector([], "any/edge")
    check matchesOnlySelector(["windows-runner"], "l3/windows-runner-test-vm")
    check not matchesOnlySelector(["macos"], "l3/windows-runner-test-vm")
    # A pattern with a metacharacter is an anchored glob, not a substring.
    check matchesOnlySelector(["l3/windows*"], "l3/windows-runner-test-vm")
    check not matchesOnlySelector(["windows*"], "l3/windows-runner-test-vm")
    check matchesOnlySelector(["*windows*"], "l3/windows-runner-test-vm")
    check matchesOnlySelector(["l3/windows-runner-test-v?"],
      "l3/windows-runner-test-vm")
    check not matchesOnlySelector(["l3/windows-runner-test-v?"],
      "l3/windows-runner-test-vmm")
    # Target names are a second matching surface.
    check matchesOnlySelector(["release"], "opaque-action-id",
      ["release", "debug"])
    check not matchesOnlySelector(["release"], "opaque-action-id",
      ["debug"])
    # An all-empty pattern list is NOT the same as no patterns: it selects
    # nothing, so a mistyped `--only=` cannot silently widen to everything.
    check not matchesOnlySelector([""], "any/edge")
