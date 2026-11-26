## repro's command-line description implements its command specification:
## the two name the same commands, and, for every command whose parsing has
## moved onto the description, the same flags and environment variables.
##
## The specification's side is `tests/fixtures/cli-contract/spec-surface.tsv`,
## generated from the specification pages by
## `scripts/generate_cli_contract_fixture.py` (the pages are not part of this
## repository; see that script for what it extracts and why the fixture is
## committed). The description's side is computed here, at compile time, from
## `reproCommandLineDescription` itself: the same tree the engine's parser
## and the thin client are generated from.
##
## WHAT IS COMPARED. `CoveredCommands` lists the commands whose flags and
## environment variables are compared, and "every declared command is
## compared" holds it equal to every command the description declares (its
## hidden spellings aside: the top-level `__<name>` words and the namespaces'
## `help` words, which spell commands listed under their own names). It grew
## group by group as commands moved onto the description (the root; the first
## group: `help`, `version`,
## `completion`, `capabilities`, `show-conventions`; the second: `configs`,
## `tasks`, `graph`, `why`, `deps` with `deps refresh`, `stats`; the third:
## `daemon`, `store`, `cas`, `cache`, `bundle`, `reap`, `launch-plan`,
## `cert-signer`, `self` and their subcommands; the fourth: `home`,
## `system`, `infra`, `anywhere`, `deploy-agent`, `hardware`, `disk`,
## `cargo`, `health`, `debug` and their subcommands; the fifth: `exec`,
## `run`, `shell`, `allow`, `deny`, `dev-env`, `up`, `down`, `dev`, `hcr`,
## `prompt` and their subcommands; the sixth: the workspace and publication
## commands; the seventh: the build family, `build`, `bench`, `lint`,
## `clean`, `test`, `certify`, `certificates`, `ci`, `watch`; of the eighth,
## `attest` and its subcommands, then every other command: the role
## processes under `internal`, the internal steps of `home` and `hooks`, the
## daemons' subcommands, `pressure`, and the command lines of other programs
## repro mounts, the add-on's and io-mon's, with every verb below them). A
## new command is added here and in the generator's `COVERED_COMMANDS`. A
## namespace's flags are accepted by each of its subcommands, so a flag a page
## documents at a subcommand matches the namespace's declaration, and the
## other way round (`sameAtAncestor`). The top-level command list is compared
## in full. Both comparisons run
## against explicit lists of known differences that may only shrink: a
## difference that is no longer there fails the test until its entry is
## removed. The only differences are flags and environment variables a page
## specifies that are not implemented yet (`SpecifiedNotImplemented`); one is
## declared when it is implemented, and its entry goes then. A page states a
## command-line input variable in the list item of the flag it supplies, in an
## `environment:` clause, and the generator records only those: a variable a
## page mentions anywhere else (one the command reads below its command line,
## carries to the actions it runs, or a constant a page writes as code) is not
## an input of the command line, and is compared on neither side.
##
## `--help` and `-h` are compared on neither side: the parser builds them into
## every command. `--help-all`, which the parser builds in only when a
## command is declared `secondary`, is compared at the root (see
## `surfaceOf`).
##
## The falsifying mutations prove the comparison can fail: the description
## with one flag's declaration removed, and with one command's declaration
## removed, must each produce exactly the difference that names it.
##
## No mocks: the description is the real one, parsed by the real clispec
## model parser.

import std/[algorithm, macros, os, sets, strutils, unittest]

import clispec/[model, dsl]

import repro_cli_support/cli_description

