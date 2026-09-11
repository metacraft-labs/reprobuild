## DA-1i / DA-1j — what a capture SAYS about its own scope, and what this
## build does about it.
##
## `repro build --evidence=full|reads-only` selects how much of what the
## monitor observes gets written down. `reads-only` drops the lookups that
## found nothing, which reproduces the evidence model of a compiler-emitted
## depfile and, with it, ninja's precise one-directional staleness: a file
## ADDED that shadows one earlier in a search path does not invalidate, and
## neither does a file that existed but could not be OPENED becoming openable.
## Modified and deleted inputs are still caught. The hazard table is normative
## and lives in three places; `reprobuild-specs/CLI/build.md` §"Dependency
## Evidence Scope" is the source.
##
## THIS FILE GRADES THE CONSUMER HALF. Every capture stamps the scope it was
## taken under, and a build that requires more than a capture offers must not
## trust it. The property under test is a PARTIAL ORDER, not a partition:
##
##   full evidence      covers  full      AND  reads-only
##   reads-only         covers  reads-only only
##   a scope this build cannot name covers NOTHING, including itself
##
## Both directions are graded, and the reason is that only one of them is. A
## predicate that refuses EVERY capture satisfies "a narrowed record is
## refused" perfectly, and the cost of shipping it is that a careful
## teammate's full-evidence record stops being usable by anyone — the exact
## outcome the partial order exists to avoid. So each refusal case here is
## paired with the acceptance case that a refuse-everything implementation
## would fail.
##
## MOCK POLICY — NO MOCKS. The captures below are written with io-mon's OWN
## canonical encoder (`encodeCanonical`), carry this host's real backend
## profile from io-mon's OWN `profileRecords(defaultHooksMonitorProfile())`,
## and are read back by the production reader through the production fold
## (`foldMonitorDepFileEvidence`). What is CHOSEN rather than observed is the
## `evidence=` / `interest=` stamp on the profile record's detail — which is
## the one thing that cannot be observed here, because producing a genuinely
## narrowed capture needs a real monitored process and a real shim. That end
## of the contract is graded by
## `tests/integration/t_da1i_evidence_scope_reaches_io_mon.nim`, which runs the
## real `repro internal io monitor` under both scopes and compares the record
## counts and the stamps it really wrote. The two files are complementary and
## neither is sufficient: this one cannot produce a narrowed capture, and that
## one cannot enumerate the refusal matrix.
##
## WHAT THIS FILE DELIBERATELY DOES NOT CONTAIN: a second copy of the partial
## order. `evidenceScopeCovers` and `observedInterestCovers` live in io-mon,
## beside the enums they order, and `monitorScopeRefusal` delegates to them.
## The structural case at the end asserts that reprobuild cannot be ordering
## scopes behind their backs, because its code never names the narrow scope at
## all.

import std/[os, strutils, unittest]

import repro_build_engine
import repro_core
import repro_test_support
import io_mon/[types, writer, capabilities, encode]

const TmpDir = "build/test-tmp/t_da1i_evidence_scope"

const EngineModuleRelPath =
  "libs/repro_build_engine/src/repro_build_engine.nim"

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

proc countOccurrences(haystack, needle: string): int =
  var pos = 0
  while true:
    let hit = haystack.find(needle, pos)
    if hit < 0: break
    inc result
    pos = hit + needle.len

proc repoRoot(): string =
  ## The reprobuild checkout this test was compiled from, found by walking up
  ## from this source file rather than trusting the cwd the runner chose.
  var dir = currentSourcePath().parentDir
  while true:
    if fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError, "cannot locate reprobuild repo root")

proc profileWithStamps(extra: string): seq[MonitorRecord] =
  ## This host's REAL backend profile, with the capture-scope stamps appended
  ## to the profile record's detail exactly as io-mon's writer appends them —
  ## `;`-separated keys on `mrBackendProfile.detail`, which is why neither
  ## stamp needed a depfile envelope bump.
  ##
  ## The profile records are not decoration. A capture with none of them
  ## leaves `entropyObservability` at `entUnknown`, and the entropy-blessing
  ## policy refuses the publish on THAT ground, so a fixture without them
  ## would read green while failing closed for an unrelated reason.
  result = profileRecords(defaultHooksMonitorProfile())
  if extra.len == 0:
    return
  var stamped = false
  for record in result.mitems:
    if record.kind == mrBackendProfile:
      record.detail.add(extra)
      stamped = true
  doAssert stamped,
    "this host's profileRecords() produced no mrBackendProfile record, so " &
    "nothing in this file is stamping anything and every case below is " &
    "asserting the unstamped default"

