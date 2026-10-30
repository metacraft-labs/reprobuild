## Windows-Runner-Binary-Cache-Deploy M4 — apply substitutes build-action
## outputs from the binary cache instead of building them locally — and
## does so only under the R1 trust anchors, publishing only from a host
## configured as a publisher.
##
## This is the M4 gate plus its trust controls. It drives `repro infra
## apply`'s build-action dispatcher
## (``repro_profile_compile.mkBuildActionDispatcher``, the same closure
## ``runInfraApply`` injects into ``ApplyOptions.buildActionDispatcher``,
## and which ``repro deploy-agent`` reaches through ``runInfraApply``).
##
## No mocks. Every case runs against:
##
##   * a REAL ``repro-binary-cache`` server subprocess on 127.0.0.1 (the
##     M1/M2 machinery), and
##   * a build action that runs a REAL ``/bin/sh`` whose only side effects
##     are (a) the declared output under ``cwd`` and (b) a "witness" file
##     OUTSIDE the outputs that the shell touches every time it runs. A
##     substituted edge never spawns the shell, so the witness is the
##     honest "built locally" vs "served from cache" signal.
##
## The cache configuration is the real ``caches.conf`` mechanism, pinned to
## a scratch file through ``REPRO_CACHES_CONFIG`` so the host's own
## ``/etc/repro/caches.conf`` (fleet hosts render one) cannot leak in.
##
## Cases:
##
##   1. M4 gate. A PUBLISHER (operator-supplied keypair A) builds and
##      publishes; a CONSUMER whose ``caches.conf`` anchors A substitutes the
##      output byte-identically without spawning the shell. Negative control:
##      no cache configured builds locally (off-by-default).
##   2. UNTRUSTED SIGNER. The entry is signed by A; a consumer that anchors
##      only B builds locally. Positive control in the same case: the same
##      consumer anchoring A hits, so the rejection is the trust gate and not
##      a missing entry.
##   3. NO ANCHORS. A cache configured with no ``trusted-public-keys``, and
##      the back-compat ``REPRO_BINARY_CACHE_URL`` with no producer cert,
##      are both misses against the same validly signed entry.
##   4. CONSUMER NEVER PUBLISHES. A host with a cache configured (including
##      ``REPRO_BINARY_CACHE_URL``, the old trigger) but no keypair builds a
##      miss locally, generates no key (the auto-credential directory stays
##      absent) and publishes nothing (the server has no manifest for the
##      entry). Positive control: the same apply with the keypair configured
##      does publish, so the "no manifest" check can see a publish. A host
##      with the keypair but WITHOUT `REPRO_APPLY_PUBLISH=1` (a developer
##      shell under `sudo -E`) publishes nothing either.
##   5. MALFORMED CONFIG. A `caches.conf` the loader cannot parse configures
##      no cache: the entry is there, the key is right, one hex digit is
##      missing, and the apply builds locally.
##   6. SYMLINK IN OUTPUTS. A publisher whose declared output tree holds a
##      symbolic link publishes nothing for that edge: a partial prefix
##      must never leave the host.
##
## Non-vacuity: before this gate was amended the dispatcher substituted
## through ``SubstituteEndpoint(trustedSigners: @[])`` without
## ``enforceTrust`` and auto-generated a publisher keypair. Against that
## code case 2 and case 3 hit (an untrusted entry materialises) and case 4
## finds a generated key and a published manifest — each case fails.

import std/[httpclient, os, osproc, net, random, strutils, tempfiles, unittest]

import repro_binary_cache_client
import repro_test_support/reasoned_skip
import repro_elevation
import repro_infra
import repro_profile
import repro_profile_compile
import repro_profile_compile/binary_cache_build_actions

import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

const ServerBinary = "build/test-bin" / addFileExt("repro_binary_cache", ExeExt)

proc pickPort(): int =
  randomize(); 25_000 + rand(6_999)

proc waitForListener(port: int; tries = 300; sleepMs = 50): bool =
  for _ in 0 ..< tries:
    try:
      let sock = newSocket()
      sock.connect("127.0.0.1", Port(port))
      sock.close()
      return true
    except CatchableError:
      sleep(sleepMs)
  return false

proc startServer(serverRoot: string; port: int): Process =
  startProcess(absolutePath(ServerBinary),
               args = @["--root=" & serverRoot,
                        "--listen=127.0.0.1:" & $port],
               options = {poStdErrToStdOut, poParentStreams})

