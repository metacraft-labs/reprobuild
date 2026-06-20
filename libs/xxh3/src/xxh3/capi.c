#include <stddef.h>
#include <stdint.h>
#ifdef REPRO_VENDORED_HASH
#include "vendor/xxhash.h"
#else
#include <xxhash.h>
#endif

uint64_t repro_xxh3_64(const void *input, size_t input_len) {
  return XXH3_64bits(input, input_len);
}

uint64_t repro_xxh3_64_seeded(const void *input, size_t input_len, uint64_t seed) {
  return XXH3_64bits_withSeed(input, input_len, seed);
}
