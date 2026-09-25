## An instance whose owning test is killed mid-run is destroyed by the
## reaper — asserted against a process this gate really kills.
##
## ## The claim, and why it needs a corpse
##
## The thing being established is that a confidential guest does not
## outlive the test that created it *even when that test is given no
## chance to clean up*. `SIGKILL` is the exit path nothing observes: no
## `finally` runs, no exit procedure runs, no signal handler runs. A
## gate that asserted this by calling a teardown procedure would be
## asserting the opposite of the interesting case.
##
## So the owner here is a **real child process** — this same binary,
## re-entered in a child role — which takes a lease, creates an
## instance through the effector seam, says so, and then waits to be
## killed. The parent kills it with `SIGKILL`, confirms it is gone, and
## then runs the reaper. Every assertion afterwards is about files on
## disk that the dead process created.
##
## ## The control comes first, everywhere
##
## Every "it was destroyed" is satisfied by an instance that was never
## created, and every "the reaper found it" is satisfied by a reaper
## that destroys everything it sees. So, in order, before each
## measurement:
##
##   * the instance is required to EXIST at the moment the owner is
##     killed, so there is something to reap;
##   * the same reaper run against a lease whose owner is ALIVE is
##     required to leave it alone, so "reaped" is a decision and not a
##     habit;
##   * the effector is required to have been ASKED — the invocation log
##     is counted — so a destroy that never reached the seam cannot pass
##     as one that did.
##
## ## Three ways an instance is found, and they degrade in that order
##
##   1. **By identifier**, out of the lease record, when the owner lived
##      long enough to write one down.
##   2. **By tag, with the record**, when the owner died in the window
##      between asking for an instance and learning what it was called.
##      The record says which lease to look for; the provider says which
##      instance carries it.
##   3. **By tag, with no record at all**, when the local store is gone.
##      This one reaps on the deadline only, and the case says so: the
##      owner tag names a process on a host this sweeper may not be on.
##
## All three have a case, and the third has the store deleted out from
## under it rather than simulated.
##
## ## What this gate does NOT establish
##
## That a real provider destroys a real instance when handed these
## invocations. Nothing here contacts a cloud, and the effector is a
## second implementation of the same seam — see the header of
## `cloud_lease_fake_provider`, which states the substitution and its
## justification. What is established is everything on this side of the
## seam: which leases are selected, when, what invocation each one
## produces, and that the selection survives its owner being killed.
##
## ## Mocking
##
## One substitution, at the effector seam, justified in that module's
## header. Nothing else: the processes are real, the signals are real,
## the store is a real directory, and the liveness probe is the one the
## command uses.

import std/[algorithm, options, os, osproc, posix, strutils, times,
            unittest]

import repro_attest
import repro_attest/cloud_lease
import repro_cli_support/attest

import ./cloud_lease_fake_provider

# The launch COMMAND computes a real expected measurement from the real
# firmware bytes, so the two cases that drive it need a firmware image
# the calculator accepts. The library cases do not — nothing in a lease
# is an input to a measurement — which is why a placeholder serves
# everywhere else in this file.
include ./snp_digest_vectors

proc bytesOfHexString(h: string): string =
  doAssert h.len mod 2 == 0
  result = newString(h.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(h[2 * i .. 2 * i + 1]))

let commandFirmware = bytesOfHexString(UpstreamOvmfAmdSevSuffixHex)

# ---------------------------------------------------------------------
# The child roles — entered before any suite runs
# ---------------------------------------------------------------------

const
  ChildRoleFlag = "--cloud-lease-child-role="
  ReadyFlag = "--ready="
  StoreFlag = "--store="
  ProviderFlag = "--provider-root="

proc flagValue(prefix: string): string =
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.startsWith(prefix): return a[prefix.len .. ^1]
  ""

