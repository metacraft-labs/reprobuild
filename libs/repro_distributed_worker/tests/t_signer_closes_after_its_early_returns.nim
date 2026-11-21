## The Distributed Execution certificate signer leaves every connection
## through the same close, never through a ``finally`` that awaits it, and
## a connection that ends early never stops it (reprobuild-pm issue
## 2026-11-07-distributed-worker-cert-signer-awaits-in-finally-asserts-
## under-nim-2-2-4).
##
## The signer and the worker run in this process: a worker the signer does
## not trust (its server returns early, after the proof) and one it trusts
## but has not authorized (a refusal) are both turned away cleanly, the
## signer counts no failed connection, and an authorized worker is
## certified after them. Under Nim 2.2.4, the construct this replaces
## (``return`` through a ``finally`` that awaits) raised an
## ``AssertionDefect`` ("yielded nil") at the first early return.
##
## The worker's side answers each refusal with a tuple built at run time:
## under Nim 2.2.4 and 2.2.10 an ``{.async.}`` proc returning a constant
## tuple literal of two or more strings dies with SIGSEGV (reprobuild-pm
## issue 2026-11-07-async-procs-returning-a-constant-tuple-of-strings-
## segfault-under-nim-2-2), and the untrusted worker's request takes that
## path ("the certificate signer closed the connection").
##
## Falsifying builds, each red under Nim 2.2.4 only, which
## ``scripts/run_nim224_lane.sh`` builds this test with:
## ``signer-close-in-finally`` (the server's close in the ``finally``, as
## before: ``failedConnections`` counts the first early return) and
## ``signer-constant-tuple-return`` (that refusal as a constant literal,
## as before: the process dies at the first request).
##
## Mocks: the signing operation answers a fixed certificate (the
## certificate's content is not what this holds; ``ssh-keygen`` signing is
## held by ``t_worker_signing_certificates_are_time_bound``).

import std/[asyncdispatch, net, os, strutils, tempfiles, times,
            unittest]

import repro_peer_cache/[identity, pki, tls, types]
import repro_distributed_worker/[receiver, signer]

import ../../repro_peer_cache/tests/m7_test_pki

proc pump(f: Future[tuple[ok: bool; certificate, reason: string]]):
    tuple[ok: bool; certificate, reason: string] =
  let deadline = epochTime() + 30.0
  while not f.finished and epochTime() < deadline:
    try: poll(50) except ValueError: sleep(50)
  doAssert f.finished, "the request did not finish"
  f.read()

suite "the certificate signer closes after its early returns":
  test "untrusted and unauthorized workers are turned away; the signer keeps serving":
    let base = createTempDir("signer-early-", "")
    defer: removeDir(base)
    let signerId = loadOrCreateHostIdentity(base / "signer" / "host-ca.crt",
      base / "signer" / "host-ca.key")
    let anchorsDir = base / "signer" / "anchors"
    createDir(anchorsDir)
    writeFile(base / "authorized", "")
    writeFile(base / "revoked", "")
    let s = newCertSignerServer(signerId, anchorsDir, base / "authorized",
      base / "revoked", base / "issued.log",
      proc (h: PeerId; r: CertificateRequest; at: Time):
          tuple[ok: bool; certificate, serial, reason: string] {.gcsafe.} =
        (true, "certificate-for-" & $h, "1", ""),
      "127.0.0.1")
    s.start()
    defer: s.stop()
    let endpoint = initEndpoint("127.0.0.1", s.listenPort)
    let signerAnchors = loadTrustAnchorFile(base / "signer" / "host-ca.crt")
    let req = CertificateRequest(content: "git-tree-sha1:" & repeat('c', 40),
      project: "p", platform: "linux-x86_64", target: "t",
      commands: @[@["/bin/true"]], baseCommit: repeat('a', 40))
    proc ask(w: TestNode): tuple[ok: bool; certificate, reason: string] =
      let leaf = mintLeaf(w.identity, lrDaemon)
      let provider = proc (): LeafCredential {.gcsafe, closure.} = leaf
      pump(requestCertificate(endpoint, provider, signerAnchors,
                              signerId.hostId, req, timeoutMs = 10_000))
    # A worker the signer does not trust: the server returns early.
    let stranger = newTestNode(base, "stranger")
    let r1 = ask(stranger)
    check not r1.ok
    # Trusted, not authorized: refused.
    let worker = newTestNode(base, "worker")
    copyFile(worker.certPath, anchorsDir / "worker.crt")
    let r2 = ask(worker)
    checkpoint r2.reason
    check not r2.ok and "not authorized" in r2.reason
    check s.failedConnections == 0
    # Authorized: certified, by the same signer.
    writeFile(base / "authorized", $worker.identity.hostId & "\n")
    let r3 = ask(worker)
    checkpoint r3.reason
    check r3.ok and r3.certificate == "certificate-for-" & $worker.identity.hostId
    check s.failedConnections == 0
