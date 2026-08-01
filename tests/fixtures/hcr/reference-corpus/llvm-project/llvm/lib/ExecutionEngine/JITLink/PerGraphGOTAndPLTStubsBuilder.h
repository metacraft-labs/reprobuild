// reprobuild.hcr.reference-corpus fixture: llvm-jitlink-lld
// GOT/PLT stub construction surface.
#pragma once
namespace llvm_fixture {
inline int got_plt_stub_count(int externalSymbols) {
  return externalSymbols < 0 ? 0 : externalSymbols;
}
}
