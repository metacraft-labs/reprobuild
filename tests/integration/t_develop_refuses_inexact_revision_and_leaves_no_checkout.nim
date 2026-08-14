## DS-5 (CLI/develop.md §"A revision comes from a lock record or not at all")
## — the exact-revision rule is a RULE, not a heuristic, and a failed placement
## leaves NO checkout behind.
##
##   > **Anything that is not exactly 40 lowercase hex is refused**, including a
##   > 41-hex string, an abbreviated SHA, and an all-hex branch name. An
##   > abbreviation is not an exact pin, and a hex-looking branch name is the
##   > `revision = "main"` hazard wearing a costume — the same class of defect
##   > that let a CI resolver build a moving branch tip.
##
## The composer used to ask ``looksLikeSha``, whose contract is "is this more
## likely a SHA than a branch name?" — 7..64 hex characters. That admits an
## abbreviation, an all-hex branch name, and a 41-hex string. The 41-hex case is
## the one with teeth: the clone RAN, ``git reset --hard`` then failed, the run
## exited 1 — and the checkout was LEFT BEHIND, sitting at the remote's branch
## tip. A revision nobody locked, placed by the one command whose contract is
## that it never does that, and sticky: the next run finds a populated
## directory and reports `already exists … refusing to overwrite`.
##
## Fixture: the DS-1 union fixture (a public `core` in the committed lock, a
## team `team-lib` in a routed git-checkout backend). ``repro workspace lock``
## publishes a REAL 40-hex record, and the record is then rewritten in place
## with each inexact form in turn. Rewriting a published record — rather than
## fabricating one — keeps every other variable identical: the backend is
## readable, it HOLDS a record for this repo, and only the revision's SHAPE
## changes.
##
## Asserts, for each of 41-hex / abbreviated-8-hex / all-hex-branch-name /
## uppercase-40-hex:
##   1. the repo never enters the develop set — it is NAMED as holding no exact
##      locked revision, rather than dropped;
##   2. NO checkout is placed for it, and no override is recorded;
##   3. the readable public repo still resolves, so the refusal is scoped to
##      the offending node rather than being a blanket failure.
##
## And for a 40-hex revision that is well-formed but does not EXIST in the
## remote (the shape that reaches the placement step and fails there):
##   4. the run fails, and NO checkout is left behind at the wrong revision.
##
## Falsifiability / pre-fix failure: against ``6b342175`` the 41-hex case gives
##
##   repro develop --all: error team-lib — reset-to-locked-revision failed:
##   status=asFailed reason=force-reset-failed stderr=git reset --hard
##   0123456789abcdef0123456789abcdef012345678 exited 128: fatal: ambiguous
##   argument … unknown revision
##   EXIT=1
##   deps/: core team-lib          <-- left behind
##   $ git -C deps/team-lib rev-parse HEAD
##   dccc0c3473d639b0647c1c7628bc7518e5f3bb57   <-- the branch tip; unlocked
##
## and the abbreviated / branch-name cases cloned team-lib and exited 0.
##
## Mutation check: widening ``isExactLockedRevision`` back to
## ``value.len >= 7 and value.len <= 64`` fails (1) and (2) for all four
## shapes; deleting ``discardPartialCheckout`` from
## ``cloneNodeAtLockedRevision`` fails (4) with the checkout present.
##
## Mocks: NONE. Real git repos, a real routed lock backend holding a real
## (then rewritten) record, the real ``repro`` binary.
##
## Hermetic: fresh tempdir; every configuration layer is silenced or supplied
## by the fixture. Skip: ``git`` missing or repro unbuilt.
##
## Note on ``removeDir(ws / ".repro" / "workspace")`` between cases: that
## directory is the build engine's per-run scratch (clone/reset receipts +
## engine cache), not part of the develop contract. It is cleared because of a
## SEPARATE, PRE-EXISTING defect this test happened to surface and that is
## deliberately NOT worked around anywhere else: two ``repro develop --all``
## runs in one workspace with DIFFERENT ``--into`` roots make the second run's
## clone actions resolve as already-satisfied — their receipt paths
## (``.repro/workspace/receipts/develop-all-clone-<node>.receipt``) do not vary
## with ``--into`` — so no checkout is created and the chained reset then fails
## with ``force-reset target is not a git working tree``. Reproduced against
## this same build with no lock-record tampering at all:
##
##   $ repro develop --all --into=../d1     # clones core + team-lib, exit 0
##   $ rm .repro/develop-overrides.toml
##   $ repro develop --all --into=../d2     # exit 1, ../d2 never created
##
## That is its own bug with its own fix; carrying it into this test would only
## obscure the rule under test, and asserting around it would weaken the
## per-case assertions. Every assertion below is unchanged by the clearing.

import std/[os, osproc, strutils, tempfiles, unittest]

const reproBinary = "./build/bin/repro"

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
    " config user.name \"Exact Revision Tester\"")

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
    " config user.name \"Exact Revision Tester\"")

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

