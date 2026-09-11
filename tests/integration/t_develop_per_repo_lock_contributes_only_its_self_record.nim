## DS-1, invariant VA — a participating repo's in-repo `repro.lock` contributes
## **only the record that repo publishes about ITSELF**, never the records it
## publishes about anybody else.
##
## `participatingRepoCommittedLocks` reads every participating repo's own
## committed lock and folds ONE dep out of each: the one at path `.` (the lock's
## own root consumer), rebased onto the repo's workspace-relative path. A repo's
## lock also pins that repo's DEPENDENCIES, and those pins are deliberately
## dropped, for the reason the procedure's own comment gives:
##
##   > two participating repos may legitimately pin a third at different
##   > revisions (that is precisely the disagreement `collectLockCoherence`
##   > reports, and reports as ADVISORY […]). Folding those cross claims into
##   > the union would turn an advisory diff into the composer's fatal DS-2
##   > "two backends disagree" refusal. Each repo is the sole authority on its
##   > own pin […]
##
## Unified-Locking-And-Hooks.md §3 says the same thing about what one public
## record holds — "the solved-graph pins for **the repo's** public dependencies
## + **the repo's own** public coordinates" — and it is the second half that the
## workspace read is entitled to, because only the second half is a statement
## the repo has the standing to make about where IT lives in THIS workspace.
##
## `t_develop_reads_each_participating_repos_committed_lock` (DS-1's primary
## case) cannot see this. Every repo in its fixture publishes a lock with
## exactly ONE dep — its own — so "fold the self-record" and "fold everything"
## are the same function there, and the whole suite stayed green under a
## composer that folded everything. This file supplies the fixture that tells
## them apart.
##
## THE DISCRIMINATING FIXTURE. Three participating repos, and one root lock.
##
## `liba`'s lock is the realistic one: besides its self-record it carries what
## `liba` last solved for its dependencies, and one of those is a SIBLING of
## this very workspace, `libb` — pinned at a STALE revision (`libb`'s first
## commit, one behind where `libb` actually is) and, because a dependency's
## `path` inside `liba`'s lock is expressed relative to `liba`'s own consumer
## root, at `../probe/libb`, which is not where `libb` lives in this workspace.
## It also cross-claims `libz`, a name the workspace's membership does not
## contain at all.
##
## Two things therefore go wrong at once if the cross claims are folded, and
## the second is the quiet one:
##
##   * the workspace resolves `libb` to a revision `libb` never published and a
##     directory outside the workspace root (state `absent` — there is nothing
##     there); and
##   * `libb`'s OWN, correct record is then dropped by the union's name dedup,
##     because `liba`'s claim was folded first and took the name. A repo's own
##     lock is silently outranked by a sibling's stale opinion of it.
##
## `liba` and `libc` each additionally carry a SECOND record at path `.`
## (`liba-shadow`, `libc-shadow`, at revisions found nowhere else in the
## fixture). `libc` is the one that matters: it is ALSO named by the root lock,
## at `vendor/libc` rather than at `libc`. That pairing is not decoration — it
## is the only shape in which the `break` at the end of the fold loop is
## load-bearing, and the reasoning is set out at the root lock in the body.
##
## Asserts, over one `repro develop --list --json` run:
##
##   1. `libb` resolves at the revision `libb`'s OWN lock records, at
##      `<ws>/libb`, state `at-lock`. Revision, path and state are each
##      asserted: the stale-cross-claim mutant differs in all three, and any one
##      of them alone could be reached by an unrelated accident.
##   2. `liba` resolves at its own self-record's revision, at `<ws>/liba`,
##      state `at-lock` — the self-record is still read, so (1) is not satisfied
##      by reading nothing.
##   3. the stale revision appears NOWHERE in the output, and neither does the
##      `probe/` path. A cross claim that is dropped from the develop set but
##      leaks into some other line of the report is still a cross claim the
##      workspace acted on.
##   4. the develop set is EXACTLY {liba, libb, libc}: `libz` — named only by a
##      sibling's dependency pin — is not develop-manageable in this workspace,
##      and the public backend reports exactly 3 records.
##   5. a repo contributes AT MOST ONE record however many root consumers its
##      document offers: neither `liba-shadow` nor `libc-shadow` is in the rows,
##      and neither revision is anywhere in the report.
##   6. `libc` resolves at the ROOT lock's revision, at `<ws>/vendor/libc`,
##      state `absent` — the precondition for (5)'s `libc` half, since it is the
##      root having claimed the NAME that leaves the PATH unclaimed.
##
## Falsifiability / mutation checks. Each was RUN against a rebuilt `repro`, and
## the failing checks are named by IDENTITY rather than by line number, which
## rots the moment this comment grows.
##
## MUTATION 1 — "fold EVERY dep of every repo's lock". THREE edits inside
## `participatingRepoCommittedLocks`, all three required, so the recipe is
## spelled out in full rather than described:
##
##   a. delete `if not (dep.path.len == 0 or dep.path == "."): continue`;
##   b. make the rebase conditional — replace
##      `rebased.path = repo.path` / `if rebased.name.len == 0: …` with
##      `if dep.path.len == 0 or dep.path == ".":` guarding both lines;
##   c. delete the trailing `break`.
##
## All six proper subsets were RUN. `a`, `b` and `ab` are GREEN; `c`, `ac` and
## `bc` are RED, but every one of them on MUTATION 2's checks BELOW and on
## nothing else — the three fail on byte-identical check sets. So no subset
## produces the cross-claim symptom: only the full triple moves `libb`.
##
## Why each edit is load-bearing, since a partial recipe is worse than none — an
## engineer who deletes (a) alone, sees the suite stay green and concludes the
## guard is dead code has been licensed by this comment to commit the exact
## regression the file exists to prevent:
##
##   * WITHOUT (a), the guard rejects every dep whose path is not `.`, so no
##     cross claim is ever reached — this is the statement under test, and the
##     other two edits only clear the obstacles standing in front of it.
##   * WITHOUT (b), `rebased.path = repo.path` is unconditional, so every
##     cross claim is rewritten onto the repo's OWN workspace path and
##     `composeDevelopLockSet`'s `havePaths` dedup then drops all of them. The
##     answer is byte-identical to the correct one. This is the edit that makes
##     the obvious two-line recipe a FALSE one, and the reason this section is
##     as long as it is.
##   * WITHOUT (c), the loop still stops at `liba`'s first folded dep — which
##     is its self-record, the document's first entry — so the cross claims are
##     never reached.
##
## With all three, `develop --list` grows the rows
##
##     libb  public  committed-lock  <stale sha>  absent  <scratch>/probe/libb
##     libz  public  committed-lock  <stale sha>  absent  <scratch>/probe/libz
##
## and 16 checks go red: `libb.revision == libbSha`,
## `libb.revision != libbStaleSha`, `libb.path == …`, `libb.state == "at-lock"`,
## `names.len == 3`, `"libz" notin names`, `"libc-shadow" notin names`,
## `publicRecords == 3`, and the `libbStaleSha` / `"probe"` / `libcShadowSha` /
## `"libz"` / `"libc-shadow"` leak checks on both output forms. The whole rest
## of the suite, including DS-1's primary case, stays GREEN under that mutant,
## which is why this file exists.
##
## MUTATION 2 — delete the `break` ALONE (edit (c), nothing else). 6 checks go
## red: `names.len == 3`, `"libc-shadow" notin names`, `publicRecords == 3`, and
## the `libcShadowSha` / `"libc-shadow"` leak checks. `develop --list` grows
##
##     libc-shadow  public  committed-lock  <libc shadow sha>  drifted  <ws>/libc
##
## — a revision published by a repo that is not a workspace member, entering the
## develop set as the pin for `<ws>/libc`, which no lock entitled to speak for
## that location ever named.
##
## This is the case the `libc` half of the fixture exists for, and it is worth
## stating why it needs a root lock at all. `composeDevelopLockSet`'s
## gap-filling fold tests two arms,
##
##     if (d.name.len > 0 and d.name in haveNames) or
##         (d.path.len > 0 and d.path in havePaths):
##       continue
##
## and that `continue` skips BOTH the `haveNames.incl` and the `havePaths.incl`
## below it. A record rejected on the NAME arm therefore never claims its PATH.
## For `liba` — unnamed by the root lock — the self-record IS admitted, claims
## path `liba`, and the path arm catches a `break`-less second dep on its own.
## For `libc` the root lock has already taken the name, so `libc`'s self-record
## is skipped, path `libc` is never claimed, and `libc-shadow` passes both arms.
## The `break` is the only thing that stops it being emitted at all.
##
## MUTATION 3 — delete the `break` AND narrow the dedup in
## `composeDevelopLockSet` to the `haveNames` test alone. 10 checks go red: the
## same 6 as MUTATION 2, plus `"liba-shadow" notin names` and the three
## `shadowSha` / `"liba-shadow"` leak checks. With the path arm gone, `liba`'s
## second `.` dep is admitted too, and two rows then claim the single checkout
## `<ws>/liba`:
##
##     liba         public  committed-lock  <liba sha>    at-lock  <ws>/liba
##     liba-shadow  public  committed-lock  <shadow sha>  drifted  <ws>/liba
##
## That is why (5) covers BOTH repos rather than just `libc`: `liba` pins the
## path arm, `libc` pins the `break`, and each is the only guard standing in its
## own case.
##
## Mocks: NONE. Real git repositories on the real filesystem, real in-repo lock
## documents, the real `repro` binary.
##
## Hermetic: fresh tempdir; configuration layers 2, 3 and 5 are silenced via the
## `REPROBUILD_*_CONFIG` overrides, so the workspace declares no `[locking]`
## route and the built-in public default is the only tier. Skip: `git` missing
## or `repro` unbuilt.

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
  ## One-commit origin plus its seed worktree; returns the seed commit's sha.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  createDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Self Record Tester\"")
  # The file BODY carries the work path, so two origins seeded inside the same
  # second cannot land on the same tree and therefore cannot land on the same
  # sha — which would make every "these revisions differ" assertion vacuous.
  writeFile(workPath / "seed.txt", "seed\n" & workPath & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add seed.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " remote add origin " &
    q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc advanceOrigin(gitBin, workPath: string): string =
  ## A second commit on the same origin; returns the new sha. The first sha is
  ## then the STALE revision a sibling's out-of-date cross claim carries.
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
    " config user.name \"Self Record Tester\"")

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
  "inputs_digest = \"ds1-self-record-only\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [" & deps & "]\n"

