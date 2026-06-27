## Workspace-Manifest-Optional MO-9 — the pre-push gate and ``repro sync``
## consume ``LockedDependencies`` from ``populateLockedDeps`` and behave
## IDENTICALLY regardless of which source supplied a repo's locked entry.
##
## Two source-agnostic behaviors are asserted:
##
##   * GATE verifies observed content against the locked INTEGRITY. The unified
##     ``verifyLockedIntegrityAtCoordinates`` recomputes each dependency's
##     multihash at its locked coordinates and compares to the locked value. We
##     build the SAME repo's locked entry from BOTH a committed-lock source and
##     a store source and show: on an untampered lock the verifier passes for
##     both; tampering the integrity makes it REFUSE for both. Source-agnostic +
##     falsifiable (the tamper is detected only because the gate verifies the
##     populated integrity, not live HEAD).
##
##   * SYNC fetches to the locked COORDINATES. ``repro workspace sync --dry-run``
##     plans the repo at the lock's recorded revision (not live ``git HEAD``),
##     and the committed-lock and store sources populate the SAME coordinate
##     revision — so sync would target the same coordinates regardless of source.
##
## The end-to-end gate/sync legs drive the built ``./build/bin/repro`` (the real
## gate consumes ``populateLockedDeps`` in its committed-lock path); when the
## binary is absent those legs are skipped while the direct source-agnostic
## verification still runs.
##
## Hermetic: fresh tempdirs only. Skip rule: ``git`` missing on PATH.

import std/[json, options, os, osproc, strutils, tables, unittest]

import repro_cli_support
import repro_lock_store
import repro_lock
import repro_workspace_manifests
import git_tool

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

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc initGitRepoWithCommit(gitBin, path: string): string =
  createDir(path)
  discard run(q(gitBin) & " init -q -b main " & q(path))
  discard run(q(gitBin) & " -C " & q(path) & " config user.email t@e.invalid")
  discard run(q(gitBin) & " -C " & q(path) & " config user.name Tester")
  writeFile(path / "seed.txt", "seed\n")
  discard run(q(gitBin) & " -C " & q(path) & " add seed.txt")
  discard run(q(gitBin) & " -C " & q(path) & " commit -qm seed")
  run(q(gitBin) & " -C " & q(path) & " rev-parse HEAD").output.strip()

proc recordBody(repoPath, sha: string): string =
  "[[repo]]\npath = \"" & repoPath & "\"\nrevision = \"" & sha & "\"\n"

