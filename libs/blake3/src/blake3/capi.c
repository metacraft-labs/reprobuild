#include <stddef.h>
#include <stdint.h>
#include <blake3.h>

void repro_blake3_hash(const void *input, size_t input_len, uint8_t out[32]) {
  blake3_hasher hasher;
  blake3_hasher_init(&hasher);
  blake3_hasher_update(&hasher, input, input_len);
  blake3_hasher_finalize(&hasher, out, 32);
}

const char *repro_blake3_version(void) {
  return blake3_version();
}
