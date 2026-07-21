## Windows-Runner-Binary-Cache-Deploy M7 (prereq a+b) gate —
## ``t_repro_https_cache_end_to_end``.
##
## The end-to-end HTTPS PROOF the M6 review flagged as missing: it proves
## that BOTH of the production ``repro`` binary's cache-consumer paths work
## over **real TLS** once the M7 prerequisites land —
##
##   (a) ``--define:ssl`` on the ``repro`` entrypoint (so the embedded
##       ``http_pool`` substitute client TLS-wraps for ``https://``), and
##   (b) the deploy-agent's ``defaultHttpGet`` building an OpenSSL context
##       from ``REPRO_BINARY_CACHE_CA_FILE`` / ``REPRO_BINARY_CACHE_TLS_INSECURE``.
##
## This binary is compiled ``-d:ssl`` (matching how the packaged ``repro``
## now builds), so the exact code an ssl-enabled ``repro`` runs is exercised
## here — the http_pool TLS path and the agent SSL context are the PRODUCT
## code, not test copies.
##
## Two consumer legs, both over ``https://`` with a self-signed cert
## verified against its own CA (``REPRO_BINARY_CACHE_CA_FILE``):
##
##   1. **M4 path over HTTPS** — the apply/substitute path. A real
##      ``repro-binary-cache`` daemon runs as a SUBPROCESS over HTTPS. The
##      REAL ``mkBuildActionDispatcher`` (the closure ``repro infra apply``
##      injects) publishes a NUL-laced build-action output to the HTTPS
##      cache on a miss, then — from a FRESH engine-cache root + FRESH cwd —
##      SUBSTITUTES it back over TLS. Asserted: the substitute did NOT raise
##      (an ssl-less ``repro`` would raise "https:// requires -d:ssl"),
##      ``substitutedFromCache == true``, and the bytes are byte-identical.
##
##   2. **M5 path over HTTPS** — the deploy-agent's manifest pull. A signed
##      ``DeployManifest`` is served over HTTPS by an in-test threaded TLS
##      static server. The agent (``runAgentTick`` with NO ``httpGet``
##      override, i.e. the REAL ``defaultHttpGet``) fetches it over TLS,
##      verifies the ECDSA-P256 signature, and applies it. Asserted: with
##      the correct CA the fetch SUCCEEDS and the desired-state side effect
##      is on disk. A NEGATIVE leg (re-exec of this binary with a WRONG CA)
##      proves the TLS verification is REAL: the same fetch against the same
##      server FAILS the handshake and the agent does NOT apply — verify is
##      genuine peer verification, not skip-all.
##
## The daemon runs as a subprocess (like the M4/M5/M6 gates) so its async
## accept loop and the synchronous TLS client live in separate processes
## (no single-event-loop deadlock). The M5 static TLS server runs on a
## dedicated OS thread with a blocking accept loop — again no shared event
## loop with the blocking client. The negative CA leg runs in a re-exec'd
## CHILD of this same binary because ``defaultHttpGet``'s SSL context (like
## ``http_pool``'s) is cached per-process on first use, so a fresh process
## is the honest way to exercise a different verify mode.
##
## Requires ``openssl`` on PATH (present in the reprobuild dev shell) to mint
## the self-signed certs. The daemon binary path is
## ``REPRO_BINARY_CACHE_SERVER`` (the ``-d:ssl`` build), falling back to
## ``build/test-bin/repro_binary_cache_m6`` for a manual run.

