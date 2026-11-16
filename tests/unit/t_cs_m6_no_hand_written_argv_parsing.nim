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
    # `infra_install_root.nim`. What `infra.nim` and `infra_image.nim` still
    # hold is no argv parsing (a `git describe` suffix, a table of the flags
    # a bootstrap names), but it has the shape the scan counts.
    ("libs/repro_cli_support/src/repro_cli_support.nim", 1073),
    ("libs/repro_cli_support/src/repro_cli_support/attest.nim", 96),
    ("libs/repro_cli_support/src/repro_cli_support/dev_env_fast_path.nim", 13),
    ("libs/repro_cli_support/src/repro_cli_support/infra.nim", 1),
    ("libs/repro_cli_support/src/repro_cli_support/infra_image.nim", 1),
    ("libs/repro_cli_support/src/repro_cli_support/project_pins.nim", 4),
    ("libs/repro_cli_support/src/repro_cli_support/workspace_restore.nim", 8),
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
    "healthArgsOf", "runHealthCommand", "runDebugArtifactCommand"]

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
  ## top-level declaration.
  let lines = source.splitLines()
  var start = -1
  for i, line in lines:
    if line.startsWith("proc " & name & "(") or
        line.startsWith("proc " & name & "*("):
      start = i
      break
  if start < 0:
    return ""
  var stop = lines.len
  for i in start + 1 ..< lines.len:
    let line = lines[i]
    if line.len > 0 and line[0] notin {' ', '#'}:
      stop = i
      break
  lines[start ..< stop].join("\n")

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
