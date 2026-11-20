## A command's row in the generated user documentation carries its one-line
## ``help``, and nothing else the command's declaration says.
##
## WHAT IS UNDER TEST. ``scripts/render_user_docs_generated.py`` reads
## ``cli_description.nim`` as text and writes the command tables of
## ``docs/users/content/reference/commands/index.md`` (and ``llms.txt``). A
## declaration may pass several string arguments:
##
##     subcmd "attest",
##         help = "Compute and check launch measurements of attested images",
##         longHelp = "Exit codes:\n" & "0  success, ...":
##
## The row's "What it does" cell is the value of ``help`` alone: the string
## literals joined by ``&`` that follow ``help =``, ending at the comma before
## the next named argument. A reader that takes every quoted string up to the
## end of the declaration appends ``longHelp`` to it, with its ``\n`` escapes
## written out literally, and the page it generates cannot be committed.
##
## Three things are held:
##
##   * the generator's own argument reader, on declarations shaped to provoke
##     the failure: ``longHelp`` and other string arguments after ``help``, a
##     ``longHelp`` BEFORE ``help``, an escaped quote and a comma inside the
##     value, and a declaration with no ``help`` at all. A value it cannot
##     read to its end (a constant in the concatenation, a triple-quoted
##     string, an operator or call after the last literal) is refused, not
##     shortened;
##   * the commands the generator parses out of the real description: each
##     top-level command that passes ``help`` and then ``longHelp`` on the two
##     lines after its ``subcmd`` (``repro attest`` must be among them, so the
##     survey cannot pass by matching nothing) has exactly its ``help`` literal
##     as its summary, and no command, subcommand or flag summary contains the
##     opening literal of any ``longHelp`` in the description;
##   * the committed page: ``--check`` runs to a verdict and finds every
##     generated region current, and each ``repro attest`` row ends with the
##     command's one-line help.
##
## NO MOCKS. The real ``python3`` on ``PATH`` loads the real generator script
## and reads the real ``cli_description.nim``; nothing is stubbed. Unlike
## ``t_dsl_reference_snippets_compile_and_docs_build``, which also runs
## ``--check``, this test needs no documentation-framework checkouts, so it
## runs wherever ``python3`` does.
##
## Recorded as reprobuild-pm
## ``issues/2026-11-19-the-user-docs-generator-reads-a-commands-long-help-into-its-one-line-summary.md``
## and
## ``issues/2026-11-20-the-user-docs-generator-finds-no-root-command-block-after-the-cliunbound-rename.md``.

import std/[json, os, osproc, strutils, unittest]

# Running `python3` from PATH is the point of this test (it is how the site
# build and a contributor run the generator), so the ambient-execution
# wrapper says so.
from repro_core/ambient_execution import uncontrolledExecCmdEx

const
  RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
  Generator = RepoRoot / "scripts" / "render_user_docs_generated.py"
  CliDescription = RepoRoot / "libs" / "repro_cli_support" / "src" /
    "repro_cli_support" / "cli_description.nim"
  CommandsPage = RepoRoot / "docs" / "users" / "content" / "reference" /
    "commands" / "index.md"
  AttestHelp = "Compute and check launch measurements of attested images"

  ## Loads the generator as a module (its ``main`` runs only as a script) and
  ## prints one JSON document: what its argument reader makes of the
  ## declarations given on stdin, and the commands it parses out of the real
  ## description.
  Probe = """
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("generator", sys.argv[1])
generator = importlib.util.module_from_spec(spec)
sys.modules["generator"] = generator
spec.loader.exec_module(generator)
declarations = json.load(sys.stdin)
def refuses(declaration):
    try:
        generator._string_argument(declaration, "help")
    except RuntimeError:
        return True
    return False
print(json.dumps({
    "arguments": [generator._string_argument(d, "help") for d in declarations["read"]],
    "refused": [refuses(d) for d in declarations["refuse"]],
    "commands": [
        {
            "name": c.name,
            "help": c.help,
            "subcommands": [{"name": s.name, "help": s.help} for s in c.subcommands],
            "flags": [{"name": f.name, "help": f.help} for f in c.flags],
        }
        for c in generator.parse_cli_commands()
    ],
}))
"""

  ## Declarations as the generator sees them (a header joined onto one line),
  ## each with the ``help`` it must read. ``nil`` is "passes no help".
  Declarations = [
    ("""subcmd "attest", help = "Compute and check", longHelp = "Exit codes:\n" & "0  success":""",
      "Compute and check"),
    ("""subcmd "a", help = "One " & "line " & "only", longHelp = "Long " & "text", visibility = hidden:""",
      "One line only"),
    ("""subcmd "b", longHelp = "Long text", help = "After the long help":""",
      "After the long help"),
    ("""subcmd "c", help = "Say \"hi\", then stop", aliases = ["d"]:""",
      """Say \"hi\", then stop"""),
    ("""flag jobs is int, help = "How many jobs", env = "REPRO_JOBS"""",
      "How many jobs"),
  ]
  NoHelp = """subcmd "e", longHelp = "Only a long help":"""
  ## Values the reader cannot follow to their end. Returning the literals it
  ## did read would publish a truncated help, so it must refuse.
  Refused = [
    """subcmd "f", help = "Starts " & SomeConstant & " ends":""",
    "subcmd \"g\", help = \"\"\"Triple quoted\"\"\":",
    """subcmd "h", help = SomeConstant:""",
    """subcmd "i", help = "Run %s" % name, longHelp = "Long":""",
    """subcmd "j", help = "Indented".dedent:""",
  ]

