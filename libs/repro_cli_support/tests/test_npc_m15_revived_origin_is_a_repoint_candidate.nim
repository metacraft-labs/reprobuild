## NPC-M15 verification `test_npc_m15_revived_origin_is_a_repoint_candidate`
## (threat model T8, G41; NPC-AREQ4, NPC-AREQ16; operator decision PA-1).
##
## `pkg` v1.0.0 is recorded from origin O. O stops answering (`gone`), and
## then answers again with other history: none of the recorded commits, and
## a tag v1.1.0 (a re-registered name). That generation records `revived`
## (once, not again at the next generation) beside NPC-M11's `tag-removed`
## and `history-rewritten`, and the v1.1.0 record names an origin entry for
## the revival. A fresh solve of `pkg >= 1.0` takes 1.0.0 and lists 1.1.0 as
## excluded `revived-origin`, with the remedy; a project locked at 1.0.0
## keeps it on refresh, and `repro lock diff` shows the event.
##
## Control: an origin that comes back after an outage holding v1.0.0's
## commit, with a new tag v1.0.1, records no `revived`, and v1.0.1 is
## offered (a fresh solve takes it).
##
## A revival entry repeats the recorded entry's spelling of the remote even
## when the registry now spells the same origin otherwise (a `.git` suffix
## dropped), since the codec admits a revival only of a remote an earlier
## entry names.
##
## Falsifying mutation (recorded in the plan): offering the records first
## seen after the revival like any other record makes the fresh solve
## choose 1.1.0.

import std/[options, os, osproc, strutils, tables, tempfiles, unittest]

import repro_nimble_generator
import repro_solver/[version_encoder, variant_encoder, solver_api]

import ./nimble_m7_fixtures

const Day = 86_400'u64

proc publishGeneration(w: World; g: GenerationResult; dir, message: string) =
  ## Commit the generator's own `published-index/` (every object as the
  ## generation wrote it, name map and events included) and sync the clone.
  let up = w.repo.upstream
  if execCmdEx("git -C " & quoteShell(up) &
      " rev-parse --verify -q refs/heads/main").exitCode == 0:
    discard git(["checkout", "-q", "-f", "main"], up)
  if dirExists(up / "published-index"): removeDir(up / "published-index")
  copyDir(dir, up / "published-index")
  discard git(["add", "-A"], up)
  discard git(["commit", "-q", "--allow-empty", "-m", message], up)
  discard w.repo.syncSharedClone(w.clones)

proc freshSolve(b: BuiltIndex; name, rng: string):
    tuple[input: NimbleSolverInput; chosen: Table[string, string]] =
  ## A solve of `app` requiring `nimble:<name> <rng>` with no lock, through
  ## the production solver input and the real solver.
  var idx = openIndex(memorySource(b.objectTable()), b.rootId)
  let opts = NimbleSolveOptions(excludeNewer: -1,
    roots: @[RootRequirement(requirer: "app", name: name, range: rng)])
  result.input = solverInput(idx, @[name], nimblePlatformOf("amd64-linux"),
    opts)
  var app = newPackage("app", ["0.1.0"])
  app.depends.add canonicalRequirement(result.input,
    newDependency("nimble:" & name, rng))
  var decls = @[app]
  decls.add lowerToSolver(result.input)
  let empty: seq[VariantDecl] = @[]
  let sol = solve(empty, decls, vpNone)
  for k, v in sol.packages:
    if k.startsWith("nimble:"): result.chosen[k] = v

proc kinds(g: GenerationResult): seq[string] =
  for e in g.events:
    result.add $e.kind & " " & e.package & " " & e.version & " " & e.before &
      " -> " & e.after

