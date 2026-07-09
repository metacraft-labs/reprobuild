// reprobuild.hcr.reference-corpus fixture: wild
// Deterministic layout slot calculation for reference-corpus validation.
pub fn layout_slot(base: u64, ordinal: u64) -> u64 {
    base + ordinal * 32
}
