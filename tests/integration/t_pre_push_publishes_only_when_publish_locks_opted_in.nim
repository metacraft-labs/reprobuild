## MO-14 — central workspace-lock PUBLICATION is opt-in via
## ``[manifest] publish_locks``.
##
## The committed lock is the primary reproducibility boundary
## (Workspace-Manifests.md §"The committed lock carries the full set"): a
## workspace syncs, checks, and gates from it with no manifest repo at all.
## Central PUBLICATION of the workspace lock to the shared manifest repo — the
## pre-push gate's RA-7/RA-21 commit + push of the ``locks/`` subtree — used to
## fire IMPLICITLY whenever a ``.repro/manifests`` git checkout was present.
## MO-14 makes it EXPLICIT and OFF BY DEFAULT: only when the host bootstrap
## config (``.repro-workspace.toml``) sets ``[manifest] publish_locks = true``
## does a passing gate publish. Absent config, or ``publish_locks`` absent /
## ``false``, is committed-lock-only: the gate still writes/refreshes the lock
## locally and PASSES cleanly, but pushes nothing to the manifest repo.
##
## This test builds a single-repo workspace whose manifest layer
## (``.repro/manifests``) IS a real git checkout WITH a bare upstream — exactly
## the shape that used to publish on presence. It then runs the same pre-push
## gate under three configurations and asserts:
##
##   (A) no ``.repro-workspace.toml`` at all           → gate PASSES, bare gets
##                                                        NO lock commit.
##   (B) ``.repro-workspace.toml`` with publish_locks   → gate PASSES, bare gets
##       absent (only ``url``)                            NO lock commit.
##   (C) ``.repro-workspace.toml`` with publish_locks   → gate PASSES, and the
##       = true                                           lock record LANDS in
##                                                        the bare upstream.
##
## Falsifiability: (A)/(B) assert the bare's commit count is UNCHANGED and no
## ``locks/`` path is present in the pushed tree — a regression to presence-based
## publication fails there. (C) asserts the bare's commit count grew and the
## exact ``locks/lib-a/lib-a/<sha>.toml`` path is present — a helper that read
## ``publish_locks`` as always-off fails there. All three assert exit 0 (the
## gate must never turn "publication disabled" into a hard failure).
##
## Uses NO mocks: a real ``repro`` binary drives real ``git`` checkouts and a
## real local bare upstream. Hermetic: only local ``git init`` /
## ``git init --bare``; no network. Skip rule: ``git`` missing on PATH.

import std/[json, options, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

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

proc commitCount(gitBin, repo, rev: string): int =
  let res = runCmd(q(gitBin) & " -C " & q(repo) & " rev-list --count " & rev)
  if res.code != 0: return -1
  res.output.strip().parseInt()

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"MO14 Tester\"")
  writeFile(workPath / "README.md", "MO14 publish-optin fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"MO14 Tester\"")

proc projectTomlWith1Remote(libAUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"lib-a\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    manifestsRoot: string
    manifestBare: string
    libAOrigin: string
    libASha: string

proc seedManifestGitLayer(gitBin, manifestsRoot, bare: string;
                          branch = "main") =
  ## Make ``.repro/manifests`` a real git checkout that TRACKS a bare upstream —
  ## so the pre-push gate genuinely CAN publish when opted in.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(bare))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(manifestsRoot))
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " config user.name \"MO14 Tester\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " add projects repos")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " commit -m \"seed manifest\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " remote add origin " & q(bare))
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " push -u origin " & branch)

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-mo14-" & slug & "-", "")
  result.reproBin = reproBinary()

  result.libAOrigin = result.scratch / "origin-lib-a.git"
  let seedPath = result.scratch / "seed-lib-a"
  result.libASha = seedGitOrigin(gitBin, result.libAOrigin, seedPath)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repro" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectTomlWith1Remote(fileUrl(result.libAOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.manifestsRoot = manifestsRoot
  result.manifestBare = result.scratch / "manifest.git"
  seedManifestGitLayer(gitBin, manifestsRoot, result.manifestBare)
  cloneInto(gitBin, result.libAOrigin, workspaceRoot / "lib-a")
  result.workspaceRoot = workspaceRoot
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

