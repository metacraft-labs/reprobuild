## NPC-M17 verification `test_npc_m17_accepted_revived_origin_is_solved`
## (NPC-AREQ4 `revived`, NPC-AREQ16, threat model T8 and G41; operator
## decision A1, 2026-11-25).
##
## `pkg` v1.0.0 is recorded from origin O at generation 1. O is `gone` at
## generation 2 and answers at generation 3 with new history holding none
## of the recorded commits and a tag v1.1.0: generation 3 records `revived`
## and a revival entry of O. Without an acceptance, the project locked at
## 1.0.0 keeps it on refresh and v1.1.0 is excluded as `revived-origin` (as
## `test_npc_m15_revived_origin_is_a_repoint_candidate`); the refresh prints
## the `[[policy]]` table that accepts the revival entry, its `revived` time
## included. With exactly that table committed, the refresh takes 1.1.0;
## `repro lock diff` shows the move from O as first recorded to O as
## revived, with the policy, and the `repro info` lines (``nimbleSourceInfo``,
## what NPC-M8's `repro info nimble:<pkg>` prints) list both entries and
## the accepted one with the policy. A `[[policy]]` naming O without
## `revived` names the entry as first recorded, and keeps 1.0.0.
##
## The policy removed afterwards, the lock row still names the revival
## entry's commit, so a refresh keeps 1.1.0 (the origin the lock records,
## as a repointed origin's row keeps its origin), and prints the table that
## would take O as first recorded again.
##
## Falsifying mutations (recorded in the plan): treating a revival entry as
## never acceptable (``originOf`` skipping an entry with a revival time)
## keeps the exclusion, and the test fails; ``acceptedOrigin`` taking the
## first entry of the row's URL (ignoring the locked commit) moves the row
## back to 1.0.0 once the policy is removed, and the test fails.

import std/[os, osproc, strutils, tables, tempfiles, unittest]

import repro_nimble_generator

import ./nimble_m7_fixtures

const Day = 86_400'u64

proc publishGeneration(w: World; dir, message: string) =
  ## Commit the generator's own `published-index/` and sync the clone.
  let up = w.repo.upstream
  if execCmdEx("git -C " & quoteShell(up) &
      " rev-parse --verify -q refs/heads/main").exitCode == 0:
    discard git(["checkout", "-q", "-f", "main"], up)
  if dirExists(up / "published-index"): removeDir(up / "published-index")
  copyDir(dir, up / "published-index")
  discard git(["add", "-A"], up)
  discard git(["commit", "-q", "--allow-empty", "-m", message], up)
  discard w.repo.syncSharedClone(w.clones)

proc printedTable(output: string): string =
  ## The `[[policy]]` table a remedy printed: the indented lines under the
  ## first "add to ...:".
  var lines = output.splitLines()
  var i = 0
  while i < lines.len and not (lines[i].endsWith(":") and
      "add to " in lines[i]):
    inc i
  inc i
  var table: seq[string]
  while i < lines.len and lines[i].startsWith("          "):
    table.add lines[i].strip()
    inc i
  table.join("\n")

proc appendPolicy(dir, table: string): int =
  let path = dir / "repro-catalogs.toml"
  let before = readFile(path)
  result = before.splitLines().len + 1
  writeFile(path, before & "\n" & table & "\n")

