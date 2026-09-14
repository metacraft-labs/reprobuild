## N48 — the ``tar`` construction site in ``apt_jammy.tarExtractDataMember``.
##
## ``extractAptDeb`` writes a .deb's ``data.tar.*`` member to a scratch file
## and invokes ``tar`` to unpack it into the content-addressed store path. The
## invocation was built as a command STRING with both operands quoted but
## RAW, and with no ``--force-local``:
##
##     "tar " & flag & " " & quoteShell(tarInput) & " -C " & quoteShell(outDir)
##
## W16 measured what that means on Windows, against GNU tar 1.35:
##
##   * GNU tar UNQUOTES command-line names — ``--unquote`` is the DEFAULT — so
##     an ``outDir`` component beginning ``a b f n r t v`` makes tar raise
##     (exit 2, zero files), and one beginning ``\0`` makes tar chdir to the
##     PARENT, unpack the whole .deb THERE and EXIT 0. The second produces no
##     error of any kind, which is why every case below asserts the parent is
##     clean as well as that the destination is full.
##   * GNU tar reads a ``-f`` operand whose first ``:`` precedes any ``/`` as a
##     remote ``host:path``, so the drive letter alone ("Cannot connect to M:
##     resolve failed") stopped it opening the member at all.
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
## This file drives the real proc at real bytes. The private
## ``tarExtractDataMember`` is reached with ``{.all.}`` rather than through
## ``extractAptDeb`` on purpose: ``extractAptDeb`` appends a
## content-addressed ``<hash>`` component of its own to the store root, which
## would put a SECOND uncontrolled backslash-escape trigger in the same path
## (a fingerprint beginning ``a``, ``b``, ``f`` or any of ``0``-``7`` is one),
## and a red would no longer name one cause.
##
## WHAT WOULD MAKE THESE CASES PASS VACUOUSLY, and why it cannot:
##
##   * The destination names drift to letters GNU tar does not escape — how
##     W13's case stayed green against a broken product. Ruled out by
##     ``n48AssertLeavesStillTest``, which runs BEFORE any extraction.
##   * A backslash appears elsewhere in the path so a red names the wrong
##     cause, or none appears at all so there is nothing to unquote. Ruled out
##     by ``n48DestFor``, which asserts EXACTLY ONE backslash.
##   * The parent looks clean because nothing was extracted anywhere. Ruled
##     out by requiring the member's real bytes in the destination in the same
##     breath.
##   * The root is a temp directory whose own name dodges or triggers the bug.
##     Ruled out by ``N48Root``: relative, forward-slash-only, NOT
##     ``createTempDir``.
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
##   * No ``tar`` on the host, so nothing runs. Not silent: the skip names it,
##     and the case checkpoints WHICH tar it exercised.
##   * On POSIX ``tarOperand`` deliberately does not rewrite (N49, a backslash
##     is a legal filename character there), so a POSIX run cannot speak to
##     the unquoting defect. ``n48DestFor`` says so in an assertion rather
##     than letting the green imply otherwise; what a POSIX run still proves
##     is that the fix did not break the platform it does not apply to, and
##     that the ``--force-local``-then-retry shape extracts the same bytes.

import std/[os, osproc, sequtils, strtabs, strutils, unittest]

import repro_dsl_stdlib/packages/apt_jammy {.all.}
from repro_core/paths import extendedPath
from repro_core/host_tar import resolveHostTar, HostTarOverrideEnv

const N48Root = "build/test-tmp/t-n48-apt-jammy"
  ## Deliberately RELATIVE and forward-slash-only, and deliberately NOT
  ## ``createTempDir``: the defect under test is that GNU tar unquotes the
  ## path it is handed, so what the case proves depends entirely on which
  ## backslashes are in that path, and a temp root is whatever ``TMPDIR``
  ## happens to be. The first scratch root W16 was probed under contained
  ## ``\7``, which GNU tar read as an octal escape.

const N48RaisingFirstChars = {'a', 'b', 'f', 'n', 'r', 't', 'v'}
  ## The seven letters GNU tar turns into a control character. ``\0`` is NOT
  ## in this set: it is the one that does NOT raise.

const
  PayloadPath = "usr/share/n48/payload.txt"
  PayloadBytes = "n48 apt-jammy payload\n"

proc shellArgv(argv: openArray[string]): string =
  argv.mapIt(quoteShell(it)).join(" ")

