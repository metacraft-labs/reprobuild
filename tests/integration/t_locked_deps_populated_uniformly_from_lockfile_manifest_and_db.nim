## Workspace-Manifest-Optional MO-9 — ``populateLockedDeps`` fills ONE unified
## ``LockedDependencies`` model from ANY source, with a uniform per-dependency
## shape (coordinates + self-describing integrity) regardless of provenance.
##
## We populate the SAME model from each of the three sources and assert the
## resulting ``LockedDep`` carries the same shape (VCS coordinates with a fetch
## URL + an exact revision, plus a self-describing git-native integrity), with
## the correct per-source revision:
##
##   (a) a committed lock file  — a v2 ``repro.lock`` (the lock's CONTENT);
##   (b) a manifest repo        — a ``git-checkout`` ``LockStore`` (the
##       manifest-repo per-repo SHA lock);
##   (c) an external DB store    — a records-in-a-dir ``CommittedFileLockStore``
##       stub standing in for an external database backend.
##
## Then a MIXED workspace: ``app`` routed to the manifest (git-checkout) source
## and ``lib`` routed to the external-DB source populate ONE object, each repo
## carrying its OWN source's locked revision — proving the per-repo-set routing
## (MO-4) feeds a single unified model.
##
## Falsifiable: each store records a DISTINCT synthetic revision that is NOT the
## repo's on-disk ``git HEAD``. If a source bypassed the populator and re-derived
## the revision from ``HEAD`` (or from another source), the per-source revision
## assertions would read the wrong value and the test fails. The uniform-shape
## helper fails if any source produced a dep without coordinates or integrity.
##
## Hermetic: every git repo + store lives in a fresh tempdir. Skip rule: ``git``
## missing on PATH.

import std/[options, os, osproc, strutils, tables, unittest]

import repro_cli_support
import repro_lock_store
import repro_lock
import repro_workspace_manifests
import git_tool

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc initGitRepoWithCommit(gitBin, path: string): string =
  ## A git checkout with one commit; returns its HEAD sha.
  createDir(path)
  discard run(q(gitBin) & " init -q -b main " & q(path))
  discard run(q(gitBin) & " -C " & q(path) & " config user.email t@e.invalid")
  discard run(q(gitBin) & " -C " & q(path) & " config user.name Tester")
  writeFile(path / "seed.txt", "seed\n")
  discard run(q(gitBin) & " -C " & q(path) & " add seed.txt")
  discard run(q(gitBin) & " -C " & q(path) & " commit -qm seed")
  run(q(gitBin) & " -C " & q(path) & " rev-parse HEAD").output.strip()

proc initBareManifest(gitBin, path: string) =
  createDir(path)
  discard run(q(gitBin) & " init -q -b main " & q(path))
  discard run(q(gitBin) & " -C " & q(path) & " config user.email t@e.invalid")
  discard run(q(gitBin) & " -C " & q(path) & " config user.name Tester")
  writeFile(path / "seed.txt", "seed\n")
  discard run(q(gitBin) & " -C " & q(path) & " add seed.txt")
  discard run(q(gitBin) & " -C " & q(path) & " commit -qm seed")

proc recordBody(repoPath, sha: string): string =
  ## A minimal workspace-lock-shaped body — the same shape
  ## ``recordWorkspaceParticipation`` writes and ``lockedShaFromStore`` reads.
  "[[repo]]\npath = \"" & repoPath & "\"\nrevision = \"" & sha & "\"\n"

proc putRecord(store: LockStore; project, repo, repoPath, sha: string) =
  let put = store.putLock(StoreLockRecord(
    key: StoreLockKey(project: project, repo: repo, sha: sha),
    body: recordBody(repoPath, sha)))
  doAssert put.outcome == spoOk, put.diagnostic

proc assertUniformVcsDep(d: LockedDep; expectRevision: string) =
  ## The shared per-dependency shape every source must produce: VCS coordinates
  ## with a non-empty fetch URL + the expected exact revision, and a non-empty
  ## self-describing integrity multihash.
  check d.coordinates.kind == ckVcs
  check d.coordinates.url.len > 0
  check d.coordinates.revision == expectRevision
  check d.integrity.len > 0
  check d.integrity.contains(":")           # self-describing <alg>:<digest>
  check d.integrity.startsWith("git-sha")   # VCS-native content hash