suite "NPC-M15: a revived origin is a repoint candidate":

  test "revived is an event; its new versions are excluded until accepted; the lock keeps 1.0.0":
    var w = newWorld("m15-revived")
    let f = newFixture("m15-revived")
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
    let work = createTempDir("npc-m15-revived-", "")
    let t0 = uint64(daysAgo(30))

    proc generation(at: uint64; name, previous: string): GenerationResult =
      result = generate(f.genConfig(ss, at, work / "state",
        previous = (if previous.len > 0: work / previous else: ""),
        outputDir = work / name))
      checkpoint name & ": " & kinds(result).join("; ") & " | " &
        result.diagnostics.join("; ")

    let g1 = generation(t0, "g1", "")
    publishGeneration(w, g1, work / "g1", "g1")
    let dir = w.newProject(@[("pkg", ">= 1.0")])
    let locked = refreshProvisioning(dir)
    checkpoint locked.output
    check locked.rc == 0
    check nimbleRows(dir)["nimble:pkg"].version == "1.0.0"
    let oldLock = work / "old.lock"
    copyFile(dir / "repro.lock", oldLock)

    # O stops answering.
    f.deleteServed("nim/pkg.git")
    let g2 = generation(t0 + Day, "g2", "g1")
    check kinds(g2) == @["gone pkg  answering -> no answer"]
    publishGeneration(w, g2, work / "g2", "g2")

    # O answers again with other history: none of the recorded commits.
    let jack = f.newRepo("jack/pkg.git")
    let j1 = jack.commit(@[nimbleFile("pkg"),
      file("src/pkg.nim", "proc v*(): int = 666\n")], date = 1_700_100_000)
    jack.tag("v1.1.0")
    jack.publish()
    moveDir(f.root / "jack/pkg.git", f.root / "nim/pkg.git")
    let g3 = generation(t0 + 2 * Day, "g3", "g2")
    var revived = 0
    for e in g3.events:
      if e.kind == oeRevived:
        inc revived
        check e.package == "pkg"
        check e.version == ""
        check e.before == "gone"
        check e.after == f.url("nim/pkg.git")
        check e.observedAt == t0 + 2 * Day
    check revived == 1
    check ("tag-removed pkg v1.0.0 " & c1 & " -> ") in kinds(g3)
    check ("history-rewritten pkg v1.0.0 " & c1 & " -> ") in kinds(g3)
    let env3 = g3.built.envelopeOf("pkg")
    check env3.origins.len == 2
    check env3.origins[0].revivedAt == 0
    check env3.origins[1].revivedAt == t0 + 2 * Day
    check env3.origins[1].url == env3.origins[0].url
    check env3.registryOrigin == 1
    for v in env3.versions:
      if v.commit == c1: check v.origin == 0
      if v.commit == j1:
        check v.origin == 1
        check v.version.tag == "v1.1.0"
    check env3.versions.len == 2
    publishGeneration(w, g3, work / "g3", "g3")

    # Reported once: the next generation records no event.
    let g4 = generation(t0 + 3 * Day, "g4", "g3")
    check g4.events.len == 0
    check g4.built.envelopeOf("pkg").origins.len == 2
    publishGeneration(w, g4, work / "g4", "g4")

    # A fresh solve takes 1.0.0; 1.1.0 is excluded as `revived-origin`.
    let s = freshSolve(g4.built, "pkg", ">= 1.0")
    check s.chosen.getOrDefault("nimble:pkg") == "1.0.0"
    var excluded = 0
    for p in s.input.packages:
      for c in p.candidates:
        if c.record.commit == j1:
          check not c.offered
          for x in c.exclusions:
            checkpoint $x.kind & ": " & x.detail
            if x.kind == exRevivedOrigin:
              inc excluded
              # The remedy is the exact `[[policy]]` table that accepts the
              # revival entry, its `revived` time included (NPC-M17).
              for l in policyTable("pkg", "<the nimble-index import's repo>",
                  f.url("nim/pkg.git"), t0 + 2 * Day).splitLines():
                check l in x.detail
              check "revived" in x.detail
    check excluded == 1

    # Through the lock verbs: a fresh project locks 1.0.0, the locked one
    # keeps it, and the diff shows the event.
    let fresh = w.newProject(@[("pkg", ">= 1.0")])
    let r = refreshProvisioning(fresh)
    checkpoint r.output
    check r.rc == 0
    check nimbleRows(fresh)["nimble:pkg"].version == "1.0.0"
    let again = refreshProvisioning(dir)
    checkpoint again.output
    check again.rc == 0
    check nimbleRows(dir)["nimble:pkg"].version == "1.0.0"
    check nimbleRows(dir)["nimble:pkg"].coordinates.revision == c1
    let diff = lockDiff(oldLock, dir / "repro.lock")
    checkpoint diff.output
    var eventLines = 0
    for l in diff.output.splitLines():
      if "revived nimble:pkg" in l: inc eventLines
    check eventLines == 1

  test "control: an outage that comes back with the recorded commit and a new tag records no revival":
    let f = newFixture("m15-revived-control")
    let repo = f.newRepo("nim/pkg.git")
    discard repo.commit(@[nimbleFile("pkg"),
      file("src/pkg.nim", "proc v*(): int = 1\n")])
    repo.tag("v1.0.0")
    repo.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let rc = reg.commit(@[packagesJson(@[("pkg", f.url("nim/pkg.git"))])])
    reg.publish()
    let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"), rc),
      "s.toml")
    let work = createTempDir("npc-m15-revived-control-", "")
    let t0 = uint64(daysAgo(30))
    discard generate(f.genConfig(ss, t0, work / "state",
      outputDir = work / "g1"))
    copyDir(f.root / "nim/pkg.git", work / "saved.git")
    f.deleteServed("nim/pkg.git")
    let g2 = generate(f.genConfig(ss, t0 + Day, work / "state",
      previous = work / "g1", outputDir = work / "g2"))
    check kinds(g2) == @["gone pkg  answering -> no answer"]
    copyDir(work / "saved.git", f.root / "nim/pkg.git")
    let c2 = repo.commit(@[nimbleFile("pkg"),
      file("src/pkg.nim", "proc v*(): int = 2\n")], date = 1_700_100_000)
    repo.tag("v1.0.1")
    repo.publish()
    let g3 = generate(f.genConfig(ss, t0 + 2 * Day, work / "state",
      previous = work / "g2", outputDir = work / "g3"))
    checkpoint kinds(g3).join("\n")
    for e in g3.events: check e.kind != oeRevived
    let env = g3.built.envelopeOf("pkg")
    check env.origins.len == 1
    var found = false
    for v in env.versions:
      if v.commit == c2:
        found = true
        check v.origin == 0
    check found
    let s = freshSolve(g3.built, "pkg", ">= 1.0")
    check s.chosen.getOrDefault("nimble:pkg") == "1.0.1"

  test "a revival keeps the recorded spelling of a remote the registry respells":
    let recorded1 = record("pkg", "v1.0.0")
    let j1 = repeat('b', 40)
    let recorded = PackageOrigin(url: "https://forge.test/nim/pkg.git",
      vcs: ovGit)
    let respelled = PackageOrigin(url: "https://forge.test/nim/pkg",
      vcs: ovGit)
    let prev = PackageEnvelope(name: "pkg", origins: @[recorded],
      registryOrigin: 0, versions: @[recorded1])
    let input = PackageInput(name: "pkg", origin: respelled, listed: true,
      previous: some(prev),
      previousObservation: some(PackageObservation(name: "pkg",
        origin: recorded, state: osGone)),
      refs: some(RefsAnswer(state: anOk, headRef: "main", head: j1,
        tags: @[("v1.1.0", j1)])),
      history: some(HistoryAnswer(state: anOk, branchCommits: @[j1],
        allCommits: @[j1])))
    const At = 1_790_000_500'u64
    let o = assemblePackage(input, GenerationParams(generatedAt: At,
      resolveName: proc(n: string): string {.gcsafe.} = n))
    checkpoint o.diagnostics.join("\n")
    # Not the fallback that keeps the previous records when the shard would
    # be refused: the revival entry itself must be one the codec admits.
    check o.diagnostics.len == 0
    check o.observation.state == osAnswering
    var revived = 0
    for e in o.events:
      checkpoint $e.kind & " " & e.before & " -> " & e.after
      if e.kind == oeRevived: inc revived
    check revived == 1
    check o.envelope.isSome
    let env = o.envelope.get
    require env.origins.len == 2
    check env.origins[1].url == recorded.url
    check env.origins[1].revivedAt == At
    check env.registryOrigin == 1
    var shape = env
    shape.versions = @[]
    try:
      validatePackage(shape, "pkg")
    except CatchableError as e:
      checkpoint e.msg
      check false
