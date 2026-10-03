## D4 — the post-commit hook's report and log belong in the DISPOSABLE
## ``.repro/build/`` tree, not beside the ``.repro/workspace.toml`` marker.
##
## `Retired-Names.md` retired the spelling this hook was still using:
##
##   `<workspace>/.repro/workspace/<verb>-report.json`
##     -> `<workspace>/.repro/build/reports/<verb>-report.json`
##   "A report is derived output, so it belongs in the disposable
##    `.repro/build/` tree rather than beside the `.repro/workspace.toml`
##    marker."
##
## `CLI/README.md` states the same convention for every other verb's
## `--write-report` artifact and spells out the reason: `.repro/build/` is
## disposable by definition, "which is true of a report and false of the
## `.repro/workspace.toml` marker beside it".
##
## WHY THIS IS NOT TIDINESS. Measured in the field: a post-commit hook that
## correctly decided it had nothing to do still dropped
## `.repro/workspace/post-commit-report.json` and
## `.repro/workspace/post-commit-lock.log` into a GIT WORKING TREE. The lock
## publisher's dirty-outside-`locks/` guard (`gitPorcelainEntries` +
## `pathIsUnderLocks`) then refused — "manifest repo is dirty outside
## locks/" — and refused PERMANENTLY, because the publisher's own next commit
## fires the same hook, which regenerates the same two files. That wedged lock
## publication for every repo in the workspace. So a no-op hook turned into a
## workspace-wide outage purely through WHERE it filed its diagnostic.
##
## THE FIXTURE IS THE FIELD TOPOLOGY. The workspace root here is itself a git
## checkout that TRACKS `.repro/workspace.toml` — the native-root layout, where
## the manifest/lock-store repo IS the workspace root and the marker is a
## committed file. Its `.gitignore` names the two disposable subtrees under
## `.repro/` (`build/`, `manifests/`) and nothing else. That ignore set is not
## a convenience chosen to make this test pass; it is exactly the distinction
## the spec's own rationale draws: the build tree is thrown away, the marker
## beside it is kept. A report filed next to the kept marker is therefore
## untracked content in a tracked directory — dirty — while the same report
## filed in the build tree is invisible to git.
##
## ASSERTIONS, each falsifiable against the retired spelling:
##   1. The trap is real — `.repro/workspace.toml` is TRACKED in the workspace
##      root's git checkout and the tree is clean before the commit. Without
##      this the porcelain check below would prove nothing.
##   2. A real `git commit` in a participating repo fires the real managed
##      hooks and succeeds (post-commit is non-blocking either way).
##   3. The report lands at
##      `<root>/.repro/build/reports/post-commit-report.json` and parses, and
##      the log at `<root>/.repro/build/reports/post-commit-lock.log` is
##      non-empty. The diagnostic is MOVED, not dropped: the stand-down and
##      no-workspace branches carry a comment recording that silence there
##      "turned this branch into a black hole in the field", so a fix that
##      stopped writing would be a worse defect than the one it replaces.
##   4. NOTHING is filed under the retired `<root>/.repro/workspace/` —
##      none of the three basenames the post-commit path writes
##      (`post-commit-report.json`, `post-commit-lock.log` and the M11
##      `lock-report.json` the wrapper files "so a manual invocation matches
##      the operator-facing surface"), and no such directory at all. That
##      third one was the same defect in the same function: the operator-facing
##      `repro workspace lock` writes its `lock-report.json` through
##      `reportDestination`, so the two surfaces the comment claimed to match
##      were writing to two different files.
##   5. THE HARM: `git -C <root> status --porcelain` is empty after the hook
##      ran. Under the retired spelling it reports the untracked report, log
##      and `lock-report.json` beside the marker — which is precisely the
##      input the lock publisher's dirty guard refuses on.
##
## No mocks: real `git init`/`clone`/`commit`, the real `repro hooks ensure
## --vcs` installer, the real managed hook bodies, and the real `repro hooks
## dispatch post-commit` entry point. Hermetic: one `createTempDir`, a local
## `git init --bare` upstream, no network. Skip rule: `git` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

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
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc configIdentity(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"PostCommit Tester\"")

