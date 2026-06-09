## ``t_variant_encoder_bool_universe`` — Spec-Implementation M2b
## encoder unit test.
##
## Verifies that a bool variant emits the canonical two-value
## ``true``/``false`` universe plus its cardinality constraint.
## Bool variants are the most common shape in the spec examples
## (``enableTLS: variant bool = false`` etc.) so the universe must
## land verbatim regardless of whether the author supplied an
## ``allowedValues`` list.

import std/[strutils, unittest]

import repro_solver/variant_encoder

suite "variant_encoder: bool universe":
  test "bool variant always emits true/false universe":
    let v = newBoolVariant("enableTLS")
    let program = encodeVariants([v])

    # 1. The two-value universe is present.
    check program.contains("variant_value(\"enableTLS\", \"true\").")
    check program.contains("variant_value(\"enableTLS\", \"false\").")

    # 2. Cardinality constraint targets the bool variant.
    check program.contains(
      "{ variant_assigned(\"enableTLS\", X) : " &
      "variant_value(\"enableTLS\", X) } = 1.")

    # 3. Only the two universe facts — no spurious extras.
    var universeCount = 0
    for line in program.splitLines():
      if line.strip().startsWith("variant_value(\"enableTLS\","):
        universeCount.inc
    check universeCount == 2

  test "default contribution does not add to the universe":
    let v = newBoolVariant("hasNetwork",
      contributions = [contribution(vpDefault, "true")])
    let facts = encodeUniverseFacts(v)
    let lines = facts.splitLines()

    # 1. Still exactly two universe entries.
    check lines.len == 2
    # 2. The default value appears in the universe.
    check facts.contains("variant_value(\"hasNetwork\", \"true\").")
    # 3. The non-default value is still in the universe.
    check facts.contains("variant_value(\"hasNetwork\", \"false\").")
