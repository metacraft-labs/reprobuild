## `repro develop --list|--all` run from INSIDE a participating repo resolves
## THAT repo's own lock set, not the workspace's.
##
## Regression: with `codetracer` cloned inside a workspace root,
## `repro develop --all` resolved the root's lock set (every participating
## repo's self-record) instead of codetracer's own pinned siblings. The
## develop set of a repo `R` is `R`'s own dependencies per `R`'s committed
## lock; which workspace root `R` sits under must not change which lock is
## read.
##
## Fixture: a workspace with three participating repos. `app` is the consumer:
## its lock carries its self entry plus ONE dependency, `liba`. `libb` is a
## sibling `app` does not depend on and carries its own lock. Run with the
## working directory `<ws>/app` and no `--workspace-root`:
##
##   1. the rows are exactly `liba` (a repo `app` does not depend on, `libb`,
##      and `app` itself are not in `app`'s develop set);
##   2. `liba` resolves at the revision `app`'s lock pins, placed in the
##      workspace (`<ws>/liba`);
##   3. a notice names the repo whose lock was used ("develop set of app").
##
## Mocks: NONE. Real git repositories, real lock documents, the real `repro`.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## `doAssert`, not `check`: this helper runs outside any `test` body, where
  ## `unittest.check` cannot see the injected `testStatusIMPL` and would report
  ## `[OK]` after printing "Check failed".
  let res = runCmd(command, cwd)
  doAssert res.code == 0, "command failed: " & command & "\nexit=" &
    $res.code & "\n" & res.output
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  createDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Root Lock Tester\"")
  # The file BODY carries the work path, so two origins seeded inside the same
  # second cannot produce the same tree and therefore cannot produce the same
  # sha — which would make every "these revisions differ" assertion vacuous.
  writeFile(workPath / "seed.txt", "seed\n" & workPath & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add seed.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " remote add origin " &
    q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc advanceOrigin(gitBin, workPath: string): string =
  writeFile(workPath / "later.txt", "later\n" & workPath & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add later.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m later")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"Root Lock Tester\"")

proc depInline(name, path, url, sha: string): string =
  "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & url & "\"" &
    ", revision = \"" & sha & "\", integrity = \"git-sha1:" & sha &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"\", tags = \"\" }"

proc lockDoc(deps: string): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"x86_64-linux\"\n" &
  "optimal = true\n" &
  "inputs_digest = \"ds1-root-outranks-per-repo\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [" & deps & "]\n"

proc projectToml(libaUrl, libbUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\nname = \"ws\"\n\n" &
  "[[remote]]\nname = \"liba-origin\"\nfetch = \"" & libaUrl & "\"\n\n" &
  "[[remote]]\nname = \"libb-origin\"\nfetch = \"" & libbUrl & "\"\n\n" &
  "includes = [\n  \"repos/liba.toml\",\n  \"repos/libb.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "mainline = \"main\"\n"

type ListedRow = object
  found: bool
  revision, path, state, tier, backend: string

proc rowFor(report: JsonNode; name: string): ListedRow =
  ## The `--json` row for `name`, or `found = false`. `--json` is read rather
  ## than the text table because every assertion below is about an exact field
  ## value, and a substring test against a padded table can be satisfied by the
  ## wrong column.
  for r in report["repos"]:
    if r["name"].getStr() == name:
      return ListedRow(found: true, revision: r["revision"].getStr(),
        path: r["path"].getStr(), state: r["state"].getStr(),
        tier: r["tier"].getStr(), backend: r["backend"].getStr())


proc repoLockDoc(deps: string): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n[lock]\n" &
  "platform = \"x86_64-linux\"\noptimal = true\n" &
  "inputs_digest = \"develop-inside-a-repo\"\nvariants = []\npackages = []\n" &
  "deps = [" & deps & "]\n"

proc projectTomlThree(urls: array[3, string]): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n[project]\nname = \"ws\"\n\n" &
  "[[remote]]\nname = \"app-origin\"\nfetch = \"" & urls[0] & "\"\n\n" &
  "[[remote]]\nname = \"liba-origin\"\nfetch = \"" & urls[1] & "\"\n\n" &
  "[[remote]]\nname = \"libb-origin\"\nfetch = \"" & urls[2] & "\"\n\n" &
  "includes = [\n  \"repos/app.toml\",\n  \"repos/liba.toml\",\n  \"repos/libb.toml\",\n]\n"

suite "repro develop run inside a participating repo uses that repo's lock set":
  test "t_develop_inside_a_repo_resolves_that_repos_own_lock_set":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case builds real repositories")
    else:
      let scratch = createTempDir("develop-inside-repo-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      var origins: array[3, string]
      var shas: array[3, string]
      let names = ["app", "liba", "libb"]
      for i, n in names:
        origins[i] = scratch / ("origin-" & n & ".git")
        shas[i] = seedOrigin(gitBin, origins[i], scratch / ("seed-" & n))
      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "ws.toml",
        projectTomlThree([fileUrl(origins[0]), fileUrl(origins[1]),
          fileUrl(origins[2])]))
      for i, n in names:
        writeFile(manifestsRoot / "repos" / (n & ".toml"),
          repoFragment(n, n & "-origin"))
        cloneInto(gitBin, origins[i], ws / n)
      writeWorkspaceBranch(ws, project = "ws", branch = "main")
      # `app` depends on liba only. `libb` has its own lock but is no
      # dependency of app.
      writeFile(ws / "app" / "repro.lock", repoLockDoc(
        depInline("app", ".", fileUrl(origins[0]), shas[0]) & ", " &
        depInline("liba", "liba", fileUrl(origins[1]), shas[1])))
      # liba's OWN self-record names a LATER revision than app pins. app's
      # develop set must carry app's pin: a sibling's self-record cannot
      # outvote the consumer's lock.
      let libaLater = advanceOrigin(gitBin, scratch / "seed-liba")
      doAssert libaLater != shas[1]
      writeFile(ws / "liba" / "repro.lock", repoLockDoc(
        depInline("liba", ".", fileUrl(origins[1]), libaLater)))
      writeFile(ws / "libb" / "repro.lock", repoLockDoc(
        depInline("libb", ".", fileUrl(origins[2]), shas[2])))

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      let listed = runCmd(q(reproBin) &
        " develop --list --json --tool-provisioning=path", ws / "app")
      if listed.code != 0:
        checkpoint("develop --list --json output: " & listed.output)
      check listed.code == 0
      var report: JsonNode = nil
      try:
        report = parseJson(listed.output)
      except CatchableError as err:
        checkpoint("unparseable --json output: " & err.msg & "\n" &
          listed.output)
      check not report.isNil
      if report != nil:
        var rowNames: seq[string]
        for r in report["repos"]: rowNames.add(r["name"].getStr())
        check rowNames == @["liba"]
        let liba = rowFor(report, "liba")
        check liba.found
        if liba.found:
          check liba.revision == shas[1]
          check liba.path == os.normalizedPath(ws / "liba")
        var named = false
        for n in report["notices"]:
          if "develop set of app" in n.getStr(): named = true
        check named
