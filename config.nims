switch("styleCheck", "hint")
switch("path", "libs/repro_core/src")
switch("path", "libs/repro_platform/src")
switch("path", "libs/repro_diagnostics/src")
switch("path", "libs/repro_cli_support/src")
switch("path", "libs/blake3/src")
switch("path", "libs/xxh3/src")
switch("path", "libs/gxhash/src")
switch("path", "libs/repro_hash/src")
switch("path", "libs/cbor/src")
switch("path", "libs/repro_domain_types/src")

import std/[os, strutils]

proc firstExistingPrefix(candidates: openArray[string]; header: string;
                         dylibNames: openArray[string]): string =
  for prefix in candidates:
    if prefix.len == 0:
      continue
    if not fileExists(prefix / header):
      continue
    for dylibName in dylibNames:
      if fileExists(prefix / "lib" / dylibName):
        return prefix
  ""

proc nixPrefix(namePattern, header: string; dylibNames: openArray[string]): string =
  let cmd = "find /nix/store -maxdepth 1 -type d -name '" & namePattern &
    "' 2>/dev/null | sort"
  let result = gorgeEx(cmd)
  if result.exitCode != 0:
    return ""
  for line in result.output.splitLines:
    let prefix = line.strip()
    if prefix.len == 0:
      continue
    if fileExists(prefix / header):
      for dylibName in dylibNames:
        if fileExists(prefix / "lib" / dylibName):
          return prefix
  ""

let blake3Prefix = block:
  let direct = firstExistingPrefix(
    [getEnv("BLAKE3_PREFIX"), "/opt/homebrew/opt/blake3", "/usr/local/opt/blake3"],
    "include/blake3.h",
    ["libblake3.dylib", "libblake3.so", "libblake3.a"])
  if direct.len > 0: direct
  else: nixPrefix("*-libblake3-*", "include/blake3.h",
                  ["libblake3.dylib", "libblake3.so", "libblake3.a"])

if blake3Prefix.len > 0:
  switch("passC", "-I" & blake3Prefix / "include")
  switch("passL", "-L" & blake3Prefix / "lib")
  switch("passL", "-lblake3")

let xxhashPrefix = block:
  let direct = firstExistingPrefix(
    [getEnv("XXHASH_PREFIX"), "/opt/homebrew/opt/xxhash", "/usr/local/opt/xxhash"],
    "include/xxhash.h",
    ["libxxhash.dylib", "libxxhash.so", "libxxhash.a"])
  if direct.len > 0: direct
  else: nixPrefix("*-xxHash-*", "include/xxhash.h",
                  ["libxxhash.dylib", "libxxhash.so", "libxxhash.a"])

if xxhashPrefix.len > 0:
  switch("passC", "-I" & xxhashPrefix / "include")
  switch("passL", "-L" & xxhashPrefix / "lib")
  switch("passL", "-lxxhash")
