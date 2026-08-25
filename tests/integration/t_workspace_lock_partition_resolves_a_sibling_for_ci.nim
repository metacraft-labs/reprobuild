## Unified-Locking-And-Hooks HL-2 (§6 Decision 1, team row) — the lock a routed
## workspace publishes into its git-checkout manifest backend must still ANSWER
## THE CROSS-REPO QUESTION CI asks of it.
##
## The end-to-end statement pinned here is deliberately not "the writer wrote
## something": it is **after `repro workspace lock`, a CI sibling resolver can
## resolve a sibling's revision for the trigger commit**. A unit test on the
## writer alone would have passed throughout the outage this test exists to
## prevent — the writer was writing records the whole time; they just could not
## be read as a workspace lock by anyone.
##
## The defect (observed on `metacraft-labs/dev`, every lock this workspace wrote
## after `repro locking adopt-manifest` declared a team route): with explicit
## `[locking]` routes present, `executeWorkspaceLock` SKIPPED the trigger-keyed
## partition write entirely and left only `recordRoutedParticipation`'s minimal
## per-repo bodies in the manifest:
##
##     [[repo]]
##     name = "core"
##     path = "core"
##     revision = "<sha>"
##
## No `schema`, no `[lock]` table, one repo. `resolve-sibling-rev.sh`
## (metacraft-github-actions/clone-siblings, vendored in codetracer/scripts)
## recognises that shape at discovery (`is_participation_record`) and ignores
## it, because it pins only the repo whose directory it sits in and therefore
## cannot name a sibling — so `clone-siblings --no-walk` reported exit 3, "no
## workspace lock found", for every commit locked that way.
##
## Spec: Unified-Locking-And-Hooks.md §6 Decision 1 requires the partition, not
## its suppression — "**team** partition → a `locks/<project>/<repo>/<sha>.toml`
## written into the team's durable backend, containing only the team partition's
## repos", and "the git manifest lock file, when one is produced, contains
## **only** the repos routed to that backend". Tier isolation is a property of
## WHAT the document contains (`manifestOwnedRepos`), not of withholding it.
##
## Assertions:
##   1. The fixture really is in ROUTED mode — `repro locking explain --json`
##      attributes both repos to the `git-checkout` backend via an explicit
##      route. Without this the test could go green vacuously by falling through
##      to the unrouted single-tier path (which always wrote a monolithic lock),
##      e.g. after a typo in the route table.
##   2. The lock at `locks/mix/core/<coreSha>.toml` is a workspace-lock
##      DOCUMENT by the resolver's own discriminator: a top-level `schema =
##      "reprobuild.workspace.lock.v1"` before any table header, plus a `[lock]`
##      table. Equivalently: it is NOT an `is_participation_record`.
##   3. Reading that document the way the resolver reads it yields the SIBLING
##      `lib`'s revision — the question the record exists to answer.
##   4. No minimal participation record squats on `locks/mix/lib/<libSha>.toml`.
##      Such a record is not merely useless to CI: published at a coordinate, it
##      permanently costs that repo the lock document its own pre-push would
##      have published there — see (6) for why that coordinate can then be
##      neither rewritten nor refused.
##   5. End-to-end, when a `resolve-sibling-rev.sh` checkout is available beside
##      this one: the real script resolves `lib` for `core@<coreSha>` with
##      `--no-walk` (exactly how the `clone-siblings` action calls it) and
##      prints lib's SHA on exit 0. Skipped, never faked, when absent.
##   6. A minimal participation record already COMMITTED at the partition's
##      coordinate neither refuses the lock nor is overwritten. Every workspace
##      that locked during the outage is in exactly that state. Refusing would
##      block its pushes (the immutable-record check compares 1 path against N);
##      overwriting would produce an `M` entry that lock publication —
##      additions-only at the staging check and at `verifyLockOnlyAheadChain` —
##      refuses forever, wedging the store. The record is left as published and
##      the operator is told what it costs.
##
## Falsifiability (mutation-tested, see the commit message): restoring the
## `not composed.hasExplicitRoutes` guard on the partition write flips (2)-(6);
## disabling the `partitionRoot` exclusion in the participation fan-out flips
## (4) — the partition itself survives, because the store refuses to rewrite it,
## but every non-trigger repo gets a squatting record again; making
## `isWorkspaceLockDocument` unconditionally true flips (6), because the
## squatting record is then read as a lock document and the coordinate-mismatch
## refusal fires.
##
## Hermetic: fresh tempdir, local `git init` / `git init --bare` only, no
## network; the system/dotfiles/VCS-private config layers are silenced with env
## overrides. Skip: `git` missing or `./build/bin/repro` absent (the suite does
## not build the binary itself). Leg (5) additionally skips when no sibling
## `resolve-sibling-rev.sh` is on disk.

import std/[json, os, osproc, strutils, tempfiles, unittest]

