## Platform-And-Filesystem-Facts **F3** and **F4** — policy reading the
## declared facts, and what happens when there are none.
##
## Spec: ``reprobuild-specs/Platform-And-Filesystem-Facts.milestones.org``
##       §F3 "Policy reads the facts", §F4 "Unknown filesystems".
##
## F2's suite checks the CONSTANTS against reality. This one checks the
## POLICY against the constants, which is a different claim and needs its
## own assertions:
##
## 1. **An attempt whose outcome the constants already determine is not
##    issued.** Asserted on a syscall COUNTER
##    (``linkAttemptsIssued``), never on elapsed time: a timing
##    assertion measures the machine, and the claim here is about the
##    code.
## 2. **Pair reachability is still probed.** The constants cannot know
##    which Btrfs subvolume a path is in, so a pair the table permits
##    and the filesystem refuses must still degrade to copy — driven
##    here across two real volumes.
## 3. **A disagreement between the two is surfaced.** ``verdictFor`` and
##    ``disagreementKind`` are pure, so both are driven over their whole
##    input space here rather than only on the two filesystems this host
##    happens to have. The end-to-end direction is driven by MUTATING a
##    constant; see the milestone's mutation table.
## 4. **A filesystem with no table row degrades to probe-everything and
##    is reported.** Twelve of the fourteen rows describe filesystems
##    this host does not have and the fifteenth does not exist, so the
##    unrowed case is exercised with synthetic endpoints — the same
##    technique the pure functions above exist to make possible.
##
## **The probe is not replaced and must not be.** Several cases here
## exist specifically to pin that: the constants may only ever REMOVE an
## attempt, never add a capability, and a mechanism reported available
## is always one an attempt produced.

import std/[os, strutils, unittest]

from repro_core/paths import extendedPath

import repro_fs_facts
import repro_cas_store

# ---------------------------------------------------------------------------
# Host volume discovery — same shape as t_link_capability_probe.nim's, so a
# reader comparing the two files is comparing the assertions rather than the
# scaffolding.
# ---------------------------------------------------------------------------

type
  FactVolume = object
    dir*: string
    fsName*: string      ## Diagnostic only.
    obs*: FilesystemObservation
    pairKey*: string

var scratchDirs: seq[string] = @[]

proc claimScratchDir(parent: string; tag: string): string =
  if parent.len == 0 or not dirExists(extendedPath(parent)):
    return ""
  let candidate = parent / ("repro-f3-" & $getCurrentProcessId() & "-" & tag)
  try:
    createDir(extendedPath(candidate))
    let witness = candidate / "witness"
    writeFile(extendedPath(witness), "ok")
    removeFile(extendedPath(witness))
  except CatchableError, Defect:
    return ""
  scratchDirs.add(candidate)
  candidate

proc candidateParents(): seq[string] =
  result = @[getTempDir()]
  when defined(windows):
    for letter in 'A' .. 'Z':
      result.add($letter & ":\\")
  else:
    for p in ["/tmp", "/var/tmp", "/dev/shm", getHomeDir()]:
      result.add(p)
  result.add(currentSourcePath().parentDir())

proc discoverVolumes(): seq[FactVolume] =
  result = @[]
  var seenKeys: seq[string] = @[]
  var tag = 0
  for parent in candidateParents():
    if parent.len == 0 or not dirExists(extendedPath(parent)):
      continue
    let key = filesystemPairKey(parent, parent)
    if key in seenKeys:
      continue
    let dir = claimScratchDir(parent, "vol" & $tag)
    tag.inc
    if dir.len == 0:
      continue
    seenKeys.add(key)
    result.add(FactVolume(dir: dir, fsName: filesystemName(dir),
                          obs: observeFilesystem(dir),
                          pairKey: filesystemPairKey(dir, dir)))

let volumes = discoverVolumes()

proc primaryVolume(): FactVolume =
  doAssert volumes.len > 0,
    "no writable scratch directory could be created on this host; F3's " &
    "policy cannot be exercised at all"
  volumes[0]

proc volumeWithout(mechanism: LinkMechanism): seq[FactVolume] =
  ## Volumes whose table row declares ``mechanism`` definitely absent —
  ## the population whose attempts F3 must not issue. On this
  ## development host that is the NTFS volume for ``lmReflink``.
  result = @[]
  for v in volumes:
    if v.obs.status != teKnown:
      continue
    let facts = filesystemFacts(v.obs.id)
    let declared =
      if mechanism == lmReflink: facts.reflink.value
      else: facts.hardlinks.value
    if declared == tnNo:
      result.add(v)

