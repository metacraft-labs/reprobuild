## TC-8c — the receiving-side gateway finds certificates in the NOTES on the
## pushed commit's TREE (test-certificates Transport §3), on the shared
## ``refs/notes/test-certificates/certificates`` (operator decision D10), and
## reads no certificate store (D12).
##
## A real gateway bare (its installed ``pre-receive`` / ``post-receive``
## hooks driving the built ``repro``) in front of a real upstream bare, under
## ``required`` (the policy the pushed tree records), every push made with ``--no-verify`` so only the receiving
## side decides:
##
##   1. a push whose note sits on ``<new>^{tree}`` is ACCEPTED and FORWARDED;
##   2. a reworded commit with the SAME tree is accepted on the same note;
##   3. a commit with different content is REJECTED with the content-specific
##      remedy;
##   4. a note on the tree carrying a record for other content is REPORTED as
##      a misattached carrier fault (and the push, uncovered, is rejected);
##   5. a certificate noted on ``refs/notes/reprobuild/certificates`` is NOT
##      read — the same certificate on the shared ref is accepted;
##   6. a certificate present in the local store but carried by no note is
##      REFUSED: there is no store read to fall back on.
##
## Falsifiability: look notes up on the commit instead of its tree → 1 and 2
## fail; drop the misattachment report → 4 fails; read the legacy ref → 5's
## rejection fails; reintroduce a gateway store read → 6 fails.
##
## Hermetic: local bare repos, the built ``repro``; no network. Requires git
## and ssh-keygen.

import std/[os, osproc, strutils, unittest]

include tc8c_store_fixture
import ./certificate_note_seed

const legacyNotesRef = "refs/notes/reprobuild/certificates"

suite "TC-8c — the gateway finds certificates by the pushed tree":

  test "t_gateway_finds_certificates_by_the_pushed_tree":
    # The policy is the pushed tree's own (TC-9d): the seed commit records
    # t-unit required on this platform in lib-a's repro.lock.
    let fx = setupStoreFixture(
      requiredPolicy(@["t-unit"], @[currentPlatformTag()]), "gateway")
    defer: removeDir(fx.scratch)
    wireStoreGateway(fx)
    let notes = certificateNotesRef & ":" & certificateNotesRef

    # ---- 1. noted on the tree: accepted and forwarded ---------------------
    let b = newCommit(fx, "b.txt", "b\n")
    seedLock(fx)
    let issued = issueViaReproTest(fx)
    checkpoint("issue B: " & issued.output)
    check issued.code == 0
    let bContent = "git-tree-sha1:" & gitOut(fx.libAPath, "rev-parse",
      b & "^{tree}")
    let certB = issuedCertificate(fx.userRoot, bContent,
      currentPlatformTag()).cert
    check seedCertificateNote("git", fx.libAPath, certB).ok
    # Keyed by the tree: there is no note on the commit itself.
    check execCmdEx(quoteShellCommand(@["git", "-C", fx.libAPath, "notes",
      "--ref", certificateNotesRef, "show", b])).exitCode != 0
    let pushB = pushToGateway(fx, @["main", notes])
    checkpoint("push B: " & pushB.output)
    check pushB.code == 0
    check "COVERED by 1 trusted certificate" in pushB.output
    check upstreamTip(fx) == b

    # ---- 2. a reworded commit, same tree: accepted on the same note -------
    let reworded = gitOut(fx.libAPath, "commit-tree", b & "^{tree}", "-p", b,
      "-m", "reworded: same content, another commit")
    discard gitOut(fx.libAPath, "update-ref", "refs/heads/main", reworded)
    discard gitOut(fx.libAPath, "reset", "--hard", "-q", reworded)
    seedLock(fx)
    let pushReworded = pushToGateway(fx, @["main", notes])
    checkpoint("push reworded: " & pushReworded.output)
    check pushReworded.code == 0
    check upstreamTip(fx) == reworded

    # ---- 3. different content: rejected, content-specific remedy ----------
    let c = newCommit(fx, "c.txt", "c\n")
    seedLock(fx)
    let pushC = pushToGateway(fx, @["main", notes])
    checkpoint("push C: " & pushC.output)
    check pushC.code != 0
    check "no covering test certificate for the pushed content" in pushC.output
    check "no certificate note on the pushed tree" in pushC.output
    check upstreamTip(fx) == reworded

    # ---- 4. a misattached note is reported as a carrier fault -------------
    let cTree = gitOut(fx.libAPath, "rev-parse", c & "^{tree}")
    check seedCertificateRecord("git", fx.libAPath, cTree, certB).ok
    let pushMis = pushToGateway(fx, @["main", notes])
    checkpoint("push misattached: " & pushMis.output)
    check pushMis.code != 0
    check "carrier fault" in pushMis.output
    check "misattached" in pushMis.output
    check bContent in pushMis.output
    check upstreamTip(fx) == reworded

    # ---- 5. the legacy notes ref is not read ------------------------------
    let cContent = "git-tree-sha1:" & cTree
    let certC = signedCertFor(fx, cContent, c)
    writeFile(fx.scratch / "legacy-note.txt",
      "# --- test-certificate ---\n" & serializeCertificateToToml(certC))
    discard gitOut(fx.libAPath, "notes", "--ref", legacyNotesRef, "add", "-f",
      "-F", fx.scratch / "legacy-note.txt", cTree)
    let pushLegacy = pushToGateway(fx,
      @["main", legacyNotesRef & ":" & legacyNotesRef])
    checkpoint("push legacy ref: " & pushLegacy.output)
    check pushLegacy.code != 0
    check upstreamTip(fx) == reworded
    # The very same certificate on the shared ref is accepted. (The
    # misattached record from 4 is still on that note, reported and ignored.)
    check seedCertificateNote("git", fx.libAPath, certC).ok
    let pushShared = pushToGateway(fx, @["main", notes])
    checkpoint("push shared ref: " & pushShared.output)
    check pushShared.code == 0
    check "carrier fault" in pushShared.output
    check upstreamTip(fx) == c

    # ---- 6. in the local store, on no note: refused (no store read) -------
    let d = newCommit(fx, "d.txt", "d\n")
    seedLock(fx)
    let dContent = "git-tree-sha1:" & gitOut(fx.libAPath, "rev-parse",
      d & "^{tree}")
    let certD = signedCertFor(fx, dContent, d)
    check publishCertificateToLocalStore(certD, fx.libAPath).written
    check storedCertificateFiles(fx.userRoot, dContent).len == 1
    # The push runs with TEST_CERTIFICATES_DIR pointing at that store.
    check getEnv("TEST_CERTIFICATES_DIR") == fx.userRoot
    let pushD = pushToGateway(fx, @["main", notes])
    checkpoint("push D: " & pushD.output)
    check pushD.code != 0
    check "no certificate note on the pushed tree" in pushD.output
    check upstreamTip(fx) == c
