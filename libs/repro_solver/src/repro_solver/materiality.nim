## ``repro_solver/materiality`` — Named-Lock-Files NLF-M6, design §5.7.
##
## **What invalidates a lock file**, derived from what the solve consulted
## rather than declared up front.
##
## ## The recorded fact
##
## §5.7, and `Locking-And-Solver.md` §"Solver Cache" as amended 2026-08-21:
##
## > the fact recorded is **"the selection, plus the interval in which no
## > better candidate was found"** — a witness and a negative bound, exactly as
## > the derived formulation wanted, but expressed as a *filtered enumeration
## > over an interval* rather than as a new kind of observation.
##
## A package's published version list is an enumeration. What the solve depends
## on is not the whole list, and not an opaque conclusion, but the list
## **filtered to an interval**. The interval is determined by the preference:
##
## | Preference | Selected | Interval |
## |---|---|---|
## | `lowest`  | 1.4 of `>=1.2 <2.0` | `[1.2, 1.4]` — at or below the selection, within the range |
## | `highest` | 1.9 of `>=1.2 <2.0` | `[1.9, 2.0)` — at or above the selection, within the range |
##
## The gap case is what shows the interval is doing work rather than restating
## the answer: `>=1.2` where 1.2 was never published and 1.4 is the lowest
## available records `[1.2, 1.4]`, so publishing 1.3 invalidates — as it must,
## because the answer moves to 1.3. An implementation that recorded only "the
## selection is 1.4, and it is still published" would keep answering 1.4
## forever, which is the silent-wrong-answer direction this campaign designs
## against.
##
## ## Three things deliberately record NOTHING
##
##   * **An UNSELECTED package.** NLF-M9 made the solve record, per package
##     instance, whether anything selected it (`UnifiedSolution.selected`,
##     derived in the ASP from the same `variant_assigned` atom that gates the
##     range constraint). An unselected package's metadata was, by
##     construction, not consulted: no live edge reached it, so no candidate of
##     it was ever weighed. Recording an interval for it would key the lock on
##     a fact the answer does not depend on — which is precisely
##     over-invalidation, and precisely what §5.7 exists to remove. This is the
##     one place M6 could not have been written before M9.
##   * **A PINNED package.** NLF-M2/§10.1: a develop-mode package's version is
##     OBSERVED off a checkout, not selected. There is no candidate set, so
##     there is no "no better candidate" claim to make. Its identity is carried
##     by the lock's own source coordinates.
##   * **A package the solution never mentions.** Absent is a third state,
##     distinct from unselected (`t_selection_is_not_the_same_as_absence`).
##
## ## Raw is the mandated fallback, and it is reached, not decorative
##
## §5.7: "**Raw remains the correct fallback** and should be specified as the
## behaviour when an interval cannot be computed — an exotic constraint form, a
## catalog adapter that cannot express intervals. Raw over-invalidates; it
## never under-invalidates."
##
## Four conditions produce `mfRaw` here, and the FIRST is the common one rather
## than an exotic corner:
##
##   1. **`vpNone`** — the default preference states no direction, so there is
##      no side of the selection on which "no better candidate exists" is a
##      claim the solve made. `default` is the strategy most invocations run
##      under, so the fallback is the hot path, not a museum piece.
##   2. A declared range that does not parse (`ESemverParse`).
##   3. A selected version that does not parse as semver.
##   4. A package whose consulted candidate universe contains a version string
##      that does not parse — the interval could be computed but could not be
##      *replayed* faithfully against the enumeration, and a filter that cannot
##      classify every member is not a filter.
##
## Over-invalidation costs one solve, never a rebuild: the re-solve produces a
## byte-identical lock and early cutoff stops there
## (`Package-Model.md` §"Rule Generators And Dynamic Rule Discovery").
##
## ## Why this module is in the solver
##
## The interval needs the semver order, the parsed declared ranges, the
## selection and the selected-ness — all of which are the solver's. The ledger
## names this file's directory correctly (`libs/repro_solver/src/repro_solver/`)
## and names `libs/repro_build_engine/src/repro_build_engine.nim` for the
## path-set recording and two-phase lookup; see
## `repro_lock_gen/solve_path_set.nim` for why the latter half could not go
## there.

import std/[algorithm, options, sets, tables]

import explainer
import version_constraints
import version_encoder