suite "MO-9 — gate + sync consume the unified locked deps regardless of source":

  test "t_gate_and_sync_consume_unified_locked_deps_regardless_of_source":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let ws = getTempDir() / "mo9-agnostic-" & $getCurrentProcessId()
      removeDir(ws)
      createDir(ws)
      defer: removeDir(ws)

      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      # A real git checkout whose locked revision is its genuine HEAD object.
      let appDir = ws / "app"
      let appSha = initGitRepoWithCommit(gitBin, appDir)
      let appUrl = "https://example.invalid/app.git"
      let goodIntegrity = gitObjectMultihash("sha1", appSha)
      let badIntegrity = "git-sha1:dead0000dead0000dead0000dead0000dead0000"

      # ---- Build the SAME locked entry from two sources --------------------
      # Source 1: a committed lock (path "." anchored at the repo root).
      proc lockLdWith(integrity: string): LockedDependencies =
        LockedDependencies(schema: SolvedGraphLockSchemaV2, deps: @[
          LockedDep(name: "app", path: ".",
            coordinates: Coordinates(kind: ckVcs, url: appUrl, gitRef: "main",
              revision: appSha),
            integrity: integrity, visibility: "public")])

      # Source 2: a store (DB) source. Record the SAME revision in a store and
      # populate; coordinates anchor at workspace-relative path "app".
      let dbStore: LockStore = newCommittedFileLockStore(ws / "extdb")
      let put = dbStore.putLock(StoreLockRecord(
        key: StoreLockKey(project: "demo", repo: "app", sha: appSha),
        body: recordBody("app", appSha)))
      doAssert put.outcome == spoOk, put.diagnostic
      let appResolved = ResolvedRepo(name: "app", path: "app",
        remoteName: "origin", fetchUrl: appUrl, revision: "main",
        visibility: wvPublic)
      let storeLd = populateLockedDeps(LockSource(kind: lskExternalStore,
        workspaceRoot: ws, projectName: "demo", repos: @[appResolved],
        store: dbStore))

      # Both sources populate the SAME locked revision (sync targets coordinates
      # source-agnostically).
      check storeLd.deps.len == 1
      check storeLd.deps[0].coordinates.revision == appSha
      check storeLd.deps[0].integrity == goodIntegrity   # git-native, identical

      # ---- GATE integrity verification is source-agnostic ------------------
      # Untampered: both the committed-lock-sourced and store-sourced models
      # PASS (the locked revision's object is present and its integrity matches).
      check verifyLockedIntegrityAtCoordinates(appDir, lockLdWith(goodIntegrity)).len == 0
      check verifyLockedIntegrityAtCoordinates(ws, storeLd).len == 0

      # Tampered integrity: the gate REFUSES for BOTH sources (identical
      # behavior). This is the load-bearing falsifiable check — the mismatch is
      # caught only because the gate verifies the POPULATED locked integrity.
      let lockFail = verifyLockedIntegrityAtCoordinates(appDir, lockLdWith(badIntegrity))
      check lockFail.len == 1
      check lockFail[0].expected == badIntegrity
      check lockFail[0].observed == goodIntegrity

      var tamperedStoreLd = storeLd
      tamperedStoreLd.deps[0].integrity = badIntegrity
      let storeFail = verifyLockedIntegrityAtCoordinates(ws, tamperedStoreLd)
      check storeFail.len == 1
      check storeFail[0].expected == badIntegrity

      # A locked coordinate whose object is missing/unreachable also fails.
      var missingLd = lockLdWith(goodIntegrity)
      missingLd.deps[0].coordinates.revision =
        "abc1230000000000000000000000000000000000"
      missingLd.deps[0].integrity =
        "git-sha1:abc1230000000000000000000000000000000000"
      check verifyLockedIntegrityAtCoordinates(appDir, missingLd).len == 1

      # ---- End-to-end: the REAL gate + sync consume the populated model ----
      if not fileExists(reproBinary):
        skip()
      else:
        # A committed-lock-only workspace: clone with a seed commit so the lock
        # pins a git-native revision, then refresh + commit the lock.
        let origin = ws / "origin.git"
        discard run(q(gitBin) & " init -q --bare -b main " & q(origin))
        let seed = ws / "seed"
        discard run(q(gitBin) & " init -q -b main " & q(seed))
        discard git(gitBin, seed, "config user.email t@e.invalid")
        discard git(gitBin, seed, "config user.name Tester")
        writeFile(seed / "README.md", "mo9\n")
        discard git(gitBin, seed, "add README.md")
        discard git(gitBin, seed, "commit -qm seed")
        discard git(gitBin, seed, "remote add origin " & q(origin))
        discard git(gitBin, seed, "push -q origin main")
        let work = ws / "work"
        discard run(q(gitBin) & " clone -q " & q(origin) & " " & q(work))
        discard git(gitBin, work, "config user.email t@e.invalid")
        discard git(gitBin, work, "config user.name Tester")
        let lockedRev = git(gitBin, work, "rev-parse HEAD").output.strip()

        writeFile(work / "repro.solver", solverInputs)
        # Ignore the CLI's ``.repro/`` work/report tree so a prior ``check`` run
        # does not leave the tree dirty for the next gate invocation.
        writeFile(work / ".gitignore", "/.repro/\n")
        let refresh = run(reproBinary & " lock refresh " & q(work))
        check refresh.code == 0
        check fileExists(work / "repro.lock")
        discard git(gitBin, work, "add repro.solver repro.lock .gitignore")
        discard git(gitBin, work, "commit -qm lock")
        discard git(gitBin, work, "push -q origin main")

        let refs = ws / "refs.txt"
        let head = git(gitBin, work, "rev-parse HEAD").output.strip()
        writeFile(refs, "refs/heads/main " & head & " refs/heads/main " &
          "0000000000000000000000000000000000000000\n")

        # SYNC fetches the locked COORDINATES: the plan names the lock's recorded
        # revision (``lockedRev``), not the current HEAD (``head``).
        let sync = run(reproBinary & " workspace sync --workspace-root=" &
          work & " --dry-run")
        check sync.code == 0
        check lockedRev in sync.output

        # GATE PASSES on the untampered committed lock (it verifies the locked
        # integrity through ``populateLockedDeps`` and finds it intact).
        let chk = run(reproBinary & " check --mode=pre-push --workspace-root=" &
          work & " --pushed-refs=" & refs)
        check chk.code == 0
        check "committed solved-graph lock OK" in chk.output

        # TAMPER the committed lock's integrity field only (leave the revision
        # intact), then commit + push so the tree is clean + published — the
        # cleanliness / publication stages pass and the gate reaches the
        # integrity stage, which must REFUSE with ``locked-integrity-mismatch``.
        let lockText = readFile(work / "repro.lock")
        let goodLine = "integrity = \"git-sha1:" & lockedRev & "\""
        check goodLine in lockText            # sanity: a git-native integrity
        let tampered = lockText.replace(goodLine,
          "integrity = \"" & badIntegrity & "\"")
        check tampered != lockText
        writeFile(work / "repro.lock", tampered)
        discard git(gitBin, work, "add repro.lock")
        discard git(gitBin, work, "commit -qm tamper")
        discard git(gitBin, work, "push -q origin main")
        let head2 = git(gitBin, work, "rev-parse HEAD").output.strip()
        writeFile(refs, "refs/heads/main " & head2 & " refs/heads/main " &
          "0000000000000000000000000000000000000000\n")

        let chk2 = run(reproBinary & " check --mode=pre-push --workspace-root=" &
          work & " --pushed-refs=" & refs)
        check chk2.code == 2
        let reportPath = work / ".repro" / "workspace" / "check-report.json"
        check fileExists(reportPath)
        let report = parseJson(readFile(reportPath))
        var sawIntegrityFailure = false
        for failure in report{"failures"}:
          if failure{"property"}.getStr() == "locked-integrity-mismatch":
            sawIntegrityFailure = true
        check sawIntegrityFailure
