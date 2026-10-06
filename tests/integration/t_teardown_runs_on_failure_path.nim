## A deliberately failing test still destroys everything it created —
## and so does one that raises, one that calls `quit`, and one that is
## asked to stop by a signal.
##
## ## Why this is a matrix and not a case
##
## "Teardown runs" is four different mechanisms wearing one sentence.
## A `finally` catches a return and an exception and does **not** catch
## `quit`. An exit procedure catches `quit` and does **not** catch a
## signal. A signal handler catches `SIGTERM`, `SIGINT` and `SIGHUP`
## and does **not** catch `SIGKILL`. Nothing catches `SIGKILL`.
##
## A gate that tested one exit path and wrote "teardown runs on every
## exit path" in its title would be a case titled after a claim whose
## body asserts something weaker. So every path is a **real child
## process** in a role of its own, leaving it the way that path leaves
## a process, and the one path nothing can catch has a case that says
## so rather than a case that pretends otherwise.
##
## ## The negative control is a role, not a comment
##
## Every measurement here is "the instance is gone". That is satisfied
## by an instance that was never created, by an effector that destroys
## on creation, and by a provider whose files vanish on their own. So
## one child role — `no-teardown` — takes a lease, creates an instance
## and exits with no teardown of any kind, and its instance is required
## to **survive**. Until that role leaves something behind, none of the
## other roles' zeroes mean anything.
##
## ## Released once, not twice
##
## Two of the mechanisms above can both fire on one exit. The release
## is idempotent, and the way that is measured is the ledger: a closed
## hold writes exactly one line, so a second release would be visible
## as a second line rather than invisible.
##
## ## What this gate does NOT establish
##
## That a real provider destroys a real instance. The effector is a
## second implementation of the same seam, justified in the header of
## `cloud_lease_fake_provider`. What is established is that the
## teardown reaches the seam, on each of these exit paths, with the
## right invocation — and that on the one path it cannot reach, nothing
## silently claims it did.
##
## ## Mocking
##
## One substitution, at the effector seam, justified in that module's
## header. The processes, the signals, the exit codes and the store are
## all real.

import std/[os, osproc, posix, strutils, times, unittest]

import repro_attest
import repro_attest/cloud_lease

import ./cloud_lease_fake_provider

# The armed-launch roles below reach `performLeasedCloudLaunch`, which
# computes the launch's expected measurement from the REAL firmware
# bytes on its way past — a dry run and an armed launch do the same work
# up to the hand-over, deliberately, so a placeholder firmware is
# refused there. Every other role in this file is about lifetime rather
# than about measurement and needs no such thing.
include ./snp_digest_vectors

proc bytesOfHexString(h: string): string =
  doAssert h.len mod 2 == 0
  result = newString(h.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(h[2 * i .. 2 * i + 1]))

let armedFirmware = bytesOfHexString(UpstreamOvmfAmdSevSuffixHex)

const
  ChildRoleFlag = "--teardown-child-role="
  ReadyFlag = "--ready="
  StoreFlag = "--store="
  ProviderFlag = "--provider-root="
  LedgerFlag = "--ledger="

proc flagValue(prefix: string): string =
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.startsWith(prefix): return a[prefix.len .. ^1]
  ""

proc childSpec(nth: int): CloudLaunchSpec =
  CloudLaunchSpec(
    provider: cpAwsEc2,
    region: "us-east-1",
    instanceName: "reproos-teardown-probe-" & $nth,
    instanceShape: "m6a.2xlarge",
    imageReference: "ami-0fixture000000000",
    subnet: "subnet-0fixture000000000",
    sshKeyReference: "reproos-teardown-probe-key",
    firmware: "not-a-real-firmware-image",
    machineModel: "EPYC-Milan",
    guestPolicy: "0x30000",
    guestFeatures: "0x21",
    configFingerprint: "reproos-attested-uefi:cloud-lease",
    ukiImage: "not-a-real-unified-kernel-image",
    verityImageDigest: "sha256:" & repeat('5', 64),
    verityRootHash: repeat('4', 64))

proc armedSpec(nth: int): CloudLaunchSpec =
  ## The same launch, with firmware bytes the measurement calculator
  ## accepts. Used only by the two roles that really create something.
  result = childSpec(nth)
  result.firmware = armedFirmware

