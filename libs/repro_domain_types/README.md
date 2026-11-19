# repro_domain_types

Representative fixed-schema Reprobuild persistent/wire types for the M6
foundation gate. Encoding uses a minimal deterministic SSZ-like binary envelope
facade with explicit magic, type id, and version tags, plus the local `cbor`
subset for dynamic metadata fields.

This is not the long-term production SSZ/CBOR implementation.

`repro_domain_types/nimble_index` is the Nimble package index's objects (root,
shard, name map, origin events): domain types, an SSZ wire mirror whose every
list and text is bounded, the RBSZ-framed canonical codec (decode, validate,
re-encode and compare), navigator-style partial access over a borrowed or
memory-mapped buffer, and a deterministic text view. It is not re-exported by
`repro_domain_types`, so only its users link the SSZ library.