const
  CoveredCommands = [
    "repro", "repro help", "repro version", "repro completion",
    "repro capabilities", "repro show-conventions", "repro configs",
    "repro tasks", "repro graph", "repro why", "repro deps",
    "repro deps refresh", "repro stats",
    # The third group (stores and daemons).
    "repro daemon", "repro store", "repro store gc", "repro store recover",
    "repro store roots", "repro store list", "repro store optimise",
    "repro store materialize", "repro store closure", "repro store export",
    "repro store import", "repro store copy", "repro store daemon",
    "repro store serve", "repro cas", "repro cas gc", "repro cas verify",
    "repro cas path", "repro cas exists", "repro cache",
    "repro cache lookup", "repro cache substitute", "repro cache publish",
    "repro cache derive-key", "repro cache gen-key", "repro cache key",
    "repro cache explain", "repro cache sharing", "repro bundle",
    "repro bundle create", "repro bundle publish", "repro bundle restore",
    "repro bundle inspect",
    "repro reap", "repro launch-plan", "repro launch-plan show",
    "repro launch-plan id", "repro cert-signer", "repro cert-signer serve",
    "repro cert-signer registration", "repro self", "repro self install",
    "repro self provision", "repro self hold", "repro self which",
    "repro self list", "repro self prune-roots",
    # The fourth group (machines). `attest` is still parsed by its own code;
    # the commands that hand their arguments to another command line
    # (`system addon|state|secret|adopt`, `debug io monitor`) and the
    # internal remote-apply steps (`home __build-bundle`, ...) are not
    # compared yet.
    "repro home", "repro home add", "repro home remove", "repro home enable",
    "repro home disable", "repro home list", "repro home why",
    "repro home history", "repro home apply", "repro home plan",
    "repro home export", "repro home facts", "repro home compare",
    "repro home rollback", "repro home gc", "repro home set",
    "repro home get", "repro home adopt", "repro home resource",
    "repro home resource move", "repro home migrate-from-env-scripts",
    "repro system", "repro system add", "repro system remove",
    "repro system list", "repro system why", "repro system plan",
    "repro system apply", "repro system sync",
    "repro system history", "repro system rollback", "repro system audit",
    "repro infra", "repro infra plan", "repro infra apply",
    "repro infra cache-keys", "repro infra install-root", "repro infra image",
    "repro anywhere", "repro deploy-agent", "repro deploy-agent keygen",
    "repro deploy-agent compile-profile", "repro hardware",
    "repro hardware probe", "repro disk", "repro disk plan",
    "repro disk apply", "repro disk mount", "repro disk unmount",
    "repro disk generate", "repro disk image", "repro cargo",
    "repro cargo gc", "repro cargo record-live", "repro cargo run",
    "repro health", "repro debug", "repro debug artifact",
    # The fifth group (development environments).
    "repro exec", "repro run", "repro shell", "repro shell hook",
    "repro allow", "repro deny", "repro dev-env", "repro dev-env export",
    "repro dev-env deactivate", "repro up", "repro down", "repro dev",
    "repro hcr", "repro hcr coordinate", "repro hcr prepare-object",
    "repro prompt", "repro prompt init",
    # The sixth group (workspaces and publication, `develop` and `flake`
    # included). The internal subcommands the managed hooks run (`hooks
    # protocol|dispatch|cache-push`) are not compared.
    "repro workspace", "repro workspace restore", "repro workspace init",
    "repro workspace bootstrap", "repro workspace enable",
    "repro workspace disable", "repro workspace sets",
    "repro workspace sets list", "repro workspace sets resolve",
    "repro workspace sets add", "repro workspace sets remove",
    "repro workspace projects", "repro workspace projects list",
    "repro workspace projects resolve", "repro workspace projects add",
    "repro workspace projects remove", "repro workspace repos",
    "repro workspace repos list", "repro workspace repos add",
    "repro workspace repos remove", "repro workspace add",
    "repro workspace remove", "repro workspace status",
    "repro workspace lock", "repro workspace list",
    "repro workspace manifests", "repro workspace branch-roles",
    "repro workspace forall", "repro workspace shared-clones",
    "repro workspace sync", "repro workspace pull", "repro workspace new",
    "repro workspace switch", "repro workspace provision",
    "repro workspace migrate", "repro workspace migrate-locks",
    "repro workspace publish-evidence", "repro sync", "repro pull",
    "repro branch", "repro switch", "repro push", "repro check",
    "repro hooks", "repro hooks ensure", "repro hooks reinstall",
    "repro hooks uninstall", "repro lock", "repro lock list",
    "repro lock solve", "repro lock refresh", "repro lock update",
    "repro lock validate", "repro lock diff", "repro lock explain",
    "repro locking", "repro locking explain", "repro locking adopt-manifest",
    "repro gateway", "repro gateway pre-receive",
    "repro gateway post-receive", "repro gateway migrate", "repro add",
    "repro remove", "repro develop", "repro flake",
    "repro flake override-args", "repro flake refresh-lock",
    "repro flake override-status",
    # The seventh group (the build family).
    "repro build", "repro bench", "repro lint", "repro clean", "repro test",
    "repro certify", "repro certificates", "repro certificates list",
    "repro certificates plan", "repro certificates policy", "repro ci",
    "repro ci plan", "repro watch",
    # The eighth group, round 8a: `attest` (the rest of the fourth group,
    # which waited for a command's long help). `system addon|state|secret|
    # adopt` and `debug io monitor` are not compared: they declare only the
    # rest of the command line, which the add-on's and io-mon's own command
    # lines parse, so the flags their pages write are those programs'.
    "repro attest", "repro attest expect", "repro attest challenge",
    "repro attest verify", "repro attest cross-check", "repro attest launch",
    "repro attest reap",
    # The eighth group, round 8b: every other command, so the list is every
    # command repro declares (hidden spellings aside; "every declared command
    # is compared"): the daemon's and the store daemon's subcommands, the
    # internal steps of a remote home apply and of the managed hooks, the
    # role processes (`internal`), `pressure`, and (round 8c) the command
    # lines of other programs mounted in repro's (`system addon|state|
    # secret|adopt`, the add-on's; `debug io monitor`, `internal io
    # monitor`, io-mon's), with every verb.
    "repro daemon serve", "repro daemon start", "repro daemon status",
    "repro daemon stop", "repro daemon restart", "repro daemon sessions",
    "repro daemon logs", "repro store daemon start",
    "repro store daemon status", "repro store daemon stop",
    "repro home __build-bundle", "repro home __receive-bundle",
    "repro home __transfer-bundle", "repro home __remote-activate",
    "repro system addon", "repro system addon preflight",
    "repro system addon bootstrap", "repro system addon evidence-ship",
    "repro system addon evidence-enrol", "repro system addon store-verify",
    "repro system addon egress-check", "repro system addon evidence-harvest",
    "repro system addon evidence-credential-check",
    "repro system addon uninstall",
    "repro system addon verify-discard-record", "repro system addon verify",
    "repro system addon boot-confirm", "repro system addon reassert",
    "repro system addon recover", "repro system addon secrets",
    "repro system addon probe", "repro system addon secret",
    "repro system addon secret put",
    "repro system addon rotate-recipient-key",
    "repro system addon image-assemble", "repro system addon agent-repin",
    "repro system addon agent-tick", "repro system addon agent-fetch",
    "repro system addon agent-apply", "repro system addon migration-plan",
    "repro system addon resume", "repro system addon migrate",
    "repro system addon contain", "repro system addon release",
    "repro system addon fingerprint", "repro system addon fingerprint diff",
    "repro system addon expected-delta", "repro system addon ledger",
    "repro system addon import", "repro system addon state",
    "repro system addon state backup", "repro system addon state release",
    "repro system addon state verify", "repro system addon state restore",
    "repro system addon state digest", "repro system addon state unit",
    "repro system addon state install-unit", "repro system addon status",
    "repro system addon retention", "repro system addon selfcheck-btrfs",
    "repro system addon selfcheck-write", "repro system state",
    "repro system state backup", "repro system state release",
    "repro system state verify", "repro system state restore",
    "repro system state digest", "repro system state unit",
    "repro system state install-unit", "repro system secret",
    "repro system secret put", "repro system secret materialise",
    "repro system adopt", "repro debug io", "repro debug io monitor",
    "repro debug io monitor run", "repro debug io monitor inspect",
    "repro hooks protocol", "repro hooks dispatch", "repro hooks cache-push",
    "repro pressure", "repro internal",
    "repro internal shared-pool-upload-pack",
    "repro internal resolve-package", "repro internal io",
    "repro internal io monitor", "repro internal io monitor run",
    "repro internal io monitor inspect", "repro internal runquota-helper",
    "repro internal compile-provider", "repro internal extract-interface",
    "repro internal compile-profile",
    "repro internal probe-profile-platforms",
    "repro internal dev-env-introspect",
    "repro internal render-dev-env-shell", "repro internal direnv-activate",
    "repro internal native-shell-activate",
    "repro internal dev-session-supervisor",
    "repro internal dev-session-http", "repro internal cmake-regenerate",
    # Declared with its page after the round: `repro catalog publish`.
    "repro catalog", "repro catalog publish",
    # The Nimble index generator's verbs.
    "repro catalog generate", "repro catalog verify",
    # The Nimble package catalog's client verbs.
    "repro nimble", "repro nimble verify",
    # One provisioned tool of the project, realized on its own.
    "repro tool", "repro tool realize",
    # Declared after `repro tool`; in the generator's order, which the
    # fixture's rows follow (`scripts/generate_cli_contract_fixture.py`).
    "repro nimble check", "repro nimble develop",
    "repro nimble gitlink-audit"]
    ## The commands whose flags and environment variables are compared:
    ## every command repro declares.
  SpecifiedNotImplemented = [
    # `repro stats`' common options beyond the first implementation.
    "flag\trepro stats\t--db", "flag\trepro stats\t--metric-group",
    "flag\trepro stats\t--redact", "flag\trepro stats\t--runs",
    "flag\trepro stats\t--since", "flag\trepro stats\t--watch-session",
    # The proposed V1 surface of `repro infra plan|apply` beyond the system
    # profile commands implemented today.
    "flag\trepro infra apply\t--activity", "flag\trepro infra apply\t--json",
    "flag\trepro infra apply\t--staged", "flag\trepro infra apply\t--yes",
    "flag\trepro infra plan\t--activity", "flag\trepro infra plan\t--strict",
    # The proposed surface of `repro dev` beyond what is implemented: a cap
    # on how long repeated changes may postpone a cycle, and hot code
    # reloading (which `repro watch --hcr` implements).
    "flag\trepro dev\t--max-debounce", "flag\trepro dev\t--hcr",
    "flag\trepro dev\t--hcr-debug", "flag\trepro dev\t--hcr-mode",
    # The proposed `repro lock solve` options.
    "flag\trepro lock solve\t--activity", "flag\trepro lock solve\t--dry-run",
    # `repro build`'s `--no-write-stats` (turn the raw observation capture
    # off for one build): specified, not implemented yet (its issue is the
    # derived stats store's).
    "flag\trepro build\t--no-write-stats",
    # The proposed V1 surface of `repro watch` beyond what is implemented
    # (`--debounce-ms` is): task and tier selection, an explicit `--target`,
    # a debounce duration and its cap, the HTTP session and a start without
    # the initial cycle.
    "flag\trepro watch\t--debounce", "flag\trepro watch\t--http",
    "flag\trepro watch\t--max-debounce", "flag\trepro watch\t--no-initial",
    "flag\trepro watch\t--target", "flag\trepro watch\t--task",
    "flag\trepro watch\t--tier"]
    ## Flags a covered command's page specifies that repro does not
    ## implement yet.
  SpecifiedNotDeclared = [
    "audit", "info", "init", "list", "lsp", "mcp", "outdated", "package",
    "search", "upgrade"]
    ## Commands the specification describes that repro does not have yet.
  DeclaredNotSpecified: array[0, string] = []
    ## Commands repro has whose specification is not a command page (some
    ## are specified only in design documents). Empty: every command repro
    ## has is specified by a page. An entry may be added only with the
    ## command, and the test then requires it to be removed once a page exists.
  BuiltInFlags = ["--help", "-h"]

