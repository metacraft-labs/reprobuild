## The store's ROOT-REACHABILITY guard, asked about ONE named entry.
##
## Spec: ``reprobuild-specs/Local-Content-Addressed-Store.md`` §"Garbage
## Collection" (root reachability, and the unlink grace that is not a
## retention policy).
##
## WHAT IS AND IS NOT UNDER TEST
##
## The cross-job coordination this milestone was originally about is gone:
## the toolchain store is guest-local, one copy per job, discarded with the
## guest. What survives is the WITHIN-JOB relationship — a job registers a
## root, the root holds the entries the job materialised, and the overlay a
## later milestone composes IS such a root. That relationship lives inside a
## single guest and is exactly what these cases measure.
##
## ``gc`` already leaves held prefixes alone, because they are not in
## ``deadSet``. That is the right behaviour for a SWEEP and the wrong
## behaviour for a caller that NAMED an entry: "I could not collect that, and
## here is who is holding it" and "there was nothing to collect" must not
## arrive as the same silent success. ``gcPrefix`` is what distinguishes them,
## and it is what is tested here.
##
## BOTH ARMS ARE REQUIRED, and the reason is that an unconditional refusal
## would pass the first arm on its own while making the store impossible to
## reclaim. So every refusal case is paired with the same entry, same store,
## same call, after the root is released — and the second call must succeed.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED. Every
## case runs against a real ``Store`` on a real temporary directory, with real
## prefix directories realised through the production
## ``realizeDirectoryAsPrefix`` and a real SQLite index. The GC then walks the
## same on-disk layout the engine reads.
##
## The CLOCK is not mocked either: the grace window is crossed by setting the
## quarantined directory's mtime into the past, which is the same technique
## ``t_a4_p4_eviction`` uses. That is an injected input, not a stand-in for a
## collaborator, and it is the alternative to sleeping for five minutes.

import std/[os, sequtils, strutils, tempfiles, times, unittest]

from repro_core/paths import extendedPath

import repro_local_store

type Fixture = object
  root: string
  store: Store

proc openFixture(tag: string): Fixture =
  let root = createTempDir("repro-win-store-gc-" & tag & "-", "")
  Fixture(root: root, store: openStore(root / "store"))

proc closeFixture(f: var Fixture) =
  close(f.store)
  try: removeDir(extendedPath(f.root))
  except OSError: discard

proc realizeEntry(f: var Fixture; name, version: string;
                  payload: string): tuple[id: PrefixIdBytes; path: string] =
  ## Realise one prefix through the production path: stage a real tree on
  ## disk and hand it to ``realizeDirectoryAsPrefix``, which materialises
  ## it, seals the receipt and publishes by rename. Nothing about the
  ## index or the on-disk layout is synthesised.
  let stage = f.root / "stage" / name & "-" & version
  createDir(extendedPath(stage / "bin"))
  writeFile(stage / "bin" / "tool", payload)

  let hint = StoreReceiptHint(
    adapter: "path",
    packageName: name,
    version: version,
    declaredExecutablePath: "bin/tool",
    lockIdentity: "store-gc-test")
  let res = realizeDirectoryAsPrefix(f.store, stage, hint)
  (id: res.prefixId, path: res.absolutePath)

