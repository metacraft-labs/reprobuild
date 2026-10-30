## Windows-Runner-Binary-Cache-Deploy M5 gate 1 —
## ``t_repro_deploy_agent_converges_from_signed_manifest``.
##
## Proves the signed desired-state pull loop:
##
##   1. Produce a manifest signed by an ALLOWED signer with a valid
##      sequence. The agent POLLS it (from a plain-path source), VERIFIES
##      the ECDSA-P256 signature against the allowed-signers set, and
##      APPLIES it.
##   2. CONVERGENCE is asserted through the REAL M4 ``runInfraApply`` path
##      (``mkRunInfraApplyHook``): the manifest carries a build action that
##      writes an observable output file. After the tick the file EXISTS
##      with the expected bytes AND the agent's persisted
##      last-applied-sequence advanced — the desired state was reached, not
##      merely "the tick returned ok".
##   3. Present a HIGHER valid sequence → it APPLIES (new observable
##      effect + advanced sequence).
##   4. Present a LOWER and an EQUAL sequence → NEITHER re-applies
##      (monotonicity): the tick reports ``aoConverged`` and the observable
##      side effect from that manifest is ABSENT.
##
## The apply is the production hook, so this ALSO closes the M4 review's
## deferred hardening: a converged manifest whose build-action output is
## served from a real ``repro-binary-cache`` yields
## ``substitutedFromCacheCount == 1`` — but the gate does not require a
## cache to be configured for convergence (off-by-default), so we assert
## convergence via the filesystem effect, which is the honest signal.
## The cache case also checks the trust anchors at the agent level: the
## publisher is the only host with a keypair, a consumer generates none, and
## a consumer whose ``caches.conf`` anchors a different key builds locally
## instead of substituting (``substituted-from-cache 0``).

import std/[os, osproc, net, random, strutils, tempfiles, unittest]

import repro_deploy_agent
import repro_deploy_agent/apply_hook
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import repro_profile

const Target = "windows-runner-001"

const ServerBinary = "build/test-bin" / addFileExt("repro_binary_cache", ExeExt)

proc pickPort(): int =
  randomize(); 26_000 + rand(6_999)

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

proc writeManifestFile(path: string; m: DeployManifest) =
  let bytes = encodeManifest(m)
  var s = newString(bytes.len)
  for i, b in bytes:
    s[i] = char(b)
  let dir = parentDir(path)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)
  writeFile(path, s)

proc shellWriteAction(id, cwd, outRel, payload: string): ProfileBuildAction =
  ## A build action that writes ``payload`` to the cwd-relative ``outRel``.
  ## ``requiresElevation = true`` routes it through the in-process broker
  ## fast path (no monitor CLI needed), matching the M4 gate's shape.
  result = ProfileBuildAction(
    id: id,
    argv: @["/bin/sh", "-c",
            "mkdir -p \"$(dirname '" & outRel & "')\"; " &
            "printf '%s' '" & payload & "' > '" & outRel & "'"],
    cwd: cwd,
    deps: @[],
    inputs: @[],
    outputs: @[outRel],
    commandStatsId: "m5.deploy.write",
    toolIdentityRefs: @[],
    requiresElevation: true,
    cacheable: true)

