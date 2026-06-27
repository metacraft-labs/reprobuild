## Workspace-Manifest-Optional MO-10 — status / health / add / remove resolve
## through the SHARED ``resolveWorkspaceProjectShared`` ladder.
##
## MO-9 collapsed sync / pull / check onto one membership-resolution seam
## (``resolveWorkspaceProjectShared``) that, besides the manifest dispatch,
## also resolves a committed-lock-only workspace (no ``.repo/manifests`` and no
## ``.repo/workspace.toml``) from the committed ``repro.lock``. MO-10 finishes
## the unification by routing the four remaining non-lock-handling resolvers —
## ``repro workspace status`` / ``repro health`` / ``repro add`` /
## ``repro remove`` — onto the SAME seam.
##
## Before MO-10 each of those four had its own dispatch ladder that RAISED on a
## committed-lock-only workspace ("requires `.repo/workspace.toml` or a
## <project> argument" / "no project named ..."). This suite drives all four
## against a committed-lock-only workspace and asserts each one RESOLVES the
## committed-lock-derived participating set instead of raising — i.e. it now
## behaves identically to the lock-handling commands.
##
## Falsifiability: revert ANY ONE of the four ladders to a copy that raises on a
## committed-lock-only workspace and the corresponding assertion below fails:
##   - status would exit non-zero with the "requires ... <project>" error
##     instead of exit 0 + a resolved project;
##   - health's ``manifest`` check would flip to ``hsFail`` / "manifest
##     unresolved" instead of ``hsOk`` / "resolved";
##   - add would print "no project named ..." (non-zero) instead of the
##     dry-run "would record ... dependency of project '<name>'";
##   - remove would print the "requires `.repo/workspace.toml`" resolution
##     error instead of reaching the "is declared in project '<name>'" stage.
##
## Hermetic: every git repo lives in a fresh tempdir; nothing touches ``$HOME``
## or any shared cache. Skip rule: ``git`` missing on PATH or no built binary.

import std/[json, os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

const solverInputs = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo: string; rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc manifestCheckStatus(healthJson: string): tuple[status, detail: string] =
  ## Extract the ``manifest`` check's status + detail from ``repro health
  ## --json`` output. Returns ("", "") when the check is absent.
  let node = parseJson(healthJson)
  for c in node["checks"]:
    if c["name"].getStr == "manifest":
      return (c["status"].getStr, c["detail"].getStr)
  ("", "")

suite "MO-10: status/health/add/remove use the unified resolver":

  test "t_status_health_add_remove_use_unified_resolver":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = getTempDir() / "mo10-unified-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- A committed-lock-only workspace: a single git repo carrying a
      # committed ``repro.lock`` but NO ``.repo/`` of any kind. This is exactly
      # the dispatch case the four ladders used to raise on. ----
      let origin = scratch / "origin.git"
      let repo = scratch / "work"
      check git(gitBin, "", "init --bare -b main " & q(origin)).code == 0
      let seed = scratch / "seed"
      check git(gitBin, "", "init -b main " & q(seed)).code == 0
      check git(gitBin, seed, "config user.email t@example.invalid").code == 0
      check git(gitBin, seed, "config user.name Tester").code == 0
      writeFile(seed / "README.md", "mo10 fixture\n")
      check git(gitBin, seed, "add README.md").code == 0
      check git(gitBin, seed, "commit -m seed").code == 0
      check git(gitBin, seed, "remote add origin " & q(origin)).code == 0
      check git(gitBin, seed, "push origin main").code == 0
      check run(q(gitBin) & " clone " & q(origin) & " " & q(repo)).code == 0
      check git(gitBin, repo, "config user.email t@example.invalid").code == 0
      check git(gitBin, repo, "config user.name Tester").code == 0

      writeFile(repo / "repro.solver", solverInputs)
      let refresh = run(reproBinary & " lock refresh " & q(repo))
      check refresh.code == 0
      check fileExists(repo / "repro.lock")
      check git(gitBin, repo, "add repro.solver repro.lock").code == 0
      check git(gitBin, repo, "commit -m lock").code == 0
      check git(gitBin, repo, "push origin main").code == 0

      # Sanity: genuinely manifest-less.
      check not dirExists(repo / ".repo")

      # ---- (1) `repro workspace status` resolves via the shared ladder. ----
      let status = run(reproBinary & " workspace status --workspace-root=" &
        repo & " --json")
      check status.code == 0
      check "requires" notin status.output
      check "no project or variant" notin status.output
      let statusJson = parseJson(status.output)
      # The committed-lock-derived project was resolved (non-empty name) and
      # carries the root repo at path ".".
      check statusJson["project"].getStr.len > 0
      var sawRootPath = false
      for entry in statusJson["repos"]:
        if entry["path"].getStr == ".":
          sawRootPath = true
      check sawRootPath

      # ---- (2) `repro health` resolves the manifest layer via the shared
      # ladder — the ``manifest`` check is OK, not "unresolved". ----
      let health = run(reproBinary & " health --workspace-root=" & repo &
        " --json")
      check "manifest unresolved" notin health.output
      let (mStatus, mDetail) = manifestCheckStatus(health.output)
      check mStatus == "ok"
      check "resolved" in mDetail

      # ---- (3) `repro add --binary --dry-run` resolves via the shared ladder
      # and names the committed-lock-derived project (no checkout, no mutation
      # in dry-run). ----
      let add = run(reproBinary & " add added-dep" &
        " --remote=https://example.invalid/added-dep.git --binary --dry-run" &
        " --workspace-root=" & repo)
      check add.code == 0
      check "would record" in add.output
      check "no project named" notin add.output
      check "requires" notin add.output

      # ---- (4) `repro remove` reaches the target-matching stage (resolution
      # succeeded) rather than raising the missing-workspace resolution error.
      # A non-existent target yields the "is declared in project '<name>'"
      # diagnostic that only prints AFTER the project resolved. ----
      let remove = run(reproBinary & " remove no-such-repo --workspace-root=" &
        repo)
      check "is declared in project" in remove.output
      check "requires `.repo/workspace.toml`" notin remove.output
      check "no project or variant" notin remove.output
