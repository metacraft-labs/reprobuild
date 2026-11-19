## Certification does not verify the revision of the lock's root entry, and a
## revision a shallow checkout cannot see is reported as unverifiable, not as
## gone (Unified-Locking-And-Hooks.md §13.7.5 "The root entry";
## Test-Certificates.md §"Issuance preconditions").
##
## A repository that commits its own ``repro.lock`` can never pin the commit
## that carries it: ``repro lock refresh`` runs on a commit, and committing its
## output makes the next one. So the root (``self``) entry names the PARENT of
## the commit the lock lives in. A depth-1 CI checkout, or a pull request's
## merge checkout, does not have that parent. Issuance reuses the pre-push
## gate, whose committed-lock branch verified every entry's revision, the root
## included, so every such checkout was refused with "the revision is GONE …
## force-push", labelled "repo not at the locked revision". Under content
## binding the root revision is informational, like a certificate's ``base``:
## issuance names the tested content by its content id instead.
##
## Cases:
##
##   1. A repository that commits its own lock (root entry = HEAD's parent),
##      cloned with ``--depth 1``: ``repro test --certify`` issues a
##      certificate for the clone's content. The real pre-push gate on the same
##      clone still checks the root pin and refuses, now with the
##      ``shallow-checkout`` cause and a remedy naming ``fetch-depth: 0`` /
##      ``git fetch --unshallow`` instead of "GONE".
##   2. A FULL clone whose lock names a root revision that origin never had (a
##      lock refreshed on an unpublished commit, then committed on top of the
##      published one): the pre-push gate keeps the existing
##      ``locked-revision-unreachable`` cause and its "GONE" remedy, and
##      certification still issues, because it does not verify the root pin.
##   3. ``verifyLockedIntegrityAtCoordinates`` on a SIBLING entry whose
##      revision is absent: in a shallow clone the cause is
##      ``licShallowCheckout``; in a full clone it stays
##      ``licRevisionUnreachable``.
##
## Falsifiability, measured: with the issuance filter disabled
## (``withoutRootEntryAtIssuance`` keeping the root entry), case 1's
## ``repro test --certify`` prints "no certificate — a locked dependency
## cannot be verified in this checkout (.)" and issues nothing, and so does
## case 2's; case 3 still passes. With the shallow probe removed, case 1's
## pre-push and case 3's shallow half report ``locked-revision-unreachable``.
##
## NO MOCKS: real bare origins and clones (``git clone --depth 1`` over
## ``file://`` is a real shallow clone), the built ``repro``, the real provider
## compile for ``repro lock refresh``, a real ssh-keygen daemon key. The test
## command run under ``repro test`` is a one-edge ``--fixture-from`` file whose
## command is ``sh -c 'exit 0'``: what is under test is whether a certificate
## is issued, not what the test does, and the fixture path is the same issuance
## path the TC-8d tests drive. Case 3 calls the library procedure directly,
## because a sibling entry's verification is the same code on every gate path
## and needs no workspace around it. Skip rule: ``git`` or ``ssh-keygen``
## missing.

import std/[json, os, strutils, tempfiles, unittest]
import repro_test_support
import repro_test_support/reasoned_skip
import repro_test_support/scoped_env
import repro_test_support/recipe_dependencies
import repro_lock
import repro_multihash
import repro_cli_support
import ./certify_working_tree_fixture

const zeroSha = "0000000000000000000000000000000000000000"
const keyId = "root-entry-daemon-key"

type RootFixture = object
  storeEnv: ScopedEnv
  gitBin, repro, scratch, origin, certStore, daemonKey, keyPub: string

proc g(fx: RootFixture; repo, args: string): string =
  requireCmd(q(fx.gitBin) & " -C " & q(repo) & " " & args)

proc configureIdentity(fx: RootFixture; repo: string) =
  discard fx.g(repo, "config user.email tester@example.invalid")
  discard fx.g(repo, "config user.name \"Lock Tester\"")
  discard fx.g(repo, "config commit.gpgsign false")

proc setupRootFixture(label: string): RootFixture =
  ## A bare origin and a seeded working clone of it, published, with a daemon
  ## key and an isolated certificate store.
  result.gitBin = findExe("git")
  result.repro = reproBinary()
  result.scratch = createTempDir("repro-" & label & "-", "")
  result.origin = result.scratch / "origin.git"
  result.certStore = isolateCertificateStore(result.scratch, result.storeEnv)
  let key = genEd25519Key(result.scratch / "daemon-keys", "root-key", keyId)
  result.daemonKey = key.priv
  result.keyPub = key.pub
  discard requireCmd(q(result.gitBin) & " init -q --bare -b main " &
    q(result.origin))

