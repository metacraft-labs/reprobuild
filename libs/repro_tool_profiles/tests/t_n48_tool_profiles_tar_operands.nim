## N48 — the two ``tar`` construction sites in ``repro_tool_profiles``.
##
## W16 established, by measurement against GNU tar 1.35 and bsdtar 3.8.8, that
## a Windows path is NOT safe as a ``tar`` command-line operand for two
## independent reasons, and fixed the three sites in
## ``repro_home_apply/builtin_adapter.nim``. Two of the four sites fixed
## alongside this file live in ``repro_tool_profiles``:
##
##   * ``extractTarballArchive``'s tar-family arm passed BOTH operands raw —
##     ``-C <destination>`` and ``-x?f <archivePath>`` — and carried no
##     ``--force-local``. ``validateTarEntries``, which runs FIRST on the same
##     archive path, carried the same defect and is fixed with it: without
##     that, the extraction fix is unreachable because the listing dies first.
##   * the ``conda`` arm's zstd fallback built a LIVE ``|`` shell string for
##     ``uncontrolledExecCmdEx``. There is no shell behind that call on
##     Windows, so the arm could never work there at all.
##
## The two defects, restated so a future reader need not fetch them:
##
##   * GNU tar UNQUOTES command-line names — ``--unquote`` is the DEFAULT — so
##     a backslash before an escape letter is consumed. A destination
##     component beginning ``a b f n r t v`` makes tar raise (exit 2, zero
##     files); one beginning ``\0`` makes tar chdir to the PARENT, extract
##     there and EXIT 0. That second one produces NO ERROR, which is why every
##     case below asserts the parent is clean as well as that the destination
##     is full.
##   * GNU tar reads a ``-f`` operand whose first ``:`` precedes any ``/`` as a
##     remote ``host:path``, so every absolute Windows path fails before tar
##     opens anything. Only ``--force-local`` answers that, and it is a GNU
##     extension, so it is offered in an attempt that is ALLOWED TO FAIL.
##
## WHICH OPERAND, measured on GNU tar 1.35 rather than assumed — the two
## halves do NOT reach the same one, and the mutation run is what forced the
## distinction out:
##
##   * ``-C`` IS unquoted. Four leaves behind a single backslash: ``tango``
##     exit 2 / 0 files, ``rvw`` exit 2 / 0 files, ``0zero`` EXIT 0 with the
##     payload in the PARENT and the destination empty, ``sierra`` correct.
##   * ``-f`` is NOT unquoted. The same four leaves in the ARCHIVE operand,
##     with and without ``--force-local``, relative so no drive letter can
##     confound: 8 of 8 exit 0 and list correctly. The archive operand's own
##     defect is ``host:path``, and ``--force-local`` is its only remedy.
##
## So ``tarOperand`` is load-bearing on ``-C`` and defence in depth on ``-f``,
## and ``--force-local`` is the reverse. The mutations below are attributed
## accordingly: deleting ``tarOperand`` from an ARCHIVE operand reds nothing
## on this tar, and that is reported rather than hidden.
##
## WHAT WOULD MAKE THESE CASES PASS VACUOUSLY, and why it cannot:
##
##   * The destination names drift to letters GNU tar does not escape. That is
##     exactly how W13's case stayed green against a broken product. Ruled out
##     by ``n48AssertLeavesStillTest``, which runs BEFORE any extraction and
##     fails unless the set still holds one of the seven raising letters AND
##     the silent ``\0`` case.
##   * A backslash appears somewhere else in the path, so a red names the
##     wrong cause — or none appears at all, so there is nothing to unquote.
##     Ruled out by ``n48DestFor``, which asserts EXACTLY ONE backslash,
##     immediately before the leaf.
##   * The parent looks clean because nothing was extracted anywhere. Ruled
##     out by requiring the archive's real entries WITH their real bytes in
##     the destination in the same breath.
##   * The root is a temp directory whose own name dodges (or triggers) the
##     bug. Ruled out by ``N48Root``: relative, forward-slash-only, and NOT
##     ``createTempDir``. The first scratch root W16 was probed under happened
##     to contain ``\7``, which GNU tar read as an octal escape and which
##     reddened every leaf before the leaf mattered.
##   * The case reports one ``tar`` and exercises another. THIS ONE ACTUALLY
##     HAPPENED and is why the child-role block below exists: the product
##     names its tool as the bare string ``"tar"``, and on Windows
##     ``CreateProcessW`` searches the SYSTEM directory BEFORE %PATH%, so the
##     bare name ran ``%WINDIR%\System32\tar.exe`` — bsdtar, the one tar
##     immune to both defects — while ``findExe("tar")``, which is what a test
##     naturally reports as "tar under test", answered with the GNU tar first
##     on %PATH%. Every destination case here was GREEN with ``tarOperand``
##     DELETED until the mutation run exposed it. Ruled out by
##     ``n48AssertChildIsAWitness``, which refuses the run unless the child
##     reports a GNU tar banner from the tar it actually spawned.
##   * The conda case silently takes the DIRECT zstd-capable-tar arm instead
##     of the fallback it claims to exercise, so the ``|`` it exists for is
##     never run. Ruled out by ``n48ZstdFallbackVerdict``, which restates the
##     product's own discovery order and turns the case into a NAMED skip
##     rather than a green whenever discovery would take the other arm.
##   * The host has no ``tar``/``zstd``/zip writer so the case never runs. Not
##     silent: every skip names what was missing, and each case checkpoints
##     WHICH tar it exercised so a green can be attributed.
##   * On POSIX a backslash is a legal filename character and ``tarOperand``
##     deliberately does not rewrite there (N49), so these cases cannot speak
##     to the unquoting defect on a POSIX host. ``n48DestFor`` asserts that in
##     so many words rather than letting the green imply otherwise. What the
##     POSIX run DOES still prove is that the fix did not break the platform
##     it does not apply to, and — for the conda case — that the shell-free
##     two-process shape moves the same bytes the ``|`` used to.
##
## Falsifiability, measured: each fix reverted on its own reds exactly one of
## these cases. See the N48 report for the mutations and their verdicts.

