## DS-1, invariant VB — the per-repo committed locks fill GAPS in the workspace
## root's lock; they never overrule it.
##
## `composeDevelopLockSet` reads the root's `repro.lock` first and then folds
## `participatingRepoCommittedLocks`, skipping any per-repo record whose name or
## path the root's read already supplied. Its own comment states the rule and
## the reason:
##
##   > The ROOT lock wins where both speak. Its entry for a repo is this
##   > workspace's own solved pin; the repo's self-record is what that repo last
##   > published about itself, and the two disagreeing is a lock-coherence
##   > observation (advisory, and already reported as such), never a develop-set
##   > failure. Gap-filling keeps the composed set a strict superset of the
##   > pre-DS-1 read for every workspace that has a root lock.
##
## "Strict superset" is the whole compatibility contract of DS-1, and it is a
## claim about what the composer may ADD, not about what it may CHANGE. A fold
## that let the per-repo record win would keep every workspace resolvable and
## keep `t_develop_public_only_unchanged` green (that fixture has no per-repo
## locks at all), while silently moving the pin of any repo whose own lock has
## moved on — the exact repos an operator has a root lock in order to hold
## still.
##
## The two disagreeing is NOT an error here, and this file asserts the
## non-error outcome deliberately: `collectLockCoherence` already reports that
## diff, advisorily
## (`t_lock_coherence_reports_the_diff_advisory_only`), and DS-2's fatal "two
## backends disagree" refusal is for two BACKENDS, not for one backend's two
## files. So the run exits 0 and simply reports the root's answer.
##
## THE DISCRIMINATING FIXTURE. One workspace, two participating repos, and a
## root `repro.lock` that speaks about exactly one of them:
##
##   * `liba` — named by BOTH. The root lock pins it to its FIRST commit; its
##     own in-repo lock pins it to its second, which is also where its checkout
##     stands. The two answers are therefore separable by all three observable
##     columns at once: the root's answer is the older sha with state `drifted`
##     (the checkout is not on it), the repo's own answer is the newer sha with
##     state `at-lock`.
##   * `libb` — named ONLY by its own in-repo lock. This is the gap, and it must
##     still be filled: without it the case would also pass against a composer
##     that stopped reading per-repo locks entirely, which is the regression
##     `t_develop_reads_each_participating_repos_committed_lock` owns and which
##     this file must not be able to be confused with.
##
## Asserts, over one `repro develop --list --json` run:
##
##   1. `liba` resolves at the ROOT lock's revision, state `drifted`;
##   2. the revision `liba`'s OWN lock publishes appears NOWHERE in the output —
##      not in a row, not in a notice, not in a backend line;
##   3. `libb` resolves at its own record's revision, state `at-lock`: the
##      gap-fill still happens, so (1) is not "per-repo locks were ignored";
##   4. the disagreement is not fatal and not even a refusal: exit 0, two rows,
##      no error entries;
##   5. the public backend's inventory line points at the ROOT lock path, which
##      is where the pin that won came from.
##
## Falsifiability / mutation check. RUN against a rebuilt `repro`: change the
## per-repo fold in `composeDevelopLockSet` from "skip a record the root already
## supplied" to "replace it", and `develop --list` answers
##
##     liba  public  committed-lock  <liba's own sha>  at-lock  <ws>/liba
##
## — (1) and (2) red, while (3), (4) and (5) stay green and the rest of the
## suite, including DS-1's primary case and `t_develop_public_only_unchanged`,
## stays green too.
##
## Mocks: NONE. Real git repositories on the real filesystem, a real root lock
## document and real in-repo lock documents, the real `repro` binary.
##
## Hermetic: fresh tempdir; configuration layers 2, 3 and 5 are silenced via the
## `REPROBUILD_*_CONFIG` overrides, so the built-in public default is the only
## tier. Skip: `git` missing or `repro` unbuilt.

import std/[json, os, osproc, strutils, tempfiles, unittest]

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
    "\", coord_kind = \"vcs\", url = \"" & url & "\", ref = \"main\"" &
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
  "[project]\nname = \"ws\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n" &
  "[[remote]]\nname = \"liba-origin\"\nfetch = \"" & libaUrl & "\"\n\n" &
  "[[remote]]\nname = \"libb-origin\"\nfetch = \"" & libbUrl & "\"\n\n" &
  "includes = [\n  \"repos/liba.toml\",\n  \"repos/libb.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

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

