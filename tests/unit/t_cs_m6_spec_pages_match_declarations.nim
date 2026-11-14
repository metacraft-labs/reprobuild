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
## from the description (the root, and the first group: `help`, `version`,
## `completion`, `capabilities`, `show-conventions`). Each later group of
## commands is added by listing it here and in the generator's
## `COVERED_COMMANDS`; the last one replaces the list with every command. The
## top-level command list is compared in full already, against two explicit
## lists of known differences that may only shrink: a difference that is no
## longer there fails the test until its entry is removed.
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
    "repro capabilities", "repro show-conventions"]
    ## The commands whose flags and environment variables are compared.
  SpecifiedNotDeclared = [
    "audit", "info", "init", "list", "lsp", "mcp", "outdated", "package",
    "search", "upgrade"]
    ## Commands the specification describes that repro does not have yet.
  DeclaredNotSpecified = [
    "allow", "anywhere", "cache", "cargo", "cas", "certificates",
    "cert-signer", "deny", "deploy-agent", "flake", "locking", "pull",
    "self"]
    ## Commands repro has whose specification is not a command page (some
    ## are specified only in design documents, `self` nowhere); each needs a
    ## page.
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
    let path = ("repro " & cmd.path.join(" ")).strip()
    if cmd.anonymous and cmd.path.len > 0:
      continue
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
    check "flag\trepro\t-V" in Declared
    check "verb\tbuild" in Declared
    check "verb\tws" notin Declared

  test "removing one flag's declaration fails the comparison":
    check "flag\trepro capabilities\t--format" notin
      WithoutCapabilitiesFormat
    check differences(WithoutCapabilitiesFormat, specified()) ==
      @["flag\trepro capabilities\t--format: specified, not declared"]

  test "removing one command's declaration fails the comparison":
    check differences(WithoutConfigs, specified()) ==
      @["verb\tconfigs: specified, not declared"]