import std/[os, osproc, sequtils, strtabs, strutils, unittest]

import repro_tool_profiles {.all.}
from repro_core/paths import extendedPath

const N48Root = "build/test-tmp/t-n48-tool-profiles"
  ## Deliberately RELATIVE and forward-slash-only, and deliberately NOT
  ## ``createTempDir`` — see the vacuity note above.

const N48RaisingFirstChars = {'a', 'b', 'f', 'n', 'r', 't', 'v'}
  ## The seven letters GNU tar turns into a control character. ``\0`` is NOT
  ## in this set: it is the one that does NOT raise, and it is asserted
  ## separately because its symptom is different in kind.

const
  AlphaBytes = "n48 alpha payload\n"
  BetaBytes = "n48 nested beta payload\n"

proc shellArgv(argv: openArray[string]): string =
  argv.mapIt(quoteShell(it)).join(" ")

proc n48AssertLeavesStillTest(leaves: openArray[string]) =
  ## THE anti-dodge control. Every assertion below is only meaningful if the
  ## leaf names actually trigger GNU tar's unquoting; rename them to safe
  ## letters and every check still passes while testing nothing.
  var raising = 0
  var nul = 0
  for leaf in leaves:
    doAssert leaf.len > 0
    if leaf[0] == '0': inc nul
    elif leaf[0] in N48RaisingFirstChars: inc raising
  doAssert raising >= 1,
    "N48 leaf set no longer contains one of " & $N48RaisingFirstChars &
    ", so it cannot observe the raising half of the defect: " & $(@leaves)
  doAssert nul >= 1,
    "N48 leaf set no longer contains the `\\0` case, so it cannot observe " &
    "the SILENT half — the one that writes into the parent and reports " &
    "success: " & $(@leaves)