# The deployment-artifact bytes the build action writes. Deliberately
# NUL-laced (via ``printf`` octal escapes in the shell, NOT via argv —
# the exec primitive rejects a NUL byte inside argv) so a "treat output
# as text" bug in the pack/substitute path would corrupt it and the
# byte-identity assertion would catch it. ``ExpectedPayload`` is the
# exact byte string the shell ``printf`` below produces.
const PrintfArg = "M4-artifact\\000\\001\\002-NUL-laced-tail"
const ExpectedPayload = "M4-artifact\x00\x01\x02-NUL-laced-tail"

const OutRel = "bin/deploy-artifact.dat"
const WitnessRel = ".witness"

proc witnessShellAction(id, cwd: string): ProfileBuildAction =
  ## A ``ProfileBuildAction`` that (1) writes the NUL-laced
  ## ``ExpectedPayload`` to the cwd-RELATIVE ``OutRel`` — the DECLARED,
  ## substitutable output — via ``printf`` octal escapes (so the NUL
  ## bytes are in the OUTPUT, never in argv), and (2) appends a byte to
  ## the cwd-relative ``WitnessRel`` — a marker OUTSIDE the outputs. The
  ## witness is only touched when the shell actually runs, so its
  ## presence/absence is an honest "built locally" signal that a
  ## substitute (which never spawns the shell) cannot forge.
  ##
  ## CRITICAL for the M4 key: the argv uses ONLY cwd-RELATIVE paths, so
  ## the action definition (hence the content-addressable cache key) is
  ## IDENTICAL across cwds. A cwd-baked absolute path in argv would make
  ## the key per-run and the substitute would never hit. The broker runs
  ## the process with ``cwd`` as its working directory, so the relative
  ## paths resolve under the right root.
  ##
  ## ``requiresElevation = true`` routes the spawn through the in-process
  ## broker fast path, which does NOT require a monitor CLI (a
  ## non-elevated cacheable action would fail the requires-io-monitor
  ## guard). The broker fast path runs the real argv synchronously.
  let script =
    "mkdir -p bin; " &
    "printf '" & PrintfArg & "' > '" & OutRel & "'; " &
    "printf x >> '" & WitnessRel & "'"
  result = ProfileBuildAction(
    id: id,
    argv: @["/bin/sh", "-c", script],
    cwd: cwd,
    deps: @[],
    inputs: @[],
    outputs: @[OutRel],
    commandStatsId: "m4.witness.write",
    toolIdentityRefs: @[],
    requiresElevation: true,
    cacheable: true)

# ---------------------------------------------------------------------------
# Cache environment. Every case sets the whole of it, so no case inherits
# another's configuration or the host's.
# ---------------------------------------------------------------------------

const CacheEnvVars = [
  "REPRO_CACHES_CONFIG", "REPRO_BINARY_CACHE_URL",
  "REPRO_BINARY_CACHE_KEY_PATH", "REPRO_BINARY_CACHE_CERT_PATH",
  "REPRO_BINARY_CACHE_SCOPE", "REPRO_BINARY_CACHE_AUTO_CRED_DIR",
  "REPRO_CACHE_DISABLE", "REPRO_APPLY_PUBLISH"]

proc clearCacheEnv() =
  for v in CacheEnvVars:
    delEnv(v)

type
  Keypair = object
    keyPath, certPath, pubHex: string

proc makeKeypair(dir: string): Keypair =
  ## A real ECDSA-P256 producer keypair on disk, in the format an operator
  ## hands to ``REPRO_BINARY_CACHE_KEY_PATH`` / ``_CERT_PATH``. The cert file
  ## is the bare public-key hex, which is also what ``caches.conf`` takes.
  createDir(dir)
  result.keyPath = dir / "producer.key"
  result.certPath = dir / "producer.cert"
  discard peerAuth.loadOrGenerateKeypair(result.certPath, result.keyPath)
  result.pubHex = readFile(result.certPath).strip()
  doAssert result.pubHex.len == 130

proc writeCachesConf(path, url: string; trusted: seq[string]) =
  ## Render the R1 ``caches.conf`` an operator (or the nixos-modules
  ## renderer) writes: one cache, its URL and its anchors. An empty
  ## ``trusted`` writes a cache with NO ``trusted-public-keys`` line.
  var text = "[fleet]\nurl = \"" & url & "\"\n"
  if trusted.len > 0:
    text.add("trusted-public-keys = \"" & trusted.join(", ") & "\"\n")
  text.add("priority = 20\n")
  writeFile(path, text)

