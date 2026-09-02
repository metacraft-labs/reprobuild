## TC-6 — the gateway honours the project's certificate policy MODE on the
## RECEIVING side: ``required`` REJECTS an uncovered push at ``pre-receive``;
## ``advisory`` ACCEPTS + records (forwards) without blocking; ``off`` ACCEPTS
## unconditionally (no cert check at all).
##
## This drives the SAME real gateway bare + installed ``pre-receive`` /
## ``post-receive`` hooks as the key test, but flips ONLY the gateway config's
## ``gate_mode`` and asserts the receiving-side outcome per mode against a real
## second "upstream" bare:
##
##   - off      : an uncovered push is ACCEPTED and FORWARDED (upstream gets it).
##   - advisory : an uncovered push is ACCEPTED and FORWARDED (upstream gets it),
##                but the gateway emits an advisory diagnostic.
##   - required : an uncovered push is REJECTED at pre-receive (upstream does
##                NOT get it).
##
## W9 — WHY THE THREE ARMS WERE NOT EVIDENCE, AND WHAT THEY NOW ASSERT.
##
## As written, none of the three arms could tell a working gate from a gate
## that never read the push. ``off`` and ``advisory`` returned before any
## object read by construction; ``required``'s only positive claim was that an
## UNCOVERED push is rejected — and a gate that reads nothing finds every push
## uncovered, so it satisfies that arm exactly. All three stayed green while
## the receiving side was in fact unable to read a single pushed object,
## because ``gitNoteRun`` scrubbed the receive-pack quarantine bindings out of
## the child environment.
##
## The fix is to make each arm assert something only a gate that READ the
## pushed certificate note can produce. Every push now carries a REAL
## certificate note — attached to the pushed commit, pushed on
## ``refs/notes/reprobuild/certificates`` alongside the branch — signed by a
## key that is deliberately NOT in the (empty) registry. The gateway must
## therefore report, in its own words, that it saw a certificate and rejected
## it BY KEY ID:
##
##   - required : REJECTED, and the diagnostic names ``key_id '<id>' not
##                registered``. That id exists nowhere but inside the note
##                blob's bytes, so the gate must have read, parsed and judged
##                the pushed object to say it.
##   - advisory : ACCEPTED + FORWARDED, and the advisory diagnostic names the
##                same id — proving advisory READS and merely declines to
##                block, rather than not looking.
##   - off      : ACCEPTED + FORWARDED with NO gateway diagnostic at all. Here
##                the absence IS the specification (``off`` is a documented
##                strict no-op), and the arm says so instead of pretending to
##                observe a check.
##
## Falsifiability:
##   - make ``required`` behave like ``off`` → the required case wrongly
##     forwards → its "upstream does NOT have the commit" assertion fails.
##   - make ``advisory`` block → its accept/forward assertion fails.
##   - restore the quarantine scrub (revert W9 part 1) → the notes object
##     becomes unreadable and the key-id assertions in the required +
##     advisory arms trip. Measured: with part 1 reverted the ``required``
##     arm's OWN verdict assertions still all pass — it rejects, it does not
##     forward — and only the two key-id/untrusted-cert lines catch it. That
##     arm is the clean demonstration that the verdict is not the evidence;
##     the ``off`` and ``advisory`` arms additionally go red on their push
##     verdicts, because the co-resident public-tier lock gate refuses an
##     unreadable commit whether or not a lock is committed in it.
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos + the REAL
## installed hooks; no network. Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## ``doAssert``, not ``quit``: this runs OUTSIDE a ``test`` body, where
  ## ``quit`` would take the binary down without ever printing a ``[FAILED]``
  ## marker for the case that tripped it.
  let res = runCmd(command, cwd)
  doAssert res.code == 0, "command failed: " & command & "\nexit=" &
    $res.code & "\n" & res.output
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type
  ModeFixture = object
    scratch: string
    reproBin: string
    upstreamBare: string
    gatewayBare: string
    clone: string

