## Regression coverage for Windows system-hash mode.
##
## The hash wrappers must not compile gitignored
## `references/mold/third-party/...` sources merely because the target OS is
## Windows. In `REPROBUILD_USE_SYSTEM_HASH_LIBS=1` mode, Windows should compile
## only the wrapper `capi.c` files and rely on configured system include/lib
## prefixes.

import std/[os, osproc, strutils, unittest]

const RepoRoot = currentSourcePath().parentDir().parentDir().parentDir()

const Blake3Header = """
#ifndef BLAKE3_H
#define BLAKE3_H
#include <stddef.h>
#include <stdint.h>
typedef struct { uint64_t opaque[32]; } blake3_hasher;
void blake3_hasher_init(blake3_hasher *self);
void blake3_hasher_update(blake3_hasher *self, const void *input, size_t input_len);
void blake3_hasher_finalize(const blake3_hasher *self, uint8_t *out, size_t out_len);
const char *blake3_version(void);
#endif
"""

const XxhashHeader = """
#ifndef XXHASH_H
#define XXHASH_H
#include <stddef.h>
#include <stdint.h>
uint64_t XXH3_64bits(const void *input, size_t length);
uint64_t XXH3_64bits_withSeed(const void *input, size_t length, uint64_t seed);
#endif
"""

const FixtureSource = """
import ./libs/blake3/src/blake3
import ./libs/xxh3/src/xxh3

discard sizeof(Blake3Digest)
discard sizeof(Xxh3Digest)
"""

proc resetDir(path: string) =
  if dirExists(path):
    removeDir(path)
  createDir(path)

proc copySource(repoRelPath, scratchRoot: string) =
  let src = RepoRoot / repoRelPath
  let dst = scratchRoot / repoRelPath
  createDir(parentDir(dst))
  copyFile(src, dst)

proc copyScratchProjectSources(scratchRoot: string) =
  for relPath in [
    "config.nims",
    "libs/blake3/src/blake3.nim",
    "libs/blake3/src/blake3/capi.c",
    "libs/xxh3/src/xxh3.nim",
    "libs/xxh3/src/xxh3/capi.c",
  ]:
    copySource(relPath, scratchRoot)

proc writeFakePrefix(prefix, headerName, libName, header: string) =
  createDir(prefix / "include")
  createDir(prefix / "lib")
  writeFile(prefix / "include" / headerName, header)
  writeFile(prefix / "lib" / libName, "")

template withEnvVar(name, value: string; body: untyped) =
  let hadValue = existsEnv(name)
  let oldValue = getEnv(name)
  putEnv(name, value)
  try:
    body
  finally:
    if hadValue:
      putEnv(name, oldValue)
    else:
      delEnv(name)

suite "Windows system-hash mode":
  test "nim check does not compile vendored hash sources on Windows":
    let scratchRoot = RepoRoot / "build" / "test-tmp" /
      "windows-system-hash-mode"
    resetDir(scratchRoot)
    defer:
      if dirExists(scratchRoot):
        removeDir(scratchRoot)

    copyScratchProjectSources(scratchRoot)

    let blake3Prefix = scratchRoot / "fake-blake3"
    let xxhashPrefix = scratchRoot / "fake-xxhash"
    writeFakePrefix(blake3Prefix, "blake3.h", "libblake3.a", Blake3Header)
    writeFakePrefix(xxhashPrefix, "xxhash.h", "libxxhash.a", XxhashHeader)

    let fixturePath = scratchRoot / "hash_fixture.nim"
    writeFile(fixturePath, FixtureSource)

    let nimcache = scratchRoot / "nimcache"
    let cmd = quoteShellCommand(@[
      "nim", "check",
      "--os:windows",
      "--cpu:amd64",
      "--hints:off",
      "--warnings:off",
      "--nimcache:" & nimcache,
      fixturePath,
    ])

    withEnvVar("REPROBUILD_USE_SYSTEM_HASH_LIBS", "1"):
      withEnvVar("BLAKE3_PREFIX", blake3Prefix):
        withEnvVar("XXHASH_PREFIX", xxhashPrefix):
          let result = execCmdEx(cmd, workingDir = scratchRoot)
          check result.exitCode == 0
          if result.exitCode != 0:
            checkpoint(result.output)
          check "references" / "mold" notin result.output