proc volumeWith(mechanism: LinkMechanism): seq[FactVolume] =
  result = @[]
  for v in volumes:
    if v.obs.status != teKnown:
      continue
    let facts = filesystemFacts(v.obs.id)
    let declared =
      if mechanism == lmReflink: facts.reflink.value
      else: facts.hardlinks.value
    if declared == tnYes:
      result.add(v)

# ---------------------------------------------------------------------------
# Synthetic endpoints
#
# The pure half of F3's policy takes a ``DeclaredPair`` and nothing else,
# which is what makes it drivable for the twelve filesystems this host does
# not have. These helpers build one from a REAL table row, so the cases
# below assert against the shipped constants rather than against numbers
# retyped into a test.
# ---------------------------------------------------------------------------

proc rowEndpoint(id: FilesystemId; volumeKey = "vol-a"): DeclaredEndpoint =
  let f = filesystemFacts(id)
  DeclaredEndpoint(
    status: teKnown, reportedName: f.names[0], volumeKey: volumeKey,
    id: id, hardlinks: f.hardlinks.value, reflink: f.reflink.value,
    hardlinkCitation: f.hardlinks.citation,
    reflinkCitation: f.reflink.citation)

proc unrowedEndpoint(name: string; volumeKey = "vol-a";
                     status = teUnknown): DeclaredEndpoint =
  DeclaredEndpoint(
    status: status, reportedName: name, volumeKey: volumeKey,
    id: fsNtfs, hardlinks: tnUnknown, reflink: tnUnknown,
    notice: "synthetic notice for " & name)

proc pairOf(a, b: DeclaredEndpoint): DeclaredPair =
  DeclaredPair(source: a, dest: b,
               sameFilesystem: a.volumeKey.len > 0 and
                               a.volumeKey == b.volumeKey)

const AllOutcomes = [loOk, loCrossDevice, loUnsupported,
                     loLinkLimitExceeded, loPermissionDenied, loOther,
                     loNotAttempted]

# ---------------------------------------------------------------------------

suite "F3 declared verdict — what the constants determine":
  test "copy is always possible and never consults a row":
    # The arm that cannot be unavailable must not become conditional on
    # a table, or the spec's promise that correctness never depends on
    # the mechanism stops holding on an unrowed filesystem.
    check verdictFor(lmCopy, pairOf(rowEndpoint(fsNtfs),
                                    rowEndpoint(fsNtfs))) == fvPossible
    check verdictFor(lmCopy, pairOf(unrowedEndpoint("zzfs"),
                                    unrowedEndpoint("zzfs"))) == fvPossible
    check verdictFor(lmCopy, pairOf(rowEndpoint(fsFat32),
                                    rowEndpoint(fsFat32))) == fvPossible

  test "a definite no at EITHER endpoint makes a mechanism impossible":
    # A clone into NTFS cannot work however capable the source is, and
    # the same the other way round. Both orders are asserted because a
    # one-sided implementation passes half of this.
    let refs = rowEndpoint(fsRefs)
    let ntfs = rowEndpoint(fsNtfs)
    check verdictFor(lmReflink, pairOf(refs, ntfs)) == fvImpossible
    check verdictFor(lmReflink, pairOf(ntfs, refs)) == fvImpossible
    check verdictFor(lmReflink, pairOf(ntfs, ntfs)) == fvImpossible
    # FAT32 declares no hardlinks: a FAT directory entry IS the file's
    # metadata, so a file cannot be named twice.
    let fat = rowEndpoint(fsFat32)
    check verdictFor(lmHardlink, pairOf(fat, refs)) == fvImpossible
    check verdictFor(lmHardlink, pairOf(refs, fat)) == fvImpossible

  test "yes at both endpoints is possible, which is not the same as available":
    # ``fvPossible`` must NOT shortcut the probe. What it licenses is
    # calling a later ``loUnsupported`` a disagreement — nothing else.
    check verdictFor(lmReflink, pairOf(rowEndpoint(fsRefs),
                                       rowEndpoint(fsRefs))) == fvPossible
    check verdictFor(lmHardlink, pairOf(rowEndpoint(fsNtfs),
                                        rowEndpoint(fsNtfs))) == fvPossible
    check verdictFor(lmHardlink, pairOf(rowEndpoint(fsBtrfs),
                                        rowEndpoint(fsBtrfs))) == fvPossible

  test "varies degrades to indefinite rather than to a value":
    # The network and union rows are F4's own subject: each declares
    # `varies` because the answer belongs to a server or to an upper
    # layer. `varies` must reach policy as "probe", never as a no (which
    # would remove an attempt that might have worked) and never as a yes
    # (which would license a false disagreement).
    for id in [fsNfs, fsSmb, fsOverlayfs]:
      let ep = rowEndpoint(id)
      check filesystemFacts(id).reflink.value == tnVaries
      check verdictFor(lmReflink, pairOf(ep, ep)) == fvIndefinite
      check verdictFor(lmHardlink, pairOf(ep, ep)) == fvIndefinite
    # And an indefinite endpoint does not rescue a definite no at the
    # other end: impossible still wins.
    check verdictFor(lmReflink, pairOf(rowEndpoint(fsNfs),
                                       rowEndpoint(fsNtfs))) == fvImpossible

  test "the real NTFS and ReFS rows produce the verdicts F3 relies on":
    # Read straight off the shipped table rather than restated here, so
    # a change to either row moves this case instead of leaving it
    # asserting a number the table no longer carries.
    check filesystemFacts(fsNtfs).reflink.value == tnNo
    check filesystemFacts(fsNtfs).hardlinks.value == tnYes
    check filesystemFacts(fsRefs).reflink.value == tnYes
    check filesystemFacts(fsRefs).hardlinks.value == tnYes
    check filesystemFacts(fsNtfs).cloneOperation.value == clNone

