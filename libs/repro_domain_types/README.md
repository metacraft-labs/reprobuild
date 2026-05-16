# repro_domain_types

Representative fixed-schema Reprobuild persistent/wire types for the M6
foundation gate. Encoding uses a minimal deterministic SSZ-like binary envelope
facade with explicit magic, type id, and version tags, plus the local `cbor`
subset for dynamic metadata fields.

This is not the long-term production SSZ/CBOR implementation.
