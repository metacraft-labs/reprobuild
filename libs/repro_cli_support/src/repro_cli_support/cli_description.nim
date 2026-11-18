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
  ## `--tool-provisioning` declares no environment variable: these commands
  ## do not read `REPRO_TOOL_PROVISIONING` (a project's
  ## `defaultToolProvisioning` applies when the flag is absent). The work
  ## root and the action-cache root declare theirs, as on `repro build`:
  ## the flag wins over `$REPROBUILD_WORK_ROOT` and
  ## `$REPROBUILD_ACTION_CACHE_ROOT`.
  quote do:
    # Every spelling `parseToolProvisioning` accepts: the five modes, and the
    # other two spellings of `from-source` (`fromSource`, the project DSL's
    # name, and the shorthand `source`).
    flag toolProvisioning is string, values = ["path", "nix", "tarball",
        "scoop", "from-source", "fromSource", "source"],
      help = "How the graph's tools are provisioned (`from-source` is also " &
        "spelt `fromSource` or `source`); default: the project's " &
        "`defaultToolProvisioning`"
    flag workRoot is string, env = "REPROBUILD_WORK_ROOT",
      help = "The work root the project's build state lives under " &
        "(default: `$REPROBUILD_WORK_ROOT`, else the project's `.repro/`)"
    flag actionCacheRoot is string, env = "REPROBUILD_ACTION_CACHE_ROOT",
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

proc devSessionSelectionFlags(): NimNode {.compileTime.} =
  ## The flags that select the development session `up`, `dev` and `down`
  ## act on: its activities and the work root it lives under.
  quote do:
    flag activity is seq[string],
      help = "The session of the named activity; repeat it or give a " &
        "comma-separated list for several (default: `default`)"
    flag workRoot is string,
      help = "The work root the development environment is computed under"
    # Internal (accepted, never shown in help), as for `exec` and `tasks`.
    flag lockSlice is string, visibility = internal,
      help = "The lock slice the development environment must match"

proc devSessionStartFlags(): NimNode {.compileTime.} =
  ## The flags of the commands that start a supervised development session
  ## (`up`, `dev`): how it runs, where its control API listens, and how
  ## long the command waits for it.
  quote do:
    boolFlag foreground is bool,
      help = "Run the supervised session in the foreground"
    flag http is string,
      help = "Serve the control API over TCP at `HOST:PORT` (default: a " &
        "Unix-domain socket on POSIX, `127.0.0.1:0` on Windows)"
    boolFlag httpAllowRemote is bool,
      help = "Permit a non-loopback `--http` host; the session token is " &
        "then the only barrier"
    flag readyTimeout is Option[int],
      help = "Wait at most this many milliseconds for the session to come " &
        "up (default: derived from the services' readiness timeouts; " &
        "not with --foreground)"
    boolFlag replace is bool,
      help = "Stop the running instance of a shared service and start " &
        "this definition"
    boolFlag force is bool,
      help = "With --replace: take the shared instance over from its other " &
        "live holders"

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
  ## `bundle create|restore`), resolved as `repro build` resolves them:
  ## `--action-cache-root` wins over `$REPROBUILD_ACTION_CACHE_ROOT`, the
  ## variable `resolveActionCacheRoot` reads (declared on the flag, as on
  ## `repro build`).
  quote do:
    flag storeRoot is string, format = equals,
      help = "The store root (default: `$REPRO_STORE_ROOT`, else the " &
        "per-user store)"
    flag actionCacheRoot is string, format = equals,
      env = "REPROBUILD_ACTION_CACHE_ROOT",
      help = "The action-cache root (default: " &
        "`$REPROBUILD_ACTION_CACHE_ROOT`, else the store's)"

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
    flag selection is string, format = equals,
      help = "Carry only this project, variant, repository set or " &
        "repository of the workspace, as `repro bundle create` does"
    flag workspaceRoot is string, format = equals,
      help = "The workspace `--selection` is resolved in (default: the " &
        "one enclosing the current directory)"

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

proc hostIdentityFlag(): NimNode {.compileTime.} =
  ## `--host`, the host identity a machine command acts as. An `Option`,
  ## because `--host=` (given, empty) is refused by the resolver rather
  ## than read as "no flag".
  quote do:
    flag host is Option[string],
      help = "The host identity to act as (default: `$REPRO_HOST`, else " &
        "the lower-cased OS host name; `--host` that `$REPRO_HOST` " &
        "contradicts is refused)"

proc homePackageEditFlags(): NimNode {.compileTime.} =
  ## What `repro home add` and `repro home remove` share: where the
  ## reference is written, its guard, and whether apply follows.
  quote do:
    flag data is string,
      help = "Edit a row of this data file (one the profile's `data:` " &
        "section declares) instead of the profile"
    flag whenPredicate is string, perSource = [cli = "when"],
      help = "Guard the reference with a runtime predicate (`when`)"
    flag ifPredicate is string, perSource = [cli = "if"],
      help = "Guard the reference with a compile-time predicate (`if`); " &
        "give one of --when and --if"
    boolFlag noApply is bool,
      help = "Edit the profile only; do not apply afterwards"

proc homeTargetPlatformFlags(): NimNode {.compileTime.} =
  ## The platform a remote target or a plan for another machine is
  ## resolved for.
  quote do:
    flag targetPlatform is string,
      help = "The target's platform: linux, macos, windows or bsd"
    flag targetArch is string,
      help = "The target's architecture: x86_64, arm64 or arm32"

proc homeRemoteTargetFlags(): NimNode {.compileTime.} =
  ## How `repro home enable|disable --host NAME --now` reaches and applies
  ## to another machine over SSH.
  let platform = homeTargetPlatformFlags()
  quote do:
    flag host is Option[string],
      help = "The `hosts:` entry to edit (default: this machine); with " &
        "--now, the host to apply to over SSH"
    boolFlag now is bool,
      help = "With --host naming another machine, apply there right away"
    boolFlag noApply is bool,
      help = "Edit the profile only; do not apply afterwards"
    flag remoteRepro is string, default = "repro",
      help = "The `repro` the target runs"
    flag targetStoreRoot is string, help = "The target's store root"
    flag targetStoreDaemon is string, values = ["dev"],
      help = "The target's store daemon profile (only `dev`)"
    flag targetStoreEndpoint is string,
      help = "The target store daemon's endpoint"
    flag targetStateDir is string, help = "The target's home state directory"
    flag targetHomeDir is string, help = "The target's home directory"
    flag ssh is string, default = "ssh", help = "The ssh program"
    flag port is int, help = "The SSH port"
    flag sshOption is seq[string],
      help = "An option passed to ssh (`-o`); repeat it for several"
    `platform`
    flag targetWsl is Option[bool], optionalValue = some(true),
      help = "Whether the target is a WSL distribution (`--target-wsl` " &
        "alone is true)"

proc homeBundleStoreFlags(): NimNode {.compileTime.} =
  ## The roots the internal bundle-transfer commands work on.
  quote do:
    flag storeRoot is string, help = "The store root"

proc homeRemoteActivateFlags(): NimNode {.compileTime.} =
  ## The target side of a remote home apply, run over SSH as `repro home
  ## __remote-activate` (or its older spelling `repro __remote-activate`).
  quote do:
    flag storeRoot is string, help = "The target's store root (required)"
    flag stateDir is string,
      help = "The target's home state directory (required)"
    flag bundleDigest is string,
      help = "The transferred bundle's digest (or --bundle)"
    flag expectedDigest is string, help = "The digest the bundle must have"
    flag bundle is string, help = "Read the bundle from this file"

proc infraLocationFlags(): NimNode {.compileTime.} =
  ## Where a system command finds its state and profile.
  quote do:
    flag stateDir is string,
      help = "The system state directory (default: the platform's)"
    flag profile is string,
      help = "The system profile (default: the one in the state directory)"

proc infraRegistryFlags(): NimNode {.compileTime.} =
  ## The host a system command acts as, and the home profile whose
  ## `hosts:` registry says who manages its system.
  let host = hostIdentityFlag()
  quote do:
    `host`
    flag homeProfileDir is string,
      help = "The home profile whose `hosts:` registry says who manages " &
        "each host's system (default: the `home.nim` beside the system " &
        "profile)"

proc infraDriftFlags(): NimNode {.compileTime.} =
  ## Acknowledging external drift (`--reconcile-drift` and `--accept-drift`
  ## are one switch at plan time).
  quote do:
    boolFlag acceptDrift is bool,
      help = "Accept the external drift the plan finds"
    boolFlag reconcileDrift is bool,
      help = "Replace drifted resources (at plan time, the same as " &
        "--accept-drift)"

proc systemPlanFlags(): NimNode {.compileTime.} =
  ## The command line of the system-profile planner, which `repro infra
  ## plan` and `repro system plan` both run. One group spliced into both,
  ## so the two spellings cannot accept different flags.
  let location = infraLocationFlags()
  let registry = infraRegistryFlags()
  let drift = infraDriftFlags()
  quote do:
    `location`
    `registry`
    `drift`
    boolFlag json is bool,
      help = "Print the plan as one JSON document (schema " &
        "reprobuild.system.plan.v1)"

proc systemApplyFlags(): NimNode {.compileTime.} =
  ## The command line of the system-profile applier, which `repro infra
  ## apply` and `repro system apply` both run. One group spliced into both,
  ## so the two spellings cannot accept different flags.
  let location = infraLocationFlags()
  let registry = infraRegistryFlags()
  let drift = infraDriftFlags()
  quote do:
    `location`
    `registry`
    `drift`
    flag plan is string,
      help = "The plan id (on an add-on host, the add-on plan id)"
    boolFlag elevate is bool, negatable = true, default = true,
      help = "Run the privileged operations (`--no-elevate` skips them)"
    boolFlag noPreview is bool,
      help = "Compute and apply a fresh plan without a preview"
    boolFlag acceptFeatureDestroy is bool,
      help = "Allow removing Windows optional features"
    boolFlag acceptPasswdDestroy is bool,
      help = "Allow destroying user and group records"
    boolFlag forceUnlock is bool,
      help = "Take the apply lock even when another apply holds it"
    flag keepGenerations is Option[int],
      help = "An add-on host's generation retention: how many to keep"
    flag keepDays is Option[int],
      help = "An add-on host's generation retention: for how many days"
    pos planId is string, required = false,
      help = "The plan id, as an alternative to --plan"

proc addonTargetFlags(): NimNode {.compileTime.} =
  ## The add-on host a profile is compiled for on another machine (`repro
  ## anywhere`, `repro infra image`). Each value is also accepted as
  ## `--flag=VALUE`.
  let host = hostIdentityFlag()
  quote do:
    `host`
    flag profile is string, help = "The system profile (required)"
    flag addonBinary is string, help = "The add-on binary (required)"
    flag addonSha256 is string,
      help = "The add-on binary's expected SHA-256 (required)"
    flag homeProfileDir is string,
      help = "A home-profile directory whose `hosts:` registry is read"

proc cargoTargetDirFlags(): NimNode {.compileTime.} =
  ## The target directory and live-set count `repro cargo gc` and
  ## `record-live` share.
  quote do:
    flag targetDir is string,
      help = "The target directory (default: `$CARGO_TARGET_DIR`, else " &
        "`./target`; with a split `build.build-dir`, the build directory)"
    flag keepSets is string,
      help = "How many recent live sets protect their units (N >= 1; " &
        "default 3, also `$REPRO_CARGO_GC_KEEP_SETS` and `keep_sets` under " &
        "`[cargo_gc]` in the configuration file)"

# ---- Group 6 (workspaces and publication) -----------------------------------

proc workspaceRootFlag(): NimNode {.compileTime.} =
  ## The workspace a workspace command acts on.
  quote do:
    flag workspaceRoot is string,
      help = "The workspace root (default: found from the current directory)"

proc workspaceToolProvisioningFlag(): NimNode {.compileTime.} =
  ## How a workspace command provisions the tools it runs (git, nix). Every
  ## spelling `parseToolProvisioning` accepts, as for `repro build`.
  quote do:
    flag toolProvisioning is string, values = ["path", "nix", "tarball",
        "scoop", "from-source", "fromSource", "source"],
      help = "How the tools the command runs are provisioned (default: " &
        "`path`)"

proc workspaceReportFlags(): NimNode {.compileTime.} =
  ## The report surface of the workspace verbs: `--json` prints the report on
  ## stdout and never touches disk; `--write-report` persists it.
  quote do:
    boolFlag json is bool,
      help = "Print the report as one JSON document on stdout"
    flag writeReport is Option[string], optionalValue = some(""),
      help = "Persist the report: bare, as " &
        "`<workspace>/.repro/build/reports/<verb>-report.json`; with " &
        "`=PATH`, at exactly PATH"
    boolFlag noWriteReport is bool,
      help = "Write no report file, not even the one a failed run leaves"

proc writeReportFlags(): NimNode {.compileTime.} =
  ## `--write-report[=PATH]` and `--no-write-report` without `--json`.
  quote do:
    flag writeReport is Option[string], optionalValue = some(""),
      help = "Persist the report: bare, as " &
        "`<workspace>/.repro/build/reports/<verb>-report.json`; with " &
        "`=PATH`, at exactly PATH"
    boolFlag noWriteReport is bool,
      help = "Write no report file, not even the one a failed run leaves"

proc cloneObjectsFlag(): NimNode {.compileTime.} =
  ## Where a clone keeps its git objects.
  quote do:
    flag cloneObjects is string,
      help = "Where new clones keep their objects: `shared` (the default " &
        "shared clone pool), `private=<dir>`, or `none` (also spelt " &
        "`dissociate`)"

proc branchRoleShorthandFlags(): NimNode {.compileTime.} =
  ## The six built-in branch roles' shorthands: each means exactly
  ## `--to=<role>` (on `repro branch`, `--from=<role>`).
  quote do:
    boolFlag mainline is bool, help = "Shorthand for the `mainline` role"
    boolFlag unstable is bool, help = "Shorthand for the `unstable` role"
    boolFlag staging is bool, help = "Shorthand for the `staging` role"
    boolFlag stable is bool, help = "Shorthand for the `stable` role"
    boolFlag production is bool, help = "Shorthand for the `production` role"
    boolFlag lts is bool, help = "Shorthand for the `lts` role"

proc branchRoleToFlags(): NimNode {.compileTime.} =
  ## `--to=<role>` and the shorthands (`sync`, `switch`, `branch-roles`).
  ## A list, so naming two different roles is refused rather than resolved
  ## by position.
  let shorthands = branchRoleShorthandFlags()
  quote do:
    flag toRole is seq[string], perSource = [cli = "to"],
      help = "The branch role whose branch each repo is reconciled with " &
        "(a built-in role, or a custom role the workspace declares under " &
        "`[branch-roles.<name>]`); an undeclared built-in role falls back " &
        "toward the mainline"
    `shorthands`

proc repoSelectionFlags(): NimNode {.compileTime.} =
  ## The repo-name selectors every workspace sweep shares (`sync`,
  ## `workspace branch-roles`).
  quote do:
    flag only is seq[string], separator = ",",
      help = "Only the named repos (exact names; repeat it or give a " &
        "comma-separated list)"
    flag exceptRepos is seq[string], separator = ",",
      perSource = [cli = "except"],
      help = "Drop the named repos (exclusion wins over inclusion)"
    flag filter is seq[string],
      help = "Only the repos whose name matches the glob (one glob)"
    flag tags is seq[string], separator = ",",
      help = "Only the repos carrying one of the tags; a tag written " &
        "`-<tag>` excludes the repos carrying it"