suite "F3 declared verdict — the unrowed short-circuit (F4)":
  test "an endpoint with no row short-circuits, whatever the other says":
    # The F4 degradation rule, in the one function that could break it:
    # nothing is determined, so nothing is skipped. Asserted against a
    # ReFS endpoint that DOES declare reflink, to prove the known side
    # cannot carry the verdict on its own.
    let unrowed = unrowedEndpoint("zzfs")
    for known in [fsNtfs, fsRefs, fsFat32]:
      let ep = rowEndpoint(known)
      check verdictFor(lmReflink, pairOf(unrowed, ep)) == fvNoTableEntry
      check verdictFor(lmReflink, pairOf(ep, unrowed)) == fvNoTableEntry
      check verdictFor(lmHardlink, pairOf(unrowed, ep)) == fvNoTableEntry
      check verdictFor(lmHardlink, pairOf(ep, unrowed)) == fvNoTableEntry

  test "no row outranks a definite no, in either position":
    # The precedence, stated as its own case because the first draft got
    # it wrong in a way that only showed up in ONE of the two orders:
    # NTFS's `reflink = no` was reached first and answered `impossible`
    # for a pair whose other end nothing in the table describes. A
    # verdict that depends on which endpoint the loop visited first is
    # not a verdict about a pair.
    let unrowed = unrowedEndpoint("zzfs")
    # NTFS declares reflink = no; FAT32 declares hardlinks = no. Both
    # are the strongest thing the table can say, and both must still
    # lose to "the table has not described this pair".
    check verdictFor(lmReflink,
                     pairOf(rowEndpoint(fsNtfs), unrowed)) == fvNoTableEntry
    check verdictFor(lmReflink,
                     pairOf(unrowed, rowEndpoint(fsNtfs))) == fvNoTableEntry
    check verdictFor(lmHardlink,
                     pairOf(rowEndpoint(fsFat32), unrowed)) == fvNoTableEntry
    check verdictFor(lmHardlink,
                     pairOf(unrowed, rowEndpoint(fsFat32))) == fvNoTableEntry
    # Where BOTH ends have rows, a definite no still wins over an
    # indefinite value, and again in either position.
    let nfs = rowEndpoint(fsNfs)
    check verdictFor(lmReflink,
                     pairOf(rowEndpoint(fsNtfs), nfs)) == fvImpossible
    check verdictFor(lmReflink,
                     pairOf(nfs, rowEndpoint(fsNtfs))) == fvImpossible

  test "a deliberate non-entry degrades exactly like an unknown one":
    # F4's rule is IDENTICAL for both; only the report differs. A policy
    # that treated a documented deferral as licence to borrow a
    # neighbouring row would be the ext4-aliasing defect all over again.
    let deferred = unrowedEndpoint("ext3", status = teDeferred)
    let unknown = unrowedEndpoint("zzfs", status = teUnknown)
    let refs = rowEndpoint(fsRefs)
    check verdictFor(lmReflink, pairOf(deferred, refs)) == fvNoTableEntry
    check verdictFor(lmReflink, pairOf(unknown, refs)) == fvNoTableEntry
    check verdictFor(lmHardlink, pairOf(deferred, refs)) == fvNoTableEntry
    check verdictFor(lmHardlink, pairOf(unknown, refs)) == fvNoTableEntry

  test "an unqueried endpoint is no information, not no capability":
    let unqueried = unrowedEndpoint("", status = teUnqueried)
    check verdictFor(lmReflink,
                     pairOf(unqueried, rowEndpoint(fsRefs))) == fvNoTableEntry
    check verdictFor(lmHardlink,
                     pairOf(unqueried, rowEndpoint(fsNtfs))) == fvNoTableEntry