proc runChildRole(role: string) {.noreturn.} =
  let store = openCloudLeaseStore(flagValue(StoreFlag))
  let provider = openFakeProvider(flagValue(ProviderFlag))
  let effector = fakeProviderEffector(provider)
  let ready = flagValue(ReadyFlag)
  let ledger = flagValue(LedgerFlag)
  let now = getTime().toUnix

  var announced: seq[string] = @[]

  proc take(nth: int): CloudLeaseHolder =
    let spec = childSpec(nth)
    result = acquireCloudLease(store, spec, delayed(seconds = 3600), now,
      3_600_000, effector, ledger)
    let created = effector(CloudEffect(
      argv: leasedLaunchPlan(spec, result.lease, fixedEnvLookup([])),
      providerEnvNames: providerEnvNamesFor(cpAwsEc2)))
    result.recordInstanceCreated(created.output.strip())
    announced.add created.output.strip()

  proc announce() =
    ## What this child created, written where the parent can read it.
    ##
    ## The parent must NOT learn this by looking at the provider: for
    ## every role that tears down immediately, the teardown races the
    ## observation and the parent sees an empty cloud — which reads as
    ## "it was destroyed" and is actually "nothing was ever seen". The
    ## first draft of this file did exactly that and the control role
    ## was the only thing that caught it.
    writeFile(ready, announced.join("\n"))

  if role == "no-teardown":
    # The negative control. A lease and an instance, and nothing that
    # would ever release either. Everything this gate asserts about the
    # other roles is worthless until this one leaves something behind.
    discard take(0)
    announce()
    quit(0)

  if role == "signal-scope-only":
    # The fold, measured. This role NEVER calls
    # `installCloudLeaseSignalTeardown` — entering the scope is the only
    # thing that could have installed the handlers — and it is stopped
    # with a signal. Before the fold the handler install was a SECOND
    # call the caller had to remember, and had to make before the
    # create, with nothing enforcing either; a role written this way
    # left its instance running.
    let alone = take(0)
    withCloudLease(alone):
      announce()
      while true: sleep(20)
    quit(0)

  if role == "launch-outside-scope":
    # An armed launch with no scope around it. The lease exists, the
    # effector exists, and the create is REFUSED — so the order cannot
    # be got wrong by writing the create first. Nothing else in this
    # role creates anything, so the provider is required to be EMPTY
    # afterwards and the refusal is measured on the cloud rather than
    # only on the exception.
    let outside = acquireCloudLease(store, armedSpec(1),
      delayed(seconds = 3600), now, 0, effector, ledger)
    var refused = false
    try:
      discard performLeasedCloudLaunch(outside, armedSpec(1), effector,
        fixedEnvLookup([]))
    except CloudLeaseError as err:
      refused = err.condition == cllArmedLaunchIsNotHeldUnderALease
    announce()
    quit(if refused: 21 else: 22)

  if role == "launch-inside-scope":
    # The same call, inside the scope, really creates — and the
    # teardown that the scope installed then destroys it. A control for
    # the role above: the refusal is about the scope and not about the
    # call being impossible.
    let inside = acquireCloudLease(store, armedSpec(1),
      delayed(seconds = 3600), now, 0, effector, ledger)
    var created = ""
    withCloudLease(inside):
      let outcome = performLeasedCloudLaunch(inside, armedSpec(1),
        effector, fixedEnvLookup([]))
      created = inside.lease.providerInstanceId
      announced.add created
      announce()
      doAssert outcome.effectsAttempted == 1
      doAssert created.len > 0
    quit(if created.len > 0: 23 else: 24)

  if role == "teardown-fault-under-a-failing-body":
    # The decision the `finally` owes: a body that failed keeps its own
    # failure, and the teardown fault raised over it is discarded. The
    # lease here has NO effector, so the release raises — and what must
    # leave this process is the body's `ValueError`, not the lease
    # library's refusal.
    let faulty = acquireCloudLease(store, childSpec(3),
      delayed(seconds = 3600), now)
    faulty.recordInstanceCreated("i-unreachable")
    announce()
    var sawBodyFailure = false
    try:
      withCloudLease(faulty):
        raise newException(ValueError, "this test fails on purpose")
    except ValueError:
      sawBodyFailure = true
    except CloudLeaseError:
      sawBodyFailure = false
    quit(if sawBodyFailure: 25 else: 26)

  if role == "teardown-fault-under-a-clean-body":
    # …and the other half: with nothing wrong with the body, a release
    # that could not run is what leaves. A scope that swallowed it would
    # report success for a lease nothing released.
    let faulty = acquireCloudLease(store, childSpec(4),
      delayed(seconds = 3600), now)
    faulty.recordInstanceCreated("i-unreachable")
    announce()
    var sawReleaseFault = false
    try:
      withCloudLease(faulty):
        discard
    except CloudLeaseError as err:
      sawReleaseFault = err.condition == cllReapHasNoEffector
    quit(if sawReleaseFault: 27 else: 28)

  let holder = take(0)
  installCloudLeaseSignalTeardown(holder)

  case role
  of "ok":
    withCloudLease(holder):
      announce()
    quit(0)
  of "raise":
    withCloudLease(holder):
      announce()
      raise newException(ValueError, "this test fails on purpose")
    quit(0)
  of "quit":
    withCloudLease(holder):
      announce()
      quit(7)
    quit(0)
  of "signal":
    withCloudLease(holder):
      announce()
      while true: sleep(20)
    quit(0)
  of "many":
    # Three holds, and the failure happens under all of them. A
    # teardown that released only the innermost would leave two
    # machines running and one case green.
    let second = take(1)
    let third = take(2)
    installCloudLeaseSignalTeardown(second)
    installCloudLeaseSignalTeardown(third)
    withCloudLease(holder):
      withCloudLease(second):
        withCloudLease(third):
          announce()
          raise newException(ValueError, "this test fails on purpose")
    quit(0)
  else:
    quit(97)
  quit(98)