proc n48AssertLeavesStillTest(leaves: openArray[string]) =
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
      "a POSIX path with a literal backslash is the KNOWN RESIDUAL (N49), " &
      "not something this case covers: " & result

proc n48Reset(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc n48EntriesDirectlyUnder(dir: string): seq[string] =
  for _, entry in walkDir(extendedPath(dir), relative = true):
    result.add(entry)

proc n48BuildDataTar(tarExe: string): string =
  ## A real ``data.tar`` built by the host tar, at a RELATIVE,
  ## forward-slash-only path — so the destination cases below vary ONE thing.
  let payloadRoot = N48Root & "/payload"
  n48Reset(payloadRoot)
  createDir(extendedPath(payloadRoot / PayloadPath.parentDir))
  writeFile(extendedPath(payloadRoot / PayloadPath), PayloadBytes)
  let archiveDir = N48Root & "/archive"
  n48Reset(archiveDir)
  result = archiveDir & "/data.tar"
  let res = execCmdEx(
    shellArgv([tarExe, "-cf", result, "-C", payloadRoot, "."]))
  doAssert res.exitCode == 0,
    "could not build the N48 data.tar fixture: exit " & $res.exitCode & ": " &
    res.output
  doAssert not result.contains('\\'),
    "the fixture archive path must carry no backslash: " & result


# ---------------------------------------------------------------------------
# N48 — the child role that pins WHICH ``tar`` the product actually spawns
# ---------------------------------------------------------------------------
#
# THIS BLOCK EXISTS BECAUSE THE FIRST VERSION OF THESE CASES WAS A FALSE
# GREEN, and the mutation run is what caught it.
#
# ``tarExtractDataMember`` names its tool as the bare string ``"tar "`` inside
# a command string handed to ``execCmdEx``. On Windows that string reaches
# ``CreateProcessW``, whose search order is
#
#     the CALLING process's directory, the current directory, the SYSTEM
#     directory, the Windows directory, then %PATH%
#
# — the system directory BEFORE %PATH%. Windows 10 1803 and later ship
# ``%WINDIR%\System32\tar.exe``, and that binary is BSDTAR (measured here:
# ``bsdtar 3.8.8 - libarchive 3.8.8``), which neither unquotes nor reads
# ``C:\…`` as ``host:path``. So on a stock Windows host the product's bare
# ``tar`` runs the ONE tar that is immune, while ``findExe("tar")`` — the call
# a test naturally uses to report "tar under test" — answers with the GNU tar
# that is first on %PATH%. Measured side by side in one process:
#
#     findExe("tar")                 -> D:\…\msys64\usr\bin\tar.exe
#     execCmdEx("tar --version")     -> bsdtar 3.8.8 - libarchive 3.8.8
#     execCmdEx(findExe(…) & " -V")  -> tar (GNU tar) 1.35
#
# Both destination cases below were green with ``tarOperand`` DELETED for
# exactly that reason. A test that reports one binary and exercises another
# proves nothing about either.
#
# The remedy uses the FIRST entry of that same search order. This binary is
# copied into a scratch directory next to a copy of the host's GNU
# ``tar.exe`` and re-invoked with ``REPRO_N48_APT_CHILD`` set; the product's
# bare ``tar`` then resolves to the GNU tar beside the running image, while
# tar's own DLLs still resolve through %PATH%. The child prints the banner of
# the tar it really got and the parent REFUSES to treat the run as a witness
# unless that banner says GNU tar.
#
# ``quit`` here is the child ROLE ending, not a verdict: this process was
# spawned for exactly one call and the parent decides what its exit means.
# Nothing in this block reports a test result, so the rule that a helper must
# use ``doAssert`` rather than ``quit`` is not in play.
#
# This block must precede the ``suite`` below: ``suite``/``test`` are
# templates that run at module-init in declaration order, and the child must
# not execute the suite.
#
# N51 UPDATE -- READ THIS BEFORE TRUSTING A GREEN FROM THIS FILE.
#
# The "copy the binary next to a GNU tar.exe" trick above worked because the
# product named its tool as the bare string ``"tar"`` and let
# ``CreateProcessW`` resolve it. N51 removed that: the product now resolves
# its tar EXPLICITLY through ``repro_core/host_tar.resolveHostTar``, which
# reproduces the same order (system directory, then PATH) but no longer looks
# in the calling process's directory -- deliberately, because that entry is a
# binary-planting hazard, and incidentally, because it was this driver's only
# lever.
#
# Left alone, that would have made these cases VACUOUS RATHER THAN RED: the
# neighbour copy would sit unused, the child's own
# ``execCmdEx("tar --version")`` would still print a GNU tar banner from it,
# ``n48AssertChildIsAWitness`` would still pass -- and the product would
# quietly be running System32's bsdtar, which has neither defect. That is the
# same false green this block's own header describes escaping from.
#
# So the driver now sets ``REPRO_HOST_TAR`` to the GNU tar it copied, and the
# child reports the banner of ``resolveHostTar()`` -- THE BINARY THE PRODUCT
# WILL ACTUALLY RUN -- instead of the banner of a bare ``tar`` nothing uses
# any more. Those two changes are what keep the witness assertion meaningful.

const N48AptChildEnv = "REPRO_N48_APT_CHILD"

type N48ChildRun = object
  entered: bool
  done: bool
  tarBanner: string
  raised: string
  transcript: string

let n48ChildSpec = getEnv(N48AptChildEnv)
if n48ChildSpec.len > 0:
  # ``<memberName>|<dataTarPath>|<outDir>``
  let parts = n48ChildSpec.split('|')
  doAssert parts.len == 3, "bad N48 apt child spec: " & n48ChildSpec
  echo "N48-CHILD-ENTERED"
  # N51: the banner of the binary the PRODUCT will run. Reporting
  # `execCmdEx("tar --version")` here would report a bare-name resolution the
  # product no longer performs, which is how this witness would go quietly
  # vacuous. `resolveHostTar` is the same call the product makes.
  let resolvedTar = resolveHostTar()
  let banner =
    if resolvedTar.exe.len == 0: (output: "", exitCode: 1)
    else: execCmdEx(quoteShell(resolvedTar.exe) & " --version")
  echo "N48-CHILD-TAR-PATH=", resolvedTar.exe, " [", resolvedTar.origin, "]"
  echo "N48-CHILD-TAR=",
    (if banner.output.len > 0: banner.output.splitLines()[0].strip()
     else: "<no output>")
  let bytes = readFile(extendedPath(parts[1]))
  var childRaised = ""
  try:
    tarExtractDataMember("n48-fixture.deb", bytes, parts[0], 0, bytes.len,
      parts[2])
  except CatchableError as err:
    childRaised = err.msg.replace("\n", " ~ ")
  echo "N48-CHILD-RAISED=", childRaised
  echo "N48-CHILD-DONE"
  quit(0)

proc n48GnuTarDriver(): tuple[ok: bool, dir: string, why: string] =
  ## A scratch directory holding a copy of THIS binary beside a copy of the
  ## host's GNU ``tar.exe``. POSIX has no such search-order quirk —
  ## ``execCmdEx`` goes through ``/bin/sh``, which uses ``$PATH`` and nothing
  ## else — so the driver is Windows-only.
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
  copyFile(extendedPath(getAppFilename()),
    extendedPath(dir / "n48-driver.exe"))
  copyFile(extendedPath(gnuTar), extendedPath(dir / "tar.exe"))
  (true, dir, "")

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

proc n48ExtractMember(driverDir, dataTar, outDir: string): string =
  ## Run the product's data-member extraction and return the message it
  ## raised ("" on success).
  when defined(windows):
    var env = newStringTable(modeCaseInsensitive)
    for k, v in envPairs(): env[k] = v
    # N51: the product resolves its tar explicitly now, so the neighbouring
    # `tar.exe` this driver copied is no longer reachable by proximity. Name
    # it. Without this the child runs System32's bsdtar and every case below
    # proves nothing -- silently, because it would still PASS.
    if driverDir.len > 0:
      env[HostTarOverrideEnv] = driverDir / "tar.exe"
    env[N48AptChildEnv] = "data.tar|" & dataTar & "|" & outDir
    let res = execCmdEx(shellArgv([driverDir / "n48-driver.exe"]), env = env,
      workingDir = getCurrentDir())
    var run = N48ChildRun(transcript: res.output)
    for line in res.output.splitLines():
      if line.startsWith("N48-CHILD-ENTERED"): run.entered = true
      elif line.startsWith("N48-CHILD-DONE"): run.done = true
      elif line.startsWith("N48-CHILD-TAR="):
        run.tarBanner = line["N48-CHILD-TAR=".len .. ^1]
      elif line.startsWith("N48-CHILD-RAISED="):
        run.raised = line["N48-CHILD-RAISED=".len .. ^1]
    n48AssertChildIsAWitness(run)
    checkpoint("driver spawned: " & run.tarBanner)
    result = run.raised
  else:
    let bytes = readFile(extendedPath(dataTar))
    try:
      tarExtractDataMember("n48-fixture.deb", bytes, "data.tar", 0,
        bytes.len, outDir)
    except CatchableError as err:
      result = err.msg

suite "N48 apt-jammy tar operands":

  test "test_n48_apt_data_member_extracts_into_dirs_gnu_tar_would_unquote":
    ## The ``-C outDir`` operand, driven at real bytes with only the leaf
    ## varying. ``tarExtractDataMember`` writes its own scratch copy of the
    ## member INTO ``outDir`` and then tars it back out, so ``outDir`` is
    ## both the ``-f`` operand's parent and the ``-C`` operand — one leaf,
    ## both operands, which is exactly the production shape.
    let tarExe = findExe("tar")
    if tarExe.len == 0:
      echo "  [skip] this case needs `tar` on PATH"
      skip()
    else:
      checkpoint("tar under test: " & tarExe)
      n48Reset(N48Root)
      let dataTar = n48BuildDataTar(tarExe)
      doAssert getFileSize(dataTar) > 0, "the data.tar fixture is empty"
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
          let caseRoot = N48Root & "/apt-" & leaf
          n48Reset(caseRoot)
          let outDir = n48DestFor(caseRoot, leaf)
          createDir(extendedPath(outDir))
          let raisedWith = n48ExtractMember(driver.dir, dataTar, outDir)
          checkpoint("leaf=" & leaf & " outDir=" & outDir &
            (if raisedWith.len > 0: " raised: " & raisedWith else: " (no raise)"))
          check raisedWith.len == 0
          # IN the intended directory, with the real bytes ...
          let landed = outDir / PayloadPath
          checkpoint("leaf=" & leaf & " payload present: " &
            $fileExists(extendedPath(landed)))
          check fileExists(extendedPath(landed))
          if fileExists(extendedPath(landed)):
            check readFile(extendedPath(landed)) == PayloadBytes
          # ... AND NOWHERE ELSE. Pre-fix, the ``0zero`` leaf unpacked ``usr``
          # right here beside an empty destination and reported success.
          let siblings = n48EntriesDirectlyUnder(caseRoot)
          checkpoint("leaf=" & leaf & " entries directly under the parent: " &
            siblings.join(", "))
          check siblings == @[leaf]

  test "test_n48_apt_data_member_extracts_under_an_absolute_windows_outdir":
    ## The ``host:path`` half. The leaf here is deliberately SAFE, so the only
    ## thing under test is that an absolute, drive-lettered destination works
    ## at all — the shape ``extractAptDeb`` always produces in production.
    ## Pre-fix on Windows this raised "Cannot connect to M: resolve failed"
    ## before tar opened anything; ``--force-local`` is the only remedy and it
    ## is a GNU extension, so it rides in an attempt allowed to fail.
    let tarExe = findExe("tar")
    if tarExe.len == 0:
      echo "  [skip] this case needs `tar` on PATH"
      skip()
    else:
      checkpoint("tar under test: " & tarExe)
      n48Reset(N48Root)
      let dataTar = n48BuildDataTar(tarExe)
      let caseRoot = N48Root & "/apt-absolute"
      n48Reset(caseRoot)
      let outDir = absolutePath(caseRoot & "/sierra-dest")
      createDir(extendedPath(outDir))
      when defined(windows):
        doAssert outDir.contains(':'),
          "this case is only a witness when the destination carries a drive " &
          "letter: " & outDir
      checkpoint("absolute outDir: " & outDir)
      let driver = n48GnuTarDriver()
      if not driver.ok:
        echo "  [skip] " & driver.why
        skip()
      else:
        let raisedWith = n48ExtractMember(driver.dir, dataTar, outDir)
        checkpoint(if raisedWith.len > 0: "raised: " & raisedWith
                   else: "(no raise)")
        check raisedWith.len == 0
        let landed = outDir / PayloadPath
        check fileExists(extendedPath(landed))
        if fileExists(extendedPath(landed)):
          check readFile(extendedPath(landed)) == PayloadBytes
