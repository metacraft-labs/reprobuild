## Shared fixture for the tests of the client pre-push gate's lock-only
## diagnostic: when trusted certificates do not cover the pushed content, the
## gate names certified content that differs from the pushed tree only in the
## lock files the commit-time writers manage (``repro.lock``, ``flake.lock``),
## and the lock files that differ.
##
## ``include``d, not a registered test. It includes ``tc8c_store_fixture``: a
## real workspace, a real developer clone of lib-a pushing to a real upstream
## bare, the local certificate store pointed at scratch roots, and a daemon
## key registered in the workspace. lib-a here is a COMMITTED-LOCK project
## (``recordStore = false``): its tracked ``repro.lock`` carries the policy
## snapshot that requires ``t-unit`` on this platform under ``required``.
##
## A certificate is made the way a producer makes one before a commit exists:
## the working tree's content id, computed by git alone (``git add --update``
## in a temporary index, ``git write-tree``), signed with the registered key
## through the real signing primitive and delivered to the local store with
## the production writer. Nothing is mocked; no hook is installed, so the
## commits and pushes here run no hook at all.

include tc8c_store_fixture

proc setupLockOnlyFixture(slug: string): StoreFixture =
  setupStoreFixture(requiredPolicy(@["t-unit"], @[currentPlatformTag()]),
    slug, recordStore = false)

proc publish(fx: StoreFixture) =
  ## Publish ``main`` to the upstream and refresh the remote-tracking ref, so
  ## the gate's publication stage passes and the certificate stage decides.
  discard gitOut(fx.libAPath, "push", "-q", "origin", "main")
  discard gitOut(fx.libAPath, "fetch", "-q", "origin")

proc certifyWorkingTree(fx: StoreFixture):
    tuple[content, base: string] =
  ## Stage everything, then certify the working tree's content — what a
  ## ``repro test`` run does before the commit exists. ``base`` is ``HEAD``.
  discard gitOut(fx.libAPath, "add", "-A")
  result.content = workingTreeContentId(fx.libAPath)
  result.base = gitOut(fx.libAPath, "rev-parse", "HEAD")
  let cert = signedCertFor(fx, result.content, result.base)
  doAssert publishCertificateToLocalStore(cert, fx.libAPath).written

proc commitAll(fx: StoreFixture; message: string): string =
  discard gitOut(fx.libAPath, "add", "-A")
  discard gitOut(fx.libAPath, "commit", "-q", "-m", message)
  gitOut(fx.libAPath, "rev-parse", "HEAD")

proc failureField(report: JsonNode; property, field: string): string =
  if report.hasKey("failures"):
    for f in report["failures"]:
      if f["property"].getStr() == property:
        return f[field].getStr()

proc relockPolicy(fx: StoreFixture) =
  ## Rewrite ``repro.lock`` so that it differs in bytes but requires the
  ## same thing: the snapshot's ``ci_trust`` moves from ``advisory`` to
  ## ``skip``, which no client gate reads. A lock-only change, like a re-pin.
  writeFile(fx.libAPath / "repro.lock", policyLock(requiredPolicy(
    @["t-unit"], @[currentPlatformTag()], ciTrust = "skip")))

const lockOnlyCauseMarker = "the lock changed after the tests ran"