let childRole = flagValue(ChildRoleFlag)
if childRole.len > 0:
  runChildRole(childRole)

# ---------------------------------------------------------------------

let scratch = getTempDir() / "repro-teardown-" & $getCurrentProcessId()
createDir(scratch)

type Gear = tuple[store: CloudLeaseStore; provider: FakeProvider;
                  ledger, ready, root: string]

var caseCounter = 0
proc freshCase(name: string): Gear =
  inc caseCounter
  let root = scratch / (name & "-" & $caseCounter)
  createDir(root)
  result.root = root
  result.store = openCloudLeaseStore(root / "leases")
  result.provider = openFakeProvider(root / "cloud")
  result.ledger = root / "ledger.txt"
  result.ready = root / "ready"

proc startChild(role: string; gear: Gear): Process =
  startProcess(getAppFilename(), args = @[
    ChildRoleFlag & role,
    StoreFlag & gear.store.root,
    ProviderFlag & gear.provider.root,
    LedgerFlag & gear.ledger,
    ReadyFlag & gear.ready], options = {})

proc waitForFile(path: string; timeoutMs = 20_000): bool =
  var waited = 0
  while waited < timeoutMs:
    if fileExists(path): return true
    sleep(20)
    waited += 20
  false

proc ledgerLines(path: string): seq[string] =
  if not fileExists(path): return
  for line in readFile(path).splitLines:
    if line.strip().len > 0: result.add line

proc runRole(role: string; gear: Gear;
             signal = 0): tuple[code: int; created: seq[string]] =
  ## Start a child in a role, wait until it says what it created,
  ## optionally signal it, and wait for it to exit.
  ##
  ## The created set is read from the CHILD's own announcement and not
  ## from the provider, for the reason the child's `announce` states:
  ## every role that tears down immediately races the observation, and
  ## an empty cloud read too late is indistinguishable from an empty
  ## cloud that was never filled.
  let child = startChild(role, gear)
  doAssert waitForFile(gear.ready), role & " never created anything"
  for line in readFile(gear.ready).splitLines:
    if line.strip().len > 0: result.created.add line.strip()
  if signal != 0:
    discard kill(Pid(child.processID), cint(signal))
  result.code = child.waitForExit()
  child.close()

# ---------------------------------------------------------------------

suite "the control: a run with no teardown leaves its instance running":

  test "an owner that releases nothing leaves the instance AND the record":
    # FIRST, because every zero below is satisfied by an instance that
    # was never created and by a provider whose files vanish on their
    # own. Until this role leaves something behind, this file measures
    # nothing.
    let gear = freshCase("control")
    let outcome = runRole("no-teardown", gear)
    check outcome.code == 0
    check outcome.created.len == 1
    check liveInstances(gear.provider) == outcome.created
    check listCloudLeases(gear.store).len == 1
    check ledgerLines(gear.ledger).len == 0
    # …and the instance carries the lease's tags, so what survived is
    # findable by the reaper rather than merely present.
    check tagValueOf(gear.provider, outcome.created[0], $cltLeaseId) ==
      listCloudLeases(gear.store)[0].leaseId