import std/[httpclient, net, os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_deploy_agent
import repro_deploy_agent/apply_hook
import ../../repro_binary_cache_client/src/repro_binary_cache_client/http_pool
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import repro_elevation      # FixtureContext (the per-apply fixture context)
import repro_profile
import repro_profile_compile

const Target = "windows-runner-001"

proc sslServerBin(): string =
  let env = getEnv("REPRO_BINARY_CACHE_SERVER", "")
  if env.len > 0: return env
  result = getCurrentDir() / "build" / "test-bin" / "repro_binary_cache_m6"

proc pickPort(): int =
  var sock = newSocket()
  defer:
    try: sock.close() except CatchableError: discard
  sock.setSockOpt(OptReuseAddr, true)
  sock.bindAddr(Port(0), "127.0.0.1")
  let local = sock.getLocalAddr()
  int(local[1])

proc genSelfSignedCert(dir, cn: string): tuple[cert, key: string] =
  let cert = dir / "tls-cert.pem"
  let key = dir / "tls-key.pem"
  let cmd = "openssl req -x509 -newkey ec " &
    "-pkeyopt ec_paramgen_curve:prime256v1 -nodes " &
    "-keyout " & quoteShell(key) & " -out " & quoteShell(cert) &
    " -days 1 -subj /CN=" & cn & " -addext subjectAltName=IP:127.0.0.1"
  let (outp, rc) = execCmdEx(cmd)
  if rc != 0:
    raise newException(IOError, "openssl cert gen failed: " & outp)
  (cert, key)

proc waitForHttpsStatus(url: string; expectedStatus: int;
                        expectedBody = ""; tries = 300;
                        sleepMs = 100): bool =
  let pool = newHttpPool(maxConnections = 1, receiveTimeoutMs = 2000)
  defer: pool.close()
  for _ in 0 ..< tries:
    try:
      let res = pool.getEntireBody(url)
      if res.statusCode == expectedStatus:
        if expectedBody.len == 0 or cast[string](res.body) == expectedBody:
          return true
    except CatchableError:
      discard
    sleep(sleepMs)
  false

proc waitForStdHttpsStatus(url, caFile: string; expectedStatus: int;
                           tries = 300; sleepMs = 100): bool =
  for _ in 0 ..< tries:
    try:
      let ctx = newContext(verifyMode = CVerifyPeer, caFile = caFile)
      let client = newHttpClient(timeout = 2000, sslContext = ctx)
      defer: client.close()
      let resp = client.request(url, HttpGet)
      if int(resp.code) == expectedStatus:
        discard resp.body
        return true
    except CatchableError:
      discard
    sleep(sleepMs)
  false

proc stopProcess(p: Process) =
  try: p.terminate() except CatchableError: discard
  try:
    discard p.waitForExit(timeout = 5000)
    if p.peekExitCode() == -1:
      try: p.kill() except CatchableError: discard
      discard p.waitForExit(timeout = 5000)
  except CatchableError:
    discard
  try: p.close() except CatchableError: discard

proc processState(p: Process): string =
  try:
    let code = p.peekExitCode()
    if code == -1:
      return "still running"
    return "exited " & $code
  except CatchableError as e:
    return "state unavailable: " & e.msg

# ---------------------------------------------------------------------------
# A minimal HTTPS static server for the M5 leg: serves ONE fixed byte-blob
# (the signed DeployManifest) at any path over TLS. Runs on a dedicated OS
# thread with a BLOCKING accept loop — no shared async event loop with the
# blocking client, so no deadlock. It just needs to speak enough HTTP/1.1
# for std/httpclient to read a body.
# ---------------------------------------------------------------------------

type M5Server = object
  certFile, keyFile: string
  port: int
  body: string

var gM5: M5Server
var gM5Stop: bool

proc m5ServerThread() {.thread.} =
  {.gcsafe.}:
    let ctx = newContext(certFile = gM5.certFile, keyFile = gM5.keyFile,
                         verifyMode = CVerifyNone)
    var listener = newSocket()
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(gM5.port), "127.0.0.1")
    listener.listen()
    while not gM5Stop:
      var client: Socket
      try:
        listener.accept(client)
      except CatchableError:
        continue
      try:
        ctx.wrapConnectedSocket(client, handshakeAsServer)
        # Drain the request line + headers (until blank line). We don't
        # care about the target — every path returns the same manifest.
        var line = ""
        while true:
          try: client.readLine(line, timeout = 3000)
          except CatchableError: break
          if line.len == 0: break
        let resp = "HTTP/1.1 200 OK\r\n" &
          "Content-Type: application/octet-stream\r\n" &
          "Content-Length: " & $gM5.body.len & "\r\n" &
          "Connection: close\r\n\r\n" & gM5.body
        client.send(resp)
      except CatchableError:
        discard
      finally:
        try: client.close() except CatchableError: discard
    try: listener.close() except CatchableError: discard

