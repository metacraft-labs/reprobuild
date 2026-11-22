## A provider that holds its recipe's source path as a VALUE is bound to the
## location it was compiled at; one that carries it only as compiler line
## information is not.
##
## WHY. A recipe-relative provider compile is shared by every byte-identical
## copy of a recipe (Hermetic-Builds-And-Path-Independence.md §"Engine-internal
## recipe compiles", "Location-bound providers"). `providerLocationEmbedding`
## decides whether a compiled provider may be shared, by looking for the
## recipe directory in its bytes. Every provider carries
## `<recipeDir>/repro.nim` as line information, so that spelling has to be
## exempt. `currentSourcePath()` in the recipe evaluates to exactly the same
## spelling. While the exemption looked at the path alone, a recipe that used
## `currentSourcePath()` at run time was shared, and a second worktree's build
## wrote into the first worktree (reprobuild-pm issue
## `2026-11-19-a-cached-provider-compile-is-reused-across-checkouts-so-currentsourcepath-names-another-checkout.md`).
##
## Asserts, on programs compiled by the real compiler in a directory that
## stands for the recipe's:
##   * EXEMPT: stack-trace frames and an assertion's rendered position;
##   * BINDING: `currentSourcePath()` used at run time, the same path from
##     `instantiationInfo(fullPaths = true)`, the path folded into a longer
##     constant (after printable text or after a line break), and the
##     directory in a `const`, alone or behind a flag such as `-I`.
## Falsifiability (observed): with the exemption applied to every occurrence
## of the source file path, the source-path cases report "" (shareable); with
## only the header test removed, the 256-byte big-endian case does.
##
## NO MOCKS: the real `nim c`, and the real verdict function over the bytes
## it produced.

import std/[os, osproc, strutils, unittest]

import repro_interface_artifacts

const
  LineInformationOnly = """
proc fail() =
  raise newException(ValueError, "x")

doAssert paramCount() >= 0
if paramCount() > 5:
  fail()
"""
  RunTimeSourcePath = """
echo currentSourcePath().parentDir().lastPathPart
"""
  InstantiationPath = """
template here(): string = instantiationInfo(fullPaths = true).filename
echo here().parentDir()
"""
  FoldedIntoAConstant = """
const where = "recipe=" & currentSourcePath()
echo where
"""
  DirectoryConstant = """
const root = parentDir(currentSourcePath())
echo root
"""
  DirectoryBehindAFlag = """
const includeFlag = "-I" & parentDir(currentSourcePath())
echo includeFlag
"""
  AfterALineBreak = """
const listing = "sources:\n" & currentSourcePath()
echo listing
"""

proc verdictFor(root, name, body: string): string =
  ## The verdict for `body` compiled as `repro.nim` in its own directory.
  let dir = root / name
  createDir(dir)
  writeFile(dir / "repro.nim", "import std/os\n" & body)
  let binary = root / (name & "-bin")
  let res = execCmdEx(quoteShellCommand([findExe("nim"), "c", "--hints:off",
    "--warnings:off", "--nimcache:" & (root / (name & "-nimcache")),
    "--out:" & binary, "repro.nim"]), workingDir = dir)
  if res.exitCode != 0:
    checkpoint(res.output)
  doAssert res.exitCode == 0, "the fixture did not compile: " & name
  providerLocationEmbedding(readFile(binary), dir)

suite "the provider location verdict":

  test "a source path held as a value binds; line information does not":
    if findExe("nim").len == 0:
      checkpoint("nim is not on PATH")
      fail()
    else:
      let root = expandFilename(getTempDir()) /
        ("rb-location-verdict-" & $getCurrentProcessId())
      removeDir(root)
      createDir(root)
      defer: removeDir(root)

      # The precondition of the exempt case: the path IS in the binary, so
      # the "" below is the exemption at work and not an absent string.
      let plainDir = root / "line-info"
      check verdictFor(root, "line-info", LineInformationOnly) == ""
      check (plainDir / "repro.nim") in readFile(root / "line-info-bin")

      check verdictFor(root, "run-time", RunTimeSourcePath) ==
        root / "run-time" / "repro.nim"
      check verdictFor(root, "instantiation", InstantiationPath) ==
        root / "instantiation" / "repro.nim"
      check verdictFor(root, "folded", FoldedIntoAConstant) ==
        root / "folded" / "repro.nim"
      check verdictFor(root, "directory", DirectoryConstant) ==
        root / "directory"
      check verdictFor(root, "flag", DirectoryBehindAFlag) == root / "flag"
      check verdictFor(root, "line-break", AfterALineBreak) ==
        root / "line-break" / "repro.nim"

  test "the storage of the path decides, on hand-built bytes":
    let dir = expandFilename(getTempDir()) /
      ("rb-location-bytes-" & $getCurrentProcessId())
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "repro.nim", "")
    let path = dir / "repro.nim"
    proc word(value: uint64; width: int; bigEndian: bool): string =
      for i in 0 ..< width:
        let shift = if bigEndian: 8 * (width - 1 - i) else: 8 * i
        result.add(char((value shr shift) and 0xff))

    # A C string literal between two terminators: a stack-trace frame.
    check providerLocationEmbedding("f\0" & path & "\0", dir) == ""
    # Nim's rendered position, wherever it stands.
    check providerLocationEmbedding(
      "\0" & path & "(12, 3) `ok` \0", dir) == ""
    # The payload of a Nim string literal, for each word size and byte order.
    for width in [8, 4]:
      for bigEndian in [false, true]:
        let header = word(uint64(path.len) or (1'u64 shl (width * 8 - 2)),
          width, bigEndian)
        check providerLocationEmbedding(
          "\0\0\0\0\0\0\0\0" & header & path & "\0", dir) == path
    # The header alone decides where the capacity word ends in a zero byte:
    # big-endian, and a path whose length is a multiple of 256. Without the
    # header test this literal would read as a C string between terminators.
    let longDir = dir / repeat('d', 256 - (dir.len + 1) - "/repro.nim".len)
    createDir(longDir)
    writeFile(longDir / "repro.nim", "")
    let longPath = longDir / "repro.nim"
    check longPath.len == 256
    for width in [8, 4]:
      let header = word(256'u64 or (1'u64 shl (width * 8 - 2)), width,
        bigEndian = true)
      check header[^1] == '\0'
      check providerLocationEmbedding(
        "\0\0\0\0\0\0\0\0" & header & longPath & "\0", longDir) == longPath
    check providerLocationEmbedding("\0" & longPath & "\0", longDir) == ""
    # Part of a longer constant, on either side, printable or not.
    check providerLocationEmbedding("\0out=" & path & "\0", dir) == path
    check providerLocationEmbedding("\0a:\n" & path & "\0", dir) == path
    check providerLocationEmbedding("\0" & path & ":12\0", dir) == path
    # The directory behind a flag binds; a longer path that ends in the
    # same components is another directory and does not.
    check providerLocationEmbedding("\0-I" & dir & "\0", dir) == dir
    check providerLocationEmbedding("\0/other" & dir & "\0", dir) == ""
    # Not a position: a call-shaped suffix that is not `(<line>, <column>)`.
    check providerLocationEmbedding("\0" & path & "(x)\0", dir) == path
    # A source file that does not exist beside the recipe was never exempt.
    check providerLocationEmbedding(
      "\0" & dir / "absent.nim" & "\0", dir) == dir / "absent.nim"
