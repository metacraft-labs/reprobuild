## A shared clone pool's maintenance gc completes over a partial pool, and no
## pass leaves git's pack temporaries in the shared object store.
##
## Required behaviour: a pool is configured with ``repack.writeBitmaps``
## off, temporary objects are removed whether a pass succeeds or fails, and
## abandoned git pack temporaries in ``objects/pack/`` are reclaimed under
## the pool lock.
##
## What happened. Pools are partial: their blobs are promised by upstream
## (``blob:none`` refills write ``.promisor`` packs). The post-commit cache
## push adds ordinary, non-promisor objects whose trees name promised blobs.
## ``git gc`` in a bare repository writes a reachability bitmap by default,
## and a bitmap needs the full closure of its pack, so every pool gc died
## (``Failed to write bitmap index. Packfile doesn't have full closure``)
## after the new pack was already on disk as ``.tmp-<pid>-pack-<hash>.pack``
## beside a ``tmp_idx_*``. The failed pass was not stamped, so the next
## commit ran it again and left another full copy, same hash, new pid: 68.71
## GiB on one host, 94.5 GiB on another. The only sweep looked at marked
## ``repro/refill-*`` directories and preserved everything else.
##
## Design. Real ``git`` against real repositories, no mocks: an upstream that
## honours filters, a pool made by ``refreshSharedBare`` and made partial the
## way refills leave it (its blobs dropped and its pack marked promisor), a
## checkout wired to it by ``wireAlternates``, and the production
## ``pushCacheRef`` and ``maintainSharedBare``. The abandoned temporaries in
## the second and third cases are planted files with git's own names: a
## process that dies mid-repack leaves exactly such files, and the pid in the
## name is that of a process this test started and reaped, so it is
## genuinely dead. Every presence probe runs with ``GIT_NO_LAZY_FETCH=1`` so a
## probe cannot heal what it measures.
##
## Cases:
##
##   - ``maintenance_gc_completes_over_a_partial_pool_and_leaves_no_temporaries``
##     -- the reproduction: before the fix ``maintainSharedBare`` reports
##     ``git gc failed (128)`` and ``objects/pack`` keeps a
##     ``.tmp-<pid>-pack-*.pack`` and a ``tmp_idx_*``; a second pass adds
##     another copy. After it, both passes succeed, nothing is left, the
##     pushed commit and the pool's promised history stay readable.
##   - ``refresh_reclaims_abandoned_temporaries_and_keeps_live_ones`` -- the
##     sweep's rules, through the refresh that every ``repro sync`` runs: a
##     dead repack's files and a stale ownerless ``tmp_*`` go; a live repack's
##     file, a fresh ownerless one, the published packs and an unrelated file
##     stay.
##   - ``maintenance_not_due_still_reclaims_abandoned_temporaries`` -- a pool
##     whose budget is not reached is still swept, so a pool that never
##     reaches it again does not keep a dead pass's copy for good.

import std/[os, osproc, sets, strutils, tempfiles, times, unittest]

import shared_clones

when defined(posix):
  import std/posix

# A child that exits at once; its pid then names no process.
if paramCount() == 1 and paramStr(1) == "exit-at-once":
  quit(0)

proc processExistsForTest(pid: int): bool =
  ## Independent of the liveness probe under test. On Windows the premise is
  ## not re-checked here.
  when defined(posix):
    posix.kill(Pid(pid), cint(0)) == 0 or errno != ESRCH
  else:
    false

proc lastParts(paths: openArray[string]): seq[string] =
  for path in paths: result.add(path.lastPathPart)

proc q(value: string): string = quoteShell(value)

proc run(cwd: string; args: varargs[string]): tuple[code: int; output: string] =
  var cmd = "GIT_NO_LAZY_FETCH=1 git -C " & q(cwd)
  for a in args:
    cmd.add(" " & q(a))
  let res = execCmdEx(cmd)
  (code: res.exitCode, output: res.output.strip())

proc must(cwd: string; args: varargs[string]): string =
  let res = run(cwd, args)
  if res.code != 0:
    checkpoint("git " & args.join(" ") & " in " & cwd & " failed: " &
      res.output)
  doAssert res.code == 0, "fixture git command failed: " & args.join(" ")
  res.output

proc commitFile(work, name, body: string) =
  writeFile(work / name, body)
  discard must(work, "add", name)
  discard must(work, "commit", "-q", "-m", name)

