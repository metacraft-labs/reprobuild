## Shared fixture for the TC-8d tests: certifying a working tree before it
## is committed (test-certificates Standard §3.2, §3.2.2, §3.2.3).
##
## Builds on ``committed_lock_siblings_fixture``: a real manifest workspace
## with four real git repositories (app → lib-b → lib-c, and lib-d), no lock
## record store, so ``app``'s lock is the ``repro.lock`` it commits. That makes
## it a COMMITTED-LOCK project, which before TC-8d could be verified but could
## not issue. On top of it this adds what issuance needs: a scratch local
## certificate store, a daemon signing key and its registration.
##
## The test commands are real shell commands run by the real ``repro test``
## fixture path; the certificates are read back from the store and judged by
## the production verifier (``evaluateReprobuildCoverage``: framework, a
## registered signature, the content match, the lock read from the content).
## The content id a test expects is computed with git alone, never with the
## library under test. Nothing is mocked.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import ./committed_lock_siblings_fixture

export committed_lock_siblings_fixture

include tc5_cert_signing_helpers

const certifyKeyId* = "tc8d-daemon-key"

type
  CertifyFixture* = object
    sib*: SiblingFixture
    daemonKey*: string
    certStore*: string
    counter*: string
      ## Every fixture test command appends a line here when it runs, so a
      ## test can tell a run from a no-op.

proc appendProjectToml*(fx: CertifyFixture; text: string) =
  ## Add a table (``[certificates]`` …) to ``projects/app.toml``, between the
  ## ``[project]`` table and the first ``[[remote]]``, where the other
  ## certificate tests put it.
  let path = fx.sib.ws / "projects" / "app.toml"
  let body = readFile(path)
  let at = body.find("[[remote]]")
  doAssert at > 0, "projects/app.toml has no [[remote]] table"
  writeFile(path, body[0 ..< at] & text & "\n" & body[at .. ^1])

proc setupCertifyFixture*(label: string): CertifyFixture =
  result.sib = setupSiblingFixture(label)
  result.certStore = isolateCertificateStore(result.sib.scratch)
  result.counter = result.sib.scratch / "run-counter.txt"
  let key = genEd25519Key(result.sib.scratch / "daemon-keys", "tc8d-key",
    certifyKeyId)
  result.daemonKey = key.priv
  writeRegistry(result.sib.ws,
    @[RegisteredKey(keyId: certifyKeyId, publicKey: key.pub,
      status: rksActive)])
  for name in ["lib-b", "lib-c", "lib-d"]:
    discard result.sib.git(result.sib.ws / name,
      "config user.email tester@example.invalid")
    discard result.sib.git(result.sib.ws / name,
      "config user.name \"Lock Tester\"")
  # The committed lock: app's repro.lock pins lib-b and lib-c as checked out.
  result.sib.refreshAndPublishLock()

proc writeFixtureJson*(fx: CertifyFixture; target, script: string): string =
  ## A one-edge ``--fixture-from`` file whose test command counts its runs and
  ## then runs ``script`` with ``sh -c``.
  result = fx.sib.scratch / ("fixture-" & target & ".json")
  var cmd = newJArray()
  cmd.add(%"sh"); cmd.add(%"-c")
  cmd.add(%("echo ran >> " & q(fx.counter) & "; " & script))
  var edge = newJObject()
  edge["id"] = %1
  edge["selector"] = %target
  edge["historyKey"] = %target
  edge["buildDeps"] = newJArray()
  edge["runCmd"] = cmd
  edge["testName"] = %target
  var fixture = newJObject()
  fixture["fallbackBuildCostNs"] = %1
  fixture["fallbackTestCostNs"] = %1
  fixture["testEdges"] = %[edge]
  fixture["buildActions"] = newJArray()
  writeFile(result, fixture.pretty() & "\n")

proc runs*(fx: CertifyFixture): int =
  if not fileExists(fx.counter): return 0
  for line in readFile(fx.counter).splitLines():
    if line.strip().len > 0: inc result

proc certify*(fx: CertifyFixture; fixtureJson: string;
              repo = ""): CmdResult =
  ## ``repro test --certify`` on the fixture path for ``repo`` (default:
  ## app), from the scratch directory so the runner's ``test-logs/`` never
  ## lands in a repository.
  runShell(shellCommand(@[
    fx.sib.repro, "test",
    "--fixture-from=" & fixtureJson,
    "--shard=1/1",
    "--certify",
    "--workspace-root=" & fx.sib.ws,
    "--current-repo=" & (if repo.len > 0: repo else: fx.sib.app)],
    daemonKeyEnv(fx.daemonKey, certifyKeyId)), fx.sib.scratch)

proc gitIn*(fx: CertifyFixture; repo, args: string): string =
  fx.sib.git(repo, args)

proc workingTreeContentId*(fx: CertifyFixture; repo: string): string =
  ## The content id of ``repo``'s working tree, computed with git alone.
  workingTreeContentIdOf(fx.sib.gitBin, repo,
    fx.sib.scratch / "expected-index")

proc issuedFor*(fx: CertifyFixture; contentId: string): seq[TestCertificate] =
  for path in storedCertificateFiles(fx.certStore, contentId):
    result.add(readCertificateFile(path))

proc anyCertificateIssued*(fx: CertifyFixture): bool =
  ## Whether the local store holds any certificate at all.
  if not dirExists(fx.certStore / "v1"): return false
  for path in walkDirRec(fx.certStore / "v1"):
    if path.endsWith(".toml"): return true
  false

proc coverageAt*(fx: CertifyFixture; repo, commit,
                 target: string): ReprobuildCoverageVerdict =
  ## The TC-8b verifier, as the gateway and CI run it, for ``commit``'s tree:
  ## the certificates the local store holds for that content, a registered
  ## signature, the content match, and the lock read from the content.
  let state = commitUnderEvaluation(repo, commit)
  let found = findCertificatesInLocalStore(state)
  evaluateReprobuildCoverage(found.found, state, @[currentPlatformTag()],
    @[target], readRegisteredKeyStoreChecked(
      registeredKeyStorePath(fx.sib.ws)), committedLockSource())