suite "post-commit files its report in the disposable build tree":

  test "t_post_commit_report_lands_in_the_disposable_build_tree":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — this case builds real repositories, fires " &
        "the real managed post-commit hook and reads `git status`, none of " &
        "which has a substitute that would still prove the claim")
    else:
      let scratch = createTempDir("repro-postcommit-report-home-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # ---- upstream + seed commit for the participating repo ------------
      let origin = scratch / "origin.git"
      let seedPath = scratch / "seed"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      discard requireGit(q(gitBin) & " init -b main " & q(seedPath))
      configIdentity(gitBin, seedPath)
      writeFile(seedPath / "README.md", "post-commit report fixture\n")
      discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(seedPath) & " commit -m base")
      discard requireGit(q(gitBin) & " -C " & q(seedPath) &
        " remote add origin " & q(origin))
      discard requireGit(q(gitBin) & " -C " & q(seedPath) & " push origin main")
      let originUrl = fileUrl(origin)

      # ---- the workspace root, which is ITSELF a git checkout -----------
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")
      writeFile(workspaceRoot / "projects" / "lib-a.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"lib-a\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" &
          originUrl & "\"\n\n" &
        "includes = [\n  \"repos/lib-a.toml\",\n]\n")
      writeFile(workspaceRoot / "repos" / "lib-a.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"lib-a\"\npath = \"lib-a\"\n" &
        "remote = \"lib-a-origin\"\nrevision = \"main\"\n")
      writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")
      check fileExists(workspaceRoot / ".repro" / "workspace.toml")

      # The two DISPOSABLE subtrees under `.repro/` are ignored; the marker
      # beside them is not. This is the spec's own distinction, written out as
      # an ignore file: `.repro/build/` is derived output, `.repro/manifests/`
      # is a nested checkout, and `.repro/workspace.toml` is metadata that is
      # kept and committed.
      writeFile(workspaceRoot / ".gitignore",
        "/lib-a/\n/.repro/build/\n/.repro/manifests/\n")

      # A manifest-backed lock route must be DECLARED, not inferred, so the
      # manifest layer is a real git checkout of its own.
      let lockStore = workspaceRoot / ".repro" / "manifests"
      createDir(lockStore)
      discard requireGit(q(gitBin) & " init -b main " & q(lockStore))
      configIdentity(gitBin, lockStore)
      writeFile(lockStore / ".gitkeep", "")
      discard requireGit(q(gitBin) & " -C " & q(lockStore) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(lockStore) &
        " commit -m \"seed lock store\"")

      # (1) THE TRAP. The workspace root is a git checkout that TRACKS
      # `.repro/workspace.toml`, and it is CLEAN. Anything the hook drops
      # beside that marker is therefore visible to `git status`.
      discard requireGit(q(gitBin) & " init -b main " & q(workspaceRoot))
      configIdentity(gitBin, workspaceRoot)
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
        " add .gitignore projects repos " & q(".repro/workspace.toml"))
      discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
        " commit -m \"seed workspace manifests\"")
      let tracked = requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
        " ls-files -- .repro").strip()
      check tracked == ".repro/workspace.toml"
      let cleanBefore = requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
        " status --porcelain --untracked-files=all")
      checkpoint("workspace status before the commit: " & cleanBefore)
      check cleanBefore.strip().len == 0

      # ---- the participating repo ---------------------------------------
      let repoPath = workspaceRoot / "lib-a"
      discard requireGit(q(gitBin) & " clone --branch main " & q(originUrl) &
        " " & q(repoPath))
      configIdentity(gitBin, repoPath)

      # Declare the TEAM route explicitly. Not decoration: without it the
      # locking layer emits its one-time "no team route declared" guidance and
      # throttles it with `.repro/workspace/legacy-manifest-migration.warned`.
      # That sentinel is deliberately NOT moved by this change — it is read
      # back to decide whether to warn, which by `CLI/README.md`'s own rule
      # ("No command may read a previous report back to decide what to do")
      # makes it durable state rather than a report, and moving it into a
      # disposable tree would make a `clean` re-emit a migration warning for a
      # workspace that has already been migrated. A fully configured workspace
      # never writes it, and this fixture is one.
      let adopted = runShell(shellCommand(@[
        reproBin, "locking", "adopt-manifest",
        "--workspace-root=" & workspaceRoot]))
      checkpoint("locking adopt-manifest output: " & adopted.output)
      check adopted.code == 0

      let ensured = runShell(shellCommand(@[
        reproBin, "hooks", "ensure", "--vcs",
        "--workspace-root=" & workspaceRoot]))
      checkpoint("hooks ensure output: " & ensured.output)
      check ensured.code == 0
      check fileExists(repoPath / ".git" / "hooks" / "post-commit")

      # ---- (2) a REAL commit fires the REAL managed hook ----------------
      writeFile(repoPath / "feature.txt", "new work\n")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add feature.txt")
      let committed = runShell(shellCommand(@[
        gitBin, "-C", repoPath, "commit", "-m", "lib-a feature"],
        @[(name: "REPROBUILD_REPRO", value: reproBin)]))
      checkpoint("git commit output: " & committed.output)
      check committed.code == 0

      # ---- (3) the report and log land in the CONVENTIONAL place --------
      let conventionalDir = workspaceRoot / ".repro" / "build" / "reports"
      let reportPath = conventionalDir / "post-commit-report.json"
      check fileExists(reportPath)
      # Guarded so a missing report does not abort the case: assertion (5)
      # below is the one that names the field harm, and it must be reported
      # even when this one has already failed.
      if fileExists(reportPath):
        let report = parseFile(reportPath)
        checkpoint("post-commit report: " & $report)
        check report["workspaceRoot"].getStr() == workspaceRoot
      let logPath = conventionalDir / "post-commit-lock.log"
      check fileExists(logPath)
      if fileExists(logPath):
        check readFile(logPath).strip().len > 0

      # ---- (4) NOTHING under the retired spelling ----------------------
      let retiredDir = workspaceRoot / ".repro" / "workspace"
      check not fileExists(retiredDir / "post-commit-report.json")
      check not fileExists(retiredDir / "post-commit-lock.log")
      check not fileExists(retiredDir / "pre-commit-lock.log")
      check not fileExists(retiredDir / "lock-report.json")
      check not dirExists(retiredDir)

      # ---- (5) THE HARM: the clean tree stayed clean -------------------
      # This is the exact question the lock publisher's dirty-outside-`locks/`
      # guard asks of the manifest repo before it will publish anything.
      let statusAfter = requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
        " status --porcelain --untracked-files=all")
      checkpoint("workspace status after the commit: " & statusAfter)
      check statusAfter.strip().len == 0
