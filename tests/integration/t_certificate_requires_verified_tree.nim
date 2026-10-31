## Distributed-Execution M7: `t_certificate_is_not_issued_for_an_unverified_tree`.
##
## After the test node runs, the worker RE-VERIFIES the worktree's
## `git-tree-sha1` before asking for a signature; a tree mutated between
## materialization and signing yields NO certificate (and a
## `certificate-tree-mismatch` detection in the off-host sink). Positive
## control: an unmodified tree still receives its certificate, and
## `repro certify --verify` accepts it on the caller — and refuses the same
## certificate once a byte of it is changed, when it is checked against
## content other than what was sent, or when no content is given at all
## (threat model G32: `--content` is required).
##
## This is asset A1 of the threat model: a signed `test-certificate.v1` for a
## tree that was never tested that way is what lets `repro push` skip
## re-execution. The mutating test node is the realistic way to obtain one —
## a test that rewrites a tracked file and then passes.
##
## THE SIGNER IS NOT ON THE WORKER (EDGE-5, threat model D5). Certificates
## come from the certificate signer (`repro cert-signer serve`, its own
## process), which holds a signing CA per worker. This test also shows:
##
##   * the worker's own state holds no signing material at all — no signing
##     CA, no signing key, before or after an issuance;
##   * the certificate is dated by the SIGNER's clock and its one-issuance
##     key's window is minutes, not an hour;
##   * the moment the signer de-authorizes the worker, the worker obtains
##     nothing more — over the same worker process, the same request;
##     re-authorized, it does again;
##   * a goal that tripped a lease detector (here: an exec outside the
##     closure) passes as a test but is NOT certified, and the withholding
##     is reported (G32);
##   * a repository with a submodule verifies and is certified (G32: gitlinks
##     used to be left out of the tree id, so it never verified).
##
## TRUST PROFILES (2026-10-20). The first case is the HARDENED profile: the
## certificate signer and the evidence sink. The second case is the TRUSTED
## profile (the default): the worker signs nothing and runs no signer; the
## REQUESTER signs after verifying the response and the goal's execution
## record (`requesterSignVerifiedGoal`). A tree the goal rewrote, a goal that
## tripped a detector, and a record that does not match its digest each get
## NO certificate from the requester; the honest goal's requester-signed
## certificate verifies with `repro certify --verify`.
##
## WHAT WITHHOLDS A CERTIFICATE differs by profile (review fix, 2026-10-20).
## HARDENED keeps the strict rule: ANY lease report withholds — the
## `test-denied` node, whose only report is a benign file denial (it tries to
## write outside its lease and passes), gets nothing. TRUSTED withholds only
## for the plan's DET triggers (here: the exec outside the closure, the tree
## mismatch); the same `test-denied` goal IS requester-signed, its `fs-denied`
## still recorded in the execution record — otherwise a macOS worker, whose
## compilers probe the build user's home, could never pass a signed goal.
## G38 (coordinator decision 2026-10-20): the strict rule does not make the
## hardened profile unusable — a goal that runs the REAL C compiler
## (`test-compiles`, the same `cc` the other M7 worker tests build with)
## produces no lease report and IS certified. Its libc's nscd probe connects
## to a unix socket that does not exist in the lease's new root; an attempt
## that cannot reach anything is not a breach and is not reported (a
## reachable unix socket is still refused and reported — the daemon-socket
## breach of `t_execution_lease_confinement`).
## And the requester's MINIMUM ISOLATION LEVEL: a requester that requires a
## stronger level than the result carries refuses it; at the level it got,
## it signs.
##
## The reddening negative controls (removing the re-verification mints a
## certificate for the mutated tree; a signer that ignores its authorization
## list certifies a de-authorized worker; a receiver that ignores lease
## detections certifies the detecting goal) are neuter experiments recorded
## in the milestone's Verification log.
##
## MOCK POLICY — none (see `m7_worker_fixture.nim`); the signer is the real
## `repro cert-signer` with real `ssh-keygen` keys and certificates; the
## verifier is the shipped `repro certify --verify`.

import std/[asyncdispatch, os, osproc, sets, strutils, tables, times, unittest]

import repro_cli_support
import repro_peer_cache
import repro_test_support
import repro_workspace_snapshot
import repro_distributed_worker

import repro_test_support/reasoned_skip
import ./m7_worker_fixture

