## repro's command line is parsed by the parser generated from its
## description, not by hand: a source scan finds no argv comparison against a
## flag literal outside the description.
##
## WHAT COUNTS. In repro's command-line code (`apps/repro`,
## `apps/repro-client`, `libs/repro_cli_support/src`), a string literal that
## spells a flag (`"--name"`, `"-x"`, with or without `=` and a value) used
##
## * in a comparison: `arg == "--json"`, `"-h" != arg`;
## * in a membership test: `arg in ["--help", "-h"]`, `"--verify" in args`;
## * as a prefix: `arg.startsWith("--format=")`;
## * as a case branch: `of "--json":`;
## * as the flag a hand-written value reader takes:
##   `valueFromFlag(args, i, "--project")`, `flagMatches(arg, "--daemon")`.
##
## Comments and documentation comments are not code and are skipped. The
## description (`repro_cli_support/cli_description.nim`) is where flags are
## declared, so it is not scanned.
##
## HOW IT SHRINKS. Commands move onto the description group by group, so for
## now the files still holding hand-written parsing are listed in
## `Remaining` with the exact number of such comparisons each holds. The
## count is a ratchet in both directions: a file over its number has new
## hand-written parsing; a file under it has lost some, and its number must
## come down with it, so the list only ever shrinks. The final group empties
## it.
##
## The procs of the commands already parsed from the description must hold
## none at all, whichever file they live in (`MigratedProcs`).
##
## The positive control counts a fixture holding one instance of every shape
## above and the shapes that must not count, so the scan cannot pass by
## seeing nothing.
##
## No mocks: the scan reads the real source files.

import std/[algorithm, os, strutils, unittest]

