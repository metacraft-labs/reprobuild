## repro's own command line, described once in the clispec ``cli:`` language.
##
## This module is the single description of what ``repro`` accepts: its
## commands, their aliases, visibility and help, and (for the commands whose
## parsing has moved onto the description) every flag, positional and
## environment variable. Everything else is derived from it:
##
## * ``repro_cli_support/cli_program`` instantiates confutils over it
##   (``confutils/clispec_config``), which generates the typed configuration
##   object, the argv parser, help and shell completion through clispec;
## * the thin client (``apps/repro-client``) reads the flags it must hand
##   over on as a compile-time table (``reproThinClientHandOverFlags``), so
##   it learns them from here and links no parser.
##
## The description is a compile-time proc returning the ``cli:`` body rather
## than a macro call, so both consumers expand the same tree: the engine into
## a program, the thin client into a constant. It imports only the clispec
## model and description parser, both used at compile time only, which is
## what keeps the thin client free of the parser and its tables.
##
## Commands whose parsing has not moved onto the description yet are declared
## with their name, aliases, visibility and help, and one positional marked
## ``passThrough = true`` that collects the rest of the command line
## unparsed; ``cli_program`` hands that list to the command's existing parser.
## A command moves onto the description by replacing that positional with its
## real declarations, and its hand-written parsing then goes.
##
## Two declarations are reprobuild's own, read through clispec's extension
## hook (``parseCliParamExtension``) into ``ReproCommandLineParamExt``:
##
## * ``passThrough = true`` on a positional (see above);
## * ``clientSide = true`` on a ``build`` flag the full CLI processes itself
##   before or after the daemon answers, so the thin client must hand the
##   invocation over rather than route it to the daemon (see the header of
##   ``apps/repro-client/repro_client.nim`` for why each one is there).

import std/macros

import clispec/[model, dsl]

type
  ReproCommandLineParamExt* = object
    ## What repro's own description says about a parameter beyond what
    ## clispec knows.
    passThrough*: bool
      ## The positional that collects an unmigrated command's arguments,
      ## unparsed.
    clientSide*: bool
      ## A ``build`` flag the thin client must hand over on.

proc extensionBool(arg: NimNode; name: string): bool =
  if arg[1].eqIdent("true"): true
  elif arg[1].eqIdent("false"): false
  else:
    error("repro command line: `" & name & "` is true or false, got: " &
      arg[1].repr, arg[1])
    false

proc parseCliParamExtension*(ext: var ReproCommandLineParamExt;
                             kind: CliParamKind; arg: NimNode): bool =
  ## clispec's parameter-extension hook (``clispec/dsl``, "Extensions"):
  ## claims ``passThrough = <bool>`` on a positional and
  ## ``clientSide = <bool>`` on a flag.
  if arg.kind != nnkExprEqExpr:
    return false
  if arg[0].eqIdent("passThrough"):
    if kind != cpkPositional:
      error("repro command line: `passThrough` belongs on a positional", arg)
    ext.passThrough = extensionBool(arg, "passThrough")
    return true
  if arg[0].eqIdent("clientSide"):
    if kind != cpkFlag:
      error("repro command line: `clientSide` belongs on a flag", arg)
    ext.clientSide = extensionBool(arg, "clientSide")
    return true
  false

const
  ReproCommandLineType* = "ReproCommandLine"
    ## The configuration object ``cli_program`` generates.
  ReproProgramName* = "repro"
    ## The name help, errors and completion scripts use: the command a user
    ## types, whichever image answers it.
  PassThroughParamName* = "args"
    ## The ``passThrough`` positional's name in every unmigrated command.

proc unbound(n: NimNode): NimNode {.compileTime.} =
  ## ``n`` with every symbol ``quote`` bound turned back into the identifier
  ## it was written as, line information kept. The ``cli:`` language is read
  ## as written, the way a macro's untyped argument is: ``required = false``
  ## names the literal ``false``, which clispec reads as an identifier, not
  ## a symbol of ``system``.
  case n.kind
  of nnkSym:
    result = ident($n)
    result.copyLineInfo(n)
  of nnkOpenSymChoice, nnkClosedSymChoice:
    result = ident($n[0])
    result.copyLineInfo(n)
  of nnkNone, nnkEmpty, nnkIdent, nnkCharLit..nnkUInt64Lit,
      nnkFloatLit..nnkFloat64Lit, nnkStrLit..nnkTripleStrLit, nnkNilLit:
    result = n
  else:
    result = n.kind.newNimNode(n)
    for child in n:
      result.add(unbound(child))

