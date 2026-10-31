## ``repro push`` has no notes step of its own: its ``git push`` runs the managed
## ``pre-push`` hook, and that hook is what carries certificates to the remote.
##
## A certified commit, its certificate in the store and already noted in the
## clone's local notes ref, so a notes step in ``repro push`` would have something
## to send. Against a real ``required`` gateway:
##
##   * WITH THE HOOK'S PROPAGATION OFF (``TEST_CERTIFICATES_HOOK=off``: the tool is
##     a linked library, so there is no process to replace with a stub), no notes
##     ref reaches the gateway, it refuses the branch, and ``repro push`` passes on
##     the gateway's own words, which name the missing note. A
##     notes step in ``repro push`` runs regardless of that variable.
##   * THE SAME ``repro push`` with propagation on is accepted, and the note is on
##     the upstream under the pushed tree. Removing the hook call reddens this.
##   * AN ALREADY-PUBLISHED COMMIT pushes nothing (Tooling §4.2: a push that
##     introduces no commit publishes no note), so a certificate issued after it
##     was published stays local. A notes step in ``repro push``, which used to
##     run for exactly this case, reddens this.
##
## Real gateway, real hooks, the built ``repro``. No mocks.

import std/unittest

include certificate_push_fixture
import ./certificate_note_seed

proc reproPush(fx: StoreFixture; env: seq[tuple[name, value: string]] = @[]):
    tuple[code: int; output: string] =
  runArgv(@[fx.reproBin, "push", "--no-certify",
    "--workspace-root=" & fx.workspaceRoot, "--current-repo=" & fx.libAPath],
    fx.libAPath,
    @[(name: "PATH", value: pathWithoutTool()),
      (name: "REPROBUILD_REPRO", value: fx.reproBin)] & env)

suite "repro push carries no notes of its own":
  test "only the hook carries the note":
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

    # ---- already published: nothing is pushed, so no hook and no note --------
    # A second platform's certificate for content the remote already has waits
    # for a push that introduces that content. It is not this command's to send.
    let later = signedCertFor(fx, "git-tree-sha1:" & tree, commit,
      platform = "linux/second")
    check publishCertificateToLocalStore(later, fx.libAPath).written
    # Noted locally too: a notes step in ``repro push`` would send this one.
    check seedCertificateNote("git", fx.libAPath, later).ok
    let again = reproPush(fx)
    checkpoint("already published: " & again.output)
    check again.code == 0
    check "already-published" in again.output
    check noteOnRemote(fx.upstreamBare, tree).count("# --- test-certificate ---") == 1
