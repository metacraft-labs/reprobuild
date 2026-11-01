## ``repro push`` leaves carrying certificates to its ``git push``'s managed
## ``pre-push`` hook, and carries them itself only where that hook has nothing to
## do: a push that introduces no commit (Tooling §4.2).
##
## A certified commit, its certificate in the store and already noted in the
## clone's local notes ref. Against a real ``required`` gateway:
##
##   * WITH THE HOOK'S PROPAGATION OFF (``TEST_CERTIFICATES_HOOK=off``: the tool is
##     a linked library, so there is no process to replace with a stub), no notes
##     ref reaches the gateway, it refuses the branch, and ``repro push`` passes on
##     the gateway's own words, which name the missing note and the remedy. So
##     for a commit the push introduces, ``repro push`` itself sends nothing.
##   * THE SAME ``repro push`` with propagation on is accepted, and the note is on
##     the upstream under the pushed tree. Removing the hook call reddens this.
##   * AN ALREADY-PUBLISHED COMMIT pushes nothing, so no hook runs, and a
##     certificate issued after it was published is carried by ``repro push``.
##   * A PLAIN ``git push`` of A NEW BRANCH at a commit a remote-tracking ref
##     already reaches introduces nothing either, and stays as Tooling §4.2 has
##     it: a ``required`` gateway refuses it, naming the remedy, and the retry
##     after that remedy is accepted.
##
## Real gateway, real hooks, the built ``repro``. No mocks.

import std/unittest

include certificate_push_fixture
import ./certificate_note_seed
from test_certificates/notes as tcnotes import nil
from test_certificates/roots as tcroots import nil

proc reproPush(fx: StoreFixture; env: seq[tuple[name, value: string]] = @[]):
    tuple[code: int; output: string] =
  runArgv(@[fx.reproBin, "push", "--no-certify",
    "--workspace-root=" & fx.workspaceRoot, "--current-repo=" & fx.libAPath],
    fx.libAPath,
    @[(name: "PATH", value: pathWithoutTool()),
      (name: "REPROBUILD_REPRO", value: fx.reproBin)] & env)

proc carryByHand(fx: StoreFixture; commit: string) =
  ## The remedy: what ``test-certificates notes publish <commit>`` and ``notes
  ## push origin`` call, in this process, whose environment names the store.
  let published = tcnotes.publishNotes(fx.libAPath, tcroots.nativeRoots(),
    [commit])
  checkpoint(published.problems.join("; "))
  check published.ok
  let pushed = tcnotes.pushNotes(fx.libAPath, "origin")
  checkpoint(pushed.problems.join("; "))
  check pushed.ok

