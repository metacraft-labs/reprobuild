## The pre-push gate refuses a force-push of EVERY branch a declared role of
## the pushed repo names — not only its mainline (Workspace-Branch-Roles.md §5
## and §9, `force_push_of_any_declared_role_is_refused`).
##
## WHY. The `mainline-history-rewrite` clause used to protect one branch: the
## declared mainline. The branching policy forbids force-pushing ANY shared
## branch, and the roles a manifest declares (`unstable`, `stable`, …) are
## exactly the shared branches it knows about — `repro sync --unstable` lands
## every teammate on the `unstable` branch, so rewriting it invalidates their
## working state just as rewriting the mainline does. A role that resolves only
## by FALLBACK adds nothing: its branch is the branch of the role it fell back
## to, which is protected already.
##
## The fixture's roles, all declared under names that are NOT `agents` or
## `dev`, so nothing compiled into the binary can stand in for the manifest:
##
##   | repo | role       | branch    | declared by                         |
##   |------|------------|-----------|-------------------------------------|
##   | app  | mainline   | main      | its repo.v2 fragment                |
##   | app  | unstable   | next      | its repo.v2 fragment                |
##   | app  | stable     | release   | the `product` profile it names      |
##   | lib  | mainline   | main      | its repo.v2 fragment (nothing else) |
##
## Cases, each refusal paired with the near-identical push that passes:
##
##   * PRIMARY — force-pushing app's `next` (its declared `unstable`) is
##     refused as `mainline-history-rewrite`, naming the branch and the role,
##     and the remote keeps the history; the identical rewrite pushed to a
##     branch no role names passes;
##   * force-pushing app's `release` — declared by a PROFILE, not the fragment —
##     is refused the same way;
##   * lib declares no `unstable`, so its `unstable` resolves by fallback to
##     `main`: a force-push of lib's `next` is an ordinary feature-branch
##     rewrite and passes. Without this converse the clause would be
##     indistinguishable from refusing every branch some OTHER repo declares;
##   * the mainline case keeps its own wording (`the shared mainline 'main'`),
##     which `t_pre_push_rewrite_orphan_gate` also asserts, unmodified;
##   * the workspace ROOT repository is a pushed repo with roles of its own,
##     declared in the settings file (§3.4): under `repro-workspace.toml`
##     its `[workspace] unstable = "edge"` and `mainline = "main"` are both
##     refused, and the same rewrite to an undeclared branch passes. A
##     `[records] branch` (here `trunk`, even with the root as the store) is
##     the record store's branch, never a role of the root: a root that
##     declares no `[workspace]` roles protects nothing by role, and nothing
##     is inferred from its store or its `origin/HEAD`.
##
## Mutation-checked: dropping the non-mainline roles from the protected set
## (`declaredRoleBranches` returning the mainline alone) passes the `next`
## force-push, failing the PRIMARY case on `check res.code != 0`. Skipping
## the root's clause in the gate passes the root's `edge` force-push, failing
## the root case on the same check.
##
## No mocks. Real `git init` / `git init --bare` repositories, the real
## `repro hooks ensure` installation, real `git push` through the installed
## pre-push hook, and the real manifest and settings readers. No network.
##
## Skip rule: `git` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip
import repro_test_support

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd,
    options = {poStdErrToStdOut, poUsePath})
  (res.exitCode, res.output)

