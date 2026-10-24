## Distributed-Execution M1 gate: `t_workspace_snapshot_export_and_materialize`.
##
## A dirty working tree — staged edits, unstaged edits (one of them a mode
## change), untracked files git does not ignore, a tracked file deleted with
## `git rm` and one deleted on disk only, plus ignored files that must NOT
## travel — and an active `repro develop` sibling with uncommitted edits of
## its own are captured into ONE `WorkspaceSnapshotManifest`
## (`captureWorkspaceSnapshot`): a `git-tree-sha1` per repository computed in
## a temporary index, and the modified files' bytes in the requester's
## snapshot store by BLAKE3 digest. The caller's `.git/index` files are
## byte-for-byte and mtime-for-mtime unchanged.
##
## The base commits are what a developer really has: the primary
## repository's `HEAD` is a LOCAL commit no remote holds, on top of one that
## was pushed to its `origin` after the worker cloned it; the sibling's
## `HEAD` is a local commit of a repository with no remote at all. The
## capture ships each repository's unpushed history as a BASE PACK, published
## for the goal like a blob; the worker indexes it into its repository cache
## and fetches the rest (the pushed commit) from the remote its operator
## configured.
##
## Case 1 — the worker is a second peer-cache node on its own real TLS
## socket (the production `PeerCacheHost`, trusted profile, pinned host keys)
## holding bare clones of both repositories. The requester sends a
## `ReachGoal` over the connection IT opened; the worker hydrates the
## manifest, exactly the changed blobs and the base packs it needs back over
## that connection (the `HydrationChannel`, FLOW-1) and materializes both
## repositories as copy-on-write leases of its worktree pool
## (`materializeWorkspaceSnapshot`). Asserted: the materialized trees hash to
## the manifest's `git-tree-sha1`s and are byte-for-byte (and mode-for-mode)
## the requester's working trees, ignored files absent; the requester served
## exactly 1 manifest + the changed blobs + the two base packs; a warm
## materialization (the base worktree cached) of a 10-file diff — timed from
## the goal's arrival at the worker: hydrating the manifest and the changed
## blobs over the peer cache, then both repositories' leases, verified —
## takes < 200 ms, asserted on the MEDIAN of seven warm runs (all seven, the
## minimum and the median are printed; if the median misses the budget the
## seven runs are repeated — at most twice — and the last median decides); two leases
## alive at once do not see each other's writes, and neither does the base.
## Negative controls: a manifest naming another tree id is refused; a blob
## served with other bytes is refused; a base worktree that drifted from its
## commit on disk refuses the next lease; a base pack that does not hold the
## base commit leaves it missing and the lease is refused.
##
## Case 2 — the SHIPPED WORKER DAEMON (`repro daemon serve … worker=1`,
## trusted profile — the profile macOS and Linux workers both run, so this
## covers the macOS daemon with `clonefile(2)` leases): its `repos=` file
## names both repository caches and, for the primary, the remote
## (production `parseWorkerRepos` and the worker role's wiring). The real
## `WorkerReceiver` materializes the primary repository AND the develop
## sibling into the goal's execution lease and runs the goal: a test node
## that archives the worktree it sees and the sibling it is given
## (`REPRO_DEVELOP_SIBLINGS`, read-only) — the archives are byte-for-byte
## the requester's working trees, the sibling cannot be written, and no
## certificate is issued while the sibling is present (the execution record
## carries `certificate-withheld-develop-siblings`). The daemon's own
## materialization time (status `worker_last_materialize_ms`: from the goal's
## arrival through both repositories verified) is < 200 ms on the median of
## seven warm goals, with the same retries. `requesterVerifyGoal` — the
## trusted profile's signing check — refuses the goal's result for the
## sibling-withheld record.
##
## Further cases: a repository whose `.gitattributes` converts on checkout
## (`text eol=crlf`, `ident`) materializes the BLOB bytes in both
## materializers and its tree verifies natively; a cache with
## `info/attributes`, or a git older than 2.40, is refused by the pool (whose
## base checkout is git's own) while the fresh checkout, which writes blob
## bytes itself, still materializes them; a directory replaced by a file (and a
## deletion that empties a directory) materializes; capture refuses
## content-id-less states, an untracked nested git repository and a base
## pack over its bound; the requester's snapshot store is owner-only and
## swept.
##
## MOCK POLICY — none: real git repositories and clones, real TLS sockets,
## the production peer-cache node, hydration channel, snapshot store and
## worktree pool, and in case 2 the shipped daemon binary with its real
## receiver and execution lease.

import std/[algorithm, asyncdispatch, monotimes, options, os, osproc,
            sequtils, sets, strutils, tables, tempfiles, times, unittest]

import blake3

import repro_peer_cache
import repro_peer_cache/snapshot_blobs
import repro_workspace_snapshot
import repro_distributed_worker
import repro_cli_support/peer_cache_wiring
from repro_cli_support import RequesterGoalContext, requesterVerifyGoal,
  workerMaterializeStatusLines

import ../../repro_peer_cache/tests/m7_test_pki
import ../../../tests/integration/m7_worker_fixture

const
  PrimaryDirs = 40
  FilesPerDir = 50
  WarmBudgetMs = 200.0
  WarmRuns = 7

proc git(dir: string; args: varargs[string]): string =
  let res = execCmdEx(quoteShellCommand(@["git", "-C", dir] & @args))
  doAssert res.exitCode == 0, "git " & args.join(" ") & ": " & res.output
  res.output.strip()

proc gitRepo(dir: string) =
  createDir(dir)
  discard git(dir, "init", "-q", "-b", "main")
  discard git(dir, "config", "user.email", "m1@example.invalid")
  discard git(dir, "config", "user.name", "M1")

proc fileBody(i, j: int): string =
  for line in 0 ..< 40:
    result.add("dir " & $i & " file " & $j & " line " & $line & "\n")

proc treeByGit(dir: string): string =
  ## The tree of the working tree as git computes it in a temporary index:
  ## `read-tree HEAD`, `add -A`, `write-tree` (the user's index untouched).
  let index = dir.parentDir / (".tree-index-" & dir.extractFilename)
  defer: (try: removeFile(index) except OSError: discard)
  let env = "GIT_INDEX_FILE=" & quoteShell(index) & " "
  for cmd in ["read-tree HEAD", "add -A", "write-tree"]:
    let res = execCmdEx(env & "git -C " & quoteShell(dir) & " " & cmd)
    doAssert res.exitCode == 0, cmd & ": " & res.output
    result = res.output.strip()

proc indexStamp(dir: string): tuple[bytes: string; mtime: Time] =
  (readFile(dir / ".git" / "index"),
   getLastModificationTime(dir / ".git" / "index"))

proc present(path: string): bool =
  fileExists(path) or symlinkExists(path)

proc shippedFiles(dir: string): seq[string] =
  ## What the snapshot must reproduce: tracked and non-ignored untracked
  ## files that exist on disk (read-only `ls-files` against the real index).
  for p in git(dir, "ls-files", "-z", "-c", "-o", "--exclude-standard").split('\0'):
    if p.len > 0 and present(dir / p) and p notin result:
      result.add(p)
  result.sort()

proc filesUnder(dir: string): seq[string] =
  for p in walkDirRec(dir, yieldFilter = {pcFile, pcLinkToFile, pcLinkToDir},
                      relative = true):
    result.add(p.replace('\\', '/'))
  result.sort()

