## Platform-And-Filesystem-Facts **F2** — the conformance suite.
##
## Spec: ``reprobuild-specs/Platform-And-Filesystem-Facts.milestones.org``
##       §F2 "The conformance suite".
##
## F1's tables are constants. This file is what makes them facts: it
## takes each declared value and drives the observation that would
## contradict it against the filesystems the host actually offers.
##
## The four requirements the milestone states are rejection criteria,
## and each is implemented literally:
##
## 1. **Discover.** ``discoverVolumes`` walks the host's mount points /
##    drive letters and asks the OS what filesystem holds each. Every
##    distinct filesystem gets tested; on this development host that is
##    NTFS (``C:``) and ReFS (``M:``, ``D:``).
## 2. **Untested is not passing.** Every (filesystem, fact) pair the
##    table declares is registered in a coverage LEDGER with one of four
##    outcomes. A fact this host cannot exercise is recorded ``coUntested``
##    WITH A REASON — never silently, and never as verified. The final
##    report prints the counts, so a green run on a one-filesystem
##    machine reads as "3 of 14 filesystems present, 96 facts untested
##    here", not as "the table is verified".
## 3. **An unknown filesystem is reported.** A host filesystem whose
##    name matches no table entry FAILS the discovery suite, naming the
##    string the OS reported and the file to add it to.
## 4. **A contradiction names both values.** ``expectFact`` emits
##    ``CONTRADICTION on <filesystem>: fact `<name>` declares <x> but
##    this filesystem does <y>`` and fails.
##
## It is also where the measurements the CAS campaign made by hand stop
## being prose in a milestone: NTFS's 1024-name cap, ReFS block cloning
## being genuinely copy-on-write, and a write through a hardlink being
## visible through every name are all asserted here.
##
## **The probe is used, not replaced.** ``attemptHardlink`` /
## ``attemptReflink`` from ``repro_local_store/link_capability`` are the
## observation mechanism for the linking and cloning facts — they are
## the code that actually issues ``CreateHardLinkW`` and the reflink
## FSCTL, and re-implementing them here would be testing a copy. What
## this suite adds is the other direction: it checks the CONSTANTS
## against what those attempts do. Migrating policy to consult the
## constants is F3 and is deliberately not done here.

import std/[os, strutils, tables, times, unittest]

from repro_core/paths import extendedPath

import repro_fs_facts
import repro_cas_store

when defined(windows):
  import std/winlean

# ---------------------------------------------------------------------------
# The fact inventory
#
# These lists are what make "covered" a checkable claim rather than an
# impression. The ``static`` blocks below fail the COMPILE when a fact is
# added to either table without being added here, so a new field cannot
# arrive uncovered.
# ---------------------------------------------------------------------------

const FsFactNames = [
  "hardlinks", "maxNamesPerFile", "hardlinksToDirectories",
  "oneDeviceIsOneLinkDomain", "reflink", "cloneOperation",
  "cloneIsCopyOnWrite", "timestampGranularityNs", "caseSensitivity",
  "casePreserving", "maxComponentLength", "maxPathLength",
  "refusedCharacters", "posixModeBits", "metadataIsPerInode",
  "atomicRenameOverExisting", "sparseFiles",
]

const OsFactNames = [
  "pathSeparator", "pathListSeparator", "executableSuffix",
  "pathLookupIsCaseSensitive", "defaultMaxPathChars", "longPathPrefix",
  "symlinkCreationIsPrivileged", "maxCommandLineBytes", "hardlinkApi",
  "reflinkApi", "honoursPosixModeBits", "hasOTmpfile",
]

static:
  # ``id`` and ``names`` are identity, not facts; everything else must be
  # named above.
  var fsProbe: FilesystemFacts
  var fsFields: seq[string] = @[]
  for name, _ in fsProbe.fieldPairs:
    fsFields.add(name)
  for declared in FsFactNames:
    doAssert declared in fsFields,
      "FsFactNames names a field FilesystemFacts does not have: " & declared
  doAssert fsFields.len == FsFactNames.len + 2,
    "FilesystemFacts has " & $fsFields.len & " fields but the conformance " &
    "suite covers " & $FsFactNames.len & " plus id/names. A fact was added " &
    "to the table without being added to this suite."

  var osProbe: OsFacts
  var osFields: seq[string] = @[]
  for name, _ in osProbe.fieldPairs:
    osFields.add(name)
  for declared in OsFactNames:
    doAssert declared in osFields,
      "OsFactNames names a field OsFacts does not have: " & declared
  doAssert osFields.len == OsFactNames.len + 2,
    "OsFacts has " & $osFields.len & " fields but the conformance suite " &
    "covers " & $OsFactNames.len & " plus id/names."

# ---------------------------------------------------------------------------
# The coverage ledger
# ---------------------------------------------------------------------------

type
  CoverageOutcome = enum
    coVerified
      ## The observation ran and agreed with the declared value, and a
      ## different value would have been contradicted by it.
    coPartial
      ## The observation ran and constrains the value, but cannot
      ## falsify it in both directions — a one-sided confirmation.
      ## Deliberately not folded into ``coVerified``: the difference is
      ## the difference between "checked" and "not disproved".
    coUntested
      ## This host cannot exercise it. The reason is recorded and
      ## printed. NEVER reported as passing.
    coContradiction
      ## The declared value and reality disagree. Fails the run.

  CoverageEntry = object
    subject: string   ## the filesystem or OS the fact belongs to
    factName: string
    outcome: CoverageOutcome
    detail: string

var ledger: seq[CoverageEntry] = @[]

proc record(subject, factName: string; outcome: CoverageOutcome;
            detail: string) =
  ledger.add(CoverageEntry(subject: subject, factName: factName,
                           outcome: outcome, detail: detail))

proc ledgerHas(subject, factName: string): bool =
  for e in ledger:
    if e.subject == subject and e.factName == factName:
      return true
  false

proc contradictionMessage(subject, factName, declared, observed,
                          detail: string): string =
  ## The message the milestone demands: it must name BOTH values.
  "CONTRADICTION on " & subject & ": fact `" & factName & "` declares " &
    declared & " but this filesystem does " & observed &
    (if detail.len > 0: " (" & detail & ")" else: "")

template expectFact(subject, factName: string; declaredValue,
                    observedValue: untyped; detail: string) =
  ## Compare a declared fact against an observation. On agreement the
  ## pair is recorded verified; on disagreement the run fails with both
  ## values named.
  block:
    let declaredText = $declaredValue
    let observedText = $observedValue
    if declaredValue == observedValue:
      record(subject, factName, coVerified,
             "declared " & declaredText & ", observed " & observedText &
             (if detail.len > 0: " — " & detail else: ""))
      check true
    else:
      let msg = contradictionMessage(subject, factName, declaredText,
                                     observedText, detail)
      record(subject, factName, coContradiction, msg)
      checkpoint(msg)
      fail()

template untestedHere(subject, factName, why: string) =
  ## Register a fact this host cannot exercise. ``why`` is mandatory and
  ## is printed by the report; "untested" with no reason is how a gap
  ## becomes invisible.
  record(subject, factName, coUntested, why)
  check why.len > 0

template partiallyChecked(subject, factName, what: string) =
  record(subject, factName, coPartial, what)
  check what.len > 0

# ---------------------------------------------------------------------------
# Host discovery
# ---------------------------------------------------------------------------

type
  HostVolume = object
    dir: string       ## a writable scratch directory on the volume
    obs: FilesystemObservation

var scratchDirs: seq[string] = @[]

proc claimScratchDir(parent, tag: string): string =
  if parent.len == 0 or not dirExists(extendedPath(parent)):
    return ""
  let candidate = parent / ("repro-f2-" & $getCurrentProcessId() & "-" & tag)
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

proc discoverVolumes(): seq[HostVolume] =
  ## One writable scratch directory per distinct mounted filesystem. The
  ## candidate's identity is read BEFORE anything is created, so a host
  ## with a dozen drive letters on one volume yields one entry.
  result = @[]
  var seen: seq[string] = @[]
  var tag = 0
  for parent in candidateParents():
    if parent.len == 0 or not dirExists(extendedPath(parent)):
      continue
    let probe = observeFilesystem(parent)
    if not probe.queried:
      continue
    if probe.volumeKey in seen:
      continue
    let dir = claimScratchDir(parent, "vol" & $tag)
    tag.inc
    if dir.len == 0:
      continue
    seen.add(probe.volumeKey)
    result.add(HostVolume(dir: dir, obs: observeFilesystem(dir)))

let volumes = discoverVolumes()

proc subjectOf(v: HostVolume): string =
  ## The label a contradiction names. Carries the OS-reported name AND
  ## the volume, because "NTFS" alone does not tell a reader which of
  ## three volumes disagreed.
  (if v.obs.reportedName.len > 0: v.obs.reportedName else: "?") &
    " (" & v.obs.volumeKey & ")"

