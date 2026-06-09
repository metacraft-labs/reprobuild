## ``t_version_encoder_universe`` — Spec-Implementation M2c encoder
## test for the package universe + cardinality emission.
##
## Verifies the ``package_version`` facts land one per declared
## candidate version and that the per-package cardinality choice rule
## locks exactly-one selection. Mirrors the M2b
## ``t_variant_encoder_enum_universe`` test pattern.

import std/[strutils, tables, unittest]

import repro_solver/version_encoder
import repro_solver/solver_api

suite "version_encoder: universe + cardinality":
  test "package universe emits one fact per version":
    let nim = newPackage("nim",
      versions = ["2.0.0", "2.2.0", "2.2.4"])
    let program = encodePackages([nim])

    # 1. Each declared version emits a ``package_version`` fact.
    check program.contains("package_version(\"nim\", \"2.0.0\").")
    check program.contains("package_version(\"nim\", \"2.2.0\").")
    check program.contains("package_version(\"nim\", \"2.2.4\").")
    # 2. The package atom itself is declared.
    check program.contains("package(\"nim\").")
    # 3. The activity seed lets the cardinality fire.
    check program.contains("package_active(\"nim\").")

  test "cardinality choice rule locks exactly-one selection":
    let p = newPackage("p", versions = ["1.0.0", "2.0.0"])
    let program = encodePackages([p])

    # 1. The cardinality form lands verbatim.
    check program.contains(
      "{ package_chosen(\"p\", V) : package_version(\"p\", V) } = 1 :- " &
      "package_active(\"p\").")
    # 2. Exactly one cardinality line for the package.
    var count = 0
    for line in program.splitLines():
      if line.contains("package_chosen(\"p\", V)") and
         line.contains("= 1"):
        inc count
    check count == 1
    # 3. End-to-end: the solver picks one version when given no
    #    dependency constraint.
    let sol = solve([], [p])
    check sol.packages["p"] in ["1.0.0", "2.0.0"]

  test "multiple packages each get their own universe block":
    let nim = newPackage("nim", versions = ["2.2.4"])
    let openssl = newPackage("openssl", versions = ["3.0.0", "3.1.0"])
    let program = encodePackages([nim, openssl])

    # 1. Both packages declared.
    check program.contains("package(\"nim\").")
    check program.contains("package(\"openssl\").")
    # 2. Each gets its own version facts.
    check program.contains("package_version(\"nim\", \"2.2.4\").")
    check program.contains("package_version(\"openssl\", \"3.0.0\").")
    check program.contains("package_version(\"openssl\", \"3.1.0\").")
    # 3. Each gets its own cardinality line.
    var nimCard = 0
    var sslCard = 0
    for line in program.splitLines():
      if line.contains("package_chosen(\"nim\", V)"): inc nimCard
      if line.contains("package_chosen(\"openssl\", V)"): inc sslCard
    check nimCard == 1
    check sslCard == 1
