## Holding a billed cloud instance under a lease, and getting rid of it
## on every exit path — including the ones the process does not live to
## see.
##
## ## What this module is for
##
## `cloud_launch` describes a launch. This module is about what happens
## *after* one: a confidential instance is a machine somebody is paying
## for by the second, and the failure mode that matters is not a wrong
## measurement, it is a test that died and left the machine running. A
## local container held past its usefulness costs nothing; a
## confidential guest held past its usefulness costs money until
## somebody notices.
##
## So every instance this build would create is held under a **lease**:
## a record, written before the provider is asked for anything, that
## says who holds it, until when, and — this is the part that matters —
## *exactly how to destroy it* without the process that created it
## being alive to help.
##
## ## Three lines of defence, because the first two can be lost
##
##   1. **The holder tears down.** `withCloudLease` releases in a
##      `finally`, from an exit procedure, and from the two signals a
##      process can catch. That covers a normal return, an exception, a
##      `quit`, an interrupt and a termination request.
##   2. **The reaper destroys what the holder could not.** A lease whose
##      owner is provably dead is reapable *immediately*, without
##      waiting for its deadline, because there is nobody left who could
##      want it. A lease whose deadline has passed is reapable whatever
##      its owner is doing. This is what answers `SIGKILL`, a panic, and
##      a machine that went away.
##   3. **The tags outlive the records.** Every instance carries the
##      lease identifier and the expiry as provider tags, so a sweeper
##      that has lost the local store entirely can still find the
##      instance and decide whether it has expired. A local state
##      directory is a cache; the provider's own tags are the authority.
##
## The third line is the one the local lease substrate in this
## repository deliberately does not have — its on-disk store *is* the
## authority, and reaping state it did not record is declared out of
## scope. That is the right answer for a container on this host and the
## wrong one for a machine on somebody else's, so this module revisits
## it rather than inheriting it.
##
## ## The lease policy vocabulary is the one that already exists
##
## `LeasePolicy`, `immediate`, `delayed` and `deadlineFrom` come from
## the resource-lease library rather than being spelled again here.
## There is one thing a cloud lease does differently, and it is a
## refusal rather than an addition: **`keep` is not a policy a billed
## instance may be held under.** "Never auto-reap" on a local container
## is the same semantics a plain dependency already has; on a
## confidential guest it is an open-ended bill, and the whole point of
## this module is that no exit path leaves one. So a `keep` policy is
## refused by name, and the refusal says why.
##
## ## Nothing here destroys anything either
##
## Every provider interaction travels through `CloudLeaseEffector`, and
## this build ships none — exactly as `cloud_launch` ships no launch
## effector. A reap asked for without one is refused rather than
## reported as a no-op, because "the reaper ran and found nothing to do"
## and "the reaper could not do anything" must not be the same output.
##
## What a failing destroy does NOT do is get swallowed. The sweep
## completes — a failure on one lease must not strand the others — and
## the failure is carried in the report, with `requireReapSucceeded`
## turning it into a refusal. A destroy whose error is discarded is how
## an orphan is made.
##
## ## Mocking
##
## None in the library. `CloudLeaseEffector` is a seam, not a mock: it
## is how a real provider tool is reached, and its absence is refused
## rather than simulated. The gates beside this module supply an
## effector whose *observable filesystem state* is the measurement,
## which is a substitute for a cloud in the same sense that a real
## subprocess is a substitute for a real subprocess.

import std/[algorithm, exitprocs, options, os, strutils, times]

import ./cloud_launch
import repro_resources/lease

export lease.LeaseKind, lease.LeasePolicy, lease.immediate, lease.delayed,
       lease.keep, lease.deadlineFrom

# ---------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------

type
  CloudLeaseCondition* = enum
    ## One value per rule, and one raise site per value. The census in
    ## the gate beside this module scans this file's own source and
    ## requires the multiset of raise sites to be each value exactly
    ## once, for the reason `cloud_launch` states next door: a rule
    ## raised from two places is paid for by a rule reached from none.
    cllPolicyWouldNeverExpire
    cllTtlIsLongerThanThisBuildWillGrant
    cllValueCarriesACharacterTheRecordCannotHold
    cllRecordIsNotOfThisFormat
    cllRecordDoesNotCarryEveryField
    cllRecordCarriesAFieldTwice
    cllReapHasNoEffector
    cllDestroyInvocationFailed

  CloudLeaseError* = object of CatchableError
    condition*: CloudLeaseCondition

const
  CloudLeaseMessage*: array[CloudLeaseCondition, string] = [
    cllPolicyWouldNeverExpire:
      "a billed instance was asked to be held under a policy with no " &
      "deadline; on a machine somebody pays for by the second there is " &
      "no such thing as holding it until further notice",
    cllTtlIsLongerThanThisBuildWillGrant:
      "the requested hold is longer than this build will grant for an " &
      "instance that bills while it is held; a longer one is a " &
      "deliberate act and does not belong behind a default",
    cllValueCarriesACharacterTheRecordCannotHold:
      "a lease value carries a character the on-disk record uses to " &
      "separate one field from the next, so writing it would let one " &
      "field forge another",
    cllRecordIsNotOfThisFormat:
      "what was read is not a lease record this build writes; its first " &
      "line does not name this format and this version",
    cllRecordDoesNotCarryEveryField:
      "a lease record was read that does not carry every field a lease " &
      "has, and a reaper that filled the gap with a default would " &
      "destroy a machine it knows nothing about",
    cllRecordCarriesAFieldTwice:
      "a lease record names the same field more than once, and there is " &
      "no rule here saying which one wins",
    cllReapHasNoEffector:
      "a reap was asked for and no effector was supplied; this build " &
      "ships none, so there is nothing the destroy invocation could be " &
      "handed to and nothing was destroyed",
    cllDestroyInvocationFailed:
      "a destroy invocation returned a failure; the lease record is " &
      "kept so the next sweep tries again, because a destroy whose " &
      "error is discarded is how an instance is orphaned"]

proc cloudLeaseMessagesAreDistinguishable*(): bool =
  ## No message is a substring of another, so an `in e.msg` assertion
  ## means one rule.
  for a in CloudLeaseCondition:
    for b in CloudLeaseCondition:
      if a == b: continue
      if CloudLeaseMessage[a] in CloudLeaseMessage[b]: return false
  true