proc useConsumer(confPath: string; url = "") =
  ## A consumer host: caches come only from ``confPath``, no keypair. A
  ## non-empty ``url`` also sets ``REPRO_BINARY_CACHE_URL`` to the same
  ## cache, as a host that exports it does. The rejection cases set it so
  ## they exercise the trust gate on every revision of the dispatcher: the
  ## pre-fix dispatcher consulted the cache only when that variable was set,
  ## and without it a "miss" there would prove nothing about trust.
  clearCacheEnv()
  putEnv("REPRO_CACHES_CONFIG", confPath)
  if url.len > 0:
    putEnv("REPRO_BINARY_CACHE_URL", url)

proc usePublisher(confPath, url: string; kp: Keypair) =
  ## A host the operator made a publisher: same cache config, plus the
  ## explicit apply-time opt-in (REPRO_APPLY_PUBLISH=1), the
  ## publish endpoint and an existing keypair.
  useConsumer(confPath, url)
  putEnv("REPRO_BINARY_CACHE_KEY_PATH", kp.keyPath)
  putEnv("REPRO_BINARY_CACHE_CERT_PATH", kp.certPath)
  putEnv("REPRO_APPLY_PUBLISH", "1")

type
  ApplyRun = object
    outcome: BuildActionApplyOutcome
    cwd: string
    shellRan: bool

proc applyOnce(root, tag, actionId: string): ApplyRun =
  ## One apply of a single build-action edge in a FRESH cwd with a FRESH
  ## engine cache root, so an engine-local action-cache hit is impossible
  ## and only the binary cache can supply the output without a build.
  result.cwd = root / ("cwd-" & tag)
  let cacheRoot = root / ("engine-cache-" & tag)
  createDir(result.cwd); createDir(cacheRoot)
  let ctx = FixtureContext(filePrefix: root / ("ctx-" & tag))
  let disp = mkBuildActionDispatcher(cacheRoot, ctx)
  let outs = disp(@[witnessShellAction(actionId, result.cwd)], nil)
  doAssert outs.len == 1, "dispatcher returned " & $outs.len & " outcomes"
  result.outcome = outs[0]
  if not result.outcome.ok:
    echo "APPLY ", tag, " DIAGNOSTIC: ", result.outcome.diagnostic
  result.shellRan = fileExists(result.cwd / WitnessRel)

proc entryKeyHexFor(actionId: string): string =
  ## The binary-cache key the dispatcher derives for ``actionId``. The key
  ## is cwd-independent, so any cwd gives the same answer.
  deriveCacheEntryKeyHex(buildActionCacheIdentity(
    witnessShellAction(actionId, getTempDir()), ""))

proc manifestPublished(url, entryHex: string): bool =
  ## Ask the real server whether ANY signer published an entry under this
  ## key. 200 = present, 404 = absent; anything else is a test failure.
  let client = newHttpClient(timeout = 10_000)
  defer: client.close()
  let resp = client.request(url & "/manifests/" & entryHex, httpMethod = HttpGet)
  let code = resp.code.int
  doAssert code in [200, 404],
    "unexpected status " & $code & " probing manifest " & entryHex
  code == 200

template checkBuiltLocally(run: ApplyRun) =
  ## A template, not a proc, so a failed `check` fails the enclosing test.
  let r = run
  check r.outcome.ok
  check not r.outcome.substitutedFromCache
  check not r.outcome.cacheHit
  check r.shellRan
  check readFile(r.cwd / OutRel) == ExpectedPayload

template checkSubstituted(run: ApplyRun) =
  let r = run
  check r.outcome.ok
  check r.outcome.substitutedFromCache
  check r.outcome.cacheHit
  check not r.shellRan
  check readFile(r.cwd / OutRel) == ExpectedPayload

