## A checkout fetches a missing object back through its pool, and a plain
## ``git fetch`` survives a dangling remote-tracking ref.
##
## Spec: ``reprobuild-specs/spec/Shared-Clone-Pool-Integrity.md`` §3.4, §3.5
## (SPI-AREQ-2, SPI-AREQ-5, SPI-GOAL-6); milestone SPI-2.
##
## Design. Real ``git`` against real repositories: an upstream, a pool made by
## ``refreshSharedBare`` and a leaf cloned with ``git clone --reference`` and
## then wired with ``wireAlternates`` — the call that writes the leaf's
## ``repro-pool`` promisor remote and ``fetch.hideRefs``.
## Objects are erased from the pool deterministically, by rebuilding its packs
## from ``rev-list --objects --all`` after dropping the ref that kept them;
## a gc in a partial-clone pool could lazily fetch them back and silently heal
## the fixture. Every presence probe runs with ``GIT_NO_LAZY_FETCH=1`` for the
## same reason; only the reads that are SUPPOSED to fetch run without it.
##
## Cases:
##
##   - ``missing_object_comes_back_into_leaf_and_pool`` — upstream still
##     serves a branch whose objects are gone from leaf and pool; reading it
##     in the leaf succeeds and leaves a copy in BOTH (SPI-AREQ-2).
##   - ``mutation_without_uploadpack_override_read_fails`` — the same read
##     with ``remote.repro-pool.uploadpack`` removed fails and fetches
##     nothing: upload-pack refuses to lazily fetch on a client's behalf.
##   - ``fetch_survives_dangling_ref_only_with_hiderefs`` — upstream rewrote a
##     branch and purged the old commit; with ``fetch.hideRefs`` removed,
##     ``git fetch`` dies on the dangling ref (the incident's error); with it,
##     ``git fetch`` succeeds and replaces the ref with upstream's new tip
##     (SPI-AREQ-5).
##   - ``nix_fetchgit_reads_configured_leaf_and_pool`` — ``builtins.fetchGit``
##     (libgit2) reads a configured leaf and a configured pool (SPI-GOAL-6),
##     and — the mutation — FAILS on the same leaf once
##     ``extensions.partialClone`` is added to it. That failure (measured with
##     Nix 2.32.8, 2.34.7 and Determinate Nix 2.34.8: "unsupported extension
##     name extensions.partialclone") is why a leaf gets
##     ``remote.repro-pool.promisor=true`` but not the extension the spec's
##     §3.4 table lists; the first case shows the promisor remote alone still
##     fetches on demand. Its fetcher cache is pointed at the temp root; the
##     store path it adds is content-addressed and inert. Skipped when ``nix``
##     is not on PATH.
##
##   - ``unmigrated_blobless_leaf_is_reported_and_healed_without_missing_tips``
##     — every current ref, commit and tree exists but their blobs do not;
##     fetch does not repair them, on-touch migration is reported, and a
##     subsequent read heals both leaf and pool. Wrong chain keys must also
##     be diagnosed, independently of object presence.
##
## No mocks. Hermetic: one ``createTempDir`` root, a private
## ``GIT_CONFIG_GLOBAL``, ``file://`` URLs throughout (a plain path would make
## git hardlink instead of borrow). Skip rule: ``git`` missing on PATH.
## The sibling compiler config shortens only the ordinary VCS lock deadline
## to 100 ms. The transport still uses real OS locks and its production
## indefinite-wait mode; this makes a bounded-wait mutation observable without
## making every suite execution wait two minutes. Child harness modes below
## exercise real exec/descriptor inheritance, rather than a mocked lock.