suite "store GC refuses an entry a live root holds":

  test "t_win_store_gc_refuses_referenced_entry":
    var f = openFixture("refuse")
    defer: closeFixture(f)

    let entry = f.realizeEntry("gcc", "15.2.0", "the gcc tree")
    checkpoint("entry realised at " & entry.path)
    check dirExists(extendedPath(entry.path))

    # A job takes a root and the root holds the entry it materialised.
    f.store.registerRoot("job-42", rkSession)
    f.store.attachPrefixToRoot("job-42", entry.id)

    # NEGATIVE CONTROL on the setup itself: without this, the refusal below
    # could be a refusal to collect something that was never held, and the
    # test would pass on a store where attachPrefixToRoot did nothing.
    check f.store.rootsHolding(entry.id) == @["job-42"]

    # ARM ONE: refuse.
    let refused = f.store.gcPrefix(entry.id, graceSeconds = 0)
    check refused.refused
    check refused.found
    check refused.holdingRoots == @["job-42"]
    checkpoint("refusal reason: " & refused.reason)
    check refused.reason.contains("job-42")

    # The entry is still on disk, and still indexed. A refusal that moved
    # the tree first would be a deletion with a complaint attached.
    check dirExists(extendedPath(entry.path))
    check f.store.lookupPrefix(entry.id).found
    check refused.quarantinedPath.len == 0

    # The refusal is auditable. A store that did not shrink and cannot say
    # why is the case this row exists for.
    let refusals = f.store.listAudit().filterIt(it.action == $gaRefuse)
    check refusals.len == 1
    check refusals[0].reason.contains("job-42")

    # ARM TWO: release the root and the SAME call collects. Without this
    # arm an unconditional refusal would pass everything above.
    f.store.deleteRoot("job-42")
    check f.store.rootsHolding(entry.id).len == 0

    let collected = f.store.gcPrefix(entry.id, graceSeconds = 0)
    check not collected.refused
    check collected.found
    check collected.quarantinedPath.len > 0
    # graceSeconds = 0 means the unlink grace has trivially elapsed, so the
    # bytes go in the same pass.
    check collected.reclaimed
    check not dirExists(extendedPath(entry.path))
    check not dirExists(extendedPath(collected.quarantinedPath))
    check not f.store.lookupPrefix(entry.id).found

  test "the unlink grace defers the bytes rather than the decision":
    ## `DefaultGcGraceSeconds` is an UNLINK grace, not a retention policy,
    ## and the difference is observable: the entry leaves the index and the
    ## live tree immediately, and only its BYTES wait.
    var f = openFixture("grace")
    defer: closeFixture(f)

    let entry = f.realizeEntry("zstd", "1.5.6", "the zstd tree")
    let collected = f.store.gcPrefix(entry.id, graceSeconds = 5 * 60)

    check not collected.refused
    check collected.quarantinedPath.len > 0
    check not collected.reclaimed
    # Gone from where a consumer would look for it...
    check not dirExists(extendedPath(entry.path))
    check not f.store.lookupPrefix(entry.id).found
    # ...but the bytes are still recoverable inside the grace.
    check dirExists(extendedPath(collected.quarantinedPath))

    # Age the quarantine past the grace and let the sweep reclaim it. The
    # clock is moved rather than waited on.
    let past = getTime() - initDuration(seconds = 10 * 60)
    setLastModificationTime(collected.quarantinedPath, past)
    let report = f.store.gc(graceSeconds = 5 * 60)
    check report.reclaimed.len >= 1
    check not dirExists(extendedPath(collected.quarantinedPath))

  test "targeted collection starts the grace when an old prefix is quarantined":
    var f = openFixture("old-target")
    defer: closeFixture(f)

    let entry = f.realizeEntry("zstd", "1.5.6", "old source-built payload")
    setLastModificationTime(entry.path, getTime() - initDuration(days = 30))
    let collected = f.store.gcPrefix(entry.id, graceSeconds = 5 * 60)

    check collected.found
    check not collected.refused
    check not collected.reclaimed
    check not f.store.lookupPrefix(entry.id).found
    check not dirExists(extendedPath(entry.path))
    check fileExists(extendedPath(collected.quarantinedPath / "bin" / "tool"))
    check f.store.gc(graceSeconds = 5 * 60).reclaimed.len == 0

  test "a sweep retains an old prefix for a full quarantine grace":
    var f = openFixture("old-sweep")
    defer: closeFixture(f)

    let entry = f.realizeEntry("zstd", "1.5.6", "old source-built payload")
    setLastModificationTime(entry.path, getTime() - initDuration(days = 30))
    let report = f.store.gc(graceSeconds = 5 * 60)

    check report.quarantined.len == 1
    require report.quarantinedPaths.len == 1
    check report.reclaimed.len == 0
    check not f.store.lookupPrefix(entry.id).found
    check not dirExists(extendedPath(entry.path))
    check fileExists(extendedPath(report.quarantinedPaths[0] / "bin" / "tool"))
    check f.store.gc(graceSeconds = 5 * 60).reclaimed.len == 0

  when defined(posix):
    test "quarantine refuses a symlink without stamping its external target":
      var f = openFixture("symlink")
      defer: closeFixture(f)

      let entry = f.realizeEntry("zstd", "1.5.6", "external payload")
      let outside = f.root / "external"
      moveDir(entry.path, outside)
      createSymlink(outside, entry.path)
      setLastModificationTime(outside, getTime() - initDuration(days = 30))
      let originalTime = getLastModificationTime(outside)

      let collected = f.store.gcPrefix(entry.id, graceSeconds = 5 * 60)
      check collected.found
      check not collected.reclaimed
      check collected.quarantinedPath.len == 0
      check collected.reason.contains("refusing non-directory quarantine source")
      check f.store.gc(graceSeconds = 5 * 60).quarantined.len == 0
      check f.store.lookupPrefix(entry.id).found
      check symlinkExists(entry.path)
      check readFile(outside / "bin" / "tool") == "external payload"
      check getLastModificationTime(outside) == originalTime

  test "a second root keeps the entry alive after the first releases":
    ## Reachability, not refcounting -- but the observable consequence has
    ## to be the same when two holders exist, or the model is only correct
    ## in the one-holder case that is easiest to get right.
    var f = openFixture("two-roots")
    defer: closeFixture(f)

    let entry = f.realizeEntry("llvm", "20.1.0", "the llvm tree")
    f.store.registerRoot("overlay-a", rkWorkspace)
    f.store.registerRoot("overlay-b", rkWorkspace)
    f.store.attachPrefixToRoot("overlay-a", entry.id)
    f.store.attachPrefixToRoot("overlay-b", entry.id)

    check f.store.gcPrefix(entry.id, graceSeconds = 0).holdingRoots ==
      @["overlay-a", "overlay-b"]

    f.store.deleteRoot("overlay-a")
    let stillHeld = f.store.gcPrefix(entry.id, graceSeconds = 0)
    check stillHeld.refused
    check stillHeld.holdingRoots == @["overlay-b"]
    check dirExists(extendedPath(entry.path))

    f.store.deleteRoot("overlay-b")
    check not f.store.gcPrefix(entry.id, graceSeconds = 0).refused
    check not dirExists(extendedPath(entry.path))

  test "an entry no root ever held is collectable, and an absent one is reported":
    ## Two negative controls in one case. The first says the refusal is not
    ## unconditional; the second says "nothing to do" is distinguishable
    ## from "done", which is the distinction `gc`'s sweep cannot express.
    var f = openFixture("controls")
    defer: closeFixture(f)

    let entry = f.realizeEntry("capnp", "1.0.2", "the capnp tree")
    let collected = f.store.gcPrefix(entry.id, graceSeconds = 0)
    check not collected.refused
    check collected.found
    check not dirExists(extendedPath(entry.path))

    # Collecting it AGAIN must report "not found", not a second success.
    let again = f.store.gcPrefix(entry.id, graceSeconds = 0)
    check not again.refused
    check not again.found
    check again.quarantinedPath.len == 0

  test "a root that holds nothing blocks nothing":
    ## The other half of "reachability, not refcounting": a live root is not
    ## by itself a reason to keep anything. Without this a guard that
    ## refused whenever ANY root existed would pass every case above.
    var f = openFixture("empty-root")
    defer: closeFixture(f)

    let entry = f.realizeEntry("nim", "2.2.4", "the nim tree")
    f.store.registerRoot("unrelated-job", rkSession)
    check f.store.listRoots().len == 1

    let collected = f.store.gcPrefix(entry.id, graceSeconds = 0)
    check not collected.refused
    check collected.holdingRoots.len == 0
    check not dirExists(extendedPath(entry.path))
