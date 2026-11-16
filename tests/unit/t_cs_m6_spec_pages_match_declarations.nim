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
## WHAT IS COMPARED, AND HOW IT GROWS. `CoveredCommands` lists the commands
## whose flags and environment variables are compared: the commands parsed
## from the description (the root; the first group: `help`, `version`,
## `completion`, `capabilities`, `show-conventions`; the second: `configs`,
## `tasks`, `graph`, `why`, `deps` with `deps refresh`, `stats`; the third:
## `daemon`, `store`, `cas`, `cache`, `bundle`, `reap`, `launch-plan`,
## `cert-signer`, `self` and their subcommands; the fourth: `home`,
## `system`, `infra`, `anywhere`, `deploy-agent`, `hardware`, `disk`,
## `cargo`, `health`, `debug` and their subcommands; the fifth: `exec`,
## `run`, `shell`, `allow`, `deny`, `dev-env`, `up`, `down`, `dev`, `hcr`,
## `prompt` and their subcommands). Each later
## group of commands is added by listing it here and in the generator's
## `COVERED_COMMANDS`; the last one replaces the list with every command. The
## top-level command list is compared in full already. Both comparisons run
## against explicit lists of known differences that may only shrink: a
## difference that is no longer there fails the test until its entry is
## removed. The only flag differences are flags a page specifies that are not
## implemented yet (`SpecifiedNotImplemented`); a flag is declared when it is
## implemented, and its entry goes then.
##
## `--help` and `-h` are compared on neither side: the parser builds them into
## every command.
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
    "repro cache derive-key", "repro cache gen-key", "repro bundle",
    "repro bundle create", "repro bundle publish", "repro bundle restore",
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
    "repro system list", "repro system why", "repro system sync",
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
    "repro prompt", "repro prompt init"]
    ## The commands whose flags and environment variables are compared.
  SpecifiedNotImplemented = [
    # `repro stats`' common options beyond the first implementation.
    "flag\trepro stats\t--db", "flag\trepro stats\t--metric-group",
    "flag\trepro stats\t--redact", "flag\trepro stats\t--runs",
    "flag\trepro stats\t--since", "flag\trepro stats\t--watch-session",
    # The proposed V1 surface of `repro infra plan|apply` beyond the system
    # profile commands implemented today.
    "flag\trepro infra apply\t--activity", "flag\trepro infra apply\t--json",
    "flag\trepro infra apply\t--staged", "flag\trepro infra apply\t--yes",
    "flag\trepro infra plan\t--activity", "flag\trepro infra plan\t--json",
    "flag\trepro infra plan\t--strict",
    # The proposed surface of `repro dev` beyond what is implemented: a cap
    # on how long repeated changes may postpone a cycle, and hot code
    # reloading (which `repro watch --hcr` implements).
    "flag\trepro dev\t--max-debounce", "flag\trepro dev\t--hcr",
    "flag\trepro dev\t--hcr-debug", "flag\trepro dev\t--hcr-mode"]
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

proc withoutDeclaration(body: NimNode; command, name: string): NimNode =
  ## The description with one declaration removed: parameter `name` of the
  ## top-level command `command`, or (`name` empty) the command itself.
  result = body.copyNimTree()
  for i in 0 ..< result.len:
    if commandWord(result[i]) != command:
      continue
    if name.len == 0:
      result.del(i)
      return
    let scope = result[i][^1]
    for j in 0 ..< scope.len:
      if paramName(scope[j]) == name:
        scope.del(j)
        return
  error("no declaration " & command & "/" & name & " to remove")

proc surfaceOf(body: NimNode): seq[string] =
  ## The description's side, as the fixture's rows: `verb <word>` for each
  ## top-level command that is not hidden, then `flag`/`env` rows of every
  ## named command and of the root (whose flags its `call:` declares).
  let model = parseCliModel[NoCliExtension, ReproCommandLineParamExt](body,
    NoCliExtension())
  for cmd in model.commands:
    if not cmd.anonymous and cmd.path.len == 1 and
        cmd.visibility != cvHidden:
      result.add("verb\t" & cmd.name)
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

proc differences(declared, specified: openArray[string]): seq[string] =
  ## Every row one side has and the other does not, with the known command
  ## differences accounted for; and every known difference that is gone.
  let spec = rowsOf(specified, ["verb", "flag", "env"])
  let decl = rowsOf(declared, ["verb", "flag", "env"])
  for row in spec - decl:
    let fields = row.split('\t')
    if fields[0] == "verb" and fields[1] in SpecifiedNotDeclared:
      continue
    if row in SpecifiedNotImplemented:
      continue
    result.add(row & ": specified, not declared")
  for row in decl - spec:
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
    check "verb\tws" notin Declared

  test "removing one flag's declaration fails the comparison":
    check "flag\trepro capabilities\t--format" notin
      WithoutCapabilitiesFormat
    check differences(WithoutCapabilitiesFormat, specified()) ==
      @["flag\trepro capabilities\t--format: specified, not declared"]

  test "removing a shared group's flag from one command fails the comparison":
    check differences(WithoutWhyToolProvisioning, specified()) ==
      @["flag\trepro why\t--tool-provisioning: specified, not declared"]

  test "removing a namespace's own flag fails the comparison":
    check differences(WithoutDaemonEndpoint, specified()) ==
      @["flag\trepro daemon\t--endpoint: specified, not declared"]

  test "removing a fourth-group command's flag fails the comparison":
    check differences(WithoutHealthFix, specified()) ==
      @["flag\trepro health\t--fix: specified, not declared"]

  test "removing a fifth-group command's flag fails the comparison":
    check differences(WithoutDownStopTimeout, specified()) ==
      @["flag\trepro down\t--stop-timeout: specified, not declared"]

  test "removing one command's declaration fails the comparison":
    check differences(WithoutConfigs, specified()) ==
      @["verb\tconfigs: specified, not declared"]
