// reprobuild.hcr.reference-corpus fixture: llvm-jitlink-lld
// Mach-O object ingestion placeholder for the HCR corpus.
namespace llvm_fixture {
bool build_macho_link_graph(bool hasTextSection) {
  return hasTextSection;
}
}
