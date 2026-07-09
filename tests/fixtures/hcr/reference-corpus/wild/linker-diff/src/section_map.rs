// reprobuild.hcr.reference-corpus fixture: wild
// Section-map comparison surface for structural linker-diff assertions.
pub fn section_map_key(object_index: u32, section_index: u32) -> u64 {
    ((object_index as u64) << 32) | section_index as u64
}
