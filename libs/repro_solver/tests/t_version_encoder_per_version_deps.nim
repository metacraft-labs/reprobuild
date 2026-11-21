## ``t_version_encoder_per_version_deps`` — NPC-M6: the encoder takes a
## dependency list per candidate version (``PackageDecl.versionDepends``),
## activates an ``onDemand`` package only when a chosen parent requires it,
## admits a ``#...`` pseudo-version only through a range that names it, and
## makes the search take a ``preferNewest`` package's newest version first
## under no strategy.
##
## Each case solves through the real clingo driver (``solve``); nothing is
## mocked. The last case pins NLF-STAT-4 for this change: a declaration set
## that uses none of the new fields encodes exactly as before, compared
## against a hand-written expected program.

import std/[strutils, tables, times, unittest]

import repro_solver/version_encoder
import repro_solver/variant_encoder
import repro_solver/solver_api
import repro_solver/explainer

const NoVariants: seq[VariantDecl] = @[]

suite "version_encoder: per-version dependencies (NPC-M6)":
  test "each version's own requirements bind only when it is chosen":
    # a 1.0.0 requires b >=2; a 2.0.0 requires b <2. The root pins a's
    # range, and the chosen b must satisfy the chosen a's list alone.
    let b = PackageDecl(name: "b", versions: @["1.0.0", "2.0.0"],
      onDemand: true)
    let a = PackageDecl(name: "a", versions: @["1.0.0", "2.0.0"],
      onDemand: true, versionDepends: @[
        newVersionDependencies("1.0.0", [newDependency("b", ">=2.0.0")]),
        newVersionDependencies("2.0.0", [newDependency("b", "<2.0.0")])])
    for (rangeOfA, wantB) in [("<2.0.0", "2.0.0"), (">=2.0.0", "1.0.0")]:
      let root = newPackage("root", ["0.1.0"],
        [newDependency("a", rangeOfA)])
      let sol = solve(NoVariants, [root, a, b])
      check sol.packages["b"] == wantB
      check sol.selected["b"] == ssSelected

  test "an on-demand package only an unchosen version requires is absent":
    # a 1.0.0 requires c; a 2.0.0 requires nothing; the root wants a 2.x.
    let c = PackageDecl(name: "c", versions: @["1.0.0"], onDemand: true)
    let a = PackageDecl(name: "a", versions: @["1.0.0", "2.0.0"],
      onDemand: true, versionDepends: @[
        newVersionDependencies("1.0.0", [newDependency("c", ">=0.0.0")])])
    let root = newPackage("root", ["0.1.0"], [newDependency("a", ">=2.0.0")])
    let sol = solve(NoVariants, [root, a, c])
    check sol.packages["a"] == "2.0.0"
    check "c" notin sol.packages
    # Control: without on-demand activation, c is forced into the answer.
    var cAlways = c
    cAlways.onDemand = false
    check "c" in solve(NoVariants, [root, a, cAlways]).packages

  test "a requirement on a package with no candidate removes only that version":
    # `gone` has no version at all (a name the index does not hold).
    let gone = PackageDecl(name: "gone", versions: @[], onDemand: true)
    let a = PackageDecl(name: "a", versions: @["1.0.0", "2.0.0"],
      onDemand: true, versionDepends: @[
        newVersionDependencies("2.0.0", [newDependency("gone", ">=0.0.0")])])
    let root = newPackage("root", ["0.1.0"], [newDependency("a", ">=0.0.0")])
    let sol = solve(NoVariants, [root, a, gone])
    check sol.packages["a"] == "1.0.0"
    # Only 2.0.0 admitted: unsatisfiable, not a crash.
    let pinned = newPackage("root", ["0.1.0"],
      [newDependency("a", ">=2.0.0")])
    expect EUnsatisfiable:
      discard solve(NoVariants, [pinned, a, gone])

  test "a pseudo-version is selected only by the range that names it":
    let x = PackageDecl(name: "x", versions: @["1.0.0", "#head"],
      onDemand: true)
    let any = newPackage("root", ["0.1.0"], [newDependency("x", ">=0.0.0")])
    check solve(NoVariants, [any, x]).packages["x"] == "1.0.0"
    let named = newPackage("root", ["0.1.0"], [newDependency("x", "#head")])
    check solve(NoVariants, [named, x]).packages["x"] == "#head"
    check rangeAdmits("#head", "#head")
    check not rangeAdmits("#head", "1.0.0")
    check not rangeAdmits(">=0.0.0", "#head")
    check not rangeAdmits("", "#head")
    # Two requirers, one naming the pseudo-version and one a range: one
    # version per name, so no answer.
    let other = PackageDecl(name: "y", versions: @["1.0.0"], onDemand: true,
      versionDepends: @[newVersionDependencies("1.0.0",
        [newDependency("x", ">=1.0.0")])])
    let both = newPackage("root", ["0.1.0"],
      [newDependency("x", "#head"), newDependency("y", ">=0.0.0")])
    expect EUnsatisfiable:
      discard solve(NoVariants, [both, x, other])

  test "preferNewest picks the newest admissible version under no strategy":
    var x = PackageDecl(name: "x", versions: @["1.0.0", "1.5.0", "2.0.0"],
      onDemand: true, preferNewest: true)
    let root = newPackage("root", ["0.1.0"], [newDependency("x", "<2.0.0")])
    check solve(NoVariants, [root, x]).packages["x"] == "1.5.0"
    check solve(NoVariants, [root, x], vpLowest).packages["x"] == "1.0.0"

  test "preferNewest stays fast on a long closure and takes every newest":
    # 120 packages in a chain, 6 versions each, each version requiring the
    # next two packages. Summing ranks in an objective made this
    # exponential (measured: a 15-package chain over 60 s); the search
    # heuristic answers in well under the bound below.
    let n = 120
    var pkgs = @[newPackage("root", ["0.1.0"], [newDependency("q0", ">=0.0.0")])]
    for i in 0 ..< n:
      var d = PackageDecl(name: "q" & $i, onDemand: true, preferNewest: true)
      for j in 0 ..< 6:
        let ver = $(1 + j div 5) & "." & $(j mod 5) & ".0"
        d.versions.add ver
        var deps: seq[DependencyDecl]
        if i + 1 < n: deps.add newDependency("q" & $(i + 1), ">=1." & $(j mod 5) & ".0")
        if i + 2 < n: deps.add newDependency("q" & $(i + 2), ">=1.1.0")
        d.versionDepends.add newVersionDependencies(ver, deps)
      pkgs.add d
    let t0 = epochTime()
    let sol = solve(NoVariants, pkgs)
    let took = epochTime() - t0
    checkpoint "solved in " & $took & " s"
    check took < 10.0
    for i in 0 ..< n:
      check sol.packages["q" & $i] == "2.0.0"

  test "the selection status follows the chosen version's edges":
    let c = PackageDecl(name: "c", versions: @["1.0.0"])
    let a = PackageDecl(name: "a", versions: @["1.0.0", "2.0.0"],
      versionDepends: @[
        newVersionDependencies("1.0.0", [newDependency("c", ">=0.0.0")])])
    let root = newPackage("root", ["0.1.0"], [newDependency("a", ">=2.0.0")])
    let sol = solve(NoVariants, [root, a, c])
    # c is declared (always active) but only an unchosen version requires it.
    check sol.packages["c"] == "1.0.0"
    check sol.selected["c"] == ssUnselected

  test "the unsat-core program guards a per-version edge and names it":
    # The core program (``encodeWithAssumptions``) must carry the same
    # per-version edge as the solving one, guarded and annotated, or a core
    # computed over it explains a program that never ran. (Which annotations
    # clingo then reports is the core driver's; see the note in the plan's
    # NPC-M6 results about duplicate core atoms, which predates this change.)
    let b = newPackage("b", ["1.0.0"])
    let a = PackageDecl(name: "a", versions: @["1.0.0"], versionDepends: @[
      newVersionDependencies("1.0.0", [newDependency("b", ">=2.0.0")])])
    let root = newPackage("root", ["0.1.0"], [newDependency("a", ">=0.0.0")])
    let (program, annotations) = encodeWithAssumptions(NoVariants,
      [root, a, b])
    var found = -1
    for ann in annotations:
      if ann.source == "a 1.0.0 -> b >=2.0.0": found = ann.id
    check found >= 0
    check (":- assume_constraint(" & $found & "), " &
      "package_chosen(\"a\", \"1.0.0\"), package_chosen(\"b\", V), " &
      "not version_in_range(\"b\", V, \">=2.0.0\").") in program
    expect EUnsatisfiable:
      discard solve(NoVariants, [root, a, b])

  test "declarations without the new fields encode exactly as before":
    let low = newPackage("low", ["1.0.0", "2.0.0"])
    let app = newPackage("app", ["0.1.0"], [newDependency("low", ">=2.0")])
    let expected = [
      "package(\"low\").", "package_active(\"low\").",
      "package_version(\"low\", \"1.0.0\").",
      "package_version(\"low\", \"2.0.0\").",
      "{ package_chosen(\"low\", V) : package_version(\"low\", V) } = 1 :- " &
        "package_active(\"low\").",
      "package(\"app\").", "package_active(\"app\").",
      "package_version(\"app\", \"0.1.0\").",
      "{ package_chosen(\"app\", V) : package_version(\"app\", V) } = 1 :- " &
        "package_active(\"app\").",
      "depends_on(\"app\", \"low\").",
      "package_required(\"app\", \"low\", \">=2.0\").",
      ":- package_chosen(\"app\", _), package_chosen(\"low\", V), " &
        "not version_in_range(\"low\", V, \">=2.0\").",
      "package_selected(\"low\") :- package_selected(\"app\").",
      "version_in_range(\"low\", \"2.0.0\", \">=2.0\").",
      "package_selected(\"app\")."].join("\n") & "\n"
    check encodePackages([low, app]) == expected
    check "version_prefer_newest" notin encodeUnified(NoVariants, [low, app])
    check "package_active(\"low\") :-" notin
      encodeUnified(NoVariants, [low, app])
