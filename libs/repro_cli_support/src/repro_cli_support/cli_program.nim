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
## * ``ReproPassThroughCommands``: the grammar indexes of those commands;
## * ``reproDeclaredEnv()``, ``reproDeclaredEnvFor(argv)``: the environment
##   the parser is loaded with -- only the variables a parameter (of the
##   command being parsed) declares, each looked up by name.
##
## ``reproArgvForParser`` is what makes an unmigrated command's arguments
## reach it unparsed: it puts ``--`` right after the words that select such a
## command, so the parser files everything after them under the command's
## ``passThrough`` positional.
##
## ``repro exec``'s command and ``repro run``'s arguments are clispec
## ``afterSeparator`` positionals: the parser itself fills them with the
## words after the first ``--``, exactly as written.

import std/[macros, options, os, sequtils, strutils, tables]

import confutils/clispec_config

import ./cli_description

# What a caller of the generated program needs, and nothing more: the
# library's whole vocabulary would otherwise land in every importer's scope.
export CliSources, CliOptions, CliHelpRequest, CliCompletionRequest,
  CliUsageError, CliConfigError, CliErrorKind, CliShell, CliGrammar,
  cliParseShell, cliChildNamed, CliOrigin, CliOriginKind, CliSite
export ReproCommandLineType, ReproProgramName
# The configuration objects hold `Option[int]` fields (`store export
# --zstd-level`, `bundle create --level`, ...).
export options

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

proc renderReproUsageError*(e: ref CliUsageError): string =
  ## The text of ``e`` as clispec's error block (``cliErrorText``), plain:
  ## the ``error:`` line (clispec's error taxonomy, naming the command; for
  ## a spelling the description declares `retired`, also what replaced it),
  ## the ``tip:`` with the error's suggestions, the usage line of the
  ## command the error is about and the command that prints its help.
  ##
  ## The daemon worker sends this text for a `repro build` command line the
  ## thin client routed unparsed. The thin client routes a build only when
  ## its stderr is not a terminal, where ``reportReproUsageError`` writes
  ## the same block unstyled, so both paths print the same bytes.
  cliErrorText(e)

proc reportReproUsageError*(e: ref CliUsageError): int =
  ## A command line the generated parser rejected: clispec's error block on
  ## stderr, styled for it as help is (``ReproCommandLine.printError``:
  ## colour on a terminal, none through a pipe, under `NO_COLOR` or
  ## `TERM=dumb`); the usage exit code (2).
  ReproCommandLine.printError(e)
  e.exitCode

proc declaredEnvOf*(g: CliGrammar; params: openArray[int]):
    Table[string, string] =
  ## ``declaredEnvOf`` for the parameters ``params`` (grammar indexes) only.
  for id in params:
    let p = g.params[id]
    if csEnv notin p.sources:
      continue
    for name in p.env:
      if not result.hasKey(name) and getEnv(name).len > 0:
        result[name] = getEnv(name)

proc declaredEnvOf*(g: CliGrammar): Table[string, string] =
  ## The variables of the process environment that some parameter of ``g``
  ## may take its value from (``env``, with ``csEnv`` among its sources),
  ## each looked up by name, keyed by its declared spelling.
  ##
  ## For the parse this is the same input as the whole environment:
  ## confutils' ``cliEnvCandidates`` consults ``CliSources.env`` only
  ## through ``hasKey`` on those same declared names, so a table holding
  ## exactly the declared variables that are set yields the same
  ## candidates. Two deliberate differences. A variable set to the empty
  ## string is left out, so it counts as unset: that is how reprobuild has
  ## always read these variables (``getEnv(name).len == 0``), and a script's
  ## ``REPRO_DAEMON= repro build`` must not become an invalid value. And,
  ## Windows only, the lookup is case-insensitive there, as the environment
  ## is, where a key of ``cliProcessEnv()`` matched a declared name only in
  ## the same case.
  declaredEnvOf(g, toSeq(0 ..< g.params.len))

proc reproDeclaredEnv*(): Table[string, string] =
  ## The environment ``ReproCommandLine.load`` takes its ``env``-sourced
  ## parameters from: each variable some parameter declares, looked up BY
  ## NAME, and nothing else.
  ##
  ## WHY NOT confutils' ``cliProcessEnv()``. That enumerates the whole
  ## environment (``envPairs``, which on Windows is ``GetEnvironmentStringsW``
  ## called from the program's own image). io-mon's Windows shim records such
  ## a block read as a read of EVERY variable in the block, because it cannot
  ## see which of them the program goes on to use
  ## (io-mon ``snoopEnvBlock``). Every monitored edge whose tree runs this
  ## image -- the profile compile and platform probe helpers, the provider
  ## compile, interface extraction -- parses its argv here first, so each was
  ## keyed on the value of every variable of its caller's environment. A
  ## ``repro home export`` after a ``repro home plan`` that differed only in
  ## ``$REPRO_HOST`` recompiled the profile ("input metadata changed:
  ## REPRO_HOST"). On Linux and macOS ``environ`` is read without an
  ## observable call, so only Windows was affected. A by-name lookup is
  ## recorded as a read of that one variable, which is exactly the
  ## dependency the parser has.
  ##
  ## The parse itself takes ``reproDeclaredEnvFor``, which narrows this to
  ## the command being parsed. Only `repro build`, `repro bench` and `repro
  ## lint` declare variables (`$REPRO_DAEMON` and the like), so any other
  ## command line reads none.
  declaredEnvOf(ReproCommandLine.cliGrammar())