proc setupModeFixture(gitBin, slug: string): ModeFixture =
  ## A fresh upstream bare + gateway bare + a developer clone wired so the
  ## clone PUSHES through the gateway and FETCHES from the upstream.
  result.scratch = createTempDir("repro-tc6-modes-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.upstreamBare = result.scratch / "upstream.git"
  result.gatewayBare = result.scratch / "gateway.git"
  result.clone = result.scratch / "clone"

  discard requireGit(q(gitBin) & " init --bare -b main " &
    q(result.upstreamBare))
  let seed = result.scratch / "seed"
  discard requireGit(q(gitBin) & " init -b main " & q(seed))
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " config user.name \"TC6 Seeder\"")
  writeFile(seed / "README.md", "seed\n")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " remote add origin " & q(result.upstreamBare))
  discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")

  discard requireGit(q(gitBin) & " clone " & q(fileUrl(result.upstreamBare)) &
    " " & q(result.clone))
  discard requireGit(q(gitBin) & " -C " & q(result.clone) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(result.clone) &
    " config user.name \"TC6 Tester\"")

proc wire(gitBin: string; fx: ModeFixture; mode: CertificateGateMode) =
  let cfg = GatewayConfig(
    gateMode: mode,
    requiredTargets: @["t-unit"],
    requiredPlatforms: @[currentPlatformTag()],
    lockDigest: "blake3:irrelevant-no-cert-attached",
    registeredKeysPath: "")  # empty registry: every cert would be untrusted
  let wired = wirePushGateway(gitBin, fx.clone, fx.gatewayBare,
    fileUrl(fx.upstreamBare), cfg)
  check wired.ok

proc makeNewCommit(gitBin: string; fx: ModeFixture; content: string): string =
  writeFile(fx.clone / "change.txt", content)
  discard requireGit(q(gitBin) & " -C " & q(fx.clone) & " add change.txt")
  discard requireGit(q(gitBin) & " -C " & q(fx.clone) & " commit -m change")
  result = requireGit(q(gitBin) & " -C " & q(fx.clone) &
    " rev-parse HEAD").strip()

proc upstreamTip(gitBin, upstreamBare: string): string =
  let tip = runCmd(q(gitBin) & " -C " & q(upstreamBare) &
    " rev-parse refs/heads/main")
  if tip.code != 0: "" else: tip.output.strip()

const modesUnregisteredKeyId = "w9-modes-unregistered-key"
  ## A key id that appears in exactly ONE place in this fixture: inside the
  ## certificate note blob the push delivers. The gateway can only name it back
  ## by reading that blob out of the received objects — which is the property
  ## these arms exist to assert.

proc attachUntrustedCert(gitBin: string; fx: ModeFixture; commit: string):
    TestCertificate =
  ## Mint a syntactically complete, SIGNED-LOOKING certificate for ``commit``
  ## and attach it (TC-2 carrier) to the pushed commit. It is deliberately
  ## untrustworthy — ``wire`` gives the gateway an EMPTY registry, so the
  ## ``key_id`` resolves to nothing and TC-5 verdicts it ``svUnregisteredKey``.
  ##
  ## Untrusted rather than valid on purpose: a valid certificate would need the
  ## whole TC-1 issuance machinery (that is the key test's job, and it needs
  ## ``ssh-keygen``), whereas an untrusted one exercises exactly the same
  ## receiving-side READ and PARSE and leaves a diagnostic naming the cert's
  ## own bytes. This test is about whether the gate looked, not about coverage.
  var cert = TestCertificate(
    schema: testCertificateSchemaV1,
    project: "modes",
    repo: "clone",
    commit: commit,
    lock: "blake3:irrelevant-no-cert-attached",
    platform: currentPlatformTag(),
    targets: @["t-unit"],
    issuedAt: "2026-08-27T00:00:00Z",
    issuer: "w9-modes-fixture",
    keyId: modesUnregisteredKeyId,
    signature: TestCertificateSignature(
      algorithm: "ed25519",
      # Not a real signature. It never gets that far: the key id is not in the
      # registry, so TC-5 stops at ``svUnregisteredKey`` before any crypto.
      value: "dzktbW9kZXMtbm90LWEtcmVhbC1zaWduYXR1cmU="))
  cert.result = tcrPassed
  let att = attachCertificate(gitBin, fx.clone, commit, cert)
  doAssert att.ok, att.diagnostic
  cert

