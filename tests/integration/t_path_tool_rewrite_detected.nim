## ``t_path_tool_rewrite_detected`` -- ReproOS-Campaign-Completion M7,
## sibling (7): a tool rewritten in place is not served from the tool
## identity cache.
##
## ## The defect this pins
##
## A path-mode tool identity records ``resolvedExecutableDigest`` (the
## blake3 of the executable), which the profile and typed-tool action
## fingerprints bind. Every cache hit -- the warm table, the stable identity
## file, the keyed cache file, a daemon-parent prewarm -- only checked that
## the recorded paths still EXIST, so rewriting the executable in place kept
## serving the OLD digest, warm and cold, and the typed-tool action
## fingerprint never moved. One layer up, the lowered-graph key folded in
## only the tool-identity KEY, which a rewrite does not move, so a graph
## lowered against the old executable (its action fingerprints embed the
## old profile fingerprint) was served too.
##
## ## What is asserted (Windows NTFS here; the fixtures are portable)
##
##   * a same-size rewrite with the mtime put back (``setLastModificationTime``)
##     is re-resolved warm and cold -- through the NTFS change time, with the
##     recorded evidence shown NOT racy, so the racy-window rule is not what
##     caught it; a different-size rewrite likewise;
##   * a delete-and-recreate with other bytes, the mtime put back, is
##     re-resolved (the file identity changed); with the SAME bytes it is a
##     hit whose evidence is refreshed;
##   * a touch that leaves the bytes alone is a hit (no re-resolution), the
##     refreshed evidence is persisted, and once out of the racy window the
##     next hit is a stat only (``ecCurrent``) and rewrites nothing;
##   * the racy-window rule, isolated: evidence identical to the file's
##     current stat but recorded within 2 s of its mtime / change time is
##     re-hashed (a same-tick rewrite is caught); recorded long after, it is
##     trusted -- which is the documented limit of a stat check;
##   * a daemon-parent prewarm does not serve a rewritten tool, and neither
##     does the KEYED cache file (an identity whose key is no longer the one
##     stamped as current);
##   * an action identity naming an executable digest no verified profile
##     carries is re-resolved, not served;
##   * an identity written without evidence (codec v8) is re-hashed on its
##     first hit;
##   * the typed-tool action fingerprint and the lowered-graph key move with
##     a rewrite, and do not move for a touch.

import std/[os, sequtils, strutils, tempfiles, times, unittest]

import repro_cli_support
import repro_interface_artifacts
import repro_tool_profiles

const
  ExeName = "rwtool"
  PayloadSize = 4096

when defined(windows):
  import std/winlean

  type FileBasicInfo = object
    creationTime, lastAccessTime, lastWriteTime, changeTime: int64
    fileAttributes: DWORD

  proc getFileInformationByHandleEx(h: Handle; infoClass: int32;
                                    info: pointer; size: DWORD): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "GetFileInformationByHandleEx".}
  proc setFileInformationByHandle(h: Handle; infoClass: int32;
                                  info: pointer; size: DWORD): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "SetFileInformationByHandle".}

  proc basicTimes(path: string; write = false;
                  value = FileBasicInfo()): FileBasicInfo =
    ## Read (or, with ``write``, forge) a file's FILE_BASIC_INFO -- the
    ## creation, last-write AND change times -- the way a deliberate forger
    ## would (``FILE_WRITE_ATTRIBUTES``).
    let access = if write: 0x100'i32 else: 0x80'i32
    let h = createFileW(newWideCString(path), access,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
      OPEN_EXISTING, 0, Handle(0))
    doAssert h != INVALID_HANDLE_VALUE
    defer: discard closeHandle(h)
    if write:
      var v = value
      v.fileAttributes = 0 # leave the attributes alone
      doAssert setFileInformationByHandle(h, 0, addr v,
        DWORD(sizeof(v))) != 0
    else:
      doAssert getFileInformationByHandleEx(h, 0, addr result,
        DWORD(sizeof(result))) != 0

proc exeFile(binDir: string): string =
  when defined(windows): binDir / (ExeName & ".exe") else: binDir / ExeName

proc payload(fill: char; size = PayloadSize): string =
  repeat(fill, size)

proc writeExe(path, bytes: string) =
  writeFile(path, bytes)
  when defined(posix):
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