## One representative volume per KNOWN filesystem id. Facts are a
## property of the filesystem, so driving them once per id is the right
## granularity; ``volumes`` keeps every instance for the discovery and
## cross-device arms.
var byFilesystem: OrderedTable[FilesystemId, HostVolume]
for v in volumes:
  if v.obs.queried and v.obs.known and v.obs.id notin byFilesystem:
    byFilesystem[v.obs.id] = v

proc presentFilesystems(): seq[FilesystemId] =
  result = @[]
  for id in byFilesystem.keys:
    result.add(id)

proc presentFilesystemsText(): string =
  var parts: seq[string] = @[]
  for id in byFilesystem.keys:
    parts.add($id)
  parts.join(", ")

# ---------------------------------------------------------------------------
# Observation helpers
# ---------------------------------------------------------------------------

proc caseDir(v: HostVolume; tag: string): string =
  let d = v.dir / tag
  removeDir(extendedPath(d))
  createDir(extendedPath(d))
  d

proc tryCreateFile(path: string): bool =
  try:
    writeFile(extendedPath(path), "x")
    true
  except CatchableError, Defect:
    false

proc entryExists(dir, name: string): bool =
  ## Whether the directory holds an entry with EXACTLY this name.
  ##
  ## Deliberately not ``fileExists``. On Windows a component containing
  ## ``:`` is accepted by the API as an alternate-data-stream reference,
  ## so the write SUCCEEDS while no directory entry of that name is
  ## created — measured on both NTFS and ReFS. Asking the directory what
  ## it actually holds is the observation that survives that.
  for _, path in walkDir(extendedPath(dir), relative = true):
    if path == name:
      return true
  false

proc refusalCandidates(): string =
  ## Every character ANY table row declares refused, plus a control group
  ## that no row refuses.
  ##
  ## The union rather than the row's own set is what makes the fact
  ## falsifiable in both directions. A row that dropped a character it
  ## should refuse is caught because the candidate is still tried; a row
  ## that added one it does not refuse is caught because the character
  ## turns out to be accepted. Testing only a row's own set catches the
  ## second and misses the first.
  var seen: set[char] = {}
  for id in FilesystemId:
    for ch in FilesystemTable[id].refusedCharacters.value:
      if ch != '\0':
        seen.incl(ch)
  # ``+ , ; = [ ]`` sit in this control group deliberately. FAT32's row
  # used to declare all six refused, on the strength of fatgen103's 8.3
  # ``DIR_Name`` list — while the very next section of that document says
  # they "are now allowed in a long name". Correcting the row also
  # removes them from the union above, so the fix would otherwise have
  # quietly retired the only characters able to catch the claim coming
  # back. Pinned here instead, where the assertion is that they ARE
  # accepted on every filesystem the host offers.
  for ch in "-+_.=%&~!@#$^(){}'`,;[]":
    seen.incl(ch)
  result = ""
  for ch in seen:
    result.add(ch)

proc pathOfLength(root: string; total: int): string =
  ## A path under ``root`` of exactly ``total`` characters, whose parent
  ## directories all exist. Returns ``""`` when ``root`` is already too
  ## long for the target — a reportable "cannot exercise", never a
  ## silently shorter path.
  var dir = root
  while dir.len + 1 + 90 + 1 + 8 <= total:
    dir = dir / repeat('d', 90)
    try:
      createDir(extendedPath(dir))
    except CatchableError, Defect:
      return ""
  let nameLen = total - dir.len - 1
  if nameLen < 1:
    return ""
  dir / repeat('n', nameLen)

proc hostCloneOperation(): CloneOperation =
  ## The clone primitive this OS offers, from the OS table. Which
  ## FILESYSTEMS answer it is the other table's claim, and checking one
  ## against the other is part of the point.
  when defined(windows): clDuplicateExtents
  elif defined(macosx): clClonefile
  elif defined(linux): clFiclone
  else: clUnknown

when defined(windows):
  const
    FsctlSetSparse = 0x000900C4'i32
    FileEndOfFileInfo = 6'i32

  proc deviceIoControl(h: Handle; code: DWORD; inBuf: pointer; inSz: DWORD;
                       outBuf: pointer; outSz: DWORD; ret: ptr DWORD;
                       ov: pointer): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "DeviceIoControl".}

  proc setFileInformationByHandle(h: Handle; klass: int32; info: pointer;
                                  sz: DWORD): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "SetFileInformationByHandle".}

  proc getCompressedFileSizeW(name: WideCString; high: ptr DWORD): DWORD
    {.stdcall, dynlib: "kernel32", importc: "GetCompressedFileSizeW".}

  proc createHardLinkW(dst, src: WideCString; sa: pointer): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "CreateHardLinkW".}

