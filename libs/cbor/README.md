# cbor

A CBOR implementation for RFC 8949, plus a reader for the diagnostic
notation the RFCs publish their examples in.

## What it covers

Every major type, including the ones this library used to be missing:
negative integers, tags, bignums (tags 2 and 3, with decimal
conversion), simple values, and floats at all three widths with
half-precision conversion done on the bit pattern. Indefinite-length
strings, arrays and maps are decoded with their chunk boundaries kept,
so decoding and re-encoding a well-formed item reproduces it byte for
byte.

Encoding comes in two modes. `encodeItem` is faithful — it reproduces
what the item records, including map order, which is what a signed
protected header needs. `encodeDeterministic` applies RFC 8949 §4.2.1
core deterministic encoding: preferred argument serialization, the
shortest float that preserves the value, definite lengths, and map keys
in bytewise lexicographic order.

Decoding is fail-closed and every refusal carries a `CborErrorKind`
named after RFC 8949 Appendix F's own classification, with a message
that is not a substring of any other refusal's message. No allocation
is ever sized from a declared length before that length is compared
against the input that remains, and nesting is bounded.

`DynamicValue` is the older, smaller, string-keyed view. It is still
here and still the shape `repro_profile_intent` reads, but it no longer
has a parser of its own: `decode` runs the checked reader and then
projects, refusing anything the smaller type cannot hold.

## What it does not cover

Tag content semantics beyond bignums. Tags 0 and 1 are carried as a tag
over their content and are not turned into a time; tag 24's embedded
item is not decoded recursively by the decoder; tags 4, 5 and 30
(decimal fractions, bigfloats, rationals) have no interpretation.
There is no streaming interface — an item is decoded from, and encoded
into, a byte sequence in memory. There is no CDDL support, and the
diagnostic-notation reader has no writer to match it.

## Gates

* `tests/integration/t_cbor_rfc8949_vectors.nim` — all 81 rows of
  RFC 8949 Appendix A, both directions, plus RFC 8949 §4.2.1's ten
  published encodings and its worked eight-key sort order.
* `tests/integration/t_cbor_rfc8949_malformed.nim` — all 94 items of
  RFC 8949 Appendix F.1, each required to produce the exact refusal the
  RFC's own classification calls for.

Both parse a verbatim, sha256-pinned excerpt of the RFC rather than a
transcription of it.