proc leaseFail*(condition: CloudLeaseCondition;
                detail: string) {.noreturn.} =
  var e = newException(CloudLeaseError, CloudLeaseMessage[condition])
  if detail.len > 0: e.msg = e.msg & ": " & detail
  e.condition = condition
  raise e

# ---------------------------------------------------------------------
# Who holds a lease
# ---------------------------------------------------------------------

type
  CloudLeaseOwner* = object
    ## Enough to answer "is the process that took this lease still
    ## running", and to answer it without being fooled by the two things
    ## that make a bare process identifier useless: a reboot, and reuse.
    host*: string
    pid*: int
    bootToken*: string
      ## Identifies this boot of this machine. A record written before a
      ## reboot names a process that cannot exist, whatever the process
      ## table says now.
    startToken*: string
      ## Identifies this run of this process identifier. Without it a
      ## recycled identifier makes a dead owner look alive, which is the
      ## direction that leaves an instance running.

  OwnerLiveness* = enum
    ## Three answers, and the third is not a synonym for either other.
    olAlive
    olDead
    olUnknowable
      ## Nothing on THIS machine can answer the question — the owner is
      ## on a different host, or this platform does not publish what the
      ## answer needs. Treated as neither: an unknowable owner does not
      ## make a lease reapable early, and does not save it from its
      ## deadline.

  OwnerLivenessProbe* = proc (owner: CloudLeaseOwner): OwnerLiveness {.closure.}

const
  BootTokenPath = "/proc/sys/kernel/random/boot_id"

proc readBootToken*(): string =
  ## This boot's identifier, or the empty string where the platform does
  ## not publish one. Empty is a *reported* absence: every rule below
  ## treats it as "cannot tell" rather than as "they match".
  try:
    if fileExists(BootTokenPath):
      return readFile(BootTokenPath).strip()
  except IOError, OSError:
    discard
  ""

proc readStartToken*(pid: int): string =
  ## The field a process's own accounting record spells its start time
  ## in, or the empty string where it cannot be read. Read from the raw
  ## record rather than parsed, because the executable name in it may
  ## itself contain the separator: everything up to the last `)` is
  ## skipped first.
  let path = "/proc/" & $pid & "/stat"
  if not fileExists(path): return ""
  var text = ""
  try:
    text = readFile(path)
  except IOError, OSError:
    return ""
  let close = text.rfind(')')
  if close < 0: return ""
  let fields = text[close + 1 .. ^1].splitWhitespace()
  # Field 22 of the record, counted from one; the two fields before the
  # executable name are gone, and the state field is now the first.
  const StartTimeIndexAfterName = 19
  if fields.len <= StartTimeIndexAfterName: return ""
  fields[StartTimeIndexAfterName]

const HostNamePath = "/proc/sys/kernel/hostname"

proc hostName*(): string =
  ## The name this machine answers to.
  ##
  ## Read from the KERNEL first and from the environment only as a
  ## fallback, and that ordering is not cosmetic: `HOSTNAME` is a shell
  ## variable that interactive shells set and non-interactive ones often
  ## do not, so a build that trusted it would find every owner
  ## unknowable under a test runner and the whole dead-owner rule would
  ## have no reachable input. That is exactly how a rule stops being a
  ## rule without anything turning red.
  ##
  ## An empty answer is carried as empty rather than replaced by a
  ## guess, and an empty host makes every liveness question unknowable
  ## rather than answerable by accident.
  try:
    if fileExists(HostNamePath):
      let name = readFile(HostNamePath).strip()
      if name.len > 0: return name
  except IOError, OSError:
    discard
  for name in ["HOSTNAME", "COMPUTERNAME"]:
    let value = getEnv(name, "").strip()
    if value.len > 0: return value
  ""

proc thisProcessOwner*(): CloudLeaseOwner =
  let pid = getCurrentProcessId()
  CloudLeaseOwner(host: hostName(),
    pid: pid, bootToken: readBootToken(), startToken: readStartToken(pid))

proc processOwnerLiveness*(): OwnerLivenessProbe =
  ## The real answer, on this machine, for an owner that claims to be on
  ## it.
  result = proc (owner: CloudLeaseOwner): OwnerLiveness =
    let here = hostName()
    if owner.host.len == 0 or here.len == 0 or owner.host != here:
      return olUnknowable
    let boot = readBootToken()
    if owner.bootToken.len == 0 or boot.len == 0:
      return olUnknowable
    if owner.bootToken != boot:
      # The machine has rebooted since the record was written, so the
      # process it names is gone whatever occupies its number now.
      return olDead
    if owner.pid <= 0: return olUnknowable
    if not dirExists("/proc/" & $owner.pid): return olDead
    let started = readStartToken(owner.pid)
    if started.len == 0 or owner.startToken.len == 0: return olUnknowable
    if started != owner.startToken: return olDead
    olAlive

proc fixedOwnerLiveness*(answer: OwnerLiveness): OwnerLivenessProbe =
  ## A stated answer, for a caller that means a particular one. Used by
  ## the gates to reach each arm of the reap rule without needing a
  ## process in that state — the arms that DO need one have a real
  ## process in that state instead.
  result = proc (owner: CloudLeaseOwner): OwnerLiveness = answer

# ---------------------------------------------------------------------
# The lease itself
# ---------------------------------------------------------------------

