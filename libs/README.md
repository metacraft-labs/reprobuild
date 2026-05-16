# Reprobuild Libraries

Libraries expose reusable Nim APIs. Application entry points compose libraries
and must stay thin.

M6 foundation libraries include `repro_core`, `repro_hash`, native `blake3` and
`xxh3` bindings, an unavailable `gxhash` capability facade, a minimal `cbor`
subset, and representative `repro_domain_types` binary envelopes.