proc capture(extra: string;
             observations: seq[MonitorRecord] = @[]): MonitorDepFile =
  ## A capture as a reader sees it: io-mon parses the stamps, not this file.
  depFileFromRecords(profileWithStamps(extra) & observations)

proc writeCapture(name, extra: string;
                  observations: seq[MonitorRecord] = @[]): string =
  ## The same capture on disk, encoded by io-mon's canonical encoder so the
  ## production reader validates magic, version, framing, sequence numbers and
  ## trailer checksum exactly as it does for a monitor-written file.
  result = TmpDir / (name & ".iomon")
  let encoded = encodeCanonical(profileWithStamps(extra) & observations)
  writeFile(result, cast[string](encoded))

proc readRecord(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
    path: path, osPid: 4242, threadId: 8484)

const
  FullInterestStamp = ";interest=file,proc,lib,nondet,ipc"
    ## What a full-interest capture really stamps — io-mon encodes
    ## `FullInterest` to every token rather than to the empty string, so an
    ## older reader cannot mistake "all" for "unset".
  ReadsOnly = MonitorEvidenceRequirement(
    interest: FullInterest, evidenceScope: esReadsOnly)
  Full = FullMonitorEvidenceRequirement

suite "DA-1i the evidence-scope consumer check":

  test "a reads-only capture is refused by a full-evidence consumer":
    ## The direction the milestone exists for. The capture is honest — it says
    ## what it dropped — and honesty is exactly what lets this build decline
    ## it instead of publishing a narrowed record as complete evidence.
    let dep = capture(FullInterestStamp & ";evidence=reads-only")
    let refusal = monitorScopeRefusal(dep, Full)
    if refusal.len == 0:
      echo "a capture stamped `evidence=reads-only` was accepted by a ",
        "consumer requiring full evidence. That is the false-complete DA-1i ",
        "exists to close: the record's input set is missing every lookup ",
        "that found nothing, so a file added into a search path will not ",
        "invalidate it."
    check refusal.len > 0
    # The refusal must be NAMEABLE, not merely a boolean. An operator who
    # cannot tell a narrowed capture from a corrupt one cannot act on either.
    check refusal.contains("reads-only")
    check refusal.contains("full")

  test "a full-evidence capture is accepted by a reads-only consumer":
    ## THE OTHER DIRECTION, and the one a refuse-everything predicate fails.
    ## Full evidence is strictly STRONGER, so it answers every question a
    ## reads-only consumer can ask. Refusing it here would mean a careful
    ## teammate's record is unusable by anyone who opted into the faster mode
    ## — which is precisely the outcome that made keying on the scope wrong.
    let dep = capture(FullInterestStamp & ";evidence=full")
    let refusal = monitorScopeRefusal(dep, ReadsOnly)
    if refusal.len > 0:
      echo "a capture stamped `evidence=full` was REFUSED by a consumer ",
        "that opted into reads-only: ", refusal,
        "\n  Full evidence is strictly stronger than reads-only evidence. A ",
        "check that refuses it is not conservative, it is a partition — and ",
        "a partition blocks the useful direction."
    check refusal.len == 0

  test "a reads-only capture is accepted by a reads-only consumer":
    ## The second half of the anti-refuse-everything control: a consumer that
    ## asked for the narrower scope gets what it asked for. Without this case
    ## the pair above is still satisfied by "refuse every narrowing".
    let dep = capture(FullInterestStamp & ";evidence=reads-only")
    check monitorScopeRefusal(dep, ReadsOnly).len == 0

  test "a full-evidence capture is accepted by a full-evidence consumer":
    let dep = capture(FullInterestStamp & ";evidence=full")
    check monitorScopeRefusal(dep, Full).len == 0

  test "an evidence scope this build cannot name is refused, not read as full":
    ## `evidence=writes-only` from a newer io-mon. The file is NOT silent about
    ## its scope and it is not full scope: it is a narrowing written in a
    ## vocabulary this build does not have, so it covers nothing and every
    ## consumer rejects it — including a reads-only one, because two builds
    ## that both fail to name a scope have not thereby agreed on it.
    let dep = capture(FullInterestStamp & ";evidence=writes-only")
    let strict = monitorScopeRefusal(dep, Full)
    let relaxed = monitorScopeRefusal(dep, ReadsOnly)
    if strict.len == 0 or relaxed.len == 0:
      echo "a capture declaring an unnamable evidence scope was accepted ",
        "(strict=`", strict, "` relaxed=`", relaxed,
        "`). An unknown token must not read as full scope: that is a ",
        "false-accept pointing FORWARD in time, where every other degrade ",
        "in this path points at `reject`."
    check strict.len > 0
    check relaxed.len > 0
    # And it is nameable: the operator is told which word defeated the build.
    check strict.contains("writes-only")

  test "an EMPTY evidence stamp is refused, not widened to full":
    ## `evidence=` with no value. On io-mon's ENV channel an absent value means
    ## "write everything down", but the KEY's presence here already proves the
    ## producer meant to say something, so an empty value is a statement this
    ## build cannot evaluate. DA-1j shipped this branch's twin undefended.
    let dep = capture(FullInterestStamp & ";evidence=")
    check monitorScopeRefusal(dep, Full).len > 0
    check monitorScopeRefusal(dep, ReadsOnly).len > 0

  test "an ABSENT evidence stamp still reads as full scope":
    ## BACK-COMPAT, and it covers every depfile written before DA-1i shipped.
    ## io-mon deliberately does not stamp `esFull` — "not stated" has always
    ## meant exactly full scope, and stamping it would change the profile-detail
    ## bytes of every capture that exists — so an unstamped capture and a
    ## genuinely full one are the same file, and both must pass a strict
    ## consumer unchanged.
    let dep = capture(FullInterestStamp)
    check dep.observedEvidenceScopeStated == false
    check monitorScopeRefusal(dep, Full).len == 0
    check monitorScopeRefusal(dep, ReadsOnly).len == 0

  test "a capture with no backend-profile record at all reads as full scope":
    ## The other absence: not "a profile that says nothing about scope" but no
    ## profile at all. Same answer, and it has to be the same answer, because
    ## this is what a hand-built or very old capture looks like.
    let dep = depFileFromRecords(@[readRecord("/tmp/x")])
    check monitorScopeRefusal(dep, Full).len == 0