proc syncFlags(): NimNode {.compileTime.} =
  ## `repro sync` and `repro workspace sync`, which are one command.
  let root = workspaceRootFlag()
  let tools = workspaceToolProvisioningFlag()
  let report = workspaceReportFlags()
  let clone = cloneObjectsFlag()
  let selection = repoSelectionFlags()
  let roles = branchRoleToFlags()
  quote do:
    `root`
    `tools`
    `clone`
    `selection`
    `roles`
    boolFlag rebase is bool,
      help = "With a role: integrate a diverged branch by rebasing it"
    boolFlag merge is bool,
      help = "With a role: integrate a diverged branch by merging"
    boolFlag rebaseOnForcePush is bool, negatable = true,
      help = "Replay local commits onto an upstream whose history was " &
        "rewritten"
    boolFlag forceSync is bool,
      help = "Overwrite divergent or dirty checkouts with their declared " &
        "revision (asks first)"
    boolFlag yes is bool, alias = "--force",
      help = "Skip the --force-sync confirmation"
    flag jobs is Option[int], short = 'j',
      help = "Default parallelism of the fetch and checkout phases"
    flag jobsNetwork is Option[int],
      help = "Parallel fetches (default 8)"
    flag jobsCheckout is Option[int],
      help = "Parallel checkouts (default: the number of processors)"
    boolFlag noInterleaved is bool,
      help = "Finish every fetch before the first checkout (the only " &
        "phase model; accepted as an explicit request)"
    boolFlag failFast is bool,
      help = "Stop at the first failed fetch (accepted; runs continue and " &
        "report)"
    boolFlag dryRun is bool,
      help = "Print the plan and exit 0, changing nothing (nothing is " &
        "fetched, so a role is planned against the current remote-tracking " &
        "refs)"
    boolFlag verbose is bool, short = 'v',
      help = "Include each repo's raw tool output"
    flag progress is string,
      help = "How progress is shown (the values `repro build --progress` " &
        "takes)"
    `report`
    pos projects is seq[string], required = false,
      help = "Scope the sync to these projects' repos (a project, variant " &
        "or repo-set name)"

proc pullFlags(): NimNode {.compileTime.} =
  ## `repro pull` and `repro workspace pull`.
  let root = workspaceRootFlag()
  let tools = workspaceToolProvisioningFlag()
  let report = writeReportFlags()
  let clone = cloneObjectsFlag()
  quote do:
    `root`
    `tools`
    `clone`
    boolFlag force is bool,
      help = "Also converge a repo whose branch would lose commits no " &
        "remote carries"
    `report`
    pos project is string, required = false,
      help = "The project to converge (default: the workspace's)"

proc switchFlags(): NimNode {.compileTime.} =
  ## `repro switch` and `repro workspace switch`.
  let root = workspaceRootFlag()
  let tools = workspaceToolProvisioningFlag()
  let report = workspaceReportFlags()
  let roles = branchRoleToFlags()
  quote do:
    `root`
    `tools`
    boolFlag newBranch is bool, short = 'b',
      help = "Create the branch in every repo, then switch to it"
    `roles`
    boolFlag fetch is bool, help = "Fetch before switching (the default)"
    boolFlag noFetch is bool,
      help = "Do not fetch: classify against local refs only"
    boolFlag yes is bool, alias = "--force",
      help = "Skip the confirmation"
    `report`
    pos branch is string, required = false,
      help = "The branch to switch to (or a role, through --to or a " &
        "shorthand)"

proc branchFlags(): NimNode {.compileTime.} =
  ## `repro branch` and `repro workspace new`: fork a sibling workspace.
  ##
  ## Both spellings refuse the retired `--from-mainlines` and name what
  ## replaced it, so the note does not depend on which name was typed.
  let root = workspaceRootFlag()
  let tools = workspaceToolProvisioningFlag()
  let report = workspaceReportFlags()
  let clone = cloneObjectsFlag()
  let shorthands = branchRoleShorthandFlags()
  quote do:
    retired "--from-mainlines",
      replacement = "`--from=mainline`, or its shorthand `--mainline`"
    `root`
    `tools`
    `clone`
    flag branch is string,
      help = "The branch name (default: the destination's last path " &
        "component)"
    boolFlag existingBranch is bool,
      help = "Check out a branch that already exists instead of creating one"
    flag fromRole is seq[string], perSource = [cli = "from"],
      help = "Cut the new branch in each repo from the branch this role " &
        "resolves to"
    `shorthands`
    boolFlag fetch is bool,
      help = "With a role: refresh the role branches first (the default)"
    boolFlag noFetch is bool,
      help = "With a role: cut from the role branches as last fetched"
    boolFlag includeChanges is bool,
      help = "Carry the source workspace's uncommitted changes over"
    flag unpublished is string,
      help = "What to do with repos whose commits no remote carries: " &
        "`refuse` (the default), `carry` or `declared`"
    flag projects is seq[string], separator = ",",
      help = "Fork only these projects (repeat it or give a " &
        "comma-separated list)"
    `report`
    pos path is string, required = false,
      help = "Where to create the new workspace (its last component names " &
        "the branch)"

proc hooksActionFlags(): NimNode {.compileTime.} =
  ## `repro hooks ensure|reinstall|uninstall`: which hooks, and where. With
  ## no selector both `--vcs` and `--shell-direnv` are implied.
  let root = workspaceRootFlag()
  let report = workspaceReportFlags()
  quote do:
    boolFlag vcs is bool,
      help = "The managed git hooks of every workspace repo (or of the " &
        "repo at PATH)"
    boolFlag recordStore is bool,
      help = "Register PATH as a git-checkout record store; implies --vcs"
    boolFlag reAnchor is bool,
      help = "With `ensure --vcs`: also replace managed hooks that demand a " &
        "contract this build does not generate (plain `ensure` leaves " &
        "them untouched and exits non-zero). Reconcile what supplies " &
        "repro first"
    boolFlag shellDirenv is bool,
      help = "The direnv `.envrc` activation block"
    boolFlag shellAutocomplete is bool,
      help = "Shell completion scripts (not implemented yet)"
    flag shell is seq[string],
      help = "A native shell activation hook: bash, zsh, fish or pwsh " &
        "(repeat it for several)"
    `root`
    `report`
    pos path is string, required = false,
      help = "The repository or directory (default: the current one)"

proc membershipSetFlags(): NimNode {.compileTime.} =
  ## `repro workspace sets|projects` (the retained spelling): list, resolve,
  ## define and delete repo-sets. Bare, the namespace lists them.
  proc listFlags(): NimNode =
    let root = workspaceRootFlag()
    quote do:
      `root`
      boolFlag enabled is bool, help = "Only the sets enabled here"
      boolFlag disabled is bool, help = "Only the sets not enabled here"
      boolFlag all is bool, help = "Every defined set (the default)"
      boolFlag json is bool, help = "Print the list as JSON"
  let callList = listFlags()
  let list = listFlags()
  let resolveRoot = workspaceRootFlag()
  let addRoot = workspaceRootFlag()
  let removeRoot = workspaceRootFlag()
  quote do:
    call:
      `callList`
    subcmd "list", help = "Every defined repo-set, marked enabled or " &
        "disabled here":
      `list`
    subcmd "resolve", help = "The repos a workspace enabling exactly these " &
        "sets would participate in (read-only)":
      `resolveRoot`
      flag at is Option[string], format = equals,
        help = "Resolve from this commit of the manifest repository instead " &
          "of its working tree"
      boolFlag json is bool, help = "Print the resolution as JSON"
      pos names is seq[string], required = false, help = "The sets"
    subcmd "add", help = "Define a new set in the manifest repository " &
        "(to activate an existing one, use `repro workspace enable`)":
      `addRoot`
      flag message is string, short = 'm',
        help = "The set's description, written beside it"
      flag templateName is string, format = equals,
        perSource = [cli = "template"],
        help = "Scaffold from `templates/<NAME>.toml` (default: the host " &
          "configuration's `[projects] default_template`)"
      boolFlag noTemplate is bool,
        help = "Write the empty stub, ignoring a default template"
      pos name is string, required = false, help = "The new set's name"
    subcmd "remove", help = "Delete a set's definition (disable it here " &
        "first)":
      `removeRoot`
      boolFlag pruneOrphanRepos is bool,
        help = "Also delete the repo fragments no other set names"
      pos name is string, required = false, help = "The set's name"
    subcmd "help", visibility = hidden:
      pos topic is seq[string], required = false

proc workspaceReposFlags(): NimNode {.compileTime.} =
  ## `repro workspace repos`: list, declare and delete repo fragments.
  proc listFlags(): NimNode =
    let root = workspaceRootFlag()
    quote do:
      `root`
      flag set is seq[string], format = equals,
        help = "Only the repos of this set"
      flag project is seq[string], format = equals,
        help = "The retained spelling of --set"
      boolFlag enabled is bool, help = "Only the repos of enabled sets"
      boolFlag disabled is bool, help = "Only the repos of no enabled set"
      boolFlag all is bool, help = "Every declared repo (the default)"
      boolFlag json is bool, help = "Print the list as JSON"
  let callList = listFlags()
  let list = listFlags()
  let addRoot = workspaceRootFlag()
  let removeRoot = workspaceRootFlag()
  quote do:
    call:
      `callList`
    subcmd "list", help = "The declared repos":
      `list`
    subcmd "add", help = "Declare a repo and name it in a set":
      `addRoot`
      flag set is seq[string], format = equals,
        help = "The set to name the repo in (repeatable; default: the " &
          "workspace's primary set)"
      flag project is seq[string], format = equals,
        help = "The retained spelling of --set"
      flag remote is string, format = equals,
        help = "The repo's remote URL (required for a new repo)"
      flag mainline is seq[string], format = equals, alias = "--branch",
        help = "The repo's mainline (required for a new repo unless its " &
          "profile supplies one)"
      flag profile is string, format = equals,
        help = "The branch-role profile the repo follows"
      flag revision is string, format = equals,
        help = "An exact commit the fragment sits at"
      flag path is string, format = equals,
        help = "The checkout directory (default: the repo's name)"
      flag message is string, short = 'm',
        help = "The repo's description, written beside its fragment"
      pos repo is string, required = false, help = "The repo's name"
    subcmd "remove", help = "Stop naming a repo in a set":
      `removeRoot`
      flag set is seq[string], format = equals,
        help = "The set to drop the repo from (default: every set naming it)"
      flag project is seq[string], format = equals,
        help = "The retained spelling of --set"
      boolFlag deleteFragment is bool,
        help = "Also delete the repo's fragment"
      pos repo is string, required = false, help = "The repo's name"
    subcmd "help", visibility = hidden:
      pos topic is seq[string], required = false

proc workspaceRepoAddFlags(): NimNode {.compileTime.} =
  ## The workspace-repository flags of `repro workspace add` (`repro ws
  ## add`): the develop-or-binary policy, its overrides and the clone. The
  ## same declarations are spliced, hidden, into top-level `repro add`,
  ## which refuses them and names the `repro ws add` command line that
  ## carries them (`refusedFlags`), so the two flag sets cannot drift.
  ## `--remote`, `--revision` and `--depends-of` are optional values, so a
  ## refusal sees them even when given empty (`--remote=`).
  let root = workspaceRootFlag()
  let tools = workspaceToolProvisioningFlag()
  quote do:
    `root`
    flag remote is Option[string],
      help = "The repo's fetch URL (required: the develop-or-binary " &
        "policy classifies its origin)"
    flag revision is Option[string], help = "The revision to pin"
    flag dependsOf is Option[string],
      help = "Refused: a repo's dependencies are declared in its repro.nim"
    `tools`
    boolFlag develop is bool,
      help = "Check it out for development, whatever the policy says"
    boolFlag binary is bool, alias = "--no-develop",
      help = "Use it as a binary dependency, whatever the policy says"
    boolFlag noMembership is bool,
      help = "Clone it without adding it to the workspace's membership"
    boolFlag json is bool, help = "Print the report as JSON"

proc workspaceRepoRemoveFlags(): NimNode {.compileTime.} =
  ## The workspace-repository flags of `repro workspace remove` (`repro ws
  ## remove`), spliced hidden into top-level `repro remove` the same way.
  let root = workspaceRootFlag()
  let tools = workspaceToolProvisioningFlag()
  quote do:
    `root`
    `tools`
    boolFlag force is bool, alias = "--yes",
      help = "Remove it even when that loses work no remote carries"
    boolFlag json is bool, help = "Print the report as JSON"

proc refusedFlags(flags: NimNode): NimNode {.compileTime.} =
  ## ``flags`` with every flag declared ``visibility = hidden``: accepted by
  ## the parser, so the command can refuse it with a tip naming the command
  ## that takes it, and listed nowhere.
  result = flags.copyNimTree()
  proc mark(n: NimNode) =
    for i in 0 ..< n.len:
      let stmt = n[i]
      if stmt.kind == nnkStmtList:
        mark(stmt)
      elif stmt.kind in {nnkCommand, nnkCall} and stmt.len >= 2 and
          (stmt[0].eqIdent("flag") or stmt[0].eqIdent("boolFlag")):
        stmt.add(nnkExprEqExpr.newTree(ident("visibility"), ident("hidden")))
  mark(result)

