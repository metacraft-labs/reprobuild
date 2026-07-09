// reprobuild.hcr.reference-corpus fixture: mold
// Covers phase-separated scan/allocation/relocation pass ordering.
namespace mold_fixture {
int scan_pass_order(int sections, int relocations) {
  return sections * 10 + relocations;
}
}
