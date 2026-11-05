## Moving a `nim c` command's search-path REASSERTION out of its argv.
##
## Why this exists
## ---------------
## The SDK-internal compiles keep the SDK's own source roots ahead of
## everything a recipe's configuration adds (`protectSdkCompilePaths`). Nim
## reads its command line twice -- once before the configuration files and
## once after them -- and `--path:` does not move a root that is already on
## the search path, so the protection spells every SDK root twice:
## `--excludePath:<root>` and then `--path:<root>`. With the 116 roots of an
## installed SDK that is about 35,000 characters, and Windows refuses to start
## a process whose command line exceeds 32,767 UTF-16 units
## (`CreateProcessW` fails with error 206, `ERROR_FILENAME_EXCED_RANGE`; see
## https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw).
## The pinned Nim has no `@file` response-file argument and no option that
## names an arbitrary configuration file
## (https://nim-lang.org/docs/nimc.html#compiler-usage-configuration-files),
## so the only other channel into the compiler is a configuration file it
## finds by itself.
##
## The mechanism
## -------------
## Nim evaluates `<main module>.nims` -- the project's own NimScript file --
## LAST among all configuration files, immediately before the second pass
## over the command line (`loadConfigs` in `compiler/nimconf.nim` and
## `loadConfigsAndProcessCmdLine` in `compiler/cmdlinehelper.nim`; nothing
## that touches the search path runs in between). A script there therefore
## sees exactly the state the second command-line pass would see.
##
## `splitSearchPathReassertion` takes the complete, LOGICAL argv and returns
##
## * a launch argv: the logical argv without the reassertion pairs (each
##   `--excludePath:<root>` and the `--path:<root>` that re-adds it), and
## * a script that replays EVERY search-path operation of the logical argv,
##   in order -- the kept `--path:`s as well as the moved pairs.
##
## It moves a root only when the argv's operations on that root are exactly
## "exclude, then re-add", and only when every exclusion in the argv is part
## of such a pair. That is the shape `protectSdkCompilePaths` produces; any
## other shape moves nothing (see below).
##
## Why the final search path is the same as the logical argv's
## -------------------------------------------------------------
## Nim's search-path operations are `--path:X` (insert X at the front unless
## it is already present) and `--excludePath:X` (remove X).
##
## 1. First pass. The logical argv adds each kept root, then the
##    reassertion: removing a root no earlier argument added is a no-op, and
##    re-adding it puts it at the front. The launch argv adds the kept roots
##    only. The reasserted roots are missing, nothing else differs.
## 2. Configuration files insert at the front and remove by value. Neither
##    operation looks at where other entries are, so the relative order of
##    every other entry comes out the same with or without the reasserted
##    roots. A configuration file that adds or removes a reasserted root
##    leaves it in a different state in the two runs; (3) erases that.
## 3. The script runs the logical argv's search-path operations in order,
##    which is exactly what the logical argv's second pass would do. Each
##    reasserted root is removed and then re-added, so it ends up in front,
##    in reassertion order, whatever state it was in before.
## 4. The launch argv's second pass holds only `--path:` operations on kept
##    roots (every exclusion was moved), and the script has just made each
##    of those roots present, so every one of them is a no-op. Without the
##    replay in (3) a kept root a configuration file had removed would be
##    re-added HERE, in front of the reasserted roots; the replay is what
##    rules that out.
##
## Evaluating the script is itself a NimScript run, and every NimScript run
## APPENDS the standard library's root (`$lib`) to the search path
## (`runNimScript`, `compiler/scriptconfig.nim`). So the split compile's
## search path carries one more copy of `$lib`, at the very end, behind an
## earlier copy of the same directory. A lookup reaches it only after
## missing in that earlier copy, so it can never resolve a module
## differently; it costs one extra probe for an import that resolves nowhere.
## The real-compiler check of this argument
## (`tests/integration/t_compiler_scratch_isolation.nim`) compares the two
## search paths with that trailing duplicate allowed and nothing else.
##
## The one difference in what nim can resolve is (1): while the configuration
## files are evaluated,
## the reasserted roots are not on the search path yet. That matters only for
## an `import` in a configuration script that resolves through one of them.
## The callers use this only for compiles whose main module is a generated
## file in a directory reprobuild owns, so the configuration files evaluated
## are Nim's own, the user's and those of that directory's ancestors -- never
## the recipe's.
##
## What the caller owns
## --------------------
## The script must be written as `nimSearchPathScriptPath(mainModule)`, and
## the main module's directory must be one reprobuild owns: the script must
## not land beside a consumer's file. Name the main module after the script's
## content too (see `extractInterfaceFromModule`), so a reader of a cached
## file can never pair a runner with another configuration's script. The
## logical argv stays the compile's identity: nimcache keys, action keys and
## relocation anchors are computed from it, never from the launch argv.
##
## Nothing is moved, and the launch argv is the logical argv, when the argv's
## search-path operations have any other shape (an exclusion that is not
## followed by exactly one re-add of the same root, a root excluded twice, a
## re-added root that also appears elsewhere), when a value cannot be
## replayed without changing what Nim resolves it to (it uses `$`
## substitution, starts with a quote, holds a NUL), or when a moved root is
## not absolute. The steps above are argued for the one shape; the others keep
## the command line they had.

import std/[os, strutils, tables]

