// reprobuild.hcr.reference-corpus fixture: wild
// Range-extension thunk predicate used by the fixture metadata.
pub fn needs_thunk(delta: i64, limit: i64) -> bool {
    delta > limit || delta < -limit
}
