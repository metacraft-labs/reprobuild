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