const
  Check = "#!/bin/sh\nset -eu\ngrep -q fixture README\nmkdir -p out\necho ok > out/ok\n"
  Mutate = "#!/bin/sh\nset -eu\necho 'rewritten by the test' >> README\nmkdir -p out\necho ok > out/ok\n"
  Sneaky = "#!/bin/sh\nset -eu\ncp /bin/sh \"$TMPDIR/sneaky\" && \"$TMPDIR/sneaky\" -c true || true\nmkdir -p out\necho ok > out/ok\n"
  Denied = "#!/bin/sh\nset -eu\n( : > /repro-m7-outside-the-lease ) 2>/dev/null || true\nmkdir -p out\necho ok > out/ok\n"
  HelloC = "#include <stdio.h>\nint main(void) { puts(\"hello\"); return 0; }\n"

proc noSigningMaterial(dir: string): seq[string] =
  ## Every file under `dir` that looks like signing material: an OpenSSH
  ## private key, an SSH certificate, a `signing-*` file.
  if not dirExists(dir):
    return
  for path in walkDirRec(dir):
    let name = path.extractFilename
    if name.startsWith("signing") or name.endsWith("-cert.pub"):
      result.add(path)
      continue
    try:
      if getFileSize(path) < 64 * 1024 and
          "OPENSSH PRIVATE KEY" in readFile(path):
        result.add(path)
    except CatchableError:
      discard

