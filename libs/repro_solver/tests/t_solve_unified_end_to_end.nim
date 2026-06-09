## ``t_solve_unified_end_to_end`` — Spec-Implementation M2c unified
## driver end-to-end test.
##
## Builds synthetic variant + package registries that exercise every
## M2c encoding rule together, runs each through ``solve`` (the
## unified driver), and verifies the returned ``UnifiedSolution``
## carries the expected assignments AND package versions.
##
## Scenarios:
##
## 1. **Pure variants.** Only variants — no packages. The unified
##    driver matches ``solveVariants`` for this case.
## 2. **Pure packages.** Only packages — no variants. The unified
##    driver concretizes versions through the same encoding.
## 3. **Mixed.** A variant gates a package version range; both
##    surfaces land in the solution.
## 4. **Variant forces a downgrade.** A variant trigger activates a
##    range that excludes the otherwise-preferred version.

import std/[tables, unittest]

import repro_solver/variant_encoder
import repro_solver/version_encoder
import repro_solver/solver_api

suite "unified solve end-to-end":
  test "scenario 1: pure variants — no packages":
    let variants = [
      newBoolVariant("enableTLS",
        contributions = [contribution(vpDefault, "false")]),
      newEnumVariant("compiler", ["gcc", "clang"],
        contributions = [contribution(vpDefault, "gcc")])]
    let sol = solve(variants, [])

    # 1. Variant defaults land.
    check sol.variants["enableTLS"] == "false"
    check sol.variants["compiler"] == "gcc"
    # 2. No packages in the solution.
    check sol.packages.len == 0
    # 3. Solver proved optimality.
    check sol.optimal

  test "scenario 2: pure packages — no variants":
    let nim = newPackage("nim", versions = ["2.0.0", "2.2.4"])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newDependency("nim", ">=2.2 <3.0")])
    let sol = solve([], [nim, app])

    # 1. The range pinned nim to the satisfying version.
    check sol.packages["nim"] == "2.2.4"
    # 2. App resolved to its sole version.
    check sol.packages["app"] == "0.1.0"
    # 3. No variants in the solution.
    check sol.variants.len == 0

  test "scenario 3: mixed — variant gates package range":
    # ``enableTLS=true`` activates an openssl dependency at >=3.0.
    let enableTls = newBoolVariant("enableTLS",
      contributions = [contribution(vpSet, "true")])
    let openssl = newPackage("openssl",
      versions = ["1.1.0", "3.0.0", "3.1.0"])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newConditionalDependency(
        "openssl", ">=3.0", "enableTLS", "true")])
    let sol = solve([enableTls], [openssl, app])

    # 1. The variant resolved.
    check sol.variants["enableTLS"] == "true"
    # 2. The gated constraint forces openssl >= 3.0.
    check sol.packages["openssl"] in ["3.0.0", "3.1.0"]
    # 3. App resolved.
    check sol.packages["app"] == "0.1.0"
    # 4. Both surfaces in the solution.
    check sol.variants.len == 1
    check sol.packages.len == 2

  test "scenario 4: variant choice forces a package downgrade":
    # ``legacyMode=true`` activates a constraint that pins nim to the
    # 1.x line; with no nim 2.x choice, the solver must "downgrade"
    # nim from the otherwise-preferred 2.2.4.
    let legacyMode = newBoolVariant("legacyMode",
      contributions = [contribution(vpSet, "true")])
    let nim = newPackage("nim",
      versions = ["1.6.0", "2.0.0", "2.2.4"])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newConditionalDependency(
        "nim", "<2.0", "legacyMode", "true")])
    let sol = solve([legacyMode], [nim, app])

    # 1. The variant was set true.
    check sol.variants["legacyMode"] == "true"
    # 2. nim is forced to the only <2.0 version.
    check sol.packages["nim"] == "1.6.0"
    # 3. App resolved.
    check sol.packages["app"] == "0.1.0"
    # 4. Solver proved optimality.
    check sol.optimal
