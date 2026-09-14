## M6 (Realize-Closure-And-Catalog-Expansion spec) hermetic tests for
## the cakBuiltin ``imMsys2Pacman`` realize hook + the ``afTarZst``
## extractor discovery.
##
## The fixture ``tests/fixtures/m6/mingw-w64-x86_64-fake-tool-...-any.pkg.tar.zst``
## is a synthetic .pkg.tar.zst built once and checked in. Its payload
## mirrors a real MSYS2 mingw64 package:
##
##   .PKGINFO
##   mingw64/bin/fake-tool.exe
##   mingw64/lib/fake-tool/data.txt
##   mingw64/share/doc/fake-tool/README
##
## Tests load this fixture via a ``file://`` URL and verify:
##
##   * test_m6_extractor_discovery_returns_usable_extractor
##   * test_m6_realize_imMsys2Pacman_extracts_and_flattens
##   * test_m6_realize_imMsys2Pacman_cache_hit_on_re_realize
##   * test_m6_realize_imMsys2Pacman_fails_closed_without_extractor
##
## W13 adds two cases that drive discovery step (iii) — the ``zekZstdPipe``
## arm — against the same fixture, by CONSTRUCTING the extractor record rather
## than discovering it. Discovery reaches that arm only on a host with bare
## ``zstd`` + ``tar`` and no zstd-capable ``7z``/``tar``, so the arm carried a
## shell-assuming ``zstd … | tar …`` command string that no test ever ran:
##
##   * test_m6_zstd_pipe_arm_extracts_real_bytes_without_a_shell
##   * test_m6_zstd_pipe_arm_reports_a_corrupt_archive_loudly
##
## W16 adds four more, because the first of those two was GREEN FOR THE WRONG
## REASON: it extracted into ``createTempDir("m6-zstd-pipe-", "")`` and GNU tar
## unquotes command-line names, so the case passed on a property of the
## temporary directory's NAME rather than of the extractor. Three of the four
## drive destinations and archive paths that a Windows tar actually mangles,
## in BOTH tar-using arms; the fourth covers the hang guard W13 landed
## uncovered, in a bounded child process:
##
##   * test_m6_zstd_pipe_arm_extracts_into_destinations_gnu_tar_would_unquote
##   * test_m6_tar_filter_arm_extracts_into_destinations_gnu_tar_would_unquote
##   * test_m6_tar_filter_arm_opens_an_absolute_windows_archive_path
##   * test_m6_zstd_pipe_arm_returns_when_tar_exits_without_reading_its_stdin

import std/[monotimes, os, osproc, streams, strutils, tempfiles, times, unittest]
from repro_core/paths import extendedPath

import repro_local_store
import repro_dsl_stdlib/packages_schema

import repro_home_apply/package_catalog
import repro_home_apply/builtin_adapter

const FixtureRoot = "build/test-tmp/t-builtin-adapter-msys2"
const M6FixtureArchive = "libs/repro_home_apply/tests/fixtures/m6/" &
  "mingw-w64-x86_64-fake-tool-1.0.0-1-any.pkg.tar.zst"

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc fileToUrl(absPath: string): string =
  let normalized = absPath.replace('\\', '/')
  when defined(windows):
    if normalized.len >= 2 and normalized[1] == ':':
      "file:///" & normalized
    else:
      "file://" & normalized
  else:
    "file://" & normalized

# ---------------------------------------------------------------------------
# W16 — shared machinery for the destination-path cases
# ---------------------------------------------------------------------------

const W16Root = "build/test-tmp/t-builtin-adapter-msys2-w16"
  ## Deliberately RELATIVE and forward-slash-only, and deliberately NOT
  ## ``createTempDir``.
  ##
  ## The defect under test is that GNU tar unquotes backslash escapes in the
  ## path it is handed, so what the test proves depends entirely on which
  ## backslashes are in that path. A temp root is the wrong base for that: it
  ## is whatever ``TMPDIR`` happens to be, and W13's case passed only because
  ## ``…\Local\Temp\m6-zstd-pipe-XXXXXXXX`` contained no escape letter — a
  ## property of the host, not of the code. How fragile that is, measured: the
  ## first scratch root W16 was probed in happened to be
  ## ``…\Temp\claude\M--m-dev\7b45a1a7-…\scratchpad\`` and GNU tar read the
  ## ``\7`` as an OCTAL escape, so EVERY leaf failed — including the two that
  ## are supposed to succeed — before the leaf mattered at all. Any component
  ## of a temp path can do that, and none of them is this test's to control.
  ##
  ## With this base the ONLY backslash in the destination is the separator the
  ## helper below puts in front of the leaf, so each case's verdict is a
  ## statement about its own leaf and a mutation reds exactly the case it
  ## breaks. ``w16DestFor`` asserts that shape rather than assuming it.

const W16RaisingFirstChars = {'a', 'b', 'f', 'n', 'r', 't', 'v'}
  ## The seven letters GNU tar turns into a control character, measured
  ## against this product and this fixture. ``\0`` is deliberately NOT in this
  ## set: it is the one that does NOT raise, and it is asserted separately
  ## because its symptom is different in kind.