# ---------------------------------------------------------------------------
# Build actions (shared by both legs). NUL-laced payloads so a "treat as
# text" bug in the pack/substitute path would corrupt the bytes and the
# byte-identity assertions would catch it.
# ---------------------------------------------------------------------------

const M4OutRel = "bin/https-artifact.dat"
const M4WitnessRel = ".witness"
const M4PrintfArg = "M7-https\\000\\001\\002-tail"
const M4Expected = "M7-https\x00\x01\x02-tail"

proc m4Action(cwd: string): ProfileBuildAction =
  let script =
    "mkdir -p bin; " &
    "printf '" & M4PrintfArg & "' > '" & M4OutRel & "'; " &
    "printf x >> '" & M4WitnessRel & "'"
  ProfileBuildAction(
    id: "m7-https-edge",
    argv: @["/bin/sh", "-c", script],
    cwd: cwd, deps: @[], inputs: @[], outputs: @[M4OutRel],
    commandStatsId: "m7.https.write", toolIdentityRefs: @[],
    requiresElevation: true, cacheable: true)

const M5OutRel = "bin/deploy-https.txt"
const M5Payload = "converged-over-https"

proc m5Action(cwd: string): ProfileBuildAction =
  ProfileBuildAction(
    id: "m7-m5-edge",
    argv: @["/bin/sh", "-c",
      "mkdir -p \"$(dirname '" & M5OutRel & "')\"; " &
      "printf '%s' '" & M5Payload & "' > '" & M5OutRel & "'"],
    cwd: cwd, deps: @[], inputs: @[], outputs: @[M5OutRel],
    commandStatsId: "m7.m5.write", toolIdentityRefs: @[],
    requiresElevation: true, cacheable: true)

proc signedM5Manifest(signer: peerAuth.PeerKeypair; cwd: string):
    DeployManifest =
  result = DeployManifest(
    target: Target, sequence: 7'u64, deploymentId: "m7-https",
    profileText: "", buildActions: @[m5Action(cwd)])
  signManifest(signer, result)

proc manifestToString(m: DeployManifest): string =
  let bytes = encodeManifest(m)
  result = newString(bytes.len)
  for i, b in bytes: result[i] = char(b)

# ---------------------------------------------------------------------------
# NEGATIVE-CA CHILD: a re-exec of this binary. It runs the REAL agent fetch
# (defaultHttpGet, no override) against the parent's HTTPS manifest server
# with whatever REPRO_BINARY_CACHE_CA_FILE the parent set. A correct CA →
# aoApplied (exit 0); a wrong CA → the TLS handshake fails and the fetch is
# a source error (exit 3). This proves the SSL context does REAL peer
# verification (a fresh process = fresh cached context).
# ---------------------------------------------------------------------------