type
  CloudLeaseState* = enum
    clsIntended = "intended"
      ## Written BEFORE the provider was asked for anything. A record in
      ## this state after its owner has died is the dangerous case: the
      ## instance may or may not exist, and the only safe action is to
      ## go and look.
    clsCreated = "created"
    clsDestroyed = "destroyed"

  CloudLease* = object
    ## Everything needed to destroy an instance without the process that
    ## created it. Every field has a value of `CloudLeaseField` named
    ## after it, and the gate beside this module asserts the two are in
    ## bijection — so a field added here without a name, or a name
    ## without a field, is a failure rather than a field no record
    ## carries.
    leaseId*: string
    provider*: CloudProvider
    region*: string
    instanceName*: string
    instanceShape*: string
    ownerHost*: string
    ownerPid*: int
    ownerBootToken*: string
    ownerStartToken*: string
    acquiredAtUnix*: int64
    ttlSeconds*: int64
    expiresAtUnix*: int64
    ratePerHourMicros*: int64
      ## What an hour of this instance costs, in millionths of the unit
      ## the operator is billed in. ZERO means "not stated", and the
      ## ledger then reports the hold as **unpriced** rather than as
      ## free. This build ships no price table: a transcribed one would
      ## be a number nobody measured, and a wrong price is worse than an
      ## absent one because it looks like an answer.
    state*: CloudLeaseState
    providerInstanceId*: string
      ## Empty until the provider has answered. A reap that finds it
      ## empty must DISCOVER by tag rather than assume nothing exists —
      ## the gap between the create request and the answer is exactly
      ## the window a crash leaves an untracked instance in.
    destroyedAtUnix*: int64

  CloudLeaseField* = enum
    ## One value per field of `CloudLease`, spelled exactly as the field
    ## is spelled, and also the key the on-disk record uses.
    clfLeaseId = "leaseId"
    clfProvider = "provider"
    clfRegion = "region"
    clfInstanceName = "instanceName"
    clfInstanceShape = "instanceShape"
    clfOwnerHost = "ownerHost"
    clfOwnerPid = "ownerPid"
    clfOwnerBootToken = "ownerBootToken"
    clfOwnerStartToken = "ownerStartToken"
    clfAcquiredAtUnix = "acquiredAtUnix"
    clfTtlSeconds = "ttlSeconds"
    clfExpiresAtUnix = "expiresAtUnix"
    clfRatePerHourMicros = "ratePerHourMicros"
    clfState = "state"
    clfProviderInstanceId = "providerInstanceId"
    clfDestroyedAtUnix = "destroyedAtUnix"

const
  MaxLeaseTtlSeconds* = 86_400
    ## The longest hold this build will grant. A day of a confidential
    ## guest is already a bill somebody will ask about; longer is a
    ## decision, and a decision does not belong behind a default.

  DefaultLeaseTtlSeconds* = 1_800
    ## Half an hour, which is what the local lease substrate's own
    ## recipes use. There IS a default, deliberately: the alternative is
    ## a required flag, and a required flag is one somebody works around
    ## by passing the largest value that is accepted.

  RecordMagic* = "reproos.cloud-lease.v1"

  LeaseValueForbidden* = {'\n', '\r', '\0'}
    ## What a value may NOT contain. The record is line-oriented, so a
    ## value carrying a line break could write a second field.

proc ownerOf*(lease: CloudLease): CloudLeaseOwner =
  CloudLeaseOwner(host: lease.ownerHost, pid: lease.ownerPid,
    bootToken: lease.ownerBootToken, startToken: lease.ownerStartToken)

proc valueOf*(lease: CloudLease; f: CloudLeaseField): string =
  ## One field, as the text the record carries. The single reader of the
  ## record type, so the writer, the parser and the gate's field sweep
  ## cannot come to disagree about which field a name means.
  case f
  of clfLeaseId: lease.leaseId
  of clfProvider: $lease.provider
  of clfRegion: lease.region
  of clfInstanceName: lease.instanceName
  of clfInstanceShape: lease.instanceShape
  of clfOwnerHost: lease.ownerHost
  of clfOwnerPid: $lease.ownerPid
  of clfOwnerBootToken: lease.ownerBootToken
  of clfOwnerStartToken: lease.ownerStartToken
  of clfAcquiredAtUnix: $lease.acquiredAtUnix
  of clfTtlSeconds: $lease.ttlSeconds
  of clfExpiresAtUnix: $lease.expiresAtUnix
  of clfRatePerHourMicros: $lease.ratePerHourMicros
  of clfState: $lease.state
  of clfProviderInstanceId: lease.providerInstanceId
  of clfDestroyedAtUnix: $lease.destroyedAtUnix

proc setValue*(lease: var CloudLease; f: CloudLeaseField; value: string) =
  ## The inverse, used by the parser and by the gate's field sweep. A
  ## total function over the enumeration, so a field added without a way
  ## to read it back does not compile.
  case f
  of clfLeaseId: lease.leaseId = value
  of clfProvider: lease.provider = cloudProviderFor(value)
  of clfRegion: lease.region = value
  of clfInstanceName: lease.instanceName = value
  of clfInstanceShape: lease.instanceShape = value
  of clfOwnerHost: lease.ownerHost = value
  of clfOwnerPid: lease.ownerPid = parseInt(value)
  of clfOwnerBootToken: lease.ownerBootToken = value
  of clfOwnerStartToken: lease.ownerStartToken = value
  of clfAcquiredAtUnix: lease.acquiredAtUnix = parseBiggestInt(value)
  of clfTtlSeconds: lease.ttlSeconds = parseBiggestInt(value)
  of clfExpiresAtUnix: lease.expiresAtUnix = parseBiggestInt(value)
  of clfRatePerHourMicros: lease.ratePerHourMicros = parseBiggestInt(value)
  of clfState:
    for s in CloudLeaseState:
      if $s == value: lease.state = s
  of clfProviderInstanceId: lease.providerInstanceId = value
  of clfDestroyedAtUnix: lease.destroyedAtUnix = parseBiggestInt(value)

# ---------------------------------------------------------------------
# Taking a lease
# ---------------------------------------------------------------------

proc requireRecordableValue(f: CloudLeaseField; value: string) =
  for c in value:
    if c in LeaseValueForbidden:
      leaseFail(cllValueCarriesACharacterTheRecordCannotHold,
        $f & " carries " & ("" & c).escape())

proc leaseTtlSecondsFor*(policy: LeasePolicy; now: int64): int64 =
  ## The hold a policy asks for, in seconds, with the two refusals this
  ## module adds to the shared vocabulary.
  ##
  ## Reached through `deadlineFrom`, which is the only place in the
  ## workspace that turns a policy into a wall clock. A second mapping
  ## here would be a second answer to the same question.
  let deadline = deadlineFrom(policy, fromUnix(now))
  if deadline.isNone:
    leaseFail(cllPolicyWouldNeverExpire,
      "the policy named is " & $policy.kind)
  let seconds = deadline.get.toUnix - now
  if seconds > MaxLeaseTtlSeconds:
    leaseFail(cllTtlIsLongerThanThisBuildWillGrant,
      $seconds & " seconds were asked for and at most " &
      $MaxLeaseTtlSeconds & " are granted")
  seconds