suite "every exit path a process lives to see":

  test "a run that returns normally destroys what it created":
    let gear = freshCase("normal")
    let outcome = runRole("ok", gear)
    check outcome.code == 0
    check outcome.created.len == 1
    check liveInstances(gear.provider).len == 0
    check listCloudLeases(gear.store).len == 0
    check ledgerLines(gear.ledger).len == 1

  test "a run that RAISES destroys what it created, and still fails":
    # The headline: a deliberately failing test still destroys
    # everything it created. Both halves are asserted —
    # a teardown that also swallowed the failure would be worse than no
    # teardown, because the suite would go green.
    let gear = freshCase("raise")
    let outcome = runRole("raise", gear)
    check outcome.code != 0
    check outcome.created.len == 1
    check liveInstances(gear.provider).len == 0
    check listCloudLeases(gear.store).len == 0
    # Released exactly ONCE, although the `finally` and the exit
    # procedure both reach the release on this path.
    check ledgerLines(gear.ledger).len == 1
    check "reaped" in ledgerLines(gear.ledger)[0]
    # The destroy actually reached the seam.
    check invocationsMentioning(gear.provider, "terminate-instances") == 1

  test "a run that calls quit destroys what it created":
    # The path a `finally` does not see at all. Without the exit
    # procedure this case is red, which is why both are installed.
    let gear = freshCase("quit")
    let outcome = runRole("quit", gear)
    check outcome.code == 7
    check outcome.created.len == 1
    check liveInstances(gear.provider).len == 0
    check listCloudLeases(gear.store).len == 0
    check ledgerLines(gear.ledger).len == 1

  test "a run stopped by each catchable signal destroys what it created":
    # Three signals, because the handler is installed for three and a
    # list nobody exercises is a list that stops being true.
    var covered = 0
    for pair in [("SIGTERM", int(SIGTERM)), ("SIGINT", int(SIGINT)),
                 ("SIGHUP", int(SIGHUP))]:
      let gear = freshCase("signal-" & pair[0])
      let outcome = runRole("signal", gear, pair[1])
      checkpoint(pair[0])
      check outcome.created.len == 1
      check outcome.code == 128 + pair[1]
      check liveInstances(gear.provider).len == 0
      check listCloudLeases(gear.store).len == 0
      check ledgerLines(gear.ledger).len == 1
      inc covered
    check covered == 3
    check cloudLeaseSignalHolderCount() == 0   # the PARENT holds none

  test "a failing run destroys EVERYTHING it created, not the last one":
    let gear = freshCase("many")
    let outcome = runRole("many", gear)
    check outcome.code != 0
    check outcome.created.len == 3
    check liveInstances(gear.provider).len == 0
    check listCloudLeases(gear.store).len == 0
    check ledgerLines(gear.ledger).len == 3
    check invocationsMentioning(gear.provider, "terminate-instances") == 3
    # Three DIFFERENT instances, so this is not one destroy counted
    # three times.
    var unique: seq[string] = @[]
    for id in outcome.created:
      if id notin unique: unique.add id
    check unique.len == 3