proc reproDeclaredEnvFor*(argv: openArray[string]): Table[string, string] =
  ## ``reproDeclaredEnv`` narrowed to the command ``argv`` selects: the
  ## variables its parameters and its enclosing commands' declare, and those
  ## of every command below the last subcommand word found (a word the walk
  ## cannot place, such as a flag's value, ends it early, so the parse may
  ## still reach one of them).
  ##
  ## WHY NARROW IT. A variable the parse looks up is an input of every
  ## monitored edge whose tree runs this image (see ``reproDeclaredEnv``).
  ## The helper edges (``__repro-compile-profile`` and the like) must not be
  ## keyed on, say, ``$REPROBUILD_PROGRESS``, which only `repro build`'s
  ## command line reads.
  ##
  ## The words before the command's are subcommand words and the root's
  ## switches, as in ``reproArgvForParser``.
  let g = ReproCommandLine.cliGrammar()
  var chain = @[0]
  var command = 0
  for word in argv:
    if word == "--":
      break
    if word.startsWith("-"):
      continue
    let child = cliChildNamed(g, command, word)
    if child < 0:
      break
    chain.add(child)
    command = child
  var params: seq[int] = @[]
  for k in chain:
    params.add(g.commands[k].ownParams)
  var below = g.commands[command].children
  while below.len > 0:
    let k = below.pop()
    params.add(g.commands[k].ownParams)
    below.add(g.commands[k].children)
  declaredEnvOf(g, params)

proc reproWordsAfterCommand*(argv: openArray[string]): seq[string] =
  ## The words of ``argv`` after the subcommand words that select its
  ## command: what a command handed its arguments unparsed (the daemon's
  ## ``rawArgs`` of `repro build`) receives. The words before the command's
  ## are subcommand words and the root's switches, as in
  ## ``reproArgvForParser``.
  let g = ReproCommandLine.cliGrammar()
  var command = 0
  var after = 0
  for i, word in argv:
    if word == "--":
      break
    if word.startsWith("-"):
      continue
    let child = cliChildNamed(g, command, word)
    if child < 0:
      break
    command = child
    after = i + 1
  @argv[after .. ^1]

proc printReproHelp*(path: openArray[string] = []; stream = stdout;
                     long = false; all = false) =
  ## Prints the help page ``ReproCommandLine.helpText(path, long, all)``
  ## renders, through clispec's printer (``ReproCommandLine.printHelp``),
  ## which styles it for ``stream`` (colour on a terminal, none through a
  ## pipe, under `NO_COLOR` or `TERM=dumb`) and lays it out for its width,
  ## as every help page repro prints. For the commands that print a help
  ## page themselves (`repro help <command>`, `repro <namespace> help`).
  ##
  ## Raises ``CliUsageError`` when ``path`` names no command, as
  ## ``helpText`` does. The printer needs the parser's help request, so the
  ## page is asked of the parser: the words ``path`` and ``-h``
  ## (``--help`` for the long page, ``--help-all`` with ``all``).
  let text = ReproCommandLine.helpText(path, long = long or all, all = all)
  let flag = if all: "--help-all" elif long: "--help" else: "-h"
  try:
    discard ReproCommandLine.load(@path & @[flag], CliSources())
  except CliHelpRequest as e:
    ReproCommandLine.printHelp(e, stream)
    return
  except CatchableError:
    discard
  # The parser did not answer with a help page (a command that takes the
  # word itself): the page as text.
  stream.write(text)

proc reproBuildFlagNames*(): seq[string] =
  ## The names of `repro build`'s flags, from the grammar: what a command
  ## that splices `build`'s declaration into its own (`repro test`, `repro
  ## certify`) hands its build, as ``argvOf(origin, only =
  ## reproBuildFlagNames(), commandWords = false)``.
  let g = ReproCommandLine.cliGrammar()
  for id in g.commands[reproCommandAt(["build"])].params:
    if g.params[id].kind == cpkFlag:
      result.add(g.params[id].name)

proc loadReproCommandLine*(argv: openArray[string];
                           conf: var ReproCommandLine): int =
  ## Parses ``argv`` (repro's arguments, without the program name) with the
  ## generated parser, the declared variables of the process environment
  ## (``reproDeclaredEnvFor``: those of the command ``argv`` selects) as the
  ## source for the parameters that declare them, into ``conf``.
  ##
  ## -1 when ``conf`` holds a command to run. Otherwise the command line was
  ## answered here and the result is its exit code: a help or completion
  ## request printed on stdout (0), or a usage or configuration error
  ## reported on stderr (2).
  try:
    conf = ReproCommandLine.load(reproArgvForParser(argv),
      CliSources(env: reproDeclaredEnvFor(argv)))
  except CliHelpRequest as e:
    # Printed by clispec's printer, which styles a help page for stdout
    # (colour on a terminal, none through a pipe, under `NO_COLOR` or
    # `TERM=dumb`) and lays it out for stdout's width. A request that
    # carries no page renderer is printed as its text, unchanged: the
    # version, `--help=json` and `CliCompletionRequest`'s completion reply.
    ReproCommandLine.printHelp(e)
    return 0
  except CliUsageError as e:
    return reportReproUsageError(e)
  except CliConfigError as e:
    stderr.writeLine("repro: " & e.msg)
    return 2
  -1

proc runReproArgs*(argv: openArray[string];
                   run: proc (conf: ReproCommandLine): int): int =
  ## ``argv`` parsed by the generated parser (``loadReproCommandLine``) and,
  ## when it selects a command, handed to ``run`` as its typed
  ## configuration. For the commands' in-process callers and tests, which
  ## then go through the same parser as ``repro``.
  var conf: ReproCommandLine
  result = loadReproCommandLine(argv, conf)
  if result < 0:
    result = run(conf)