proc seedWork(fx: RootFixture; name: string): string =
  ## A working clone of the origin carrying a recipe and a README, committed
  ## and published. Its lock is written by the case.
  result = fx.scratch / name
  discard requireCmd(q(fx.gitBin) & " clone -q " & q(fileUrl(fx.origin)) &
    " " & q(result))
  fx.configureIdentity(result)
  writeFile(result / "README.md", "root-entry fixture\n")
  writeDependencyRecipe(result, [], library = false)
  discard fx.g(result, "add -A")
  discard fx.g(result, "commit -q -m seed")
  discard fx.g(result, "push -q origin main")

proc refreshLock(fx: RootFixture; repo: string) =
  let r = refreshCommittedLock(fx.repro, repo)
  checkpoint(r.output)
  doAssert r.code == 0, "repro lock refresh failed:\n" & r.output

proc rootRevision(repo: string): string =
  ## The revision the lock's root entry pins, read with the lock parser.
  for d in parseLockedDependencies(readFile(repo / "repro.lock")).deps:
    if isSelfLockedDep(d) and d.coordinates.kind == ckVcs:
      return d.coordinates.revision
  ""

proc prepareCheckout(fx: RootFixture; repo: string) =
  ## Identity, and the registered-key store issuance and the gate read
  ## (under the ignored ``.repro/``).
  fx.configureIdentity(repo)
  writeRegistry(repo, @[RegisteredKey(keyId: keyId, publicKey: fx.keyPub,
    status: rksActive)])

proc certify(fx: RootFixture; repo: string): CmdResult =
  ## ``repro test --certify`` on a one-edge fixture whose command passes, run
  ## from the scratch directory so ``test-logs/`` never lands in ``repo``.
  let fixture = fx.scratch / "fixture.json"
  var edge = newJObject()
  edge["id"] = %1
  edge["selector"] = %"t-unit"
  edge["historyKey"] = %"t-unit"
  edge["buildDeps"] = newJArray()
  edge["runCmd"] = %["sh", "-c", "exit 0"]
  edge["testName"] = %"t-unit"
  var doc = newJObject()
  doc["fallbackBuildCostNs"] = %1
  doc["fallbackTestCostNs"] = %1
  doc["testEdges"] = %[edge]
  doc["buildActions"] = newJArray()
  writeFile(fixture, doc.pretty() & "\n")
  runShell(shellCommand(@[fx.repro, "test", "--fixture-from=" & fixture,
    "--shard=1/1", "--certify", "--workspace-root=" & repo,
    "--current-repo=" & repo], daemonKeyEnv(fx.daemonKey, keyId)),
    fx.scratch)

proc prePush(fx: RootFixture; repo: string): CmdResult =
  ## The real pre-push gate, as the managed hook runs it for a push of HEAD.
  let refs = fx.scratch / "pushed-refs.txt"
  writeFile(refs, "refs/heads/main " & fx.g(repo, "rev-parse HEAD").strip() &
    " refs/heads/main " & zeroSha & "\n")
  runShell(shellCommand(@[fx.repro, "check", "--mode=pre-push",
    "--workspace-root=" & repo, "--current-repo=" & repo,
    "--pushed-refs=" & refs]), repo)

proc contentOf(fx: RootFixture; repo: string): string =
  workingTreeContentIdOf(fx.gitBin, repo, fx.scratch / "expected-index")

proc verifySibling(root, path, revision,
                   integrity: string): seq[LockedIntegrityFailure] =
  ## The gate's verification of one non-root entry checked out at
  ## ``root/path``, pinned at ``revision``.
  verifyLockedIntegrityAtCoordinates(root, LockedDependencies(
    deps: @[LockedDep(name: path, path: path,
      coordinates: Coordinates(kind: ckVcs, revision: revision),
      integrity: integrity)]))

proc toolsMissing(): bool =
  findExe("git").len == 0 or findExe("ssh-keygen").len == 0

