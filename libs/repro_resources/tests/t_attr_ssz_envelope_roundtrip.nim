## Typed-Extension-Interfaces M1a: the attribute record ``T`` a provider
## registers via ``registerExtension[T](typeId)`` crosses the
## provider<->client boundary as a **versioned SSZ envelope**
## (``[u16le version][ssz-framed record]``) — NOT ``std/json``. This test
## pins that seam end-to-end:
##
##   * a record exercising every supported field kind (``string`` +
##     ``seq[string]`` + integer + ``bool`` + ``enum``) round-trips
##     through ``marshalAttrs`` / ``unmarshalAttrs`` (the exact
##     registry seam ``ResourceInstance`` marshalling uses) EQUAL to the
##     original;
##   * the wire bytes start with the ``u16le`` envelope version (== 1),
##     and specifically are NOT an ASCII ``{`` — proving no ``std/json``
##     is on the path;
##   * a wrong version byte is rejected (fails closed).
##
## Spec cite: Provider-Runtime-Protocol-v1.md §5 / Incremental-
## Invalidation.md ("Binary formats from Reprobuild domain types"); the
## M1a Verification ``t_attr_ssz_envelope_roundtrip``.

import std/unittest

import repro_project_dsl
import repro_project_dsl/attr_ssz
import repro_resources/marshal

type
  Flavour = enum
    fVanilla
    fChocolate
    fStrawberry

  ScoopAttrs = object
    ## Flat record covering every supported SSZ attribute field kind.
    name*: string
    toppings*: seq[string]
    count*: int
    chilled*: bool
    flavour*: Flavour

suite "t_attr_ssz_envelope_roundtrip":

  setup:
    registerExtension[ScoopAttrs]("rt.scoop")

  test "record round-trips EQUAL through marshalAttrs / unmarshalAttrs":
    let original = ScoopAttrs(
      name: "double-cone",
      toppings: @["sprinkles", "fudge", "nuts"],
      count: 3,
      chilled: true,
      flavour: fStrawberry)
    let box = TypedExtensionBox[ScoopAttrs](
      typeId: "rt.scoop", val: original)

    let payload = marshalAttrs(box)
    let back = unmarshalAttrs("rt.scoop", payload)

    check back.typeId == "rt.scoop"
    check TypedExtensionBox[ScoopAttrs](back).val == original

  test "the envelope is a u16le version (==1), NOT a JSON object":
    let original = ScoopAttrs(
      name: "x", toppings: @["a"], count: -7, chilled: false,
      flavour: fChocolate)
    # Encode the raw envelope so we can inspect the leading bytes.
    let bytes = encodeAttrEnvelope(original)

    # First two bytes are the u16le framing version == AttrEnvelopeVersion.
    check bytes.len >= 2
    let version = uint16(bytes[0]) or (uint16(bytes[1]) shl 8)
    check version == AttrEnvelopeVersion
    check AttrEnvelopeVersion == 1'u16

    # Prove there is no std/json on the path: a JSON object would begin
    # with an ASCII '{' (0x7B). The SSZ envelope begins with 0x01 0x00.
    check bytes[0] != byte('{')
    check bytes[0] == 1'u8
    check bytes[1] == 0'u8

    # Negative integers survive the two's-complement projection too.
    let back = decodeAttrEnvelope[ScoopAttrs](bytes)
    check back == original

  test "a wrong envelope version is rejected (fails closed)":
    let original = ScoopAttrs(
      name: "y", toppings: @[], count: 0, chilled: true, flavour: fVanilla)
    var bytes = encodeAttrEnvelope(original)
    check bytes.len >= 2
    # Corrupt the version word to an unsupported value.
    bytes[0] = 99'u8
    expect AttrEnvelopeError:
      discard decodeAttrEnvelope[ScoopAttrs](bytes)