proc runNegativeChild() =
  let manifestUrl = getEnv("M7_MANIFEST_URL")
  let anchorHex = getEnv("M7_ANCHOR_HEX")
  let cwd = getEnv("M7_APPLY_CWD")
  let stateDir = getEnv("M7_STATE_DIR")
  let applyState = getEnv("M7_APPLY_STATE")
  let cacheRoot = getEnv("M7_CACHE_ROOT")
  var anchorBytes: peerAuth.PublicKeyBytes
  doAssert anchorHex.len == anchorBytes.len * 2
  for i in 0 ..< anchorBytes.len:
    anchorBytes[i] = byte(parseHexInt(anchorHex[i*2 .. i*2+1]))
  let cfg = AgentConfig(
    target: Target, sources: @[manifestUrl],
    anchors: anchorsFromKeypairs(@[anchorBytes]),
    stateDir: stateDir, fetchTimeoutMs: 8000)
  let deps = AgentDeps(
    apply: mkRunInfraApplyHook(applyState, cacheRoot,
      hostIdentity = "m7-neg-host", reproExe = "/usr/bin/false"))
  # NOTE: no httpGet override — this drives the REAL defaultHttpGet.
  let r = runAgentTick(cfg, deps)
  case r.kind
  of aoApplied:
    # The child re-uses the parent's SIGNED manifest (served over HTTPS),
    # whose build-action cwd is baked to the PARENT's applyCwd — the child
    # cannot re-target it, so the side effect lands there, not under this
    # child's M7_APPLY_CWD. Reaching aoApplied therefore already proves the
    # whole TLS pipeline succeeded (fetch over https + ECDSA verify + apply);
    # that is the CONTROL leg's success signal. The WRONG-CA leg must never
    # get here (its handshake fails → aoSourceError below).
    discard cwd
    quit(0)
  of aoSourceError:
    stderr.writeLine("child source error: " & r.message)
    quit(3)
  else:
    stderr.writeLine("child outcome " & $r.kind & ": " & r.message)
    quit(5)

when isMainModule:
  if getEnv("M7_NEGATIVE_CHILD").len > 0:
    runNegativeChild()

# ---------------------------------------------------------------------------