suite "certification does not verify the lock's root revision":

  test "a shallow clone of a repository that commits its own lock is certified; pre-push names the shallow checkout":
    if toolsMissing():
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      var fx = setupRootFixture("root-shallow")
      defer: removeDir(fx.scratch)
      let work = fx.seedWork("work")
      fx.refreshLock(work)
      let lockedOn = fx.g(work, "rev-parse HEAD").strip()
      discard fx.g(work, "add repro.lock")
      discard fx.g(work, "commit -q -m lock")
      discard fx.g(work, "push -q origin main")
      # The root entry names the commit before the one carrying the lock.
      check rootRevision(work) == lockedOn
      check fx.g(work, "rev-parse HEAD^").strip() == lockedOn

      let clone = fx.scratch / "ci-checkout"
      discard requireCmd(q(fx.gitBin) & " clone -q --depth 1 " &
        q(fileUrl(fx.origin)) & " " & q(clone))
      fx.prepareCheckout(clone)
      check fx.g(clone, "rev-parse --is-shallow-repository").strip() == "true"
      check runCmd(q(fx.gitBin) & " -C " & q(clone) &
        " rev-parse --verify --quiet " & lockedOn & "^{commit}").code != 0

      let content = fx.contentOf(clone)
      let res = fx.certify(clone)
      checkpoint("certify:\n" & res.output)
      check res.code == 0
      check "no certificate" notin res.output
      check storedCertificateFiles(fx.certStore, content).len == 1

      # The real pre-push gate still verifies the root pin, and says why it
      # cannot here instead of claiming the revision is gone.
      let gate = fx.prePush(clone)
      checkpoint("pre-push:\n" & gate.output)
      check gate.code != 0
      check "locked-integrity-mismatch" in gate.output
      check "cause=shallow-checkout" in gate.output
      check "fetch-depth: 0" in gate.output
      check "git fetch --unshallow" in gate.output
      check "GONE" notin gate.output

  test "in a full clone a missing root revision is still GONE to pre-push, and certification still issues":
    if toolsMissing():
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      var fx = setupRootFixture("root-gone")
      defer: removeDir(fx.scratch)
      let work = fx.seedWork("work")
      let published = fx.g(work, "rev-parse HEAD").strip()
      # Refresh the lock on a commit origin never receives, then commit the
      # lock directly on top of the published one.
      writeFile(work / "unpublished.txt", "never pushed\n")
      discard fx.g(work, "add unpublished.txt")
      discard fx.g(work, "commit -q -m unpublished")
      let unpublished = fx.g(work, "rev-parse HEAD").strip()
      fx.refreshLock(work)
      check rootRevision(work) == unpublished
      discard fx.g(work, "reset -q --mixed " & published)
      discard fx.g(work, "add repro.lock")
      discard fx.g(work, "commit -q -m lock")
      discard fx.g(work, "push -q origin main")

      let clone = fx.scratch / "full-checkout"
      discard requireCmd(q(fx.gitBin) & " clone -q " & q(fileUrl(fx.origin)) &
        " " & q(clone))
      fx.prepareCheckout(clone)
      check fx.g(clone, "rev-parse --is-shallow-repository").strip() == "false"
      check rootRevision(clone) == unpublished
      check runCmd(q(fx.gitBin) & " -C " & q(clone) &
        " rev-parse --verify --quiet " & unpublished & "^{commit}").code != 0

      let gate = fx.prePush(clone)
      checkpoint("pre-push:\n" & gate.output)
      check gate.code != 0
      check "locked-integrity-mismatch" in gate.output
      check "cause=locked-revision-unreachable" in gate.output
      check "GONE" in gate.output
      check "fetch-depth" notin gate.output

      let content = fx.contentOf(clone)
      let res = fx.certify(clone)
      checkpoint("certify:\n" & res.output)
      check res.code == 0
      check storedCertificateFiles(fx.certStore, content).len == 1

  test "a sibling revision missing from a shallow clone is unverifiable, from a full clone unreachable":
    if toolsMissing():
      # The shared fixture generates a daemon key, so ssh-keygen is needed
      # here too even though this case signs nothing.
      skip("git or ssh-keygen not on PATH; this test verifies real " &
        "repositories")
    else:
      var fx = setupRootFixture("sibling-shallow")
      defer: removeDir(fx.scratch)
      let work = fx.seedWork("work")
      let older = fx.g(work, "rev-parse HEAD").strip()
      writeFile(work / "next.txt", "next\n")
      discard fx.g(work, "add next.txt")
      discard fx.g(work, "commit -q -m next")
      discard fx.g(work, "push -q origin main")
      let integrity = gitObjectMultihash("sha1", older)
      discard requireCmd(q(fx.gitBin) & " clone -q --depth 1 " &
        q(fileUrl(fx.origin)) & " " & q(fx.scratch / "sib-shallow"))
      # A full clone of a history that never had the pinned revision.
      let stranger = "1111111111111111111111111111111111111111"
      discard requireCmd(q(fx.gitBin) & " clone -q " &
        q(fileUrl(fx.origin)) & " " & q(fx.scratch / "sib-full"))

      let shallow = verifySibling(fx.scratch, "sib-shallow", older, integrity)
      check shallow.len == 1
      if shallow.len == 1:
        check shallow[0].cause == licShallowCheckout
        check lockedIntegrityCauseToken(shallow[0].cause) == "shallow-checkout"
        let remedy = lockedIntegrityRemedy(shallow[0], "", "the lock",
          "repro lock refresh")
        check "fetch-depth: 0" in remedy
        check "git fetch --unshallow" in remedy
        check "GONE" notin remedy

      let full = verifySibling(fx.scratch, "sib-full", stranger, integrity)
      check full.len == 1
      if full.len == 1:
        check full[0].cause == licRevisionUnreachable
        check "GONE" in lockedIntegrityRemedy(full[0], "", "the lock",
          "repro lock refresh")