proc writeBootstrapConfig(fx: Fixture; publishLocks: Option[bool]) =
  ## Write ``.repro-workspace.toml`` with a (harmless, never-fetched) manifest
  ## ``url`` and, optionally, an explicit ``publish_locks`` flag.
  var body =
    "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
    "[manifest]\n" &
    "url = \"" & fileUrl(fx.manifestBare) & "\"\n" &
    "branch = \"main\"\n"
  if publishLocks.isSome:
    body.add("publish_locks = " & (if publishLocks.get(): "true" else: "false") &
      "\n")
  writeFile(fx.workspaceRoot / ".repro-workspace.toml", body)

proc writeRefsFile(path: string; localSha: string) =
  let zeroSha = "0000000000000000000000000000000000000000"
  writeFile(path, "refs/heads/main " & localSha & " " &
    "refs/heads/main " & zeroSha & "\n")

proc invokeCheckPrePush(fx: Fixture; refsFile: string): tuple[code: int;
    output: string] =
  runCmd(q(fx.reproBin) & " check --mode=pre-push --write-report" &
    " --workspace-root=" & q(fx.workspaceRoot) &
    " --current-repo=" & q(fx.workspaceRoot / "lib-a") &
    " --pushed-refs=" & q(refsFile) & " --json")

proc bareHasLockRecord(gitBin, bare: string): bool =
  let ls = runCmd(q(gitBin) & " -C " & q(bare) &
    " ls-tree -r --name-only refs/heads/main")
  ls.code == 0 and ls.output.contains("locks/lib-a/lib-a/")

suite "MO-14 — pre-push publishes only when publish_locks is opted in":

  test "t_pre_push_publishes_only_when_publish_locks_opted_in":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # ---- (A) no bootstrap config → committed-lock-only, no publish -------
      block:
        let fx = setupFixture(gitBin, "noconfig")
        defer: removeDir(fx.scratch)
        let refsFile = fx.scratch / "pushed-refs.txt"
        writeRefsFile(refsFile, fx.libASha)
        let baseCount = commitCount(gitBin, fx.manifestBare,
          "refs/heads/main")
        check baseCount >= 1

        let res = invokeCheckPrePush(fx, refsFile)
        checkpoint("no-config gate output: " & res.output)
        # The gate PASSES — a missing config is committed-lock-only, never a
        # publication failure.
        check res.code == 0
        # Nothing reached the bare upstream: no new commit, no lock path.
        check commitCount(gitBin, fx.manifestBare, "refs/heads/main") ==
          baseCount
        check not bareHasLockRecord(gitBin, fx.manifestBare)

      # ---- (B) config present but publish_locks absent → still no publish --
      block:
        let fx = setupFixture(gitBin, "optout")
        defer: removeDir(fx.scratch)
        writeBootstrapConfig(fx, none(bool))
        let refsFile = fx.scratch / "pushed-refs.txt"
        writeRefsFile(refsFile, fx.libASha)
        let baseCount = commitCount(gitBin, fx.manifestBare,
          "refs/heads/main")

        let res = invokeCheckPrePush(fx, refsFile)
        checkpoint("opt-out gate output: " & res.output)
        check res.code == 0
        check commitCount(gitBin, fx.manifestBare, "refs/heads/main") ==
          baseCount
        check not bareHasLockRecord(gitBin, fx.manifestBare)

      # ---- (C) publish_locks = true → publishes on a passing gate ----------
      block:
        let fx = setupFixture(gitBin, "optin")
        defer: removeDir(fx.scratch)
        writeBootstrapConfig(fx, some(true))
        let refsFile = fx.scratch / "pushed-refs.txt"
        writeRefsFile(refsFile, fx.libASha)
        let baseCount = commitCount(gitBin, fx.manifestBare,
          "refs/heads/main")

        let res = invokeCheckPrePush(fx, refsFile)
        checkpoint("opt-in gate output: " & res.output)
        check res.code == 0
        # The lock record LANDED in the bare upstream.
        check commitCount(gitBin, fx.manifestBare, "refs/heads/main") ==
          baseCount + 1
        check bareHasLockRecord(gitBin, fx.manifestBare)
