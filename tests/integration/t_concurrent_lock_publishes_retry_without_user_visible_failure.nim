## RA-29 — concurrent lock publication retries non-fast-forward invisibly.
##
## Locks are commit-addressed (``locks/<project>/<repo>/<sha>.toml``), so
## two concurrent publishers write DISJOINT paths — append-only, no shared
## mutable file (Workspace-And-Develop-Mode.md §"Locks are commit-addressed,
## so concurrent publication does not collide"). When the manifest tip
## advances under a publisher (another agent published first), its push is
## rejected non-fast-forward; RA-29 RE-FETCHES the tip, RE-APPLIES this
## publisher's lock commit on top (disjoint path ⇒ conflict-free, NOT a
## force-push), and RE-PUSHES — so the race is INVISIBLE to the user and
## NEITHER lock is lost. A genuine (non-retryable) publish failure stays
## LOUD (RA-21 preserved).
##
## Deterministic & hermetic construction: rather than racing two live
## publishers, we ADVANCE the manifest upstream OUT-OF-BAND (push an
## unrelated commit to the bare from a second clone) BEFORE the publisher
## pushes, so the publisher's local manifest branch is behind and its push
## is guaranteed non-fast-forward. The publisher is ``repro check
## --mode=pre-push`` (which writes + commits + publishes the lock via the
## RA-7/RA-21 path). We assert:
##   - the publisher exits 0 (no user-visible failure) — RA-29 retried;
##   - the manifest upstream tip ends with BOTH the out-of-band commit AND
##     this publisher's lock file present (neither overwritten/lost);
##   - a genuinely failing publish (unwritable upstream — the bare removed)
##     still fails LOUDLY with a non-zero exit (RA-21 preserved).
##
## Falsifiable: with NO non-ff retry the publisher's push stays rejected and
## ``repro check`` exits non-zero (RA-21 loud-on-failure) — the exit-0
## assertion fails; with a FORCE-push "retry" the out-of-band commit would
## be clobbered — the "out-of-band commit survives" assertion fails.
##
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

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
    " config user.name \"RA29 Tester\"")
  writeFile(workPath / "README.md", "RA29 concurrent-publish fixture\n")
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
    " config user.name \"RA29 Tester\"")

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

proc seedManifestGitLayer(gitBin, manifestsRoot, bare, projectToml: string;
                          branch = "main") =
  ## ``.repo/manifests`` is a real git checkout tracking a bare upstream so
  ## the publish path genuinely commits + pushes.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(bare))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(manifestsRoot))
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " config user.name \"RA29 Tester\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " add projects repos")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " commit -m \"seed manifest\"")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " remote add origin " & q(bare))
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " push -u origin " & branch)

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra29-concpub-" & slug & "-", "")
  result.reproBin = reproBinary()

  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libASha = seedGitOrigin(gitBin, result.libAOrigin,
    result.scratch / "seed-lib-a")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectTomlWith1Remote(fileUrl(result.libAOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.manifestsRoot = manifestsRoot
  result.manifestBare = result.scratch / "manifest.git"
  seedManifestGitLayer(gitBin, manifestsRoot, result.manifestBare,
    projectTomlWith1Remote(fileUrl(result.libAOrigin)))
  cloneInto(gitBin, result.libAOrigin, workspaceRoot / "lib-a")
  result.workspaceRoot = workspaceRoot
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

proc writeRefsFile(path: string; localSha: string) =
  let zeroSha = "0000000000000000000000000000000000000000"
  writeFile(path, "refs/heads/main " & localSha & " " &
    "refs/heads/main " & zeroSha & "\n")

proc invokeCheckPrePush(fx: Fixture; refsFile: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & (fx.workspaceRoot / "lib-a"),
    "--pushed-refs=" & refsFile,
    "--json",
  ]))

proc advanceUpstreamOutOfBand(gitBin: string; fx: Fixture;
                              marker: string): string =
  ## Simulate ANOTHER publisher advancing the manifest upstream first:
  ## clone the bare, add an unrelated commit, push it. The publisher's
  ## local manifest branch is now behind → its later push is non-ff.
  ## Returns the file path (manifest-relative) we created upstream so the
  ## caller can assert it survives.
  let sidecar = fx.scratch / "manifest-sidecar"
  cloneInto(gitBin, fx.manifestBare, sidecar)
  let relPath = "out-of-band-" & marker & ".txt"
  writeFile(sidecar / relPath, "another publisher was here: " & marker & "\n")
  discard requireGit(q(gitBin) & " -C " & q(sidecar) & " add " & q(relPath))
  discard requireGit(q(gitBin) & " -C " & q(sidecar) &
    " commit -m \"out-of-band publish " & marker & "\"")
  discard requireGit(q(gitBin) & " -C " & q(sidecar) & " push origin main")
  removeDir(sidecar)
  relPath

proc upstreamFiles(gitBin, bare: string): string =
  let ls = runCmd(q(gitBin) & " -C " & q(bare) &
    " ls-tree -r --name-only refs/heads/main")
  check ls.code == 0
  ls.output

suite "RA-29 — concurrent lock publishes retry without user-visible failure":

  test "t_concurrent_lock_publishes_retry_without_user_visible_failure":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # ---- Concurrent-publisher (non-ff) case: RETRIES + SUCCEEDS -------
      let fx = setupFixture(gitBin, "retry")
      defer: removeDir(fx.scratch)

      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, fx.libASha)

      # Advance the manifest upstream out-of-band so the publisher's local
      # manifest branch is behind → its publish push is non-fast-forward.
      let oobRel = advanceUpstreamOutOfBand(gitBin, fx, "first")

      let res = invokeCheckPrePush(fx, refsFile)
      checkpoint("retry output: " & res.output)
      # No user-visible failure: the non-ff was retried and the publish
      # succeeded. (Falsifiable: no retry → RA-21 loud-on-failure → non-zero.)
      check res.code == 0

      let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
        "check-report.json"
      check fileExists(reportPath)
      let report = parseFile(reportPath)
      check report["exitCode"].getInt() == 0
      # No lock-publish-failure recorded.
      for f in report["failures"]:
        check f["property"].getStr() != "lock-publish-failure"

      # BOTH survive on the upstream tip: the out-of-band commit's file AND
      # this publisher's lock file. (Falsifiable: a force-push "retry" would
      # clobber the out-of-band file.)
      let files = upstreamFiles(gitBin, fx.manifestBare)
      check files.contains(oobRel)
      check files.contains("locks/lib-a/lib-a/")

      # ---- Genuine failure still LOUD (RA-21 preserved) ----------------
      let fx2 = setupFixture(gitBin, "loud")
      defer: removeDir(fx2.scratch)
      let refsFile2 = fx2.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile2, fx2.libASha)
      # Remove the bare upstream entirely: the push can never succeed (this
      # is NOT a non-ff race — it is an unwritable/missing upstream), so the
      # retry must NOT mask it; the gate stays loud.
      removeDir(fx2.manifestBare)

      let loud = invokeCheckPrePush(fx2, refsFile2)
      checkpoint("loud output: " & loud.output)
      check loud.code != 0
      let report2 = parseFile(fx2.workspaceRoot / ".repro" / "workspace" /
        "check-report.json")
      check report2["exitCode"].getInt() != 0
      var sawPublishFailure = false
      for f in report2["failures"]:
        if f["property"].getStr() == "lock-publish-failure":
          sawPublishFailure = true
      check sawPublishFailure
