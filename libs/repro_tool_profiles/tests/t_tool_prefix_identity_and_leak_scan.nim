## The pieces a shared tool prefix's portability rests on, each against the
## real filesystem:
##
##   * the staging-path leak scan finds the path in `/`, `\` and UTF-16LE
##     spellings, across a read-chunk boundary and in a symbolic link's
##     target, and finds nothing in a clean tree;
##   * the identity of a realized input: a sealed prefix's recorded key, the
##     Nix store, an incomplete record, and a host path;
##   * a build step's composite identity is complete only when every input
##     is, moves when an input's key moves, and does not depend on where an
##     input file sits on disk;
##   * a step declaration that cannot be realized portably is refused.
##
## No mocks: files are written to a temporary directory and read back by the
## code under test.

import std/[os, strutils, tempfiles, unittest]

import repro_binary_cache_client/cache_key
import repro_test_support/reasoned_skip
import repro_tool_profiles

proc utf16le(text: string): string =
  for ch in text:
    result.add(ch)
    result.add('\0')

suite "staging-path leak scan":

  test "a clean tree has no leaks":
    let root = createTempDir("repro-leak-clean-", "")
    defer: removeDir(root)
    createDir(root / "bin")
    writeFile(root / "bin" / "tool", "#!/bin/sh\necho clean\n")
    writeFile(root / "README", "prefix=.\n")
    check findStagingPathLeaks(root).len == 0
    refuseStagingPathLeaks(root, "clean")

  test "each spelling of the staging path is found and named":
    let root = createTempDir("repro-leak-spellings-", "")
    defer: removeDir(root)
    createDir(root / "etc")
    writeFile(root / "etc" / "slash.cfg", "home=" & root & "/lib\n")
    writeFile(root / "etc" / "backslash.cfg",
      "home=" & root.replace('/', '\\') & "\\lib\n")
    writeFile(root / "etc" / "wide.res", "\xff\xfe" & utf16le(root & "/x"))
    writeFile(root / "etc" / "widebs.res",
      utf16le(root.replace('/', '\\') & "\\x"))
    var found: seq[string]
    for leak in findStagingPathLeaks(root):
      found.add(leak.file & "=" & leak.spelling)
    check "etc/slash.cfg=slash" in found
    check "etc/backslash.cfg=backslash" in found
    check "etc/wide.res=utf16le-slash" in found
    check "etc/widebs.res=utf16le-backslash" in found
    var raised = false
    try:
      refuseStagingPathLeaks(root, "fixture")
    except StagingPathLeakError as err:
      raised = true
      check err.leaks.len == 4
      check "etc/slash.cfg" in err.msg
    check raised

  test "a path across a read-chunk boundary is still found":
    let root = createTempDir("repro-leak-chunk-", "")
    defer: removeDir(root)
    # The scan reads 1 MiB at a time; put the path so it straddles the first
    # boundary.
    let half = root.len div 2
    let padding = repeat('x', (1 shl 20) - half)
    writeFile(root / "big.bin", padding & root & "/tail")
    let leaks = findStagingPathLeaks(root)
    check leaks.len == 1
    check leaks[0].file == "big.bin"

  test "a symbolic link into the staging tree by absolute path is a leak":
    when defined(windows):
      skip("creating a symbolic link on Windows needs a privilege this " &
        "case cannot assume")
    else:
      let root = createTempDir("repro-leak-link-", "")
      defer: removeDir(root)
      createDir(root / "bin")
      writeFile(root / "bin" / "real", "x")
      createSymlink(root / "bin" / "real", root / "bin" / "absolute")
      createSymlink("real", root / "bin" / "relative")
      let leaks = findStagingPathLeaks(root)
      check leaks.len == 1
      check leaks[0].file == "bin/absolute"
      check leaks[0].spelling == "symlink-target"