proc reproCommandLineDescription*(): NimNode {.compileTime.} =
  ## The ``cli:`` body of repro's command line.
  ##
  ## Command order is the order ``repro --help`` lists them in.
  result = unbound quote do:
    help "Reproducible builds, development environments and workspaces"
    # Command-line flags are kebab-case (`--tool-provisioning`); keys in
    # reprobuild's TOML configuration files are snake_case.
    convention cli = kebabCase
    convention file = snakeCase

    call:
      boolFlag version is bool, short = 'V',
        help = "Print the version (the line `repro version` prints) and exit"

    # ---- Building and testing -------------------------------------------
    subcmd "build", help = "Build the current project or the selected targets":
      # The flags the thin client hands over on (see the module header).
      # `build` is not parsed from this description yet: until it is, these
      # declarations feed the thin client's table and completion, and the
      # arguments reach `runBuildCommand` unparsed through `args`.
      flag daemon is string, values = ["auto", "require", "off"],
        clientSide = true,
        help = "Whether the build runs in the per-user daemon"
      boolFlag listTargets is bool, clientSide = true,
        help = "List the project's targets instead of building"
      boolFlag listTargetsJson is bool, clientSide = true,
        help = "List the project's targets as JSON"
      boolFlag printSolvedGraph is bool, clientSide = true,
        help = "Print the solved build graph instead of building"
      flag only is string, clientSide = true,
        help = "Run only the actions matching the pattern"
      flag writeBenchmark is string, clientSide = true,
        help = "Write a benchmark document to the path"
      flag writeStats is string, optionalValue = "", clientSide = true,
        help = "Write the build statistics"
      flag statsGroups is string, clientSide = true,
        help = "Which statistics groups to record"
      flag progressBars is string, values = ["overlay", "split"],
        clientSide = true, help = "How progress bars are laid out"
      # Routable when (and only when) it selects quiet progress; the thin
      # client reads its spellings from here.
      flag progress is string, help = "How build progress is shown"
      pos args is seq[string], required = false, passThrough = true,
        help = "Targets and the rest of the build command line"
    subcmd "test", help = "Run the project's tests":
      pos args is seq[string], required = false, passThrough = true
    subcmd "bench", help = "Run the project's benchmarks":
      pos args is seq[string], required = false, passThrough = true
    subcmd "lint", help = "Run the project's lint checks":
      pos args is seq[string], required = false, passThrough = true
    subcmd "certify",
        help = "Run the required test set and issue a signed test certificate":
      pos args is seq[string], required = false, passThrough = true
    subcmd "certificates",
        help = "List the project's named certificates or those a plan issues":
      pos args is seq[string], required = false, passThrough = true
    subcmd "ci", help = "Plan which targets a CI run must execute":
      pos args is seq[string], required = false, passThrough = true
    subcmd "watch",
        help = "Watch for changes and rebuild or rerun continuously":
      pos args is seq[string], required = false, passThrough = true
    subcmd "clean", help = "Remove the current project's build artifacts":
      pos args is seq[string], required = false, passThrough = true
    subcmd "run", help = "Run a task, a build output or a target once":
      pos args is seq[string], required = false, passThrough = true
    subcmd "tasks", help = "List the current project's tasks":
      pos args is seq[string], required = false, passThrough = true

    # ---- Inspecting the graph -------------------------------------------
    subcmd "graph", help = "Render the build graph of the current context":
      pos args is seq[string], required = false, passThrough = true
    subcmd "why",
        help = "Explain why a package or an action is in the active context":
      pos args is seq[string], required = false, passThrough = true
    subcmd "deps", help = "Refresh and check scanner-inferred dependencies":
      pos args is seq[string], required = false, passThrough = true
    subcmd "stats", help = "Inspect accumulated build analytics":
      pos args is seq[string], required = false, passThrough = true
    subcmd "show-conventions",
        help = "Print the resolved convention stack of a workspace":
      flag project is string,
        help = "The workspace root (default: the current directory)"
      flag target is string,
        help = "Print details only for the named member or package"
      boolFlag json is bool,
        help = "Print a JSON document instead of the text form"
      pos path is string, required = false,
        help = "The workspace root, as an alternative to --project"
    subcmd "configs", help = "List the standard build configurations":
      pos args is seq[string], required = false, passThrough = true
    subcmd "capabilities",
        help = "Describe what this build of repro supports":
      flag format is string, values = ["json", "text"], default = "json",
        help = "The output format"

    # ---- Development environments ---------------------------------------
    subcmd "exec", help = "Run a command inside the development environment":
      pos args is seq[string], required = false, passThrough = true
    subcmd "shell",
        help = "Enter or print the development shell environment":
      pos args is seq[string], required = false, passThrough = true
    subcmd "allow", help = "Trust a project's development environment":
      pos args is seq[string], required = false, passThrough = true
    subcmd "deny",
        help = "Revoke the trust in a project's development environment":
      pos args is seq[string], required = false, passThrough = true
    subcmd "dev-env",
        help = "Export or deactivate a development environment for a shell":
      pos args is seq[string], required = false, passThrough = true
    subcmd "up", help = "Start the project's services":
      pos args is seq[string], required = false, passThrough = true
    subcmd "down", help = "Stop the project's supervised development session":
      pos args is seq[string], required = false, passThrough = true
    subcmd "dev",
        help = "Run the development session with continuous rebuilds":
      pos args is seq[string], required = false, passThrough = true
    subcmd "develop",
        help = "Set up a project or a dependency for development":
      pos args is seq[string], required = false, passThrough = true
    subcmd "add", help = "Add a dependency to the active context":
      pos args is seq[string], required = false, passThrough = true
    subcmd "remove", help = "Remove a dependency from the active context":
      pos args is seq[string], required = false, passThrough = true
    subcmd "hcr", help = "Coordinate hot code reloading":
      pos args is seq[string], required = false, passThrough = true

    # ---- Workspaces and publication -------------------------------------
    subcmd "workspace", aliases = ["ws"],
        help = "Manage the multi-repository workspace":
      pos args is seq[string], required = false, passThrough = true
    subcmd "sync",
        help = "Fast-forward the workspace's repositories toward a target":
      pos args is seq[string], required = false, passThrough = true
    subcmd "pull",
        help = "Converge the workspace onto its declared revisions":
      pos args is seq[string], required = false, passThrough = true
    subcmd "branch", help = "Fork a new sibling workspace on a new branch":
      pos args is seq[string], required = false, passThrough = true
    subcmd "switch", help = "Switch the workspace to a branch":
      pos args is seq[string], required = false, passThrough = true
    subcmd "push",
        help = "Publish the current work as a reproducible workspace state":
      pos args is seq[string], required = false, passThrough = true
    subcmd "check", help = "Run the publication checks (the pre-push gate)":
      pos args is seq[string], required = false, passThrough = true
    subcmd "hooks", help = "Install, repair or remove the managed hooks":
      pos args is seq[string], required = false, passThrough = true
    subcmd "lock", help = "Inspect and update the project's lock":
      pos args is seq[string], required = false, passThrough = true
    subcmd "locking",
        help = "Explain or adopt the workspace's locking configuration":
      pos args is seq[string], required = false, passThrough = true
    subcmd "flake",
        help = "Compute the Nix flake overrides of the develop set":
      pos args is seq[string], required = false, passThrough = true
    subcmd "gateway", help = "Run a push-gateway hook entry point":
      pos args is seq[string], required = false, passThrough = true
    subcmd "prompt",
        help = "Print a workspace-state segment for the shell prompt":
      pos args is seq[string], required = false, passThrough = true

    # ---- Stores, caches and daemons -------------------------------------
    subcmd "daemon", help = "Manage the per-user reprobuild daemon":
      pos args is seq[string], required = false, passThrough = true
    subcmd "store", help = "Manage the local store":
      pos args is seq[string], required = false, passThrough = true
    subcmd "cas", help = "Inspect the content-addressed blob store":
      pos args is seq[string], required = false, passThrough = true
    subcmd "cache",
        help = "Look up, substitute and publish binary-cache entries":
      pos args is seq[string], required = false, passThrough = true
    subcmd "bundle", help = "Create, publish and restore store bundles":
      pos args is seq[string], required = false, passThrough = true
    subcmd "reap", help = "Run one sweep of the resource-state store":
      pos args is seq[string], required = false, passThrough = true
    subcmd "launch-plan", help = "Show stored launch plans":
      pos args is seq[string], required = false, passThrough = true
    subcmd "cert-signer",
        help = "Run the certificate signer for remote build workers":
      pos args is seq[string], required = false, passThrough = true
    subcmd "self", help = "Install and manage reprobuild's own versions":
      pos args is seq[string], required = false, passThrough = true

    # ---- Machines --------------------------------------------------------
    subcmd "home", help = "Manage your home profile":
      pos args is seq[string], required = false, passThrough = true
    subcmd "system", help = "Manage the machine's system configuration":
      pos args is seq[string], required = false, passThrough = true
    subcmd "infra", help = "Plan and apply infrastructure":
      pos args is seq[string], required = false, passThrough = true
    subcmd "anywhere", help = "Install the reprobuild system add-on on a host":
      pos args is seq[string], required = false, passThrough = true
    subcmd "deploy-agent", help = "Run the deployment agent":
      pos args is seq[string], required = false, passThrough = true
    subcmd "hardware", help = "Probe the machine's hardware":
      pos args is seq[string], required = false, passThrough = true
    subcmd "disk", help = "Plan, apply and mount disk layouts":
      pos args is seq[string], required = false, passThrough = true
    subcmd "attest",
        help = "Compute and check launch measurements of attested images":
      pos args is seq[string], required = false, passThrough = true
    subcmd "cargo", help = "Garbage-collect cargo target directories":
      pos args is seq[string], required = false, passThrough = true

    # ---- About repro itself ----------------------------------------------
    subcmd "health", help = "Diagnose the reprobuild environment":
      pos args is seq[string], required = false, passThrough = true
    subcmd "debug", help = "Inspect the filesystem monitor and artifacts":
      pos args is seq[string], required = false, passThrough = true
    subcmd "help", help = "Show the help of repro or of one command":
      pos topic is seq[string], required = false,
        help = "The command whose help to show, for example `workspace sync`"
    subcmd "version",
        help = "Show the client version and the protocol versions it speaks":
      boolFlag json is bool,
        help = "Print one JSON object (schema reprobuild.version.v1)"
    subcmd "completion", help = "Print a shell's completion script":
      pos shell is string, values = ["bash", "zsh", "fish", "powershell"],
        help = "The shell whose completion script to print"

    # ---- Role processes ----------------------------------------------------
    # The commands repro spawns of itself. Listed only by
    # `repro internal --help`, never by the primary help.
    subcmd "internal", visibility = internal,
        help = "Role processes repro spawns of itself":
      subcmd "shared-pool-upload-pack",
          help = "The shared-clone Git transport":
        pos args is seq[string], required = false, passThrough = true
      subcmd "resolve-package",
          help = "Print the checkout a declared package resolves to":
        pos args is seq[string], required = false, passThrough = true
      subcmd "io", help = "Filesystem monitoring":
        subcmd "monitor",
            help = "The filesystem-monitor shim around one action":
          pos args is seq[string], required = false, passThrough = true
      subcmd "runquota-helper", help = "RunQuota lease helper":
        pos args is seq[string], required = false, passThrough = true
      subcmd "compile-provider", help = "Provider-compile helper":
        pos args is seq[string], required = false, passThrough = true
      subcmd "extract-interface", help = "Interface-extraction helper":
        pos args is seq[string], required = false, passThrough = true
      subcmd "compile-profile", help = "Profile-compile helper":
        pos args is seq[string], required = false, passThrough = true
      subcmd "probe-profile-platforms",
          help = "Profile platform-probe helper":
        pos args is seq[string], required = false, passThrough = true
      subcmd "dev-env-introspect", help = "Dev-env introspection helper":
        pos args is seq[string], required = false, passThrough = true
      subcmd "render-dev-env-shell", help = "Dev-env shell renderer":
        pos args is seq[string], required = false, passThrough = true
      subcmd "direnv-activate", help = "direnv activation helper":
        pos args is seq[string], required = false, passThrough = true
      subcmd "native-shell-activate",
          help = "Native-shell activation helper":
        pos args is seq[string], required = false, passThrough = true
      subcmd "dev-session-supervisor", help = "Dev-session supervisor":
        pos args is seq[string], required = false, passThrough = true
      subcmd "dev-session-http", help = "Dev-session HTTP bridge":
        pos args is seq[string], required = false, passThrough = true
      subcmd "cmake-regenerate", help = "CMake regeneration helper":
        pos args is seq[string], required = false, passThrough = true

    # The `__repro-<name>` spellings of the internal helpers, accepted for
    # one release beside `internal <name>` and listed nowhere.
    subcmd "__repro-runquota-helper", visibility = hidden:
      pos args is seq[string], required = false, passThrough = true
    subcmd "__repro-compile-provider", visibility = hidden:
      pos args is seq[string], required = false, passThrough = true
    subcmd "__repro-extract-interface", visibility = hidden:
      pos args is seq[string], required = false, passThrough = true
    subcmd "__repro-compile-profile", visibility = hidden:
      pos args is seq[string], required = false, passThrough = true
    subcmd "__repro-probe-profile-platforms", visibility = hidden:
      pos args is seq[string], required = false, passThrough = true
    subcmd "__repro-dev-env-introspect", visibility = hidden:
      pos args is seq[string], required = false, passThrough = true
    subcmd "__repro-render-dev-env-shell", visibility = hidden:
      pos args is seq[string], required = false, passThrough = true
    subcmd "__repro-direnv-activate", visibility = hidden:
      pos args is seq[string], required = false, passThrough = true
    subcmd "__repro-native-shell-activate", visibility = hidden:
      pos args is seq[string], required = false, passThrough = true
    subcmd "__repro-dev-session-supervisor", visibility = hidden:
      pos args is seq[string], required = false, passThrough = true
    subcmd "__repro-dev-session-http", visibility = hidden:
      pos args is seq[string], required = false, passThrough = true
    subcmd "__repro-cmake-regenerate", visibility = hidden:
      pos args is seq[string], required = false, passThrough = true
    # The home-profile activation a remote `repro home apply` runs over ssh.
    subcmd "__remote-activate", visibility = hidden:
      pos args is seq[string], required = false, passThrough = true

