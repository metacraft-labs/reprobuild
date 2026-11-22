## The shell completion files of a program described in its ``repro.nim``.
##
## An ``executable`` with a ``cli:`` section describes a program's command
## line. When a package builds such an executable with ``nim c``, the
## provider gives it a completion edge (``runtime_provider``): the compile
## also writes nim-entrypoints' entry list (``-d:entrypointsManifest``), and
## the completion edge runs ``repro-completion-files``, which writes the
## program's Bash, Zsh, Fish and PowerShell completion scripts from two facts:
##
## * **the program's name**, the one the ``<name>CliDescription`` template
##   passes to the program's CLI generator (the executable's ``name:``, else
##   the executable's name);
## * **the completion entry word**, the first argument through which a script
##   asks the program for candidates: ``--entrypoint=complete`` when the entry
##   list names a ``complete`` entry that can be selected at run time (the
##   program calls nim-entrypoints' ``describeProgram``), and clispec's
##   ``__complete`` otherwise, including when the compile wrote no list (the
##   program does not use nim-entrypoints).
##
## Clispec's scripts hold no grammar: each is a function of the shell, the
## program's name and the entry word (``clispec/completion_scripts``). So the
## files are written on the build host without running the program, which is
## what makes them right for a binary the build host cannot run, and they are
## byte-identical to what a ``describeProgram`` binary prints for
## ``--entrypoint=completion <shell>``.
##
## The files are named as reprobuild's own release names its scripts:
##
## ============= ====================
## shell         file
## ============= ====================
## bash          ``<program>.bash``
## zsh           ``_<program>``
## fish          ``<program>.fish``
## powershell    ``<program>.ps1``
## ============= ====================
##
## The entry list's format is nim-entrypoints' ``entrypoints/1`` document
## (https://github.com/metacraft-labs/nim-entrypoints, ``--entrypoint=list``).
##
## Imports the standard library and clispec only, so the producer program
## compiles nothing else.

import std/[json, os, strutils]

import clispec/[completion, completion_scripts, parser]

const
  CompletionFilesProducerName* = "repro-completion-files"
    ## The program the completion edge runs, installed beside the engine.
  DescribeCompletionEntry* = "--entrypoint=complete"
    ## The entry word of a program that registers nim-entrypoints'
    ## ``complete`` entry (``entrypoints/describe``'s ``selectorEntry``).
  EntryListSchema* = "entrypoints/1"
    ## The schema name of nim-entrypoints' entry list.
  CompletionShells* = [cshBash, cshZsh, cshFish, cshPowerShell]
    ## The shells a completion edge writes files for, in this order.

proc validCompletionProgram*(program: string): bool =
  ## Whether ``program`` can name completion files: not empty, not ``.`` or
  ## ``..``, and without a path separator or a NUL.
  program.len > 0 and program notin [".", ".."] and
    not program.contains({'/', '\\', '\0'})

proc completionFileName*(shell: CliShell; program: string): string =
  ## The file name of ``shell``'s completion script for ``program``.
  case shell
  of cshBash: program & ".bash"
  of cshZsh: "_" & program
  of cshFish: program & ".fish"
  of cshPowerShell: program & ".ps1"

proc completionFileNames*(program: string): seq[string] =
  ## The file names of every shell's script for ``program``, in
  ## ``CompletionShells`` order.
  for shell in CompletionShells:
    result.add(completionFileName(shell, program))

proc completionEntryOfList*(listText: string): string =
  ## The completion entry word of the program whose ``entrypoints/1`` entry
  ## list is ``listText``: ``DescribeCompletionEntry`` when the list names an
  ## entry ``complete`` whose ``select`` includes ``runtime``, clispec's
  ## ``DefaultCompletionEntry`` otherwise. Raises ``ValueError`` for a text
  ## that is not such a list, so a malformed list fails the edge instead of
  ## silently giving ``__complete``.
  var doc: JsonNode
  try:
    doc = parseJson(listText)
  except JsonParsingError as err:
    raise newException(ValueError, "the entry list is not JSON: " & err.msg)
  if doc.kind != JObject or doc{"schema"}.getStr() != EntryListSchema:
    raise newException(ValueError, "the entry list is not an " &
      EntryListSchema & " document")
  let entries = doc{"entries"}
  if entries.isNil or entries.kind != JArray:
    raise newException(ValueError, "the entry list has no `entries` array")
  for entry in entries:
    if entry.kind != JObject:
      raise newException(ValueError, "the entry list has an entry that is " &
        "not an object")
    if entry{"name"}.getStr() != "complete":
      continue
    let select = entry{"select"}
    if select.isNil or select.kind != JArray:
      raise newException(ValueError, "the entry list's `complete` entry " &
        "has no `select` array")
    for kind in select:
      if kind.getStr() == "runtime":
        return DescribeCompletionEntry
  DefaultCompletionEntry

