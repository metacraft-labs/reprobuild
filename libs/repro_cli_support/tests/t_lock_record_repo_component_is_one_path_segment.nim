## RA-32 — the repo component of ``locks/<project>/<repo>/<sha>.toml`` is ONE
## path segment, whatever the repo is called.
##
## Why this test exists: ``GitCheckoutLockStore.putLock`` built the record's
## path by string-joining the store key straight into it
## (``"locks/" & project & "/" & repo & "/" & sha & ".toml"``). A repo whose
## NAME carries a slash — and the real workspace has twelve, because upstream
## forks are named the way GitHub names them (``stripe/sync-engine``,
## ``0install/0install``, ``microsoft/BuildXL``, ``llvm/llvm-project``) —
## therefore landed a record at DEPTH 5 where the format is depth 4:
##
##     locks/codetracer/stripe/sync-engine/<sha>.toml
##
## Everything downstream reads depth 4. The record was committed by ``putLock``
## and then permanently rejected by the publisher, so the manifest checkout
## accumulated commits that were unpublishable BY CONSTRUCTION: ``repro push``
## could not publish them and its own offered remedy (re-run the publish) could
## not clear them either, because re-running re-verifies the same chain. The
## branch had to be rebuilt by hand.
##
## The three halves this pins:
##
##   1. WRITE — the record for a slash-named repo lands at depth 4, at exactly
##      the path every reader and the ``git log -1 -- locks/<p>/<r>/`` subtree
##      query address, and the repo name round-trips out of it.
##   2. REFUSE AND REPORT — a record ALREADY at a non-canonical path is
##      refused by the publisher with a diagnostic that names it, and is never
##      relocated, deleted, or otherwise repaired from inside the push path.
##      An unrelated well-formed record beside it still publishes.
##   3. REPAIR ONLY WHEN ASKED — ``repro workspace migrate-locks`` plans the
##      relocation in full, proves the result would publish BEFORE moving a
##      single file, refuses as a whole otherwise, and is never invoked
##      implicitly.
##
## The ahead chain is additions-only with NO exception. An earlier revision
## carved out a migration exception here and drove it automatically from the
## publisher; that machinery is gone, and
## ``test_ra32_the_append_only_rule_has_no_exception`` pins its absence by
## re-running the two commit shapes the exception used to admit.
##
## Plus the traversal/reserved-name neighbours: a repo named ``../../etc`` must
## not be able to write outside ``locks/``.
##
## No mocks: this drives the real ``GitCheckoutLockStore`` against real ``git``
## checkouts on the real filesystem, which is the only place the write/verify
## disagreement is observable. Skipped when ``git`` is not on PATH (the same
## convention as the M9/M11/M17/M19 suites).

import std/[algorithm, options, os, osproc, sets, strutils, tables,
  tempfiles, unittest]

import repro_cli_support
import repro_lock_store
import repro_workspace_manifests
import git_tool

const
  triggerSha = "1111111111111111111111111111111111111111"

proc q(value: string): string = quoteShell(value)

