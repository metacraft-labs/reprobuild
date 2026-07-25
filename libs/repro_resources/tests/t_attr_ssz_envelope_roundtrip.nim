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
import ssz_serialization

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

  StringListAttrs = object
    values: seq[string]

  FixedArrayWire = object
    values: array[3, uint16]

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

    # Pin the nested variable-size bulk-copy path that writes
    # ``List[List[byte]]`` and its canonical wire format.
    let canonical = StringListAttrs(values: @["ab", "C"])
    let canonicalBytes = encodeAttrEnvelope(canonical)
    check canonicalBytes == @[
      0x01'u8, 0x00,
      0x01, 0x00, 0x00, 0x00,
      0x0f, 0x00, 0x00, 0x00,
      0x04, 0x00, 0x00, 0x00,
      0x08, 0x00, 0x00, 0x00,
      0x0a, 0x00, 0x00, 0x00,
      0x61, 0x62, 0x43,
    ]
    check decodeAttrEnvelope[StringListAttrs](canonicalBytes) == canonical

    # A present-but-empty inner string reaches writeElements[byte] with a
    # zero-length openArray. This is the precise empty bulk-copy edge: it must
    # emit no payload bytes and must not take the address of value[0].
    let withEmptyItem = StringListAttrs(values: @[""])
    let withEmptyItemBytes = encodeAttrEnvelope(withEmptyItem)
    check withEmptyItemBytes == @[
      0x01'u8, 0x00,
      0x01, 0x00, 0x00, 0x00,
      0x08, 0x00, 0x00, 0x00,
      0x04, 0x00, 0x00, 0x00,
      0x04, 0x00, 0x00, 0x00,
    ]
    check decodeAttrEnvelope[StringListAttrs](withEmptyItemBytes) == withEmptyItem

    let empty = StringListAttrs(values: @[])
    let emptyBytes = encodeAttrEnvelope(empty)
    check emptyBytes == @[
      0x01'u8, 0x00,
      0x01, 0x00, 0x00, 0x00,
      0x04, 0x00, 0x00, 0x00,
      0x04, 0x00, 0x00, 0x00,
    ]
    check decodeAttrEnvelope[StringListAttrs](emptyBytes) == empty

    # The second bulk-copy caller serializes fixed-size arrays. Pin its byte
    # count and little-endian representation independently of the attr codec.
    let fixed = FixedArrayWire(values: [0x1234'u16, 0xabcd'u16, 0x0001'u16])
    let fixedBytes = SSZ.encode(fixed)
    check fixedBytes == @[
      0x34'u8, 0x12, 0xcd, 0xab, 0x01, 0x00,
    ]
    check SSZ.decode(fixedBytes, FixedArrayWire) == fixed

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
