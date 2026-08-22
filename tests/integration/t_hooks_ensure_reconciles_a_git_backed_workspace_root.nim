## ``repro hooks ensure --vcs`` must reconcile EVERY participating repo of a
## workspace whose root directory is itself a Git repository, and must be able
## to reinstall its dispatcher after a foreign hook installer overwrites it a
## second time.
##
## Why this shape exists
## ---------------------
##
## Real workspaces keep their manifests in the workspace root, and that root is
## a checked-out Git repo (``metacraft-labs/workspace``). Every pre-existing
## M17 fixture builds the workspace root with a bare ``createDir``, so the
## "root is also a repo" shape — the only shape that ships — was never
## exercised. ``enumerateParticipatingRepos`` short-circuits to
## ``single-repo`` the moment ``gitTopLevel(workspaceRoot)`` equals the root,
## which means ``repro hooks ensure --vcs`` run from a real workspace root
## reconciles the root repo alone and reports success. Participating repos
## silently keep whatever hooks (or no hooks) they have, the pre-push
## publication gate never runs in them, and no workspace lock is ever published
## for their commits — which is what CI then fails on, far downstream, as
## "No workspace lock for <repo>".
##
## The second case is the other half of the same outage. ``ensure`` chains a
## pre-existing user hook to ``<hook>.repro-local``. When a foreign installer
## (pre-commit's ``pre-commit install``) later re-takes the standard hook path,
## the dispatcher is gone AGAIN while ``<hook>.repro-local`` still holds the
## copy chained the first time. The installer then refuses with "is user-owned
## and ... already exists" — so the documented remedy for a shadowed hook
## cannot repair the single state a shadowed hook is actually found in.
##
## Falsifiability / anti-vacuity
## -----------------------------
##
## Every assertion here POSITIVELY finds what it expects rather than asserting
## an absence:
##
##   * the repo set is asserted to CONTAIN all three participating repos and to
##     have an exact size, so a resolver that enumerates nothing fails;
##   * the entry count is asserted against an exact expected number
##     (repos x hooks), so an installer that writes zero hooks fails;
##   * the dispatcher files are read back and asserted to CARRY the sentinel,
##     so a missing file fails rather than passing an "is not foreign" test;
##   * the repaired chain is EXECUTED and both the chained shim's marker file
##     and the managed body's marker are asserted present, so a dispatcher that
##     is bytes-correct but does not actually run its chain fails.
##
## Hermetic: local bare origins under one ``createTempDir``; no network. Skip
## only when ``git`` is missing (the M9-M17 convention).