suite "the scope installs the teardown, so the order cannot be got wrong":

  test "a scope alone tears down on a signal, with no second call":
    # The fold. This child never calls the install procedure; entering
    # `withCloudLease` is the only thing that could have armed the
    # handlers. Before the fold this role left its instance running,
    # because the install was a separate call a caller had to remember
    # and had to make BEFORE the create, with nothing enforcing either.
    let gear = freshCase("scope-only")
    let outcome = runRole("signal-scope-only", gear, int(SIGTERM))
    check outcome.created.len == 1
    check outcome.code == 128 + int(SIGTERM)
    check liveInstances(gear.provider).len == 0
    check listCloudLeases(gear.store).len == 0
    check ledgerLines(gear.ledger).len == 1

  test "an armed launch OUTSIDE a scope is refused, and INSIDE creates":
    # Both directions in one case, because either alone reads as the
    # whole answer: a refusal with nothing that succeeds is satisfied by
    # a call that can never work, and a success with nothing refused is
    # satisfied by a guard that is not there.
    let refusedGear = freshCase("armed-outside")
    let refused = runRole("launch-outside-scope", refusedGear)
    check refused.code == 21          # the refusal was the named one
    # Nothing was created: the refusal happened BEFORE the provider was
    # asked, which is the only place a refusal is worth anything.
    check liveInstances(refusedGear.provider).len == 0
    check invocationsMentioning(refusedGear.provider, "run-instances") == 0

    let allowedGear = freshCase("armed-inside")
    let allowed = runRole("launch-inside-scope", allowedGear)
    check allowed.code == 23          # it really created one
    check invocationsMentioning(allowedGear.provider, "run-instances") == 1
    # …and the scope that permitted it also destroyed it: nothing the
    # armed path created outlived the process.
    check liveInstances(allowedGear.provider).len == 0
    check listCloudLeases(allowedGear.store).len == 0

  test "an armed launch carries the lease's tags to the provider":
    # The armed path must send the TAGGED invocation, because the tags
    # are the line of defence that survives losing the record. Read off
    # the invocation log, which is what the effector was really handed.
    let gear = freshCase("armed-tags")
    let outcome = runRole("launch-inside-scope", gear)
    check outcome.code == 23
    var tagged = 0
    for tag in CloudLeaseTag:
      if invocationsMentioning(gear.provider, "{Key=" & $tag & ",Value=") > 0:
        inc tagged
    check tagged == ord(high(CloudLeaseTag)) + 1

