## Unit tests for ``repro_core/link_target`` — a link's target is read from
## the link, on Windows as on POSIX, and never comes back as the link's own
## path.
##
## The defect (reprobuild-pm issue
## ``2026-10-26-windows-stow-drift-names-the-link-itself-as-its-different-source``):
## Nim's ``os.expandSymlink`` returns its argument on Windows, so every
## caller that read a link there got the link's path back. The Windows
## reader parses the ``REPARSE_DATA_BUFFER`` returned by
## ``FSCTL_GET_REPARSE_POINT``
## (https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_reparse_data_buffer).
##
## Two halves, no mocks:
##
## * The parser is a pure function over bytes, so the byte layout is checked
##   on every host. The three ``Recorded*`` buffers are NOT hand-built: they
##   are the bytes ``fsutil reparsepoint query`` printed on eli-pc
##   (Windows 11, 2026-10-26) for links ``mklink`` and ``mklink /J`` made,
##   with the 8-byte header ``fsutil`` reports separately (tag, data length)
##   prepended. Note that ``mklink`` stores the PRINT name first, at offset
##   0, and the substitute name after it — so a parser that assumed the
##   substitute name leads would read the wrong string.
## * The filesystem half creates real links (file and directory, absolute
##   and relative; a junction on Windows) in a fresh temporary directory and
##   reads them back through ``readSymlinkTarget`` — the system call path
##   the parser sits behind. It runs on every host: on POSIX it pins the
##   ``readlink`` behaviour the callers already relied on, on Windows it is
##   the regression test for the defect. The positive control is the check
##   that the answer is not the link's own path, which is exactly what
##   ``expandSymlink`` returns on Windows.

import std/[os, strutils, tempfiles, unittest]

import repro_core/link_target

proc hexBytes(text: string): seq[byte] =
  for token in text.splitWhitespace:
    result.add byte(parseHexInt(token))