suite "F3 disagreement detection — the only place the two are compared":
  test "a declared-possible mechanism answering unsupported disagrees":
    check disagreementKind(fvPossible, issued = true,
                           outcome = loUnsupported,
                           sameFilesystem = true) ==
      fdDeclaredPossibleButUnsupported

  test "only loUnsupported contradicts a declared capability":
    # The exclusions carry the weight here. Cross-device is pair
    # reachability, a link-count limit is a per-file property, denial is
    # the caller's, and loOther is undiagnosed — none of them says the
    # filesystem lacks the operation, and reporting any of them as a
    # table defect would train a reader to ignore the report.
    for outcome in AllOutcomes:
      let kind = disagreementKind(fvPossible, issued = true,
                                  outcome = outcome, sameFilesystem = true)
      if outcome == loUnsupported:
        check kind == fdDeclaredPossibleButUnsupported
      else:
        check kind == fdNone

  test "a declared-impossible mechanism that WORKS disagrees":
    for outcome in AllOutcomes:
      let kind = disagreementKind(fvImpossible, issued = true,
                                  outcome = outcome, sameFilesystem = true)
      if outcome == loOk:
        check kind == fdDeclaredImpossibleButWorked
      else:
        check kind == fdNone

  test "an attempt that was never issued cannot disagree with anything":
    # This is the asymmetry the audit mode exists to close, and it must
    # be explicit rather than incidental: without an attempt there is no
    # observation, and a deduction cannot contradict itself.
    for verdict in [fvNoTableEntry, fvIndefinite, fvPossible, fvImpossible]:
      for outcome in AllOutcomes:
        check disagreementKind(verdict, issued = false, outcome = outcome,
                               sameFilesystem = true) == fdNone

  test "a pair spanning two filesystems never raises a disagreement":
    # A cross-volume reflink on Windows answers ERROR_INVALID_PARAMETER,
    # which classifies loUnsupported. Without this guard every
    # cross-volume materialization on this host would report a defect in
    # NTFS's row — a false contradiction, which is the worst outcome for
    # a conformance mechanism because it teaches distrust of the
    # mechanism rather than of the row.
    for verdict in [fvNoTableEntry, fvIndefinite, fvPossible, fvImpossible]:
      for outcome in AllOutcomes:
        check disagreementKind(verdict, issued = true, outcome = outcome,
                               sameFilesystem = false) == fdNone

  test "an indefinite or absent declaration cannot be contradicted":
    # `varies` is consistent with every observation; that is what makes
    # it an honest value rather than an evasion.
    for verdict in [fvNoTableEntry, fvIndefinite]:
      for outcome in AllOutcomes:
        check disagreementKind(verdict, issued = true, outcome = outcome,
                               sameFilesystem = true) == fdNone