proc reproCommandLineModel*(): CliModel[NoCliExtension,
    ReproCommandLineParamExt] {.compileTime.} =
  ## The description parsed into clispec's typed model.
  parseCliModel[NoCliExtension, ReproCommandLineParamExt](
    reproCommandLineDescription(), NoCliExtension())

proc flagSpellings*(p: CliParam[ReproCommandLineParamExt]): seq[string] =
  ## Every spelling a flag answers to on the command line: ``--<long>``,
  ## ``--no-<long>`` for a negatable one, its ``alias`` (without a trailing
  ## ``=``) and ``-<short>``.
  if p.kind != cpkFlag:
    return
  result.add("--" & p.longName)
  if p.negatable:
    result.add("--no-" & p.longName)
  if p.alias.len > 0:
    var alias = p.alias
    if alias[^1] == '=':
      alias.setLen(alias.len - 1)
    if alias notin result:
      result.add(alias)
  if p.short != '\0':
    result.add("-" & p.short)

proc commandNamed*(model: CliModel[NoCliExtension, ReproCommandLineParamExt];
                   path: openArray[string]): int {.compileTime.} =
  ## The index in ``model.commands`` of the named (not ``call:``) command
  ## at ``path``, or -1.
  for i, c in model.commands:
    if not c.anonymous and c.path == @path:
      return i
  -1

