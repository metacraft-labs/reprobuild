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
## ## What else the answer depends on: rejected candidates
##
## The selection interval above is not the whole of what a solve consulted.
## The solver also weighs candidates it then REJECTS, and an answer built on a
## rejection moves when the rejection stops holding (reprobuild-pm issue
## `2026-11-12-filtered-interval-materiality-misses-changes-that-matter-and-is-undefined-for-the-most.md`,
## measured by `t_materiality_covers_unselected_and_dormant_constraints`):
##
##   * **A dormant constraint.** An edge `Y ∈ R` whose declarer is unselected,
##     or whose variant gate resolved to another value, is dormant in the
##     answer — but the solver evaluated it: a variant that WANTS the arm gives
##     it up only because no candidate of `Y` satisfies `R`. Publishing one
##     inside `R` reopens the arm. So every dormant constraint records `Y`'s
##     enumeration filtered to `R` (`mbConstraint`), whether `Y` itself is
##     selected or not; for a selected `Y` the version that reopens the arm
##     may lie on the side of the selection the selection interval ignores.
##     The one dormant edge left out is the one that can NEVER become live:
##     its gate is a pinned variant (NLF-M3, a fact rather than a choice) set
##     to another value, or its declarer can be reached only through such
##     edges. Recording it would invalidate on a publication that cannot move
##     the answer — the over-invalidation §5.7 exists to remove (NLF-GEN-1).
##   * **An unselected package's chosen version.** The lock carries a version
##     for every instance, selected or not (`solutionToLock`), and the version
##     preference ranks every `package_chosen` atom. With no live range, the
##     interval is the selection interval with the range unbounded:
##     `[-inf, chosen]` downward, `[chosen, +inf)` upward.
##   * **A live arm the version objective can abandon.** Folding a live
##     constraint into the selection interval assumes the constraint stays
##     live. It does when its gate is decided at the variant level (level 0,
##     above every version level): the assigned value is strictly the
##     cheapest feasible one. When the gate is TIED with another value — a
##     variant nobody expressed a preference for — the version levels break
##     the tie, comparing whole configurations by their summed ranks, and a
##     publication outside every interval can flip it (only `libfoo 1.4`
##     admissible under `fast`, `libfoo 3.0` published, `fast` dropped). The
##     packages such a variant reaches are recorded raw
##     (`tradeableVariants`, `tradedPackages`).
##
## This is the issue's proposal — "for every constraint `Y ∈ R` that the
## solver evaluates, record Y's enumeration filtered to R" — with the live
## constraints folded into the selection interval, which is tighter: a live
## constraint whose gate is decided is satisfied by the selection and stays
## live, so the only members of `R` that can move the answer are the ones the
## selection interval already covers.
## Several observations over one version list are several filters over one
## enumeration, each replayed on its own; none is a new observation class.
##
## ## Two things deliberately record NOTHING
##
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
##   1. **`vpNone`** — the default preference states no direction: `default`
##      emits no version objective at all, so which admissible candidate the
##      solve returns is whichever model clingo finds first, and no side of
##      the selection carries a "no better candidate exists" claim. `default`
##      is the strategy most invocations run under, so the fallback is the hot
##      path, not a museum piece.
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
import variant_encoder
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

  MaterialityBasis* = enum
    ## WHICH fact about the answer an observation protects. One version list
    ## can carry several observations — a selection interval and one per
    ## dormant constraint on it — and the basis is what says which is which
    ## when an invalidation has to be explained. It is part of the recorded
    ## path set, so it is also part of the strong fingerprint.
    mbSelection = "selection"
      ## The selection plus the interval in which no better candidate exists
      ## (or, for `mfRaw`, the whole enumeration the selection was made from).
    mbConstraint = "constraint"
      ## A dormant constraint `Y ∈ R`: the members of `R`, any one of which
      ## could make the constraint satisfiable and reopen the arm.

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
    basis*: MaterialityBasis
      ## Which fact this interval protects; see `MaterialityBasis`.