proc completionScripts*(program, entry: string):
    seq[tuple[fileName, text: string]] =
  ## Every shell's completion script for ``program`` whose scripts ask for
  ## candidates through ``entry``, with its file name, in
  ## ``CompletionShells`` order. The text is clispec's, byte for byte.
  for shell in CompletionShells:
    result.add((completionFileName(shell, program),
      cliCompletionScript(shell, program,
        options = CliOptions(completionEntry: entry))))

proc producerArgv*(producer, program, entryList, outDir: string):
    seq[string] =
  ## The completion edge's command line: ``producer`` writes ``program``'s
  ## files into ``outDir``, reading the entry list at ``entryList`` when it
  ## exists.
  @[producer, "--program=" & program, "--entry-list=" & entryList,
    "--out-dir=" & outDir]

const ProducerUsage* = CompletionFilesProducerName &
  " --program=<name> --entry-list=<entrypoints/1 file> --out-dir=<dir>"

proc writeCompletionFiles*(program, entryList, outDir: string): string =
  ## Writes ``program``'s completion files into ``outDir`` (created when
  ## missing), taking the entry word from the entry list at ``entryList``
  ## when that file exists and clispec's default when it does not. Returns
  ## the entry word. Raises ``ValueError`` for an invalid program name or a
  ## malformed entry list, ``IOError``/``OSError`` when a file cannot be
  ## read or written.
  if not validCompletionProgram(program):
    raise newException(ValueError, "cannot name completion files after `" &
      program & "`: a program name is not empty and has no path separator")
  # Read only when present: a program that does not use nim-entrypoints
  # makes its compile write no list. The existence check is itself what
  # the edge's monitor records, so the list appearing later reruns the edge.
  result =
    if entryList.len > 0 and fileExists(entryList):
      completionEntryOfList(readFile(entryList))
    else:
      DefaultCompletionEntry
  createDir(outDir)
  for (fileName, text) in completionScripts(program, result):
    writeFile(outDir / fileName, text)

proc runProducer*(args: openArray[string]): int =
  ## The program ``repro-completion-files``: parses ``args`` (``--program=``,
  ## ``--entry-list=``, ``--out-dir=``, each once) and writes the files.
  ## Returns the exit code: 0 on success, 2 for a usage error, 1 when the
  ## files cannot be written.
  var program, entryList, outDir: string
  var seen: seq[string]
  for arg in args:
    let eq = arg.find('=')
    let key = if eq > 0: arg[0 ..< eq] else: arg
    if key notin ["--program", "--entry-list", "--out-dir"] or eq < 0:
      stderr.writeLine(CompletionFilesProducerName & ": unknown argument `" &
        arg & "`; usage: " & ProducerUsage)
      return 2
    if key in seen:
      stderr.writeLine(CompletionFilesProducerName & ": " & key &
        " given twice; usage: " & ProducerUsage)
      return 2
    seen.add(key)
    let value = arg[eq + 1 .. ^1]
    case key
    of "--program": program = value
    of "--entry-list": entryList = value
    else: outDir = value
  if program.len == 0 or outDir.len == 0:
    stderr.writeLine(CompletionFilesProducerName &
      ": --program and --out-dir are required; usage: " & ProducerUsage)
    return 2
  try:
    let entry = writeCompletionFiles(program, entryList, outDir)
    stdout.writeLine(CompletionFilesProducerName & ": wrote " &
      $CompletionShells.len & " completion files for " & program &
      " (entry word " & entry & ")")
    0
  except CatchableError as err:
    stderr.writeLine(CompletionFilesProducerName & ": " & err.msg)
    1
