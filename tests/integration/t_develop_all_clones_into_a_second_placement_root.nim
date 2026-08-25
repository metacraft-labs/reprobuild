## CLI/develop.md §"Action axis" — ``--into=<dir>`` is the checkout-placement
## root, so it DETERMINES WHERE a node lands. A placement key that ignores it
## makes the second placement of the same node resolve as the first one.
##
## The defect this pins down (reproduced against the build that shipped the
## DS-1/DS-3/DS-5 fixes, with no lock-record tampering of any kind):
##
##   $ repro develop --all --into=<A>     # clones team-lib, exit 0
##   $ rm .repro/develop-overrides.toml   # the remedy the tool itself prints
##   $ repro develop --all --into=<B>     # exit 1, <B> never created
##   repro develop --all: error team-lib — reset-to-locked-revision failed:
##   status=asFailed reason=force-reset-target-missing stderr=force-reset
##   target is not a git working tree: <B>/team-lib
##
## Two independent causes, and BOTH have to go or the bug survives:
##
##   1. the clone/reset RECEIPTS were named ``develop-all-clone-<node>``, with
##      no component from the target path, so both placements declared the
##      same output file and shared one action id;
##   2. more fundamentally, the clone action was CACHEABLE while its
##      fingerprint deliberately omits ``repoPath`` (git_actions.nim
##      ``fingerprintPayload`` — M2 design rule 1, so two temp roots cloning
##      the same (remote, revision, identity) share a cache entry). The
##      action's real product is a WORKING TREE, which is not a declared
##      output; only the receipt is. So with the engine default
##      ``rebuildMissingOutputsOnCacheHit = false`` the second run hit the
##      shared entry, materialized the receipt, cloned nothing, and the
##      chained force-reset failed against a directory that never existed.
##
##   Fixing only (1) is NOT enough — the fingerprint is unchanged, so the
##   lookup still hits and still restores the receipt without cloning. The
##   clone action is therefore non-cacheable now, for the same reason
##   ``gitForceResetAction`` already is: its precondition is live working-tree
##   state, not a deterministic function of its declared inputs.
##
## Why it matters: ``repro develop --all`` MUTATES WORKING TREES. It failed
## with a diagnostic that names an internal action ("force-reset target is not
## a git working tree") rather than the real cause, on a workflow the tool
## itself directs the user into — its refusal for a moved placement literally
## says "drop it before re-developing into <B>".
##
## Fixture: the DS-1 shape — a workspace with NO committed lock whose team
## route is carried by configuration layer 5
## (``<git-common-dir>/repro/config.toml``), backed by a real git-checkout
## lock store holding a real published record.
##
## Asserts:
##   1. placing into a SECOND root succeeds and produces a real checkout at
##      the exact locked revision (the regression under test);
##   2. the two placements wrote DISTINCT receipts, so the key really does
##      carry the target and not just the node;
##   3. re-running into an ALREADY-PLACED root is still recognised as
##      already-satisfied (``adopted``) — the fix must not turn idempotence
##      into a re-clone.
##
## Mocks: NONE. Real git repos on the real filesystem, a real manifest
## checkout, a real layer-5 config inside a real ``.git``, the real
## git-checkout lock backend, the real ``repro`` binary and the real build
## engine.
##
## Hermetic: fresh tempdir; layers 2 and 3 are silenced via the
## ``REPROBUILD_*_CONFIG`` overrides. Skip: ``git`` missing or repro unbuilt.

import std/[os, osproc, strutils, tempfiles, unittest]

const reproBinary = "./build/bin/" & addFileExt("repro", ExeExt)

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"Placement Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  writeFile(workPath / "seed.txt", "seed " & extractFilename(workPath) & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add seed.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q("file://" & originPath) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"Placement Tester\"")