proc paramName(stmt: NimNode): string =
  ## The name a `flag`/`boolFlag`/`pos` declaration declares, or "".
  if stmt.kind notin {nnkCommand, nnkCall} or stmt.len < 2:
    return ""
  if not (stmt[0].eqIdent("flag") or stmt[0].eqIdent("boolFlag") or
      stmt[0].eqIdent("pos")):
    return ""
  let head = stmt[1]
  if head.kind == nnkInfix and head[0].eqIdent("is"):
    return $head[1]
  if head.kind == nnkIdent:
    return $head
  ""

proc commandWord(stmt: NimNode): string =
  ## The word a `subcmd "<word>"` declaration declares, or "".
  if stmt.kind in {nnkCommand, nnkCall} and stmt.len >= 2 and
      stmt[0].eqIdent("subcmd") and stmt[1].kind == nnkStrLit:
    return stmt[1].strVal
  ""

proc removeDeclaration(scope: NimNode; command, name: string): bool =
  ## Removes one declaration from `scope` (see `withoutDeclaration`),
  ## looking into the `group` sections the shown top-level commands stand
  ## in; whether it found it.
  for i in 0 ..< scope.len:
    let stmt = scope[i]
    if stmt.kind == nnkCommand and stmt.len == 3 and
        stmt[0].eqIdent("group") and stmt[^1].kind == nnkStmtList:
      if removeDeclaration(stmt[^1], command, name):
        return true
      continue
    if commandWord(stmt) != command:
      continue
    if name.len == 0:
      scope.del(i)
      return true
    let body = stmt[^1]
    for j in 0 ..< body.len:
      if paramName(body[j]) == name:
        body.del(j)
        return true
  false