suite "F3 — an attempt the constants determine is NOT issued":
  test "no reflink attempt is issued against a filesystem declared to have none":
    let targets = volumeWithout(lmReflink)
    if targets.len == 0:
      checkpoint("no volume on this host has a table row declaring " &
                 "reflink = no; the skip arm was NOT exercised")
      check volumes.len >= 1
    else:
      for vol in targets:
        var cache: LinkCapabilityCache
        resetLinkAttemptCounters()
        let before = linkAttemptsIssued(lmReflink)
        let cap = probeLinkCapabilities(cache, vol.dir, vol.dir)
        checkpoint(vol.dir & " fs=" & vol.fsName & " -> " & cap.describe())
        check cap.probed
        # A COUNTER, not a stopwatch: the claim is that the syscall was
        # never made, and only a counter can say that.
        check linkAttemptsIssued(lmReflink) == before
        check cap.reflinkVerdict == fvImpossible
        check cap.reflinkAttempt.outcome == loNotAttempted
        check not cap.reflink
        check lmReflink notin cap.preferredMechanisms()

  test "the skipped attempt records WHY, naming the row that ruled it out":
    let targets = volumeWithout(lmReflink)
    if targets.len == 0:
      checkpoint("no volume on this host declares reflink = no; the " &
                 "skip-message arm was NOT exercised")
      check volumes.len >= 1
    else:
      var cache: LinkCapabilityCache
      let cap = probeLinkCapabilities(cache, targets[0].dir, targets[0].dir)
      let msg = cap.reflinkAttempt.message
      checkpoint(msg)
      # "not attempted" with no reason attached is indistinguishable
      # from a probe that quietly stopped running.
      check "NOT attempted" in msg
      check $targets[0].obs.id in msg
      check "reflink=no" in msg
      # ...and it reaches the caller's own log line rather than waiting
      # to be asked for.
      check "loNotAttempted" in cap.describe()

  test "the attempt IS issued where the table does not rule it out":
    # The other half, and the one that stops the skip from being a
    # silent "never probe anything": every mechanism the constants do
    # not determine must still cost a syscall.
    for vol in volumes:
      var cache: LinkCapabilityCache
      resetLinkAttemptCounters()
      let cap = probeLinkCapabilities(cache, vol.dir, vol.dir)
      check cap.probed
      check linkAttemptsIssued(lmHardlink) ==
        (if cap.hardlinkVerdict == fvImpossible: 0 else: 1)
      check linkAttemptsIssued(lmReflink) ==
        (if cap.reflinkVerdict == fvImpossible: 0 else: 1)

  test "the audit mode issues the attempt the constants ruled out":
    # The one way the "table says no but it works" direction becomes
    # observable in place. It costs exactly the syscalls F3 exists to
    # avoid, which is why it is off by default rather than merely
    # discouraged.
    let targets = volumeWithout(lmReflink)
    if targets.len == 0:
      checkpoint("no volume on this host declares reflink = no; the " &
                 "audit arm was NOT exercised")
      check volumes.len >= 1
    else:
      var cache: LinkCapabilityCache
      cache.setFactAudit(true)
      check cache.factAudit()
      resetLinkAttemptCounters()
      let cap = probeLinkCapabilities(cache, targets[0].dir, targets[0].dir)
      check cap.probed
      check linkAttemptsIssued(lmReflink) == 1
      # The row said no and the operation agreed, so there is nothing to
      # report. Had it succeeded, the disagreement would be here.
      check cap.reflinkAttempt.outcome != loNotAttempted
      check not cap.reflink
      check cap.disagreements.len == 0

  test "switching the audit on or off drops answers derived under the other":
    let vol = primaryVolume()
    var cache: LinkCapabilityCache
    discard probeLinkCapabilities(cache, vol.dir, vol.dir)
    check cache.probeCount() == 1
    cache.setFactAudit(true)
    check cache.probeCount() == 0
    check cache.cachedPairCount() == 0
    discard probeLinkCapabilities(cache, vol.dir, vol.dir)
    check cache.probeCount() == 1
    # Setting it to what it already is must not throw the memo away.
    cache.setFactAudit(true)
    check cache.probeCount() == 1

  test "linkAttemptsIssued counts real attempts and copy is never one":
    let vol = primaryVolume()
    resetLinkAttemptCounters()
    check linkAttemptsIssued(lmHardlink) == 0
    check linkAttemptsIssued(lmReflink) == 0
    check linkAttemptsIssued(lmCopy) == 0
    let src = vol.dir / "counter-src.bin"
    writeFile(extendedPath(src), "counted")
    discard attemptHardlink(src, vol.dir / "counter-dst.bin")
    check linkAttemptsIssued(lmHardlink) == 1
    check linkAttemptsIssued(lmReflink) == 0
    discard attemptReflink(src, vol.dir / "counter-clone.bin")
    check linkAttemptsIssued(lmReflink) == 1
    check linkAttemptsIssued(lmCopy) == 0
    for p in ["counter-src.bin", "counter-dst.bin", "counter-clone.bin"]:
      try: removeFile(extendedPath(vol.dir / p))
      except CatchableError: discard

