## The materialized-prefix restore stages a binary-cache substitute under a
## name nobody can predict, removes only what it created, and moves the
## restored tree into place by ``rename(2)``.
##
## ``substituteMaterializedBinaryCacheEntries`` restores a tagged prefix from
## the binary cache before a source auto-recurse builds it. It once staged at
## ``<prefix>.repro-cache-substitute-<pid>``, removed that path before and
## after the substitute, and removed the old prefix with a helper that tested
## ``dirExists`` first. ``dirExists`` follows a symbolic link and ``removeDir``
## walks through one, so a link planted at the staging name, or a link at the
## prefix itself, made the restore empty the directory it pointed at
## (the same defect ``repro cache substitute`` was already fixed for).
##
## Each case plants the link the old code followed and checks that the
## directory it points at, and the link itself, are untouched:
##
##   1. a MISS with a link at the old staging name (no cache configured, so
##      the substitute misses; no server is needed to reach the removal);
##   2. a HIT with a link at the old staging name, over an existing prefix,
##      which must be replaced by the restored tree;
##   3. a HIT where the prefix itself is a link to a directory: the link is
##      replaced by the restored tree and its target keeps its contents;
##   4. a HIT into an absent prefix, after which nothing but the prefix is
##      left beside it (the staging directory is gone).
##
## No mocks. The hits are served by the real ``repro_binary_cache`` server
## subprocess on 127.0.0.1, from an entry published with the real
## ``publishInProcess`` under the key the restore derives for the action, and
## trusted through a real ``caches.conf`` pinned by ``REPRO_CACHES_CONFIG``.
## ``REPRO_LOCAL_STORE`` points at scratch so the host's own store cannot
## answer.
##
## Non-vacuity: against the restore before this fix, cases 1 and 2 empty the
## planted link's target (and raise ``OSError`` from ``rmdir`` on the link)
## and case 3 empties the prefix link's target.

import std/[net, options, os, osproc, random, strutils, tempfiles, unittest]

import repro_binary_cache_client
import repro_binary_cache_server/types as bcsTypes
import repro_build_engine
import repro_cli_support
import repro_project_dsl
import repro_test_support/reasoned_skip

import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

const ServerBinary = "build/test-bin" / addFileExt("repro_binary_cache", ExeExt)

const CacheEnvVars = ["REPRO_CACHES_CONFIG", "REPRO_BINARY_CACHE_URL",
  "REPRO_LOCAL_STORE"]

const VictimFile = "keep.txt"
const VictimText = "the directory a planted link points at\n"
const RestoredRel = "bin/tool"
const RestoredText = "restored from the binary cache\n"

proc cacheIdentity(name: string): CacheEntryIdentity =
  newCacheEntryIdentity(
    packageName = name,
    packageVersion = "1.0",
    platform = bcsTypes.PlatformTriple(
      cpu: "x86_64", os: "linux", abi: "gnu", libcVariant: "glibc"),
    toolchain = bcsTypes.ToolchainIdentity(
      name: "fixture", version: "1", hostLdSoAbi: "",
      extraFingerprint: ""),
    providerRevision = "fixture-revision")

proc restoreAction(id, root, prefix: string): BuildAction =
  BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakStamp,
    id: id,
    cwd: root,
    declaredOutputs: @[prefix],
    publishToBinaryCache: true,
    cacheEntryIdentity: some(cacheIdentity(id)))

proc oldStagingName(prefix: string): string =
  ## The name the restore staged at before this fix.
  prefix & ".repro-cache-substitute-" & $getCurrentProcessId()

proc makeVictim(dir: string) =
  createDir(dir)
  writeFile(dir / VictimFile, VictimText)

proc victimIntact(dir: string): bool =
  fileExists(dir / VictimFile) and readFile(dir / VictimFile) == VictimText

proc runRestore(action: BuildAction): tuple[res: BuildRunResult, raised: string] =
  ## The restore under test. An exception is recorded rather than allowed to
  ## end the case, so the checks on the planted link's target still run:
  ## that the old code raised is not what this test is about.
  try:
    result.res = substituteMaterializedBinaryCacheEntries(graph(@[action]))
  except CatchableError as e:
    result.raised = $e.name & ": " & e.msg

proc clearCacheEnv() =
  for v in CacheEnvVars:
    delEnv(v)

proc pickPort(): int =
  randomize(); 25_000 + rand(6_999)

proc waitForListener(port: int): bool =
  for _ in 0 ..< 300:
    try:
      let sock = newSocket()
      sock.connect("127.0.0.1", Port(port))
      sock.close()
      return true
    except CatchableError:
      sleep(50)
  false