suite "M7 — repro consumes the HTTPS binary cache end-to-end (M4 + M5 over TLS)":

  test "t_repro_https_cache_end_to_end":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      when not defined(ssl):
        # This gate is meaningless without TLS compiled in; the generator
        # stamps -d:ssl on it. A non-ssl build must not silently pass.
        checkpoint("gate requires -d:ssl")
        fail()
      else:
        let bin = sslServerBin()
        check fileExists(bin)

        let tmpRoot = createTempDir("m7-https-", "")
        defer:
          try: removeDir(tmpRoot) except CatchableError: discard

        # --- TLS material: the REAL CA (self-signed) + a WRONG CA ---------
        let certDir = tmpRoot / "tls"; createDir(certDir)
        let (certFile, keyFile) = genSelfSignedCert(certDir, "127.0.0.1")
        let wrongDir = tmpRoot / "tls-wrong"; createDir(wrongDir)
        let (wrongCert, _) = genSelfSignedCert(wrongDir, "127.0.0.1")

        # Point BOTH product SSL paths (http_pool + agent) at the real CA so
        # they perform REAL peer verification. Must be set before the first
        # use (both contexts cache on first use).
        putEnv("REPRO_BINARY_CACHE_CA_FILE", certFile)
        defer: delEnv("REPRO_BINARY_CACHE_CA_FILE")

        # =============================================================
        # LEG 1 — M4 substitute over HTTPS (real dispatcher, real daemon)
        # =============================================================
        let tlsPort = pickPort()
        let srvRoot = tmpRoot / "srv"; createDir(srvRoot)
        let srvProc = startProcess(bin, args = [
          "--root=" & srvRoot,
          "--listen=127.0.0.1:" & $tlsPort,
          "--tls-cert=" & certFile,
          "--tls-key=" & keyFile],
          options = {poStdErrToStdOut, poParentStreams})
        defer: stopProcess(srvProc)
        let httpsUrl = "https://127.0.0.1:" & $tlsPort
        doAssert waitForHttpsStatus(httpsUrl & "/healthz", 200, "ok"),
          "HTTPS cache daemon did not become healthy on 127.0.0.1:" &
            $tlsPort & " (" & processState(srvProc) & ")"

        putEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR", tmpRoot / "cred")
        defer: delEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR")
        putEnv("REPRO_BINARY_CACHE_URL", httpsUrl)
        defer: delEnv("REPRO_BINARY_CACHE_URL")

        # RUN 1: empty cache → build locally + publish over HTTPS.
        let cwd1 = tmpRoot / "m4-cwd1"
        let cacheRoot1 = tmpRoot / "m4-cache1"
        createDir(cwd1); createDir(cacheRoot1)
        let ctx1 = FixtureContext(filePrefix: tmpRoot / "m4-ctx1")
        let disp1 = mkBuildActionDispatcher(cacheRoot1, ctx1)
        let out1 = disp1(@[m4Action(cwd1)])
        check out1.len == 1
        if not out1[0].ok:
          echo "M4 RUN1 DIAGNOSTIC: ", out1[0].diagnostic
        check out1[0].ok
        check not out1[0].substitutedFromCache      # built locally
        check fileExists(cwd1 / M4OutRel)
        check readFile(cwd1 / M4OutRel) == M4Expected
        check fileExists(cwd1 / M4WitnessRel)        # shell ran
        let run1Bytes = readFile(cwd1 / M4OutRel)

        # RUN 2: FRESH cwd + FRESH engine cache → SUBSTITUTE over HTTPS.
        # If -d:ssl were absent this would RAISE at http_pool.parseTarget.
        let cwd2 = tmpRoot / "m4-cwd2"
        let cacheRoot2 = tmpRoot / "m4-cache2"
        createDir(cwd2); createDir(cacheRoot2)
        let ctx2 = FixtureContext(filePrefix: tmpRoot / "m4-ctx2")
        let disp2 = mkBuildActionDispatcher(cacheRoot2, ctx2)
        var raised = false
        # Assert INSIDE the try so we never touch the type name explicitly
        # (BuildActionApplyOutcome lives in the heavy repro_infra tree). The
        # substitute over https:// is what must not raise; the ``raised``
        # flag proves that ssl is linked (an ssl-less build raises here).
        try:
          let out2 = disp2(@[m4Action(cwd2)])
          check out2.len == 1
          check out2[0].ok
          # THE M4-over-HTTPS ASSERTION: served from the TLS cache.
          check out2[0].substitutedFromCache
          check out2[0].cacheHit
          check fileExists(cwd2 / M4OutRel)
          check readFile(cwd2 / M4OutRel) == run1Bytes  # byte-identical
          check not fileExists(cwd2 / M4WitnessRel)     # shell never ran
        except CatchableError as e:
          raised = true
          echo "M4 RUN2 RAISED: ", e.msg
        check not raised                             # did NOT raise on https

        # =============================================================
        # LEG 2 — M5 deploy-agent manifest pull over HTTPS (real fetch)
        # =============================================================
        let signer = peerAuth.generateKeypair()
        let anchors = anchorsFromKeypairs(@[signer.publicKey])
        let applyCwd = tmpRoot / "m5-target"; createDir(applyCwd)
        let manifest = signedM5Manifest(signer, applyCwd)

        # Bring up the threaded HTTPS static server serving the manifest.
        let m5Port = pickPort()
        gM5 = M5Server(certFile: certFile, keyFile: keyFile, port: m5Port,
                       body: manifestToString(manifest))
        gM5Stop = false
        var m5Thread: Thread[void]
        createThread(m5Thread, m5ServerThread)
        let manifestUrl = "https://127.0.0.1:" & $m5Port & "/latest.rdm"
        doAssert waitForStdHttpsStatus(manifestUrl, certFile, 200),
          "M5 HTTPS manifest server did not become ready on 127.0.0.1:" &
            $m5Port

        let agentState = tmpRoot / "m5-agent"
        let applyState = tmpRoot / "m5-apply"
        let m5CacheRoot = tmpRoot / "m5-cache"
        for d in [agentState, applyState, m5CacheRoot]: createDir(d)

        # POSITIVE: real defaultHttpGet (no override) + correct CA → applies.
        block m5Positive:
          let cfg = AgentConfig(
            target: Target, sources: @[manifestUrl], anchors: anchors,
            stateDir: agentState, fetchTimeoutMs: 8000)
          let deps = AgentDeps(
            apply: mkRunInfraApplyHook(applyState, m5CacheRoot,
              hostIdentity = "m7-m5-host", reproExe = "/usr/bin/false"))
          let r = runAgentTick(cfg, deps)
          check r.kind == aoApplied
          check r.sequence == 7'u64
          check fileExists(applyCwd / M5OutRel)
          check readFile(applyCwd / M5OutRel) == M5Payload
          check readLastAppliedSequence(cfg) == 7'u64

        # NEGATIVE: re-exec THIS binary as a child with a WRONG CA. The real
        # defaultHttpGet's TLS handshake must FAIL (fresh process = fresh
        # cached context) → aoSourceError (child exit 3), proving the CA is
        # actually verified (not skip-all). A CONTROL child with the correct
        # CA must exit 0, proving the URL/server are fine and only the CA
        # differs between the two legs.
        var anchorHex = ""
        for b in signer.publicKey:
          anchorHex.add(toHex(int(b), 2).toLowerAscii())

        proc runChild(caFile: string): int =
          var env = newStringTable()
          for k, v in envPairs(): env[k] = v
          env["M7_NEGATIVE_CHILD"] = "1"
          env["M7_MANIFEST_URL"] = manifestUrl
          env["M7_ANCHOR_HEX"] = anchorHex
          env["M7_APPLY_CWD"] = tmpRoot / "m5-neg-target"
          env["M7_STATE_DIR"] = tmpRoot / "m5-neg-agent"
          env["M7_APPLY_STATE"] = tmpRoot / "m5-neg-apply"
          env["M7_CACHE_ROOT"] = tmpRoot / "m5-neg-cache"
          env["REPRO_BINARY_CACHE_CA_FILE"] = caFile
          createDir(tmpRoot / "m5-neg-target")
          createDir(tmpRoot / "m5-neg-agent")
          createDir(tmpRoot / "m5-neg-apply")
          createDir(tmpRoot / "m5-neg-cache")
          let child = startProcess(getAppFilename(), args = @[],
            env = env, options = {poStdErrToStdOut, poParentStreams})
          defer:
            try: child.close() except CatchableError: discard
          result = child.waitForExit()

        block m5NegativeWrongCa:
          # Wrong CA: the server's cert is NOT signed by / equal to wrongCert,
          # so peer verification must FAIL the handshake.
          let rc = runChild(wrongCert)
          check rc == 3        # aoSourceError (TLS handshake failed)
          # And nothing applied on the child's target.
          check not fileExists((tmpRoot / "m5-neg-target") / M5OutRel)

        block m5ControlCorrectCa:
          # Same child, same URL, CORRECT CA → must SUCCEED (exit 0). This
          # proves the negative leg failed on the CA, not on a broken URL.
          removeDir(tmpRoot / "m5-neg-target")
          removeDir(tmpRoot / "m5-neg-agent")
          removeDir(tmpRoot / "m5-neg-apply")
          removeDir(tmpRoot / "m5-neg-cache")
          let rc = runChild(certFile)
          check rc == 0        # aoApplied: correct CA → real TLS fetch+apply
          # (The apply side effect lands in the manifest's baked applyCwd,
          # already byte-identity-checked in block m5Positive above; here we
          # only need that the SAME fetch that failed on the wrong CA now
          # SUCCEEDS on the correct CA — proving real peer verification.)

        # Tear down the M5 server thread.
        gM5Stop = true
        # Nudge the accept loop so it observes the stop flag and exits.
        try:
          let s = newSocket(); s.connect("127.0.0.1", Port(m5Port))
          s.close()
        except CatchableError: discard
        try: joinThread(m5Thread) except CatchableError: discard
