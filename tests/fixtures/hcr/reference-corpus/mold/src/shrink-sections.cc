// reprobuild.hcr.reference-corpus fixture: mold
// Keeps a deterministic section-shrinking decision for fixture validation.
namespace mold_fixture {
bool can_shrink_section(int liveBytes, int allocatedBytes) {
  return liveBytes >= 0 && liveBytes < allocatedBytes;
}
}
