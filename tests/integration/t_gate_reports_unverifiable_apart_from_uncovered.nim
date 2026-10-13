## TC-8c — UNVERIFIABLE is its own verdict at the client gate, the gateway and
## the CI plan (test-certificates Verification §7): "this consumer could not
## judge" is never reported as "not covered", whose remedy — run the tests —
## would be the wrong one. Under ``required`` the push is still refused, and
## the diagnostic names the reason.
##
## Two ways evaluation breaks down, each driven end to end through all three
## consumers (the real ``repro check --mode=pre-push``, a real gateway bare's
## ``pre-receive``, the real ``repro ci plan``):
##
##   1. an UNREADABLE key store — a registered-keys file that does not parse
##      (a missing or empty one trusts nobody, which is not covered);
##   2. a record in a schema version this consumer does not implement,
##      sitting where each consumer looks (the local store for the client
##      gate and the CI plan, the note on the pushed tree for the gateway).
##
## And a third, at the evaluator all three consumers share:
##
##   3. a content id in an algorithm the consumer cannot compute
##      (``git-tree-sha256`` in a SHA-1 repository) is unverifiable, not a
##      mismatch. No consumer can DISCOVER such a record by content: a reader
##      finds a certificate only by computing its id (Transport §2.4, §3), so
##      the store lookup and the tree-keyed note never surface it, and the case
##      is asserted at ``evaluateReprobuildCoverage`` and the CI plan's
##      ``computeCiPlatformPlan``, which the gates call.
##
## Control: an EMPTY registry (nobody trusted) is NOT COVERED at the client
## gate — the other verdict, with the other remedy.
##
## Falsifiability: fold unverifiable into not-covered → every
## ``certificate-unverifiable`` / ``UNVERIFIABLE`` / ``verdict ==
## "unverifiable"`` assertion fails.
##
## Hermetic: local repos, the built ``repro``; no network. Requires git and
## ssh-keygen.

import std/[json, os, osproc, sequtils, strutils, unittest]

include tc8c_store_fixture

proc evidenceOf(report: JsonNode; property: string): string =
  if report.hasKey("failures"):
    for f in report["failures"]:
      if f["property"].getStr() == property:
        return f["evidence"].getStr()

proc publishDirectly(fx: StoreFixture) =
  ## Publish HEAD straight to the upstream (bypassing the gateway) and fetch,
  ## so the client gate's publication stage passes and the certificate stage
  ## is what decides. The gateway, which has not received the commit, still
  ## judges the push it is handed.
  discard gitOut(fx.libAPath, "push", fileUrl(fx.upstreamBare), "main")
  discard gitOut(fx.libAPath, "fetch", "-q", "origin")