proc sparseAllocationRatio(dir: string):
    tuple[measured: bool; logical, allocated: int64] =
  ## Create a file marked sparse, extend it far past its written bytes,
  ## and report logical vs allocated size. A filesystem without sparse
  ## support allocates the whole extent.
  result = (false, 0'i64, 0'i64)
  when defined(windows):
    let f = dir / "sparse-probe.bin"
    let h = createFileW(newWideCString(extendedPath(f)),
                        GENERIC_READ or GENERIC_WRITE, 0, nil, CREATE_ALWAYS,
                        FILE_ATTRIBUTE_NORMAL, 0)
    if h == INVALID_HANDLE_VALUE:
      return
    var ret: DWORD
    let marked = deviceIoControl(h, DWORD(FsctlSetSparse), nil, 0, nil, 0,
                                 addr ret, nil)
    var eof = 64'i64 * 1024 * 1024
    let extended = setFileInformationByHandle(h, FileEndOfFileInfo, addr eof,
                                              DWORD(sizeof(eof)))
    discard closeHandle(h)
    if marked == 0 or extended == 0:
      try: removeFile(extendedPath(f))
      except CatchableError, Defect: discard
      return
    var hi: DWORD
    let lo = getCompressedFileSizeW(newWideCString(extendedPath(f)), addr hi)
    let allocated = (int64(uint32(hi)) shl 32) or int64(uint32(lo))
    try: removeFile(extendedPath(f))
    except CatchableError, Defect: discard
    result = (true, eof, allocated)
  else:
    let f = dir / "sparse-probe.bin"
    try:
      let handle = open(f, fmWrite)
      handle.setFilePos(64'i64 * 1024 * 1024)
      handle.write('x')
      handle.close()
    except CatchableError, Defect:
      return
    # ``getFileSize`` is logical; the allocated size comes from st_blocks,
    # which Nim does not surface portably, so the POSIX arm reports the
    # logical size twice and the caller treats it as unmeasured.
    try: removeFile(f)
    except CatchableError, Defect: discard
    result = (false, 0'i64, 0'i64)

proc attemptDirectoryLink(src, dst: string): bool =
  ## ``true`` when a second NAME for a directory was created.
  when defined(windows):
    createHardLinkW(newWideCString(extendedPath(dst)),
                    newWideCString(extendedPath(src)), nil) != 0
  else:
    attemptHardlink(src, dst).outcome == loOk

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

suite "F2 filesystem-facts conformance — discovery":
  test "the host offers at least one writable filesystem to test":
    checkpoint("discovered " & $volumes.len & " distinct filesystem(s)")
    for v in volumes:
      checkpoint("  " & v.obs.describe())
    check volumes.len >= 1

  test "every filesystem this host offers has a table entry":
    # Requirement 3. A host filesystem the table does not know is
    # REPORTED, not ignored — that is how the table grows, and an
    # unknown filesystem silently falling back is how a wrong policy
    # decision hides.
    #
    # **F4 refined what "does not know" means, and it is a narrowing of
    # the failure, not a weakening of it.** There are two ways to have
    # no row. One is that nobody has looked, and the only honest advice
    # is "add a row" — that still FAILS, unchanged. The other is that
    # somebody looked, established that the honest row cannot be
    # written, and recorded why in ``UnenteredFilesystems``; ext3 is the
    # real case, a filesystem current kernels serve with the ext4 driver
    # while ``/proc/self/mountinfo`` still reports the name ``ext3``,
    # and whose timestamp granularity is nonetheless NOT ext4's. Failing
    # on that one asks a developer to fix something no change can fix
    # short of inventing the facts this library exists to remove, and a
    # gate nobody can satisfy is a gate everybody learns to ignore.
    #
    # What replaces the failure is strictly more than nothing: the
    # deferral must carry a reason AND the change that would replace it,
    # both asserted here, and it is ECHOED on a green run rather than
    # checkpointed, for the same reason the coverage report is — a fact
    # this suite did not verify must be visible when it passes.
    var unknown: seq[string] = @[]
    var deferred: seq[string] = @[]
    for v in volumes:
      if not v.obs.queried:
        continue
      case v.obs.status
      of teKnown, teUnqueried:
        discard
      of teDeferred:
        deferred.add(v.obs.reportedName & " at " & v.obs.volumeKey)
        # A deferral with an empty reason is an excuse, not a decision.
        check v.obs.deferral.reason.len > 0
        check v.obs.deferral.toAdd.len > 0
        echo "NOT VERIFIED HERE: " & describeTableStatus(v.obs)
      of teUnknown:
        unknown.add(v.obs.reportedName & " at " & v.obs.volumeKey)
    if unknown.len > 0:
      checkpoint("this host offers filesystem(s) with NO entry in " &
                 "libs/repro_fs_facts/src/repro_fs_facts/filesystems.nim: " &
                 unknown.join(", ") &
                 ". Add a FilesystemId member and a FilesystemTable row " &
                 "(with citations) rather than letting policy fall back " &
                 "silently — or, if the honest row cannot be written, " &
                 "record WHY in that file's UnenteredFilesystems.")
    check unknown.len == 0
    if deferred.len > 0:
      checkpoint("deliberately unrowed filesystem(s) on this host: " &
                 deferred.join(", "))

  test "an unrecognised filesystem name resolves to no entry rather than a default":
    # The lookup's own contract, asserted directly: a name the table does
    # not carry must come back ``found = false``. A lookup that returned
    # the zeroth row would make the check above vacuous.
    let miss = filesystemIdForName("definitely-not-a-filesystem")
    check not miss.found
    let hit = filesystemIdForName("NTFS")
    check hit.found
    check hit.id == fsNtfs
    check filesystemIdForName("").found == false

  test "the table's filesystem names are unique and already lowercased":
    var seen = initTable[string, FilesystemId]()
    for id in FilesystemId:
      let entry = FilesystemTable[id]
      check entry.id == id
      check entry.names.len > 0
      for name in entry.names:
        check name == normalizedFsName(name)
        if name in seen:
          checkpoint("filesystem name '" & name & "' is claimed by both " &
                     $seen[name] & " and " & $id)
        check name notin seen
        seen[name] = id

  test "the host OS has a table entry and it is the compiled-for one":
    let byName = osIdForName(hostOS)
    checkpoint("hostOS=" & hostOS & " table entry=" & $HostOsId)
    check byName.found
    check byName.id == HostOsId
    check hostOsFacts().id == HostOsId

# ---------------------------------------------------------------------------
# Table integrity — the rules F1 states about the SHAPE of a fact
# ---------------------------------------------------------------------------

suite "F2 filesystem-facts conformance — table integrity":
  # NOTE for anyone editing these loops: the ``fieldPairs`` value MUST
  # NOT be named ``value``. ``Fact`` has a field of that name, and
  # ``value.value`` inside the loop does not resolve — so a
  # ``when compiles(value.value.…)`` guard is silently FALSE for every
  # field and the whole check becomes vacuous while still reporting
  # green. That is exactly what happened here, and it was found by
  # mutating a table entry and watching the mutant survive.
  test "every fact in both tables carries a citation and a falsifier":
    var missing: seq[string] = @[]
    var examined = 0
    for id in FilesystemId:
      for name, f in FilesystemTable[id].fieldPairs:
        when compiles(f.citation) and compiles(f.falsifiedBy):
          examined.inc
          if not f.isWellFormed():
            missing.add($id & "." & name)
    for id in OsId:
      for name, f in OsTable[id].fieldPairs:
        when compiles(f.citation) and compiles(f.falsifiedBy):
          examined.inc
          if not f.isWellFormed():
            missing.add($id & "." & name)
    if missing.len > 0:
      checkpoint("facts with an empty citation or falsifier: " &
                 missing.join(", "))
    check missing.len == 0
    # The guard against the guard: a run that examined nothing would
    # report green having checked nothing.
    checkpoint("examined " & $examined & " facts")
    check examined ==
      (ord(high(FilesystemId)) + 1) * FsFactNames.len +
      (ord(high(OsId)) + 1) * OsFactNames.len

  test "a fact marked not-observable says WHY rather than what":
    # ``obNone`` is a legitimate marker, but only when it carries an
    # explanation. A ``falsifiedBy`` that describes an operation while
    # claiming the fact is unobservable is a contradiction in the entry
    # itself.
    var bad: seq[string] = @[]
    var examined = 0
    for id in FilesystemId:
      for name, f in FilesystemTable[id].fieldPairs:
        when compiles(f.observability):
          examined.inc
          if f.observability == obNone and
             not f.falsifiedBy.startsWith("not observable"):
            bad.add($id & "." & name & ": " & f.falsifiedBy)
    for id in OsId:
      for name, f in OsTable[id].fieldPairs:
        when compiles(f.observability):
          examined.inc
          if f.observability == obNone and
             not f.falsifiedBy.startsWith("not observable"):
            bad.add($id & "." & name & ": " & f.falsifiedBy)
    if bad.len > 0:
      checkpoint("obNone facts whose falsifier does not explain the " &
                 "absence: " & bad.join(" | "))
    check bad.len == 0
    check examined ==
      (ord(high(FilesystemId)) + 1) * FsFactNames.len +
      (ord(high(OsId)) + 1) * OsFactNames.len

  test "an unestablished fact does not carry a confident value":
    # F1: "an honest `unknown` or `varies` is a fact; a confident wrong
    # number is a defect". This is that sentence made executable — a
    # ``pvUnestablished`` provenance may not sit next to a definite
    # value.
    var bad: seq[string] = @[]
    var examined = 0
    for id in FilesystemId:
      for name, f in FilesystemTable[id].fieldPairs:
        when compiles(f.provenance) and compiles(f.value.isDefinite()):
          examined.inc
          if f.provenance == pvUnestablished and f.value.isDefinite():
            bad.add($id & "." & name & " claims no source (pvUnestablished) " &
                    "but declares the definite value " & $f.value)
        elif compiles(f.provenance):
          # A string-valued fact has no indefinite form at all, so
          # ``pvUnestablished`` beside one is always a contradiction.
          examined.inc
          if f.provenance == pvUnestablished:
            bad.add($id & "." & name & " claims no source but its value " &
                    "type admits no `unknown`: " & $f.value)
    for id in OsId:
      for name, f in OsTable[id].fieldPairs:
        when compiles(f.provenance) and compiles(f.value.isDefinite()):
          examined.inc
          if f.provenance == pvUnestablished and f.value.isDefinite():
            bad.add($id & "." & name & " claims no source (pvUnestablished) " &
                    "but declares the definite value " & $f.value)
        elif compiles(f.provenance):
          examined.inc
          if f.provenance == pvUnestablished:
            bad.add($id & "." & name & " claims no source but its value " &
                    "type admits no `unknown`: " & $f.value)
    if bad.len > 0:
      checkpoint(bad.join(" | "))
    check bad.len == 0
    check examined ==
      (ord(high(FilesystemId)) + 1) * FsFactNames.len +
      (ord(high(OsId)) + 1) * OsFactNames.len

# ---------------------------------------------------------------------------
# Linking
# ---------------------------------------------------------------------------

suite "F2 filesystem-facts conformance — linking":
  test "hardlink support matches the table on every host filesystem":
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].hardlinks
      let dir = caseDir(v, "hardlink")
      let src = dir / "src.bin"
      writeFile(extendedPath(src), "payload")
      let attempt = attemptHardlink(src, dir / "second.bin")
      let observed =
        if attempt.outcome == loOk and hardlinkCount(src) >= 2: tnYes
        else: tnNo
      expectFact(subject, "hardlinks", declared.value, observed,
                 "attempt=" & $attempt.outcome & " links=" &
                 $hardlinkCount(src))
      # The OS's own advertisement is a SECOND, independent observation.
      # It is worth making because the two can disagree, and when they
      # do the table is not the only thing that is wrong.
      if v.obs.advertisedHardLinks != tnUnknown:
        checkpoint(subject & ": OS advertises hardlinks=" &
                   $v.obs.advertisedHardLinks)
        check v.obs.advertisedHardLinks == observed
      removeDir(extendedPath(dir))

  test "the maximum number of names per file matches the table":
    # Folds in the CAS campaign's headline measurement: NTFS caps a file
    # at 1024 TOTAL names — 1023 further links after the first, then
    # ERROR_TOO_MANY_LINKS — and ReFS accepted 2000 with no cap in sight.
    const LinkBudget = 4096
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].maxNamesPerFile.value
      if not declared.isDefinite:
        untestedHere(subject, "maxNamesPerFile",
                     "the declared value is `" & $declared & "`, which no " &
                     "single observation can contradict: a host that " &
                     "refuses at any count is consistent with it")
        continue
      if declared.value > LinkBudget:
        untestedHere(subject, "maxNamesPerFile",
                     "the declared cap (" & $declared.value & " names) " &
                     "exceeds this suite's link budget of " & $LinkBudget &
                     "; driving it to the boundary is not attempted here")
        continue
      let dir = caseDir(v, "linkcap")
      let src = dir / "src.bin"
      writeFile(extendedPath(src), "shared blob")
      var created = 1  # the source's own name
      var final = LinkAttempt(outcome: loOk)
      while created < LinkBudget:
        let attempt = attemptHardlink(src, dir / ("l" & $created & ".bin"))
        if attempt.outcome != loOk:
          final = attempt
          break
        created.inc
      checkpoint(subject & ": accepted " & $created & " total names, then " &
                 (if final.outcome == loOk: "the budget ran out"
                  else: final.message))
      case declared.kind
      of qkExact:
        expectFact(subject, "maxNamesPerFile", declared.value, int64(created),
                   "the refusal was " & $final.outcome)
        # A cap that presents as anything other than a per-file limit
        # would make policy invalidate the whole pair verdict, which the
        # CAS spec forbids.
        check final.outcome == loLinkLimitExceeded
        check isPerFileFallback(final)
      of qkAtLeast:
        if int64(created) >= declared.value:
          record(subject, "maxNamesPerFile", coPartial,
                 "declared >= " & $declared.value & "; " & $created &
                 " names were accepted, so the lower bound holds. An " &
                 "upper bound is deliberately not claimed")
          check int64(created) >= declared.value
        else:
          let msg = contradictionMessage(subject, "maxNamesPerFile",
                                         ">= " & $declared.value,
                                         $created & " (then " &
                                         $final.outcome & ")", "")
          record(subject, "maxNamesPerFile", coContradiction, msg)
          checkpoint(msg)
          fail()
      else: discard
      removeDir(extendedPath(dir))

  test "hardlinks to directories are refused where the table says so":
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].hardlinksToDirectories
      if not declared.value.isDefinite:
        # HFS+ is the case: TN1150 forbids directory hard links, the
        # later ADL mechanism permits them on a journaled volume to the
        # directory's owner, and neither answer is HFS+'s property. One
        # volume's result cannot contradict `varies`, so recording it as
        # a pass would be exactly the confusion this ledger exists to
        # prevent.
        untestedHere(subject, "hardlinksToDirectories",
                     "the declared value is `" & $declared.value &
                     "`, which one volume's answer cannot contradict")
        continue
      let dir = caseDir(v, "dirlink")
      let sub = dir / "subdir"
      createDir(extendedPath(sub))
      let observed =
        if attemptDirectoryLink(sub, dir / "dirlink"): tnYes else: tnNo
      expectFact(subject, "hardlinksToDirectories", declared.value, observed,
                 "link against a directory")
      removeDir(extendedPath(dir))

  test "one device is one link domain where the table says so":
    # The fact Btrfs falsifies, checked in the direction this host can
    # supply: two directories on one filesystem that do NOT share a
    # parent must still be able to link.
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].oneDeviceIsOneLinkDomain
      if not declared.value.isDefinite:
        untestedHere(subject, "oneDeviceIsOneLinkDomain",
                     "the declared value is `" & $declared.value &
                     "`, which an observation on one mount cannot " &
                     "contradict")
        continue
      if declared.value == tnNo:
        untestedHere(subject, "oneDeviceIsOneLinkDomain",
                     "contradicting `no` needs two subtrees that share a " &
                     "device but not a link domain (a Btrfs subvolume " &
                     "pair, a ZFS dataset pair, an APFS container). This " &
                     "host offers none")
        continue
      let dir = caseDir(v, "linkdomain")
      createDir(extendedPath(dir / "a"))
      createDir(extendedPath(dir / "b"))
      let src = dir / "a" / "src.bin"
      writeFile(extendedPath(src), "payload")
      let attempt = attemptHardlink(src, dir / "b" / "dst.bin")
      let observed = if attempt.outcome == loOk: tnYes else: tnNo
      expectFact(subject, "oneDeviceIsOneLinkDomain", declared.value,
                 observed,
                 "link across two subtrees of one mount: " & $attempt.outcome)
      removeDir(extendedPath(dir))

  test "a write through a hardlink is visible through every name":
    # Carried from Local-CAS-Hardlink-Materialization M0. Not a table
    # fact of its own — it is the DATA half of what
    # ``metadataIsPerInode`` says about metadata — but it is the
    # property the whole CAS shared-inode decision rests on, and it was
    # prose in a milestone until now.
    #
    # It is ALSO the case that showed how a green case can mean nothing.
    # This test used to end with `check volumes.len >= 1`, which is true
    # on every host that got this far, and it recorded nothing in the
    # ledger — so on a hardlink-less machine it printed `[OK]` and the
    # coverage report was silent about a property nobody had checked.
    # The fix is the one ``hardlinkApi`` already had: the ledger gets an
    # entry either way, and an unexercised property is UNTESTED HERE with
    # a reason rather than a pass.
    const WriteThroughFact = "writeThroughHardlinkIsShared"
    var exercised = 0
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      if FilesystemTable[id].hardlinks.value != tnYes:
        untestedHere(subject, WriteThroughFact,
                     "this filesystem declares hardlinks=" &
                     $FilesystemTable[id].hardlinks.value &
                     ", so there is no second name to write through")
        continue
      let dir = caseDir(v, "writethrough")
      let src = dir / "src.bin"
      writeFile(extendedPath(src), "original")
      let dst = dir / "second.bin"
      if attemptHardlink(src, dst).outcome != loOk:
        untestedHere(subject, WriteThroughFact,
                     "a second name could not be created on this host, so " &
                     "there is no other name through which to observe the " &
                     "write")
        removeDir(extendedPath(dir))
        continue
      exercised.inc
      writeFile(extendedPath(dst), "REWRITTEN")
      let throughFirst = readFile(extendedPath(src))
      let links = hardlinkCount(src)
      checkpoint(subject & ": wrote through the second name; the " &
                 "first now reads " & throughFirst)
      if throughFirst == "REWRITTEN" and links == 2:
        record(subject, WriteThroughFact, coVerified,
               "wrote through the second name; the first name reads the " &
               "new bytes back and the link count is " & $links)
        check true
      else:
        let msg = contradictionMessage(subject, WriteThroughFact,
          "one inode behind both names, so a write through either is " &
          "visible through the other",
          "the first name reads " & repr(throughFirst) & " with a link " &
          "count of " & $links, "")
        record(subject, WriteThroughFact, coContradiction, msg)
        checkpoint(msg)
        fail()
      removeDir(extendedPath(dir))
    if exercised == 0:
      # Not a pass. The ledger already carries a reason per filesystem;
      # this is the host-level statement the report prints.
      untestedHere("host", WriteThroughFact,
                   "no host filesystem produced a hardlink, so the " &
                   "shared-inode write property — which the whole CAS " &
                   "materialisation design rests on — was NOT exercised " &
                   "anywhere on this machine")
    else:
      checkpoint("the shared-inode write property was exercised on " &
                 $exercised & " filesystem(s)")

