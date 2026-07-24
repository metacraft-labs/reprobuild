## Managed-hook protocol v2 — mixed-version matrix and atomic refresh.
##
## The fixture installs a canonical dispatcher/body, then deliberately combines
## old/new dispatcher, managed body, and CLI implementations. Every partial
## upgrade fails closed: old dispatcher + new body, new dispatcher + old body,
## new pair + old CLI, and old pair + new CLI. A fully old bundle retains its
## historical behavior but has no v2 capability exemption; a fully new bundle
## completes the side-effect-free v2 probe and accepts valid Git framing.
## It also proves that absent, partial, unknown, and marker-only bundles fail the
## real ``repro push`` preflight; a missing configured CLI fails closed; the
## exact configured CLI executes both protocol and dispatch; inherited legacy
## and guessed capability variables grant no bypass; and ``core.hooksPath`` is
## enumerated and repaired. Finally ``repro hooks ensure --vcs`` refreshes both
## old pieces and the resulting bytes execute successfully. Real executable
## shell hooks and real Git pushes are used on every supported OS whose Git
## supplies the hook shell. Accepting any partial tuple or rejecting the
## repaired all-v2 tuple falsifies the matrix. No hook call or protocol probe is
## mocked or ignored.

import std/[os, strutils, tempfiles, unittest]

when not defined(windows):
  import std/osproc

import repro_cli_support/push_hook_protocol
import repro_test_support

proc q(value: string): string =
  when defined(windows):
    # These command strings execute under Git-for-Windows sh. Nim's
    # quoteShell leaves space-free Windows paths unquoted, so their backslashes
    # become shell escapes (C:\\foo -> C:foo). Always POSIX-quote them here.
    "'" & value.replace("'", "'\"'\"'") & "'"
  else:
    quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  when defined(windows):
    let shell = findExe("sh")
    if shell.len == 0:
      return (127, "Git hook shell is unavailable")
    let res = runShell(shellCommand(@[shell, "-c", command]),
      if cwd.len > 0: cwd else: getCurrentDir())
    (res.code, res.output)
  else:
    let res = execCmdEx(command, workingDir = cwd,
      options = {poStdErrToStdOut, poUsePath})
    (res.exitCode, res.output)

