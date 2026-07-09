// reprobuild.hcr.reference-corpus fixture: wild
// Symbol-diff predicate used by the fixture reference corpus.
pub fn symbol_changed(old_addr: u64, new_addr: u64) -> bool {
    old_addr != new_addr
}
