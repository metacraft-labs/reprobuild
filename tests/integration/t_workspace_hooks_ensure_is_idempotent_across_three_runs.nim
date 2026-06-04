## M17 — ``repro hooks ensure --vcs``.
##
## End-to-end integration test for the workspace-aware VCS-hook
## installer. Five sub-cases (per the M17 deliverable in
## ``reprobuild-specs/Workspace-Management.milestones.org``):
##
##   1. ``test_m17_hooks_ensure_installs_four_hooks_per_repo`` — fresh
##      workspace, four hooks land in every participating repo with the
##      managed-by sentinel comment and the executable bit set.
##   2. ``test_m17_hooks_ensure_is_idempotent_across_three_runs`` — run
##      ensure three times back-to-back; every per-repo per-hook entry
##      reports ``already-up-to-date`` on the second and third runs and
##      the on-disk file bytes are bit-identical across runs.
##   3. ``test_m17_hooks_ensure_chains_pre_existing_user_hook`` — drop a
##      user-owned ``pre-push`` into one repo; ensure preserves it as
##      ``pre-push.repro-local`` and the dispatcher invokes it before
##      the managed body, propagating its exit code.
##   4. ``test_m17_hooks_ensure_refreshes_drifted_hook`` — overwrite the
##      managed body with a body that still carries the sentinel but
##      diverges from canonical content; ensure detects the drift and
##      rewrites the canonical bytes.
##   5. ``test_m17_hooks_dispatch_noop_succeeds`` — ``repro hooks
##      dispatch post-commit`` with no registered body exits 0 cleanly
##      so M18 / M19 / M19a can wire their bodies on top without a
##      flag day.
##
## Fixture pattern mirrors M9 / M10 / M11 / M14 / M15: three local bare
## origins stand in for remote URLs, a workspace tree carries
## ``.repo/manifests/projects/<name>.toml`` plus three repo fragments,
## and every repo is cloned into the workspace before the command runs.
##
## Skip rule: ``git`` missing on PATH (same convention as M9–M16).

import std/[json, os, osproc, strutils, tables, tempfiles, unittest]

import repro_test_support

# ---- repro binary build ---------------------------------------------------

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc compileRepro(tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro", ExeExt)
  createDir(parentDir(result))
  let root = repoRoot()
  let args = @[
    "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
    "--nimcache:" & root / "build" / "nimcache" / "m17-hooks-ensure-repro",
    "--out:" & result,
    root / "apps" / "repro" / "repro.nim",
  ]
  discard requireSuccess(shellCommand(args), root)

# ---- bare-repo seed fixture ----------------------------------------------

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name 'M17 Tester'")
  writeFile(workPath / "README.md", "M17 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q("file://" & originPath) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name 'M17 Tester'")

# ---- manifest TOML strings ------------------------------------------------

proc projectTomlWith3Remotes(libAUrl, libBUrl, libCUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"lib-a\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-c-origin\"\nfetch = \"" & libCUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "  \"repos/lib-b.toml\",\n" &
    "  \"repos/lib-c.toml\",\n" &
    "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
revision = "main"
"""

const libCFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-c"
path = "lib-c"
remote = "lib-c-origin"
revision = "main"
"""

# ---- fixture builder ------------------------------------------------------

type
  RepoSeed = object
    name: string
    origin: string
    seedPath: string
    sha: string

  M17Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libA: RepoSeed
    libB: RepoSeed
    libC: RepoSeed

proc setupFixture(gitBin, slug: string): M17Fixture =
  result.scratch = createTempDir("repro-m17-" & slug & "-", "")
  result.reproBin = compileRepro(result.scratch)

  result.libA.name = "lib-a"
  result.libA.origin = result.scratch / "origin-lib-a.git"
  result.libA.seedPath = result.scratch / "seed-lib-a"
  result.libA.sha = seedGitOrigin(gitBin, result.libA.origin,
    result.libA.seedPath)
  result.libB.name = "lib-b"
  result.libB.origin = result.scratch / "origin-lib-b.git"
  result.libB.seedPath = result.scratch / "seed-lib-b"
  result.libB.sha = seedGitOrigin(gitBin, result.libB.origin,
    result.libB.seedPath)
  result.libC.name = "lib-c"
  result.libC.origin = result.scratch / "origin-lib-c.git"
  result.libC.seedPath = result.scratch / "seed-lib-c"
  result.libC.sha = seedGitOrigin(gitBin, result.libC.origin,
    result.libC.seedPath)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectTomlWith3Remotes(
      "file://" & result.libA.origin,
      "file://" & result.libB.origin,
      "file://" & result.libC.origin))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-c.toml", libCFragmentToml)
  result.workspaceRoot = workspaceRoot

proc cloneAll(gitBin: string; fx: M17Fixture) =
  cloneInto(gitBin, fx.libA.origin, fx.workspaceRoot / "lib-a")
  cloneInto(gitBin, fx.libB.origin, fx.workspaceRoot / "lib-b")
  cloneInto(gitBin, fx.libC.origin, fx.workspaceRoot / "lib-c")

proc invokeEnsure(fx: M17Fixture; json = false): CmdResult =
  var argv = @[
    fx.reproBin, "hooks", "ensure", "--vcs",
    "--workspace-root=" & fx.workspaceRoot,
  ]
  if json: argv.add("--json")
  runShell(shellCommand(argv))

proc invokeDispatch(fx: M17Fixture; hookName: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "hooks", "dispatch", hookName,
    "--repo-root", fx.workspaceRoot / "lib-a", "--",
  ]))