proc withHeader(tag: uint32; data: seq[byte]): seq[byte] =
  ## `ReparseTag`, `ReparseDataLength`, `Reserved` — the 8 bytes `fsutil`
  ## prints as "Reparse Tag Value" / "Reparse Data Length" — then the data.
  for shift in [0, 8, 16, 24]:
    result.add byte((tag shr shift) and 0xFF)
  result.add byte(data.len and 0xFF)
  result.add byte(data.len shr 8)
  result.add [0'u8, 0]
  result.add data

proc utf16(text: string): seq[byte] =
  ## UTF-16LE of an ASCII string, for the hand-built edge cases.
  for ch in text:
    result.add [byte(ord(ch)), 0'u8]

proc symlinkBuffer(substitute, print: string; flags: uint32): seq[byte] =
  ## A symlink buffer in the substitute-first order `CreateSymbolicLinkW`
  ## documents, for edge cases no `mklink` produces.
  let sub = utf16(substitute)
  let pr = utf16(print)
  var data: seq[byte]
  proc u16(v: int) = data.add [byte(v and 0xFF), byte(v shr 8)]
  u16(0); u16(sub.len); u16(sub.len); u16(pr.len)
  for shift in [0, 8, 16, 24]:
    data.add byte((flags shr shift) and 0xFF)
  data.add sub
  data.add pr
  withHeader(IoReparseTagSymlink, data)

const
  # `mklink abs-link C:\Users\Public\repro-target.txt`
  RecordedAbsoluteSymlink = """
    40 00 48 00 00 00 40 00  00 00 00 00 43 00 3a 00
    5c 00 55 00 73 00 65 00  72 00 73 00 5c 00 50 00
    75 00 62 00 6c 00 69 00  63 00 5c 00 72 00 65 00
    70 00 72 00 6f 00 2d 00  74 00 61 00 72 00 67 00
    65 00 74 00 2e 00 74 00  78 00 74 00 5c 00 3f 00
    3f 00 5c 00 43 00 3a 00  5c 00 55 00 73 00 65 00
    72 00 73 00 5c 00 50 00  75 00 62 00 6c 00 69 00
    63 00 5c 00 72 00 65 00  70 00 72 00 6f 00 2d 00
    74 00 61 00 72 00 67 00  65 00 74 00 2e 00 74 00
    78 00 74 00"""
  # `mklink rel-link ..\sub\target.txt`
  RecordedRelativeSymlink = """
    22 00 22 00 00 00 22 00  01 00 00 00 2e 00 2e 00
    5c 00 73 00 75 00 62 00  5c 00 74 00 61 00 72 00
    67 00 65 00 74 00 2e 00  74 00 78 00 74 00 2e 00
    2e 00 5c 00 73 00 75 00  62 00 5c 00 74 00 61 00
    72 00 67 00 65 00 74 00  2e 00 74 00 78 00 74 00"""
  # `mklink /J junction C:\Users\Public`
  RecordedJunction = """
    00 00 26 00 28 00 1e 00  5c 00 3f 00 3f 00 5c 00
    43 00 3a 00 5c 00 55 00  73 00 65 00 72 00 73 00
    5c 00 50 00 75 00 62 00  6c 00 69 00 63 00 00 00
    43 00 3a 00 5c 00 55 00  73 00 65 00 72 00 73 00
    5c 00 50 00 75 00 62 00  6c 00 69 00 63 00 00 00"""

suite "REPARSE_DATA_BUFFER parsing (recorded on Windows, checked anywhere)":

  test "absolute symlink: the substitute name, in its Win32 spelling":
    let parsed = parseReparseDataBuffer(
      withHeader(IoReparseTagSymlink, hexBytes(RecordedAbsoluteSymlink)))
    check parsed.ok
    check parsed.kind == rlkSymlink
    check not parsed.relative
    check parsed.printName == r"C:\Users\Public\repro-target.txt"
    check parsed.substituteName == r"\??\C:\Users\Public\repro-target.txt"
    check parsed.target == r"C:\Users\Public\repro-target.txt"

  test "relative symlink keeps its relative text and flag":
    let parsed = parseReparseDataBuffer(
      withHeader(IoReparseTagSymlink, hexBytes(RecordedRelativeSymlink)))
    check parsed.ok
    check parsed.relative
    check parsed.target == r"..\sub\target.txt"

  test "junction: mount-point layout, names exclude their terminators":
    let parsed = parseReparseDataBuffer(
      withHeader(IoReparseTagMountPoint, hexBytes(RecordedJunction)))
    check parsed.ok
    check parsed.kind == rlkMountPoint
    check parsed.substituteName == r"\??\C:\Users\Public"
    check parsed.target == r"C:\Users\Public"

  test "the target is the substitute name; an empty print name is fine":
    check parseReparseDataBuffer(symlinkBuffer(
      r"\??\D:\data\file", "", 0)).target == r"D:\data\file"
    check parseReparseDataBuffer(symlinkBuffer(
      r"\??\UNC\server\share\file", "", 0)).target ==
      r"\\server\share\file"
    # A relative substitute name carries no NT prefix to strip.
    check parseReparseDataBuffer(symlinkBuffer(
      r"..\x", "", SymlinkFlagRelative)).target == r"..\x"

  test "a print name that disagrees with the substitute name is not believed":
    # `FSCTL_SET_REPARSE_POINT` stores any print name. The OS follows the
    # substitute name, so that is where the link points; a reader that
    # returned the print name would let this link pass a containment check
    # for `C:\inside` while it opens `D:\outside`.
    let parsed = parseReparseDataBuffer(symlinkBuffer(
      r"\??\D:\outside\file", r"C:\inside\file", 0))
    check parsed.ok
    check parsed.printName == r"C:\inside\file"
    check parsed.target == r"D:\outside\file"

  test "a volume-GUID substitute keeps its device prefix":
    # A volume mount point's substitute name has no drive letter; dropping
    # `\??\` alone would leave the relative path `Volume{...}\`.
    check parseReparseDataBuffer(symlinkBuffer(
      r"\??\Volume{0b1c2d3e-0000-0000-0000-100000000000}\", "", 0)).target ==
      r"\\?\Volume{0b1c2d3e-0000-0000-0000-100000000000}\"

  test "surrogate pairs decode to one code point":
    # U+1F600 is D83D DE00 in UTF-16.
    let name = @[byte 0x43, 0, 0x3A, 0, 0x5C, 0, 0x3D, 0xD8, 0x00, 0xDE]
    var data: seq[byte] = @[byte 0, 0, byte(name.len), 0, 0, 0, 0, 0,
                             0, 0, 0, 0]
    data.add name
    let parsed = parseReparseDataBuffer(withHeader(IoReparseTagSymlink, data))
    check parsed.ok
    check parsed.target == "C:\\\xF0\x9F\x98\x80"

  test "other tags are refused, named by their tag":
    # IO_REPARSE_TAG_APPEXECLINK — the WindowsApps execution aliases.
    let parsed = parseReparseDataBuffer(
      withHeader(0x8000001B'u32, hexBytes(RecordedJunction)))
    check not parsed.ok
    check "0x8000001B" in parsed.reason

  test "a buffer that does not hold together is refused, not over-read":
    check not parseReparseDataBuffer(@[byte 0x0C, 0, 0, 0xA0]).ok
    let full = withHeader(IoReparseTagSymlink,
      hexBytes(RecordedAbsoluteSymlink))
    # Truncated inside the substitute name.
    let truncated = parseReparseDataBuffer(full[0 ..< full.len - 6])
    check not truncated.ok
    check "runs past" in truncated.reason
    # ReparseDataLength claims less than the names need.
    var shortLen = full
    # version-literal-ok: bytes 4-5 are ReparseDataLength, not a version word
    shortLen[4] = 0x20
    # version-literal-ok: high byte of ReparseDataLength in REPARSE_DATA_BUFFER
    shortLen[5] = 0
    check not parseReparseDataBuffer(shortLen).ok
    # Header of a symlink with no room for its own fields.
    check not parseReparseDataBuffer(
      withHeader(IoReparseTagSymlink, @[byte 0, 0, 0, 0])).ok
    # A print-name offset far past the buffer (0xFFFF), names otherwise
    # sound: refused on the print name, not read from beyond the buffer.
    var farPrint = full
    farPrint[12] = 0xFF
    farPrint[13] = 0xFF
    let far = parseReparseDataBuffer(farPrint)
    check not far.ok
    check "print name" in far.reason

  test "the NT prefix is stripped only where it is a prefix":
    check stripNtObjectPrefix(r"\??\C:\x") == r"C:\x"
    check stripNtObjectPrefix(r"\\?\C:\x") == r"C:\x"
    check stripNtObjectPrefix(r"\\?\UNC\h\s") == r"\\h\s"
    check stripNtObjectPrefix(r"\??\GLOBALROOT\Device\X") ==
      r"\\?\GLOBALROOT\Device\X"
    check stripNtObjectPrefix(r"C:\a\??\b") == r"C:\a\??\b"
    check stripNtObjectPrefix("/home/x") == "/home/x"

suite "readSymlinkTarget against real links":

  proc scratch(): string =
    result = createTempDir("repro-link-target-", "")
    createDir(result / "sub" / "dir")
    writeFile(result / "sub" / "file.txt", "payload")

  proc cleanup(root: string) =
    # Best effort: a directory symlink is not removable by every
    # `removeFile` spelling on Windows, and a failed cleanup of a fresh
    # temporary directory is not what these cases test.
    try: removeDir(root) except OSError: discard

  test "absolute and relative, file and directory links":
    let root = scratch()
    defer: cleanup(root)
    let cases = [
      (link: root / "abs-file", text: root / "sub" / "file.txt"),
      (link: root / "abs-dir", text: root / "sub" / "dir"),
      (link: root / "rel-file", text: "sub" / "file.txt"),
      (link: root / "rel-dir", text: "sub" / "dir")]
    # Created from inside `root`: on Windows `createSymlink` decides
    # file-vs-directory link by `dirExists(text)`, which resolves a relative
    # text against the CURRENT directory.
    let previous = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(previous)
    for c in cases:
      # On Windows this needs the symlink privilege or Developer Mode;
      # eli-pc has it. A host without it fails here, loudly.
      createSymlink(c.text, c.link)
      checkpoint c.link
      check symlinkExists(c.link)
      let read = readSymlinkTarget(c.link)
      # The positive control: `expandSymlink` returns `c.link` on Windows.
      check read != c.link
      check read == c.text
      check resolvedSymlinkTarget(c.link) ==
        normalizedPath(if c.text.isAbsolute: c.text else: root / c.text)
    # A relative link one level down resolves against ITS directory.
    createSymlink(".." / "file.txt", root / "sub" / "dir" / "up")
    check resolvedSymlinkTarget(root / "sub" / "dir" / "up") ==
      normalizedPath(root / "sub" / "file.txt")

  test "a dangling link still reads":
    let root = scratch()
    defer: cleanup(root)
    let gone = root / "no-such-target"
    createSymlink(gone, root / "dangling")
    check readSymlinkTarget(root / "dangling") == gone

  test "a regular file is not a link: OSError, never its own path":
    let root = scratch()
    defer: cleanup(root)
    expect OSError:
      discard readSymlinkTarget(root / "sub" / "file.txt")
    expect OSError:
      discard readSymlinkTarget(root / "absent")

  when defined(windows):
    test "a junction reads as its target directory":
      let root = scratch()
      defer: cleanup(root)
      let junction = root / "junction"
      let made = execShellCmd("cmd /c mklink /J " & quoteShell(junction) &
        " " & quoteShell(root / "sub" / "dir") & " >NUL")
      check made == 0
      check readSymlinkTarget(junction) == root / "sub" / "dir"

    test "the extended-length spelling reads the same link":
      let root = scratch()
      defer: cleanup(root)
      createSymlink(root / "sub" / "file.txt", root / "abs")
      check readSymlinkTarget(r"\\?\" & (root / "abs")) ==
        root / "sub" / "file.txt"
      check resolvedSymlinkTarget(r"\\?\" & (root / "abs")) ==
        root / "sub" / "file.txt"
