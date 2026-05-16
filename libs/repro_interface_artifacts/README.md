# repro_interface_artifacts

M7 interface artifact and provider compile helpers.

This library persists project interface and provider compile records in a
minimal fixed-schema binary envelope that follows the M6 binary-first policy
and reuses `repro_core/codec` primitives plus `repro_hash` domain-separated
BLAKE3 fingerprints. The format is intentionally narrow for M7; it is not yet
the final SSZ/status-im integration.