type
  NimSearchPathLaunch* = object
    argv*: seq[string]
      ## The command to spawn: the logical argv without the moved
      ## reassertion pairs.
    script*: string
      ## The NimScript that must sit at `nimSearchPathScriptPath(<main
      ## module>)` for `argv` to compile what the logical argv compiles; ""
      ## when nothing was moved (then `argv` is the logical argv and no
      ## script may be written).
    movedArguments*: int
      ## How many arguments the launch argv lacks.

  SearchPathOperation = object
    index: int
    exclude: bool
    value: string

const NimSearchPathScriptHeader* =
  "# Generated by reprobuild for one compile; not a configuration file to edit.\n" &
  "# It replays the compile's --path/--excludePath operations after Nim has\n" &
  "# read every other configuration file, so its command line need not repeat\n" &
  "# the SDK roots it reasserts (repro_interface_artifacts/nim_search_path_script).\n"

proc nimSearchPathScriptPath*(mainModule: string): string =
  ## Where Nim looks for the project's NimScript: the main module with its
  ## extension replaced by `.nims` (`loadConfigs`, `compiler/nimconf.nim`).
  mainModule.changeFileExt("nims")

proc searchPathOperation(arg: string; index: int;
                         operation: var SearchPathOperation): bool =
  ## Whether `arg` is one of Nim's search-path switches, in any spelling Nim
  ## accepts: one or two dashes, `:` or `=`, and the style-insensitive switch
  ## name (`compiler/commands.nim` compares names with `normalize`).
  if arg.len < 2 or arg[0] != '-':
    return false
  let body = if arg.startsWith("--"): arg[2 .. ^1] else: arg[1 .. ^1]
  var split = -1
  for i, ch in body:
    if ch in {':', '='}:
      split = i
      break
  if split <= 0:
    return false
  let name = body[0 ..< split].normalize
  if name notin ["path", "p", "excludepath"]:
    return false
  operation = SearchPathOperation(index: index, exclude: name == "excludepath",
    value: body[split + 1 .. ^1])
  true

proc resolvesAlikeInScript(value: string): bool =
  ## A value Nim resolves to the same directory from the command line and
  ## from the script. `$` substitution differs (`$config` names the script's
  ## directory there), and a NimScript `path` value that starts with a quote
  ## is unescaped first (`processCfgPath`). A relative value resolves against
  ## the main module's directory in both places, because the script sits in
  ## that directory.
  value.len > 0 and '$' notin value and value[0] != '"' and '\0' notin value

proc splitSearchPathReassertion*(command: openArray[string];
                                 moduleArg: string): NimSearchPathLaunch =
  ## Split `command` (the logical argv, whose main-module argument is
  ## `moduleArg`) into a launch argv and the script that completes it; see
  ## the module documentation for the equivalence argument. Only arguments
  ## before `moduleArg` are switches -- Nim hands what follows it to the
  ## program -- so nothing after it is examined or moved.
  result.argv = @command
  let moduleAt = block:
    var at = -1
    for i, arg in command:
      if arg == moduleArg:
        at = i
        break
    at
  if moduleAt < 0:
    return
  var operations: seq[SearchPathOperation]
  for i in 0 ..< moduleAt:
    var operation: SearchPathOperation
    if searchPathOperation(command[i], i, operation):
      operations.add(operation)
  # Group the operations by value, in command order. A value is moved when
  # its operations are exactly [exclude, re-add]; an exclusion of any other
  # shape means the argv is not the shape the equivalence is argued for, and
  # nothing is moved.
  var groupOf = initTable[string, int]()
  var byValue: seq[seq[SearchPathOperation]]
  for operation in operations:
    let at = groupOf.getOrDefault(operation.value, -1)
    if at < 0:
      groupOf[operation.value] = byValue.len
      byValue.add(@[operation])
    else:
      byValue[at].add(operation)
  var moved = newSeq[bool](command.len)
  var movedCount = 0
  for group in byValue:
    var excludes = 0
    for operation in group:
      if operation.exclude:
        inc excludes
    if excludes == 0:
      continue
    if group.len != 2 or not group[0].exclude or group[1].exclude:
      return
    if not isAbsolute(group[0].value):
      return
    moved[group[0].index] = true
    moved[group[1].index] = true
    inc movedCount, 2
  if movedCount == 0:
    return
  for operation in operations:
    if not resolvesAlikeInScript(operation.value):
      return
  var script = NimSearchPathScriptHeader
  for operation in operations:
    script.add("switch(")
    script.add(if operation.exclude: "\"excludePath\"" else: "\"path\"")
    script.add(", ")
    # `escape` spells every byte outside printable ASCII as `\xHH`, which a
    # Nim string literal turns back into that byte: spaces, quotes,
    # backslashes and UTF-8 survive unchanged.
    script.add(operation.value.escape)
    script.add(")\n")
  var argv: seq[string]
  for i, arg in command:
    if i >= moduleAt or not moved[i]:
      argv.add(arg)
  result = NimSearchPathLaunch(argv: argv, script: script,
    movedArguments: movedCount)

proc commandLineLength*(command: openArray[string]): int =
  ## The length of `command` as one Windows command line, quoted the way
  ## `runCommand` quotes it, in bytes of its UTF-8 spelling (the UTF-16
  ## length Windows limits is the same for an ASCII command and smaller
  ## otherwise). A measurement for diagnostics and tests; the split does not
  ## depend on it.
  for i, arg in command:
    if i > 0:
      inc result
    inc result, quoteShellWindows(arg).len
