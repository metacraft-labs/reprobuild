## ``t_version_strategy_solves_package_by_package`` — a version strategy
## (``highest``, ``lowest``, ``lowest-direct``) settles the closure one
## package at a time, nearest the request first, and its solve time grows
## with the closure rather than with the product of its candidate sets.
##
## reprobuild-pm issue
## 2026-11-20-highest-strategy-solve-time-grows-exponentially-with-the-closure,
## and Named-Lock-Files §5.5 "How a strategy orders the closure", which
## settles it: one objective level per package, solved with core-guided
## optimisation. Before, the objective was one level summing every
## package's rank under clingo's default branch-and-bound, and on the
## issue's chain ``highest`` took 3.7 s at 10 packages and 42-87 s at 12;
## 14 did not finish in 300 s.
##
## Cases, and what each fails on:
##
## - "the issue's chain" is the issue's exact shape at 12 packages under a
##   10 s bound. The summed objective fails it (tens of seconds), the fixed
##   encoding answers in milliseconds. It also checks the answer in closed
##   form, so a fast encoding that picked something else fails it too.
## - "a long closure" runs that chain and a chain whose newer versions
##   require OLDER versions of the next package (so the strategy's
##   direction genuinely conflicts along the chain) at 120 and 40 packages.
##   Under the summed objective these do not terminate in any useful time;
##   per-package levels with branch-and-bound also stall on the conflicting
##   chain, so this case is what pins the core-guided optimisation too.
## - "each package takes the best version the packages before it allow"
##   is the semantics: walking ``versionPreferenceOrder``, no package can
##   move in the strategy's direction while every earlier package keeps its
##   version. That is the lexicographic optimum, checked by asking the real
##   solver for exactly such a move and requiring UNSAT. A summed objective
##   that trades an earlier package down for two later ones up fails it.
## - "the answer does not depend on declaration order" and "the order is
##   distance from the request, then name" pin the order the levels use.
##
## Nothing is mocked: every solve goes through the real clingo driver.

import std/[algorithm, sequtils, sets, strutils, tables, times, unittest]

import repro_solver/version_encoder
import repro_solver/variant_encoder
import repro_solver/solver_api
import repro_solver/version_constraints

const NoVariants: seq[VariantDecl] = @[]
const Versions = ["1.0.0", "1.1.0", "1.2.0", "1.3.0", "1.4.0", "2.0.0"]
const Bound = 10.0
  ## Seconds. The fixed encoding answers every case here in well under one
  ## second on an idle host; the bound leaves room for a loaded CI host and
  ## stays far below what the summed objective took.

proc issueChain(n: int): seq[PackageDecl] =
  ## The issue's shape: ``p<i>`` depends on ``p<i+1> >=1.0.0, <(2 + i mod
  ## 3).0.0`` and on ``p<i+2> >=1.1.0``, package-level, no variants.
  for i in 0 ..< n:
    var deps: seq[DependencyDecl]
    if i + 1 < n:
      deps.add newDependency("p" & $(i + 1),
        ">=1.0.0, <" & $(2 + i mod 3) & ".0.0")
    if i + 2 < n:
      deps.add newDependency("p" & $(i + 2), ">=1.1.0")
    result.add newPackage("p" & $i, Versions, deps)

proc conflictingChain(n: int): seq[PackageDecl] =
  ## Version ``j`` of ``q<i>`` admits only ranks ``4 - j .. 6 - j`` of
  ## ``q<i+1>``, and its even versions also require ``q<i+2> >=1.(j/2)``:
  ## the newer a package, the older the next one must be, so no answer takes
  ## every package's extreme and the strategy has a real choice at each
  ## step.
  result.add newPackage("root", ["0.1.0"], [newDependency("q0", ">=0.0.0")])
  for i in 0 ..< n:
    var d = PackageDecl(name: "q" & $i, onDemand: true)
    for j in 0 ..< Versions.len:
      d.versions.add Versions[j]
      var deps: seq[DependencyDecl]
      if i + 1 < n:
        deps.add newDependency("q" & $(i + 1),
          ">=" & Versions[max(0, 4 - j)] & ", <=" & Versions[min(5, 6 - j)])
      if i + 2 < n and j mod 2 == 0:
        deps.add newDependency("q" & $(i + 2), ">=1." & $(j div 2) & ".0")
      d.versionDepends.add newVersionDependencies(Versions[j], deps)
    result.add d

proc timedSolve(packages: seq[PackageDecl];
                preference: VersionPreference): UnifiedSolution =
  let t0 = epochTime()
  result = solve(NoVariants, packages, preference)
  let took = epochTime() - t0
  checkpoint $preference & " over " & $packages.len & " packages: " &
    $took & " s"
  check took < Bound
  check result.optimal

proc better(preference: VersionPreference; directs: HashSet[string];
            name, candidate, chosen: string): bool =
  ## Whether ``candidate`` is a move in the strategy's direction from
  ## ``chosen`` for package ``name``.
  let c = cmpSemver(parseSemver(candidate), parseSemver(chosen))
  case preference
  of vpHighest: c > 0
  of vpLowest: c < 0
  of vpLowestDirect: (if name in directs: c < 0 else: c > 0)
  of vpNone: false

