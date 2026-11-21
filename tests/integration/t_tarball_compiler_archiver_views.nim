## Exercise production archive-view reuse with real installed compiler and
## archiver entry points. The fixture supplies only an owned archive layout;
## neither executable is a fake. Both profiles run their real version probe,
## and the selected archiver must create/list an archive of two real C objects.
## Distinct package views must share payload inodes without editing the first
## view's provenance. No upstream distribution download or native Windows
## qualification is inferred from running this on another host.
import std/[os, strutils, tempfiles, unittest]
import repro_interface_artifacts
import repro_test_support
import repro_tool_profiles

proc invoke(argv: openArray[string]): auto =
  runShell(shellCommand(argv))

proc makeUse(selector, executable, url, digest, identity: string): InterfaceToolUse =
  result = InterfaceToolUse(rawConstraint: selector,
    packageSelector: selector, executableName: executable)
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: selector, url: url, sha256: digest, archiveType: "tar.gz",
    executablePath: "bin/" & executable & ExeExt,
    packageId: "owned-toolchain-view-fixture", lockIdentity: identity)]

type ViewObservation = object
  firstReceiptBefore, firstReceiptAfter: string
  sharedPayloads: seq[bool]
  archiveMembers: seq[string]

proc exerciseViews(archiverFirst: bool; mismatchedIdentity = false):
    ViewObservation =
  let scratch = createTempDir("repro-real-toolchain-views-", "")
  defer: removeDir(scratch)
  let priorCache = getEnv("REPRO_CACHE_DISABLE")
  let hadCache = existsEnv("REPRO_CACHE_DISABLE")
  putEnv("REPRO_CACHE_DISABLE", "1")
  defer:
    if hadCache: putEnv("REPRO_CACHE_DISABLE", priorCache)
    else: delEnv("REPRO_CACHE_DISABLE")

  let compilerName = when defined(macosx): "clang" else: "gcc"
  let compiler = findExe(compilerName)
  let archiver = findExe("ar")
  doAssert compiler.len > 0 and archiver.len > 0,
    "the normal development toolchain must supply a compiler and ar"
  let payload = scratch / "payload"
  createDir(payload / "bin")
  copyFile(compiler, payload / "bin" / (compilerName & ExeExt))
  copyFile(archiver, payload / "bin" / ("ar" & ExeExt))
  when not defined(windows):
    for name in [compilerName, "ar"]:
      setFilePermissions(payload / "bin" / name,
        {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
         fpOthersRead, fpOthersExec})
  let archive = scratch / "toolchain.tar.gz"
  let tar = findExe("tar")
  doAssert tar.len > 0
  let packed = invoke([tar, "-czf", archive, "-C", payload, "bin"])
  doAssert packed.code == 0, packed.output
  let digest = fileSha256Hex(archive)
  let url = "file://" & archive.replace('\\', '/')
  let identity = "owned-toolchain-view-fixture:sha256:" & digest
  let compilerUse = makeUse("compiler-view", compilerName, url, digest, identity)
  let archiverUse = makeUse("archiver-view", "ar", url, digest, identity)
  let firstUse = if archiverFirst: archiverUse else: compilerUse
  var secondUse = if archiverFirst: compilerUse else: archiverUse
  if mismatchedIdentity:
    secondUse.tarballProvisioning[0].lockIdentity.add("-different-declaration")
  let store = scratch / "store"
  let first = resolveTarballTool(firstUse, store)
  require first.probes.len > 0
  check first.probes[0].exitCode == 0
  let firstReceipt = first.selectedStorePath / ".reprobuild-tarball-receipt.json"
  let receiptBefore = readFile(firstReceipt)
  result.firstReceiptBefore = receiptBefore
  let second = resolveTarballTool(secondUse, store)
  require second.probes.len > 0
  check second.probes[0].exitCode == 0
  check first.selectedStorePath != second.selectedStorePath
  result.firstReceiptAfter = readFile(firstReceipt)
  check result.firstReceiptAfter == receiptBefore
  for name in [compilerName, "ar"]:
    let shared = sameFile(first.selectedStorePath / "bin" / (name & ExeExt),
                          second.selectedStorePath / "bin" / (name & ExeExt))
    result.sharedPayloads.add(shared)
    check shared == (not mismatchedIdentity)
  let arProfile = if archiverFirst: first else: second
  let ccProfile = if archiverFirst: second else: first
  check arProfile.resolvedExecutableDigest != ccProfile.resolvedExecutableDigest
  check fileSha256Hex(arProfile.resolvedExecutablePath) == fileSha256Hex(archiver)
  var objects: seq[string]
  for name in ["one", "two"]:
    let source = scratch / (name & ".c")
    let objectPath = scratch / (name & ".o")
    writeFile(source, "int " & name & "(void) { return 1; }\n")
    let compiled = invoke([compiler, "-c", source, "-o", objectPath])
    doAssert compiled.code == 0, compiled.output
    objects.add(objectPath)
  let library = scratch / "real.a"
  let created = invoke(@[arProfile.resolvedExecutablePath, "rcs", library] & objects)
  check created.code == 0
  let listed = invoke([arProfile.resolvedExecutablePath, "t", library])
  check listed.code == 0
  result.archiveMembers = listed.output.strip.splitLines
  check result.archiveMembers == @["one.o", "two.o"]

suite "real compiler archive views":
  test "compiler then archiver preserves payload and provenance":
    let observed = exerciseViews(false)
    check observed.firstReceiptAfter == observed.firstReceiptBefore
    check observed.sharedPayloads == @[true, true]
    check observed.archiveMembers == @["one.o", "two.o"]
  test "archiver then compiler preserves payload and provenance":
    let observed = exerciseViews(true)
    check observed.firstReceiptAfter == observed.firstReceiptBefore
    check observed.sharedPayloads == @[true, true]
    check observed.archiveMembers == @["one.o", "two.o"]

  test "matching bytes without the shared declaration are not hardlinked":
    let observed = exerciseViews(false, mismatchedIdentity = true)
    check observed.firstReceiptAfter == observed.firstReceiptBefore
    check observed.sharedPayloads == @[false, false]
    check observed.archiveMembers == @["one.o", "two.o"]
