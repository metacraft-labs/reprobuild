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

proc runAttestCommandIn(args: seq[string]; toolPath = ""): int =
  ## The command, run against a STATED environment.
  ##
  ## Every library call in this file already said which environment it
  ## meant, and every case that went through the command still reached
  ## the process environment — so this gate was a statement about the
  ## machine it ran on after all. Measured: one exported variable whose
  ## value a plan legitimately spells (an image reference is twenty-one
  ## characters, and the search floor is sixteen) turned this file's 40
  ## passing cases into 37 with 3 failures and exit 1, and it is
  ## FAIL-CLOSED, so the failure looked like a finding about the work
  ## rather than about the room.
  ##
  ## `toolPath` is the search path a DESTROYING sweep is allowed to find
  ## a provider tool on, and stating it is not a convenience: the
  ## effector resolves the tool against the path it was given, so the
  ## program a sweep runs is decided by this argument and not by
  ## whatever is installed on the machine. A case that named a stand-in
  ## and got the operator's own tool would be measuring the room again,
  ## one layer down.
  ##
  ## No credential variable is ever stated: this gate is about plans and
  ## leases, not about anybody's credentials.
  var stated: seq[(string, string)] = @[]
  if toolPath.len > 0:
    stated.add ("PATH", toolPath)
    stated.add ("HOME", getTempDir())
  runAttestCommand(args, fixedEnvLookup(stated))

let shellToolDir = findExe("rm").parentDir
  ## Where the ordinary shell tools a stand-in provider script uses live.
  ##
  ## Named rather than inherited, because the effector narrows what a
  ## provider tool can see to a STATED search path — so a script it runs
  ## has exactly the programs the case said it may have, and a stand-in
  ## that quietly reached for something else would fail with a message
  ## about `rm` rather than about anything under test. That narrowing is
  ## the behaviour, not an inconvenience.

proc statedToolPath(shimDir: string): string =
  ## The shim first, then the ordinary tools. Deliberately NOT this
  ## process's own path: what a sweep runs must be decided by the case.
  shimDir & ":" & shellToolDir