suite "M5 — deploy agent converges from a signed manifest":

  test "t_repro_deploy_agent_converges_from_signed_manifest":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      let tmpRoot = createTempDir("m5-converge-", "")
      defer:
        try: removeDir(tmpRoot) except CatchableError: discard

      # --- allowed signer (ECDSA-P256, the cache's own scheme) ----------
      let signer = peerAuth.generateKeypair()
      let anchors = anchorsFromKeypairs(@[signer.publicKey])

      # --- durable agent state + apply infra dirs -----------------------
      let agentStateDir = tmpRoot / "agent-state"
      let applyStateDir = tmpRoot / "apply-state"
      let cacheRoot = tmpRoot / "apply-cache"
      let applyCwd = tmpRoot / "target"       # where the profile "converges"
      createDir(agentStateDir); createDir(applyStateDir)
      createDir(cacheRoot); createDir(applyCwd)

      let cfg = AgentConfig(
        target: Target,
        sources: @[tmpRoot / "manifests" / "latest.rdm"],  # plain-path source
        anchors: anchors,
        stateDir: agentStateDir,
        fetchTimeoutMs: 5000)

      let deps = AgentDeps(
        apply: mkRunInfraApplyHook(applyStateDir, cacheRoot,
          hostIdentity = "m5-test-host", reproExe = "/usr/bin/false"))

      let manifestPath = cfg.sources[0]

      proc signedManifest(seqNo: int; depId, outRel, payload: string):
          DeployManifest =
        result = DeployManifest(
          target: Target,
          sequence: uint64(seqNo),
          deploymentId: depId,
          profileText: "",
          buildActions: @[shellWriteAction(
            "m5-edge-" & depId, applyCwd, outRel, payload)])
        signManifest(signer, result)

      # ==================================================================
      # 1. First valid manifest at sequence 10 APPLIES + converges.
      # ==================================================================
      let out1Rel = "bin/deploy-10.txt"
      let out1Payload = "converged-at-10"
      writeManifestFile(manifestPath,
        signedManifest(10, "deploy-10", out1Rel, out1Payload))

      let r1 = runAgentTick(cfg, deps)
      check r1.kind == aoApplied
      check r1.sequence == 10'u64
      # CONVERGENCE: the desired-state side effect is on disk.
      check fileExists(applyCwd / out1Rel)
      check readFile(applyCwd / out1Rel) == out1Payload
      # last-applied-sequence advanced to 10.
      check readLastAppliedSequence(cfg) == 10'u64

      # ==================================================================
      # 2. A SECOND tick against the SAME sequence-10 manifest: converged,
      #    no re-apply (monotonic: 10 is not newer than 10).
      # ==================================================================
      # Remove the side-effect file so a spurious re-apply would recreate it.
      removeFile(applyCwd / out1Rel)
      let r1b = runAgentTick(cfg, deps)
      check r1b.kind == aoConverged
      check r1b.sequence == 10'u64
      check not fileExists(applyCwd / out1Rel)   # NOT re-applied
      check readLastAppliedSequence(cfg) == 10'u64

      # ==================================================================
      # 3. HIGHER valid sequence 11 APPLIES.
      # ==================================================================
      let out2Rel = "bin/deploy-11.txt"
      let out2Payload = "converged-at-11"
      writeManifestFile(manifestPath,
        signedManifest(11, "deploy-11", out2Rel, out2Payload))

      let r2 = runAgentTick(cfg, deps)
      check r2.kind == aoApplied
      check r2.sequence == 11'u64
      check fileExists(applyCwd / out2Rel)
      check readFile(applyCwd / out2Rel) == out2Payload
      check readLastAppliedSequence(cfg) == 11'u64

      # ==================================================================
      # 4a. LOWER sequence 9 is NOT re-applied (monotonicity).
      # ==================================================================
      let out3Rel = "bin/deploy-09.txt"
      writeManifestFile(manifestPath,
        signedManifest(9, "deploy-09", out3Rel, "should-not-apply"))

      let r3 = runAgentTick(cfg, deps)
      check r3.kind == aoConverged
      check not fileExists(applyCwd / out3Rel)   # its effect never ran
      check readLastAppliedSequence(cfg) == 11'u64   # floor unchanged

      # ==================================================================
      # 4b. EQUAL sequence 11 (fresh deployment id) is NOT re-applied.
      # ==================================================================
      let out4Rel = "bin/deploy-11-again.txt"
      writeManifestFile(manifestPath,
        signedManifest(11, "deploy-11b", out4Rel, "should-not-apply"))

      let r4 = runAgentTick(cfg, deps)
      check r4.kind == aoConverged
      check not fileExists(applyCwd / out4Rel)
      check readLastAppliedSequence(cfg) == 11'u64

  test "converged manifest substitutes build outputs from the binary cache":
    # Closes the M4 review's deferred hardening: a signed manifest applied
    # through the agent's PRODUCTION apply hook, with a REAL
    # ``repro-binary-cache`` server configured, serves the build-action
    # output FROM THE CACHE on re-apply — ``substitutedFromCacheCount == 1``
    # (surfaced in the hook's message). Proves the M5 agent's apply path IS
    # the M4 substitute path, end-to-end from a signed desired-state doc.
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      check fileExists(ServerBinary)
      let tmpRoot = createTempDir("m5-cache-", "")
      defer:
        try: removeDir(tmpRoot) except CatchableError: discard

      let port = pickPort()
      let serverRoot = tmpRoot / "server-store"
      createDir(serverRoot)
      let srvProc = startServer(serverRoot, port)
      defer:
        try: srvProc.terminate() except CatchableError: discard
        try: srvProc.close() except CatchableError: discard
      doAssert waitForListener(port),
        "cache server did not start on 127.0.0.1:" & $port
      let url = "http://127.0.0.1:" & $port
      # Apply 1 runs on a PUBLISHER (operator-supplied keypair); applies 2
      # and 3 on consumers. The apply path substitutes only entries signed by
      # a key the consumer's caches.conf anchors, and publishes only with a
      # configured keypair. REPRO_CACHES_CONFIG pins the trust config to this
      # test so the host's own /etc/repro/caches.conf cannot leak in.
      let autoCredDir = tmpRoot / "cred"
      putEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR", autoCredDir)
      defer: delEnv("REPRO_BINARY_CACHE_AUTO_CRED_DIR")
      putEnv("REPRO_BINARY_CACHE_URL", url)
      defer: delEnv("REPRO_BINARY_CACHE_URL")
      proc producerKeypair(dir: string): string =
        ## Writes a keypair under ``dir``; returns the public-key hex.
        createDir(dir)
        discard peerAuth.loadOrGenerateKeypair(dir / "cert", dir / "key")
        readFile(dir / "cert").strip()
      let publisherPub = producerKeypair(tmpRoot / "publisher")
      let strangerPub = producerKeypair(tmpRoot / "stranger")
      proc anchorConf(path, pubHex: string): string =
        writeFile(path, "[fleet]\nurl = \"" & url & "\"\n" &
          "trusted-public-keys = \"" & pubHex & "\"\n")
        path
      let trustsPublisher = anchorConf(tmpRoot / "trusts-publisher.conf",
                                       publisherPub)
      let trustsStranger = anchorConf(tmpRoot / "trusts-stranger.conf",
                                      strangerPub)
      putEnv("REPRO_CACHES_CONFIG", trustsPublisher)
      defer: delEnv("REPRO_CACHES_CONFIG")
      putEnv("REPRO_BINARY_CACHE_KEY_PATH", tmpRoot / "publisher" / "key")
      putEnv("REPRO_BINARY_CACHE_CERT_PATH", tmpRoot / "publisher" / "cert")
      defer:
        delEnv("REPRO_BINARY_CACHE_KEY_PATH")
        delEnv("REPRO_BINARY_CACHE_CERT_PATH")

      let signer = peerAuth.generateKeypair()
      let anchors = anchorsFromKeypairs(@[signer.publicKey])

      # NUL-laced payload so a "treat as text" bug in pack/substitute would
      # corrupt it and the convergence assertion would catch it. Written via
      # printf octal escapes (NUL never in argv).
      const OutRel = "bin/cached-artifact.dat"
      let action = ProfileBuildAction(
        id: "m5-cache-edge",
        argv: @["/bin/sh", "-c",
          "mkdir -p bin; printf 'M5\\000\\001cache' > '" & OutRel & "'"],
        cwd: "",  # per-apply cwd is set below
        outputs: @[OutRel],
        commandStatsId: "m5.cache.write",
        requiresElevation: true, cacheable: true)
      const Expected = "M5\x00\x01cache"

      proc cacheManifest(seqNo: int; depId, cwd: string): DeployManifest =
        var a = action
        a.cwd = cwd
        result = DeployManifest(target: Target, sequence: uint64(seqNo),
          deploymentId: depId, profileText: "", buildActions: @[a])
        signManifest(signer, result)

      # --- apply 1: fresh cache → build locally + publish-on-miss --------
      let agentState1 = tmpRoot / "agent1"
      let applyState1 = tmpRoot / "apply1"
      let cacheRoot1 = tmpRoot / "cache1"
      let cwd1 = tmpRoot / "cwd1"
      for d in [agentState1, applyState1, cacheRoot1, cwd1]: createDir(d)
      let mp1 = tmpRoot / "m1.rdm"
      writeManifestFile(mp1, cacheManifest(1, "cache-1", cwd1))
      let cfg1 = AgentConfig(target: Target, sources: @[mp1], anchors: anchors,
        stateDir: agentState1, fetchTimeoutMs: 5000)
      let deps1 = AgentDeps(apply: mkRunInfraApplyHook(applyState1, cacheRoot1,
        hostIdentity = "m5-cache-host", reproExe = "/usr/bin/false"))
      let a1 = runAgentTick(cfg1, deps1)
      check a1.kind == aoApplied
      check fileExists(cwd1 / OutRel)
      check readFile(cwd1 / OutRel) == Expected
      # Run 1 built locally (empty cache), so 0 substituted.
      check "substituted-from-cache 0" in a1.message

      # --- apply 2: FRESH state/cwd/cacheRoot, cache now populated -------
      # A fresh agent state (last-applied floor = 0) + fresh engine cache
      # root means the ONLY way the output appears is a cache SUBSTITUTE of
      # the content-addressable key run 1 published. This host is a consumer:
      # no keypair, and its caches.conf anchors the publisher's key.
      delEnv("REPRO_BINARY_CACHE_KEY_PATH")
      delEnv("REPRO_BINARY_CACHE_CERT_PATH")
      let agentState2 = tmpRoot / "agent2"
      let applyState2 = tmpRoot / "apply2"
      let cacheRoot2 = tmpRoot / "cache2"
      let cwd2 = tmpRoot / "cwd2"
      for d in [agentState2, applyState2, cacheRoot2, cwd2]: createDir(d)
      let mp2 = tmpRoot / "m2.rdm"
      writeManifestFile(mp2, cacheManifest(1, "cache-1", cwd2))
      let cfg2 = AgentConfig(target: Target, sources: @[mp2], anchors: anchors,
        stateDir: agentState2, fetchTimeoutMs: 5000)
      let deps2 = AgentDeps(apply: mkRunInfraApplyHook(applyState2, cacheRoot2,
        hostIdentity = "m5-cache-host", reproExe = "/usr/bin/false"))
      let a2 = runAgentTick(cfg2, deps2)
      check a2.kind == aoApplied
      check fileExists(cwd2 / OutRel)
      # Byte-identical to run 1's locally-built output.
      check readFile(cwd2 / OutRel) == Expected
      # THE M4-hardening ASSERTION: the output was served from the cache.
      check "substituted-from-cache 1" in a2.message
      # A consumer generates no publisher key of its own.
      check not dirExists(autoCredDir)

      # --- apply 3: a consumer that anchors a DIFFERENT key ----------------
      # The cache holds the same validly signed entry, but this host's
      # caches.conf anchors only a stranger's key. The deploy agent must build
      # locally rather than run outputs signed by a key it does not trust.
      putEnv("REPRO_CACHES_CONFIG", trustsStranger)
      let agentState3 = tmpRoot / "agent3"
      let applyState3 = tmpRoot / "apply3"
      let cacheRoot3 = tmpRoot / "cache3"
      let cwd3 = tmpRoot / "cwd3"
      for d in [agentState3, applyState3, cacheRoot3, cwd3]: createDir(d)
      let mp3 = tmpRoot / "m3.rdm"
      writeManifestFile(mp3, cacheManifest(1, "cache-1", cwd3))
      let cfg3 = AgentConfig(target: Target, sources: @[mp3], anchors: anchors,
        stateDir: agentState3, fetchTimeoutMs: 5000)
      let deps3 = AgentDeps(apply: mkRunInfraApplyHook(applyState3, cacheRoot3,
        hostIdentity = "m5-cache-host", reproExe = "/usr/bin/false"))
      let a3 = runAgentTick(cfg3, deps3)
      check a3.kind == aoApplied
      check readFile(cwd3 / OutRel) == Expected
      check "substituted-from-cache 0" in a3.message