suite "the signal set is a set":

  test "installing the same holder twice puts it in the set ONCE":
    # Found by a mutation row that came back GREEN, which is the whole
    # reason this case exists: making the install non-idempotent changed
    # NOTHING any other check could see. The reason it is invisible is
    # itself the reason it matters — a holder listed twice is released
    # twice from one signal, and the second release is harmless only
    # because the release is idempotent. Relying on one idempotence to
    # excuse the absence of another, inside a signal handler, is a thin
    # thing to be resting on.
    #
    # This case runs AFTER the one that requires the parent to hold
    # none, so the count it starts from is a measurement rather than an
    # assumption.
    let gear = freshCase("signal-set")
    let before = cloudLeaseSignalHolderCount()
    let effector = fakeProviderEffector(gear.provider)
    let holder = acquireCloudLease(gear.store, childSpec(0),
      delayed(seconds = 600), 1_700_000_000'i64, 0, effector)
    installCloudLeaseSignalTeardown(holder)
    check cloudLeaseSignalHolderCount() == before + 1
    check holder.handlersInstalled
    # The second, third and fourth calls add nothing.
    for _ in 0 .. 2: installCloudLeaseSignalTeardown(holder)
    check cloudLeaseSignalHolderCount() == before + 1
    # The control: a DIFFERENT holder does add one, so the equality
    # above is about this holder and not about the set being closed.
    let second = acquireCloudLease(gear.store, childSpec(1),
      delayed(seconds = 600), 1_700_000_000'i64, 0, effector)
    installCloudLeaseSignalTeardown(second)
    check cloudLeaseSignalHolderCount() == before + 2
    # …and entering a scope installs without duplicating either, which
    # is the case the fold creates: the scope installs unconditionally
    # and a caller may already have installed by hand.
    withCloudLease(second):
      check cloudLeaseSignalHolderCount() == before + 2
      check second.inScope
    check not second.inScope

suite "a teardown fault does not replace the failure that caused it":

  test "a failing body keeps its own failure, and a clean one does not":
    # The decision the scope's `finally` owed, asserted in both
    # directions in one case. A teardown fault raised over a failing
    # body replaces the cause with a symptom; a teardown fault
    # swallowed under a clean body reports success for a lease nothing
    # released.
    let failing = freshCase("fault-failing-body")
    check runRole("teardown-fault-under-a-failing-body", failing).code == 25
    let clean = freshCase("fault-clean-body")
    check runRole("teardown-fault-under-a-clean-body", clean).code == 27

suite "the exit path nothing can see":

  test "SIGKILL leaves the instance, and the reaper is what takes it":
    # Stated as what it is. A gate that claimed teardown ran here would
    # be claiming something impossible, and the division of labour
    # between the holder and the reaper is the whole design: this case
    # is the handover.
    let gear = freshCase("sigkill")
    let outcome = runRole("signal", gear, int(SIGKILL))
    check outcome.created.len == 1
    check outcome.code == 137
    # Nothing ran. The instance and the record are both still there…
    check liveInstances(gear.provider) == outcome.created
    check listCloudLeases(gear.store).len == 1
    check ledgerLines(gear.ledger).len == 0
    # …and the reaper, which needs no cooperation from the dead owner,
    # takes it — well inside the lease window, because the owner is
    # provably gone.
    let lease = listCloudLeases(gear.store)[0]
    let report = reapCloudLeases(gear.store, lease.acquiredAtUnix + 1,
      processOwnerLiveness(), fakeProviderEffector(gear.provider),
      gear.ledger)
    check report.reaped == 1
    check report.events[0].decision == rdOrphaned
    check liveInstances(gear.provider).len == 0
    check listCloudLeases(gear.store).len == 0
    check ledgerLines(gear.ledger).len == 1
    requireReapSucceeded(report)

suite "releasing twice is free, and releasing is not optional":

  test "a second release is a no-operation and is COUNTED as an attempt":
    let gear = freshCase("twice")
    let effector = fakeProviderEffector(gear.provider)
    let now = 1_700_000_000'i64
    let spec = childSpec(0)
    let holder = acquireCloudLease(gear.store, spec,
      delayed(seconds = 600), now, 0, effector, gear.ledger)
    let created = effector(CloudEffect(
      argv: leasedLaunchPlan(spec, holder.lease, fixedEnvLookup([])),
      providerEnvNames: providerEnvNamesFor(cpAwsEc2)))
    holder.recordInstanceCreated(created.output.strip())
    check liveInstances(gear.provider).len == 1

    let first = releaseCloudLease(holder, now + 10)
    check first.outcome == roReaped
    check holder.releases == 1
    check liveInstances(gear.provider).len == 0
    let destroys = invocationsMentioning(gear.provider,
      "terminate-instances")
    check destroys == 1

    let second = releaseCloudLease(holder, now + 20)
    check second.outcome == roNothingToDestroy
    # The attempt is COUNTED — a flag alone could not tell "never
    # released" from "released and said nothing" — and no second
    # destroy was issued.
    check holder.releases == 2
    check invocationsMentioning(gear.provider, "terminate-instances") ==
      destroys
    check ledgerLines(gear.ledger).len == 1

  test "a release whose destroy fails puts the record BACK":
    # The other direction: a teardown that could not do its job must
    # leave the reaper something to find, not tidy away the evidence.
    let gear = freshCase("release-fails")
    let effector = fakeProviderEffector(gear.provider)
    let now = 1_700_000_000'i64
    let spec = childSpec(0)
    let holder = acquireCloudLease(gear.store, spec,
      delayed(seconds = 600), now, 0, effector, gear.ledger)
    let created = effector(CloudEffect(
      argv: leasedLaunchPlan(spec, holder.lease, fixedEnvLookup([])),
      providerEnvNames: providerEnvNamesFor(cpAwsEc2)))
    holder.recordInstanceCreated(created.output.strip())
    setFailureMode(gear.provider, ffmDestroyFails)
    let event = releaseCloudLease(holder, now + 10)
    check event.outcome == roFailed
    check liveInstances(gear.provider).len == 1
    check listCloudLeases(gear.store).len == 1
    check ledgerLines(gear.ledger).len == 0
    # And the reaper then finishes the job once the provider answers.
    setFailureMode(gear.provider, ffmNone)
    let report = reapCloudLeases(gear.store, now + 700,
      fixedOwnerLiveness(olUnknowable), effector, gear.ledger)
    check report.reaped == 1
    check liveInstances(gear.provider).len == 0

  test "a lease with no effector cannot be released quietly":
    # A missing effector is a programming error rather than a destroy
    # that failed, so the release RAISES instead of reporting. Only the
    # exit procedure and the signal handler discard it; the `finally`
    # does not, and a fault there replaces the body's own failure.
    let gear = freshCase("no-effector")
    let now = 1_700_000_000'i64
    let holder = acquireCloudLease(gear.store, childSpec(0),
      delayed(seconds = 600), now)
    holder.recordInstanceCreated("i-unreachable")
    var refused = false
    try:
      discard releaseCloudLease(holder, now + 10)
    except CloudLeaseError as err:
      refused = err.condition == cllReapHasNoEffector
    check refused

suite "teardown":

  test "the scratch directory is removed":
    removeDir(scratch)
    check not dirExists(scratch)
