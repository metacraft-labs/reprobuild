## Issuance writes the local certificate store and nothing else, and what carries
## the certificate to a gateway is the managed ``pre-push`` hook's call into the
## linked reference library.
##
## Two issuing paths, ``repro test --certify`` and ``repro certify --check-set``,
## each followed by a plain one-ref ``git push`` to a real ``required`` gateway
## forwarding to a real upstream bare, with the real managed hooks. After
## issuance the clone has no certificate notes ref, and the certificate is in the
## store. After the push the note is on the upstream's
## ``refs/notes/test-certificates/certificates``, under the pushed TREE and not
## the commit, and the gateway accepted the branch.
##
## There is no stub for the tool: it is a linked library, not a process. What
## proves the hook carried the note is that nothing else can: removing the hook
## call reddens this test.
## No ``test-certificates`` executable is on ``PATH`` for the push. No mocks.

import std/unittest

include certificate_push_fixture

proc localNotesRefAbsent(fx: StoreFixture): bool =
  execCmdEx(quoteShellCommand(@["git", "-C", fx.libAPath, "rev-parse",
    "--verify", "--quiet", certificateNotesRef])).exitCode != 0

proc checkCarried(fx: StoreFixture; commit: string) =
  ## The upstream holds the branch and, on its tree alone, one record.
  check upstreamTip(fx) == commit
  let tree = gitOut(fx.libAPath, "rev-parse", commit & "^{tree}")
  check noteOnRemote(fx.upstreamBare, tree).count("# --- test-certificate ---") == 1
  check noteOnRemote(fx.upstreamBare, commit) == ""

suite "issuance writes the store only and the hook carries the notes":

  test "repro test --certify, then a plain git push":
    let fx = setupStoreFixture(
      requiredPolicy(@["t-unit"], @[currentPlatformTag()]), "issue-test")
    defer: removeDir(fx.scratch)
    wireStoreGateway(fx)
    installHooks(fx)
    # Certified before the commit, the order a project at ``required`` needs:
    # its ``pre-commit`` gate looks for the certificate too.
    writeFile(fx.libAPath / "change.txt", "change\n")
    discard gitOut(fx.libAPath, "add", "change.txt")
    let issued = issueViaReproTest(fx)
    checkpoint("issue: " & issued.output)
    check issued.code == 0
    let tree = gitOut(fx.libAPath, "write-tree")
    check storedCertificateFiles(fx.userRoot, "git-tree-sha1:" & tree).len == 1
    check localNotesRefAbsent(fx)
    discard gitOut(fx.libAPath, "commit", "-m", "certified change")
    let commit = gitOut(fx.libAPath, "rev-parse", "HEAD")
    check localNotesRefAbsent(fx)
    seedLock(fx)
    let pushed = plainPush(fx)
    checkpoint("push: " & pushed.output)
    check pushed.code == 0
    check "COVERED by 1 trusted certificate" in pushed.output
    checkCarried(fx, commit)

  test "repro certify --check-set, then a plain git push":
    let fx = setupStoreFixture(
      requiredPolicy(@["pre-commit"], @[currentPlatformTag()]), "issue-certify")
    defer: removeDir(fx.scratch)
    wireStoreGateway(fx)
    installHooks(fx)
    writeFile(fx.libAPath / "change.txt", "change\n")
    discard gitOut(fx.libAPath, "add", "change.txt")
    let certified = runArgv(@[fx.reproBin, "certify", "--check-set",
      "--check-set-command=true", "--workspace-root=" & fx.workspaceRoot,
      "--current-repo=" & fx.libAPath], fx.libAPath,
      daemonKeyEnv(fx.daemonKey, storeKeyId))
    checkpoint("certify: " & certified.output)
    check certified.code == 0
    let tree = gitOut(fx.libAPath, "write-tree")
    check storedCertificateFiles(fx.userRoot, "git-tree-sha1:" & tree).len == 1
    check localNotesRefAbsent(fx)
    discard gitOut(fx.libAPath, "commit", "-m", "certified change")
    let commit = gitOut(fx.libAPath, "rev-parse", "HEAD")
    seedLock(fx)
    let pushed = plainPush(fx)
    checkpoint("push: " & pushed.output)
    check pushed.code == 0
    check "COVERED by 1 trusted certificate" in pushed.output
    checkCarried(fx, commit)