suite "repro push carries what no hook would":
  test "the hook carries a pushed commit, repro push an already-published one":
    let fx = setupStoreFixture(
      requiredPolicy(@["t-unit"], @[currentPlatformTag()]), "push-no-notes")
    defer: removeDir(fx.scratch)
    wireStoreGateway(fx)
    installHooks(fx)
    # ``repro push`` publishes lock records to the backend's upstream, through
    # the backend's own hook.
    let manifests = fx.workspaceRoot / ".repro" / "manifests"
    let manifestBare = fx.scratch / "manifests.git"
    discard gitOut(fx.scratch, "init", "--bare", manifestBare)
    discard gitOut(manifests, "remote", "add", "origin", manifestBare)
    discard gitOut(manifests, "push", "-u", "origin", "HEAD")
    let backend = runArgv(@[fx.reproBin, "hooks", "ensure", "--vcs", manifests],
      env = @[(name: "REPROBUILD_REPRO", value: fx.reproBin)])
    doAssert backend.code == 0, backend.output
    writeFile(fx.libAPath / "certified.txt", "certified\n")
    discard gitOut(fx.libAPath, "add", "certified.txt")
    let tree = gitOut(fx.libAPath, "write-tree")
    let cert = signedCertFor(fx, "git-tree-sha1:" & tree,
      gitOut(fx.libAPath, "rev-parse", "HEAD"))
    check publishCertificateToLocalStore(cert, fx.libAPath).written
    discard gitOut(fx.libAPath, "commit", "-m", "certified change")
    let commit = gitOut(fx.libAPath, "rev-parse", "HEAD")
    check seedCertificateNote("git", fx.libAPath, cert).ok
    seedLock(fx)
    let before = upstreamTip(fx)

    # ---- propagation off: the branch alone travels, and is refused ----------
    let refused = reproPush(fx,
      @[(name: "TEST_CERTIFICATES_HOOK", value: "off")])
    checkpoint("off: " & refused.output)
    check refused.code != 0
    check "stage=source-push" in refused.output
    # The gateway's refusal reaches the developer, with its remedy, and the
    # retry advice is not the one for a lost race.
    check "no certificate note on the pushed tree" in refused.output
    check "test-certificates notes publish" in refused.output
    check "retry: repro push\n" in refused.output & "\n"
    check "--sync" notin refused.output
    check upstreamTip(fx) == before
    check not remoteHasNotes(fx.upstreamBare)
    check not remoteHasNotes(fx.gatewayBare)

    # ---- propagation on: the same push goes through ------------------------
    let accepted = reproPush(fx)
    checkpoint("on: " & accepted.output)
    check accepted.code == 0
    check "repro hooks: certificates: " in accepted.output # What the hook did.
    check upstreamTip(fx) == commit
    check noteOnRemote(fx.upstreamBare, tree).count("# --- test-certificate ---") == 1
    check noteOnRemote(fx.upstreamBare, commit) == ""

    # ---- already published: nothing is pushed, so no hook runs ---------------
    # A second platform's certificate for content the remote already has.
    let later = signedCertFor(fx, "git-tree-sha1:" & tree, commit,
      platform = "linux/second")
    check publishCertificateToLocalStore(later, fx.libAPath).written
    let again = reproPush(fx)
    checkpoint("already published: " & again.output)
    check again.code == 0
    check "already-published" in again.output
    check noteOnRemote(fx.upstreamBare, tree).count("# --- test-certificate ---") == 2
    check "test-certificates notes publish" notin again.output
    let settled = reproPush(fx)
    check settled.code == 0
    check "certificate(s) for " notin settled.output

  test "a plain git push of a new branch at a commit a remote-tracking ref reaches":
    let fx = setupStoreFixture(
      requiredPolicy(@["t-unit"], @[currentPlatformTag()]), "push-new-branch")
    defer: removeDir(fx.scratch)
    wireStoreGateway(fx)
    installHooks(fx)
    writeFile(fx.libAPath / "certified.txt", "certified\n")
    discard gitOut(fx.libAPath, "add", "certified.txt")
    let tree = gitOut(fx.libAPath, "write-tree")
    check publishCertificateToLocalStore(signedCertFor(fx,
      "git-tree-sha1:" & tree, gitOut(fx.libAPath, "rev-parse", "HEAD")),
      fx.libAPath).written
    discard gitOut(fx.libAPath, "commit", "-m", "certified change")
    let commit = gitOut(fx.libAPath, "rev-parse", "HEAD")
    seedLock(fx)
    # The §4.2 exclusion for a new branch: what a remote-tracking ref reaches.
    # A branch fetched from another clone, or pushed earlier, leaves this state.
    discard gitOut(fx.libAPath, "update-ref", "refs/remotes/origin/elsewhere",
      commit)

    let refused = plainPush(fx, @["HEAD:refs/heads/topic"])
    checkpoint("new branch: " & refused.output)
    check refused.code != 0
    check not remoteHasNotes(fx.upstreamBare)
    check "no certificate note on the pushed tree" in refused.output
    check "test-certificates notes publish" in refused.output

    carryByHand(fx, commit)
    let retried = plainPush(fx, @["HEAD:refs/heads/topic"])
    checkpoint("retried: " & retried.output)
    check retried.code == 0
    check noteOnRemote(fx.upstreamBare, tree).count("# --- test-certificate ---") == 1
