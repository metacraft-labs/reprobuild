## ``t_version_encoder_constraints`` — Spec-Implementation M2c encoder
## test for the range-membership integrity constraints.
##
## A dependency carries a range expression. The encoder pre-grounds
## ``version_in_range/3`` facts at encode time and emits the integrity
## constraint that forbids the parent picking a child version outside
## the range.

import std/[strutils, tables, unittest]

import repro_solver/version_encoder
import repro_solver/solver_api

suite "version_encoder: range constraints":
  test "ground facts: only in-range versions emit version_in_range":
    let nim = newPackage("nim",
      versions = ["1.9.0", "2.0.0", "2.2.0", "2.2.4", "3.0.0"])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newDependency("nim", ">=2.2 <3.0")])
    let program = encodePackages([nim, app])

    # 1. In-range versions are grounded.
    check program.contains(
      "version_in_range(\"nim\", \"2.2.0\", \">=2.2 <3.0\").")
    check program.contains(
      "version_in_range(\"nim\", \"2.2.4\", \">=2.2 <3.0\").")
    # 2. Out-of-range versions do NOT emit a ground fact.
    check not program.contains(
      "version_in_range(\"nim\", \"1.9.0\", \">=2.2 <3.0\").")
    check not program.contains(
      "version_in_range(\"nim\", \"2.0.0\", \">=2.2 <3.0\").")
    check not program.contains(
      "version_in_range(\"nim\", \"3.0.0\", \">=2.2 <3.0\").")
    # 3. The integrity constraint lands gating on the chosen version.
    check program.contains(":-")
    check program.contains("not version_in_range(\"nim\", V, \">=2.2 <3.0\").")

  test "integrity constraint forces a satisfying version":
    # ``app`` depends on ``nim >=2.2 <3.0``. Only ``2.2.4`` and ``2.2.0``
    # satisfy. The solver must pick one of those.
    let nim = newPackage("nim",
      versions = ["1.9.0", "2.0.0", "2.2.0", "2.2.4", "3.0.0"])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newDependency("nim", ">=2.2 <3.0")])
    let sol = solve([], [nim, app])

    # 1. ``app`` resolves to its only version.
    check sol.packages["app"] == "0.1.0"
    # 2. ``nim`` resolves to an in-range version.
    check sol.packages["nim"] in ["2.2.0", "2.2.4"]
    # 3. The solver returned a solution covering both packages.
    check sol.packages.len == 2

  test "exact-pin dependency forces the exact version":
    let nim = newPackage("nim",
      versions = ["2.2.0", "2.2.4"])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newDependency("nim", "2.2.4")])
    let sol = solve([], [nim, app])

    # 1. ``nim`` is pinned exactly to 2.2.4.
    check sol.packages["nim"] == "2.2.4"
    # 2. ``app`` still resolves.
    check sol.packages["app"] == "0.1.0"
    # 3. Both packages appear.
    check sol.packages.len == 2

  test "out-of-range-only catalog yields unsat":
    let nim = newPackage("nim", versions = ["1.0.0", "1.5.0"])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newDependency("nim", ">=2.0 <3.0")])

    var raised = false
    try:
      discard solve([], [nim, app])
    except EUnsatisfiable:
      raised = true
    check raised
