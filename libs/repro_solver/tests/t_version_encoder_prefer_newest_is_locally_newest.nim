## ``t_version_encoder_prefer_newest_is_locally_newest`` — what NPC-M6's
## newest-first preference (``PackageDecl.preferNewest`` under ``vpNone``)
## actually guarantees, checked on closures where the newest versions
## conflict, so the answer is not simply "every newest".
##
## ``preferNewest`` is a clingo domain heuristic, not an objective: each
## ``package_chosen`` atom gets the level of its version's rank and is tried
## true first, highest level first. The property relied on is that clingo's
## first model under such a heuristic is maximal level by level, which here
## means: no package of the answer can be moved to a newer version while
## every other package keeps the version it was given. This test checks
## that property on seeded random closures by asking the solver for exactly
## such a move (every other package pinned, the package restricted to newer
## versions) and requiring it to be unsatisfiable. It also checks that the
## same closure gives the same answer on every solve.
##
## It does NOT claim the answer is the one maximising any sum of ranks
## (that is ``vpHighest``), nor which of two incomparable answers is taken
## when raising one package forces another down.
##
## Falsifying mutation: giving the heuristic the sign ``false`` (oldest
## first), or dropping it, leaves a package that could be raised alone.

import std/[algorithm, random, sequtils, strutils, tables, unittest]

import repro_solver/version_encoder
import repro_solver/variant_encoder
import repro_solver/solver_api
import repro_solver/version_constraints

const NoVariants: seq[VariantDecl] = @[]

proc versionText(i: int): string =
  $(1 + i div 4) & "." & $(i mod 4) & ".0"

proc randomClosure(r: var Rand; n, v: int): seq[PackageDecl] =
  ## ``n`` packages of ``v`` versions; each version of ``q<i>`` requires a
  ## random range of up to two later packages, so the newest versions of a
  ## package often exclude the newest versions of the ones it requires.
  var root = newPackage("root", ["0.1.0"])
  for i in 0 ..< n:
    root.depends.add newDependency("q" & $i, ">=1.0.0")
  result.add root
  for i in 0 ..< n:
    var p = PackageDecl(name: "q" & $i, preferNewest: true)
    for j in 0 ..< v:
      let ver = versionText(j)
      p.versions.add ver
      var deps: seq[DependencyDecl]
      for k in 0 ..< 2:
        if i + 1 + k < n and r.rand(2) > 0:
          let target = i + 1 + r.rand(n - i - 2)
          let bound = versionText(r.rand(v - 1))
          deps.add newDependency("q" & $target,
            if r.rand(1) == 0: "<" & bound else: ">=" & bound)
      if deps.len > 0:
        p.versionDepends.add newVersionDependencies(ver, deps)
    result.add p

proc tryRaise(closure: seq[PackageDecl]; chosen: Table[string, string];
              name: string): bool =
  ## Can ``name`` take a version newer than ``chosen[name]`` while every
  ## other package keeps its chosen version?
  var decls: seq[PackageDecl]
  for p in closure:
    var d = p
    if p.name == name:
      d.versions = p.versions.filterIt(cmpSemver(parseSemver(it), parseSemver(chosen[name])) > 0)
      if d.versions.len == 0:
        return false
    elif p.name in chosen:
      d.versions = @[chosen[p.name]]
    decls.add d
  try:
    discard solve(NoVariants, decls)
    true
  except EUnsatisfiable:
    false

suite "version_encoder: preferNewest takes a locally newest answer (NPC-M6)":
  test "no package of the answer can be raised alone, and solves repeat":
    var r = initRand(20261120)
    var solved, conflicted = 0
    for round in 0 ..< 60:
      let closure = randomClosure(r, 6 + round mod 7, 6)
      var sol: UnifiedSolution
      try:
        sol = solve(NoVariants, closure)
      except EUnsatisfiable:
        continue
      inc solved
      var allNewest = true
      for p in closure:
        if p.name != "root" and sol.packages[p.name] != p.versions[^1]:
          allNewest = false
      if not allNewest: inc conflicted
      for again in 0 ..< 3:
        check solve(NoVariants, closure).packages == sol.packages
      for p in closure:
        if p.name == "root": continue
        checkpoint "round " & $round & ": " & p.name & " " &
          sol.packages[p.name] & " in " & $sol.packages
        check not tryRaise(closure, sol.packages, p.name)
    checkpoint $solved & " solved, " & $conflicted & " not all newest"
    # The property is only interesting where the newest versions conflict.
    check solved >= 30
    check conflicted >= 10