proc withoutDeclaration(body: NimNode; command, name: string): NimNode =
  ## The description with one declaration removed: parameter `name` of the
  ## top-level command `command`, or (`name` empty) the command itself.
  result = body.copyNimTree()
  if not removeDeclaration(result, command, name):
    error("no declaration " & command & "/" & name & " to remove")

proc removeDeclarationAt(scope: NimNode; path: openArray[string];
                         name: string): bool =
  ## Removes parameter `name` of the command at `path` (its subcommand
  ## words, for a command below the top level, such as a verb of a mounted
  ## command line; the word `call:` names the `call:` of the command before
  ## it) from `scope`, looking into the `group` sections as
  ## `removeDeclaration` does; whether it found it.
  for i in 0 ..< scope.len:
    let stmt = scope[i]
    if stmt.kind == nnkCommand and stmt.len == 3 and
        stmt[0].eqIdent("group") and stmt[^1].kind == nnkStmtList:
      if removeDeclarationAt(stmt[^1], path, name):
        return true
      continue
    let isCall = stmt.kind == nnkCall and stmt.len == 2 and
      stmt[0].eqIdent("call") and stmt[1].kind == nnkStmtList
    if (if path[0] == "call:": not isCall else: commandWord(stmt) != path[0]):
      continue
    let body = stmt[^1]
    if path.len > 1:
      return removeDeclarationAt(body, path[1 .. ^1], name)
    for j in 0 ..< body.len:
      if paramName(body[j]) == name:
        body.del(j)
        return true
  false

