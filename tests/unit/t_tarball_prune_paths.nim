## ``prune`` on a tarball provisioning entry drops declared subtrees before
## the prefix is sealed.
##
## The mechanism exists because several upstreams ship one archive serving an
## audience a build environment does not have: the PostgreSQL Windows
## distribution carries a 671 MB pgAdmin desktop client beside a 72 MB
## ``bin``, and the LLVM release carries a debugger and an interpreter beside
## the compiler. Realizing those wholesale costs store space on every machine
## and, once the packed prefix passes the shared cache's request-body limit,
## costs the package its place in the cache entirely — so the artifact other
## machines most want to install quickly is the one they must always build
## for themselves.
##
## What is asserted here is the part that is easy to get silently wrong:
##
##   * the declared paths are gone from the SEALED prefix, not merely from a
##     staging copy — a prune applied after the move would edit a published
##     realization;
##   * everything not declared survives, including the executable;
##   * a directory and a plain file are both accepted;
##   * a path that is not present is not an error, because upstream layouts
##     move between versions and a stale entry should cost a version bump
##     rather than a broken realize;
##   * a path that escapes the prefix is rejected outright.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_test_support
import repro_tool_profiles

proc buildFixtureArchive(tempRoot: string): tuple[url, sha256: string] =
  ## A tar.gz with the shape the prune declarations below target: a wrapper
  ## directory (so ``stripComponents = 1`` is exercised too), a ``bin`` the
  ## executable lives in, a bulky subtree to drop, and a loose file to drop.
  let payloadRoot = tempRoot / "payload"
  let wrapper = payloadRoot / "prunefixture-1.0.0"
  createDir(wrapper / "bin")
  createDir(wrapper / "gui" / "nested")
  createDir(wrapper / "share")

  let toolPath =
    when defined(windows): wrapper / "bin" / "prunetool.cmd"
    else: wrapper / "bin" / "prunetool"
  when defined(windows):
    writeFile(toolPath, "@echo off\r\necho prunetool 1.0.0\r\n")
  else:
    writeFile(toolPath, "#!/bin/sh\nset -eu\necho prunetool 1.0.0\n")
    setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

  writeFile(wrapper / "gui" / "app.bin", repeat("gui-payload-", 4096))
  writeFile(wrapper / "gui" / "nested" / "deep.bin", "deep")
  writeFile(wrapper / "manual.html", "<html>docs</html>")
  writeFile(wrapper / "share" / "keep.txt", "kept")

  let archivePath = tempRoot / "prunefixture-1.0.0.tar.gz"
  let tarExe =
    when defined(windows):
      let systemTar = r"C:\Windows\System32\tar.exe"
      if fileExists(systemTar): systemTar else: findExe("tar")
    else:
      findExe("tar")
  doAssert tarExe.len > 0, "tar is required for the prune gate"
  let tar = runShell(shellCommand([tarExe, "-czf", archivePath, "-C",
    payloadRoot, "prunefixture-1.0.0"]))
  doAssert tar.code == 0, "tar failed: " & tar.output
  (url: "file://" & archivePath.replace('\\', '/'),
   sha256: fileSha256Hex(archivePath))

proc pruningUse(url, sha256: string; prunePaths: seq[string];
                selector: string): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: "prunefixture",
    packageSelector: selector,
    executableName: "prunetool",
    location: SourceLocation(file: "fixture", line: 1))
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: "prunefixture",
    url: url,
    sha256: "sha256:" & sha256,
    archiveType: "tar.gz",
    executablePath:
      when defined(windows): "bin/prunetool.cmd" else: "bin/prunetool",
    prunePaths: prunePaths,
    stripComponents: 1,
    packageId: selector,
    lockIdentity: "sha256:" & sha256 & ":" & prunePaths.join(","),
    location: SourceLocation(file: "fixture", line: 2))]

suite "tarball prune paths":
  # Publishing is irrelevant to what is under test and would need
  # credentials plus a reachable endpoint; disable the cache so the realize
  # is purely local.
  putEnv("REPRO_CACHE_DISABLE", "1")

  test "declared subtrees and files are absent from the sealed prefix":
    let tempRoot = createTempDir("repro-prune-", "")
    defer:
      try: removeDir(tempRoot) except CatchableError: discard
    let fixture = buildFixtureArchive(tempRoot)
    let storeRoot = tempRoot / "store"

    let profile = resolveTarballTool(
      pruningUse(fixture.url, fixture.sha256,
        @["gui", "manual.html", "not-present-in-this-version"],
        "prunefixture@1.0.0-pruned"),
      storeRoot)
    let prefix = profile.selectedStorePath

    check dirExists(prefix)
    # Dropped: a directory (with its nested content) and a loose file.
    check (not dirExists(prefix / "gui"))
    check (not fileExists(prefix / "manual.html"))
    # Kept: everything not declared, the executable included.
    check fileExists(profile.resolvedExecutablePath)
    check readFile(prefix / "share" / "keep.txt") == "kept"
    # A declared path that upstream does not ship is tolerated — the realize
    # above would have raised rather than reaching this line.
    check profile.installMethod == "tarball"

  test "an unpruned realize of the same archive keeps everything":
    # The control. Without it, a fixture that simply never shipped ``gui``
    # would satisfy the assertions above.
    let tempRoot = createTempDir("repro-prune-control-", "")
    defer:
      try: removeDir(tempRoot) except CatchableError: discard
    let fixture = buildFixtureArchive(tempRoot)
    let storeRoot = tempRoot / "store"

    let profile = resolveTarballTool(
      pruningUse(fixture.url, fixture.sha256, @[],
        "prunefixture@1.0.0-whole"),
      storeRoot)
    let prefix = profile.selectedStorePath
    check dirExists(prefix / "gui" / "nested")
    check fileExists(prefix / "manual.html")
    check fileExists(profile.resolvedExecutablePath)

  test "a prune path that escapes the prefix is rejected":
    let tempRoot = createTempDir("repro-prune-escape-", "")
    defer:
      try: removeDir(tempRoot) except CatchableError: discard
    let fixture = buildFixtureArchive(tempRoot)
    let storeRoot = tempRoot / "store"

    expect CatchableError:
      discard resolveTarballTool(
        pruningUse(fixture.url, fixture.sha256, @["../outside"],
          "prunefixture@1.0.0-escape"),
        storeRoot)
