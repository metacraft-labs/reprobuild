/*
 * repro_hcr_sha256.h — a self-contained SHA-256, for HLX-M7's
 * `codeHashBefore` / `codeHashAfter` / patch-bundle digest.
 *
 * WHY A HASH IS IMPLEMENTED HERE RATHER THAN CALLED.
 *
 * This header is included by `repro_hcr_agent.c`, which is compiled INTO the
 * target program — an arbitrary application the provider does not own. It may
 * not add a link dependency (no OpenSSL, no libcrypto, no libb2), and inside an
 * MCR-recorded process it must not call through libc entry points the recorder
 * has interposed. So the digest has to be local, dependency-free, and use no
 * syscalls: it is one `static` function over the caller's bytes.
 *
 * WHY SHA-256 AND NOT A CHEAP MIX.
 *
 * The protocol
 * (`codetracer-specs/Planned-Features/Hot-Code-Reloading-High-Level-Interfaces.md`
 * §7.2) names `codeHashBefore` / `codeHashAfter` as hashes of the code, and a
 * consumer's only defence against a fabricated one is being able to RECOMPUTE
 * it from bytes it obtained independently. That requires a named, standard,
 * widely implemented function — the gates recompute these digests with Python's
 * `hashlib`, which is a completely separate implementation. A bespoke 64-bit
 * mix would be checkable only against itself, which is the same as not being
 * checkable: a campaign that has repeatedly shipped literals where measurements
 * were expected does not get to grade its own hash.
 *
 * FIPS 180-4. Constants are the first 32 bits of the fractional parts of the
 * cube roots of the first 64 primes (`K`) and the square roots of the first 8
 * (`H0`), reproduced verbatim; the implementation is the standard one and is
 * checked against the two published test vectors in
 * `repro_hcr_sha256_selftest`, which the agent runs before it uses a digest for
 * anything. A hash function that silently computes the wrong thing would put a
 * plausible 32-byte value in a protocol field, which is precisely the failure
 * this whole design refuses to ship.
 */
#ifndef REPRO_HCR_SHA256_H
#define REPRO_HCR_SHA256_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define REPRO_HCR_SHA256_DIGEST_BYTES 32

typedef struct repro_hcr_sha256_ctx {
  uint32_t state[8];
  uint64_t bit_len;
  uint8_t block[64];
  size_t block_len;
} repro_hcr_sha256_ctx;

static const uint32_t repro_hcr_sha256_k[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu,
    0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u,
    0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u,
    0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u,
    0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
    0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u,
    0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u, 0x1e376c08u,
    0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu,
    0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u};

static uint32_t repro_hcr_sha256_rotr(uint32_t x, unsigned n) {
  return (x >> n) | (x << (32u - n));
}

static void repro_hcr_sha256_compress(repro_hcr_sha256_ctx *ctx,
                                      const uint8_t block[64]) {
  uint32_t w[64];
  uint32_t a, b, c, d, e, f, g, h;
  unsigned i;

  for (i = 0; i < 16; ++i) {
    w[i] = ((uint32_t)block[4 * i] << 24) | ((uint32_t)block[4 * i + 1] << 16) |
           ((uint32_t)block[4 * i + 2] << 8) | (uint32_t)block[4 * i + 3];
  }
  for (i = 16; i < 64; ++i) {
    uint32_t s0 = repro_hcr_sha256_rotr(w[i - 15], 7) ^
                  repro_hcr_sha256_rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 = repro_hcr_sha256_rotr(w[i - 2], 17) ^
                  repro_hcr_sha256_rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }

  a = ctx->state[0];
  b = ctx->state[1];
  c = ctx->state[2];
  d = ctx->state[3];
  e = ctx->state[4];
  f = ctx->state[5];
  g = ctx->state[6];
  h = ctx->state[7];

  for (i = 0; i < 64; ++i) {
    uint32_t s1 = repro_hcr_sha256_rotr(e, 6) ^ repro_hcr_sha256_rotr(e, 11) ^
                  repro_hcr_sha256_rotr(e, 25);
    uint32_t ch = (e & f) ^ ((~e) & g);
    uint32_t t1 = h + s1 + ch + repro_hcr_sha256_k[i] + w[i];
    uint32_t s0 = repro_hcr_sha256_rotr(a, 2) ^ repro_hcr_sha256_rotr(a, 13) ^
                  repro_hcr_sha256_rotr(a, 22);
    uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    uint32_t t2 = s0 + maj;
    h = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }

  ctx->state[0] += a;
  ctx->state[1] += b;
  ctx->state[2] += c;
  ctx->state[3] += d;
  ctx->state[4] += e;
  ctx->state[5] += f;
  ctx->state[6] += g;
  ctx->state[7] += h;
}