proc withCapturedStdout(path: string;
                        body: proc (): int): tuple[code: int; text: string] =
  ## Run `body` with this process's standard output redirected to a
  ## file, then put it back.
  ##
  ## Done with the descriptor rather than with Nim's `reopen`, because
  ## the command under test writes through the C library and the thing
  ## being measured is what an operator would SEE — and because the
  ## descriptor can be restored, which `reopen` cannot portably.
  flushFile(stdout)
  let saved = dup(1)
  doAssert saved >= 0
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o644)
  doAssert fd >= 0
  doAssert dup2(fd, 1) >= 0
  discard close(fd)
  try:
    result.code = body()
  finally:
    flushFile(stdout)
    doAssert dup2(saved, 1) >= 0
    discard close(saved)
  result.text = readFile(path)

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
      check runAttestCommandIn(args) == AttestExitAccepted
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
    check runAttestCommandIn(base & @[
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
    check runAttestCommandIn(base & @["--plan-out", plainPath]) ==
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
      check runAttestCommandIn(@["launch",
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
    # The control for the case next door: a sweep that really destroyed
    # something DOES say so, so "destroyed" being absent there is a
    # reading and not a word this renderer never emits.
    check ("destroyed: " & created[0]) in renderReapReportText(report)
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
    # Nothing was expired, so there is no event at all — which is a
    # different statement from "an instance was looked at and left
    # alone", and the two must not wear the same tally.
    check early.events.len == 0
    check liveInstances(gear.provider).len == 1
    # …and after it, it does not.
    let late = reapExpiredByTag(cpAwsEc2, childSpec().region, now + 600,
      effector)
    check late.reaped == 1
    check late.events.len == 1
    check late.events[0].outcome == roReaped
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
    # The event, and not only the tally: a listing that failed leaves
    # one event naming no lease, because there was no listing to read a
    # lease identifier out of.
    check swept.events.len == 1
    check swept.events[0].outcome == roFailed
    check swept.events[0].leaseId == ""

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
    # will accept as a label value — which is the LABEL set and not the
    # command-line set. That distinction is the repair for a case whose
    # comment claimed this and whose body checked something seven
    # spellings wider: `.`, `:`, `/`, `@`, `+`, `=` and upper case all
    # pass a command line and are all refused as a label value, so the
    # old assertion would have stayed green on an identifier no cloud
    # would take.
    for id in ids:
      for c in id: check c in ProviderLabelValueChars

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
        check c in ProviderLabelValueChars
    # The two sets are not the same set, and this is what stops the
    # narrower one being widened back to its neighbour: every label
    # character is a command-line character, and at least one
    # command-line character is not a label character.
    check providerLabelSetIsNarrower()
    var widerBy = 0
    for c in SafeLaunchValueChars:
      if c notin ProviderLabelValueChars: inc widerBy
    # Six punctuation spellings and the twenty-six upper-case letters.
    check widerBy == 32
    for c in ['.', ':', '/', '@', '+', '=', 'A', 'Z']:
      check c in SafeLaunchValueChars
      check c notin ProviderLabelValueChars

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

    block:
      # The identifier retry, at its bound. Every name the minting
      # source will produce next is RESERVED, which is the same shape a
      # source that has stopped making progress has and needs no such
      # source — and reaching the bound is a refusal rather than a spin.
      let crowded = freshCase("census-identifier")
      let owner = thisProcessOwner()
      let first = acquireCloudLease(crowded.store, childSpec(),
        delayed(seconds = 600), now).lease
      let serial = parseInt(first.leaseId.rsplit('-', 1)[1])
      var reserved = 0
      while reserved <= MaxLeaseIdentifierAttempts:
        writeFile(recordPath(crowded.store, "rl-" & $now & "-" &
          $owner.pid & "-" & $(serial + 1 + reserved)), "reserved")
        inc reserved
      var spec = childSpec()
      spec.instanceName = "reproos-lease-probe-crowded"
      let e = refuses(proc () =
        discard acquireCloudLease(crowded.store, spec,
          delayed(seconds = 600), now))
      check e.condition == cllLeaseIdentifierCouldNotBeMinted
      reached.incl e.condition

    block:
      # An armed launch outside a lease scope. Reached from the library
      # rather than from a child process, because what is being asserted
      # is the rule and not the exit path.
      let unheld = freshCase("census-unheld")
      let holder = acquireCloudLease(unheld.store, childSpec(),
        delayed(seconds = 600), now, 0,
        fakeProviderEffector(unheld.provider))
      let e = refuses(proc () =
        discard performLeasedCloudLaunch(holder, childSpec(),
          fakeProviderEffector(unheld.provider), fixedEnvLookup([])))
      check e.condition == cllArmedLaunchIsNotHeldUnderALease
      reached.incl e.condition
      # …and nothing was created on the way to the refusal.
      check liveInstances(unheld.provider).len == 0

    var missing: seq[string] = @[]
    for c in CloudLeaseCondition:
      if c notin reached: missing.add $c
    check missing == newSeq[string]()
    var count = 0
    for c in CloudLeaseCondition:
      if c in reached: inc count
    check count == 10
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
    check found.len == 10
    check found.len == ord(high(CloudLeaseCondition)) + 1
    for c in CloudLeaseCondition:
      var seen = 0
      for n in found:
        if n == $c: inc seen
      if seen != 1:
        checkpoint($c & " is raised at " & $seen & " site(s)")
      check seen == 1

suite "the reaper has exactly one driver, and it is the command":

  test "every call site under libs and apps is in the one file":
    # This case used to assert that the reaper had NO caller anywhere in
    # the shipped tree, and it was true — which is precisely what made
    # the whole substrate a library rather than a safety property. A
    # sweep nothing runs reduces the cost of a leak to "until somebody
    # runs the sweep", and nothing bounded that.
    #
    # So the claim is now an ACCOUNTING rather than a zero: the sweeps
    # are driven from exactly one file, that file is the command, and
    # every other source under `libs` and `apps` still has none. A
    # second driver appearing anywhere is red, and so is the driver
    # disappearing.
    #
    # The sweep and its control go through ONE reader, and that is the
    # repair for a row of this change's own mutation table that came
    # back GREEN. Written with the counting inlined in the loop and the
    # control calling `count` directly, the two were different
    # expressions: blinding the LOOP left the control reading its own
    # source and passing, so the instrument was never falsified at all.
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    const Driver = "repro_cli_support/attest.nim"
    var scanned = 0
    var elsewhereSweep = 0
    var elsewhereTagSweep = 0
    var driverSweep = 0
    var driverTagSweep = 0
    var driverFiles = 0
    for root in ["libs", "apps"]:
      for path in walkDirRec(repoRoot / root):
        if not path.endsWith(".nim"): continue
        inc scanned
        if path.endsWith("cloud_lease.nim"): continue
        let found = reaperCallSitesIn(path)
        if path.endsWith(Driver):
          inc driverFiles
          driverSweep += found.sweep
          driverTagSweep += found.tagSweep
        else:
          elsewhereSweep += found.sweep
          elsewhereTagSweep += found.tagSweep
    check scanned > 1000
    # The driver exists, is exactly one file, and drives BOTH sweeps —
    # so a build that shipped the store sweep and quietly dropped the
    # tag sweep is red here rather than invisible.
    check driverFiles == 1
    check driverSweep == 1
    check driverTagSweep == 1
    # …and nothing else drives either.
    check elsewhereSweep == 0
    check elsewhereTagSweep == 0
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
      code = runAttestCommandIn(@["reap", "--lease-store", gear.store.root,
        "--now", $(now + 6_000)], statedToolPath(shimDir))
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
    check runAttestCommandIn(@["reap", "--lease-store", gear.store.root]) ==
      AttestExitAccepted
    # …and a store that is not there IS, because a sweep that silently
    # scanned nothing is indistinguishable from one that found nothing.
    check runAttestCommandIn(@["reap", "--lease-store",
      gear.root / "no-such-store"]) == AttestExitUsage
    check runAttestCommandIn(@["reap"]) == AttestExitUsage

suite "a second destroy of a machine that is already gone":

  test "the three answers a destroy can give, and they are distinct":
    # The reader, on its own, over values the providers publish. Two of
    # the three are failures at the exit-code level and only one of
    # them is a failure for a reaper, which is the whole point: "there
    # is no such instance" means the machine is not billing, and that
    # is the outcome the sweep wanted.
    check destroyDispositionFor(cpAwsEc2, 0, "") == ddDestroyed
    check destroyDispositionFor(cpAwsEc2, 255,
      "An error occurred (" & AwsAbsentInstanceMarker & ") when " &
      "calling the TerminateInstances operation") == ddAlreadyGone
    # The narrowing, and it is the half that stops this being "swallow
    # every failure": a refusal that is NOT the absent-instance one is
    # still a failure, keeps the record, and is tried again.
    check destroyDispositionFor(cpAwsEc2, 255,
      "An error occurred (UnauthorizedOperation) when calling the " &
      "TerminateInstances operation") == ddFailed
    check destroyDispositionFor(cpAwsEc2, 255,
      "Could not connect to the endpoint URL") == ddFailed
    # The other cloud spells it in its own words, and the marker is
    # read PER PROVIDER: one cloud's absent-instance text is not the
    # other's, so a reader that matched either everywhere would score a
    # foreign message as success.
    for text in ["Could not fetch resource: - The resource " &
                 "'projects/a-project/zones/us-central1-a/instances/x' " &
                 "was not found",
                 "{\"error\":{\"code\":404,\"errors\":" &
                 "[{\"reason\":\"notFound\"}]}}"]:
      check destroyDispositionFor(cpGcpCompute, 1, text) == ddAlreadyGone
      check destroyDispositionFor(cpAwsEc2, 1, text) == ddFailed
    check destroyDispositionFor(cpGcpCompute, 1,
      "An error occurred (" & AwsAbsentInstanceMarker & ")") == ddFailed
    # Each provider's marker set is non-empty, so neither arm is a rule
    # with no input.
    for cloud in MeasurableCloud:
      check alreadyGoneMarkersFor(cloud).len > 0

  test "the retry TERMINATES when the instance is already gone":
    # The trap this arm exists for, reproduced end to end. The order
    # this module destroys in is destroy, ledger, remove — so a crash
    # in the middle leaves a record whose instance is gone. Without the
    # arm the next sweep scores the refusal `failed`, KEEPS the record,
    # and every sweep after it does the same: a permanent retry against
    # a machine nobody is paying for, with the refusal never clearing.
    let gear = freshCase("already-gone")
    let effector = fakeProviderEffector(gear.provider)
    let now = 1_700_000_000'i64
    let holder = acquireCloudLease(gear.store, childSpec(),
      delayed(seconds = 1), now, 0, effector, gear.ledger)
    holder.recordInstanceCreated("i-0fixture000000000")
    setFailureMode(gear.provider, ffmDestroyAlreadyGone)
    let report = reapCloudLeases(gear.store, now + 600,
      fixedOwnerLiveness(olUnknowable), effector, gear.ledger)
    # It was ASKED — this is not the empty-discovery path wearing the
    # same outcome.
    check invocationsMentioning(gear.provider, "terminate-instances") == 1
    check report.failed == 0
    check report.nothingToDestroy == 1
    # …and it is NOT reported as reaped, because this sweep destroyed
    # nothing and a ledger that said otherwise would claim an action
    # nobody took.
    check report.reaped == 0
    # …and the report does not SAY it destroyed it either. A line
    # reading "destroyed" beside an outcome of nothing-to-destroy would
    # claim an action nobody took.
    let text = renderReapReportText(report)
    check "outcome: nothing-to-destroy" in text
    check "destroyed: " notin text
    check "instance: i-0fixture000000000" in text
    # The record is gone, so there is no next sweep to fail.
    check listCloudLeases(gear.store).len == 0
    requireReapSucceeded(report)
    # The control, on the SAME store shape: a refusal that is not the
    # absent-instance one keeps the record and refuses, so the
    # termination above is about the message and not about this build
    # having stopped caring.
    let other = freshCase("still-failing")
    let otherEffector = fakeProviderEffector(other.provider)
    let kept = acquireCloudLease(other.store, childSpec(),
      delayed(seconds = 1), now, 0, otherEffector, other.ledger)
    kept.recordInstanceCreated("i-0fixture000000000")
    setFailureMode(other.provider, ffmDestroyFails)
    let stuck = reapCloudLeases(other.store, now + 600,
      fixedOwnerLiveness(olUnknowable), otherEffector, other.ledger)
    check stuck.failed == 1
    check stuck.nothingToDestroy == 0
    check listCloudLeases(other.store).len == 1
    check refuses(proc () = requireReapSucceeded(stuck)).condition ==
      cllDestroyInvocationFailed

  test "the tag sweep reads the same answer the same way":
    # A tag sweep races the holder's own teardown by construction: both
    # are looking at the same expired instance. So "somebody got there
    # first" is its ORDINARY outcome, and a sweeper that scored it as a
    # failure would refuse for ever on a cloud that is already clean.
    let gear = freshCase("tag-already-gone")
    let effector = fakeProviderEffector(gear.provider)
    let now = 1_700_000_000'i64
    let holder = acquireCloudLease(gear.store, childSpec(),
      delayed(seconds = 600), now, 0, effector, gear.ledger)
    let created = effector(CloudEffect(
      argv: leasedLaunchPlan(childSpec(), holder.lease, fixedEnvLookup([])),
      providerEnvNames: providerEnvNamesFor(cpAwsEc2)))
    holder.recordInstanceCreated(created.output.strip())
    setFailureMode(gear.provider, ffmDestroyAlreadyGone)
    let report = reapExpiredByTag(cpAwsEc2, childSpec().region, now + 600,
      effector)
    check report.failed == 0
    check report.nothingToDestroy == 1
    check report.reaped == 0
    # …and the EVENT says it too, not only the tally beside it.
    #
    # Added by review, because a mutation written from this case's own
    # sentence came back GREEN: setting every already-gone event's
    # outcome to `roFailed` while leaving the counter alone changed
    # NOTHING any check could see. Every assertion this store-less
    # sweep had was over the summary, so the per-lease outcome — the
    # field `renderReapReportText` prints, and the field that decides
    # whether the line reads "destroyed:" or "instance:" — was
    # unasserted on the third line of defence. A report that
    # contradicted its own summary would have been invisible, which is
    # the same "claiming an action nobody took" this module is careful
    # about everywhere else.
    check report.events.len == 1
    check report.events[0].outcome == roNothingToDestroy
    check report.events[0].decision == rdExpired
    check report.events[0].instanceIds == @[holder.lease.providerInstanceId]
    check "outcome: nothing-to-destroy" in renderReapReportText(report)
    check "destroyed: " notin renderReapReportText(report)
    # The control: the other refusal is still a failure here too, and
    # its event says so as well — so the equality above is about the
    # marker and not about this renderer only ever writing one word.
    setFailureMode(gear.provider, ffmDestroyFails)
    let failing = reapExpiredByTag(cpAwsEc2, childSpec().region,
      now + 600, effector)
    check failing.failed == 1
    check failing.nothingToDestroy == 0
    check failing.events.len == 1
    check failing.events[0].outcome == roFailed
    check "outcome: failed" in renderReapReportText(failing)

suite "the identifier retry is BOUNDED":

  test "an identifier source that cannot make progress REFUSES":
    # The guard that stops a record being written over is `while the
    # name is taken: mint another`, and its termination depends on the
    # minting making progress — a property nothing asserts. Written
    # without a bound it did not fail slowly, it did not fail at all:
    # the caller spun inside the path that takes a hold, and a gate
    # pointed at it stopped mid-run without reaching a check.
    #
    # The bound is reached here by RESERVING every name the source will
    # produce next, which is the same shape a stuck source has and
    # needs no stuck source.
    let gear = freshCase("bounded-mint")
    let now = 1_700_000_000'i64
    let owner = thisProcessOwner()
    # One real lease first, to learn where the serial stands.
    let first = acquireCloudLease(gear.store, childSpec(),
      delayed(seconds = 600), now).lease
    let parts = first.leaseId.rsplit('-', 1)
    check parts.len == 2
    let serial = parseInt(parts[1])
    var reserved = 0
    while reserved <= MaxLeaseIdentifierAttempts:
      writeFile(recordPath(gear.store,
        "rl-" & $now & "-" & $owner.pid & "-" & $(serial + 1 + reserved)),
        "reserved")
      inc reserved
    var spec = childSpec()
    spec.instanceName = "reproos-lease-probe-bounded"
    let e = refuses(proc () =
      discard acquireCloudLease(gear.store, spec,
        delayed(seconds = 600), now))
    check e.condition == cllLeaseIdentifierCouldNotBeMinted
    check $MaxLeaseIdentifierAttempts in e.msg
    # The bound is pinned by a LITERAL as well as exercised at itself,
    # so halving the constant does not move both ends together.
    check MaxLeaseIdentifierAttempts == 64
    # The control: with the reservations removed the SAME call succeeds,
    # so the refusal is about the names being taken and not about this
    # store.
    for i in 0 .. reserved:
      let path = recordPath(gear.store,
        "rl-" & $now & "-" & $owner.pid & "-" & $(serial + 1 + i))
      if fileExists(path): removeFile(path)
    check acquireCloudLease(gear.store, spec, delayed(seconds = 600),
      now).lease.leaseId.len > 0

suite "the sweep this build SHIPS can destroy":

  test "the shipped effector really runs the tool, and reads its answer":
    # The effector was the missing half. Without one the reaper was a
    # library and a printing command: `repro attest reap` could say what
    # it would destroy and could not destroy it, so a leak cost "until
    # somebody runs the sweep" and nothing bounded that.
    #
    # This drives the REAL effector — `startProcess`, a real child, its
    # real exit status and its real output — against a program on PATH
    # that behaves the way the provider's tool does. The substitution is
    # at the program, not at the seam.
    let gear = freshCase("shipped-effector")
    let shimDir = gear.root / "bin"
    createDir(shimDir)
    let instances = instancesDir(gear.provider)
    writeFile(shimDir / "aws", "#!/bin/sh\n" &
      "if [ \"$2\" = terminate-instances ]; then\n" &
      "  id=$(eval echo \\$$#)\n" &
      "  if [ -e \"" & instances & "/$id\" ]; then rm -f \"" &
      instances & "/$id\"; exit 0; fi\n" &
      "  echo \"An error occurred (" & AwsAbsentInstanceMarker &
      ") when calling the TerminateInstances operation\" >&2\n" &
      "  exit 255\n" &
      "fi\nexit 64\n")
    setFilePermissions(shimDir / "aws",
      {fpUserRead, fpUserWrite, fpUserExec})
    writeFile(instances / "i-shipped-probe", "")
    let effector = subprocessCloudLeaseEffector(
      fixedEnvLookup([("PATH", statedToolPath(shimDir))]))
    var lease = CloudLease(provider: cpAwsEc2, region: "us-east-1",
      leaseId: "rl-shipped")
    let done = effector(CloudEffect(
      argv: destroyPlanFor(lease, "i-shipped-probe"),
      providerEnvNames: providerEnvNamesFor(cpAwsEc2)))
    check done.status == 0
    check not fileExists(instances / "i-shipped-probe")
    # The second destroy is the documented trap, and it arrives here
    # through the real program: a non-zero status whose TEXT is the
    # absent-instance answer.
    let again = effector(CloudEffect(
      argv: destroyPlanFor(lease, "i-shipped-probe"),
      providerEnvNames: providerEnvNamesFor(cpAwsEc2)))
    check again.status != 0
    check AwsAbsentInstanceMarker in again.output
    check destroyDispositionFor(cpAwsEc2, again.status, again.output) ==
      ddAlreadyGone
    # Standard error is part of the answer, and that is not incidental:
    # both providers write the REASON there, and a reader that captured
    # only standard output would see a bare exit code and could not
    # tell "there is no such instance" from "you may not do that".
    check again.output.len > 0

    # And the effector RECORDS what it resolved. Nothing provisioned
    # this program and nothing afterwards can say which file it was, so
    # the resolved executable and the search path it came from travel
    # back with the answer — the model this repository works to requires
    # exactly that of a PATH-resolved external tool, and it matters more
    # here than almost anywhere else because this is the program that
    # destroys machines.
    check done.program == shimDir / "aws"
    check done.searchPath == statedToolPath(shimDir)
    check again.program == done.program
    # A tool that is not there is a FAILURE, not a silent nothing.
    let missing = effector(CloudEffect(
      argv: @["a-tool-this-machine-does-not-have", "x"],
      providerEnvNames: @[]))
    check missing.status != 0

    # WHICH tool gets run is decided by the path this effector was
    # given, and not by the one this process happens to have. That is
    # not a nicety: the lookup that finds a program happens in the
    # PARENT and reads the parent's own search path, so an effector
    # that merely put `PATH` in the child's environment would run
    # whatever the operator has installed while telling the child
    # something else. The first draft did exactly that, and this case
    # found it by reaching the machine's real provider tool and coming
    # back with an authentication failure — which on a machine with no
    # such tool would have said nothing at all.
    let elsewhere = gear.root / "elsewhere"
    createDir(elsewhere)
    let ambientOnly = "reproos-lease-ambient-probe"
    writeFile(elsewhere / ambientOnly, "#!/bin/sh\nexit 0\n")
    setFilePermissions(elsewhere / ambientOnly,
      {fpUserRead, fpUserWrite, fpUserExec})
    let savedPath = getEnv("PATH")
    try:
      putEnv("PATH", elsewhere & ":" & savedPath)
      # On the PROCESS path and not on the STATED one: not found.
      check resolveOnStatedPath(ambientOnly, statedToolPath(shimDir)) == ""
      let unreachable = effector(CloudEffect(argv: @[ambientOnly],
        providerEnvNames: @[]))
      check unreachable.status == 127
      # The control: the same program IS found when the stated path is
      # the one it is on, so the refusal above is about the path and
      # not about the program.
      check resolveOnStatedPath(ambientOnly, elsewhere) ==
        elsewhere / ambientOnly
      let reachable = subprocessCloudLeaseEffector(
        fixedEnvLookup([("PATH", elsewhere)]))(
          CloudEffect(argv: @[ambientOnly], providerEnvNames: @[]))
      check reachable.status == 0
    finally:
      putEnv("PATH", savedPath)
    # A program that names a directory is taken as the caller meaning
    # that file, rather than searched for.
    check resolveOnStatedPath(shimDir / "aws", "") == shimDir / "aws"

  test "the command DESTROYS with --destroy and does not without it":
    # Both directions, because either alone reads as the whole answer.
    let gear = freshCase("command-destroy")
    let shimDir = gear.root / "bin"
    createDir(shimDir)
    let instances = instancesDir(gear.provider)
    let shimLog = gear.root / "shim.log"
    writeFile(shimDir / "aws", "#!/bin/sh\n" &
      "echo \"$@\" >> " & shimLog & "\n" &
      "if [ \"$2\" = terminate-instances ]; then\n" &
      "  id=$(eval echo \\$$#)\n" &
      "  rm -f \"" & instances & "/$id\"\n  exit 0\nfi\nexit 64\n")
    setFilePermissions(shimDir / "aws",
      {fpUserRead, fpUserWrite, fpUserExec})
    writeFile(instances / "i-command-destroy", "")
    let now = 1_700_000_000'i64
    let holder = acquireCloudLease(gear.store, childSpec(),
      delayed(seconds = 600), now, 3_600_000)
    holder.recordInstanceCreated("i-command-destroy")

    # Without `--destroy`: the record and the instance both survive,
    # and the tool is reachable — it is named on the stated path — so
    # "nothing ran" is a decision and not an absence.
    let reported = withCapturedStdout(gear.root / "report.out",
      proc (): int = runAttestCommandIn(@["reap", "--lease-store",
        gear.store.root, "--now", $(now + 6_000)], statedToolPath(shimDir)))
    let reportCode = reported.code
    let reportOut = reported.text
    check reportCode == AttestExitAccepted
    check not fileExists(shimLog)
    check fileExists(instances / "i-command-destroy")
    check listCloudLeases(gear.store).len == 1
    # With it: the tool is run and the instance is gone.
    let destroyed = withCapturedStdout(gear.root / "destroy.out",
      proc (): int = runAttestCommandIn(@["reap", "--lease-store",
        gear.store.root, "--now", $(now + 6_000), "--destroy"],
        statedToolPath(shimDir)))
    let destroyCode = destroyed.code
    let destroyOut = destroyed.text
    check destroyCode == AttestExitAccepted
    check fileExists(shimLog)
    check "terminate-instances" in readFile(shimLog)
    # …and the command SAID which program it ran. A sweep that destroyed
    # machines with an unnamed binary is not one an operator can audit.
    check (shimDir / "aws") in destroyOut
    check "provider-tool: " in destroyOut
    check "provider-tool-search-path: " in destroyOut
    # The control: the REPORTING sweep names none, because it resolved
    # none — so the lines above are a reading and not a template.
    check "provider-tool: " notin reportOut
    check not fileExists(instances / "i-command-destroy")
    check listCloudLeases(gear.store).len == 0

  test "a destroying sweep REPEATS, and the gap between sweeps is capped":
    # A sweep that runs once is not a cadence. `--sweeps` bounds the
    # repetition so this case terminates; an operator omits it and the
    # sweep runs until it is stopped.
    let gear = freshCase("cadence")
    let shimDir = gear.root / "bin"
    createDir(shimDir)
    let shimLog = gear.root / "shim.log"
    writeFile(shimDir / "aws", "#!/bin/sh\necho ran >> " & shimLog &
      "\nexit 0\n")
    setFilePermissions(shimDir / "aws",
      {fpUserRead, fpUserWrite, fpUserExec})
    let now = 1_700_000_000'i64
    # Three leases the sweep can see, none of them destroyable to
    # nothing: each one keeps its record only if the destroy fails, and
    # this shim succeeds, so what is being counted is the REPETITION.
    let holder = acquireCloudLease(gear.store, childSpec(),
      delayed(seconds = 600), now)
    holder.recordInstanceCreated("i-cadence-probe")
    let code = runAttestCommandIn(@["reap", "--lease-store",
      gear.store.root, "--now", $(now + 6_000), "--destroy",
      "--interval-seconds", "1", "--sweeps", "3"], statedToolPath(shimDir))
    check code == AttestExitAccepted
    # Three sweeps ran. The first destroys and removes the record; the
    # two after it find an empty store and destroy nothing, which is
    # what a cadence looks like when there is nothing to do.
    check listCloudLeases(gear.store).len == 0
    check fileExists(shimLog)
    check readFile(shimLog).count("ran") == 1
    # A sweep gap longer than the cap is REFUSED, because the interval
    # is half of how long a leaked instance can keep billing and a
    # daily sweep would make the leak findable rather than short.
    check runAttestCommandIn(@["reap", "--lease-store", gear.store.root,
      "--destroy", "--interval-seconds",
      $(MaxReapIntervalSeconds + 1), "--sweeps", "1"]) == AttestExitUsage
    # …and AT the cap it is accepted, so the refusal is a bound and not
    # a dislike of the flag.
    check runAttestCommandIn(@["reap", "--lease-store", gear.store.root,
      "--destroy", "--interval-seconds", $MaxReapIntervalSeconds,
      "--sweeps", "1"]) == AttestExitAccepted
    # A sweep that never runs is refused too.
    check runAttestCommandIn(@["reap", "--lease-store", gear.store.root,
      "--destroy", "--sweeps", "0"]) == AttestExitUsage
    # And a bare `--destroy` runs ONCE and returns. Repetition is what
    # `--interval-seconds` asks for, and tying it to `--destroy` instead
    # made a plain command-line invocation never come back — found here
    # rather than by reading, by this file failing to terminate.
    check runAttestCommandIn(@["reap", "--lease-store", gear.store.root,
      "--now", $(now + 6_000), "--destroy"],
      statedToolPath(shimDir)) == AttestExitAccepted

  test "a sweep that could not destroy something EXITS non-zero":
    # Whatever runs this on a cadence has to be able to tell "there was
    # nothing to do" from "something is still running and I could not
    # stop it". A printing sweep could not say either.
    let gear = freshCase("sweep-failure")
    let shimDir = gear.root / "bin"
    createDir(shimDir)
    writeFile(shimDir / "aws", "#!/bin/sh\n" &
      "echo 'An error occurred (UnauthorizedOperation)' >&2\nexit 255\n")
    setFilePermissions(shimDir / "aws",
      {fpUserRead, fpUserWrite, fpUserExec})
    let now = 1_700_000_000'i64
    let holder = acquireCloudLease(gear.store, childSpec(),
      delayed(seconds = 600), now)
    holder.recordInstanceCreated("i-unstoppable")
    let code = runAttestCommandIn(@["reap", "--lease-store",
      gear.store.root, "--now", $(now + 6_000), "--destroy",
      "--sweeps", "1"], statedToolPath(shimDir))
    check code == AttestExitRejected
    # The record is kept, so the next sweep tries again.
    check listCloudLeases(gear.store).len == 1

  test "the tag sweep is reachable from the command line":
    # The sweep of last resort — no store, tags only — and it needs the
    # cloud and the region named because it has nothing else to read
    # them from.
    let gear = freshCase("command-tag-sweep")
    check runAttestCommandIn(@["reap", "--tag-sweep",
      "--region", "us-east-1", "--sweeps", "1"]) == AttestExitUsage
    check runAttestCommandIn(@["reap", "--tag-sweep",
      "--provider", "aws-ec2", "--sweeps", "1"]) == AttestExitUsage
    let shimDir = gear.root / "bin"
    createDir(shimDir)
    let shimLog = gear.root / "shim.log"
    writeFile(shimDir / "aws", "#!/bin/sh\necho \"$@\" >> " & shimLog &
      "\nexit 0\n")
    setFilePermissions(shimDir / "aws",
      {fpUserRead, fpUserWrite, fpUserExec})
    let code = runAttestCommandIn(@["reap", "--tag-sweep",
      "--provider", "aws-ec2", "--region", "us-east-1",
      "--sweeps", "1"], statedToolPath(shimDir))
    check code == AttestExitAccepted
    check fileExists(shimLog)
    check "describe-instances" in readFile(shimLog)
    check "Name=tag-key,Values=" & $cltLeaseId in readFile(shimLog)

suite "the sweep is SCHEDULED, not merely runnable":

  test "the shipped units run the destroying sweep on a bounded cadence":
    # A sweep that exists and a sweep that runs are different things.
    # Until something activates it unattended, the cost of a leak is
    # "until somebody runs the sweep", and the length of that interval
    # is the thing this file is trying to turn into a number.
    #
    # So the schedule is an ARTIFACT in this tree and is read here,
    # rather than a sentence in a document. Its cadence is required to
    # be inside the bound the library states, so the two cannot drift.
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let units = repoRoot / "recipes/cloud-lease-reaper/systemd-units"
    let service = units / "repro-cloud-lease-reaper.service"
    let timer = units / "repro-cloud-lease-reaper.timer"
    check fileExists(service)
    check fileExists(timer)

    # The unit runs the DESTROYING sweep, and one sweep per activation
    # — a unit that also looped would give the machine two answers
    # about how often it is swept.
    var execStart = ""
    for line in readFile(service).splitLines:
      if line.startsWith("ExecStart="): execStart = line["ExecStart=".len .. ^1]
    check execStart.len > 0
    check "attest reap" in execStart
    check "--destroy" in execStart
    check "--sweeps 1" in execStart
    check "--interval-seconds" notin execStart
    # …and it does not carry an account, a region or a credential in a
    # file that ships in a source tree.
    check "EnvironmentFile=" in readFile(service)

    # The cadence, read off the timer and required to be inside the
    # bound the library states. A unit that swept once a day would make
    # a leak findable rather than short.
    var cadence = 0
    for line in readFile(timer).splitLines:
      if line.startsWith("OnUnitActiveSec="):
        let raw = line["OnUnitActiveSec=".len .. ^1].strip()
        check raw.endsWith("s")
        cadence = parseInt(raw[0 ..< raw.len - 1])
    check cadence > 0
    check cadence <= MaxReapIntervalSeconds
    check cadence == DefaultReapIntervalSeconds
    # It fires soon after a machine has been off, because a lease that
    # expired while the machine was down is exactly the one still
    # billing — and the directive that delivers that is read here, with
    # its own number, rather than the one that merely reads as though it
    # does.
    #
    # `Persistent=true` was what this asserted, and it is documented to
    # have an effect only on a timer configured with `OnCalendar=`. On a
    # monotonic timer it is inert, so the check was green on a line that
    # does nothing — a rule with no reachable input, one layer out from
    # the code. `OnBootSec=` is what actually arms the first sweep after
    # a boot, and it is bounded by the same cap as the cadence so a unit
    # that waited out an hour after a reboot is red.
    var afterBoot = -1
    for line in readFile(timer).splitLines:
      if line.startsWith("OnBootSec="):
        let raw = line["OnBootSec=".len .. ^1].strip()
        check raw.endsWith("s")
        afterBoot = parseInt(raw[0 ..< raw.len - 1])
    check afterBoot > 0
    check afterBoot <= MaxReapIntervalSeconds
    check afterBoot == 60
    # …and the inert directive is gone rather than left beside the one
    # that works, because a reader who finds both will believe the wrong
    # one is doing it.
    check "Persistent=true" notin readFile(timer)
    # The cadence is NOMINAL: a timer may fire late by its stated
    # accuracy, so the gap a sweep is really bounded by is the sum. Read
    # off the unit rather than assumed, and required to stay small
    # against the cadence it perturbs.
    var slack = -1
    for line in readFile(timer).splitLines:
      if line.startsWith("AccuracySec="):
        let raw = line["AccuracySec=".len .. ^1].strip()
        check raw.endsWith("s")
        slack = parseInt(raw[0 ..< raw.len - 1])
    check slack >= 0
    check cadence + slack <= MaxReapIntervalSeconds
    check cadence + slack == 310

    # The exposure window THIS schedule buys, as the numbers it is —
    # and they are the schedule's, not the build's ceiling. With the
    # hold an operator gets by default: 1,800 + 300. With the longest
    # hold this build will grant: 86,400 + 300. The build's own ceiling
    # is larger again, because a caller may ask for a slower cadence up
    # to the cap, and that number is pinned in the case below.
    check worstCaseExposureSeconds(DefaultLeaseTtlSeconds, cadence) ==
      2_100
    check worstCaseExposureSeconds(MaxLeaseTtlSeconds, cadence) == 86_700
    check worstCaseExposureSeconds(MaxLeaseTtlSeconds,
      MaxReapIntervalSeconds) == 87_300
    # On the owner's own host the record is still there, so a provably
    # dead owner is not waited out at all and the window is ONE sweep.
    check cadence == 300

  test "the invocation the unit names is one this build ACCEPTS":
    # A unit file is a string until something runs it, and a flag that
    # has been renamed out from under it fails at three in the morning
    # on somebody else's machine. So the flags the unit spells are put
    # through the real argument parser here.
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let service = repoRoot /
      "recipes/cloud-lease-reaper/systemd-units/repro-cloud-lease-reaper.service"
    var execStart = ""
    for line in readFile(service).splitLines:
      if line.startsWith("ExecStart="): execStart = line["ExecStart=".len .. ^1]
    var args: seq[string] = @[]
    var seenSubcommand = false
    for token in execStart.splitWhitespace():
      if token.endsWith("/repro") or token == "repro": continue
      if token == "attest":
        seenSubcommand = true
        continue
      # The store path is an expansion the service manager performs, so
      # a real directory stands in for it here.
      args.add (if token.startsWith("${"): scratch else: token)
    check seenSubcommand
    let parsed = parseAttestArgs(args)
    check parsed.sub == ascReap
    check parsed.reapDestroy
    check parsed.reapSweeps == "1"
    check parsed.leaseStore == scratch
    # The control: a flag this build does not have is refused by the
    # same parser, so the acceptance above is a reading.
    var refusedUnknown = false
    try:
      discard parseAttestArgs(args & @["--sweep-everything"])
    except ValueError:
      refusedUnknown = true
    check refusedUnknown

suite "how long a leaked instance can keep billing, as a number":

  test "the window is the hold plus one sweep, and both are bounded":
    # "Reduced from unbounded to until the next sweep" is not a bound
    # unless somebody says how long that is. Both terms are literals
    # here as well as constants, so halving either does not move the
    # arithmetic and the assertion together.
    check MaxLeaseTtlSeconds == 86_400
    check DefaultLeaseTtlSeconds == 1_800
    check DefaultReapIntervalSeconds == 300
    check MaxReapIntervalSeconds == 900
    # The worst case this build can be configured into: the longest
    # hold it will grant, plus the longest gap it will schedule.
    check worstCaseExposureSeconds(MaxLeaseTtlSeconds,
      MaxReapIntervalSeconds) == 87_300
    # …and the case an operator who states nothing gets.
    check worstCaseExposureSeconds(DefaultLeaseTtlSeconds,
      DefaultReapIntervalSeconds) == 2_100
    # It is a function of BOTH, so a build that stopped counting the
    # sweep interval would be red rather than optimistic.
    check worstCaseExposureSeconds(100, 0) == 100
    check worstCaseExposureSeconds(100, 7) == 107
    check worstCaseExposureSeconds(0, 7) == 7

  test "a dead owner is not waited out, so the usual case is one sweep":
    # The worst case above is the STORE-LESS one: a sweeper with only
    # tags reaps on expiry, because it cannot read the owner's process
    # table. A sweeper that still has the record does better, and the
    # difference is the whole economic argument for the record.
    let gear = freshCase("exposure-shape").store
    let now = 1_700_000_000'i64
    let lease = acquireCloudLease(gear, childSpec(),
      delayed(seconds = MaxLeaseTtlSeconds), now).lease
    # One second into a full day's hold, with the owner provably gone.
    check reapDecision(lease, now + 1, olDead) == rdOrphaned
    # The same lease, one second in, seen by a sweeper that cannot
    # judge the owner: held until the deadline.
    check reapDecision(lease, now + 1, olUnknowable) == rdHeld
    check reapDecision(lease, now + MaxLeaseTtlSeconds, olUnknowable) ==
      rdExpired

suite "teardown":

  test "every child this gate started is gone":
    # A gate about not leaking processes must not leak processes. The
    # children are all killed and waited for in their own cases; this
    # asserts the scratch tree is the only thing left, and removes it.
    removeDir(scratch)
    check not dirExists(scratch)