proc committedLock(url, sha: string): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"x86_64-linux\"\n" &
  "optimal = true\n" &
  "inputs_digest = \"ds5-inexact\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [{ name = \"core\", path = \"core\", coord_kind = \"vcs\"" &
  ", url = \"" & url & "\", ref = \"main\", revision = \"" & sha &
  "\", integrity = \"git-sha1:" & sha &
  "\", version = \"\", visibility = \"public\", participation = \"\"" &
  ", depends = \"\", groups = \"\" }]\n"

suite "DS-5: only an exact 40-hex pin enters the develop set":

  test "t_develop_refuses_inexact_revision_and_leaves_no_checkout":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds5-inexact-", "")
      defer: removeDir(scratch)

      let coreOrigin = scratch / "origin-core.git"
      let teamOrigin = scratch / "origin-team.git"
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")
      let teamSha = seedGitOrigin(gitBin, teamOrigin, scratch / "seed-team")
      check teamSha.len == 40

      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "mix.toml",
        projectToml("file://" & coreOrigin, "file://" & teamOrigin))
      writeFile(manifestsRoot / "repos" / "core.toml",
        repoFragment("core", "core-origin"))
      writeFile(manifestsRoot / "repos" / "team-lib.toml",
        repoFragment("team-lib", "team-origin"))
      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")

      cloneInto(gitBin, coreOrigin, ws / "core")
      cloneInto(gitBin, teamOrigin, ws / "team-lib")
      createDir(ws / ".repro")
      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\n" &
        "project = \"mix\"\n" &
        "branch = \"main\"\n")
      writeFile(ws / "repro.lock",
        committedLock("file://" & coreOrigin, coreSha))
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests\", repos = [\"team-lib\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      let lockRes = run(repro & " workspace lock --workspace-root=" & q(ws))
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0
      let recordRel = "locks/mix/team-lib/" & teamSha & ".toml"
      let recordAbs = manifestsRoot / "locks" / "mix" / "team-lib" /
        (teamSha & ".toml")
      check fileExists(recordAbs)

      proc rewriteRecord(revision: string) =
        ## Rewrite the PUBLISHED record's revision in place and commit it, so
        ## the backend genuinely HOLDS a record naming this repo — only the
        ## revision's shape differs from a valid pin.
        writeFile(recordAbs,
          "[[repo]]\nname = \"team-lib\"\npath = \"team-lib\"\n" &
          "revision = \"" & revision & "\"\n")
        discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
          " add -f -- " & q(recordRel))
        discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
          " commit -q -m rewrite -- " & q(recordRel))

      # ---- (1)-(3) every inexact SHAPE is refused. -----------------------
      # 41 hex; an 8-hex abbreviation of the REAL sha (git would happily
      # resolve it, which is what made it dangerous); an all-hex branch name;
      # and the real sha in uppercase.
      let inexact = [
        ("41-hex", "0123456789abcdef0123456789abcdef012345678"),
        ("abbreviated", teamSha[0 ..< 8]),
        ("all-hex branch name", "deadbeef"),
        ("uppercase 40-hex", teamSha.toUpperAscii())]
      var caseIndex = 0
      for (label, revision) in inexact:
        inc caseIndex
        rewriteRecord(revision)
        # Clear the engine's per-run scratch — see the header note; unrelated
        # to the rule under test.
        removeDir(ws / ".repro" / "workspace")
        let deps = scratch / ("deps-" & $caseIndex)
        let res = run(repro & " develop --all --into=" & q(deps) &
          " --tool-provisioning=path", cwd = ws)
        checkpoint("case " & label & " (revision=" & revision & ") output: " &
          res.output)
        # (1) named, not dropped.
        check "no exact locked revision recorded" in res.output
        check "team-lib" in res.output
        # (2) nothing placed for it.
        check not dirExists(deps / "team-lib")
        # (3) the readable public repo is unaffected — the refusal is scoped.
        check ("cloned core @ " & coreSha) in res.output
        check dirExists(deps / "core")
        let ovPath = ws / ".repro" / "develop-overrides.toml"
        if fileExists(ovPath):
          check "package = \"team-lib\"" notin readFile(ovPath)
        removeFile(ws / ".repro" / "develop-overrides.toml")

      # ---- (4) a well-formed 40-hex pin that does NOT exist in the remote
      #          fails WITHOUT leaving a checkout behind. -----------------
      # This one passes the shape rule and reaches the placement step, where
      # the clone succeeds and the reset-to-SHA fails. Before the fix the
      # clone's tree survived at the branch tip.
      rewriteRecord("0123456789abcdef0123456789abcdef01234567")
      removeDir(ws / ".repro" / "workspace")
      let depsMissing = scratch / "deps-missing"
      let missing = run(repro & " develop --all --into=" & q(depsMissing) &
        " --tool-provisioning=path", cwd = ws)
      checkpoint("missing-revision output: " & missing.output)
      check missing.code != 0
      check "team-lib" in missing.output
      # The load-bearing assertion: no partial mutation survives the failure.
      check not dirExists(depsMissing / "team-lib")
      let ovPath2 = ws / ".repro" / "develop-overrides.toml"
      if fileExists(ovPath2):
        check "package = \"team-lib\"" notin readFile(ovPath2)