proc newCloudLease*(leaseId: string; spec: CloudLaunchSpec;
                    policy: LeasePolicy; owner: CloudLeaseOwner;
                    now: int64; ratePerHourMicros: int64 = 0): CloudLease =
  ## A lease, in the state it is in before the provider has been asked
  ## for anything. Written to the store FIRST and updated afterwards:
  ## the order is the whole of the crash story, because a record written
  ## after the create request would be absent exactly when it is needed.
  let ttl = leaseTtlSecondsFor(policy, now)
  result = CloudLease(
    leaseId: leaseId,
    provider: spec.provider,
    region: spec.region,
    instanceName: spec.instanceName,
    instanceShape: spec.instanceShape,
    ownerHost: owner.host,
    ownerPid: owner.pid,
    ownerBootToken: owner.bootToken,
    ownerStartToken: owner.startToken,
    acquiredAtUnix: now,
    ttlSeconds: ttl,
    expiresAtUnix: now + ttl,
    ratePerHourMicros: ratePerHourMicros,
    state: clsIntended,
    providerInstanceId: "",
    destroyedAtUnix: 0)
  for f in CloudLeaseField:
    requireRecordableValue(f, valueOf(result, f))

# ---------------------------------------------------------------------
# The record on disk
# ---------------------------------------------------------------------

proc renderCloudLease*(lease: CloudLease): string =
  ## The canonical bytes. Every field, in enumeration order, one per
  ## line, under a line naming the format — so a reader that is handed
  ## something else says so rather than guessing.
  result = RecordMagic & "\n"
  for f in CloudLeaseField:
    result.add $f & "=" & valueOf(lease, f) & "\n"

proc parseCloudLease*(text, origin: string): CloudLease =
  ## The strict reader. Every field required exactly once; a repeated
  ## field refused rather than resolved, because "the last one wins" is
  ## a rule nobody wrote down and an attacker would.
  let lines = text.splitLines()
  if lines.len == 0 or lines[0].strip() != RecordMagic:
    leaseFail(cllRecordIsNotOfThisFormat,
      origin & " begins " &
      (if lines.len == 0: "empty" else: lines[0].escape()))
  var seen: array[CloudLeaseField, int]
  var pending: seq[(CloudLeaseField, string)] = @[]
  for i in 1 ..< lines.len:
    let line = lines[i]
    if line.len == 0: continue
    let at = line.find('=')
    if at <= 0: continue
    let key = line[0 ..< at]
    let value = line[at + 1 .. ^1]
    for f in CloudLeaseField:
      if $f == key:
        inc seen[f]
        pending.add (f, value)
  for f in CloudLeaseField:
    if seen[f] > 1:
      leaseFail(cllRecordCarriesAFieldTwice,
        origin & " names " & $f & " " & $seen[f] & " times")
  var missing: seq[string] = @[]
  for f in CloudLeaseField:
    if seen[f] == 0: missing.add $f
  if missing.len > 0:
    leaseFail(cllRecordDoesNotCarryEveryField,
      origin & " is missing " & missing.join(", "))
  for pair in pending:
    setValue(result, pair[0], pair[1])

type
  CloudLeaseStore* = object
    ## A directory of lease records. A cache and an index, NOT the
    ## authority: the authority is the tag on the instance itself, which
    ## is why `sweepPlanFor` exists and does not read this at all.
    root*: string

proc openCloudLeaseStore*(root: string): CloudLeaseStore =
  createDir(root)
  CloudLeaseStore(root: root)

proc recordPath*(store: CloudLeaseStore; leaseId: string): string =
  store.root / leaseId & ".lease"

proc writeCloudLease*(store: CloudLeaseStore; lease: CloudLease) =
  ## Written to a neighbouring name and renamed, so a reader never sees
  ## half a record — a crash during the write leaves the previous one,
  ## and a crash before the write leaves nothing, and both are states a
  ## reaper can act on.
  let final = recordPath(store, lease.leaseId)
  let temp = final & ".partial"
  writeFile(temp, renderCloudLease(lease))
  moveFile(temp, final)

proc readCloudLease*(store: CloudLeaseStore; leaseId: string): CloudLease =
  let path = recordPath(store, leaseId)
  parseCloudLease(readFile(path), path)

proc removeCloudLease*(store: CloudLeaseStore; leaseId: string) =
  removeFile(recordPath(store, leaseId))

proc listCloudLeases*(store: CloudLeaseStore): seq[CloudLease] =
  if not dirExists(store.root): return
  var paths: seq[string] = @[]
  for _, path in walkDir(store.root):
    if path.endsWith(".lease"): paths.add path
  paths.sort()
  for path in paths:
    result.add parseCloudLease(readFile(path), path)

# ---------------------------------------------------------------------
# Tags — the line of defence that survives losing the store
# ---------------------------------------------------------------------

type
  CloudLeaseTag* = enum
    ## The tags every leased instance carries. An enumeration rather
    ## than a list of strings so a tag cannot be added without a row
    ## that says how its value is derived.
    cltLeaseId = "repro-lease-id"
    cltExpiresAt = "repro-lease-expires-at"
    cltOwner = "repro-lease-owner"

proc leaseTagValue*(lease: CloudLease; tag: CloudLeaseTag): string =
  ## What each tag carries, derived from the record rather than passed
  ## in beside it.
  ##
  ## The owner tag is the process and its start token, and NOT the host.
  ## That is a limit rather than an oversight, and stating it is the
  ## point: both providers constrain a label to a short run of lower-case
  ## characters, a host name does not reliably fit, and a sweeper on a
  ## DIFFERENT host could not use it anyway — it cannot read that host's
  ## process table. So a sweep that has only tags reaps on EXPIRY, and a
  ## sweep that still has the record can additionally reap on a dead
  ## owner. `expiresAt` is therefore the tag that carries the guarantee.
  case tag
  of cltLeaseId: lease.leaseId
  of cltExpiresAt: $lease.expiresAtUnix
  of cltOwner: $lease.ownerPid & "-" & lease.ownerStartToken

proc leaseTagsFor*(lease: CloudLease): seq[(string, string)] =
  for tag in CloudLeaseTag: result.add ($tag, leaseTagValue(lease, tag))

var leaseSerial = 0

proc newLeaseId*(owner: CloudLeaseOwner; now: int64): string =
  ## An identifier that is unique among the leases this host can have
  ## open at once, and that a provider will accept as a label value:
  ## lower case, digits and one separator.
  ##
  ## The serial is not decoration. Written as second-and-process alone
  ## this collided the first time a process took two leases inside one
  ## second — and a collision here is not a cosmetic clash, it is the
  ## SECOND lease overwriting the first one's record, which deletes the
  ## only local knowledge of a machine that is already running. The
  ## process identifier separates two processes; the serial separates
  ## two leases inside one.
  inc leaseSerial
  "rl-" & $now & "-" & $owner.pid & "-" & $leaseSerial

