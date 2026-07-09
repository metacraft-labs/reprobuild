// reprobuild.hcr.reference-corpus fixture: llvm-jitlink-lld
// Minimal LinkGraph declaration surface for fixture validation.
#pragma once
namespace llvm_fixture {
struct LinkGraph {
  const char *name;
  unsigned symbolCount;
};
}
