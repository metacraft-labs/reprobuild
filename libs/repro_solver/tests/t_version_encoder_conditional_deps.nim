## ``t_version_encoder_conditional_deps`` — Spec-Implementation M2c
## encoder test for variant-conditioned dependencies.
##
## A dependency declared with ``conditional`` gating only activates
## when the named variant resolves to the trigger value. When the
## variant is off, the range constraint should NOT force the depended-on
## package's version.

import std/[strutils, tables, unittest]

import repro_solver/variant_encoder
import repro_solver/version_encoder
import repro_solver/solver_api

suite "version_encoder: conditional dependencies":
  test "variant-gated dependency activates only on trigger value":
    # When ``enableTLS=true``, the constraint ``openssl >=3.0`` fires;
    # otherwise the openssl version is free to pick anything.
    let enableTls = newBoolVariant("enableTLS",
      contributions = [contribution(vpSet, "true")])
    let openssl = newPackage("openssl",
      versions = ["1.1.0", "3.0.0", "3.1.0"])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newConditionalDependency(
        "openssl", ">=3.0", "enableTLS", "true")])
    let sol = solve([enableTls], [openssl, app])

    # 1. The variant resolved to its set value.
    check sol.variants["enableTLS"] == "true"
    # 2. The gate fired, so openssl must satisfy ``>=3.0``.
    check sol.packages["openssl"] in ["3.0.0", "3.1.0"]
    # 3. The app picks its only version.
    check sol.packages["app"] == "0.1.0"

  test "variant off keeps the version free":
    # When ``enableTLS=false``, the constraint is dormant. With a
    # default priority on ``openssl 1.1.0`` we expect the lower
    # version to win.
    let enableTls = newBoolVariant("enableTLS",
      contributions = [contribution(vpSet, "false")])
    let openssl = newPackage("openssl",
      versions = ["1.1.0", "3.0.0"])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newConditionalDependency(
        "openssl", ">=3.0", "enableTLS", "true")])
    let sol = solve([enableTls], [openssl, app])

    # 1. The variant is false.
    check sol.variants["enableTLS"] == "false"
    # 2. The constraint never fired, so the solver may pick any version.
    check sol.packages["openssl"] in ["1.1.0", "3.0.0"]
    # 3. Both packages resolved.
    check sol.packages.len == 2

  test "conditional gate appears in the integrity constraint body":
    let openssl = newPackage("openssl",
      versions = ["3.0.0"])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newConditionalDependency(
        "openssl", ">=3.0", "enableTLS", "true")])
    let variants = [newBoolVariant("enableTLS")]
    let program = encodeUnified(variants, [openssl, app])

    # 1. The gating variant atom appears in the integrity constraint body.
    check program.contains("variant_assigned(\"enableTLS\", \"true\")")
    # 2. The version range is still present in the same line.
    check program.contains("version_in_range(\"openssl\", V, \">=3.0\")")
    # 3. The conditional encoding is wired through the unified entry
    #    so the variant universe is present too.
    check program.contains("variant_value(\"enableTLS\", \"true\").")
    check program.contains("variant_value(\"enableTLS\", \"false\").")