# ---------------------------------------------------------------------
# The provider invocations
# ---------------------------------------------------------------------

proc awsTagSpecification(lease: CloudLease): string =
  var parts = @["{Key=Name,Value=" & lease.instanceName & "}"]
  for pair in leaseTagsFor(lease):
    parts.add "{Key=" & pair[0] & ",Value=" & pair[1] & "}"
  "ResourceType=instance,Tags=[" & parts.join(",") & "]"

proc gcpLabels(lease: CloudLease): string =
  var parts: seq[string] = @[]
  for pair in leaseTagsFor(lease):
    parts.add pair[0] & "=" & pair[1]
  parts.join(",")

proc leasedLaunchPlan*(spec: CloudLaunchSpec; lease: CloudLease;
                       env: CloudEnvLookup = nil): seq[string] =
  ## The launch invocation `cloud_launch` renders, with the lease's tags
  ## on it. The tags are the recovery path, so a launch that carried
  ## none would be an instance nobody can find after the record is lost.
  ##
  ## Built by rewriting the invocation rather than by rendering a second
  ## one: a second renderer is a second answer to what a launch is, and
  ## the two would be kept in step by nobody.
  result = checkedCloudLaunchPlan(spec, env)
  case measurableCloudFor(spec.provider)
  of mcAwsEc2:
    for i in 0 ..< result.len:
      if result[i] == "--tag-specifications" and i + 1 < result.len:
        result[i + 1] = awsTagSpecification(lease)
  of mcGcpCompute:
    result.add "--labels"
    result.add gcpLabels(lease)

proc discoverPlanFor*(lease: CloudLease): seq[string] =
  ## How to find an instance from its lease tag alone. This is what the
  ## write-ahead record buys: an owner that died between asking for an
  ## instance and learning its identifier still leaves something
  ## findable.
  case measurableCloudFor(lease.provider)
  of mcAwsEc2:
    @["aws", "ec2", "describe-instances",
      "--region", lease.region,
      "--filters",
      "Name=tag:" & $cltLeaseId & ",Values=" & lease.leaseId,
      "Name=instance-state-name,Values=pending,running,stopping,stopped",
      "--query", "Reservations[].Instances[].InstanceId",
      "--output", "text"]
  of mcGcpCompute:
    @["gcloud", "compute", "instances", "list",
      "--zones", lease.region,
      "--filter", "labels." & $cltLeaseId & "=" & lease.leaseId,
      "--format", "value(name)"]

proc destroyPlanFor*(lease: CloudLease; instanceId: string): seq[string] =
  ## How to destroy one instance. Takes the identifier rather than
  ## reading it off the lease, because the discovery above can return
  ## more than one and every one of them has to go.
  case measurableCloudFor(lease.provider)
  of mcAwsEc2:
    @["aws", "ec2", "terminate-instances",
      "--region", lease.region,
      "--instance-ids", instanceId]
  of mcGcpCompute:
    @["gcloud", "compute", "instances", "delete", instanceId,
      "--zone", lease.region,
      "--quiet"]

# ---------------------------------------------------------------------
# What to do with a lease
# ---------------------------------------------------------------------

type
  ReapDecision* = enum
    rdHeld
    rdExpired
    rdOrphaned
    rdAlreadyDestroyed

proc reapDecision*(lease: CloudLease; now: int64;
                   liveness: OwnerLiveness): ReapDecision =
  ## The rule, in one place, in the order the answers matter.
  ##
  ## A provably dead owner beats the deadline, and that is the whole
  ## economic point of this module: waiting out a thirty-minute hold on
  ## a machine whose owner exited twenty-nine minutes ago is
  ## twenty-nine minutes of somebody's money. An UNKNOWABLE owner does
  ## not get that treatment — it is not evidence of death, and
  ## destroying a live peer's instance is the one mistake worse than
  ## paying for an idle one. It waits for the deadline like anything
  ## else, which is why the deadline is the tag that travels.
  if lease.state == clsDestroyed: return rdAlreadyDestroyed
  if liveness == olDead: return rdOrphaned
  if now >= lease.expiresAtUnix: return rdExpired
  rdHeld

proc leasedSecondsOf*(lease: CloudLease; now: int64): int64 =
  let until = (if lease.destroyedAtUnix > 0: lease.destroyedAtUnix else: now)
  if until <= lease.acquiredAtUnix: 0'i64 else: until - lease.acquiredAtUnix

proc costMicrosOf*(lease: CloudLease; now: int64): int64 =
  ## Nought when no rate was stated, which the report distinguishes from
  ## a hold that genuinely cost nothing — see `unpriced` below.
  if lease.ratePerHourMicros <= 0: return 0
  leasedSecondsOf(lease, now) * lease.ratePerHourMicros div 3600

proc isPriced*(lease: CloudLease): bool = lease.ratePerHourMicros > 0

# ---------------------------------------------------------------------
# The effector seam
# ---------------------------------------------------------------------

type
  CloudEffectResult* = object
    ## Richer than the launch seam's plain status, because a reap has to
    ## READ an answer: discovering an instance from its tag is a query,
    ## and a query that returns only an exit code has told you nothing.
    status*: int
    output*: string

  CloudLeaseEffector* = proc (effect: CloudEffect): CloudEffectResult {.closure.}

  ReapOutcome* = enum
    roHeld = "held"
    roReaped = "reaped"
    roNothingToDestroy = "nothing-to-destroy"
    roFailed = "failed"

  ReapEvent* = object
    leaseId*: string
    decision*: ReapDecision
    outcome*: ReapOutcome
    instanceIds*: seq[string]
    leasedSeconds*: int64
    costMicros*: int64
    priced*: bool

  ReapReport* = object
    events*: seq[ReapEvent]
    reaped*: int
    held*: int
    nothingToDestroy*: int
    failed*: int
    leasedSeconds*: int64
    costMicros*: int64
    unpriced*: int

proc discoveredIds(output: string): seq[string] =
  ## Both providers answer a plain-text query with whitespace-separated
  ## identifiers, and both spell "none" as an empty answer. `None` is
  ## dropped explicitly because one of them writes that word rather than
  ## nothing when a query matches no instance, and a machine called
  ## `None` is not a thing this will then try to destroy.
  for token in output.splitWhitespace():
    if token.len == 0 or token == "None": continue
    if token notin result: result.add token