suite "MO-9 — populateLockedDeps fills one model uniformly from any source":

  test "t_locked_deps_populated_uniformly_from_lockfile_manifest_and_db":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let ws = getTempDir() / "mo9-uniform-" & $getCurrentProcessId()
      removeDir(ws)
      createDir(ws)
      defer: removeDir(ws)

      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      # A real git checkout for the "app" repo; its HEAD is a genuine git sha.
      let appDir = ws / "app"
      let appSha = initGitRepoWithCommit(gitBin, appDir)
      let appUrl = "https://example.invalid/app.git"

      # ---- (a) committed lock file: the lock's CONTENT populates the model ---
      block committedLockSource:
        let dep = LockedDep(
          name: "app", path: ".",
          coordinates: Coordinates(kind: ckVcs, url: appUrl, gitRef: "main",
            revision: appSha),
          integrity: gitObjectMultihash("sha1", appSha),
          visibility: "public")
        let ld = LockedDependencies(schema: SolvedGraphLockSchemaV2,
          platform: "amd64-linux", optimal: true, deps: @[dep])
        writeFile(appDir / "repro.lock", serializeLockedDependencies(ld))

        let populated = populateLockedDeps(
          LockSource(kind: lskCommittedLock, workspaceRoot: appDir))
        check populated.deps.len == 1
        assertUniformVcsDep(populated.deps[0], appSha)
        check populated.deps[0].path == "."

      # ---- (b) manifest repo: the git-checkout SHA lock populates the model --
      # Record a DISTINCT synthetic revision in the store so the assertion proves
      # the revision came from the SOURCE (the store), not the repo's on-disk
      # HEAD (``appSha``).
      let manifestSha = "1111111111111111111111111111111111111111"
      let manifestRepo = ws / "manifests"
      initBareManifest(gitBin, manifestRepo)
      let manifestStore: LockStore =
        newGitCheckoutLockStore(identity, manifestRepo)
      putRecord(manifestStore, "demo", "app", "app", manifestSha)

      let appResolved = ResolvedRepo(name: "app", path: "app",
        remoteName: "origin", fetchUrl: appUrl, revision: "main",
        visibility: wvPublic)

      block manifestSource:
        let populated = populateLockedDeps(LockSource(
          kind: lskManifestRepo, workspaceRoot: ws, projectName: "demo",
          repos: @[appResolved], store: manifestStore))
        check populated.deps.len == 1
        assertUniformVcsDep(populated.deps[0], manifestSha)
        check populated.deps[0].coordinates.url == appUrl

      # ---- (c) external DB store: the same shape from a DB-like backend ------
      let dbSha = "2222222222222222222222222222222222222222"
      let dbStore: LockStore = newCommittedFileLockStore(ws / "extdb")
      putRecord(dbStore, "demo", "app", "app", dbSha)

      block externalStoreSource:
        let populated = populateLockedDeps(LockSource(
          kind: lskExternalStore, workspaceRoot: ws, projectName: "demo",
          repos: @[appResolved], store: dbStore))
        check populated.deps.len == 1
        assertUniformVcsDep(populated.deps[0], dbSha)

      # ---- MIXED: one object, each repo's source-correct entry --------------
      # ``app`` from the manifest (git-checkout) source, ``lib`` from the
      # external-DB source — routed per repo-set, feeding ONE LockedDependencies.
      let libDir = ws / "lib"
      discard initGitRepoWithCommit(gitBin, libDir)   # on-disk HEAD (unused)
      let libSha = "3333333333333333333333333333333333333333"
      putRecord(dbStore, "demo", "lib", "lib", libSha)
      let libResolved = ResolvedRepo(name: "lib", path: "lib",
        remoteName: "origin", fetchUrl: "https://example.invalid/lib.git",
        revision: "main", visibility: wvPersonal)

      block mixedWorkspace:
        var mixed = LockedDependencies(
          schema: SolvedGraphLockSchemaV2, deps: @[])
        # app routed to the manifest source.
        mixed.deps.add(populateLockedDeps(LockSource(
          kind: lskManifestRepo, workspaceRoot: ws, projectName: "demo",
          repos: @[appResolved], store: manifestStore)).deps)
        # lib routed to the external-DB source.
        mixed.deps.add(populateLockedDeps(LockSource(
          kind: lskExternalStore, workspaceRoot: ws, projectName: "demo",
          repos: @[libResolved], store: dbStore)).deps)

        check mixed.deps.len == 2
        var byName = initTable[string, LockedDep]()
        for d in mixed.deps: byName[d.name] = d
        check "app" in byName
        check "lib" in byName
        # Each repo carries ITS OWN source's locked revision in the ONE object.
        check byName["app"].coordinates.revision == manifestSha
        check byName["lib"].coordinates.revision == libSha
        # And both still carry the uniform shape (coordinates + integrity).
        assertUniformVcsDep(byName["app"], manifestSha)
        assertUniformVcsDep(byName["lib"], libSha)