proc edgeIsLive(declarer: PackageDecl; d: DependencyDecl;
                sol: UnifiedSolution): bool =
  ## Whether the edge `declarer -> d` is live in `sol`: its declarer is
  ## selected and, for a variant-conditioned edge, the variant resolved to the
  ## trigger. The same two-part gate `encodeDependencyEdges` puts in the ASP
  ## body of the range constraint, read off the solution rather than
  ## recomputed from the declarations. `effectiveRange` intersects the live
  ## edges; `deriveConsultedIntervals` records the dormant ones. One predicate
  ## for both, so an edge cannot be counted in neither.
  if sol.selected.getOrDefault(declarer.name, ssUnselected) != ssSelected:
    return false
  if d.conditional.isSome:
    let g = d.conditional.get()
    if sol.variants.getOrDefault(g.variantName, "") != g.triggerValue:
      return false
  true

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
    for d in p.depends:
      if d.name != target: continue
      if not edgeIsLive(p, d, sol): continue
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

proc collectVariantDecls(packages: openArray[PackageDecl];
                         variants: openArray[VariantDecl]):
                           Table[string, VariantDecl] =
  ## Every variant declaration the solve was given, by name, with the
  ## encoder's precedence: the request's declarations first, then those inside
  ## `PackageDecl.variants`, first one wins (`encodeUnifiedProgram`). Reading
  ## them in another order could take a pin or a contribution from a
  ## declaration the solver ignored.
  result = initTable[string, VariantDecl]()
  for v in variants:
    if v.name notin result:
      result[v.name] = v
  for p in packages:
    for v in p.variants:
      if v.name notin result:
        result[v.name] = v

proc pinnedVariantValues(decls: Table[string, VariantDecl]):
                           Table[string, string] =
  ## Every variant whose value is a FACT of the program (NLF-M3
  ## `pinnedValue`), by name. A pinned variant is asserted, not searched for,
  ## so an edge gated on it with another trigger can never become live.
  result = initTable[string, string]()
  for name, v in decls:
    if v.pinnedValue.len > 0:
      result[name] = v.pinnedValue

proc tradeableVariants(decls: Table[string, VariantDecl];
                       sol: UnifiedSolution): HashSet[string] =
  ## The unpinned variants whose assignment the VERSION objective may have
  ## decided. Variant weights are optimised at level 0, above every version
  ## level, so a variant whose assigned value is strictly the cheapest of its
  ## feasible values cannot be traded for a better version: it moves only
  ## when a cheaper value becomes feasible, which is a dormant constraint
  ## being satisfied and is recorded as one. A variant is tradeable when that
  ## argument does not hold:
  ##
  ##   * another value carries the SAME weight as the assigned one — a tie at
  ##     level 0, which the version levels below then break, so publishing a
  ##     version can flip it and abandon a live arm;
  ##   * a constraint expression names it, as source or target — its weight
  ##     is then traded against other variants' at level 0, which this
  ##     derivation does not model;
  ##   * the solution assigns it nothing, or it has no declaration here.
  ##
  ## Over-approximating this set over-invalidates; it never under-invalidates.
  result = initHashSet[string]()
  var constrained = initHashSet[string]()
  for name, v in decls:
    for c in v.constraints:
      constrained.incl(name)
      constrained.incl(c.target)
  for name, v in decls:
    if v.pinnedValue.len > 0:
      continue
    if name in constrained or name notin sol.variants:
      result.incl(name)
      continue
    let assigned = sol.variants[name]
    let weights = valueWeights(v)
    let own = weights.getOrDefault(assigned, NoContributionWeight)
    for value, w in weights:
      if value != assigned and w == own:
        result.incl(name)
        break
  # A gate naming a variant the solve assigned but nobody declared here: the
  # weights are unknown, so it is tradeable.
  for name in sol.variants.keys:
    if name notin decls:
      result.incl(name)

proc tradedPackages(packages: openArray[PackageDecl];
                    tradeable: HashSet[string]): HashSet[string] =
  ## The packages whose admissible versions differ between assignments of a
  ## tradeable variant: the target of every edge gated on one, closed over
  ## every edge out of such a package (its own selection, and so the
  ## liveness of its edges, can flip with the gate). For these the version
  ## objective compares whole configurations — the sum of ranks across
  ## packages — so a publication anywhere in the enumeration, even one that
  ## merely shifts the ranks between two configurations' choices, can move
  ## the answer. No interval expresses that; they are recorded raw.
  result = initHashSet[string]()
  for p in packages:
    for d in p.depends:
      if d.conditional.isSome and
          d.conditional.get().variantName in tradeable:
        result.incl(d.name)
  var changed = true
  while changed:
    changed = false
    for p in packages:
      if p.name notin result: continue
      for d in p.depends:
        if d.name notin result:
          result.incl(d.name)
          changed = true