type
  MaterialityFilterKind* = enum
    ## How a recorded observation filters the enumeration it was taken over.
    ##
    ## `SearchPathDirectoryMembershipFilter` is the BuildXL precedent §5.7
    ## names: the filter is stored in the path set and REPLAYED, so a recorded
    ## observation means "I enumerated D, but only this subset mattered; here
    ## is the hash of that subset."
    mfInterval = "interval"
    mfRaw = "raw"

  ConsultedInterval* = object
    ## One package's consulted metadata, as a filtered enumeration.
    packageName*: string
    kind*: MaterialityFilterKind
    selection*: string
      ## The witness half: the version the solve chose. Recorded even for
      ## `mfRaw` because a diagnostic that cannot say what was selected cannot
      ## explain an invalidation.
    low*: string
      ## Inclusive lower bound of the interval, or `""` for unbounded below.
    high*: string
      ## Upper bound; `""` for unbounded above. Inclusivity is
      ## `highInclusive` — an upper bound derived from a declared range is
      ## EXCLUSIVE (semver ranges are half-open `[lower, upper)`), while one
      ## derived from the selection is INCLUSIVE.
    highInclusive*: bool
    reason*: string
      ## For `mfRaw`, why no interval could be computed. Empty for
      ## `mfInterval`. A fallback that cannot say why it fired is
      ## indistinguishable from a fallback that fires always.

proc effectiveRange*(packages: openArray[PackageDecl];
                     sol: UnifiedSolution;
                     target: string;
                     ok: var bool): SemverRange =
  ## Intersect every LIVE declared range on `target`.
  ##
  ## A range is live when its declaring package is itself selected and, for a
  ## variant-conditioned edge, when the variant resolved to the trigger. That
  ## is the same two-part gate `encodeDependencyEdges` puts in the ASP body of
  ## both the range constraint and the selection rule — read here off the
  ## solution the solver produced rather than recomputed from the declarations,
  ## so the two cannot drift.
  ##
  ## `ok` is set false when a range string does not parse. The caller must then
  ## fall back to raw: a range the derivation could not read is a range whose
  ## boundary the interval would get wrong, and getting a boundary wrong is the
  ## under-invalidation direction.
  ok = true
  result = unboundedRange()
  for p in packages:
    if sol.selected.getOrDefault(p.name, ssUnselected) != ssSelected:
      continue
    for d in p.depends:
      if d.name != target: continue
      if d.conditional.isSome:
        let g = d.conditional.get()
        if sol.variants.getOrDefault(g.variantName, "") != g.triggerValue:
          continue
      let parsed =
        try:
          parseSemverRange(d.range)
        except ESemverParse:
          ok = false
          return unboundedRange()
      if parsed.lower.isSome:
        if result.lower.isNone or result.lower.get < parsed.lower.get:
          result.lower = parsed.lower
      if parsed.upper.isSome:
        if result.upper.isNone or parsed.upper.get < result.upper.get:
          result.upper = parsed.upper

proc renderSemver(v: SemverVersion): string =
  result = $v.major & "." & $v.minor & "." & $v.patch
  if v.prerelease.len > 0:
    result.add("-" & v.prerelease)

proc universeParses(versions: openArray[string]): bool =
  for v in versions:
    try:
      discard parseSemver(v)
    except ESemverParse:
      return false
  true

