## N48 — the ``tar`` construction sites in the harvester's ``msys2_source``.
##
## ``tarExtractMember`` and ``tarListEntries`` already passed ``--force-local``
## to a GNU tar and already shell-quoted every operand, so the ``host:path``
## half of W16 was answered here. The OTHER half was not: GNU tar UNQUOTES the
## directory it is told to chdir into — ``--unquote`` is the DEFAULT — so
## every backslash in a ``-C`` operand that precedes an escape letter is
## consumed before tar opens anything.
##
## WHICH OPERAND, measured on GNU tar 1.35 rather than assumed — the two
## halves do NOT reach the same one, and the mutation run is what forced the
## distinction out. ``-C`` IS unquoted: four leaves behind a single backslash
## gave ``tango`` exit 2 / 0 files, ``rvw`` exit 2 / 0 files, ``0zero`` EXIT 0
## with the payload in the PARENT, ``sierra`` correct. ``-f`` is NOT unquoted:
## the same four leaves in the ARCHIVE operand, with and without
## ``--force-local``, relative so no drive letter can confound, gave 8 of 8
## exit 0. So ``tarExtractMember``'s ``-C`` is the load-bearing fix here and
## ``tarListEntries`` — which builds nothing but ``-f`` operands — depends on
## ``--force-local`` instead, with ``tarOperand`` riding along as defence in
## depth. Deleting ``tarOperand`` from an archive operand reds nothing on this
## tar, and that is reported rather than hidden.
##
## ``tarExtractMember`` extracts into ``<workDir>\.m6-extract-scratch``, where
## ``workDir`` is ``parentDir(destFile)`` — in production, a directory under
## the harvester's output root, i.e. an absolute Windows path. A component
## beginning ``a b f n r t v`` makes tar raise; one beginning ``\0`` makes tar
## chdir to the PARENT and extract there while still exiting 0, after which
## the proc finds no member at ``scratch / member``, returns ``false``, and
## the harvester reports a package as lacking a file it had just written
## somewhere else. That failure mode emits no error at all, which is why the
## cases below assert the parent is clean as well as that the destination
## holds the member's real bytes.
##
## WHAT WOULD MAKE THESE CASES PASS VACUOUSLY, and why it cannot:
##
##   * The leaf names drift to letters GNU tar does not escape — how W13's
##     case stayed green against a broken product. Ruled out by
##     ``n48AssertLeavesStillTest``, which runs BEFORE any extraction.
##   * The path stops putting a leaf behind a backslash, so there is nothing
##     to unquote. Ruled out by ``n48WorkDirFor``, which asserts the shape.
##   * The parent looks clean because nothing was extracted anywhere. Ruled
##     out by requiring the member's real bytes at ``destFile`` in the same
##     breath — and by requiring ``tarExtractMember`` to return ``true``,
##     which is the verdict the harvester actually consumes.
##   * The root is a temp directory whose own name dodges or triggers the bug.
##     Ruled out by ``N48Root``: relative, forward-slash-only, NOT
##     ``createTempDir``.
##   * ``tar``/``zstd`` absent so nothing runs. Not silent: the skip names the
##     missing binary and each case checkpoints WHICH tar it exercised.
##   * On POSIX ``tarOperand`` deliberately does not rewrite (N49), so a POSIX
##     run cannot speak to the unquoting defect; ``n48WorkDirFor`` asserts
##     that rather than letting the green imply otherwise. What a POSIX run
##     still proves is that the fix did not break the platform it does not
##     apply to.

import std/[os, osproc, sequtils, strutils, unittest]

import ../src/msys2_source
from repro_core/paths import extendedPath

const N48Root = "build/test-tmp/test-n48-msys2"
  ## Deliberately RELATIVE and forward-slash-only, and deliberately NOT
  ## ``createTempDir`` — see the vacuity note above.

const N48RaisingFirstChars = {'a', 'b', 'f', 'n', 'r', 't', 'v'}

const
  MemberPath = "mingw64/bin/n48-fake-tool.txt"
  MemberBytes = "n48 msys2 member payload\n"

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

