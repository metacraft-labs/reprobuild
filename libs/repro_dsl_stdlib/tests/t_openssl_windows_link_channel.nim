## OpenSSL's Windows library channel, from declaration to `-L`.
##
## M8's defect was not "the flag was missing". It was that the flag's SOURCE
## was the consumer: `repro.nim` computed
## `-L<diyRoot>/msys2/msys64/mingw64/lib` and threaded it onto the `passL` of
## whichever `-d:ssl` edges someone remembered, while the package that owns
## OpenSSL declared nothing for Windows at all.
##
## So the assertions below are about the CHAIN, not about the flag:
##
##   * the package declares a Windows arm, pinned and hashed;
##   * it declares it in the layout vocabulary rather than as pasted strings,
##     and the executable path it declares is CONSISTENT with the prefix
##     shape the derivation will invert it back to (this is the one that
##     catches a declaration and a deriver drifting apart — each would still
##     be internally coherent);
##   * a prefix that really carries the import libraries yields the directory
##     the linker needs, in BOTH shapes the package can arrive in;
##   * a prefix that does not carries NOTHING, because a `-L` naming a
##     directory with no OpenSSL in it is worse than no `-L`: the link fails
##     either way, but only one of them looks like the channel was supplied;
##   * PATH resolution outranks a consumer-offered prefix, since PATH is what
##     the engine's own `--tool-provisioning=path` resolver binds
##     `uses: "openssl"` to.
##
## The fixtures build real directories with real files rather than mocking the
## filesystem, because the acceptance test IS a filesystem question and a mock
## would let the module's idea of a link-library name drift away from `ld`'s.

