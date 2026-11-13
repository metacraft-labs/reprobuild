## The tarball listing pre-flight reads ENTRY NAMES, not tar's diagnostics.
##
## THE FAILURE THIS GUARDS (reprobuild-pm issue
## ``2026-10-16-tar-listing-preflight-reads-tar-warnings-as-archive-entries``):
## an archive packed by macOS ``/usr/bin/tar`` (bsdtar, libarchive) records
## each file's extended attributes — ``com.apple.provenance`` on every
## downloaded or quarantined file — as pax extended-header keywords named
## ``LIBARCHIVE.xattr.<name>``. GNU tar does not know that keyword and, while
## listing, prints on stderr
##
##   /nix/store/…-gnutar-1.35/bin/tar: Ignoring unknown extended header
##     keyword 'LIBARCHIVE.xattr.com.apple.provenance'
##
## The listing merged stderr into the text it validates, so that line was
## taken for an entry, and because it starts with ``/`` the absolute-path
## check refused the archive as "unsafe archive entry". Every macOS-built
## archive was refused by a host whose ``tar`` is GNU tar.
##
## WHAT IS ASSERTED
##
##   1. Control: GNU tar really does emit the warning for this fixture. If a
##      future GNU tar learned the keyword, cases 2-3 would pass vacuously.
##   2. ``validateTarEntries`` accepts the archive, and ``extractTarballArchive``
##      realizes its real bytes.
##   3. The unsafe-entry check is NOT weakened: the same pax header in front of
##      an absolute entry and in front of a ``../`` entry is still refused, and
##      the refusal names the ENTRY — not a tar diagnostic that happened to
##      start with ``/``.
##
## NO MOCKS. The fixture archives are written byte-for-byte here (ustar +
## POSIX pax, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/pax.html
## "pax Interchange Format") rather than with bsdtar ``--xattrs`` after
## ``xattr -w``, because that needs macOS (or a Linux bsdtar plus an xattr-
## capable filesystem); the bytes are exactly the shape bsdtar writes. The tar
## that reads them is the host's real GNU tar, pinned through
## ``REPRO_HOST_TAR`` so the case cannot exercise a different tar than it
## names.
##
## Skip rule: no GNU tar on PATH (the dev shell provides it). bsdtar
## understands the ``LIBARCHIVE.xattr`` keyword and prints nothing, so a
## bsdtar-only host cannot witness the defect.

import std/[os, osproc, strutils, unittest]

import repro_tool_profiles {.all.}
from repro_core/host_tar import HostTarOverrideEnv
from repro_test_support/process_fixtures import releaseDirAtProcessExit
import repro_test_support/reasoned_skip

const
  PayloadBytes = "tar-warning payload\n"
  UnknownKeyword = "LIBARCHIVE.xattr.com.apple.provenance"
    ## The keyword from the observed failure. GNU tar 1.35 knows only its own
    ## ``SCHILY.xattr.*`` spelling and the POSIX keywords.

proc octalField(value: int; width: int): string =
  ## A ustar numeric field: zero-padded octal, NUL-terminated, ``width`` bytes.
  result = toOct(value, width - 1)
  result.add('\0')

proc ustarHeader(name: string; size: int; typeflag: char): string =
  ## One 512-byte ustar header block (POSIX ``ustar`` format, field offsets
  ## per the pax specification cited above).
  doAssert name.len < 100, "fixture names fit the 100-byte name field"
  result = newString(512)
  for i in 0 ..< 512: result[i] = '\0'
  proc put(dst: var string; offset: int; s: string) =
    for i, c in s: dst[offset + i] = c
  result.put(0, name)
  result.put(100, octalField(0o644, 8))
  result.put(108, octalField(0, 8))
  result.put(116, octalField(0, 8))
  result.put(124, octalField(size, 12))
  result.put(136, octalField(0, 12))
  result.put(148, "        ")       # checksum is computed with spaces here
  result[156] = typeflag
  result.put(257, "ustar\0")
  result.put(263, "00")
  var sum = 0
  for c in result: sum += ord(c)
  result.put(148, toOct(sum, 6) & "\0 ")

proc padded(data: string): string =
  result = data
  while result.len mod 512 != 0: result.add('\0')

