## A recipe's `useFlakeDevShell()` asks the ENGINE that is running it for the
## workspace's flake overrides — never whatever `repro` happens to be first on
## PATH — and a failure of that request says what failed.
##
## WHY. `workspaceFlakeOverrides` runs inside the project provider, which the
## engine compiles from the recipe with the engine's OWN stdlib. It then
## shelled out to `repro flake override-args` resolved from PATH. When the
## shell's `repro` was older than the engine (a dev shell pinned to 0.1.3
## while a 0.2.5 engine ran the recipe — measured in this workspace), the old
## binary did not know the verb, exited non-zero with its complaint on
## stderr, and the provider reported
##
##     native workspace flake override resolution failed:
##
## with nothing after the colon. `repro exec` into any flake-backed workspace
## repo (codetracer-trace-format-nim, which codetracer-wasm-recorder's tests
## enter) therefore failed for anyone whose PATH `repro` lagged the engine.
##
## Cases:
##   1. With a stale `repro` first on PATH and `REPRO_INVOKING_CLI` naming the
##      built engine, `workspaceFlakeOverrides` gets its answer from the
##      engine (red: it asked the stale PATH binary and raised).
##   2. When the resolver fails, the error names the binary it ran, its exit
##      status and what it printed on stderr (red: an empty diagnostic).
##   3. The engine exports `REPRO_INVOKING_CLI` naming itself to the
##      processes it starts: `repro exec <project> -- env` shows it (red: the
##      variable is absent, so a provider could only fall back to PATH).
##
## STUBS, justified. Cases 1 and 2 put a shell script named `repro` on PATH
## that exits 2 with an "unknown verb" message on stderr. It stands in for an
## OLDER released `repro` binary, which is exactly the thing whose presence
## on PATH the fix must not depend on; building a real old release inside a
## test is out of reach. Everything else is real: the real resolver code, the
## real built engine answering `flake override-args`, a real workspace on
## disk, and a real `repro exec`.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_dsl_stdlib/foreign_env

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
let engine = RepoRoot / "build" / "bin" / addFileExt("reprobuild", ExeExt)
let thinCli = RepoRoot / "build" / "bin" / addFileExt("repro", ExeExt)