proc requireReapEffector*(effector: CloudLeaseEffector; detail: string) =
  ## The ONE site the missing-effector rule is raised from. Both entry
  ## points to a reap — the store-driven sweep and the tag sweep — come
  ## through here rather than each carrying their own copy, because a
  ## rule raised from two places is one a census cannot keep honest: a
  ## site reached twice pays for a site reached never.
  if effector == nil:
    leaseFail(cllReapHasNoEffector, detail)

proc reapOneLease*(lease: var CloudLease; now: int64;
                   decision: ReapDecision;
                   effector: CloudLeaseEffector): ReapEvent =
  ## Destroy what one lease holds. Never swallows a failure: a
  ## non-zero destroy leaves the lease exactly as it was, so the next
  ## sweep tries again, and the event says so.
  result.leaseId = lease.leaseId
  result.decision = decision
  result.priced = isPriced(lease)
  if decision in {rdHeld, rdAlreadyDestroyed}:
    result.outcome = (if decision == rdHeld: roHeld else: roNothingToDestroy)
    result.leasedSeconds = leasedSecondsOf(lease, now)
    result.costMicros = costMicrosOf(lease, now)
    return
  requireReapEffector(effector, "lease " & lease.leaseId & " is " & $decision)
  let envNames = providerEnvNamesFor(lease.provider)
  var ids: seq[string] = @[]
  if lease.providerInstanceId.len > 0:
    ids = @[lease.providerInstanceId]
  else:
    # The write-ahead window. Nothing here knows whether an instance
    # exists, so it goes and looks rather than assuming either way.
    let found = effector(CloudEffect(argv: discoverPlanFor(lease),
      providerEnvNames: envNames))
    if found.status != 0:
      result.outcome = roFailed
      return
    ids = discoveredIds(found.output)
  result.instanceIds = ids
  if ids.len == 0:
    result.outcome = roNothingToDestroy
  else:
    var failed = false
    for id in ids:
      let done = effector(CloudEffect(argv: destroyPlanFor(lease, id),
        providerEnvNames: envNames))
      if done.status != 0: failed = true
    if failed:
      result.outcome = roFailed
      result.leasedSeconds = leasedSecondsOf(lease, now)
      result.costMicros = costMicrosOf(lease, now)
      return
    result.outcome = roReaped
  lease.state = clsDestroyed
  lease.destroyedAtUnix = now
  result.leasedSeconds = leasedSecondsOf(lease, now)
  result.costMicros = costMicrosOf(lease, now)

proc renderLedgerLine*(lease: CloudLease; event: ReapEvent): string =
  ## One closed hold, as one line. Append-only: the store's records are
  ## removed when a lease closes, so if metering lived there it would be
  ## deleted at exactly the moment it became the answer.
  @[lease.leaseId, $lease.provider, lease.region, lease.instanceShape,
    $lease.acquiredAtUnix, $lease.destroyedAtUnix,
    $event.leasedSeconds, $lease.ratePerHourMicros,
    (if event.priced: $event.costMicros else: "unpriced"),
    $event.outcome].join(" ")

proc reapCloudLeases*(store: CloudLeaseStore; now: int64;
                      liveness: OwnerLivenessProbe;
                      effector: CloudLeaseEffector;
                      ledgerPath = ""): ReapReport =
  ## One sweep over every lease this store knows about.
  ##
  ## The sweep COMPLETES. A failure on one lease is recorded and the
  ## next one is still attempted, because a reaper that stops at the
  ## first refusal leaves everything after it running. Turning the
  ## failures into a refusal is `requireReapSucceeded`'s job, once
  ## everything has been tried.
  ##
  ## Order of operations per reaped lease: destroy, then append to the
  ## ledger, then remove the record. A crash anywhere in that sequence
  ## leaves a record the next sweep will act on again, which costs a
  ## second destroy of something already gone and never costs an
  ## instance nobody knows about.
  for original in listCloudLeases(store):
    var lease = original
    let answer = (if liveness == nil: olUnknowable
                  else: liveness(ownerOf(lease)))
    let decision = reapDecision(lease, now, answer)
    let event = reapOneLease(lease, now, decision, effector)
    result.events.add event
    result.leasedSeconds += event.leasedSeconds
    result.costMicros += event.costMicros
    if not event.priced: inc result.unpriced
    case event.outcome
    of roHeld: inc result.held
    of roReaped: inc result.reaped
    of roNothingToDestroy: inc result.nothingToDestroy
    of roFailed: inc result.failed
    if event.outcome in {roReaped, roNothingToDestroy} and
       decision != rdHeld:
      if ledgerPath.len > 0:
        let dir = ledgerPath.parentDir
        if dir.len > 0 and not dirExists(dir): createDir(dir)
        let f = open(ledgerPath, fmAppend)
        f.write(renderLedgerLine(lease, event) & "\n")
        f.close()
      removeCloudLease(store, lease.leaseId)

proc requireReapSucceeded*(report: ReapReport) =
  ## The refusal, after everything has been tried.
  if report.failed > 0:
    var names: seq[string] = @[]
    for event in report.events:
      if event.outcome == roFailed: names.add event.leaseId
    leaseFail(cllDestroyInvocationFailed,
      names.join(", ") & " still stand and will be tried again")

proc outstandingExposure*(store: CloudLeaseStore;
                          now: int64): tuple[leases: int;
                                             leasedSeconds: int64;
                                             costMicros: int64;
                                             unpriced: int] =
  ## What is standing right now, in seconds and in money. The
  ## operator-facing half of metering: a number that answers "what is
  ## this costing me at this moment" without destroying anything to
  ## find out.
  for lease in listCloudLeases(store):
    if lease.state == clsDestroyed: continue
    inc result.leases
    result.leasedSeconds += leasedSecondsOf(lease, now)
    result.costMicros += costMicrosOf(lease, now)
    if not isPriced(lease): inc result.unpriced

# ---------------------------------------------------------------------
# The sweep that needs no store at all
# ---------------------------------------------------------------------

type
  TaggedInstance* = object
    ## One instance as the PROVIDER describes it, reconstructed from its
    ## tags alone. This is the third line of defence: everything here
    ## came off the cloud, so it survives the local store being deleted,
    ## the host being reinstalled, and the run having happened on
    ## somebody else's machine.
    id*: string
    leaseId*: string
    expiresAtUnix*: int64

