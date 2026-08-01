// reprobuild.hcr.reference-corpus fixture: mold
// Captures the range-extension thunk planning surface.
namespace mold_fixture {
bool needs_thunk(long branchDistance, long branchLimit) {
  return branchDistance > branchLimit || branchDistance < -branchLimit;
}
}
