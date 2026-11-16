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
  ##
  ## A ``help`` text written as string literals joined with ``&``, to keep
  ## the lines short, is folded into the one literal clispec requires there,
  ## a statement list spliced into a scope is flattened into it, and a type
  ## such as ``seq[string]`` is kept a bracket expression.
  if n.kind == nnkInfix and n.len == 3 and n[0].eqIdent("&"):
    let left = unbound(n[1])
    let right = unbound(n[2])
    if left.kind in {nnkStrLit..nnkTripleStrLit} and
        right.kind in {nnkStrLit..nnkTripleStrLit}:
      result = newLit(left.strVal & right.strVal)
      result.copyLineInfo(n)
      return
  # `quote` turns `seq[string]` into a call of the `[]` operator; the
  # language reads (and help prints) the bracket expression as written.
  if n.kind == nnkCall and n.len >= 2 and
      n[0].kind in {nnkSym, nnkOpenSymChoice, nnkClosedSymChoice} and
      (if n[0].kind == nnkSym: $n[0] else: $n[0][0]) == "[]":
    result = nnkBracketExpr.newNimNode(n)
    for child in n[1 .. ^1]:
      result.add(unbound(child))
    return
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
  of nnkStmtList:
    # A shared group of declarations (``graphInspectionFlags`` and the like)
    # is spliced in as a statement list of its own; its statements belong
    # to the scope it is spliced into, which is where clispec reads them.
    result = n.kind.newNimNode(n)
    for child in n:
      let converted = unbound(child)
      if converted.kind == nnkStmtList:
        for statement in converted:
          result.add(statement)
      else:
        result.add(converted)
  else:
    result = n.kind.newNimNode(n)
    for child in n:
      result.add(unbound(child))

proc graphInspectionFlags(): NimNode {.compileTime.} =
  ## The flags of every command that materializes the project's build graph
  ## to inspect it (`graph`, `why`, `stats`): how the graph's tools are
  ## provisioned and where its build state and action cache live. Each takes
  ## the same value, and has the same effect, as on `repro build`.
  ##
  ## None of them declares an environment variable: these commands do not
  ## read `REPRO_TOOL_PROVISIONING` (a project's `defaultToolProvisioning`
  ## applies when the flag is absent), and the work root's and the action
  ## cache's variables are read where the paths are resolved, after the
  ## flag, so the precedence stays in one place.
  quote do:
    # Every spelling `parseToolProvisioning` accepts: the five modes, and the
    # other two spellings of `from-source` (`fromSource`, the project DSL's
    # name, and the shorthand `source`).
    flag toolProvisioning is string, values = ["path", "nix", "tarball",
        "scoop", "from-source", "fromSource", "source"],
      help = "How the graph's tools are provisioned (`from-source` is also " &
        "spelt `fromSource` or `source`); default: the project's " &
        "`defaultToolProvisioning`"
    flag workRoot is string,
      help = "The work root the project's build state lives under " &
        "(default: `$REPROBUILD_WORK_ROOT`, else the project's `.repro/`)"
    flag actionCacheRoot is string,
      help = "The action-cache root (default: " &
        "`$REPROBUILD_ACTION_CACHE_ROOT`, else the store's)"

proc devEnvSelectionFlags(): NimNode {.compileTime.} =
  ## The flags that select a project's development environment, shared by the
  ## commands that compute it.
  quote do:
    flag activity is seq[string],
      help = "Activate the named activity; repeat it or give a " &
        "comma-separated list for several (default: `default`)"
    flag workRoot is string,
      help = "The work root the development environment is computed under"
    # Internal (accepted, never shown in help): the engine names the lock
    # slice when it computes an environment on a caller's behalf.
    flag lockSlice is string, visibility = internal,
      help = "The lock slice the development environment must match"
    flag devEnvStats is string,
      help = "Write statistics of the development-environment computation " &
        "to the path"