proc runProbe(): JsonNode =
  var read = newJArray()
  for (declaration, _) in Declarations:
    read.add(%declaration)
  read.add(%NoHelp)
  let declarations = %*{"read": read, "refuse": Refused}
  let (output, exitCode) = uncontrolledExecCmdEx(
    "python3 -c " & quoteShell(Probe) & " " & quoteShell(Generator),
    options = {}, input = $declarations, workingDir = RepoRoot)
  checkpoint output
  doAssert exitCode == 0, "the generator could not be loaded or could not " &
    "parse " & CliDescription & ":\n" & output
  parseJson(output)

proc declaredWithLongHelp(): seq[tuple[name, help: string]] =
  ## The top-level commands of the description that pass a ``longHelp``, with
  ## the single-literal ``help`` each passes on the line before it. Read here
  ## with nothing shared with the generator, so the two cannot agree by
  ## sharing a mistake.
  let lines = readFile(CliDescription).splitLines
  for i in 0 ..< lines.len - 2:
    if not lines[i].startsWith("    subcmd \""):
      continue
    const HelpOpener = "        help = \""
    if lines[i + 1].startsWith(HelpOpener) and
        lines[i + 1].endsWith("\",") and
        lines[i + 2].strip.startsWith("longHelp ="):
      result.add((name: lines[i].split('"')[1],
        help: lines[i + 1][HelpOpener.len ..^ 3]))

proc longHelpOpenings(): seq[string] =
  ## The first string literal of every ``longHelp =`` in the description, as
  ## written (escapes not decoded, which is also how the generator reads).
  const Opener = "longHelp = \""
  for line in readFile(CliDescription).splitLines:
    let at = line.find(Opener)
    if at < 0:
      continue
    let rest = line[at + Opener.len .. ^1]
    let close = rest.find('"')
    if close > 0:
      result.add(rest[0 ..< close])

suite "user docs: a command's row carries its one-line help":
  let probed = runProbe()

  test "the argument reader stops at the end of the help argument":
    let arguments = probed["arguments"]
    require arguments.len == Declarations.len + 1
    for i, (declaration, expected) in Declarations:
      checkpoint declaration
      check arguments[i].kind == JString
      if arguments[i].kind == JString:
        check arguments[i].getStr == expected
    check arguments[Declarations.len].kind == JNull

  test "the argument reader refuses a value it cannot read to its end":
    let refused = probed["refused"]
    require refused.len == Refused.len
    for i, declaration in Refused:
      checkpoint declaration
      check refused[i].getBool

  test "a command that declares a long help is summarized by its help alone":
    let declared = declaredWithLongHelp()
    # Not vacuous: `repro attest` is such a command today. If none is left,
    # this test protects nothing and should be given another subject.
    require declared.len > 0
    var attestSeen = false
    for (name, help) in declared:
      var parsed = ""
      for command in probed["commands"]:
        if command["name"].getStr == name:
          parsed = command["help"].getStr
      checkpoint "repro " & name
      check parsed == help
      if name == "attest":
        attestSeen = true
        check help == AttestHelp
    check attestSeen

  test "no summary contains the opening of a long help":
    let openings = longHelpOpenings()
    # Not vacuous: nested subcommands declare long helps too, in a shape
    # `declaredWithLongHelp` does not read.
    require openings.len > 1
    require probed["commands"].len > 0
    var summaries: seq[tuple[what, help: string]] = @[]
    for command in probed["commands"]:
      let name = "repro " & command["name"].getStr
      summaries.add((what: name, help: command["help"].getStr))
      for sub in command["subcommands"]:
        summaries.add((what: name & " " & sub["name"].getStr,
          help: sub["help"].getStr))
      for flag in command["flags"]:
        summaries.add((what: name & " " & flag["name"].getStr,
          help: flag["help"].getStr))
    for (what, help) in summaries:
      for opening in openings:
        if opening in help:
          checkpoint what & ": " & help
          check opening notin help

  test "the committed generated regions are current and say the same":
    let (output, exitCode) = uncontrolledExecCmdEx(
      "python3 " & quoteShell(Generator) & " --check",
      options = {poStdErrToStdOut}, workingDir = RepoRoot)
    checkpoint output
    check exitCode == 0
    var rows = 0
    for line in readFile(CommandsPage).splitLines:
      if line.startsWith("| `repro attest` |"):
        inc rows
        checkpoint line
        check line.endsWith("| " & AttestHelp & ". |")
    # One row in the table by domain, one in the table by name.
    check rows == 2