proc childSpec(): CloudLaunchSpec =
  ## The same launch in the parent and in every child, so a difference
  ## between them is a finding rather than a difference of inputs. Every
  ## identifier is a fabricated placeholder: this gate reaches no cloud.
  CloudLaunchSpec(
    provider: cpAwsEc2,
    region: "us-east-1",
    instanceName: "reproos-lease-probe",
    instanceShape: "m6a.2xlarge",
    imageReference: "ami-0fixture000000000",
    subnet: "subnet-0fixture000000000",
    sshKeyReference: "reproos-lease-probe-key",
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
  let holder = acquireCloudLease(store, childSpec(),
    delayed(seconds = 3600), getTime().toUnix, 0, effector)
  let created = effector(CloudEffect(
    argv: leasedLaunchPlan(childSpec(), holder.lease,
      fixedEnvLookup([])),
    providerEnvNames: providerEnvNamesFor(cpAwsEc2)))
  case role
  of "leak":
    # The owner lived long enough to write the identifier down, so the
    # reaper will find the instance by name.
    holder.recordInstanceCreated(created.output.strip())
    writeFile(ready, holder.lease.leaseId)
    while true: sleep(50)
  of "leak-midflight":
    # The window the write-ahead record exists for: the provider has
    # answered and this process dies before it can record the answer.
    # Not simulated — it really kills itself, here, between the two
    # statements.
    writeFile(ready, holder.lease.leaseId)
    discard kill(Pid(getCurrentProcessId()), SIGKILL)
    while true: sleep(50)
  else:
    quit(97)
  quit(98)

let childRole = flagValue(ChildRoleFlag)
if childRole.len > 0:
  runChildRole(childRole)

# ---------------------------------------------------------------------
# The parent's scratch
# ---------------------------------------------------------------------

let scratch = getTempDir() / "repro-cloud-lease-" & $getCurrentProcessId()
createDir(scratch)

var caseCounter = 0
proc freshCase(name: string): tuple[store: CloudLeaseStore;
                                    provider: FakeProvider;
                                    ledger: string; root: string] =
  inc caseCounter
  let root = scratch / (name & "-" & $caseCounter)
  createDir(root)
  result.root = root
  result.store = openCloudLeaseStore(root / "leases")
  result.provider = openFakeProvider(root / "cloud")
  result.ledger = root / "ledger.txt"

proc startOwner(role: string; store: CloudLeaseStore;
                provider: FakeProvider; ready: string): Process =
  startProcess(getAppFilename(), args = @[
    ChildRoleFlag & role,
    StoreFlag & store.root,
    ProviderFlag & provider.root,
    ReadyFlag & ready], options = {})

proc waitForFile(path: string; timeoutMs = 20_000): bool =
  var waited = 0
  while waited < timeoutMs:
    if fileExists(path) and getFileSize(path) > 0: return true
    sleep(20)
    waited += 20
  false

proc theOnlyLease(store: CloudLeaseStore): CloudLease =
  let all = listCloudLeases(store)
  doAssert all.len == 1, "expected exactly one lease, found " & $all.len
  all[0]

proc ledgerLines(path: string): seq[string] =
  if not fileExists(path): return
  for line in readFile(path).splitLines:
    if line.strip().len > 0: result.add line

proc occurrencesOf(path, needle: string): int =
  ## Occurrences in a file's RAW bytes. The single reader, used by the
  ## sweep below AND by its control: two different expressions counting
  ## the same thing is how an instrument goes unfalsified.
  readFile(path).count(needle)

proc reaperCallSitesIn(path: string): tuple[sweep, tagSweep: int] =
  (occurrencesOf(path, "reapCloudLeases("),
   occurrencesOf(path, "reapExpiredByTag("))

proc refuses(body: proc ()): ref CloudLeaseError =
  try:
    body()
  except CloudLeaseError as err:
    return err
  doAssert false, "expected a refusal and none was raised"

# ---------------------------------------------------------------------

suite "a lease record says everything a reaper needs":

  test "every field of the record has a name, and the reverse":
    # The bijection. A field added to the record without a name is a
    # field no record carries and no reaper reads; a name without a
    # field is a name nothing answers to.
    var lease: CloudLease
    var fieldNames: seq[string] = @[]
    for name, _ in lease.fieldPairs:
      fieldNames.add name
    var enumNames: seq[string] = @[]
    for f in CloudLeaseField: enumNames.add $f
    fieldNames.sort()
    enumNames.sort()
    check fieldNames == enumNames
    check fieldNames.len == 16

  test "the refusal vocabulary is distinguishable":
    check cloudLeaseMessagesAreDistinguishable()

  test "a record round-trips through its own bytes":
    let store = freshCase("roundtrip").store
    let holder = acquireCloudLease(store, childSpec(),
      delayed(seconds = 900), 1_700_000_000'i64, 42)
    let text = renderCloudLease(holder.lease)
    let back = parseCloudLease(text, "round-trip")
    check back == holder.lease
    check renderCloudLease(back) == text

  test "each field is carried SEPARATELY, one at a time":
    # The property a round-trip alone does not have: a writer that put
    # every field into one slot, or a reader that answered every name
    # with the same value, round-trips perfectly. So each field is moved
    # on its own and every other field is required to stay put.
    let store = freshCase("per-field").store
    let base = acquireCloudLease(store, childSpec(),
      delayed(seconds = 900), 1_700_000_000'i64, 42).lease
    var moved = 0
    for f in CloudLeaseField:
      if f == clfProvider: continue     # an enumeration with one member
      var mutated = base                # this build can name it twice
      let onlyValue = (case f
        of clfOwnerPid, clfAcquiredAtUnix, clfTtlSeconds,
           clfExpiresAtUnix, clfRatePerHourMicros, clfDestroyedAtUnix:
          "424242"
        of clfState: $clsDestroyed
        else: "a-value-only-this-field-has")
      setValue(mutated, f, onlyValue)
      let back = parseCloudLease(renderCloudLease(mutated), $f)
      check valueOf(back, f) == onlyValue
      inc moved
      for other in CloudLeaseField:
        if other == f: continue
        if valueOf(back, other) != valueOf(base, other):
          checkpoint($f & " also moved " & $other)
        check valueOf(back, other) == valueOf(base, other)
    check moved == 15

  test "a record that is not one, is short a field, or names one twice":
    let store = freshCase("record-refusals").store
    let good = renderCloudLease(acquireCloudLease(store, childSpec(),
      delayed(seconds = 900), 1_700_000_000'i64).lease)

    let notOurs = refuses(proc () =
      discard parseCloudLease("some other document\nleaseId=x\n", "probe"))
    check notOurs.condition == cllRecordIsNotOfThisFormat

    var lines = good.splitLines()
    var withoutRegion: seq[string] = @[]
    for line in lines:
      if not line.startsWith($clfRegion & "="): withoutRegion.add line
    let short = refuses(proc () =
      discard parseCloudLease(withoutRegion.join("\n"), "probe"))
    check short.condition == cllRecordDoesNotCarryEveryField
    check $clfRegion in short.msg

    let twice = refuses(proc () =
      discard parseCloudLease(good & $clfRegion & "=elsewhere\n", "probe"))
    check twice.condition == cllRecordCarriesAFieldTwice
    # …and the one that matters: the SECOND value does not silently win.
    check parseCloudLease(good, "probe").region == childSpec().region

  test "a value that could forge a second field is refused":
    var spec = childSpec()
    spec.instanceName = "probe\nownerPid=1"
    let store = freshCase("forged").store
    let e = refuses(proc () =
      discard acquireCloudLease(store, spec, delayed(seconds = 900),
        1_700_000_000'i64))
    check e.condition == cllValueCarriesACharacterTheRecordCannotHold

suite "the command writes down the launch it was ASKED for":

  test "each command-line parameter moves the record field it names":
    # This closes, for the lease, the hole the launch side could not:
    # the only cross-check between the command and the library there is
    # the MANIFEST, and a manifest is by construction insensitive to
    # every OPERATIONAL parameter — so a command that answered
    # `--region` with a constant printed the wrong region five times
    # and passed. Lease, deadline and tags are operational parameters
    # too, and they would have the same hole.
    #
    # The lease RECORD does not have it. It is an artifact the command
    # writes that carries the operational parameters verbatim, so each
    # flag can be moved on its own and the record read back. Each probe
    # DECLARES which fields it expects to move and is checked against
    # what actually moved, so a probe that moved more than it said is
    # red as well as one that moved less.
    let gear = freshCase("command-record")
    const BaseNow = "1700000000"
    proc launchArgs(leaseOut: string): seq[string] =
      @["launch",
        "--provider", "aws-ec2",
        "--region", "us-east-1",
        "--instance-name", "reproos-lease-probe",
        "--instance-shape", "m6a.2xlarge",
        "--image-reference", "ami-0fixture000000000",
        "--subnet", "subnet-0fixture000000000",
        "--ssh-key-reference", "reproos-lease-probe-key",
        "--firmware", gear.root / "firmware.bin",
        "--vcpu-type", "EPYC-Milan",
        "--guest-policy", "0x30000",
        "--guest-features", "0x21",
        "--config-fingerprint", "reproos-attested-uefi:cloud-lease",
        "--uki", gear.root / "uki.bin",
        "--verity-image-digest", "sha256:" & repeat('5', 64),
        "--verity-root-hash", repeat('4', 64),
        "--lease-store", gear.store.root,
        "--lease-ttl-seconds", "600",
        "--lease-rate-micros-per-hour", "3600000",
        "--now", BaseNow,
        "--lease-out", leaseOut]
    writeFile(gear.root / "firmware.bin", commandFirmware)
    writeFile(gear.root / "uki.bin", "not-a-real-unified-kernel-image")

    proc recordFor(args: seq[string]; at: string): CloudLease =
      check runAttestCommand(args) == AttestExitAccepted
      parseCloudLease(readFile(at), at)

    let basePath = gear.root / "base.lease"
    let base = recordFor(launchArgs(basePath), basePath)
    check base.region == "us-east-1"
    check base.instanceName == "reproos-lease-probe"
    check base.instanceShape == "m6a.2xlarge"
    check base.acquiredAtUnix == 1_700_000_000'i64
    check base.ttlSeconds == 600
    check base.expiresAtUnix == 1_700_000_600'i64
    check base.ratePerHourMicros == 3_600_000
    check base.state == clsIntended

    # Every probe: one flag, a declared set of fields that must move,
    # and the requirement that nothing else does. `clfLeaseId` is
    # excluded and asserted separately, because a fresh identifier on
    # every launch is the point of it.
    let probes = [
      ("--region", "us-west-2", {clfRegion}),
      ("--instance-name", "reproos-lease-probe-renamed",
       {clfInstanceName}),
      ("--instance-shape", "m6a.xlarge", {clfInstanceShape}),
      ("--lease-ttl-seconds", "1234", {clfTtlSeconds, clfExpiresAtUnix}),
      ("--lease-rate-micros-per-hour", "999", {clfRatePerHourMicros}),
      ("--now", "1700000123",
       {clfAcquiredAtUnix, clfExpiresAtUnix})]
    var identifiers = @[base.leaseId]
    var probed = 0
    for probe in probes:
      let path = gear.root / ("probe-" & $probed & ".lease")
      var args: seq[string] = @[]
      var replaced = 0
      let source = launchArgs(path)
      var i = 0
      while i < source.len:
        if source[i] == probe[0]:
          args.add source[i]
          args.add probe[1]
          inc replaced
          i += 2
        else:
          args.add source[i]
          inc i
      checkpoint(probe[0])
      # The probe reached the flag it meant to, so a flag renamed out
      # from under this list is red rather than silently unprobed.
      check replaced == 1
      check args.len == source.len
      let moved = recordFor(args, path)
      var observed: set[CloudLeaseField] = {}
      for f in CloudLeaseField:
        if f == clfLeaseId: continue
        if valueOf(moved, f) != valueOf(base, f): observed.incl f
      if observed != probe[2]:
        checkpoint("declared " & $probe[2] & " and moved " & $observed)
      check observed == probe[2]
      check moved.leaseId notin identifiers
      identifiers.add moved.leaseId
      inc probed
    check probed == 6
    check identifiers.len == 7

  test "the invocation the command PRINTS carries the lease's tags":
    # The repair for a row of this change's own mutation table that came
    # back GREEN: rendering a leased launch with the UNTAGGED plan was
    # invisible to every case here, because they all read the lease
    # RECORD and nothing read what the command actually printed. The
    # tags are the line of defence that survives losing the record, so a
    # command that silently dropped them would leave an instance no
    # sweep could ever find — and the record would have looked perfect.
    let gear = freshCase("printed-plan")
    writeFile(gear.root / "firmware.bin", commandFirmware)
    writeFile(gear.root / "uki.bin", "not-a-real-unified-kernel-image")
    let base = @["launch",
      "--provider", "aws-ec2",
      "--region", "us-east-1",
      "--instance-name", "reproos-lease-probe",
      "--instance-shape", "m6a.2xlarge",
      "--image-reference", "ami-0fixture000000000",
      "--subnet", "subnet-0fixture000000000",
      "--ssh-key-reference", "reproos-lease-probe-key",
      "--firmware", gear.root / "firmware.bin",
      "--vcpu-type", "EPYC-Milan",
      "--guest-policy", "0x30000",
      "--guest-features", "0x21",
      "--config-fingerprint", "reproos-attested-uefi:cloud-lease",
      "--uki", gear.root / "uki.bin",
      "--verity-image-digest", "sha256:" & repeat('5', 64),
      "--verity-root-hash", repeat('4', 64)]

    let leasePath = gear.root / "printed.lease"
    let leasedPlanPath = gear.root / "leased.plan"
    check runAttestCommand(base & @[
      "--lease-store", gear.store.root,
      "--lease-ttl-seconds", "600", "--now", "1700000000",
      "--lease-out", leasePath,
      "--plan-out", leasedPlanPath]) == AttestExitAccepted
    let lease = parseCloudLease(readFile(leasePath), leasePath)
    let leased = readFile(leasedPlanPath)
    var tagsFound = 0
    for tag in CloudLeaseTag:
      let spelling = "{Key=" & $tag & ",Value=" &
        leaseTagValue(lease, tag) & "}"
      if spelling notin leased:
        checkpoint($tag & " is not in the rendered invocation")
      check spelling in leased
      inc tagsFound
    check tagsFound == ord(high(CloudLeaseTag)) + 1
    # The tags went into the invocation's OWN tag argument rather than
    # beside it, so what was rendered is one request and not two.
    check leased.count("--tag-specifications") == 1
    # The control: the SAME command with no lease asked for renders a
    # plan carrying none of them, so the presences above are a reading
    # and not a property of every plan this command emits.
    let plainPath = gear.root / "plain.plan"
    check runAttestCommand(base & @["--plan-out", plainPath]) ==
      AttestExitAccepted
    let plain = readFile(plainPath)
    check "--tag-specifications" in plain
    for tag in CloudLeaseTag:
      check $tag notin plain
    check lease.leaseId notin plain

  test "a lease parameter does not reach the measurement identity":
    # The other half of the same claim: the record is sensitive to the
    # operational parameters and the manifest is not, and BOTH have to
    # hold or one of them is doing the other's job.
    let gear = freshCase("lease-vs-identity")
    writeFile(gear.root / "firmware.bin", commandFirmware)
    writeFile(gear.root / "uki.bin", "not-a-real-unified-kernel-image")
    proc manifestFor(ttl, rate, policy: string): string =
      let target = gear.root / ("m-" & ttl & "-" & rate & "-" & policy &
        ".json")
      check runAttestCommand(@["launch",
        "--provider", "aws-ec2",
        "--region", "us-east-1",
        "--instance-name", "reproos-lease-probe",
        "--instance-shape", "m6a.2xlarge",
        "--image-reference", "ami-0fixture000000000",
        "--subnet", "subnet-0fixture000000000",
        "--ssh-key-reference", "reproos-lease-probe-key",
        "--firmware", gear.root / "firmware.bin",
        "--vcpu-type", "EPYC-Milan",
        "--guest-policy", policy,
        "--guest-features", "0x21",
        "--config-fingerprint", "reproos-attested-uefi:cloud-lease",
        "--uki", gear.root / "uki.bin",
        "--verity-image-digest", "sha256:" & repeat('5', 64),
        "--verity-root-hash", repeat('4', 64),
        "--lease-store", gear.store.root,
        "--lease-ttl-seconds", ttl,
        "--lease-rate-micros-per-hour", rate,
        "--now", "1700000000",
        "--out", target]) == AttestExitAccepted
      readFile(target)
    check manifestFor("600", "0", "0x30000") ==
      manifestFor("1234", "999", "0x30000")
    # …and the control: a parameter that IS an input to the measurement
    # moves it, so the equality above is not two identical stubs.
    check manifestFor("600", "0", "0x30000") !=
      manifestFor("600", "0", "0x30001")

suite "a hold that never ends is not a hold this build grants":

  test "the never-expire policy is refused BY NAME":
    # The one thing a cloud lease does differently from the local lease
    # vocabulary it otherwise reuses. On a container `keep` is the
    # semantics a plain dependency already has; on a machine that bills
    # by the second it is an open-ended invoice.
    let store = freshCase("keep").store
    let e = refuses(proc () =
      discard acquireCloudLease(store, childSpec(), keep(),
        1_700_000_000'i64))
    check e.condition == cllPolicyWouldNeverExpire
    check $lkKeep in e.msg
    # …and the two policies that DO end are accepted, so the refusal is
    # about the deadline and not about policies.
    check acquireCloudLease(store, childSpec(), immediate(),
      1_700_000_000'i64).lease.ttlSeconds == 0
    check acquireCloudLease(store, childSpec(), delayed(seconds = 900),
      1_700_000_000'i64).lease.ttlSeconds == 900

  test "a hold longer than this build grants is refused":
    let store = freshCase("long").store
    let e = refuses(proc () =
      discard acquireCloudLease(store, childSpec(),
        delayed(seconds = 86_401), 1_700_000_000'i64))
    check e.condition == cllTtlIsLongerThanThisBuildWillGrant
    # The bound is pinned by a LITERAL as well as exercised at itself.
    # Written only in terms of the constant, halving the constant would
    # move both cases together and leave this green.
    check MaxLeaseTtlSeconds == 86_400
    check acquireCloudLease(store, childSpec(),
      delayed(seconds = 86_400), 1_700_000_000'i64).lease.ttlSeconds ==
      86_400
    check acquireCloudLease(store, childSpec(),
      delayed(seconds = 86_399), 1_700_000_000'i64).lease.ttlSeconds ==
      86_399

  test "the deadline comes from the shared vocabulary, not a second one":
    # A second policy-to-clock mapping would be a second answer to the
    # same question, and nobody would keep the two in step. So the
    # record's deadline is required to equal what the shared mapping
    # says, for every policy the shared mapping has.
    let now = 1_700_000_000'i64
    let store = freshCase("vocabulary").store
    for policy in [immediate(), delayed(seconds = 1),
                   delayed(minutes = 30), delayed(hours = 2)]:
      let lease = acquireCloudLease(store, childSpec(), policy, now).lease
      let shared = deadlineFrom(policy, fromUnix(now))
      check shared.isSome
      check lease.expiresAtUnix == shared.get.toUnix

suite "which leases are reapable, and when":

  test "the four decisions, each from a real lease":
    let store = freshCase("decisions").store
    let now = 1_700_000_000'i64
    let lease = acquireCloudLease(store, childSpec(),
      delayed(seconds = 600), now).lease
    check reapDecision(lease, now, olAlive) == rdHeld
    check reapDecision(lease, now + 599, olAlive) == rdHeld
    check reapDecision(lease, now + 600, olAlive) == rdExpired
    check reapDecision(lease, now, olDead) == rdOrphaned
    var destroyed = lease
    destroyed.state = clsDestroyed
    check reapDecision(destroyed, now, olDead) == rdAlreadyDestroyed

  test "a dead owner beats the deadline, and an unknowable one does not":
    # The economic rule, and the limit on it, asserted together because
    # separately either one reads as the whole answer.
    let store = freshCase("liveness-rule").store
    let now = 1_700_000_000'i64
    let lease = acquireCloudLease(store, childSpec(),
      delayed(hours = 1), now).lease
    check reapDecision(lease, now + 1, olDead) == rdOrphaned
    check reapDecision(lease, now + 1, olUnknowable) == rdHeld
    # …but an unknowable owner does not save it from the deadline
    # either, which is why the deadline is the tag that travels.
    check reapDecision(lease, now + 3_600, olUnknowable) == rdExpired
    check reapDecision(lease, now + 3_600, olAlive) == rdExpired

suite "the liveness probe answers about real processes":

  test "this process is alive, and the probe can say so":
    # The control. Without it every `olDead` below is satisfied by a
    # probe that says `olDead` to everything.
    let probe = processOwnerLiveness()
    let me = thisProcessOwner()
    if me.host.len == 0 or me.bootToken.len == 0 or me.startToken.len == 0:
      # This platform does not publish what the answer needs. The case
      # asserts THAT rather than a verdict it did not measure — and the
      # arm is reached through the same probe the cases below use.
      check probe(me) == olUnknowable
      checkpoint("this platform publishes no owner liveness source")
    else:
      check probe(me) == olAlive

  test "a killed process is DEAD, and a recycled number does not save it":
    let probe = processOwnerLiveness()
    let me = thisProcessOwner()
    if me.startToken.len == 0:
      check probe(me) == olUnknowable
      checkpoint("this platform publishes no process start token")
    else:
      let gear = freshCase("liveness-dead")
      let ready = gear.root / "ready"
      let child = startOwner("leak", gear.store, gear.provider, ready)
      check waitForFile(ready)
      let owner = ownerOf(theOnlyLease(gear.store))
      check probe(owner) == olAlive
      child.kill()
      discard child.waitForExit()
      child.close()
      check probe(owner) == olDead
      # And the shape a bare process number cannot survive: this
      # process's own number carried with somebody else's start token.
      var recycled = me
      recycled.startToken = me.startToken & "0"
      check probe(recycled) == olDead

  test "an owner on another host is UNKNOWABLE, not dead and not alive":
    let probe = processOwnerLiveness()
    var elsewhere = thisProcessOwner()
    elsewhere.host = "a-host-this-process-is-not-on"
    check probe(elsewhere) == olUnknowable
    # …and after a reboot the owner is dead whatever its number is now.
    var beforeReboot = thisProcessOwner()
    if beforeReboot.bootToken.len == 0:
      check probe(beforeReboot) == olUnknowable
    else:
      beforeReboot.bootToken = "00000000-0000-0000-0000-000000000000"
      check probe(beforeReboot) == olDead

suite "a leaked instance is reaped":

  test "an owner killed with SIGKILL loses its instance to the reaper":
    let gear = freshCase("leaked")
    let ready = gear.root / "ready"
    let child = startOwner("leak", gear.store, gear.provider, ready)
    check waitForFile(ready)

    # Control 1: there is something to reap. Without this line every
    # assertion below is satisfied by an instance that never existed.
    let created = liveInstances(gear.provider)
    check created.len == 1
    let lease = theOnlyLease(gear.store)
    check lease.state == clsCreated
    check lease.providerInstanceId == created[0]
    # The instance carries the lease's tags, read back off the instance
    # rather than off the plan — so a launch that rendered no tag is red
    # here and not only in the plan case below.
    check tagValueOf(gear.provider, created[0], $cltLeaseId) ==
      lease.leaseId
    check tagValueOf(gear.provider, created[0], $cltExpiresAt) ==
      $lease.expiresAtUnix

    # Control 2: the reaper leaves a LIVE owner's instance alone. A
    # reaper that destroyed everything it saw would pass the headline
    # measurement and be useless.
    let effector = fakeProviderEffector(gear.provider)
    let whileAlive = reapCloudLeases(gear.store, lease.acquiredAtUnix + 1,
      processOwnerLiveness(), effector, gear.ledger)
    check whileAlive.reaped == 0
    check whileAlive.held == 1
    check liveInstances(gear.provider) == created
    check listCloudLeases(gear.store).len == 1

    # The measurement. The owner is killed outright — no `finally`, no
    # exit procedure, no handler — and the reaper runs WELL INSIDE the
    # lease window, because a dead owner is not something to wait out.
    # `waitForExit` is what synchronises, and that is measured rather
    # than assumed: a polling "is it gone yet" helper used to sit here
    # too, and blinding it left this case GREEN — because the blocking
    # wait below already reaps the process before anything reads its
    # liveness. An instrument that cannot change the answer is not an
    # instrument, so it was removed rather than kept as decoration.
    child.kill()
    discard child.waitForExit()
    child.close()
    check liveInstances(gear.provider) == created

    let before = invocationCount(gear.provider)
    let report = reapCloudLeases(gear.store, lease.acquiredAtUnix + 1,
      processOwnerLiveness(), effector, gear.ledger)
    check report.reaped == 1
    check report.held == 0
    check report.failed == 0
    check report.events.len == 1
    check report.events[0].decision == rdOrphaned
    check report.events[0].outcome == roReaped
    check report.events[0].instanceIds == created
    # The instance is gone…
    check liveInstances(gear.provider).len == 0
    # …the effector was actually ASKED, so it is not gone for some other
    # reason…
    check invocationCount(gear.provider) > before
    check invocationsMentioning(gear.provider,
      "terminate-instances " & "--region " & childSpec().region) == 1
    # …the record is gone, so the next sweep does not try again…
    check listCloudLeases(gear.store).len == 0
    # …and the hold is written down in the ledger.
    check ledgerLines(gear.ledger).len == 1
    check lease.leaseId in ledgerLines(gear.ledger)[0]
    check "unpriced" in ledgerLines(gear.ledger)[0]
    requireReapSucceeded(report)

  test "a lease whose owner cannot be judged is reaped on its DEADLINE":
    # The other route to the same outcome, and the one a sweeper on
    # another machine has. Nothing here is killed; the lease simply runs
    # out, and the owner is an owner this host cannot ask about.
    let gear = freshCase("deadline")
    let effector = fakeProviderEffector(gear.provider)
    let now = 1_700_000_000'i64
    let holder = acquireCloudLease(gear.store, childSpec(),
      delayed(seconds = 600), now, 0, effector, gear.ledger)
    let created = effector(CloudEffect(
      argv: leasedLaunchPlan(childSpec(), holder.lease, fixedEnvLookup([])),
      providerEnvNames: providerEnvNamesFor(cpAwsEc2)))
    holder.recordInstanceCreated(created.output.strip())
    check liveInstances(gear.provider).len == 1

    let elsewhere = fixedOwnerLiveness(olUnknowable)
    let early = reapCloudLeases(gear.store, now + 599, elsewhere, effector,
      gear.ledger)
    check early.held == 1
    check early.reaped == 0
    check liveInstances(gear.provider).len == 1

    let late = reapCloudLeases(gear.store, now + 600, elsewhere, effector,
      gear.ledger)
    check late.reaped == 1
    check late.events[0].decision == rdExpired
    check liveInstances(gear.provider).len == 0
    check ledgerLines(gear.ledger).len == 1

suite "the window between asking for an instance and being told its name":

  test "an owner killed mid-flight leaves an instance found by TAG":
    let gear = freshCase("midflight")
    let ready = gear.root / "ready"
    let child = startOwner("leak-midflight", gear.store, gear.provider,
      ready)
    check waitForFile(ready)
    discard child.waitForExit()
    child.close()

    # The state this window leaves behind: an instance exists, and the
    # record does not know its name.
    let created = liveInstances(gear.provider)
    check created.len == 1
    let lease = theOnlyLease(gear.store)
    check lease.state == clsIntended
    check lease.providerInstanceId == ""

    let effector = fakeProviderEffector(gear.provider)
    let report = reapCloudLeases(gear.store, lease.acquiredAtUnix + 1,
      processOwnerLiveness(), effector, gear.ledger)
    check report.reaped == 1
    check report.events[0].instanceIds == created
    check liveInstances(gear.provider).len == 0
    # It went and LOOKED, rather than assuming either way — which is
    # the whole reason the record is written before the create request.
    check invocationsMentioning(gear.provider, "describe-instances") == 1
    check invocationsMentioning(gear.provider,
      "Name=tag:" & $cltLeaseId & ",Values=" & lease.leaseId) == 1

  test "an empty answer is an empty answer and not a machine called None":
    # One of these providers writes that word where the other writes
    # nothing. A reaper that took it for an identifier would issue a
    # destroy for it, so the case asserts the outcome AND that no
    # destroy was attempted.
    let gear = freshCase("none")
    let effector = fakeProviderEffector(gear.provider)
    let now = 1_700_000_000'i64
    discard acquireCloudLease(gear.store, childSpec(),
      delayed(seconds = 1), now, 0, effector, gear.ledger)
    let report = reapCloudLeases(gear.store, now + 60,
      fixedOwnerLiveness(olUnknowable), effector, gear.ledger)
    check report.reaped == 0
    check report.nothingToDestroy == 1
    check report.events[0].instanceIds.len == 0
    check invocationsMentioning(gear.provider, "terminate-instances") == 0
    check listCloudLeases(gear.store).len == 0
    check parseTaggedInstances("None\n").len == 0

suite "the store is a cache; the tags are the authority":

  test "the whole store is DELETED and the instance is still reaped":
    let gear = freshCase("storeless")
    let effector = fakeProviderEffector(gear.provider)
    let now = 1_700_000_000'i64
    let holder = acquireCloudLease(gear.store, childSpec(),
      delayed(seconds = 600), now, 0, effector, gear.ledger)
    let created = effector(CloudEffect(
      argv: leasedLaunchPlan(childSpec(), holder.lease, fixedEnvLookup([])),
      providerEnvNames: providerEnvNamesFor(cpAwsEc2)))
    holder.recordInstanceCreated(created.output.strip())
    check liveInstances(gear.provider).len == 1

    # Not simulated. The directory the record-driven reaper depends on
    # is removed, and the record-driven reaper is then asked and finds
    # nothing — which is the failure the tag sweep exists to cover.
    removeDir(gear.store.root)
    check not dirExists(gear.store.root)
    let blind = reapCloudLeases(gear.store, now + 6_000,
      processOwnerLiveness(), effector, gear.ledger)
    check blind.events.len == 0
    check liveInstances(gear.provider).len == 1

    # The sweep that never opens the store. Before the deadline it
    # leaves the instance alone…
    let early = reapExpiredByTag(cpAwsEc2, childSpec().region, now + 599,
      effector)
    check early.reaped == 0
    check early.nothingToDestroy == 1
    check liveInstances(gear.provider).len == 1
    # …and after it, it does not.
    let late = reapExpiredByTag(cpAwsEc2, childSpec().region, now + 600,
      effector)
    check late.reaped == 1
    check liveInstances(gear.provider).len == 0

  test "an instance carrying no lease tag is not swept, and that is a LIMIT":
    # The sweep is keyed on the tag, so an instance without one is
    # invisible to it. Said out loud with a case rather than left for
    # somebody to discover: this is why the tag goes on at launch and
    # why a plan that carries none is a defect rather than a cosmetic
    # difference.
    let gear = freshCase("untagged")
    let effector = fakeProviderEffector(gear.provider)
    # An untagged instance, created through the UNTAGGED plan — the one
    # the launch command renders when no lease is asked for.
    discard effector(CloudEffect(
      argv: checkedCloudLaunchPlan(childSpec(), fixedEnvLookup([])),
      providerEnvNames: providerEnvNamesFor(cpAwsEc2)))
    check liveInstances(gear.provider).len == 1
    let report = reapExpiredByTag(cpAwsEc2, childSpec().region,
      2_000_000_000'i64, effector)
    check report.reaped == 0
    check liveInstances(gear.provider).len == 1

  test "the listing reader refuses to guess":
    check parseTaggedInstances("i-1\trl-a\t1700000000\n").len == 1
    check parseTaggedInstances("i-1\trl-a\n").len == 0
    check parseTaggedInstances("i-1\trl-a\tnot-a-number\n").len == 0
    check parseTaggedInstances("").len == 0
    let all = @[TaggedInstance(id: "i-1", leaseId: "a", expiresAtUnix: 10),
                TaggedInstance(id: "i-2", leaseId: "b", expiresAtUnix: 20)]
    check expiredTaggedInstances(all, 9).len == 0
    check expiredTaggedInstances(all, 10).len == 1
    check expiredTaggedInstances(all, 20).len == 2

suite "a failing destroy is not swallowed":

  test "the sweep completes, the record stays, and the failure refuses":
    let gear = freshCase("failing")
    let effector = fakeProviderEffector(gear.provider)
    let now = 1_700_000_000'i64
    var leaseIds: seq[string] = @[]
    for i in 0 .. 1:
      var spec = childSpec()
      spec.instanceName = "reproos-lease-probe-" & $i
      let holder = acquireCloudLease(gear.store, spec,
        delayed(seconds = 1), now + i, 0, effector, gear.ledger)
      let created = effector(CloudEffect(
        argv: leasedLaunchPlan(spec, holder.lease, fixedEnvLookup([])),
        providerEnvNames: providerEnvNamesFor(cpAwsEc2)))
      holder.recordInstanceCreated(created.output.strip())
      leaseIds.add holder.lease.leaseId
    check liveInstances(gear.provider).len == 2

    setFailureMode(gear.provider, ffmDestroyFails)
    let report = reapCloudLeases(gear.store, now + 600,
      fixedOwnerLiveness(olUnknowable), effector, gear.ledger)
    # Both were TRIED — a sweep that stopped at the first refusal would
    # leave everything after it running.
    check report.failed == 2
    check report.reaped == 0
    check invocationsMentioning(gear.provider, "terminate-instances") == 2
    # Both records are still there, so the next sweep tries again.
    check listCloudLeases(gear.store).len == 2
    check liveInstances(gear.provider).len == 2
    check ledgerLines(gear.ledger).len == 0
    let e = refuses(proc () = requireReapSucceeded(report))
    check e.condition == cllDestroyInvocationFailed
    for id in leaseIds: check id in e.msg

    # The control: with the failure mode off, the same sweep succeeds —
    # so the refusal above is about the destroy and not about the state
    # of this store.
    setFailureMode(gear.provider, ffmNone)
    let retry = reapCloudLeases(gear.store, now + 600,
      fixedOwnerLiveness(olUnknowable), effector, gear.ledger)
    check retry.reaped == 2
    check retry.failed == 0
    check liveInstances(gear.provider).len == 0
    requireReapSucceeded(retry)

  test "a failing LIST does not read as an empty cloud":
    # The dangerous shape: a query that failed and a query that matched
    # nothing look the same to anything that reads only the output.
    let gear = freshCase("failing-list")
    let effector = fakeProviderEffector(gear.provider)
    let now = 1_700_000_000'i64
    discard acquireCloudLease(gear.store, childSpec(),
      delayed(seconds = 1), now, 0, effector, gear.ledger)
    setFailureMode(gear.provider, ffmListFails)
    let report = reapCloudLeases(gear.store, now + 600,
      fixedOwnerLiveness(olUnknowable), effector, gear.ledger)
    check report.failed == 1
    check report.nothingToDestroy == 0
    # The record stays, because nothing here established that there was
    # nothing to destroy.
    check listCloudLeases(gear.store).len == 1
    let swept = reapExpiredByTag(cpAwsEc2, childSpec().region, now + 600,
      effector)
    check swept.failed == 1
    check swept.reaped == 0

suite "metering":

  test "a hold is counted in seconds, and priced only if a rate was given":
    let store = freshCase("metering").store
    let now = 1_700_000_000'i64
    let free = acquireCloudLease(store, childSpec(),
      delayed(seconds = 600), now).lease
    check leasedSecondsOf(free, now + 300) == 300
    check isPriced(free) == false
    check costMicrosOf(free, now + 300) == 0

    var spec = childSpec()
    spec.instanceName = "reproos-lease-probe-priced"
    let priced = acquireCloudLease(store, spec,
      delayed(seconds = 600), now, 3_600_000).lease
    check isPriced(priced)
    # A rate of 3,600,000 millionths an hour is 1,000 an hour, so an
    # hour's hold costs 3,600,000 and a minute's costs 60,000.
    check costMicrosOf(priced, now + 3_600) == 3_600_000
    check costMicrosOf(priced, now + 60) == 60_000

  test "two leases taken in one second are two leases":
    # Found by the case below failing rather than by inspection: written
    # as second-and-process alone, the identifier collided and the
    # SECOND record overwrote the first — which deletes the only local
    # knowledge of a machine that is already running. Asserted here on
    # its own so the arithmetic case below is not the thing guarding it.
    let gear = freshCase("distinct-ids")
    let now = 1_700_000_000'i64
    var ids: seq[string] = @[]
    for i in 0 .. 7:
      var spec = childSpec()
      spec.instanceName = "reproos-lease-probe-" & $i
      ids.add acquireCloudLease(gear.store, spec,
        delayed(seconds = 600), now).lease.leaseId
    var unique: seq[string] = @[]
    for id in ids:
      if id notin unique: unique.add id
    check unique.len == 8
    check listCloudLeases(gear.store).len == 8
    # …and every one of them is spelled in the character set a provider
    # will accept as a label value.
    for id in ids:
      for c in id: check c in SafeLaunchValueChars

  test "what is standing right now is a question that destroys nothing":
    let gear = freshCase("exposure")
    let now = 1_700_000_000'i64
    discard acquireCloudLease(gear.store, childSpec(),
      delayed(seconds = 600), now, 3_600_000)
    var spec = childSpec()
    spec.instanceName = "reproos-lease-probe-second"
    discard acquireCloudLease(gear.store, spec, delayed(seconds = 600),
      now, 0)
    let exposure = outstandingExposure(gear.store, now + 1_800)
    check exposure.leases == 2
    check exposure.leasedSeconds == 3_600
    check exposure.costMicros == 1_800_000
    check exposure.unpriced == 1
    # Nothing was reached, and nothing was removed.
    check invocationCount(gear.provider) == 0
    check listCloudLeases(gear.store).len == 2

  test "a closed hold is written down where the record is not":
    # The record is REMOVED when a lease closes, so metering that lived
    # in it would be deleted at the moment it became the answer.
    let gear = freshCase("ledger")
    let effector = fakeProviderEffector(gear.provider)
    let now = 1_700_000_000'i64
    let holder = acquireCloudLease(gear.store, childSpec(),
      delayed(seconds = 600), now, 3_600_000, effector, gear.ledger)
    let created = effector(CloudEffect(
      argv: leasedLaunchPlan(childSpec(), holder.lease, fixedEnvLookup([])),
      providerEnvNames: providerEnvNamesFor(cpAwsEc2)))
    holder.recordInstanceCreated(created.output.strip())
    discard reapCloudLeases(gear.store, now + 600,
      fixedOwnerLiveness(olUnknowable), effector, gear.ledger)
    check listCloudLeases(gear.store).len == 0
    let lines = ledgerLines(gear.ledger)
    check lines.len == 1
    let cols = lines[0].splitWhitespace()
    check cols[0] == holder.lease.leaseId
    check cols[1] == $cpAwsEc2
    check cols[2] == childSpec().region
    check cols[6] == "600"
    check cols[8] == "600000"
    check "unpriced" notin lines[0]

suite "the invocations, and what they carry":

  test "a leased plan is the launch plan plus the lease's tags":
    let store = freshCase("tagged-plan").store
    let spec = childSpec()
    let lease = acquireCloudLease(store, spec, delayed(seconds = 600),
      1_700_000_000'i64).lease
    let plain = checkedCloudLaunchPlan(spec, fixedEnvLookup([]))
    let tagged = leasedLaunchPlan(spec, lease, fixedEnvLookup([]))
    # Same length, one argument different: the tag specification. A
    # second renderer would be a second answer to what a launch is.
    check tagged.len == plain.len
    var differing = 0
    for i in 0 ..< plain.len:
      if plain[i] != tagged[i]: inc differing
    check differing == 1
    let joined = tagged.join(" ")
    var tagsFound = 0
    for tag in CloudLeaseTag:
      check ("{Key=" & $tag & ",Value=" & leaseTagValue(lease, tag) & "}") in
        joined
      inc tagsFound
    check tagsFound == 3
    check tagsFound == ord(high(CloudLeaseTag)) + 1
    # The instance's own name survives the rewrite.
    check ("{Key=Name,Value=" & spec.instanceName & "}") in joined

  test "the other cloud's plan carries the same tags in its own grammar":
    # Both clouds, so the tagging is a property of the substrate and not
    # of the one the rest of this gate happens to drive.
    let store = freshCase("gcp-plan").store
    var spec = childSpec()
    spec.provider = cpGcpCompute
    spec.region = "us-central1-a"
    spec.instanceShape = "n2d-standard-4"
    spec.imageReference = "projects/a-project/global/images/reproos"
    spec.subnet = "default"
    spec.sshKeyReference = "/tmp/ssh-keys.txt"
    let lease = acquireCloudLease(store, spec, delayed(seconds = 600),
      1_700_000_000'i64).lease
    let tagged = leasedLaunchPlan(spec, lease, fixedEnvLookup([]))
    check "--labels" in tagged
    let labels = tagged[tagged.find("--labels") + 1]
    for tag in CloudLeaseTag:
      check ($tag & "=" & leaseTagValue(lease, tag)) in labels
    check destroyPlanFor(lease, "reproos-1")[0 .. 3] ==
      @["gcloud", "compute", "instances", "delete"]
    check "--zone" in destroyPlanFor(lease, "reproos-1")
    check spec.region in destroyPlanFor(lease, "reproos-1")

  test "the owner tag is the process, NOT the host, and that is a limit":
    # Both providers constrain a label to a short run of characters a
    # host name does not reliably fit, and a sweeper on another host
    # could not read that host's process table anyway. So the tag that
    # carries the guarantee is the deadline, and this case pins which
    # is which rather than leaving it to the comment.
    let store = freshCase("owner-tag").store
    var spec = childSpec()
    let lease = acquireCloudLease(store, spec, delayed(seconds = 600),
      1_700_000_000'i64).lease
    check leaseTagValue(lease, cltExpiresAt) == $lease.expiresAtUnix
    check leaseTagValue(lease, cltLeaseId) == lease.leaseId
    check leaseTagValue(lease, cltOwner) ==
      $lease.ownerPid & "-" & lease.ownerStartToken
    if lease.ownerHost.len > 0:
      check lease.ownerHost notin leaseTagValue(lease, cltOwner)
    for tag in CloudLeaseTag:
      for c in leaseTagValue(lease, tag):
        check c in SafeLaunchValueChars

suite "the rules this substrate refuses on":

  test "every refusal has an input, and the count is an EQUALITY":
    var reached: set[CloudLeaseCondition] = {}
    let gear = freshCase("census")
    let now = 1_700_000_000'i64

    block:
      let e = refuses(proc () =
        discard acquireCloudLease(gear.store, childSpec(), keep(), now))
      check e.condition == cllPolicyWouldNeverExpire
      reached.incl e.condition

    block:
      let e = refuses(proc () =
        discard acquireCloudLease(gear.store, childSpec(),
          delayed(seconds = MaxLeaseTtlSeconds + 1), now))
      check e.condition == cllTtlIsLongerThanThisBuildWillGrant
      reached.incl e.condition

    block:
      var spec = childSpec()
      spec.region = "us-east-1\rownerPid=1"
      let e = refuses(proc () =
        discard acquireCloudLease(gear.store, spec,
          delayed(seconds = 600), now))
      check e.condition == cllValueCarriesACharacterTheRecordCannotHold
      reached.incl e.condition

    block:
      let e = refuses(proc () = discard parseCloudLease("", "probe"))
      check e.condition == cllRecordIsNotOfThisFormat
      reached.incl e.condition

    block:
      let e = refuses(proc () =
        discard parseCloudLease(RecordMagic & "\n", "probe"))
      check e.condition == cllRecordDoesNotCarryEveryField
      reached.incl e.condition

    block:
      let good = renderCloudLease(acquireCloudLease(gear.store,
        childSpec(), delayed(seconds = 600), now).lease)
      let e = refuses(proc () =
        discard parseCloudLease(good & $clfLeaseId & "=again\n", "probe"))
      check e.condition == cllRecordCarriesAFieldTwice
      reached.incl e.condition

    block:
      # A reap with no effector. This build ships none, so this is the
      # arm every caller outside a gate reaches.
      let solo = freshCase("no-effector")
      discard acquireCloudLease(solo.store, childSpec(),
        delayed(seconds = 1), now)
      let e = refuses(proc () =
        discard reapCloudLeases(solo.store, now + 600,
          fixedOwnerLiveness(olDead), nil, solo.ledger))
      check e.condition == cllReapHasNoEffector
      reached.incl e.condition
      # …and the tag sweep refuses at the same rule, from the same site.
      let f = refuses(proc () =
        discard reapExpiredByTag(cpAwsEc2, "us-east-1", now, nil))
      check f.condition == cllReapHasNoEffector

    block:
      let failing = freshCase("census-destroy")
      let effector = fakeProviderEffector(failing.provider)
      let holder = acquireCloudLease(failing.store, childSpec(),
        delayed(seconds = 1), now, 0, effector, failing.ledger)
      let created = effector(CloudEffect(
        argv: leasedLaunchPlan(childSpec(), holder.lease,
          fixedEnvLookup([])),
        providerEnvNames: providerEnvNamesFor(cpAwsEc2)))
      holder.recordInstanceCreated(created.output.strip())
      setFailureMode(failing.provider, ffmDestroyFails)
      let report = reapCloudLeases(failing.store, now + 600,
        fixedOwnerLiveness(olDead), effector, failing.ledger)
      let e = refuses(proc () = requireReapSucceeded(report))
      check e.condition == cllDestroyInvocationFailed
      reached.incl e.condition

    var missing: seq[string] = @[]
    for c in CloudLeaseCondition:
      if c notin reached: missing.add $c
    check missing == newSeq[string]()
    var count = 0
    for c in CloudLeaseCondition:
      if c in reached: inc count
    check count == 8
    check count == ord(high(CloudLeaseCondition)) + 1

  test "every rule has a site, and every site has exactly one rule":
    # The static half, which is what makes the census above a census
    # over SITES rather than over kinds: a kind raised from two places
    # and a kind reached from none cancel out in a census over kinds.
    const Source = staticRead(
      "../../libs/repro_attest/src/repro_attest/cloud_lease.nim")
    var found: seq[string] = @[]
    var i = 0
    const Needle = "leaseFail(cll"
    while i < Source.len:
      let at = Source.find(Needle, i)
      if at < 0: break
      var j = at + len("leaseFail(")
      var name = ""
      while j < Source.len and
            (Source[j].isAlphaAscii or Source[j].isDigit):
        name.add Source[j]
        inc j
      found.add name
      i = j
    check found.len == 8
    check found.len == ord(high(CloudLeaseCondition)) + 1
    for c in CloudLeaseCondition:
      var seen = 0
      for n in found:
        if n == $c: inc seen
      if seen != 1:
        checkpoint($c & " is raised at " & $seen & " site(s)")
      check seen == 1

suite "this build reaps nothing by itself":

  test "no source under libs or apps drives the reaper":
    # Symmetric with the launch side: the procedures that would destroy
    # something exist, take an effector, and are called from nowhere in
    # the shipped tree.
    #
    # The sweep and its control go through ONE reader, and that is the
    # repair for a row of this change's own mutation table that came
    # back GREEN. Written with the counting inlined in the loop and the
    # control calling `count` directly, the two were different
    # expressions: blinding the LOOP left the control reading its own
    # source and passing, so the instrument was never falsified at all.
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    var scanned = 0
    var sweepSites = 0
    var tagSweepSites = 0
    for root in ["libs", "apps"]:
      for path in walkDirRec(repoRoot / root):
        if not path.endsWith(".nim"): continue
        inc scanned
        if path.endsWith("cloud_lease.nim"): continue
        let found = reaperCallSitesIn(path)
        sweepSites += found.sweep
        tagSweepSites += found.tagSweep
    check scanned > 1000
    check sweepSites == 0
    check tagSweepSites == 0
    # The control: the SAME reader, over a file that HAS both — this
    # one — returns non-zero, so the two zeroes are measurements.
    let control = reaperCallSitesIn(currentSourcePath())
    check control.sweep >= 4
    check control.tagSweep >= 3
    # …and it is a substring count, so a needle that occurs nowhere
    # returns zero from the same reader that returns non-zero above.
    check occurrencesOf(currentSourcePath(),
      "reapCloudLeases" & "NoSuch" & "Procedure(") == 0

  test "the command prints a sweep and runs no provider tool":
    let gear = freshCase("command-reap")
    let now = 1_700_000_000'i64
    let holder = acquireCloudLease(gear.store, childSpec(),
      delayed(seconds = 600), now, 3_600_000)
    holder.recordInstanceCreated("i-command-probe")
    # Shims named after every program that could reach a cloud from
    # here, with the control that one of them records when it is run.
    let shimDir = gear.root / "shims"
    createDir(shimDir)
    let shimLog = gear.root / "shim.log"
    for tool in ["aws", "gcloud", "az", "terraform", "tofu", "curl"]:
      writeFile(shimDir / tool, "#!/bin/sh\necho ran >> " & shimLog & "\n")
      setFilePermissions(shimDir / tool,
        {fpUserRead, fpUserWrite, fpUserExec})
    let savedPath = getEnv("PATH")
    var code = 0
    try:
      putEnv("PATH", shimDir & ":" & savedPath)
      check execShellCmd("aws ec2 describe-instances") == 0
      check fileExists(shimLog)          # the control fired
      removeFile(shimLog)
      code = runAttestCommand(@["reap", "--lease-store", gear.store.root,
        "--now", $(now + 6_000)])
    finally:
      putEnv("PATH", savedPath)
    check code == AttestExitAccepted
    check not fileExists(shimLog)
    # …and the record is untouched, so printing a sweep is not a sweep.
    check listCloudLeases(gear.store).len == 1

  test "the printed sweep says what it would do and what it costs":
    let gear = freshCase("reap-text")
    let now = 1_700_000_000'i64
    let holder = acquireCloudLease(gear.store, childSpec(),
      delayed(seconds = 600), now, 3_600_000)
    holder.recordInstanceCreated("i-printed-probe")
    let text = renderReapPlanText(gear.store, now + 6_000,
      fixedOwnerLiveness(olUnknowable))
    check ("lease: " & holder.lease.leaseId) in text
    check "decision: rdExpired" in text
    check "leased-seconds: 6000" in text
    check "cost-micros: 6000000" in text
    check "i-printed-probe" in text
    check "terminate-instances" in text
    check "reapable-now: 1" in text
    # …and before the deadline the same store prints the other answer,
    # so the strings above are a reading and not a template.
    let held = renderReapPlanText(gear.store, now + 1,
      fixedOwnerLiveness(olUnknowable))
    check "decision: rdHeld" in held
    check "reapable-now: 0" in held
    check "terminate-instances" notin held

  test "a store with nothing in it is not an error":
    let gear = freshCase("empty-store")
    check runAttestCommand(@["reap", "--lease-store", gear.store.root]) ==
      AttestExitAccepted
    # …and a store that is not there IS, because a sweep that silently
    # scanned nothing is indistinguishable from one that found nothing.
    check runAttestCommand(@["reap", "--lease-store",
      gear.root / "no-such-store"]) == AttestExitUsage
    check runAttestCommand(@["reap"]) == AttestExitUsage

suite "teardown":

  test "every child this gate started is gone":
    # A gate about not leaking processes must not leak processes. The
    # children are all killed and waited for in their own cases; this
    # asserts the scratch tree is the only thing left, and removes it.
    removeDir(scratch)
    check not dirExists(scratch)