proc gateCanOpen(d: DependencyDecl; pinned: Table[string, string]): bool =
  ## False only for an edge whose variant gate is pinned to another value.
  if d.conditional.isNone:
    return true
  let g = d.conditional.get()
  not pinned.hasKey(g.variantName) or pinned[g.variantName] == g.triggerValue

proc reachableDeclarers(packages: openArray[PackageDecl];
                        sol: UnifiedSolution;
                        pinned: Table[string, string]): HashSet[string] =
  ## The packages that are selected, or could become selected if some
  ## unpinned variant resolved differently: the selected set, closed over
  ## every edge whose gate can open. Only their edges are constraints the
  ## answer can depend on. Over-approximating this set over-invalidates; it
  ## never under-invalidates.
  result = initHashSet[string]()
  for name, status in sol.selected:
    if status == ssSelected:
      result.incl(name)
  var changed = true
  while changed:
    changed = false
    for p in packages:
      if p.name notin result: continue
      for d in p.depends:
        if d.name notin result and gateCanOpen(d, pinned):
          result.incl(d.name)
          changed = true

proc rawInterval(name, selection, reason: string): ConsultedInterval =
  ConsultedInterval(packageName: name, kind: mfRaw, selection: selection,
    low: "", high: "", highInclusive: false, reason: reason,
    basis: mbSelection)