macro reproThinClientHandOverFlags*(): untyped =
  ## Every spelling of a ``build`` flag declared ``clientSide = true``, as an
  ## array literal: the thin client hands any invocation carrying one of
  ## them over to the full CLI.
  let model = reproCommandLineModel()
  let build = model.commandNamed(["build"])
  if build < 0:
    error("repro command line: the description declares no `build` command")
  result = nnkBracket.newTree()
  for p in model.commands[build].params:
    if p.ext.clientSide:
      for spelling in flagSpellings(p):
        result.add(newLit(spelling))
  if result.len == 0:
    error("repro command line: no `build` flag is declared clientSide")

macro reproFlagSpellings*(path: static[seq[string]];
                          name: static[string]): untyped =
  ## The spellings of the flag ``name`` of the command at ``path``, as an
  ## array literal; a compile error when there is no such flag.
  let model = reproCommandLineModel()
  let at = model.commandNamed(path)
  if at < 0:
    error("repro command line: no command `" & $path & "`")
  result = nnkBracket.newTree()
  for p in model.commands[at].params:
    if p.name == name and p.kind == cpkFlag:
      for spelling in flagSpellings(p):
        result.add(newLit(spelling))
  if result.len == 0:
    error("repro command line: command `" & $path & "` has no flag `" &
      name & "`")