proc storeRootFlags(): NimNode {.compileTime.} =
  ## The store root of the commands that open the local store (`store`'s
  ## subcommands, `cas`, `launch-plan`, `self`). Spelt `--store-root=PATH`
  ## only: these commands never took the path as the next word. The
  ## variable `REPRO_STORE_ROOT` is read where the root is resolved, after
  ## the flag, as `repro build` resolves it.
  quote do:
    flag storeRoot is string, format = equals,
      help = "The store root (default: `$REPRO_STORE_ROOT`, else the " &
        "per-user store)"

proc storeAndActionCacheRootFlags(): NimNode {.compileTime.} =
  ## The two roots of the bundle commands (`store closure|export|import`,
  ## `bundle create|restore`), resolved as `repro build` resolves them.
  quote do:
    flag storeRoot is string, format = equals,
      help = "The store root (default: `$REPRO_STORE_ROOT`, else the " &
        "per-user store)"
    flag actionCacheRoot is string, format = equals,
      help = "The action-cache root (default: " &
        "`$REPRO_ACTION_CACHE_ROOT`, else the store's)"

proc storeBundleSelectionFlags(): NimNode {.compileTime.} =
  ## What `store closure` and `store export` bundle: the workspace roots and
  ## the development environments frozen into the bundle.
  let roots = storeAndActionCacheRootFlags()
  quote do:
    `roots`
    flag root is seq[string], format = equals,
      help = "A workspace root to bundle (at least one); repeat it for " &
        "several"
    flag freezeDevEnv is seq[string], format = equals,
      help = "A project whose development-environment activation the " &
        "bundle carries; repeat it for several"

proc userDaemonConfigFlags(): NimNode {.compileTime.} =
  ## The per-user daemon's configuration, which every `repro daemon`
  ## subcommand takes (the client commands to find the daemon, `start`,
  ## `restart` and `serve` to configure it). Each value is also accepted as
  ## the next word, the form the daemon's own launches pass.
  quote do:
    boolFlag foreground is bool,
      help = "Run the daemon in the foreground instead of detaching it"
    boolFlag dev is bool,
      help = "Development mode: run from a staged copy and restart when " &
        "the binary changes"
    boolFlag system is bool,
      help = "Serve the system lease scope instead of the per-user one"
    flag endpoint is string,
      help = "The daemon's endpoint (default: the per-user endpoint)"
    flag stateDir is string,
      help = "The daemon's state directory (default: the per-user one)"
    flag log is string,
      help = "The daemon log (default: `<state dir>/logs/repro-daemon.log`)"
    flag stateRoot is string,
      help = "The resource-state store the daemon's reaper sweeps " &
        "(default: the scope's)"
    flag peerCache is string,
      help = "Serve the peer cache: `none` or " &
        "`lan://CIDR[:port][?seeds=HOST:PORT,...&listen=PORT]`"
    flag trustProfile is string,
      help = "The trust profile of the peer cache and the worker role: " &
        "`trusted` or `hardened`"
    # Internal (accepted, never shown in help): the daemon passes these to
    # the process it restarts into in development mode.
    flag daemonExe is string, visibility = internal,
      help = "The daemon image to launch"
    flag sourceExe is string, visibility = internal,
      help = "The image a development-mode daemon watches for changes"
    flag stagedGeneration is string, visibility = internal,
      help = "The staged generation directory this daemon runs from"
    flag previousStagedGeneration is string, visibility = internal,
      help = "The staged generation directory to remove once this one runs"
    flag restartRunId is string, visibility = internal,
      help = "The run id of the restart that launched this daemon"

proc storeDaemonConfigFlags(): NimNode {.compileTime.} =
  ## The development store daemon's configuration (`store daemon`, `store
  ## serve`). Each value is also accepted as the next word, the form
  ## `store daemon start` passes to the process it launches.
  quote do:
    boolFlag dev is bool,
      help = "The development profile (required: the only one implemented)"
    flag storeRoot is string,
      help = "The development store root (default: the platform's " &
        "development store)"
    flag endpoint is string,
      help = "The development endpoint (default: `$REPROSTORED_ENDPOINT`, " &
        "else the platform's)"