suite "DA-1j the event-interest consumer check":

  test "a narrowed interest stamp is refused by a full-interest consumer":
    ## The same shape on the KIND axis, and the same live defect behind it:
    ## a capture asked for only some categories graded `mcComplete` without
    ## saying it had been narrowed. Note which categories are missing here —
    ## `nondet` carries the env reads that reach the strong fingerprint, and
    ## `ipc` carries the connects whose loss markers force a downgrade.
    let dep = capture(";interest=file,proc,lib")
    let refusal = monitorScopeRefusal(dep, Full)
    if refusal.len == 0:
      echo "a capture stamped `interest=file,proc,lib` was accepted by a ",
        "consumer requiring every category. The record cannot contain the ",
        "env reads that key the action or the IPC connects that downgrade it."
    check refusal.len > 0
    check refusal.contains("file,proc,lib")

  test "a full-interest capture is accepted":
    check monitorScopeRefusal(capture(FullInterestStamp), Full).len == 0

  test "an interest vocabulary this build cannot name is refused":
    ## `interest=gpu` — the residual DA-1j closed. Nothing in the stamp parses,
    ## which is NOT the same fact as no stamp at all.
    let dep = capture(";interest=gpu")
    check dep.statesUnevaluableInterest
    check monitorScopeRefusal(dep, Full).len > 0

  test "an ABSENT interest stamp still reads as full interest":
    let dep = capture("")
    check dep.observedInterestStated == false
    check monitorScopeRefusal(dep, Full).len == 0

