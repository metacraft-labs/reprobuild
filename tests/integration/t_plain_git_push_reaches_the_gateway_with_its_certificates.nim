## A plain one-ref ``git push`` reaches a ``required`` gateway with its
## certificates, because the managed ``pre-push`` hook propagated them first,
## and the gateway reads notes only: it has no store to read.
##
## Setup: the real gateway bare with its real hooks, forwarding to a real
## upstream bare; the real managed hooks on the developer's clone; no
## ``test-certificates`` executable on ``PATH``, so a host where nothing
## provisioned the tool still gets through. No mocks.
##
## Scenarios:
##
##   * ACCEPTED. Certify, commit, ``git push origin main``, naming one ref. The
##     gateway reports the push covered and forwards it. Only the hook could
##     have delivered the note, so this fails if the hook call is removed.
##   * ``--no-verify`` skips the hook, and propagation with it. The certificate
##     is in the store, but no note arrives, so the gateway refuses. Its
##     diagnostic names the missing note and the hook, and does not send the
##     developer to certify again. Skipping client hooks therefore never lets an
##     uncovered push through.
##   * THE OPT-OUT is refused the same way: the push leaves the note behind.
##   * A COVERED PUSH AFTERWARDS. The commit those refusals left behind goes
##     through, which shows they were about the missing note, not the commit.

import std/unittest

include certificate_push_fixture

proc certifyThenCommit(fx: StoreFixture; file: string): string =
  ## Certify the staged state, then commit it, the order a project at
  ## ``required`` needs: its ``pre-commit`` gate looks for the certificate too.
  writeFile(fx.libAPath / file, file & "\n")
  discard gitOut(fx.libAPath, "add", file)
  let tree = gitOut(fx.libAPath, "write-tree")
  let cert = signedCertFor(fx, "git-tree-sha1:" & tree,
    gitOut(fx.libAPath, "rev-parse", "HEAD"))
  doAssert publishCertificateToLocalStore(cert, fx.libAPath).written
  discard gitOut(fx.libAPath, "commit", "-m", "change " & file)
  result = gitOut(fx.libAPath, "rev-parse", "HEAD")
  doAssert gitOut(fx.libAPath, "rev-parse", result & "^{tree}") == tree

suite "a plain git push reaches the gateway with its certificates":
  test "the hook carries them, and without it the gateway refuses by name":
    let fx = setupStoreFixture(
      requiredPolicy(@["t-unit"], @[currentPlatformTag()]), "prop-gateway")
    defer: removeDir(fx.scratch)
    wireStoreGateway(fx)
    installHooks(fx)

    # ---- accepted: one ref named, the note travels through the hook --------
    let covered = certifyThenCommit(fx, "covered.txt")
    seedLock(fx)
    let accepted = plainPush(fx)
    checkpoint("accepted: " & accepted.output)
    check accepted.code == 0
    check "COVERED by 1 trusted certificate" in accepted.output
    check upstreamTip(fx) == covered

    # ---- --no-verify: certified, in the store, and no note arrives --------
    let refused = certifyThenCommit(fx, "refused.txt")
    seedLock(fx)
    let skipped = plainPush(fx, @["--no-verify", "main"])
    checkpoint("no-verify: " & skipped.output)
    check skipped.code != 0
    check "no certificate note on the pushed tree" in skipped.output
    check "managed pre-push hook" in skipped.output
    check "--no-verify" in skipped.output
    check "repro certify" notin skipped.output
    # What is unmet is still named, or the operator cannot tell what was asked.
    check "'t-unit'" in skipped.output
    check upstreamTip(fx) == covered

    # ---- the opt-out: refused the same way ---------------------------------
    let optedOut = plainPush(fx,
      env = @[(name: "TEST_CERTIFICATES_HOOK", value: "off")])
    checkpoint("opt-out: " & optedOut.output)
    check optedOut.code != 0
    check "no certificate note on the pushed tree" in optedOut.output
    check "repro certify" notin optedOut.output
    check upstreamTip(fx) == covered

    # ---- a plain push again: the same commit goes through -----------------
    let retried = plainPush(fx)
    checkpoint("retried: " & retried.output)
    check retried.code == 0
    check upstreamTip(fx) == refused