type Fixture = object
  root, binDir, outDir, exe, savedPath: string

proc outOfRacyWindow() =
  ## The racy window is 2 s from the moment hashing starts; wait it out so
  ## the evidence the next resolution records is trusted.
  sleep(2300)

proc setup(): Fixture =
  result.root = createTempDir("repro-path-rewrite-", "")
  result.binDir = result.root / "bin"
  result.outDir = result.root / "out"
  createDir(result.binDir)
  result.exe = exeFile(result.binDir)
  writeExe(result.exe, payload('A'))
  result.savedPath = getEnv("PATH")
  putEnv("PATH", result.binDir)
  forgetWarmBuildCaches()
  outOfRacyWindow()

proc teardown(f: Fixture) =
  putEnv("PATH", f.savedPath)
  forgetWarmBuildCaches()
  removeDir(f.root)

proc consumer(): ProjectInterfaceArtifact =
  artifactFor(ProjectInterface(projectName: "rewriteConsumer",
    packageName: "rewriteConsumer", defaultToolProvisioning: "path",
    toolUses: @[InterfaceToolUse(rawConstraint: "rwTool",
      packageSelector: "rwTool", executableName: ExeName)]))

proc resolveWarm(f: Fixture): tuple[identity: PathOnlyBuildIdentity;
                                     identityPath: string] =
  let r = warmResolveAndWriteIdentity(consumer(), f.outDir, tpmPathOnly)
  (identity: r.identity, identityPath: r.identityPath)

proc resolveCold(f: Fixture): tuple[identity: PathOnlyBuildIdentity;
                                     identityPath: string] =
  forgetWarmBuildCaches()
  resolveWarm(f)

proc digestOf(identity: PathOnlyBuildIdentity): string =
  identity.profiles[0].resolvedExecutableDigest

proc rewriteKeepingMtime(path, bytes: string) =
  ## In place (same file), then the mtime put back.
  let mtime = getLastModificationTime(path)
  writeExe(path, bytes)
  setLastModificationTime(path, mtime)

proc replaceKeepingMtime(path, bytes: string) =
  ## Deleted and recreated (a new file), then the old mtime put on it.
  let mtime = getLastModificationTime(path)
  removeFile(path)
  writeExe(path, bytes)
  setLastModificationTime(path, mtime)

template checkRewriteServed(before, after: PathOnlyBuildIdentity;
                            bytes: string) =
  check after.digestOf != before.digestOf
  check after.digestOf == "blake3:" & blake3HexText(bytes)
  check after.profiles[0].profileFingerprint !=
    before.profiles[0].profileFingerprint
  check after.actionIdentities[0].actionFingerprint !=
    before.actionIdentities[0].actionFingerprint
  check after.actionIdentities[0].resolvedExecutableDigest == after.digestOf

