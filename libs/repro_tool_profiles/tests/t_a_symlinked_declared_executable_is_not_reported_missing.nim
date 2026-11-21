## A declared executable that is present but reached through a SYMLINK is
## refused as a symlink, not reported as missing.
##
## The defect: tarball realization refuses a declared executable reached
## through a symlink (``executableInStorePath(..., rejectSymlinks = true)``),
## and every refusal said the realization "lacks" it. `python3`'s POSIX arms
## declared ``python/bin/python3``, which in the pinned
## python-build-standalone archive is a relative symlink to ``python3.12``, so
## provisioning downloaded the archive, verified its digest, extracted it, and
## reported
##
##     tool-resolution failed: extracted tarball lacks executable
##     python/bin/python3
##
## about an archive that plainly contains that entry. Anyone reading that goes
## looking for a missing file, which is the one thing that was not wrong
## (reprobuild-pm/issues/
## 2026-09-24-no-conformance-check-runs-against-stdlib-tarball-arms.md,
## §"Note also the diagnostic cost").
##
## What is asserted, end to end through the realizer's own ``file://`` arm:
##
##   * declaring the symlink refuses, and the message names the component and
##     what it points at, and does NOT say "lacks";
##   * positive control — declaring the regular file the link resolves to
##     realizes, and the resolved path is a regular file inside the prefix, so
##     the refusal above is about the symlink and not about the fixture;
##   * negative control — declaring an absent path still says "lacks
##     executable", so the genuinely-missing diagnostic was not traded away
##     for the new one;
##   * ``probeDeclaredExecutable`` returns the right verdict for each of the
##     five cases, including that ``rejectSymlinks = false`` still ACCEPTS a
##     symlinked path, which is what the callers that only choose between
##     already-realized prefixes rely on.
##
## No mocks: a real ``tar.gz`` this test builds, the realizer's own
## ``file://`` arm, a real store under a temporary directory, and the shared
## cache switched off so nothing is published.
##
## Falsifiable: make ``reason`` render every verdict as "lacks executable
## <path>" (the behaviour before this) and the first case fails on the
## substring it requires, while the negative control still passes.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_tool_profiles
import repro_test_support/reasoned_skip

proc writeExecutable(path, body: string) =
  createDir(parentDir(path))
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc removeTree(root: string) =
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    try: setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError: discard
  removeDir(root)

proc archiveUse(archive, declaredPath: string): InterfaceToolUse =
  ## A tool use whose single arm is the fixture archive, declaring
  ## ``declaredPath``. ``lockIdentity`` carries the declared path so two
  ## declarations over the same bytes are two realizations rather than one
  ## cache hit on the other's prefix.
  result = InterfaceToolUse(rawConstraint: "symlink-fixture",
    packageSelector: "symlink-fixture", executableName: "tool")
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    url: "file://" & archive, sha256: fileSha256Hex(archive),
    archiveType: "tar.gz", executablePath: declaredPath,
    packageId: "symlink-fixture@1", cpu: "any", os: "any",
    lockIdentity: "fixture:symlink-fixture@1:" & declaredPath)]

