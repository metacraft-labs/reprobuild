## `DEP_<NAME>_PREFIX` names the prefix that holds the library
## (reprobuild-pm Package-Model.md §"Environment-provided library prefixes").
##
## WHY. A realization can carry several prefixes: a Nix package realizes
## every output, and its first is often `-bin`. Measured 2026-11-03 at
## reprobuild a9cbaaca36 on high-mem-server: native `repro build .#apps`
## handed the `-d:ssl` images `DEP_OPENSSL_PREFIX=…-openssl-3.6.0-bin`,
## which holds no `libssl`, and `config.nims` stopped all three ("holds no
## libssl"). The library sat in the `out` output, the second prefix. With
## "the first prefix with a lib/ directory" the next run was handed
## `…-openssl-3.6.0-debug`, whose `lib/` holds only `debug/`: a prefix
## counts when its `lib/` or `lib64/` holds a library file itself.
##
## HOW. Real directories in a temp dir, shaped like a multi-output store
## package, the environment arm's prefix and a sibling's target mirror.
## No mocks.

import std/[os, tempfiles, unittest]

import repro_cli_support

suite "DEP_<NAME>_PREFIX names the prefix that holds the library":

  test "a multi-output realization names its library output, not -bin":
    let root = createTempDir("dep-prefix-multi-", "")
    defer: removeDir(root)
    let binOut = root / "aaaa-openssl-3.6.0-bin"
    let libOut = root / "bbbb-openssl-3.6.0"
    let devOut = root / "cccc-openssl-3.6.0-dev"
    let debugOut = root / "dddd-openssl-3.6.0-debug"
    createDir(binOut / "bin")
    createDir(debugOut / "lib" / "debug" / ".build-id" / "ab")
    writeFile(debugOut / "lib" / "debug" / ".build-id" / "ab" / "cd.debug", "")
    createDir(devOut / "include")
    createDir(devOut / "lib" / "pkgconfig")
    writeFile(devOut / "lib" / "pkgconfig" / "openssl.pc", "")
    createDir(libOut / "lib")
    writeFile(libOut / "lib" / "libssl.so.3", "")
    check depLibraryPrefix(@[binOut, debugOut, devOut, libOut]) == libOut

  test "lib64 counts as a library directory":
    let root = createTempDir("dep-prefix-lib64-", "")
    defer: removeDir(root)
    createDir(root / "a" / "bin")
    createDir(root / "b" / "lib64")
    writeFile(root / "b" / "lib64" / "libz.a", "")
    check depLibraryPrefix(@[root / "a", root / "b"]) == root / "b"

  test "a single prefix is named as it is":
    let root = createTempDir("dep-prefix-single-", "")
    defer: removeDir(root)
    createDir(root / "usr" / "lib")
    writeFile(root / "usr" / "lib" / "libsqlite3.so.0", "")
    check depLibraryPrefix(@[root / "usr"]) == root / "usr"

  test "with no library directory anywhere, the first prefix (the old rule)":
    let root = createTempDir("dep-prefix-none-", "")
    defer: removeDir(root)
    createDir(root / "a")
    createDir(root / "b")
    check depLibraryPrefix(@[root / "a", root / "b"]) == root / "a"
    check depLibraryPrefix(@[]) == ""