proc projectToml(libaUrl, libbUrl, libcUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\nname = \"ws\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n" &
  "[[remote]]\nname = \"liba-origin\"\nfetch = \"" & libaUrl & "\"\n\n" &
  "[[remote]]\nname = \"libb-origin\"\nfetch = \"" & libbUrl & "\"\n\n" &
  "[[remote]]\nname = \"libc-origin\"\nfetch = \"" & libcUrl & "\"\n\n" &
  "includes = [\n  \"repos/liba.toml\",\n  \"repos/libb.toml\"," &
  "\n  \"repos/libc.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"" & "main" & "\"\n"

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

suite "DS-1: a per-repo committed lock contributes only its own self-record":

  test "t_develop_per_repo_lock_contributes_only_its_self_record":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("ds1-self-record-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      let libaOrigin = scratch / "origin-liba.git"
      let libbOrigin = scratch / "origin-libb.git"
      let libcOrigin = scratch / "origin-libc.git"
      let libaSha = seedOrigin(gitBin, libaOrigin, scratch / "seed-liba")
      # `libb` has TWO commits. The first is what `liba`'s lock still claims
      # about it; the second is where `libb` actually is and what `libb`'s own
      # lock records.
      let libbStaleSha = seedOrigin(gitBin, libbOrigin, scratch / "seed-libb")
      let libbSha = advanceOrigin(gitBin, scratch / "seed-libb")
      # `libc` likewise: the ROOT lock holds it at the first commit, its own
      # lock and its checkout are at the second. See (6).
      let libcRootSha = seedOrigin(gitBin, libcOrigin, scratch / "seed-libc")
      let libcSha = advanceOrigin(gitBin, scratch / "seed-libc")
      # A fourth origin, never checked out and never a workspace member. It
      # exists only to give `liba`'s and `libc`'s locks a SECOND record at path
      # `.`, each at a unique and therefore unambiguously greppable revision —
      # see (5) and (6).
      let shadowOrigin = scratch / "origin-shadow.git"
      let shadowSha = seedOrigin(gitBin, shadowOrigin, scratch / "seed-shadow")
      let libcShadowSha = advanceOrigin(gitBin, scratch / "seed-shadow")
      check libbSha != libbStaleSha
      check libaSha != libbSha
      check libcSha != libcRootSha
      check shadowSha != libaSha
      check shadowSha != libbSha
      check shadowSha != libbStaleSha
      check libcShadowSha != shadowSha
      check libcShadowSha != libcSha
      check libcShadowSha != libcRootSha

      # A manifest-described workspace: `.repro/manifests` supplies membership.
      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "ws.toml",
        projectToml(fileUrl(libaOrigin), fileUrl(libbOrigin),
          fileUrl(libcOrigin)))
      writeFile(manifestsRoot / "repos" / "liba.toml",
        repoFragment("liba", "liba-origin"))
      writeFile(manifestsRoot / "repos" / "libb.toml",
        repoFragment("libb", "libb-origin"))
      writeFile(manifestsRoot / "repos" / "libc.toml",
        repoFragment("libc", "libc-origin"))
      cloneInto(gitBin, libaOrigin, ws / "liba")
      cloneInto(gitBin, libbOrigin, ws / "libb")
      cloneInto(gitBin, libcOrigin, ws / "libc")
      writeWorkspaceBranch(ws, project = "ws", branch = "main")

      # Both checkouts sit at the revision their OWN lock records, so a repo
      # resolved from its own self-record reads `at-lock` and a repo resolved
      # from somebody else's stale claim cannot: it names a different revision
      # AND a directory that does not exist. The lock documents are written
      # into the worktree and not committed — that is exactly the state `repro
      # lock refresh` leaves behind, and a lock file can never contain the sha
      # of the commit that adds it, so committing here would make `at-lock`
      # unreachable for a self-record by construction.
      check requireGit(q(gitBin) & " -C " & q(ws / "liba") &
        " rev-parse HEAD").strip() == libaSha
      check requireGit(q(gitBin) & " -C " & q(ws / "libb") &
        " rev-parse HEAD").strip() == libbSha
      check requireGit(q(gitBin) & " -C " & q(ws / "libc") &
        " rev-parse HEAD").strip() == libcSha

      # `liba`'s lock: its own coordinates, PLUS the two cross claims. Both
      # cross-claim paths are relative to `liba`'s own consumer root, so they
      # land OUTSIDE the workspace when read as workspace-relative — which is
      # the second half of why a cross claim is not this workspace's to fold.
      #
      # It also carries a SECOND record at path `.` — see (5). A repo speaks
      # for itself exactly once; a document offering two root consumers gets
      # ONE of them folded, deterministically the first.
      let probeLibb = scratch / "probe" / "libb"
      let probeLibz = scratch / "probe" / "libz"
      check not dirExists(probeLibb)
      check not dirExists(probeLibz)
      writeFile(ws / "liba" / "repro.lock", lockDoc(
        depInline("liba", ".", fileUrl(libaOrigin), libaSha) & ", " &
        depInline("liba-shadow", ".", fileUrl(shadowOrigin), shadowSha) & ", " &
        depInline("libb", "../probe/libb", fileUrl(libbOrigin), libbStaleSha) &
        ", " &
        depInline("libz", "../probe/libz", fileUrl(libbOrigin), libbStaleSha)))
      # `libb`'s lock: its own coordinates, and nothing else to say.
      writeFile(ws / "libb" / "repro.lock", lockDoc(
        depInline("libb", ".", fileUrl(libbOrigin), libbSha)))
      # `libc`'s lock: the same two-root-consumers shape as `liba`'s — but
      # `libc` is ALSO named by the ROOT lock below, at a path that is NOT its
      # workspace path. That combination is what makes the `break` load-bearing
      # on its own, and it is the whole reason `libc` exists. See (6).
      writeFile(ws / "libc" / "repro.lock", lockDoc(
        depInline("libc", ".", fileUrl(libcOrigin), libcSha) & ", " &
        depInline("libc-shadow", ".", fileUrl(shadowOrigin), libcShadowSha)))

      # The ROOT lock, naming `libc` ONLY, and at `vendor/libc` rather than at
      # `libc`. Both halves are deliberate and neither is exotic — a root lock
      # records the path the SOLVE placed a dependency at, which need not be the
      # path workspace membership puts the checkout at.
      #
      # The consequence is the branch (6) exists to cover. In
      # `composeDevelopLockSet`'s gap-filling fold the two dedup arms are
      # `d.name in haveNames` OR `d.path in havePaths`, and the `continue` they
      # guard skips BOTH `incl` calls. So when the NAME arm fires — as it does
      # here for `libc`'s self-record, the root having already claimed the name
      # — the PATH `libc` is never entered into `havePaths` at all. A second
      # `.` dep from that same repo therefore passes both arms, and only the
      # `break` in `participatingRepoCommittedLocks` stops it from being
      # emitted in the first place.
      let vendorLibc = ws / "vendor" / "libc"
      check not dirExists(vendorLibc)
      writeFile(ws / "repro.lock", lockDoc(
        depInline("libc", "vendor/libc", fileUrl(libcOrigin), libcRootSha)))

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
      check listed.code == 0

      # A malformed document would make every field lookup below raise rather
      # than fail a named check, so parse defensively and keep the rest of the
      # case guarded on the parse having succeeded (`check` does not abort a
      # `test` body).
      var report: JsonNode = nil
      try:
        report = parseJson(listed.output)
      except CatchableError as err:
        checkpoint("unparseable --json output: " & err.msg & "\n" &
          listed.output)
      check report != nil
      if report != nil:
        check report["exitCode"].getInt() == 0

        # ---- (1) `libb` is resolved from `libb`'s OWN record. -------------
        let libb = rowFor(report, "libb")
        check libb.found
        if libb.found:
          check libb.revision == libbSha
          check libb.revision != libbStaleSha
          check libb.path == os.normalizedPath(ws / "libb")
          check libb.state == "at-lock"
          check libb.tier == "public"
          check libb.backend == "committed-lock"

        # ---- (2) `liba`'s own self-record is still read. ------------------
        let liba = rowFor(report, "liba")
        check liba.found
        if liba.found:
          check liba.revision == libaSha
          check liba.path == os.normalizedPath(ws / "liba")
          check liba.state == "at-lock"

        # ---- (6) `libc` resolves from the ROOT lock, and ONLY from it. ----
        # The root claimed the NAME, so `libc`'s own self-record is skipped —
        # and, because that skip never claims the PATH, this is precisely the
        # shape in which a second `.` dep would sail through both dedup arms.
        let libc = rowFor(report, "libc")
        check libc.found
        if libc.found:
          check libc.revision == libcRootSha
          check libc.revision != libcSha
          check libc.path == os.normalizedPath(ws / "vendor" / "libc")
          check libc.state == "absent"

        # ---- (4) the develop set is EXACTLY the participating repos. ------
        var names: seq[string]
        for r in report["repos"]: names.add(r["name"].getStr())
        check names.len == 3
        check "libz" notin names

        # ---- (5) ONE record per repo, whatever the document offers. -------
        # Both `liba`'s and `libc`'s locks name two root consumers. Exactly one
        # is folded from each, and it is the first: the second is not a second
        # repo, it is a second opinion about the SAME workspace location, and
        # admitting it would make which pin the repo gets depend on document
        # order downstream.
        #
        # The two are NOT redundant. `liba` is unnamed by the root lock, so its
        # self-record claims path `liba` and the path dedup would catch a
        # `break`-less second dep anyway. `libc` IS named by the root, at
        # another path, so nothing claims path `libc` and the `break` is the
        # only thing standing between `libc-shadow` and the develop set.
        check "liba-shadow" notin names
        check "libc-shadow" notin names
        # …and the public backend says it folded exactly three records, so a
        # cross claim cannot have been folded and then filtered out downstream.
        var publicRecords = -1
        for b in report["backends"]:
          if b["tier"].getStr() == "public" and
              b["kind"].getStr() == "committed-lock":
            publicRecords = b["records"].getInt()
        check publicRecords == 3

      # ---- (3) the stale claim leaks into no part of the report. ----------
      # Asserted on the RAW text of both output forms, so a cross claim that is
      # kept out of the rows but surfaces in a notice, a diagnostic or a
      # backend line is still caught.
      check libbStaleSha notin listed.output
      check "probe" notin listed.output
      check shadowSha notin listed.output
      check libcShadowSha notin listed.output
      let listedText = runCmd(q(reproBin) &
        " develop --list --tool-provisioning=path --workspace-root=" & q(ws))
      check listedText.code == 0
      check libbStaleSha notin listedText.output
      check "probe" notin listedText.output
      check "libz" notin listedText.output
      check shadowSha notin listedText.output
      check libcShadowSha notin listedText.output
      check "liba-shadow" notin listedText.output
      check "libc-shadow" notin listedText.output
