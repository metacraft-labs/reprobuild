// reprobuild.hcr.reference-corpus fixture: llvm-jitlink-lld
// Concat output section placement surface.
#pragma once
namespace lld_fixture {
inline unsigned concat_output_alignment(unsigned inputAlignment) {
  return inputAlignment == 0 ? 1 : inputAlignment;
}
}
