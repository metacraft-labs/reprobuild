## `rootStorePaths` roots every path it is given, however many there are.
##
## The defect (reprobuild-pm issue 2026-11-07, "the worker's held lease GC
## roots fail with Argument list too long on a large closure"): every path was
## registered by ONE `nix-store --realise --add-root <link> <path>…` command
## string run through `/bin/sh -c`. That string is a single argument of `sh`,
## and Linux caps one argument at `MAX_ARG_STRLEN` (128 KiB), so a closure of
## ~2,500 store paths failed with `E2BIG` before `nix-store` ran, and nothing
## was rooted. A distributed worker started from a login environment holds
## such a closure.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED. The
## store paths are real, added to the host's real store with the real
## `nix-store --add`, rooted by the production code with the host's real
## `nix-store`, and every liveness claim is asked of the real store: a path
## the store refuses to `--delete` is a path a garbage collection keeps. A
## fake `nix-store` could only report what the client believes it registered,
## and could not show that the kernel accepts the call.
##
## PRIVATE PATHS. Each added file's content carries this process's id and the
## time, so its store path is one nothing else on the host has referenced or
## rooted. They are deleted again at the end with `nix-store --delete` (never
## a garbage collection, never `--ignore-liveness`).

import std/[os, osproc, sets, streams, strutils, tempfiles, times, unittest]

import repro_core/nix_store_roots

const
  PathCount = 900
    ## Paths rooted at once. With `NameLen`, their argument bytes are ~200 KiB:
    ## past the 128 KiB a single `sh -c` argument may carry, and three
    ## batches of `NixStoreArgvBudget`.
  NameLen = 180
    ## Store name length of each added path (Nix allows up to 211).

proc nixStoreExe(): string =
  ## `followSymlinks = false`: `nix-store` is a symlink to the multi-call
  ## `nix`, which dispatches on `argv[0]`.
  result = findExe("nix-store", followSymlinks = false)
  if result.len == 0:
    raise newException(OSError,
      "nix-store is not on PATH; this real-Nix test needs the host's Nix")

proc nixStore(args: openArray[string]): tuple[output: string; code: int] =
  ## The real `nix-store`, with `args` as its argv (no shell, so the test's
  ## own calls are not subject to the limit under test).
  var p = startProcess(nixStoreExe(), args = args,
    options = {poStdErrToStdOut})
  try:
    result.output = p.outputStream.readAll()
    result.code = p.waitForExit()
  finally:
    p.close()

proc addPrivatePaths(dir, tag: string; count: int): seq[string] =
  ## `count` new store paths with `NameLen`-character names, added with
  ## `nix-store --add` in groups small enough for any `ARG_MAX`.
  var files: seq[string] = @[]
  for i in 0 ..< count:
    let prefix = "rbroot-" & align($i, 4, '0') & "-"
    let file = dir / prefix & repeat('x', NameLen - prefix.len)
    writeFile(file, "reprobuild large-closure root probe " & tag & " " & $i &
      "\n")
    files.add(file)
  var start = 0
  while start < files.len:
    let group = files[start ..< min(start + 100, files.len)]
    let res = nixStore(@["--add"] & group)
    doAssert res.code == 0, "nix-store --add failed: " & res.output
    for line in res.output.splitLines():
      if line.strip().len > 0:
        result.add(line.strip())
    start += group.len
  doAssert result.len == count,
    "nix-store --add printed " & $result.len & " paths for " & $count

suite "storePathBatches":

  test "every path once, in order, each batch within the budget":
    var paths: seq[string] = @[]
    for i in 0 ..< 50:
      paths.add("/nix/store/" & repeat('a', 32) & "-p" & $i)
    let cost = paths[0].len + 1 + sizeof(pointer)
    let batches = storePathBatches(paths, budget = 7 * cost + cost div 2)
    var flat: seq[string] = @[]
    for b in batches:
      check b.len in 1 .. 7
      var used = 0
      for p in b:
        used += p.len + 1 + sizeof(pointer)
      check used <= 7 * cost + cost div 2
      flat.add(b)
    check flat == paths
    check batches.len == 8

  test "no paths, no batches; a path over the budget is alone, never dropped":
    check storePathBatches(newSeq[string]()).len == 0
    let long = "/nix/store/" & repeat('b', 32) & "-" & repeat('n', 200)
    let batches = storePathBatches(["/nix/store/x-a", long, "/nix/store/x-b"],
      budget = 64)
    check batches == @[@["/nix/store/x-a"], @[long], @["/nix/store/x-b"]]

suite "rootStorePaths over a closure larger than one shell argument":

  test "every path is rooted, and the real store keeps them":
    let tag = $getCurrentProcessId() & "-" & $int64(epochTime() * 1000)
    let srcDir = createTempDir("repro-large-closure-src-", "")
    let rootDir = createTempDir("repro-large-closure-roots-", "")
    var paths: seq[string] = @[]
    try:
      paths = addPrivatePaths(srcDir, tag, PathCount)
      var argBytes = 0
      for p in paths:
        argBytes += p.len + 1
      # The precondition the defect needs: as one `sh -c` string these
      # paths alone exceed Linux's MAX_ARG_STRLEN.
      check argBytes > 128 * 1024

      let outcome = rootStorePaths(rootDir, paths, label = "large-closure",
        storeDir = nixStoreDir())
      check outcome.absent.len == 0
      check outcome.registered == PathCount
      check outcome.rooted.len == PathCount
      check outcome.rooted.toHashSet() == paths.toHashSet()
      check outcome.nixStoreCalls == storePathBatches(paths).len
      check outcome.nixStoreCalls > 1

      # Exactly one link per path, each pointing at it.
      var targets = initHashSet[string]()
      var links = 0
      for kind, child in walkDir(rootDir):
        if kind in {pcLinkToFile, pcLinkToDir}:
          inc links
          targets.incl(expandSymlink(child))
      check links == PathCount
      check targets == paths.toHashSet()

      # The store agrees: a rooted path cannot be deleted. The first and last
      # paths sit in the first and last batch.
      for p in [paths[0], paths[^1]]:
        check nixStore(["--delete", p]).code != 0

      # A warm call registers nothing and runs no nix-store.
      let warm = rootStorePaths(rootDir, paths, label = "large-closure",
        storeDir = nixStoreDir())
      check warm.nixStoreCalls == 0
      check warm.registered == 0
      check warm.rooted.len == PathCount
    finally:
      removeDir(rootDir)
      removeDir(srcDir)
      # The links are gone, so Nix drops the dangling auto-roots and the
      # private paths can be deleted without touching anything else.
      var start = 0
      while start < paths.len:
        discard nixStore(@["--delete"] &
          paths[start ..< min(start + 100, paths.len)])
        start += 100
    for p in [paths[0], paths[^1]]:
      check not fileExists(p)
