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
## * ``reproDeclaredEnv()``, ``reproDeclaredEnvFor(argv)``: the environment
##   the parser is loaded with -- only the variables a parameter (of the
##   command being parsed) declares, each looked up by name;
## * ``reproArgvOf(path, values)``: the argv words of a command line repro
##   spawns of itself, written by clispec's renderer (``cliArgvOf``) from the
##   values the spawner gives each parameter, so the child's parse is the
##   round trip of the parent's values.
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

macro reproCommandLineProgram() =
  reproProgramCode(reproCommandLineModel())

reproCommandLineProgram()

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

proc reproCommandTakesRest*(command: int): bool =
  ## Whether the command's words after it are a clispec `rest` positional:
  ## another program's command line it hands over verbatim (`repro system
  ## addon`, `repro debug io monitor`). `repro help <command> <words>` then
  ## prints the command's own help, whatever the words, as it does for a
  ## command its own code still parses: the words are not repro's.
  let g = ReproCommandLine.cliGrammar()
  var holders = @[command]
  if g.commands[command].callChild >= 0:
    holders.add(g.commands[command].callChild)
  for k in holders:
    for id in g.commands[k].ownParams:
      if g.params[id].rest:
        return true
  false

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
  ## the command being parsed: a command line reads only the variables its
  ## own command (and the commands above and below it) declares, such as
  ## `repro build`'s `$REPRO_DAEMON` or `repro gateway pre-receive`'s
  ## `$GIT_DIR`, and none of any other command's.
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
  ## switches, which all start with ``-`` and take no value, so a word that
  ## does not start with ``-`` is always the next subcommand word.
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
  # A command's `call:` is a command of its own in the grammar (its
  # ``callChild``), not one of its ``children``: the parameters a `call:`
  # declares (`repro shell`'s `--shell`, beside its `hook` subcommand) count
  # wherever their command does.
  var params: seq[int] = @[]
  for k in chain:
    params.add(g.commands[k].ownParams)
    if g.commands[k].callChild >= 0:
      params.add(g.commands[g.commands[k].callChild].ownParams)
  var below = g.commands[command].children
  while below.len > 0:
    let k = below.pop()
    params.add(g.commands[k].ownParams)
    if g.commands[k].callChild >= 0:
      params.add(g.commands[g.commands[k].callChild].ownParams)
    below.add(g.commands[k].children)
  declaredEnvOf(g, params)

proc reproWordsAfterCommand*(argv: openArray[string]): seq[string] =
  ## The words of ``argv`` after the subcommand words that select its
  ## command: what a command handed its arguments unparsed (the daemon's
  ## ``rawArgs`` of `repro build`) receives. The words before the command's
  ## are subcommand words and the root's switches, as in
  ## ``reproDeclaredEnvFor``.
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
                           conf: var ReproCommandLine;
                           origins: var ReproCommandLineOrigins): int =
  ## ``loadReproCommandLine`` (below), also giving where each value came
  ## from (``origins``, confutils' origin object): for a command that must
  ## tell a flag the user typed from the variable the flag declares (a
  ## variable set in nearly every environment, such as `$SHELL`, or one whose
  ## bad value is a warning where the flag's is an error).
  try:
    (conf, origins) = ReproCommandLine.loadWithOrigins(argv,
      CliSources(env: reproDeclaredEnvFor(argv)))
  except CliHelpRequest as e:
    ReproCommandLine.printHelp(e)
    return 0
  except CliUsageError as e:
    return reportReproUsageError(e)
  except CliConfigError as e:
    stderr.writeLine("repro: " & e.msg)
    return 2
  -1

proc reproGivenOnCommandLine*(origin: CliOrigin): bool =
  ## Whether a value came from the command line (not from the variable its
  ## flag declares, nor its default).
  origin.winner.kind == cokCli

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
    conf = ReproCommandLine.load(argv,
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

proc reproArgvOf*(path: openArray[string];
                  values: openArray[(string, seq[string])];
                  commandWords = true): seq[string] {.raises: [ValueError].} =
  ## The argv words (without the image) of the command at ``path`` (its
  ## subcommand words) that give each named parameter the values listed: one
  ## value per occurrence of a list, ``true`` / ``false`` for a switch, the
  ## value of a flag or a positional otherwise. A parameter left out, or
  ## listed with no values, is not written, so the child takes its default.
  ##
  ## The words are written by clispec's renderer (``cliArgvOf``) from the
  ## description: each flag in its long spelling with its value attached
  ## (``--<long>=<value>``, so an empty value or one that starts with ``-``
  ## stays that flag's), ``--`` where a positional or an ``afterSeparator``
  ## list needs it. The generated parser reads them back to exactly these
  ## values, which is what a spawner of a process repro runs of itself
  ## needs: it names the values, never the words.
  ##
  ## Raises ``ValueError`` when ``path`` names no command or a name is no
  ## parameter of that command.
  let g = ReproCommandLine.cliGrammar()
  let leaf = reproCommandAt(path)
  if leaf < 0:
    raise newException(ValueError, "repro command line: no command `" &
      @path.join(" ") & "`")
  var selected: seq[int] = @[]
  var at = leaf
  while at > 0:
    selected.insert(at, 0)
    at = g.commands[at].parent
  selected.insert(0, 0)
  var given = newSeq[seq[CliCandidate]](g.params.len)
  var params: seq[int] = @[]
  var index = 0
  for (name, texts) in values:
    var id = -1
    for candidate in g.commands[leaf].params:
      if nimIdentNormalize(g.params[candidate].name) ==
          nimIdentNormalize(name):
        id = candidate
        break
    if id < 0:
      raise newException(ValueError, "repro command line: `" &
        @path.join(" ") & "` has no parameter `" & name & "`")
    if texts.len == 0:
      continue
    params.add(id)
    for text in texts:
      inc index
      given[id].add(CliCandidate(source: csCli, form: ccfValue, text: text,
        argvIndex: index, valueArgvIndex: -1))
  cliArgvOf(g, selected, given, params, commandWords)

proc printReproNamespaceHelp*(namespace: string; topic: seq[string]) =
  ## The help `repro <namespace> help [<word>...]` prints: the subcommand's
  ## when the words name one, else the namespace's (whose own parser always
  ## answered `help` with its usage, whatever followed).
  try:
    printReproHelp(@[namespace] & topic)
  except CliUsageError:
    printReproHelp([namespace])