static void repro_hcr_sha256_init(repro_hcr_sha256_ctx *ctx) {
  ctx->state[0] = 0x6a09e667u;
  ctx->state[1] = 0xbb67ae85u;
  ctx->state[2] = 0x3c6ef372u;
  ctx->state[3] = 0xa54ff53au;
  ctx->state[4] = 0x510e527fu;
  ctx->state[5] = 0x9b05688cu;
  ctx->state[6] = 0x1f83d9abu;
  ctx->state[7] = 0x5be0cd19u;
  ctx->bit_len = 0;
  ctx->block_len = 0;
}

static void repro_hcr_sha256_update(repro_hcr_sha256_ctx *ctx,
                                    const void *data, size_t len) {
  const uint8_t *p = (const uint8_t *)data;
  size_t i;
  for (i = 0; i < len; ++i) {
    ctx->block[ctx->block_len++] = p[i];
    if (ctx->block_len == 64) {
      repro_hcr_sha256_compress(ctx, ctx->block);
      ctx->bit_len += 512;
      ctx->block_len = 0;
    }
  }
}

static void repro_hcr_sha256_final(repro_hcr_sha256_ctx *ctx,
                                   uint8_t out[REPRO_HCR_SHA256_DIGEST_BYTES]) {
  size_t i = ctx->block_len;
  unsigned j;

  ctx->bit_len += (uint64_t)ctx->block_len * 8u;
  ctx->block[i++] = 0x80u;
  if (i > 56) {
    while (i < 64) {
      ctx->block[i++] = 0x00u;
    }
    repro_hcr_sha256_compress(ctx, ctx->block);
    i = 0;
  }
  while (i < 56) {
    ctx->block[i++] = 0x00u;
  }
  for (j = 0; j < 8; ++j) {
    ctx->block[56 + j] = (uint8_t)((ctx->bit_len >> (56u - 8u * j)) & 0xFFu);
  }
  repro_hcr_sha256_compress(ctx, ctx->block);

  for (j = 0; j < 8; ++j) {
    out[4 * j] = (uint8_t)((ctx->state[j] >> 24) & 0xFFu);
    out[4 * j + 1] = (uint8_t)((ctx->state[j] >> 16) & 0xFFu);
    out[4 * j + 2] = (uint8_t)((ctx->state[j] >> 8) & 0xFFu);
    out[4 * j + 3] = (uint8_t)(ctx->state[j] & 0xFFu);
  }
}

static void repro_hcr_sha256(const void *data, size_t len,
                             uint8_t out[REPRO_HCR_SHA256_DIGEST_BYTES]) {
  repro_hcr_sha256_ctx ctx;
  repro_hcr_sha256_init(&ctx);
  repro_hcr_sha256_update(&ctx, data, len);
  repro_hcr_sha256_final(&ctx, out);
}

/*
 * Self-test against the two FIPS 180-4 example vectors. Returns 1 on success.
 *
 * The agent calls this BEFORE it puts a digest into a protocol field, and
 * refuses the patch if it fails. This is not defensive decoration: the failure
 * mode of a broken hash is a well-formed 32-byte value that no downstream
 * reader can tell from a correct one, and the whole point of recording
 * `codeHashBefore` / `codeHashAfter` is that they can be checked.
 */
static int repro_hcr_sha256_selftest(void) {
  static const uint8_t abc_expected[REPRO_HCR_SHA256_DIGEST_BYTES] = {
      0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40,
      0xde, 0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17,
      0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad};
  static const uint8_t empty_expected[REPRO_HCR_SHA256_DIGEST_BYTES] = {
      0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4,
      0xc8, 0x99, 0x6f, 0xb9, 0x24, 0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b,
      0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55};
  /* 448-bit message vector: exercises the two-block padding path, which the
   * one-block vectors above do not reach. */
  static const char two_block[] =
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
  static const uint8_t two_block_expected[REPRO_HCR_SHA256_DIGEST_BYTES] = {
      0x24, 0x8d, 0x6a, 0x61, 0xd2, 0x06, 0x38, 0xb8, 0xe5, 0xc0, 0x26,
      0x93, 0x0c, 0x3e, 0x60, 0x39, 0xa3, 0x3c, 0xe4, 0x59, 0x64, 0xff,
      0x21, 0x67, 0xf6, 0xec, 0xed, 0xd4, 0x19, 0xdb, 0x06, 0xc1};
  uint8_t got[REPRO_HCR_SHA256_DIGEST_BYTES];

  repro_hcr_sha256("abc", 3, got);
  if (memcmp(got, abc_expected, sizeof(got)) != 0) {
    return 0;
  }
  repro_hcr_sha256("", 0, got);
  if (memcmp(got, empty_expected, sizeof(got)) != 0) {
    return 0;
  }
  repro_hcr_sha256(two_block, sizeof(two_block) - 1, got);
  if (memcmp(got, two_block_expected, sizeof(got)) != 0) {
    return 0;
  }
  return 1;
}

#endif /* REPRO_HCR_SHA256_H */