# ---------------------------------------------------------------------------
# Cloning
# ---------------------------------------------------------------------------

suite "F2 filesystem-facts conformance — cloning":
  test "reflink support and the operation that performs it match the table":
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let entry = FilesystemTable[id]
      let dir = caseDir(v, "reflink")
      let src = dir / "src.bin"
      var payload = newString(1 shl 16)
      for i in 0 ..< payload.len:
        payload[i] = char((i * 31 + 7) and 0xFF)
      writeFile(extendedPath(src), payload)
      let attempt = attemptReflink(src, dir / "clone.bin")
      let bytesMatch =
        attempt.outcome == loOk and
        readFile(extendedPath(dir / "clone.bin")) == payload
      let observed = if bytesMatch: tnYes else: tnNo
      if entry.reflink.value.isDefinite:
        expectFact(subject, "reflink", entry.reflink.value, observed,
                   "attempt=" & $attempt.outcome)
      else:
        record(subject, "reflink", coPartial,
               "the declared value is `" & $entry.reflink.value &
               "` (feature- or version-gated), so this host's answer (" &
               $observed & ", " & $attempt.outcome & ") cannot contradict " &
               "it — but it is recorded")
        check true
      # The operation is its own fact: a filesystem that clones must be
      # declared to clone with the primitive this OS actually issued.
      let observedOp = if bytesMatch: hostCloneOperation() else: clNone
      if entry.cloneOperation.value.isDefinite:
        expectFact(subject, "cloneOperation", entry.cloneOperation.value,
                   observedOp, "the OS table names " &
                   hostOsFacts().reflinkApi.value & " for this platform")
      else:
        record(subject, "cloneOperation", coPartial,
               "declared `" & $entry.cloneOperation.value & "`; observed " &
               $observedOp)
        check true
      # Windows advertises block refcounting as a volume flag — an
      # independent second opinion on the same fact.
      if v.obs.advertisedBlockRefcounting != tnUnknown:
        checkpoint(subject & ": OS advertises blockRefcounting=" &
                   $v.obs.advertisedBlockRefcounting)
        check v.obs.advertisedBlockRefcounting == observed
      removeDir(extendedPath(dir))

  test "a clone is copy-on-write where the table claims it is":
    # Carried from Local-CAS-Hardlink-Materialization M0: ReFS block
    # cloning is genuinely copy-on-write. This is the fact the CAS
    # probe explicitly could NOT establish — it verifies bytes, so a
    # silently-degraded clone would read as available — and it is why
    # a cost claim needs this suite rather than that probe.
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].cloneIsCopyOnWrite
      if declared.observability == obNone:
        untestedHere(subject, "cloneIsCopyOnWrite", declared.falsifiedBy)
        continue
      if not declared.value.isDefinite:
        untestedHere(subject, "cloneIsCopyOnWrite",
                     "the declared value is `" & $declared.value & "`")
        continue
      let dir = caseDir(v, "cow")
      let src = dir / "src.bin"
      writeFile(extendedPath(src), "original payload, long enough to clone")
      let clone = dir / "clone.bin"
      if attemptReflink(src, clone).outcome != loOk:
        untestedHere(subject, "cloneIsCopyOnWrite",
                     "the clone operation did not succeed on this host, so " &
                     "there is no clone whose write semantics to observe")
        removeDir(extendedPath(dir))
        continue
      writeFile(extendedPath(clone), "REWRITTEN THROUGH THE CLONE")
      let sourceIntact =
        readFile(extendedPath(src)) == "original payload, long enough to clone"
      let observed = if sourceIntact: tnYes else: tnNo
      expectFact(subject, "cloneIsCopyOnWrite", declared.value, observed,
                 "wrote through the clone; the source " &
                 (if sourceIntact: "was unchanged"
                  else: "CHANGED — the clone shared the inode"))
      check hardlinkCount(src) == 1
      removeDir(extendedPath(dir))

