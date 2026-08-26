## DS-8 (CLI/develop.md §"Source axis") — **`--tier` and
## `--lock-store=<kind>:<location>`**.
##
##   > `--lock-store` is the flag that makes **CI** able to delegate. A CI
##   > checkout is shallow and has no VCS-private layer-5 config […] — that
##   > file is never pushed, by design — so the private route must be supplied
##   > explicitly. `--lock-store` supplies it in the same layering vocabulary
##   > the configuration plane uses, rather than a bespoke per-consumer
##   > mechanism.
##
## Why this is not cosmetic. The metacraft workspaces carry their team route in
## configuration **layer 5** (`<git-common-dir>/repro/config.toml`), which is
## deliberately never tracked and never pushed. A CI checkout therefore has NO
## route at all, so before this milestone `repro develop` in CI resolved the
## built-in public default alone and reported an EMPTY lock set — the private
## records were on disk and unreachable, with no flag able to name them.
##
## Asserts:
##   1. a workspace with NO routing configuration whatsoever (the CI shape)
##      resolves NOTHING: exit 1, "the workspace lock set … is EMPTY";
##   2. the same workspace, plus `--lock-store=git-checkout:<path>`, resolves
##      the private backend's records — the flag SUPPLIES the missing route;
##   3. the ad-hoc route is announced, not silent: the two-field form carries
##      no tier, and the run says which tier it just declared;
##   4. an UNREADABLE `--lock-store` is FATAL (exit 2) and never downgrades to
##      "just use what the configuration plane found" — including at the
##      `personal` tier, where a CONFIGURED route would only warn;
##   5. a malformed / unknown-kind `--lock-store` is refused at parse time;
##   6. repeatable, in INCREASING precedence: two `--lock-store`s at the same
##      tier, and the LAST one wins;
##   7. `--tier=<list>` restricts which tiers contribute: `--tier=public` on a
##      two-tier workspace yields only the committed lock's repos, and the
##      excluded backend is still NAMED in the inventory rather than vanishing.
##
## Fixture (built ``./build/bin/repro``, black-box, fully offline):
##
##   <scratch>/
##     origin-core.git / origin-team.git
##     private-manifests/   — a git checkout holding `locks/mix/team-lib/…`;
##                            the "private route" a CI checkout cannot see
##     other-manifests/     — a SECOND private store pinning team-lib to a
##                            different revision, for the precedence check
##     ws/                  — the CI-shaped workspace: manifests + committed
##                            lock, and NO `[locking]` table anywhere
##
## Falsifiability / pre-fix failure: against ``391a892a`` this test fails at
## (2) with
##
##   repro develop: error: unsupported `repro develop --all` argument:
##   --lock-store=git-checkout:<path>
##
## Mutation check: making an unreadable `--lock-store` fall back to the
## configuration plane's answer (instead of refusing) fails (4); appending the
## invocation routes in DECREASING precedence fails (6); dropping the
## ``tierContributes`` guard in the composer fails (7).
##
## Mocks: NONE. Real git repositories, real manifest checkouts, real lock
## records written by `repro workspace lock`, the real ``repro`` binary.
##
## Hermetic: fresh tempdir; every configuration layer is silenced, which is the
## POINT — the fixture must have no route except the one the flag supplies.
## Skip: ``git`` missing or ``repro`` unbuilt.

import std/[os, osproc, strutils, tempfiles, unittest]
from repro_test_support import fileUrl

const reproBinary = "./build/bin/" & addFileExt("repro", ExeExt)

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## `doAssert`, not `check` or `quit`: this is a HELPER, outside any
  ## `test` body. `unittest.check` there cannot see the `testStatusIMPL`
  ## the `test` template injects, so it prints "Check failed" and the case
  ## still reports `[OK]`; `quit 1` tears the process down mid-case, so
  ## `unittest` emits no `[FAILED]` marker and every later case in the file
  ## silently never runs. `doAssert` raises an `AssertionDefect`, which the
  ## `test` template's own `except Exception` catches and reports as a
  ## failure from any call depth.
  let res = run(command, cwd)
  doAssert res.code == 0, "command failed: " & command & "\nexit=" &
    $res.code & "\n" & res.output
  res.output

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"DS8 Tester\"")