proc n48DestFor(caseRoot, leaf: string): string =
  ## ``<caseRoot><DirSep><leaf>``, with the SHAPE asserted rather than
  ## assumed.
  result = caseRoot & $DirSep & leaf
  when defined(windows):
    doAssert result.contains('\\' & leaf[0]),
      "N48 destination no longer puts the leaf straight after a backslash: " &
      result
    doAssert result.count('\\') == 1,
      "N48 destination must carry EXACTLY ONE backslash so a red names one " &
      "cause: " & result
  else:
    doAssert not result.contains('\\'),
      "a POSIX path with a literal backslash is the KNOWN RESIDUAL (N49) " &
      "described in builtin_adapter's W16 comment, not something this case " &
      "covers: " & result

proc n48Reset(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc n48EntriesDirectlyUnder(dir: string): seq[string] =
  for _, entry in walkDir(extendedPath(dir), relative = true):
    result.add(entry)

proc n48CheckExtractedTree(destDir: string): tuple[ok: bool, why: string] =
  ## The fixture's two entries, on disk under ``destDir``, WITH their real
  ## bytes. Existence alone is not enough: an extractor that created empty
  ## placeholders would satisfy it.
  let alpha = destDir / "alpha.txt"
  let beta = destDir / "nested" / "beta.txt"
  for p in [alpha, beta]:
    if not fileExists(extendedPath(p)):
      return (false, "missing: " & p)
  if readFile(extendedPath(alpha)) != AlphaBytes:
    return (false, "wrong bytes in " & alpha)
  if readFile(extendedPath(beta)) != BetaBytes:
    return (false, "wrong bytes in " & beta)
  (true, "")

proc n48BuildPayloadDir(): string =
  ## A payload tree at a RELATIVE, forward-slash-only path.
  result = N48Root & "/payload"
  n48Reset(result)
  createDir(extendedPath(result & "/nested"))
  writeFile(extendedPath(result & "/alpha.txt"), AlphaBytes)
  writeFile(extendedPath(result & "/nested/beta.txt"), BetaBytes)
  doAssert not result.contains('\\')

proc n48BuildTarGz(tarExe: string): string =
  ## A real ``.tar.gz`` built by the host tar, at a RELATIVE, forward-slash
  ## only path.
  ##
  ## The archive operand is kept backslash-free ON PURPOSE: the destination
  ## cases below are about ONE variable, and handing them an absolute archive
  ## path would put a SECOND Windows defect in the same call so that a red no
  ## longer names one cause. The absolute-archive case is the sole witness for
  ## that other defect.
  let payload = n48BuildPayloadDir()
  let archiveDir = N48Root & "/archive"
  n48Reset(archiveDir)
  result = archiveDir & "/n48-fixture.tar.gz"
  let res = execCmdEx(shellArgv([tarExe, "-czf", result, "-C", payload, "."]))
  doAssert res.exitCode == 0,
    "could not build the N48 fixture archive: exit " & $res.exitCode & ": " &
    res.output
  doAssert fileExists(extendedPath(result)), "fixture archive absent: " & result
  doAssert not result.contains('\\'),
    "the fixture archive path must carry no backslash: " & result

proc n48MakeZip(sourceDir, zipPath: string): tuple[ok: bool, why: string] =
  ## A REAL zip envelope, written by a real zip writer. There is no portable
  ## Nim zip writer in this tree and none is invented here: the product
  ## extracts this file with the host's own extractor, so the fixture has to
  ## be the genuine format.
  if fileExists(extendedPath(zipPath)):
    removeFile(extendedPath(zipPath))
  when defined(windows):
    let ps = findExe("powershell")
    if ps.len == 0:
      return (false, "no powershell on PATH to write a zip")
    let res = execCmdEx(quoteShell(ps) &
      " -NoProfile -ExecutionPolicy Bypass -Command " &
      quoteShell("Compress-Archive -Path " &
        quoteShell(absolutePath(sourceDir) / "*") &
        " -DestinationPath " & quoteShell(zipPath) & " -Force"))
    if res.exitCode != 0:
      return (false, "Compress-Archive exited " & $res.exitCode & ": " &
        res.output)
  else:
    let zipExe = findExe("zip")
    if zipExe.len == 0:
      return (false, "no `zip` on PATH to write a zip")
    let res = execCmdEx(shellArgv([zipExe, "-q", "-r", zipPath, "."]),
      workingDir = sourceDir)
    if res.exitCode != 0:
      return (false, "zip exited " & $res.exitCode & ": " & res.output)
  if not fileExists(extendedPath(zipPath)):
    return (false, "zip writer reported success but produced no file")
  (true, "")

proc n48SpeaksZstd(exe: string): bool =
  ## ``tarSpeaksZstd``'s predicate, restated. The product's copy is a nested
  ## proc inside ``extractTarballArchive`` and cannot be called from here, so
  ## it is mirrored — and the mirror is validated by the fact that the case
  ## FAILS TO REACH THE FALLBACK whenever this returns true for anything
  ## discovery would pick.
  if exe.len == 0: return false
  let probe = execCmdEx(shellArgv([exe, "--version"]))
  probe.exitCode == 0 and probe.output.toLowerAscii().contains("libarchive")

proc n48InertBinary(): string =
  ## A real, harmless executable whose ``--version`` output cannot contain
  ## ``libarchive``. Used below to stand in for ``bsdtar`` so discovery is
  ## forced past the direct arm. It must be a REAL image: an empty file named
  ## ``bsdtar.exe`` would make ``CreateProcessW`` fail and the product would
  ## raise out of the probe rather than reject the candidate.
  when defined(windows):
    result = getEnv("WINDIR", r"C:\Windows") / "System32" / "whoami.exe"
    if not fileExists(extendedPath(result)): result = ""
  else:
    result = findExe("false")

proc n48ZstdFallbackVerdict(): tuple[reachable: bool, why: string] =
  ## Whether the conda arm's zstd fallback is the arm discovery would take,
  ## RIGHT NOW, with the environment as this case has arranged it. This
  ## restates the product's own discovery order so the case cannot quietly
  ## exercise the OTHER arm and report a green for the ``|`` it exists to
  ## have removed.
  when defined(windows):
    let systemTar = getEnv("WINDIR", r"C:\Windows") / "System32" / "tar.exe"
    if fileExists(extendedPath(systemTar)) and n48SpeaksZstd(systemTar):
      return (false, "%WINDIR%\\System32\\tar.exe (" & systemTar &
        ") still speaks zstd, so discovery takes the DIRECT arm")
  let bsd = findExe("bsdtar")
  if n48SpeaksZstd(bsd):
    return (false, "`bsdtar` on PATH (" & bsd & ") speaks zstd, so " &
      "discovery takes the DIRECT arm")
  let plain = findExe("tar")
  if n48SpeaksZstd(plain):
    return (false, "`tar` on PATH (" & plain & ") reports libarchive, so " &
      "discovery takes the DIRECT arm")
  if findExe("zstd").len == 0:
    return (false, "no bare `zstd` on PATH, so the fallback cannot run")
  (true, "")


# ---------------------------------------------------------------------------
# N48 — the child role that pins WHICH ``tar`` the product actually spawns
# ---------------------------------------------------------------------------
#
# THIS BLOCK EXISTS BECAUSE THE FIRST VERSION OF THESE CASES WAS A FALSE
# GREEN, and the mutation run is what caught it.
#
# ``extractTarballArchive`` and ``validateTarEntries`` name their tool as the
# bare string ``"tar"`` inside a command string handed to ``execCmdEx``. On
# Windows that string reaches ``CreateProcessW``, whose search order is
#
#     the CALLING process's directory, the current directory, the SYSTEM
#     directory, the Windows directory, then %PATH%
#
# — the system directory BEFORE %PATH%. Windows 10 1803 and later ship
# ``%WINDIR%\System32\tar.exe``, and that binary is BSDTAR (measured here:
# ``bsdtar 3.8.8 - libarchive 3.8.8``). bsdtar does not unquote and does not
# read ``C:\…`` as ``host:path``. So on a stock Windows host the product's
# bare ``tar`` runs the ONE tar that is immune, while ``findExe("tar")`` — the
# call a test naturally uses to report "tar under test" — answers with the GNU
# tar that is first on %PATH%. Measured side by side in one process:
#
#     findExe("tar")                 -> D:\…\msys64\usr\bin\tar.exe
#     execCmdEx("tar --version")     -> bsdtar 3.8.8 - libarchive 3.8.8
#     execCmdEx(findExe(…) & " -V")  -> tar (GNU tar) 1.35
#
# Every destination case below was green with ``tarOperand`` DELETED for
# exactly that reason, and the checkpoint said "tar under test: …GNU tar" the
# whole time. A test that reports one binary and exercises another proves
# nothing about either.
#
# The remedy uses the first entry of that same search order: the CALLING
# process's directory. This binary is copied into a scratch directory next to
# a copy of the host's GNU ``tar.exe``, and the copy is re-invoked with
# ``REPRO_N48_TAR_CHILD`` set. The product's bare ``tar`` then resolves to the
# GNU tar sitting beside the running image, while tar's own DLLs still resolve
# through %PATH%. The child prints the banner of the tar it really got, and
# the parent REFUSES to treat the run as a witness unless that banner says GNU
# tar.
#
# ``quit`` here is the child ROLE ending, not a verdict: this process was
# spawned for exactly one call and the parent decides what its exit means.
# Nothing in this block reports a test result, so the rule that a helper must
# use ``doAssert`` rather than ``quit`` is not in play.
#
# This block must precede the ``suite`` below: ``suite``/``test`` are
# templates that run at module-init in declaration order, and the child must
# not execute the suite.
const N48TarChildEnv = "REPRO_N48_TAR_CHILD"

type N48ChildRun = object
  entered: bool
  done: bool
  tarBanner: string
  raised: string
  transcript: string

let n48ChildSpec = getEnv(N48TarChildEnv)
if n48ChildSpec.len > 0:
  # ``<archiveType>|<archivePath>|<destination>``
  let parts = n48ChildSpec.split('|')
  doAssert parts.len == 3, "bad N48 child spec: " & n48ChildSpec
  echo "N48-CHILD-ENTERED"
  let banner = execCmdEx("tar --version")
  echo "N48-CHILD-TAR=",
    (if banner.output.len > 0: banner.output.splitLines()[0].strip()
     else: "<no output>")
  var childRaised = ""
  try:
    extractTarballArchive(parts[1], parts[2], parts[0], 0)
  except CatchableError as err:
    childRaised = err.msg.replace("\n", " ~ ")
  echo "N48-CHILD-RAISED=", childRaised
  echo "N48-CHILD-DONE"
  quit(0)

proc n48GnuTarDriver(): tuple[ok: bool, dir: string, why: string] =
  ## A scratch directory holding a copy of THIS binary beside a copy of the
  ## host's GNU ``tar.exe``, so a bare ``tar`` spawned from that copy resolves
  ## to GNU tar. On POSIX there is no such search-order quirk — ``execCmdEx``
  ## goes through ``/bin/sh``, which uses ``$PATH`` and nothing else — so the
  ## driver is Windows-only and the POSIX arm runs the product in process.
  when not defined(windows):
    return (true, "", "")
  let gnuTar = findExe("tar")
  if gnuTar.len == 0:
    return (false, "", "no `tar` on PATH to copy")
  let banner = execCmdEx(shellArgv([gnuTar, "--version"]))
  if not banner.output.toLowerAscii().contains("gnu tar"):
    return (false, "", "`tar` on PATH is not GNU tar (" &
      (if banner.output.len > 0: banner.output.splitLines()[0].strip()
       else: "<no output>") & "), so this host cannot witness a defect that " &
      "is GNU tar's")
  let dir = N48Root & "/gnu-tar-driver"
  n48Reset(dir)
  let driver = dir / "n48-driver.exe"
  copyFile(extendedPath(getAppFilename()), extendedPath(driver))
  copyFile(extendedPath(gnuTar), extendedPath(dir / "tar.exe"))
  (true, dir, "")

proc n48RunViaGnuTar(driverDir, archiveType, archivePath,
                     destination: string): N48ChildRun =
  ## Drive ``extractTarballArchive`` in the child whose neighbour is GNU tar.
  var env = newStringTable(modeCaseInsensitive)
  for k, v in envPairs(): env[k] = v
  env[N48TarChildEnv] = archiveType & "|" & archivePath & "|" & destination
  let res = execCmdEx(shellArgv([driverDir / "n48-driver.exe"]), env = env,
    workingDir = getCurrentDir())
  result.transcript = res.output
  for line in res.output.splitLines():
    if line.startsWith("N48-CHILD-ENTERED"): result.entered = true
    elif line.startsWith("N48-CHILD-DONE"): result.done = true
    elif line.startsWith("N48-CHILD-TAR="):
      result.tarBanner = line["N48-CHILD-TAR=".len .. ^1]
    elif line.startsWith("N48-CHILD-RAISED="):
      result.raised = line["N48-CHILD-RAISED=".len .. ^1]

proc n48AssertChildIsAWitness(run: N48ChildRun) =
  ## The anti-vacuity control the first version of this file lacked. Both
  ## markers must be present — a child that died before reaching the product
  ## would otherwise look like a clean run — and the tar it actually spawned
  ## must be the GNU tar whose behaviour is under test.
  doAssert run.entered,
    "the N48 driver never reached the product; transcript: " & run.transcript
  doAssert run.done,
    "the N48 driver did not finish its one call; transcript: " &
    run.transcript
  doAssert run.tarBanner.toLowerAscii().contains("gnu tar"),
    "the N48 driver spawned '" & run.tarBanner & "', not GNU tar, so this " &
    "case would prove nothing about the defect it exists for; transcript: " &
    run.transcript

proc n48Extract(driverDir, archiveType, archivePath,
                destination: string): string =
  ## Run the product's tar-family arm and return the message it raised ("" on
  ## success). On Windows this goes through the GNU-tar driver so the binary
  ## under test is the one whose behaviour the case is about; on POSIX
  ## ``execCmdEx`` resolves through ``/bin/sh`` and ``$PATH`` with no
  ## search-order quirk, so the product runs in this process.
  when defined(windows):
    let run = n48RunViaGnuTar(driverDir, archiveType, archivePath, destination)
    n48AssertChildIsAWitness(run)
    checkpoint("driver spawned: " & run.tarBanner)
    result = run.raised
  else:
    try:
      extractTarballArchive(archivePath, destination, archiveType, 0)
    except CatchableError as err:
      result = err.msg

suite "N48 repro_tool_profiles tar operands":

  test "test_n48_tarball_arm_extracts_into_destinations_gnu_tar_would_unquote":
    ## Site 1 — ``extractTarballArchive``'s tar-family arm, driven at real
    ## bytes with only the destination's leaf varying.
    let tarExe = findExe("tar")
    if tarExe.len == 0:
      echo "  [skip] this case needs `tar` on PATH"
      skip()
    else:
      n48Reset(N48Root)
      let archive = n48BuildTarGz(tarExe)
      let driver = n48GnuTarDriver()
      if not driver.ok:
        echo "  [skip] " & driver.why
        skip()
      else:
        # ``t`` is the letter a future author writes without thinking; ``0`` is
        # the one that does not fail. ``sierra`` is the control: under every
        # mutation it stays GREEN, which is what makes the others' reds mean
        # something.
        let leaves = ["tango-n48", "0zero-n48", "sierra-n48"]
        n48AssertLeavesStillTest(leaves)
        for leaf in leaves:
          let caseRoot = N48Root & "/tarball-" & leaf
          n48Reset(caseRoot)
          let destDir = n48DestFor(caseRoot, leaf)
          let raisedWith = n48Extract(driver.dir, "tar.gz", archive, destDir)
          checkpoint("leaf=" & leaf & " dest=" & destDir &
            (if raisedWith.len > 0: " raised: " & raisedWith else: " (no raise)"))
          check raisedWith.len == 0
          # IN the intended directory ...
          let tree = n48CheckExtractedTree(destDir)
          checkpoint("leaf=" & leaf & " tree verdict: " &
            (if tree.ok: "complete" else: tree.why))
          check tree.ok
          # ... AND NOWHERE ELSE. Pre-fix, the ``0zero`` leaf put ``alpha.txt``
          # and ``nested`` right here beside an empty destination, and reported
          # success doing it.
          let siblings = n48EntriesDirectlyUnder(caseRoot)
          checkpoint("leaf=" & leaf & " entries directly under the parent: " &
            siblings.join(", "))
          check siblings == @[leaf]

  test "test_n48_tarball_arm_opens_an_absolute_windows_archive_path":
    ## Site 1, the other operand — and the ``validateTarEntries`` listing that
    ## runs before it on the same path.
    ##
    ## The destination here is relative and backslash-free so the ONLY thing
    ## under test is the archive operand. On Windows that operand is
    ## ``M:\…\n48-fixture.tar.gz``: GNU tar read the leading ``M:`` as a
    ## remote host and died with "Cannot connect to M: resolve failed" before
    ## opening anything, and the backslashes were unquoted on top of that.
    ## ``--force-local`` plus ``tarOperand`` answer both; bsdtar needs neither
    ## and rejects the flag, which is why the attempt carrying it is allowed
    ## to fail.
    let tarExe = findExe("tar")
    if tarExe.len == 0:
      echo "  [skip] this case needs `tar` on PATH"
      skip()
    else:
      checkpoint("tar under test: " & tarExe)
      n48Reset(N48Root)
      let relativeArchive = n48BuildTarGz(tarExe)
      let absoluteArchive = absolutePath(relativeArchive)
      when defined(windows):
        doAssert absoluteArchive.contains(':'),
          "this case is only a witness when the archive path carries a " &
          "drive letter: " & absoluteArchive
        doAssert absoluteArchive.contains('\\'),
          "this case is only a witness when the archive path is " &
          "backslashed: " & absoluteArchive
      checkpoint("absolute archive: " & absoluteArchive)
      let caseRoot = N48Root & "/absolute-archive"
      n48Reset(caseRoot)
      let destDir = caseRoot & "/dest"
      doAssert not destDir.contains('\\'),
        "the destination must stay backslash-free so a red names the " &
        "ARCHIVE operand: " & destDir
      let driver = n48GnuTarDriver()
      if not driver.ok:
        echo "  [skip] " & driver.why
        skip()
      else:
        let raisedWith = n48Extract(driver.dir, "tar.gz", absoluteArchive,
          destDir)
        checkpoint(if raisedWith.len > 0: "raised: " & raisedWith
                   else: "(no raise)")
        check raisedWith.len == 0
        let tree = n48CheckExtractedTree(destDir)
        checkpoint("tree verdict: " & (if tree.ok: "complete" else: tree.why))
        check tree.ok

  test "test_n48_conda_zstd_fallback_runs_without_a_shell":
    ## Site 2 — the conda arm's zstd fallback, which used to be one command
    ## string carrying a ``|`` handed to ``uncontrolledExecCmdEx``. There is
    ## no shell behind that call on Windows, so the arm could not work there
    ## at all; and its ``-C`` operand was raw, so it carried the unquoting
    ## defect on top.
    ##
    ## Reaching the arm takes a host whose ``tar`` is not libarchive, because
    ## ``tarSpeaksZstd`` demands that banner before the direct arm is taken.
    ## On Windows that means hiding ``%WINDIR%\System32\tar.exe``, which IS
    ## bsdtar, so the case points ``WINDIR`` at a directory with no
    ## ``System32\tar.exe`` and restores it afterwards. Whether the override
    ## worked is ASSERTED, not assumed.
    let zstdExe = findExe("zstd")
    let tarExe = findExe("tar")
    if zstdExe.len == 0 or tarExe.len == 0:
      echo "  [skip] this arm needs BOTH a bare `zstd` and a `tar` on PATH" &
        " (zstd=" & zstdExe & " tar=" & tarExe & ")"
      skip()
    else:
      checkpoint("tar under test: " & tarExe)
      checkpoint("zstd under test: " & zstdExe)
      n48Reset(N48Root)
      let payload = n48BuildPayloadDir()
      let stageDir = N48Root & "/conda-stage"
      n48Reset(stageDir)
      # Inner payload: a real tar, zstd-compressed, named the way conda-forge
      # names it (``pkg-*.tar.zst`` is what the product looks for).
      let innerTar = stageDir & "/pkg-n48.tar"
      let tarRes = execCmdEx(
        shellArgv([tarExe, "-cf", innerTar, "-C", payload, "."]))
      doAssert tarRes.exitCode == 0,
        "could not build the conda inner tar: " & tarRes.output
      let zstdRes = execCmdEx(
        shellArgv([zstdExe, "-q", "-f", "-o", innerTar & ".zst", innerTar]))
      doAssert zstdRes.exitCode == 0,
        "could not zstd the conda inner tar: " & zstdRes.output
      removeFile(extendedPath(innerTar))
      let condaArchive = N48Root & "/n48-fixture.conda"
      let zipMade = n48MakeZip(stageDir, absolutePath(condaArchive))
      if not zipMade.ok:
        echo "  [skip] no zip writer available to build the .conda " &
          "envelope: " & zipMade.why
        skip()
      else:
        # Force discovery past the direct arm, then PROVE it went past it.
        #
        # Two things have to move. ``%WINDIR%\System32\tar.exe`` IS bsdtar on
        # Windows and is step (i), so ``WINDIR`` is pointed at a directory
        # with no ``System32\tar.exe``. Step (ii) tries ``bsdtar`` then
        # ``tar`` on PATH, and this host has a real libarchive ``bsdtar``
        # beside its GNU ``tar`` in the same directory — so a shim directory
        # goes FIRST on PATH carrying a ``bsdtar`` that is a real but inert
        # image (``whoami.exe`` / ``false``), which the product's probe
        # rejects exactly as it would reject any non-libarchive candidate.
        # ``tar`` is deliberately NOT shimmed, so it still resolves to the
        # host's real GNU tar and real bytes still move.
        let originalWindir = getEnv("WINDIR")
        let originalPath = getEnv("PATH")
        let inert = n48InertBinary()
        let shimDir = absolutePath(N48Root & "/discovery-shim")
        n48Reset(N48Root & "/discovery-shim")
        n48Reset(N48Root & "/no-system-tar")
        if inert.len > 0:
          let shimName = when defined(windows): "bsdtar.exe" else: "bsdtar"
          copyFile(extendedPath(inert), extendedPath(shimDir / shimName))
          when not defined(windows):
            inclFilePermissions(shimDir / shimName, {fpUserExec})
          putEnv("PATH", shimDir & (when defined(windows): ";" else: ":") &
            originalPath)
        when defined(windows):
          putEnv("WINDIR", absolutePath(N48Root & "/no-system-tar"))
        defer:
          putEnv("PATH", originalPath)
          when defined(windows):
            if originalWindir.len > 0: putEnv("WINDIR", originalWindir)
        let verdict = n48ZstdFallbackVerdict()
        if not verdict.reachable:
          echo "  [skip] this host cannot be steered onto the conda zstd " &
            "fallback: " & verdict.why
          skip()
        else:
          checkpoint("discovery steered onto the zstd fallback; bsdtar shim: " &
            (if inert.len > 0: inert else: "<none needed>"))
          let leaves = ["tango-n48", "0zero-n48"]
          n48AssertLeavesStillTest(leaves)
          for leaf in leaves:
            let leafRoot = N48Root & "/conda-" & leaf
            n48Reset(leafRoot)
            let destDir = n48DestFor(leafRoot, leaf)
            var raisedWith = ""
            try:
              extractTarballArchive(condaArchive, destDir, "conda", 0)
            except CatchableError as err:
              raisedWith = err.msg
            checkpoint("leaf=" & leaf & " dest=" & destDir &
              (if raisedWith.len > 0: " raised: " & raisedWith
               else: " (no raise)"))
            check raisedWith.len == 0
            let tree = n48CheckExtractedTree(destDir)
            checkpoint("leaf=" & leaf & " tree verdict: " &
              (if tree.ok: "complete" else: tree.why))
            check tree.ok
            # The conda arm's own staging directory is a SIBLING of the
            # destination (``<dest>.conda-staging``) and is removed in the
            # product's ``finally``, so the parent must hold the destination
            # and nothing else once the call returns.
            let siblings = n48EntriesDirectlyUnder(leafRoot)
            checkpoint("leaf=" & leaf & " entries directly under the parent: " &
              siblings.join(", "))
            check siblings == @[leaf]
