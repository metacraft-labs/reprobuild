## The interface extract runner gets an RPATH to the darwin release's own
## `libclingo.dylib` when the host has no clingo prefix (reprobuild#505).
##
## WHY. The darwin release archive ships `lib/libclingo.dylib` beside
## `bin/reprobuild`, and the engine reaches it through its `@loader_path/../lib`
## LC_RPATH. The extract runner is linked later from a temporary directory, so
## none of that rpath reaches it. On the macOS arm64 runner its module-init
## dlopen of `@rpath/libclingo.dylib` aborted with
## `could not load: @rpath/libclingo.dylib`, and the TermAssert dev-env step
## failed before any build ran. The Linux archive is covered by
## `portableReleaseRpathFlags`; this file pins the darwin counterpart.
##
## Asserts, on a real temporary release layout:
##   1. a darwin target with `lib/libclingo.dylib` gets exactly one
##      `-Wl,-rpath,<release>/lib` flag (ld64 takes one per directory);
##   2. a darwin target whose release has no libclingo gets no flag;
##   3. a Linux target gets none here (the Linux path is separate);
##   4. an empty engine path gets none.
##
## Falsifiability: before the fix `releaseClingoRpathFlags` did not exist, so
## this file did not compile. The darwin-only leg runs for real only on a macOS
## host; on Linux the function is driven with `rltDarwin`, which is what the
## Darwin argv shape depends on.
##
## MOCK POLICY - none. A real directory tree and the real `fileExists`; the
## target is a parameter, so the darwin argv shape is checked on any host.

import std/[os, tempfiles, unittest]

import repro_interface_artifacts

proc isFile(path: string): bool =
  fileExists(path)

suite "darwin release clingo rpath for the extract runner":

  test "a darwin release with libclingo.dylib gets its lib dir as rpath":
    let root = createTempDir("repro-darwin-release-", "")
    defer: removeDir(root)
    let bin = root / "bin"
    let lib = root / "lib"
    createDir(bin)
    createDir(lib)
    writeFile(bin / "reprobuild", "engine")
    writeFile(lib / "libclingo.dylib", "clingo")
    let flags = releaseClingoRpathFlags(bin / "reprobuild", rltDarwin, isFile)
    check flags == @["--passL:-Wl,-rpath," & lib]

  test "a darwin release without libclingo adds no rpath":
    let root = createTempDir("repro-darwin-release-empty-", "")
    defer: removeDir(root)
    createDir(root / "bin")
    createDir(root / "lib")
    writeFile(root / "bin" / "reprobuild", "engine")
    check releaseClingoRpathFlags(root / "bin" / "reprobuild", rltDarwin,
      isFile) == newSeq[string]()

  test "the Linux target is left to the portable-release path":
    let root = createTempDir("repro-linux-release-", "")
    defer: removeDir(root)
    createDir(root / "bin")
    createDir(root / "lib")
    writeFile(root / "bin" / "reprobuild", "engine")
    writeFile(root / "lib" / "libclingo.dylib", "clingo")
    check releaseClingoRpathFlags(root / "bin" / "reprobuild", rltLinux,
      isFile) == newSeq[string]()

  test "an empty engine path adds no rpath":
    check releaseClingoRpathFlags("", rltDarwin, isFile) == newSeq[string]()