proc readReport(fx: M17Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repo" / "workspace" /
    "hooks-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc hookFilesInRepo(workspaceRoot, repoName: string):
    seq[tuple[name: string; path: string]] =
  let hooksDir = workspaceRoot / repoName / ".git" / "hooks"
  for name in ["pre-push", "post-commit", "post-merge", "post-checkout"]:
    result.add((name: name, path: hooksDir / name))

# ---- the suite -------------------------------------------------------------

suite "M17 — repro hooks ensure --vcs (workspace-aware)":

  test "test_m17_hooks_ensure_installs_four_hooks_per_repo":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "install-four")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)

      let res = invokeEnsure(fx)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["mode"].getStr() == "workspace"
      check report["project"].getStr() == "lib-a"
      check report["repos"].len == 3
      # Four hooks × three repos = 12 entries.
      check report["entries"].len == 12

      # Every per-repo per-hook entry was a fresh ``installed`` outcome
      # on the first run.
      for entry in report["entries"]:
        check entry["outcome"].getStr() == "installed"

      # On-disk: each hook file exists, carries the sentinel, and has
      # the executable bit set.
      for repoName in ["lib-a", "lib-b", "lib-c"]:
        for h in hookFilesInRepo(fx.workspaceRoot, repoName):
          check fileExists(h.path)
          let content = readFile(h.path)
          check content.contains("reprobuild hook dispatcher")
          let perms = getFilePermissions(h.path)
          check fpUserExec in perms
          # The managed body is the actual hook payload and must also
          # carry the ``managed-by: reprobuild hooks ensure`` sentinel
          # the spec asks for, plus the executable bit.
          let managedPath = h.path & ".repro-managed"
          check fileExists(managedPath)
          let managedContent = readFile(managedPath)
          check managedContent.contains("managed-by: reprobuild hooks ensure")
          check managedContent.contains("repro hooks dispatch " & h.name)
          let managedPerms = getFilePermissions(managedPath)
          check fpUserExec in managedPerms

  test "test_m17_hooks_ensure_is_idempotent_across_three_runs":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "idempotent")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)

      let firstRes = invokeEnsure(fx)
      check firstRes.code == 0
      let firstReport = readReport(fx)

      # Snapshot every hook file's bytes after the first install so we
      # can prove the second and third runs land on the same content.
      var firstBytes = initTable[string, string]()
      for repoName in ["lib-a", "lib-b", "lib-c"]:
        for h in hookFilesInRepo(fx.workspaceRoot, repoName):
          firstBytes[h.path] = readFile(h.path)
          firstBytes[h.path & ".repro-managed"] =
            readFile(h.path & ".repro-managed")

      # Second run: every entry should report ``already-up-to-date``;
      # no file bytes change.
      let secondRes = invokeEnsure(fx)
      check secondRes.code == 0
      let secondReport = readReport(fx)
      check secondReport["entries"].len == 12
      for entry in secondReport["entries"]:
        check entry["outcome"].getStr() == "already-up-to-date"
      for path, body in firstBytes:
        check readFile(path) == body

      # Third run: identical to the second.
      let thirdRes = invokeEnsure(fx)
      check thirdRes.code == 0
      let thirdReport = readReport(fx)
      check thirdReport["entries"].len == 12
      for entry in thirdReport["entries"]:
        check entry["outcome"].getStr() == "already-up-to-date"
      for path, body in firstBytes:
        check readFile(path) == body

      # Sanity: the summary table is what the renderer prints. Every
      # outcome on runs 2/3 must be ``already-up-to-date`` = 12.
      check secondReport["summary"]["already-up-to-date"].getInt() == 12
      check thirdReport["summary"]["already-up-to-date"].getInt() == 12
      check firstReport["summary"]["installed"].getInt() == 12

  test "test_m17_hooks_ensure_chains_pre_existing_user_hook":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "chain-user")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)

      # Drop a user-owned pre-push into lib-b BEFORE running ensure.
      # The hook exits 73 so we can prove the dispatcher propagates
      # the exit code from the chained user hook.
      let libBHooks = fx.workspaceRoot / "lib-b" / ".git" / "hooks"
      createDir(libBHooks)
      let userHookContent = "#!/usr/bin/env sh\n# user-owned hook (not managed-by reprobuild)\nexit 73\n"
      writeFile(libBHooks / "pre-push", userHookContent)
      var perms = getFilePermissions(libBHooks / "pre-push")
      perms.incl(fpUserExec)
      perms.incl(fpGroupExec)
      perms.incl(fpOthersExec)
      setFilePermissions(libBHooks / "pre-push", perms)

      let res = invokeEnsure(fx)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      var chained = 0
      for entry in report["entries"]:
        if entry["repo"].getStr() == "lib-b" and
            entry["hook"].getStr() == "pre-push":
          check entry["outcome"].getStr() == "chained-user-hook"
          inc chained
      check chained == 1

      # The user hook was preserved under ``.repro-local`` with the
      # original bytes intact.
      let preservedPath = libBHooks / "pre-push.repro-local"
      check fileExists(preservedPath)
      check readFile(preservedPath) == userHookContent

      # The dispatcher at the canonical path is now Reprobuild-owned.
      let dispatcherContent = readFile(libBHooks / "pre-push")
      check dispatcherContent.contains("reprobuild hook dispatcher")

      # End-to-end propagation: invoking the dispatcher inside the
      # repo runs the preserved user hook FIRST and propagates its
      # exit code (73). We feed an empty refs stdin so pre-push's
      # ``cat`` doesn't block.
      let dispatcherRun = runCmd("sh -c " &
        q("cd " & q(fx.workspaceRoot / "lib-b") &
          " && " & q(libBHooks / "pre-push") & " origin file://nowhere </dev/null"))
      check dispatcherRun.code == 73

  test "test_m17_hooks_ensure_refreshes_drifted_hook":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "drift")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)

      # First, install canonical hooks.
      let firstRes = invokeEnsure(fx)
      check firstRes.code == 0

      # Simulate drift: keep the sentinel comment ("managed-by:
      # reprobuild hooks ensure" and the dispatcher marker line) so
      # the installer still recognises the file as Reprobuild-owned,
      # but mutate the body so it no longer matches canonical content.
      let managedPath = fx.workspaceRoot / "lib-a" / ".git" / "hooks" /
        "post-commit.repro-managed"
      let originalManaged = readFile(managedPath)
      let driftedManaged = originalManaged.replace(
        "exit $?", "echo drifted >&2\nexit $?")
      check driftedManaged != originalManaged
      check driftedManaged.contains("managed-by: reprobuild hooks ensure")
      writeFile(managedPath, driftedManaged)

      let res = invokeEnsure(fx)
      check res.code == 0

      let report = readReport(fx)
      var refreshed = 0
      for entry in report["entries"]:
        if entry["repo"].getStr() == "lib-a" and
            entry["hook"].getStr() == "post-commit":
          check entry["outcome"].getStr() == "refreshed-drifted"
          inc refreshed
      check refreshed == 1

      # The managed body is now the canonical content again.
      check readFile(managedPath) == originalManaged

  test "test_m17_hooks_dispatch_noop_succeeds":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dispatch-noop")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)

      # ``dispatch`` is the entry point the installed hook scripts
      # call. With no body registered (M17 ground state) every known
      # hook name returns 0 cleanly so M18+ can layer their bodies on
      # top without a flag day. We exercise all four names.
      for hookName in ["pre-push", "post-commit", "post-merge",
                       "post-checkout"]:
        let res = invokeDispatch(fx, hookName)
        if res.code != 0:
          checkpoint("dispatch " & hookName & " output: " & res.output)
        check res.code == 0

      # An unknown hook name surfaces as a structured error (exit 1).
      let badRes = runShell(shellCommand(@[
        fx.reproBin, "hooks", "dispatch", "not-a-real-hook",
      ]))
      check badRes.code != 0
