#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#ifdef REPRO_VENDORED_HASH
#include "vendor/blake3.h"
#else
#include <blake3.h>
#endif

void repro_blake3_hash(const void *input, size_t input_len, uint8_t out[32]) {
  blake3_hasher hasher;
  blake3_hasher_init(&hasher);
  blake3_hasher_update(&hasher, input, input_len);
  blake3_hasher_finalize(&hasher, out, 32);
}

const char *repro_blake3_version(void) {
  return blake3_version();
}

void *repro_blake3_hasher_new(void) {
  blake3_hasher *hasher = malloc(sizeof(blake3_hasher));
  if (hasher != NULL) {
    blake3_hasher_init(hasher);
  }
  return hasher;
}

void repro_blake3_hasher_update(void *state, const void *input, size_t input_len) {
  blake3_hasher_update((blake3_hasher *)state, input, input_len);
}

void repro_blake3_hasher_finalize(void *state, uint8_t out[32]) {
  blake3_hasher_finalize((const blake3_hasher *)state, out, 32);
}

void repro_blake3_hasher_free(void *state) {
  free(state);
}
