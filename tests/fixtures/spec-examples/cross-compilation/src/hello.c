/*
 * Cross-compilation worked example — trivial C program.
 *
 * Reprobuild-Standard-Library §"Worked Example: Cross-Compilation"
 * and Configurable-System §"Worked Example: Cross-Compilation" both
 * describe the variant-driven cross-toolchain selection. This source
 * file is intentionally minimal: it exists only to demonstrate that
 * the same recipe builds a host-native binary OR an aarch64-linux-gnu
 * binary depending on the `targetTriple` variant the workspace
 * resolves.
 */

#include <stdio.h>

int main(void) {
  puts("hello from a cross-compiled binary");
  return 0;
}