proc commitIn(gitBin, repo, name: string): string =
  writeFile(repo / name, name & "\n")
  discard requireGit(q(gitBin) & " -C " & q(repo) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(repo) & " commit -m " & q(name))
  requireGit(q(gitBin) & " -C " & q(repo) & " rev-parse HEAD").strip()

proc seedGitOrigin(gitBin, originPath, workPath: string):
    tuple[first, second: string] =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  let a = commitIn(gitBin, workPath, "one.txt")
  let b = commitIn(gitBin, workPath, "two.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  (first: a, second: b)

proc projectToml(coreUrl, teamUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "[[remote]]\nname = \"team-origin\"\nfetch = \"" & teamUrl & "\"\n\n" &
  "includes = [\n  \"repos/core.toml\",\n  \"repos/team-lib.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

proc depInline(name, path, url, sha: string): string =
  "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & url & "\", ref = \"main\"" &
    ", revision = \"" & sha & "\", integrity = \"git-sha1:" & sha &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"\", groups = \"\" }"

proc committedLock(deps: string): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"x86_64-linux\"\n" &
  "optimal = true\n" &
  "inputs_digest = \"ds8-fixture\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [" & deps & "]\n"

proc lockRecord(teamSha: string): string =
  "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
  "[lock]\n" &
  "project = \"mix\"\n" &
  "created_at = \"2026-01-01T00:00:00Z\"\n" &
  "created_by = \"ds8 fixture\"\n\n" &
  "[[repo]]\nname = \"team-lib\"\npath = \"team-lib\"\n" &
  "remote = \"team-origin\"\nrevision = \"" & teamSha & "\"\n" &
  "branch = \"main\"\n"

proc rowFor(output, name: string): string =
  for line in output.splitLines():
    if line.startsWith(name & " ") or line == name: return line
  ""

suite "DS-8: --lock-store supplies the private route a CI checkout lacks":

  test "t_develop_lock_store_supplies_private_route":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds8-lockstore-", "")
      defer: removeDir(scratch)

      let coreOrigin = scratch / "origin-core.git"
      let teamOrigin = scratch / "origin-team.git"
      let coreShas = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")
      let teamShas = seedGitOrigin(gitBin, teamOrigin, scratch / "seed-team")
      check teamShas.first != teamShas.second

      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "mix.toml",
        projectToml(fileUrl(coreOrigin), fileUrl(teamOrigin)))
      writeFile(manifestsRoot / "repos" / "core.toml",
        repoFragment("core", "core-origin"))
      writeFile(manifestsRoot / "repos" / "team-lib.toml",
        repoFragment("team-lib", "team-origin"))

      discard requireGit(q(gitBin) & " clone " & q(fileUrl(coreOrigin)) &
        " " & q(ws / "core"))
      discard requireGit(q(gitBin) & " clone " & q(fileUrl(teamOrigin)) &
        " " & q(ws / "team-lib"))
      createDir(ws / ".repro")
      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\n" &
        "project = \"mix\"\n" &
        "branch = \"main\"\n")
      # The PUBLIC tier: the committed lock, naming ONLY `core`.
      writeFile(ws / "repro.lock",
        committedLock(depInline("core", "core", fileUrl(coreOrigin),
          coreShas.second)))
      # NO `[locking]` table anywhere — the CI shape.
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n")

      # The PRIVATE stores, off to the side — exactly what `$RUNNER_TEMP` would
      # hold in CI. Two of them, pinning team-lib differently, for (6).
      proc makePrivateStore(dir, teamSha: string) =
        initGitRepo(gitBin, dir)
        createDir(dir / "locks" / "mix" / "team-lib")
        writeFile(dir / "locks" / "mix" / "team-lib" / (teamSha & ".toml"),
          lockRecord(teamSha))
        discard requireGit(q(gitBin) & " -C " & q(dir) & " add -A")
        discard requireGit(q(gitBin) & " -C " & q(dir) & " commit -m locks")
      let privateStore = scratch / "private-manifests"
      let otherStore = scratch / "other-manifests"
      makePrivateStore(privateStore, teamShas.first)
      makePrivateStore(otherStore, teamShas.second)

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      proc list(flags: string): tuple[code: int; output: string] =
        run(repro & " develop --list --tool-provisioning=path " & flags,
          cwd = ws)

      # ---- (1) no route at all: only the public tier resolves. -----------
      let bare = list("")
      if bare.code != 0:
        checkpoint("develop --list output: " & bare.output)
      check bare.code == 0
      check rowFor(bare.output, "core").len > 0
      check rowFor(bare.output, "team-lib").len == 0
      # …and with the committed lock removed too, the union is EMPTY and the
      # failure names every backend consulted.
      moveFile(ws / "repro.lock", scratch / "parked-repro.lock")
      let empty = list("")
      check empty.code == 1
      check "is EMPTY" in empty.output
      moveFile(scratch / "parked-repro.lock", ws / "repro.lock")

      # ---- (2)+(3) --lock-store SUPPLIES the private route. --------------
      let supplied = list("--lock-store=git-checkout:" & q(privateStore))
      if supplied.code != 0:
        checkpoint("develop --list output: " & supplied.output)
      check supplied.code == 0
      let teamRow = rowFor(supplied.output, "team-lib")
      check teamRow.len > 0
      check teamShas.first in teamRow
      check "team" in teamRow
      check "git-checkout" in teamRow
      # The backend inventory labels it as declared by the flag.
      check ("backend: team tier / git-checkout at " & privateStore) in
        supplied.output
      check "[--lock-store]" in supplied.output
      # (3) — the two-field form's tier is ANNOUNCED, never silent.
      check ("declares a team-tier git-checkout backend at " & privateStore) in
        supplied.output
      check "--lock-store=<tier>:git-checkout:" in supplied.output
      # The public tier is untouched: `core` still comes from the committed
      # lock. The flag composes with the configuration plane, it does not
      # replace it.
      check "committed-lock" in rowFor(supplied.output, "core")

      # ---- (4) an UNREADABLE --lock-store is FATAL. ----------------------
      let missing = scratch / "not-cloned-manifests"
      let unreadable = list("--lock-store=git-checkout:" & q(missing))
      check unreadable.code == 2
      check "could not be read" in unreadable.output
      check missing in unreadable.output
      check "declared by --lock-store=git-checkout:" in unreadable.output
      # It must NOT have quietly answered with the configuration plane's set.
      check rowFor(unreadable.output, "core").len == 0
      # …and the same at the `personal` tier, where a CONFIGURED route would
      # only warn-and-continue: an explicit per-invocation assertion that THIS
      # backend is the route can never degrade to "use something else".
      let unreadablePersonal = list("--lock-store=personal:git-checkout:" &
        q(missing))
      check unreadablePersonal.code == 2
      check "could not be read" in unreadablePersonal.output
      check "WARNING" notin unreadablePersonal.output

      # ---- (5) malformed / unknown kind is refused at parse time. --------
      let badKind = list("--lock-store=git-checkut:" & q(privateStore))
      check badKind.code != 0
      check "unknown backend kind" in badKind.output
      let badShape = list("--lock-store=git-checkout")
      check badShape.code != 0
      check "malformed" in badShape.output

      # ---- (6) repeatable, in INCREASING precedence: the LAST wins. ------
      let firstThenOther = list(
        "--lock-store=git-checkout:" & q(privateStore) &
        " --lock-store=git-checkout:" & q(otherStore))
      if firstThenOther.code != 0:
        checkpoint("develop --list output: " & firstThenOther.output)
      check firstThenOther.code == 0
      check teamShas.second in rowFor(firstThenOther.output, "team-lib")
      let otherThenFirst = list(
        "--lock-store=git-checkout:" & q(otherStore) &
        " --lock-store=git-checkout:" & q(privateStore))
      check otherThenFirst.code == 0
      check teamShas.first in rowFor(otherThenFirst.output, "team-lib")

      # ---- (7) --tier restricts which tiers contribute. ------------------
      let publicOnly = list("--lock-store=git-checkout:" & q(privateStore) &
        " --tier=public")
      check publicOnly.code == 0
      check rowFor(publicOnly.output, "core").len > 0
      check rowFor(publicOnly.output, "team-lib").len == 0
      # The excluded backend is still NAMED — a narrowed answer is never
      # indistinguishable from a complete one.
      check "excluded by --tier" in publicOnly.output
      let teamOnly = list("--lock-store=git-checkout:" & q(privateStore) &
        " --tier=team")
      check teamOnly.code == 0
      check rowFor(teamOnly.output, "team-lib").len > 0
      check rowFor(teamOnly.output, "core").len == 0
      check "excluded by --tier" in teamOnly.output
      # An unknown tier name is refused.
      let badTier = list("--tier=teem")
      check badTier.code != 0
      check "names no locking tier" in badTier.output