suite "DA-1i the refusal reaches the production fold":

  test "the fold downgrades a narrowed capture to Level 2, not Level 3":
    ## The check has to be wired into the path production actually takes, and
    ## it has to land on the right rung of Failure-Semantics.md's ladder.
    ## Level 2 is right because the capture is not corrupt and monitoring did
    ## not fail; Level 3 would punish a successful command for a property of
    ## its evidence.
    ##
    ## THIS CASE GRADES THE STATUS, not the consequence. Turning Level 2 into
    ## "the action succeeds and its publish is skipped" is
    ## `applyMonitorEvidenceStatus`'s existing arm, which predates this change
    ## and has its own coverage; what is new here, and all that is asserted
    ## here, is that the fold reaches that arm for a narrowed capture.
    resetTmp()
    let path = writeCapture("narrowed",
      FullInterestStamp & ";evidence=reads-only",
      @[readRecord("/da1i-fixture/input.txt")])
    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    var attribution = initMonitorPeerAttribution([])
    let status = foldMonitorDepFileEvidence(path, "", evidence, seen,
      attribution, FullMonitorEvidenceRequirement)
    if status != mesUnknownScopeLoss:
      echo "folding a `reads-only` capture under a full-evidence requirement ",
        "returned ", status, ", not mesUnknownScopeLoss. The consumer check ",
        "is not wired into the fold the scheduler calls."
    check status == mesUnknownScopeLoss
    # The reason is carried to the operator, not just to the status enum.
    check evidence.diagnostics.len > 0
    var explained = false
    for diagnostic in evidence.diagnostics:
      if diagnostic.contains("reads-only"):
        explained = true
    check explained
    # AND THE OBSERVATIONS ARE STILL FOLDED. Refusing to TRUST a capture is
    # not refusing to read it: the paths it did record are still the action's
    # evidence, and a build that dropped them would report an edge that
    # observed nothing, which fails closed for a different reason and would
    # make this case green for the wrong one.
    check evidence.monitorReads.len == 1

  test "the same capture folds clean when the build asked for reads-only":
    ## The acceptance direction through the production fold. A build running
    ## under `--evidence=reads-only` must not refuse its OWN captures.
    resetTmp()
    let path = writeCapture("narrowed",
      FullInterestStamp & ";evidence=reads-only",
      @[readRecord("/da1i-fixture/input.txt")])
    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    var attribution = initMonitorPeerAttribution([])
    let status = foldMonitorDepFileEvidence(path, "", evidence, seen,
      attribution, ReadsOnly)
    check status == mesComplete
    check evidence.monitorReads.len == 1

  test "a pre-DA-1i capture folds clean under the default requirement":
    ## The four-argument fold — every caller predating this — must be
    ## byte-for-byte unchanged in behaviour on a capture that states nothing.
    resetTmp()
    let path = writeCapture("silent", "",
      @[readRecord("/da1i-fixture/input.txt")])
    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    check foldMonitorDepFileEvidence(path, "", evidence, seen) == mesComplete

  test "the records fold grades the stamp the same way the file fold does":
    ## The hosted launch path folds records it already has instead of reading
    ## the file back, and the two paths are required to produce identical
    ## evidence for the same action. A guard wired to one of them is a guard
    ## half of production does not execute.
    let records = profileWithStamps(
      FullInterestStamp & ";evidence=reads-only") &
      @[readRecord("/tmp/input.txt")]
    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    var attribution = initMonitorPeerAttribution([])
    check foldMonitorRecordsEvidence(records, "", evidence, seen, attribution,
      FullMonitorEvidenceRequirement) == mesUnknownScopeLoss

