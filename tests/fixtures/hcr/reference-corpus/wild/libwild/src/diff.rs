// reprobuild.hcr.reference-corpus fixture: wild
// Minimal object/section diff model for incremental linking metadata.
pub fn changed_sections(old_hash: u64, new_hash: u64) -> bool {
    old_hash != new_hash
}
