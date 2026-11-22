## The completion files ``repro-completion-files`` writes
## (``repro_project_dsl/completion_files``): their names, the entry word read
## from an ``entrypoints/1`` entry list, and the scripts themselves.
##
## * a list naming a ``complete`` entry selectable at run time gives
##   ``--entrypoint=complete``; one whose ``complete`` is compile-time only,
##   one without it, and no list at all give clispec's ``__complete``;
## * a list that is not JSON, not ``entrypoints/1``, or malformed fails
##   instead of silently giving ``__complete``;
## * each script is clispec's ``cliCompletionScript`` for that shell, program
##   and word, byte for byte, written under the release's file names;
## * the producer's command line: its usage errors exit 2, a bad program
##   name or list exits 1 and writes nothing.
##
## No mocks: the module is called directly, against a scratch directory.

import std/[os, strutils, tempfiles, unittest]

import clispec/[completion, completion_scripts, parser]
import repro_project_dsl/completion_files

const
  DescribeList = """{"schema":"entrypoints/1","program":"tool",""" &
    """"default":"main","entries":[{"name":"main","doc":"run the program",""" &
    """"select":["compiletime","runtime"]},{"name":"complete",""" &
    """"doc":"answer a shell's completion request",""" &
    """"select":["compiletime","runtime"],"args":"<shell> <words...>"}]}"""
  MainOnlyList = """{"schema":"entrypoints/1","program":"tool",""" &
    """"default":"main","entries":[{"name":"main","doc":"run the program",""" &
    """"select":["compiletime","runtime"]}]}"""
  CompileTimeCompleteList = """{"schema":"entrypoints/1",""" &
    """"program":"tool","default":"complete","entries":[{"name":"complete",""" &
    """"doc":"x","select":["compiletime"]}]}"""

proc scratchDir(): string =
  createTempDir("t-completion-files-", "")

suite "t_completion_files":

  test "the files are named as the release names repro's":
    check completionFileNames("tool") ==
      @["tool.bash", "_tool", "tool.fish", "tool.ps1"]
    check completionFileName(cshZsh, "my-prog") == "_my-prog"

  test "the entry word follows the list's complete entry":
    check completionEntryOfList(DescribeList) == "--entrypoint=complete"
    check completionEntryOfList(MainOnlyList) == DefaultCompletionEntry
    check completionEntryOfList(CompileTimeCompleteList) ==
      DefaultCompletionEntry
    check DefaultCompletionEntry == "__complete"

  test "a malformed list is refused, never read as __complete":
    for text in ["", "not json", "[]", """{"schema":"other/1","entries":[]}""",
                 """{"schema":"entrypoints/1"}""",
                 """{"schema":"entrypoints/1","entries":[3]}""",
                 """{"schema":"entrypoints/1","entries":[{"name":"complete"}]}"""]:
      checkpoint(text)
      expect ValueError:
        discard completionEntryOfList(text)

  test "each script is clispec's, byte for byte":
    for entry in ["--entrypoint=complete", "__complete"]:
      let scripts = completionScripts("tool", entry)
      check scripts.len == 4
      for i, shell in CompletionShells:
        check scripts[i].fileName == completionFileName(shell, "tool")
        check scripts[i].text == cliCompletionScript(shell, "tool",
          options = CliOptions(completionEntry: entry))
        check entry in scripts[i].text

  test "the producer writes the four files, with or without a list":
    let dir = scratchDir()
    defer: removeDir(dir)
    writeFile(dir / "described.json", DescribeList)
    check runProducer(["--program=tool", "--entry-list=" & dir /
      "described.json", "--out-dir=" & dir / "a"]) == 0
    for (name, text) in completionScripts("tool", "--entrypoint=complete"):
      check readFile(dir / "a" / name) == text
    # No list: the program does not use nim-entrypoints.
    check runProducer(["--program=tool", "--entry-list=" & dir /
      "absent.json", "--out-dir=" & dir / "b"]) == 0
    for (name, text) in completionScripts("tool", "__complete"):
      check readFile(dir / "b" / name) == text

  test "usage errors exit 2; a bad name or list exits 1 and writes nothing":
    let dir = scratchDir()
    defer: removeDir(dir)
    check runProducer([]) == 2
    check runProducer(["--program=tool"]) == 2
    check runProducer(["--program=tool", "--out-dir=" & dir, "--bogus=1"]) == 2
    check runProducer(["--program=tool", "--program=again",
      "--out-dir=" & dir]) == 2
    check runProducer(["--program", "--out-dir=" & dir]) == 2
    check runProducer(["--program=a/b", "--out-dir=" & dir / "c"]) == 1
    check not dirExists(dir / "c")
    writeFile(dir / "bad.json", "{")
    check runProducer(["--program=tool", "--entry-list=" & dir / "bad.json",
      "--out-dir=" & dir / "d"]) == 1
    check not dirExists(dir / "d")
    check not validCompletionProgram("")
    check not validCompletionProgram("..")
    check not validCompletionProgram("a\\b")
    check validCompletionProgram("csm14-describe")