template withCacheServer(tmpPrefix: string; body: untyped) =
  ## Starts a real cache server in a fresh temp tree and exposes ``tmpRoot``
  ## and ``url`` to ``body``. The cache env is cleared on the way out so no
  ## case leaks into the next.
  let tmpRoot {.inject.} = createTempDir(tmpPrefix, "")
  let port = pickPort()
  let serverRoot = tmpRoot / "server-store"
  createDir(serverRoot)
  let srvProc = startServer(serverRoot, port)
  try:
    # Hard requirement: the server MUST be listening before any apply, or
    # the substitute/publish would spuriously miss. 300 x 50 ms tolerates
    # a slow first bind.
    doAssert waitForListener(port),
      "cache server did not start listening on 127.0.0.1:" & $port
    let url {.inject.} = "http://127.0.0.1:" & $port
    body
  finally:
    clearCacheEnv()
    try: srvProc.terminate() except CatchableError: discard
    try: srvProc.close() except CatchableError: discard
    try: removeDir(tmpRoot) except CatchableError: discard

suite "M4 — repro infra apply substitutes build-action outputs from cache":

  test "t_infra_apply_substitutes_from_cache":
    when not (defined(linux) or defined(macosx)):
      skip("the build action is a /bin/sh script and the cache server a POSIX subprocess; no Windows arm")
    else:
      check fileExists(ServerBinary)
      withCacheServer("m4-substitute-"):
        let kpA = makeKeypair(tmpRoot / "key-a")
        let conf = tmpRoot / "caches.conf"
        writeCachesConf(conf, url, @[kpA.pubHex])

        # RUN 1 — empty cache, publisher host: build locally + publish.
        usePublisher(conf, url, kpA)
        let run1 = applyOnce(tmpRoot, "1", "m4-edge")
        checkBuiltLocally(run1)
        check readFile(run1.cwd / WitnessRel).len == 1
        check manifestPublished(url, entryKeyHexFor("m4-edge"))

        # RUN 2 — consumer anchoring A, cache populated: SUBSTITUTE, and
        # the output is byte-identical to the local build of run 1.
        useConsumer(conf, url)
        let run2 = applyOnce(tmpRoot, "2", "m4-edge")
        checkSubstituted(run2)
        check readFile(run2.cwd / OutRel) == readFile(run1.cwd / OutRel)

        # NEGATIVE CONTROL — no cache configured at all: build locally.
        useConsumer(tmpRoot / "no-such-caches.conf")
        let run3 = applyOnce(tmpRoot, "3", "m4-edge")
        checkBuiltLocally(run3)

  test "an entry signed by a key the cache does not anchor is a miss":
    when not (defined(linux) or defined(macosx)):
      skip("the build action is a /bin/sh script and the cache server a POSIX subprocess; no Windows arm")
    else:
      withCacheServer("m4-untrusted-"):
        let kpA = makeKeypair(tmpRoot / "key-a")
        let kpB = makeKeypair(tmpRoot / "key-b")
        let confA = tmpRoot / "caches-a.conf"
        let confB = tmpRoot / "caches-b.conf"
        writeCachesConf(confA, url, @[kpA.pubHex])
        writeCachesConf(confB, url, @[kpB.pubHex])

        usePublisher(confA, url, kpA)
        checkBuiltLocally(applyOnce(tmpRoot, "producer", "untrusted-edge"))
        check manifestPublished(url, entryKeyHexFor("untrusted-edge"))

        # The consumer anchors only B. The entry is validly signed — by A.
        useConsumer(confB, url)
        checkBuiltLocally(applyOnce(tmpRoot, "anchors-b", "untrusted-edge"))

        # Positive control: anchoring A, the very same entry substitutes.
        useConsumer(confA, url)
        checkSubstituted(applyOnce(tmpRoot, "anchors-a", "untrusted-edge"))

  test "a cache with no trust anchors is never substituted from":
    when not (defined(linux) or defined(macosx)):
      skip("the build action is a /bin/sh script and the cache server a POSIX subprocess; no Windows arm")
    else:
      withCacheServer("m4-unanchored-"):
        let kpA = makeKeypair(tmpRoot / "key-a")
        let confA = tmpRoot / "caches-a.conf"
        let confNone = tmpRoot / "caches-none.conf"
        writeCachesConf(confA, url, @[kpA.pubHex])
        writeCachesConf(confNone, url, @[])

        usePublisher(confA, url, kpA)
        checkBuiltLocally(applyOnce(tmpRoot, "producer", "unanchored-edge"))
        check manifestPublished(url, entryKeyHexFor("unanchored-edge"))

        # caches.conf names the cache but anchors no key.
        useConsumer(confNone, url)
        checkBuiltLocally(applyOnce(tmpRoot, "conf-no-keys",
                                    "unanchored-edge"))

        # Back-compat env cache: URL only, no producer cert to anchor.
        useConsumer(tmpRoot / "no-such-caches.conf")
        putEnv("REPRO_BINARY_CACHE_URL", url)
        checkBuiltLocally(applyOnce(tmpRoot, "env-no-cert",
                                    "unanchored-edge"))

        # Positive control: the entry is there and substitutable.
        useConsumer(confA, url)
        checkSubstituted(applyOnce(tmpRoot, "anchors-a", "unanchored-edge"))

  test "a publisher refuses to stage an output tree that contains a symlink":
    when not (defined(linux) or defined(macosx)):
      skip("symbolic links and the /bin/sh build action are POSIX; no Windows arm")
    else:
      withCacheServer("m4-symlink-"):
        let kpA = makeKeypair(tmpRoot / "key-a")
        let confA = tmpRoot / "caches-a.conf"
        writeCachesConf(confA, url, @[kpA.pubHex])
        usePublisher(confA, url, kpA)
        # The edge declares the directory `bin` and its script leaves a
        # link to a directory inside it. The old stager did not descend
        # into link-to-directory entries, so the prefix it published was
        # missing a subtree; a consumer substituted it cleanly and ran
        # without it. Now the whole edge is refused for publication.
        let cwd = tmpRoot / "cwd-link"
        createDir(cwd)
        let action = ProfileBuildAction(
          id: "symlink-edge",
          argv: @["/bin/sh", "-c",
            "mkdir -p bin real; printf payload > real/lib.so; " &
            "ln -s ../real bin/lib; printf x > bin/tool"],
          cwd: cwd, outputs: @["bin"],
          commandStatsId: "m4.symlink.write",
          requiresElevation: true, cacheable: true)
        let cacheRoot = tmpRoot / "engine-cache-link"
        createDir(cacheRoot)
        let disp = mkBuildActionDispatcher(cacheRoot,
          FixtureContext(filePrefix: tmpRoot / "ctx-link"))
        let outs = disp(@[action], nil)
        check outs.len == 1
        check outs[0].ok                       # the edge itself converged
        check symlinkExists(cwd / "bin" / "lib")
        let entry = deriveCacheEntryKeyHex(buildActionCacheIdentity(
          action, ""))
        check not manifestPublished(url, entry)  # and nothing left the host

  test "a publisher refuses to stage an output tree that contains a link to a file":
    when not (defined(linux) or defined(macosx)):
      skip("symbolic links and the /bin/sh build action are POSIX; no Windows arm")
    else:
      withCacheServer("m4-filelink-"):
        let kpA = makeKeypair(tmpRoot / "key-a")
        let confA = tmpRoot / "caches-a.conf"
        writeCachesConf(confA, url, @[kpA.pubHex])
        usePublisher(confA, url, kpA)
        # The directory case above leaves a link to a DIRECTORY, which the
        # old walk silently skipped. A link to a FILE was yielded by that
        # walk as `pcLinkToFile` and copied through -- a different branch of
        # the same guard, so it gets its own control: `bin/tool` is a link
        # to a regular file outside the declared tree.
        let cwd = tmpRoot / "cwd-filelink"
        createDir(cwd)
        let action = ProfileBuildAction(
          id: "filelink-edge",
          argv: @["/bin/sh", "-c",
            "mkdir -p bin real; printf tool > real/tool; " &
            "ln -s ../real/tool bin/tool; printf x > bin/other"],
          cwd: cwd, outputs: @["bin"],
          commandStatsId: "m4.filelink.write",
          requiresElevation: true, cacheable: true)
        let cacheRoot = tmpRoot / "engine-cache-filelink"
        createDir(cacheRoot)
        let disp = mkBuildActionDispatcher(cacheRoot,
          FixtureContext(filePrefix: tmpRoot / "ctx-filelink"))
        let outs = disp(@[action], nil)
        check outs.len == 1
        check outs[0].ok
        check symlinkExists(cwd / "bin" / "tool")
        check not manifestPublished(url, deriveCacheEntryKeyHex(
          buildActionCacheIdentity(action, "")))

  test "a caches.conf that cannot be parsed configures no cache":
    when not (defined(linux) or defined(macosx)):
      skip("the build action is a /bin/sh script and the cache server a POSIX subprocess; no Windows arm")
    else:
      withCacheServer("m4-malformed-"):
        let kpA = makeKeypair(tmpRoot / "key-a")
        let confA = tmpRoot / "caches-a.conf"
        writeCachesConf(confA, url, @[kpA.pubHex])
        usePublisher(confA, url, kpA)
        checkBuiltLocally(applyOnce(tmpRoot, "producer", "malformed-edge"))
        check manifestPublished(url, entryKeyHexFor("malformed-edge"))

        # The same cache and the right key, but the trusted-key line is
        # not a key: one hex digit short. The loader raises, the resolver
        # reports a configError, and NOTHING is substituted -- a config the
        # loader cannot read grants no trust, even to a URL the back-compat
        # variable names as well.
        let broken = tmpRoot / "caches-broken.conf"
        writeFile(broken, "[fleet]\nurl = \"" & url & "\"\n" &
          "trusted-public-keys = \"" & kpA.pubHex[0 ..< kpA.pubHex.len - 1] &
          "\"\n")
        useConsumer(broken, url)
        checkBuiltLocally(applyOnce(tmpRoot, "broken-conf", "malformed-edge"))

        # Positive control: the well-formed file substitutes the same entry.
        useConsumer(confA, url)
        checkSubstituted(applyOnce(tmpRoot, "anchors-a", "malformed-edge"))

  test "a consumer host generates no key and publishes nothing on a miss":
    when not (defined(linux) or defined(macosx)):
      skip("the build action is a /bin/sh script and the cache server a POSIX subprocess; no Windows arm")
    else:
      withCacheServer("m4-consumer-"):
        let kpA = makeKeypair(tmpRoot / "key-a")
        let confA = tmpRoot / "caches-a.conf"
        writeCachesConf(confA, url, @[kpA.pubHex])
        let autoCredDir = tmpRoot / "auto-cred"

        # A consumer with the cache fully configured — caches.conf AND the
        # REPRO_BINARY_CACHE_URL that used to switch publishing on — but no
        # keypair. The auto-credential dir is redirected into the sandbox so
        # a generated key would be seen here and never touch real config.
        useConsumer(confA, url)
        putEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR", autoCredDir)
        checkBuiltLocally(applyOnce(tmpRoot, "consumer", "consumer-edge"))
        check not dirExists(autoCredDir)
        check not manifestPublished(url, entryKeyHexFor("consumer-edge"))

        # A keypair ALONE is not a publisher. This is the developer-shell
        # case: REPRO_BINARY_CACHE_KEY_PATH / _CERT_PATH exported for
        # `repro build`, then `sudo -E repro infra apply` from that shell.
        # Without the explicit REPRO_APPLY_PUBLISH=1 the apply must not
        # publish, even though it could sign.
        usePublisher(confA, url, kpA)
        delEnv("REPRO_APPLY_PUBLISH")
        putEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR", autoCredDir)
        checkBuiltLocally(applyOnce(tmpRoot, "keypair-no-optin",
                                    "consumer-edge"))
        check not manifestPublished(url, entryKeyHexFor("consumer-edge"))

        # Positive control: the same apply on a publisher host does publish,
        # so the probe above can see a publish when one happens.
        usePublisher(confA, url, kpA)
        putEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR", autoCredDir)
        checkBuiltLocally(applyOnce(tmpRoot, "publisher", "consumer-edge"))
        check manifestPublished(url, entryKeyHexFor("consumer-edge"))
        check not dirExists(autoCredDir)

