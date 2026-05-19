## M58 gate: `integration_configurable_persistent_lookup`.
##
## Normative description:
##
##   Write an RBCG envelope; restructure source so a configurable
##   moves to a different scope while keeping its `@id`; reload and
##   verify the persisted value is recovered through explicit-id
##   match. Drop the `@id`; the same restructuring loses persistence
##   and falls back to default. Two configurables declaring the same
##   `@id` produce `EDuplicateId`; two current declarations resolving
##   to the same persisted entry produce `EAmbiguousLookup`.

import std/[unittest]
import repro_dsl_stdlib/configurables

suite "M58 persistent lookup":

  test "@id survives scope restructuring":
    # Phase 1: original layout — port lives under `legacyApi`.
    var portHandle: Configurable[int]
    let original = evalConfig:
      scope "legacyApi":
        config:
          ## API port.
          ## @id api-server-port
          port = 8080
        port.override 9876
        portHandle = port
    let envelope = encodeRbcg(original)
    check original.read(portHandle) == 9876

    # Phase 2: source has been refactored — port now lives under
    # `modernApi`. The @id directive keeps the persisted value
    # discoverable.
    var newPortHandle: Configurable[int]
    let restructured = evalConfig:
      decodeRbcgInto(currentContext(), envelope)
      scope "modernApi":
        config:
          ## API port (relocated).
          ## @id api-server-port
          port = 8080
        newPortHandle = port
    check restructured.read(newPortHandle) == 9876

  test "without @id, scope restructuring loses persistence":
    var portHandle: Configurable[int]
    let original = evalConfig:
      scope "legacyApi":
        config:
          ## API port.
          port = 8080
        port.override 9876
        portHandle = port
    let envelope = encodeRbcg(original)

    var newPortHandle: Configurable[int]
    let restructured = evalConfig:
      decodeRbcgInto(currentContext(), envelope)
      scope "modernApi":
        config:
          ## API port.
          port = 8080
        newPortHandle = port
    # Falls back to construction default because the scope-derived
    # name `modernApi.port` does not match the persisted
    # `legacyApi.port` and no @id was declared to bridge them.
    check restructured.read(newPortHandle) == 8080

  test "duplicate @id raises EDuplicateId":
    expect EDuplicateId:
      discard evalConfig:
        config:
          ## First.
          ## @id shared-name
          a = 1
        config:
          ## Second.
          ## @id shared-name
          b = 2

  test "two current declarations resolving to one persisted entry raises EAmbiguousLookup":
    # Original context has ONE configurable carrying both:
    # - scope-derived name "api.port"
    # - explicit id "api-server-port"
    var portHandle: Configurable[int]
    let original = evalConfig:
      scope "api":
        config:
          ## API port.
          ## @id api-server-port
          port = 8080
        port.override 9876
        portHandle = port
    let envelope = encodeRbcg(original)

    # New source has TWO configurables. The first matches the
    # persisted entry by @id; the second matches by scope-derived
    # name. Both resolve to the same persisted entry, which the
    # algorithm flags as ambiguous.
    expect EAmbiguousLookup:
      discard evalConfig:
        decodeRbcgInto(currentContext(), envelope)
        block:
          scope "renamed":
            config:
              ## New location.
              ## @id api-server-port
              port = 0
        block:
          scope "api":
            config:
              ## Old name still present.
              port = 0