suite "DA-1i the evidence scope is not in the cache key":

  test "two captures differing only in their scope stamp key identically":
    ## Trust here is a PARTIAL ORDER, not a partition. Keying on the scope
    ## would make the two modes disjoint and block the useful direction —
    ## the careful teammate publishes and the fast teammate cannot consume —
    ## so the stamp must reach the TRUST decision and nothing else.
    ##
    ## The two captures below record the same observations and differ in one
    ## thing only: the `evidence=` token on the profile record. Both
    ## EVIDENCE-DERIVED components of the action-cache record are compared —
    ## `cacheInputPaths` and `cacheEnvInputs`, the only two things
    ## `recordActionResult` is handed that a capture can influence at all. The
    ## rest of its arguments are properties of the ACTION (its weak
    ## fingerprint, policy, outputs, cwd), which no capture can reach; the
    ## structural check below is what says so.
    resetTmp()
    let observations = @[
      readRecord("/da1i-fixture/a.txt"), readRecord("/da1i-fixture/b.txt")]
    let fullPath = writeCapture("key-full",
      FullInterestStamp & ";evidence=full", observations)
    let narrowPath = writeCapture("key-narrow",
      FullInterestStamp & ";evidence=reads-only", observations)

    let act = action("da1i/key", ["/bin/true"], cwd = TmpDir,
      cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

    var fullEvidence: PathSetEvidence
    var fullSeen: EvidenceSeenSets
    discard foldMonitorDepFileEvidence(fullPath, act.cwd, fullEvidence,
      fullSeen)
    var narrowEvidence: PathSetEvidence
    var narrowSeen: EvidenceSeenSets
    var narrowAttribution = initMonitorPeerAttribution([])
    discard foldMonitorDepFileEvidence(narrowPath, act.cwd, narrowEvidence,
      narrowSeen, narrowAttribution, ReadsOnly)

    let fullKeyed = act.cacheInputPaths(fullEvidence)
    let narrowKeyed = act.cacheInputPaths(narrowEvidence)
    if fullKeyed != narrowKeyed:
      echo "the action-cache input set MOVED when only the evidence-scope ",
        "stamp changed:\n  full       = ", fullKeyed,
        "\n  reads-only = ", narrowKeyed,
        "\n  The scope must not be a key component; keying on it partitions ",
        "the cache and stops a full-evidence record from being served to a ",
        "reads-only lookup."
    check fullKeyed == narrowKeyed
    # Not an empty-equals-empty tautology: the captures really do key on the
    # paths they recorded.
    check fullKeyed.len == 2
    # The OTHER evidence-derived key component, for the same reason — and it is
    # VACUOUS on this fixture, said here rather than left to be discovered:
    # measured `@[]` on both sides, because these captures record file reads
    # and no env reads, so this compares empty against empty. It is kept because
    # `cacheEnvInputs` is the second and last thing `recordActionResult` is
    # handed that a capture can influence at all, so an edit that began routing
    # the scope through the env channel would still have to get past it. It is
    # not kept because it currently discriminates — it does not, and the two
    # checks that do are the path comparison above (measured non-empty, and
    # reddened by leaking the scope token into `monitorReads`) and the
    # read-count audit below.
    check act.cacheEnvInputs(fullEvidence) == act.cacheEnvInputs(narrowEvidence)
    # AND THE OPERATOR'S SCOPE IS READ IN EXACTLY ONE PLACE. The comparisons
    # above say the key did not move for these two captures; this says why it
    # cannot move for any of them. `BuildEngineConfig.evidenceScope` is read
    # once, by `monitorEvidenceScope`, whose answer feeds the monitor REQUEST
    # and the trust REQUIREMENT and nothing else. The three things
    # `recordActionResult` keys on — `cacheInputPaths`, `cacheEnvInputs` and
    # the weak fingerprint — take no `BuildEngineConfig` at all, so there is no
    # channel for the scope to arrive through, and a second reader is how one
    # would be opened.
    let codeOnly = nimSourceCodeOnly(readFile(repoRoot() / EngineModuleRelPath))
    let reads = countOccurrences(codeOnly, "config.evidenceScope")
    if reads != 1:
      echo "`BuildEngineConfig.evidenceScope` is read ", reads,
        " time(s) in the engine's code, expected exactly 1 ",
        "(`monitorEvidenceScope`). A second reader is how the scope reaches ",
        "somewhere it must not, and the place it must not reach is the key."
    check reads == 1

suite "DA-1i the flag vocabulary is io-mon's":

  test "--evidence accepts exactly the two scopes io-mon can name":
    check parseEvidenceScope("full", "--evidence") == esFull
    check parseEvidenceScope("reads-only", "--evidence") == esReadsOnly

  test "--evidence refuses a value io-mon cannot name":
    ## Not `esUnrecognized`, and not a silent fall back to the default. An
    ## operator who typed something wrong must be told, because the two ways
    ## of being quiet here are "you got full when you asked for narrow" and
    ## "you are building under a scope whose own captures this build refuses".
    expect ValueError:
      discard parseEvidenceScope("writes-only", "--evidence")
    expect ValueError:
      discard parseEvidenceScope("reads_only", "--evidence")

  test "--evidence refuses an EMPTY value":
    ## `parseEvidenceScopeToken("")` answers `esFull`, because on the env
    ## channel an absent variable means "record everything". On a command line
    ## `--evidence=` is a typo, and answering a typo with the default is how
    ## an operator who meant `reads-only` silently gets `full`.
    expect ValueError:
      discard parseEvidenceScope("", "--evidence")

  test "every scope this build can ASK FOR has a wire token":
    ## The hole DA-1i's own third verification round named: a future
    ## `EvidenceScope` member added without a token would encode as the empty
    ## string, ship a depfile carrying `evidence=` with no value, and be
    ## refused by every consumer — while the whole suite stayed green,
    ## because nothing enumerated the enum.
    ##
    ## `esUnrecognized` is excluded BY NAME rather than by a skip: it is a
    ## READING of someone else's token, never a scope this build can be asked
    ## for, and giving it a spelling would make it producible and destroy the
    ## distinction it exists to draw.
    for scope in EvidenceScope.low .. EvidenceScope.high:
      if scope == esUnrecognized:
        check evidenceScopeToken(scope).len == 0
        continue
      let token = evidenceScopeToken(scope)
      if token.len == 0:
        echo "EvidenceScope member `", scope, "` has no wire token. A ",
          "capture taken under it would stamp `evidence=` with an empty ",
          "value, which every consumer refuses — discovered as a build that ",
          "quietly stopped caching."
      check token.len > 0
      # And the token round-trips, so the flag an operator types and the stamp
      # a later reader compares against cannot be two different tables.
      check parseEvidenceScopeToken(token) == scope
      check parseEvidenceScope(token, "--evidence") == scope

suite "DA-1i structural: the order is delegated and the flag is forwarded":

  test "the engine never names the narrow scope, so it cannot be ordering it":
    ## An audit a comment can satisfy audits the prose, so this one is
    ## computed over CODE with every comment and string literal blanked.
    ##
    ## The claim is narrow and checkable: reprobuild's engine never writes
    ## `esReadsOnly`. It cannot compare full against reads-only, or branch on
    ## "is this the narrow one", without naming it — so a second copy of the
    ## partial order cannot be hiding in this module. The order lives in
    ## io-mon's `evidenceScopeCovers`, reached through
    ## `observedEvidenceScopeCovers`.
    let src = readFile(repoRoot() / EngineModuleRelPath)
    let codeOnly = nimSourceCodeOnly(src)
    let mentions = countOccurrences(codeOnly, "esReadsOnly")
    if mentions != 0:
      echo "the engine's CODE names `esReadsOnly` ", mentions, " time(s). ",
        "The only reason to name the narrow scope here is to compare it ",
        "against the wide one, and that comparison belongs in io-mon beside ",
        "the enum — two copies of a trust order drift, and the direction ",
        "they drift in is accepting a narrowed capture as complete."
    check mentions == 0
    # And the delegation is really there: exactly one consumer-side call.
    check countOccurrences(codeOnly, "observedEvidenceScopeCovers(") == 1
    check countOccurrences(codeOnly, "observedInterestCovers(") == 1

  test "the wrapped monitor argv forwards the evidence scope exactly once":
    ## The spawned path's ONLY channel. `REPRO_MONITOR_EVIDENCE` is io-mon's
    ## own variable — `childEnv` writes it last, after the caller's env and
    ## after the injected pairs — so an engine that seeded it into the
    ## action's environment would be writing into a variable io-mon
    ## overwrites before any shim could read it. That is exactly how the
    ## INTEREST request was silently discarded on this path once already.
    ##
    ## Neither the end-to-end integration case nor this one is sufficient
    ## alone: that one cannot see a forwarding deleted while the engine's
    ## scope happens to equal io-mon's default, and this one cannot see io-mon
    ## ignoring a flag it was handed.
    let src = readFile(repoRoot() / EngineModuleRelPath)
    let codeOnly = nimSourceCodeOnly(src)
    let sites = countOccurrences(codeOnly,
      "monitorEvidenceFlag(monitorEvidenceScope(config))")
    if sites != 1:
      echo "the engine's wrapped monitor-argv construction forwards the ",
        "evidence scope ", sites, " time(s), expected exactly 1."
    check sites == 1

  test "the hosted monitor request carries the same scope":
    ## The in-process host does not build an argv, so its channel is the
    ## request field. Both hosting forms must ask for the SAME scope for the
    ## same action; the interest axis is one proc for precisely this reason,
    ## after the two paths diverged in production.
    let src = readFile(repoRoot() / EngineModuleRelPath)
    let codeOnly = nimSourceCodeOnly(src)
    check countOccurrences(codeOnly, "evidenceScope: evidenceScope") == 1
    check countOccurrences(codeOnly,
      "depTemp, monitorEvidenceScope(config)") == 1
