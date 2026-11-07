## Distributed-Execution M7 (CRED-1 for the certificate-signing key): a
## worker signs each `test-certificate.v1` with a one-issuance key that its
## per-host signing CA certified for at most an hour, callers register the
## CA (`cert-authority <key>`), and the verifier judges the signature at the
## record's OWN `issued_at`.
##
##   * a record dated inside the signing certificate's window verifies — even
##     though that certificate has already expired by the time anyone checks
##     (certificates are imported and re-checked long after issuance);
##   * the SAME key cannot produce a record dated outside its window (a key
##     stolen after its hour forges nothing current) — the falsifier of the
##     "short-lived" claim;
##   * a record signed through ANOTHER host's signing CA does not verify for
##     this worker's `key_id` (per-host, CRED-4);
##   * a plain (non-certificate) registered key verifies exactly as before;
##   * the certificate signer (`repro cert-signer serve`, the real process)
##     refuses a worker listed in its revocation file even while the worker
##     is still on its authorized list, records the refusal in its register,
##     treats an unreadable revocation file as "revoked" (fail closed), and
##     issues again once the listing is withdrawn (positive control). No
##     lease is involved: the worker side is the production client
##     (`requestCertificate`) holding a worker's daemon leaf.
##
## MOCK POLICY — none: real `ssh-keygen` keys, certificates and signatures;
## the production signer (`signCertificateOnIssuance`) and verifier
## (`verifyCertificateSignature`); the shipped `repro cert-signer` process.

import std/[asyncdispatch, os, osproc, strutils, tempfiles, times, unittest]

import repro_cli_support
import repro_peer_cache/[identity, pki, types]
import repro_distributed_worker

import ../../repro_peer_cache/tests/m7_test_pki

proc keygen(args: varargs[string]) =
  let res = execCmdEx(quoteShellCommand(@["ssh-keygen"] & @args))
  doAssert res.exitCode == 0, res.output

proc record(issuedAt: DateTime): TestCertificate =
  TestCertificate(schema: testCertificateSchemaV1,
    framework: reprobuildFrameworkId, project: "m7-signing",
    platform: currentPlatformTag(), targets: @["t"], result: tcrPassed,
    issuedAt: issuedAt.format("yyyy-MM-dd'T'HH:mm:ss'Z'"), issuer: "test",
    vcs: TestCertificateVcs(repo: "m7-signing",
      content: "git-tree-sha1:" & repeat('a', 40), untracked: false),
    commands: @[TestCertificateCommand(argv: @["/bin/true"])])