proc removeEnv(scope: NimNode; command, name: string): bool =
  ## Removes the `env = ...` of parameter `name` of the top-level command
  ## `command` from `scope`, looking into the `group` sections as
  ## `removeDeclaration` does; whether it found it.
  for i in 0 ..< scope.len:
    let stmt = scope[i]
    if stmt.kind == nnkCommand and stmt.len == 3 and
        stmt[0].eqIdent("group") and stmt[^1].kind == nnkStmtList:
      if removeEnv(stmt[^1], command, name):
        return true
      continue
    if commandWord(stmt) != command:
      continue
    let body = stmt[^1]
    for j in 0 ..< body.len:
      if paramName(body[j]) == name:
        for k in countdown(body[j].len - 1, 2):
          if body[j][k].kind == nnkExprEqExpr and
              body[j][k][0].eqIdent("env"):
            body[j].del(k)
            return true
  false

proc withoutEnv(body: NimNode; command, name: string): NimNode =
  ## The description with the `env = ...` of parameter `name` of the
  ## top-level command `command` removed: the flag stays, the variables it
  ## declares go.
  result = body.copyNimTree()
  if not removeEnv(result, command, name):
    error("no `env` of " & command & "/" & name & " to remove")

proc surfaceOf(body: NimNode): seq[string] =
  ## The description's side, as the fixture's rows: `verb <word>` for each
  ## top-level command that is not hidden, then `flag`/`env` rows of every
  ## named command and of the root (whose flags its `call:` declares).
  ##
  ## `--help-all` is the one built-in spelling compared: clispec accepts it
  ## only in a program that declares a `secondary` command (and then at
  ## every command, where a command without one gives `--help`'s page), so
  ## it is a row of the root, where the specification names it, exactly
  ## when the description declares one.
  let model = parseCliModel[NoCliExtension, ReproCommandLineParamExt](body,
    NoCliExtension())
  for cmd in model.commands:
    if not cmd.anonymous and cmd.path.len == 1 and
        cmd.visibility != cvHidden:
      result.add("verb\t" & cmd.name)
  for cmd in model.commands:
    if not cmd.anonymous and cmd.tier == ctSecondary:
      result.add("flag\trepro\t--help-all")
      break
  for cmd in model.commands:
    # A `call:` holds the flags of the command it belongs to (the root's
    # own, or a namespace's that runs without a subcommand, such as `repro
    # deploy-agent`), so its rows are that command's.
    let path = ("repro " & cmd.path.join(" ")).strip()
    for p in cmd.params:
      if p.declaredIn != cmd.path:
        continue
      for spelling in flagSpellings(p):
        if spelling notin BuiltInFlags:
          result.add("flag\t" & path & "\t" & spelling)
      for name in p.env:
        result.add("env\t" & path & "\t" & name)
  result.sort()

macro declaredCommandPaths(): untyped =
  ## Every command the description declares, as `repro <words>`: the
  ## internal ones included (the role processes, the managed hooks' entry
  ## points), the hidden SPELLINGS left out, since each spells a command
  ## listed under its own name: the top-level `__<name>` words (`__repro-<name>`
  ## is `internal <name>`, `__remote-activate` is `home __remote-activate`)
  ## and the `help` word of a namespace (`repro <namespace> help` is `repro
  ## help <namespace>`). A hidden command that spells nothing else
  ## (`workspace projects`) is compared like any other.
  let model = parseCliModel[NoCliExtension, ReproCommandLineParamExt](
    reproCommandLineDescription(), NoCliExtension())
  var hidden: seq[seq[string]] = @[]
  for cmd in model.commands:
    if not cmd.anonymous and cmd.visibility == cvHidden and cmd.path.len > 0 and
        (cmd.path[^1] == "help" or
         (cmd.path.len == 1 and cmd.path[0].startsWith("__"))):
      hidden.add(cmd.path)
  result = nnkBracket.newTree(newLit("repro"))
  for cmd in model.commands:
    if cmd.anonymous or cmd.path.len == 0:
      continue
    var underHidden = false
    for h in hidden:
      if cmd.path.len >= h.len and cmd.path[0 ..< h.len] == h:
        underHidden = true
    if not underHidden:
      result.add(newLit(("repro " & cmd.path.join(" ")).strip()))

const DeclaredCommands = declaredCommandPaths()
  ## Every command repro declares, its hidden spellings left out.

macro declaredSurface(command, name: static[string];
                      mutate: static[bool]): untyped =
  var body = reproCommandLineDescription()
  if mutate:
    body = withoutDeclaration(body, command, name)
  newLit(surfaceOf(body))