const
  ScannedRoots = [
    "apps" / "repro", "apps" / "repro-client",
    "libs" / "repro_cli_support" / "src"]
  Description = "libs/repro_cli_support/src/repro_cli_support/cli_description.nim"
  Remaining = [
    # (file, hand-written argv comparisons against flag literals it holds).
    # `apps/repro-client/repro_client.nim` left this list in the first group:
    # its flag tables are generated from the description. The third group
    # emptied `bundle_cli.nim`, `selfhost.nim`, `store_bundle_cli.nim` and
    # `store_copy_cli.nim`; the fourth `anywhere.nim`, `cargo_gc.nim`,
    # `deploy_agent.nim`, `disk.nim`, `hardware.nim`, `home.nim` and
    # `infra_install_root.nim`; the fifth `dev_env_fast_path.nim` (the thin
    # client's `dev-env export` reader takes its flags from the
    # description); the sixth `workspace_restore.nim` (`repro workspace
    # restore` takes its values from the description), and the sixth's
    # `develop` and `flake` took this file from 502 to 343, and the seventh
    # group's `build` (with `bench` and `lint`) and `clean` from 343 to
    # 221. What `infra.nim` and `infra_image.nim` still hold is no argv
    # parsing (a `git describe` suffix, a table of the flags a bootstrap
    # names), but it has the shape the scan counts.
    ("libs/repro_cli_support/src/repro_cli_support.nim", 221),
    ("libs/repro_cli_support/src/repro_cli_support/attest.nim", 96),
    ("libs/repro_cli_support/src/repro_cli_support/infra.nim", 1),
    ("libs/repro_cli_support/src/repro_cli_support/infra_image.nim", 1),
    ("libs/repro_cli_support/src/repro_cli_support/project_pins.nim", 4),
  ]
  MigratedProcs = [
    # The commands parsed from the description. The first group:
    # `version`, `capabilities`, `show-conventions`, `completion` (and
    # `help`, which has no proc of its own besides the dispatcher's
    # `runReproHelp`).
    "runVersionCommand", "runCapabilitiesCommand",
    "runShowConventionsCommand", "runCompletionCommand", "runReproHelp",
    "runReproCommandLine",
    # The second group: `configs`, `tasks`, `deps refresh`, `stats`,
    # `graph`, `why`, and the format choice `graph` and `why` share.
    "runConfigsCommand", "runReproTasksCommand", "runDepsRefreshCommand",
    "runStatsCommand", "runGraphCommand", "runWhyCommand",
    "inspectionFormat",
    # The third group: `daemon`, `store`, `cas`, `cache`, `bundle`, `reap`,
    # `launch-plan`, `cert-signer`, `self` (their submodules,
    # `store_bundle_cli`, `store_copy_cli`, `bundle_cli` and `selfhost`,
    # left `Remaining` with nothing to parse).
    "runUserDaemonCliCommand", "userDaemonConfigOf", "runStoreCommand",
    "runStoreDaemonCommand", "runStoreServeCommand", "runCasCommand",
    "parseCasDigest", "runCacheCommand",
    "runBundleCliCommand", "namespaceHelpText", "runReapCommand",
    "runLaunchPlanCommand", "runCertSignerCommand", "runSelfCommand",
    # The fourth group (machines) whose procs live here: `health`, `debug
    # artifact`. Its other commands' modules (`home`, `infra`, `disk`,
    # `hardware`, `cargo_gc`, `deploy_agent`, `anywhere`,
    # `infra_install_root`) left `Remaining` above.
    "healthArgsOf", "runHealthCommand", "runDebugArtifactCommand",
    # The fifth group (development environments): `exec`, `run`, `shell`
    # with `shell hook`, `allow`, `deny`, `dev-env export|deactivate`, `up`,
    # `dev`, `down`, `hcr coordinate|prepare-object`, `prompt` with `prompt
    # init`. (`devSessionStartOf`, generic over `up`'s and `dev`'s
    # configuration, is not found by `procBody`; it reads typed fields
    # only.)
    "devEnvSelectionOf", "reproRunOf", "runReproRunCommand",
    "runReproExecCommand", "runReproShellCommand", "runShellHookCommand",
    "runReproAllowCommand", "runReproDenyCommand", "devEnvExportOf",
    "runDevEnvExportCommand", "runDevEnvDeactivateCommand",
    "devSessionCommandOf", "resolveDevSessionCommand", "runUpOrDevCommand",
    "runDownCommand", "runHcrCoordinateCommand", "runHcrPrepareObjectCommand",
    "promptArgsOf", "runPromptCommand", "runPromptInitCommand",
    # The sixth group (workspaces and publication): `hooks` (and the managed
    # hooks' internal `protocol`, `dispatch`, `cache-push`), `check`, `push`,
    # `workspace` with every subcommand, `lock`, `locking`, `gateway`, `add`,
    # `remove`; `sync`, `pull`, `branch` and `switch` share the generic
    # readers of their `workspace` spellings (`syncArgsOf`, `pullArgsOf`,
    # `branchArgsOf`, `switchArgsOf`, `roleChoiceOf`, `applyRepoSelection`,
    # `reportSpecOf`, `hooksCommandOf`, `lockVerbInputsOf`), which
    # `procBody` does not find; they read typed fields only.
    "runHooksCommand", "runHooksProtocolCommand", "runHooksDispatchCommand",
    "runCachePushCommand", "checkArgsOf", "resolveCheckScope", "pushArgsOf",
    "runPushCommand", "defaultWorkspaceSyncArgs", "syncJobsOf",
    "applyTagSelection", "runWorkspaceSyncWithProjects",
    "branchRolesArgsOf", "runWorkspaceBranchRolesCommand",
    "runWorkspaceEnableCommand", "runWorkspaceDisableCommand",
    "setsRequestOf", "runWorkspaceSetsCommand", "runWorkspaceProjectsCommand",
    "reposRequestOf", "runWorkspaceReposCommand", "workspaceStatusArgsOf",
    "workspaceListArgsOf", "workspaceManifestsArgsOf", "sharedClonesArgsOf",
    "workspaceForallArgsOf", "workspaceLockArgsOf",
    "runWorkspaceMigrateCommand", "runWorkspaceMigrateLocksCommand",
    "runWorkspacePublishEvidenceCommand", "bootstrapTargetDir",
    "runWorkspaceBootstrapCommand", "runWorkspaceProvisionCommand",
    "workspaceInitArgsOf", "runWorkspaceInitFromUrl", "runWorkspaceCommand",
    "addArgsOf", "removeArgsOf", "gatewayDirOf", "runGatewayCommand",
    "runGatewayMigrateCommand", "runReproLockingCommand",
    "runReproLockingExplain", "runReproLockingAdoptManifest",
    "runReproLockCommand", "runReproLockList", "runReproLockDiff",
    "runReproLockUpdate", "projectsWorkspaceRoot",
    # The sixth group's `develop` and `flake` (with `flake override-args`,
    # `refresh-lock`, `override-status`), and the develop-set computation
    # the flake verbs and the managed hooks share. (`developSetSelectionOf`
    # and `developSelectorWords`, generic over the configurations that
    # declare the selection, are not found by `procBody`; they read typed
    # fields only.)
    "runDevelopCommand", "developSetArgsOf", "workspaceDevelopArgsOf",
    "runWorkspaceDevelopCommand", "runDevelopDropCommand",
    "developFlagsGiven", "firstOutside", "developAllArgsOf",
    "flakeDevelopSelectionOf", "flakeShellBindingsOf",
    "hookSubstitutedDevelopSet", "executeFlakeLockRefresh",
    "runFlakeOverrideArgsCommand", "runFlakeRefreshLockCommand",
    "runFlakeOverrideStatusCommand", "runReproFlakeCommand",
    # The seventh group (the build family) so far: `build`, with `bench` and
    # `lint`, which take its command line (`runBuildVerbCommand`); every
    # route into a build, the daemon worker's included, reads its arguments
    # through `loadBuildCommandLine`, and the daemon parent's request
    # readers through `buildRequestOf`; and `clean`.
    "runBuildCommand", "runBuildVerbCommand", "loadBuildCommandLine",
    "buildRequestOf", "givenOnCommandLine", "daemonRequestProjectRoot",
    "daemonPrewarmTargetOutputDir", "runCleanCommand"]

proc isFlagLiteralAt(line: string; quote: int): bool =
  ## Whether the string literal opening at `quote` spells a flag.
  var i = quote + 1
  if i < line.len and line[i] == '-':
    inc i
    if i < line.len and line[i] == '-':
      inc i
    return i < line.len and line[i] in {'a'..'z', 'A'..'Z'}
  false

