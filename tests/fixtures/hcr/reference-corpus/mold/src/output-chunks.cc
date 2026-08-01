// reprobuild.hcr.reference-corpus fixture: mold
// Represents output chunk layout decisions consumed by HCR patch planning.
namespace mold_fixture {
int output_chunk_address(int base, int ordinal) {
  return base + ordinal * 16;
}
}