proc w16AssertLeavesStillTestW16(leaves: openArray[string]) =
  ## THE anti-dodge control, and the reason this test is not the next W13.
  ##
  ## Every assertion below about extraction is only meaningful if the leaf
  ## names actually trigger GNU tar's unquoting. Rename them to safe letters
  ## — which is all it took for W13's case to go green against a broken
  ## product — and every check would still pass while testing nothing. So the
  ## leaf set is CHECKED, here, before any extraction: at least one of the
  ## seven raising letters, and the silent ``\0`` case.
  var raising = 0
  var nul = 0
  for leaf in leaves:
    doAssert leaf.len > 0
    if leaf[0] == '0': inc nul
    elif leaf[0] in W16RaisingFirstChars: inc raising
  doAssert raising >= 1,
    "W16 leaf set no longer contains one of " & $W16RaisingFirstChars &
    ", so it cannot observe the raising half of the defect: " & $(@leaves)
  doAssert nul >= 1,
    "W16 leaf set no longer contains the `\\0` case, so it cannot observe " &
    "the SILENT half — the one that writes into the parent and reports " &
    "success: " & $(@leaves)

proc w16DestFor(caseRoot, leaf: string): string =
  ## ``<caseRoot><DirSep><leaf>``, with the path SHAPE asserted rather than
  ## assumed: on Windows the separator in front of the leaf must be a
  ## backslash and it must be the ONLY one in the whole path.
  ##
  ## Both halves matter. Without the first there is nothing for tar to
  ## unquote; without the second a backslash elsewhere in the path could red
  ## a case for a reason that has nothing to do with its leaf — which is
  ## exactly what happened when W16 was first probed under a scratch root
  ## containing ``\7``.
  result = caseRoot & $DirSep & leaf
  when defined(windows):
    doAssert result.contains('\\' & leaf[0]),
      "W16 destination no longer puts the leaf straight after a backslash: " &
      result
    doAssert result.count('\\') == 1,
      "W16 destination must carry EXACTLY ONE backslash so a red names one " &
      "cause: " & result
  else:
    # On POSIX there is no backslash in the path at all, so GNU tar has
    # nothing to unquote and this case cannot speak to the defect. Say so in
    # an assertion rather than let the green imply otherwise.
    doAssert not result.contains('\\'),
      "a POSIX path with a literal backslash is the KNOWN RESIDUAL described " &
      "in builtin_adapter's W16 comment, not something this case covers: " &
      result

proc w16Reset(caseRoot: string) =
  if dirExists(extendedPath(caseRoot)):
    removeDir(extendedPath(caseRoot))
  createDir(extendedPath(caseRoot))

proc w16EntriesDirectlyUnder(dir: string): seq[string] =
  for _, entry in walkDir(extendedPath(dir), relative = true):
    result.add(entry)

proc w16CheckExtractedTree(destDir: string): tuple[ok: bool, why: string] =
  ## The archive's four entries, on disk under ``destDir``, with their real
  ## bytes. Existence alone is not enough: an extractor that created empty
  ## placeholders would satisfy it.
  let binPath = destDir / "mingw64" / "bin" / "fake-tool.exe"
  let dataPath = destDir / "mingw64" / "lib" / "fake-tool" / "data.txt"
  let readmePath = destDir / "mingw64" / "share" / "doc" / "fake-tool" / "README"
  let pkgInfoPath = destDir / ".PKGINFO"
  for p in [binPath, dataPath, readmePath, pkgInfoPath]:
    if not fileExists(extendedPath(p)):
      return (false, "missing: " & p)
  if not readFile(extendedPath(binPath)).contains("stub-fake-tool-binary-payload"):
    return (false, "wrong bytes in " & binPath)
  if not readFile(extendedPath(dataPath)).contains("stub fixture lib payload"):
    return (false, "wrong bytes in " & dataPath)
  if not readFile(extendedPath(pkgInfoPath)).contains("mingw-w64-x86_64-fake-tool"):
    return (false, "wrong bytes in " & pkgInfoPath)
  (true, "")

proc w16FixtureArchive(): string =
  ## Anchored on THIS source file, not the process working directory: the
  ## fixture is an input and the cwd is not one.
  currentSourcePath().parentDir / "fixtures" / "m6" /
    "mingw-w64-x86_64-fake-tool-1.0.0-1-any.pkg.tar.zst"

proc w16RelativeArchiveCopy(): string =
  ## A copy of the fixture at a RELATIVE, forward-slash-only path.
  ##
  ## The two destination cases are about ONE variable — the destination's
  ## leaf. Handing them the fixture at its real absolute location would put a
  ## SECOND Windows defect in the same call (a drive-lettered ``-f`` operand,
  ## which GNU tar reads as ``host:path``), and a red would no longer name one
  ## cause. Measured: with ``--force-local`` removed, the absolute archive
  ## reddened the destination cases too. The copy removes that coupling, and
  ## the absolute-path case below is then the sole witness for that defect.
  let archiveDir = W16Root & "/archive"
  createDir(extendedPath(archiveDir))
  result = archiveDir & "/fake-tool.pkg.tar.zst"
  copyFile(extendedPath(w16FixtureArchive()), extendedPath(result))
  doAssert not result.contains('\\'),
    "the isolating archive copy must carry no backslash: " & result

