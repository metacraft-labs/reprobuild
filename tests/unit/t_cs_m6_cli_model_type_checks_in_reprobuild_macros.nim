## Every reprobuild macro that builds a clispec model places clispec's
## `cliModelTypeChecks` in its output, so a `default` or `implies` value that
## is not a value of its parameter's type is a compile error naming the
## parameter, at the line that wrote it.
##
## clispec's parser checks what it can tell from spellings. Whether an
## expression is a value of a type needs the compiler, so clispec generates
## those checks as code (`cliModelTypeChecks`) and a macro that builds a model
## must place them in its output. Three macros build one here:
##
## * the `package` macro, for each `executable`'s `cli:` block;
## * `defineCliInterface`;
## * `reproProgramCode`, which generates repro's own command line from its
##   description (`repro_cli_support/cli_program`).
##
## Each fixture under `tests/unit/fixtures/cs_m6_cli_model_type_checks/`
## writes a value that is wrong under `-d:csM6Wrong` and right otherwise. The
## first three declare `flag jobs is int, default = csM6Default`, where
## `csM6Default` is the string `"four"` under the define and the integer `4`
## otherwise. `defineCliInterface` reads `implies` too:
## `define_cli_interface_implies.nim` declares `boolFlag fast, implies =
## [jobs = csM6Implied]`, a string under the define and an `int` (the type of
## `jobs`, not of `fast`) otherwise; `define_cli_interface_implies_unknown.nim`
## makes a top-level flag imply a subcommand's parameter under the define,
## which `defineCliInterface` refuses as a `cli:` block does, and a top-level
## one otherwise. For each fixture:
##
## 1. with the define, the compile fails, with the message naming the
##    parameter and the value, in the fixture on the line marked `# CHECK`,
##    the line that wrote the value (not the enclosing command's);
## 2. CONTROL: without it, the same fixture compiles. If it did not, the
##    fixture would be broken for another reason and case 1 would prove
##    nothing.
##
## The compile is the subject (it must fail), so no build edge produces it.
##
## The compile is `nim c --compileOnly`, not `nim check`: `nim check` does not
## run `gorgeEx`, so the repo-root `config.nims` cannot tell a stale sibling
## checkout of a pinned library from a work in progress there and keeps the
## sibling, and these fixtures import the pinned clispec.
##
## No mocks: the real compiler runs on real source files under this
## checkout, with the repo-root `config.nims` supplying the paths.

import std/[os, osproc, strutils, tempfiles, unittest]

const
  FixtureDir = "tests/unit/fixtures/cs_m6_cli_model_type_checks"
  DefaultExpected = "clispec: parameter 'jobs': default `csM6Default` is " &
    "not a valid int"
  Fixtures = [
    (file: "package_cli.nim", expected: DefaultExpected),
    (file: "define_cli_interface.nim", expected: DefaultExpected),
    (file: "repro_description.nim", expected: DefaultExpected),
    (file: "define_cli_interface_implies.nim",
      expected: "clispec: parameter 'fast': implies jobs = `csM6Implied`, " &
        "which is not a valid int (the type of 'jobs')"),
    (file: "define_cli_interface_implies_unknown.nim",
      expected: "parameter 'verbose': implies 'jobs', which is not a " &
        "parameter of the interface's top level")]

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while not fileExists(dir / "repro_tests.nim"):
    let parent = dir.parentDir
    doAssert parent != dir, "cannot locate the reprobuild repository root"
    dir = parent
  dir

proc checkLine(path: string): int =
  ## The 1-based line marked `# CHECK`.
  var lineNo = 0
  for line in readFile(path).splitLines():
    inc lineNo
    if "# CHECK" in line:
      return lineNo
  -1

proc nimCheck(root, fixture: string; wrong: bool):
    tuple[output: string, exitCode: int] =
  ## The semantic compile of one fixture from the repo root, with a nimcache
  ## of its own (cases may run in parallel).
  let nim = findExe("nim")
  doAssert nim.len > 0, "no `nim` on PATH; this test runs the real compiler"
  createDir(root / "build")
  let dir = createTempDir("cs-m6-type-checks-", "", root / "build")
  defer: removeDir(dir)
  var cmd = quoteShell(nim) & " c --compileOnly --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(dir / "nimcache")
  if wrong:
    cmd.add(" -d:csM6Wrong")
  cmd.add(" " & quoteShell(root / FixtureDir / fixture))
  checkpoint(cmd)
  execCmdEx(cmd, workingDir = root)

suite "CS-M6: reprobuild's clispec macros place cliModelTypeChecks":
  for (fixture, expected) in Fixtures:
    test "a wrong-typed or misdirected value is a compile error: " & fixture:
      let root = repoRoot()
      let line = checkLine(root / FixtureDir / fixture)
      check line > 0
      let (output, exitCode) = nimCheck(root, fixture, wrong = true)
      checkpoint(output)
      check exitCode != 0
      # Reported in the fixture, naming the parameter and the value, at
      # the line that wrote the value.
      var named = false
      var atLine = false
      for l in output.splitLines():
        if fixture & "(" in l and "Error:" in l and expected in l:
          named = true
          if fixture & "(" & $line & ", " in l:
            atLine = true
      check named
      check atLine

    test "control: the right value compiles: " & fixture:
      let (output, exitCode) = nimCheck(repoRoot(), fixture, wrong = false)
      checkpoint(output)
      check exitCode == 0