const
  Declared = declaredSurface("", "", false)
  WithoutCapabilitiesFormat = declaredSurface("capabilities", "format", true)
  WithoutConfigs = declaredSurface("configs", "", true)
  # A flag of a shared group (spliced into `why`, `graph` and `stats`): the
  # comparison sees the flag in each command it is spliced into.
  WithoutWhyToolProvisioning = declaredSurface("why", "toolProvisioning",
    true)
  # A namespace's own flag (inherited by every `repro daemon` subcommand).
  WithoutDaemonEndpoint = declaredSurface("daemon", "endpoint", true)
  # A command of the fourth group, compared since its parsing moved.
  WithoutHealthFix = declaredSurface("health", "fix", true)
  # A command of the fifth group, compared since its parsing moved.
  WithoutDownStopTimeout = declaredSurface("down", "stopTimeout", true)
  # A command of the sixth group, compared since its parsing moved: the
  # pre-push gate's own input.
  WithoutCheckPushedRefs = declaredSurface("check", "pushedRefs", true)
  # `repro develop`, compared since its parsing moved: a flag of the
  # develop-set selection it shares with the `repro flake` verbs, removed
  # from `develop` alone.
  WithoutDevelopReset = declaredSurface("develop", "reset", true)
  # `repro build`, compared since its parsing moved: a flag of the
  # declaration `bench` and `lint` share, with the environment variable it
  # declares, removed from `build` alone.
  WithoutBuildDaemon = declaredSurface("build", "daemon", true)

macro declaredSurfaceWithoutAt(paths: static[seq[seq[string]]];
                               name: static[string]): untyped =
  ## The description's side with parameter `name` removed from the command
  ## at each of `paths`.
  var body = reproCommandLineDescription().copyNimTree()
  for path in paths:
    if not removeDeclarationAt(body, path, name):
      error("no declaration " & $path & "/" & name & " to remove")
  newLit(surfaceOf(body))

const
  # The mounted command lines (round 8c): a flag of an add-on verb, spliced
  # from the add-on's description; and a flag of io-mon's, spliced from
  # io-mon's under `debug io monitor`, removed from both places it is
  # declared there (`run` and the bare form's `call:`, which would each
  # match the other's page row as a namespace's flag does); its copy under
  # `internal io monitor` stays.
  WithoutAddonPreflightJson = declaredSurfaceWithoutAt(
    @[@["system", "addon", "preflight"]], "json")
  WithoutDebugMonitorDepfile = declaredSurfaceWithoutAt(
    @[@["debug", "io", "monitor", "run"], @["debug", "io", "monitor", "call:"]],
    "depfile")

macro declaredSurfaceWithoutEnv(command, name: static[string]): untyped =
  newLit(surfaceOf(withoutEnv(reproCommandLineDescription(), command, name)))

const
  # `repro watch`, compared since its parsing moved: one of its own flags,
  # and the variable its `--daemon` declares with the flag kept.
  WithoutWatchDebounceMs = declaredSurface("watch", "debounceMs", true)
  WithoutWatchDaemonEnv = declaredSurfaceWithoutEnv("watch", "daemon")

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while not fileExists(dir / "repro_tests.nim"):
    let parent = dir.parentDir
    doAssert parent != dir, "cannot locate the reprobuild repository root"
    dir = parent
  dir

proc specified(): seq[string] =
  ## The fixture's rows, comments dropped.
  for line in readFile(repoRoot() / "tests" / "fixtures" / "cli-contract" /
      "spec-surface.tsv").splitLines():
    if line.len > 0 and not line.startsWith("#"):
      result.add(line)

proc rowsOf(rows: openArray[string]; kinds: openArray[string]): HashSet[
    string] =
  for row in rows:
    let fields = row.split('\t')
    if fields[0] in kinds:
      if fields[0] == "verb" or fields[1] in CoveredCommands:
        result.incl(row)

proc sameAtAncestor(row: string; other: HashSet[string];
                    upwards: bool): bool =
  ## Whether ``other`` holds the `flag`/`env` row ``row`` at another command
  ## on the same line: an ancestor of its command when ``upwards``, else a
  ## descendant. A namespace's flags are accepted by each of its
  ## subcommands (`repro daemon --endpoint` is also `repro daemon start
  ## --endpoint`), so a page may document one where it is used and the
  ## description declare it on the namespace, or the other way round.
  let fields = row.split('\t')
  if fields.len != 3 or fields[0] notin ["flag", "env"]:
    return false
  for candidate in other:
    let o = candidate.split('\t')
    if o.len != 3 or o[0] != fields[0] or o[2] != fields[2] or
        o[1] == fields[1]:
      continue
    let (inner, outer) = if upwards: (fields[1], o[1]) else: (o[1], fields[1])
    if inner.startsWith(outer & " "):
      return true
  false

