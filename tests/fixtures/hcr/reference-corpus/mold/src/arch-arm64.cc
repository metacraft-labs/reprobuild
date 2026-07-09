// reprobuild.hcr.reference-corpus fixture: mold
// AArch64 branch range and relocation classification placeholder.
namespace mold_fixture {
const int arm64BranchBits = 26;
int arm64_relocation_class(int kind) {
  return kind == 1 ? arm64BranchBits : 0;
}
}
