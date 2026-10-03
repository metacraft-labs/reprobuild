## A pinned provider Nim that is not in the store is realized from the archive
## the LOCK pins, verified against the digest the lock records -- and a
## download that does not hash to it is refused, not installed.
##
## Reprobuild-specs Distribution-And-Packaging.milestones.org, M5 "pin the
## provider-compile toolchain": a pinned Nim of any released version is
## provisioned automatically, with the bootstrap's hard-failure semantics; the
## archive is verified against a digest that is part of the pin, never one
## re-read from the network at use time.
##
## THE PROPERTIES, EACH WITH THE DEFECT IT CATCHES:
##
##   1. An archive whose bytes do not hash to the lock's `archive_sha256` is
##      REFUSED with `ProviderNimPinError`, naming the archive, the digest the
##      lock records and the one it got; nothing is installed at the pin's
##      prefix and no executable is returned. Catches a realizer that trusts
##      what it downloaded, and a failure that falls back to another Nim.
##   2. The same archive with the right digest is realized through the
##      tool store's provisioning edge and installed at the pin's own prefix
##      (`prefixes/nim/<version>-<hash>/`), with its standard library; the
##      next resolution is arithmetic. Catches a realizer that ignores the
##      lock's archive, and an install at an address the pin does not name.
##   3. A lock written before archive pins existed, pinning a version that is
##      not the bootstrap's own, is refused naming `repro lock refresh` and
##      `repro self install`. Catches an unpinned network resolution at use
##      time.
##   4. A source archive pin whose bytes do not match is refused in the same
##      way BEFORE any build is attempted.
##
## Test-double policy: no mocks. The "release archive" is a real `.tar.gz`
## made with the host's `tar` from a synthetic Nim tree (its `bin/nim` is not
## a compiler: nothing here runs it), served by `file://` URL, and realized by
## the real `realizePinnedProviderNim` -> `provisionPinnedNim` ->
## `resolveTarballTool` provisioning edge into a real store in a temporary
## directory. The binary cache is disabled so the realization cannot be
## served from anywhere but the archive.

import std/[os, osproc, strutils, tables, tempfiles, unittest]

import repro_core/ambient_execution
import repro_lock
import repro_selfhost
import repro_tool_profiles
import repro_cli_support/project_pins

const PinnedVersion = "2.2.8"

proc hostTar(): string =
  when defined(windows):
    getEnv("SystemRoot", r"C:\Windows") / "System32" / "tar.exe"
  else:
    for candidate in ["/usr/bin/tar", "/bin/tar"]:
      if fileExists(candidate):
        return candidate
    uncontrolledFindExe("tar")

proc fileUrl(path: string): string =
  "file://" & path.replace('\\', '/')

proc makeNimArchive(root: string): tuple[path, sha256: string] =
  ## `nim-<version>/bin/nim[.exe]` + `nim-<version>/lib/system.nim`, packed
  ## as upstream packs its archives: one top-level directory.
  let tree = root / "src" / ("nim-" & PinnedVersion)
  createDir(tree / "bin")
  createDir(tree / "lib")
  writeFile(tree / "bin" / addFileExt("nim", ExeExt), "not a compiler\n")
  writeFile(tree / "lib" / "system.nim", "# synthetic system module\n")
  result.path = root / ("nim-" & PinnedVersion & ".tar.gz")
  let res = uncontrolledExecCmdEx(quoteShellCommand([hostTar(), "-czf",
    result.path, "-C", root / "src", "nim-" & PinnedVersion]))
  doAssert res.exitCode == 0, res.output
  result.sha256 = fileSha256Hex(result.path)

proc writePinnedLock(project: string; archive: LockedArchive) =
  var sol = UnifiedSolution(variants: initTable[string, string](),
    packages: initTable[string, string](), optimal: true)
  sol.packages["nim"] = PinnedVersion
  var ld = lockedDepsFromSolved(solutionToLock(sol, currentPlatformId(), ""))
  ld.packages[0].source = "store"
  ld.deps = lockedDepsFromPackages(ld.packages, currentPlatformId())
  ld.deps[0].archive = archive
  createDir(project)
  writeFile(project / "repro.lock", serializeLockedDependencies(ld))

type Scenario = object
  root, store, project: string
  archive: tuple[path, sha256: string]