# ---------------------------------------------------------------------------
# Substitute-only edges pin their bytes (Binary-Caches.md §"Publishing for a
# host that cannot build"). A publisher's signature says who packed an
# archive; `expectedOutputDigest` in the SIGNED profile says what it must
# contain. These cases pin that:
#   * a trusted publisher whose archive is not the pinned one is a MISS and
#     materialises nothing (the publisher is transport, not authority);
#   * the pinned archive is a hit;
#   * outputs already on disk that hash to the pin are a hit with NO fetch —
#     the cache may be unreachable; a converge tick that changes nothing does
#     no network I/O;
#   * a substitute-only edge never builds: on a miss it is a FAILED outcome
#     and the shell did not run.
# ---------------------------------------------------------------------------

proc pinnedAction(id, cwd, digest: string; substituteOnly = false):
    ProfileBuildAction =
  result = witnessShellAction(id, cwd)
  result.expectedOutputDigest = digest
  result.substituteOnly = substituteOnly

proc applyAction(root, tag: string; action: ProfileBuildAction): ApplyRun =
  result.cwd = action.cwd
  let cacheRoot = root / ("engine-cache-" & tag)
  createDir(result.cwd); createDir(cacheRoot)
  let ctx = FixtureContext(filePrefix: root / ("ctx-" & tag))
  let disp = mkBuildActionDispatcher(cacheRoot, ctx)
  let outs = disp(@[action], nil)
  doAssert outs.len == 1, "dispatcher returned " & $outs.len & " outcomes"
  result.outcome = outs[0]
  result.shellRan = fileExists(result.cwd / WitnessRel)

