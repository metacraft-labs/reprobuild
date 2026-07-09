// reprobuild.hcr.reference-corpus fixture: llvm-jitlink-lld
// lld ELF thunk planning placeholder.
namespace lld_fixture {
bool elf_needs_thunk(long delta, long limit) {
  return delta > limit || delta < -limit;
}
}