suite "DS-1: the workspace root's lock outranks a per-repo committed lock":

  test "t_develop_root_lock_outranks_a_per_repo_lock":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("ds1-root-outranks-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      let libaOrigin = scratch / "origin-liba.git"
      let libbOrigin = scratch / "origin-libb.git"
      # `liba` has TWO commits: the root lock holds it at the first, its own
      # lock has moved on to the second.
      let libaPinnedSha = seedOrigin(gitBin, libaOrigin, scratch / "seed-liba")
      let libaOwnSha = advanceOrigin(gitBin, scratch / "seed-liba")
      let libbSha = seedOrigin(gitBin, libbOrigin, scratch / "seed-libb")
      check libaPinnedSha != libaOwnSha
      check libbSha != libaOwnSha
      check libbSha != libaPinnedSha

      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "ws.toml",
        projectToml(fileUrl(libaOrigin), fileUrl(libbOrigin)))
      writeFile(manifestsRoot / "repos" / "liba.toml",
        repoFragment("liba", "liba-origin"))
      writeFile(manifestsRoot / "repos" / "libb.toml",
        repoFragment("libb", "libb-origin"))
      cloneInto(gitBin, libaOrigin, ws / "liba")
      cloneInto(gitBin, libbOrigin, ws / "libb")
      writeWorkspaceBranch(ws, project = "ws", branch = "main")

      # Both checkouts stand at the revision their OWN in-repo lock publishes.
      # That is what makes the two candidate answers for `liba` differ in STATE
      # as well as in revision: the root's pin is behind the checkout
      # (`drifted`), the repo's own pin is the checkout (`at-lock`). A composer
      # that let the repo win therefore cannot produce this test's expected
      # state by accident.
      check requireGit(q(gitBin) & " -C " & q(ws / "liba") &
        " rev-parse HEAD").strip() == libaOwnSha
      check requireGit(q(gitBin) & " -C " & q(ws / "libb") &
        " rev-parse HEAD").strip() == libbSha

      # The ROOT lock: this workspace's own solved pin, and it speaks about
      # `liba` only. (`libb` is the gap.)
      writeFile(ws / "repro.lock", lockDoc(
        depInline("liba", "liba", fileUrl(libaOrigin), libaPinnedSha)))
      # Each repo's own lock, pinning ITSELF — `liba`'s disagreeing with the
      # root, `libb`'s filling a gap the root left.
      writeFile(ws / "liba" / "repro.lock", lockDoc(
        depInline("liba", ".", fileUrl(libaOrigin), libaOwnSha)))
      writeFile(ws / "libb" / "repro.lock", lockDoc(
        depInline("libb", ".", fileUrl(libbOrigin), libbSha)))

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      let listed = runCmd(q(reproBin) &
        " develop --list --json --tool-provisioning=path --workspace-root=" &
        q(ws))
      if listed.code != 0:
        checkpoint("develop --list --json output: " & listed.output)
      # ---- (4) the disagreement is not fatal. -----------------------------
      check listed.code == 0

      var report: JsonNode = nil
      try:
        report = parseJson(listed.output)
      except CatchableError as err:
        checkpoint("unparseable --json output: " & err.msg & "\n" &
          listed.output)
      check report != nil
      if report != nil:
        check report["exitCode"].getInt() == 0
        check report["errors"].len == 0

        # ---- (1) the ROOT's pin is the one that resolves. -----------------
        let liba = rowFor(report, "liba")
        check liba.found
        if liba.found:
          check liba.revision == libaPinnedSha
          check liba.revision != libaOwnSha
          check liba.path == os.normalizedPath(ws / "liba")
          check liba.state == "drifted"
          check liba.tier == "public"
          check liba.backend == "committed-lock"

        # ---- (3) the gap is still filled from the per-repo lock. ----------
        let libb = rowFor(report, "libb")
        check libb.found
        if libb.found:
          check libb.revision == libbSha
          check libb.path == os.normalizedPath(ws / "libb")
          check libb.state == "at-lock"

        var names: seq[string]
        for r in report["repos"]: names.add(r["name"].getStr())
        check names.len == 2

        # ---- (5) the inventory names the medium the winning pin came from.
        var publicLocation = ""
        for b in report["backends"]:
          if b["tier"].getStr() == "public" and
              b["kind"].getStr() == "committed-lock":
            publicLocation = b["location"].getStr()
        check publicLocation == os.normalizedPath(ws / "repro.lock")

      # ---- (2) the overruled revision leaks nowhere. ----------------------
      check libaOwnSha notin listed.output
      let listedText = runCmd(q(reproBin) &
        " develop --list --tool-provisioning=path --workspace-root=" & q(ws))
      check listedText.code == 0
      check libaPinnedSha in listedText.output
      check libaOwnSha notin listedText.output