proc workspaceSubcommands(syncWs, pullWs, switchWs, branchWs: NimNode): NimNode
    {.compileTime.} =
  ## Every subcommand of `repro workspace` (`repro ws`).
  let initRoot = workspaceRootFlag()
  let initTools = workspaceToolProvisioningFlag()
  let initReport = workspaceReportFlags()
  let initClone = cloneObjectsFlag()
  let enableRoot = workspaceRootFlag()
  let enableClone = cloneObjectsFlag()
  let disableRoot = workspaceRootFlag()
  let sets = membershipSetFlags()
  let projects = membershipSetFlags()
  let repos = workspaceReposFlags()
  let wsAddFlags = workspaceRepoAddFlags()
  let wsRemoveFlags = workspaceRepoRemoveFlags()
  let statusRoot = workspaceRootFlag()
  let statusTools = workspaceToolProvisioningFlag()
  let statusReport = workspaceReportFlags()
  let lockRoot = workspaceRootFlag()
  let lockTools = workspaceToolProvisioningFlag()
  let lockReport = writeReportFlags()
  let listRoot = workspaceRootFlag()
  let listReport = workspaceReportFlags()
  let manifestsRoot = workspaceRootFlag()
  let manifestsReport = workspaceReportFlags()
  let branchRolesRoot = workspaceRootFlag()
  let branchRolesRoles = branchRoleToFlags()
  let branchRolesSelection = repoSelectionFlags()
  let forallRoot = workspaceRootFlag()
  let forallReport = workspaceReportFlags()
  let sharedClonesRoot = workspaceRootFlag()
  let sharedClonesReport = workspaceReportFlags()
  let migrateRoot = workspaceRootFlag()
  let migrateReport = workspaceReportFlags()
  let migrateLocksRoot = workspaceRootFlag()
  let migrateLocksTools = workspaceToolProvisioningFlag()
  let publishEvidenceRoot = workspaceRootFlag()
  let publishEvidenceTools = workspaceToolProvisioningFlag()
  let bootstrapRoot = workspaceRootFlag()
  quote do:
    subcmd "restore", help = "Materialize project sets at recorded pins " &
        "into a new directory":
      flag projects is string, format = equals,
        help = "The project sets to restore (comma-separated; required)"
      flag at is string, format = equals,
        help = "The workspace-metadata revision to read the sets from"
      flag record is string, format = equals,
        help = "The lock record to restore (`PATH` or " &
          "`PROJECT/REPO@SHA`)"
      flag snapshot is string, format = equals,
        help = "The named snapshot to restore"
      flag recordStore is string, format = equals,
        help = "Where the lock records are read from"
      flag recordStoreAt is string, format = equals,
        help = "The record store's revision"
      pos source is string, required = false,
        help = "The workspace to restore from"
      pos destination is string, required = false,
        help = "The new directory"
    subcmd "init", help = "Join a workspace: from a URL into a new " &
        "directory, or materialize a project in this one":
      `initRoot`
      `initTools`
      `initClone`
      boolFlag allowMissingLayers is bool,
        help = "Drop a manifest layer that cannot be fetched instead of " &
          "failing"
      flag manifestUrl is string, help = "The manifest repository's URL"
      flag manifestBranch is string,
        help = "The manifest repository's branch"
      flag privateManifestUrl is string,
        help = "A private companion manifest repository's URL"
      boolFlag printResolvedUrl is bool,
        help = "Print the workspace URL a `<url>` resolves to and exit " &
          "(clones nothing)"
      `initReport`
      pos target is string, required = false,
        help = "A workspace URL (`host:org`, an org name or a full URL) " &
          "for a new directory, or a project to materialize here " &
          "(default: the host configuration's `[projects] default`)"
      pos localPath is string, required = false,
        help = "With a URL: the new directory (default: the org's name)"
    subcmd "bootstrap", help = "Write the bootstrap scripts of a new host " &
        "into a directory":
      call:
        `bootstrapRoot`
        pos dir is string, required = false,
          help = "The directory (default: the current one)"
      subcmd "help", visibility = hidden:
        pos topic is seq[string], required = false
    subcmd "enable", help = "Activate defined projects in this workspace " &
        "and check out their repos":
      `enableRoot`
      boolFlag useDefault is bool, perSource = [cli = "default"],
        help = "Enable the default projects (`$REPRO_DEFAULT_PROJECTS`, " &
          "else the host configuration's `[projects] default`)"
      boolFlag noSync is bool, help = "Record membership only; check " &
        "nothing out"
      boolFlag dryRun is bool,
        help = "Print the resulting set and the checkout plan; change nothing"
      `enableClone`
      flag jobs is Option[int], format = equals,
        help = "Default parallelism of the checkout's fetch and checkout"
      flag jobsNetwork is Option[int], format = equals,
        help = "Parallel fetches"
      flag jobsCheckout is Option[int], format = equals,
        help = "Parallel checkouts"
      flag tags is seq[string], separator = ",", format = equals,
        help = "Check out only the repos carrying one of the tags " &
          "(`-<tag>` excludes)"
      boolFlag json is bool, help = "Print the checkout's report as JSON"
      boolFlag verbose is bool, help = "Include each repo's raw tool output"
      flag writeReport is Option[string], optionalValue = some(""),
        help = "Persist the checkout's report (bare: under " &
          "`.repro/build/reports/`; `=PATH`: at PATH)"
      pos projects is seq[string], required = false,
        help = "The projects to enable"
    subcmd "disable", help = "Deactivate projects and remove the checkouts " &
        "only they declared":
      `disableRoot`
      boolFlag keepCheckouts is bool, help = "Leave every checkout in place"
      boolFlag force is bool,
        help = "Remove checkouts even with work no remote carries"
      pos projects is seq[string], required = false,
        help = "The projects to disable"
    subcmd "sets", help = "List, resolve, define and delete repo-sets":
      `sets`
    subcmd "projects", visibility = hidden,
        help = "The retained spelling of `repro workspace sets`":
      `projects`
    subcmd "repos", help = "List, declare and delete repos":
      `repos`
    subcmd "add", help = "Bring a repository into the workspace: a " &
        "develop-mode checkout or a binary dependency, as the policy says":
      `wsAddFlags`
      boolFlag dryRun is bool, help = "Print what would change"
      pos repo is string, required = false, help = "The repo's name"
    subcmd "remove", help = "Remove a repository from the workspace and " &
        "collect the checkouts nothing else needs":
      `wsRemoveFlags`
      boolFlag dryRun is bool, help = "Print what would change"
      pos repo is string, required = false, help = "The repo's name"
    subcmd "status", help = "Each repo's branch, cleanliness and " &
        "divergence":
      `statusRoot`
      `statusTools`
      boolFlag stashes is bool, help = "Report stashes"
      boolFlag files is bool, help = "Report changed files"
      boolFlag aheadBehind is bool, help = "Report ahead/behind counts"
      boolFlag unmerged is bool, help = "Report unmerged branches"
      boolFlag fileDetails is bool, help = "List each changed file"
      boolFlag fix is bool, help = "Repair what can be repaired safely"
      `statusReport`
      pos project is string, required = false,
        help = "The project (default: the workspace's)"
    subcmd "lock", help = "Create or refresh the workspace's lock record":
      `lockRoot`
      flag recordStoreRoot is string,
        help = "The record store the lock is written to"
      flag sha is string, visibility = internal,
        help = "The commit that triggered the lock"
      flag triggerRepo is string, visibility = internal,
        help = "The repository whose commit triggered the lock"
      `lockTools`
      `lockReport`
      pos project is string, required = false,
        help = "The project (default: the workspace's)"
    subcmd "list", help = "The workspace's repos and where they stand":
      `listRoot`
      `listReport`
      pos project is string, required = false,
        help = "The project (default: the workspace's)"
    subcmd "manifests", help = "The manifest layers and their revisions":
      `manifestsRoot`
      `manifestsReport`
    subcmd "branch-roles", help = "The branch each branch role resolves to " &
        "in every repo (fetches and changes nothing)":
      `branchRolesRoot`
      `branchRolesRoles`
      `branchRolesSelection`
      boolFlag json is bool, help = "Print one JSON document on stdout"
      pos projects is seq[string], required = false,
        help = "Scope the list to these projects' repos"
    subcmd "forall", help = "Run a shell command in every repo":
      flag command is string, short = 'c', help = "The command (required)"
      `forallRoot`
      boolFlag failFast is bool, help = "Stop at the first failure"
      boolFlag keepGoing is bool,
        help = "Run in every repo whatever fails (the default)"
      boolFlag ignoreErrors is bool, help = "The same as --keep-going"
      boolFlag quiet is bool, help = "Print only failures"
      `forallReport`
      pos project is string, required = false,
        help = "The project (default: the workspace's)"
    subcmd "shared-clones", help = "Inspect and maintain the shared clone " &
        "pool":
      `sharedClonesRoot`
      boolFlag force is bool, help = "With gc: run whatever the budget says"
      `sharedClonesReport`
      pos verb is string, required = false,
        help = "list (the default), rewire, consolidate, root, gc (also " &
          "spelt maintenance) or migrate"
      pos project is string, required = false,
        help = "The project (default: the workspace's)"
    subcmd "sync", help = "Fast-forward the workspace's repositories " &
        "toward a target (`repro sync`)":
      `syncWs`
    subcmd "pull", help = "Converge the workspace onto its declared " &
        "revisions (`repro pull`)":
      `pullWs`
    subcmd "new", help = "Fork a new sibling workspace on a new branch " &
        "(`repro branch <path>`)":
      `branchWs`
    subcmd "switch", help = "Switch the workspace to a branch " &
        "(`repro switch`)":
      `switchWs`
    subcmd "provision", help = "Provision a Windows host's toolchain":
      call:
        flag installRoot is string, format = equals,
          help = "Where the toolchain is installed"
        flag arch is string, format = equals,
          help = "The architecture to provision"
      subcmd "help", visibility = hidden:
        pos topic is seq[string], required = false
    subcmd "migrate", help = "Move a workspace from the `.repo/` layout " &
        "onto the native one":
      `migrateRoot`
      boolFlag dryRun is bool, help = "Print what would change"
      `migrateReport`
    subcmd "migrate-locks", help = "Move lock records into the record store":
      `migrateLocksRoot`
      flag recordStoreRoot is string, help = "The record store"
      `migrateLocksTools`
      boolFlag apply is bool, help = "Make the changes"
      boolFlag dryRun is bool, help = "Print what would change (the default)"
    subcmd "publish-evidence", help = "Publish the evidence-only repos' " &
        "records":
      `publishEvidenceRoot`
      flag project is string, help = "The project (default: the workspace's)"
      `publishEvidenceTools`
      pos projectName is string, required = false,
        help = "The project, as a positional"

proc developSelectionFlags(): NimNode {.compileTime.} =
  ## The develop-set selection `repro develop` and the three `repro flake`
  ## verbs share. Which repos: a mode (`--all`, the default, `--direct`,
  ## `--indirect` or `--transitive-of`), narrowed by `--project`, `--tag`,
  ## `--filter`, `--only` and `--except` in that fixed order. Which lock
  ## records: `--tier`, `--at`, `--lock-store` and `--strict`.
  ##
  ## A name list may be repeated and each value may be comma-separated; the
  ## command splits it, trimming the names and dropping empty ones.
  ## `--transitive-of`, `--filter` and `--at` take one value: they are lists
  ## so that two different values are refused by the command rather than
  ## resolved by their position.
  quote do:
    boolFlag all is bool,
      help = "Select every dependency of the lock set (the default mode)"
    boolFlag direct is bool,
      help = "Select only the root repo's direct dependencies"
    boolFlag indirect is bool,
      help = "Select the dependencies that are not direct ones"
    flag transitiveOf is seq[string],
      help = "Select the transitive closure below this dependency"
    flag project is seq[string],
      help = "Keep only the repos these projects contribute " &
        "(comma-separated)"
    flag tag is seq[string],
      help = "Keep only the repos carrying these manifest tags " &
        "(comma-separated)"
    flag filter is seq[string],
      help = "Keep only the repos whose name matches the glob (one glob)"
    flag only is seq[string],
      help = "Keep only these repos (exact names, comma-separated)"
    flag exceptNames is seq[string], perSource = [cli = "except"],
      help = "Drop these repos (exact names, comma-separated)"
    flag tier is seq[string],
      help = "Read only these tiers' lock records: `public`, `org`, " &
        "`team`, `personal` (comma-separated)"
    flag at is seq[string],
      help = "Key commit-addressed lock records on this revision instead " &
        "of the root repo's HEAD"
    flag lockStore is seq[string],
      help = "An extra lock backend for this run, " &
        "`[<tier>:]<kind>:<location>` (repeatable; a later one takes " &
        "precedence)"
    boolFlag strict is bool,
      help = "Refuse when any lock backend is unreadable, the personal " &
        "tier's included"

proc flakeVerbFlags(): NimNode {.compileTime.} =
  ## The flags every `repro flake` verb takes: the develop set whose
  ## checkouts the flake's inputs follow, the flake, and the workspace.
  let selection = developSelectionFlags()
  let tools = workspaceToolProvisioningFlag()
  quote do:
    `selection`
    flag flake is string,
      help = "The directory holding `flake.nix` (default: the current " &
        "directory)"
    flag stripSuffix is Option[string],
      help = "Input-name suffixes removed before an input is matched with " &
        "a repo (comma-separated; default: the built-in list)"
    flag workspaceRoot is string,
      help = "The workspace (default: found from the current directory)"
    `tools`
    boolFlag json is bool, help = "Print the result as JSON"

proc daemonModeFlag(what: string): NimNode {.compileTime.} =
  ## `--daemon`, over `$REPRO_DAEMON`: whether `what` (a build, or a watch)
  ## runs in the per-user daemon. `repro build` (and every command that takes
  ## its command line) and `repro watch` declare it.
  let help = newLit("Whether the " & what & " runs in the per-user " &
    "daemon: `auto` (use it, falling back to an in-process " & what &
    "), `require` or `off`; the flag wins over `$REPRO_DAEMON` (default: " &
    "auto)")
  quote do:
    flag daemon is string, values = ["auto", "require", "off"],
      env = "REPRO_DAEMON", clientSide = true, help = `help`

proc buildToolProvisioningFlag(): NimNode {.compileTime.} =
  ## `--tool-provisioning`, over `$REPRO_TOOL_PROVISIONING`, of the commands
  ## that build: `repro build` (and every command that takes its command
  ## line) and `repro watch`.
  quote do:
    flag toolProvisioning is string, values = ["path", "nix", "tarball",
        "scoop", "from-source", "fromSource", "source"],
      env = "REPRO_TOOL_PROVISIONING",
      help = "How the build's tools are provisioned (`from-source` is also " &
        "spelt `fromSource` or `source`); the flag wins over " &
        "`$REPRO_TOOL_PROVISIONING` (default: the project's " &
        "`defaultToolProvisioning`)"

proc buildWorkRootFlag(): NimNode {.compileTime.} =
  ## `--work-root` of the commands that build: the flag wins over
  ## `$REPROBUILD_WORK_ROOT`, which it declares.
  quote do:
    flag workRoot is string, env = "REPROBUILD_WORK_ROOT",
      help = "The work root the project's build state lives under " &
        "(default: `$REPROBUILD_WORK_ROOT`, else the project's `.repro/`)"

proc measurementFlags(): NimNode {.compileTime.} =
  ## The collect and present axes of the measurement flags, each over its
  ## variable, of the commands that build. Where the value came from matters
  ## to `--measure`: the flag starts from the empty set, the variable adds to
  ## the default set.
  quote do:
    flag measure is seq[string], env = "REPROBUILD_MEASURE",
      help = "What the build collects: trace, cache-evidence, timing, all " &
        "or none, comma-separated (repeatable, additive; `none` clears). " &
        "The flag replaces `$REPROBUILD_MEASURE`, which adds to the " &
        "default set (default: trace,cache-evidence)"
    flag show is seq[string], env = "REPROBUILD_SHOW",
      help = "What the build prints of what it collected, in `--measure`'s " &
        "vocabulary (implies measuring it); the flag wins over " &
        "`$REPROBUILD_SHOW` (default: none)"

proc buildReportFlags(): NimNode {.compileTime.} =
  ## The persist axis: the build report of the commands that build.
  quote do:
    flag writeReport is Option[string], optionalValue = some(""),
      help = "Write the build report: bare, as " &
        "`<outDir>/build-report.json`; with `=PATH`, at exactly PATH"
    boolFlag noWriteReport is bool,
      help = "Write no report file, not even the one a failed build leaves"

proc buildStatsFlags(): NimNode {.compileTime.} =
  ## The analytics-store capture of the commands that build.
  quote do:
    flag writeStats is Option[string], optionalValue = some(""),
      clientSide = true,
      help = "Capture the build's statistics in the analytics store: bare, " &
        "the conventional store; with `=PATH`, that store (daemon-hosted " &
        "builds only)"
    flag statsGroups is Option[string], format = equals, clientSide = true,
      help = "Which statistics groups to capture: timing, cache, runquota, " &
        "deps, sessions or all, comma-separated (enables `--write-stats`)"

proc restoreCachedOutputsFlag(): NimNode {.compileTime.} =
  ## `--[no-]restore-cached-outputs`, over `$REPRO_RESTORE_CACHED_OUTPUTS`,
  ## of the commands that build.
  quote do:
    boolFlag restoreCachedOutputs is bool, negatable = true,
      env = "REPRO_RESTORE_CACHED_OUTPUTS",
      help = "Restore the outputs of cache hits into the tree; the flag " &
        "wins over `$REPRO_RESTORE_CACHED_OUTPUTS` (default: off)"