proc cacheIdentityFlags(): NimNode {.compileTime.} =
  ## The cache-entry identity `repro cache publish` labels a manifest with
  ## and `repro cache derive-key` derives a key from. Spelt `--name=value`
  ## only, and a value may be empty (`--platform-libc=`), which is how a
  ## build script leaves a field out.
  quote do:
    flag packageName is string, format = equals, help = "The package name"
    flag packageVersion is string, format = equals,
      help = "The package version"
    flag platformCpu is string, format = equals,
      help = "The CPU family: x86_64, aarch64, armv7 or x86 (and their " &
        "aliases, such as amd64 and armhf)"
    flag platformOs is string, format = equals, help = "The operating system"
    flag platformAbi is string, format = equals, help = "The ABI"
    flag platformLibc is string, format = equals, help = "The libc variant"
    flag toolchainName is string, format = equals,
      help = "The toolchain's name"
    flag toolchainVersion is string, format = equals,
      help = "The toolchain's version"
    flag toolchainHostLdso is string, format = equals,
      help = "The toolchain's host dynamic-loader ABI"
    flag toolchainExtra is string, format = equals,
      help = "An extra toolchain fingerprint"
    flag providerRevision is string, format = equals,
      help = "The provider revision"
    flag dep is seq[string], format = equals,
      help = "A dependency's entry key; repeat it for several"
    flag option is seq[string], format = equals,
      help = "An option, as `name=value`; repeat it for several"

proc certSignerStateFlag(): NimNode {.compileTime.} =
  ## The certificate signer's state directory, which both of its
  ## subcommands read.
  quote do:
    flag state is string,
      help = "The signer's state directory, holding the workers' signing " &
        "CAs and `issued.log` (required)"

proc selfFlags(): tuple[version, package, platform,
                        project: NimNode] {.compileTime.} =
  ## The flags `repro self`'s subcommands share, each spelt `--name=value`
  ## only.
  result.version = quote do:
    flag version is string, format = equals,
      help = "The version to act on (required)"
  result.package = quote do:
    flag package is string, format = equals,
      help = "`reprobuild` (the default) or `nim`, the compiler that " &
        "builds the project's provider"
  result.platform = quote do:
    flag platform is string, format = equals,
      help = "The platform (default: this host's)"
  result.project = quote do:
    flag project is string, format = equals,
      help = "The project whose pin to act on (default: the one enclosing " &
        "the current directory)"