proc sameEntry(a, b: string): bool =
  ## Byte-for-byte and mode-for-mode (a symlink by its target).
  if symlinkExists(a) or symlinkExists(b):
    return symlinkExists(a) and symlinkExists(b) and
      expandSymlink(a) == expandSymlink(b)
  readFile(a) == readFile(b) and
    (fpUserExec in getFilePermissions(a)) ==
    (fpUserExec in getFilePermissions(b))

proc mismatchesBetween(src, dst: string): seq[string] =
  ## Paths whose shipped content differs between `src` (the requester's
  ## working tree) and `dst` (the materialized lease), and paths present
  ## in only one of them.
  let want = shippedFiles(src)
  let have = filesUnder(dst)
  for p in want:
    if p notin have: result.add("missing " & p)
    elif not sameEntry(src / p, dst / p): result.add("differs " & p)
  for p in have:
    if p notin want: result.add("extra " & p)

proc pumpFor(ms: int) =
  let deadline = epochTime() + ms.float / 1000.0
  while epochTime() < deadline:
    try: poll(20) except ValueError: sleep(20)

proc median(xs: seq[float]): float =
  var s = xs
  s.sort()
  s[s.len div 2]

proc ms(xs: seq[float]): string =
  xs.mapIt(it.formatFloat(ffDecimal, 1)).join(",")

type
  Workspace = object
    app, cairo, origin, cacheApp, cacheCairo: string
    headApp, headPushed, headCairo: string