import std/[json, os, sequtils, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc git(gitBin: string; args: openArray[string]; cwd = ""): CmdResult =
  var argv = @[gitBin]
  argv.add(@args)
  runShell(shellCommand(argv), cwd = if cwd.len > 0: cwd else: getCurrentDir())

proc requireGit(gitBin: string; args: openArray[string]; cwd = "") =
  let res = git(gitBin, args, cwd)
  if res.code != 0:
    checkpoint("git " & args.join(" ") & " failed in " & cwd &
      "\nexit=" & $res.code & "\n" & res.output)
    fail()

const HookNames = ["pre-push", "post-commit", "post-merge", "post-checkout"]

# ---------------------------------------------------------------------------
# Fixture: three sibling repos plus a workspace root that is ITSELF a git repo
# carrying the manifests, exactly like metacraft-labs/workspace.
# ---------------------------------------------------------------------------

type WsFixture = object
  scratch: string
  reproBin: string
  root: string
  repoNames: seq[string]

proc seedOrigin(gitBin, originPath, workPath: string) =
  requireGit(gitBin, ["init", "--bare", "-b", "main", originPath])
  requireGit(gitBin, ["init", "-b", "main", workPath])
  requireGit(gitBin, ["-C", workPath, "config", "user.email",
    "tester@example.invalid"])
  requireGit(gitBin, ["-C", workPath, "config", "user.name", "Hook Tester"])
  writeFile(workPath / "README.md", "fixture\n")
  requireGit(gitBin, ["-C", workPath, "add", "README.md"])
  requireGit(gitBin, ["-C", workPath, "commit", "-m", "fixture"])
  requireGit(gitBin, ["-C", workPath, "remote", "add", "origin", originPath])
  requireGit(gitBin, ["-C", workPath, "push", "origin", "main"])

proc projectToml(urls: openArray[string]): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"wsroot\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n"
  for i, url in urls:
    result.add("[[remote]]\nname = \"lib-" & $i & "-origin\"\nfetch = \"" &
      url & "\"\n\n")
  result.add("includes = [\n")
  for i in 0 ..< urls.len:
    result.add("  \"repos/lib-" & $i & ".toml\",\n")
  result.add("]\n")

proc repoFragment(i: int): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\nname = \"lib-" & $i & "\"\npath = \"lib-" & $i & "\"\n" &
  "remote = \"lib-" & $i & "-origin\"\nrevision = \"main\"\n"

proc setupWorkspace(gitBin, slug: string; gitBackedRoot: bool): WsFixture =
  result.scratch = createTempDir("repro-wsroot-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.root = result.scratch / "workspace"
  createDir(result.root)

  var urls: seq[string]
  for i in 0 ..< 3:
    let name = "lib-" & $i
    result.repoNames.add(name)
    let origin = result.scratch / ("origin-" & name & ".git")
    seedOrigin(gitBin, origin, result.scratch / ("seed-" & name))
    urls.add(fileUrl(origin))
    requireGit(gitBin, ["clone", fileUrl(origin), result.root / name])
    requireGit(gitBin, ["-C", result.root / name, "config", "user.email",
      "tester@example.invalid"])
    requireGit(gitBin, ["-C", result.root / name, "config", "user.name",
      "Hook Tester"])

  createDir(result.root / "projects")
  createDir(result.root / "repos")
  writeFile(result.root / "projects" / "wsroot.toml", projectToml(urls))
  for i in 0 ..< 3:
    writeFile(result.root / "repos" / ("lib-" & $i & ".toml"), repoFragment(i))
  createDir(result.root / ".repro")
  writeFile(result.root / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"wsroot\"\nprojects = [\"wsroot\"]\n")

  if gitBackedRoot:
    # The shape that ships: the manifests live in a checked-out repo, so the
    # workspace root and a git top-level are the same directory.
    requireGit(gitBin, ["init", "-b", "main", result.root])
    requireGit(gitBin, ["-C", result.root, "config", "user.email",
      "tester@example.invalid"])
    requireGit(gitBin, ["-C", result.root, "config", "user.name",
      "Hook Tester"])
    writeFile(result.root / ".gitignore", "lib-0/\nlib-1/\nlib-2/\n")
    requireGit(gitBin, ["-C", result.root, "add", "-A"])
    requireGit(gitBin, ["-C", result.root, "commit", "-m", "manifests"])

proc ensure(fx: WsFixture; json = true): CmdResult =
  var argv = @[fx.reproBin, "hooks", "ensure", "--vcs",
    "--workspace-root=" & fx.root]
  if json: argv.add("--json")
  runShell(shellCommand(argv), cwd = fx.root)

proc hooksDirOf(repoPath: string): string = repoPath / ".git" / "hooks"

proc isDispatcher(path: string): bool =
  fileExists(path) and "reprobuild hook dispatcher" in readFile(path)

proc isManagedBody(path: string): bool =
  fileExists(path) and "reprobuild managed" in readFile(path)

# A pre-commit `hook-impl`-shaped shim. Writing its marker proves it RAN.
proc preCommitShim(marker, ranFile: string): string =
  "#!/usr/bin/env sh\n" &
  "# File generated by pre-commit: https://pre-commit.com\n" &
  "printf '%s\\n' " & quoteShell(marker) & " >> " & quoteShell(ranFile) & "\n" &
  "exit 0\n"

suite "hooks ensure reconciles a git-backed workspace root":

  test "test_ensure_reaches_every_repo_when_the_workspace_root_is_a_git_repo":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "reach", gitBackedRoot = true)
      defer: removeDir(fx.scratch)

      # Control: the root really IS a git top-level, so this fixture models
      # the shape that regressed and not a plain directory.
      let topLevel = git(gitBin, ["-C", fx.root, "rev-parse",
        "--show-toplevel"])
      check topLevel.code == 0
      check sameFile(topLevel.output.strip(), fx.root)

      let res = ensure(fx)
      checkpoint(res.output)
      check res.code == 0

      let report = parseJson(res.output)
      check report["mode"].getStr() == "workspace"
      check report["project"].getStr() == "wsroot"

      let repos = report["repos"].getElems().mapIt(it.getStr())
      # Positive membership + exact size: an empty or truncated enumeration
      # cannot read as success.
      for name in fx.repoNames:
        check name in repos
      # The workspace root repo participates too — it is pushed like any
      # other, and before the fix it was the ONLY repo the root-invoked
      # ensure reached. Losing it would trade one gap for another.
      check lastPathPart(fx.root) in repos
      check repos.len == fx.repoNames.len + 1

      let entries = report["entries"].getElems()
      check entries.len == (fx.repoNames.len + 1) * HookNames.len

      # And on disk, in every participating repo, for every hook.
      var installed = 0
      for repoPath in fx.repoNames.mapIt(fx.root / it) & @[fx.root]:
        let hooksDir = hooksDirOf(repoPath)
        for hookName in HookNames:
          check isDispatcher(hooksDir / hookName)
          check isManagedBody(hooksDir / (hookName & ".repro-managed"))
          inc installed
      check installed == (fx.repoNames.len + 1) * HookNames.len

  test "test_ensure_reinstalls_the_dispatcher_after_a_second_shadowing":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "reshadow", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let target = fx.root / "lib-0"
      let hooksDir = hooksDirOf(target)
      let ranFile = fx.scratch / "shim-ran.txt"
      let shim = preCommitShim("shim", ranFile)

      # 1. A foreign installer owns pre-push first; ensure chains it.
      writeFile(hooksDir / "pre-push", shim)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      let first = ensure(fx)
      checkpoint(first.output)
      check first.code == 0
      check isDispatcher(hooksDir / "pre-push")
      check fileExists(hooksDir / "pre-push.repro-local")
      check readFile(hooksDir / "pre-push.repro-local") == shim

      # 2. The foreign installer runs AGAIN and re-takes the standard path.
      #    This is the state every shadowed repo is found in.
      writeFile(hooksDir / "pre-push", shim)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check not isDispatcher(hooksDir / "pre-push")

      # 3. The documented remedy must repair it.
      let second = ensure(fx)
      checkpoint(second.output)
      check second.code == 0
      check isDispatcher(hooksDir / "pre-push")
      check isManagedBody(hooksDir / "pre-push.repro-managed")
      check fileExists(hooksDir / "pre-push.repro-local")
      check readFile(hooksDir / "pre-push.repro-local") == shim

      # 4. And the repaired chain must actually RUN the preserved shim.
      #    Git hands a pre-push hook the ref list on stdin and the dispatcher
      #    reads it to EOF before doing anything, so stdin must be closed
      #    explicitly — inheriting the test process's stdin hangs forever. An
      #    empty stream is also what makes the managed body a clean no-op,
      #    which isolates the chaining from the publication gate.
      removeFile(ranFile)
      #    ``REPROBUILD_REPRO`` names the build that generated this hook. The
      #    managed body refuses to let a ``repro`` it does not recognise speak
      #    for it, and the ``repro`` on a developer's PATH is routinely a
      #    different build — so pinning it here is what makes the assertion
      #    about the CHAIN rather than about the ambient PATH.
      let run = runShell(shellCommand(
        @["sh", "-c", quoteShell(hooksDir / "pre-push") & " origin " &
          quoteShell(fileUrl(fx.scratch / "origin-lib-0.git")) &
          " < /dev/null"],
        @[("REPROBUILD_REPRO", fx.reproBin)]), cwd = target)
      checkpoint(run.output)
      check run.code == 0
      check fileExists(ranFile)
      check "shim" in readFile(ranFile)

  test "test_a_manifest_backend_checkout_is_still_a_single_repo_target":
    # The counterweight to the case above, and the reason the "explicitly
    # targeted Git worktree" guard exists at all. The manifest LOCK BACKEND
    # is a checkout that carries manifest-shaped `projects/` and `repos/`
    # data and declares no workspace. Enumerating it as a workspace would
    # look for `<manifest>/<repo.path>` children that do not exist, install
    # zero hooks, and print a remediation that cannot work. Widening the
    # workspace branch to "has projects/" instead of "declares a workspace"
    # would silently break it, so it is asserted here.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "backend", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      # Same tree, minus the one thing that DECLARES a workspace.
      removeFile(fx.root / ".repro" / "workspace.toml")
      check dirExists(fx.root / "projects")   # positively still manifest-shaped
      check dirExists(fx.root / "repos")

      let res = ensure(fx)
      checkpoint(res.output)
      check res.code == 0
      # The legacy single-repo line, naming this checkout's own hooks dir.
      check "VCS hooks ensure" in res.output
      check (fx.root / ".git" / "hooks") in res.output
      # Its own hooks are installed...
      check isDispatcher(hooksDirOf(fx.root) / "pre-push")
      # ...and it did NOT reach into the sibling checkouts.
      check not fileExists(hooksDirOf(fx.root / "lib-0") / "pre-push")

  test "test_a_surviving_hook_repairs_a_deleted_pre_push_gate":
    # The dev shell runs pre-commit's installer on EVERY entry
    # (``shellHook = pre-commit-check.shellHook``), and for a config that
    # does not declare a pre-push stage that installer DELETES
    # ``.git/hooks/pre-push`` outright — leaving the managed body orphaned
    # beside it. Nothing re-ran ``ensure``, so the publication gate stayed
    # off and every later commit pushed unlocked. The hooks pre-commit is
    # not configured for still run, so they must put the gate back.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "selfheal", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let target = fx.root / "lib-2"
      let hooksDir = hooksDirOf(target)

      check ensure(fx).code == 0
      check isDispatcher(hooksDir / "pre-push")

      # Reproduce what `pre-commit uninstall --hook-type pre-push` does.
      removeFile(hooksDir / "pre-push")
      check not fileExists(hooksDir / "pre-push")
      # The managed body is still there, orphaned — this is the exact
      # on-disk shape the fleet was found in.
      check isManagedBody(hooksDir / "pre-push.repro-managed")
      # And post-commit survived, because pre-commit was not managing it.
      check isDispatcher(hooksDir / "post-commit")

      let healed = runShell(shellCommand(
        @[fx.reproBin, "hooks", "dispatch", "post-commit",
          "--protocol=2", "--repo-root", target]), cwd = target)
      checkpoint(healed.output)
      check healed.code == 0
      # Positively assert the repair happened AND was announced, so a
      # dispatch that silently does nothing cannot pass.
      check isDispatcher(hooksDir / "pre-push")
      check "repaired pre-push" in healed.output

  test "test_ensure_still_refuses_a_second_distinct_user_hook":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "conflict", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let hooksDir = hooksDirOf(fx.root / "lib-1")
      let ranFile = fx.scratch / "conflict-ran.txt"

      writeFile(hooksDir / "pre-push", preCommitShim("first", ranFile))
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check ensure(fx).code == 0
      check fileExists(hooksDir / "pre-push.repro-local")

      # A genuinely DIFFERENT user hook arrives. There is no basis for
      # discarding either one, so ensure must refuse loudly and name both.
      writeFile(hooksDir / "pre-push", preCommitShim("second", ranFile))
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      let refused = ensure(fx)
      checkpoint(refused.output)
      check refused.code != 0
      check "pre-push" in refused.output
      check (hooksDir / "pre-push.repro-local") in refused.output
      # The first shim is not silently destroyed.
      check readFile(hooksDir / "pre-push.repro-local") ==
        preCommitShim("first", ranFile)
