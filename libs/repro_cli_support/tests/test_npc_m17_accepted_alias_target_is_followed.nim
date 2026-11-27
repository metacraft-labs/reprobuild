## NPC-M17 verification `test_npc_m17_accepted_alias_target_is_followed`
## (NPC-AREQ3, NPC-AREQ16, threat model T9 and G42; operator decision A1,
## 2026-11-25).
##
## `user` 1.0.0 requires `oldname >= 1.0`. Registry commit 1 has the alias
## `oldname -> alpha`, commit 2 `oldname -> beta`: the second generation
## records `alias-retargeted` and keeps `beta` as the alias's candidate.
## Without an acceptance, a requirement of `oldname` resolves to `alpha` (as
## `test_npc_m15_alias_retarget_is_an_event_not_followed`), and the refresh
## prints the `[[policy]]` table that accepts `beta`. With exactly that table
## committed, it resolves to `beta`: the lock has `beta`'s row and no
## `alpha` row, the refresh says which policy chose it, and `repro lock
## diff` shows the retarget and the policy. A policy naming a target the
## name map does not record for the alias is refused, naming the file and
## the line; so is a target accepted for a name that is not an alias.
##
## Falsifying mutation (recorded in the plan): resolving an alias only
## through its recorded target (``solverInput`` not reading the alias's
## acceptance) ignores the policy, and the test fails.

import std/[os, osproc, strutils, tables, tempfiles, unittest]

import repro_nimble_generator

import ./nimble_m7_fixtures

const Day = 86_400'u64

proc publishGeneration(w: World; dir, message: string) =
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

suite "NPC-M17: an accepted alias target is followed":
  test "the printed policy resolves oldname to beta; an unrecorded target is refused":
    var w = newWorld("m17-alias")
    let f = newFixture("m17-alias")
    var repos: seq[(string, string)]
    for (name, reqs) in [("user", @["oldname >= 1.0"]), ("alpha", @[]),
                         ("beta", @[]), ("gamma", @[])]:
      let r = f.newRepo("nim/" & name & ".git")
      discard r.commit(@[nimbleFile(name, reqs),
        file("src/" & name & ".nim", "proc v*(): int = 1\n")])
      r.tag("v1.0.0")
      r.publish()
      repos.add (name, f.url("nim/" & name & ".git"))
    let reg = f.newRepo("nim-lang/packages.git")
    let rc1 = reg.commit(@[packagesJson(repos, @[("oldname", "alpha")])])
    reg.publish()
    let rc2 = reg.commit(@[packagesJson(repos, @[("oldname", "beta")])])
    reg.publish()
    let work = createTempDir("npc-m17-alias-", "")
    let t0 = uint64(daysAgo(30))
    proc generation(rc: string; at: uint64; name, previous: string):
        GenerationResult =
      let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"),
        rc), "s.toml")
      result = generate(f.genConfig(ss, at, work / "state",
        previous = (if previous.len > 0: work / previous else: ""),
        outputDir = work / name))
      checkpoint name & ": " & result.diagnostics.join("; ")

    discard generation(rc1, t0, "g1", "")
    publishGeneration(w, work / "g1", "g1")
    let dir = w.newProject(@[("user", "")])
    let locked = refreshProvisioning(dir)
    checkpoint locked.output
    check locked.rc == 0
    check "nimble:alpha" in nimbleRows(dir)
    let oldLock = work / "old.lock"
    copyFile(dir / "repro.lock", oldLock)

    let g2 = generation(rc2, t0 + Day, "g2", "g1")
    var retargeted = 0
    for e in g2.events:
      if e.kind == oeAliasRetargeted: inc retargeted
    check retargeted == 1
    publishGeneration(w, work / "g2", "g2")

    # No acceptance: alpha, and the table that accepts beta.
    let kept = refreshProvisioning(dir)
    checkpoint kept.output
    check kept.rc == 0
    check "nimble:alpha" in nimbleRows(dir)
    check "nimble:beta" notin nimbleRows(dir)
    check printedTable(kept.output) ==
      policyTable("oldname", IndexRepo, target = "beta")

    # The printed table, committed: oldname resolves to beta.
    let line = appendPolicy(dir, printedTable(kept.output))
    let at = dir / "repro-catalogs.toml:" & $line
    let moved = refreshProvisioning(dir)
    checkpoint moved.output
    check moved.rc == 0
    let rows = nimbleRows(dir)
    check "nimble:beta" in rows
    check "nimble:alpha" notin rows
    check rows["nimble:beta"].coordinates.url == f.url("nim/beta.git")
    check rows["nimble:user"].depends == @["nimble:beta"]
    check ("nimble:oldname resolves to nimble:beta, the target " & at &
      " accepts (the alias was first recorded with nimble:alpha; the " &
      "registry now names nimble:beta, alias-retargeted)") in moved.output

    let diff = lockDiff(oldLock, dir / "repro.lock")
    checkpoint diff.output
    check "  - nimble:alpha 1.0.0 (removed)" in diff.output
    check "  + nimble:beta 1.0.0" in diff.output
    check ("  ~ nimble:oldname: resolves to nimble:beta (the alias's " &
      "recorded target is nimble:alpha), accepted by the [[policy]] at " &
      at) in diff.output
    var eventLines = 0
    for l in diff.output.splitLines():
      if "alias-retargeted nimble:oldname" in l and "alpha -> beta" in l:
        inc eventLines
    check eventLines == 1

    # A target the name map does not record for the alias is refused.
    let other = w.newProject(@[("user", "")])
    let badLine = appendPolicy(other, policyTable("oldname", IndexRepo,
      target = "gamma"))
    let bad = refreshProvisioning(other)
    checkpoint bad.output
    check bad.rc != 0
    check (other / "repro-catalogs.toml:" & $badLine & ": [[policy]] " &
      "accepts the target nimble:gamma for the alias nimble:oldname, which ") in
      bad.output
    check "its name map records nimble:alpha and nimble:beta" in bad.output
    check not fileExists(other / "repro.lock")

    # A target accepted for a name that is not an alias is refused.
    let third = w.newProject(@[("user", "")])
    let notAlias = appendPolicy(third, policyTable("alpha", IndexRepo,
      target = "beta"))
    let refused = refreshProvisioning(third)
    checkpoint refused.output
    check refused.rc != 0
    check (third / "repro-catalogs.toml:" & $notAlias & ": [[policy]] " &
      "accepts the target nimble:beta for nimble:alpha, which ") in
      refused.output
    check "records as a package, not an alias" in refused.output