# ---------------------------------------------------------------------------
# Timestamps
# ---------------------------------------------------------------------------

suite "F2 filesystem-facts conformance — timestamps":
  test "the stored last-write granularity matches the table":
    # Two-sided, which is what makes it a measurement rather than a
    # gesture: a difference of exactly one granularity unit must be
    # STORED distinctly, and a difference of one unit MINUS ONE must
    # not. The first half falsifies a coarser claim, the second a finer
    # one. At a declared granularity of 1 ns the second half degenerates
    # (there is no smaller difference to try) and the entry is recorded
    # as partial rather than verified.
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].timestampGranularityNs.value
      if not declared.isDefinite or declared.kind != qkExact:
        untestedHere(subject, "timestampGranularityNs",
                     "the declared value is `" & $declared &
                     "`, which no round-trip can contradict")
        continue
      let dir = caseDir(v, "timestamps")
      let f = dir / "stamp.bin"
      writeFile(extendedPath(f), "t")
      let base = fromUnix(1_000_000)
      let g = declared.value

      setLastModificationTime(extendedPath(f), base)
      let readBase = getLastModificationTime(extendedPath(f))
      setLastModificationTime(extendedPath(f),
                              base + initDuration(nanoseconds = g))
      let readUp = getLastModificationTime(extendedPath(f))
      let representable = readUp != readBase

      if g <= 1:
        if representable:
          record(subject, "timestampGranularityNs", coPartial,
                 "declared 1 ns; a 1 ns difference is stored distinctly. " &
                 "The lower half of the two-sided check does not exist at " &
                 "this granularity, so a FINER real granularity could not " &
                 "be distinguished from this one")
          check representable
        else:
          let msg = contradictionMessage(subject, "timestampGranularityNs",
            "1 ns", "coarser than 1 ns (a 1 ns difference did not survive " &
            "the round trip)", "")
          record(subject, "timestampGranularityNs", coContradiction, msg)
          checkpoint(msg)
          fail()
      else:
        setLastModificationTime(extendedPath(f),
                                base + initDuration(nanoseconds = g - 1))
        let readDown = getLastModificationTime(extendedPath(f))
        let finerNotRepresentable = readDown == readBase
        checkpoint(subject & ": +" & $g & "ns distinct=" & $representable &
                   ", +" & $(g - 1) & "ns collapses to base=" &
                   $finerNotRepresentable)
        if representable and finerNotRepresentable:
          record(subject, "timestampGranularityNs", coVerified,
                 "declared " & $g & " ns; a " & $g & " ns difference is " &
                 "stored distinctly and a " & $(g - 1) & " ns difference " &
                 "is not")
          check true
        else:
          let observedText =
            if not representable:
              "coarser than " & $g & " ns (a " & $g &
              " ns difference did not survive the round trip)"
            else:
              "finer than " & $g & " ns (a " & $(g - 1) &
              " ns difference DID survive the round trip)"
          let msg = contradictionMessage(subject, "timestampGranularityNs",
                                         $g & " ns", observedText, "")
          record(subject, "timestampGranularityNs", coContradiction, msg)
          checkpoint(msg)
          fail()
      removeDir(extendedPath(dir))

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

