## ``t_variant_encoder_enum_universe`` — Spec-Implementation M2b
## encoder unit test.
##
## Verifies that an enum variant with three values emits exactly three
## ``variant_value`` universe facts plus a cardinality constraint that
## forces a single ``variant_assigned`` per variant. This is the
## encoder's atomic shape — every other rule predicates over the
## universe + cardinality pair, so a regression here breaks every
## subsequent encoding step.

import std/[strutils, unittest]

import repro_solver/variant_encoder

suite "variant_encoder: enum universe":
  test "three-value enum emits three universe facts plus cardinality":
    let v = newEnumVariant("compiler", ["gcc", "clang", "msvc"])
    let program = encodeVariants([v])

    # 1. Each enum value gets its own variant_value fact.
    check program.contains("variant_value(\"compiler\", \"gcc\").")
    check program.contains("variant_value(\"compiler\", \"clang\").")
    check program.contains("variant_value(\"compiler\", \"msvc\").")

    # 2. Exactly three universe facts (no duplicates).
    var universeCount = 0
    for line in program.splitLines():
      if line.strip().startsWith("variant_value(\"compiler\","):
        universeCount.inc
    check universeCount == 3

    # 3. Cardinality constraint locks in exactly-one selection.
    check program.contains(
      "{ variant_assigned(\"compiler\", X) : " &
      "variant_value(\"compiler\", X) } = 1.")

    # 4. The #show directive scopes the model to variant_assigned only.
    check program.contains("#show variant_assigned/2.")

  test "encodeUniverseFacts isolated helper preserves declaration order":
    let v = newEnumVariant("tlsBackend", ["openssl", "boringssl", "rustls"])
    let facts = encodeUniverseFacts(v)
    let lines = facts.splitLines()

    check lines.len == 3
    check lines[0] == "variant_value(\"tlsBackend\", \"openssl\")."
    check lines[1] == "variant_value(\"tlsBackend\", \"boringssl\")."
    check lines[2] == "variant_value(\"tlsBackend\", \"rustls\")."