proc buildWorkspace(base: string): Workspace =
  ## The requester's primary repository `app` (2004 files, an `origin`) and
  ## its `repro develop` sibling `cairo` (no remote), the worker's bare
  ## caches of both, then: one commit pushed to `origin` after the worker
  ## cloned it, one LOCAL commit in each repository, and the dirty state —
  ## 10 changes in the primary, 4 in the sibling.
  result.app = base / "ws" / "app"
  result.cairo = base / "ws" / "cairo"
  result.origin = base / "origin" / "app.git"
  result.cacheApp = base / "worker-repos" / "app.git"
  result.cacheCairo = base / "worker-repos" / "cairo.git"
  let app = result.app
  let cairo = result.cairo
  gitRepo(app)
  writeFile(app / ".gitignore", ".repro/\n*.log\n")
  for i in 0 ..< PrimaryDirs:
    createDir(app / "src" / ("d" & $i))
    for j in 0 ..< FilesPerDir:
      writeFile(app / "src" / ("d" & $i) / ("f" & $j & ".txt"), fileBody(i, j))
  writeFile(app / "run.sh", "#!/bin/sh\necho run\n")
  setFilePermissions(app / "run.sh", {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  createSymlink("src/d0/f0.txt", app / "first-link")
  writeFile(app / "VERSION", "1\n")
  discard git(app, "add", "-A")
  discard git(app, "commit", "-q", "-m", "base")
  createDir(result.origin.parentDir)
  discard git(base, "clone", "-q", "--bare", app, result.origin)
  discard git(app, "remote", "add", "origin", result.origin)
  discard git(app, "fetch", "-q", "origin")
  gitRepo(cairo)
  createDir(cairo / "lib")
  for j in 0 ..< 30:
    writeFile(cairo / "lib" / ("m" & $j & ".nim"), fileBody(99, j))
  discard git(cairo, "add", "-A")
  discard git(cairo, "commit", "-q", "-m", "cairo base")
  # The worker's repository caches (its local git objects).
  createDir(result.cacheApp.parentDir)
  discard git(base, "clone", "-q", "--bare", result.origin, result.cacheApp)
  discard git(base, "clone", "-q", "--bare", cairo, result.cacheCairo)
  # Pushed after the worker cloned: the worker fetches it from `origin`.
  writeFile(app / "CHANGELOG", "2: a changelog\n")
  writeFile(app / "VERSION", "2\n")
  discard git(app, "add", "-A")
  discard git(app, "commit", "-q", "-m", "version 2")
  discard git(app, "push", "-q", "origin", "main")
  result.headPushed = git(app, "rev-parse", "HEAD")
  # Local commits no remote has: shipped as base packs.
  writeFile(app / "VERSION", "3\n")
  discard git(app, "commit", "-q", "-am", "version 3 (not pushed)")
  writeFile(cairo / "lib" / "m0.nim", "cairo local commit\n")
  discard git(cairo, "commit", "-q", "-am", "cairo local commit")
  result.headApp = git(app, "rev-parse", "HEAD")
  result.headCairo = git(cairo, "rev-parse", "HEAD")
  # The dirty state: 10 changes in the primary, 4 in the sibling.
  for p in ["src/d1/f1.txt", "src/d2/f2.txt", "src/d3/f3.txt"]:
    writeFile(app / p, "staged edit of " & p & "\n")   # staged edits
    discard git(app, "add", p)
  for p in ["src/d4/f4.txt", "src/d5/f5.txt"]:
    writeFile(app / p, "unstaged edit of " & p & "\n") # unstaged edits
  setFilePermissions(app / "src/d6/f6.txt", {fpUserRead, fpUserWrite,
    fpUserExec, fpGroupRead, fpOthersRead})            # unstaged mode change
  createDir(app / "src" / "new")
  writeFile(app / "src/new/a.txt", "untracked a\n")    # untracked, allowed
  writeFile(app / "src/new/b.txt", "untracked b\n")
  discard git(app, "rm", "-q", "src/d7/f7.txt")        # staged deletion
  removeFile(app / "src/d8/f8.txt")                    # unstaged deletion
  writeFile(app / "build.log", "ignored\n")            # ignored: stays home
  createDir(app / ".repro")
  writeFile(app / ".repro" / "develop-overrides.toml",
    "schema = \"reprobuild.workspace.develop-overrides.v1\"\n\n" &
    "[[override]]\npackage = \"cairo\"\nlocal_path = \"../cairo\"\n" &
    "state = \"editable\"\ncreated_at = \"2026-10-21T00:00:00Z\"\n")
  writeFile(cairo / "lib/m1.nim", "staged sibling edit\n")
  discard git(cairo, "add", "lib/m1.nim")
  writeFile(cairo / "lib/m2.nim", "unstaged sibling edit\n")
  writeFile(cairo / "lib/extra.nim", "untracked sibling file\n")
  removeFile(cairo / "lib/m3.nim")

proc newDiff(ws: Workspace; tag: string) =
  ## A fresh 10-file diff (the same paths, new content).
  for p in ["src/d1/f1.txt", "src/d2/f2.txt", "src/d3/f3.txt",
            "src/d4/f4.txt", "src/d5/f5.txt", "src/new/a.txt",
            "src/new/b.txt"]:
    writeFile(ws.app / p, tag & " edit of " & p & "\n")

type
  WorkerSide = ref object
    pool: WorktreePool
    leaseRoot: string
    caches: Table[string, string]
    results: Table[string, WorkspaceMaterializeResult]
    elapsedMs: Table[string, float]
    fetched: Table[string, int]

suite "Distributed-Execution M1: workspace snapshot export and materialize":

  test "t_workspace_snapshot_export_and_materialize":
    let base = normalizedPath(absolutePath(getTempDir() /
      ("repro-m1-snapshot-" & $getCurrentProcessId())))
    removeDir(base)
    createDir(base)
    var hosts: seq[PeerCacheHost] = @[]
    defer:
      for h in hosts: h.stop()
      removeDir(base)
    let ws = buildWorkspace(base)
    let app = ws.app
    let cairo = ws.cairo
    let appIndexBefore = indexStamp(app)
    let cairoIndexBefore = indexStamp(cairo)

    # -- Capture -------------------------------------------------------------
    let store = openSnapshotStore(base / "requester-snapshots")
    defer: store.close()
    let sink = proc(d: Blake3Digest; bytes: seq[byte]) {.gcsafe, closure.} =
      {.cast(gcsafe).}:
        store.putBlob(d, bytes)
    let cap = captureWorkspaceSnapshot(app, "app", sink)
    checkpoint("capture: " & cap.reason)
    check cap.ok
    # The caller's indexes were never written.
    check indexStamp(app) == appIndexBefore
    check indexStamp(cairo) == cairoIndexBefore
    let snap = cap.manifest
    check snap.primaryRepo.baseCommitSha == ws.headApp
    check snap.primaryRepo.gitTreeSha1 == treeByGit(app)
    var modified: seq[string] = @[]
    for m in snap.primaryRepo.modified: modified.add(m.relPath)
    check modified == @["src/d1/f1.txt", "src/d2/f2.txt", "src/d3/f3.txt",
      "src/d4/f4.txt", "src/d5/f5.txt", "src/d6/f6.txt", "src/new/a.txt",
      "src/new/b.txt"]
    check snap.primaryRepo.deleted == @["src/d7/f7.txt", "src/d8/f8.txt"]
    for m in snap.primaryRepo.modified:
      if m.relPath == "src/d6/f6.txt":
        check m.mode == ModeExecutable
    check snap.developSiblings.len == 1
    check snap.developSiblings.len == 1 and
      snap.developSiblings[0].repoId == "cairo" and
      snap.developSiblings[0].baseCommitSha == ws.headCairo and
      snap.developSiblings[0].gitTreeSha1 == treeByGit(cairo) and
      snap.developSiblings[0].modified.len == 3 and
      snap.developSiblings[0].deleted == @["lib/m3.nim"]
    check cap.exportedBlobs == 8 + 3
    # Both base commits are local: each repository ships a base pack.
    check cap.basePacks == 2
    check snap.primaryRepo.hasBasePack
    check snap.developSiblings.len == 1 and snap.developSiblings[0].hasBasePack
    check validateManifest(snap) == ""
    check decodeManifest(encodeManifest(snap)) == snap

    # -- Two peer-cache nodes: the requester and the worker ------------------
    let r = newTestNode(base, "r")
    let w = newTestNode(base, "w")
    mutualTrust([r, w])
    w.grantRoles(r, "cache-peer,orchestrator")
    let hostW = startPeerCacheHost(tlsConfig(w, profile = tpTrusted),
      w.identity.hostId, cacheRoot = base / "w-cache",
      stateDir = base / "w-state")
    hosts.add(hostW)
    hostW.server.gate.policy.servesWorker = true
    hostW.client.dialDiscovered = false        # FLOW-1: never dials back
    let side = WorkerSide(pool: newWorktreePool(base / "w-pool"),
      leaseRoot: base / "w-leases",
      caches: {"app": ws.cacheApp, "cairo": ws.cacheCairo}.toTable)
    side.pool.fetchRemotes["app"] = ws.origin
    createDir(side.leaseRoot)
    hostW.server.workerHandler = proc(caller: CallerIdentity; frame: Frame;
        hydration: HydrationChannel):
        Future[tuple[kind: MessageKind; payload: seq[byte]]]
        {.async, gcsafe.} =
      {.cast(gcsafe).}:
        let started = getMonoTime()
        let req = decodeRequest(frame.payload)
        var resp = ReachGoalResponse(requestId: req.requestId,
          status: gsRefused, reason: "manifest not hydrated")
        let manBytes = await hydration.fetch(
          blobDigestFromBytes(req.snapshotManifestDigest))
        if manBytes.isSome:
          let m = decodeManifest(manBytes.get())
          let blobs = await fetchSnapshotBlobs(m,
            proc(d: array[32, byte]): Future[Option[seq[byte]]] {.gcsafe.} =
              hydration.fetch(blobDigestFromBytes(d)),
            proc(repo: RepoSnapshot): bool {.gcsafe, closure.} =
              {.cast(gcsafe).}:
                side.pool.needsBasePack(side.caches[repo.repoId], repo))
          side.fetched[req.requestId] = blobs.fetched
          let lease = side.leaseRoot / req.requestId
          createDir(lease)
          let mat = side.pool.materializeWorkspaceSnapshot(m,
            proc(id: string): string {.gcsafe, closure.} =
              {.cast(gcsafe).}: side.caches.getOrDefault(id, ""),
            lease / "wt", lease / "siblings",
            proc(d: Blake3Digest): Option[seq[byte]] {.gcsafe, closure.} =
              {.cast(gcsafe).}:
                if blobs.blobs.hasKey(d): some(blobs.blobs[d])
                else: none(seq[byte]))
          side.elapsedMs[req.requestId] =
            float((getMonoTime() - started).inMicroseconds) / 1000.0
          side.results[req.requestId] = mat
          resp.status = if mat.ok: gsCompleted else: gsFailed
          resp.reason = mat.reason
          resp.treeBefore = mat.primary.observedTree
        return (mkReachGoalResponse, encodeResponse(resp))
    let hostR = startPeerCacheHost(tlsConfig(r, seeds = @[initEndpoint(
      "127.0.0.1", hostW.actualPort)], profile = tpTrusted),
      r.identity.hostId, cacheRoot = base / "r-cache",
      stateDir = base / "r-state")
    hosts.add(hostR)
    check hostR.client.isConnected(w.identity.hostId)

    proc sendGoal(id: string; m: WorkspaceSnapshotManifest): GoalReply =
      pumpFor(600)      # the receiver's ReachGoal rate (2/s)
      let pub = store.publishSnapshot(m)
      waitFor hostR.client.requestReachGoal(w.identity.hostId,
        encodeRequest(ReachGoalRequest(requestId: id,
          snapshotManifestDigest: bytes(pub.manifestDigest),
          goalNode: "materialize")),
        store.hydrationSetFor([pub]), timeoutMs = 300_000)

    # -- Goal 1 (cold: no base worktree yet; the base commits are completed
    # from the base packs and, for the pushed commit, from `origin`) --------
    # The worker's caches lack both base commits.
    check execCmdEx(quoteShellCommand(["git", "--git-dir=" & ws.cacheApp,
      "cat-file", "-e", ws.headApp & "^{commit}"])).exitCode != 0
    check execCmdEx(quoteShellCommand(["git", "--git-dir=" & ws.cacheCairo,
      "cat-file", "-e", ws.headCairo & "^{commit}"])).exitCode != 0
    let served0 = hostR.client.hydrationServed
    let reply1 = sendGoal("g1", snap)
    check reply1.kind == grkResponse
    let resp1 = decodeResponse(reply1.payload)
    checkpoint("goal 1: " & $resp1.status & " " & resp1.reason)
    check resp1.status == gsCompleted
    # Only the manifest, the changed blobs and the two base packs crossed
    # the wire.
    check hostR.client.hydrationServed - served0 == 1 + cap.exportedBlobs + 2
    check side.fetched.getOrDefault("g1") == cap.exportedBlobs + 2
    check side.pool.basePacks == 2                 # both packs indexed
    check side.pool.baseFetches == 1               # CHANGELOG came from origin
    # The unpushed commits are now in the worker's caches.
    check execCmdEx(quoteShellCommand(["git", "--git-dir=" & ws.cacheApp,
      "cat-file", "-e", ws.headApp & "^{commit}"])).exitCode == 0
    check execCmdEx(quoteShellCommand(["git", "--git-dir=" & ws.cacheCairo,
      "cat-file", "-e", ws.headCairo & "^{commit}"])).exitCode == 0
    let mat1 = side.results["g1"]
    check mat1.ok
    check mat1.primary.observedTree == snap.primaryRepo.gitTreeSha1
    check mat1.siblings.len == 1
    check mat1.siblings.len == 1 and
      mat1.siblings[0][1].observedTree == snap.developSiblings[0].gitTreeSha1
    # Byte-for-byte parity with the requester's working trees, ignored
    # files (build.log, .repro/) absent.
    let lease1 = side.leaseRoot / "g1" / "wt"
    check mismatchesBetween(app, lease1).len == 0
    checkpoint("primary mismatches: " & $mismatchesBetween(app, lease1))
    check not present(lease1 / "build.log")
    check not dirExists(lease1 / ".repro")
    let siblingLease1 = side.leaseRoot / "g1" / "siblings" / "cairo"
    check mismatchesBetween(cairo, siblingLease1).len == 0
    checkpoint("sibling mismatches: " & $mismatchesBetween(cairo,
      siblingLease1))
    let coldMs = side.elapsedMs["g1"]

    # -- Warm goals (the cached base worktree), a fresh 10-file diff each ----
    var warmIds: seq[string] = @[]
    proc warmBlock(attempt: int): tuple[total, primary: seq[float]] =
      for round in 1 .. WarmRuns:
        newDiff(ws, "attempt " & $attempt & " round " & $round)
        let capN = captureWorkspaceSnapshot(app, "app", sink)
        check capN.ok
        check capN.manifest.primaryRepo.modified.len +
          capN.manifest.primaryRepo.deleted.len == 10
        let id = "w" & $attempt & "r" & $round
        let servedBefore = hostR.client.hydrationServed
        let reply = sendGoal(id, capN.manifest)
        check reply.kind == grkResponse
        check decodeResponse(reply.payload).status == gsCompleted
        # No base pack is fetched once a base worktree is at the commit.
        check hostR.client.hydrationServed - servedBefore ==
          1 + capN.exportedBlobs
        check side.results[id].primary.observedTree ==
          capN.manifest.primaryRepo.gitTreeSha1
        check mismatchesBetween(app, side.leaseRoot / id / "wt").len == 0
        warmIds.add(id)
        result.total.add(side.elapsedMs[id])
        result.primary.add(side.results[id].elapsedMs[0])
    let checkoutsBefore = side.pool.baseCheckouts
    var warm = warmBlock(1)
    var attempts = 1
    echo "M1-TIMING attempt=1 clone=", side.pool.lastCloneMode,
      " primaryFiles=", PrimaryDirs * FilesPerDir + 5,
      " coldMs=", coldMs.formatFloat(ffDecimal, 1),
      " warmMs=", ms(warm.total),
      " warmMinMs=", min(warm.total).formatFloat(ffDecimal, 1),
      " warmMedianMs=", median(warm.total).formatFloat(ffDecimal, 1),
      " primaryLeaseMs=", ms(warm.primary)
    while median(warm.total) >= WarmBudgetMs and attempts < 3:
      # Up to two retries of the whole series: a shared host (CI runners,
      # Spotlight, parallel suites) can stall a whole series; the MEDIAN of
      # the last series decides.
      inc attempts
      warm = warmBlock(attempts)
      echo "M1-TIMING attempt=", attempts, " warmMs=", ms(warm.total),
        " warmMinMs=", min(warm.total).formatFloat(ffDecimal, 1),
        " warmMedianMs=", median(warm.total).formatFloat(ffDecimal, 1),
        " primaryLeaseMs=", ms(warm.primary)
    check side.pool.baseCheckouts == checkoutsBefore   # the base was reused
    check side.pool.baseHits >= 2 * WarmRuns * attempts
    check median(warm.total) < WarmBudgetMs

    # -- Concurrent leases never collide -------------------------------------
    let leaseA = side.leaseRoot / warmIds[3] / "wt"
    let leaseB = side.leaseRoot / warmIds[4] / "wt"
    let baseTree = side.pool.root / repoKey("app") / "b0" / "tree"
    let untouched = "src/d20/f20.txt"
    let original = readFile(leaseB / untouched)
    block inPlace:
      var f = open(leaseA / untouched, fmReadWriteExisting)
      f.write("written in place by the goal in lease A\n")
      f.close()
    writeFile(leaseA / "src/d21/f21.txt", "replaced in lease A\n")
    check readFile(leaseB / untouched) == original
    check readFile(baseTree / untouched) == original
    check readFile(leaseB / "src/d21/f21.txt") == fileBody(21, 21)
    check readFile(baseTree / "src/d21/f21.txt") == fileBody(21, 21)

    # -- Negative controls ---------------------------------------------------
    let reader = proc(d: Blake3Digest): Option[seq[byte]] {.gcsafe, closure.} =
      {.cast(gcsafe).}:
        store.readBlob(blobDigestFromBytes(d))
    # (n1) a manifest naming another tree is refused.
    var lying = snap.primaryRepo
    lying.gitTreeSha1 = repeat('0', 40)
    let n1Dir = side.leaseRoot / "n1"
    createDir(n1Dir)
    let n1 = side.pool.materializeLease(ws.cacheApp, lying, n1Dir / "wt", reader)
    checkpoint("n1: " & n1.reason)
    check not n1.ok
    check "does not match the manifest's git-tree-sha1" in n1.reason
    # (n2) a blob served with other bytes is refused before it is written.
    let n2Dir = side.leaseRoot / "n2"
    createDir(n2Dir)
    let n2 = side.pool.materializeLease(ws.cacheApp, snap.primaryRepo,
      n2Dir / "wt", proc(d: Blake3Digest): Option[seq[byte]] {.gcsafe.} =
        some(@[byte 1, 2, 3]))
    check not n2.ok
    check "does not hash to its BLAKE3 digest" in n2.reason
    # (n4) a base pack that does not hold the base commit: a commit object
    # only the requester has (no ref, no worktree change), named with the
    # pack of another commit — the commit stays missing, the lease refused.
    let orphan = git(app, "commit-tree", ws.headApp & "^{tree}", "-p",
      ws.headApp, "-m", "never shipped")
    var wrongPack = snap.primaryRepo
    wrongPack.baseCommitSha = orphan
    let n4Dir = side.leaseRoot / "n4"
    createDir(n4Dir)
    let n4 = side.pool.materializeLease(ws.cacheApp, wrongPack, n4Dir / "wt",
      reader)
    checkpoint("n4: " & n4.reason)
    check not n4.ok
    check ("base commit " & orphan & " is not available") in n4.reason
    # (n3) a base worktree that drifted from its commit on disk refuses the
    # next lease: the verification reads the files, not just the manifest.
    writeFile(baseTree / "src/d30/f30.txt", fileBody(30, 30) & "drift\n")
    let n3Dir = side.leaseRoot / "n3"
    createDir(n3Dir)
    let n3 = side.pool.materializeLease(ws.cacheApp, snap.primaryRepo,
      n3Dir / "wt", reader)
    checkpoint("n3: " & n3.reason)
    check not n3.ok
    check "differs from its tree at src/d30/f30.txt" in n3.reason

    # The caller's indexes are still untouched.
    check indexStamp(app) == appIndexBefore
    check indexStamp(cairo) == cairoIndexBefore

  test "the shipped worker daemon materializes the primary and a develop sibling into the lease":
    let base = m7TestBase("repro-m1-daemon")
    let ws = buildWorkspace(base)
    var w = newTestNode(base, "worker")
    var o = newTestNode(base, "orch")
    mutualTrust([w, o])
    w.grantRoles(o, "cache-peer,orchestrator")
    # The daemon's `repos=` file: both caches, and the primary's remote.
    let reposFile = base / "repos"
    writeFile(reposFile, "# repoId cache [remote]\napp " & ws.cacheApp & " " &
      ws.origin & "\ncairo " & ws.cacheCairo & "\n")
    let parsed = parseWorkerRepos(readFile(reposFile))
    check parsed.caches == @[("app", ws.cacheApp), ("cairo", ws.cacheCairo)]
    check parsed.remotes == @[("app", ws.origin)]
    let odd = parseWorkerRepos("a /c\n\n  # note\nlonely\nb /d r extra\n")
    check odd.caches == @[("a", "/c")]
    check odd.remotes.len == 0
    var worker = newWorkerDaemon(base, w)
    var orch: Orchestrator
    let store = openSnapshotStore(base / "requester-snapshots")
    defer:
      store.close()
      if not orch.host.isNil: orch.host.stop()
      stopWorkerDaemon(worker)
      removeDir(base)
    worker.startWorkerDaemon(trustedWorkerSpec(reposFile))
    checkpoint("worker daemon log:\n" & worker.daemonLog())
    check "repos=2 remotes=1" in worker.daemonLog()
    orch = newOrchestrator(base, o, worker.peerCachePort(),
      profile = tpTrusted)
    let workerId = w.identity.hostId
    check orch.waitConnected(workerId, worker)
    let sink = proc(d: Blake3Digest; bytes: seq[byte]) {.gcsafe, closure.} =
      {.cast(gcsafe).}:
        store.putBlob(d, bytes)

    proc goal(id: string; m: WorkspaceSnapshotManifest; node: GraphNode;
              certify = false): ReachGoalResponse =
      var desc = GraphCacheDescriptor(schema: DescriptorSchema,
        project: "m1-daemon", platform: hostOS & "/" & hostCPU,
        snapshotContentId: contentIdOf(m), nodes: @[node])
      desc.sortNodes()
      check validateDescriptor(desc) == ""
      let descBytes = encodeDescriptor(desc)
      let descDigest = blake3.digest(descBytes)
      store.putBlob(descDigest, descBytes)
      let pub = store.publishSnapshot(m)
      pump(600)        # the receiver's ReachGoal rate (2/s)
      let reply = waitFor orch.host.client.requestReachGoal(workerId,
        encodeRequest(ReachGoalRequest(requestId: id,
          graphDescriptorDigest: descDigest,
          snapshotManifestDigest: bytes(pub.manifestDigest),
          goalNode: node.id, issueCertificate: certify)),
        store.hydrationSetFor([pub], [blobDigestFromBytes(descDigest)]),
        timeoutMs = 300_000)
      check reply.kind == grkResponse
      if reply.kind == grkResponse:
        result = decodeResponse(reply.payload)
        checkpoint(id & ": " & $result.status & " " & result.trigger & ": " &
          result.reason & "\n" & result.stderrTail)

    proc materializedAfter(n: int): float =
      ## The daemon's own materialization time of its `n`-th snapshot.
      result = -1.0
      let deadline = epochTime() + 15.0
      while epochTime() < deadline:
        orch.host.tick(50)
        let st = worker.status()
        if worker.statusInt("worker_materializations") >= n:
          return parseFloat(st.getOrDefault("worker_last_materialize_ms", "-1"))

    proc fetchOutput(resp: ReachGoalResponse; path: string): string =
      for o in resp.outputs:
        if o.path == path:
          let got = waitFor orch.host.client.requestFetchFrom(workerId,
            blobDigestFromBytes(o.digest))
          if got.isSome and got.get().len > 0:
            result = newString(got.get().len)
            copyMem(addr result[0], unsafeAddr got.get()[0], result.len)

    # -- Goal 1: the goal archives the worktree it runs in and the sibling
    # it is given, and tries to write the sibling ---------------------------
    let cap = captureWorkspaceSnapshot(ws.app, "app", sink)
    checkpoint("capture: " & cap.reason)
    check cap.ok
    check cap.basePacks == 2
    let snap = cap.manifest
    let dump = GraphNode(id: "dump", isTest: true, argv: @["/bin/sh", "-c",
      "set -eu; export COPYFILE_DISABLE=1; " &
      "S=\"$REPRO_DEVELOP_SIBLINGS/cairo\"; " &
      "tar -cf \"$TMPDIR/p.tar\" .; tar -cf \"$TMPDIR/s.tar\" -C \"$S\" .; " &
      "mkdir -p out; mv \"$TMPDIR/p.tar\" out/primary.tar; " &
      "mv \"$TMPDIR/s.tar\" out/sibling.tar; " &
      "if ( echo x > \"$S/lib/m1.nim\" ) 2>/dev/null; " &
      "then echo SIBLING-WRITTEN > out/ro.txt; " &
      "else echo SIBLING-WRITE-BLOCKED > out/ro.txt; fi"],
      outputs: @["out/primary.tar", "out/ro.txt", "out/sibling.tar"])
    let d1 = goal("dump", snap, dump, certify = true)
    check d1.status == gsCompleted
    check d1.treeBefore == snap.primaryRepo.gitTreeSha1
    check d1.treeAfter == snap.primaryRepo.gitTreeSha1
    check d1.outputs.len == 3
    # What the goal saw is byte-for-byte the requester's working trees.
    for (name, src) in [("primary", ws.app), ("sibling", ws.cairo)]:
      let tarBytes = fetchOutput(d1, "out/" & name & ".tar")
      check tarBytes.len > 0
      let into = base / ("seen-" & name)
      createDir(into)
      writeFile(base / (name & ".tar"), tarBytes)
      let x = execCmdEx(quoteShellCommand(["tar", "-xf", base / (name & ".tar"),
        "-C", into]))
      check x.exitCode == 0
      let diffs = mismatchesBetween(src, into)
      checkpoint(name & " as the goal saw it: " & $diffs)
      check diffs.len == 0
    # The sibling is read-only in the lease.
    let ro = fetchOutput(d1, "out/ro.txt")
    checkpoint("sibling write: " & ro)
    check "SIBLING-WRITE-BLOCKED" in ro
    check "SIBLING-WRITTEN" notin ro
    # No certificate while a sibling is present: the response says why, the
    # record carries the withholding, and the trusted profile's signing
    # check — the requester's `requesterVerifyGoal` over this very response
    # and record — refuses for it.
    check "repro develop sibling" in d1.reason
    let recBytes = orch.fetchExecutionRecord(workerId, d1.executionRecordDigest)
    check recBytes.len > 0
    if recBytes.len > 0:
      let rec = decodeExecutionRecord(recBytes)
      var withheld = false
      for det in rec.detections:
        if det.trigger == DevelopSiblingsWithheld: withheld = true
      check withheld
    let verdict = requesterVerifyGoal(d1, recBytes, RequesterGoalContext(
      expectedContent: contentIdOf(snap), project: "m1-daemon",
      platform: hostOS & "/" & hostCPU, target: dump.id, argv: dump.argv,
      isTest: true, baseCommit: snap.primaryRepo.baseCommitSha,
      issuer: "m1-requester"))
    checkpoint("requesterVerifyGoal: " & verdict.reason)
    check not verdict.ok
    check DevelopSiblingsWithheld in verdict.reason
    let coldMs = materializedAfter(1)
    let st1 = worker.status()
    checkpoint("worker status after goal 1: " & $st1)
    check worker.statusInt("worker_certificates_withheld") >= 1
    check worker.statusInt("worker_worktree_base_packs") == 2
    check worker.statusInt("worker_worktree_base_fetches") == 1
    check st1.getOrDefault("worker_worktree_clone", "").len > 0
    when defined(macosx):
      check st1.getOrDefault("worker_worktree_clone", "") == "clonefile"
    # FLOW-1: the worker hydrated over the requester's connection only.
    check worker.statusInt("peers_connected") == 0

    # -- Warm goals: the daemon's materialization time ------------------------
    let noop = GraphNode(id: "noop", argv: @["/bin/sh", "-c", "true"])
    var count = 1
    proc warmBlock(attempt: int): seq[float] =
      for round in 1 .. WarmRuns:
        newDiff(ws, "daemon attempt " & $attempt & " round " & $round)
        let capN = captureWorkspaceSnapshot(ws.app, "app", sink)
        check capN.ok
        check capN.manifest.primaryRepo.modified.len +
          capN.manifest.primaryRepo.deleted.len == 10
        let resp = goal("w" & $attempt & "r" & $round, capN.manifest, noop)
        check resp.status == gsCompleted
        check resp.treeBefore == capN.manifest.primaryRepo.gitTreeSha1
        inc count
        result.add(materializedAfter(count))
    var warm = warmBlock(1)
    echo "M1-DAEMON-TIMING attempt=1 clone=",
      worker.status().getOrDefault("worker_worktree_clone", ""),
      " coldMs=", coldMs.formatFloat(ffDecimal, 1), " warmMs=", ms(warm),
      " warmMinMs=", min(warm).formatFloat(ffDecimal, 1),
      " warmMedianMs=", median(warm).formatFloat(ffDecimal, 1)
    var daemonAttempts = 1
    while median(warm) >= WarmBudgetMs and daemonAttempts < 3:
      inc daemonAttempts
      warm = warmBlock(daemonAttempts)
      echo "M1-DAEMON-TIMING attempt=", daemonAttempts, " warmMs=", ms(warm),
        " warmMinMs=", min(warm).formatFloat(ffDecimal, 1),
        " warmMedianMs=", median(warm).formatFloat(ffDecimal, 1)
    check min(warm) > 0.0
    check median(warm) < WarmBudgetMs
    check worker.statusInt("worker_worktree_base_checkouts") == 2
    check worker.statusInt("worker_worktree_base_packs") == 2

  test "a repository with .gitattributes conversions materializes canonical bytes":
    let base = createTempDir("repro-m1-attrs-", "")
    defer: removeDir(base)
    let repo = base / "repo"
    gitRepo(repo)
    writeFile(repo / ".gitattributes", "*.txt text eol=crlf\n*.id ident\n")
    writeFile(repo / "f.txt", "a\nb\n")
    writeFile(repo / "g.id", "$Id$\n")
    writeFile(repo / "h.txt", "one\n")
    discard git(repo, "add", "-A")
    discard git(repo, "commit", "-q", "-m", "attributes")
    let cache = base / "cache.git"
    discard git(base, "clone", "-q", "--bare", repo, cache)
    writeFile(repo / "h.txt", "two\nthree\n")
    var blobs = initTable[Blake3Digest, seq[byte]]()
    let cap = captureRepoSnapshot(repo, "r",
      proc(d: Blake3Digest; b: seq[byte]) {.gcsafe, closure.} =
        {.cast(gcsafe).}: blobs[d] = b,
      shipBasePack = false)
    checkpoint("capture: " & cap.reason)
    check cap.ok
    let snap = cap.snapshot
    let reader = proc(d: Blake3Digest): Option[seq[byte]] {.gcsafe, closure.} =
      {.cast(gcsafe).}:
        if blobs.hasKey(d): some(blobs[d]) else: none(seq[byte])
    proc blobOf(rev: string): string =
      git(repo, "cat-file", "blob", rev) & "\n"
    let pool = newWorktreePool(base / "pool")
    createDir(base / "leases")
    let lease = pool.materializeLease(cache, snap, base / "leases" / "a", reader)
    let fresh = materializeRepoSnapshot(cache, snap, base / "leases" / "b",
      reader)
    for (what, mat) in [("pool lease", lease), ("fresh checkout", fresh)]:
      checkpoint(what & ": " & mat.reason)
      check mat.ok
      if mat.ok:
        # The bytes on disk are the blobs: no CRLF, no expanded $Id$.
        check readFile(mat.worktree / "f.txt") == "a\nb\n"
        check readFile(mat.worktree / "f.txt") == blobOf("HEAD:f.txt")
        check readFile(mat.worktree / "g.id") == "$Id$\n"
        check readFile(mat.worktree / "h.txt") == "two\nthree\n"
        # The native tree computation (what runs again after the goal)
        # agrees with git's.
        check reverifyTree(mat.worktree, mat.tracked, snap.gitTreeSha1,
          mat.gitlinks).ok
        check treeIdOf(mat.worktree, mat.tracked, mat.gitlinks).treeHex ==
          treeByGit(repo)
    # A repository cache with info/attributes (applied by git regardless of
    # --attr-source) is refused by the pool; the fresh checkout writes blob
    # bytes without git's checkout machinery, so it is unaffected.
    writeFile(cache / "info" / "attributes", "*.txt text eol=crlf\n")
    let refusedLease = pool.materializeLease(cache, snap, base / "leases" / "c",
      reader)
    checkpoint("pool with info/attributes: " & refusedLease.reason)
    check not refusedLease.ok
    check "info/attributes" in refusedLease.reason
    let freshAttrs = materializeRepoSnapshot(cache, snap,
      base / "leases" / "d", reader)
    checkpoint("fresh with info/attributes: " & freshAttrs.reason)
    check freshAttrs.ok
    if freshAttrs.ok:
      check readFile(freshAttrs.worktree / "f.txt") == "a\nb\n"
    removeFile(cache / "info" / "attributes")
    # A git older than 2.40 (no --attr-source) cannot check out canonically:
    # the pool refuses it with the reason; the fresh checkout needs only
    # `ls-tree` and `cat-file --batch`.
    when defined(posix):
      let oldGit = base / "old-git"
      writeFile(oldGit, "#!/bin/sh\n" &
        "if [ \"$1\" = --version ]; then echo 'git version 2.39.5'; exit 0; fi\n" &
        "exec git \"$@\"\n")
      setFilePermissions(oldGit, {fpUserRead, fpUserWrite, fpUserExec})
      let oldPool = newWorktreePool(base / "old-pool", gitExe = oldGit)
      let tooOld = oldPool.materializeLease(cache, snap, base / "leases" / "e",
        reader)
      checkpoint("git 2.39 (pool): " & tooOld.reason)
      check not tooOld.ok
      check "too old" in tooOld.reason
      let freshOld = materializeRepoSnapshot(cache, snap, base / "leases" / "f",
        reader, gitExe = oldGit)
      checkpoint("git 2.39 (fresh): " & freshOld.reason)
      check freshOld.ok

  test "a directory replaced by a file, and a deletion that empties a directory":
    let base = createTempDir("repro-m1-dirfile-", "")
    defer: removeDir(base)
    let repo = base / "repo"
    gitRepo(repo)
    createDir(repo / "a")
    createDir(repo / "d")
    writeFile(repo / "a" / "b.txt", "b\n")
    writeFile(repo / "a" / "c.txt", "c\n")
    writeFile(repo / "d" / "only.txt", "only\n")
    writeFile(repo / "keep.txt", "keep\n")
    discard git(repo, "add", "-A")
    discard git(repo, "commit", "-q", "-m", "dirs")
    let cache = base / "cache.git"
    discard git(base, "clone", "-q", "--bare", repo, cache)
    discard git(repo, "rm", "-q", "a/b.txt", "a/c.txt")
    writeFile(repo / "a", "a is a file now\n")       # directory -> file
    removeFile(repo / "d" / "only.txt")               # d/ emptied
    var blobs = initTable[Blake3Digest, seq[byte]]()
    let cap = captureRepoSnapshot(repo, "r",
      proc(d: Blake3Digest; b: seq[byte]) {.gcsafe, closure.} =
        {.cast(gcsafe).}: blobs[d] = b,
      shipBasePack = false)
    checkpoint("capture: " & cap.reason)
    check cap.ok
    check cap.snapshot.deleted == @["a/b.txt", "a/c.txt", "d/only.txt"]
    let reader = proc(d: Blake3Digest): Option[seq[byte]] {.gcsafe, closure.} =
      {.cast(gcsafe).}:
        if blobs.hasKey(d): some(blobs[d]) else: none(seq[byte])
    let pool = newWorktreePool(base / "pool")
    createDir(base / "leases")
    var results: seq[(string, MaterializeResult)] = @[]
    for (what, dest) in [("pool lease", base / "leases" / "a"),
                         ("fresh checkout", base / "leases" / "b")]:
      var mat: MaterializeResult
      try:
        mat =
          if what == "pool lease":
            pool.materializeLease(cache, cap.snapshot, dest, reader)
          else:
            materializeRepoSnapshot(cache, cap.snapshot, dest, reader)
      except CatchableError as err:
        mat = MaterializeResult(reason: "raised: " & err.msg)
      checkpoint(what & ": " & mat.reason)
      check mat.ok
      check mismatchesBetween(repo, dest).len == 0
      check fileExists(dest / "a")
      check not dirExists(dest / "d")

  test "capture refuses a state with no honest content id, index untouched":
    let base = createTempDir("repro-m1-capture-", "")
    defer: removeDir(base)
    let repo = base / "repo"
    gitRepo(repo)
    writeFile(repo / "a.txt", "a\n")
    writeFile(repo / "b.txt", "b\n")
    discard git(repo, "add", "-A")
    discard git(repo, "commit", "-q", "-m", "base")
    discard git(repo, "update-index", "--assume-unchanged", "a.txt")
    writeFile(repo / "a.txt", "edited behind git's back\n")
    let before = indexStamp(repo)
    var sunk = 0
    let res = captureWorkspaceSnapshot(repo, "r",
      proc(d: Blake3Digest; b: seq[byte]) {.gcsafe, closure.} =
        {.cast(gcsafe).}: inc sunk)
    checkpoint(res.reason)
    check not res.ok
    check "assume-unchanged" in res.reason and "a.txt" in res.reason
    check sunk == 0
    check indexStamp(repo) == before

  test "capture refuses an untracked nested repository and an oversized base pack":
    let base = createTempDir("repro-m1-capture2-", "")
    defer: removeDir(base)
    let repo = base / "repo"
    gitRepo(repo)
    writeFile(repo / "a.txt", "a\n")
    discard git(repo, "add", "-A")
    discard git(repo, "commit", "-q", "-m", "base")
    let noSink = proc(d: Blake3Digest; b: seq[byte]) {.gcsafe, closure.} =
      discard
    # Control: the clean repository captures, with a base pack (no remote:
    # its whole history is unpushed).
    let control = captureRepoSnapshot(repo, "r", noSink)
    checkpoint("control: " & control.reason)
    check control.ok
    check control.basePacks == 1
    # A base pack over its bound is refused with the reason.
    let tooBig = captureRepoSnapshot(repo, "r", noSink, maxBasePackBytes = 16)
    checkpoint("bounded pack: " & tooBig.reason)
    check not tooBig.ok
    check "more than a snapshot may carry" in tooBig.reason
    # An untracked nested git repository is refused, not shipped as a bare
    # commit id.
    let nested = repo / "vendor" / "lib"
    gitRepo(nested)
    writeFile(nested / "x.c", "int x;\n")
    discard git(nested, "add", "-A")
    discard git(nested, "commit", "-q", "-m", "nested")
    let before = indexStamp(repo)
    let res = captureRepoSnapshot(repo, "r", noSink)
    checkpoint("nested: " & res.reason)
    check not res.ok
    check "untracked nested git repository" in res.reason
    check "vendor/lib" in res.reason
    check indexStamp(repo) == before

  test "the requester's snapshot store is owner-only and swept after retention":
    let base = createTempDir("repro-m1-store-", "")
    defer: removeDir(base)
    let store = openSnapshotStore(base / "snapshots")
    defer: store.close()
    when defined(posix):
      check getFilePermissions(store.root) == {fpUserRead, fpUserWrite,
        fpUserExec}
    proc blob(s: string): (Blake3Digest, seq[byte]) =
      var b = newSeq[byte](s.len)
      for i, ch in s: b[i] = byte(ord(ch))
      (blake3.digest(b), b)
    let (dOld, bOld) = blob("published long ago\n")
    let (dNew, bNew) = blob("published again recently\n")
    store.putBlob(dOld, bOld)
    store.putBlob(dNew, bNew)
    proc manifestOf(d: Blake3Digest; size: int; tag: string):
        WorkspaceSnapshotManifest =
      WorkspaceSnapshotManifest(schema: ManifestSchema,
        primaryRepo: RepoSnapshot(repoId: tag, baseCommitSha: repeat('a', 40),
          gitTreeSha1: repeat('b', 40), modified: @[ModifiedFileEntry(
            relPath: "f", mode: ModeRegular, gitOid: repeat('c', 40),
            blake3Digest: d, size: uint64(size))]))
    let t0 = 1_700_000_000'i64
    let day = 24'i64 * 3600
    let pubOld = store.publishSnapshot(manifestOf(dOld, bOld.len, "old"),
      nowS = t0)
    discard store.publishSnapshot(manifestOf(dNew, bNew.len, "new1"),
      nowS = t0)
    discard store.publishSnapshot(manifestOf(dNew, bNew.len, "new2"),
      nowS = t0 + 20 * day)     # the same blob published again
    check pubOld.digests.len == 2
    check store.hasBlob(dOld)
    # Inside retention nothing goes.
    check store.sweepSnapshotStore(nowS = t0 + 29 * day) == 0
    check store.hasBlob(dOld)
    # Thirty days after its LAST publication a blob is deleted; one that was
    # published again later stays.
    let swept = store.sweepSnapshotStore(nowS = t0 + 31 * day)
    check swept >= 2                         # dOld and the old manifests
    check not store.hasBlob(dOld)
    check store.readBlob(pubOld.manifestDigest).isNone
    check store.hasBlob(dNew)
    let index = readFile(store.root / "snapshots.index")
    check digestHex(dOld) notin index
    check digestHex(dNew) in index
    check store.sweepSnapshotStore(nowS = t0 + 51 * day) >= 1
    check not store.hasBlob(dNew)

  test "a worker fetches a snapshot's blobs with bounded concurrency":
    # 40 distinct blobs; the fetcher answers each after a delay and records
    # how many requests were outstanding at once.
    var m = WorkspaceSnapshotManifest(schema: ManifestSchema,
      primaryRepo: RepoSnapshot(repoId: "r", baseCommitSha: repeat('a', 40),
        gitTreeSha1: repeat('b', 40)))
    var byDigest = initTable[Blake3Digest, seq[byte]]()
    for i in 0 ..< 40:
      let bytes = @[byte(i), byte(i shr 8), 7, 7]
      let d = blake3.digest(bytes)
      byDigest[d] = bytes
      m.primaryRepo.modified.add(ModifiedFileEntry(relPath: "f" & $(100 + i),
        mode: ModeRegular, gitOid: gitBlobOid(bytes), blake3Digest: d,
        size: uint64(bytes.len)))
    check validateManifest(m) == ""
    var inFlight = 0
    var peak = 0
    let got = waitFor fetchSnapshotBlobs(m,
      proc(d: array[32, byte]): Future[Option[seq[byte]]] {.async, gcsafe.} =
        {.cast(gcsafe).}:
          inc inFlight
          peak = max(peak, inFlight)
          await sleepAsync(5)
          dec inFlight
          return some(byDigest[d]))
    checkpoint("peak in flight: " & $peak)
    check got.ok
    check got.fetched == 40
    check peak <= MaxSnapshotFetchesInFlight
    check peak > 1                       # still concurrent

  test "a base tree over the checkout bounds and an oversized snapshot are refused":
    let base = createTempDir("repro-m1-bounds-", "")
    defer: removeDir(base)
    let repo = base / "repo"
    gitRepo(repo)
    writeFile(repo / "small.txt", "s\n")
    writeFile(repo / "big.bin", repeat('x', 4096))
    discard git(repo, "add", "-A")
    discard git(repo, "commit", "-q", "-m", "sizes")
    let cache = base / "cache.git"
    discard git(base, "clone", "-q", "--bare", repo, cache)
    writeFile(repo / "small.txt", "edited\n")
    var blobs = initTable[Blake3Digest, seq[byte]]()
    let cap = captureRepoSnapshot(repo, "r",
      proc(d: Blake3Digest; b: seq[byte]) {.gcsafe, closure.} =
        {.cast(gcsafe).}: blobs[d] = b,
      shipBasePack = false)
    check cap.ok
    let reader = proc(d: Blake3Digest): Option[seq[byte]] {.gcsafe, closure.} =
      {.cast(gcsafe).}:
        if blobs.hasKey(d): some(blobs[d]) else: none(seq[byte])
    createDir(base / "leases")
    # Control: within the bounds both materializers succeed.
    let okPool = newWorktreePool(base / "pool-ok")
    okPool.maxBaseTreeBytes = 8192
    check okPool.materializeLease(cache, cap.snapshot, base / "leases" / "ok1",
      reader).ok
    check materializeRepoSnapshot(cache, cap.snapshot, base / "leases" / "ok2",
      reader, maxTreeBytes = 8192).ok
    # The base tree's blobs total 4098 bytes: a 4000-byte total bound, and
    # a 1024-byte per-blob bound, refuse before anything is checked out.
    let totalPool = newWorktreePool(base / "pool-total")
    totalPool.maxBaseTreeBytes = 4000
    let blobPool = newWorktreePool(base / "pool-blob")
    blobPool.maxBlobBytes = 1024
    let refused = [
      totalPool.materializeLease(cache, cap.snapshot, base / "leases" / "t1",
        reader),
      materializeRepoSnapshot(cache, cap.snapshot, base / "leases" / "t2",
        reader, maxTreeBytes = 4000),
      blobPool.materializeLease(cache, cap.snapshot, base / "leases" / "b1",
        reader),
      materializeRepoSnapshot(cache, cap.snapshot, base / "leases" / "b2",
        reader, maxBlobBytes = 1024)]
    for i, mat in refused:
      checkpoint("bound " & $i & ": " & mat.reason)
      check not mat.ok
      check "more than a worker checks out" in mat.reason
      check not fileExists(base / "leases" / ["t1", "t2", "b1", "b2"][i] /
        "big.bin")
    check "checks out to more than 4000 bytes" in refused[0].reason
    check "big.bin of 4096 bytes" in refused[2].reason
    # A manifest naming more blob bytes than MaxSnapshotBlobBytes in total
    # is refused (each entry within MaxBlobBytes; 8 of them exactly fit).
    var m = WorkspaceSnapshotManifest(schema: ManifestSchema,
      primaryRepo: RepoSnapshot(repoId: "r", baseCommitSha: repeat('a', 40),
        gitTreeSha1: repeat('b', 40)))
    let perEntry = MaxSnapshotBlobBytes div 8
    check perEntry <= MaxBlobBytes
    for i in 0 ..< 8:
      var d: Blake3Digest
      d[0] = byte(i + 1)
      m.primaryRepo.modified.add(ModifiedFileEntry(relPath: "f" & $i,
        mode: ModeRegular, gitOid: repeat('c', 40), blake3Digest: d,
        size: perEntry))
    check validateManifest(m) == ""
    var extra: Blake3Digest
    extra[0] = 99
    m.primaryRepo.modified.add(ModifiedFileEntry(relPath: "f8",
      mode: ModeRegular, gitOid: repeat('c', 40), blake3Digest: extra,
      size: 1))
    checkpoint("oversized snapshot: " & validateManifest(m))
    check "more than " & $MaxSnapshotBlobBytes & " bytes of blobs" in
      validateManifest(m)

  test "the receiver's materialization status lines without a worktree pool":
    let base = createTempDir("repro-m1-status-", "")
    defer: removeDir(base)
    let r = newWorkerReceiver(WorkerConfig(leaseRoot: base / "leases",
      metaRoot: base / "meta"), nil, nil)
    check r.pool.isNil
    let lines = workerMaterializeStatusLines(r)
    checkpoint($lines)
    check "worker_worktree_leases=0" in lines
    check "worker_worktree_base_packs=0" in lines
    check "worker_worktree_clone=" in lines
    check "worker_materializations=0" in lines
    # With a pool the same lines carry its counters.
    let pooled = newWorkerReceiver(WorkerConfig(leaseRoot: base / "leases",
      metaRoot: base / "meta", worktreePoolRoot: base / "pool"), nil, nil)
    check not pooled.pool.isNil
    pooled.pool.leases = 3
    check "worker_worktree_leases=3" in workerMaterializeStatusLines(pooled)