suite "Distributed-Execution M7: worker signing certificates are time-bound":

  test "a certificate-signed record verifies at its own issuance time only":
    if findExe("ssh-keygen").len == 0:
      checkpoint("ssh-keygen is the signer and verifier")
      fail()
    else:
      let dir = createTempDir("m7-signing-", "")
      defer: removeDir(dir)
      let keyId = "repro-worker-0123456789abcdef"
      keygen("-q", "-t", "ed25519", "-N", "", "-f", dir / "ca")
      keygen("-q", "-t", "ed25519", "-N", "", "-f", dir / "other-ca")
      keygen("-q", "-t", "ed25519", "-N", "", "-f", dir / "leaf")
      # A signing certificate whose hour ENDED an hour ago.
      keygen("-q", "-s", dir / "ca", "-I", "past", "-n",
        allowedSignerIdentity(keyId), "-V", "-2h:-1h", dir / "leaf.pub")
      var store = RegisteredKeyStore()
      store.registerKey(keyId, "cert-authority " &
        readFile(dir / "ca.pub").strip())
      let inside = now().utc - initDuration(minutes = 90)
      var good = record(inside)
      signCertificateOnIssuance(good, keyId, dir / "leaf-cert.pub")
      check verifyCertificateSignature(good, store) == svValid
      # The same key, a record dated NOW: outside its window.
      var late = record(now().utc)
      signCertificateOnIssuance(late, keyId, dir / "leaf-cert.pub")
      check verifyCertificateSignature(late, store) == svBadSignature
      # Another host's CA certified the key: not this worker's key_id.
      keygen("-q", "-t", "ed25519", "-N", "", "-f", dir / "leaf2")
      keygen("-q", "-s", dir / "other-ca", "-I", "other", "-n",
        allowedSignerIdentity(keyId), "-V", "-5m:+1h", dir / "leaf2.pub")
      var foreign = record(now().utc)
      signCertificateOnIssuance(foreign, keyId, dir / "leaf2-cert.pub")
      check verifyCertificateSignature(foreign, store) == svBadSignature
      # A plain registered key is unaffected by the time binding.
      var plainStore = RegisteredKeyStore()
      plainStore.registerKey("plain-key", readFile(dir / "leaf.pub").strip())
      var plain = record(now().utc - initDuration(days = 30))
      signCertificateOnIssuance(plain, "plain-key", dir / "leaf")
      check verifyCertificateSignature(plain, plainStore) == svValid

  test "the signer refuses a revoked worker, failing closed":
    if findExe("ssh-keygen").len == 0:
      checkpoint("ssh-keygen is the certificate signer")
      fail()
    else:
      let base = createTempDir("m7-signer-revoked-", "")
      var w = newTestNode(base, "worker")
      var signer = prepareSigner(base)
      signer.servesWorker(w)
      signer.startSigner()
      defer:
        try: setFilePermissions(signer.revokedPath, {fpUserRead, fpUserWrite})
        except CatchableError: discard
        stopSigner(signer)
        removeDir(base)
      let leaf = mintLeaf(w.identity, lrDaemon)
      let provider = proc(): LeafCredential {.gcsafe, closure.} = leaf
      let anchors = loadTrustAnchorFile(w.tlsDir / "cert-signer.crt")
      let colon = signer.endpoint.rfind(':')
      let endpoint = initEndpoint(signer.endpoint[0 ..< colon],
        Port(parseInt(signer.endpoint[colon + 1 .. ^1])))
      let req = CertificateRequest(content: "git-tree-sha1:" & repeat('c', 40),
        project: "m7-signer", platform: currentPlatformTag(), target: "t",
        commands: @[@["/bin/sh", "t.sh"]], baseCommit: repeat('a', 40))
      proc ask(): tuple[ok: bool; certificate, reason: string] =
        waitFor requestCertificate(endpoint, provider, anchors,
          signer.hostId, req)
      let workerId = $w.identity.hostId
      let issuedLog = signer.stateDir / "issued.log"
      # Positive control: authorized, not revoked — certified.
      let first = ask()
      checkpoint("first: " & first.reason)
      check first.ok
      check first.certificate.len > 0
      # Revoked, though still on the authorized list: refused, and recorded.
      check workerId in readFile(signer.authorizedPath)
      writeFile(signer.revokedPath, "# revoked workers\n" & workerId & "\n")
      let revoked = ask()
      checkpoint("revoked: " & revoked.reason)
      check not revoked.ok
      check revoked.certificate.len == 0
      check "is revoked" in revoked.reason
      check ("refused " & workerId & " worker " & workerId & " is revoked") in
        readFile(issuedLog)
      # An unreadable revocation file cannot show the worker is NOT revoked.
      writeFile(signer.revokedPath, "")
      setFilePermissions(signer.revokedPath, {})
      var unreadable = false
      try:
        discard readFile(signer.revokedPath)
      except CatchableError:
        unreadable = true
      if unreadable:                    # (not when the test runs as root)
        let closed = ask()
        checkpoint("unreadable revocation file: " & closed.reason)
        check not closed.ok
        check "is revoked" in closed.reason
      setFilePermissions(signer.revokedPath, {fpUserRead, fpUserWrite})
      # Withdrawn: certified again.
      let again = ask()
      checkpoint("again: " & again.reason)
      check again.ok
      check again.certificate.len > 0