suite "F2 filesystem-facts conformance — naming":
  test "case sensitivity matches the table":
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].caseSensitivity
      if not declared.value.isDefinite:
        untestedHere(subject, "caseSensitivity",
                     "the declared value is `" & $declared.value &
                     "`, a format- or mount-time property that one " &
                     "volume's answer cannot contradict")
        continue
      let dir = caseDir(v, "casing")
      check tryCreateFile(dir / "CaseProbe.txt")
      let otherCaseResolves = fileExists(extendedPath(dir / "caseprobe.txt"))
      let observed =
        if otherCaseResolves: caInsensitive else: caSensitive
      expectFact(subject, "caseSensitivity", declared.value, observed,
                 "created CaseProbe.txt; caseprobe.txt " &
                 (if otherCaseResolves: "resolves to it"
                  else: "does not resolve"))
      removeDir(extendedPath(dir))

  test "case preservation matches the table":
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].casePreserving
      if not declared.value.isDefinite:
        untestedHere(subject, "casePreserving",
                     "the declared value is `" & $declared.value & "`")
        continue
      let dir = caseDir(v, "casepreserve")
      check tryCreateFile(dir / "MixedCaseName.txt")
      let observed =
        if entryExists(dir, "MixedCaseName.txt"): tnYes else: tnNo
      expectFact(subject, "casePreserving", declared.value, observed,
                 "the directory listing reports the name as created")
      if v.obs.advertisedCasePreservedNames != tnUnknown:
        check v.obs.advertisedCasePreservedNames == observed
      removeDir(extendedPath(dir))

  test "the maximum component length matches the table":
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].maxComponentLength.value
      if declared.kind != qkExact:
        untestedHere(subject, "maxComponentLength",
                     "the declared value is `" & $declared & "`")
        continue
      let dir = caseDir(v, "namelen")
      let atLimit = repeat('a', int(declared.value))
      let overLimit = repeat('b', int(declared.value) + 1)
      let atOk = tryCreateFile(dir / atLimit)
      let overOk = tryCreateFile(dir / overLimit)
      checkpoint(subject & ": " & $declared.value & " chars ok=" & $atOk &
                 ", " & $(declared.value + 1) & " chars ok=" & $overOk)
      if atOk and not overOk:
        record(subject, "maxComponentLength", coVerified,
               "declared " & $declared.value & "; that length is accepted " &
               "and one more is refused")
        check true
      else:
        let observedText =
          if not atOk: "refuses a component of " & $declared.value &
                       " characters"
          else: "accepts a component of " & $(declared.value + 1) &
                " characters"
        let msg = contradictionMessage(subject, "maxComponentLength",
                                       $declared.value, observedText, "")
        record(subject, "maxComponentLength", coContradiction, msg)
        checkpoint(msg)
        fail()
      # The OS's own reported limit is a second, independent observation.
      if v.obs.reportedMaxComponentLength >= 0:
        checkpoint(subject & ": the OS reports a maximum component " &
                   "length of " & $v.obs.reportedMaxComponentLength)
        check int64(v.obs.reportedMaxComponentLength) == declared.value
      removeDir(extendedPath(dir))

  test "the maximum path length matches the table":
    # The declared Windows value (32767) is far beyond what this suite
    # is willing to create and tear down, so it reports UNTESTED rather
    # than passing on a lower-bound observation. The lower bound is
    # still recorded, and the fact that a path beyond the OS default IS
    # reachable is checked as an OS fact instead.
    const PathBudget = 3000
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].maxPathLength.value
      if declared.kind != qkExact:
        untestedHere(subject, "maxPathLength",
                     "the declared value is `" & $declared & "`; on this " &
                     "filesystem the whole-path bound belongs to the OS, " &
                     "and the OS table checks it")
        continue
      if declared.value > PathBudget:
        untestedHere(subject, "maxPathLength",
                     "the declared limit (" & $declared.value &
                     " characters) exceeds this suite's path budget of " &
                     $PathBudget & "; driving it to the boundary would " &
                     "create a tree this suite cannot reliably remove")
        continue
      let dir = caseDir(v, "pathlen")
      let atPath = pathOfLength(dir, int(declared.value))
      let overPath = pathOfLength(dir, int(declared.value) + 1)
      if atPath.len == 0 or overPath.len == 0:
        untestedHere(subject, "maxPathLength",
                     "the scratch directory is already too long to build a " &
                     "path of " & $declared.value & " characters under it")
      else:
        let atOk = tryCreateFile(atPath)
        let overOk = tryCreateFile(overPath)
        checkpoint(subject & ": " & $declared.value & "-char path ok=" &
                   $atOk & ", one char longer ok=" & $overOk)
        if atOk and not overOk:
          record(subject, "maxPathLength", coVerified,
                 "a path of exactly " & $declared.value & " characters is " &
                 "accepted and one character more is refused")
          check true
        else:
          let observedText =
            if not atOk: "refuses a path of " & $declared.value &
                         " characters"
            else: "accepts a path of " & $(declared.value + 1) & " characters"
          let msg = contradictionMessage(subject, "maxPathLength",
                                         $declared.value, observedText, "")
          record(subject, "maxPathLength", coContradiction, msg)
          checkpoint(msg)
          fail()
      removeDir(extendedPath(dir))

  test "the refused character set matches the table":
    # Symmetric, and it has to be. Checking only that the DECLARED
    # characters are refused passes just as happily against a row that
    # dropped one — measured: a mutant removing '*' from NTFS's set
    # survived the one-sided version of this test. So every candidate
    # character is tried against every filesystem and the observation
    # must agree with membership in BOTH directions.
    let candidates = refusalCandidates()
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].refusedCharacters
      let dir = caseDir(v, "refusedchars")
      var skipped: seq[string] = @[]
      var tried = 0
      if '\0' in declared.value:
        # A NUL cannot be carried through the path API at all, so its
        # refusal is not observable — an honest gap, not a pass.
        skipped.add("NUL")
      # Normalise the declared set into the same ascending, NUL-free
      # order the candidates are tried in, so the two sides of a
      # contradiction are directly comparable strings rather than a list
      # of grievances.
      var declaredSet: set[char] = {}
      for ch in declared.value:
        if ch != '\0':
          declaredSet.incl(ch)
      var declaredNormalised = ""
      for ch in declaredSet:
        declaredNormalised.add(ch)
      var observedRefused = ""
      for ch in candidates:
        let name = "c" & ch & "n"
        discard tryCreateFile(dir / name)
        tried.inc
        if not entryExists(dir, name):
          observedRefused.add(ch)
      checkpoint(subject & ": tried " & $tried & " candidate characters")
      check tried >= 15
      if declaredNormalised != observedRefused:
        let msg = contradictionMessage(subject, "refusedCharacters",
          "refuse exactly " & repr(declaredNormalised),
          "refuse exactly " & repr(observedRefused),
          "over the " & $tried & " candidate characters this suite tries")
        record(subject, "refusedCharacters", coContradiction, msg)
        checkpoint(msg)
        fail()
      elif skipped.len > 0:
        record(subject, "refusedCharacters", coPartial,
               "all " & $tried & " candidate characters agreed with the " &
               "declared set in both directions; " & skipped.join(", ") &
               " cannot be expressed through the path API and was not tried")
        check true
      else:
        record(subject, "refusedCharacters", coVerified,
               "all " & $tried & " candidate characters agreed with the " &
               "declared set in both directions")
        check true
      removeDir(extendedPath(dir))

# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------

suite "F2 filesystem-facts conformance — metadata":
  test "POSIX mode-bit storage matches the table":
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].posixModeBits
      if not declared.value.isDefinite:
        untestedHere(subject, "posixModeBits",
                     "the declared value is `" & $declared.value & "`")
        continue
      let dir = caseDir(v, "modebits")
      let f = dir / "mode.bin"
      writeFile(extendedPath(f), "m")
      let wanted = {fpUserRead, fpUserWrite, fpGroupRead}
      setFilePermissions(extendedPath(f), wanted)
      let got = getFilePermissions(extendedPath(f))
      # Round-tripping an arbitrary mode is what "stores POSIX mode
      # bits" means. Windows synthesises a mode from the read-only
      # attribute, so it comes back with group and other bits the caller
      # never asked for — which is the observation, not a nuisance.
      let observed = if got == wanted: tnYes else: tnNo
      expectFact(subject, "posixModeBits", declared.value, observed,
                 "set " & $wanted & ", read back " & $got)
      removeDir(extendedPath(dir))

  test "permission and attribute changes are per-inode where the table says so":
    # Carried from Local-CAS-Hardlink-Materialization M3, which measured
    # that a chmod through a hardlinked OUTPUT moves the CAS BLOB's own
    # mode. That measurement is why ``applyPermissions`` excludes the
    # hardlink arm and why the read-only-blob guard rail was rejected.
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].metadataIsPerInode
      if declared.observability == obNone:
        untestedHere(subject, "metadataIsPerInode", declared.falsifiedBy)
        continue
      if not declared.value.isDefinite:
        untestedHere(subject, "metadataIsPerInode",
                     "the declared value is `" & $declared.value & "`")
        continue
      let dir = caseDir(v, "perinode")
      let src = dir / "src.bin"
      writeFile(extendedPath(src), "payload")
      let lnk = dir / "second.bin"
      if attemptHardlink(src, lnk).outcome != loOk:
        untestedHere(subject, "metadataIsPerInode",
                     "a second name could not be created on this host, so " &
                     "there is no other name through which to observe the " &
                     "change")
        removeDir(extendedPath(dir))
        continue
      let before = getFilePermissions(extendedPath(src))
      setFilePermissions(extendedPath(lnk), {fpUserRead})
      let after = getFilePermissions(extendedPath(src))
      let observed = if after != before: tnYes else: tnNo
      expectFact(subject, "metadataIsPerInode", declared.value, observed,
                 "changed permissions through the SECOND name; the first " &
                 "name reports " & $after & " (was " & $before & ")")
      setFilePermissions(extendedPath(lnk), before)
      removeDir(extendedPath(dir))

# ---------------------------------------------------------------------------
# Atomicity and sparseness
# ---------------------------------------------------------------------------

suite "F2 filesystem-facts conformance — atomicity and sparseness":
  test "rename-over-existing behaves as the table declares":
    # The marker on this fact is ``obConsequence`` and it is honest:
    # user space can see that the destination was REPLACED rather than
    # refused, which contradicts a ``no``, but it cannot crash the
    # machine mid-rename to prove the window does not exist. So a
    # declared ``yes`` is recorded PARTIAL, never verified.
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].atomicRenameOverExisting
      if not declared.value.isDefinite:
        untestedHere(subject, "atomicRenameOverExisting",
                     "the declared value is `" & $declared.value & "`")
        continue
      let dir = caseDir(v, "renameover")
      let a = dir / "a.bin"
      let b = dir / "b.bin"
      writeFile(extendedPath(a), "AAA")
      writeFile(extendedPath(b), "BBB")
      var replaced = false
      try:
        moveFile(extendedPath(a), extendedPath(b))
        replaced = fileExists(extendedPath(b)) and
                   readFile(extendedPath(b)) == "AAA" and
                   not fileExists(extendedPath(a))
      except CatchableError, Defect:
        replaced = false
      let observed = if replaced: tnYes else: tnNo
      if declared.value != observed:
        let msg = contradictionMessage(subject, "atomicRenameOverExisting",
          $declared.value,
          (if replaced: "replaces the destination"
           else: "refuses to replace an existing destination"), "")
        record(subject, "atomicRenameOverExisting", coContradiction, msg)
        checkpoint(msg)
        fail()
      else:
        record(subject, "atomicRenameOverExisting", coPartial,
               "the destination was " &
               (if replaced: "replaced" else: "not replaced") &
               ", which is consistent with `" & $declared.value &
               "`. The ATOMICITY itself is not observable from user " &
               "space — see the fact's own observability marker")
        check true
      removeDir(extendedPath(dir))

  test "sparse-file support matches the table":
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let subject = subjectOf(v)
      let declared = FilesystemTable[id].sparseFiles
      if not declared.value.isDefinite:
        untestedHere(subject, "sparseFiles",
                     "the declared value is `" & $declared.value & "`")
        continue
      let dir = caseDir(v, "sparse")
      let measurement = sparseAllocationRatio(dir)
      if measurement.measured:
        # A filesystem without sparse support allocates the whole
        # extent; one with it allocates a small fraction of it.
        let observed =
          if measurement.allocated * 8 < measurement.logical: tnYes
          else: tnNo
        expectFact(subject, "sparseFiles", declared.value, observed,
                   "a " & $measurement.logical & "-byte file occupies " &
                   $measurement.allocated & " bytes")
      elif v.obs.advertisedSparseFiles != tnUnknown:
        expectFact(subject, "sparseFiles", declared.value,
                   v.obs.advertisedSparseFiles,
                   "from the OS's own volume-capability report")
      else:
        untestedHere(subject, "sparseFiles",
                     "this platform offers neither an allocated-size " &
                     "query nor a capability report that this suite binds")
      removeDir(extendedPath(dir))