proc deriveConsultedIntervals*(packages: openArray[PackageDecl];
                               sol: UnifiedSolution;
                               preference: VersionPreference;
                               variants: openArray[VariantDecl] = []):
                                 seq[ConsultedInterval] =
  ## The path set's semantic half: what the solve consulted, per package.
  ##
  ## Per package, in this order:
  ##
  ##   1. the SELECTION interval (`mbSelection`), for a selected package and —
  ##      because the lock carries its chosen version too — for an unselected
  ##      one, whose interval then has an unbounded range;
  ##   2. one `mbConstraint` interval per distinct DORMANT constraint on it,
  ##      sorted, from a declarer that is or could become selected and
  ##      through a gate that can open (see the module header).
  ##
  ## When the package falls back to raw, one raw observation replaces both:
  ## the whole enumeration subsumes every filter over it.
  ##
  ## `variants` are the request's variant declarations; their `pinnedValue`,
  ## contributions and constraints are read. Omitting them treats every gate
  ## as one that can open and every assigned variant as tradeable, which
  ## over-invalidates and is therefore safe.
  ##
  ## A package whose admissible versions depend on a TRADEABLE variant
  ## (`tradeableVariants`, `tradedPackages`) falls back to raw: the version
  ## objective can abandon a live arm for a better version elsewhere, so
  ## neither its selection interval nor its constraints bound what matters.
  ##
  ## Returned sorted by package name so two solves over the same facts render
  ## one path set. Ordering is a cache key here — §1.3's hazard, which "does
  ## not fail loudly: it produces two different keys for one lock file".
  var declared = initTable[string, PackageDecl]()
  for p in packages:
    declared[p.name] = p
  let directs = directDependencyNames(packages)
  let variantDecls = collectVariantDecls(packages, variants)
  let pinnedVariants = pinnedVariantValues(variantDecls)
  let traded = tradedPackages(packages,
    tradeableVariants(variantDecls, sol))
  let declarers = reachableDeclarers(packages, sol, pinnedVariants)
  var perVersion = initHashSet[string]()
  for p in packages:
    for vd in p.versionDepends:
      perVersion.incl(p.name)
      for d in vd.depends:
        perVersion.incl(d.name)

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
      result.add(rawInterval(name, sol.packages.getOrDefault(name, ""),
        "the solution records no selection status for this package"))
      continue
    let isSelected = sol.selected[name] == ssSelected
    if declared.hasKey(name) and declared[name].pinned:
      continue
    if name in perVersion:
      # NPC-M6: which of these edges bind depends on which version each
      # declarer chooses, which this derivation does not model. Raw
      # over-invalidates, which is the safe direction.
      result.add(rawInterval(name, sol.packages.getOrDefault(name, ""),
        "a per-version dependency list declares or constrains this package"))
      continue
    let selection = sol.packages.getOrDefault(name, "")
    if selection.len == 0:
      continue

    # The dormant constraints on this package. A range that does not parse
    # makes the package raw, for the reason `effectiveRange` gives: a boundary
    # the filter gets wrong is the under-invalidation direction.
    var dormant: seq[SemverRange] = @[]
    var dormantOk = true
    for p in packages:
      if p.name notin declarers: continue
      for d in p.depends:
        if d.name != name: continue
        if edgeIsLive(p, d, sol) or not gateCanOpen(d, pinnedVariants):
          continue
        try:
          dormant.add(parseSemverRange(d.range))
        except ESemverParse:
          dormantOk = false

    # `fallback` is set to the first condition that makes an interval
    # uncomputable, and the checks below are ordered cheapest-first. The
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
    let rng =
      if isSelected: effectiveRange(packages, sol, name, rangeOk)
      else: unboundedRange()
    if fallback.len == 0 and not rangeOk:
      fallback = "a live declared range on this package does not parse as a " &
        "semver range"
    if fallback.len == 0 and name in traded:
      fallback = "a variant gating an edge into this package is not " &
        "decided at the variant level (tied, or bound by a constraint " &
        "expression), so the version objective can trade its arms against " &
        "versions of other packages"
    if fallback.len == 0 and not dormantOk:
      fallback = "a dormant declared range on this package does not parse " &
        "as a semver range"
    var chosen = semver(0, 0, 0)
    if fallback.len == 0:
      try:
        chosen = parseSemver(selection)
      except ESemverParse:
        fallback = "the selected version does not parse as semver"
    if fallback.len > 0:
      result.add(rawInterval(name, selection, fallback))
      continue

    # The per-package direction. `lowest-direct` is the only preference whose
    # direction is not uniform, and it is uniform per package — which is what
    # lets one interval express it. Its objective ranks a dormant direct
    # package downward too (`directDependencyNames` includes conditional
    # arms), so the same test serves an unselected package.
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
        high: renderSemver(chosen), highInclusive: true, reason: "",
        basis: mbSelection))
    else:
      # At or above the selection, up to the range's EXCLUSIVE upper bound.
      result.add(ConsultedInterval(packageName: name, kind: mfInterval,
        selection: selection,
        low: renderSemver(chosen),
        high: (if rng.upper.isSome: renderSemver(rng.upper.get) else: ""),
        highInclusive: false, reason: "", basis: mbSelection))

    # Each dormant constraint, as its own range: `[lower, upper)`, both bounds
    # the declared range's own. Rendered, deduplicated and sorted so the path
    # set does not depend on declaration order.
    var seen = initHashSet[(string, string)]()
    var constraints: seq[ConsultedInterval] = @[]
    for r in dormant:
      let lo = if r.lower.isSome: renderSemver(r.lower.get) else: ""
      let hi = if r.upper.isSome: renderSemver(r.upper.get) else: ""
      if (lo, hi) in seen: continue
      seen.incl((lo, hi))
      constraints.add(ConsultedInterval(packageName: name, kind: mfInterval,
        selection: selection, low: lo, high: hi, highInclusive: false,
        reason: "", basis: mbConstraint))
    constraints.sort(proc(a, b: ConsultedInterval): int =
      result = cmp(a.low, b.low)
      if result == 0: result = cmp(a.high, b.high))
    result.add(constraints)

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
  ## A human-legible rendering for diagnostics: `libfoo [1.2, 1.4]`, or
  ## `libssl constraint [2.0, 2.5)` for a dormant constraint.
  if iv.kind == mfRaw:
    return iv.packageName & " raw (" & iv.reason & ")"
  iv.packageName & (if iv.basis == mbConstraint: " constraint" else: "") &
    " [" & (if iv.low.len > 0: iv.low else: "-inf") & ", " &
    (if iv.high.len > 0: iv.high else: "+inf") &
    (if iv.highInclusive: "]" else: ")")