proc newScenario(): Scenario =
  putEnv("REPRO_CACHE_DISABLE", "1")
  result.root = createTempDir("repro-pinned-nim-verify-", "")
  result.store = result.root / "store"
  result.project = result.root / "project"
  createDir(result.store)
  result.archive = makeNimArchive(result.root)

proc cleanup(s: Scenario) =
  ## Best effort: on Windows the engine that ran the provisioning edge in
  ## THIS process still maps its action-cache records, and a mapped file
  ## cannot be deleted until the process exits.
  try: removeDir(s.root)
  except OSError: discard

proc pin(s: Scenario): SelfPin =
  result = projectPinsFor(s.project).providerNim
  doAssert result.state == spsPinned, result.detail

suite "a pinned Nim is realized only from bytes that match the lock":

  test "a download that does not hash to the pinned digest is refused":
    let s = newScenario()
    defer: s.cleanup()
    let wrong = "0".repeat(64)
    writePinnedLock(s.project, LockedArchive(url: fileUrl(s.archive.path),
      sha256: wrong, archiveType: "tar.gz", build: LockedArchiveBinary))
    let pin = s.pin()
    check pin.archive.sha256 == wrong
    let prefix = selfPrefixAbsolutePath(s.store, pin)
    var message = ""
    var returned = ""
    try:
      returned = realizePinnedProviderNim(s.store, pin)
    except ProviderNimPinError as err:
      message = err.msg
    checkpoint(message)
    check returned == ""
    check message.contains("could not provision the provider compiler nim " &
      PinnedVersion)
    check message.contains(fileUrl(s.archive.path))
    check message.contains("sha256 mismatch expected " & wrong & " got " &
      s.archive.sha256)
    check message.contains("repro lock refresh")
    check not dirExists(prefix)
    check not fileExists(pinnedExecutableIn(providerNimPin(), prefix))

  test "the archive with the pinned digest is realized at the pin's prefix":
    let s = newScenario()
    defer: s.cleanup()
    writePinnedLock(s.project, LockedArchive(url: fileUrl(s.archive.path),
      sha256: s.archive.sha256, archiveType: "tar.gz",
      build: LockedArchiveBinary))
    let pin = s.pin()
    let prefix = selfPrefixAbsolutePath(s.store, pin)
    let exe = realizePinnedProviderNim(s.store, pin)
    check exe == pinnedExecutableIn(providerNimPin(), prefix)
    check fileExists(exe)
    check readFile(exe) == "not a compiler\n"
    check fileExists(prefix / "lib" / "system.nim")
    check prefix.replace('\\', '/').contains("/prefixes/nim/" &
      PinnedVersion & "-")
    # The archive came through the tool store's provisioning edge.
    check dirExists(s.store / "tool-store" / "provisioning" / "receipts")
    # Resident now: the second resolution is arithmetic, even with the
    # archive gone.
    removeFile(s.archive.path)
    check realizePinnedProviderNim(s.store, pin) == exe

  test "a lock with no archive for a non-bootstrap version is refused":
    let s = newScenario()
    defer: s.cleanup()
    writePinnedLock(s.project, LockedArchive())
    let pin = s.pin()
    check not pin.archive.isPinned
    var message = ""
    try:
      discard realizePinnedProviderNim(s.store, pin)
    except ProviderNimPinError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("the lock records no archive for it")
    check message.contains("repro lock refresh")
    check message.contains("repro self install --package=nim")
    check not dirExists(selfPrefixAbsolutePath(s.store, pin))

  test "a source archive with the wrong digest is refused before any build":
    let s = newScenario()
    defer: s.cleanup()
    let wrong = "f".repeat(64)
    writePinnedLock(s.project, LockedArchive(url: fileUrl(s.archive.path),
      sha256: wrong, archiveType: "tar.gz", build: LockedArchiveSource))
    let pin = s.pin()
    var message = ""
    try:
      discard realizePinnedProviderNim(s.store, pin)
    except ProviderNimPinError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("could not provision the provider compiler nim")
    check message.contains("sha256 mismatch expected " & wrong)
    # Refused before a C compiler was provisioned or a build attempted.
    check not dirExists(s.store / "tool-store" / "bootstrap-nim")
    check not dirExists(s.store / "tool-store" / "compiler-probes")
    check not dirExists(selfPrefixAbsolutePath(s.store, pin))