import std/[json, os, osproc, streams, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip
import repro_test_support/process_fixtures

import shared_clones

# Focused executable harness for the real production transport, not a mock:
# Git, filesystem operations, negotiation and locking remain real.
when declared(serveSharedPoolUploadPack):
  if paramCount() == 3 and paramStr(1) == "internal" and
      paramStr(2) == "shared-pool-upload-pack":
    quit serveSharedPoolUploadPack(findExe("git"), paramStr(3))

if paramCount() == 3 and paramStr(1) == "lock-inheritance-child":
  writeFile(paramStr(2), $getCurrentProcessId())
  while not fileExists(paramStr(3)): sleep(10)
  writeFile(paramStr(3) & ".done", "")
  quit(0)
if paramCount() == 4 and paramStr(1) == "lock-inheritance-owner":
  let owned = acquireVcsFileLock(paramStr(2), timeoutMs = -1)
  if not owned.acquired: quit(3)
  let child = startProcess(getAppFilename(), args = @["lock-inheritance-child",
    paramStr(3), paramStr(4)], options = {poParentStreams})
  while not fileExists(paramStr(3)):
    if child.peekExitCode() != -1: quit(4)
    sleep(10)
  # Intentionally exit without releasing: only an inherited OS descriptor
  # could retain ownership after this process is gone.
  quit(0)

if paramCount() == 2 and paramStr(1) == "refill-orphan-child":
  let stage = paramStr(2)
  createDir(stage / "objects/pack")
  defer: removeDir(stage)
  writeFile(stage / ".repro-refill-stage", "reprobuild.pool-refill.v1\n")
  writeFile(stage / "objects/pack/interrupted.pack", "interrupted tiny transfer")
  while true: sleep(10)

proc expectedPoolUploadPack(): string =
  when declared(leafPoolUploadPackCommand): leafPoolUploadPackCommand()
  else: LeafPoolUploadPack

let originalReproOverride = getEnv("REPROBUILD_REPRO")

proc q(value: string): string = quoteShell(value)

proc run(cwd: string; lazy: bool; args: varargs[string]):
    tuple[code: int; output: string] =
  # Lazy fetching ON is the variable UNSET, as in a user's shell: upload-pack
  # keeps an inherited value, so ``=0`` here would let the pool fetch on the
  # leaf's behalf even without the uploadpack override.
  var cmd = (if lazy: "env -u GIT_NO_LAZY_FETCH " else: "GIT_NO_LAZY_FETCH=1 ") &
    "git -C " & q(cwd)
  for a in args:
    cmd.add(" " & q(a))
  let res = execCmdEx(cmd)
  (code: res.exitCode, output: res.output.strip())

proc gitIn(cwd: string; args: varargs[string]): tuple[code: int;
                                                      output: string] =
  run(cwd, false, args)

proc must(cwd: string; args: varargs[string]): string =
  let res = gitIn(cwd, args)
  if res.code != 0:
    checkpoint("git " & args.join(" ") & " in " & cwd & " failed: " &
      res.output)
  doAssert res.code == 0, "fixture git command failed: " & args.join(" ")
  res.output

proc commitFile(work, name, body: string) =
  writeFile(work / name, body)
  discard must(work, "add", name)
  discard must(work, "commit", "-q", "-m", name)

proc has(repo, id: string): bool =
  gitIn(repo, "cat-file", "-e", id).code == 0

proc erasePoolUnreachable(pool: string) =
  ## Rebuild the pool's object store from exactly what its refs reach.
  let objects = must(pool, "rev-list", "--objects", "--all")
  var ids = ""
  for line in objects.splitLines():
    let id = line.split(' ')[0].strip()
    if id.len > 0: ids.add(id & "\n")
  let packDir = pool / "objects" / "pack"
  let packed = execCmdEx("GIT_NO_LAZY_FETCH=1 git -C " & q(pool) &
    " pack-objects -q " & q(packDir / "fresh"), input = ids)
  doAssert packed.exitCode == 0, packed.output
  let keep = "fresh-" & packed.output.strip()
  for kind, f in walkDir(packDir):
    if not f.lastPathPart.startsWith(keep):
      removeFile(f)
  for kind, d in walkDir(pool / "objects"):
    if kind == pcDir and d.lastPathPart.len == 2:
      removeDir(d)

const GlobalConfig = """
[user]
  name = SPI Tester
  email = tester@example.invalid
[init]
  defaultBranch = main
"""

type Fixture = object
  root, up, pool, leaf, gitBin: string

proc setUp(root: string; shallow = false): Fixture =
  result.root = root
  let transport = root / ("pool user's transport" & ExeExt)
  copyFile(getAppFilename(), transport)
  setFilePermissions(transport, getFilePermissions(getAppFilename()))
  putEnv("REPROBUILD_REPRO", transport)
  result.gitBin = findExe("git")
  result.up = root / "up"
  writeFile(root / "gitconfig", GlobalConfig)
  putEnv("GIT_CONFIG_GLOBAL", root / "gitconfig")
  putEnv("GIT_CONFIG_NOSYSTEM", "1")
  let url = "file://" & result.up
  createDir(result.up)
  discard must(result.up, "init", "-q")
  for i in 1 .. 2:
    commitFile(result.up, "m" & $i, $i & "\n")
  discard must(result.up, "checkout", "-q", "-b", "side")
  for i in 1 .. 3:
    commitFile(result.up, "s" & $i, "side " & $i & "\n")
  discard must(result.up, "checkout", "-q", "main")
  if shallow:
    discard must(result.up, "config", "uploadpack.allowFilter", "true")
  let created = refreshSharedBare(result.gitBin, root / "cache", url)
  doAssert created.ok, created.diagnostic
  result.pool = created.sharedBarePath
  result.leaf = root / "ws" / "up"
  createDir(result.leaf.parentDir)
  var cloneArgs = @["clone", "-q", "--reference", result.pool]
  if shallow: cloneArgs.add(["--depth=1", "--filter=blob:none", "--no-checkout"])
  cloneArgs.add([url, result.leaf])
  discard must(root, cloneArgs)
  let wired = wireAlternates(result.leaf, result.pool, result.gitBin)
  doAssert wired.ok and wired.diagnostic.len == 0, wired.diagnostic
  # Premise: the leaf holds no objects of its own; everything is borrowed.
  doAssert must(result.leaf, "count-objects", "-v").contains("in-pack: 0")

proc tearDown() =
  if originalReproOverride.len > 0: putEnv("REPROBUILD_REPRO", originalReproOverride)
  else: delEnv("REPROBUILD_REPRO")
  delEnv("GIT_CONFIG_GLOBAL")
  delEnv("GIT_CONFIG_NOSYSTEM")

proc loseSideFromPool(f: Fixture): string =
  ## Make ``side``'s objects missing from leaf and pool while upstream still
  ## serves them; returns the side tip.
  result = must(f.leaf, "rev-parse", "refs/remotes/origin/side")
  discard must(f.pool, "update-ref", "-d", "refs/heads/side")
  erasePoolUnreachable(f.pool)
  doAssert not has(f.pool, result) and not has(f.leaf, result)
  doAssert has(f.up, result)

proc makePoolBlobless(f: Fixture) =
  let objects = must(f.pool, "rev-list", "--objects", "--all",
    "--filter=blob:none", "--no-object-names")
  let packDir = f.pool / "objects" / "pack"
  let packed = execCmdEx("GIT_NO_LAZY_FETCH=1 git -C " & q(f.pool) &
    " pack-objects -q " & q(packDir / "blobless"), input = objects & "\n")
  doAssert packed.exitCode == 0, packed.output
  let keep = "blobless-" & packed.output.strip()
  for kind, path in walkDir(packDir):
    if not path.lastPathPart.startsWith(keep): removeFile(path)
  for kind, path in walkDir(f.pool / "objects"):
    if kind == pcDir and path.lastPathPart.len == 2: removeDir(path)
  writeFile(packDir / (keep & ".promisor"), "")

proc packedObjectIds(pool: string): seq[string] =
  for path in walkFiles(pool / "objects/pack/*.idx"):
    for line in must(pool, "verify-pack", "-v", path).splitLines():
      let fields = line.splitWhitespace()
      if fields.len >= 2 and fields[0].len in [40, 64] and
          fields[1] in ["commit", "tree", "blob", "tag"]:
        result.add(fields[0])

proc erasePoolIds(pool: string; erased: seq[string]) =
  let objects = must(pool, "cat-file", "--batch-all-objects",
    "--batch-check=%(objectname)")
  var retained = ""
  for id in objects.splitLines():
    if id.len in [40, 64] and id.allCharsInSet({'0'..'9', 'a'..'f'}) and
        id notin erased:
      retained.add(id & "\n")
  let packDir = pool / "objects/pack"
  let packed = execCmdEx("GIT_NO_LAZY_FETCH=1 git -C " & q(pool) &
    " pack-objects -q " & q(packDir / "erased"), input = retained)
  doAssert packed.exitCode == 0, packed.output
  let keep = "erased-" & packed.output.strip()
  for kind, path in walkDir(packDir):
    if not path.lastPathPart.startsWith(keep): removeFile(path)
  for kind, path in walkDir(pool / "objects"):
    if kind == pcDir and path.lastPathPart.len == 2: removeDir(path)
  writeFile(packDir / (keep & ".promisor"), "")

suite "SPI-2: leaves refetch through the pool":

  test "transport_waits_past_the_ordinary_vcs_lock_deadline":
    doAssert VcsLockDefaultTimeoutMs == 100, "the sibling cfg must be honored"
    let root = genTempPath("repro-spi2-lock-wait-", "")
    releaseDirAtProcessExit(root)
    createDir(root)
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    var held = acquireVcsFileLock(cacheEntryLockPath(f.pool))
    doAssert held.acquired
    var child: Process
    defer:
      releaseVcsFileLock(held)
      if child != nil:
        if child.running(): child.terminate()
        discard child.waitForExit()
        child.close()
    child = startProcess(getAppFilename(), args = @["internal",
      "shared-pool-upload-pack", f.pool], options = {poStdErrToStdOut})
    # Consume the real advertisement before submitting a request, so the
    # measured hold starts after the service is ready for protocol input.
    while true:
      let header = child.outputStream.readStr(4)
      doAssert header.len == 4
      let length = parseHexInt(header)
      if length == 0: break
      doAssert length >= 4
      doAssert child.outputStream.readStr(length - 4).len == length - 4
    let id = must(f.pool, "rev-parse", "HEAD")
    let want = "want " & id & "\n"
    child.inputStream.write(toHex(want.len + 4, 4) & want & "0000" & "0009done\n")
    child.inputStream.close()
    sleep(VcsLockDefaultTimeoutMs * 4)
    check child.peekExitCode() == -1
    releaseVcsFileLock(held)
    let output = child.outputStream.readAll()
    checkpoint(output)
    check child.waitForExit() == 0
    check "PACK" in output
    let impossibleParent = root / "not-a-directory"
    writeFile(impossibleParent, "")
    check not acquireVcsFileLock(impossibleParent / "lock", timeoutMs = -1).acquired

  test "indefinite_lock_is_not_retained_by_an_executed_child":
    let root = genTempPath("repro-spi2-lock-exec-", "")
    releaseDirAtProcessExit(root)
    createDir(root)
    defer: removeDir(root)
    let ready = root / "child-ready"
    let release = root / "release-child"
    let lockPath = root / "lock"
    var started = false
    defer:
      if started:
        writeFile(release, "")
        while not fileExists(release & ".done"): sleep(10)
    let owner = startProcess(getAppFilename(), args = @["lock-inheritance-owner",
      lockPath, ready, release], options = {poStdErrToStdOut})
    check owner.waitForExit() == 0
    owner.close()
    doAssert fileExists(ready)
    started = true
    when defined(posix):
      terminateAtProcessExit(parseInt(readFile(ready).strip()))
    var reacquired = acquireVcsFileLock(lockPath)
    defer: releaseVcsFileLock(reacquired)
    check reacquired.acquired

  test "concurrent_missing_history_refills_only_missing_objects":
    let root = createTempDir("repro-spi2 user's & %PATH% bounded-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    discard must(f.up, "config", "uploadpack.allowFilter", "true")
    let tip = loseSideFromPool(f)
    makePoolBlobless(f)
    let oldBlob = must(f.up, "rev-parse", "main:m2")
    let before = packedObjectIds(f.pool)
    doAssert not has(f.pool, oldBlob) and not has(f.pool, tip)
    let tracePath = root / "git-trace.jsonl"
    putEnv("GIT_TRACE2_EVENT", tracePath)
    defer: delEnv("GIT_TRACE2_EVENT")
    var readers: seq[Process]
    for i in 0 ..< 4:
      readers.add(startProcess("env -u GIT_NO_LAZY_FETCH git -C " &
        q(f.leaf) & " cat-file -p " & q(tip & "^{tree}"),
        options = {poEvalCommand, poStdErrToStdOut}))
    for reader in readers:
      let output = reader.outputStream.readAll()
      checkpoint(output)
      check reader.waitForExit() == 0
      check "could not lock config" notin output
      reader.close()
    var upstreamFetches = 0
    var physicalHistoryWalks = 0
    for line in readFile(tracePath).splitLines():
      if line.len == 0: continue
      let event = parseJson(line)
      if event["event"].getStr() == "start" and event.hasKey("argv"):
        var args: seq[string]
        for arg in event["argv"]: args.add(arg.getStr())
        if "fetch" in args and "origin" in args: inc upstreamFetches
        if "--topo-order" in args: inc physicalHistoryWalks
    check upstreamFetches == 1
    check physicalHistoryWalks == 0
    check has(f.pool, tip) and has(f.leaf, tip)
    check not has(f.pool, oldBlob)
    let after = packedObjectIds(f.pool)
    # Three side commits and their trees are the ONLY missing metadata.
    # Counting identities catches duplication even within a single new pack.
    check after.len == before.len + 6
    for i, id in after:
      check id notin after[0 ..< i]
    check must(f.leaf, "config", "maintenance.auto") == "false"
    check must(f.leaf, "config", "gc.auto") == "0"

  test "transport_rejects_malformed_and_interactive_requests":
    let root = createTempDir("repro-spi2-protocol-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    let id = must(f.pool, "rev-parse", "HEAD")
    proc pkt(payload: string): string =
      toHex(payload.len + 4, 4) & payload
    let command = q(getAppFilename()) & " internal shared-pool-upload-pack " &
      q(f.pool)
    for (request, diagnostic) in [
        ("zzzz", "invalid packet length"),
        ("0003", "invalid packet length"),
        ("0010short", "incomplete packet payload"),
        (pkt("want invalid\n"), "invalid wanted object id"),
        (pkt("want " & id & "\n") & "0000" & pkt("have " & id & "\n"),
          "only non-negotiating lazy fetches")]:
      let response = execCmdEx(command, input = request)
      checkpoint(response.output)
      check response.exitCode != 0
      check diagnostic in response.output
    let emptyRequest = execCmdEx(command, input = "0000")
    check emptyRequest.exitCode == 0
    let missing = repeat('f', 40)
    let beforeFailureRefs = must(f.pool, "show-ref")
    let failedRefill = execCmdEx(command,
      input = pkt("want " & missing & "\n") & "0000" & pkt("done\n"))
    check failedRefill.exitCode != 0
    check "could not refill shared pool" in failedRefill.output
    check not has(f.pool, missing)
    check must(f.pool, "show-ref") == beforeFailureRefs

  test "transport_refills_a_dangling_pool_tip_without_changing_refs":
    let root = createTempDir("repro-spi2-dangling-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    discard must(f.up, "config", "uploadpack.allowFilter", "true")
    let tip = loseSideFromPool(f)
    writeFile(f.pool / "refs/heads/side", tip & "\n")
    proc pkt(payload: string): string = toHex(payload.len + 4, 4) & payload
    let response = execCmdEx(q(getAppFilename()) &
      " internal shared-pool-upload-pack " & q(f.pool),
      input = pkt("want " & tip & " filter\n") & pkt("filter blob:none\n") &
        "0000" & pkt("done\n"))
    checkpoint(response.output)
    check response.exitCode == 0
    check has(f.pool, tip)
    check must(f.pool, "rev-parse", "refs/heads/side") == tip

  test "refill_repairs_a_missing_ancestor_below_a_present_pool_tip":
    for noSafeRefs in [false, true]:
      let root = createTempDir("repro-spi2-ancestor-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      discard must(f.up, "config", "uploadpack.allowFilter", "true")
      let tip = must(f.pool, "rev-parse", "refs/heads/side")
      let parent = must(f.pool, "rev-parse", tip & "~1")
      if noSafeRefs:
        discard must(f.pool, "update-ref", "-d", "refs/heads/main")
      discard must(f.pool, "tag", "-a", "broken-history", "-m", "tagged side", tip)
      discard must(f.pool, "-c", "core.commitGraph=true", "commit-graph",
        "write", "--reachable")
      doAssert fileExists(f.pool / "objects/info/commit-graph")
      # Demand the physically absent object rather than trusting the stale
      # alternate graph in the client. The pool deliberately retains that graph
      # so the transport's recovery must inspect physical ancestry itself.
      discard must(f.leaf, "config", "core.commitGraph", "false")
      let objects = must(f.pool, "cat-file", "--batch-all-objects",
        "--batch-check=%(objectname)")
      var retained = ""
      for id in objects.splitLines():
        if id.len in [40, 64] and id.allCharsInSet({'0'..'9', 'a'..'f'}) and
            id != parent:
          retained.add(id & "\n")
      let packDir = f.pool / "objects/pack"
      let packed = execCmdEx("GIT_NO_LAZY_FETCH=1 git -C " & q(f.pool) &
        " pack-objects -q " & q(packDir / "ancestor-hole"), input = retained)
      doAssert packed.exitCode == 0, packed.output
      let keep = "ancestor-hole-" & packed.output.strip()
      for kind, path in walkDir(packDir):
        if not path.lastPathPart.startsWith(keep): removeFile(path)
      for kind, path in walkDir(f.pool / "objects"):
        if kind == pcDir and path.lastPathPart.len == 2: removeDir(path)
      writeFile(packDir / (keep & ".promisor"), "")
      doAssert has(f.pool, tip) and not has(f.pool, parent)
      let refs = must(f.pool, "show-ref")
      let read = run(f.leaf, true, "cat-file", "-p", parent)
      checkpoint(read.output)
      check read.code == 0
      check has(f.pool, parent) and has(f.leaf, parent)
      check must(f.pool, "show-ref") == refs

  test "present_pool_only_object_never_contacts_upstream":
    let root = createTempDir("repro-spi2-pool-only-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    let stored = execCmdEx("git -C " & q(f.pool) & " hash-object -w --stdin",
      input = "unpublished pool-only object\n")
    doAssert stored.exitCode == 0, stored.output
    let id = stored.output.strip()
    discard must(f.pool, "config", "remote.origin.url", "file:///absent-upstream")
    proc pkt(payload: string): string = toHex(payload.len + 4, 4) & payload
    let response = execCmdEx(q(getAppFilename()) &
      " internal shared-pool-upload-pack " & q(f.pool),
      input = pkt("want " & id & "\n") & "0000" & pkt("done\n"))
    checkpoint(response.output)
    check response.exitCode == 0
    check "PACK" in response.output

  test "shallow_leaf_lazily_reads_a_missing_blob":
    let root = createTempDir("repro-spi2-shallow-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root, shallow = true)
    makePoolBlobless(f)
    # The borrowing leaf uses the pool as its sole promisor, just like an
    # existing wired reference checkout; retain its real shallow boundary.
    discard must(f.leaf, "config", "--unset-all", "remote.origin.promisor")
    discard must(f.leaf, "config", "--unset-all", "remote.origin.partialclonefilter")
    if gitIn(f.leaf, "config", "--get", "extensions.partialclone").code == 0:
      discard must(f.leaf, "config", "--unset-all", "extensions.partialclone")
    check must(f.leaf, "rev-parse", "--is-shallow-repository") == "true"
    let blob = must(f.up, "rev-parse", "main:m2")
    doAssert not has(f.leaf, blob) and not has(f.pool, blob)
    let read = run(f.leaf, true, "show", "HEAD:m2")
    checkpoint(read.output)
    check read.code == 0
    check read.output.splitLines()[^1] == "2"
    check has(f.leaf, blob) and has(f.pool, blob)
    check must(f.leaf, "rev-parse", "--is-shallow-repository") == "true"

  test "missing_object_comes_back_into_leaf_and_pool":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi2-heal-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      # The leaf carries §3.4 (less the format extension) and §3.5.
      check must(f.leaf, "config", "--get", "remote.repro-pool.url") ==
        poolFileUrl(f.pool)
      check must(f.leaf, "config", "--get", "remote.repro-pool.promisor") ==
        "true"
      check must(f.leaf, "config", "--get",
        "remote.repro-pool.partialclonefilter") == "blob:none"
      check must(f.leaf, "config", "--get", "remote.repro-pool.uploadpack") ==
        expectedPoolUploadPack()
      check must(f.leaf, "config", "--get",
        "remote.repro-pool.skipFetchAll") == "true"
      check gitIn(f.leaf, "config", "--get", "remote.repro-pool.fetch").code != 0
      # Deliberately NOT written into a leaf: see the module comment.
      check gitIn(f.leaf, "config", "--get", "extensions.partialClone").code != 0
      check must(f.leaf, "config", "--get-all", "fetch.hideRefs") ==
        LeafHiddenFetchRefs
      check must(f.pool, "config", "--get", "extensions.partialClone") ==
        "origin"
      check must(f.pool, "config", "--get", "remote.origin.promisor") == "true"
      let tip = loseSideFromPool(f)
      let read = run(f.leaf, true, "cat-file", "-p", tip & "^{tree}")
      checkpoint("lazy read: " & read.output)
      check read.code == 0
      check has(f.leaf, tip)
      check has(f.pool, tip)               # the pool kept a copy
      check has(f.leaf, tip & "~2")        # the history behind it came too

  test "mutation_without_uploadpack_override_read_fails":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi2-nooverride-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      discard must(f.leaf, "config", "--unset", "remote.repro-pool.uploadpack")
      let tip = loseSideFromPool(f)
      let read = run(f.leaf, true, "cat-file", "-p", tip & "^{tree}")
      checkpoint("lazy read without override: " & read.output)
      check read.code != 0
      check not has(f.leaf, tip)
      check not has(f.pool, tip)

  test "fetch_survives_dangling_ref_only_with_hiderefs":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi2-hiderefs-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let old = must(f.leaf, "rev-parse", "refs/remotes/origin/side")
      # Upstream rewrites side and purges the old commits.
      discard must(f.up, "checkout", "-q", "-B", "side", "main")
      commitFile(f.up, "rewritten", "r\n")
      discard must(f.up, "checkout", "-q", "main")
      discard must(f.up, "reflog", "expire", "--expire=now", "--all")
      discard must(f.up, "gc", "-q", "--prune=now")
      let newTip = must(f.up, "rev-parse", "side")
      doAssert not has(f.up, old)
      check refreshSharedBare(f.gitBin, root / "cache", "file://" & f.up).ok
      # Leave the leaf's ref dangling (a refresh's detector would remove it;
      # this case is about plain git fetch, outside reprobuild).
      if gitIn(f.leaf, "rev-parse", "-q", "--verify",
          "refs/remotes/origin/side").code != 0:
        discard must(f.leaf, "update-ref", "refs/remotes/origin/side", old)
      erasePoolUnreachable(f.pool)
      doAssert not has(f.leaf, old) and not has(f.pool, old)
      # Without fetch.hideRefs: the incident's error.
      discard must(f.leaf, "config", "--unset-all", "fetch.hideRefs")
      let bad = run(f.leaf, true, "fetch", "origin")
      checkpoint("fetch without hideRefs: " & bad.output)
      check bad.code != 0
      check "bad object" in bad.output
      # With it: success, and the ref now names upstream's new tip.
      discard must(f.leaf, "config", "--add", "fetch.hideRefs",
        LeafHiddenFetchRefs)
      let good = run(f.leaf, true, "fetch", "origin")
      checkpoint("fetch with hideRefs: " & good.output)
      check good.code == 0
      check must(f.leaf, "rev-parse", "refs/remotes/origin/side") == newTip

  test "nix_fetchgit_reads_configured_leaf_and_pool":
    if findExe("git").len == 0 or findExe("nix").len == 0:
      skip("needs git and nix on PATH")
    else:
      let root = createTempDir("repro-spi2-nix-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let head = must(f.leaf, "rev-parse", "HEAD")
      for (what, url) in [("leaf", "file://" & f.leaf),
                          ("pool", "file://" & f.pool)]:
        let expr = "(builtins.fetchGit { url = \"" & url & "\"; rev = \"" &
          head & "\"; }).outPath"
        let res = execCmdEx("XDG_CACHE_HOME=" & q(root / "xdg-cache") &
          " nix eval --raw --impure --extra-experimental-features nix-command" &
          " --expr " & q(expr))
        checkpoint("nix fetchGit of the " & what & ": " & res.output)
        check res.exitCode == 0
        if res.exitCode == 0:
          let outPath = res.output.strip().splitLines()[^1]
          check fileExists(outPath / "m2")
      # Mutation: the spec's leaf extension makes the leaf unreadable.
      discard must(f.leaf, "config", "core.repositoryFormatVersion", "1")
      discard must(f.leaf, "config", "extensions.partialClone",
        LeafPoolRemoteName)
      let expr = "(builtins.fetchGit { url = \"file://" & f.leaf &
        "\"; rev = \"" & head & "\"; }).outPath"
      let broken = execCmdEx("XDG_CACHE_HOME=" & q(root / "xdg-cache-2") &
        " nix eval --raw --impure --extra-experimental-features nix-command" &
        " --expr " & q(expr))
      checkpoint("nix fetchGit of a leaf with the extension: " & broken.output)
      check broken.exitCode != 0
      check "partialclone" in broken.output.toLowerAscii

  test "unmigrated_blobless_leaf_is_reported_and_healed_without_missing_tips":
    let root = createTempDir("repro-spi2-unmigrated-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    # Keep every commit and tree, but no blobs: the incident's blob:none
    # pool, with current refs intact. Repacking explicitly prevents a lazy
    # fetch or an expiry policy from accidentally healing the fixture.
    let objects = must(f.pool, "rev-list", "--objects", "--all",
      "--filter=blob:none", "--no-object-names")
    let packDir = f.pool / "objects" / "pack"
    let packed = execCmdEx("GIT_NO_LAZY_FETCH=1 git -C " & q(f.pool) &
      " pack-objects -q " & q(packDir / "blobless"), input = objects & "\n")
    doAssert packed.exitCode == 0, packed.output
    let keep = "blobless-" & packed.output.strip()
    for kind, path in walkDir(packDir):
      if not path.lastPathPart.startsWith(keep): removeFile(path)
    for kind, path in walkDir(f.pool / "objects"):
      if kind == pcDir and path.lastPathPart.len == 2: removeDir(path)
    writeFile(packDir / (keep & ".promisor"), "")
    discard must(f.leaf, "remote", "remove", LeafPoolRemoteName)
    discard must(f.leaf, "config", "--unset-all", "fetch.hideRefs")
    let blob = must(f.up, "rev-parse", "main:m2")
    for line in must(f.leaf, "show-ref").splitLines():
      doAssert has(f.leaf, line.splitWhitespace()[0])
    doAssert has(f.leaf, "HEAD^{tree}")
    doAssert not has(f.leaf, blob) and not has(f.pool, blob)
    # Ordinary fetch succeeds yet leaves current-commit blobs missing.
    check run(f.leaf, true, "fetch", "origin").code == 0
    check not has(f.leaf, blob)
    check run(f.leaf, true, "show", "HEAD:m2").code != 0
    let report = checkLeaf(f.gitBin, f.leaf, lcmReport, root / "cache")
    check report.configured
    check report.hasMessages
    check "refetch chain" in messages([report]).join("\n")
    let read = run(f.leaf, true, "show", "HEAD:m2")
    check read.code == 0
    check read.output.splitLines()[^1] == "2"
    check has(f.leaf, blob) and has(f.pool, blob)
    check not checkLeaf(f.gitBin, f.leaf, lcmReport, root / "cache").hasMessages
    for (key, value) in [
        ("url", "file:///missing-pool"),
        ("promisor", "false"),
        ("partialclonefilter", "tree:0"),
        ("uploadpack", "git-upload-pack"),
        ("skipFetchAll", "false"),
        ("fetch", "+refs/heads/*:refs/remotes/repro-pool/*")]:
      discard must(f.leaf, "config", "remote.repro-pool." & key, value)
      let wrong = checkLeaf(f.gitBin, f.leaf, lcmReport, root / "cache")
      checkpoint("incorrect refetch chain key: " & key)
      check wrong.hasMessages
      check wrong.configured
      check "refetch chain" in messages([wrong]).join("\n")
      check not checkLeaf(f.gitBin, f.leaf, lcmReport, root / "cache").hasMessages
    for key in ["url", "promisor"]:
      let name = "remote.repro-pool." & key
      let expected = must(f.leaf, "config", "--get", name)
      discard must(f.leaf, "config", "--add", name, expected)
      let duplicate = checkLeaf(f.gitBin, f.leaf, lcmReport, root / "cache")
      checkpoint("duplicate refetch chain key: " & key)
      check duplicate.hasMessages
      check duplicate.configured
      check must(f.leaf, "config", "--get-all", name) == expected
      check not checkLeaf(f.gitBin, f.leaf, lcmReport, root / "cache").hasMessages

  test "cache_push_does_not_refetch_a_missing_similar_blob_under_its_lock":
    let root = createTempDir("repro-spi2-cache-push-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    # Deterministic, incompressible-enough content gives Git a compelling old
    # delta base. Construct the new blob without ever reading that base from
    # the blobless pool, using the same known bytes as the private upstream.
    var body = newStringOfCap(200000)
    var randomState = 0x12345678'u32
    for i in 0 ..< 200000:
      randomState = randomState xor (randomState shl 13)
      randomState = randomState xor (randomState shr 17)
      randomState = randomState xor (randomState shl 5)
      body.add(char(ord('a') + int(randomState mod 26)))
    commitFile(f.up, "large-base", body)
    let base = must(f.up, "rev-parse", "HEAD:large-base")
    check refreshSharedBare(f.gitBin, root / "cache", "file://" & f.up).ok
    discard must(f.leaf, "fetch", "origin")
    discard must(f.leaf, "reset", "--soft", "refs/remotes/origin/main")
    discard must(f.leaf, "read-tree", "HEAD")
    let objects = must(f.pool, "cat-file", "--batch-all-objects",
      "--batch-check=%(objectname)")
    var retained = ""
    for id in objects.splitLines():
      if id.len in [40, 64] and id.allCharsInSet({'0'..'9', 'a'..'f'}) and
          id != base:
        retained.add(id & "\n")
    let packDir = f.pool / "objects/pack"
    let packed = execCmdEx("GIT_NO_LAZY_FETCH=1 git -C " & q(f.pool) &
      " pack-objects -q " & q(packDir / "without-base"), input = retained)
    doAssert packed.exitCode == 0, packed.output
    let keep = "without-base-" & packed.output.strip()
    for kind, path in walkDir(packDir):
      if not path.lastPathPart.startsWith(keep): removeFile(path)
    for kind, path in walkDir(f.pool / "objects"):
      if kind == pcDir and path.lastPathPart.len == 2: removeDir(path)
    writeFile(packDir / (keep & ".promisor"), "")
    doAssert not has(f.pool, base) and not has(f.leaf, base)
    var changed = body
    changed[100000 .. 100007] = "MUTATION"
    writeFile(f.leaf / "large-base", changed)
    discard must(f.leaf, "add", "large-base")
    discard must(f.leaf, "-c", "core.hooksPath=/dev/null", "commit", "-q",
      "-m", "similar blob without its old base")
    doAssert not has(f.pool, base) and not has(f.leaf, base)
    let head = must(f.leaf, "rev-parse", "HEAD")
    let tracePath = root / "cache-push-trace.jsonl"
    putEnv("GIT_TRACE2_EVENT", tracePath)
    defer: delEnv("GIT_TRACE2_EVENT")
    let pushed = pushCacheRef(f.gitBin, f.leaf, f.pool, "push-audit", "main")
    checkpoint(pushed.diagnostic)
    check pushed.ok
    check must(f.pool, "rev-parse", "refs/cache/push-audit/main") == head
    check not has(f.pool, base) and not has(f.leaf, base)
    var fetches = 0
    for line in readFile(tracePath).splitLines():
      if line.len == 0: continue
      let event = parseJson(line)
      if event["event"].getStr() == "start" and event.hasKey("argv"):
        for arg in event["argv"]:
          if arg.getStr() == "fetch": inc fetches
    check fetches == 0

  test "sequential_and_concurrent_distinct_refills_keep_a_nonretaining_frontier":
    let root = createTempDir("repro-spi2-frontier-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    discard must(f.up, "config", "uploadpack.allowFilter", "true")
    makePoolBlobless(f)
    let initial = packedObjectIds(f.pool)
    let refs = must(f.pool, "show-ref")
    proc addTip(branch, parent, body: string): string =
      discard must(f.up, "checkout", "-q", "-B", branch, parent)
      commitFile(f.up, "fresh", body)
      must(f.up, "rev-parse", "HEAD")
    proc readTip(id: string) =
      let read = run(f.leaf, true, "cat-file", "-p", id)
      checkpoint(read.output)
      check read.code == 0
    let a = addTip("fresh-a", "main", "a")
    readTip(a)
    let b = addTip("fresh-b", a, "b")
    let tracePath = root / "frontier-transfer.jsonl"
    putEnv("GIT_TRACE2_EVENT", tracePath)
    readTip(b)
    delEnv("GIT_TRACE2_EVENT")
    var usedPriorHintAndRefs = false
    for line in readFile(tracePath).splitLines():
      if line.len == 0: continue
      let event = parseJson(line)
      if event["event"].getStr() == "start" and event.hasKey("argv"):
        var args: seq[string]
        for arg in event["argv"]: args.add(arg.getStr())
        if "fetch" in args and "origin" in args:
          usedPriorHintAndRefs = "--negotiation-tip=" & a in args and
            "--negotiation-tip=*" in args and
            "fetch.negotiationAlgorithm=consecutive" in args
    check usedPriorHintAndRefs
    check packedObjectIds(f.pool).len == initial.len + 4
    let hintPath = f.pool / "repro/refill-tips"
    check readFile(hintPath).splitWhitespace() == @[b]
    let c = addTip("fresh-c", a, "c")
    readTip(c)
    check packedObjectIds(f.pool).len == initial.len + 6
    let d = addTip("fresh-d", b, "d")
    let e = addTip("fresh-e", c, "e")
    var readers: seq[Process]
    for id in [d, e]:
      readers.add(startProcess("env -u GIT_NO_LAZY_FETCH git -C " &
        q(f.leaf) & " cat-file -p " & q(id),
        options = {poEvalCommand, poStdErrToStdOut}))
    for reader in readers:
      checkpoint(reader.outputStream.readAll())
      check reader.waitForExit() == 0
      reader.close()
    let after = packedObjectIds(f.pool)
    check after.len == initial.len + 10
    for i, id in after: check id notin after[0 ..< i]
    let hints = readFile(hintPath).splitWhitespace()
    check hints.len == 2 and d in hints and e in hints
    check must(f.pool, "show-ref") == refs
    # The hint file is not a Git reachability/retention root. Expire exactly
    # what the actual refs no longer reach, then show stale hints are pruned.
    let reachable = must(f.pool, "rev-list", "--all").splitWhitespace()
    check d notin reachable and e notin reachable
    var expired: seq[string]
    for id in after:
      if id notin initial: expired.add(id)
    erasePoolIds(f.pool, expired)
    doAssert not has(f.pool, d) and not has(f.pool, e)
    let next = addTip("fresh-next", d, "next")
    readTip(next)
    check readFile(hintPath).splitWhitespace() == @[next]
    check must(f.pool, "show-ref") == refs

  test "tree_refills_do_not_duplicate_a_shared_unpromised_subtree":
    let root = createTempDir("repro-spi2-tree-dedup-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    discard must(f.up, "config", "uploadpack.allowFilter", "true")
    createDir(f.up / "common")
    commitFile(f.up, "common/shared", "same subtree")
    commitFile(f.up, "root-file", "a")
    let a = must(f.up, "rev-parse", "HEAD^{tree}")
    commitFile(f.up, "root-file", "b")
    let b = must(f.up, "rev-parse", "HEAD^{tree}")
    check refreshSharedBare(f.gitBin, root / "cache", "file://" & f.up).ok
    let commits = must(f.pool, "rev-list", "--all")
    let packDir = f.pool / "objects/pack"
    let packed = execCmdEx("GIT_NO_LAZY_FETCH=1 git -C " & q(f.pool) &
      " pack-objects -q " & q(packDir / "treeless"), input = commits & "\n")
    doAssert packed.exitCode == 0, packed.output
    let keep = "treeless-" & packed.output.strip()
    for kind, path in walkDir(packDir):
      if not path.lastPathPart.startsWith(keep): removeFile(path)
    for kind, path in walkDir(f.pool / "objects"):
      if kind == pcDir and path.lastPathPart.len == 2: removeDir(path)
    writeFile(packDir / (keep & ".promisor"), "")
    let initial = packedObjectIds(f.pool)
    for id in [a, b]:
      let read = run(f.leaf, true, "cat-file", "-p", id)
      checkpoint(read.output)
      check read.code == 0
    let after = packedObjectIds(f.pool)
    check after.len == initial.len + 3
    for i, id in after: check id notin after[0 ..< i]

  test "refilled_tag_advances_the_commit_frontier_without_retaining_refs":
    let root = createTempDir("repro-spi2-tag-frontier-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    discard must(f.up, "config", "uploadpack.allowFilter", "true")
    discard must(f.up, "checkout", "-q", "-b", "tag-history", "main")
    commitFile(f.up, "tagged", "tagged")
    let a = must(f.up, "rev-parse", "HEAD")
    discard must(f.up, "tag", "-a", "new-tag", "-m", "annotated tag")
    let tag = must(f.up, "rev-parse", "refs/tags/new-tag")
    check run(f.leaf, true, "cat-file", "-p", tag).code == 0
    check readFile(f.pool / "repro/refill-tips").splitWhitespace() == @[a]
    let before = packedObjectIds(f.pool)
    commitFile(f.up, "tagged", "child")
    let b = must(f.up, "rev-parse", "HEAD")
    check run(f.leaf, true, "cat-file", "-p", b).code == 0
    let after = packedObjectIds(f.pool)
    check after.len == before.len + 2
    for i, id in after: check id notin after[0 ..< i]
    check readFile(f.pool / "repro/refill-tips").splitWhitespace() == @[b]

  test "damaged_hint_history_is_repaired_without_reusing_the_invalid_have":
    for unrelated in [false, true]:
      checkpoint("unrelated unavailable hint history: " & $unrelated)
      let root = createTempDir("repro-spi2-damaged-hint-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      discard must(f.up, "config", "uploadpack.allowFilter", "true")
      discard must(f.up, "checkout", "-q", "-b", "hint-history", "main")
      for i in 1 .. 3: commitFile(f.up, "hinted", $i)
      let tip = must(f.up, "rev-parse", "HEAD")
      let parent = must(f.up, "rev-parse", "HEAD~1")
      check run(f.leaf, true, "cat-file", "-p", tip).code == 0
      check readFile(f.pool / "repro/refill-tips").splitWhitespace() == @[tip]
      var child: string
      if unrelated:
        discard must(f.up, "checkout", "-q", "-B", "unrelated", "main")
        commitFile(f.up, "unrelated", "complete wanted history")
        child = must(f.up, "rev-parse", "HEAD")
      erasePoolIds(f.pool, @[parent])
      doAssert has(f.pool, tip) and not has(f.pool, parent)
      if unrelated:
        erasePoolIds(f.up / ".git", @[parent])
      else:
        commitFile(f.up, "hinted", "child")
        child = must(f.up, "rev-parse", "HEAD")
      let read = run(f.leaf, true, "cat-file", "-p", child)
      checkpoint(read.output)
      check read.code == 0
      check has(f.pool, child)
      if unrelated:
        check not has(f.pool, parent)
      else:
        check has(f.pool, parent)
      check readFile(f.pool / "repro/refill-tips").splitWhitespace() == @[child]
      let after = packedObjectIds(f.pool)
      for i, id in after: check id notin after[0 ..< i]

  test "invalid_or_unreadable_hint_file_refuses_refill_before_writing_objects":
    let root = createTempDir("repro-spi2-invalid-hint-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    discard must(f.up, "config", "uploadpack.allowFilter", "true")
    let tip = loseSideFromPool(f)
    let refs = must(f.pool, "show-ref")
    let before = packedObjectIds(f.pool)
    let hintPath = f.pool / "repro/refill-tips"
    writeFile(hintPath, "--inject-option\n")
    let invalid = run(f.leaf, true, "cat-file", "-p", tip)
    check invalid.code != 0
    check "could not read refill negotiation tips" in invalid.output
    check packedObjectIds(f.pool) == before
    check must(f.pool, "show-ref") == refs
    removeFile(hintPath)
    createDir(hintPath)
    let unreadable = run(f.leaf, true, "cat-file", "-p", tip)
    check unreadable.code != 0
    check "could not read refill negotiation tips" in unreadable.output
    check packedObjectIds(f.pool) == before

  test "killed_refill_stages_are_reclaimed_without_touching_unknown_directories":
    let root = createTempDir("repro-spi2-abandoned-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    discard must(f.up, "config", "uploadpack.allowFilter", "true")
    let tip = loseSideFromPool(f)
    let reproDir = f.pool / "repro"
    let orphan = reproDir / "refill-killed-child"
    # A real killed child cannot run its defer. The marker and tiny partial
    # payload reproduce the persistent state of a killed large Git transfer.
    var child = startProcess(getAppFilename(),
      args = @["refill-orphan-child", orphan], options = {poParentStreams})
    defer:
      if child.running():
        child.kill()
        discard child.waitForExit()
      child.close()
    while not fileExists(orphan / "objects/pack/interrupted.pack"):
      doAssert child.peekExitCode() == -1, "orphan fixture child exited early"
      sleep(10)
    child.kill()
    discard child.waitForExit()
    doAssert fileExists(orphan / "objects/pack/interrupted.pack")
    let unmanaged = reproDir / "refill-unmanaged"
    let unknown = reproDir / "refill-other-version"
    createDir(unmanaged)
    createDir(unknown)
    writeFile(unmanaged / "keep", "user-owned scratch")
    writeFile(unknown / ".repro-refill-stage", "different-tool.v2\n")
    writeFile(unknown / "keep", "unknown version")
    when defined(posix):
      # Refuse before fetching more bytes if an owned abandoned stage cannot
      # be removed. Restore permissions so normal retry can reclaim it.
      let permissions = getFilePermissions(orphan / "objects/pack")
      let before = packedObjectIds(f.pool)
      setFilePermissions(orphan / "objects/pack", {fpUserRead, fpUserExec})
      let tracePath = root / "orphan-refusal-trace.jsonl"
      putEnv("GIT_TRACE2_EVENT", tracePath)
      try:
        let refused = run(f.leaf, true, "cat-file", "-p", tip)
        check refused.code != 0
        check "could not remove abandoned pool refill stage" in refused.output
        check packedObjectIds(f.pool) == before
        var upstreamFetches = 0
        for line in readFile(tracePath).splitLines():
          if line.len == 0: continue
          let event = parseJson(line)
          if event["event"].getStr() == "start" and event.hasKey("argv"):
            var args: seq[string]
            for arg in event["argv"]: args.add(arg.getStr())
            if "fetch" in args and "origin" in args: inc upstreamFetches
        check upstreamFetches == 0
      finally:
        delEnv("GIT_TRACE2_EVENT")
        if dirExists(orphan / "objects/pack"):
          setFilePermissions(orphan / "objects/pack", permissions)
    let read = run(f.leaf, true, "cat-file", "-p", tip)
    checkpoint(read.output)
    check read.code == 0
    check not dirExists(orphan)
    check readFile(unmanaged / "keep") == "user-owned scratch"
    check readFile(unknown / "keep") == "unknown version"
    check has(f.pool, tip) and has(f.leaf, tip)