suite "F3 — pair reachability is still the probe's question":
  test "a pair the constants allow but the filesystem refuses degrades to copy":
    # The distinction the whole initiative rests on. Both endpoints
    # declare hardlinks = yes, so the constants permit the mechanism;
    # the operation still answers cross-device, and the answer that
    # reaches policy is the operation's.
    let usable = volumeWith(lmHardlink)
    if usable.len < 2:
      checkpoint("fewer than two volumes with a hardlink-declaring row " &
                 "on this host; the pair-reachability arm was NOT " &
                 "exercised")
      check volumes.len >= 1
    else:
      let a = usable[0]
      let b = usable[1]
      var cache: LinkCapabilityCache
      let cap = probeLinkCapabilities(cache, a.dir, b.dir)
      checkpoint(a.dir & " (" & a.fsName & ") -> " & b.dir & " (" &
                 b.fsName & "): " & cap.describe())
      check cap.probed
      # The table permits it...
      check cap.hardlinkVerdict == fvPossible
      # ...the filesystem does not, and the filesystem wins.
      check not cap.hardlink
      check cap.hardlinkAttempt.outcome == loCrossDevice
      check cap.preferredMechanisms() == @[lmCopy]
      # And a refusal on a cross-filesystem pair is NOT a table defect.
      check cap.disagreements.len == 0

  test "the constants never turn a mechanism ON":
    # There is no path through this module by which a declared `yes`
    # becomes a reported capability. Every reported capability is an
    # attempt's own answer.
    for vol in volumes:
      var cache: LinkCapabilityCache
      let cap = probeLinkCapabilities(cache, vol.dir, vol.dir)
      check cap.hardlink == (cap.hardlinkAttempt.outcome == loOk)
      check cap.reflink == (cap.reflinkAttempt.outcome == loOk)
      # A skipped arm is reported unavailable, never available.
      if cap.hardlinkAttempt.outcome == loNotAttempted:
        check not cap.hardlink
      if cap.reflinkAttempt.outcome == loNotAttempted:
        check not cap.reflink

  test "the capability record names the filesystems it reasoned about":
    let vol = primaryVolume()
    var cache: LinkCapabilityCache
    let cap = probeLinkCapabilities(cache, vol.dir, vol.dir)
    check cap.declared.sameFilesystem
    check cap.declared.source.reportedName.len > 0
    check cap.declared.source.status == vol.obs.status
    check "fs=" in cap.describe()

  test "the fallback pair key folds case exactly as the OS table says":
    # A path that cannot be opened has no device identity, so the key
    # falls back to the paths themselves. That fallback used to lowercase
    # BOTH of them unconditionally, which filed `/srv/A` and `/srv/a` —
    # two different directories on any case-sensitive host, with
    # potentially different answers — under one entry. It now reads
    # `pathLookupIsCaseSensitive` from the OS table.
    let vol = primaryVolume()
    let upper = vol.dir / "NoSuchDirectory-A"
    let lower = vol.dir / "nosuchdirectory-a"
    check not dirExists(extendedPath(upper))
    check not dirExists(extendedPath(lower))
    let ku = filesystemPairKey(upper, upper)
    let kl = filesystemPairKey(lower, lower)
    # Both must be on the path-fallback arm, or this proves nothing.
    check ku.startsWith("path:")
    check kl.startsWith("path:")
    if hostOsFacts().pathLookupIsCaseSensitive.value == tnNo:
      check ku == kl
    else:
      check ku != kl