proc tagSweepPlanFor*(provider: CloudProvider; region: string): seq[string] =
  ## Every instance in one region that carries a lease identifier, with
  ## the two tags a decision needs. Deliberately keyed on the PRESENCE
  ## of the lease tag rather than on a particular lease: a sweeper
  ## running this has no list of leases to check against, which is the
  ## situation it exists for.
  case measurableCloudFor(provider)
  of mcAwsEc2:
    @["aws", "ec2", "describe-instances",
      "--region", region,
      "--filters", "Name=tag-key,Values=" & $cltLeaseId,
      "Name=instance-state-name,Values=pending,running,stopping,stopped",
      "--query", "Reservations[].Instances[].[InstanceId," &
        "Tags[?Key=='" & $cltLeaseId & "']|[0].Value," &
        "Tags[?Key=='" & $cltExpiresAt & "']|[0].Value]",
      "--output", "text"]
  of mcGcpCompute:
    @["gcloud", "compute", "instances", "list",
      "--zones", region,
      "--filter", "labels." & $cltLeaseId & ":*",
      "--format", "value(name,labels." & $cltLeaseId &
        ",labels." & $cltExpiresAt & ")"]

proc parseTaggedInstances*(listing: string): seq[TaggedInstance] =
  ## Both providers answer the query above with one instance per line
  ## and the three columns separated by whitespace. A line that is not
  ## three readable columns is SKIPPED rather than guessed at: this
  ## sweeper destroys things, and the one input it must never
  ## misinterpret is the list of what to destroy.
  for line in listing.splitLines():
    let cols = line.splitWhitespace()
    if cols.len < 3: continue
    var expires = 0'i64
    try:
      expires = parseBiggestInt(cols[2])
    except ValueError:
      continue
    if cols[0].len == 0 or cols[1].len == 0: continue
    result.add TaggedInstance(id: cols[0], leaseId: cols[1],
      expiresAtUnix: expires)

proc expiredTaggedInstances*(all: seq[TaggedInstance];
                             now: int64): seq[TaggedInstance] =
  ## Expiry is the ONLY rule a store-less sweep applies, and that is the
  ## design rather than a shortfall. The owner tag names a process
  ## identifier, and a sweeper that is not on the owner's host cannot
  ## read that host's process table — so a dead-owner rule here would be
  ## a guess, and the thing it would guess about is whether to destroy
  ## somebody's running machine. The deadline is a fact the tag carries.
  for instance in all:
    if now >= instance.expiresAtUnix: result.add instance

proc reapExpiredByTag*(provider: CloudProvider; region: string;
                       now: int64;
                       effector: CloudLeaseEffector): ReapReport =
  ## The sweep of last resort. Finds instances by their tags, destroys
  ## the expired ones, and never opens the local store.
  requireReapEffector(effector,
    "a tag sweep of " & $provider & " in " & region)
  let envNames = providerEnvNamesFor(provider)
  let listed = effector(CloudEffect(argv: tagSweepPlanFor(provider, region),
    providerEnvNames: envNames))
  if listed.status != 0:
    result.failed = 1
    result.events.add ReapEvent(leaseId: "", decision: rdExpired,
      outcome: roFailed)
    return
  let expired = expiredTaggedInstances(parseTaggedInstances(listed.output),
    now)
  if expired.len == 0:
    result.nothingToDestroy = 1
    return
  for instance in expired:
    var stub = CloudLease(leaseId: instance.leaseId, provider: provider,
      region: region, expiresAtUnix: instance.expiresAtUnix)
    let done = effector(CloudEffect(
      argv: destroyPlanFor(stub, instance.id), providerEnvNames: envNames))
    var event = ReapEvent(leaseId: instance.leaseId, decision: rdExpired,
      instanceIds: @[instance.id])
    if done.status == 0:
      event.outcome = roReaped
      inc result.reaped
    else:
      event.outcome = roFailed
      inc result.failed
    result.events.add event

proc renderReapPlanText*(store: CloudLeaseStore; now: int64;
                         liveness: OwnerLivenessProbe): string =
  ## What a sweep WOULD do, without an effector and therefore without
  ## doing any of it.
  ##
  ## The operator-facing half, and the same shape the launch side takes:
  ## one argument per line, because an invocation printed as a single
  ## line invites being pasted into a shell and these are the
  ## invocations that destroy things.
  var standing = 0
  for lease in listCloudLeases(store):
    let answer = (if liveness == nil: olUnknowable
                  else: liveness(ownerOf(lease)))
    let decision = reapDecision(lease, now, answer)
    result.add "lease: " & lease.leaseId & "\n"
    result.add "  provider: " & $lease.provider & "\n"
    result.add "  region: " & lease.region & "\n"
    result.add "  instance-name: " & lease.instanceName & "\n"
    result.add "  state: " & $lease.state & "\n"
    result.add "  owner-liveness: " & $answer & "\n"
    result.add "  decision: " & $decision & "\n"
    result.add "  leased-seconds: " & $leasedSecondsOf(lease, now) & "\n"
    result.add "  cost-micros: " &
      (if isPriced(lease): $costMicrosOf(lease, now) else: "unpriced") & "\n"
    for tag in CloudLeaseTag:
      result.add "  tag " & $tag & ": " & leaseTagValue(lease, tag) & "\n"
    if decision notin {rdHeld, rdAlreadyDestroyed}:
      inc standing
      let argv = (if lease.providerInstanceId.len > 0:
                    destroyPlanFor(lease, lease.providerInstanceId)
                  else: discoverPlanFor(lease))
      result.add "  would-run:\n"
      for arg in argv: result.add "    " & arg & "\n"
  let exposure = outstandingExposure(store, now)
  result.add "outstanding-leases: " & $exposure.leases & "\n"
  result.add "outstanding-leased-seconds: " & $exposure.leasedSeconds & "\n"
  result.add "outstanding-cost-micros: " & $exposure.costMicros & "\n"
  result.add "outstanding-unpriced: " & $exposure.unpriced & "\n"
  result.add "reapable-now: " & $standing & "\n"

# ---------------------------------------------------------------------
# Teardown on every exit path the process lives to see
# ---------------------------------------------------------------------