const GlobalConfig = """
[user]
  name = Pool Temporaries Tester
  email = tester@example.invalid
[init]
  defaultBranch = main
"""

type Fixture = object
  root, up, pool, leaf, gitBin: string

proc makePoolPartial(pool: string) =
  ## Leave the pool as refills do: its history in a promisor pack that holds
  ## commits and trees, its blobs promised by upstream.
  let objects = must(pool, "rev-list", "--objects", "--all",
    "--filter=blob:none", "--no-object-names")
  let packDir = pool / "objects" / "pack"
  let packed = execCmdEx("GIT_NO_LAZY_FETCH=1 git -C " & q(pool) &
    " pack-objects -q " & q(packDir / "blobless"), input = objects & "\n")
  doAssert packed.exitCode == 0, packed.output
  let keep = "blobless-" & packed.output.strip()
  for kind, path in walkDir(packDir):
    if not path.lastPathPart.startsWith(keep): removeFile(path)
  for kind, path in walkDir(pool / "objects"):
    if kind == pcDir and path.lastPathPart.len == 2: removeDir(path)
  writeFile(packDir / (keep & ".promisor"), "")

proc setUp(root: string): Fixture =
  result.root = root
  result.gitBin = findExe("git")
  writeFile(root / "gitconfig", GlobalConfig)
  putEnv("GIT_CONFIG_GLOBAL", root / "gitconfig")
  putEnv("GIT_CONFIG_NOSYSTEM", "1")
  result.up = root / "up"
  createDir(result.up)
  discard must(result.up, "init", "-q")
  discard must(result.up, "config", "uploadpack.allowFilter", "true")
  for i in 1 .. 3:
    commitFile(result.up, "m" & $i, "upstream " & $i & "\n")
  let url = "file://" & result.up
  let created = refreshSharedBare(result.gitBin, root / "cache", url)
  doAssert created.ok, created.diagnostic
  result.pool = created.sharedBarePath
  makePoolPartial(result.pool)
  result.leaf = root / "ws" / "up"
  createDir(result.leaf.parentDir)
  discard must(root, "clone", "-q", url, result.leaf)
  let wired = wireAlternates(result.leaf, result.pool, result.gitBin)
  doAssert wired.ok, wired.diagnostic

proc tearDown() =
  delEnv("GIT_CONFIG_GLOBAL")
  delEnv("GIT_CONFIG_NOSYSTEM")

proc temporariesIn(pool: string): seq[string] =
  ## Git's pack temporaries in ``objects/pack/``, by git's own names, listed
  ## without the code under test.
  for kind, path in walkDir(pool / "objects" / "pack"):
    let name = path.lastPathPart
    if name.startsWith(".tmp-") or name.startsWith("tmp_"):
      result.add(name)

proc garbageCount(pool: string): int =
  for line in must(pool, "count-objects", "-v").splitLines():
    if line.startsWith("garbage:"):
      return parseInt(line["garbage:".len .. ^1].strip())
  -1

proc deadPid(): int =
  ## The pid of a process this test started and reaped.
  let child = startProcess(getAppFilename(), args = @["exit-at-once"])
  result = child.processID
  discard child.waitForExit()
  child.close()
  # Reaped, so nothing answers to it unless the kernel reuses it in the
  # next moment; ``kill(pid, 0)`` failing is the test's own premise.
  doAssert not processExistsForTest(result)