suite "F3 — a disagreement is surfaced, not papered over":
  test "the message names BOTH values and carries the row's citation":
    # The shape F2's suite already uses for a contradiction: a message
    # that named only one value would have decided for the reader which
    # of the table and the machine is wrong, and that is exactly the
    # judgement this record exists to leave open.
    let refs = rowEndpoint(fsRefs)
    let attempt = LinkAttempt(outcome: loUnsupported, errorCode: 1,
                              message: "FSCTL failed with Windows error 1")
    let kind = disagreementKind(fvPossible, issued = true,
                                outcome = attempt.outcome,
                                sameFilesystem = true)
    check kind == fdDeclaredPossibleButUnsupported
    let d = buildDisagreement(kind, lmReflink, pairOf(refs, refs), attempt)
    checkpoint(d.message)
    check "DISAGREEMENT" in d.message
    check "reflink=yes" in d.message          # the declared value
    check "loUnsupported" in d.message        # the observed one
    check d.citation.len > 0
    check d.citation in d.message             # checkable without a machine
    check d.mechanism == lmReflink
    check d.filesystem == "refs"

  test "the impossible-but-worked direction names both values too":
    let ntfs = rowEndpoint(fsNtfs)
    let attempt = LinkAttempt(outcome: loOk)
    let kind = disagreementKind(fvImpossible, issued = true,
                                outcome = loOk, sameFilesystem = true)
    let d = buildDisagreement(kind, lmReflink, pairOf(ntfs, ntfs), attempt)
    checkpoint(d.message)
    check "DISAGREEMENT" in d.message
    check "reflink=no" in d.message
    check "SUCCEEDED" in d.message
    check d.citation in d.message

  test "a disagreement reaches the caller's log line rather than waiting":
    # ``describe`` is what the store puts in a materialization
    # diagnostic, so a disagreement that did not appear there would be
    # visible only to code that remembered to look for it.
    var cap = LinkCapability(probed: true, key: "synthetic")
    let refs = rowEndpoint(fsRefs)
    cap.declared = pairOf(refs, refs)
    cap.disagreements.add(buildDisagreement(
      fdDeclaredPossibleButUnsupported, lmReflink, cap.declared,
      LinkAttempt(outcome: loUnsupported, message: "synthetic")))
    check "DISAGREEMENT" in cap.describe()

  test "a healthy host reports no disagreements at all":
    # The green-run half. If this ever fails, the table and this host
    # disagree and the message above says how.
    for vol in volumes:
      var cache: LinkCapabilityCache
      let cap = probeLinkCapabilities(cache, vol.dir, vol.dir)
      if cap.disagreements.len > 0:
        for d in cap.disagreements:
          checkpoint(d.message)
      check cap.disagreements.len == 0
    check linkFactNotices().len >= 0

suite "F4 — a filesystem with no table row":
  test "the notice names the filesystem, what policy did, and the fix":
    var obs = FilesystemObservation(queried: true, path: "/mnt/zz",
                                    reportedName: "zzfs", known: false,
                                    status: teUnknown, volumeKey: "zz")
    let notice = describeTableStatus(obs)
    checkpoint(notice)
    check "zzfs" in notice
    # The PATH as well as the type: a host can mount several volumes of
    # one unknown type, and a notice that named only the type would not
    # say which decision it belonged to. (Mutation found this: dropping
    # the path from the message left the type-name assertion passing,
    # because the type is named twice and the path only once.)
    check "/mnt/zz" in notice
    check "NO ENTRY" in notice
    # The degradation rule itself, in the message a reader will see.
    check "probing" in notice
    check "assumes nothing" in notice
    # ...and the small documented change.
    check TableEntrySourceFile in notice
    # A guess must be named as not-an-option, because a wrong fact is
    # worse than no fact.
    check "guess" in notice

  test "a filesystem WITH a row produces no notice":
    var obs = observeFilesystem(primaryVolume().dir)
    if obs.status == teKnown:
      check describeTableStatus(obs) == ""
    else:
      checkpoint("this host's primary volume has no table row; the " &
                 "silent-when-healthy arm was NOT exercised")
      check volumes.len >= 1

  test "an unqueried path is no information, and says so":
    let notice = describeTableStatus(
      FilesystemObservation(queried: false, path: "/nowhere",
                            status: teUnqueried))
    check "UNQUERIED" in notice
    check "assumes nothing" in notice

  test "status and the boolean `known` can never disagree":
    # Two spellings of one observation. The tests below read ``status``;
    # the F2 suite and ``factsForPath`` read ``known``. If they could
    # drift, one of the two would be reading a stale answer.
    for v in volumes:
      check v.obs.known == (v.obs.status == teKnown)
    check observeFilesystem("").known ==
      (observeFilesystem("").status == teKnown)
    # ...and off this host's own filesystems, where the interesting
    # arms are.
    for name in ["ntfs", "refs", "ext4", "ext3", "ext2", "zzfs", ""]:
      let c = tableEntryStatusFor(name)
      check c.known == (c.status == teKnown)

  test "the classifier answers all three kinds of name":
    # ``observeFilesystem``'s unrowed arms cannot be reached on a host
    # whose filesystems all have rows, and this development host is one.
    # Driving the classification as a function of the NAME is what makes
    # F4's subject testable at all here — mutation confirmed it: with
    # the classification inline, answering `known` for an unrowed name
    # survived.
    let known = tableEntryStatusFor("NTFS")
    check known.status == teKnown
    check known.known
    check known.id == fsNtfs
    check known.deferral.name.len == 0

    let deferred = tableEntryStatusFor("ext3")
    check deferred.status == teDeferred
    check not deferred.known
    check deferred.deferral.name == "ext3"
    check deferred.deferral.reason.len > 0

    let unknown = tableEntryStatusFor("zzfs")
    check unknown.status == teUnknown
    check not unknown.known
    check unknown.deferral.name.len == 0

    # An empty name is not a filesystem, and must not become one.
    check tableEntryStatusFor("").status == teUnknown
    check not tableEntryStatusFor("").known