proc projectToml(teamUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"team-origin\"\nfetch = \"" & teamUrl & "\"\n\n" &
  "includes = [\n  \"repos/team-lib.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

proc receiptNames(ws: string): seq[string] =
  let dir = ws / ".repro" / "workspace" / "receipts"
  if not dirExists(dir): return @[]
  for kind, path in walkDir(dir):
    if kind == pcFile and extractFilename(path).startsWith("develop-all-clone-"):
      result.add(extractFilename(path))

suite "develop --all: a placement key carries the target, not just the node":

  test "t_develop_all_clones_into_a_second_placement_root":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("develop-placement-", "")
      defer: removeDir(scratch)

      let teamOrigin = scratch / "origin-team.git"
      let teamSha = seedGitOrigin(gitBin, teamOrigin, scratch / "seed-team")
      check teamSha.len == 40

      let ws = scratch / "workspace"
      initGitRepo(gitBin, ws)

      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "mix.toml",
        projectToml("file://" & teamOrigin))
      writeFile(manifestsRoot / "repos" / "team-lib.toml",
        repoFragment("team-lib", "team-origin"))
      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")

      # The repo must be present in the workspace for `repro workspace lock`
      # to have a HEAD to record for it.
      cloneInto(gitBin, teamOrigin, ws / "team-lib")

      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\n" &
        "project = \"mix\"\n" &
        "branch = \"main\"\n")
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n")

      let layer5Dir = ws / ".git" / "repro"
      createDir(layer5Dir)
      writeFile(layer5Dir / "config.toml",
        "schema = \"reprobuild.config.v1\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests\", repos = [\"team-lib\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")

      let lockRes = run(repro & " workspace lock --workspace-root=" & q(ws))
      check lockRes.code == 0
      check fileExists(manifestsRoot / "locks" / "mix" / "team-lib" /
        (teamSha & ".toml"))

      let depsA = scratch / "depsA"
      let depsB = scratch / "depsB"
      let overrides = ws / ".repro" / "develop-overrides.toml"

      # ---- placement 1 ---------------------------------------------------
      let first = run(repro & " develop --all --into=" & q(depsA) &
        " --tool-provisioning=path", cwd = ws)
      if first.code != 0:
        checkpoint("placement 1 output: " & first.output)
      check first.code == 0
      check dirExists(depsA / "team-lib")
      check requireGit(q(gitBin) & " -C " & q(depsA / "team-lib") &
        " rev-parse HEAD").strip() == teamSha
      let receiptsAfterA = receiptNames(ws)
      check receiptsAfterA.len == 1

      # ---- (3) the SAME root is still already-satisfied -------------------
      # Guarded before the override is dropped, because the override entry is
      # itself part of what makes a repeat run idempotent.
      let again = run(repro & " develop --all --into=" & q(depsA) &
        " --tool-provisioning=path", cwd = ws)
      if again.code != 0:
        checkpoint("repeat placement output: " & again.output)
      check again.code == 0
      check ("already in develop mode" in again.output) or
        ("adopted existing checkout of team-lib" in again.output)

      # ---- placement 2, a DIFFERENT root ---------------------------------
      # Dropping the override is exactly what the tool instructs when a node
      # is re-developed into another root ("drop it before re-developing
      # into …"), so this is the supported workflow, not a contrivance.
      removeFile(overrides)
      let second = run(repro & " develop --all --into=" & q(depsB) &
        " --tool-provisioning=path", cwd = ws)
      if second.code != 0:
        checkpoint("placement 2 output: " & second.output)
      # (1) the regression: this used to exit 1 with "force-reset target is
      # not a git working tree" and create nothing at all.
      check "force-reset target is not a git working tree" notin second.output
      check second.code == 0
      check dirExists(depsB / "team-lib")
      check requireGit(q(gitBin) & " -C " & q(depsB / "team-lib") &
        " rev-parse HEAD").strip() == teamSha
      # The first placement is untouched by the second.
      check dirExists(depsA / "team-lib")

      # ---- (2) the two placements are distinct receipts -------------------
      let receiptsAfterB = receiptNames(ws)
      check receiptsAfterB.len == 2