template withPublishedEntry(tmpRoot: string; action: BuildAction;
                            body: untyped) =
  ## Start a real cache server, publish a prefix holding ``RestoredRel``
  ## under the key the restore derives for ``action``, and configure this
  ## process as a consumer that trusts only the publishing key.
  let port = pickPort()
  let serverRoot = tmpRoot / "server-store"
  createDir(serverRoot)
  let srv = startProcess(absolutePath(ServerBinary),
    args = @["--root=" & serverRoot, "--listen=127.0.0.1:" & $port],
    options = {poStdErrToStdOut, poParentStreams})
  try:
    doAssert waitForListener(port),
      "cache server did not start listening on 127.0.0.1:" & $port
    let url = "http://127.0.0.1:" & $port
    let keyDir = tmpRoot / "keys"
    createDir(keyDir)
    let kp = peerAuth.loadOrGenerateKeypair(keyDir / "producer.cert",
      keyDir / "producer.key")
    let pubHex = readFile(keyDir / "producer.cert").strip()
    let published = tmpRoot / "published"
    createDir(published / "bin")
    writeFile(published / RestoredRel, RestoredText)
    let pub = publishInProcess(PublishInProcessRequest(
      entryKeyHex: deriveActionCacheKeyHex(action),
      prefixDir: published,
      identity: applyCachePlatformTag(action.cacheEntryIdentity.get(),
        action.cachePlatformTag),
      endpoint: url,
      keypair: kp))
    doAssert pub.ok, "publish failed: " & pub.error
    let conf = tmpRoot / "caches.conf"
    writeFile(conf, "[fleet]\nurl = \"" & url & "\"\n" &
      "trusted-public-keys = \"" & pubHex & "\"\npriority = 20\n")
    clearCacheEnv()
    putEnv("REPRO_CACHES_CONFIG", conf)
    putEnv("REPRO_LOCAL_STORE", tmpRoot / "local-store")
    body
  finally:
    clearCacheEnv()
    try: srv.terminate() except CatchableError: discard
    try: discard srv.waitForExit() except CatchableError: discard
    try: srv.close() except CatchableError: discard

const PosixOnly =
  "the cache server is a POSIX subprocess here and the planted links are " &
  "POSIX symbolic links; the Windows restore keeps its moveDir fallback"

suite "materialized-prefix restore stages under a private name":

  test "a miss leaves a link planted at the old staging name and its target alone":
    when defined(windows):
      skip(PosixOnly)
    else:
      let root = createTempDir("restore-miss-", "")
      defer: removeDir(root)
      let prefix = root / "prefix"
      createDir(prefix)
      writeFile(prefix / "retained.txt", "existing payload\n")
      let victim = root / "victim"
      makeVictim(victim)
      createSymlink(victim, oldStagingName(prefix))
      # A cache configuration that names no cache: the substitute misses
      # without a network, which is all this case needs to reach the
      # removal the old code made before and after it.
      let conf = root / "caches.conf"
      writeFile(conf, "")
      clearCacheEnv()
      putEnv("REPRO_CACHES_CONFIG", conf)
      putEnv("REPRO_LOCAL_STORE", root / "local-store")
      defer: clearCacheEnv()
      let run = runRestore(restoreAction("miss", root, prefix))
      check victimIntact(victim)
      check symlinkExists(oldStagingName(prefix))
      check run.raised == ""
      check run.res.results.len == 1
      if run.res.results.len == 1:
        check run.res.results[0].status == asFailed
        check run.res.results[0].cacheDecision == cdMiss
        check "trusted binary-cache miss for " in run.res.results[0].stderr
      check readFile(prefix / "retained.txt") == "existing payload\n"
      # Nothing of the restore's own is left beside the prefix.
      for kind, path in walkDir(root):
        check extractFilename(path) in ["prefix", "victim", "caches.conf",
          "local-store", extractFilename(oldStagingName(prefix))]

  test "a hit replaces the prefix and leaves a link at the old staging name alone":
    when defined(windows):
      skip(PosixOnly)
    else:
      let root = createTempDir("restore-hit-", "")
      defer: removeDir(root)
      let work = root / "work"
      createDir(work)
      let prefix = work / "prefix"
      createDir(prefix)
      writeFile(prefix / "stale.txt", "the previous build\n")
      let victim = root / "victim"
      makeVictim(victim)
      createSymlink(victim, oldStagingName(prefix))
      let action = restoreAction("hit-planted", work, prefix)
      withPublishedEntry(root, action):
        let run = runRestore(action)
        check victimIntact(victim)
        check symlinkExists(oldStagingName(prefix))
        check run.raised == ""
        check run.res.results.len == 1
        if run.res.results.len == 1:
          check run.res.results[0].status == asCacheHit
          check run.res.results[0].cacheDecision == cdHit
        check readFile(prefix / RestoredRel) == RestoredText
        check not fileExists(prefix / "stale.txt")

  test "a hit replaces a prefix that is a link without emptying its target":
    when defined(windows):
      skip(PosixOnly)
    else:
      let root = createTempDir("restore-link-prefix-", "")
      defer: removeDir(root)
      let work = root / "work"
      createDir(work)
      let victim = root / "victim"
      makeVictim(victim)
      let prefix = work / "prefix"
      createSymlink(victim, prefix)
      let action = restoreAction("hit-link-prefix", work, prefix)
      withPublishedEntry(root, action):
        let run = runRestore(action)
        check victimIntact(victim)
        check not fileExists(victim / RestoredRel)
        check run.raised == ""
        check run.res.results.len == 1
        if run.res.results.len == 1:
          check run.res.results[0].status == asCacheHit
        check not symlinkExists(prefix)
        check dirExists(prefix)
        check readFile(prefix / RestoredRel) == RestoredText

  test "a hit into an absent prefix leaves nothing else beside it":
    when defined(windows):
      skip(PosixOnly)
    else:
      let root = createTempDir("restore-fresh-", "")
      defer: removeDir(root)
      let work = root / "work"
      createDir(work)
      let prefix = work / "prefix"
      let action = restoreAction("hit-fresh", work, prefix)
      withPublishedEntry(root, action):
        let run = runRestore(action)
        check run.raised == ""
        check run.res.results.len == 1
        if run.res.results.len == 1:
          check run.res.results[0].status == asCacheHit
        check readFile(prefix / RestoredRel) == RestoredText
        var beside: seq[string]
        for kind, path in walkDir(work):
          beside.add(extractFilename(path))
        check beside == @["prefix"]