proc buildFlags(): NimNode {.compileTime.} =
  ## The command line of `repro build`, which `repro bench` and `repro lint`
  ## take unchanged (each is `repro build` of its conventional collection).
  ##
  ## `clientSide = true` marks the flags the full CLI processes itself, so
  ## the thin client hands an invocation carrying one over rather than route
  ## it to the daemon (the module header says why each one is there). The
  ## thin client reads them from `build`'s declarations.
  ##
  ## Where a flag has an environment default, the variable is declared on it
  ## and the flag wins over it (`--daemon` over `REPRO_DAEMON`, `--log` over
  ## `REPROBUILD_LOG`, ...). Whether a value came from the flag or the
  ## variable matters in three places, which read it from the origin of the
  ## value: `--measure` adds to the empty set and `REPROBUILD_MEASURE` to the
  ## default set; a quiet `--progress` quiets `--log` and `--show` only when
  ## they were not passed on the command line; and `--runquota` is a request
  ## a dry run's implied bypass must not override. `--work-root` and
  ## `--action-cache-root` declare `REPROBUILD_WORK_ROOT` and
  ## `REPROBUILD_ACTION_CACHE_ROOT`, as every command that builds or
  ## inspects a build graph does.
  ##
  ## A switch that stands for another flag's value (`-v`, `--release`,
  ## `--runquota`, ...) refuses `=false`: written that way it would set
  ## nothing, so it is refused rather than silently ignored.
  let daemon = daemonModeFlag("build")
  let toolProvisioning = buildToolProvisioningFlag()
  let workRoot = buildWorkRootFlag()
  let measurement = measurementFlags()
  let report = buildReportFlags()
  let stats = buildStatsFlags()
  let restore = restoreCachedOutputsFlag()
  quote do:
    `daemon`
    `toolProvisioning`
    flag target is string,
      help = "Build for this platform triple (a short name such as " &
        "`armv7-linux` names the catalog's triple; `native` assigns none): " &
        "the `--variant targetTriple=` assignment, canonicalised"
    flag variant is seq[string],
      help = "Assign a variant, `NAME=VALUE` (repeatable); added to " &
        "`$REPRO_VARIANTS` for the recipe's evaluation"
    boolFlag release is bool, alsoSets = [variant = "buildType=release"],
      refuseFalse = true,
      help = "The same as `--variant buildType=release`"
    boolFlag debug is bool, alsoSets = [variant = "buildType=debug"],
      refuseFalse = true,
      help = "The same as `--variant buildType=debug`"
    `workRoot`
    flag actionCacheRoot is string, env = "REPROBUILD_ACTION_CACHE_ROOT",
      help = "The action-cache root (default: " &
        "`$REPROBUILD_ACTION_CACHE_ROOT`, else the store's)"
    flag lock is seq[string],
      help = "The committed lock: `PATH` binds `default`, `NAME=PATH` a " &
        "named lock file (repeatable; default: the project's `repro.lock`)"
    flag strategy is string,
      help = "Solve a hidden lock under this version strategy (default, " &
        "lowest, highest or lowest-direct) and build from it; the " &
        "committed lock is neither used nor written"
    boolFlag printSolvedGraph is bool, clientSide = true,
      help = "Print the solved graph the build would pin, and build nothing"
    boolFlag listTargets is bool, clientSide = true,
      help = "List the project's targets instead of building"
    boolFlag listTargetsJson is bool, clientSide = true,
      help = "List the project's targets as JSON"
    boolFlag json is bool,
      help = "With `--list-targets`: list them as JSON"
    flag package is string,
      help = "With `--list-targets`: only the targets of this package"
    flag progress is string,
      env = ["REPROBUILD_PROGRESS", "REPRO_PROGRESS"],
      help = "How build progress is shown: quiet (also silent, none, off), " &
        "line (ninja, single-line), bar-line (bar, ninja-bar, auto, " &
        "plain), lines (tup, per-line), lines-bar (tup-bar, " &
        "per-line-bar), dots (dot), simple-dots, simple-lines or " &
        "live-lines; the flag wins over `$REPROBUILD_PROGRESS`, then " &
        "`$REPRO_PROGRESS` (default: bar-line, quiet when " &
        "`$IN_AGENT_SHELL` is set)"
    flag progressBars is string, env = "REPROBUILD_PROGRESS_BARS",
      clientSide = true,
      help = "How progress bars are laid out: overlay (also overlaid, " &
        "single, combined) or split (two, two-bars, separate); the flag " &
        "wins over `$REPROBUILD_PROGRESS_BARS` (default: overlay)"
    boolFlag unicode is bool, negatable = true, env = "REPRO_UNICODE",
      help = "Unicode markers and checkboxes in progress output; the flag " &
        "wins over `$REPRO_UNICODE` (default: ASCII)"
    flag log is string, env = "REPROBUILD_LOG",
      help = "Which status lines the build prints: actions (also " &
        "verbose), summary (normal) or quiet (none, off); the flag wins " &
        "over `$REPROBUILD_LOG` (default: quiet)"
    boolFlag verbose is bool, short = 'v', alsoSets = [log = "summary"],
      refuseFalse = true,
      help = "The same as `--log=summary`"
    boolFlag veryVerbose is bool, alias = "-vv", alsoSets = [log = "actions"],
      refuseFalse = true,
      help = "The same as `--log=actions`"
    flag actionOutput is string,
      help = "Which actions' output is printed: failed (default) or all"
    `measurement`
    `report`
    flag writeDiagnostics is string,
      help = "Write the human-readable diagnostic log to the path"
    flag writeBenchmark is string, clientSide = true,
      help = "Write a benchmark document of the build's phase timings to " &
        "the path (implies `--measure=timing`)"
    `stats`
    boolFlag prepareOnly is bool,
      help = "Prepare the build graph and run no action"
    boolFlag dryRun is bool,
      help = "Plan the build and run no action (implies `--no-runquota` " &
        "unless `--runquota` is passed)"
    boolFlag forceRebuild is bool, alias = "--rebuild",
      help = "Rebuild every action, ignoring the caches"
    boolFlag softRebuild is bool,
      help = "Re-run the actions whose results may differ between runs"
    boolFlag rebuildHostBound is bool,
      help = "Re-run the actions bound to this host"
    boolFlag hardRebuild is bool,
      help = "Re-run every action, discarding its recorded state"
    flag only is seq[string], clientSide = true,
      help = "Scope a rebuild verb to the actions or targets matching the " &
        "pattern (repeatable; `*` and `?` glob, otherwise a substring)"
    flag unsafePreserveOutputs is seq[string],
      help = "Run the matching steps in unsafe preserve-outputs mode " &
        "(repeatable; `--only`'s patterns, `*` for every step)"
    boolFlag noOutputCleanup is bool,
      help = "Leave stale outputs of vanished actions in place"
    boolFlag publishCacheHits is bool,
      help = "Publish cache hits to the shared cache too"
    boolFlag publishMaterialized is bool,
      help = "Publish materialized outputs to the shared cache"
    boolFlag skipCmakeRegeneration is bool,
      help = "Do not regenerate CMake build files"
    `restore`
    boolFlag noRunquota is bool, env = "REPROBUILD_NO_RUNQUOTA",
      refuseFalse = true,
      help = "Bypass RunQuota entirely (the unsafe single-process " &
        "fallback); the flag wins over `$REPROBUILD_NO_RUNQUOTA`. " &
        "`--dry-run` implies it"
    boolFlag runquota is bool, alsoSets = [noRunquota = "false"],
      refuseFalse = true,
      help = "Admit the build's actions through RunQuota even where it " &
        "would be bypassed (`--dry-run`, `$REPROBUILD_NO_RUNQUOTA`); the " &
        "last of `--runquota` and `--no-runquota` wins"
    flag monitorHosting is string, env = "REPROBUILD_MONITOR_HOSTING",
      help = "Where the I/O monitor is hosted: never, where-supported or " &
        "required; the flag wins over `$REPROBUILD_MONITOR_HOSTING` " &
        "(default: never)"
    # DA-1i. THE HAZARD, NOT ONLY THE BEHAVIOUR. An operator choosing
    # `--evidence=reads-only` is accepting a specific, nameable risk, and a
    # risk described only in a specification is not one they were given the
    # chance to accept. The table is narrower than "probes are unsafe" and
    # that is its value, so every copy (this long help, which `repro build
    # --help` prints, and docs/dependency-collection.md) carries the same
    # four rows AND the sentence that row 1 does not cover row 4
    # (`t_da1i_evidence_help_names_the_hazard`).
    flag evidence is string, valueName = "full|reads-only",
      help = "Which dependency evidence the build records: full (default) " &
        "or reads-only",
      longHelp = "`full` records every observation, including lookups " &
        "that found nothing. `reads-only` records only lookups that " &
        "SUCCEEDED (about a third of the records on a real nim c) and is " &
        "NOT merely faster: it weakens \"is this build up to date?\" in " &
        "one direction. Still detected: a recorded file is modified; a " &
        "recorded file is deleted. NOT detected: a file is ADDED that " &
        "shadows one earlier in a search path; a file that exists but " &
        "could not be opened (a permission bit, a directory where a file " &
        "was wanted) becomes openable. Those two are one rule: only " &
        "successful lookups are recorded, so any later change that makes " &
        "an unsuccessful lookup succeed is invisible, and \"a recorded " &
        "file is modified\" does NOT cover the second, because the file " &
        "is not recorded at all. This is ninja's own stale-build failure, " &
        "which is why the mode exists: like-for-like comparison with " &
        "depfile-driven tools, not speed. Artifacts built this way are " &
        "correct and publishable; what degrades is the staleness check. " &
        "Recover with --evidence=full or a clean build.\n" &
        "A capture made under reads-only is refused by a build that " &
        "requires full evidence, which recomputes locally instead; the " &
        "scope is not part of the cache key, so a full-evidence result " &
        "stays usable by everyone. That refusal is SESSION-WIDE, not " &
        "per-action: it is graded as an unknown-scope evidence loss, " &
        "because a reads-only record cannot say which lookups it dropped, " &
        "so there is no narrower set to invalidate, and the first refused " &
        "capture therefore turns every later cache lookup in " &
        "that session into a miss. The build stays correct; it stops " &
        "being incremental. You only reach it by reading a capture " &
        "someone else narrowed, never your own. Recover by opting into " &
        "the reduced scope with --evidence=reads-only, or by re-capturing " &
        "under --evidence=full."
    flag peerCache is string,
      help = "Consult a peer cache: none, lan://CIDR[:port][?seeds=" &
        "HOST:PORT,...&listen=PORT&multicast=0&tls=1&profile=" &
        "trusted|hardened] or remote://URL"
    flag trustProfile is seq[string],
      help = "The trust profile of the peer-cache node: trusted or " &
        "hardened (given at most once)"
    flag publish is Option[string], format = equals,
      help = "Publish the build's install mirror under a profile's " &
        "substitute-only edge: `--publish=<profile.nim>#<edge-id>` (the " &
        "consuming platform is `--target`'s)"
    pos selectors is seq[string], required = false,
      help = "What to build: a project path, `path#name`, a target name " &
        "or `package:name` (default: the current directory's default " &
        "target)"
    pos actionArgs is seq[string], required = false, afterSeparator = true,
      help = "Arguments forwarded to the selected action, after `--`"

proc testFlags(): NimNode {.compileTime.} =
  ## The command line of `repro test`, which `repro certify` takes too: its
  ## own flags (the sharded CI path and certificate issuance), then the
  ## command line of `repro build`, which it hands to the build it runs (the
  ## build of the `test` collection, or of the named targets).
  let build = buildFlags()
  quote do:
    flag shard is string, valueName = "K/N",
      help = "Run shard K of N (1-indexed) of the joint build and test work"
    flag partitionStrategy is string, values = ["joint-duration", "slice",
        "hash", "duration"], default = "joint-duration",
      help = "How the work is split into shards (`hash` and `duration` are " &
        "not implemented)"
    flag emitPartitionPlan is string,
      help = "Write the partition plan to the path and run nothing"
    flag planFrom is string,
      help = "Run this shard of the partition plan at the path"
    flag fixtureFrom is string,
      help = "Shard the test edges a fixture file declares instead of the " &
        "project's"
    flag binDir is string, default = "build/test-bin",
      help = "Where a sharded run places the test binaries"
    boolFlag certify is bool, negatable = true, default = true,
      help = "Issue a test certificate for what passed when the issuance " &
        "preconditions hold; `--no-certify` runs the tests and issues " &
        "nothing"
    flag certificateOut is string,
      help = "Also write the issued certificate to this path (an extra " &
        "copy; the certificate always goes to the local certificate store)"
    flag workspaceRoot is string,
      help = "The workspace the certificate is bound to (default: the one " &
        "enclosing the tested repository)"
    flag currentRepo is string,
      help = "The repository being certified (default: the tested " &
        "project's)"
    flag ctIncrementalTraceDir is string,
      help = "The incremental test adapter's trace directory, which the " &
        "re-certify no-op also consults"
    flag allowPinRegression is seq[string],
      help = "Siblings whose pins the lock-update step may move backward " &
        "(comma-separated, repeatable; `$REPRO_ALLOW_PIN_REGRESSION` is " &
        "read too)"
    `build`

proc certificatesInspectionFlags(): NimNode {.compileTime.} =
  ## The flags `repro certificates list` and `plan` share: they read the
  ## project's stored graph, as a build does.
  quote do:
    boolFlag json is bool, help = "Print the result as JSON"
    flag toolProvisioning is string, format = equals, values = ["path",
        "nix", "tarball", "scoop", "from-source", "fromSource", "source"],
      help = "How the tools that read the project are provisioned " &
        "(default: path)"
    boolFlag noRunquota is bool, env = "REPROBUILD_NO_RUNQUOTA",
      refuseFalse = true,
      help = "Bypass RunQuota admission; the flag wins over " &
        "`$REPROBUILD_NO_RUNQUOTA`, the same bypass"

proc watchFlags(): NimNode {.compileTime.} =
  ## The command line of `repro watch`: the build flags a watch cycle takes
  ## (each the same declaration as `repro build`'s), the session's own, and
  ## hot code reloading's. The watch's own flags take their value only in
  ## the `=` spelling.
  let daemon = daemonModeFlag("watch")
  let toolProvisioning = buildToolProvisioningFlag()
  let workRoot = buildWorkRootFlag()
  let measurement = measurementFlags()
  let report = buildReportFlags()
  let stats = buildStatsFlags()
  let restore = restoreCachedOutputsFlag()
  quote do:
    `daemon`
    `toolProvisioning`
    `workRoot`
    flag maxCycles is int, format = equals,
      help = "Stop after this many cycles (default: run until stopped)"
    flag debounceMs is int, format = equals, default = 250,
      help = "How long a change waits for more changes before a cycle " &
        "starts, in milliseconds"
    boolFlag detach is bool,
      help = "Start a daemon-hosted watch that keeps running after this " &
        "command returns"
    flag attach is string, format = equals, valueName = "SESSION",
      help = "Attach to a detached watch session and stream its events"
    flag stop is string, format = equals, valueName = "SESSION",
      help = "Stop a detached watch session"
    `measurement`
    `report`
    `stats`
    `restore`
    boolFlag hcr is bool,
      help = "Hot code reloading: deliver each change as a patch to the " &
        "running process (direct mode only: `--daemon=off`)"
    flag hcrMode is string, format = equals, values = ["direct", "shlib"],
      help = "How patches are delivered (default: direct)"
    flag hcrDebug is string, format = equals, values = ["embedded",
        "external", "none"],
      help = "How debug information is delivered (default: embedded)"
    flag hcrAgentSocket is string, format = equals,
      help = "The HCR agent's socket (default: `.repro/hcr/agent.sock`)"
    flag hcrArtifacts is string, format = equals,
      help = "Where the HCR artifacts are written (default: `.repro/hcr`)"
    flag hcrMetadata is string, format = equals,
      help = "The patch metadata document a build writes (default: infer " &
        "the changed function)"
    flag hcrTarget is seq[string], format = equals,
      valueName = "NAME:SOCKET:ARTIFACTS[:METADATA]",
      help = "Hot-reload one target (repeatable); also written " &
        "`name=NAME,socket=SOCKET,artifacts=ARTIFACTS[,metadata=METADATA]`"
    boolFlag ctIncremental is bool,
      help = "Skip a watched test whose trace says the change cannot " &
        "affect it"
    flag ctIncrementalTraceDir is string, format = equals,
      help = "The directory the watched test writes its trace to"
    pos selectors is seq[string], required = false,
      help = "What to watch: a project path, `path#name`, a target name or " &
        "`package:name` (default: the current directory's default target)"