suite "shared clone pool: no abandoned pack temporaries":

  test "maintenance_gc_completes_over_a_partial_pool_and_leaves_no_temporaries":
    let root = createTempDir("repro-pool-tmp-gc-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    let promised = must(f.up, "rev-parse", "HEAD:m1")
    doAssert run(f.pool, "cat-file", "-e", promised).code != 0,
      "premise: the pool only promises upstream's blobs"
    var pushedTips: seq[string]
    for pass in 1 .. 2:
      # The post-commit cache push: ordinary objects whose tree names the
      # blobs the pool only promises.
      commitFile(f.leaf, "local" & $pass, "workspace change " & $pass & "\n")
      pushedTips.add(must(f.leaf, "rev-parse", "HEAD"))
      let pushed = pushCacheRef(f.gitBin, f.leaf, f.pool, "ws", "main")
      checkpoint("pushCacheRef: " & pushed.diagnostic)
      check pushed.ok
      let m = maintainSharedBare(f.gitBin, f.pool, @["ws"],
        defaultMaintenanceBudget(), force = true)
      checkpoint("pass " & $pass & ": " & m.diagnostic)
      check m.ok
      check m.ran
      check temporariesIn(f.pool).len == 0
      check garbageCount(f.pool) == 0
    for tip in pushedTips:
      check run(f.pool, "cat-file", "-e", tip).code == 0
    check run(f.leaf, "cat-file", "-e", pushedTips[^1]).code == 0
    # The gc kept the pool partial: its promised blob is still promised, not
    # fetched or dropped from the promisor's view.
    check must(f.pool, "config", "--get", "extensions.partialClone") == "origin"
    check run(f.pool, "rev-list", "--objects", "--all", "--missing=print").code == 0

  test "refresh_reclaims_abandoned_temporaries_and_keeps_live_ones":
    let root = createTempDir("repro-pool-tmp-refresh-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    let packDir = f.pool / "objects" / "pack"
    var published: seq[string]
    for kind, path in walkDir(packDir):
      published.add(path.lastPathPart)
    let dead = deadPid()
    let live = getCurrentProcessId()
    let hash = "8043f2e57aebc5ec763b65a0123456789abcdef0"
    let deadPack = packDir / (".tmp-" & $dead & "-pack-" & hash & ".pack")
    let deadRev = packDir / (".tmp-" & $dead & "-pack-" & hash & ".rev")
    let staleIdx = packDir / "tmp_idx_YGlArC"
    let stalePack = packDir / "tmp_pack_Ab12Cd"
    let liveRepack = packDir / (".tmp-" & $live & "-pack-" & hash & ".pack")
    let reusedPid = packDir / (".tmp-" & $live & "-pack-" & hash & ".rev")
    let freshIdx = packDir / "tmp_idx_eBsYfz"
    let unrelated = packDir / "operator-notes.txt"
    for path in [deadPack, deadRev, staleIdx, stalePack, liveRepack,
        reusedPid, freshIdx, unrelated]:
      writeFile(path, "abandoned bytes")
    let twoHoursAgo = getTime() - initDuration(hours = 2)
    setLastModificationTime(staleIdx, twoHoursAgo)
    setLastModificationTime(stalePack, twoHoursAgo)
    # A live pid on a two-day-old repack file is a reused pid, not its owner.
    setLastModificationTime(reusedPid, getTime() - initDuration(days = 2))

    # What ``repro health`` reports, before anything is removed.
    var reported: seq[string]
    for t in abandonedPackTemporaries(f.pool):
      reported.add(t.path.lastPathPart)
    check reported.toHashSet == lastParts([deadPack, deadRev, staleIdx,
      stalePack, reusedPid]).toHashSet

    commitFile(f.up, "m4", "upstream 4\n")
    let refreshed = refreshSharedBare(f.gitBin, root / "cache", "file://" & f.up)
    checkpoint(refreshed.diagnostic)
    check refreshed.ok
    for path in [deadPack, deadRev, staleIdx, stalePack, reusedPid]:
      check not fileExists(path)
    for path in [liveRepack, freshIdx, unrelated]:
      check fileExists(path)
    for name in published:
      check fileExists(packDir / name)
    check run(f.pool, "cat-file", "-e", must(f.up, "rev-parse", "HEAD")).code == 0

  test "maintenance_not_due_still_reclaims_abandoned_temporaries":
    let root = createTempDir("repro-pool-tmp-notdue-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    let packDir = f.pool / "objects" / "pack"
    let dead = deadPid()
    let deadPack = packDir / (".tmp-" & $dead &
      "-pack-a7d8597b92ac1cfcc511a1202e08394846b6510c.pack")
    let deadIdx = packDir / "tmp_idx_IB3aD6"
    writeFile(deadPack, "abandoned bytes")
    writeFile(deadIdx, "abandoned index")
    setLastModificationTime(deadIdx, getTime() - initDuration(hours = 2))
    let lenient = MaintenanceBudget(looseObjectLimit: 100000,
      sizeBytesLimit: 0, ageSeconds: 0)
    let m = maintainSharedBare(f.gitBin, f.pool, @["ws"], lenient)
    checkpoint(m.diagnostic)
    check m.ok
    check not m.ran
    check not fileExists(deadPack)
    check not fileExists(deadIdx)
    check m.reclaimedTemporaries.len == 2
