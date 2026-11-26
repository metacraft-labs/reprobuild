## A `shell(...)` action runs the tools its package names in `uses:`, and
## nothing else the caller's `PATH` happens to offer.
##
## ## The defect this pins
##
## A package that names its tools in `uses:` and builds with `shell(...)`
## lowered to an edge whose
## `toolIdentityRefs` were EMPTY: the edge's own tool (`sh`) was resolved,
## but `make` and `gcc` from the same `uses:` block were neither selected
## for realization ("selected tool identities: 2/24") nor put on the edge's
## `PATH`. With no ref declared, `actionPathDecision` took the inherited
## branch, so the shell ran with `<sh's dir>:<the caller's PATH>` and found
## the HOST's `/usr/bin/make` and `/usr/bin/gcc` under
## `--tool-provisioning=nix`, reporting success with nothing in the action's
## identity saying which compiler it ran.
##
## ## How this test sees it
##
## Two directories are prepended to the caller's `PATH`:
##
## * `tools/` holds `rb-shell-uses-tool`, which the package declares in
##   `uses:`. The shell must find it, and must find it because the solved
##   graph resolved it into that directory, not because the caller's
##   `PATH` contains it.
## * `decoy/` holds `rb-shell-decoy-tool`, which the package does NOT
##   declare. Under the defect the shell inherited the caller's `PATH` and
##   found it; with the fix the edge's `PATH` is composed only of resolved
##   tool directories (Validation-Criteria.md §Build Engine And Scheduler)
##   and the decoy is unreachable.
##
## The shell records what it saw into files the test reads back, and the
## build header's tool-selection and `PATH` census lines are checked too, so
## the assertion is about both halves the issue names: which tools the
## build selected, and which `PATH` the action ran under.
##
## No mocks: the real graph-built `repro`, a real `sh`, real files. The two
## fixture tools are scripts because their only job is to be found (or not)
## by name.
import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc runShell(command: openArray[string]; cwd: string;
              pathValue: string): tuple[code: int; output: string] =
  let shellCommand = "PATH=" & q(pathValue) & " " &
    command.mapIt(q(it)).join(" ")
  let res = execCmdEx(shellCommand, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc writeTool(dir, name, message: string) =
  createDir(dir)
  let toolPath = dir / name
  writeFile(toolPath,
    "#!/bin/sh\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then\n" &
    "  echo '" & name & " 1.0.0'\n" &
    "  exit 0\n" &
    "fi\n" &
    "echo '" & message & "'\n")
  setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc writeProject(projectRoot: string) =
  createDir(projectRoot)
  # Every byte the shell writes goes through shell builtins (`command -v`,
  # `echo`, redirection), so the recipe needs no tool beyond the two it
  # declares. `|| echo missing` keeps a not-found tool from failing the
  # action: the test wants to READ what the shell saw, not infer it from
  # an exit status.
  writeFile(projectRoot / "repro.nim",
    "import repro_project_dsl\n" &
    "import repro_dsl_stdlib/packages/sh\n\n" &
    "package shellUses:\n" &
    "  uses:\n" &
    "    \"sh\"\n" &
    "    \"rb-shell-uses-tool >=1.0\"\n\n" &
    "  build:\n" &
    "    let run = shell(\n" &
    "      command = \"rb-shell-uses-tool > declared.txt; \" &\n" &
    "        \"(command -v rb-shell-decoy-tool || echo missing) > decoy.txt; \" &\n" &
    "        \"echo \\\"$PATH\\\" > path.txt\",\n" &
    "      actionId = \"shelluses.run\",\n" &
    "      extraOutputs = @[\"declared.txt\", \"decoy.txt\", \"path.txt\"],\n" &
    "      cacheable = false)\n" &
    "    defaultTarget(run)\n")

proc lineStartingWith(output, prefix: string): string =
  for line in output.splitLines:
    let stripped = line.strip()
    if stripped.startsWith(prefix):
      return stripped
  ""

suite "e2e_shell_action_runs_its_package_uses_tools":
  when isNixSupported:
    test "shell edge names its package's uses tools and runs on a hermetic PATH":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-shell-uses", "")
      defer: removeDir(tempRoot)

      let reproBin = requireHostBinary(reproBinaryPath())
      let toolsDir = tempRoot / "tools"
      let decoyDir = tempRoot / "decoy"
      writeTool(toolsDir, "rb-shell-uses-tool", "declared tool ran")
      writeTool(decoyDir, "rb-shell-decoy-tool", "decoy tool ran")
      let pathValue = toolsDir & $PathSep & decoyDir & $PathSep &
        getEnv("PATH")
      let projectRoot = tempRoot / "project"
      writeProject(projectRoot)

      let res = runShell(@[reproBin, "build", projectRoot,
        "--daemon=off", "--tool-provisioning=path", "--log=actions"],
        repoRoot, pathValue)
      checkpoint(res.output)
      require res.code == 0

      # The declared tool ran, found through the solved graph.
      check readFile(projectRoot / "declared.txt").strip() ==
        "declared tool ran"

      # The undeclared tool on the caller's PATH was NOT reachable. Under
      # the defect this read the decoy's absolute path.
      check readFile(projectRoot / "decoy.txt").strip() == "missing"

      # The action's PATH holds the declared tool's directory and no
      # directory the caller merely had on its PATH.
      let actionPath = readFile(projectRoot / "path.txt").strip()
      let actionDirs = actionPath.split(PathSep)
      check toolsDir in actionDirs
      check decoyDir notin actionDirs
      # Every caller directory that survives must be one a declared tool
      # resolved into: here, only wherever `sh` was found. Under the defect
      # the whole caller `PATH` followed `sh`'s directory.
      var strayDirs: seq[string] = @[]
      for dir in getEnv("PATH").split(PathSep):
        if dir.len > 0 and dir in actionDirs and not fileExists(dir / "sh"):
          strayDirs.add(dir)
      checkpoint("caller PATH dirs on the action's PATH that hold no " &
        "declared tool: " & strayDirs.join(", "))
      check strayDirs.len == 0

      # The declared tool was selected for this build alongside `sh`. The
      # line is `selected tool identities: <selected>/<known>`; under the
      # defect only the shell's own `sh` identities were selected (2).
      let selected = lineStartingWith(res.output,
        "selected tool identities:")
      checkpoint(selected)
      let counts = selected["selected tool identities:".len .. ^1].
        strip().split('/')
      require counts.len == 2
      check parseInt(counts[0]) == 3

      # The census counts the shell edge as hermetic, not inherited.
      let census = lineStartingWith(res.output, "env:")
      checkpoint(census)
      check "PATH: 1 hermetic (keyed by value), 0 inherited" in census