suite "a symlinked declared executable is refused as one":
  setup:
    let root = createTempDir("repro-symlink-decl-", "")
    let savedCacheDisable = getEnv("REPRO_CACHE_DISABLE")
    putEnv("REPRO_CACHE_DISABLE", "1")
    let store = root / "store"
    # The tree the fixture archive carries:
    #   bin/real  — a regular executable
    #   bin/tool  — a RELATIVE symlink to ``real``, the shape upstream
    #               archives use (python-build-standalone's
    #               ``python3 -> python3.12``, node's
    #               ``npm -> ../lib/node_modules/npm/bin/npm-cli.js``)
    #   bin/data  — a regular file with no execute bit
    let tree = root / "tree"
    writeExecutable(tree / "bin" / "real", "#!/bin/sh\necho real\n")
    writeFile(tree / "bin" / "data", "not a program\n")
    var haveSymlink = false
    try:
      createSymlink("real", tree / "bin" / "tool")
      haveSymlink = fileExists(tree / "bin" / "tool")
    except OSError, IOError:
      haveSymlink = false
    # `tar` is one of the irreducible host tools the realizer itself requires
    # (Dependency-Provisioning-In-Build-Graph.md §4.1), so building the
    # fixture with it adds no dependency this suite did not already have.
    let archive = root / "fixture.tar.gz"
    let packed = execCmdEx("tar -czf " & quoteShell(archive) &
      " -C " & quoteShell(tree) & " bin")

  teardown:
    if savedCacheDisable.len > 0:
      putEnv("REPRO_CACHE_DISABLE", savedCacheDisable)
    else:
      delEnv("REPRO_CACHE_DISABLE")
    removeTree(root)

  test "declaring the symlink names the symlink, not a missing file":
    if not haveSymlink:
      skip("this host cannot create a symlink in the fixture tree " &
        "(on Windows that needs a privilege not every developer has), so " &
        "there is no symlinked declaration to refuse")
    else:
      require packed.exitCode == 0
      var message = ""
      try:
        discard resolveTarballTool(archiveUse(archive, "bin/tool"), store)
        checkpoint("expected a refusal, got a realization")
      except CatchableError as err:
        message = err.msg
      checkpoint("message: " & message)
      check "reached through a symlink" in message
      check "bin/tool -> real" in message
      # The point of the case: the old message said this, and it is what sent
      # a reader looking for a file the archive contains.
      check "lacks executable" notin message

  test "positive control: the regular file the link resolves to realizes":
    require packed.exitCode == 0
    let profile = resolveTarballTool(archiveUse(archive, "bin/real"), store)
    checkpoint("realized: " & profile.resolvedExecutablePath)
    check profile.resolvedExecutablePath.startsWith(profile.selectedStorePath)
    check fileExists(profile.resolvedExecutablePath)
    check getFileInfo(profile.resolvedExecutablePath,
      followSymlink = false).kind == pcFile

  test "negative control: an absent path still reports lacks executable":
    require packed.exitCode == 0
    var message = ""
    try:
      discard resolveTarballTool(archiveUse(archive, "bin/absent"), store)
      checkpoint("expected a refusal, got a realization")
    except CatchableError as err:
      message = err.msg
    checkpoint("message: " & message)
    check "lacks executable bin/absent" in message
    check "reached through a symlink" notin message

  test "probeDeclaredExecutable returns a verdict per failure mode":
    require packed.exitCode == 0
    let prefix = root / "tree"

    let ok = probeDeclaredExecutable(prefix, "bin/real",
      rejectSymlinks = true)
    check ok.verdict == deOk
    check ok.resolvedPath.len > 0
    check "carries executable bin/real" in ok.reason

    let missing = probeDeclaredExecutable(prefix, "bin/absent",
      rejectSymlinks = true)
    check missing.verdict == deMissing
    check missing.reason == "lacks executable bin/absent"
    check missing.resolvedPath.len == 0

    let unsafe = probeDeclaredExecutable(prefix, "../escape",
      rejectSymlinks = true)
    check unsafe.verdict == deUnsafePath
    check unsafe.resolvedPath.len == 0

    when not defined(windows):
      # Windows reports execute permission for ordinary files, so there is no
      # not-executable case to make there.
      let notExec = probeDeclaredExecutable(prefix, "bin/data",
        rejectSymlinks = true)
      check notExec.verdict == deNotExecutable
      check "carries no execute permission" in notExec.reason

    if haveSymlink:
      let symlinked = probeDeclaredExecutable(prefix, "bin/tool",
        rejectSymlinks = true)
      check symlinked.verdict == deSymlinkedPath
      check symlinked.symlinkComponent == "bin/tool"
      check symlinked.symlinkTarget == "real"

      # The old behaviour every other caller depends on: without
      # ``rejectSymlinks`` a symlinked path is still a usable executable, and
      # the prefix-choosing callers must keep accepting it.
      let permitted = probeDeclaredExecutable(prefix, "bin/tool")
      check permitted.verdict == deOk
      check executableInStorePath(prefix, "bin/tool").len > 0
      check executableInStorePath(prefix, "bin/tool",
        rejectSymlinks = true).len == 0