proc codeOf(line: string): string =
  ## The line without its comment (outside string literals).
  var inString = false
  var i = 0
  while i < line.len:
    let ch = line[i]
    if inString:
      if ch == '\\':
        inc i
      elif ch == '"':
        inString = false
    elif ch == '"':
      inString = true
    elif ch == '#':
      return line[0 ..< i]
    elif ch == '\'' and i + 2 < line.len and line[i + 2] == '\'':
      i += 2
    inc i
  line

proc argvComparisons*(source: string): int =
  ## The number of flag literals in `source` used as the module header
  ## describes.
  var inDocBlock = false
  for raw in source.splitLines():
    let stripped = raw.strip()
    if inDocBlock:
      if stripped.endsWith("]##") or stripped.endsWith("]#"):
        inDocBlock = false
      continue
    if stripped.startsWith("##[") or stripped.startsWith("#["):
      inDocBlock = not (stripped.endsWith("]##") or stripped.endsWith("]#"))
      continue
    let code = codeOf(raw)
    var at = code.find('"')
    var inString = false
    var opening = -1
    while at >= 0 and at < code.len:
      # Walk the literals, honouring escapes.
      if not inString:
        inString = true
        opening = at
      else:
        if code[at - 1] == '\\' and (at < 2 or code[at - 2] != '\\'):
          at = code.find('"', at + 1)
          continue
        inString = false
        if isFlagLiteralAt(code, opening):
          let before = code[0 ..< opening].strip()
          let after = code[at + 1 .. ^1].strip()
          let counted =
            before.endsWith("==") or before.endsWith("!=") or
            after.startsWith("==") or after.startsWith("!=") or
            after.startsWith("in ") or after.startsWith("notin ") or
            before.endsWith("startsWith(") or
            code.strip().startsWith("of ") or
            before.contains(" in [") or before.contains(" in @[") or
            before.contains(" notin [") or before.contains(" notin @[") or
            before.contains("valueFromFlag(") or
            before.contains("flagMatches(")
          if counted:
            inc result
      at = code.find('"', at + 1)

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while not fileExists(dir / "repro_tests.nim"):
    let parent = dir.parentDir
    doAssert parent != dir, "cannot locate the reprobuild repository root"
    dir = parent
  dir

proc scannedFiles(): seq[string] =
  let root = repoRoot()
  for top in ScannedRoots:
    for path in walkDirRec(root / top):
      if path.endsWith(".nim"):
        let rel = path.relativePath(root).replace('\\', '/')
        if rel != Description:
          result.add(rel)
  result.sort()

proc procBody(source, name: string): string =
  ## The text of top-level proc `name`: from its `proc` line to the next
  ## top-level declaration. Every top-level `proc` of that name counts, so a
  ## forward declaration does not hide the body that follows it.
  let lines = source.splitLines()
  var bodies: seq[string] = @[]
  for start, line in lines:
    if not (line.startsWith("proc " & name & "(") or
        line.startsWith("proc " & name & "*(")):
      continue
    var stop = lines.len
    for i in start + 1 ..< lines.len:
      let next = lines[i]
      if next.len > 0 and next[0] notin {' ', '#'}:
        stop = i
        break
    bodies.add(lines[start ..< stop].join("\n"))
  bodies.join("\n")

const Fixture = """
if arg == "--json": discard            # 1: comparison
if "-h" != arg: discard                # 2: comparison, literal first
if arg in ["--help", "-h"]: discard    # 3, 4: membership
if "--verify" in args: discard         # 5: membership, literal first
if arg.startsWith("--format="): discard # 6: prefix
case arg
of "--json": discard                   # 7: case branch
let v = valueFromFlag(args, i, "--project") # 8: value reader
if flagMatches(arg, "--daemon"): discard     # 9: value reader
echo "--json is a flag"                # prose: not a comparison
# if arg == "--json": a comment
## if arg == "--json": a doc comment
if arg == "--": discard                # the terminator is not a flag
if arg == "x": discard                 # not a flag
"""

suite "CS-M6: no hand-written argv parsing outside the description":

  test "the scan counts every shape of hand-written flag comparison":
    check argvComparisons(Fixture) == 9

  test "each file holds exactly the hand-written parsing it is allowed":
    let root = repoRoot()
    var found: seq[(string, int)] = @[]
    for rel in scannedFiles():
      let count = argvComparisons(readFile(root / rel))
      if count > 0:
        found.add((rel, count))
    var expected: seq[(string, int)] = @[]
    for entry in Remaining:
      if entry[1] > 0:
        expected.add(entry)
    for entry in found:
      checkpoint("found " & entry[0] & ": " & $entry[1])
    check found == expected

  test "the commands parsed from the description parse nothing by hand":
    let source = readFile(repoRoot() / "libs" / "repro_cli_support" / "src" /
      "repro_cli_support.nim")
    for name in MigratedProcs:
      let body = procBody(source, name)
      checkpoint(name)
      check body.len > 0
      check argvComparisons(body) == 0
