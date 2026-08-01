// reprobuild.hcr.reference-corpus fixture: llvm-jitlink-lld
// lld ELF relocation processing placeholder.
namespace lld_fixture {
int elf_relocation_action(int relocationKind) {
  return relocationKind == 0 ? 0 : 1;
}
}
