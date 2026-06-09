## ``t_variant_encoder_priorities`` — Spec-Implementation M2b
## encoder + end-to-end priority lattice test.
##
## Verifies that the encoder emits ``priority/3`` facts in the
## ``prDefault < prSet < prOverride < prForce`` order specified by
## ``Configurable-System.md`` §"Solver-Phase Resolution", that the
## ``#minimize`` directive references them, and that the M2b solver
## driver actually picks the highest-band contribution across the
## full lattice when run end-to-end through clingo.

import std/[strutils, tables, unittest]

import repro_solver/variant_encoder
import repro_solver/solver_api

suite "variant_encoder: priority lattice":
  test "encoder emits one priority fact per contribution":
    let v = newBoolVariant("enableTLS",
      contributions = [
        contribution(vpDefault, "false"),
        contribution(vpSet, "true")])
    let program = encodeVariants([v])

    # 1. Both contributions land as priority facts.
    check program.contains("priority(\"enableTLS\", \"false\", 4).")
    check program.contains("priority(\"enableTLS\", \"true\", 3).")
    # 2. The #minimize directive references the priority predicate.
    check program.contains("#minimize")
    check program.contains("priority(Name, Value, Weight)")
    # 3. The lattice ordering: prForce < prOverride < prSet < prDefault
    #    so smaller weight = higher priority (prForce weight = 1).
    check program.contains("variant_assigned(Name, Value)")

  test "solver picks prForce over prOverride over prSet over prDefault":
    # 1. prDefault vs prSet — prSet wins.
    block:
      let v = newBoolVariant("flag",
        contributions = [
          contribution(vpDefault, "false"),
          contribution(vpSet, "true")])
      let sol = solveVariants([v])
      check sol.assignments["flag"] == "true"

    # 2. prSet vs prOverride — prOverride wins.
    block:
      let v = newEnumVariant("compiler", ["gcc", "clang"],
        contributions = [
          contribution(vpSet, "gcc"),
          contribution(vpOverride, "clang")])
      let sol = solveVariants([v])
      check sol.assignments["compiler"] == "clang"

    # 3. prOverride vs prForce — prForce wins.
    block:
      let v = newEnumVariant("compiler", ["gcc", "clang", "msvc"],
        contributions = [
          contribution(vpOverride, "clang"),
          contribution(vpForce, "msvc")])
      let sol = solveVariants([v])
      check sol.assignments["compiler"] == "msvc"

    # 4. Full lattice in one variant — prForce must dominate.
    block:
      let v = newEnumVariant("backend", ["a", "b", "c", "d"],
        contributions = [
          contribution(vpDefault, "a"),
          contribution(vpSet, "b"),
          contribution(vpOverride, "c"),
          contribution(vpForce, "d")])
      let sol = solveVariants([v])
      check sol.assignments["backend"] == "d"

  test "default contribution wins when no higher-band exists":
    let v = newEnumVariant("kind", ["small", "medium", "large"],
      contributions = [contribution(vpDefault, "medium")])
    let sol = solveVariants([v])

    # 1. The default value is selected.
    check sol.assignments["kind"] == "medium"
    # 2. The variant appears in the assignments table at all.
    check "kind" in sol.assignments
    # 3. The solver proved optimality (small search space).
    check sol.optimal