type
  CloudLeaseHolder* = ref object
    ## One held lease, and the one place that releases it. A reference
    ## so the exit procedure, the signal handler and the `finally` are
    ## all talking about the same object, and so releasing twice is
    ## cheap rather than wrong.
    store*: CloudLeaseStore
    lease*: CloudLease
    effector*: CloudLeaseEffector
    ledgerPath*: string
    released*: bool
    releases*: int
      ## How many times release was ATTEMPTED. A count rather than a
      ## flag, so a gate can tell "never released" from "released and
      ## said nothing", and so a second attempt on a different exit path
      ## is visible rather than invisible.

proc acquireCloudLease*(store: CloudLeaseStore; spec: CloudLaunchSpec;
                        policy: LeasePolicy; now: int64;
                        ratePerHourMicros: int64 = 0;
                        effector: CloudLeaseEffector = nil;
                        ledgerPath = ""): CloudLeaseHolder =
  ## Take a lease and write it down BEFORE anything is created.
  ##
  ## The record is on disk when this returns, so from here on a crash at
  ## any point leaves something the reaper can act on. That is the
  ## whole reason this is a separate step from the launch.
  let owner = thisProcessOwner()
  var lease = newCloudLease(newLeaseId(owner, now), spec, policy, owner,
    now, ratePerHourMicros)
  # A record is never written over. If an identifier is somehow already
  # taken — a process number reused inside one second, a store shared by
  # two hosts whose clocks agree — the next one is minted instead, because
  # the record being overwritten would be the only local trace of an
  # instance that is already running.
  while fileExists(recordPath(store, lease.leaseId)):
    lease.leaseId = newLeaseId(owner, now)
  writeCloudLease(store, lease)
  CloudLeaseHolder(store: store, lease: lease, effector: effector,
    ledgerPath: ledgerPath, released: false, releases: 0)

proc recordInstanceCreated*(holder: CloudLeaseHolder; instanceId: string) =
  ## The provider has answered. Written through the store immediately,
  ## because the window this closes is the one the discovery path exists
  ## for and every second it stays open is a second of it.
  holder.lease.providerInstanceId = instanceId
  holder.lease.state = clsCreated
  writeCloudLease(holder.store, holder.lease)

proc releaseCloudLease*(holder: CloudLeaseHolder; now: int64): ReapEvent =
  ## Destroy what this lease holds, whatever brought us here.
  ##
  ## Idempotent on purpose: the `finally`, the exit procedure and a
  ## signal handler may all reach it, and the second arrival must be a
  ## cheap no-operation rather than a second destroy or an exception on
  ## the way out of a process that is already leaving.
  inc holder.releases
  if holder.released:
    result.leaseId = holder.lease.leaseId
    result.outcome = roNothingToDestroy
    return
  holder.released = true
  result = reapOneLease(holder.lease, now, rdExpired, holder.effector)
  if result.outcome != roFailed:
    if holder.ledgerPath.len > 0:
      let dir = holder.ledgerPath.parentDir
      if dir.len > 0 and not dirExists(dir): createDir(dir)
      let f = open(holder.ledgerPath, fmAppend)
      f.write(renderLedgerLine(holder.lease, result) & "\n")
      f.close()
    removeCloudLease(holder.store, holder.lease.leaseId)
  else:
    # Put the failure back on the disk so the next sweep sees it, and
    # leave `released` set so this process does not spin on it.
    writeCloudLease(holder.store, holder.lease)

template withCloudLease*(holder: CloudLeaseHolder; body: untyped) =
  ## Run `body` and release the lease afterwards, on EVERY path out of
  ## it: a normal return, an exception, and a `quit` from inside it.
  ##
  ## The exit procedure is the half that is easy to forget and is the
  ## half that catches `quit`, which a `finally` does not see at all.
  ## Both reach the same idempotent release, so arriving twice is free.
  block:
    let h = holder
    addExitProc(proc () {.closure.} =
      if not h.released:
        try:
          discard releaseCloudLease(h, getTime().toUnix)
        except CatchableError:
          discard)
    try:
      body
    finally:
      discard releaseCloudLease(h, getTime().toUnix)

# ---------------------------------------------------------------------
# The two signals a process can catch — and the one it cannot
# ---------------------------------------------------------------------

when defined(posix):
  import std/posix

  var signalHolders: seq[CloudLeaseHolder] = @[]

  proc releaseHeldLeasesOnSignal(sig: cint) {.noconv.} =
    ## Every lease this process still holds, released, and then out.
    ##
    ## A handler that does this much is not what a textbook calls
    ## async-signal-safe, and the alternative — set a flag and hope
    ## somebody reads it — does nothing at all for a process sitting in
    ## a blocking wait, which is the process this is for. The exchange
    ## is deliberate: the cost of the unsafety is a possible crash on
    ## the way out, and the cost of the flag is a machine that keeps
    ## billing.
    for holder in signalHolders:
      if not holder.released:
        try:
          discard releaseCloudLease(holder, getTime().toUnix)
        except CatchableError:
          discard
    # Die OF the signal rather than of an exit code that stands for it.
    #
    # `quit(128 + n)` is the obvious spelling and it does not work: this
    # Nim clamps every exit code above 127 to 127, so `SIGTERM`,
    # `SIGINT` and `SIGHUP` would all report the same status and a
    # caller could not tell them apart — or tell any of them from a
    # genuine 127. Measured, not assumed. Restoring the default
    # disposition and re-raising gives the process the termination
    # status the convention actually describes.
    discard signal(sig, SIG_DFL)
    discard kill(getpid(), sig)

  proc installCloudLeaseSignalTeardown*(holder: CloudLeaseHolder) =
    ## Add a holder to the set the signal handler releases, and install
    ## the handler the first time.
    ##
    ## `SIGKILL` is deliberately not in the list, and cannot be: it is
    ## the exit path no process observes, and it is the reaper's to
    ## answer rather than this procedure's. That division is the reason
    ## both halves exist.
    if signalHolders.len == 0:
      discard signal(SIGTERM, releaseHeldLeasesOnSignal)
      discard signal(SIGINT, releaseHeldLeasesOnSignal)
      discard signal(SIGHUP, releaseHeldLeasesOnSignal)
    signalHolders.add holder

  proc cloudLeaseSignalHolderCount*(): int = signalHolders.len

else:
  proc installCloudLeaseSignalTeardown*(holder: CloudLeaseHolder) =
    ## This platform is not one this build installs handlers on, so the
    ## reaper is the only line of defence here. Said out loud rather
    ## than left as an empty body somebody reads as coverage.
    discard

  proc cloudLeaseSignalHolderCount*(): int = 0