proc lockSolveFlags(): NimNode {.compileTime.} =
  ## The flags `repro lock solve`, `refresh` and `validate` share.
  quote do:
    flag inputs is string,
      help = "Solve from this solver-inputs file instead of the recipe"
    flag lock is string, help = "The lock file (default: the committed lock)"
    flag platform is string, help = "The platform to solve for"
    flag strategy is Option[string],
      help = "The version strategy: default, lowest, highest or " &
        "lowest-direct"
    boolFlag lowest is bool, help = "Shorthand for --strategy=lowest"
    boolFlag highest is bool, help = "Shorthand for --strategy=highest"
    flag registry is seq[string],
      help = "A metadata index the solve may reach (repeatable)"
    boolFlag write is bool, help = "Write the solved lock"
    boolFlag json is bool, help = "Print the result as JSON"
    pos projectDir is string, required = false,
      help = "The project (default: the current directory)"

type
  ReproCommandGroup* = object
    ## One heading of ``repro --help``: its title, the commands the short
    ## page (``-h``, ``--help``, ``repro help``) lists under it, and the
    ## commands only ``repro --help-all`` (and ``repro help --all``) adds.
    title*: string
    primary*: seq[string]
    secondary*: seq[string]

const
  ReproCommandGroups* = @[
    ReproCommandGroup(title: "Build & Test",
      primary: @["build", "test", "watch", "clean"],
      secondary: @["bench", "lint", "certify", "certificates", "ci", "graph",
        "deps", "stats", "configs", "show-conventions", "cargo"]),
    ReproCommandGroup(title: "Environments & Services",
      primary: @["shell", "exec", "up", "down", "run", "tasks"],
      secondary: @["dev", "hcr", "allow", "deny", "dev-env", "prompt",
        "launch-plan"]),
    ReproCommandGroup(title: "Dependencies & Workspaces",
      primary: @["develop", "add", "why", "lock", "workspace"],
      secondary: @["remove", "sync", "pull", "branch", "switch", "push",
        "check", "hooks", "locking", "flake", "gateway", "bundle"]),
    ReproCommandGroup(title: "Machines & Diagnostics",
      primary: @["home", "system", "infra", "health"],
      secondary: @["anywhere", "deploy-agent", "hardware", "disk", "attest",
        "cert-signer", "daemon", "store", "cas", "cache", "reap", "self",
        "pressure", "capabilities", "debug", "version", "help",
        "completion"])]
    ## How ``repro --help`` organizes the top-level commands, in the order
    ## it lists them: each group's ``primary`` commands are the daily ones
    ## the short page shows, its ``secondary`` ones the rest, which
    ## ``--help-all`` lists after them under the same heading. Every shown
    ## top-level command is in exactly one group, and only shown ones are:
    ## ``arrangeCommandGroups`` refuses to compile otherwise, so a new
    ## command has to be given a place here. The user documentation's
    ## commands index reads this table as text
    ## (``scripts/render_user_docs_generated.py``), so keep its shape: one
    ## ``ReproCommandGroup(...)`` per group, string literals only.

proc commandHeadWord(stmt: NimNode): string {.compileTime.} =
  ## The word a top-level ``subcmd "<word>"`` statement declares, or "".
  if stmt.kind in {nnkCommand, nnkCall} and stmt.len >= 2 and
      stmt[0].eqIdent("subcmd") and stmt[1].kind == nnkStrLit:
    return stmt[1].strVal
  ""

proc commandHeadArgs(stmt: NimNode): int {.compileTime.} =
  ## The index one past a ``subcmd`` statement's last head argument: its
  ## body (a statement list) when it has one, else its end. A command
  ## written without a body (``subcmd "x", visibility = hidden``) has head
  ## arguments up to its last child.
  if stmt[^1].kind == nnkStmtList: stmt.len - 1 else: stmt.len

proc commandIsShown(stmt: NimNode): bool {.compileTime.} =
  ## Whether a ``subcmd`` statement leaves its visibility at ``shown``:
  ## neither ``hidden`` (listed nowhere) nor ``internal`` (listed only by
  ## its own help), so the root's help has a row for it.
  for arg in stmt[2 ..< commandHeadArgs(stmt)]:
    if arg.kind == nnkExprEqExpr and arg[0].eqIdent("visibility"):
      return arg[1].eqIdent("shown")
  true

proc arrangeCommandGroups(body: NimNode): NimNode {.compileTime.} =
  ## ``body`` (the ``cli:`` body) with its shown top-level commands moved
  ## into the ``group`` sections ``ReproCommandGroups`` names, in its order,
  ## and every ``secondary`` one marked ``tier = secondary``. The sections
  ## stand where the first shown command stood; every other statement keeps
  ## its place. A group is applied here, rather than written around the
  ## declarations, so the table is the one place that says where a command
  ## is listed and the declarations keep their shape.
  ##
  ## A compile error when the table names a command that is not a shown
  ## top-level command, names one twice, or leaves a shown one out.
  var shown: seq[(string, NimNode)] = @[]
  var notShown: seq[string] = @[]
  for stmt in body:
    let word = commandHeadWord(stmt)
    if word.len == 0:
      continue
    if commandIsShown(stmt):
      shown.add((word, stmt))
    else:
      notShown.add(word)
  proc declaration(word: string): NimNode =
    for (name, stmt) in shown:
      if name == word:
        return stmt
    if word in notShown:
      error("repro command line: ReproCommandGroups lists `" & word &
        "`, which is not a shown command (a hidden or internal command " &
        "has no row in `repro --help`)")
    error("repro command line: ReproCommandGroups lists `" & word &
      "`, which is not a top-level command")
  var placed: seq[string] = @[]
  var sections: seq[NimNode] = @[]
  for group in ReproCommandGroups:
    var commands = newStmtList()
    for (words, secondary) in [(group.primary, false),
                               (group.secondary, true)]:
      for word in words:
        if word in placed:
          error("repro command line: ReproCommandGroups lists `" & word &
            "` twice")
        placed.add(word)
        var command = declaration(word).copyNimTree()
        if secondary:
          command.insert(commandHeadArgs(command), nnkExprEqExpr.newTree(
            ident("tier"), ident("secondary")))
        commands.add(command)
    sections.add(nnkCommand.newTree(ident("group"), newLit(group.title),
      commands))
  for (word, stmt) in shown:
    if word notin placed:
      error("repro command line: the top-level command `" & word & "` is " &
        "in no group of ReproCommandGroups; add it to the `primary` list " &
        "of a group if `repro --help` should list it, to the `secondary` " &
        "list otherwise", stmt)
  result = body.kind.newNimNode(body)
  var sectionsAdded = false
  for stmt in body:
    let word = commandHeadWord(stmt)
    if word.len > 0 and commandIsShown(stmt):
      if not sectionsAdded:
        for section in sections:
          result.add(section)
        sectionsAdded = true
      continue
    result.add(stmt)