proc n48WorkDirFor(caseRoot, leaf: string): string =
  ## ``<caseRoot><DirSep><leaf>`` — the ``workDir`` ``tarExtractMember``
  ## derives its scratch directory from. The shape is asserted rather than
  ## assumed: the leaf must sit straight behind a backslash on Windows, and
  ## that backslash must be the only one in the path, so a red names one
  ## cause. (The product appends ``\.m6-extract-scratch`` of its own; ``\.``
  ## is not one of GNU tar's escapes, so it is inert and the leaf stays the
  ## only variable.)
  result = caseRoot & $DirSep & leaf
  when defined(windows):
    doAssert result.contains('\\' & leaf[0]),
      "N48 workDir no longer puts the leaf straight after a backslash: " &
      result
    doAssert result.count('\\') == 1,
      "N48 workDir must carry EXACTLY ONE backslash so a red names one " &
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

proc n48BuildPkgTarZst(tarExe, zstdExe: string): string =
  ## A real ``.pkg.tar.zst`` at a RELATIVE, forward-slash-only path, so the
  ## destination cases vary ONE thing.
  let payloadRoot = N48Root & "/payload"
  n48Reset(payloadRoot)
  createDir(extendedPath(payloadRoot / MemberPath.parentDir))
  writeFile(extendedPath(payloadRoot / MemberPath), MemberBytes)
  let archiveDir = N48Root & "/archive"
  n48Reset(archiveDir)
  let plainTar = archiveDir & "/n48-fixture.tar"
  let tarRes = execCmdEx(
    shellArgv([tarExe, "-cf", plainTar, "-C", payloadRoot, "."]))
  doAssert tarRes.exitCode == 0,
    "could not build the N48 msys2 fixture tar: " & tarRes.output
  result = archiveDir & "/n48-fixture.pkg.tar.zst"
  let zstdRes = execCmdEx(
    shellArgv([zstdExe, "-q", "-f", "-o", result, plainTar]))
  doAssert zstdRes.exitCode == 0,
    "could not zstd the N48 msys2 fixture tar: " & zstdRes.output
  removeFile(extendedPath(plainTar))
  doAssert not result.contains('\\'),
    "the fixture archive path must carry no backslash: " & result