proc require(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc reproBinary(): string =
  let configured = getEnv("REPROBUILD_REPRO")
  let candidate =
    if configured.len > 0: configured
    else: currentSourcePath().parentDir.parentDir.parentDir / "build" /
      "bin" / addFileExt("repro", ExeExt)
  requireBinary(candidate, "reprobuild.apps.repro")

type
  EnvSnapshot = object
    existed: bool
    value: string

  Fixture = object
    scratch, workspace, app, lib, appOrigin, libOrigin: string
    gitBin, reproBin: string

proc overrideEnv(name, value: string): EnvSnapshot =
  result = EnvSnapshot(existed: existsEnv(name), value: getEnv(name))
  putEnv(name, value)

proc restoreEnv(name: string; snapshot: EnvSnapshot) =
  if snapshot.existed: putEnv(name, snapshot.value)
  else: delEnv(name)

proc gitIn(fx: Fixture; repo: string; args: openArray[string];
    required = true): tuple[code: int; output: string] =
  var argv = @[fx.gitBin, "-C", repo]
  argv.add(args)
  let res = runShell(shellCommand(argv))
  result = (res.code, res.output)
  if required and result.code != 0:
    checkpoint("git failed: " & argv.join(" ") & "\n" & res.output)
    quit 1

proc headOf(fx: Fixture; repo: string): string =
  fx.gitIn(repo, ["rev-parse", "HEAD"]).output.strip()

proc commitIn(fx: Fixture; repo, label: string): string =
  writeFile(repo / "content.txt", label & "\n")
  discard fx.gitIn(repo, ["add", "content.txt"])
  discard fx.gitIn(repo, ["commit", "-m", label])
  fx.headOf(repo)

proc remoteTip(fx: Fixture; repo, remote, branch: string): string =
  fx.gitIn(repo, ["ls-remote", remote, "refs/heads/" & branch])
    .output.strip().split('\t')[0]

proc writeManifest(fx: Fixture) =
  ## Membership at the workspace root (native flat layout), the settings file
  ## declaring the `product` profile, and two repo.v2 fragments.
  createDir(fx.workspace / "projects")
  createDir(fx.workspace / "repos")
  createDir(fx.workspace / ".repro")
  writeFile(fx.workspace / ".repro" / "workspace-state.toml",
    "schema = \"reprobuild.workspace.state.v1\"\n\n" &
    "[workspace]\nproject = \"app\"\nbranch = \"main\"\n")
  writeFile(fx.workspace / "repro-workspace.toml",
    "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
    "[workspace]\nmainline = \"main\"\n\n" &
    "[profiles.product]\nmainline = \"main\"\nstable = \"release\"\n")
  writeFile(fx.workspace / "projects" / "app.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\n\n" &
    "[[remote]]\nname = \"app-origin\"\nfetch = \"" &
      fx.appOrigin.replace('\\', '/') & "\"\n\n" &
    "[[remote]]\nname = \"lib-origin\"\nfetch = \"" &
      fx.libOrigin.replace('\\', '/') & "\"\n\n" &
    "includes = [\"repos/app.toml\", \"repos/lib.toml\"]\n")
  writeFile(fx.workspace / "repos" / "app.toml",
    "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
    "[repo]\nname = \"app\"\npath = \"app\"\nremote = \"app-origin\"\n" &
    "profile = \"product\"\nmainline = \"main\"\nunstable = \"next\"\n")
  writeFile(fx.workspace / "repos" / "lib.toml",
    "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
    "[repo]\nname = \"lib\"\npath = \"lib\"\nremote = \"lib-origin\"\n" &
    "mainline = \"main\"\n")

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-role-rewrite-" & slug & "-", "")
  result.workspace = result.scratch / "workspace"
  result.app = result.workspace / "app"
  result.lib = result.workspace / "lib"
  result.appOrigin = result.scratch / "origin-app.git"
  result.libOrigin = result.scratch / "origin-lib.git"
  result.gitBin = gitBin
  result.reproBin = reproBinary()
  createDir(result.workspace)
  for origin in [result.appOrigin, result.libOrigin]:
    discard require(q(gitBin) & " init --bare -b main " & q(origin))
  for (path, remoteName, origin) in [
      (result.app, "app-origin", result.appOrigin),
      (result.lib, "lib-origin", result.libOrigin)]:
    discard require(q(gitBin) & " init -b main " & q(path))
    discard result.gitIn(path, ["config", "user.email",
      "tester@example.invalid"])
    discard result.gitIn(path, ["config", "user.name", "Role Tester"])
    discard result.gitIn(path, ["remote", "add", remoteName, origin])
    writeFile(path / "content.txt", "seed\n")
    discard result.gitIn(path, ["add", "content.txt"])
    discard result.gitIn(path, ["commit", "-m", "seed"])
    discard result.gitIn(path, ["push", "--no-verify", "-u", remoteName,
      "main"])
  result.writeManifest()
  # The lock store the gate writes into: a real git checkout with a real
  # upstream, so the gate runs its production write-and-publish path (as in
  # `t_pre_push_rewrite_orphan_gate`).
  let storeOrigin = result.scratch / "origin-manifests.git"
  let store = result.workspace / ".repro" / "manifests"
  discard require(q(gitBin) & " init --bare -b main " & q(storeOrigin))
  discard require(q(gitBin) & " clone " & q("file://" & storeOrigin) & " " &
    q(store))
  discard result.gitIn(store, ["config", "user.email",
    "tester@example.invalid"])
  discard result.gitIn(store, ["config", "user.name", "Role Tester"])
  writeFile(store / "README.md", "lock store\n")
  discard result.gitIn(store, ["add", "-A"])
  discard result.gitIn(store, ["commit", "-m", "seed"])
  discard result.gitIn(store, ["push", "--no-verify", "origin", "main"])
  discard require(q(gitBin) & " init -b main " & q(result.workspace))
  discard result.gitIn(result.workspace, ["config", "user.email",
    "tester@example.invalid"])
  discard result.gitIn(result.workspace, ["config", "user.name",
    "Role Tester"])
  writeFile(result.workspace / ".gitignore", "/.repro/\n/app/\n/lib/\n")
  discard result.gitIn(result.workspace, ["add", "-A"])
  discard result.gitIn(result.workspace, ["commit", "-m", "seed manifests"])
  let ensured = runShell(shellCommand(@[result.reproBin, "hooks", "ensure",
    "--vcs", "--workspace-root=" & result.workspace, result.workspace]))
  if ensured.code != 0:
    checkpoint("hook ensure failed:\n" & ensured.output)
    quit 1
  # Post-commit / post-merge / post-checkout refreshes are orthogonal here and
  # would rewrite locks between the steps this suite measures.
  for repo in [result.app, result.lib]:
    for name in ["post-commit", "post-merge", "post-checkout"]:
      for suffix in ["", ".repro-managed", ".repro-local"]:
        let path = repo / ".git" / "hooks" / (name & suffix)
        if fileExists(path): removeFile(path)

template refuses(res: tuple[code: int; output: string];
    needles: openArray[string]) =
  ## Refused FOR THE STATED REASON: a bare `code != 0` would pass against a
  ## gate that refuses every force-push.
  if res.code == 0:
    checkpoint("push unexpectedly passed:\n" & res.output)
  check res.code != 0
  for needle in needles:
    if needle notin res.output:
      checkpoint("missing '" & needle & "' in:\n" & res.output)
    check needle in res.output
  # A rewrite publishes HEAD; the gate must not call it unpublished, and
  # nothing here pins the discarded commits from a sibling's lock.
  for bad in ["unpublished", "will not help", "orphans-locked-commit"]:
    if bad in res.output:
      checkpoint("forbidden '" & bad & "' in:\n" & res.output)
    check bad notin res.output

template passes(res: tuple[code: int; output: string]) =
  if res.code != 0:
    checkpoint("push unexpectedly refused:\n" & res.output)
  check res.code == 0

template withFixture(gitBin, slug: string; body: untyped) =
  var fx {.inject.} = setupFixture(gitBin, slug)
  defer: removeDir(fx.scratch)
  let priorRepro = overrideEnv("REPROBUILD_REPRO", fx.reproBin)
  let priorSystem = overrideEnv("REPROBUILD_SYSTEM_CONFIG",
    fx.scratch / "no-system.toml")
  let priorUser = overrideEnv("REPROBUILD_USER_CONFIG",
    fx.scratch / "no-user.toml")
  let priorVcsPrivate = overrideEnv("REPROBUILD_VCS_PRIVATE_CONFIG",
    fx.scratch / "no-vcs-private.toml")
  let priorConfig = overrideEnv("REPRO_WORKSPACE_CONFIG", "")
  delEnv("REPRO_WORKSPACE_CONFIG")
  defer:
    restoreEnv("REPRO_WORKSPACE_CONFIG", priorConfig)
    restoreEnv("REPROBUILD_VCS_PRIVATE_CONFIG", priorVcsPrivate)
    restoreEnv("REPROBUILD_USER_CONFIG", priorUser)
    restoreEnv("REPROBUILD_SYSTEM_CONFIG", priorSystem)
    restoreEnv("REPROBUILD_REPRO", priorRepro)
  body

proc publishThenRewrite(fx: Fixture; repo, remote, branch: string):
    tuple[published, rewritten: string] =
  ## Publish one commit on `branch` (a branch create), then replace it with a
  ## different commit on the same parent, ready for a force-push.
  discard fx.gitIn(repo, ["checkout", "-q", "-B", branch, "main"])
  result.published = fx.commitIn(repo, branch & " work")
  let created = fx.gitIn(repo, ["push", remote, branch], required = false)
  if created.code != 0:
    checkpoint("creating '" & branch & "' was refused:\n" & created.output)
  doAssert created.code == 0, "the fixture could not publish " & branch
  discard fx.gitIn(repo, ["reset", "-q", "--hard", "main"])
  result.rewritten = fx.commitIn(repo, branch & " work, rewritten")
  doAssert result.rewritten != result.published

suite "pre-push gate — every declared role branch is protected":

  test "force_push_of_any_declared_role_is_refused":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      withFixture(gitBin, "roles"):
        # PRIMARY: app's declared `unstable` branch.
        let next = fx.publishThenRewrite(fx.app, "app-origin", "next")
        let refusedNext = fx.gitIn(fx.app,
          ["push", "--force", "app-origin", "next"], required = false)
        refuses(refusedNext, ["mainline-history-rewrite",
          "the shared branch 'next' (role `unstable`)",
          "the branch of the `unstable` role", next.published,
          "is publishable"])
        check fx.remoteTip(fx.app, "app-origin", "next") == next.published
        # The identical rewrite to a branch no role names is published.
        passes(fx.gitIn(fx.app,
          ["push", "app-origin", "HEAD:refs/heads/next-rework"],
          required = false))
        check fx.remoteTip(fx.app, "app-origin", "next-rework") ==
          next.rewritten

        # A role declared by the PROFILE the fragment names, not the fragment.
        let release = fx.publishThenRewrite(fx.app, "app-origin", "release")
        let refusedRelease = fx.gitIn(fx.app,
          ["push", "--force", "app-origin", "release"], required = false)
        refuses(refusedRelease, ["mainline-history-rewrite",
          "the shared branch 'release' (role `stable`)", release.published])
        check fx.remoteTip(fx.app, "app-origin", "release") ==
          release.published

        # The mainline keeps the wording it always had.
        discard fx.gitIn(fx.app, ["checkout", "-q", "main"])
        let mainPublished = fx.commitIn(fx.app, "mainline work")
        passes(fx.gitIn(fx.app, ["push", "app-origin", "main"],
          required = false))
        discard fx.gitIn(fx.app, ["reset", "-q", "--hard", "HEAD~1"])
        discard fx.commitIn(fx.app, "mainline rewritten")
        let refusedMain = fx.gitIn(fx.app,
          ["push", "--force", "app-origin", "main"], required = false)
        refuses(refusedMain, ["mainline-history-rewrite",
          "the shared mainline 'main'", "the mainline branch", mainPublished])

  test "a role that resolves only by fallback protects nothing new":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      withFixture(gitBin, "fallback"):
        # lib declares no `unstable` (it resolves to `main` by fallback), so
        # its `next` is an ordinary feature branch even though app declares
        # a role of that name.
        let next = fx.publishThenRewrite(fx.lib, "lib-origin", "next")
        passes(fx.gitIn(fx.lib, ["push", "--force", "lib-origin", "next"],
          required = false))
        check fx.remoteTip(fx.lib, "lib-origin", "next") == next.rewritten

  test "the workspace root repository's declared roles are protected":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      withFixture(gitBin, "root"):
        # The ROOT repository declares its roles in the settings file
        # (Workspace-Branch-Roles.md §3.4), not in a fragment: here its
        # mainline `main` and its `unstable` `edge`. It is published to an
        # `origin` of its own, the remote every root operation uses.
        let ws = fx.workspace
        for name in ["post-commit", "post-merge", "post-checkout"]:
          for suffix in ["", ".repro-managed", ".repro-local"]:
            let path = ws / ".git" / "hooks" / (name & suffix)
            if fileExists(path): removeFile(path)
        let rootOrigin = fx.scratch / "origin-root.git"
        discard require(q(gitBin) & " init --bare -b main " & q(rootOrigin))
        discard fx.gitIn(ws, ["remote", "add", "origin", rootOrigin])
        writeFile(ws / "repro-workspace.toml",
          "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
          "[workspace]\nmainline = \"main\"\nunstable = \"edge\"\n\n" &
          "[profiles.product]\nmainline = \"main\"\nstable = \"release\"\n")
        discard fx.gitIn(ws, ["commit", "-q", "-am", "root roles"])
        discard fx.gitIn(ws, ["push", "--no-verify", "-u", "origin", "main"])

        # PRIMARY: the root's declared `unstable` branch.
        let edge = fx.publishThenRewrite(ws, "origin", "edge")
        let refusedEdge = fx.gitIn(ws, ["push", "--force", "origin", "edge"],
          required = false)
        refuses(refusedEdge, ["mainline-history-rewrite",
          "the shared branch 'edge' (role `unstable`)",
          "declares for the workspace root repository", edge.published])
        check fx.remoteTip(ws, "origin", "edge") == edge.published
        # The identical rewrite to a branch no root role names is published.
        passes(fx.gitIn(ws, ["push", "--force", "origin",
          "HEAD:refs/heads/edge-rework"], required = false))
        check fx.remoteTip(ws, "origin", "edge-rework") == edge.rewritten

        # The root's mainline.
        discard fx.gitIn(ws, ["checkout", "-q", "main"])
        let mainPublished = fx.commitIn(ws, "root mainline work")
        passes(fx.gitIn(ws, ["push", "origin", "main"], required = false))
        discard fx.gitIn(ws, ["reset", "-q", "--hard", "HEAD~1"])
        discard fx.commitIn(ws, "root mainline rewritten")
        let refusedMain = fx.gitIn(ws, ["push", "--force", "origin", "main"],
          required = false)
        refuses(refusedMain, ["mainline-history-rewrite",
          "the shared mainline 'main'", mainPublished])
        check fx.remoteTip(ws, "origin", "main") == mainPublished

  test "a record store's branch is no role of the root":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      withFixture(gitBin, "root-legacy"):
        # `[records]` names the record store and its branch — here the root
        # repository itself, on `trunk` — and `[workspace]` declares no root
        # role. The store's branch is not the root's mainline, so it is not
        # protected by role.
        let ws = fx.workspace
        for name in ["post-commit", "post-merge", "post-checkout"]:
          for suffix in ["", ".repro-managed", ".repro-local"]:
            let path = ws / ".git" / "hooks" / (name & suffix)
            if fileExists(path): removeFile(path)
        let rootOrigin = fx.scratch / "origin-root.git"
        discard require(q(gitBin) & " init --bare -b main " & q(rootOrigin))
        discard fx.gitIn(ws, ["remote", "add", "origin", rootOrigin])
        discard fx.gitIn(ws, ["rm", "-q", "repro-workspace.toml"])
        writeFile(ws / "repro-workspace.toml",
          "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
          "[records]\nurl = \"" & rootOrigin.replace('\\', '/') & "\"\n" &
          "branch = \"trunk\"\n")
        # The settings file declares no profiles, so app names none either.
        writeFile(ws / "repos" / "app.toml",
          "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
          "[repo]\nname = \"app\"\npath = \"app\"\n" &
          "remote = \"app-origin\"\nmainline = \"main\"\n" &
          "unstable = \"next\"\n")
        discard fx.gitIn(ws, ["add", "-A"])
        discard fx.gitIn(ws, ["commit", "-q", "-m", "records-only settings file"])
        discard fx.gitIn(ws, ["push", "--no-verify", "-u", "origin", "main"])

        let trunk = fx.publishThenRewrite(ws, "origin", "trunk")
        let rewritten = fx.gitIn(ws, ["push", "--force", "origin", "trunk"],
          required = false)
        passes(rewritten)
        check "mainline-history-rewrite" notin rewritten.output
        check fx.remoteTip(ws, "origin", "trunk") != trunk.published
        # `main` is no role of this root either: an ordinary rewrite passes.
        discard fx.gitIn(ws, ["checkout", "-q", "main"])
        discard fx.commitIn(ws, "root main work")
        passes(fx.gitIn(ws, ["push", "origin", "main"], required = false))
        discard fx.gitIn(ws, ["reset", "-q", "--hard", "HEAD~1"])
        let rewrittenMain = fx.commitIn(ws, "root main rewritten")
        passes(fx.gitIn(ws, ["push", "--force", "origin", "main"],
          required = false))
        check fx.remoteTip(ws, "origin", "main") == rewrittenMain