suite "substitute-only edges: the profile pins the bytes, not the publisher":

  test "a trusted publisher's archive that is not the pinned one is a miss":
    when not (defined(linux) or defined(macosx)):
      skip("POSIX shell action and cache server subprocess; no Windows arm")
    else:
      withCacheServer("m4-digest-"):
        let kpA = makeKeypair(tmpRoot / "key-a")
        let conf = tmpRoot / "caches.conf"
        writeCachesConf(conf, url, @[kpA.pubHex])
        # The trusted publisher builds and publishes the REAL output.
        usePublisher(conf, url, kpA)
        let run1 = applyOnce(tmpRoot, "pub", "digest-edge")
        checkBuiltLocally(run1)
        let real = localOutputsDigest(witnessShellAction("digest-edge",
          run1.cwd), tmpRoot / "stage-real")
        check real.startsWith("blake3:") and real.len == 7 + 64
        useConsumer(conf, url)
        # A consumer whose profile pins a DIFFERENT digest: the entry is
        # signed by a key it trusts and is still refused; nothing lands.
        let wrong = "blake3:" & repeat('0', 64)
        let cwdWrong = tmpRoot / "cwd-wrong"
        let runWrong = applyAction(tmpRoot, "wrong",
          pinnedAction("digest-edge", cwdWrong, wrong, substituteOnly = true))
        check not runWrong.outcome.ok
        check "output digest mismatch" in runWrong.outcome.diagnostic
        check not runWrong.shellRan
        check not fileExists(cwdWrong / OutRel)
        # The same consumer pinning the REAL digest: a substitute.
        let runRight = applyAction(tmpRoot, "right",
          pinnedAction("digest-edge", tmpRoot / "cwd-right", real,
                       substituteOnly = true))
        if not runRight.outcome.ok:
          echo "RIGHT DIAGNOSTIC: ", runRight.outcome.diagnostic
        checkSubstituted(runRight)

  test "present outputs that hash to the pin are a hit without a fetch":
    when not (defined(linux) or defined(macosx)):
      skip("POSIX shell action and cache server subprocess; no Windows arm")
    else:
      withCacheServer("m4-present-"):
        let kpA = makeKeypair(tmpRoot / "key-a")
        let conf = tmpRoot / "caches.conf"
        writeCachesConf(conf, url, @[kpA.pubHex])
        usePublisher(conf, url, kpA)
        let run1 = applyOnce(tmpRoot, "pub", "present-edge")
        checkBuiltLocally(run1)
        let real = localOutputsDigest(witnessShellAction("present-edge",
          run1.cwd), tmpRoot / "stage-real")
        # The outputs are already in place from run1 (same cwd). Point the
        # consumer at a cache that does not exist: a fetch would fail, so a
        # hit here can only have come from the present bytes.
        let deadConf = tmpRoot / "dead.conf"
        writeCachesConf(deadConf, "http://127.0.0.1:9", @[kpA.pubHex])
        useConsumer(deadConf, "http://127.0.0.1:9")
        removeFile(run1.cwd / WitnessRel)
        let again = applyAction(tmpRoot, "present",
          pinnedAction("present-edge", run1.cwd, real, substituteOnly = true))
        check again.outcome.ok
        check again.outcome.cacheHit
        # Verified present, not fetched: not counted as a substitution.
        check not again.outcome.substitutedFromCache
        check not again.shellRan
        check readFile(run1.cwd / OutRel) == ExpectedPayload
        # Tamper with the present output: the pin no longer matches, the
        # dead cache cannot serve it, and the edge FAILS (never rebuilds).
        writeFile(run1.cwd / OutRel, "tampered")
        let tampered = applyAction(tmpRoot, "tampered",
          pinnedAction("present-edge", run1.cwd, real, substituteOnly = true))
        check not tampered.outcome.ok
        check not tampered.shellRan
        check readFile(run1.cwd / OutRel) == "tampered"

  test "a substitute-only edge never builds: a miss is a failure naming the remedy":
    when not (defined(linux) or defined(macosx)):
      skip("POSIX shell action and cache server subprocess; no Windows arm")
    else:
      withCacheServer("m4-subonly-"):
        let kpA = makeKeypair(tmpRoot / "key-a")
        let conf = tmpRoot / "caches.conf"
        writeCachesConf(conf, url, @[kpA.pubHex])
        useConsumer(conf, url)
        let run = applyAction(tmpRoot, "miss",
          pinnedAction("never-published", tmpRoot / "cwd-miss",
                       "blake3:" & repeat('1', 64), substituteOnly = true))
        check not run.outcome.ok
        check "substitute-only edge never-published" in run.outcome.diagnostic
        check "repro infra cache-keys" in run.outcome.diagnostic
        check not run.shellRan
        # Control: the same edge WITHOUT substituteOnly builds locally — the
        # refusal is the flag's, not a broken dispatcher.
        let built = applyAction(tmpRoot, "ctl",
          witnessShellAction("never-published", tmpRoot / "cwd-ctl"))
        checkBuiltLocally(built)

  test "a substitute-only edge without a pinned digest is refused, not trusted":
    when not (defined(linux) or defined(macosx)):
      skip("POSIX shell action and cache server subprocess; no Windows arm")
    else:
      withCacheServer("m4-nopin-"):
        let kpA = makeKeypair(tmpRoot / "key-a")
        let conf = tmpRoot / "caches.conf"
        writeCachesConf(conf, url, @[kpA.pubHex])
        usePublisher(conf, url, kpA)
        checkBuiltLocally(applyOnce(tmpRoot, "pub", "nopin-edge"))
        useConsumer(conf, url)
        # The entry IS in the cache and IS trusted; the hand-built intent
        # says substitute-only with no digest, and that is refused.
        let run = applyAction(tmpRoot, "nopin",
          pinnedAction("nopin-edge", tmpRoot / "cwd-nopin", "",
                       substituteOnly = true))
        check not run.outcome.ok
        check "pins no expectedOutputDigest" in run.outcome.diagnostic
        check not fileExists(tmpRoot / "cwd-nopin" / OutRel)

  test "repro cache publish reports the digest the consumer verifies against":
    # The producer's pin comes from `publishInProcess`'s report; the
    # consumer's check hashes the raw archive it fetched, and the no-fetch
    # hit hashes the present outputs with the same packer. All three must
    # be one number, or a producer pins a digest nothing ever matches.
    when not (defined(linux) or defined(macosx)):
      skip("POSIX shell action and cache server subprocess; no Windows arm")
    else:
      withCacheServer("m4-publish-digest-"):
        let kpA = makeKeypair(tmpRoot / "key-a")
        let conf = tmpRoot / "caches.conf"
        writeCachesConf(conf, url, @[kpA.pubHex])
        usePublisher(conf, url, kpA)
        let run1 = applyOnce(tmpRoot, "pub", "report-edge")
        checkBuiltLocally(run1)
        let action = witnessShellAction("report-edge", run1.cwd)
        let present = localOutputsDigest(action, tmpRoot / "stage-present")
        # Publish the same outputs again by hand, under another id so the
        # server takes it, and read the digest the publisher reports.
        let stage = tmpRoot / "stage-publish"
        createDir(stage / "bin")
        copyFile(run1.cwd / OutRel, stage / OutRel)
        let keypair = peerAuth.loadOrGenerateKeypair(kpA.certPath, kpA.keyPath)
        let idy = buildActionCacheIdentity(
          witnessShellAction("report-edge-2", run1.cwd), "")
        let res = publishInProcess(PublishInProcessRequest(
          entryKeyHex: deriveCacheEntryKeyHex(idy),
          prefixDir: stage,
          identity: idy,
          endpoint: url,
          keypair: keypair))
        check res.ok
        check res.rawArchiveDigestHex.len == 64
        check "blake3:" & res.rawArchiveDigestHex == present