suite "F4 — deliberate non-entries":
  test "every deferral carries a reason AND the change that replaces it":
    # A deferral with an empty reason is an excuse. This is the same
    # rule ``isWellFormed`` enforces for a fact, applied to the decision
    # NOT to write one.
    check UnenteredFilesystems.len > 0
    var examined = 0
    for entry in UnenteredFilesystems:
      check entry.name.len > 0
      check entry.reason.len > 0
      check entry.toAdd.len > 0
      # Sourced the way a citation is: a reader must be able to check it
      # without a machine, which means it names something.
      check entry.reason.len > 120
      # The change that would replace it has to be concrete enough to
      # act on.
      check "FilesystemId" in entry.toAdd
      check "deferral" in entry.toAdd
      examined.inc
    # A case that cannot report green having examined nothing — the
    # failure mode mutant M22 found in F2's own integrity checks.
    check examined == UnenteredFilesystems.len

  test "a deferral name is already normalised and unique":
    var seen: seq[string] = @[]
    for entry in UnenteredFilesystems:
      check entry.name == normalizedFsName(entry.name)
      check entry.name notin seen
      seen.add(entry.name)

  test "no deferral shadows a real table row":
    # The invariant that keeps the two lookups from disagreeing about
    # one string. If a row is ever added for a deferred name, this fails
    # until the deferral is deleted — which is exactly the reminder the
    # author of that row needs.
    var examined = 0
    for entry in UnenteredFilesystems:
      check not filesystemIdForName(entry.name).found
      for id in FilesystemId:
        check entry.name notin FilesystemTable[id].names
      examined.inc
    check examined == UnenteredFilesystems.len

  test "ext3 is a deliberate non-entry and does NOT resolve to the ext4 row":
    # The case the re-review surfaced: current kernels serve an ext3
    # volume with the ext4 driver while /proc/self/mountinfo still
    # reports `ext3`. Aliasing it onto the ext4 row would restore the
    # defect review round 2 removed — ext4's row declares a 1 ns
    # timestamp granularity that an ext3 volume with 128-byte inodes
    # does not have.
    let found = unenteredFilesystem("ext3")
    check found.found
    check found.entry.name == "ext3"
    check "ext4" in found.entry.reason
    check "timestampGranularityNs" in found.entry.reason
    check not filesystemIdForName("ext3").found
    check "ext3" notin FilesystemTable[fsExt4].names
    # ...and the lookup is case-insensitive the way the OS-reported name
    # may not be.
    check unenteredFilesystem("EXT3").found

  test "ext2 is deferred for a reason ext3's does not cover":
    let found = unenteredFilesystem("ext2")
    check found.found
    check "EXT2_LINK_MAX" in found.entry.reason
    check "32000" in found.entry.reason
    check not filesystemIdForName("ext2").found

  test "a name in neither table is simply unknown":
    check not unenteredFilesystem("definitely-not-a-filesystem").found
    check not unenteredFilesystem("").found
    check not filesystemIdForName("definitely-not-a-filesystem").found

suite "F3/F4 link-capability facts — teardown":
  test "every scratch directory this suite created is removed":
    for d in scratchDirs:
      try:
        removeDir(extendedPath(d))
      except CatchableError, Defect:
        discard
      check not dirExists(extendedPath(d))