proc reproCommandLineDescription*(): NimNode {.compileTime.} =
  ## The ``cli:`` body of repro's command line.
  ##
  ## ``repro --help`` lists the shown top-level commands by
  ## ``ReproCommandGroups``, not in the order they are declared here
  ## (``arrangeCommandGroups``). The ``# ---- ... ----`` comments below
  ## only organise the declarations; they are not the help's sections.
  let graphInspection = graphInspectionFlags()
  let devEnvSelection = devEnvSelectionFlags()
  # Group 5 (development environments), one splice per command.
  let execSelection = devEnvSelectionFlags()
  let shellSelection = devEnvSelectionFlags()
  let runSelection = devEnvSelectionFlags()
  let upSession = devSessionSelectionFlags()
  let devSession = devSessionSelectionFlags()
  let downSession = devSessionSelectionFlags()
  let upStart = devSessionStartFlags()
  let devStart = devSessionStartFlags()
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
  # Group 4 (machines). A shared group is spliced once per command, so each
  # splice gets its own tree.
  let homeAddEdit = homePackageEditFlags()
  let homeRemoveEdit = homePackageEditFlags()
  let homeEnableRemote = homeRemoteTargetFlags()
  let homeDisableRemote = homeRemoteTargetFlags()
  let homeListHost = hostIdentityFlag()
  let homeWhyHost = hostIdentityFlag()
  let homeApplyHost = hostIdentityFlag()
  let homeApplyPlatform = homeTargetPlatformFlags()
  let homePlanHost = hostIdentityFlag()
  let homeExportHost = hostIdentityFlag()
  let homeFactsHost = hostIdentityFlag()
  let homeBuildBundleStore = homeBundleStoreFlags()
  let homeBuildBundlePlatform = homeTargetPlatformFlags()
  let homeReceiveBundleStore = homeBundleStoreFlags()
  let homeTransferBundleStore = homeBundleStoreFlags()
  let homeRemoteActivate = homeRemoteActivateFlags()
  let remoteActivate = homeRemoteActivateFlags()
  let systemAddLocation = infraLocationFlags()
  let systemRemoveLocation = infraLocationFlags()
  let systemListLocation = infraLocationFlags()
  let systemWhyLocation = infraLocationFlags()
  let systemSyncLocation = infraLocationFlags()
  let systemAuditLocation = infraLocationFlags()
  let systemSyncRegistry = infraRegistryFlags()
  let systemSyncDrift = infraDriftFlags()
  let systemRollbackLocation = infraLocationFlags()
  let systemRollbackRegistry = infraRegistryFlags()
  let systemRollbackDrift = infraDriftFlags()
  # `repro system plan|apply` and `repro infra plan|apply` run the same
  # planner and applier, and splice the same groups.
  let systemPlan = systemPlanFlags()
  let systemApply = systemApplyFlags()
  let infraPlan = systemPlanFlags()
  let infraApply = systemApplyFlags()
  let infraCacheKeysLocation = infraLocationFlags()
  let infraImageTarget = addonTargetFlags()
  let anywhereTarget = addonTargetFlags()
  let deployAgentHost = hostIdentityFlag()
  let compileProfileHost = hostIdentityFlag()
  let cargoGcTargetDir = cargoTargetDirFlags()
  let cargoRecordLiveTargetDir = cargoTargetDirFlags()
  # Group 6 (workspaces and publication), one splice per command.
  let pushRoot = workspaceRootFlag()
  let pushTools = workspaceToolProvisioningFlag()
  let pushReport = workspaceReportFlags()
  let checkRoot = workspaceRootFlag()
  let checkTools = workspaceToolProvisioningFlag()
  let checkReport = workspaceReportFlags()
  let hooksEnsure = hooksActionFlags()
  let hooksReinstall = hooksActionFlags()
  let hooksUninstall = hooksActionFlags()
  let syncTop = syncFlags()
  let syncWs = syncFlags()
  let pullTop = pullFlags()
  let pullWs = pullFlags()
  let switchTop = switchFlags()
  let switchWs = switchFlags()
  let branchTop = branchFlags()
  let branchWs = branchFlags()
  let addRefused = refusedFlags(workspaceRepoAddFlags())
  let removeRefused = refusedFlags(workspaceRepoRemoveFlags())
  let lockingExplainRoot = workspaceRootFlag()
  let lockingExplainTools = workspaceToolProvisioningFlag()
  let lockingAdoptRoot = workspaceRootFlag()
  let lockingAdoptTools = workspaceToolProvisioningFlag()
  let developSelection = developSelectionFlags()
  let developTools = workspaceToolProvisioningFlag()
  let developReport = writeReportFlags()
  let flakeOverrideArgs = flakeVerbFlags()
  let flakeRefreshLock = flakeVerbFlags()
  let flakeOverrideStatus = flakeVerbFlags()
  let lockSolve = lockSolveFlags()
  # Group 7 (the build family): `build`, and `bench` and `lint`, which take
  # its command line unchanged.
  let buildCommand = buildFlags()
  let benchCommand = buildFlags()
  let lintCommand = buildFlags()
  let testCommand = testFlags()
  let certifyCommand = testFlags()
  let certificatesList = certificatesInspectionFlags()
  let certificatesPlan = certificatesInspectionFlags()
  let watchCommand = watchFlags()
  let lockRefresh = lockSolveFlags()
  let lockValidate = lockSolveFlags()
  let workspaceCommands = workspaceSubcommands(syncWs, pullWs, switchWs,
    branchWs)
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
      `buildCommand`
    subcmd "test", help = "Run the project's tests":
      `testCommand`
    subcmd "bench", help = "Run the project's benchmarks":
      `benchCommand`
    subcmd "lint", help = "Run the project's lint checks":
      `lintCommand`
    subcmd "certify",
        help = "Run the required test set and issue a signed test certificate":
      # `repro test --certify`'s command line, and two other modes: verify
      # a certificate a remote worker returned, or certify the repository's
      # check set. A flag of one mode is refused in another.
      `certifyCommand`
      boolFlag verify is bool,
        help = "Verify a certificate (the positional) instead of running " &
          "tests: authentic, and bound to `--content`"
      flag content is string,
        help = "With `--verify`: the content id the certificate must name " &
          "(required)"
      flag registeredKeys is string,
        help = "With `--verify`: the registered-key store (default: the " &
          "workspace's)"
      flag workspace is string,
        help = "With `--verify`: the workspace whose registered keys are " &
          "read (default: the current directory)"
      boolFlag checkSet is bool,
        help = "Certify the repository's pre-commit check set, run over the " &
          "whole tree, as the one target `pre-commit`"
      flag checkSetCommand is string, format = equals,
        help = "With `--check-set`: the shell command that runs the check " &
          "set (default: the repository's `.pre-commit-config.yaml`, run " &
          "by prek or pre-commit)"
    subcmd "certificates",
        help = "List the project's named certificates or those a plan issues":
      subcmd "list",
          help = "The certificate names the project declares and the node " &
            "each marks":
        `certificatesList`
      subcmd "plan",
          help = "The certificate-producing nodes the plan for the " &
            "selectors materializes":
        `certificatesPlan`
        boolFlag noCertify is bool,
          help = "Plan the run as `repro test --no-certify` would"
        pos selectors is seq[string], required = false,
          help = "What the plan builds (default: `.#test`, as for " &
            "`repro test`)"
      subcmd "policy",
          help = "The certificate policy `repro.lock` records, and the rule " &
            "that applies to a branch":
        flag branch is Option[string],
          help = "The branch, or a full ref (default: the current " &
            "branch's upstream, else the current branch)"
        boolFlag json is bool, help = "Print the result as JSON"
      subcmd "help", visibility = hidden:
        pos topic is seq[string], required = false
    subcmd "ci", help = "Plan which targets a CI run must execute":
      subcmd "plan",
          help = "Which required targets a valid certificate lets CI skip, " &
            "and which it must run, per platform":
        flag platform is seq[string], format = equals,
          help = "Plan for this platform (repeatable; default: every " &
            "required platform)"
        flag base is string, format = equals,
          help = "The commit whose certificate-policy snapshot decides " &
            "(default: `origin/<branch>`)"
        flag branch is string, format = equals,
          env = ["GITHUB_BASE_REF", "GITHUB_REF_NAME"],
          help = "The branch whose rule applies; the flag wins over " &
            "`$GITHUB_BASE_REF`, then `$GITHUB_REF_NAME` (default: the " &
            "checkout's branch)"
        boolFlag json is bool,
          help = "Print the plan as a `reprobuild.ci-plan.v2` document"
        flag workspaceRoot is string, format = equals,
          help = "The workspace root (default: the current directory)"
        flag currentRepo is string, format = equals,
          help = "The repository whose certificates are read (default: the " &
            "workspace root)"
        flag registeredKeys is Option[string], format = equals,
          help = "The registered-key store a skip verifies signers " &
            "against: a file the CI job owns, outside the checkout and the " &
            "workspace root (without it, nothing is skipped)"
    subcmd "watch",
        help = "Watch for changes and rebuild or rerun continuously":
      `watchCommand`
    subcmd "clean", help = "Remove the current project's build artifacts":
      flag projectRoot is string,
        help = "The project (default: the current directory)"
      flag workRoot is string, env = "REPROBUILD_WORK_ROOT",
        help = "The work root the project's build state lives under " &
          "(default: `$REPROBUILD_WORK_ROOT`)"
      boolFlag dryRun is bool,
        help = "List the outputs that would be removed, and remove nothing"
    subcmd "run", help = "Run a task, a build output or a target once":
      `runSelection`
      boolFlag choose is bool,
        help = "List the runnable tasks and run-edges instead of running one"
      pos target is string, required = false,
        help = "The task or target: `NAME`, `task:NAME` (a task only) or " &
          "`PACKAGE:NAME` (a run-edge of that package); without one, list " &
          "what can run"
      pos args is seq[string], required = false, afterSeparator = true,
        help = "Arguments for the program, after `--`"
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
      # No default: an explicit `--format` wins over `--json`, so the
      # command must see whether one was given (`json` when neither is).
      flag format is string, values = ["json", "text"],
        help = "The output format: `json` (the default) or `text`"
      boolFlag json is bool,
        help = "Shortcut for `--format=json` (an explicit --format wins)"

    # ---- Development environments ---------------------------------------
    subcmd "exec", help = "Run a command inside the development environment":
      `execSelection`
      pos selector is string, required = false,
        help = "The project whose environment to use (default: the " &
          "current directory's)"
      pos command is seq[string], required = false, afterSeparator = true,
        help = "The command and its arguments, after `--` (required)"
    subcmd "shell",
        help = "Enter or print the development shell environment":
      call:
        `shellSelection`
        flag shell is string,
          help = "The shell to start (default: `$SHELL`; on Windows " &
            "`$COMSPEC`, else pwsh)"
        flag printEnv is Option[string],
          help = "Print the environment instead of starting a shell: " &
            "`posix` (also `sh`, `bash`, `zsh`), `fish`, `powershell` " &
            "(also `pwsh`, `ps1`) or `json`"
        flag command is Option[string], short = 'c',
          help = "Run this command through the shell (`<shell> -c " &
            "<command>`) instead of starting an interactive one, and exit " &
            "with its status"
        pos selector is string, required = false,
          help = "The project whose environment to use (default: the " &
            "current directory's)"
        pos argv is seq[string], required = false, afterSeparator = true,
          help = "A command and its arguments, after `--`, run directly in " &
            "the environment as `repro exec` runs it"
      subcmd "hook", help = "Print the shell hook that activates " &
          "development environments on `cd`":
        flag reproBin is string,
          help = "The repro the hook runs (default: `repro` on PATH)"
        pos shell is string,
          help = "The shell: `bash`, `zsh`, `fish`, `nushell` (also `nu`) " &
            "or `pwsh` (also `powershell`, `ps`, `ps1`)"
    # `allow` and `deny` take one directory; a directory whose name starts
    # with `-` is written after `--`.
    subcmd "allow", help = "Trust a directory's development environment, " &
        "so the shell hook activates it":
      pos directory is string, required = false,
        help = "The directory to trust (default: the current directory)"
    subcmd "deny", help = "Revoke the trust `repro allow` recorded for a " &
        "directory":
      pos directory is string, required = false,
        help = "The directory (default: the current directory)"
    subcmd "dev-env",
        help = "Export or deactivate a development environment for a shell":
      subcmd "export", help = "Print the script that activates the " &
          "project's development environment in a shell":
        flag projectRoot is string,
          help = "The project to activate (default: the nearest project " &
            "above the current directory)"
        flag activity is string,
          help = "The activity to activate (default: `default`)"
        flag developOverrides is string,
          help = "The develop-overrides metadata file (default: the " &
            "project's)"
        flag preActivationEnv is string,
          help = "The shell's environment before activation, as " &
            "NUL-separated `NAME=VALUE` entries (`env -0`)"
        boolFlag allowStale is bool,
          help = "Skip the cache-key fast path and the stale-dependency " &
            "check"
        pos shell is string,
          help = "The shell: `bash`, `zsh`, `fish`, `nushell` (also `nu`) " &
            "or `pwsh` (also `powershell`, `ps`, `ps1`)"
      subcmd "deactivate", help = "Print the script that rolls an " &
          "activation back (exit 3 when the activation was tampered with)":
        flag shell is Option[string],
          help = "The shell of the script (default: `bash`)"
        pos manifest is string,
          help = "The rollback manifest the activation wrote " &
            "(`<artifact>.rollback.json`)"
    subcmd "up", help = "Start the project's services":
      `upSession`
      `upStart`
      pos selector is string, required = false,
        help = "The project (default: the current directory's)"
    subcmd "down", help = "Stop the project's supervised development session":
      `downSession`
      boolFlag force is bool,
        help = "Write a stop request file when the session's control API " &
          "does not answer"
      flag stopTimeout is Option[int],
        help = "Wait at most this many milliseconds for the session to stop"
      pos selector is string, required = false,
        help = "The project (default: the current directory's)"
    subcmd "dev",
        help = "Run the development session with continuous rebuilds":
      `devSession`
      `devStart`
      flag debounceMs is int, default = 250,
        help = "Wait this many milliseconds for a burst of changes to " &
          "settle before rebuilding"
      pos selector is string, required = false,
        help = "The project (default: the current directory's)"
    subcmd "develop",
        help = "Set up a project or a dependency for development":
      `developSelection`
      boolFlag list is bool,
        help = "Print the resolved lock set and exit, changing nothing"
      boolFlag listOverrides is bool,
        help = "Print the local develop-override map and exit"
      flag drop is seq[string],
        help = "Remove the develop override of these dependencies " &
          "(comma-separated) and exit"
      boolFlag dryRun is bool,
        help = "Print what the selection would do and exit, changing nothing"
      flag into is Option[string],
        help = "Where the selected checkouts go (default: beside the " &
          "workspace); with one dependency, its checkout"
      boolFlag reset is bool,
        help = "Force a checkout that drifted off its locked revision back " &
          "to it (destructive)"
      flag source is Option[string],
        help = "Register this existing checkout of the dependency instead " &
          "of cloning it"
      flag workspaceRoot is Option[string],
        help = "The workspace (default: found from the current directory)"
      flag projectRoot is string,
        help = "With --drop: the project whose overrides to drop too " &
          "(default: the current directory's)"
      `developTools`
      boolFlag json is bool, help = "Print the report as JSON"
      `developReport`
      boolFlag cmake is bool,
        help = "Treat the target as a CMake source directory"
      flag cmakeBinary is Option[string],
        help = "With --cmake: the cmake to run"
      flag workRoot is Option[string],
        help = "The work root of the environment build (default: the " &
          "project's `.repro`)"
      pos target is string, required = false,
        help = "The dependency, project or build target"
      pos command is seq[string], required = false, afterSeparator = true,
        help = "The command to run in the target's environment, after `--`"
    subcmd "add", help = "Add a package dependency to the current " &
        "project's repro.nim":
      boolFlag build is bool,
        help = "Add it to `buildDeps:` (default: `uses:`)"
      boolFlag nativeBuild is bool,
        help = "Add it to `nativeBuildDeps:` (default: `uses:`)"
      boolFlag runtime is bool,
        help = "Add it to `runtimeDeps:` (default: `uses:`)"
      flag package is string,
        help = "The package of repro.nim to edit (default: its only one)"
      boolFlag dryRun is bool,
        help = "Print the change to repro.nim; write nothing"
      `addRefused`
      pos dependency is string, required = false,
        help = "The package, with an optional version constraint as " &
          "`uses:` writes it: `name`, `name >=1.2 <2` (one word) or " &
          "`name@>=1.2`"
    subcmd "remove", help = "Remove a package dependency from the current " &
        "project's repro.nim":
      flag package is string,
        help = "The package of repro.nim to edit (default: its only one)"
      boolFlag dryRun is bool,
        help = "Print the change to repro.nim; write nothing"
      `removeRefused`
      pos dependency is string, required = false,
        help = "The package to remove"
    subcmd "hcr", help = "Coordinate hot code reloading":
      subcmd "coordinate", help = "Run one coordination cycle with an HCR " &
          "agent: edit, rebuild and patch":
        flag project is string, help = "The project root (required)"
        flag target is string, help = "The build target (required)"
        flag socket is string,
          help = "The Unix-domain socket the agent connects to (required)"
        flag sourceEditDriver is string,
          help = "The program run against the project to edit its source " &
            "(required)"
        flag artifacts is string,
          help = "Where the rebuilt objects and the reports go (required)"
        flag patchFunction is string,
          default = "reprobuild_hcr_patchable_value",
          help = "The function to patch"
      subcmd "prepare-object", help = "Rewrite an object so its code is " &
          "patchable (a dedicated segment on Mach-O; expanded compressed " &
          "debug sections on ELF)":
        flag input is string, help = "The object to read (required)"
        flag output is string, help = "The object to write (required)"
        flag function is string,
          help = "Rewrite only this function's section (or --all-code)"
        boolFlag allCode is bool,
          help = "Rewrite every code section (or --function)"
        flag segment is string, default = "__HCR",
          help = "The segment the code is placed in"

    # ---- Workspaces and publication -------------------------------------
    subcmd "workspace", aliases = ["ws"],
        help = "Manage the multi-repository workspace":
      `workspaceCommands`
    subcmd "sync",
        help = "Fast-forward the workspace's repositories toward a target":
      `syncTop`
    subcmd "pull",
        help = "Converge the workspace onto its declared revisions":
      `pullTop`
    subcmd "branch", help = "Fork a new sibling workspace on a new branch " &
        "(with no path: print the workspace's branch)":
      call:
        `branchTop`
      subcmd "help", visibility = hidden:
        pos topic is seq[string], required = false
    subcmd "switch", help = "Switch the workspace to a branch":
      call:
        `switchTop`
      subcmd "help", visibility = hidden:
        pos topic is seq[string], required = false
    subcmd "push",
        help = "Publish the current work as a reproducible workspace state":
      `pushRoot`
      `pushTools`
      flag currentRepo is string,
        help = "The repository being pushed (default: the git worktree " &
          "containing the current directory)"
      boolFlag sync is bool,
        help = "Reconcile with the upstream before pushing (by merging, " &
          "unless --rebase)"
      boolFlag merge is bool, help = "Reconcile by merging (implies --sync)"
      boolFlag rebase is bool, help = "Reconcile by rebasing (implies --sync)"
      boolFlag certify is bool, negatable = true, default = true,
        help = "Obtain the test certificate the pushed commit needs " &
          "(the default)"
      `pushReport`
      pos project is string, required = false,
        help = "The project to push (default: the workspace's)"
    subcmd "check", help = "Run the publication checks (the pre-push gate)":
      # Not required by the parser: a missing `--mode` is the command's own
      # refusal (exit 1), so it stays apart from exit 2, a failed gate.
      flag mode is string, values = ["pre-push"],
        help = "The check set to run (required; `pre-push` is the only one)"
      `checkRoot`
      flag currentRepo is string,
        help = "The repository being pushed (default: the git worktree " &
          "containing the current directory)"
      flag pushedRefs is string,
        help = "The file holding the ref lines git gives a pre-push hook"
      `checkTools`
      `checkReport`
    subcmd "hooks", help = "Install, repair or remove the managed hooks":
      subcmd "ensure",
          help = "Install or repair the managed hooks (idempotent)":
        `hooksEnsure`
      subcmd "reinstall", help = "Rewrite the managed hooks from scratch":
        `hooksReinstall`
      subcmd "uninstall", help = "Remove the managed hooks":
        `hooksUninstall`
      # The handshake a managed hook body runs before handing its work over
      # (`hooks protocol --require=2 --hook-contract=<token>`); exit 3 means
      # "I speak the handshake but generate a different hook". Each flag is
      # spelt `--flag=VALUE` only, as the bodies write it.
      subcmd "protocol", visibility = internal,
          help = "Answer a managed hook's contract handshake":
        flag require is string, format = equals,
          help = "The dispatcher protocol the hook speaks (`2`)"
        flag hookContract is Option[string], format = equals,
          help = "The contract token the hook body carries"
        boolFlag requireSourceComponent is bool,
          help = "Require source-component capabilities"
      # What a managed hook body runs: `hooks dispatch <hook> --repo-root R
      # [--refs-file F --protocol=2] [--phase=P --dispatcher-displaced=D]
      # -- <git's hook arguments>`.
      subcmd "dispatch", visibility = internal,
          help = "Run a managed git hook's work":
        flag repoRoot is string, help = "The repository the hook fired in"
        flag refsFile is string,
          help = "The file holding the ref lines git gave a pre-push hook"
        flag protocol is Option[string], help = "The hook protocol (`2`)"
        flag phase is string, default = "refresh",
          help = "The pre-commit phase: `refresh` or `certificate-gate`"
        flag dispatcherDisplaced is string,
          help = "`1` when the dispatcher runs displaced as `<hook>.legacy`"
        pos hookName is string,
          help = "The hook: pre-commit, pre-push, post-commit, post-merge " &
            "or post-checkout"
        pos hookArgs is seq[string], required = false, afterSeparator = true,
          help = "The arguments git gave the hook"
      # Spawned detached by the post-commit hook.
      subcmd "cache-push", visibility = internal,
          help = "Push the committed branch into the shared clone cache":
        flag repoRoot is string, help = "The repository committed in"
        flag workspaceName is string, help = "The workspace's cache namespace"
      subcmd "help", visibility = hidden:
        pos topic is seq[string], required = false
    subcmd "lock", help = "Inspect and update the project's lock":
      subcmd "list", help = "The lock files the project declares, each " &
          "with its description":
        pos projectDir is string, required = false,
          help = "The project (default: the current directory)"
      subcmd "solve", help = "Solve the project's lock (written only with " &
          "--write)":
        `lockSolve`
      subcmd "refresh", help = "Solve the project's lock and write it":
        `lockRefresh`
        boolFlag provisioning is bool,
          help = "Re-select the lock's provisioning records instead of " &
            "carrying them forward"
        flag allowPinRegression is seq[string],
          help = "Allow these siblings' pins to move backward " &
            "(comma-separated; `$REPRO_ALLOW_PIN_REGRESSION` is read too)"
        flag repin is seq[string],
          help = "Re-pin only these packages (comma-separated)"
        boolFlag allowStaleManifest is bool,
          help = "Deprecated; accepted and ignored"
      subcmd "update", help = "Move every resolution of one repository, in " &
          "repro.lock and in flake.lock, to one revision (an intended " &
          "upgrade)":
        flag to is string,
          help = "The target revision (default: the sibling checkout's HEAD)"
        flag repoRoot is string,
          help = "The repo whose recipes and locks are updated (default: the " &
            "git top level of the current directory)"
        flag allowPinRegression is seq[string],
          help = "Allow a target behind, or diverged from, a current " &
            "resolution (comma-separated; `$REPRO_ALLOW_PIN_REGRESSION` is " &
            "read too)"
        pos dependency is string, required = false,
          help = "A flake input, repro.lock dependency or workspace repo " &
            "name (qualify an ambiguous one as `input:`, `dep:` or `repo:`)"
      subcmd "validate", help = "Check the committed lock is loadable, " &
          "consistent and still what a fresh solve gives":
        `lockValidate`
      subcmd "diff", help = "The provisioning-level difference of two locks":
        pos oldLock is string, required = false, help = "The old lock"
        pos newLock is string, required = false, help = "The new lock"
      subcmd "explain", help = "Explain a variant's value from a solver " &
          "fixture":
        flag fixture is string, help = "The solver fixture (required)"
        boolFlag json is bool, help = "Print the explanation as JSON"
        pos variant is string, required = false, help = "The variant"
    subcmd "locking",
        help = "Explain or adopt the workspace's locking configuration":
      subcmd "explain", help = "Each repo's lock tier and backend, and the " &
          "configuration layer that decided it":
        `lockingExplainRoot`
        flag project is string, help = "The project (default: the workspace's)"
        `lockingExplainTools`
        boolFlag json is bool, help = "Print the explanation as JSON"
        pos projectName is string, required = false,
          help = "The project, as a positional"
      subcmd "adopt-manifest", help = "Adopt the manifest's locking " &
          "declarations into the workspace":
        `lockingAdoptRoot`
        flag project is string, help = "The project (default: the workspace's)"
        `lockingAdoptTools`
        pos projectName is string, required = false,
          help = "The project, as a positional"
    subcmd "flake",
        help = "Compute the Nix flake overrides of the develop set":
      subcmd "override-args", help = "Print the `--override-input` " &
          "arguments that bind the flake's inputs to the develop set's " &
          "checkouts":
        `flakeOverrideArgs`
      subcmd "refresh-lock", help = "Move each substituted input's " &
          "`flake.lock` pin to its checkout's HEAD":
        `flakeRefreshLock`
        flag currentRepo is string,
          help = "The checkout the refresh runs for (default: the flake " &
            "directory)"
        boolFlag recordDowngrade is bool,
          help = "Record a pin that moves backward instead of withholding it"
      subcmd "override-status", help = "Report whether each substituted " &
          "checkout is at, ahead of or behind its `flake.lock` pin":
        `flakeOverrideStatus`
        boolFlag applied is bool,
          help = "Report on the `--override-input` arguments after `--` " &
            "instead of a develop set"
        pos appliedArgs is seq[string], required = false,
          afterSeparator = true,
          help = "With --applied: the override arguments the shell used"
    subcmd "gateway", help = "Run a push-gateway hook entry point":
      subcmd "pre-receive", help = "Verify the pushed refs' certificates " &
          "and forward them upstream (the gateway's pre-receive hook)":
        flag gatewayDir is string,
          help = "The gateway bare (default: `$GIT_DIR`, else the current " &
            "directory)"
      subcmd "post-receive",
          help = "Nothing (the gateway's post-receive hook)":
        flag gatewayDir is string,
          help = "The gateway bare (default: `$GIT_DIR`, else the current " &
            "directory)"
      subcmd "migrate", help = "Install or repair the gateways of a " &
          "workspace's repos":
        flag workspaceRoot is string, format = equals,
          help = "The workspace root (default: the current directory)"
        boolFlag dryRun is bool, help = "Print what would change"
    subcmd "prompt",
        help = "Print a workspace-state segment for the shell prompt":
      call:
        flag format is Option[string],
          help = "`plain` (the default), `ansi`, `json`, or a template " &
            "with `{branch}`, `{repos}`, `{drift}`, `{develop}`, `{stale}` " &
            "and `{segment}`"
        flag workspaceRoot is Option[string],
          help = "The workspace, used as given (default: the one above the " &
            "current directory)"
      subcmd "init", help = "Print the snippet that adds the segment to a " &
          "shell's prompt":
        pos shell is string,
          help = "`bash`, `zsh`, `fish`, `starship`, `p10k` (also " &
            "`powerlevel10k`), `oh-my-zsh` (also `omz`) or `prezto`"

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
        flag latestSha256 is string, format = equals, visibility = internal,
          help = "The SHA-256 of the only latest.json to accept: the one " &
            "restore.sh was made from"
        `bundleStoreRoots`
        boolFlag json is bool, help = "Print the report as JSON"
        pos source is string, help = "A bundle directory or URL, or " &
          "`github:OWNER/REPO[@REF]/BUNDLE`"
      subcmd "inspect", help = "Print the roots to provision, the producing " &
          "repro and the selection of a bundle, writing nothing":
        boolFlag json is bool, help = "Print the report as JSON " &
          "(`reprobuild.bundle-inspect.v1`)"
        pos source is string, help = "A bundle directory, one of its " &
          "system directories, or a native-store half"
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
      # Every subcommand reads the profile from here, so it is the
      # namespace's own flag (it may precede or follow the subcommand).
      flag profileDir is string,
        help = "The home-profile directory (default: the platform's)"
      subcmd "add", help = "Add a package reference to an activity":
        flag activity is string, default = "default",
          help = "The activity the reference is added to"
        `homeAddEdit`
        flag catalog is string,
          help = "Package catalogs to load first, comma-separated (default: " &
            "`$REPRO_HOME_PACKAGE_CATALOG`)"
        pos package is string,
          help = "`<package>`, `<package>@<version>`, or `<package>@latest` " &
            "to pin the version an unpinned reference resolves to"
      subcmd "remove", help = "Remove a package reference":
        flag activity is Option[string],
          help = "Remove only from this activity (default: every activity)"
        `homeRemoveEdit`
        pos package is string,
          help = "`<package>` (every reference) or `<package>@<version>` " &
            "(only the pinned one)"
      subcmd "enable", help = "Enable an activity for a host":
        `homeEnableRemote`
        pos activity is string, help = "The activity to enable"
      subcmd "disable", help = "Disable an activity for a host":
        `homeDisableRemote`
        pos activity is string, help = "The activity to disable"
      subcmd "list", help = "List the profile's package references and " &
          "whether this host plans them":
        `homeListHost`
        boolFlag json is bool,
          help = "Print the list as one JSON document (schema " &
            "reprobuild.home.list.v1)"
      subcmd "why", help = "Explain why a package is in the profile":
        `homeWhyHost`
        pos package is string, help = "The package"
      subcmd "history", help = "List the home-profile generations, " &
          "oldest first":
        boolFlag json is bool,
          help = "Print the generations as one JSON document (schema " &
            "reprobuild.home.history.v1)"
      subcmd "apply", help = "Apply the home profile as a new generation " &
          "(only the concerns this host's `applies:` lists are executed)":
        boolFlag plan is bool,
          help = "Preview the full apply without changing anything"
        `homeApplyHost`
        boolFlag allowDrift is bool,
          help = "With --plan: exit 0 even when drift is detected"
        boolFlag reconcileDrift is bool, alias = "--accept-overwrite",
          help = "Replace a drifted target instead of failing, recording " &
            "the prior content so rollback can restore it"
        boolFlag relock is bool,
          help = "Ignore the selections `home.lock` pins and select every " &
            "package again"
        boolFlag uninstallFromScoop is bool,
          help = "Remove from Scoop the packages this apply drops (only " &
            "what Reprobuild installed and nothing holds)"
        `homeApplyPlatform`
      subcmd "plan", help = "Show what the next apply would do; exit " &
          "non-zero on drift":
        `homePlanHost`
        boolFlag allowDrift is bool, help = "Exit 0 even when drift is detected"
        boolFlag reconcileDrift is bool,
          help = "Plan replacing drifted targets"
        boolFlag json is bool,
          help = "Print the plan as one JSON document (schema " &
            "reprobuild.home.plan.v1); the exit code is the same as without it"
      subcmd "export", help = "Print the evaluated home-profile intent " &
          "(activities, config, hosts, resources, the host's selection, " &
          "provenance) as JSON, or check a committed export; exit 1 when " &
          "stale or failed, 3 when it cannot describe --target":
        `homeExportHost`
        flag format is string, default = "json",
          help = "The output format (only `json`)"
        flag check is Option[string],
          help = "Compare this committed export with a fresh one instead of " &
            "printing: exit 0 when selection, intent and platforms agree, 1 " &
            "with the differences (provenance never fails it)"
        flag target is string,
          help = "Also evaluate the guards for this platform (x86_64-linux, " &
            "aarch64-darwin, ...) and the host, as `evaluation`; refused " &
            "(exit 3) when the export would be wrong for it"
        flag nixos is Option[bool], optionalValue = some(true),
          help = "Whether the --target host is NixOS (`--nixos` alone is " &
            "true; `--nixos=false` states it is not). The system name does " &
            "not say it, so a profile with a `nixos` guard is refused (exit " &
            "3) without it"
      subcmd "facts", help = "Report the host facts an apply would " &
          "produce (packages, files, environment, user services; paths " &
          "relative to a private home), the Reprobuild side of `repro home " &
          "compare`; exit 3 when the profile cannot be described for " &
          "--target":
        `homeFactsHost`
        flag target is string,
          help = "The platform to plan for (x86_64-linux, aarch64-darwin, " &
            "...; default: the one repro runs on)"
        flag nixos is Option[bool], optionalValue = some(true),
          help = "Whether the --target host is NixOS (`--nixos` alone is " &
            "true; `--nixos=false` states it is not); without --target the " &
            "machine's os-release says. A profile with a `nixos` guard is " &
            "refused (exit 3) for a --target without it"
        flag output is Option[string],
          help = "Write the document here instead of to standard output"
      subcmd "compare", help = "Compare a Nix-side and a Reprobuild-side " &
          "host-facts document per category (same, only-in-nix, " &
          "only-in-reprobuild, different, unmapped); exit 1 on a difference " &
          "not allowlisted or a stale allowlist row, 2 when they cannot be " &
          "compared":
        flag facts is seq[string],
          help = "A host-facts document; give exactly two, one per side"
        flag allow is seq[string],
          help = "A TOML allowlist of known differences (`[[allow]]` rows " &
            "with `category` and a non-empty `reason`; at most one file)"
        flag format is string, default = "text",
          help = "The output format: `text` or `json`"
        boolFlag showSame is bool, help = "Also list the entries that agree"
      subcmd "rollback", help = "Revert to a past generation (default: the " &
          "previous one)":
        boolFlag acceptOverwrite is bool,
          help = "Overwrite managed files edited since that generation"
        boolFlag uninstallFromScoop is bool,
          help = "Remove from Scoop the packages the rollback drops"
        pos generation is string, required = false,
          help = "The generation to roll back to"
      subcmd "gc", help = "Delete store prefixes no live generation " &
          "references":
        boolFlag dryRun is bool,
          help = "Print the candidates and their footprint; delete nothing"
        boolFlag force is bool, short = 'y',
          help = "Skip the confirmation prompt"
        flag keepGenerations is Option[int],
          help = "Keep the N most recent generations' prefixes (N >= 1, " &
            "default 2; the active generation is always kept)"
        flag store is string,
          help = "The store root (default: `$REPRO_STORE_ROOT`, else the " &
            "platform's)"
      subcmd "set", help = "Set a managed configurable in the profile's " &
          "`config:` section, then apply":
        flag whenPredicate is Option[string], perSource = [cli = "when"],
          help = "Guard the value with a runtime predicate"
        boolFlag noApply is bool,
          help = "Edit the profile only; do not apply afterwards"
        pos key is string, help = "`<package>.<configurable>`"
        pos value is string, help = "The value"
      subcmd "get", help = "Print a managed configurable's value in the " &
          "current generation":
        pos key is string, help = "`<package>.<configurable>`"
      subcmd "adopt", help = "Claim an existing object the profile declares " &
          "into management without changing it":
        pos address is string, help = "The resource address"
      subcmd "resource", help = "Edit resource records":
        subcmd "move", help = "Rename a resource record without re-applying":
          pos oldAddress is string, help = "The current address"
          pos newAddress is string, help = "The new address"
      subcmd "migrate-from-env-scripts", help = "Write the pins of a " &
          "`toolchain-versions.env` file into the profile as package " &
          "references":
        flag envFile is string,
          help = "A `toolchain-versions.env`-shaped file (default: " &
            "`$METACRAFT_ROOT/windows/toolchain-versions.env`; required " &
            "when METACRAFT_ROOT is unset)"
        flag activity is string, default = "migrated_from_env_scripts",
          help = "The activity block that receives the references (a Nim " &
            "identifier)"
        boolFlag dryRun is bool,
          help = "Print the proposed `home.nim` diff; write nothing"
      # The remote-apply steps repro runs of itself (locally, and on the
      # target over SSH).
      subcmd "__build-bundle", visibility = internal,
          help = "Build an activation bundle of a generation":
        boolFlag evaluate is bool,
          help = "Evaluate the profile for target facts first (implied by " &
            "the --target-* flags)"
        flag generation is Option[string],
          help = "The generation to bundle (default: `current`)"
        flag stateDir is string, help = "The home state directory"
        `homeBuildBundleStore`
        flag homeDir is string, help = "The home directory to evaluate for"
        flag out is string, help = "Also write the bundle here"
        flag targetHost is string, help = "The target host"
        `homeBuildBundlePlatform`
        flag targetWsl is Option[bool], optionalValue = some(true),
          help = "Whether the target is a WSL distribution"
      subcmd "__receive-bundle", visibility = internal,
          help = "Query or receive an activation bundle (the target side)":
        `homeReceiveBundleStore`
        flag query is string, help = "The bundle digest to look up"
        flag queryPrefix is seq[string], help = "A prefix to look up"
        flag expectedDigest is string, help = "The digest the bundle must have"
        flag bundle is string,
          help = "Read the bundle from this file instead of stdin"
      subcmd "__transfer-bundle", visibility = internal,
          help = "Send an activation bundle to a target over SSH":
        flag bundleDigest is string, help = "The bundle's digest"
        `homeTransferBundleStore`
        flag target is string, help = "The SSH destination"
        flag remoteRepro is string, default = "repro",
          help = "The `repro` the target runs"
        flag targetStoreRoot is string, help = "The target's store root"
        flag ssh is string, default = "ssh", help = "The ssh program"
        flag sshOption is seq[string], help = "An option passed to ssh"
        flag port is int, help = "The SSH port"
      subcmd "__remote-activate", visibility = internal,
          help = "Activate a received bundle (the target side)":
        `homeRemoteActivate`
    subcmd "system", help = "Manage the machine's system configuration":
      subcmd "add", help = "Add a resource to the system profile":
        `systemAddLocation`
        pos kind is string, help = "The resource kind"
        pos fields is seq[string], required = false,
          help = "The resource's fields, as `key=value`"
      subcmd "remove", help = "Remove a resource from the system profile":
        `systemRemoveLocation`
        pos address is string, help = "The resource address"
      subcmd "list", help = "List the system profile's resources":
        `systemListLocation`
        boolFlag json is bool,
          help = "Print the list as one JSON document (schema " &
            "reprobuild.system.list.v1)"
      subcmd "why", help = "Explain why a resource is in the system profile":
        `systemWhyLocation`
        pos address is string, help = "The resource address"
      subcmd "plan", help = "Compile the system profile and show what an " &
          "apply would change; writes nothing but the plan (the same " &
          "planner as `repro infra plan`)":
        `systemPlan`
      subcmd "apply", help = "Apply a plan `repro system plan` printed, as " &
          "a new system generation (the same applier as `repro infra " &
          "apply`)":
        `systemApply`
      subcmd "sync", help = "Plan and apply the system profile in one step":
        `systemSyncLocation`
        `systemSyncRegistry`
        `systemSyncDrift`
        boolFlag elevate is bool, negatable = true, default = true,
          help = "Run the privileged operations (`--no-elevate` skips them)"
        boolFlag acceptPasswdDestroy is bool,
          help = "Allow destroying user and group records"
        boolFlag forceUnlock is bool,
          help = "Take the apply lock even when another apply holds it"
      subcmd "history", help = "List the system generations":
        flag stateDir is string,
          help = "The system state directory (default: the platform's)"
        boolFlag json is bool,
          help = "Print the generations as one JSON document (schema " &
            "reprobuild.system.history.v1)"
      subcmd "rollback", help = "Re-apply a past system generation " &
          "(default: the previous one)":
        `systemRollbackLocation`
        `systemRollbackRegistry`
        `systemRollbackDrift`
        flag generation is string,
          help = "The generation, as an alternative to the positional"
        boolFlag acceptFeatureDestroy is bool,
          help = "Allow removing Windows optional features"
        boolFlag acceptPasswdDestroy is bool,
          help = "Allow destroying user and group records"
        boolFlag forceUnlock is bool,
          help = "Take the apply lock even when another apply holds it"
        pos target is string, required = false,
          help = "The generation to roll back to"
      subcmd "audit", help = "Print a generation's audit log (default: " &
          "the current one)":
        # `--profile` is accepted, as the page specifies, and not consulted
        # for the read.
        `systemAuditLocation`
        boolFlag json is bool,
          help = "Print the audit log as one JSON document (schema " &
            "reprobuild.system.audit.v1)"
        pos generation is string, required = false,
          help = "The generation"
      # The add-on's own command line (repro_addon/cli), shared with the
      # static add-on binary, which parses these.
      subcmd "addon", help = "Manage an add-on host (Linux)":
        pos args is seq[string], required = false, passThrough = true
      subcmd "state", help = "Save and restore the declared state set " &
          "(Linux)":
        pos args is seq[string], required = false, passThrough = true
      subcmd "secret", help = "Seal and materialise system secrets (Linux)":
        pos args is seq[string], required = false, passThrough = true
      subcmd "adopt", help = "Claim an object on an add-on host (Linux)":
        pos args is seq[string], required = false, passThrough = true
    subcmd "infra", help = "Plan and apply infrastructure":
      subcmd "plan", help = "Compile the system profile and show what an " &
          "apply would change; writes nothing but the plan":
        `infraPlan`
      subcmd "apply", help = "Apply a plan `repro infra plan` printed, as a " &
          "new system generation":
        `infraApply`
      subcmd "cache-keys", help = "Print the binary-cache entry key of every " &
          "build-action edge of the profile, for a platform":
        `infraCacheKeysLocation`
        flag platformCpu is Option[string],
          help = "The consuming host's CPU (default: this host's)"
        flag platformOs is Option[string],
          help = "The consuming host's OS (default: this host's)"
        flag platformAbi is Option[string],
          help = "The consuming host's ABI (default: this host's)"
        flag platformLibc is Option[string],
          help = "The consuming host's libc (default: this host's; empty " &
            "for none)"
      subcmd "install-root", help = "Mirror the live root onto a target " &
          "disk and make it bootable (the installer's last step)":
        flag target is string, default = "/mnt",
          help = "The mounted target root"
        flag source is string, default = "/", help = "The live root to mirror"
        flag device is string, help = "The disk GRUB is installed on"
        flag disko is string,
          help = "The disk layout the target's fstab is generated from"
        flag hostname is string, default = "reproos",
          help = "The target's host name"
        flag kernel is string, help = "The kernel image to install"
        flag initrd is string, help = "The initrd to install"
        flag exclude is seq[string],
          help = "Another path to leave out; repeat it for several"
        boolFlag noRsync is bool, help = "Skip the mirror step"
        boolFlag noGrub is bool, help = "Skip installing GRUB"
        boolFlag noFstab is bool, help = "Skip generating fstab"
        boolFlag dryRun is bool, help = "Print the steps; change nothing"
      subcmd "image", help = "Synthesise a ready-to-flash disk image of an " &
          "add-on host (Linux; needs no privilege)":
        `infraImageTarget`
        flag output is string, help = "The image to write (required)"
        flag compress is string, default = "none",
          help = "`xz` or `none`"
        flag debCache is string, help = "A cache directory for packages"
        flag workDir is string, help = "The working directory"
        boolFlag keepWork is bool, help = "Keep the working directory"
        flag assemblyTimeout is int, help = "The assembly timeout, in seconds"
    subcmd "anywhere", help = "Bootstrap a booted distribution host into " &
        "ReproOS add-on mode over SSH (Linux): without --expect-plan print " &
        "the plan and exit 3, with it apply":
      flag mode is string, help = "The mode: `addon`, the only one (required)"
      `anywhereTarget`
      flag knownHosts is string,
        help = "The SSH known-hosts file (required)"
      flag sshKey is string, help = "The SSH key"
      flag sshPort is int, help = "The SSH port"
      flag arch is string,
        help = "The host's architecture: amd64, arm64 or armhf (default: " &
          "the add-on binary's)"
      flag deploySigners is string, help = "The deploy signers file"
      flag cachePublishers is string, help = "The cache publishers file"
      flag cacheUrl is string, help = "The binary cache"
      flag agentTarget is string, help = "The deploy agent's target"
      flag manifest is seq[string],
        help = "A manifest the deploy agent polls; repeat it for several"
      flag pollInterval is int, help = "The deploy agent's poll interval (s)"
      flag expectPlan is string,
        help = "The plan digest acknowledged; apply only that plan"
      flag recipientOut is string,
        help = "Write the host's secrets recipient here"
      flag appliedProfileOut is string,
        help = "Write the applied profile here"
      pos destination is string, required = false,
        help = "`root@ADDRESS`, the SSH destination (required)"
    subcmd "deploy-agent", help = "Run one deploy-agent tick: poll the " &
        "manifests, verify them and apply the newest for the target":
      call:
        flag target is string, help = "The deployment target (required)"
        flag manifest is seq[string],
          help = "A manifest path or URL to poll (at least one); repeat it " &
            "for several"
        flag allowedSigners is string,
          help = "The allowed signers' public keys (required)"
        flag stateDir is string,
          help = "The agent's state directory (default: " &
            "`./.repro-deploy-agent`)"
        flag cacheRoot is string,
          help = "The fetch cache (default: `<state dir>/cache`)"
        `deployAgentHost`
        flag secretsKey is string,
          help = "The recipient key that opens sealed sections"
        flag secretsDir is string,
          help = "Where secrets are materialised (default: `<state " &
            "dir>/secrets`)"
        flag fetchTimeoutMs is int, default = 30_000,
          help = "The manifest fetch timeout, in milliseconds"
      subcmd "keygen", help = "Create the recipient key on this host (or " &
          "keep the existing one) and print its public key":
        flag secretsKey is string, help = "The key file (required)"
      subcmd "compile-profile", visibility = internal,
          help = "Compile a staged manifest profile and apply nothing":
        boolFlag stdio is bool,
          help = "Read the profile on stdin and print the result"
        boolFlag probeCCompiler is bool,
          help = "Print the compilers a compile would use, and compile nothing"
        flag staged is string, help = "The staged profile module"
        flag canonicalOut is string, help = "Write the canonical text here"
        flag actionsOut is string, help = "Write the build actions here"
        flag stateDir is string, help = "The compile state directory"
        flag digestOut is string, help = "Write the profile digest here"
        flag revisionOut is string, help = "Write the compiler revision here"
        `compileProfileHost`
        flag platform is string, help = "The target's platform"
        flag arch is string, help = "The target's architecture"
        flag systemMode is string, help = "`addOn` or `full`"
        flag systemActivities is seq[string], separator = ",",
          help = "The system activities, comma-separated"
    subcmd "hardware", help = "Probe the machine's hardware":
      subcmd "probe", help = "Render the live system's hardware as a " &
          "`hardware.nim` and write it (default: /etc/repro/hardware.nim)":
        boolFlag dryRun is bool,
          help = "Print the rendered source instead of writing it"
        flag output is string, help = "Write here instead of the default"
        boolFlag regenerate is bool,
          help = "Overwrite an existing file (otherwise refused, exit 2)"
    subcmd "disk", help = "Plan, apply and mount disk layouts":
      subcmd "plan", help = "Print the partition and mount plan of a layout":
        pos source is string, help = "The layout (`disko.nim`)"
      subcmd "apply", help = "Create the layout's partitions, filesystems " &
          "and pools (destructive; needs --confirm)":
        boolFlag confirm is bool,
          help = "Run it; without, print the plan and exit 2"
        flag device is string,
          help = "Only the disk whose device is this path"
        flag identity is string,
          help = "The identity document seeding the filesystem and GPT " &
            "identifiers (default: `<disko>.identity.json` beside the layout)"
        pos source is string, help = "The layout (`disko.nim`)"
      subcmd "mount", help = "Print the mount plan, and with --confirm mount it":
        flag target is string, help = "The mount prefix (required)"
        boolFlag confirm is bool, help = "Mount (otherwise only print)"
        pos source is string, help = "The layout (`disko.nim`)"
      subcmd "unmount", help = "Unmount the layout under a prefix":
        flag target is string, help = "The mount prefix (required)"
        pos source is string, help = "The layout (`disko.nim`)"
      subcmd "generate", help = "Generate a layout from a live system " &
          "(not implemented yet; exits 2)":
        flag probe is string, help = "The root to probe (default: `/`)"
      subcmd "image", help = "Build a disk image of a layout (not " &
          "implemented yet; exits 2)":
        flag output is string, help = "The image to write (required)"
        flag size is string, help = "The image size"
        pos source is string, help = "The layout (`disko.nim`)"
    # Not parsed from this description yet: its `--help` documents its exit
    # codes, which needs a command's long description (not in this clispec
    # yet).
    subcmd "attest",
        help = "Compute and check launch measurements of attested images":
      pos args is seq[string], required = false, passThrough = true
    subcmd "cargo", help = "Manage cargo target directories and run cargo " &
        "as a build edge":
      subcmd "gc", help = "Delete the cargo build units no recent cargo " &
          "invocation used (exit 75 while cargo holds the lock)":
        `cargoGcTargetDir`
        flag minAge is string,
          help = "Keep units written within this duration (`30m`, `36h`, " &
            "`14d`, `2w`, `0`; default 14d, also `$REPRO_CARGO_GC_MIN_AGE` " &
            "and `min_age` under `[cargo_gc]`)"
        boolFlag dryRun is bool,
          help = "Print what would be deleted, with byte counts"
        flag cargoHome is Option[string], optionalValue = some(""),
          help = "Also sweep `CARGO_HOME/registry/src` (`--cargo-home=DIR` " &
            "names it)"
      subcmd "record-live", help = "Record which units a `cargo " &
          "--message-format=json` invocation used":
        `cargoRecordLiveTargetDir`
        flag fromFile is string, perSource = [cli = "from"],
          help = "Read the stream from this file (default, or `-`: stdin)"
        boolFlag tee is bool, help = "Copy the stream to standard output"
      subcmd "run", help = "Run cargo as a build edge and report its final " &
          "products":
        flag width is int, short = 'j', help = "Passed to cargo as `-j`"
        flag products is string, help = "Write the products here"
        flag fragment is string,
          help = "Write a dynamic-graph fragment declaring the products here"
        flag actionId is string, help = "The action the fragment declares"
        flag relativeTo is string, help = "Write paths relative to this"
        boolFlag libs is bool, help = "Also list the project's rlibs"
        pos cargo is seq[string], required = false,
          help = "The cargo command, after `--`"
      # `repro cargo help`: the same as `repro cargo --help`.
      subcmd "help", visibility = hidden:
        pos topic is seq[string], required = false

    # ---- About repro itself ----------------------------------------------
    subcmd "pressure", help = "Show build-wait pressure from the RunQuota " &
        "daemon (exit 1 when it cannot be reached or predates it)":
      flag group is string,
        help = "Only the session groups of this name, and their sessions"
      boolFlag json is bool, help = "Print the daemon's answer as JSON"
    subcmd "health", help = "Diagnose the reprobuild environment; exit 1 " &
        "when any check fails":
      flag workspaceRoot is string,
        help = "The workspace (default: the current directory)"
      boolFlag json is bool, help = "Print the checks as JSON"
      boolFlag offline is bool, help = "Skip the forge identity probes"
      boolFlag fix is bool, help = "Perform the safe remediations"
      boolFlag verbose is bool, short = 'v', help = "Show every check's detail"
      pos project is string, required = false,
        help = "The project to diagnose (default: the workspace's)"
    subcmd "debug", help = "Inspect the filesystem monitor and artifacts":
      subcmd "io", help = "Filesystem monitoring":
        # The monitor's own command line (the io-mon library's, shared
        # with `repro internal io monitor`).
        subcmd "monitor", help = "Run a command under the filesystem " &
            "monitor, or inspect a monitor dependency file":
          pos args is seq[string], required = false, passThrough = true
      subcmd "artifact", help = "Decode an internal binary artifact":
        flag format is string,
          help = "The output format: `text` (the default) or `json`"
        boolFlag json is bool, help = "Shortcut for `--format=json`"
        pos path is string, help = "The artifact"
    subcmd "help", help = "Show the help of repro or of one command":
      boolFlag all is bool,
        help = "List every command, not only the daily ones (the page " &
          "`--help-all` prints)"
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
    # The older spelling of `repro home __remote-activate`.
    subcmd "__remote-activate", visibility = hidden:
      `remoteActivate`
  result = arrangeCommandGroups(result)

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

macro reproFlagEnv*(path: static[seq[string]];
                    name: static[string]): untyped =
  ## The environment variables the flag ``name`` of the command at ``path``
  ## declares, as an array literal; a compile error when there is no such
  ## flag or it declares none.
  let model = reproCommandLineModel()
  let at = model.commandNamed(path)
  if at < 0:
    error("repro command line: no command `" & $path & "`")
  result = nnkBracket.newTree()
  for p in model.commands[at].params:
    if p.name == name and p.kind == cpkFlag:
      for variable in p.env:
        result.add(newLit(variable))
  if result.len == 0:
    error("repro command line: flag `" & name & "` of `" & $path &
      "` declares no environment variable")