proc canImprove(closure: seq[PackageDecl]; chosen: Table[string, string];
                earlier: HashSet[string]; name: string;
                preference: VersionPreference): bool =
  ## Can ``name`` move in the strategy's direction while every package in
  ## ``earlier`` keeps its chosen version? The later packages stay free.
  let directs = directDependencyNames(closure)
  var decls: seq[PackageDecl]
  for p in closure:
    var d = p
    if p.name == name:
      d.versions = p.versions.filterIt(
        better(preference, directs, name, it, chosen[name]))
      if d.versions.len == 0:
        return false
    elif p.name in earlier and p.name in chosen:
      d.versions = @[chosen[p.name]]
    decls.add d
  try:
    discard solve(NoVariants, decls)
    true
  except EUnsatisfiable:
    false

suite "version strategies settle the closure package by package":
  test "the issue's chain: highest over 12 packages answers within the bound":
    for preference in [vpHighest, vpLowest, vpLowestDirect]:
      let sol = timedSolve(issueChain(12), preference)
      for i in 0 ..< 12:
        # p0 is the only root, so lowest-direct minimises p1 and p2 (its
        # direct dependencies) and maximises the rest. Every package whose
        # parent bounds it below 2.0.0 (i mod 3 == 1) tops out at 1.4.0; p2
        # onwards are bounded below by >=1.1.0 from their grandparent.
        let top = if i mod 3 == 1: "1.4.0" else: "2.0.0"
        let bottom = if i < 2: "1.0.0" else: "1.1.0"
        let want =
          case preference
          of vpHighest: top
          of vpLowest: bottom
          else: (if i in 1 .. 2: bottom else: top)
        checkpoint $preference & " p" & $i
        check sol.packages["p" & $i] == want

  test "a long closure answers within the bound under every strategy":
    for preference in [vpHighest, vpLowest, vpLowestDirect]:
      # timedSolve checks the bound and optimality; every package of the
      # closure must also have been given a version.
      check timedSolve(issueChain(120), preference).packages.len == 120
      check timedSolve(conflictingChain(40), preference).packages.len == 41

  test "each package takes the best version the packages before it allow":
    var conflicted = 0
    for preference in [vpHighest, vpLowest, vpLowestDirect]:
      for closure in [conflictingChain(10), issueChain(10)]:
        let sol = timedSolve(closure, preference)
        var earlier = initHashSet[string]()
        for name in versionPreferenceOrder(closure, preference):
          checkpoint $preference & ": " & name & " at " &
            sol.packages[name] & " in " & $sol.packages
          check not canImprove(closure, sol.packages, earlier, name,
                               preference)
          earlier.incl(name)
        # Count the answers in which some package is not at its extreme:
        # only those exercise the order rather than a greedy answer.
        for p in closure:
          if p.name in sol.packages and p.versions.len > 1 and
             sol.packages[p.name] notin [p.versions[0], p.versions[^1]]:
            inc conflicted
            break
    check conflicted >= 3

  test "the answer does not depend on declaration order":
    for preference in [vpHighest, vpLowest, vpLowestDirect]:
      let closure = conflictingChain(16)
      let forward = solve(NoVariants, closure, preference).packages
      let backward = solve(NoVariants, closure.reversed,
        preference).packages
      check forward == backward
      check solve(NoVariants, closure, preference).packages == forward

  test "the order is distance from the request, then name":
    # root -> {b, a}; a -> c; b -> c, d; d -> e. Pinned x is not ordered.
    # A cycle no root reaches (y <-> z) comes last, by name.
    let closure = @[
      newPackage("root", ["1.0.0"],
        [newDependency("b", ">=0.0.0"), newDependency("a", ">=0.0.0")]),
      newPackage("e", ["1.0.0"]),
      newPackage("d", ["1.0.0"], [newDependency("e", ">=0.0.0")]),
      newPackage("c", ["1.0.0"], [newDependency("x", ">=0.0.0")]),
      newPackage("b", ["1.0.0"],
        [newDependency("c", ">=0.0.0"), newDependency("d", ">=0.0.0")]),
      newPackage("a", ["1.0.0"], [newDependency("c", ">=0.0.0")]),
      newPinnedPackage("x", "1.0.0"),
      newPackage("z", ["1.0.0"], [newDependency("y", ">=0.0.0")]),
      newPackage("y", ["1.0.0"], [newDependency("z", ">=0.0.0")])]
    check versionPreferenceOrder(closure, vpHighest) ==
      @["root", "a", "b", "c", "d", "e", "y", "z"]
    check versionPreferenceOrder(closure, vpLowest) ==
      @["root", "a", "b", "c", "d", "e", "y", "z"]
    # lowest-direct: the root's direct dependencies first.
    check versionPreferenceOrder(closure, vpLowestDirect) ==
      @["a", "b", "root", "c", "d", "e", "y", "z"]
    # One level per ordered package, counting down from the base.
    let text = encodeVersionPreference(closure, vpHighest)
    check "version_level(\"root\", -1)." in text
    check "version_level(\"e\", -6)." in text
    check "version_level(\"z\", -8)." in text
    check "version_level(\"x\"" notin text
    check "#maximize { R@L, P : package_chosen(P, V), " &
      "version_rank(P, V, R), version_level(P, L) }." in text
