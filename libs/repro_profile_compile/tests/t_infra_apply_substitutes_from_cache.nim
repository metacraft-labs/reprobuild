## Windows-Runner-Binary-Cache-Deploy M4 — apply substitutes build-action
## outputs from the binary cache instead of building them locally.
##
## This is the M4 gate. It proves that `repro infra apply`'s build-action
## dispatcher (``repro_profile_compile.mkBuildActionDispatcher``, the same
## closure ``runInfraApply`` injects into ``ApplyOptions.buildActionDispatcher``)
## PREFERS fetching a build-action's OUTPUTS from a real
## ``repro-binary-cache`` server (``bakBinaryCacheSubstitute`` machinery)
## over running the local build, WHEN a cache is configured
## (``REPRO_BINARY_CACHE_URL`` set) AND the cache holds that output.
##
## It is a genuine, non-weak gate:
##
##   * A REAL ``repro-binary-cache`` server subprocess binds 127.0.0.1
##     (the M1/M2 machinery). No stub, no in-memory fake.
##   * The build action runs a REAL ``/bin/sh`` process whose ONLY
##     side effect visible to the assertions is (a) the declared output
##     file under ``cwd`` AND (b) a "witness" marker file OUTSIDE the
##     outputs that the shell touches EVERY time it runs. The witness is
##     how we prove "built locally" vs "served from cache" honestly: a
##     substituted edge never spawns the shell, so the witness is not
##     re-touched.
##   * Run 1 (EMPTY cache): the action builds locally + publishes its
##     output. Asserted: ``substitutedFromCache == false`` and the
##     witness was written (the shell ran).
##   * Run 2 (FRESH cwd, FRESH engine cache root, cache now populated):
##     the output is SUBSTITUTED. Asserted: ``substitutedFromCache ==
##     true``, ``cacheHit == true``, the materialised output is
##     BYTE-IDENTICAL to run 1's, AND the witness is ABSENT (the shell
##     never ran — proof it came from the cache, not a local build).
##   * Negative control (``REPRO_BINARY_CACHE_URL`` UNSET, fresh cwd):
##     the same apply BUILDS LOCALLY — ``substitutedFromCache == false``
##     and the witness is written. Proves the feature is off-by-default
##     and the local-build fallback is intact.
##
## The counts come from the REAL dispatcher executing REAL actions
## against the REAL cache server — they are not faked.

import std/[os, osproc, net, random, strutils, tempfiles, unittest]

import repro_elevation
import repro_infra
import repro_profile
import repro_profile_compile

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
  ## IDENTICAL across the run-1 and run-2 cwds. A cwd-baked absolute
  ## path in argv would make the key per-run and the substitute would
  ## never hit. The broker runs the process with ``cwd`` as its working
  ## directory, so the relative paths resolve under the right root.
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

suite "M4 — repro infra apply substitutes build-action outputs from cache":

  test "t_infra_apply_substitutes_from_cache":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      check fileExists(ServerBinary)

      let tmpRoot = createTempDir("m4-substitute-", "")
      defer:
        try: removeDir(tmpRoot) except CatchableError: discard

      let port = pickPort()
      let serverRoot = tmpRoot / "server-store"
      createDir(serverRoot)
      let srvProc = startServer(serverRoot, port)
      defer:
        try: srvProc.terminate() except CatchableError: discard
        try: srvProc.close() except CatchableError: discard
      # Hard requirement: the server MUST be listening before either
      # apply run, or the substitute/publish would spuriously miss. A
      # 15 s window (300 x 50 ms) tolerates a slow first bind.
      doAssert waitForListener(port),
        "cache server did not start listening on 127.0.0.1:" & $port
      let url = "http://127.0.0.1:" & $port

      # Sandbox the auto-credential dir so the publisher's keygen never
      # touches real user config.
      putEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR", tmpRoot / "cred")
      defer: delEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR")

      # -------------------------------------------------------------------
      # RUN 1 — empty cache, URL set: build locally + publish.
      # -------------------------------------------------------------------
      let cwd1 = tmpRoot / "cwd1"
      let cacheRoot1 = tmpRoot / "engine-cache-1"
      let witness1 = cwd1 / WitnessRel
      createDir(cwd1); createDir(cacheRoot1)

      putEnv("REPRO_BINARY_CACHE_URL", url)
      let ctx1 = FixtureContext(filePrefix: tmpRoot / "ctx1")
      let disp1 = mkBuildActionDispatcher(cacheRoot1, ctx1)
      let pba1 = witnessShellAction("m4-edge", cwd1)
      let out1 = disp1(@[pba1])

      check out1.len == 1
      if not out1[0].ok:
        echo "RUN1 DIAGNOSTIC: ", out1[0].diagnostic
      check out1[0].ok
      check not out1[0].substitutedFromCache      # built locally
      check not out1[0].cacheHit
      check fileExists(cwd1 / OutRel)
      check readFile(cwd1 / OutRel) == ExpectedPayload
      # The shell RAN on run 1 (local build) — witness present + non-empty.
      check fileExists(witness1)
      check readFile(witness1).len == 1
      let run1Bytes = readFile(cwd1 / OutRel)

      # -------------------------------------------------------------------
      # RUN 2 — FRESH cwd + FRESH engine cache, cache populated: SUBSTITUTE.
      # -------------------------------------------------------------------
      let cwd2 = tmpRoot / "cwd2"
      let cacheRoot2 = tmpRoot / "engine-cache-2"
      let witness2 = cwd2 / WitnessRel
      createDir(cwd2); createDir(cacheRoot2)

      # URL still set. Fresh cwd (no local output), fresh engine cache
      # (no engine action-cache hit possible), witness2 does not exist.
      let ctx2 = FixtureContext(filePrefix: tmpRoot / "ctx2")
      let disp2 = mkBuildActionDispatcher(cacheRoot2, ctx2)
      let pba2 = witnessShellAction("m4-edge", cwd2)
      let out2 = disp2(@[pba2])

      check out2.len == 1
      check out2[0].ok
      # THE M4 ASSERTION: served from the binary cache, not built locally.
      check out2[0].substitutedFromCache
      check out2[0].cacheHit
      # Byte-identical to run 1's locally-built output.
      check fileExists(cwd2 / OutRel)
      check readFile(cwd2 / OutRel) == run1Bytes
      # NO local build ran: the witness was never created (the shell did
      # not spawn on the substituted edge).
      check not fileExists(witness2)

      # -------------------------------------------------------------------
      # NEGATIVE CONTROL — URL UNSET, fresh cwd: build locally, 0 cache hits.
      # -------------------------------------------------------------------
      delEnv("REPRO_BINARY_CACHE_URL")
      let cwd3 = tmpRoot / "cwd3"
      let cacheRoot3 = tmpRoot / "engine-cache-3"
      let witness3 = cwd3 / WitnessRel
      createDir(cwd3); createDir(cacheRoot3)

      let ctx3 = FixtureContext(filePrefix: tmpRoot / "ctx3")
      let disp3 = mkBuildActionDispatcher(cacheRoot3, ctx3)
      let pba3 = witnessShellAction("m4-edge", cwd3)
      let out3 = disp3(@[pba3])

      check out3.len == 1
      check out3[0].ok
      # Off-by-default: NOT substituted, built locally.
      check not out3[0].substitutedFromCache
      check not out3[0].cacheHit
      check fileExists(cwd3 / OutRel)
      check readFile(cwd3 / OutRel) == ExpectedPayload
      # The shell RAN (local build) — witness present.
      check fileExists(witness3)
      check readFile(witness3).len == 1