# ---------------------------------------------------------------------------
# The OS table
# ---------------------------------------------------------------------------

suite "F2 filesystem-facts conformance — the OS table":
  let osSubject = "OS " & hostOS
  let facts = hostOsFacts()

  test "path separators and the executable suffix match the table":
    expectFact(osSubject, "pathSeparator", facts.pathSeparator.value,
               $DirSep, "Nim's DirSep")
    expectFact(osSubject, "pathListSeparator", facts.pathListSeparator.value,
               $PathSep, "Nim's PathSep")
    let observedExeSuffix = if ExeExt.len > 0: "." & ExeExt else: ""
    expectFact(osSubject, "executableSuffix", facts.executableSuffix.value,
               observedExeSuffix, "Nim's ExeExt")

  test "path lookup case sensitivity matches the table":
    var exercised = false
    for id in presentFilesystems():
      let entry = FilesystemTable[id]
      if not entry.caseSensitivity.value.isDefinite:
        continue
      let v = byFilesystem[id]
      let dir = caseDir(v, "oscase")
      check tryCreateFile(dir / "OsCaseProbe.txt")
      let observed =
        if fileExists(extendedPath(dir / "oscaseprobe.txt")): tnNo
        else: tnYes
      removeDir(extendedPath(dir))
      if facts.pathLookupIsCaseSensitive.value.isDefinite:
        expectFact(osSubject, "pathLookupIsCaseSensitive",
                   facts.pathLookupIsCaseSensitive.value, observed,
                   "observed on " & subjectOf(v))
      else:
        record(osSubject, "pathLookupIsCaseSensitive", coPartial,
               "the declared value is `" &
               $facts.pathLookupIsCaseSensitive.value &
               "`; this volume answered " & $observed)
        check true
      exercised = true
      break
    if not exercised:
      untestedHere(osSubject, "pathLookupIsCaseSensitive",
                   "no host filesystem declares a definite case " &
                   "sensitivity, so there is no volume on which the OS's " &
                   "rule can be separated from the filesystem's")

  test "the default path limit and the prefix that lifts it match the table":
    # Two-sided by construction: a path below the limit must work
    # WITHOUT the prefix, and a path above it must fail without and
    # succeed with. That is the exact property
    # ``repro_core/paths.extendedPath`` exists to supply.
    let declared = facts.defaultMaxPathChars.value
    let v =
      if volumes.len > 0: volumes[0]
      else: HostVolume(dir: "")
    if v.dir.len == 0 or declared.kind != qkExact:
      untestedHere(osSubject, "defaultMaxPathChars",
                   "no writable volume, or the declared limit is `" &
                   $declared & "`")
      untestedHere(osSubject, "longPathPrefix",
                   "the check depends on defaultMaxPathChars being driven")
    else:
      let dir = caseDir(v, "oslongpath")
      # Two-sided, and it has to be: a path JUST UNDER the declared
      # limit must work with no prefix, and one just over must not.
      # Checking only the second half passes against any limit at all —
      # measured: a mutant raising Windows' 260 to 4096 survived the
      # one-sided version, because a 4186-character path fails under
      # either claim.
      let nearPath = pathOfLength(dir, int(declared.value) - 5)
      let overPath = pathOfLength(dir, int(declared.value) + 60)
      if nearPath.len == 0 or overPath.len == 0:
        untestedHere(osSubject, "defaultMaxPathChars",
                     "the scratch directory is already too long to build a " &
                     "path of " & $declared.value & " characters under it")
        untestedHere(osSubject, "longPathPrefix",
                     "the check depends on defaultMaxPathChars being driven")
      else:
        var nearOk = true
        try:
          writeFile(nearPath, "s")
        except CatchableError, Defect:
          nearOk = false
        var overOk = true
        try:
          writeFile(overPath, "p")
        except CatchableError, Defect:
          overOk = false
        let overPrefixedOk = tryCreateFile(overPath & ".pfx")
        checkpoint(osSubject & ": " & $nearPath.len &
                   "-char path with no prefix ok=" & $nearOk & "; " &
                   $overPath.len & "-char path with no prefix ok=" & $overOk &
                   ", with the prefix ok=" & $overPrefixedOk)
        let observedText =
          if not nearOk:
            "refuses a " & $nearPath.len & "-character path, so its limit " &
            "is BELOW " & $declared.value
          elif overOk:
            "accepts a " & $overPath.len & "-character path with no " &
            "prefix, so its limit is ABOVE " & $declared.value
          else:
            ""
        if observedText.len > 0:
          let msg = contradictionMessage(osSubject, "defaultMaxPathChars",
                                         $declared.value, observedText, "")
          record(osSubject, "defaultMaxPathChars", coContradiction, msg)
          record(osSubject, "longPathPrefix", coContradiction, msg)
          checkpoint(msg)
          fail()
        else:
          record(osSubject, "defaultMaxPathChars", coVerified,
                 "a " & $nearPath.len & "-character path works without a " &
                 "prefix and a " & $overPath.len & "-character one does not")
          check true
          if facts.longPathPrefix.value.len == 0:
            # A platform with no opt-in prefix: the limit is absolute,
            # so the over-length path must fail with or without it.
            #
            # When it does NOT fail, the table is wrong and this is a
            # contradiction like any other — it must be REPORTED as one,
            # naming both values, and must leave the ledger showing a
            # contradiction. The bare `check not overPrefixedOk` that
            # stood here failed the run without doing either, which made
            # mutant M26 (Windows' prefix emptied) fail for a reason the
            # report could not explain.
            checkpoint(osSubject & ": no long-path prefix is declared; the " &
                       "over-length path must fail either way")
            if overPrefixedOk:
              let msg = contradictionMessage(osSubject, "longPathPrefix",
                "no prefix at all (empty), so the " & $declared.value &
                "-character limit is absolute on this platform",
                "accept a " & $overPath.len & "-character path once " &
                "repro_core/paths.extendedPath has been applied, so a " &
                "prefix DOES lift the limit here", "")
              record(osSubject, "longPathPrefix", coContradiction, msg)
              checkpoint(msg)
              fail()
            else:
              untestedHere(osSubject, "longPathPrefix",
                           facts.longPathPrefix.falsifiedBy)
          elif overPrefixedOk:
            record(osSubject, "longPathPrefix", coVerified,
                   "the same over-length path succeeds once " &
                   repr(facts.longPathPrefix.value) & " is applied")
            check true
          else:
            let msg = contradictionMessage(osSubject, "longPathPrefix",
              repr(facts.longPathPrefix.value) & " lifts the limit",
              "refuses a " & $overPath.len &
              "-character path even WITH the prefix", "")
            record(osSubject, "longPathPrefix", coContradiction, msg)
            checkpoint(msg)
            fail()
      removeDir(extendedPath(dir))

  test "symlink creation privilege is recorded against what this host does":
    let declared = facts.symlinkCreationIsPrivileged
    var created = false
    var detail = ""
    if volumes.len > 0:
      let dir = caseDir(volumes[0], "symlink")
      let target = dir / "target.bin"
      writeFile(extendedPath(target), "t")
      try:
        createSymlink(target, dir / "link.bin")
        created = fileExists(dir / "link.bin") or
                  symlinkExists(dir / "link.bin")
      except CatchableError, Defect:
        created = false
      detail = "createSymlink " & (if created: "succeeded" else: "was refused")
      removeDir(extendedPath(dir))
    if declared.value.isDefinite:
      expectFact(osSubject, "symlinkCreationIsPrivileged", declared.value,
                 (if created: tnNo else: tnYes), detail)
    else:
      # The declared value is indefinite, so this host's observation
      # constrains it without being able to falsify it in either
      # direction — the framework's ``coPartial`` shape. ``partiallyChecked``
      # records that outcome (and the observed detail) into the ledger the
      # coverage report reads, which is the honest statement here; a bare
      # ``check true`` would have claimed a verification that did not happen.
      partiallyChecked(osSubject, "symlinkCreationIsPrivileged",
             "the declared value is `" & $declared.value &
             "` (Developer Mode flips it on Windows), so this host's " &
             "answer cannot contradict it. Observed: " & detail)

  test "the maximum command line is declared but not driven here":
    # Driving it means spawning a process with a 32767-character command
    # line and one character more. That is a process launch, which
    # `scripts/check_ambient_execution.sh` bans from new files, and the
    # refusal surfaces as a generic CreateProcess failure rather than a
    # distinguishable "too long" error — which is exactly what the
    # fact's own ``obConsequence`` marker says.
    untestedHere(osSubject, "maxCommandLineBytes",
                 hostOsFacts().maxCommandLineBytes.falsifiedBy &
                 " — not driven by this suite: it requires spawning a " &
                 "process, and the failure is not distinguishable from " &
                 "any other CreateProcess/execve refusal")

  test "the linking and cloning APIs named by the OS table are the ones that run":
    # The OS table names an API; the filesystem table says which
    # filesystems answer it. This check closes the loop between them:
    # every present filesystem that DECLARES the capability must actually
    # deliver it through the named API. ``expectFact`` asserts exactly
    # that — a declaring filesystem whose named API fails to produce a
    # second name (or a clone) records a contradiction and fails the run,
    # rather than being silently swallowed as "not exercised".
    var linkExercised = false
    var cloneExercised = false
    for id in presentFilesystems():
      let v = byFilesystem[id]
      let dir = caseDir(v, "osapi")
      let src = dir / "src.bin"
      writeFile(extendedPath(src), "payload")
      if FilesystemTable[id].hardlinks.value == tnYes:
        let linked = attemptHardlink(src, dir / "second.bin").outcome == loOk and
                     hardlinkCount(src) == 2
        expectFact(osSubject, "hardlinkApi", tnYes,
                   (if linked: tnYes else: tnNo),
                   facts.hardlinkApi.value & " on " & subjectOf(v) &
                   (if linked: " created a second name and the inode's " &
                    "link count rose to 2"
                    else: " did NOT create a second name with link count 2"))
        linkExercised = true
      if FilesystemTable[id].reflink.value == tnYes:
        let cloned = attemptReflink(src, dir / "clone.bin").outcome == loOk
        expectFact(osSubject, "reflinkApi", tnYes,
                   (if cloned: tnYes else: tnNo),
                   facts.reflinkApi.value & " on " & subjectOf(v) &
                   (if cloned: " produced a clone of the source bytes"
                    else: " did NOT produce a clone"))
        cloneExercised = true
      removeDir(extendedPath(dir))
    checkpoint(osSubject & ": hardlinkApi=" & facts.hardlinkApi.value &
               " exercised=" & $linkExercised & "; reflinkApi=" &
               facts.reflinkApi.value & " exercised=" & $cloneExercised)
    # Preserve the ledger-coverage invariant: if no present filesystem
    # declared the capability, the API was never driven here, and the
    # fact is recorded untested rather than left as a coverage hole.
    if not linkExercised:
      untestedHere(osSubject, "hardlinkApi",
                   "no host filesystem both declares hardlinks and " &
                   "produced one, so the named API was not exercised")
    if not cloneExercised:
      untestedHere(osSubject, "reflinkApi",
                   "no host filesystem declares reflink support, so the " &
                   "named API was not exercised")

  test "POSIX mode-bit honouring and O_TMPFILE match the table":
    let modeDeclared = facts.honoursPosixModeBits
    if volumes.len > 0 and modeDeclared.value.isDefinite:
      let dir = caseDir(volumes[0], "osmode")
      let f = dir / "mode.bin"
      writeFile(extendedPath(f), "m")
      let wanted = {fpUserRead, fpUserWrite, fpGroupRead}
      setFilePermissions(extendedPath(f), wanted)
      let got = getFilePermissions(extendedPath(f))
      expectFact(osSubject, "honoursPosixModeBits", modeDeclared.value,
                 (if got == wanted: tnYes else: tnNo),
                 "set " & $wanted & ", read back " & $got)
      removeDir(extendedPath(dir))
    else:
      untestedHere(osSubject, "honoursPosixModeBits",
                   "no writable volume, or the declared value is `" &
                   $modeDeclared.value & "`")
    when defined(linux):
      untestedHere(osSubject, "hasOTmpfile",
                   "O_TMPFILE is declared available on this OS but is a " &
                   "per-filesystem capability; this suite does not bind " &
                   "the open(2) flag")
    else:
      untestedHere(osSubject, "hasOTmpfile",
                   "O_TMPFILE is a Linux open(2) flag; there is no call " &
                   "on this OS to attempt, so `" & $facts.hasOTmpfile.value &
                   "` cannot be contradicted here")

