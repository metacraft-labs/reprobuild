## The two predicates the build-script run edge's environment rests on
## (`build_script_edges`): which variables would choose a C toolchain or
## linker ahead of the `CC`, `CXX` and `AR` the edge gives a script, and
## whether a compiler path is a system binary once its symbolic links are
## followed (refused on macOS, where the monitor cannot inject into one).
##
## That the selectors are removed from a real run edge, and that a script
## then compiles with the edge's compiler, is the integration case
## `tests/integration/t_rqe_cg5_build_script_cfg_and_links`. No mocks: the
## symbolic links are real ones to real system paths.
##
## Falsifying mutations (applied, observed to fail, reverted): checking a
## compiler path without following its symbolic links fails the second
## case; not matching the underscore spelling of a target triple fails the
## first.

import std/[os, tempfiles, unittest]

import repro_cargo_edge/build_script_edges

suite "the build-script run edge's toolchain":

  test "the variables that choose a toolchain ahead of CC":
    const target = "x86_64-unknown-linux-gnu"
    const host = "aarch64-apple-darwin"
    for name in ["TARGET_CC", "HOST_CC", "TARGET_CXX", "HOST_AR",
                 "TARGET_RANLIB", "CC_x86_64-unknown-linux-gnu",
                 "CC_x86_64_unknown_linux_gnu", "CXX_aarch64-apple-darwin",
                 "AR_aarch64_apple_darwin", "RANLIB_x86_64-unknown-linux-gnu",
                 "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER",
                 "CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER"]:
      checkpoint name
      check isToolchainSelector(name, target, host)
    for name in ["CC", "CXX", "AR", "CFLAGS", "CC_ENABLE_DEBUG_OUTPUT",
                 "AR_FLAGS", "CC_riscv64gc-unknown-none-elf",
                 "CARGO_TARGET_DIR", "RUSTC_LINKER"]:
      checkpoint name
      check not isToolchainSelector(name, target, host)

  test "a system compiler is found through a symbolic link":
    check isSystemCompiler("/usr/bin/cc")
    check isSystemCompiler("/bin/sh")
    let dir = createTempDir("cg5-syscc-", "")
    defer: removeDir(dir)
    require fileExists("/bin/sh")
    createSymlink("/bin/sh", dir / "cc")
    check isSystemCompiler(dir / "cc")
    writeFile(dir / "real-cc", "")
    check not isSystemCompiler(dir / "real-cc")
