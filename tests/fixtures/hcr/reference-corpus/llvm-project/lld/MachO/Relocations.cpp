// reprobuild.hcr.reference-corpus fixture: llvm-jitlink-lld
// lld Mach-O relocation processing placeholder.
namespace lld_fixture {
int macho_relocation_action(int relocationKind) {
  return relocationKind == 0 ? 0 : 1;
}
}