proc require(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\n" & res.output)
    quit 1
  res.output

proc sourceRoot(): string = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  let configured = getEnv("REPROBUILD_REPRO")
  let candidate =
    if configured.len > 0: configured
    else: sourceRoot() / "build" / "bin" / addFileExt("repro", ExeExt)
  requireBinary(candidate, "reprobuild.apps.repro")

proc executable(path, content: string) =
  writeFile(path, content)
  var permissions = getFilePermissions(path)
  permissions.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(path, permissions)

type Fixture = object
  scratch: string
  workspace: string
  repo: string
  origin: string
  dispatcher: string
  managed: string
  refs: string
  reproBin: string
  newDispatcher: string
  newManaged: string

proc setupFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-hook-v2-mixed-", "")
  result.workspace = result.scratch / "workspace"
  result.repo = result.workspace / "app"
  result.origin = result.scratch / "origin.git"
  result.reproBin = reproBinary()
  createDir(result.workspace)
  discard require(q(gitBin) & " init --bare -b main " & q(result.origin))
  discard require(q(gitBin) & " init -b main " & q(result.repo))
  discard require(q(gitBin) & " -C " & q(result.repo) &
    " config user.email tester@example.invalid")
  discard require(q(gitBin) & " -C " & q(result.repo) &
    " config user.name 'Mixed Hook Tester'")
  writeFile(result.repo / "README.md", "seed\n")
  discard require(q(gitBin) & " -C " & q(result.repo) & " add README.md")
  discard require(q(gitBin) & " -C " & q(result.repo) & " commit -m seed")
  discard require(q(gitBin) & " -C " & q(result.repo) &
    " remote add origin " & q(result.origin))
  discard require(q(gitBin) & " -C " & q(result.repo) &
    " push --no-verify -u origin main")
  let manifests = result.workspace / ".repro" / "manifests"
  createDir(manifests / "projects")
  createDir(manifests / "repos")
  writeFile(result.workspace / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"app\"\nbranch = \"main\"\n")
  writeFile(manifests / "projects" / "app.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n[[remote]]\nname = \"origin\"\n" &
    "fetch = \"" & result.origin.replace('\\', '/') & "\"\n\n" &
    "includes = [\"repos/app.toml\"]\n")
  writeFile(manifests / "repos" / "app.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"app\"\npath = \"app\"\n" &
    "remote = \"origin\"\nrevision = \"main\"\n")
  let ensureCmd = runShell(shellCommand(@[result.reproBin, "hooks", "ensure",
    "--vcs", "--workspace-root=" & result.workspace, result.workspace]))
  let ensure = (code: ensureCmd.code, output: ensureCmd.output)
  if ensure.code != 0:
    checkpoint(ensure.output)
    quit 1
  # This matrix exercises only pre-push protocol compatibility. Avoid letting
  # orthogonal post-commit refresh manufacture locks while its fixtures create
  # later histories (the dedicated post-commit suites cover that boundary).
  for hookName in ["post-commit", "post-merge", "post-checkout"]:
    for suffix in ["", ".repro-managed", ".repro-local"]:
      let path = result.repo / ".git" / "hooks" / (hookName & suffix)
      if fileExists(path): removeFile(path)
  result.dispatcher = result.repo / ".git" / "hooks" / "pre-push"
  result.managed = result.dispatcher & ".repro-managed"
  result.newDispatcher = readFile(result.dispatcher)
  result.newManaged = readFile(result.managed)
  let head = require(q(gitBin) & " -C " & q(result.repo) &
    " rev-parse HEAD").strip()
  result.refs = result.scratch / "refs"
  writeFile(result.refs, "refs/heads/main " & head & " refs/heads/main " &
    head & "\n")

proc oldDispatcher(): string =
  "#!/usr/bin/env sh\n# reprobuild hook dispatcher\nset -eu\n" &
  "REPROBUILD_HOOK_ACTIVE=1; export REPROBUILD_HOOK_ACTIVE\n" &
  "HOOK_DIR=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)\n" &
  "TMP=$(mktemp); trap 'rm -f \"$TMP\"' EXIT\ncat > \"$TMP\"\n" &
  "\"$HOOK_DIR/pre-push.repro-managed\" \"$@\" < \"$TMP\"\n"

proc oldManaged(): string =
  "#!/usr/bin/env sh\n# reprobuild managed pre-push hook\nset -eu\n" &
  "ROOT=$(git rev-parse --show-toplevel)\nTMP=$(mktemp)\n" &
  "trap 'rm -f \"$TMP\"' EXIT\ncat > \"$TMP\"\n" &
  "\"${REPROBUILD_REPRO:-repro}\" hooks dispatch pre-push " &
  "--repo-root \"$ROOT\" --refs-file \"$TMP\" -- \"$@\"\n"

proc invoke(fx: Fixture; cli: string): tuple[code: int; output: string] =
  run("env REPROBUILD_REPRO=" & q(cli) & " " & q(fx.dispatcher) &
    " origin " & q(fx.origin) & " < " & q(fx.refs), fx.repo)

proc invokePush(fx: Fixture; extraEnv = ""): tuple[code: int; output: string] =
  var command = ""
  if extraEnv.len > 0: command.add("env " & extraEnv & " ")
  command.add(q(fx.reproBin) & " push app --no-certify --workspace-root=" &
    q(fx.workspace) & " --current-repo=" & q(fx.repo) & " --json")
  run(command, fx.repo)

proc ensureHooks(fx: Fixture): tuple[code: int; output: string] =
  let repaired = runShell(shellCommand(@[fx.reproBin, "hooks", "ensure",
    "--vcs", "--workspace-root=" & fx.workspace, fx.workspace],
    @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
  (repaired.code, repaired.output)

suite "hook protocol v2 mixed versions fail closed":
  test "all partial-upgrade combinations refuse and ensure repairs them":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let oldCli = fx.scratch / "old-repro"
      executable(oldCli,
        "#!/usr/bin/env sh\n" &
        "if [ \"${1:-}\" = hooks ] && [ \"${2:-}\" = dispatch ]; then exit 0; fi\n" &
        "exit 1\n")

      # old dispatcher / new managed / new CLI
      executable(fx.dispatcher, oldDispatcher())
      executable(fx.managed, fx.newManaged)
      check fx.invoke(fx.reproBin).code != 0

      # new dispatcher / old managed / any CLI
      executable(fx.dispatcher, fx.newDispatcher)
      executable(fx.managed, oldManaged())
      check fx.invoke(fx.reproBin).code != 0

      # new dispatcher + managed / old CLI: v2 probe fails.
      executable(fx.dispatcher, fx.newDispatcher)
      executable(fx.managed, fx.newManaged)
      check fx.invoke(oldCli).code != 0

      # old dispatcher + managed / new CLI: new CLI rejects v1 dispatch.
      executable(fx.dispatcher, oldDispatcher())
      executable(fx.managed, oldManaged())
      check fx.invoke(fx.reproBin).code != 0

      # Fully old stays old (no v2 exemption) and follows the old CLI stub.
      check fx.invoke(oldCli).code == 0

      # Fully new probes and dispatches protocol 2 successfully.
      executable(fx.dispatcher, fx.newDispatcher)
      executable(fx.managed, fx.newManaged)
      check fx.invoke(fx.reproBin).code == 0

      # A partial/old install is refreshed to canonical v2 bytes by ensure.
      executable(fx.dispatcher, oldDispatcher())
      executable(fx.managed, oldManaged())
      let repairedCmd = runShell(shellCommand(@[fx.reproBin, "hooks", "ensure",
        "--vcs", "--workspace-root=" & fx.workspace, fx.workspace]))
      let repaired = (code: repairedCmd.code, output: repairedCmd.output)
      if repaired.code != 0: checkpoint(repaired.output)
      check repaired.code == 0
      check V2DispatcherMarker in readFile(fx.dispatcher)
      check V2ManagedMarker in readFile(fx.managed)
      check fx.invoke(fx.reproBin).code == 0

  test "real push preflight refuses absent partial unknown and marker-only bundles":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)

      removeFile(fx.dispatcher)
      removeFile(fx.managed)
      let absent = fx.invokePush()
      check absent.code != 0
      check "hook-preflight" in absent.output or "pre-push hook" in absent.output

      let repairedAbsent = fx.ensureHooks()
      if repairedAbsent.code != 0: checkpoint(repairedAbsent.output)
      check repairedAbsent.code == 0
      removeFile(fx.managed)
      let partial = fx.invokePush()
      check partial.code != 0
      check "hook-preflight" in partial.output or "incomplete" in partial.output

      discard fx.ensureHooks()
      executable(fx.dispatcher, "#!/usr/bin/env sh\nexit 0\n")
      executable(fx.managed, "#!/usr/bin/env sh\nexit 0\n")
      let unknown = fx.invokePush()
      check unknown.code != 0
      check "hook-preflight" in unknown.output or "unrecognized" in unknown.output

      discard fx.ensureHooks()
      executable(fx.managed,
        "#!/usr/bin/env sh\n# reprobuild managed pre-push hook protocol=2\nexit 0\n")
      let markerOnly = fx.invokePush()
      check markerOnly.code != 0
      check "hook-preflight" in markerOnly.output or
        "incompatible" in markerOnly.output

  test "missing CLI fails closed and exact configured CLI handles both calls":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let missing = fx.repo / "definitely-missing-repro"
      let absentCli = fx.invoke(missing)
      check absentCli.code != 0
      let canonicalRepo = require(q(gitBin) & " -C " & q(fx.repo) &
        " rev-parse --show-toplevel").strip()
      check absentCli.output.strip() ==
        "repro hooks: hook protocol mismatch; run 'repro hooks ensure --vcs " &
          canonicalRepo & "' and retry"

      let log = fx.scratch / "exact-cli.log"
      let proxy = fx.scratch / addFileExt("exact-repro", ExeExt)
      when defined(windows):
        # Git for Windows executes POSIX hooks, so use a shell proxy even when
        # the delegated native executable carries .exe.
        executable(proxy,
          "#!/usr/bin/env sh\nprintf '%s\\n' \"$*\" >> " & q(log) &
          "\nexec " & q(fx.reproBin) & " \"$@\"\n")
      else:
        executable(proxy,
          "#!/usr/bin/env sh\nprintf '%s\\n' \"$*\" >> " & q(log) &
          "\nexec " & q(fx.reproBin) & " \"$@\"\n")
      let exact = fx.invoke(proxy)
      if exact.code != 0: checkpoint(exact.output)
      check exact.code == 0
      let calls = readFile(log)
      check "hooks protocol --require=2" in calls
      check "hooks dispatch pre-push" in calls

  test "spoofed legacy sentinel and guessed capability cannot bypass a real push":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      writeFile(fx.repo / "README.md", "unpublished\n")
      discard require(q(gitBin) & " -C " & q(fx.repo) & " add README.md")
      discard require(q(gitBin) & " -C " & q(fx.repo) &
        " commit -m unpublished")
      discard require(q(gitBin) & " -C " & q(fx.repo) &
        " tag guessed-capability")
      let guessed = repeat('a', 64)
      let pushed = run("env REPROBUILD_REPRO=" & q(fx.reproBin) & " " &
        LegacyHookSentinelEnv & "=1 " & HookCapabilityEnv & "=" & guessed &
        " " & q(gitBin) & " -C " & q(fx.repo) &
        " push origin refs/tags/guessed-capability")
      check pushed.code != 0
      check "capability" in pushed.output or "unpublished" in pushed.output

  test "core hooksPath receives and runs the complete canonical bundle":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)
      let custom = fx.scratch / "custom-hooks"
      createDir(custom)
      discard require(q(gitBin) & " -C " & q(fx.repo) &
        " config core.hooksPath " & q(custom))
      let ensured = fx.ensureHooks()
      if ensured.code != 0: checkpoint(ensured.output)
      check ensured.code == 0
      let dispatcher = custom / "pre-push"
      let managed = custom / "pre-push.repro-managed"
      check fileExists(dispatcher)
      check fileExists(managed)
      check V2DispatcherMarker in readFile(dispatcher)
      check V2ManagedMarker in readFile(managed)
      let invoked = run("env REPROBUILD_REPRO=" & q(fx.reproBin) & " " &
        q(dispatcher) & " origin " & q(fx.origin) & " < " & q(fx.refs),
        fx.repo)
      if invoked.code != 0: checkpoint(invoked.output)
      check invoked.code == 0

  test "protocol mismatch names the repository for every hooksPath form":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      for hookPathForm in ["normal", "relative", "absolute"]:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        case hookPathForm
        of "relative":
          createDir(fx.repo / "relative-hooks")
          discard require(q(gitBin) & " -C " & q(fx.repo) &
            " config core.hooksPath relative-hooks")
        of "absolute":
          let absoluteHooks = fx.scratch / "absolute-hooks"
          createDir(absoluteHooks)
          discard require(q(gitBin) & " -C " & q(fx.repo) &
            " config core.hooksPath " & q(absoluteHooks))
        else:
          discard
        let ensured = fx.ensureHooks()
        if ensured.code != 0: checkpoint(ensured.output)
        check ensured.code == 0
        let dispatcher = require(q(gitBin) & " -C " & q(fx.repo) &
          " rev-parse --path-format=absolute --git-path hooks/pre-push").strip()
        let managed = dispatcher & ".repro-managed"
        check fileExists(dispatcher)
        check fileExists(managed)
        removeFile(managed)
        let mismatch = run("env REPROBUILD_REPRO=" & q(fx.reproBin) & " " &
          q(dispatcher) & " origin " & q(fx.origin) & " < " & q(fx.refs),
          fx.repo)
        check mismatch.code != 0
        let canonicalRepo = require(q(gitBin) & " -C " & q(fx.repo) &
          " rev-parse --show-toplevel").strip()
        check mismatch.output.strip() ==
          "repro hooks: hook protocol mismatch; run '" & fx.reproBin &
          " hooks ensure --vcs " & canonicalRepo & "' and retry"