suite "M7 sibling (7): a path-mode tool rewritten in place is re-resolved":

  test "a same-size in-place rewrite with the mtime put back is re-resolved, warm and cold":
    let f = setup()
    defer: teardown(f)
    let first = resolveWarm(f)
    check first.identity.digestOf == "blake3:" & blake3HexText(payload('A'))
    # The evidence the hit will compare against is NOT racy: what catches
    # the rewrite below is the stat evidence, not the racy-window rule.
    check first.identity.profiles[0].executableEvidence.recorded
    check not first.identity.profiles[0].executableEvidence.racy
    let sizeBefore = getFileSize(f.exe)
    let mtimeBefore = getLastModificationTime(f.exe)
    let before = statExecutable(f.exe).evidence
    rewriteKeepingMtime(f.exe, payload('B'))
    let after = statExecutable(f.exe).evidence
    check getFileSize(f.exe) == sizeBefore
    check getLastModificationTime(f.exe) == mtimeBefore
    check after.mtimeNs == before.mtimeNs
    check after.size == before.size
    check after.fileIdLow == before.fileIdLow
    check after.fileIdHigh == before.fileIdHigh
    check after.ctimeNs != before.ctimeNs
    # Warm.
    let warm = resolveWarm(f)
    checkRewriteServed(first.identity, warm.identity, payload('B'))
    # Cold, from a state whose evidence is again trusted (refreshed out of
    # the racy window by a hit), then rewritten again.
    outOfRacyWindow()
    let settled = resolveCold(f)
    check settled.identity.digestOf == warm.identity.digestOf
    check not readPathOnlyBuildIdentity(settled.identityPath).profiles[0].
      executableEvidence.racy
    rewriteKeepingMtime(f.exe, payload('C'))
    let cold = resolveCold(f)
    checkRewriteServed(settled.identity, cold.identity, payload('C'))

  test "a rewrite with a different size is re-resolved, warm and cold":
    let f = setup()
    defer: teardown(f)
    let first = resolveWarm(f)
    writeExe(f.exe, payload('D', PayloadSize + 1))
    let warm = resolveWarm(f)
    checkRewriteServed(first.identity, warm.identity, payload('D', PayloadSize + 1))
    writeExe(f.exe, payload('E', PayloadSize - 1))
    let cold = resolveCold(f)
    checkRewriteServed(warm.identity, cold.identity, payload('E', PayloadSize - 1))

  test "a replaced executable (deleted and recreated) is caught, warm and cold":
    let f = setup()
    defer: teardown(f)
    let first = resolveWarm(f)
    let idBefore = statExecutable(f.exe).evidence
    replaceKeepingMtime(f.exe, payload('F'))
    let idAfter = statExecutable(f.exe).evidence
    check getFileSize(f.exe) == PayloadSize
    check idAfter.mtimeNs == idBefore.mtimeNs
    check (idAfter.fileIdLow, idAfter.fileIdHigh) !=
      (idBefore.fileIdLow, idBefore.fileIdHigh)
    let warm = resolveWarm(f)
    checkRewriteServed(first.identity, warm.identity, payload('F'))
    replaceKeepingMtime(f.exe, payload('G'))
    let cold = resolveCold(f)
    checkRewriteServed(warm.identity, cold.identity, payload('G'))
    # The SAME bytes recreated: a hit (same digest), with the evidence of
    # the new file persisted.
    let resolvesBefore = warmBuildCacheCounters.toolIdentityResolves
    replaceKeepingMtime(f.exe, payload('G'))
    let same = resolveWarm(f)
    check warmBuildCacheCounters.toolIdentityResolves == resolvesBefore
    check same.identity.digestOf == cold.identity.digestOf
    check same.identity.profiles[0].profileFingerprint ==
      cold.identity.profiles[0].profileFingerprint
    check sameFileState(readPathOnlyBuildIdentity(same.identityPath).
      profiles[0].executableEvidence, statExecutable(f.exe).evidence)

  test "a replaced executable with every time forged back is caught by its file identity":
    # Verifier addition: delete-and-recreate at the same size, then the
    # creation, last-write AND change times put back (``SetFileInformation
    # ByHandle``). Size, mtime and change time all match the recorded
    # evidence; only the FILE IDENTITY differs -- the one field that pins
    # it (without this case, ignoring the file id in ``sameFileState``
    # stayed green: a recreate was always also caught by the change time).
    when defined(windows):
      let f = setup()
      defer: teardown(f)
      let first = resolveWarm(f)
      let recorded = statExecutable(f.exe).evidence
      let times = basicTimes(f.exe)
      removeFile(f.exe)
      writeExe(f.exe, payload('J'))
      discard basicTimes(f.exe, write = true, value = times)
      let forged = statExecutable(f.exe).evidence
      check forged.size == recorded.size
      check forged.mtimeNs == recorded.mtimeNs
      check forged.ctimeNs == recorded.ctimeNs
      check (forged.fileIdLow, forged.fileIdHigh) !=
        (recorded.fileIdLow, recorded.fileIdHigh)
      let warm = resolveWarm(f)
      checkRewriteServed(first.identity, warm.identity, payload('J'))
      let times2 = basicTimes(f.exe)
      removeFile(f.exe)
      writeExe(f.exe, payload('L'))
      discard basicTimes(f.exe, write = true, value = times2)
      let cold = resolveCold(f)
      checkRewriteServed(warm.identity, cold.identity, payload('L'))
    else:
      skip()

  test "a touch with unchanged content is a hit; the refreshed evidence makes the next hit a stat":
    let f = setup()
    defer: teardown(f)
    let first = resolveWarm(f)
    let resolves = warmBuildCacheCounters.toolIdentityResolves
    setLastModificationTime(f.exe, getTime())
    let touched = resolveWarm(f)
    check warmBuildCacheCounters.toolIdentityResolves == resolves
    check touched.identity.digestOf == first.identity.digestOf
    check touched.identity.profiles[0].profileFingerprint ==
      first.identity.profiles[0].profileFingerprint
    check touched.identity.actionIdentities[0].actionFingerprint ==
      first.identity.actionIdentities[0].actionFingerprint
    # Refreshed and persisted: the identity on disk carries the touched
    # file's evidence.
    check sameFileState(readPathOnlyBuildIdentity(touched.identityPath).
      profiles[0].executableEvidence, statExecutable(f.exe).evidence)
    # Cold, out of the racy window: a hit, served from disk.
    outOfRacyWindow()
    let cold = resolveCold(f)
    check cold.identity.digestOf == first.identity.digestOf
    check cold.identity.profiles[0].profileFingerprint ==
      first.identity.profiles[0].profileFingerprint
    # That hit re-hashed (the touch was racy) and refreshed once more; from
    # now on a hit is a stat: nothing is re-read and nothing is rewritten.
    var persisted = readPathOnlyBuildIdentity(cold.identityPath)
    check not persisted.profiles[0].executableEvidence.racy
    check verifyResolvedExecutable(persisted.profiles[0]) == ecCurrent
    let bytesBefore = readFile(cold.identityPath)
    let again = resolveCold(f)
    check again.identity.digestOf == first.identity.digestOf
    check readFile(cold.identityPath) == bytesBefore

  test "the racy-window rule catches a rewrite that leaves every stat field unchanged":
    let f = setup()
    defer: teardown(f)
    let first = resolveWarm(f)
    var profile = first.identity.profiles[0]
    let now = statExecutable(f.exe).evidence
    # Evidence identical to the file's current stat, but the recorded
    # digest is of other bytes -- what a rewrite within the same timestamp
    # tick as the recording would leave behind.
    profile.resolvedExecutableDigest = "blake3:" & repeat('0', 64)
    profile.executableEvidence = now
    profile.executableEvidence.recordedAtNs =
      max(now.mtimeNs, now.ctimeNs) + 500_000_000
    check profile.executableEvidence.racy
    check verifyResolvedExecutable(profile) == ecChanged
    # Recorded well after the file was last written, the same evidence is
    # trusted: a stat check cannot see such a write, and the racy window is
    # the only signal for it.
    profile.executableEvidence.recordedAtNs =
      max(now.mtimeNs, now.ctimeNs) + 10_000_000_000
    check not profile.executableEvidence.racy
    check verifyResolvedExecutable(profile) == ecCurrent
    # And a real digest with racy evidence is re-hashed and refreshed.
    var honest = first.identity.profiles[0]
    honest.executableEvidence.recordedAtNs =
      max(now.mtimeNs, now.ctimeNs) + 100_000_000
    check verifyResolvedExecutable(honest) == ecRefreshed
    check not honest.executableEvidence.racy

  test "a daemon-parent prewarm does not serve a rewritten tool":
    let f = setup()
    defer: teardown(f)
    let first = resolveWarm(f)
    forgetWarmBuildCaches()
    check prewarmDaemonParentCaches(f.outDir).toolIdentities == 1
    rewriteKeepingMtime(f.exe, payload('H'))
    let served = resolveWarm(f)
    checkRewriteServed(first.identity, served.identity, payload('H'))

  test "an identity written without evidence (codec v8) is re-hashed on its first hit":
    let f = setup()
    defer: teardown(f)
    let first = resolveWarm(f)
    var legacy = readPathOnlyBuildIdentity(first.identityPath)
    legacy.profiles[0].executableEvidence = ExecutableEvidence()
    writePathOnlyBuildIdentity(first.identityPath, legacy)
    let cacheDir = f.outDir / "tool-identity-cache"
    for path in walkFiles(cacheDir / "*.rbtp"):
      writePathOnlyBuildIdentity(path, legacy)
    # Unchanged bytes: a hit, and the evidence is recorded from now on.
    let hit = resolveCold(f)
    check hit.identity.digestOf == first.identity.digestOf
    check readPathOnlyBuildIdentity(hit.identityPath).profiles[0].
      executableEvidence.recorded
    # Strip it again, then rewrite: the first hit re-hashes and misses.
    writePathOnlyBuildIdentity(first.identityPath, legacy)
    for path in walkFiles(cacheDir / "*.rbtp"):
      writePathOnlyBuildIdentity(path, legacy)
    rewriteKeepingMtime(f.exe, payload('I'))
    let rewritten = resolveCold(f)
    checkRewriteServed(first.identity, rewritten.identity, payload('I'))

  test "a rewrite is caught on the KEYED cache path (another key stamped since)":
    # The stable identity file serves only the key last stamped; an identity
    # stored under another key is read from ``<key>.rbtp``. Resolve A, then
    # B (the stamp moves to B), rewrite, then A again cold: A's identity
    # comes from the keyed file and must be verified too.
    let f = setup()
    defer: teardown(f)
    let artifactA = consumer()
    var otherInterface = artifactA.projectInterface
    otherInterface.projectName = "rewriteConsumerB"
    let artifactB = artifactFor(otherInterface)
    let keyA = toolIdentityCacheKey(artifactA, tpmPathOnly)
    check toolIdentityCacheKey(artifactB, tpmPathOnly) != keyA
    let first = warmResolveAndWriteIdentity(artifactA, f.outDir, tpmPathOnly)
    discard warmResolveAndWriteIdentity(artifactB, f.outDir, tpmPathOnly)
    check readFile(f.outDir / "tool-identity-cache" / "path.current-key").strip() !=
      keyA
    # Unchanged: A is a keyed hit, not a re-resolution. (The warm-miss
    # counter counts every cold read, disk hit or not; a re-resolution is
    # told apart by the evidence it re-seals -- a new recording time.)
    forgetWarmBuildCaches()
    let hit = warmResolveAndWriteIdentity(artifactA, f.outDir, tpmPathOnly)
    check hit.identity.digestOf == first.identity.digestOf
    check hit.identity.profiles[0].executableEvidence.recordedAtNs ==
      first.identity.profiles[0].executableEvidence.recordedAtNs
    discard warmResolveAndWriteIdentity(artifactB, f.outDir, tpmPathOnly)
    rewriteKeepingMtime(f.exe, payload('K'))
    forgetWarmBuildCaches()
    let served = warmResolveAndWriteIdentity(artifactA, f.outDir, tpmPathOnly)
    checkRewriteServed(first.identity, served.identity, payload('K'))

  test "an action identity naming a digest no verified profile carries is not served":
    let f = setup()
    defer: teardown(f)
    let first = resolveWarm(f)
    var tampered = readPathOnlyBuildIdentity(first.identityPath)
    tampered.actionIdentities[0].resolvedExecutableDigest =
      "blake3:" & repeat('0', 64)
    writePathOnlyBuildIdentity(first.identityPath, tampered)
    for path in walkFiles(f.outDir / "tool-identity-cache" / "*.rbtp"):
      writePathOnlyBuildIdentity(path, tampered)
    let again = resolveCold(f)
    # Re-resolved (re-sealed), not served: the action identity is rebuilt
    # from the profile.
    check again.identity.profiles[0].executableEvidence.recordedAtNs !=
      first.identity.profiles[0].executableEvidence.recordedAtNs
    check again.identity.actionIdentities[0].resolvedExecutableDigest ==
      first.identity.digestOf

  test "the lowered-graph key moves with a rewrite and not with a touch":
    let f = setup()
    defer: teardown(f)
    let artifact = consumer()
    let pathEnv = getEnv("PATH")
    let first = resolveWarm(f)
    proc graphKey(identity: PathOnlyBuildIdentity): string =
      loweredGraphCacheKey(artifact, tpmPathOnly, "provider-artifact", "",
        pathEnv, resolvedIdentity = identity)
    let toolKey = toolIdentityCacheKey(artifact, tpmPathOnly)
    setLastModificationTime(f.exe, getTime())
    let touched = resolveWarm(f)
    check graphKey(touched.identity) == graphKey(first.identity)
    rewriteKeepingMtime(f.exe, payload('J'))
    let rewritten = resolveWarm(f)
    # The tool-identity KEY does not move with a rewrite (it keys on where
    # path resolution lands); the lowered-graph key must, through the
    # resolved identity.
    check toolIdentityCacheKey(artifact, tpmPathOnly) == toolKey
    check graphKey(rewritten.identity) != graphKey(first.identity)
    check resolvedToolIdentityDigest(rewritten.identity) !=
      resolvedToolIdentityDigest(first.identity)
