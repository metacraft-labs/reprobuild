## The static reader's declarative subset: what each class means, field by
## field, and the structural errors that make a file unreadable.

import std/[os, unittest]

import repro_nimble_reader
import repro_test_support/process_fixtures

proc read(src: string; options = ReaderOptions()): NimbleFile =
  readNimbleSource(src, "fixture.nimble", options)

proc hasIssue(f: NimbleFile; kind: IssueKind): bool =
  for i in f.issues:
    if i.kind == kind:
      return true
  false

suite "static reader: plain files":
  test "every literal field of the version record is read":
    let f = read("""
# Package
version       = "0.3.1"
author        = "A. Author"
description   = "Something"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
backend       = "cpp"
bin           = @["tool", "other"]
namedBin      = {"tool_main": "tool"}.toTable()
installDirs   = @["assets"]
installFiles  = @["tool.nim"]
installExt    = @["nim"]
skipDirs      = @["tests", "examples"]
skipFiles     = @["README.md"]
skipExt       = @["md"]
paths         = @["src", "vendor"]
installExt.add "json"
bin &= "third"

# Dependencies

requires "nim >= 1.6.0"
requires("stew", "results >= 0.4")
requires @["faststreams#head"]
""")
    check f.readerClass == rcPlain
    check f.resolutionClass == rcPlain
    check f.issues.len == 0
    check f.version == "0.3.1"
    check f.author == "A. Author"
    check f.srcDir == "src"
    check f.binDir == "bin"
    check f.backend == "cpp"
    check f.bin == @["tool", "other", "third"]
    check f.namedBin == @[("tool_main", "tool")]
    check f.installExt == @["nim", "json"]
    check f.skipDirs == @["tests", "examples"]
    check f.paths == @["src", "vendor"]
    check f.nim.len == 1
    check f.requires.len == 3
    check f.requires[2].requirement.version.kind == vkHead

  test "the other namedBin spellings and an indexed assignment":
    for src in ["namedBin = toTable({\"a\": \"b\"})",
                "namedBin = toTable {\"a\": \"b\"}",
                "namedBin = {\"a\": \"b\"}.toTable",
                "namedBin[\"a\"] = \"b\""]:
      checkpoint src
      let f = read(src & "\n")
      check f.readerClass == rcPlain
      check f.namedBin == @[("a", "b")]

  test "identifiers compare style-insensitively, keywords and comments are skipped":
    let f = read("src_dir = \"lib\"\n#[ requires \"hidden\" ]#\n" &
                 "## requires \"doc\"\nrequires \"\"\"x >= 1\"\"\"\n")
    check f.readerClass == rcPlain
    check f.srcDir == "lib"
    check f.requires.len == 1
    check f.requires[0].requirement.target.name == "x"

  test "statements that set no field are ignored":
    let f = read("import os, strutils\n--define:release\nswitch(\"path\", \"src\")\n" &
                 "echo \"hi\"\nconst x = 1\nproc helper() = echo \"x\"\n" &
                 "requires \"a\"\n")
    check f.readerClass == rcPlain
    check f.requires.len == 1
    # An import list on the following lines, one module per line: the
    # items are deeper than the `import`, so the commas continue it.
    let g = read("import\n  os,\n  strutils\nwhen defined(linux):\n" &
                 "  import\n    sugar,\n    sequtils\nrequires \"a\"\n")
    check g.readerClass == rcPlain
    check g.issues.len == 0
    check g.requires.len == 1

  test "a multi-line requires call is read":
    let f = read("requires \"a >= 1\",\n         \"b\",\n  \"c\"\nrequires(\n  \"d\",\n  \"e\")\n")
    check f.readerClass == rcPlain
    check f.requires.len == 5

suite "static reader: closed-when and feature":
  test "a layout field under a closed condition is conditional data":
    let f = read("when defined(windows):\n  bin = @[\"tool.exe\"]\nelse:\n  bin = @[\"tool\"]\n")
    check f.readerClass == rcClosedWhen
    check f.bin.len == 0
    require f.conditionalFields.len == 2
    check f.conditionalFields[0].field == fBin
    check $f.conditionalFields[0].condition == "defined(windows)"
    check f.conditionalFields[1].values == @["tool"]

  test "hostCPU and inline else":
    let f = read("when hostCPU == \"arm64\": requires \"a\" else: requires \"b\"\n")
    check f.readerClass == rcClosedWhen
    require f.requires.len == 2
    check $f.requires[0].condition == "hostCPU == \"arm64\""
    check $f.requires[1].condition == "not (hostCPU == \"arm64\")"

  test "feature and dev blocks are their own requirement lists":
    let f = read("requires \"base\"\nfeature \"chronos\":\n  requires \"chronos >= 4\"\n" &
                 "  when defined(linux):\n    requires \"epoll\"\n" &
                 "dev:\n  requires \"unittest2\"\n")
    check f.readerClass == rcFeature
    check f.requires.len == 1
    require f.features.len == 2
    check f.features[0].name == "chronos"
    check not f.features[0].rootOnly
    check f.features[0].requires.len == 2
    check $f.features[0].requires[1].condition == "defined(linux)"
    check f.features[1].name == "dev"
    check f.features[1].rootOnly

  test "a requirement may activate the features of its target":
    let f = read("requires \"figdraw[siwin, harfbuzz] >= 0.35\"\n")
    check f.readerClass == rcPlain
    check f.requires[0].requirement.features == @["siwin", "harfbuzz"]

  test "taskRequires is recorded for develop mode and does not change the class":
    let f = read("requires \"a\"\ntaskRequires \"test\", \"unittest2 >= 0.2\"\n")
    check f.readerClass == rcPlain
    require f.taskRequires.len == 1
    check f.taskRequires[0].task == "test"
    check f.taskRequires[0].requires[0].requirement.target.name == "unittest2"

  test "foreignDep is recorded":
    let f = read("when defined(linux):\n  foreignDep \"libssl-dev\"\n")
    check f.foreignDeps.len == 1
    check f.foreignDeps[0].name == "libssl-dev"
    check $f.foreignDeps[0].condition == "defined(linux)"

