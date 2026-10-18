## Every system-scope commit is a distinct, retained generation, even when
## several commits land within one second (reprobuild-pm issue
## 2026-10-18-system-generation-ids-collide-within-one-second;
## System-Profile-And-Infra-Apply.md §State Directory and §Rollback;
## CLI/system/rollback.md: rollback is "an ordinary first-class system
## operation").
##
## Before the fix the generation id was `computePlanId(digest &
## ".generation", host, <whole-second timestamp>)`. An action-edge-only (or
## empty) profile renders to the empty text, so two commits of it by one
## host within one second derived the SAME id, and the second commit's
## `writeGenerationEnvelope` replaced the first generation's envelope:
## `repro system history` listed fewer generations than were committed and
## the replaced state could no longer be rolled back to.
##
## Cases:
##
## * `three_commits_in_one_second_are_three_generations`: three applies of
##   the empty profile, all inside one wall-clock second (the test waits for
##   a fresh second first and re-tries in the next one should the three
##   straddle a boundary). Three distinct ids, three envelopes on disk, each
##   naming its predecessor; `enumerateSystemGenerations` lists them in
##   commit order although their timestamps tie, and
##   `resolveGenerationId("")` (rollback's default target) is the SECOND
##   commit, the one before the active generation.
## * `the_generation_id_is_recomputable_from_its_envelope`: the id each
##   commit recorded equals `deriveGenerationId` over the envelope's own
##   recorded inputs.
## * `a_left_over_generation_directory_is_never_overwritten`: a directory
##   at the id the next commit would derive (what an apply that died between
##   `createDir` and moving `current` leaves) is left alone; the commit takes
##   the next second and records it.
## * `schema_1_envelopes_stay_readable`: an envelope written by the earlier
##   schema (no predecessor field) decodes, with an empty predecessor.
##
## Falsifying mutations (performed; see the issue's Resolution): dropping
## `previousGenerationId` from the id input turns the first two cases red
## (one id for all three commits); dropping `orderTiesByCommitChain`
## from enumeration turns the ordering checks of the first red; dropping the
## existence loop in `allocateGenerationId` turns the third red.
##
## No mocks: the real `runInfraApply` with an empty profile (no resources,
## no action edges, so no broker and no dispatcher is needed), a real state
## directory on the real filesystem, the real envelope writer and reader.

import std/[os, sets, tempfiles, times, unittest]

import blake3
import repro_core

import repro_infra

const
  Host = "gen-collision-test-host"
  EmptyProfileText = ""

proc mkApplyOptions(stateDir: string): ApplyOptions =
  result.stateDir = stateDir
  result.hostIdentity = Host
  result.reproExe = "/usr/bin/false"   # never spawned: nothing to elevate
  result.planId = ""
  result.elevationMode = emNoElevate
  result.noPreview = true

proc nextSecond() =
  ## Wait until the wall clock enters a new second, so the commits that
  ## follow have the most room to share one.
  let start = epochTime().int64
  while epochTime().int64 == start:
    sleep(5)

proc commitsInOneSecond(stateDir: string; n: int): seq[ApplyResult] =
  ## `n` commits of the empty profile whose activation timestamps are all
  ## the same second. A run that straddles a boundary is discarded with its
  ## state dir contents and redone; each apply takes milliseconds, so the
  ## first attempt almost always fits.
  for attempt in 0 ..< 5:
    removeDir(stateDir)
    createDir(stateDir)
    nextSecond()
    result = @[]
    for i in 0 ..< n:
      result.add runInfraApply(EmptyProfileText, mkApplyOptions(stateDir))
    var seconds = initHashSet[int64]()
    for r in result:
      seconds.incl readGenerationEnvelope(
        pointerPath(stateDir, r.generationId)).activationTimestamp
    # A collision overwrites an envelope, so an id may repeat; the second
    # is still read from whichever envelope is there.
    if seconds.len == 1:
      return
  raise newException(AssertionDefect,
    "could not fit " & $n & " commits into one second in 5 attempts")