suite "identity of a realized input":

  test "a sealed prefix names its recorded key, from any file inside it":
    let root = createTempDir("repro-input-identity-", "")
    defer: removeDir(root)
    let key = repeat('a', 64)
    createDir(root / "prefix" / "bin")
    writePrefixIdentityFile(root / "prefix", key, "")
    writeFile(root / "prefix" / "bin" / "cc", "x")
    let identity = realizedInputIdentity("cc", root / "prefix" / "bin" / "cc")
    check identity.keyHex == key
    check identity.incomplete.len == 0
    check realizedInputIdentity("cc", root / "prefix").keyHex == key

  test "a prefix sealed with an incomplete identity is an incomplete input":
    let root = createTempDir("repro-input-pending-", "")
    defer: removeDir(root)
    createDir(root / "prefix")
    writePrefixIdentityFile(root / "prefix", "", "source recipe unbound")
    let identity = realizedInputIdentity("lib", root / "prefix")
    check identity.keyHex.len == 0
    check "source recipe unbound" in identity.incomplete
    check identity.localIdentity == root / "prefix"

  test "a host path is an incomplete input; a Nix store path is complete":
    let root = createTempDir("repro-input-host-", "")
    defer: removeDir(root)
    writeFile(root / "cc", "x")
    let host = realizedInputIdentity("cc", root / "cc")
    check host.keyHex.len == 0
    check "not inside a content-keyed tool prefix" in host.incomplete
    let nixA = realizedInputIdentity("cc",
      "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-gcc-wrapper-15/bin/gcc")
    let nixB = realizedInputIdentity("cc",
      "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-gcc-wrapper-15/bin/cc")
    check nixA.keyHex.len == 64
    check nixA.keyHex == nixB.keyHex  # one store path, one identity

suite "composite identity of a build step":

  test "the source build of a tool is complete only with an identified compiler":
    let root = createTempDir("repro-composite-", "")
    defer: removeDir(root)
    createDir(root / "cc-a" / "bin")
    writePrefixIdentityFile(root / "cc-a", repeat('1', 64), "")
    writeFile(root / "cc-a" / "bin" / "gcc", "x")
    createDir(root / "cc-b" / "bin")
    writePrefixIdentityFile(root / "cc-b", repeat('2', 64), "")
    writeFile(root / "cc-b" / "bin" / "gcc", "x")
    writeFile(root / "host-cc", "x")
    let sha = repeat('f', 64)
    let complete = nimSourceBuildCacheIdentity("2.2.4", sha,
      root / "cc-a" / "bin" / "gcc", "")
    check cacheEntryIdentityError(complete).len == 0
    let other = nimSourceBuildCacheIdentity("2.2.4", sha,
      root / "cc-b" / "bin" / "gcc", "")
    check deriveCacheEntryKeyHex(complete) != deriveCacheEntryKeyHex(other)
    let hostBuilt = nimSourceBuildCacheIdentity("2.2.4", sha,
      root / "host-cc", "")
    check "incomplete" in cacheEntryIdentityError(hostBuilt)
    let withSdk = nimSourceBuildCacheIdentity("2.2.4", sha,
      root / "cc-a" / "bin" / "gcc", "/Library/Developer/SDKs/MacOSX.sdk")
    check "SDK" in cacheEntryIdentityError(withSdk)

  test "a step input file keys by content, not by path":
    let a = PostExtractStepDecl(kind: "k", contractVersion: "k-v1",
      inputFiles: @[PostExtractStepInputFile(path: "/one/ext.src",
        sha256: repeat('c', 64))])
    var b = a
    b.inputFiles[0].path = "/elsewhere/ext.src"
    check postExtractStepIdentityOptions(a) == postExtractStepIdentityOptions(b)
    var c = a
    c.inputFiles[0].sha256 = repeat('d', 64)
    check postExtractStepIdentityOptions(a) != postExtractStepIdentityOptions(c)
    check postExtractStepIdentityOptions(PostExtractStepDecl()).len == 0

suite "post-extraction step declarations":

  proc refusal(decl: PostExtractStepDecl): string =
    try:
      validatePostExtractStepDecl(decl, "pkg", "")
    except ToolPrefixDeclarationError as err:
      return err.msg
    ""

  test "a declaration that cannot be realized portably is refused":
    let base = PostExtractStepDecl(kind: "k", contractVersion: "k-v1")
    check refusal(base) == ""
    var noContract = base
    noContract.contractVersion = ""
    check "contract version" in refusal(noContract)
    var absolutePrune = base
    absolutePrune.prunePaths = @["/etc/passwd"]
    check "not a relative path inside the prefix" in refusal(absolutePrune)
    var escaping = base
    escaping.rewrittenFiles = @["../outside"]
    check "not a relative path inside the prefix" in refusal(escaping)
    var unstated = base
    unstated.externalInputs = @[PostExtractStepExternalInput(role: "lib")]
    check "neither its complete cache key" in refusal(unstated)
    var stated = base
    stated.externalInputs = @[PostExtractStepExternalInput(role: "lib",
      incomplete: "source recipe")]
    check refusal(stated) == ""