suite "TC-8c — unverifiable is reported apart from uncovered":

  test "t_gate_reports_unverifiable_apart_from_uncovered":
    let host = currentPlatformTag()
    let fx = setupStoreFixture(requiredPolicy(@["t-unit"], @[host]),
      "unverifiable")
    defer: removeDir(fx.scratch)
    wireStoreGateway(fx)
    let notes = certificateNotesRef & ":" & certificateNotesRef
    let keysPath = registeredKeyStorePath(fx.workspaceRoot)
    let goodKeys = readFile(keysPath)

    let b = newCommit(fx, "b.txt", "b\n")
    publishDirectly(fx)
    seedLock(fx)
    let issued = issueViaReproTest(fx)
    check issued.code == 0
    let content = "git-tree-sha1:" & gitOut(fx.libAPath, "rev-parse",
      b & "^{tree}")
    let cert = issuedCertificate(fx.userRoot, content, host).cert
    check attachCertificate("git", fx.libAPath, cert).ok
    # Sanity: with a readable key store all three consumers are covered.
    check checkPrePush(fx, b).code == 0
    check planPlatform(ciPlan(fx, host), host)["verdict"].getStr() == "covered"

    # ---- 1. an unreadable key store ---------------------------------------
    writeFile(keysPath, "this is [not a registered-keys store\n")
    block clientGate:
      let gate = checkPrePush(fx, b)
      checkpoint("client gate: " & gate.output)
      check gate.code == 2
      check failureProperties(gate.report) == @["certificate-unverifiable"]
      let evidence = evidenceOf(gate.report, "certificate-unverifiable")
      check evidence.startsWith("unverifiable: ")
      check "registered-key store could not be read" in evidence
    block ciPlanConsumer:
      let host1 = planPlatform(ciPlan(fx, host), host)
      check host1["verdict"].getStr() == "unverifiable"
      check strings(host1, "run") == @["t-unit"]
      check strings(host1, "unevaluated").anyIt(
        "registered-key store could not be read" in it)
    block gateway:
      let push = pushToGateway(fx, @["main", notes])
      checkpoint("gateway: " & push.output)
      check push.code != 0
      check "refs/heads/main: unverifiable: " in push.output
      check "UNVERIFIABLE" in push.output
      check "no covering test certificate" notin push.output

    # Control: an EMPTY registry trusts nobody — that is NOT covered.
    writeFile(keysPath, "")
    let empty = checkPrePush(fx, b)
    check empty.code == 2
    check failureProperties(empty.report) == @["certificate-coverage"]
    check evidenceOf(empty.report, "certificate-coverage").startsWith(
      "uncovered: ")
    writeFile(keysPath, goodKeys)

    # ---- 2. a record in a schema version this build does not implement ----
    let c = newCommit(fx, "c.txt", "c\n")
    publishDirectly(fx)
    seedLock(fx)
    let cTree = gitOut(fx.libAPath, "rev-parse", c & "^{tree}")
    let cContent = "git-tree-sha1:" & cTree
    let future = serializeCertificateToToml(signedCertFor(fx, cContent, c)).
      replace("\"test-certificate.v1\"", "\"test-certificate.v2\"")
    check readCertificateRecord(future).status == crsUnknownSchema
    let dir = fx.userRoot / "v1" / "git-tree-sha1" / cTree
    createDir(dir)
    writeFile(dir / ("f".repeat(64) & ".toml"), future)
    writeFile(fx.scratch / "future-note.txt",
      "# --- test-certificate ---\n" & future)
    discard gitOut(fx.libAPath, "notes", "--ref", certificateNotesRef, "add",
      "-F", fx.scratch / "future-note.txt", cTree)
    block clientGate2:
      let gate = checkPrePush(fx, c)
      checkpoint("client gate (v2 record): " & gate.output)
      check gate.code == 2
      check failureProperties(gate.report) == @["certificate-unverifiable"]
      check "test-certificate.v2" in
        evidenceOf(gate.report, "certificate-unverifiable")
    block ciPlan2:
      let host2 = planPlatform(ciPlan(fx, host), host)
      check host2["verdict"].getStr() == "unverifiable"
      check strings(host2, "run") == @["t-unit"]
    block gateway2:
      let push = pushToGateway(fx, @["main", notes])
      checkpoint("gateway (v2 record): " & push.output)
      check push.code != 0
      check "refs/heads/main: unverifiable: " in push.output
      check "test-certificate.v2" in push.output
      check "UNVERIFIABLE" in push.output

    # ---- 3. an algorithm this consumer cannot compute ---------------------
    let sha256Cert = signedCertFor(fx, "git-tree-sha256:" & "a".repeat(64), c)
    let atC = commitUnderEvaluation(fx.libAPath, c)
    let found = @[FoundCertificate(name: "sha256.toml",
      read: readCertificateRecord(serializeCertificateToToml(sha256Cert)))]
    let keys = readRegisteredKeyStoreChecked(keysPath)
    check keys.availability == ksaReadable
    let verdict = evaluateReprobuildCoverage(found, atC, @[host], @["t-unit"],
      keys, committedLockSource())
    check verdict.outcome == voUnverifiable
    check verdict.unevaluated.anyIt("git-tree-sha256" in it)
    let planned = computeCiPlatformPlan(found, atC, committedLockSource(),
      host, @["t-unit"], cctSkip, keys)
    check planned.verdict == voUnverifiable
    check planned.run == @["t-unit"]
    # ...and discovery by content does not surface it: the lookup computes
    # the repository's own (SHA-1) id.
    check publishCertificateToLocalStore(sha256Cert, fx.libAPath).written
    check findCertificatesInLocalStore(atC).found.allIt(
      it.read.cert.vcs.content != sha256Cert.vcs.content)