# ---------------------------------------------------------------------------
# W16 — the child role for the BOUNDED hang-guard case
# ---------------------------------------------------------------------------
#
# ``extractTarZst`` is a synchronous call, so a test for "it does not hang"
# cannot be written in-process: if the guard is gone, the test hangs too, and
# a test for a hang that can itself hang is worse than no test.
#
# So the case runs the extraction in a SEPARATE PROCESS — this same binary,
# re-invoked with the env var below — and waits on it with a hard deadline.
# Exceeding the deadline is a FAILURE with a message naming what hung, not a
# hang.
#
# ``quit`` here is the child ROLE ending, not a verdict: this process was
# spawned for exactly one call and the parent decides what its exit means.
# Nothing in this block reports a test result, so the rule that a helper must
# use ``doAssert`` rather than ``quit`` (stock ``unittest.fail`` sets the exit
# code only inside a test body) is not in play.
#
# This block must precede the ``suite`` below: ``suite``/``test`` are
# templates that run at module-init in declaration order, and the child must
# not execute the suite.
const W16HangChildEnv = "REPRO_W16_HANG_GUARD_CHILD"

let w16ChildSpec = getEnv(W16HangChildEnv)
if w16ChildSpec.len > 0:
  # ``<zstdExe>|<archive>|<destDir>``
  let parts = w16ChildSpec.split('|')
  doAssert parts.len == 3, "bad W16 child spec: " & w16ChildSpec
  # ``tarExeForPipe`` is pointed at the ZSTD binary on purpose. ``zstd``
  # rejects ``-xf`` ("Incorrect parameter: -x") and exits WITHOUT reading its
  # stdin — measured — which is precisely the shape the guard exists for: the
  # copy loop's write fails, the loop breaks BEFORE the decompressor's EOF,
  # and the real ``zstd -dc`` on the other side is left blocked writing into a
  # pipe nobody drains. Paired with a multi-megabyte decompressed stream it
  # cannot finish on its own, so without the guard ``waitForExit`` never
  # returns.
  #
  # The two markers are what stops the parent's deadline check from passing
  # for a reason other than the guard: a child that exited fast because it
  # never reached ``extractTarZst`` prints the first and not the second, and
  # the parent requires BOTH.
  echo "W16-CHILD-ENTERED"
  flushFile(stdout)
  let extractor = ZstdExtractor(kind: zekZstdPipe,
    zstdExe: parts[0], tarExeForPipe: parts[0])
  try:
    extractTarZst("w16-hang-guard", parts[1], parts[2], extractor)
  except CatchableError:
    # WHICH error, or whether one is raised at all, is not this case's claim.
    # The claim is that control RETURNS. Reaching the marker below is the
    # whole observation.
    discard
  echo "W16-CHILD-RETURNED"
  flushFile(stdout)
  quit(0)