suite "N48 msys2 harvester tar operands":

  test "test_n48_msys2_extracts_members_into_dirs_gnu_tar_would_unquote":
    let tarExe = findExe("tar")
    let zstdExe = findExe("zstd")
    if tarExe.len == 0 or zstdExe.len == 0:
      echo "  [skip] this case needs BOTH `tar` and `zstd` on PATH " &
        "(tar=" & tarExe & " zstd=" & zstdExe & ")"
      skip()
    else:
      checkpoint("tar under test: " & tarExe)
      checkpoint("zstd under test: " & zstdExe)
      n48Reset(N48Root)
      let archive = n48BuildPkgTarZst(tarExe, zstdExe)
      # ``t`` is the letter a future author writes without thinking; ``0`` is
      # the one that does not fail. ``sierra`` is the control: under every
      # mutation it stays GREEN, which is what makes the others' reds mean
      # something.
      let leaves = ["tango-n48", "0zero-n48", "sierra-n48"]
      n48AssertLeavesStillTest(leaves)
      for leaf in leaves:
        let caseRoot = N48Root & "/msys2-" & leaf
        n48Reset(caseRoot)
        let workDir = n48WorkDirFor(caseRoot, leaf)
        createDir(extendedPath(workDir))
        let destFile = workDir / "n48-extracted.txt"
        var extracted = false
        var raisedWith = ""
        try:
          extracted = tarExtractMember(archive, "./" & MemberPath, destFile)
        except CatchableError as err:
          raisedWith = err.msg
        checkpoint("leaf=" & leaf & " workDir=" & workDir &
          " returned=" & $extracted &
          (if raisedWith.len > 0: " raised: " & raisedWith else: ""))
        check raisedWith.len == 0
        # The verdict the harvester actually consumes ...
        check extracted
        # ... and the bytes, in the intended place.
        check fileExists(extendedPath(destFile))
        if fileExists(extendedPath(destFile)):
          check readFile(extendedPath(destFile)) == MemberBytes
        # ... AND NOWHERE ELSE. Pre-fix the ``0zero`` leaf let tar chdir to
        # the parent and unpack ``mingw64`` there while still exiting 0.
        let siblings = n48EntriesDirectlyUnder(caseRoot)
        checkpoint("leaf=" & leaf & " entries directly under the parent: " &
          siblings.join(", "))
        check siblings == @[leaf]

  test "test_n48_msys2_lists_an_absolute_windows_archive_path":
    ## ``tarListEntries`` is the other half of the same pair: every operand it
    ## builds is a ``-f``, from an absolute path, with its scratch tar under
    ## ``getTempDir()``. What it needs is ``--force-local`` — without it the
    ## drive letter alone is read as a remote host and the listing never
    ## happens (that is the mutation this case reds under).
    ##
    ## The temp directory is steered onto a ``\t`` component anyway. Not
    ## because the case needs it to fail — measurement says an ``-f`` operand
    ## is not unquoted — but because that was the ASSUMPTION this file was
    ## first written on, and pinning the ambient ``%TEMP%`` out of the picture
    ## is what makes the verdict a statement about the code rather than about
    ## whatever directory the host handed us.
    let tarExe = findExe("tar")
    let zstdExe = findExe("zstd")
    if tarExe.len == 0 or zstdExe.len == 0:
      echo "  [skip] this case needs BOTH `tar` and `zstd` on PATH " &
        "(tar=" & tarExe & " zstd=" & zstdExe & ")"
      skip()
    else:
      checkpoint("tar under test: " & tarExe)
      n48Reset(N48Root)
      let archive = absolutePath(n48BuildPkgTarZst(tarExe, zstdExe))
      when defined(windows):
        doAssert archive.contains(':'),
          "this case is only a witness when the archive path carries a " &
          "drive letter: " & archive
        doAssert archive.contains('\\'),
          "this case is only a witness when the archive path is " &
          "backslashed: " & archive
      checkpoint("absolute archive: " & archive)
      # ``tarListEntries`` decompresses into ``getTempDir()`` and lists THAT
      # file first, so whatever the ambient ``%TEMP%`` happens to be decides
      # which of its three attempts actually runs. On this host
      # ``C:\Users\…\AppData\Local\Temp\`` holds no escape component, the
      # first attempt succeeds, and the two archive-path fallbacks are never
      # reached. The temp directory is therefore STEERED onto a ``\t``
      # component for the duration, and the steer is ASSERTED, not assumed —
      # not because an ``-f`` operand is unquoted (measured: it is not) but so
      # the verdict is a statement about the code rather than about whichever
      # directory the host handed us.
      let originalTemp = getEnv("TEMP")
      let originalTmp = getEnv("TMP")
      let originalTmpDir = getEnv("TMPDIR")
      let steeredTemp = absolutePath(N48Root & "/tango-tmp")
      n48Reset(N48Root & "/tango-tmp")
      putEnv("TEMP", steeredTemp)
      putEnv("TMP", steeredTemp)
      putEnv("TMPDIR", steeredTemp)
      defer:
        putEnv("TEMP", originalTemp)
        putEnv("TMP", originalTmp)
        putEnv("TMPDIR", originalTmpDir)
      when defined(windows):
        doAssert getTempDir().replace('/', DirSep).contains(DirSep & "tango-tmp"),
          "the temp directory was not steered onto a backslash-t component, " &
          "so this case cannot witness the unquoting defect: " & getTempDir()
      checkpoint("steered temp dir: " & getTempDir())
      var entries: seq[string] = @[]
      var raisedWith = ""
      try:
        entries = tarListEntries(archive)
      except CatchableError as err:
        raisedWith = err.msg
      checkpoint(if raisedWith.len > 0: "raised: " & raisedWith
                 else: "entries: " & entries.join(", "))
      check raisedWith.len == 0
      check entries.anyIt(it.replace('\\', '/').endsWith(MemberPath))