proc paxRecord(keyword, value: string): string =
  ## ``"%d %s=%s\n"``, where the decimal length counts the whole record,
  ## itself included.
  let body = " " & keyword & "=" & value & "\n"
  var n = body.len + 1
  while ($n).len + body.len != n: n = ($n).len + body.len
  $n & body

proc writeFixture(path, entryName: string) =
  ## A pax extended header carrying the unknown keyword, then a regular file
  ## named ``entryName`` — the layout bsdtar writes for a file with an xattr.
  let pax = paxRecord(UnknownKeyword, "AQIAAAAAAAA=")
  var bytes = ustarHeader("PaxHeader/" & entryName.replace("/", "_"),
                          pax.len, 'x')
  bytes.add(padded(pax))
  bytes.add(ustarHeader(entryName, PayloadBytes.len, '0'))
  bytes.add(padded(PayloadBytes))
  for _ in 0 ..< 2: bytes.add(newString(512))   # end-of-archive: two zero blocks
  writeFile(path, bytes)

proc gnuTarOnPath(): string =
  let t = findExe("tar")
  if t.len == 0: return ""
  let r = execCmdEx(quoteShell(t) & " --version")
  if r.exitCode == 0 and "GNU tar" in r.output: t else: ""

let root = getTempDir() / ("t-tar-listing-warnings-" & $getCurrentProcessId())
removeDir(root)
createDir(root)
releaseDirAtProcessExit(root)

suite "the tar listing pre-flight validates entries, not tar's warnings":
  let gnuTar = gnuTarOnPath()
  let savedTar = getEnv(HostTarOverrideEnv)

  setup:
    if gnuTar.len > 0: putEnv(HostTarOverrideEnv, gnuTar)

  teardown:
    if savedTar.len > 0: putEnv(HostTarOverrideEnv, savedTar)
    else: delEnv(HostTarOverrideEnv)

  test "GNU tar warns about the fixture's unknown pax keyword (control)":
    if gnuTar.len == 0:
      skip("no GNU tar on PATH; bsdtar reads the LIBARCHIVE.xattr keyword " &
           "silently, so this host cannot witness the defect")
    else:
      checkpoint("tar under test: " & gnuTar)
      let archive = root / "control.tar"
      writeFixture(archive, "pkg/tool")
      let r = execCmdEx(quoteShell(gnuTar) & " -tf " & quoteShell(archive))
      checkpoint(r.output)
      check r.exitCode == 0
      check ("Ignoring unknown extended header keyword '" & UnknownKeyword &
             "'") in r.output
      check "pkg/tool" in r.output

  test "an archive carrying an unknown pax keyword is listed and realized":
    if gnuTar.len == 0:
      skip("no GNU tar on PATH; bsdtar reads the LIBARCHIVE.xattr keyword " &
           "silently, so this host cannot witness the defect")
    else:
      checkpoint("tar under test: " & gnuTar)
      # The tool store names downloads `<sha>.archive`; mirror it so the type
      # comes only from `archiveType`.
      let archive = root / "warned.archive"
      writeFixture(archive, "pkg/tool")
      var raised = ""
      try:
        validateTarEntries(archive, "tar")
      except CatchableError as e:
        raised = e.msg
      check raised == ""
      if raised == "":
        let dest = root / "dest-warned"
        extractTarballArchive(archive, dest, "tar", 0)
        check readFile(dest / "pkg" / "tool") == PayloadBytes

  for (label, entry) in [("an absolute", "/abs/escape"),
                         ("a parent-relative", "../escape")]:
    test label & " entry behind the same pax header is still refused":
      if gnuTar.len == 0:
        skip("no GNU tar on PATH; bsdtar reads the LIBARCHIVE.xattr keyword " &
             "silently, so this host cannot witness the defect")
      else:
        checkpoint("tar under test: " & gnuTar)
        let archive = root / ("unsafe-" & entry.replace("/", "_") & ".archive")
        writeFixture(archive, entry)
        var raised = ""
        try:
          validateTarEntries(archive, "tar")
        except CatchableError as e:
          raised = e.msg
        checkpoint("raised: " & raised)
        # The refusal must name the entry itself. "unsafe archive entry:
        # <tar path>: ..." would mean a diagnostic was read as an entry, which
        # is the defect, and would hide whether the entry check ran at all.
        check raised.splitLines()[0] ==
          "tool-resolution failed: unsafe archive entry: " & entry