suite "M6 — cakBuiltin imMsys2Pacman realize hook + afTarZst":

  test "test_m6_extractor_discovery_returns_usable_extractor":
    ## Discovery picks one of the three strategies on the host. We do
    ## NOT assert which one — the test asserts only that the
    ## discoverer returned a usable record, exercising the
    ## prefix-lookup / tar-filter / zstd-pipe walk end-to-end.
    let fixtureDir = FixtureRoot / "discover"
    let storeDir = fixtureDir / "store"
    resetDir(fixtureDir); resetDir(storeDir)
    var store = openStore(storeDir)
    defer: store.close()
    try:
      let extractor = discoverZstdExtractor(store, "m6-test-tool")
      check extractor.kind in {zekSevenZip, zekTarFilter, zekZstdPipe}
    except EBuiltinZstdUnavailable:
      echo "  [skip] host has no zstd-capable extractor (full 7z, " &
        "tar --zstd / bsdtar+libzstd, or zstd)"
      skip()

  test "test_m6_realize_imMsys2Pacman_extracts_and_flattens":
    ## End-to-end realize against the checked-in fixture: the
    ## prefix carries ``bin/fake-tool.exe`` + the sibling
    ## ``lib/fake-tool/data.txt`` (mingw64/ husk flattened).
    if not fileExists(extendedPath(M6FixtureArchive)):
      echo "  [skip] M6 fixture archive missing: " & M6FixtureArchive
      skip()
    else:
      let fixtureDir = FixtureRoot / "realize-flatten"
      let storeDir = fixtureDir / "store"
      resetDir(fixtureDir); resetDir(storeDir)
      let archiveAbs = absolutePath(M6FixtureArchive)
      let sha = fileShaHex(archiveAbs, "sha256")
      var store = openStore(storeDir)
      defer: store.close()
      let vp = initVersionedProvisioning(
        version = "1.0.0-1",
        archive_format = afTarZst,
        install_method = imMsys2Pacman,
        bin_relpath = @["bin/fake-tool.exe"],
        platforms = @[
          initPlatformBinary(
            cpu = detectHostCpu(), os = detectHostOs(),
            url = fileToUrl(archiveAbs),
            sha256 = sha,
            extract_path = "mingw64")
        ],
        pacman_packages = @["mingw-w64-x86_64-fake-tool"])
      let res = resolveBuiltinPackage("fake-tool", @[vp])
      check res.found
      check res.resolution.archiveFormat == afTarZst
      check res.resolution.installMethod == imMsys2Pacman
      var skipFlatten = false
      var outR: RealizeBuiltinResult
      try:
        outR = realizeBuiltinPackage(store, res.resolution)
      except EBuiltinZstdUnavailable:
        echo "  [skip] no zstd extractor available on host"
        skipFlatten = true
      if not skipFlatten:
        check (not outR.cacheHit)
        let realizedBin = outR.prefixAbsolutePath / "bin" / "fake-tool.exe"
        check fileExists(extendedPath(realizedBin))
        check readFile(extendedPath(realizedBin)).contains(
          "stub-fake-tool-binary-payload")
        let realizedData = outR.prefixAbsolutePath / "lib" /
          "fake-tool" / "data.txt"
        check fileExists(extendedPath(realizedData))
        # Inner mingw64/ husk should be gone after flatten.
        check (not dirExists(extendedPath(
          outR.prefixAbsolutePath / "mingw64")))

  test "test_m6_realize_imMsys2Pacman_cache_hit_on_re_realize":
    ## Re-realize against the same prefixId is a cache hit. Mirrors
    ## the M64 cache-hit invariant for the new install_method
    ## dispatch.
    if not fileExists(extendedPath(M6FixtureArchive)):
      echo "  [skip] M6 fixture archive missing"
      skip()
    else:
      let fixtureDir = FixtureRoot / "cache-hit"
      let storeDir = fixtureDir / "store"
      resetDir(fixtureDir); resetDir(storeDir)
      let archiveAbs = absolutePath(M6FixtureArchive)
      let sha = fileShaHex(archiveAbs, "sha256")
      var store = openStore(storeDir)
      defer: store.close()
      let vp = initVersionedProvisioning(
        version = "1.0.0-1",
        archive_format = afTarZst,
        install_method = imMsys2Pacman,
        bin_relpath = @["bin/fake-tool.exe"],
        platforms = @[
          initPlatformBinary(
            cpu = detectHostCpu(), os = detectHostOs(),
            url = fileToUrl(archiveAbs),
            sha256 = sha,
            extract_path = "mingw64")
        ],
        pacman_packages = @["mingw-w64-x86_64-fake-tool"])
      let res = resolveBuiltinPackage("fake-tool", @[vp])
      check res.found
      var skipCache = false
      var first: RealizeBuiltinResult
      try:
        first = realizeBuiltinPackage(store, res.resolution)
      except EBuiltinZstdUnavailable:
        echo "  [skip] no zstd extractor on host"
        skipCache = true
      if not skipCache:
        check (not first.cacheHit)
        let second = realizeBuiltinPackage(store, res.resolution)
        check second.cacheHit
        check second.prefixAbsolutePath == first.prefixAbsolutePath

  test "test_m6_realize_imMsys2Pacman_fails_closed_without_extractor":
    ## Discovery (iv): when no zstd-capable extractor is on PATH AND
    ## no catalog 7zip prefix carries the codec, the realize raises
    ## ``EBuiltinZstdUnavailable`` with a populated discovery trace.
    let fixtureDir = FixtureRoot / "fail-closed"
    let storeDir = fixtureDir / "store"
    resetDir(fixtureDir); resetDir(storeDir)
    let emptyDir = fixtureDir / "empty-path"
    resetDir(emptyDir)
    let savedPath = getEnv("PATH")
    putEnv("PATH", emptyDir)
    defer: putEnv("PATH", savedPath)
    var store = openStore(storeDir)
    defer: store.close()
    var raised = false
    var traceLen = 0
    var pkg = ""
    try:
      discard discoverZstdExtractor(store, "needy-tool")
    except EBuiltinZstdUnavailable as err:
      raised = true
      traceLen = err.discoveryTrace.len
      pkg = err.packageId
    check raised
    check pkg == "needy-tool"
    check traceLen >= 1

  test "test_m6_zstd_pipe_arm_extracts_real_bytes_without_a_shell":
    ## W13 — discovery step (iii), the ``zekZstdPipe`` arm, FORCED and driven
    ## against the real checked-in ``.tar.zst``.
    ##
    ## The arm used to build ``zstd -dc <archive> | tar -xf - -C <dest>`` as ONE
    ## command string for ``execCmdEx``, under a comment asserting that
    ## "``execCmdEx`` runs through cmd.exe on Windows, which honors ``|``
    ## natively". No ``cmd.exe`` is in that path: ``execCmdEx`` adds
    ## ``poEvalCommand`` and Windows ``startProcess`` hands the line to
    ## ``CreateProcessW`` VERBATIM, so ``|``, the tar path and its three
    ## arguments all arrived as ARGV to ``zstd`` and nothing was ever extracted.
    ## The pipe is now connected in-process, with no shell on either platform.
    ##
    ## FORCED rather than discovered: ``discoverZstdExtractor`` reaches step
    ## (iii) only on a host with bare ``zstd`` + ``tar`` and no zstd-capable
    ## ``7z``/``tar``, so on most hosts — including this one, which has a
    ## zstd-capable ``7z`` — a discovery-driven test would silently assert some
    ## OTHER arm. Constructing the record by hand is the only way to make the
    ## claim about the arm the milestone is about.
    ##
    ## It asserts EXTRACTION, not argv shape: the files the archive carries are
    ## on disk afterwards with their real contents. A test that only checked
    ## that no ``|`` reaches a command line would pass against an extractor
    ## that spawns nothing at all.
    ##
    ## Falsifiability: restore the single-command-string form and on Windows
    ## the first two checks fail (``zstd`` rejects the extra arguments, tar
    ## never runs, and ``raiseExtractFailed`` fires instead) — measured. Break
    ## the copy loop (write nothing into tar's stdin) and ``tar`` exits with an
    ## empty-archive error, so the raise-free assertion fails. Point the
    ## extractor at the archive without decompressing and the CONTENT checks
    ## fail rather than the existence ones.
    let zstdExe = findExe("zstd")
    let tarExe = findExe("tar")
    # Anchor on THIS source file, not the process working directory: the
    # fixture is an input and the cwd is not one (the Class-A trap).
    let fixtureArchive = currentSourcePath().parentDir /
      "fixtures" / "m6" / "mingw-w64-x86_64-fake-tool-1.0.0-1-any.pkg.tar.zst"
    if zstdExe.len == 0 or tarExe.len == 0:
      echo "  [skip] this arm needs BOTH a bare `zstd` and a `tar` on PATH" &
        " (zstd=" & zstdExe & " tar=" & tarExe & ")"
      skip()
    elif not fileExists(extendedPath(fixtureArchive)):
      echo "  [skip] M6 fixture archive missing: " & fixtureArchive
      skip()
    else:
      let destDir = createTempDir("m6-zstd-pipe-", "")
      defer: removeDir(extendedPath(destDir))
      let extractor = ZstdExtractor(kind: zekZstdPipe,
        zstdExe: zstdExe, tarExeForPipe: tarExe)
      var raisedWith = ""
      try:
        extractTarZst("m6-zstd-pipe", fixtureArchive, destDir, extractor)
      except EBuiltinExtractFailed as err:
        raisedWith = err.msg
      if raisedWith.len > 0:
        checkpoint("extractTarZst raised: " & raisedWith)
      check raisedWith.len == 0
      # The archive's own entries, on disk, with their real bytes. No flatten
      # happens here (``flattenExtractPath`` is a separate step), so the
      # ``mingw64/`` husk the tarball carries is still the top level.
      let binPath = destDir / "mingw64" / "bin" / "fake-tool.exe"
      let dataPath = destDir / "mingw64" / "lib" / "fake-tool" / "data.txt"
      let pkgInfoPath = destDir / ".PKGINFO"
      check fileExists(extendedPath(binPath))
      check fileExists(extendedPath(dataPath))
      check fileExists(extendedPath(pkgInfoPath))
      check readFile(extendedPath(binPath)).contains(
        "stub-fake-tool-binary-payload")
      check readFile(extendedPath(dataPath)).contains(
        "stub fixture lib payload")
      check readFile(extendedPath(pkgInfoPath)).contains(
        "mingw-w64-x86_64-fake-tool")

  test "test_m6_zstd_pipe_arm_reports_a_corrupt_archive_loudly":
    ## The other half of the arm: a file that is NOT zstd must fail closed with
    ## the structured extractor error, naming the package and carrying both
    ## children's evidence — not silently produce an empty prefix. Without this
    ## case the arm above would be satisfied by an extractor that could not
    ## distinguish success from failure at all.
    ##
    ## Falsifiability: make the arm ignore the children's exit codes and this
    ## case's ``raised`` check fails.
    let zstdExe = findExe("zstd")
    let tarExe = findExe("tar")
    if zstdExe.len == 0 or tarExe.len == 0:
      echo "  [skip] this arm needs BOTH a bare `zstd` and a `tar` on PATH"
      skip()
    else:
      let scratch = createTempDir("m6-zstd-pipe-bad-", "")
      defer: removeDir(extendedPath(scratch))
      let bogus = scratch / "not-really-zstd.tar.zst"
      writeFile(extendedPath(bogus), "this is not a zstd frame\n")
      let destDir = scratch / "dest"
      let extractor = ZstdExtractor(kind: zekZstdPipe,
        zstdExe: zstdExe, tarExeForPipe: tarExe)
      var raised = false
      var message = ""
      var reportedPackage = ""
      try:
        extractTarZst("m6-bogus-zstd", bogus, destDir, extractor)
      except EBuiltinExtractFailed as err:
        raised = true
        message = err.msg
        reportedPackage = err.packageId
      checkpoint("corrupt-archive message: " & message)
      check raised
      check reportedPackage == "m6-bogus-zstd"
      # The diagnostic must say WHICH child failed and what it said, or an
      # operator is left with "extraction failed" and nothing to act on.
      check "zstd exit=" in message
      check "tar exit=" in message
      check "byte(s) piped" in message

  test "test_m6_zstd_pipe_arm_extracts_into_destinations_gnu_tar_would_unquote":
    ## W16 — the half of the ``zekZstdPipe`` defect W13 did not remove.
    ##
    ## W13 took the shell out of the pipe. It left the OTHER Windows
    ## assumption in the same three lines: that a Windows path survives being
    ## handed to ``tar`` as an argv element. It does not. GNU tar UNQUOTES
    ## command-line names — ``--unquote`` is the DEFAULT — so every backslash
    ## before an escape letter is consumed. Measured pre-fix on GNU tar 1.35
    ## driving THIS product at THIS fixture, changing only the leaf name:
    ##
    ##   m6-zstd-pipe-AAA  11 entries, exit 0    <- W13's own leaf: green
    ##   extra-AAA         11 entries, exit 0    <- ``\e`` is not an escape
    ##   alpha bravo foxtrot nope rvw13 tango verbose
    ##                      0 entries, tar exit=2, "Cannot open"
    ##   0zero-AAA          0 entries IN THE DEST, exit 0, NO ERROR
    ##
    ## The ``\0`` row is why this case exists in this shape. The NUL
    ## terminates tar's C string, ``-C`` names the PARENT, tar chdirs into it,
    ## extracts and exits 0 — a package written OUTSIDE its prefix with a
    ## SUCCESS verdict. Pre-fix, ``.PKGINFO`` and the whole ``mingw64/`` tree
    ## were measured sitting next to an empty destination. That failure mode
    ## produces no error, so the parent-is-clean assertion below is the only
    ## thing that can see it, and it is asserted per leaf rather than once.
    ##
    ## WHAT WOULD MAKE THIS PASS VACUOUSLY, and why it cannot:
    ##
    ##   * The leaf names drift to letters GNU tar does not escape — exactly
    ##     how W13 stayed green, and all it would take. Ruled out by
    ##     ``w16AssertLeavesStillTestW16``, which runs BEFORE any extraction
    ##     and fails unless the set still holds one of the seven raising
    ##     letters AND the silent ``\0`` case. Verified by mutation: renaming
    ##     the leaves to ``sierra/xray/extra`` reds this case with
    ##     "W16 leaf set no longer contains one of {'a','b',…}" rather than
    ##     passing.
    ##   * The destination stops putting the leaf behind a backslash, or picks
    ##     up a SECOND one somewhere else so a red names the wrong cause.
    ##     Ruled out by ``w16DestFor``, which asserts exactly-one backslash
    ##     immediately before the leaf.
    ##   * The parent looks clean because nothing was extracted at all. Ruled
    ##     out by requiring the four real entries WITH their bytes in the
    ##     destination in the same breath.
    ##   * The archive operand contributes a failure of its own, so a red
    ##     stops naming the destination. Ruled out by
    ##     ``w16RelativeArchiveCopy``: the archive here is relative and
    ##     backslash-free, and the separate absolute-path case below is the
    ##     sole witness for that other defect.
    ##   * The case skips because ``zstd``/``tar`` is absent. Not silent: the
    ##     skip names both resolved paths, and the checkpoint below records
    ##     WHICH tar was exercised so a green can be attributed.
    ##
    ## Falsifiability, measured: drop ``tarOperand`` from the ``-C`` argument
    ## in the ``zekZstdPipe`` arm and this case alone goes red — the seven
    ## letter leaves raise and ``0zero`` fails the clean-parent assertion.
    let zstdExe = findExe("zstd")
    let tarExe = findExe("tar")
    let fixtureSource = w16FixtureArchive()
    if zstdExe.len == 0 or tarExe.len == 0:
      echo "  [skip] this arm needs BOTH a bare `zstd` and a `tar` on PATH" &
        " (zstd=" & zstdExe & " tar=" & tarExe & ")"
      skip()
    elif not fileExists(extendedPath(fixtureSource)):
      echo "  [skip] M6 fixture archive missing: " & fixtureSource
      skip()
    else:
      checkpoint("tar under test: " & tarExe)
      checkpoint("zstd under test: " & zstdExe)
      let fixtureArchive = w16RelativeArchiveCopy()
      let extractor = ZstdExtractor(kind: zekZstdPipe,
        zstdExe: zstdExe, tarExeForPipe: tarExe)
      # ``t`` is the letter a future author writes without thinking; ``0`` is
      # the one that does not fail. ``m6-zstd-pipe`` is W13's own leaf, kept
      # as the control that was green for the wrong reason — measured: under
      # every mutation below it stays GREEN, which is the whole point.
      let leaves = ["tango-AAA", "rvw13-AAA", "0zero-AAA", "m6-zstd-pipe-AAA"]
      w16AssertLeavesStillTestW16(leaves)
      for leaf in leaves:
        let caseRoot = W16Root & "/pipe-" & leaf
        w16Reset(caseRoot)
        let destDir = w16DestFor(caseRoot, leaf)
        createDir(extendedPath(destDir))
        var raisedWith = ""
        try:
          extractTarZst("m6-w16-pipe", fixtureArchive, destDir, extractor)
        except EBuiltinExtractFailed as err:
          raisedWith = err.msg
        checkpoint("leaf=" & leaf & " dest=" & destDir &
          (if raisedWith.len > 0: " raised: " & raisedWith else: " (no raise)"))
        check raisedWith.len == 0
        # IN the intended directory ...
        let tree = w16CheckExtractedTree(destDir)
        checkpoint("leaf=" & leaf & " tree verdict: " &
          (if tree.ok: "complete" else: tree.why))
        check tree.ok
        # ... AND NOWHERE ELSE. The parent must hold the destination and
        # nothing besides it. Pre-fix, the ``0zero`` leaf put ``.PKGINFO`` and
        # ``mingw64`` right here while the destination stayed empty, and
        # reported success doing it.
        let siblings = w16EntriesDirectlyUnder(caseRoot)
        checkpoint("leaf=" & leaf & " entries directly under the parent: " &
          siblings.join(", "))
        check siblings == @[leaf]

  test "test_m6_tar_filter_arm_extracts_into_destinations_gnu_tar_would_unquote":
    ## W16, the other half: ``zekTarFilter`` is discovery step (ii) — the arm
    ## a Git-for-Windows host NORMALLY takes — and it carried the identical
    ## construction. ``quoteShell`` is no defence: on Windows it adds quotes
    ## only when the string contains WHITESPACE, and the argv parser strips
    ## them before tar sees the value.
    ##
    ## Nothing had been seen here because this arm's other M6 tests extract
    ## into ``build/test-tmp/…`` — relative, forward-slash-rooted, no
    ## backslash to unquote.
    ##
    ## Same vacuity analysis as the case above, and one addition: this arm
    ## could pass by falling through to its bsdtar attempt on a host whose
    ## ``tar`` is libarchive, which does not unquote and so cannot fail. The
    ## checkpoint records the tar binary and its banner so a green is
    ## attributable to a specific implementation rather than to "some tar".
    ##
    ## Falsifiability, measured: drop ``tarOperand`` from this arm's ``-C``
    ## argument and this case alone goes red against a GNU tar.
    let tarExe = findExe("tar")
    let fixtureSource = w16FixtureArchive()
    if tarExe.len == 0:
      echo "  [skip] this arm needs a `tar` on PATH"
      skip()
    elif not fileExists(extendedPath(fixtureSource)):
      echo "  [skip] M6 fixture archive missing: " & fixtureSource
      skip()
    else:
      let banner = execCmdEx(quoteShell(tarExe) & " --version")
      checkpoint("tar under test: " & tarExe & " -> " &
        (if banner.output.len == 0: "<no banner>"
         else: banner.output.splitLines()[0]))
      let fixtureArchive = w16RelativeArchiveCopy()
      let extractor = ZstdExtractor(kind: zekTarFilter, tarExe: tarExe)
      let leaves = ["tango-AAA", "verbose-AAA", "0zero-AAA",
                    "m6-tar-filter-AAA"]
      w16AssertLeavesStillTestW16(leaves)
      for leaf in leaves:
        let caseRoot = W16Root & "/filter-" & leaf
        w16Reset(caseRoot)
        let destDir = w16DestFor(caseRoot, leaf)
        createDir(extendedPath(destDir))
        var raisedWith = ""
        try:
          extractTarZst("m6-w16-filter", fixtureArchive, destDir, extractor)
        except EBuiltinExtractFailed as err:
          raisedWith = err.msg
        checkpoint("leaf=" & leaf & " dest=" & destDir &
          (if raisedWith.len > 0: " raised: " & raisedWith else: " (no raise)"))
        check raisedWith.len == 0
        let tree = w16CheckExtractedTree(destDir)
        checkpoint("leaf=" & leaf & " tree verdict: " &
          (if tree.ok: "complete" else: tree.why))
        check tree.ok
        let siblings = w16EntriesDirectlyUnder(caseRoot)
        checkpoint("leaf=" & leaf & " entries directly under the parent: " &
          siblings.join(", "))
        check siblings == @[leaf]

  test "test_m6_tar_filter_arm_opens_an_absolute_windows_archive_path":
    ## W16, found while fixing the above and NOT the unquoting defect: GNU tar
    ## reads an operand of ``-f`` whose first ``:`` precedes any ``/`` as a
    ## REMOTE ``host:path`` spec and tries to reach the host. Every absolute
    ## Windows archive path is that shape, escape letters or not. Measured
    ## against this very fixture, pre-fix:
    ##
    ##   tar (child): Cannot connect to M: resolve failed
    ##   tar: Child returned status 128                     (exit 2, 0 files)
    ##
    ## Forward slashes do NOT help (``C:/…`` fails identically) and neither
    ## does a ``./`` prefix (measured: fails on GNU tar AND on bsdtar). The
    ## remedy is ``--force-local``, a GNU extension bsdtar rejects outright —
    ## which is why the arm offers it in an attempt that is ALLOWED TO FAIL
    ## and retries the bsdtar shape.
    ##
    ## WHAT WOULD MAKE THIS PASS VACUOUSLY: the archive operand ceasing to be
    ## an absolute drive-lettered path — precisely the property that kept this
    ## invisible, since the existing M6 cases pass a relative one. Asserted
    ## below before the extraction, so the case cannot quietly stop testing
    ## it. On POSIX there is no drive letter and no remote misreading, so the
    ## case asserts that instead of implying coverage it does not have.
    ##
    ## Falsifiability, measured: remove ``--force-local`` from the arm's
    ## GNU-only flags and this case alone goes red on Windows.
    let tarExe = findExe("tar")
    let fixtureArchive = absolutePath(w16FixtureArchive())
    if tarExe.len == 0:
      echo "  [skip] this arm needs a `tar` on PATH"
      skip()
    elif not fileExists(extendedPath(fixtureArchive)):
      echo "  [skip] M6 fixture archive missing: " & fixtureArchive
      skip()
    else:
      checkpoint("absolute archive operand: " & fixtureArchive)
      when defined(windows):
        # The precondition this case rests on, asserted rather than assumed.
        check fixtureArchive.len >= 2 and fixtureArchive[1] == ':'
      else:
        check not fixtureArchive.contains(':')
      let caseRoot = W16Root & "/filter-abs"
      w16Reset(caseRoot)
      # A deliberately SAFE leaf: this case is about the ``-f`` operand, and a
      # destination that could fail on its own would blur which defect a red
      # names.
      let destDir = caseRoot & "/dest"
      createDir(extendedPath(destDir))
      let extractor = ZstdExtractor(kind: zekTarFilter, tarExe: tarExe)
      var raisedWith = ""
      try:
        extractTarZst("m6-w16-abs", fixtureArchive, destDir, extractor)
      except EBuiltinExtractFailed as err:
        raisedWith = err.msg
      if raisedWith.len > 0:
        checkpoint("extractTarZst raised: " & raisedWith)
      check raisedWith.len == 0
      let tree = w16CheckExtractedTree(destDir)
      checkpoint("tree verdict: " & (if tree.ok: "complete" else: tree.why))
      check tree.ok

  test "test_m6_zstd_pipe_arm_returns_when_tar_exits_without_reading_its_stdin":
    ## W13 added a guard and landed it UNCOVERED: when the copy loop ends
    ## before the decompressor's EOF, ``zstd`` is left blocked writing into a
    ## pipe nobody drains, and ``waitForExit`` HANGS FOREVER. The guard tracks
    ## ``sawDecompressorEof`` and terminates ``zstd`` when the loop ends early.
    ##
    ## The construction: point ``tarExeForPipe`` at the ``zstd`` binary. It
    ## rejects ``-xf`` ("Incorrect parameter: -x") and exits WITHOUT reading
    ## its stdin, so the very first write into it fails and the loop breaks
    ## early. Pair that with a multi-megabyte decompressed stream — a ~10 MB
    ## payload generated here, which zstd squeezes to under a kilobyte, so it
    ## costs milliseconds — and the real ``zstd -dc`` cannot drain itself into
    ## the 64 KiB pipe buffer and finish. Without the guard it never exits.
    ##
    ## This is not hypothetical elsewhere either: while measuring W16's
    ## alternative remedy, a bsdtar handed the GNU-only ``--no-unquote``
    ## exited without reading its stdin and hung the probe in exactly this
    ## way. The guard is what stands between that and a wedged realize.
    ##
    ## BOUNDED: the extraction runs in a CHILD PROCESS (this same binary,
    ## re-invoked through ``REPRO_W16_HANG_GUARD_CHILD``) and is waited on
    ## with a hard deadline. Exceeding it terminates the child and FAILS with
    ## a message naming what hung. A test for a hang must not be able to hang.
    ##
    ## WHAT WOULD MAKE THIS PASS VACUOUSLY:
    ##
    ##   * The child exits fast for some reason other than the guard — e.g.
    ##     it never reached ``extractTarZst``. Ruled out by requiring the
    ##     child to report, on stdout, that it ran; the parent checks for the
    ##     marker as well as for the deadline.
    ##   * The payload is small enough that ``zstd -dc`` finishes on its own
    ##     and there is nothing to hang. Ruled out by asserting the
    ##     DECOMPRESSED size is multiples of the 64 KiB pipe buffer before
    ##     spawning, and measured: with the guard removed this case times out.
    ##   * The deadline is so long the suite would look hung anyway. It is 90
    ##     seconds; the passing path returns in well under one.
    let zstdExe = findExe("zstd")
    if zstdExe.len == 0:
      echo "  [skip] this case needs a bare `zstd` on PATH"
      skip()
    else:
      let caseRoot = W16Root & "/hang-guard"
      w16Reset(caseRoot)
      # A stream whose DECOMPRESSED size is far past the 64 KiB pipe buffer,
      # so the decompressor cannot possibly finish once the loop stops
      # draining it. Highly compressible on purpose: the cost is the write,
      # not the entropy.
      let plain = caseRoot & "/payload.bin"
      var blob = newStringOfCap(10_000_000)
      while blob.len < 10_000_000:
        blob.add("w16-hang-guard-payload-0123456789abcdef\n")
      writeFile(extendedPath(plain), blob)
      let archive = caseRoot & "/payload.zst"
      let comp = execCmdEx(quoteShell(zstdExe) & " -q -f " & quoteShell(plain) &
        " -o " & quoteShell(archive))
      checkpoint("zstd compress exit=" & $comp.exitCode & " " & comp.output)
      check comp.exitCode == 0
      check fileExists(extendedPath(archive))
      # The property the construction rests on, asserted rather than assumed.
      check getFileSize(extendedPath(plain)) > 64 * 1024 * 16
      let destDir = caseRoot & "/dest"
      createDir(extendedPath(destDir))
      putEnv(W16HangChildEnv,
        zstdExe & "|" & absolutePath(archive) & "|" & absolutePath(destDir))
      var child: Process
      try:
        child = startProcess(getAppFilename(), args = [],
          options = {poStdErrToStdOut})
      finally:
        # Never leave it set for the rest of the suite: this binary IS the
        # child role when it is.
        delEnv(W16HangChildEnv)
      const DeadlineMs = 90_000
      let started = getMonoTime()
      var exitCode = -1
      var timedOut = true
      while (getMonoTime() - started).inMilliseconds < DeadlineMs:
        let peeked = child.peekExitCode()
        if peeked != -1:
          exitCode = peeked
          timedOut = false
          break
        sleep(50)
      let elapsedMs = (getMonoTime() - started).inMilliseconds
      var childSaid = ""
      if timedOut:
        child.terminate()
        discard child.waitForExit()
      else:
        # Only safe to read once the child is gone: a still-running child
        # could leave this blocked, which is the failure this case exists to
        # prevent.
        # ``readData`` until a genuine EOF, not ``readAll``: Nim 2.2's
        # ``readAll`` stops at the first SHORT pipe read on Windows, and the
        # marker this case turns on is the LAST thing the child writes.
        var buf = newString(4096)
        while true:
          var n = 0
          try:
            n = child.outputStream.readData(addr buf[0], buf.len)
          except CatchableError:
            break
          if n <= 0: break
          childSaid.add(buf[0 ..< n])
      checkpoint("child role returned=" & $(not timedOut) &
        " exit=" & $exitCode & " after " & $elapsedMs & "ms; said: " &
        childSaid.strip().replace("\n", " / "))
      child.close()
      if timedOut:
        checkpoint("HUNG: extractTarZst did not return within " &
          $DeadlineMs & "ms. That is the W13 guard missing: the copy loop " &
          "ended before the decompressor's EOF and `zstd` is still blocked " &
          "writing into an undrained pipe, so `waitForExit` never returns.")
      check(not timedOut)
      # Both markers, or the deadline was met by a child that never ran the
      # call under test.
      check childSaid.contains("W16-CHILD-ENTERED")
      check childSaid.contains("W16-CHILD-RETURNED")