proc pushThroughGateway(gitBin: string; fx: ModeFixture):
    tuple[code: int; output: string] =
  ## Push the branch AND the certificate notes ref, which is how a real push
  ## carries an attestation to the receiving side.
  runShell(shellCommand(@[
    gitBin, "-C", fx.clone, "push", "origin", "main",
    certificateNotesRef & ":" & certificateNotesRef],
    @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))

suite "TC-6 — certificate policy required/advisory/off modes (receiving side)":

  test "t_certificate_policy_required_advisory_off_modes":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # ---- off: uncovered push ACCEPTED + FORWARDED unconditionally -------
      block:
        let fx = setupModeFixture(gitBin, "off")
        defer: removeDir(fx.scratch)
        wire(gitBin, fx, cgmOff)
        let newSha = makeNewCommit(gitBin, fx, "off-mode change\n")
        discard attachUntrustedCert(gitBin, fx, newSha)
        let pushed = pushThroughGateway(gitBin, fx)
        checkpoint("off push output: " & pushed.output)
        check pushed.code == 0
        # An UNTRUSTED cert is right there in the push, yet ``off`` forwards:
        # the upstream tip advances.
        check upstreamTip(gitBin, fx.upstreamBare) == newSha
        # ``off`` is a documented STRICT no-op, so here the absence of any
        # gateway verdict IS the specification rather than a missing check.
        # Stated as the mode's contract, not as evidence that a gate ran.
        check "reprobuild gateway" notin pushed.output
        check modesUnregisteredKeyId notin pushed.output

      # ---- advisory: uncovered push ACCEPTED + FORWARDED, never blocks -----
      block:
        let fx = setupModeFixture(gitBin, "advisory")
        defer: removeDir(fx.scratch)
        wire(gitBin, fx, cgmAdvisory)
        let newSha = makeNewCommit(gitBin, fx, "advisory-mode change\n")
        discard attachUntrustedCert(gitBin, fx, newSha)
        let pushed = pushThroughGateway(gitBin, fx)
        checkpoint("advisory push output: " & pushed.output)
        # Falsifiable: if advisory blocked, this would be a non-zero push.
        check pushed.code == 0
        check upstreamTip(gitBin, fx.upstreamBare) == newSha
        # The gateway records an advisory diagnostic (recorded, not blocking).
        check "advisory" in pushed.output
        # ...and it is a diagnostic about the CERTIFICATE THAT ARRIVED. The key
        # id lives only inside the pushed note blob, so advisory cannot name it
        # without having read and parsed that object. Without this line the arm
        # is satisfied by a gate that looked at nothing.
        check ("key_id '" & modesUnregisteredKeyId & "' not registered") in
          pushed.output
        check "untrusted certs ignored" in pushed.output

      # ---- required: uncovered push REJECTED at pre-receive ---------------
      block:
        let fx = setupModeFixture(gitBin, "required")
        defer: removeDir(fx.scratch)
        let seedTip = upstreamTip(gitBin, fx.upstreamBare)
        wire(gitBin, fx, cgmRequired)
        let newSha = makeNewCommit(gitBin, fx, "required-mode change\n")
        discard attachUntrustedCert(gitBin, fx, newSha)
        let pushed = pushThroughGateway(gitBin, fx)
        checkpoint("required push output: " & pushed.output)
        # Falsifiable: if required behaved like off, this would succeed and the
        # upstream tip would advance to ``newSha``.
        check pushed.code != 0
        check ("REJECTED" in pushed.output or "rejected" in pushed.output)
        # The upstream tip must NOT have advanced — the push never reached it.
        check upstreamTip(gitBin, fx.upstreamBare) == seedTip
        check upstreamTip(gitBin, fx.upstreamBare) != newSha
        # And the refusal was REASONED FROM THE PUSHED OBJECT: the gate read
        # the certificate note, parsed the record, and rejected it by key id.
        # A gate that reads nothing also rejects here — for the entirely
        # different reason that it found no certificate — so this is the
        # assertion that tells the two apart.
        check ("key_id '" & modesUnregisteredKeyId & "' not registered") in
          pushed.output
        check "untrusted certs ignored" in pushed.output