suite "system generations stay distinct within one second":

  test "three_commits_in_one_second_are_three_generations":
    let tmp = createTempDir("gen-collision-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let stateDir = tmp / "state"
    let commits = commitsInOneSecond(stateDir, 3)
    let ids = @[commits[0].generationId, commits[1].generationId,
      commits[2].generationId]
    checkpoint("ids: " & $ids)
    check ids.toHashSet.len == 3
    let gens = enumerateSystemGenerations(stateDir)
    check gens.len == 3
    var listed: seq[string]
    for g in gens:
      listed.add g.generationId
    # Commit order, although all three timestamps are the same second.
    check listed == ids
    check gens[0].envelope.previousGenerationId == ""
    check gens[1].envelope.previousGenerationId == ids[0]
    check gens[2].envelope.previousGenerationId == ids[1]
    check readCurrentGenerationId(stateDir) == ids[2]
    check gens[2].isActive
    # Rollback's default target is the generation before the active one.
    check resolveGenerationId(stateDir, "") == ids[1]

  test "the_generation_id_is_recomputable_from_its_envelope":
    let tmp = createTempDir("gen-collision-recompute-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let stateDir = tmp / "state"
    let commits = commitsInOneSecond(stateDir, 2)
    for c in commits:
      let env = readGenerationEnvelope(pointerPath(stateDir, c.generationId))
      check env.generationId == c.generationId
      check deriveGenerationId(env.profileDigestHex, env.hostIdentity,
        env.activationTimestamp, env.previousGenerationId) == c.generationId

  test "a_left_over_generation_directory_is_never_overwritten":
    let tmp = createTempDir("gen-collision-leftover-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let stateDir = tmp / "state"
    createDir(stateDir)
    let first = runInfraApply(EmptyProfileText, mkApplyOptions(stateDir))
    let firstEnv = readGenerationEnvelope(
      pointerPath(stateDir, first.generationId))
    # Pre-create the directory of every id the next commit could derive in
    # the next few seconds, each holding a sentinel the commit must not
    # touch. The commit then has to step past all of them.
    let now = epochTime().int64
    var sentinels: seq[string]
    for ts in now - 1 .. now + 3:
      let id = deriveGenerationId(firstEnv.profileDigestHex, Host, ts,
        first.generationId)
      createDir(generationDir(stateDir, id))
      let s = generationDir(stateDir, id) / "sentinel"
      writeFile(s, "left over by a dead apply")
      sentinels.add s
    let second = runInfraApply(EmptyProfileText, mkApplyOptions(stateDir))
    for s in sentinels:
      check fileExists(s)
      check not fileExists(parentDir(s) / "pointer.bin")
    let env = readGenerationEnvelope(pointerPath(stateDir, second.generationId))
    check env.activationTimestamp > now + 3
    check deriveGenerationId(env.profileDigestHex, env.hostIdentity,
      env.activationTimestamp, env.previousGenerationId) == second.generationId
    check enumerateSystemGenerations(stateDir).len == 2

  test "schema_1_envelopes_stay_readable":
    # The schema-1 body: fields 1-8, no predecessor.
    var body: seq[byte]
    body.writeString("aaaa1111aaaa1111aaaa1111aaaa1111")
    body.writeU64Le(1234'u64)
    body.writeString(Host)
    body.writeString("plan")
    body.writeString("digest")
    body.writeString("")
    body.writeU32Le(0'u32)
    body.writeU32Le(0'u32)
    var bytes: seq[byte]
    for ch in GenMagic: bytes.add byte(ord(ch))
    bytes.writeU16Le(1'u16)
    bytes.writeU32Le(uint32(body.len))
    bytes.add body
    let sum = blake3.digest(bytes)
    for b in sum: bytes.add b
    let env = decodeGenerationBytes(bytes)
    check env.schemaVersion == 1
    check env.generationId == "aaaa1111aaaa1111aaaa1111aaaa1111"
    check env.activationTimestamp == 1234
    check env.previousGenerationId == ""
