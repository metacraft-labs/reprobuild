## ``t_solve_variants_end_to_end`` — Spec-Implementation M2b
## end-to-end driver test.
##
## Builds synthetic variant registries that exercise every M2b
## encoding rule together, runs each through ``solveVariants`` (which
## drives ``libclingo.so`` via the M2a bindings), and verifies the
## returned ``VariantSolution`` carries the expected assignments.
##
## Scenarios:
##
## 1. **Pure defaults.** Three independent variants, each with only a
##    ``prDefault`` contribution. The solver picks every default.
## 2. **Priority cascade.** Two variants, a default + override pair
##    per variant. Both overrides win.
## 3. **Constraint web.** Three variants linked by a requires + a
##    conflicts. The solver navigates the web and lands a consistent
##    assignment.
## 4. **Mixed kinds.** A bool, an enum, and an int variant share a
##    single solver call. Each variant's universe is respected and
##    the priority lattice picks the expected value for each.

import std/[tables, unittest]

import repro_solver/variant_encoder
import repro_solver/solver_api

suite "solveVariants end-to-end":
  test "scenario 1: pure defaults across three variants":
    let variants = [
      newBoolVariant("enableTLS",
        contributions = [contribution(vpDefault, "false")]),
      newEnumVariant("compiler", ["gcc", "clang"],
        contributions = [contribution(vpDefault, "gcc")]),
      newEnumVariant("backend", ["a", "b", "c"],
        contributions = [contribution(vpDefault, "b")])]
    let sol = solveVariants(variants)

    # 1. Each default lands as the chosen value.
    check sol.assignments["enableTLS"] == "false"
    check sol.assignments["compiler"] == "gcc"
    check sol.assignments["backend"] == "b"
    # 2. No surprise atoms in the solution.
    check sol.assignments.len == 3
    # 3. The solver proved the search exhausted.
    check sol.optimal

  test "scenario 2: priority cascade across two variants":
    let variants = [
      newEnumVariant("compiler", ["gcc", "clang", "msvc"],
        contributions = [
          contribution(vpDefault, "gcc"),
          contribution(vpOverride, "clang")]),
      newEnumVariant("optLevel", ["O0", "O1", "O2", "O3"],
        contributions = [
          contribution(vpDefault, "O0"),
          contribution(vpForce, "O2")])]
    let sol = solveVariants(variants)

    # 1. Override wins over default.
    check sol.assignments["compiler"] == "clang"
    # 2. Force wins over default.
    check sol.assignments["optLevel"] == "O2"
    # 3. Both variants in the solution, none extra.
    check sol.assignments.len == 2

  test "scenario 3: constraint web (requires + conflicts)":
    let variants = [
      newBoolVariant("enableTLS",
        contributions = [contribution(vpSet, "true")],
        constraints = [requiresExpr("true", "tlsBackend", "openssl")]),
      newEnumVariant("tlsBackend", ["openssl", "boringssl"]),
      newBoolVariant("nativeTls",
        contributions = [contribution(vpDefault, "false")],
        constraints = [conflictsExpr("true", "tlsBackend", "openssl")])]
    let sol = solveVariants(variants)

    # 1. enableTLS keeps its set value.
    check sol.assignments["enableTLS"] == "true"
    # 2. The require pins tlsBackend.
    check sol.assignments["tlsBackend"] == "openssl"
    # 3. nativeTls=false leaves the conflict dormant, so the require
    #    can still hold.
    check sol.assignments["nativeTls"] == "false"
    # 4. Every variant resolved.
    check sol.assignments.len == 3

  test "scenario 4: mixed kinds — bool + enum + string":
    let variants = [
      newBoolVariant("enableDebug",
        contributions = [contribution(vpSet, "true")]),
      newEnumVariant("targetTriple",
        ["x86_64-linux-gnu", "aarch64-linux-gnu", "wasm32-unknown-unknown"],
        contributions = [contribution(vpDefault, "x86_64-linux-gnu")]),
      VariantDecl(
        name: "logSink",
        kind: vkString,
        allowedValues: @["stderr", "file", "syslog"],
        contributions: @[contribution(vpOverride, "syslog")])]
    let sol = solveVariants(variants)

    # 1. Bool variant respects the set value.
    check sol.assignments["enableDebug"] == "true"
    # 2. Enum default holds.
    check sol.assignments["targetTriple"] == "x86_64-linux-gnu"
    # 3. String override wins.
    check sol.assignments["logSink"] == "syslog"
    # 4. All three variants present.
    check sol.assignments.len == 3