proc differences(declared, specified: openArray[string]): seq[string] =
  ## Every row one side has and the other does not, with the known command
  ## differences accounted for; and every known difference that is gone.
  ## A namespace's flag counts as the same row at each of its subcommands
  ## (``sameAtAncestor``).
  let spec = rowsOf(specified, ["verb", "flag", "env"])
  let decl = rowsOf(declared, ["verb", "flag", "env"])
  for row in spec - decl:
    if sameAtAncestor(row, decl, upwards = true):
      continue
    let fields = row.split('\t')
    if fields[0] == "verb" and fields[1] in SpecifiedNotDeclared:
      continue
    if row in SpecifiedNotImplemented:
      continue
    result.add(row & ": specified, not declared")
  for row in decl - spec:
    if sameAtAncestor(row, spec, upwards = false):
      continue
    let fields = row.split('\t')
    if fields[0] == "verb" and fields[1] in DeclaredNotSpecified:
      continue
    result.add(row & ": declared, not specified")
  for verb in SpecifiedNotDeclared:
    if "verb\t" & verb notin spec or "verb\t" & verb in decl:
      result.add("verb\t" & verb & ": no longer a difference; remove it " &
        "from SpecifiedNotDeclared")
  for row in SpecifiedNotImplemented:
    if row notin spec or row in decl:
      result.add(row & ": no longer a difference; remove it from " &
        "SpecifiedNotImplemented")
  for verb in DeclaredNotSpecified:
    if "verb\t" & verb notin decl or "verb\t" & verb in spec:
      result.add("verb\t" & verb & ": no longer a difference; remove it " &
        "from DeclaredNotSpecified")
  result.sort()

