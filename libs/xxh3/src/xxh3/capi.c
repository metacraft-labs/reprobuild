#include <stddef.h>
#include <stdint.h>
#include <xxhash.h>

uint64_t repro_xxh3_64(const void *input, size_t input_len) {
  return XXH3_64bits(input, input_len);
}

uint64_t repro_xxh3_64_seeded(const void *input, size_t input_len, uint64_t seed) {
  return XXH3_64bits_withSeed(input, input_len, seed);
}