suite "Distributed-Execution M7: certificates require a re-verified tree":

  test "t_certificate_is_not_issued_for_an_unverified_tree":
    if not hardenedWorkerHere():
      echo HardenedWorkerNA
      skip("platform N/A: hardened workers are Linux-only")
    else:
      if findExe("ssh-keygen").len == 0:
        checkpoint("ssh-keygen is the certificate signer and verifier; " &
          "not found on PATH=" & getEnv("PATH"))
        fail()
      else:
        let base = m7TestBase("repro-m7-cert")
        var w = newTestNode(base, "worker")
        var o = newTestNode(base, "orch")
        mutualTrust([w, o])
        w.grantRoles(o, "cache-peer,orchestrator")
        var sink = prepareEvidenceSink(base)
        sink.acceptsFrom(w)
        sink.acceptsFrom(o)
        sink.startEvidenceSink()
        var signer = prepareSigner(base)
        signer.servesWorker(w)
        signer.startSigner()
        let cc = ccPath()
        check cc.len > 0                # the G38 node compiles with it
        let repo = makeFixtureRepo(base, [("README", "fixture\n"),
          ("check.sh", Check), ("mutate.sh", Mutate), ("sneaky.sh", Sneaky),
          ("denied.sh", Denied), ("hello.c", HelloC)])
        writeFile(base / "repos", "fixture " & repo.cache & "\n")
        var worker = newWorkerDaemon(base, w)
        var orch: Orchestrator
        defer:
          if not orch.host.isNil: orch.host.stop()
          stopWorkerDaemon(worker)
          stopSigner(signer)
          stopEvidenceSink(sink)
          removeDir(base)
        worker.startWorkerDaemon(workerSpec(sink, base / "repos",
          signer = signer.endpoint))
        check "signer=" & signer.endpoint in worker.daemonLog()
        orch = newOrchestrator(base, o, worker.peerCachePort(), sink.endpoint)
        let workerId = w.identity.hostId
        check orch.waitConnected(workerId, worker)

        let snap = repo.snapshotOf("fixture", [])
        let tree = snap.manifest.primaryRepo.gitTreeSha1
        let manifestDigest = orch.publish(encodeManifest(snap.manifest))
        var desc = GraphCacheDescriptor(schema: DescriptorSchema,
          project: "m7-cert", platform: hostOS & "/" & hostCPU,
          snapshotContentId: contentIdOf(snap.manifest),
          nodes: @[
            GraphNode(id: "test-honest", argv: @["/bin/sh", "check.sh"],
              inputs: @["check.sh", "README"], outputs: @["out/ok"],
              isTest: true),
            GraphNode(id: "test-mutating", argv: @["/bin/sh", "mutate.sh"],
              inputs: @["mutate.sh", "README"], outputs: @["out/ok"],
              isTest: true),
            GraphNode(id: "test-sneaky", argv: @["/bin/sh", "sneaky.sh"],
              inputs: @["sneaky.sh"], outputs: @["out/ok"], isTest: true),
            GraphNode(id: "test-denied", argv: @["/bin/sh", "denied.sh"],
              inputs: @["denied.sh"], outputs: @["out/ok"], isTest: true),
            GraphNode(id: "test-compiles",
              argv: @[cc, "-O1", "-o", "out/hello", "hello.c"],
              inputs: @["hello.c"], outputs: @["out/hello"], isTest: true)])
        desc.sortNodes()
        let descDigest = orch.publish(encodeDescriptor(desc))
        pump(300)
        proc goalOn(d, m: array[32, byte]; node: string): ReachGoalResponse =
          let r = orch.reachGoal(workerId, ReachGoalRequest(requestId: node,
            graphDescriptorDigest: d, snapshotManifestDigest: m, goalNode: node,
            issueCertificate: true))
          check r.kind == grkResponse
          result = decodeResponse(r.payload)
          checkpoint(node & ": " & $result.status & " before=" &
            result.treeBefore & " after=" & result.treeAfter & " reason=" &
            result.reason & "\nstderr: " & result.stderrTail)
        proc goal(node: string): ReachGoalResponse =
          goalOn(descDigest, manifestDigest, node)

        # The worker holds no signing material — at all.
        check noSigningMaterial(worker.stateDir).len == 0
        check noSigningMaterial(w.xdgState).len == 0

        # -- A tree mutated during the test yields no certificate --------------
        let mutated = goal("test-mutating")
        check mutated.status == gsCompleted        # the test itself passed
        check mutated.treeBefore == tree
        check mutated.treeAfter != tree
        check mutated.certificate.len == 0         # but nothing was signed
        let mismatch = sink.waitForDetection("certificate-tree-mismatch")
        check mismatch.len >= 1
        for e in mismatch:
          check e.senderHostId == workerId
          check e.record.field("expectedTree") == tree
          check e.record.field("observedTree") == mutated.treeAfter

        # -- A goal that tripped a lease detector is not certified (G32) -------
        let sneaky = goal("test-sneaky")
        check sneaky.status == gsCompleted          # its exit code was 0
        check sneaky.treeAfter == tree              # and the tree is intact
        check sneaky.certificate.len == 0           # yet nothing was signed
        check "detection" in sneaky.reason
        check sink.waitForDetection("certificate-withheld-detections").len >= 1

        # -- HARDENED keeps the strict rule: a benign file denial withholds ----
        let denied = goal("test-denied")
        check denied.status == gsCompleted
        check denied.treeAfter == tree
        check denied.leaseReports >= 1
        check denied.certificate.len == 0
        check "detection" in denied.reason

        # -- G38: a goal running the real C compiler is certified -------------
        # Its libc's nscd probe reaches nothing in the new root, so it is not
        # a report; the strict rule above then has nothing to withhold for.
        let compiles = goal("test-compiles")
        checkpoint("test-compiles: leaseReports=" & $compiles.leaseReports &
          " reason=" & compiles.reason)
        check compiles.status == gsCompleted
        check compiles.treeAfter == tree
        check compiles.leaseReports == 0
        check compiles.certificate.len > 0

        # -- Positive control: the unmodified tree is certified ----------------
        let issuedAround = getTime()
        let honest = goal("test-honest")
        check honest.status == gsCompleted
        check honest.treeAfter == tree
        check honest.certificate.len > 0
        let certPath = base / "caller" / "test-honest.cert.toml"
        createDir(certPath.parentDir)
        writeFile(certPath, honest.certificate)
        # Still no signing material on the worker after an issuance.
        check noSigningMaterial(worker.stateDir).len == 0
        # The signer recorded the issuance in its register.
        check "issued " & $workerId in readFile(signer.stateDir / "issued.log")
        # The caller registers the worker's signing CA as the SIGNER publishes
        # it (CRED-4: one key id per worker).
        let reg = signer.registrationOf(w)
        check reg.keyId == "repro-worker-" & ($workerId)[0 ..< 16]
        check reg.publicKey.startsWith("cert-authority ")
        let keys = base / "caller" / "registered-keys.toml"
        writeFile(keys, "schema = \"reprobuild.registered-keys.v1\"\n\n" &
          "[[key]]\nkey_id = \"" & reg.keyId & "\"\npublic_key = \"" &
          reg.publicKey & "\"\nstatus = \"active\"\n")
        proc verify(path, content: string): CmdResult =
          var args = @[publicReproBin(), "certify", "--verify", path,
            "--registered-keys", keys]
          if content.len > 0: args.add(@["--content", content])
          runShell(shellCommand(args), repoRootDir())
        let accepted = verify(certPath, "git-tree-sha1:" & tree)
        checkpoint("repro certify --verify: " & accepted.output)
        check accepted.code == 0
        check "certificate valid" in accepted.output
        # Dated by the signer's clock, now — not by anything the worker wrote.
        let dated = honest.certificate.find("issued_at = \"")
        check dated >= 0
        if dated >= 0:
          let stamp = honest.certificate[dated + 13 ..< dated + 33]
          let at = parse(stamp, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc()).toTime
          check abs((at - issuedAround).inSeconds) < 120
        # The verifier is not vacuous: wrong content, no content, or a changed
        # byte fails.
        check verify(certPath, "git-tree-sha1:" & mutated.treeAfter).code != 0
        check verify(certPath, "").code != 0        # --content is required
        let tampered = base / "caller" / "tampered.cert.toml"
        writeFile(tampered, honest.certificate.replace("test-honest",
          "test-mutating"))
        check verify(tampered, "git-tree-sha1:" & tree).code != 0

        # -- De-authorized at the signer: the worker obtains nothing more ------
        signer.deauthorize(w)
        let refused = goal("test-honest")
        check refused.status == gsCompleted
        check refused.certificate.len == 0
        check "not authorized" in refused.reason
        check "refused " & $workerId in readFile(signer.stateDir / "issued.log")
        signer.servesWorker(w)
        let again = goal("test-honest")
        check again.certificate.len > 0

        # -- A repository with a submodule verifies and is certified (G32) -----
        let subRepo = makeFixtureRepo(base / "sub", [("lib.c", "int lib;\n")])
        let res = execCmdEx(quoteShellCommand(["git", "-C", repo.dir, "-c",
          "protocol.file.allow=always", "submodule", "add", "-q", subRepo.dir,
          "vendor/lib"]))
        check res.exitCode == 0
        discard execCmdEx(quoteShellCommand(["git", "-C", repo.dir, "commit",
          "-q", "-m", "submodule"]))
        discard execCmdEx(quoteShellCommand(["git", "-C", repo.cache, "fetch",
          "-q", repo.dir, "+refs/heads/main:refs/heads/main"]))
        var subFixture = repo
        subFixture.baseCommit = execCmdEx(quoteShellCommand(["git", "-C",
          repo.dir, "rev-parse", "HEAD"])).output.strip()
        let subSnap = subFixture.snapshotOf("fixture", [])
        let subManifest = orch.publish(encodeManifest(subSnap.manifest))
        var subDesc = desc
        subDesc.snapshotContentId = contentIdOf(subSnap.manifest)
        let subDescDigest = orch.publish(encodeDescriptor(subDesc))
        pump(300)
        let subHonest = goalOn(subDescDigest, subManifest, "test-honest")
        check subHonest.status == gsCompleted
        check subHonest.treeBefore == subSnap.manifest.primaryRepo.gitTreeSha1
        check subHonest.certificate.len > 0

  test "trusted profile: the requester signs only a verified tree":
    if findExe("ssh-keygen").len == 0:
      checkpoint("ssh-keygen is the certificate signer and verifier; " &
        "not found on PATH=" & getEnv("PATH"))
      fail()
    else:
      let base = m7TestBase("repro-m7-cert-trusted")
      var w = newTestNode(base, "worker")
      var o = newTestNode(base, "orch")
      mutualTrust([w, o])
      w.grantRoles(o, "cache-peer,orchestrator")
      let repo = makeFixtureRepo(base, [("README", "fixture\n"),
        ("check.sh", Check), ("mutate.sh", Mutate), ("sneaky.sh", Sneaky),
          ("denied.sh", Denied)])
      writeFile(base / "repos", "fixture " & repo.cache & "\n")
      var worker = newWorkerDaemon(base, w)
      var orch: Orchestrator
      defer:
        if not orch.host.isNil: orch.host.stop()
        stopWorkerDaemon(worker)
        removeDir(base)
      worker.startWorkerDaemon(trustedWorkerSpec(base / "repos"))
      check "profile=trusted" in worker.daemonLog()
      check "signer=none" in worker.daemonLog()
      orch = newOrchestrator(base, o, worker.peerCachePort(),
        profile = tpTrusted)
      let workerId = w.identity.hostId
      check orch.waitConnected(workerId, worker)
      # The REQUESTER's signing key and its registration.
      createDir(base / "caller")
      let keyPath = base / "caller" / "requester-key"
      let gen = execCmdEx(quoteShellCommand(["ssh-keygen", "-q", "-t",
        "ed25519", "-N", "", "-C", "requester", "-f", keyPath]))
      check gen.exitCode == 0
      let keyId = "repro-requester-" & ($o.identity.hostId)[0 ..< 16]
      let keys = base / "caller" / "registered-keys.toml"
      writeFile(keys, "schema = \"reprobuild.registered-keys.v1\"\n\n" &
        "[[key]]\nkey_id = \"" & keyId & "\"\npublic_key = \"" &
        readFile(keyPath & ".pub").strip() & "\"\nstatus = \"active\"\n")

      let snap = repo.snapshotOf("fixture", [])
      let tree = snap.manifest.primaryRepo.gitTreeSha1
      let manifestDigest = orch.publish(encodeManifest(snap.manifest))
      var desc = GraphCacheDescriptor(schema: DescriptorSchema,
        project: "m7-cert", platform: hostOS & "/" & hostCPU,
        snapshotContentId: contentIdOf(snap.manifest),
        nodes: @[
          GraphNode(id: "test-honest", argv: @["/bin/sh", "check.sh"],
            inputs: @["check.sh", "README"], outputs: @["out/ok"],
            isTest: true),
          GraphNode(id: "test-mutating", argv: @["/bin/sh", "mutate.sh"],
            inputs: @["mutate.sh", "README"], outputs: @["out/ok"],
            isTest: true),
          GraphNode(id: "test-sneaky", argv: @["/bin/sh", "sneaky.sh"],
            inputs: @["sneaky.sh"], outputs: @["out/ok"], isTest: true),
          GraphNode(id: "test-denied", argv: @["/bin/sh", "denied.sh"],
            inputs: @["denied.sh"], outputs: @["out/ok"], isTest: true)])
      desc.sortNodes()
      let descDigest = orch.publish(encodeDescriptor(desc))
      pump(300)
      proc goal(node: string): ReachGoalResponse =
        let r = orch.reachGoal(workerId, ReachGoalRequest(requestId: node,
          graphDescriptorDigest: descDigest,
          snapshotManifestDigest: manifestDigest, goalNode: node,
          issueCertificate: true))
        check r.kind == grkResponse
        result = decodeResponse(r.payload)
        checkpoint(node & ": " & $result.status & " before=" &
          result.treeBefore & " after=" & result.treeAfter & " reason=" &
          result.reason)
      proc ctxFor(node: string): RequesterGoalContext =
        let idx = desc.findNode(node)
        RequesterGoalContext(expectedContent: "git-tree-sha1:" & tree,
          project: desc.project, platform: desc.platform, target: node,
          argv: desc.nodes[idx].argv, isTest: desc.nodes[idx].isTest,
          baseCommit: repo.baseCommit,
          issuer: "repro-requester@" & $o.identity.hostId)
      proc sign(resp: ReachGoalResponse; node: string;
                recordOverride: seq[byte] = @[]): tuple[ok: bool;
                  certificate, reason: string] =
        let rec = if recordOverride.len > 0: recordOverride
                  else: orch.fetchExecutionRecord(workerId,
                    resp.executionRecordDigest)
        result = requesterSignVerifiedGoal(resp, rec, ctxFor(node), keyId,
          keyPath)
        checkpoint(node & " requester: ok=" & $result.ok & " " & result.reason)

      # -- A tree mutated during the test: the requester refuses -------------
      let mutated = goal("test-mutating")
      check mutated.status == gsCompleted        # the test itself passed
      check mutated.treeAfter != tree
      check mutated.certificate.len == 0         # the trusted worker signs nothing
      let m = sign(mutated, "test-mutating")
      check not m.ok
      check m.certificate.len == 0
      check "tree mismatch" in m.reason
      # …and the mismatch is a recorded detection (record + local log).
      let mRec = decodeExecutionRecord(orch.fetchExecutionRecord(workerId,
        mutated.executionRecordDigest))
      var sawMismatch = false
      for d in mRec.detections:
        if d.trigger == "certificate-tree-mismatch": sawMismatch = true
      check sawMismatch
      check "certificate-tree-mismatch" in worker.detectionLog()

      # -- A goal that tripped a detector: the requester refuses -------------
      let sneaky = goal("test-sneaky")
      check sneaky.status == gsCompleted
      check sneaky.treeAfter == tree
      let s1 = sign(sneaky, "test-sneaky")
      check not s1.ok
      check "exec-outside-closure" in s1.reason

      # -- TRUSTED: a benign sandbox report is recorded, not disqualifying ---
      let denied = goal("test-denied")
      check denied.status == gsCompleted
      check denied.treeAfter == tree
      check denied.leaseReports >= 1
      check "requester signs" in denied.reason      # the worker withheld nothing
      let dRec = decodeExecutionRecord(orch.fetchExecutionRecord(workerId,
        denied.executionRecordDigest))
      var sawDenied = false
      for d in dRec.detections:
        if d.trigger == "fs-denied": sawDenied = true
        check d.trigger != "exec-outside-closure"
      check sawDenied                                  # still recorded
      let ds = sign(denied, "test-denied")
      check ds.ok                                      # and signed
      check ds.certificate.len > 0

      # -- Positive control: the honest goal, requester-signed, verifies -----
      let honest = goal("test-honest")
      check honest.status == gsCompleted
      check honest.treeAfter == tree
      check honest.certificate.len == 0
      check "requester signs" in honest.reason
      let signed = sign(honest, "test-honest")
      check signed.ok
      # The requester's minimum isolation level: a result weaker than the
      # requester requires is refused; at the level it got, it is signed.
      check honest.isolation.len > 0
      let honestRec = orch.fetchExecutionRecord(workerId,
        honest.executionRecordDigest)
      # Unconditional, host-independent: re-issue the honest result as one
      # confined WITHOUT a layer the requester requires (a consistent
      # response + record pair, so only the isolation check can refuse it),
      # and as one with a weaker base. Both are refused; the requirement
      # the result does meet is signed.
      proc weakened(level: string): (ReachGoalResponse, seq[byte]) =
        var rec = decodeExecutionRecord(honestRec)
        rec.isolation = level
        let bytes = encodeExecutionRecord(rec)
        var resp = honest
        resp.isolation = level
        resp.executionRecordDigest = executionRecordDigestOf(bytes)
        (resp, bytes)
      var strict = ctxFor("test-honest")
      strict.minIsolation = "linux-namespace+landlock"
      for level in ["linux-namespace+floor+memfd-noexec", "macos-seatbelt",
                    "windows-job"]:
        check not isolationSatisfies(level, strict.minIsolation)
        let (wResp, wRec) = weakened(level)
        let weak = requesterSignVerifiedGoal(wResp, wRec, strict, keyId,
          keyPath)
        checkpoint("min isolation " & strict.minIsolation & " vs " & level &
          ": " & weak.reason)
        check not weak.ok
        check weak.certificate.len == 0
        check "does not meet the required" in weak.reason
        # Control: the same re-issued pair, with no minimum, is signed —
        # so the refusal above is the isolation check and nothing else.
        check requesterSignVerifiedGoal(wResp, wRec, ctxFor("test-honest"),
          keyId, keyPath).ok
      block:
        let (wResp, wRec) = weakened("linux-namespace+floor+landlock")
        check requesterSignVerifiedGoal(wResp, wRec, strict, keyId,
          keyPath).ok
      var exact = ctxFor("test-honest")
      exact.minIsolation = honest.isolation
      check requesterSignVerifiedGoal(honest, honestRec, exact, keyId,
        keyPath).ok
      let certPath = base / "caller" / "test-honest.cert.toml"
      writeFile(certPath, signed.certificate)
      proc verify(path, content: string): CmdResult =
        runShell(shellCommand(@[publicReproBin(), "certify", "--verify", path,
          "--registered-keys", keys, "--content", content]), repoRootDir())
      let accepted = verify(certPath, "git-tree-sha1:" & tree)
      checkpoint("repro certify --verify: " & accepted.output)
      check accepted.code == 0
      check verify(certPath, "git-tree-sha1:" & mutated.treeAfter).code != 0
      # A record that is not the one the response names: refused.
      var forged = orch.fetchExecutionRecord(workerId,
        honest.executionRecordDigest)
      check forged.len > 0
      if forged.len > 0:
        forged[^2] = byte(ord(' '))
        check not sign(honest, "test-honest", forged).ok
      # The trusted worker never held signing material.
      check noSigningMaterial(worker.stateDir).len == 0