suite "NPC-M17: an accepted revived origin is solved":
  test "the printed policy takes the revival's 1.1.0; diff and info show the acceptance":
    var w = newWorld("m17-revived")
    let f = newFixture("m17-revived")
    let repo = f.newRepo("nim/pkg.git")
    let c1 = repo.commit(@[nimbleFile("pkg"),
      file("src/pkg.nim", "proc v*(): int = 1\n")])
    repo.tag("v1.0.0")
    repo.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let rc = reg.commit(@[packagesJson(@[("pkg", f.url("nim/pkg.git"))])])
    reg.publish()
    let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"), rc),
      "s.toml")
    let work = createTempDir("npc-m17-revived-", "")
    let t0 = uint64(daysAgo(30))
    proc generation(at: uint64; name, previous: string): GenerationResult =
      result = generate(f.genConfig(ss, at, work / "state",
        previous = (if previous.len > 0: work / previous else: ""),
        outputDir = work / name))
      checkpoint name & ": " & result.diagnostics.join("; ")

    discard generation(t0, "g1", "")
    publishGeneration(w, work / "g1", "g1")
    let dir = w.newProject(@[("pkg", ">= 1.0")])
    let locked = refreshProvisioning(dir)
    checkpoint locked.output
    check locked.rc == 0
    check nimbleRows(dir)["nimble:pkg"].version == "1.0.0"
    let oldLock = work / "old.lock"
    copyFile(dir / "repro.lock", oldLock)

    f.deleteServed("nim/pkg.git")
    discard generation(t0 + Day, "g2", "g1")
    publishGeneration(w, work / "g2", "g2")
    let jack = f.newRepo("jack/pkg.git")
    let j1 = jack.commit(@[nimbleFile("pkg"),
      file("src/pkg.nim", "proc v*(): int = 666\n")], date = 1_700_100_000)
    jack.tag("v1.1.0")
    jack.publish()
    moveDir(f.root / "jack/pkg.git", f.root / "nim/pkg.git")
    let g3 = generation(t0 + 2 * Day, "g3", "g2")
    var revived = 0
    for e in g3.events:
      if e.kind == oeRevived: inc revived
    check revived == 1
    let env3 = g3.built.envelopeOf("pkg")
    require env3.origins.len == 2
    check env3.origins[1].revivedAt == t0 + 2 * Day
    publishGeneration(w, work / "g3", "g3")
    let origin = env3.origins[0].url

    # No acceptance: 1.0.0 is kept, and the refresh prints the table that
    # accepts the revival entry.
    let kept = refreshProvisioning(dir)
    checkpoint kept.output
    check kept.rc == 0
    check nimbleRows(dir)["nimble:pkg"].version == "1.0.0"
    let expected = policyTable("pkg", IndexRepo, origin, t0 + 2 * Day)
    check printedTable(kept.output) == expected
    check "revived = \"" & isoUtc(int64(t0 + 2 * Day)) & "\"" in expected

    # A policy naming O without `revived` names the entry as first
    # recorded: still 1.0.0.
    discard appendPolicy(dir, policyTable("pkg", IndexRepo, origin))
    let plain = refreshProvisioning(dir)
    checkpoint plain.output
    check plain.rc == 0
    check nimbleRows(dir)["nimble:pkg"].version == "1.0.0"
    check nimbleRows(dir)["nimble:pkg"].coordinates.revision == c1
    writeFile(dir / "repro-catalogs.toml",
      readFile(dir / "repro-catalogs.toml").replace(
        "\n" & policyTable("pkg", IndexRepo, origin) & "\n", ""))

    # The printed table, committed: the solve takes the revival's 1.1.0.
    let line = appendPolicy(dir, printedTable(kept.output))
    let at = dir / "repro-catalogs.toml:" & $line
    let moved = refreshProvisioning(dir)
    checkpoint moved.output
    check moved.rc == 0
    let row = nimbleRows(dir)["nimble:pkg"]
    check row.version == "1.1.0"
    check row.coordinates.revision == j1
    check row.coordinates.url == origin
    let again = refreshProvisioning(dir)
    checkpoint again.output
    check again.rc == 0
    check nimbleRows(dir)["nimble:pkg"].coordinates.revision == j1

    let diff = lockDiff(oldLock, dir / "repro.lock")
    checkpoint diff.output
    check "nimble:pkg: version 1.0.0 -> 1.1.0 (upgrade)" in diff.output
    check ("  ~ nimble:pkg: origin " & origin & " (the first recorded) -> " &
      origin & " (revived " & isoUtc(int64(t0 + 2 * Day)) &
      ", the registry's now), accepted by the [[policy]] at " & at) in
      diff.output
    check "revived nimble:pkg" in diff.output

    # `repro info`'s lines: both entries, and the accepted one.
    let pin = indexPin(dir)
    let index = discoverNimbleIndexAt(pin.repo, pin.remote, pin.gitRef,
      pin.revision, dir)
    let info = nimbleSourceInfo(dir, index, "pkg", lockOf(dir).deps)
    checkpoint info.join("\n")
    check ("  " & origin & " (the first recorded)") in info
    check ("  " & origin & " (revived " & isoUtc(int64(t0 + 2 * Day)) &
      ", the registry's now)") in info
    check ("  taken: " & origin & " (revived " & isoUtc(int64(t0 + 2 * Day)) &
      ", the registry's now), accepted by the [[policy]] at " & at) in info
    let fresh = w.newProject(@[("pkg", ">= 1.0")])
    let freshInfo = nimbleSourceInfo(fresh, index, "pkg")
    checkpoint freshInfo.join("\n")
    check ("  taken: " & origin & " (the first recorded) (no acceptance)") in
      freshInfo

    # The policy removed: the lock row names the revival's commit, so the
    # refresh keeps it, and prints the table that takes O as first recorded.
    writeFile(dir / "repro-catalogs.toml",
      readFile(dir / "repro-catalogs.toml").replace(
        "\n" & printedTable(kept.output) & "\n", ""))
    check "revived =" notin readFile(dir / "repro-catalogs.toml")
    let unaccepted = refreshProvisioning(dir)
    checkpoint unaccepted.output
    check unaccepted.rc == 0
    let stays = nimbleRows(dir)["nimble:pkg"]
    check stays.version == "1.1.0"
    check stays.coordinates.revision == j1
    check printedTable(unaccepted.output) == policyTable("pkg", IndexRepo,
      origin)