proc deriveConsultedIntervals*(packages: openArray[PackageDecl];
                               sol: UnifiedSolution;
                               preference: VersionPreference):
                                 seq[ConsultedInterval] =
  ## The path set's semantic half: what the solve consulted, per package.
  ##
  ## Returned sorted by package name so two solves over the same facts render
  ## one path set. Ordering is a cache key here — §1.3's hazard, which "does
  ## not fail loudly: it produces two different keys for one lock file".
  var declared = initTable[string, PackageDecl]()
  for p in packages:
    declared[p.name] = p
  let directs = directDependencyNames(packages)

  var names: seq[string] = @[]
  for name in sol.packages.keys:
    names.add(name)
  names.sort()

  result = @[]
  for name in names:
    # `in` then `[]`, never `getOrDefault`: `UnifiedSolution.selected`'s own
    # header forbids the latter because `ssSelected` is the zero value, so a
    # missing key would answer "selected" for a package the graph does not
    # contain. A key missing HERE cannot happen (`solve` populates one entry
    # per `packages` key) — but if it ever did, silently answering "selected"
    # would record an interval nobody derived. Treating it as unselected drops
    # the observation, which is the under-invalidating direction, so this
    # instead refuses to guess and records raw.
    if name notin sol.selected:
      result.add(ConsultedInterval(packageName: name, kind: mfRaw,
        selection: sol.packages.getOrDefault(name, ""), low: "", high: "",
        highInclusive: false,
        reason: "the solution records no selection status for this package"))
      continue
    if sol.selected[name] != ssSelected:
      continue
    if declared.hasKey(name) and declared[name].pinned:
      continue
    let selection = sol.packages.getOrDefault(name, "")
    if selection.len == 0:
      continue

    # `fallback` is set to the first condition that makes an interval
    # uncomputable, and the four checks below are ordered cheapest-first. The
    # variable exists rather than an early `continue` so that the REASON
    # survives into the recorded observation.
    var fallback = ""
    if preference == vpNone:
      fallback = "preference `default` states no direction, so the solve " &
        "made no `no better candidate` claim on either side"
    if fallback.len == 0 and declared.hasKey(name) and
        not universeParses(declared[name].versions):
      fallback = "the consulted candidate universe contains a version the " &
        "semver parser rejects, so the interval could not be replayed over it"
    var rangeOk = true
    let rng = effectiveRange(packages, sol, name, rangeOk)
    if fallback.len == 0 and not rangeOk:
      fallback = "a live declared range on this package does not parse as a " &
        "semver range"
    var chosen = semver(0, 0, 0)
    if fallback.len == 0:
      try:
        chosen = parseSemver(selection)
      except ESemverParse:
        fallback = "the selected version does not parse as semver"
    if fallback.len > 0:
      result.add(ConsultedInterval(packageName: name, kind: mfRaw,
        selection: selection, low: "", high: "", highInclusive: false,
        reason: fallback))
      continue

    # The per-package direction. `lowest-direct` is the only preference whose
    # direction is not uniform, and it is uniform per package — which is what
    # lets one interval express it.
    let downward =
      case preference
      of vpNone: true          # unreachable: `vpNone` fell back above.
      of vpLowest: true
      of vpHighest: false
      of vpLowestDirect: directs.contains(name)

    if downward:
      # At or below the selection, within the range. The lower bound is the
      # range's own, INCLUSIVE, so the gap between a declared lower bound and
      # the lowest published version is covered.
      result.add(ConsultedInterval(packageName: name, kind: mfInterval,
        selection: selection,
        low: (if rng.lower.isSome: renderSemver(rng.lower.get) else: ""),
        high: renderSemver(chosen), highInclusive: true, reason: ""))
    else:
      # At or above the selection, up to the range's EXCLUSIVE upper bound.
      result.add(ConsultedInterval(packageName: name, kind: mfInterval,
        selection: selection,
        low: renderSemver(chosen),
        high: (if rng.upper.isSome: renderSemver(rng.upper.get) else: ""),
        highInclusive: false, reason: ""))

proc withinInterval*(version: string; iv: ConsultedInterval): bool =
  ## Replay one interval filter against one enumeration member.
  ##
  ## A member the parser rejects is treated as INSIDE. That direction is
  ## chosen, not incidental: a version the filter cannot classify must
  ## contribute to the digest, or publishing an unparseable version would be
  ## invisible to the cache. Unclassifiable members over-invalidate; they never
  ## under-invalidate.
  if iv.kind == mfRaw:
    return true
  let v =
    try:
      parseSemver(version)
    except ESemverParse:
      return true
  if iv.low.len > 0:
    let lo =
      try: parseSemver(iv.low)
      except ESemverParse: return true
    if v < lo: return false
  if iv.high.len > 0:
    let hi =
      try: parseSemver(iv.high)
      except ESemverParse: return true
    if iv.highInclusive:
      if hi < v: return false
    else:
      if not (v < hi): return false
  true

proc filterMembers*(members: openArray[string];
                    iv: ConsultedInterval): seq[string] =
  ## The filtered enumeration: the members inside the interval, in semver
  ## order.
  ##
  ## Sorted rather than kept in published order, because the fact being
  ## recorded is a SET membership claim over an interval and a registry that
  ## reordered its file without changing its contents has published nothing.
  ## `mfRaw` keeps every member and is sorted by the same rule, so raw and
  ## interval differ only in the filter.
  result = @[]
  for m in members:
    if withinInterval(m, iv):
      result.add(m)
  result.sort(proc(a, b: string): int =
    try:
      cmpSemver(parseSemver(a), parseSemver(b))
    except ESemverParse:
      cmp(a, b))

proc renderInterval*(iv: ConsultedInterval): string =
  ## A human-legible rendering for diagnostics: `libfoo [1.2, 1.4]`.
  if iv.kind == mfRaw:
    return iv.packageName & " raw (" & iv.reason & ")"
  iv.packageName & " [" & (if iv.low.len > 0: iv.low else: "-inf") & ", " &
    (if iv.high.len > 0: iv.high else: "+inf") &
    (if iv.highInclusive: "]" else: ")")
