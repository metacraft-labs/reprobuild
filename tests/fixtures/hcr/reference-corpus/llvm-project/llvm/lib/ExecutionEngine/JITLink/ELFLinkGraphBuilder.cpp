// reprobuild.hcr.reference-corpus fixture: llvm-jitlink-lld
// ELF object ingestion placeholder for LinkGraph metadata.
namespace llvm_fixture {
bool build_elf_link_graph(bool hasRelocations) {
  return hasRelocations;
}
}