# ---------------------------------------------------------------------------
# The report — requirement 2 made visible
# ---------------------------------------------------------------------------

suite "F2 filesystem-facts conformance — coverage report":
  test "every fact of every filesystem the host offers was accounted for":
    # The guard against the suite quietly stopping short: a fact of a
    # PRESENT filesystem that no test recorded an outcome for is a
    # coverage hole, and it fails here rather than passing invisibly.
    var holes: seq[string] = @[]
    for id in presentFilesystems():
      let subject = subjectOf(byFilesystem[id])
      for factName in FsFactNames:
        if not ledgerHas(subject, factName):
          holes.add(subject & "." & factName)
    let osSubject = "OS " & hostOS
    for factName in OsFactNames:
      if not ledgerHas(osSubject, factName):
        holes.add(osSubject & "." & factName)
    if holes.len > 0:
      checkpoint("no test recorded an outcome for: " & holes.join(", "))
    check holes.len == 0

  test "no declared fact contradicts what this host does":
    var contradictions: seq[string] = @[]
    for e in ledger:
      if e.outcome == coContradiction:
        contradictions.add(e.detail)
    for c in contradictions:
      checkpoint(c)
    check contradictions.len == 0

  test "the run reports what it did NOT verify":
    # Requirement 2, made legible. A green run on a one-filesystem
    # machine must not read as "the table is verified", so the report
    # names the filesystems the table knows and this host does not have,
    # and every fact recorded untested with its reason.
    var verified, partial, untested, contradicted = 0
    for e in ledger:
      case e.outcome
      of coVerified: verified.inc
      of coPartial: partial.inc
      of coUntested: untested.inc
      of coContradiction: contradicted.inc

    var absent: seq[string] = @[]
    for id in FilesystemId:
      if id notin byFilesystem:
        absent.add($id)

    # ``echo``, not ``checkpoint``. A checkpoint is printed only when the
    # case fails, and the whole point of this report is that it must be
    # read on a GREEN run: "the suite passed" and "the table is verified"
    # are different statements, and only this output distinguishes them.
    echo "=== F1 fact-table coverage on this host ==="
    echo "filesystems in the table: ", ord(high(FilesystemId)) + 1,
         "; present on this host: ", byFilesystem.len,
         " (", presentFilesystemsText(), ")"
    echo "filesystems the table knows and this host does NOT have, so " &
         "NOTHING here verifies them: ", absent.join(", ")
    echo "fact outcomes: ", verified, " verified, ", partial,
         " partially checked, ", untested, " untested here, ",
         contradicted, " contradicted"
    echo "--- untested here, with reasons ---"
    for e in ledger:
      if e.outcome == coUntested:
        echo "  ", e.subject, ".", e.factName, ": ", e.detail
    echo "--- partially checked ---"
    for e in ledger:
      if e.outcome == coPartial:
        echo "  ", e.subject, ".", e.factName, ": ", e.detail
    echo "=== end of coverage report ==="

    # The report is not allowed to be empty of either kind of honesty:
    # a run that verified nothing, or one that claimed to verify
    # everything the table holds, would both be wrong on this host.
    check verified > 0
    check untested + partial > 0
    check absent.len > 0 or byFilesystem.len == ord(high(FilesystemId)) + 1

suite "F2 filesystem-facts conformance — teardown":
  # Deliberately a test rather than an ``addExitProc``: under ORC the
  # exit-proc closure runs after this module's globals are destroyed.
  test "every scratch directory this suite created is removed":
    var surviving: seq[string] = @[]
    for d in scratchDirs:
      try:
        removeDir(extendedPath(d))
      except CatchableError, Defect:
        discard
      if dirExists(extendedPath(d)):
        surviving.add(d)
    if surviving.len > 0:
      checkpoint("surviving scratch directories: " & surviving.join(", "))
    check surviving.len == 0
