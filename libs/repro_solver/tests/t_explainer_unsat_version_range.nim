## Spec-Implementation M2e — ``explainUnsat`` surfaces a version-range
## conflict via the ``depends_on`` annotation kind.
##
## Scenario: package ``app`` depends on ``openssl >= 3.0`` but the
## catalog only carries ``openssl 1.1.0``. The unsat must surface
## with a core entry tagged ``depends_on`` (the dependency edge that
## could not be satisfied).

import std/[strutils, unittest]

import repro_solver/variant_encoder
import repro_solver/version_encoder
import repro_solver/solver_api
import repro_solver/explainer

suite "explainUnsat — version range failure":
  test "unsat-core points at the failing dependency edge":
    let openssl = newPackage("openssl", versions = ["1.1.0"])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newDependency("openssl", ">=3.0")])

    var coreAtoms: seq[string] = @[]
    var raised = false
    try:
      discard solve([], [openssl, app])
    except EUnsatisfiable as e:
      raised = true
      coreAtoms = e.coreAtoms

    # 1. The solve raised unsat.
    check raised
    # 2. The assumption-interface re-solve produced at least one core
    #    atom.
    check coreAtoms.len >= 1
    # 3. Each entry is the M2e annotated atom shape.
    for atom in coreAtoms:
      check atom.startsWith("assume_constraint(")

    # 4. Structured decode surfaces a ``depends_on`` kind entry
    #    pointing at the app -> openssl edge.
    let entries = explainUnsat(coreAtoms, [], [openssl, app])
    var sawDependsOn = false
    for e in entries:
      if e.kind == "depends_on" and "app" in e.source and
         "openssl" in e.source and ">=3.0" in e.source:
        sawDependsOn = true
    check sawDependsOn

  test "structurally empty range package surfaces the edge":
    # Catalog versions exist but NONE satisfy the range.
    let q = newPackage("q", versions = ["1.0.0", "1.5.0"])
    let p = newPackage("p",
      versions = ["0.1.0"],
      depends = [newDependency("q", ">=2.0 <3.0")])

    var coreAtoms: seq[string] = @[]
    var raised = false
    try:
      discard solve([], [q, p])
    except EUnsatisfiable as e:
      raised = true
      coreAtoms = e.coreAtoms

    # 1. Solve raised unsat.
    check raised
    # 2. Core has entries.
    check coreAtoms.len >= 1
    # 3. Structured decode lists at least one depends_on kind entry
    #    pointing at p -> q.
    let entries = explainUnsat(coreAtoms, [], [q, p])
    var sawEdge = false
    for e in entries:
      if e.kind == "depends_on" and "p" in e.source and "q" in e.source:
        sawEdge = true
    check sawEdge