suite "CS-M6: the specification pages match the declarations":

  test "every declared command is compared":
    var covered = @CoveredCommands
    covered.sort()
    var declared = @DeclaredCommands
    declared.sort()
    for c in declared:
      if c notin covered:
        checkpoint("declared, not compared: " & c)
    for c in covered:
      if c notin declared:
        checkpoint("compared, not declared: " & c)
    check covered == declared

  test "the fixture covers the commands this test compares":
    var commands: seq[string] = @[]
    for row in specified():
      if row.startsWith("command\t"):
        commands.add(row.split('\t')[1])
    check commands == @CoveredCommands

  test "every command, flag and variable is in both the pages and the declarations":
    let diff = differences(Declared, specified())
    for d in diff:
      checkpoint(d)
    check diff.len == 0

  test "the comparison sees the declarations it compares":
    # A surface that lost its flags would agree with an empty fixture.
    check "flag\trepro capabilities\t--format" in Declared
    check "flag\trepro graph\t--tool-provisioning" in Declared
    check "flag\trepro deps refresh\t--check" in Declared
    check "flag\trepro store gc\t--budget" in Declared
    check "flag\trepro daemon\t--endpoint" in Declared
    check "flag\trepro cache publish\t--platform-cpu" in Declared
    check "flag\trepro\t-V" in Declared
    check "verb\tbuild" in Declared
    check "flag\trepro home\t--profile-dir" in Declared
    # A namespace's `call:` flags are its own (`repro deploy-agent`'s tick).
    check "flag\trepro deploy-agent\t--allowed-signers" in Declared
    # An `alias` is a spelling of its own.
    check "flag\trepro home apply\t--accept-overwrite" in Declared
    # The fifth group: a `call:`'s flags beside a subcommand (`shell`,
    # `prompt`), a subcommand's own (`shell hook`, `dev-env export`), and an
    # internal flag (listed by the pages, kept out of help).
    check "flag\trepro shell\t--print-env" in Declared
    check "flag\trepro shell hook\t--repro-bin" in Declared
    check "flag\trepro dev-env export\t--pre-activation-env" in Declared
    check "flag\trepro prompt\t--workspace-root" in Declared
    check "flag\trepro up\t--lock-slice" in Declared
    check "flag\trepro down\t--ready-timeout" notin Declared
    # The develop-set selection, shared by `develop` and the flake verbs.
    check "flag\trepro develop\t--except" in Declared
    check "flag\trepro flake override-status\t--lock-store" in Declared
    check "flag\trepro flake refresh-lock\t--record-downgrade" in Declared
    # The Nimble package catalog's lock flags (NPC-M6): a flag one lock verb
    # declares beside the shared ones, and one only `refresh` has.
    check "flag\trepro lock solve\t--exclude-newer" in Declared
    check "flag\trepro lock refresh\t--exclude-newer" in Declared
    check "flag\trepro lock refresh\t--allow-rewind" in Declared
    check "flag\trepro lock validate\t--allow-rewind" notin Declared
    check "verb\tws" notin Declared
    # The build family: a flag of the declaration `build`, `bench` and
    # `lint` share, in each of them, with the variable it declares.
    check "flag\trepro build\t--daemon" in Declared
    check "env\trepro build\tREPRO_DAEMON" in Declared
    check "flag\trepro lint\t--no-runquota" in Declared
    check "env\trepro bench\tREPROBUILD_NO_RUNQUOTA" in Declared
    check "flag\trepro build\t-vv" in Declared
    check "flag\trepro clean\t--project-root" in Declared
    # `repro test` and `repro certify` take `repro build`'s flags with their
    # own; `repro watch` and the `repro ci plan` branch declare variables.
    check "flag\trepro test\t--shard" in Declared
    check "flag\trepro test\t--only" in Declared
    check "env\trepro certify\tREPRO_DAEMON" in Declared
    check "flag\trepro certify\t--check-set-command" in Declared
    check "flag\trepro certificates plan\t--no-certify" in Declared
    check "env\trepro ci plan\tGITHUB_BASE_REF" in Declared
    check "env\trepro watch\tREPRO_DAEMON" in Declared
    check "flag\trepro watch\t--hcr-target" in Declared

  test "removing one flag's declaration fails the comparison":
    check "flag\trepro capabilities\t--format" notin
      WithoutCapabilitiesFormat
    check differences(WithoutCapabilitiesFormat, specified()) ==
      @["flag\trepro capabilities\t--format: specified, not declared"]

  test "removing a shared group's flag from one command fails the comparison":
    check differences(WithoutWhyToolProvisioning, specified()) ==
      @["flag\trepro why\t--tool-provisioning: specified, not declared"]

  test "removing a namespace's own flag fails the comparison":
    # At the namespace and at each subcommand whose page writes it: the
    # subcommands take the namespace's flags, and the pages document the
    # flag where it is used.
    check differences(WithoutDaemonEndpoint, specified()) ==
      @["flag\trepro daemon\t--endpoint: specified, not declared",
        "flag\trepro daemon logs\t--endpoint: specified, not declared",
        "flag\trepro daemon restart\t--endpoint: specified, not declared",
        "flag\trepro daemon start\t--endpoint: specified, not declared",
        "flag\trepro daemon status\t--endpoint: specified, not declared",
        "flag\trepro daemon stop\t--endpoint: specified, not declared"]

  test "removing a fourth-group command's flag fails the comparison":
    check differences(WithoutHealthFix, specified()) ==
      @["flag\trepro health\t--fix: specified, not declared"]

  test "removing a fifth-group command's flag fails the comparison":
    check differences(WithoutDownStopTimeout, specified()) ==
      @["flag\trepro down\t--stop-timeout: specified, not declared"]

  test "removing a sixth-group command's flag fails the comparison":
    check differences(WithoutCheckPushedRefs, specified()) ==
      @["flag\trepro check\t--pushed-refs: specified, not declared"]

  test "removing a flag of `repro develop` fails the comparison":
    check differences(WithoutDevelopReset, specified()) ==
      @["flag\trepro develop\t--reset: specified, not declared"]

  test "removing a flag of `repro build` fails the comparison":
    # The flag and the environment variable it declares, in `build` alone:
    # `bench` and `lint` splice their own copy of the declaration.
    check differences(WithoutBuildDaemon, specified()) ==
      @["env\trepro build\tREPRO_DAEMON: specified, not declared",
        "flag\trepro build\t--daemon: specified, not declared"]

  test "removing a flag of `repro watch` fails the comparison":
    check differences(WithoutWatchDebounceMs, specified()) ==
      @["flag\trepro watch\t--debounce-ms: specified, not declared"]

  test "removing the variable a flag declares fails the comparison":
    # The flag stays declared; only the variable that supplies its value
    # when it is absent goes.
    check "flag\trepro watch\t--daemon" in WithoutWatchDaemonEnv
    check differences(WithoutWatchDaemonEnv, specified()) ==
      @["env\trepro watch\tREPRO_DAEMON: specified, not declared"]

  test "removing a flag of a mounted command line fails the comparison":
    check "flag\trepro system addon preflight\t--json" in Declared
    check "flag\trepro system state verify\t--from" in Declared
    check "flag\trepro internal io monitor run\t--depfile" in Declared
    check differences(WithoutAddonPreflightJson, specified()) ==
      @["flag\trepro system addon preflight\t--json: specified, not declared"]
    check differences(WithoutDebugMonitorDepfile, specified()) ==
      @["flag\trepro debug io monitor\t--depfile: specified, not declared",
        "flag\trepro debug io monitor run\t--depfile: specified, not declared"]

  test "removing one command's declaration fails the comparison":
    check differences(WithoutConfigs, specified()) ==
      @["verb\tconfigs: specified, not declared"]