proc git(gitBin: string; args: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(gitBin.q & " " & args, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(gitBin, args: string; cwd = "") =
  let res = git(gitBin, args, cwd)
  if res.code != 0:
    checkpoint("git " & args & " failed (" & $res.code & "):\n" & res.output)
    doAssert false

proc namedMigrateLocksCommands(message: string): seq[string] =
  ## The ``repro workspace migrate-locks …`` invocations a refusal tells the
  ## operator to run, parsed out of the single quotes it wraps them in. Naming
  ## a command is a promise that it runs; the caller keeps that promise honest
  ## by running exactly what was named.
  var i = 0
  while true:
    let a = message.find('\'', i)
    if a < 0: break
    let b = message.find('\'', a + 1)
    if b < 0: break
    let cmd = message[(a + 1) ..< b].strip()
    if cmd.startsWith("repro workspace migrate-locks") and cmd notin result:
      result.add(cmd)
    i = b + 1

proc identityFor(gitBin: string): GitToolIdentity =
  GitToolIdentity(binaryPath: gitBin, version: "test", platformOs: "test",
    platformCpu: "test", installMethod: "path")

proc routedBody(repoName, repoPath, revision: string): string =
  ## The minimal routed participation record shape the git-checkout backend
  ## stores (one ``[[repo]]`` coordinate, no full workspace-lock schema).
  "[[repo]]\n" &
  "name = \"" & repoName & "\"\n" &
  "path = \"" & repoPath & "\"\n" &
  "revision = \"" & revision & "\"\n"

type Fixture = object
  scratch: string
  origin: string
  store: string

proc newFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra32-" & slug & "-", "")
  result.origin = result.scratch / "origin.git"
  result.store = result.scratch / "manifests"
  requireGit(gitBin, "init --bare -b main " & q(result.origin))
  requireGit(gitBin, "clone " & q(result.origin) & " " & q(result.store))
  requireGit(gitBin, "-C " & q(result.store) &
    " config user.email tester@example.invalid")
  requireGit(gitBin, "-C " & q(result.store) & " config user.name \"RA32\"")
  writeFile(result.store / "README.md", "manifest store\n")
  requireGit(gitBin, "-C " & q(result.store) & " add README.md")
  requireGit(gitBin, "-C " & q(result.store) & " commit -q -m seed")
  requireGit(gitBin, "-C " & q(result.store) & " push -q origin main")

proc recordPaths(fx: Fixture): seq[string] =
  ## Every ``*.toml`` under ``locks/``, store-relative, forward slashes.
  let root = fx.store / "locks"
  if not dirExists(root): return
  for path in walkDirRec(root):
    if not path.endsWith(".toml"): continue
    var rel = path
    if rel.startsWith(fx.store): rel = rel[fx.store.len .. ^1]
    result.add(rel.strip(chars = {'/', '\\'}).replace('\\', '/'))
  result.sort()

proc writeStoreFile(fx: Fixture; rel, body: string) =
  let abs = fx.store / rel.replace('/', DirSep)
  createDir(parentDir(abs))
  writeFile(abs, body)

proc dropStoreFile(fx: Fixture; rel: string) =
  removeFile(fx.store / rel.replace('/', DirSep))

proc commitLocks(gitBin: string; fx: Fixture; message: string) =
  ## Commit whatever the test just did to ``locks/`` — including deletions —
  ## the way the old writer's own commits looked.
  requireGit(gitBin, "-C " & q(fx.store) & " add -f -A -- locks")
  requireGit(gitBin, "-C " & q(fx.store) & " commit -q -m " & q(message))

proc pushMain(gitBin: string; fx: Fixture) =
  requireGit(gitBin, "-C " & q(fx.store) & " push -q origin main")

proc remoteTomlPaths(gitBin: string; fx: Fixture): seq[string] =
  let ls = git(gitBin, "-C " & q(fx.origin) & " ls-tree -r --name-only main")
  doAssert ls.code == 0
  for raw in ls.output.splitLines():
    let p = raw.strip()
    if p.startsWith("locks/") and p.endsWith(".toml"): result.add(p)
  result.sort()

proc storeHead(gitBin: string; fx: Fixture; rev = "HEAD"): string =
  let res = git(gitBin, "-C " & q(fx.store) & " rev-parse " & rev)
  doAssert res.code == 0
  res.output.strip()

proc expectedFor(project, repo, repoPath, sha: string): ExpectedLockRecord =
  ExpectedLockRecord(project: project, repoName: repo, repoPath: repoPath,
    oid: sha, relPath: lockFileRepoRelativePath(project, repo, sha))

suite "RA-32 — a slash in a repo name must not deepen the lock path":

  test "test_ra32_slash_named_repo_records_at_depth_four":
    ## Before the fix this wrote ``locks/codetracer/stripe/sync-engine/<sha>.toml``
    ## — depth 5, a path the publisher rejects as "non-canonical lock record
    ## path" forever after.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newFixture(gitBin, "write")
      defer: removeDir(fx.scratch)
      let store = newGitCheckoutLockStore(identityFor(gitBin), fx.store)
      let put = store.putLock(StoreLockRecord(
        key: StoreLockKey(project: "codetracer", repo: "stripe/sync-engine",
          sha: triggerSha),
        body: routedBody("stripe/sync-engine",
          "isonim/references/stripe-sync-engine", triggerSha)))
      check put.outcome == spoOk

      let paths = recordPaths(fx)
      check paths.len == 1
      # The format is depth 4. Anything deeper is the defect.
      check paths[0].split('/').len == 4
      check paths[0] == lockFileRepoRelativePath("codetracer",
        "stripe/sync-engine", triggerSha)

      # The subtree the "latest published lock for repo X" query reads is a
      # prefix of the record's own path — that is what makes
      # ``git log -1 -- locks/<p>/<r>/`` a stable subtree.
      let subtree = lockRepoSubtreeRelativePath("codetracer",
        "stripe/sync-engine")
      check paths[0].startsWith(subtree)
      check subtree.strip(chars = {'/'}).split('/').len == 3

      # And the name round-trips back out of the path, so the reader can bind
      # the record to the repo it belongs to.
      let trig = parseTriggerFromLockRelPath(paths[0])
      check trig.repo == "stripe/sync-engine"
      check trig.sha == triggerSha

      # The commit-keyed read addresses the same path the writer landed on.
      let readBack = lockRecordAtCommit(store, "codetracer",
        "stripe/sync-engine", triggerSha)
      check readBack.isSome
      check readBack.get().key.repo == "stripe/sync-engine"

  test "test_ra32_slash_named_repo_publishes":
    ## The write landing at depth 4 is only half the claim: the publisher must
    ## also accept it. Before the fix this failed with
    ## ``non-canonical lock record path`` / ``unverified local backend state``.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newFixture(gitBin, "publish")
      defer: removeDir(fx.scratch)
      let store = newGitCheckoutLockStore(identityFor(gitBin), fx.store)
      check store.putLock(StoreLockRecord(
        key: StoreLockKey(project: "codetracer", repo: "stripe/sync-engine",
          sha: triggerSha),
        body: routedBody("stripe/sync-engine",
          "isonim/references/stripe-sync-engine", triggerSha))).outcome == spoOk
      let pub = store.publishPending()
      if pub.outcome != spoOk:
        checkpoint("publish diagnostic: " & pub.diagnostic)
      check pub.outcome == spoOk
      # It really reached the remote.
      let ls = git(gitBin, "-C " & q(fx.origin) & " ls-tree -r --name-only main")
      check ls.code == 0
      check ls.output.contains(lockFileRepoRelativePath("codetracer",
        "stripe/sync-engine", triggerSha))

  test "test_ra32_a_committed_noncanonical_record_is_refused_and_names_its_repair":
    ## The second half of the defect, and what replaced the publish-time
    ## migration that used to "repair" it silently.
    ##
    ## A record committed at the raw joined path — the shape the old writer
    ## left behind — sits in the ahead chain, and that chain is additions-only
    ## with NO exception, so the publish refuses. The refusal is correct and
    ## unavoidable: a branch push moves a ref and carries every commit with it,
    ## so there is no way to publish the healthy record and leave this one
    ## behind.
    ##
    ## What the publish owes the operator is therefore not a silent relocation
    ## — that mutated a shared store from inside the push path — but a refusal
    ## that NAMES the record and leaves a real route forward. Both halves are
    ## asserted here.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newFixture(gitBin, "refuse")
      defer: removeDir(fx.scratch)
      let legacyRel = "locks/codetracer/stripe/sync-engine/" &
        triggerSha & ".toml"
      writeStoreFile(fx, legacyRel, routedBody("stripe/sync-engine",
        "isonim/references/stripe-sync-engine", triggerSha))
      commitLocks(gitBin, fx, "lockstore: the old writer's joined path")
      # Deliberately NOT pushed. This is the wedge exactly as it occurred: an
      # unpublishable record inside commits that never left the machine.

      let identity = identityFor(gitBin)
      let otherSha = "2222222222222222222222222222222222222222"
      let store = newGitCheckoutLockStore(identity, fx.store)
      check store.putLock(StoreLockRecord(
        key: StoreLockKey(project: "codetracer", repo: "isonim",
          sha: otherSha),
        body: routedBody("isonim", "isonim", otherSha))).outcome == spoOk
      let pub = store.publishPending()
      checkpoint("publish: " & $pub.outcome & " :: " & pub.diagnostic)
      check pub.outcome != spoOk
      # It names the offending record rather than merely calling the state bad.
      check pub.diagnostic.contains(legacyRel)

      # Nothing was relocated, deleted, or otherwise repaired behind the
      # operator's back: at publish time this code is a READER of the store.
      let canonicalRel = lockFileRepoRelativePath("codetracer",
        "stripe/sync-engine", triggerSha)
      check fileExists(fx.store / legacyRel.replace('/', DirSep))
      check not fileExists(fx.store / canonicalRel.replace('/', DirSep))

      # And the route forward is real rather than merely advertised: the
      # explicit verb plans exactly this record's relocation.
      let plan = planLockRecordMigration(identity, fx.store)
      checkpoint("plan: " & $plan.ok & " :: " & plan.diagnostic)
      check plan.ok
      check plan.steps.len == 1
      check plan.steps[0].oldPath == legacyRel
      check plan.steps[0].target == canonicalRel

      # ...and "real" means the command the refusal PRINTS is the command that
      # runs. Parse it back out of the refusal's own text and dispatch it
      # VERBATIM through the CLI entry point — argv, parser and all — rather
      # than calling the planner the refusal does not name.
      #
      # This is the assertion the earlier tests could not make, because they
      # all entered at ``planLockRecordMigration`` and skipped the parser. The
      # parser seeded ``tpmUnspecified`` for tool provisioning, which
      # ``resolveGitTool`` rejects outright ("no provisioning mode was selected
      # before resolving git"), so the documented invocation exited 1 before
      # doing any work unless the operator also passed
      # ``--tool-provisioning=path`` — a flag neither the refusal nor
      # ``repro workspace --help`` mentions.
      let named = namedMigrateLocksCommands(pub.diagnostic)
      checkpoint("commands named: " & named.join(" | "))
      check named.len >= 1
      for cmd in named:
        let argv = cmd.splitWhitespace()
        check argv.len >= 3
        check argv[0 .. 2] == @["repro", "workspace", "migrate-locks"]
        let code = runWorkspaceMigrateLocksCommand(argv[3 .. ^1])
        checkpoint("`" & cmd & "` -> exit " & $code)
        check code == 0

  test "test_ra32_traversal_and_reserved_names_stay_inside_locks":
    ## A path component derived from a NAME is an injection surface. None of
    ## these may escape ``locks/<project>/``, and each must still round-trip.
    for name in ["../../etc", "..", ".", "a/../../b", "/leading",
                 "trailing/", "back\\slash", "CON", "NUL", "com1",
                 "dot.", "sp ace", "pct%2F", "uniçode"]:
      let rel = lockFileRepoRelativePath("proj", name, triggerSha)
      let parts = rel.split('/')
      checkpoint("name=" & name & " rel=" & rel)
      check parts.len == 4
      check parts[0] == "locks"
      check parts[1] == "proj"
      # One segment, and not a traversal or an absolute anchor.
      check parts[2].len > 0
      check parts[2] notin [".", ".."]
      check '/' notin parts[2]
      check '\\' notin parts[2]
      # Reversible: the reader recovers the exact name.
      check parseTriggerFromLockRelPath(rel).repo == name
      # Windows reserved device names must not be produced verbatim.
      let stem = parts[2].split('.')[0].toUpperAscii()
      check stem notin ["CON", "PRN", "AUX", "NUL", "COM1", "LPT1"]
      # No trailing dot or space (Windows silently strips both).
      check not parts[2].endsWith('.')
      check not parts[2].endsWith(' ')

  test "test_ra32_encoding_is_injective":
    ## The reason this is an ENCODING and not a sanitizer: two distinct repo
    ## names must never collide on one lock subtree, or repo A's revision
    ## becomes readable as repo B's.
    ##
    ## "Injective" here is over BYTE-DISTINCT segments. The encoder emits
    ## UPPERCASE hex and passes ``[A-Za-z]`` through literally, so two names
    ## that differ only in the case of their literal letters still collide on a
    ## CASE-INSENSITIVE filesystem (macOS, Windows). That hazard predates this
    ## encoding and is unchanged by it — ``Stripe`` and ``stripe`` were already
    ## one directory there — so it is stated, not claimed away.
    var seen = initTable[string, string]()
    for name in ["stripe/sync-engine", "stripe-sync-engine",
                 "stripe%2Fsync-engine", "stripe%2fsync-engine",
                 "Stripe/Sync-Engine", "a/b", "a-b", "a%2Db"]:
      let seg = encodeLockPathSegment(name)
      checkpoint("name=" & name & " segment=" & seg)
      check seg notin seen
      seen[seg] = name
      check decodeLockPathSegment(seg) == name
      check isCanonicalLockPathSegment(seg)

suite "RA-32 — refuse and report at publish; repair only when asked":

  test "test_ra32_a_stray_not_already_upstream_does_not_deny_publishing":
    ## The isolation claim, tested against the case the previous version of
    ## this suite avoided.
    ##
    ## That version pushed its stray to the remote BEFORE publishing, so the
    ## stray was never in the ahead chain and never in the index — it only ever
    ## exercised the passing case. The interesting stray is one that is NOT
    ## already upstream, because that is the one a blanket ``git add -f --
    ## locks`` sweeps into the index and turns into a staged addition the
    ## canonical-additions check then refuses, denying publication to every
    ## repo in the workspace.
    ##
    ## So: strays that exist only here, never pushed, never committed. A
    ## record-shaped one, a non-record one, and one at a non-canonical depth.
    ## The publish stages by PATH, so none of them can reach the index.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newFixture(gitBin, "stray")
      defer: removeDir(fx.scratch)
      let strays = ["locks/NOTES.toml", "locks/README.md",
                    "locks/codetracer/stripe%2fsync-engine/" &
                      triggerSha & ".toml"]
      for stray in strays:
        writeStoreFile(fx, stray, "not a lock record\n")

      let otherSha = "2222222222222222222222222222222222222222"
      let store = newGitCheckoutLockStore(identityFor(gitBin), fx.store)
      check store.putLock(StoreLockRecord(
        key: StoreLockKey(project: "codetracer", repo: "isonim",
          sha: otherSha),
        body: routedBody("isonim", "isonim", otherSha))).outcome == spoOk
      let pub = store.publishPending()
      checkpoint("publish: " & $pub.outcome & " :: " & pub.diagnostic)
      check pub.outcome == spoOk

      # The healthy record reached the remote...
      check remoteTomlPaths(gitBin, fx) ==
        @[lockFileRepoRelativePath("codetracer", "isonim", otherSha)]
      for stray in strays:
        # ...and every stray is still exactly where the operator left it,
        # still untracked, and still absent from the remote.
        check fileExists(fx.store / stray.replace('/', DirSep))
        let tracked = git(gitBin, "-C " & q(fx.store) &
          " ls-files --error-unmatch -- " & q(stray))
        check tracked.code != 0
        let ls = git(gitBin, "-C " & q(fx.origin) &
          " ls-tree -r --name-only main")
        check ls.code == 0
        check not ls.output.contains(stray)

  test "test_ra32_a_conflicting_twin_does_not_deny_unrelated_publishing":
    ## Two spellings of one record with DIFFERENT bodies, already published.
    ## Which body survives is a human's decision about those two files; it is
    ## not a reason to stop an unrelated healthy record from reaching the
    ## remote, and — since nothing relocates anything any more — it is not a
    ## reason for the publish to touch either file.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newFixture(gitBin, "conflict")
      defer: removeDir(fx.scratch)
      let legacyRel = "locks/codetracer/stripe/sync-engine/" &
        triggerSha & ".toml"
      let legacyBody = routedBody("stripe/sync-engine",
        "isonim/references/stripe-sync-engine", triggerSha)
      let canonicalRel = lockFileRepoRelativePath("codetracer",
        "stripe/sync-engine", triggerSha)
      writeStoreFile(fx, legacyRel, legacyBody)
      writeStoreFile(fx, canonicalRel,
        routedBody("stripe/sync-engine", "references/stripe-sync-engine",
          triggerSha))
      commitLocks(gitBin, fx, "lockstore: two spellings, different bodies")
      pushMain(gitBin, fx)

      let otherSha = "2222222222222222222222222222222222222222"
      let store = newGitCheckoutLockStore(identityFor(gitBin), fx.store)
      check store.putLock(StoreLockRecord(
        key: StoreLockKey(project: "codetracer", repo: "isonim",
          sha: otherSha),
        body: routedBody("isonim", "isonim", otherSha))).outcome == spoOk
      let pub = store.publishPending()
      checkpoint("publish: " & $pub.outcome & " :: " & pub.diagnostic)
      check pub.outcome == spoOk
      check remoteTomlPaths(gitBin, fx).contains(
        lockFileRepoRelativePath("codetracer", "isonim", otherSha))
      # Neither conflicting file was touched.
      check readFile(fx.store / legacyRel.replace('/', DirSep)) == legacyBody

      # The repair verb refuses this pair as a whole rather than guessing, and
      # says why — a published record is immutable.
      let plan = planLockRecordMigration(identityFor(gitBin), fx.store)
      check not plan.ok
      check plan.diagnostic.contains(legacyRel)

  test "test_ra32_publish_never_moves_or_deletes_anything":
    ## The publish path writes canonical records and commits them. It never
    ## moves a file, never deletes one, and never rewrites a branch. The
    ## withdrawn migration did all three, from inside the push path.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newFixture(gitBin, "readonly")
      defer: removeDir(fx.scratch)
      # One legacy record tracked and PUSHED, one only on disk and untracked.
      let publishedLegacy = "locks/codetracer/stripe/sync-engine/" &
        triggerSha & ".toml"
      let legacyBody = routedBody("stripe/sync-engine",
        "isonim/references/stripe-sync-engine", triggerSha)
      writeStoreFile(fx, publishedLegacy, legacyBody)
      commitLocks(gitBin, fx, "lockstore: legacy record")
      pushMain(gitBin, fx)
      let untrackedLegacy = "locks/codetracer/llvm/llvm-project/" &
        triggerSha & ".toml"
      writeStoreFile(fx, untrackedLegacy,
        routedBody("llvm/llvm-project", "references/llvm-project", triggerSha))
      let headBefore = storeHead(gitBin, fx)

      discard publishWorkspaceLock(identityFor(gitBin), fx.store, @[])

      # Both files are exactly where they were, with their original bytes, and
      # no canonical twin was conjured for either.
      check readFile(fx.store / publishedLegacy.replace('/', DirSep)) ==
        legacyBody
      check fileExists(fx.store / untrackedLegacy.replace('/', DirSep))
      check not fileExists(fx.store / lockFileRepoRelativePath("codetracer",
        "stripe/sync-engine", triggerSha).replace('/', DirSep))
      check not fileExists(fx.store / lockFileRepoRelativePath("codetracer",
        "llvm/llvm-project", triggerSha).replace('/', DirSep))
      # And no commit was made on the operator's behalf.
      check storeHead(gitBin, fx) == headBefore

  test "test_ra32_the_append_only_rule_has_no_exception":
    ## The simplification this change is really about.
    ##
    ## The ahead chain used to be "additions-only, EXCEPT a migration commit",
    ## and the exception carried its own sub-rules: one deletion per commit,
    ## identical blob, canonical target added-or-already-present, no N-into-1
    ## collapse, no re-addition after the relocation. Every one of those was a
    ## way to get a deletion past the verifier.
    ##
    ## There is now no exception at all. The first two blocks below are the
    ## exact shapes the exception used to ADMIT — they published before, and
    ## must be refused now. The last two always failed and still do. What is
    ## being pinned is that "is there a D in this chain?" is the whole rule.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let identity = identityFor(gitBin)
      let legacyRel = "locks/codetracer/stripe/sync-engine/" &
        triggerSha & ".toml"
      let canonicalRel = lockFileRepoRelativePath("codetracer",
        "stripe/sync-engine", triggerSha)
      let body = routedBody("stripe/sync-engine",
        "isonim/references/stripe-sync-engine", triggerSha)
      let expectedCanonical = expectedFor("codetracer", "stripe/sync-engine",
        "isonim/references/stripe-sync-engine", triggerSha)

      block relocationWithIdenticalBlob:
        # D <non-canonical> + A <canonical>, identical bytes. The exception's
        # headline case.
        let fx = newFixture(gitBin, "d-relocate")
        defer: removeDir(fx.scratch)
        writeStoreFile(fx, legacyRel, body)
        commitLocks(gitBin, fx, "lockstore: legacy")
        pushMain(gitBin, fx)
        let remoteBefore = remoteTomlPaths(gitBin, fx)
        dropStoreFile(fx, legacyRel)
        writeStoreFile(fx, canonicalRel, body)
        commitLocks(gitBin, fx, "relocate the record")
        let pub = publishWorkspaceLock(identity, fx.store, @[expectedCanonical])
        checkpoint("relocation: " & $pub.outcome & " :: " & pub.diagnostic)
        check pub.outcome == lpoFailed
        check pub.diagnostic.contains("additions-only")
        check remoteTomlPaths(gitBin, fx) == remoteBefore

      block bareDeletionWithTwinPresent:
        # D <non-canonical> ALONE, the canonical twin already in the tree. The
        # exception's second admitted shape, and the one whose earlier refusal
        # wedged a store AFTER the deletion had been committed.
        let fx = newFixture(gitBin, "d-bare")
        defer: removeDir(fx.scratch)
        writeStoreFile(fx, legacyRel, body)
        writeStoreFile(fx, canonicalRel, body)
        commitLocks(gitBin, fx, "lockstore: legacy plus canonical twin")
        pushMain(gitBin, fx)
        let remoteBefore = remoteTomlPaths(gitBin, fx)
        dropStoreFile(fx, legacyRel)
        commitLocks(gitBin, fx, "drop the redundant legacy record")
        let pub = publishWorkspaceLock(identity, fx.store, @[expectedCanonical])
        checkpoint("bare deletion: " & $pub.outcome & " :: " & pub.diagnostic)
        check pub.outcome == lpoFailed
        check pub.diagnostic.contains("additions-only")
        check remoteTomlPaths(gitBin, fx) == remoteBefore

      block deletionOfACanonicalRecord:
        # A canonical record is immutable history. Deleting one was never
        # permitted and still is not.
        let fx = newFixture(gitBin, "d-canonical")
        defer: removeDir(fx.scratch)
        writeStoreFile(fx, canonicalRel, body)
        commitLocks(gitBin, fx, "lockstore: canonical record")
        pushMain(gitBin, fx)
        let remoteBefore = remoteTomlPaths(gitBin, fx)
        dropStoreFile(fx, canonicalRel)
        commitLocks(gitBin, fx, "delete a published record")
        let pub = publishWorkspaceLock(identity, fx.store, @[expectedCanonical])
        checkpoint("canonical deletion: " & $pub.outcome & " :: " &
          pub.diagnostic)
        check pub.outcome == lpoFailed
        check remoteTomlPaths(gitBin, fx) == remoteBefore

      block twoDeletionsOntoOneAddition:
        # Two spellings decode to ONE canonical path, so collapsing them in a
        # single commit would let one record vanish from a chain that verified.
        let fx = newFixture(gitBin, "d-collapse")
        defer: removeDir(fx.scratch)
        let otherSpelling = "locks/%63odetracer/stripe/sync-engine/" &
          triggerSha & ".toml"
        writeStoreFile(fx, legacyRel, body)
        writeStoreFile(fx, otherSpelling, body)
        commitLocks(gitBin, fx, "lockstore: two spellings")
        pushMain(gitBin, fx)
        let remoteBefore = remoteTomlPaths(gitBin, fx)
        dropStoreFile(fx, legacyRel)
        dropStoreFile(fx, otherSpelling)
        writeStoreFile(fx, canonicalRel, body)
        commitLocks(gitBin, fx, "collapse two spellings onto one")
        let pub = publishWorkspaceLock(identity, fx.store, @[expectedCanonical])
        checkpoint("collapse: " & $pub.outcome & " :: " & pub.diagnostic)
        check pub.outcome == lpoFailed
        check remoteTomlPaths(gitBin, fx) == remoteBefore

  test "test_ra32_a_refused_publish_never_unstages_the_operators_own_work":
    ## Regression: ``git reset --quiet HEAD --`` with an EMPTY pathspec is not
    ## a no-op. Git reads "no pathspec" and performs a FULL mixed reset, so the
    ## publish's own tidy-up — unstage exactly what I staged — silently threw
    ## away whatever the operator had staged, in a store where the publish had
    ## staged nothing at all.
    ##
    ## Construct precisely that: nothing for the publish to stage (no new
    ## canonical record), the operator holding a staged file, and a refusal
    ## that runs the tidy-up.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newFixture(gitBin, "unstage")
      defer: removeDir(fx.scratch)
      writeStoreFile(fx, "locks/NOTES.toml", "operator notes\n")
      requireGit(gitBin, "-C " & q(fx.store) & " add -f -- " &
        q("locks/NOTES.toml"))
      # Dirty OUTSIDE locks/, so the publish refuses and runs its tidy-up.
      writeFile(fx.store / "UNRELATED.md", "unrelated work\n")
      requireGit(gitBin, "-C " & q(fx.store) & " add -f -- " & q("UNRELATED.md"))

      let pub = publishWorkspaceLock(identityFor(gitBin), fx.store, @[])
      checkpoint("publish: " & $pub.outcome & " :: " & pub.diagnostic)
      check pub.outcome == lpoRefusedDirty

      # The operator's staged work is still staged. Before the guard, both of
      # these were silently unstaged by a publish that had staged nothing.
      let staged = git(gitBin, "-C " & q(fx.store) &
        " diff --cached --name-only")
      check staged.code == 0
      check staged.output.contains("locks/NOTES.toml")
      check staged.output.contains("UNRELATED.md")

  test "test_ra32_migrate_locks_refuses_a_canonical_path_that_cannot_publish":
    ## Regression: a canonical PATH is not the same thing as a publishable
    ## RECORD. ``locks/<p>/<r>/NOTES.toml`` decodes cleanly and sits at depth
    ## four, but its filename stem is not an object id, so the publisher
    ## refuses it wherever it sits.
    ##
    ## The repair rebuilds the unpublished commits, so it would have re-added
    ## this file and produced a chain it already knew would never publish —
    ## manufacturing a fresh wedge in the act of clearing one. It must refuse
    ## the plan instead, and move nothing.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newFixture(gitBin, "unpublishable")
      defer: removeDir(fx.scratch)
      let repairable = "locks/codetracer/stripe/sync-engine/" &
        triggerSha & ".toml"
      let canonicalButNotARecord = "locks/codetracer/isonim/NOTES.toml"
      writeStoreFile(fx, repairable, routedBody("stripe/sync-engine",
        "isonim/references/stripe-sync-engine", triggerSha))
      writeStoreFile(fx, canonicalButNotARecord, "notes, not a record\n")
      commitLocks(gitBin, fx, "lockstore: a record and a canonical non-record")
      let headBefore = storeHead(gitBin, fx)

      # It really does sit at a canonical path — that is the whole point.
      check parseLockRecordRelPath(canonicalButNotARecord).ok

      let plan = planLockRecordMigration(identityFor(gitBin), fx.store)
      checkpoint("plan: " & $plan.ok & " :: " & plan.diagnostic)
      check not plan.ok
      check plan.diagnostic.contains(canonicalButNotARecord)
      check plan.steps.len == 0
      # Nothing moved, including the record that was repairable on its own.
      check fileExists(fx.store / repairable.replace('/', DirSep))
      check storeHead(gitBin, fx) == headBefore

  test "test_ra32_migrate_locks_plans_without_touching_the_store":
    ## The repair is a separate verb, and its planning half is read-only. A
    ## dry run must be a safe thing to run on a store you do not yet
    ## understand.
    ##
    ## The tracked non-records committed alongside are the blast-radius guard:
    ## a ``.toml`` with no project/repo structure to derive a canonical path
    ## from is the operator's file, and the plan must neither claim it nor
    ## refuse the whole store over it. Relocating files that were never
    ## records is precisely what the withdrawn migration did.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newFixture(gitBin, "plan")
      defer: removeDir(fx.scratch)
      let legacyRel = "locks/codetracer/stripe/sync-engine/" &
        triggerSha & ".toml"
      let body = routedBody("stripe/sync-engine",
        "isonim/references/stripe-sync-engine", triggerSha)
      writeStoreFile(fx, legacyRel, body)
      writeStoreFile(fx, "locks/NOTES.toml", "operator notes\n")
      writeStoreFile(fx, "locks/codetracer/NOTES.toml", "more notes\n")
      writeStoreFile(fx, "locks/README.md", "read me\n")
      commitLocks(gitBin, fx, "lockstore: legacy record plus operator files")
      let headBefore = storeHead(gitBin, fx)

      let plan = planLockRecordMigration(identityFor(gitBin), fx.store)
      checkpoint("plan: " & $plan.ok & " :: " & plan.diagnostic)
      check plan.ok
      check plan.steps.len == 1
      check plan.steps[0].target == lockFileRepoRelativePath("codetracer",
        "stripe/sync-engine", triggerSha)
      check renderLockMigrationPlan(plan).len > 0

      # The operator's files are named as things the rebuild will leave
      # behind, and are never claimed as relocation subjects.
      for step in plan.steps:
        check step.oldPath notin ["locks/NOTES.toml",
          "locks/codetracer/NOTES.toml", "locks/README.md"]
      for path in ["locks/NOTES.toml", "locks/codetracer/NOTES.toml",
                   "locks/README.md"]:
        check path in plan.orphans

      # Planned, not performed.
      check readFile(fx.store / legacyRel.replace('/', DirSep)) == body
      check not fileExists(fx.store / plan.steps[0].target.replace('/', DirSep))
      check storeHead(gitBin, fx) == headBefore

  test "test_ra32_migrate_locks_refuses_as_a_whole_before_the_first_move":
    ## Plan fully, THEN move — never move-then-discover. Two records need
    ## relocating and one of them can never publish wherever it sits (its
    ## filename stem is not a full object id, which the publisher requires).
    ## The repairable one must not be moved either: a partially repaired store
    ## is a new state whose own remedy has to be invented, which is precisely
    ## the failure mode being designed out.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newFixture(gitBin, "refuse-whole")
      defer: removeDir(fx.scratch)
      let repairable = "locks/codetracer/stripe/sync-engine/" &
        triggerSha & ".toml"
      let unrepairable = "locks/codetracer/llvm/llvm-project/abc123.toml"
      writeStoreFile(fx, repairable, routedBody("stripe/sync-engine",
        "isonim/references/stripe-sync-engine", triggerSha))
      writeStoreFile(fx, unrepairable,
        routedBody("llvm/llvm-project", "references/llvm-project", "abc123"))
      commitLocks(gitBin, fx, "lockstore: one repairable, one not")
      let headBefore = storeHead(gitBin, fx)

      let identity = identityFor(gitBin)
      let plan = planLockRecordMigration(identity, fx.store)
      checkpoint("plan: " & $plan.ok & " :: " & plan.diagnostic)
      check not plan.ok
      check plan.diagnostic.contains(unrepairable)
      check plan.steps.len == 0

      # Applying a refused plan is a no-op, not a partial repair.
      let applied = applyLockRecordMigration(identity, fx.store, plan)
      check not applied.ok

      # NOTHING moved — including the record that was individually fine.
      check fileExists(fx.store / repairable.replace('/', DirSep))
      check fileExists(fx.store / unrepairable.replace('/', DirSep))
      check not fileExists(fx.store / lockFileRepoRelativePath("codetracer",
        "stripe/sync-engine", triggerSha).replace('/', DirSep))
      check storeHead(gitBin, fx) == headBefore

  test "test_ra32_migrate_locks_repairs_and_the_result_publishes":
    ## End to end: the wedge, the explicit repair, and a publish that then
    ## succeeds through the ordinary path with no exception anywhere.
    ##
    ## The repair is a rebuild of the UNPUBLISHED commits, not a move committed
    ## on top — a commit carrying a deletion could not publish. So the chain
    ## the publisher finally verifies is additions-only, which is the whole
    ## point.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newFixture(gitBin, "repair")
      defer: removeDir(fx.scratch)
      let legacyRel = "locks/codetracer/stripe/sync-engine/" &
        triggerSha & ".toml"
      let canonicalRel = lockFileRepoRelativePath("codetracer",
        "stripe/sync-engine", triggerSha)
      let body = routedBody("stripe/sync-engine",
        "isonim/references/stripe-sync-engine", triggerSha)
      writeStoreFile(fx, legacyRel, body)
      commitLocks(gitBin, fx, "lockstore: the old writer's joined path")

      let identity = identityFor(gitBin)
      let plan = planLockRecordMigration(identity, fx.store)
      check plan.ok
      let applied = applyLockRecordMigration(identity, fx.store, plan)
      checkpoint("apply: " & $applied.ok & " :: " & applied.diagnostic)
      check applied.ok

      # The record moved, byte-identically, and the mis-shaped subtree is gone.
      check readFile(fx.store / canonicalRel.replace('/', DirSep)) == body
      check not fileExists(fx.store / legacyRel.replace('/', DirSep))
      check not dirExists(fx.store /
        "locks/codetracer/stripe".replace('/', DirSep))

      # The rebuilt chain is additions-only relative to the upstream, so an
      # ordinary publish now carries the repaired record out.
      let otherSha = "2222222222222222222222222222222222222222"
      let store = newGitCheckoutLockStore(identity, fx.store)
      check store.putLock(StoreLockRecord(
        key: StoreLockKey(project: "codetracer", repo: "isonim",
          sha: otherSha),
        body: routedBody("isonim", "isonim", otherSha))).outcome == spoOk
      let pub = store.publishPending()
      checkpoint("publish: " & $pub.outcome & " :: " & pub.diagnostic)
      check pub.outcome == spoOk

      let remote = remoteTomlPaths(gitBin, fx)
      check remote.contains(canonicalRel)
      check remote.contains(
        lockFileRepoRelativePath("codetracer", "isonim", otherSha))
      check not remote.contains(legacyRel)

      # Idempotent: a second dry run finds nothing left to do.
      let again = planLockRecordMigration(identity, fx.store)
      check again.ok
      check again.steps.len == 0
      check lockMigrationNothingToDo(again)

  test "test_ra32_migrate_locks_refuses_an_already_published_record":
    ## The one state the repair will not touch. Rebuilding unpublished commits
    ## is safe because nothing shared depends on them; a record that HAS
    ## reached the remote is immutable, and removing it would need a
    ## coordinated rewrite of history other people have cloned. Refuse, name
    ## the record, and say so — do not quietly rewrite shared history.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newFixture(gitBin, "published")
      defer: removeDir(fx.scratch)
      let legacyRel = "locks/codetracer/stripe/sync-engine/" &
        triggerSha & ".toml"
      let body = routedBody("stripe/sync-engine",
        "isonim/references/stripe-sync-engine", triggerSha)
      writeStoreFile(fx, legacyRel, body)
      commitLocks(gitBin, fx, "lockstore: legacy record")
      pushMain(gitBin, fx)
      let headBefore = storeHead(gitBin, fx)

      let identity = identityFor(gitBin)
      let plan = planLockRecordMigration(identity, fx.store)
      checkpoint("plan: " & $plan.ok & " :: " & plan.diagnostic)
      check not plan.ok
      check plan.diagnostic.contains(legacyRel)
      check plan.diagnostic.contains("ALREADY PUBLISHED")
      # Untouched, and the branch is exactly where it was.
      check readFile(fx.store / legacyRel.replace('/', DirSep)) == body
      check storeHead(gitBin, fx) == headBefore

  test "test_ra32_every_locks_project_reader_reads_the_encoded_component":
    ## Defect D. The change began ENCODING the project component while three
    ## readers kept joining it raw:
    ## ``latestLockShasViaGit`` and ``latestLockAny`` (``"locks/" & project &
    ## "/"``) and ``resolveCoherenceLayerRoot`` (``"locks" / project``). For any
    ## project name outside ``[A-Za-z0-9._-]`` the "latest lock" query silently
    ## returned EMPTY, so ``repro check`` stage 5 and ``repro workspace status``
    ## saw no lock at all — a new writer/reader divergence of exactly the kind
    ## this change exists to remove.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let project = "team/alpha"
      let fx = newFixture(gitBin, "reader")
      defer: removeDir(fx.scratch)
      let store = newGitCheckoutLockStore(identityFor(gitBin), fx.store)
      check store.putLock(StoreLockRecord(
        key: StoreLockKey(project: project, repo: "isonim", sha: triggerSha),
        body: routedBody("isonim", "isonim", triggerSha))).outcome == spoOk

      # latestLockAny — the newest record across every repo of the project.
      let any = store.latestLockAny(project)
      check any.isSome
      if any.isSome:
        check any.get().key.repo == "isonim"
        check any.get().key.sha == triggerSha

      # latestLockShas — `repro check` stage 5 / `repro workspace status`.
      let shas = store.latestLockShas(project)
      check shas.shas.getOrDefault("isonim") == triggerSha
      check shas.lockKey.repo == "isonim"

      # resolveCoherenceLayerRoot — reached only through `lockCoherenceFor`.
      # A claim for a repo with no checkout is interrupting, so a resolved
      # layer root is observable as a finding and an unresolved one as none.
      let ws = fx.scratch / "ws"
      createDir(ws)
      let dbRel = lockFileRepoRelativePath(project, "isonim", triggerSha)
      let dbAbs = ws / ".repro" / "manifests" / dbRel.replace('/', DirSep)
      createDir(parentDir(dbAbs))
      writeFile(dbAbs, routedBody("isonim", "isonim", triggerSha))
      let report = lockCoherenceFor(identityFor(gitBin), ws, project,
        @[(name: "isonim", path: "isonim")])
      checkpoint("coherence findings: " & $report.findings.len)
      check report.findings.len == 1

  test "test_ra32_sibling_backends_keep_every_component_inside_the_store":
    ## Defect D, second half. The two sibling backends raw-joined every
    ## component, and ``CommittedFileLockStore``'s record path with
    ## ``repo == ".."`` wrote ``baseDir/locks/<project>/../<sha>.rec`` — the live
    ## traversal that drove this change's severity, in a backend the first round
    ## left untouched. Both now key through the same encoder, so a name can
    ## neither traverse nor deepen the path.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra32-siblings-", "")
      try:
        let body = routedBody("stripe/sync-engine",
          "isonim/references/stripe-sync-engine", triggerSha)

        let cfRoot = scratch / "committed-file"
        let cf = newCommittedFileLockStore(cfRoot)
        # A traversal name is refused outright, and writes nothing.
        for hostile in ["..", ".", "a/../../b", "/leading", "back\\slash"]:
          checkpoint("hostile repo name: " & hostile)
          check cf.putLock(StoreLockRecord(
            key: StoreLockKey(project: "codetracer", repo: hostile,
              sha: triggerSha), body: body)).outcome == spoFailed
        check not dirExists(cfRoot / "locks")

        # A forge-shaped name is accepted, stays one component, round-trips.
        check cf.putLock(StoreLockRecord(
          key: StoreLockKey(project: "codetracer", repo: "stripe/sync-engine",
            sha: triggerSha), body: body)).outcome == spoOk
        let got = cf.latestLock("codetracer", "stripe/sync-engine")
        check got.isSome
        if got.isSome:
          check got.get().key.repo == "stripe/sync-engine"
          check got.get().body == body
        # Nothing landed outside the project's own subtree.
        let projDir = cfRoot / "locks" / "codetracer"
        for path in walkDirRec(cfRoot):
          checkpoint("committed-file wrote: " & path)
          check path.startsWith(projDir)
          check "/../" notin path.replace('\\', '/')

        # Same for the separate-branch backend, whose paths live in a tree
        # object rather than on disk.
        let sbRoot = scratch / "separate-branch"
        createDir(sbRoot)
        requireGit(gitBin, "init -q -b main " & q(sbRoot))
        requireGit(gitBin, "-C " & q(sbRoot) &
          " config user.email tester@example.invalid")
        requireGit(gitBin, "-C " & q(sbRoot) & " config user.name \"RA32\"")
        let sb = newSeparateBranchLockStore(gitBin, sbRoot)
        check sb.putLock(StoreLockRecord(
          key: StoreLockKey(project: "codetracer", repo: "..",
            sha: triggerSha), body: body)).outcome == spoFailed
        check sb.putLock(StoreLockRecord(
          key: StoreLockKey(project: "codetracer", repo: "stripe/sync-engine",
            sha: triggerSha), body: body)).outcome == spoOk
        let sbGot = sb.latestLock("codetracer", "stripe/sync-engine")
        check sbGot.isSome
        if sbGot.isSome:
          check sbGot.get().key.repo == "stripe/sync-engine"
        let tree = git(gitBin, "-C " & q(sbRoot) &
          " ls-tree -r --name-only " & separateBranchRef)
        check tree.code == 0
        var sawRecord = false
        for raw in tree.output.splitLines():
          let p = raw.strip()
          if p.len == 0: continue
          checkpoint("separate-branch wrote: " & p)
          # The record is depth 4; the per-project ``HEAD`` pointer is depth 3.
          check p.startsWith("locks/codetracer/")
          check p.split('/').len in {3, 4}
          if p.endsWith(".rec"):
            sawRecord = true
            check p == "locks/codetracer/" &
              encodeLockPathSegment("stripe/sync-engine") & "/" &
              triggerSha & ".rec"
        check sawRecord
      finally:
        removeDir(scratch)