proc staleReproDir(scratch: string): string =
  result = scratch / "stale-bin"
  createDir(result)
  let stub = result / "repro"
  writeFile(stub, "#!/bin/sh\necho \"repro: unknown command 'flake " &
    "override-args' (stale release)\" >&2\nexit 2\n")
  setFilePermissions(stub, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc sh(cmd, cwd: string) =
  let r = execCmdEx(cmd, workingDir = cwd)
  if r.exitCode != 0:
    checkpoint("command failed: " & cmd & "\n" & r.output)
    quit 1

proc workspaceWithFlake(scratch: string): string =
  ## A real manifest workspace the engine can resolve: one repo, `app`, a git
  ## checkout carrying a flake with one input and a committed `repro.lock`
  ## (written by the engine itself). There is no develop set, so the engine's
  ## answer is a well-formed EMPTY override list.
  let ws = scratch / "ws"
  createDir(ws / ".repro")
  createDir(ws / "projects")
  createDir(ws / "repos")
  writeFile(ws / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n[workspace]\n" &
    "project = \"app\"\nbranch = \"main\"\n")
  writeFile(ws / "projects" / "app.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n[project]\n" &
    "name = \"app\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n" &
    "[[remote]]\nname = \"app-origin\"\nfetch = \"file:///nonexistent/app.git\"\n\n" &
    "includes = [\n  \"repos/app.toml\",\n]\n")
  writeFile(ws / "repos" / "app.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\nname = \"app\"\n" &
    "path = \"app\"\nremote = \"app-origin\"\nrevision = \"main\"\n")
  let app = ws / "app"
  createDir(app)
  writeFile(app / "flake.nix", "{\n  inputs.nixpkgs.url = " &
    "\"github:NixOS/nixpkgs/nixos-unstable\";\n  outputs = _: { };\n}\n")
  writeFile(app / "repro.solver", "package app\nversions: 0.1.0\n")
  let git = quoteShell(findExe("git"))
  let commit = git & " -c user.name=t -c user.email=t@example.invalid commit -q -m "
  sh(git & " init -q -b main", app)
  sh(git & " add -A", app)
  sh(commit & "seed", app)
  if fileExists(engine):
    sh(quoteShell(engine) & " lock refresh .", app)
    sh(git & " add repro.lock", app)
    sh(commit & "lock", app)
  app

suite "flake override resolution uses the invoking engine":
  let savedPath = getEnv("PATH")
  let savedInvoking = getEnv("REPRO_INVOKING_CLI")
  let savedExplicit = getEnv("REPROBUILD_REPRO")

  teardown:
    putEnv("PATH", savedPath)
    if savedInvoking.len > 0: putEnv("REPRO_INVOKING_CLI", savedInvoking)
    else: delEnv("REPRO_INVOKING_CLI")
    if savedExplicit.len > 0: putEnv("REPROBUILD_REPRO", savedExplicit)
    else: delEnv("REPROBUILD_REPRO")

  test "a_stale_path_repro_does_not_answer_for_the_engine":
    if not fileExists(engine):
      skip("the built engine build/bin/reprobuild is required; run `just build`")
    else:
      let scratch = createTempDir("repro-invoking-cli-", "")
      defer: removeDir(scratch)
      let app = workspaceWithFlake(scratch)
      putEnv("PATH", staleReproDir(scratch) & $PathSep & savedPath)
      delEnv("REPROBUILD_REPRO")
      putEnv("REPRO_INVOKING_CLI", engine)
      var raised = ""
      var overrides: seq[(string, string)] = @[]
      try:
        overrides = workspaceFlakeOverrides(app)
      except CatchableError as err:
        raised = err.msg
      checkpoint(raised)
      check raised.len == 0
      check overrides.len == 0

  test "a_failed_resolution_names_the_binary_its_status_and_its_stderr":
    let scratch = createTempDir("repro-invoking-cli-", "")
    defer: removeDir(scratch)
    let app = workspaceWithFlake(scratch)
    let stale = staleReproDir(scratch)
    delEnv("REPROBUILD_REPRO")
    putEnv("REPRO_INVOKING_CLI", stale / "repro")
    var raised = ""
    try:
      discard workspaceFlakeOverrides(app)
    except CatchableError as err:
      raised = err.msg
    checkpoint(raised)
    check (stale / "repro") in raised
    check "exit" in raised
    check "2" in raised
    check "unknown command" in raised

  test "the_engine_names_itself_to_the_processes_it_starts":
    if not fileExists(engine) or not fileExists(thinCli):
      skip("the built CLI images build/bin/{repro,reprobuild} are required; run `just build`")
    else:
      let scratch = createTempDir("repro-invoking-cli-", "")
      defer: removeDir(scratch)
      let project = scratch / "proj"
      createDir(project)
      writeFile(project / "repro.nim",
        "import repro_project_dsl\n\npackage proj:\n  devEnv:\n" &
        "    activity \"default\"\n")
      putEnv("PATH", staleReproDir(scratch) & $PathSep & savedPath)
      delEnv("REPRO_INVOKING_CLI")
      let res = execCmdEx(quoteShell(thinCli) & " exec " & quoteShell(project) &
        " -- env", workingDir = project)
      checkpoint(res.output)
      check res.exitCode == 0
      var named = ""
      for line in res.output.splitLines():
        if line.startsWith("REPRO_INVOKING_CLI="):
          named = line["REPRO_INVOKING_CLI=".len .. ^1]
      check named.len > 0
      check named.len > 0 and fileExists(named)
      check extractFilename(named) != "repro" or
        not named.startsWith(scratch)
