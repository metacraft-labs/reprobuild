## L1 REPRO-DEVELOP-ALL ``--reset`` — an already-present sibling checkout that
## has DRIFTED off the locked revision is force-reconciled back to the lock when
## ``--reset`` is passed, instead of being refused. Without ``--reset`` the same
## drift is refused (the fleet-safe default is preserved).
##
## Spec: reprobuild-specs/Reprobuild-Lock-Driven-Provisioning-And-Publish-
## Scope.milestones.org §L1; CLI/develop.md. This mirrors
## t_develop_all_clones_deps_at_locked_revisions.nim but exercises the CI
## reconcile path: a prior clone step (e.g. clone-siblings at a `=dev` tip)
## placed the sibling at a revision that differs from the committed lock.
##
## Asserts:
##   1. With a sibling pre-placed at the branch TIP (!= locked SHA), plain
##      ``repro develop --all`` REFUSES (exit 1, diagnostic names --reset).
##   2. ``repro develop --all --reset`` reconciles the SAME drifted checkout:
##      exit 0, reports it "reset", and its HEAD is now the EXACT locked SHA.
##   3. The override file records the reconciled node -> local path.
##
## Falsifiability: if --reset did not reset, (2)'s exact-SHA assertion fails; if
## the default silently overwrote, (1)'s exit-1 fails.
##
## Hermetic + offline: every git repo lives in a fresh tempdir; nothing touches
## $HOME. Skip rule: ``git`` missing on PATH, or repro unbuilt.

import std/[os, osproc, strutils, unittest]

const reproBinary = "./build/bin/" & addFileExt("repro", ExeExt)

const depRecipe = """
import repro_project_dsl

package PKG:
  build:
    discard aggregate("PKG-agg", actions = @[])
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc initPublishedRepo(gitBin, scratch, name: string):
    tuple[origin, work: string] =
  let origin = scratch / (name & ".git")
  let work = scratch / name
  check git(gitBin, "", "init --bare -b main " & q(origin)).code == 0
  check run(q(gitBin) & " clone " & q(origin) & " " & q(work)).code == 0
  check git(gitBin, work, "config user.email t@example.invalid").code == 0
  check git(gitBin, work, "config user.name Tester").code == 0
  (origin: origin, work: work)

proc depInline(name, path, url, sha, depends: string): string =
  "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & url & "\", ref = \"main\"" &
    ", revision = \"" & sha & "\", integrity = \"" &
    (if sha.len > 0: "git-sha1:" & sha else: "") &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"" & depends & "\", groups = \"\" }"

suite "L1: repro develop --all --reset reconciles a drifted sibling":

  test "t_develop_all_reset_reconciles_drifted_sibling":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = getTempDir() / "l1-develop-reset-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- One published dependency repo with a first (locked) commit and a
      #      SECOND commit that advances the branch tip past the lock. ----
      let (libOrigin, libWork) = initPublishedRepo(gitBin, scratch, "liba")
      writeFile(libWork / "repro.nim", depRecipe.replace("PKG", "liba"))
      check git(gitBin, libWork, "add repro.nim").code == 0
      check git(gitBin, libWork, "commit -m liba").code == 0
      check git(gitBin, libWork, "push origin main").code == 0
      let lockedSha = git(gitBin, libWork, "rev-parse HEAD").output.strip()
      check lockedSha.len == 40
      # Advance the branch tip PAST the locked SHA.
      writeFile(libWork / "moved.txt", "past the lock\n")
      check git(gitBin, libWork, "add moved.txt").code == 0
      check git(gitBin, libWork, "commit -m move").code == 0
      check git(gitBin, libWork, "push origin main").code == 0
      let tipSha = git(gitBin, libWork, "rev-parse HEAD").output.strip()
      check tipSha != lockedSha

      # ---- The workspace repo with a committed lock pinning liba at lockedSha.
      let host = initPublishedRepo(gitBin, scratch, "app")
      let repo = host.work
      writeFile(repo / "README.md", "reset fixture\n")
      check git(gitBin, repo, "add README.md").code == 0
      check git(gitBin, repo, "commit -m seed").code == 0
      let appSha = git(gitBin, repo, "rev-parse HEAD").output.strip()
      let rootDep = depInline("app", ".", host.origin, "", "liba").replace(
        "revision = \"\"", "revision = \"" & appSha & "\"")
      let lockBody = "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
        "[lock]\n" &
        "platform = \"x86_64-linux\"\n" &
        "optimal = true\n" &
        "inputs_digest = \"reset-fixture\"\n" &
        "variants = []\n" &
        "packages = []\n" &
        "deps = [" & rootDep & ", " &
        depInline("liba", "liba", libOrigin, lockedSha, "") & "]\n"
      writeFile(repo / "repro.lock", lockBody)

      let deps = scratch / "deps"
      createDir(deps)

      # ---- Pre-place liba at the BRANCH TIP (the drift a CI pre-clone leaves).
      check run(q(gitBin) & " clone " & q(libOrigin) & " " &
        q(deps / "liba")).code == 0
      check git(gitBin, deps / "liba", "rev-parse HEAD").output.strip() == tipSha

      # ---- (1) Default: refuse-on-drift; diagnostic mentions --reset. ----
      let refused = run(repro & " develop --all --into=" & q(deps) &
        " --tool-provisioning=path", cwd = repo)
      check refused.code == 1
      check "refused" in refused.output
      check "--reset" in refused.output
      # The checkout was NOT touched.
      check git(gitBin, deps / "liba", "rev-parse HEAD").output.strip() == tipSha

      # ---- (2) --reset reconciles the SAME drifted checkout to the lock. ----
      let reset = run(repro & " develop --all --reset --into=" & q(deps) &
        " --tool-provisioning=path", cwd = repo)
      check reset.code == 0
      check "reset" in reset.output
      check git(gitBin, deps / "liba", "rev-parse HEAD").output.strip() ==
        lockedSha

      # ---- (3) the override file records the reconciled node -> local path. ----
      let ovPath = repo / ".repro" / "develop-overrides.toml"
      check fileExists(ovPath)
      let ov = readFile(ovPath)
      check "package = \"liba\"" in ov
      check ("local_path = \"" & (deps / "liba") & "\"") in ov