const reproBinary = "./build/bin/" & addFileExt("repro", ExeExt)

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
    " config user.name \"Partition Lock Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath, marker: string): string =
  ## ``marker`` makes each seeded repo's tree — and therefore its commit SHA —
  ## DISTINCT. Two repos seeded with identical content, author and timestamp
  ## produce the identical commit SHA, and then "the lock pins the sibling's
  ## revision" is unfalsifiable: reading the WRONG repo's revision still
  ## compares equal. The assertion only means something when the two SHAs
  ## differ, which is asserted below.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  writeFile(workPath / "seed.txt", "seed " & marker & "\n")
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
    " config user.name \"Partition Lock Tester\"")

proc projectToml(coreUrl, libUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
  "includes = [\n  \"repos/core.toml\",\n  \"repos/lib.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

# ---- the CI resolver's contract, reimplemented faithfully ------------------
#
# These two procs are the Nim transcription of the only two things
# ``resolve-sibling-rev.sh`` does with a candidate ``.toml``: decide whether it
# is a routed participation record (and if so IGNORE it, which is what makes a
# commit report "unlocked"), and otherwise parse it strictly as a
# ``reprobuild.workspace.lock.v1`` document to read one sibling's revision.
# They are here so the claim is pinned hermetically in this repo; leg (5) below
# additionally runs the real script when a checkout of it is on disk.

proc isParticipationRecord(body: string): bool =
  ## Mirrors ``is_participation_record``: no top-level ``schema`` key, every
  ## table in the document is ``[[repo]]``, and at least one ``name`` is
  ## present. Such a document is not a workspace lock and is skipped at
  ## discovery.
  var tables = 0
  var repoTables = 0
  var names = 0
  for rawLine in body.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"): continue
    if line.startsWith("["):
      inc tables
      if line == "[[repo]]": inc repoTables
      continue
    let eq = line.find('=')
    if eq <= 0: continue
    let key = line[0 ..< eq].strip()
    if tables == 0 and key == "schema":
      return false
    if key == "name": inc names
  repoTables > 0 and tables == repoTables and names > 0

proc siblingRevFromLock(body, sibling: string): string =
  ## Mirrors ``rev_from_toml``: require the top-level
  ## ``schema = "reprobuild.workspace.lock.v1"`` announcement, then return the
  ## ``revision`` of the ``[[repo]]`` block whose ``name`` is ``sibling``.
  ## Returns "" when the document does not announce the schema or does not pin
  ## the sibling.
  var schemaSeen = false
  var inRepo = false
  var curName = ""
  var curRev = ""
  var hit = ""
  for rawLine in body.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"): continue
    if line.startsWith("["):
      if inRepo and curName == sibling and curRev.len > 0:
        hit = curRev
      inRepo = line == "[[repo]]"
      curName = ""
      curRev = ""
      continue
    let eq = line.find('=')
    if eq <= 0: continue
    let key = line[0 ..< eq].strip()
    let val = line[eq + 1 .. ^1].strip().strip(chars = {'"'})
    if key == "schema":
      if val != "reprobuild.workspace.lock.v1": return ""
      schemaSeen = true
      continue
    if not inRepo: continue
    case key
    of "name": curName = val
    of "revision": curRev = val
    else: discard
  if inRepo and curName == sibling and curRev.len > 0:
    hit = curRev
  if not schemaSeen: return ""
  hit

proc findRealResolver(): string =
  ## The `clone-siblings` action's script, in either of the two checkouts this
  ## workspace is known to carry it in. Empty when neither is present.
  for rel in [
      ".." / "metacraft-github-actions" / "clone-siblings" /
        "resolve-sibling-rev.sh",
      ".." / "codetracer" / "scripts" / "resolve-sibling-rev.sh"]:
    let p = absolutePath(rel)
    if fileExists(p): return p
  ""

suite "HL-2 — the routed manifest partition lock resolves a sibling for CI":

  test "t_workspace_lock_partition_resolves_a_sibling_for_ci":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = createTempDir("partition-lock-", "")
      defer: removeDir(scratch)

      let coreOrigin = scratch / "origin-core.git"
      let libOrigin = scratch / "origin-lib.git"
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core",
        "core")
      let libSha = seedGitOrigin(gitBin, libOrigin, scratch / "seed-lib",
        "lib")
      # Guard the guard: identical SHAs would make every "pins the SIBLING's
      # revision" assertion below pass while reading the wrong repo.
      check coreSha != libSha

      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "mix.toml",
        projectToml("file://" & coreOrigin, "file://" & libOrigin))
      writeFile(manifestsRoot / "repos" / "core.toml",
        repoFragment("core", "core-origin"))
      writeFile(manifestsRoot / "repos" / "lib.toml",
        repoFragment("lib", "lib-origin"))

      # The team backend IS the manifest checkout (adopt-manifest's
      # ``path = ".repro/manifests"``), so it must be a real git repo.
      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")

      cloneInto(gitBin, coreOrigin, ws / "core")
      cloneInto(gitBin, libOrigin, ws / "lib")
      createDir(ws / ".repro")
      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"mix\"\nbranch = \"main\"\n")

      # Byte-for-byte the route ``repro locking adopt-manifest`` scaffolds.
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests\", repos = [\"core\", \"lib\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- (1) the fixture is genuinely in ROUTED mode -------------------
      # Guards against a vacuous green: an ignored/mis-typed route table would
      # take the unrouted single-tier path, which always wrote a monolithic
      # lock and would satisfy (2)/(3) for the wrong reason.
      let explain = run(reproBinary & " locking explain" &
        " --workspace-root=" & q(ws) & " --json")
      if explain.code != 0:
        checkpoint("locking explain output: " & explain.output)
      check explain.code == 0
      var routedRepos = 0
      for entry in parseJson(explain.output)["repos"]:
        if entry["backend"].getStr() == "git-checkout" and
            entry["tier"].getStr() == "team" and
            entry["layer"].getStr() != "built-in":
          inc routedRepos
      if routedRepos != 2:
        checkpoint("locking explain JSON: " & explain.output)
      check routedRepos == 2

      # ---- lock ----------------------------------------------------------
      let lock1 = run(reproBinary & " workspace lock --workspace-root=" & q(ws))
      if lock1.code != 0:
        checkpoint("workspace lock output: " & lock1.output)
      check lock1.code == 0

      # ---- (2) the trigger-keyed record is a workspace-lock DOCUMENT -----
      let partitionPath =
        manifestsRoot / "locks" / "mix" / "core" / (coreSha & ".toml")
      check fileExists(partitionPath)
      let partition = readFile(partitionPath)
      checkpoint("partition lock body:\n" & partition)
      check not isParticipationRecord(partition)
      check partition.contains("schema = \"reprobuild.workspace.lock.v1\"")
      check partition.contains("[lock]")

      # ---- (3) it answers the sibling question ---------------------------
      check siblingRevFromLock(partition, "lib") == libSha
      check siblingRevFromLock(partition, "core") == coreSha

      # ---- (4) no minimal record squats on lib's own coordinate ----------
      check not fileExists(
        manifestsRoot / "locks" / "mix" / "lib" / (libSha & ".toml"))

      # ---- (5) the REAL resolver, called the way clone-siblings calls it --
      let resolver = findRealResolver()
      if resolver.len == 0:
        checkpoint("no resolve-sibling-rev.sh checkout beside this repo; " &
          "leg (5) skipped (legs 1-4 pin the same contract hermetically)")
      else:
        # stderr carries the resolver's diagnostics; stdout carries ONLY the
        # revision, which is what `clone-siblings` consumes. Keep them apart so
        # the assertion is on the answer, not on the commentary.
        let resolvedCmd = q(resolver) & " --repo core --sibling lib" &
          " --manifest-dir " & q(manifestsRoot) &
          " --sha " & q(coreSha) &
          " --repo-dir " & q(ws / "core") &
          " --prefer-project mix --no-walk"
        let diagnosed = run(resolvedCmd)
        let resolved = run(resolvedCmd & " 2>/dev/null")
        if resolved.code != 0:
          checkpoint("resolve-sibling-rev output:\n" & diagnosed.output)
        check resolved.code == 0
        check resolved.output.strip() == libSha

      # ---- (6) a PUBLISHED squatting record neither wedges nor is rewritten --
      # Every workspace that locked during the outage is in this state: its own
      # minimal participation records are committed at exactly the coordinates
      # its partitions would occupy. Two failure modes are pinned out here.
      #
      # Refusing is one: the immutable-record check compares the existing
      # coordinate set (1 path) against the partition's (N), so it would raise
      # "different repository coordinates" and turn EVERY lock in such a
      # workspace into a lock-failure, blocking pushes.
      #
      # Overwriting is the other, and is worse than it looks: lock publication
      # is additions-only at the staging check AND at
      # ``verifyLockOnlyAheadChain`` ("additions-only, with NO exception"), so
      # the resulting ``M`` entry would be refused on this and every later
      # publish — wedging the store instead of repairing it.
      #
      # So: exit 0, the published record left byte-identical, and the operator
      # told plainly that this commit is not resolvable.
      let squatBody =
        "[[repo]]\nname = \"core\"\npath = \"core\"\nrevision = \"" &
          coreSha & "\"\n"
      removeFile(partitionPath)
      writeFile(partitionPath, squatBody)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " add -f -- locks")
      # Tolerated: "nothing to commit" when the file already held exactly this
      # body (the pre-fix shape). What matters is that the record is TRACKED —
      # that is what makes the immutability refusal apply to it — so assert
      # that rather than the commit's exit code.
      discard run(q(gitBin) & " -C " & q(manifestsRoot) & " commit -m squat")
      let tracked = run(q(gitBin) & " -C " & q(manifestsRoot) &
        " ls-files --error-unmatch -- " & q(partitionPath))
      check tracked.code == 0
      let relock = run(reproBinary & " workspace lock --workspace-root=" & q(ws))
      if relock.code != 0:
        checkpoint("re-lock over squatting record: " & relock.output)
      # Not a refusal: no "different repository coordinates" lock-failure.
      check relock.code == 0
      check not relock.output.contains("different repository coordinates")
      # Not an overwrite: the published record is byte-identical.
      check readFile(partitionPath) == squatBody
      # And the operator is told, not left to wonder why CI cannot resolve it.
      check relock.output.contains("participation record")
      check relock.output.contains("left untouched")