suite "static reader: needs-probe":
  test "computed values":
    for src in ["version = pkgVersion", "srcDir = \"s\" & \"rc\"",
                "bin = listFiles(\"x\")", "namedBin = {\"a\": \"b\"}",
                "srcDir = [\"src\"]", "requires deps",
                "requires \"a\" & \"b\"",
                # Nim continues a line after a binary operator at the same
                # column (unlike after a comma), so this parses and is
                # computed, not a syntax error.
                "requires \"a\" &\n\"b\""]:
      checkpoint src
      let f = read(src & "\n")
      check f.readerClass == rcNeedsProbe
      check flUnreadable in f.flags
      check not f.hasIssue(ikParseError)

  test "requires in a loop, a routine, a block or an unknown statement":
    # The last two are look-alikes: another identifier to Nim (the first
    # letter is case-sensitive), an error to Nimble.
    for src in ["for d in [\"a\", \"b\"]:\n  requires d\n",
                "proc addDeps() =\n  requires \"a\"\naddDeps()\n",
                "block:\n  requires \"a\"\n",
                "withDir \"x\":\n  requires \"a\"\n",
                "version = \"1\"\n[Deps]\nRequires: \"nim >= 0.15.3\"\n",
                "SrcDir = \"src\"\n"]:
      checkpoint src
      check read(src).readerClass == rcNeedsProbe

  test "a runtime if is not a when":
    let f = read("if defined(windows):\n  requires \"a\"\n")
    check f.readerClass == rcNeedsProbe
    check f.hasIssue(ikFieldsUnderIf)
    check f.requires.len == 0
    check f.undecided.len == 1

  test "a computed version alone does not affect resolution":
    let f = read("const v = \"1.0\"\nversion = v\nrequires \"a\"\n")
    check f.readerClass == rcNeedsProbe
    check f.resolutionClass == rcPlain

  test "an include of a local file":
    check read("include \"deps.nims\"\n").readerClass == rcNeedsProbe
    check read("include ./tasks.nims\n").readerClass == rcNeedsProbe
    check read("include std/os\n").readerClass == rcPlain

  test "the INI format is needs-probe unless admitted":
    let ini = "[Package]\nname = \"old\"\nversion = \"0.1\"\nsrcDir = \"src\"\n" &
              "bin = \"tool\"\n\n[Deps]\nRequires: \"nim >= 0.10, foo#head\"\n"
    let f = read(ini)
    check f.format == ffIni
    check f.readerClass == rcNeedsProbe
    check f.hasIssue(ikIniFormat)
    let admitted = read(ini, ReaderOptions(admitIniFormat: true))
    check admitted.readerClass == rcPlain
    check admitted.packageName == "old"
    check admitted.srcDir == "src"
    check admitted.bin == @["tool"]
    check admitted.nim.len == 1
    check admitted.requires.len == 1
    check read("[Package]\nnope = \"x\"\n").readerClass == rcUnreadable

suite "static reader: unreadable":
  test "files Nim cannot parse":
    for src in ["requires \"unterminated\n", "requires (\"a\"\n",
                "requires \"a\")\n", "version = \"1\"\n  srcDir = \"src\"\n",
                "when defined(linux):\nrequires \"a\"\n", "else:\n  discard\n",
                "requires\t\"a\"\n", "#[ never closed\n", "x = 'ab'\n",
                "requires \"\\q\"\n",
                # A list continued at the statement's own column, and one
                # that ends the file after its comma.
                "requires \"a\",\n\"b\"\n",
                "when defined(linux):\n  requires \"a\",\n  \"b\"\n",
                "requires \"a\", \"b\","]:
      checkpoint src
      let f = read(src)
      check f.readerClass == rcUnreadable
      check f.hasIssue(ikParseError)

  test "a requirement Nimble rejects":
    let f = read("requires \"a>=1.0\"\n")
    check f.readerClass == rcUnreadable
    check f.hasIssue(ikMalformedRequirement)

  test "a requirement naming a version of more than three components reads":
    # Needs-override before NPC-AREQ6's "any number of components"; read
    # since (NPC-M15).
    let f = read("requires \"secp256k1 >= 0.6.0.3.1\"\n")
    check f.readerClass == rcPlain
    check not f.hasIssue(ikUntranslatableRequirement)

suite "package directories":
  test "findNimbleFile finds exactly one":
    let dir = getTempDir() / ("npc_m2_dir_" & $getCurrentProcessId())
    releaseDirAtProcessExit(dir)
    createDir(dir)
    check findNimbleFile(dir).kind == lkNone
    check readPackageDir(dir).kind == prNoNimbleFile
    writeFile(dir / "pkg.nimble", "srcDir = \"lib\"\nrequires \"a\"\n")
    let found = findNimbleFile(dir)
    check found.kind == lkFound
    check found.path == dir / "pkg.nimble"
    let r = readPackageDir(dir)
    require r.kind == prRead
    check r.file.sourceDir(dir) == dir / "lib"
    writeFile(dir / "other.nimble", "")
    check findNimbleFile(dir).kind == lkMultiple
    check readPackageDir(dir).kind == prAmbiguous
    check findNimbleFile(dir / "missing").kind == lkError

  test "sourceDir without srcDir is the package directory":
    check read("").sourceDir("/p") == "/p"
