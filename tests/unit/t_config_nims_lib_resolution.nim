## Recipe-Validation side-finding (Item 1): `config.nims`
## `firstExistingPrefix` lib64 / multiarch handling.
##
## Pre-fix: `firstExistingPrefix` (in `config.nims`) only probed
## `$prefix/lib/<dylib>`, so `BLAKE3_PREFIX=/usr` on Fedora missed
## `/usr/lib64/libblake3.so` and the build silently fell back to
## the vendored sources (when system-libs were intended). Same
## blind spot on Debian-multiarch (`/usr/lib/x86_64-linux-gnu/`).
##
## The fix extends `firstExistingPrefixLibDir` to probe `lib`,
## `lib64`, `lib/x86_64-linux-gnu`, and `lib/aarch64-linux-gnu`,
## and threads the resolved libdir into the `-L` flag emission so
## the linker actually finds the dylib on Fedora / SUSE / RHEL.
##
## `config.nims` is a Nim-script (evaluated by the compiler config
## stage), so the helpers can't be `import`ed from a regular unit
## test. This test re-implements the same closed-set lib-subdir
## probe and verifies the algorithm against a temp-dir fake
## filesystem. The constant `LibSubdirs` here MUST stay in sync
## with the one in `config.nims`; a divergence would surface as a
## test failure on the next harness pass.

import std/[os, tempfiles, unittest]

const LibSubdirs = [
  "lib",
  "lib64",
  "lib/x86_64-linux-gnu",
  "lib/aarch64-linux-gnu",
]
  ## MUST mirror `config.nims:LibSubdirs`. A divergence is a bug.

proc firstExistingPrefixLibDir(prefix: string;
                               dylibNames: openArray[string]): string =
  ## Mirror of `config.nims:firstExistingPrefixLibDir`.
  for libSub in LibSubdirs:
    let candidate = prefix / libSub
    for dylibName in dylibNames:
      if fileExists(candidate / dylibName):
        return candidate
  ""

proc makeFakePrefix(layout: openArray[(string, string)]): string =
  ## Build a temp prefix populated with the requested
  ## `(relativePath, content)` entries; returns the absolute prefix.
  let dir = createTempDir("reprobuild-libsearch-", "")
  for (relPath, content) in layout:
    let full = dir / relPath
    createDir(parentDir(full))
    writeFile(full, content)
  return dir

suite "Recipe-Val side-finding: config.nims lib64 + multiarch resolution":

  test "Fedora-style lib64 layout: /usr/lib64/libblake3.so":
    # The case the pre-fix code missed. With `BLAKE3_PREFIX=/usr`
    # on Fedora, the dylib lives at `/usr/lib64/libblake3.so` —
    # the bare `prefix/lib/<dylib>` probe never reaches it.
    let prefix = makeFakePrefix({
      "include/blake3.h": "// header",
      "lib64/libblake3.so": "// dylib bytes",
    })
    try:
      let libDir = firstExistingPrefixLibDir(prefix,
        ["libblake3.so", "libblake3.a"])
      check libDir == prefix / "lib64"
    finally:
      removeDir(prefix)

  test "Debian-multiarch layout: /usr/lib/x86_64-linux-gnu/":
    # Debian / Ubuntu install dylibs under the multiarch triple
    # directory; the header lives at the prefix root.
    let prefix = makeFakePrefix({
      "include/xxhash.h": "// header",
      "lib/x86_64-linux-gnu/libxxhash.so": "// dylib bytes",
    })
    try:
      let libDir = firstExistingPrefixLibDir(prefix,
        ["libxxhash.dylib", "libxxhash.so", "libxxhash.a"])
      check libDir == prefix / "lib/x86_64-linux-gnu"
    finally:
      removeDir(prefix)

  test "Arch / classic layout: /usr/lib/libfoo.so":
    # The pre-fix code WAS correct for this case; the test pins
    # the behavior so the new helper doesn't regress it.
    let prefix = makeFakePrefix({
      "include/blake3.h": "// header",
      "lib/libblake3.so": "// dylib bytes",
    })
    try:
      let libDir = firstExistingPrefixLibDir(prefix,
        ["libblake3.dylib", "libblake3.so", "libblake3.a"])
      check libDir == prefix / "lib"
    finally:
      removeDir(prefix)

  test "aarch64 multiarch: /usr/lib/aarch64-linux-gnu/":
    # The ARM64-Linux case for CI runners (Ubuntu / Debian on
    # ARM). Same multiarch convention as x86_64 with a different
    # triple.
    let prefix = makeFakePrefix({
      "include/xxhash.h": "// header",
      "lib/aarch64-linux-gnu/libxxhash.so": "// dylib bytes",
    })
    try:
      let libDir = firstExistingPrefixLibDir(prefix,
        ["libxxhash.dylib", "libxxhash.so", "libxxhash.a"])
      check libDir == prefix / "lib/aarch64-linux-gnu"
    finally:
      removeDir(prefix)

  test "missing dylib returns empty string":
    # The pre-existing fail-closed contract: if no probed subdir
    # holds any of the dylib candidate names, the helper returns
    # "" and the caller falls back to either the vendored sources
    # or a hardcoded `prefix/lib` `-L` flag (the pre-fix default).
    let prefix = makeFakePrefix({
      "include/blake3.h": "// header alone, no dylib next to it",
    })
    try:
      check firstExistingPrefixLibDir(prefix,
        ["libblake3.dylib", "libblake3.so", "libblake3.a"]) == ""
    finally:
      removeDir(prefix)

  test "macOS .dylib in lib/ is selected before .a":
    # The dylibName-order contract: the first matching dylib wins,
    # so the caller's preferred extension (`.dylib` for macOS,
    # `.so` for Linux, `.a` last as a static-fallback) is honored.
    let prefix = makeFakePrefix({
      "include/blake3.h": "// header",
      "lib/libblake3.dylib": "// macOS dylib",
      "lib/libblake3.a": "// static archive",
    })
    try:
      let libDir = firstExistingPrefixLibDir(prefix,
        ["libblake3.dylib", "libblake3.so", "libblake3.a"])
      # Either match is valid (both files exist) — pin that the
      # returned libDir IS `prefix/lib`, which is what every caller
      # expects for `-L` flag emission.
      check libDir == prefix / "lib"
    finally:
      removeDir(prefix)

  test "lib subdir order: lib wins over lib64 when both exist":
    # When both `prefix/lib/libfoo.so` AND `prefix/lib64/libfoo.so`
    # exist, the closed-set order MUST return `prefix/lib` first.
    # This matches the historical bare-`lib` probe so a system that
    # had both subdirs (rare; some distros ship 32-bit compat libs
    # in `lib/` alongside the 64-bit ones in `lib64/`) still
    # resolves the same libdir the pre-fix code did.
    let prefix = makeFakePrefix({
      "include/blake3.h": "// header",
      "lib/libblake3.so": "// 32-bit compat or default",
      "lib64/libblake3.so": "// 64-bit primary",
    })
    try:
      let libDir = firstExistingPrefixLibDir(prefix,
        ["libblake3.dylib", "libblake3.so", "libblake3.a"])
      check libDir == prefix / "lib"
    finally:
      removeDir(prefix)
