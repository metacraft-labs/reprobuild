// reprobuild.hcr.reference-corpus fixture: mold
// x86-64 relocation classification placeholder for the metadata corpus.
namespace mold_fixture {
int x86_64_relocation_class(int pcRelative) {
  return pcRelative != 0 ? 32 : 64;
}
}
