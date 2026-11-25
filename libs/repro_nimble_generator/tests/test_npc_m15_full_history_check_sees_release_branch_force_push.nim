## NPC-M15 verification
## `test_npc_m15_full_history_check_sees_release_branch_force_push`
## (threat model G43; NPC-AREQ4; operator decision M4-P2).
##
## `pkg`'s origin has `main` (its `HEAD`) and `release`. Two of its records
## are on `release` only: the tag `v1.0.0`, cut on `release`, and a commit
## `user` requires by `#<commit>`. `release` is then force-pushed while
## `HEAD` stays put. A per-generation run reports nothing: its rule looks
## only at whether `HEAD` left the branches, which is the documented
## weakness. A `--full-history` generation reports `history-rewritten` for
## both commits, and the next full check does not report them again. With
## `history_check_days = 7` (the default) and the generation time as the
## clock, a generation 6 days after the last full check runs per-generation
## and one 7 days after runs full. The root says which mode ran, and
## `repro catalog verify` of the full-check generation agrees (same root).
##
## The plan names a `#release` requirement for one of the two records; the
## generator records no `ref` record for a `#<branch>` requirement, so a tag
## cut on the release branch stands in for it (see the plan's Results).
##
## Falsifying mutation (recorded in the plan): running the per-generation
## rule in full-history mode leaves the rewritten `release` commits
## unreported.

import std/[algorithm, os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator

import ./generator_fixtures

const
  Day = 86_400'u64
  T1 = 1_790_000_000'u64

proc rewrittenOf(g: GenerationResult): seq[string] =
  for e in g.events:
    if e.kind == oeHistoryRewritten and e.package == "pkg":
      result.add e.version & " " & e.before
  result.sort()

suite "NPC-M15: the full history check sees a force-pushed release branch":

  test "per-generation misses it, the full check reports it once, on schedule and on demand":
    let f = newFixture("m15-full-history")
    let repo = f.newRepo("nim/pkg.git")
    discard repo.commit(@[nimbleFile("pkg"),
      file("src/pkg.nim", "proc v*(): int = 0\n")])
    discard git(repo, "checkout", "-q", "-b", "release")
    let r1 = repo.commit(@[nimbleFile("pkg"),
      file("src/pkg.nim", "proc v*(): int = 1\n")], date = 1_700_000_100)
    repo.tag("v1.0.0")
    let r2 = repo.commit(@[nimbleFile("pkg"),
      file("src/pkg.nim", "proc v*(): int = 2\n")], date = 1_700_000_200)
    discard git(repo, "checkout", "-q", "main")
    repo.publish()
    let user = f.newRepo("nim/user.git")
    discard user.commit(@[nimbleFile("user", @["pkg#" & r2]),
      file("src/user.nim", "proc u*(): int = 1\n")])
    user.tag("v1.0.0")
    user.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let rc = reg.commit(@[packagesJson(@[("pkg", f.url("nim/pkg.git")),
      ("user", f.url("nim/user.git"))])])
    reg.publish()
    let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"), rc),
      "s.toml")
    check ss.policy.historyCheckDays == 7
    let work = createTempDir("npc-m15-full-history-", "")
    proc generation(at: uint64; name, previous: string;
                    mode = hmScheduled): GenerationResult =
      var cfg = f.genConfig(ss, at, work / "state",
        previous = (if previous.len > 0: work / previous else: ""),
        outputDir = work / name)
      cfg.historyMode = mode
      result = generate(cfg)
      var ev: seq[string]
      for e in result.events:
        ev.add $e.kind & " " & e.package & " " & e.version & " " & e.before
      checkpoint name & ": " & ev.join("; ") & " | " &
        result.diagnostics.join("; ")

    # The first generation has nothing recorded to check: it is a full
    # check at no cost, and the schedule starts there.
    let g1 = generation(T1, "g1", "")
    check g1.built.root.fullHistory
    check g1.built.root.lastFullCheck == T1
    var recorded: seq[string]
    for v in g1.built.envelopeOf("pkg").versions: recorded.add v.commit
    check r1 in recorded
    check r2 in recorded

    # `release` force-pushed; `HEAD` (`main`) stays put; the tag stays.
    discard git(repo, "checkout", "-q", "release")
    discard git(repo, "reset", "-q", "--hard", "main")
    discard repo.commit(@[nimbleFile("pkg"),
      file("src/pkg.nim", "proc v*(): int = 3\n")], date = 1_700_000_300)
    discard git(repo, "checkout", "-q", "main")
    repo.publish()

    # A per-generation run reports nothing: the documented weakness.
    let g2 = generation(T1 + Day, "g2", "g1")
    check not g2.built.root.fullHistory
    check g2.built.root.lastFullCheck == T1
    check g2.events.len == 0

    # On demand: the full check reports both commits.
    let g3 = generation(T1 + 2 * Day, "g3", "g2", hmFull)
    check g3.built.root.fullHistory
    check g3.built.root.lastFullCheck == T1 + 2 * Day
    check rewrittenOf(g3) == @["v1.0.0 " & r1, r2 & " " & r2].sorted()
    check g3.events.len == 2
    check g3.built.observationOf("pkg").reported == @[r1, r2].sorted()

    # The next full check does not report them again.
    let g4 = generation(T1 + 3 * Day, "g4", "g3", hmFull)
    check g4.built.root.fullHistory
    check g4.events.len == 0

    # By schedule: 6 days after the last full check, per-generation; 7 days
    # after, full.
    let g5 = generation(T1 + 9 * Day, "g5", "g4")
    check not g5.built.root.fullHistory
    check g5.built.root.lastFullCheck == T1 + 3 * Day
    let g6 = generation(T1 + 10 * Day, "g6", "g5")
    check g6.built.root.fullHistory
    check g6.built.root.lastFullCheck == T1 + 10 * Day
    check g6.events.len == 0

    # The independent repeat of the full-check generation runs the same
    # mode and agrees.
    let v = verifyIndex(work / "g3", ss, work / "g2", work / "verify-state",
      GeneratorConfig(policy: testPolicy(f), gitBin: f.gitBin, shardBits: -1))
    for d in v.differences:
      checkpoint d.package & " " & d.field & ": " & d.published & " / " &
        d.repeated
    check v.verified
    check v.repeatedRoot == g3.built.rootId
    let vp = verifyIndex(work / "g2", ss, work / "g1", work / "verify-state2",
      GeneratorConfig(policy: testPolicy(f), gitBin: f.gitBin, shardBits: -1))
    check vp.verified