import std/[os, sequtils, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/openssl_layout
import repro_dsl_stdlib/prefix_layout
# Imported for its REGISTRATION side effect — `package openssl:` is what puts
# the catalog entry into the DSL registry that `opensslPackage()` reads back —
# so the compiler's unused-import heuristic does not apply.
{.push warning[UnusedImport]: off.}
import repro_dsl_stdlib/packages/openssl
{.pop.}

proc opensslPackage(): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == "openssl":
      return pkg
  raise newException(ValueError,
    "the openssl catalog entry did not register a package")

proc windowsTarballEntry(): TarballProvisioningDef =
  for entry in opensslPackage().tarballProvisioning:
    if entry.os.toLowerAscii == "windows":
      return entry
  raise newException(ValueError,
    "openssl declares no Windows tarball provisioning entry")

proc makePrefix(root: string; layout: PrefixLayout;
                libNames: openArray[string]): string =
  ## A prefix on disk in `layout`'s shape, carrying `libNames` in its LINK
  ## directory and an `openssl.exe` in its BIN directory.
  result = root
  let bin = if binDir(layout) == ".": root else: root / binDir(layout)
  let lib = if linkLibDir(layout) == ".": root else: root / linkLibDir(layout)
  createDir(bin)
  createDir(lib)
  writeFile(bin / "openssl.exe", "not really an executable")
  for name in libNames:
    writeFile(lib / name, "not really an import library")

suite "the openssl package declares a Windows library channel":

  test "the Windows arm is pinned to an artefact and hashed":
    let entry = windowsTarballEntry()
    checkpoint("url: " & entry.url)
    check entry.url.len > 0
    check entry.cpu == "x86_64"
    # A pin without a digest is a download, not a pin. 64 hex chars, and not
    # the all-zero placeholder the DSL-parse fixtures use.
    check entry.sha256.len == 64
    check entry.sha256.allIt(it in HexDigits)
    check entry.sha256 != repeat('0', 64)
    # The lock identity has to carry the same digest, or the lock would pin a
    # different artefact from the one the fetch verifies.
    check entry.sha256 in entry.lockIdentity
    # `conda` is the archive shape this DSL can actually unpack (the realizer
    # rejects every type outside its list, `.pkg.tar.zst` among them).
    check entry.archiveType == "conda"

  test "the declared executable path IS the declared layout":
    # The consistency check the chain hangs on. `executablePath` is written
    # `binDir(plConda) & "/openssl.exe"`; the deriver inverts `binDir` to get
    # back to a prefix. If either side ever changes alone, this fails.
    let entry = windowsTarballEntry()
    check entry.executablePath == binDir(plConda) & "/openssl.exe"

    let candidates = opensslPrefixCandidates(
      "C:/store/openssl-abc" / entry.executablePath)
    checkpoint("candidates: " & $candidates)
    check candidates.len > 0
    check candidates[0].layout == plConda
    check candidates[0].prefix == "C:/store/openssl-abc"
    check opensslLinkDir(candidates[0].prefix, candidates[0].layout) ==
      "C:/store/openssl-abc" / linkLibDir(plConda)

  test "the loadable side is declared separately from the linkable one":
    # On Windows they are different directories, which is the whole reason
    # `runtimeLibDir` and `linkLibDir` are separate functions.
    let declared = opensslPackage().runtimeLibraries
    check declared.len > 0
    var windowsDirs: seq[string] = @[]
    for lib in declared:
      if lib.os.toLowerAscii == "windows":
        windowsDirs.add(lib.dir)
    check windowsDirs.len > 0
    for dir in windowsDirs:
      check dir == runtimeLibDir(plConda)
      check dir != linkLibDir(plConda)

suite "a prefix yields the link directory only if it really provides one":

  setup:
    resetOpensslPrefixCandidates()

  teardown:
    resetOpensslPrefixCandidates()

  test "ld's PE spellings include both the mingw and the MSVC import library":
    # Not a restatement of the implementation: conda-forge win-64 ships ONLY
    # `libssl.lib` / `libcrypto.lib` (MSVC-produced), and mingw's ld does
    # resolve `-lssl` against them. Dropping the `.lib` spellings would make
    # the arm this package pins unusable while every other test still passed.
    let ssl = linkLibraryCandidates("ssl")
    check "libssl.dll.a" in ssl
    check "libssl.a" in ssl
    check "libssl.lib" in ssl
    check "ssl.lib" in ssl

  test "a conda-shaped prefix with both import libraries is accepted":
    let root = getTempDir() / "m8-openssl-conda"
    removeDir(root)
    discard makePrefix(root, plConda, ["libssl.lib", "libcrypto.lib"])
    defer: removeDir(root)

    check prefixProvidesLinkLibraries(root, plConda)
    registerOpensslPrefixCandidate(root)
    check opensslLinkDirFromCandidates() == root / linkLibDir(plConda)

  test "a mingw-shaped prefix with both import libraries is accepted":
    let root = getTempDir() / "m8-openssl-mingw"
    removeDir(root)
    discard makePrefix(root, plWindowsTree,
      ["libssl.dll.a", "libcrypto.dll.a"])
    defer: removeDir(root)

    check prefixProvidesLinkLibraries(root, plWindowsTree)
    registerOpensslPrefixCandidate(root)
    check opensslLinkDirFromCandidates() == root / linkLibDir(plWindowsTree)
    # And the same prefix is recoverable from its executable, which is the
    # path the PATH arm takes.
    check opensslLinkDirForExecutable(
      root / binDir(plWindowsTree) / "openssl.exe") ==
      root / linkLibDir(plWindowsTree)

  test "half a channel is no channel":
    # `libssl` without `libcrypto` links no further than neither: `nim.c`
    # emits both `-l` names. Accepting this prefix would produce a `-L` that
    # makes the failure message misleading rather than the link succeed.
    let root = getTempDir() / "m8-openssl-half"
    removeDir(root)
    discard makePrefix(root, plWindowsTree, ["libssl.dll.a"])
    defer: removeDir(root)

    check not prefixProvidesLinkLibraries(root, plWindowsTree)
    registerOpensslPrefixCandidate(root)
    check opensslLinkDirFromCandidates() == ""

  test "an openssl.exe with no development libraries contributes nothing":
    # Git-for-Windows' shape, which is on almost every Windows host's PATH.
    let root = getTempDir() / "m8-openssl-exe-only"
    removeDir(root)
    discard makePrefix(root, plWindowsTree, [])
    defer: removeDir(root)

    check opensslLinkDirForExecutable(
      root / binDir(plWindowsTree) / "openssl.exe") == ""
    registerOpensslPrefixCandidate(root)
    check opensslLinkDirFromCandidates() == ""

  test "a prefix offered at the wrong level matches no declared layout":
    # `msys64` rather than `msys64/mingw64` — a plausible off-by-one for a
    # consumer offering a prefix. It has no `lib` of its own, so it is
    # rejected instead of producing a directory the linker would search in
    # vain.
    let root = getTempDir() / "m8-openssl-parent"
    removeDir(root)
    discard makePrefix(root / "mingw64", plWindowsTree,
      ["libssl.dll.a", "libcrypto.dll.a"])
    defer: removeDir(root)

    registerOpensslPrefixCandidate(root)
    check opensslLinkDirFromCandidates() == ""
    registerOpensslPrefixCandidate(root / "mingw64")
    check opensslLinkDirFromCandidates() ==
      root / "mingw64" / linkLibDir(plWindowsTree)

  test "registration is ordered and deduplicated":
    resetOpensslPrefixCandidates()
    registerOpensslPrefixCandidate("A")
    registerOpensslPrefixCandidate("B")
    registerOpensslPrefixCandidate("A")
    registerOpensslPrefixCandidate("")
    check registeredOpensslPrefixCandidates() == @["A", "B"]

  test "PATH resolution outranks a consumer-offered prefix":
    # The precedence rule, stated as an experiment rather than as a comment.
    # It matters because the engine's own `--tool-provisioning=path` resolver
    # binds `uses: "openssl"` to the PATH hit; deriving `-L` from a different
    # realization while the declared dependency names that one is how a link
    # and its dependency come to disagree about which OpenSSL is in play.
    when defined(windows):
      let onPath = getTempDir() / "m8-openssl-onpath"
      let offered = getTempDir() / "m8-openssl-offered"
      removeDir(onPath)
      removeDir(offered)
      discard makePrefix(onPath, plWindowsTree,
        ["libssl.dll.a", "libcrypto.dll.a"])
      discard makePrefix(offered, plWindowsTree,
        ["libssl.dll.a", "libcrypto.dll.a"])
      defer:
        removeDir(onPath)
        removeDir(offered)

      let savedPath = getEnv("PATH")
      defer: putEnv("PATH", savedPath)
      putEnv("PATH", onPath / binDir(plWindowsTree))

      registerOpensslPrefixCandidate(offered)
      checkpoint("resolved: " & resolvedOpensslExecutable())
      # Both arms could answer; the PATH one has to win.
      check opensslLinkDirFromCandidates() ==
        offered / linkLibDir(plWindowsTree)
      check windowsOpensslLinkSearchDir() ==
        onPath / linkLibDir(plWindowsTree)

      # And when the PATH hit has no development libraries — the
      # Git-for-Windows shape — the offered prefix is what answers.
      let bare = getTempDir() / "m8-openssl-onpath-bare"
      removeDir(bare)
      discard makePrefix(bare, plWindowsTree, [])
      defer: removeDir(bare)
      putEnv("PATH", bare / binDir(plWindowsTree))
      check windowsOpensslLinkSearchDir() ==
        offered / linkLibDir(plWindowsTree)

  test "an empty executable path derives no candidates":
    check opensslPrefixCandidates("").len == 0
    check opensslLinkDirForExecutable("") == ""