proc reproCommandLineDescription*(): NimNode {.compileTime.} =
  ## The ``cli:`` body of repro's command line.
  ##
  ## Command order is the order ``repro --help`` lists them in.
  let graphInspection = graphInspectionFlags()
  let devEnvSelection = devEnvSelectionFlags()
  let storeRootFlag = storeRootFlags()
  let storeBundleRoots = storeBundleSelectionFlags()
  let storeBundleCommonRoots = storeAndActionCacheRootFlags()
  let bundleStoreRoots = storeAndActionCacheRootFlags()
  let userDaemonConfig = userDaemonConfigFlags()
  let storeDaemonConfig = storeDaemonConfigFlags()
  let cacheIdentity = cacheIdentityFlags()
  let certSignerState = certSignerStateFlag()
  let self = selfFlags()
  let selfVersion = self.version
  let selfPackage = self.package
  let selfPlatform = self.platform
  let selfProject = self.project
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
      `devEnvSelection`
      pos selector is string, required = false,
        help = "The project whose tasks to list (default: the current " &
          "directory's)"

    # ---- Inspecting the graph -------------------------------------------
    subcmd "graph", help = "Render the build graph of the current context":
      flag view is string, default = "actions",
        values = ["actions", "env", "neighborhood", "inputs", "dependents",
          "blast-radius", "critical-path", "partition-candidates"],
        help = "The view of the graph to render"
      flag focus is string,
        help = "The action the neighborhood and inputs views are about " &
          "(default: the selected target's action)"
      flag path is string,
        help = "The input path the dependents and blast-radius views are about"
      flag run is string,
        help = "The run (an id, or `last`) the critical-path view is about"
      flag kind is string,
        help = "The partition kind of the partition-candidates view " &
          "(default: `dylib`)"
      flag target is string,
        help = "The target whose graph to render, as an alternative to the " &
          "positional"
      flag format is string,
        help = "The output format: `text` (the default), `json` or `dot`"
      boolFlag json is bool, help = "Shortcut for `--format=json`"
      boolFlag dot is bool, help = "Shortcut for `--format=dot`"
      boolFlag lock is bool,
        help = "Focus on the solved package graph (not implemented yet: " &
          "use `repro lock visualize`)"
      boolFlag infra is bool,
        help = "Focus on the resource and infrastructure graph (not " &
          "implemented yet)"
      boolFlag all is bool,
        help = "Show the combined cross-layer graph (not implemented yet)"
      boolFlag build is bool,
        help = "Focus on the build/action graph (the default, and the only " &
          "graph implemented)"
      `graphInspection`
      pos selector is string, required = false,
        help = "The target (`target[#action]`, a path or a target name) " &
          "whose graph to render (default: the current project)"
      pos focusAction is string, required = false,
        help = "The focus action, as an alternative to --focus"
    subcmd "why",
        help = "Explain why a package or an action is in the active context":
      flag action is string,
        help = "Explain this build action; the positional is then the target"
      flag format is string,
        help = "The output format: `text` (the default) or `json`"
      boolFlag json is bool, help = "Shortcut for `--format=json`"
      `graphInspection`
      pos subject is string, required = false,
        help = "The package or build action to explain"
      pos target is string, required = false,
        help = "The target (`target[#action]` or a path) whose graph to " &
          "search (default: the current project)"
    subcmd "deps", help = "Refresh and check scanner-inferred dependencies":
      subcmd "refresh",
          help = "Scan the workspace and rewrite repro.scanned-deps.nim":
        boolFlag check is bool,
          help = "Compare against the file on disk without writing; exit " &
            "1 when it is out of date"
        boolFlag dryRun is bool,
          help = "Print what the file would contain; never write it"
        flag project is string,
          help = "The workspace root to scan (default: the current directory)"
        pos path is string, required = false,
          help = "The workspace root, as an alternative to --project"
      # `repro deps help`: the same as `repro deps --help`.
      subcmd "help", visibility = hidden:
        pos topic is seq[string], required = false
    subcmd "stats", help = "Inspect accumulated build analytics":
      flag scope is string, values = ["actions", "inputs", "targets", "tools"],
        help = "What `rank` and `show` are about"
      flag by is string,
        help = "The metric `rank` orders by (default: the scope's own)"
      flag id is string, help = "The action `show --scope=actions` is about"
      flag path is string, help = "The input `show --scope=inputs` is about"
      flag label is string, help = "The name `snapshot` records"
      flag baseline is string, help = "The snapshot `compare` starts from"
      flag candidate is string, help = "The snapshot `compare` compares"
      flag top is int, default = 10, help = "How many rows `rank` prints"
      flag projectRoot is string,
        help = "The project whose analytics to read (default: the current " &
          "directory)"
      flag target is string,
        help = "The target whose graph structural metrics use"
      flag format is string,
        help = "The output format: `text` (the default) or `json`"
      boolFlag json is bool, help = "Shortcut for `--format=json`"
      `graphInspection`
      pos view is string, default = "overview",
        values = ["status", "overview", "rank", "show", "snapshot", "compare"],
        help = "What to show: status, overview, rank, show, snapshot or " &
          "compare"
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
    subcmd "configs":
      help "List the standard build configurations"
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
      # Every subcommand takes the same daemon configuration, so the flags
      # are the namespace's own and each subcommand inherits them.
      `userDaemonConfig`
      subcmd "status":
        help "Print the daemon's identity, protocol and " &
          "sessions count"
      subcmd "start":
        help "Start the daemon unless it is running " &
          "(detached, unless --foreground)"
      subcmd "stop":
        help "Stop the daemon gracefully"
      subcmd "restart":
        help "Stop the daemon if it runs, then start it"
      subcmd "logs":
        help "Print the daemon log (the previous generation first)"
      subcmd "sessions":
        help "List the build and watch sessions the daemon hosts"
      # The daemon process itself, which `start` launches.
      subcmd "serve", visibility = internal:
        help "Run the daemon process in the foreground"
    subcmd "store", help = "Manage the local store":
      subcmd "gc", help = "Garbage-collect unreachable store contents, or " &
          "evict down to a size budget":
        `storeRootFlag`
        flag graceSeconds is int, format = equals,
          default = 300,
          help = "How long a quarantined tree waits before it is unlinked"
        boolFlag json is bool,
          help = "Print the budget collector's report as JSON"
        flag budget is string, format = equals,
          help = "Collect as a cache bounded by this size (`384G`, `1.5T`): " &
            "evict the least recently used dead objects when above it"
        flag target is string, format = equals,
          help = "The size budget mode evicts down to (default: 90% of " &
            "--budget)"
        flag keepRecent is string, format = equals,
          help = "Never evict anything used within this duration (`90s`, " &
            "`30m`, `12h`, `2d`; default: `2d`)"
        boolFlag evictCas is bool,
          help = "Also evict CAS blobs no remaining action-cache entry " &
            "references. Only for a store the action cache alone refers " &
            "to, such as a shared CI store: in a user's store it also " &
            "evicts home-generation records, which cannot be recovered"
        boolFlag dryRun is bool,
          help = "Plan the budget eviction without removing anything"
      subcmd "recover", help = "Reconcile the store's index with the " &
          "prefixes on disk after an unclean shutdown":
        `storeRootFlag`
      subcmd "roots", help = "List the roots registered against the store":
        `storeRootFlag`
      subcmd "list", help = "List every realized prefix the store records":
        `storeRootFlag`
      subcmd "optimise", aliases = ["optimize"],
          help = "Hardlink byte-identical files across realized prefixes":
        `storeRootFlag`
        boolFlag json is bool, help = "Print the report as JSON"
      subcmd "materialize", help = "Reproduce a directory tree at another " &
          "path with the store's materialiser, and report what it did":
        boolFlag json is bool, help = "Print the report as JSON"
        boolFlag noSharedInode is bool,
          help = "Copy every file instead of hardlinking it"
        pos srcDir is string, help = "The directory to reproduce"
        pos dstDir is string, help = "Where to reproduce it"
      subcmd "closure", help = "List what a native-store bundle of the " &
          "workspace roots would carry, writing nothing":
        `storeBundleRoots`
        boolFlag json is bool, help = "Print the closure as JSON"
      subcmd "export",
          help = "Write the native-store bundle of the workspace roots " &
            "(docs/store-bundles.md)":
        `storeBundleRoots`
        flag out is string, format = equals,
          help = "The directory the bundle is written to (required)"
        flag partSize is string, format = equals,
          help = "The size of each part (`64M`, `1G`; default: 64 MiB)"
        flag zstdLevel is Option[int], format = equals,
          help = "The zstd compression level (default: 19)"
        flag zstdThreads is Option[int], format = equals,
          help = "The zstd worker threads (default: all cores)"
        boolFlag json is bool, help = "Print the bundle manifest"
      subcmd "import", help = "Restore a native-store bundle":
        `storeBundleCommonRoots`
        flag root is seq[string], format = equals,
          help = "A workspace root the bundle must have been produced at; " &
            "repeat it for several"
        boolFlag allowDevEnv is bool,
          help = "Allow the frozen development environments the bundle " &
            "carries, as `repro allow` would"
        boolFlag force is bool,
          help = "Unpack again even when the bundle was already imported"
        boolFlag json is bool,
          help = "Print the report, with per-phase wall times, as JSON"
        pos bundleDir is string, help = "The bundle directory"
      subcmd "copy", help = "Copy realized closures into another store root":
        `storeRootFlag`
        flag to is string, format = equals,
          help = "The destination store root (required)"
        flag rootId is seq[string], format = equals,
          help = "Copy every prefix this registered root holds; repeat it " &
            "for several"
        boolFlag json is bool, help = "Print the report as JSON"
        pos prefixes is seq[string], required = false,
          help = "Prefixes of the source store, as absolute paths or " &
            "`prefixes/<pkg>/<dir>`; a path inside a prefix names that prefix"
      subcmd "daemon",
          help = "Start, query or stop the development store daemon":
        `storeDaemonConfig`
        subcmd "start":
          help "Start the development store daemon"
        subcmd "status":
          help "Print the development store daemon's " &
            "status"
        subcmd "stop":
          help "Stop the development store daemon"
      # The store daemon process itself, which `store daemon start` launches.
      subcmd "serve", visibility = internal,
          help = "Run the development store daemon in the foreground":
        `storeDaemonConfig`
    subcmd "cas", help = "Inspect the content-addressed blob store":
      `storeRootFlag`
      subcmd "gc",
          help = "Reclaim every CAS blob outside the retain set. This " &
            "includes the blobs home generations refer to, which cannot " &
            "be recovered; run it only on a store with none, or keep them":
        flag keep is string, format = equals,
          help = "The blobs to keep, as comma-separated 64-character hex " &
            "digests"
      subcmd "verify",
          help = "Check one blob's bytes against its digest (exit 1 when " &
            "they differ)":
        pos digest is string, help = "The blob's 64-character hex digest"
      subcmd "path", help = "Print the on-disk path of one blob":
        pos digest is string, help = "The blob's 64-character hex digest"
      subcmd "exists",
          help = "Exit 0 when the blob is present, 1 when it is not":
        pos digest is string, help = "The blob's 64-character hex digest"
    subcmd "cache",
        help = "Look up, substitute and publish binary-cache entries. The " &
          "cache is `$REPRO_BINARY_CACHE_URL` (default " &
          "`http://localhost:7878`); `substitute` trusts only the caches " &
          "`$REPRO_CACHES_CONFIG` (else /etc/repro/caches.conf and " &
          "~/.config/repro/caches.conf) lists with their producer keys; " &
          "`publish` and `gen-key` read the producer key pair from " &
          "`$REPRO_BINARY_CACHE_KEY_PATH` and " &
          "`$REPRO_BINARY_CACHE_CERT_PATH`; `substitute` fetches through the " &
          "local store `$REPRO_LOCAL_STORE`":
      # `repro cache` alone prints this help and succeeds, as it always has.
      call:
        discard
      subcmd "lookup",
          help = "Exit 0 when the cache holds the entry, 1 when it does not":
        pos entryKey is string, help = "The entry key, 64 hex characters"
      subcmd "substitute", help = "Fetch an entry from a trusted cache and " &
          "extract it into a directory":
        pos entryKey is string, help = "The entry key, 64 hex characters"
        pos outDir is string, help = "The directory to extract it into"
      subcmd "publish", help = "Pack a directory, sign its manifest with " &
          "the producer key and upload it":
        `cacheIdentity`
        pos entryKey is string, help = "The entry key, 64 hex characters"
        pos prefixDir is string, help = "The directory to publish"
      subcmd "derive-key",
          help = "Print the entry key the identity flags derive":
        `cacheIdentity`
      subcmd "gen-key", help = "Create the producer key pair when it is " &
          "missing, and print its public key":
        `cacheIdentity`
      # `repro cache help`: the same as `repro cache --help`.
      subcmd "help", visibility = hidden:
        pos topic is seq[string], required = false
    subcmd "bundle", help = "Create, publish and restore workspace bundles " &
        "(docs/workspace-bundles.md)":
      subcmd "create", help = "Write the bundle of a workspace selection":
        flag out is string, format = equals,
          help = "The directory the bundle is written under (required)"
        flag workspaceRoot is string, format = equals,
          help = "The workspace (default: the one enclosing the current " &
            "directory)"
        flag name is string, format = equals,
          help = "The bundle's name (default: derived from the selector)"
        boolFlag allShells is bool,
          help = "Capture every member's development shell"
        flag primary is string, format = equals,
          help = "The shell the bundle activates, as `MEMBER:SHELL`"
        boolFlag noNix is bool, help = "Leave out the Nix half"
        boolFlag noSources is bool, help = "Leave out the source checkouts"
        boolFlag noNative is bool, help = "Leave out the native-store half"
        flag nativeRoot is seq[string], format = equals,
          help = "A workspace root whose native store the bundle carries; " &
            "repeat it for several"
        boolFlag freezeDevEnv is bool,
          help = "Freeze the repro development environment of every member " &
            "that is a repro project"
        flag zstd is string, format = equals,
          help = "The store path the bootstrap realises when the restoring " &
            "machine has no zstd"
        flag repro is string, format = equals,
          help = "The store path whose `bin/repro` the bootstrap hands over to"
        flag level is Option[int], format = equals,
          help = "The zstd compression level"
        flag partSize is string, format = equals,
          help = "The size of each part (`64M`, `1G`)"
        boolFlag checkStable is bool,
          help = "Capture every shell environment twice and refuse when the " &
            "captures differ"
        `bundleStoreRoots`
        boolFlag json is bool, help = "Print the bundle's `latest.json`"
        pos selector is string,
          help = "The project, variant, repository set or repository to bundle"
      subcmd "publish", help = "Upload a bundle to S3 (credentials from " &
          "`$AWS_ACCESS_KEY_ID` and `$AWS_SECRET_ACCESS_KEY`) or to GitHub " &
          "(your git credentials)":
        flag to is string, format = equals,
          help = "`s3://BUCKET[/PREFIX]` or `github:OWNER/REPO` (required)"
        flag endpoint is string, format = equals,
          help = "The S3 endpoint URL"
        flag region is string, format = equals, help = "The S3 region"
        flag parallel is Option[int], format = equals,
          help = "How many uploads run at once"
        pos bundleDir is string, help = "The bundle, `<out>/<bundle>`"
      subcmd "restore", help = "Restore a bundle on this machine":
        flag workspace is string, format = equals,
          help = "Where the workspace is restored"
        boolFlag activate is bool,
          help = "Write the profile script that enters the primary shell in " &
            "every new shell"
        flag activationFile is string, format = equals,
          help = "The profile script --activate writes"
        flag bashrcFile is string, format = equals,
          help = "The shell startup file that sources the profile script"
        boolFlag allowDevEnv is bool,
          help = "Allow the frozen development environments the bundle " &
            "carries"
        flag parallel is Option[int], format = equals,
          help = "How many downloads run at once"
        flag staging is string, format = equals,
          help = "Where downloads are staged"
        flag nixRoot is string, format = equals,
          help = "Restore the Nix half into another store root (for tests)"
        boolFlag afterBootstrap is bool, visibility = internal,
          help = "Run by the bundle's restore.sh once the Nix half is restored"
        `bundleStoreRoots`
        boolFlag json is bool, help = "Print the report as JSON"
        pos source is string, help = "A bundle directory or URL, or " &
          "`github:OWNER/REPO[@REF]/BUNDLE`"
      # `repro bundle help`: the same as `repro bundle --help`.
      subcmd "help", visibility = hidden:
        pos topic is seq[string], required = false
    subcmd "reap", help = "Run one sweep of the resource-state store":
      boolFlag once is bool,
        help = "Sweep once (the only mode; accepted for clarity)"
      boolFlag force is bool,
        help = "Reap every present record (or the named ones) regardless " &
          "of its lease"
      flag stateRoot is string, format = equals,
        help = "The state store to sweep (default: the per-user store)"
      # `repro build`'s spellings, refused with a pointer to `--force`
      # rather than as unknown flags.
      boolFlag hardRebuild is bool, visibility = hidden
      boolFlag rebuildHostBound is bool, visibility = hidden
      pos addresses is seq[string], required = false,
        help = "Restrict the sweep to these records"
    subcmd "launch-plan", help = "Show stored launch plans":
      `storeRootFlag`
      subcmd "show", help = "Print a stored launch plan as JSON":
        pos hexId is string,
          help = "The launch plan's 64-character hex digest"
      subcmd "id",
          help = "Print the launch-plan id of an envelope file on disk":
        pos path is string, help = "The launch-plan envelope file"
    subcmd "cert-signer",
        help = "Run the certificate signer for remote build workers":
      subcmd "serve", help = "Sign one certificate per request for an " &
          "authorized worker":
        `certSignerState`
        flag identity is string,
          help = "The signer's host CA directory (required)"
        flag anchors is string,
          help = "The directory of the workers' host CAs (required)"
        flag authorized is string,
          help = "The file of authorized worker host ids, re-read on every " &
            "request (required)"
        flag revoked is string, help = "The file of revoked worker host ids"
        flag bindAddr is string, perSource = [cli = "bind"],
          default = "127.0.0.1",
          help = "The address to listen on (never a wildcard)"
        flag port is int, help = "The port to listen on (default: any free " &
          "port)"
        flag readyFile is string,
          help = "Write `ADDR:PORT` and the signer's host id here once it " &
            "listens"
      subcmd "registration",
          help = "Print the registered-keys entry for one worker":
        `certSignerState`
        flag worker is string,
          help = "The worker's host id, 64 hex characters (required)"
    subcmd "self", help = "Install and manage reprobuild's own versions":
      subcmd "install",
          help = "Realize a built reprobuild image tree into the store":
        flag fromDir is string, format = equals, perSource = [cli = "from"],
          help = "The image tree to install (required)"
        `selfVersion`
        `selfPackage`
        `selfPlatform`
        `storeRootFlag`
        boolFlag json is bool, help = "Print the result as JSON"
      subcmd "provision",
          help = "Put the version a pin names into the store":
        `selfVersion`
        `selfPackage`
        `selfPlatform`
        `selfProject`
        `storeRootFlag`
        flag fromDir is string, format = equals, perSource = [cli = "from"],
          help = "Install from this image tree when the version is missing"
        boolFlag json is bool, help = "Print the result as JSON"
      subcmd "hold", help = "Attach the project's pin root to the prefix " &
          "its lock pins, so `repro store gc` keeps it":
        `selfPackage`
        `selfProject`
        `storeRootFlag`
        boolFlag json is bool, help = "Print the result as JSON"
      subcmd "which",
          help = "Report what the launcher would run here, and why":
        `selfPackage`
        `selfProject`
        `storeRootFlag`
        boolFlag json is bool, help = "Print the report as JSON"
      subcmd "list", help = "List the images resident in the store":
        `selfPackage`
        `storeRootFlag`
        boolFlag json is bool, help = "Print the list as JSON"
      subcmd "prune-roots",
          help = "Re-derive every pin root from the lock it names":
        `storeRootFlag`
        boolFlag json is bool, help = "Print the outcomes as JSON"

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
