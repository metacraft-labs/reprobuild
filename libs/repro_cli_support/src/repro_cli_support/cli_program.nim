## repro's command line as a program: confutils instantiated over the
## description in ``repro_cli_support/cli_description``.
##
## The description carries reprobuild's own parameter extension
## (``ReproCommandLineParamExt``), so the code is generated the way confutils
## documents for a description with an extension: clispec's
## ``cliProgramCode`` (the configuration object ``ReproCommandLine``, its
## argv parser, help and completion, and the model's type checks,
## ``cliModelTypeChecks``) followed by confutils' ``cliConfigurationCode``
## (loading over configuration layers and the environment, and the origin
## object). It generates, exported:
##
## * everything ``cliConfiguration`` generates for ``ReproCommandLine``:
##   ``ReproCommandLine.load(argv, sources, options)``, ``helpText``,
##   ``helpJson``, ``complete``, ``completionScript``, ``cliGrammar``, ...;
## * ``reproPassThrough(conf)``: for a command still parsed by its own code
##   (its ``passThrough`` positional), the command's path and the arguments
##   after it, unparsed;
## * ``ReproPassThroughCommands``: the grammar indexes of those commands.
##
## ``reproArgvForParser`` is what makes an unmigrated command's arguments
## reach it unparsed: it puts ``--`` right after the words that select such a
## command, so the parser files everything after them under the command's
## ``passThrough`` positional.

import std/[macros, strutils]

import confutils/clispec_config

import ./cli_description

# What a caller of the generated program needs, and nothing more: the
# library's whole vocabulary would otherwise land in every importer's scope.
export CliSources, CliOptions, CliHelpRequest, CliCompletionRequest,
  CliUsageError, CliConfigError, CliErrorKind, CliShell, CliGrammar,
  cliProcessEnv, cliParseShell, cliChildNamed
export ReproCommandLineType, ReproProgramName

proc passThroughCode(model: CliModel[NoCliExtension,
                     ReproCommandLineParamExt]): NimNode =
  ## ``ReproPassThroughCommands`` and ``reproPassThrough`` for ``model``,
  ## using the names ``cliProgramCode`` gives the configuration objects.
  var problems: seq[CliGrammarProblem] = @[]
  var decls: seq[CliParam[ReproCommandLineParamExt]] = @[]
  let g = cliGrammarOf(model, ReproProgramName, problems, decls)
  let names = cliGeneratedNames(g, ReproCommandLineType)
  var passThrough: seq[int] = @[]
  for k, cmd in g.commands:
    if cmd.isCall:
      continue
    for id in cmd.ownParams:
      if decls[id].ext.passThrough:
        if decls[id].name != PassThroughParamName or
            g.params[id].kind != cpkPositional:
          error("repro command line: the passThrough positional of '" &
            cmd.path.join(" ") & "' must be `pos " & PassThroughParamName &
            " is seq[string]`")
        if cmd.children.len > 0:
          error("repro command line: '" & cmd.path.join(" ") &
            "' has subcommands and a passThrough positional")
        passThrough.add(k)
  var indexes = nnkBracket.newTree()
  for k in passThrough:
    indexes.add(newLit(k))
  result = newStmtList()
  result.add(nnkConstSection.newTree(nnkConstDef.newTree(
    postfix(ident("ReproPassThroughCommands"), "*"), newEmptyNode(),
    indexes)))
  # One `if` per pass-through command, testing each discriminator on the
  # way down and reading the command's `args` field at the end.
  let conf = ident("conf")
  var body = newStmtList()
  for k in passThrough:
    var chain: seq[int] = @[]
    var at = k
    while at > 0:
      chain.insert(at, 0)
      at = g.commands[at].parent
    var cond: NimNode = nil
    var access = conf
    var parent = 0
    for child in chain:
      let enumName = ident(cliCommandEnumName(names, parent))
      let test = infix(newDotExpr(access, ident("command")), "==",
        newDotExpr(enumName, nnkAccQuoted.newTree(
          ident(names.fieldOfChild[child]))))
      cond = if cond.isNil: test else: infix(cond, "and", test)
      access = newDotExpr(access, nnkAccQuoted.newTree(
        ident(names.fieldOfChild[child])))
      parent = child
    var path = nnkBracket.newTree()
    for word in g.commands[k].path:
      path.add(newLit(word))
    let args = newDotExpr(access, ident(PassThroughParamName))
    body.add(newIfStmt((cond, newStmtList(nnkReturnStmt.newTree(
      nnkTupleConstr.newTree(newLit(true), prefix(path, "@"), args))))))
  let resultType = quote do:
    tuple[found: bool, path: seq[string], args: seq[string]]
  result.add(newProc(postfix(ident("reproPassThrough"), "*"),
    params = [resultType, newIdentDefs(conf, ident(ReproCommandLineType))],
    body = body))

proc reproProgramCode*(model: CliModel[NoCliExtension,
                       ReproCommandLineParamExt]): NimNode =
  ## The program generated from a model of repro's command line (see the
  ## module documentation). Its first statements are clispec's
  ## ``cliModelTypeChecks`` of the model, so a ``default``,
  ## ``optionalValue``, ``values`` entry or ``implies`` value that is not a
  ## value of its parameter's type is a compile error naming the parameter.
  result = cliProgramCode(model, ReproCommandLineType, ReproProgramName,
    exported = true)
  result.add(cliConfigurationCode(model, ReproCommandLineType,
    ReproProgramName, exported = true))
  result.add(passThroughCode(model))

macro reproCommandLineProgram() =
  reproProgramCode(reproCommandLineModel())

reproCommandLineProgram()

proc reproArgvForParser*(argv: openArray[string]): seq[string] =
  ## ``argv`` with ``--`` inserted right after the words that select a
  ## command still parsed by its own code (``ReproPassThroughCommands``), so
  ## everything after those words reaches that code unparsed. Any other
  ## command line is returned unchanged for the parser to accept or reject.
  ##
  ## The words before the command's are subcommand words and the root's
  ## switches, which all start with ``-`` and take no value, so a word that
  ## does not start with ``-`` is always the next subcommand word.
  let g = ReproCommandLine.cliGrammar()
  result = @argv
  var command = 0
  for i, word in argv:
    if word == "--":
      return
    if word.startsWith("-"):
      continue
    let child = cliChildNamed(g, command, word)
    if child < 0:
      return
    if child in ReproPassThroughCommands:
      result.insert("--", i + 1)
      return
    command = child

proc reproCommandAt*(path: openArray[string]): int =
  ## The grammar index of the command the subcommand words ``path`` reach
  ## (aliases included), or -1.
  let g = ReproCommandLine.cliGrammar()
  result = 0
  for word in path:
    result = cliChildNamed(g, result, word)
    if result < 0:
      return -1

proc reproCommandPath*(command: int): seq[string] =
  ## The canonical subcommand words of the command at grammar index
  ## ``command``.
  ReproCommandLine.cliGrammar().commands[command].path

proc reproCommandIsPassThrough*(command: int): bool =
  ## Whether the command is still parsed by its own code.
  command in ReproPassThroughCommands

proc reproCommandIsShown*(command: int): bool =
  ## Whether the command and every command holding it are ``shown`` (not
  ## ``internal`` or ``hidden``).
  let g = ReproCommandLine.cliGrammar()
  var at = command
  while at > 0:
    if g.commands[at].visibility != cvShown:
      return false
    at = g.commands[at].parent
  true
