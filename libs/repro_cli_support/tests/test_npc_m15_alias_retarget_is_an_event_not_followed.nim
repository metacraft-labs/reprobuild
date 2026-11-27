## NPC-M15 verification `test_npc_m15_alias_retarget_is_an_event_not_followed`
## (threat model T9, G42; NPC-AREQ3, NPC-AREQ4, NPC-AREQ16; operator
## decision PA-2). NPC-M11 finding F4's reproduction.
##
## `user` 1.0.0 requires `oldname >= 1.0`. Registry commit 1 has the alias
## `oldname -> alpha`, commit 2 has `oldname -> beta`. The second generation,
## on top of the first, records `alias-retargeted` (before `alpha`, after
## `beta`), keeps `oldname -> alpha` in its shard and keeps `beta` as the
## alias's candidate in the name map (name-map schema 2). A fresh solve of
## `user` at the second generation takes `nimble:alpha`, as at the first,
## and lists `beta` as a candidate that needs acceptance; a refresh of a
## locked project says so too, and `repro lock diff` shows the event. A name
## map with no retargeted alias is byte-identical to its committed fixture
## (written by the build before NPC-M15), and the committed schema-2 fixture
## declares a schema that build's reader does not accept.
##
## Falsifying mutation (recorded in the plan): resolving the alias to the
## registry's current target makes the second solve take `nimble:beta`.

import std/[os, osproc, strutils, tables, tempfiles, unittest]

import repro_nimble_generator
import repro_solver/[version_encoder, variant_encoder, solver_api]

import ./nimble_m7_fixtures

const
  Day = 86_400'u64
  Schema1NameMapHex = staticRead("fixtures/npc_m15_name_map_schema1.hex")
  Schema2NameMapHex = staticRead("fixtures/npc_m15_name_map_schema2.hex")

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

proc freshSolve(b: BuiltIndex; name: string):
    tuple[input: NimbleSolverInput; chosen: Table[string, string]] =
  var idx = openIndex(memorySource(b.objectTable()), b.rootId)
  let opts = NimbleSolveOptions(excludeNewer: -1,
    roots: @[RootRequirement(requirer: "app", name: name, range: "")])
  result.input = solverInput(idx, @[name], nimblePlatformOf("amd64-linux"),
    opts)
  var app = newPackage("app", ["0.1.0"])
  app.depends.add canonicalRequirement(result.input,
    newDependency("nimble:" & name, ""))
  var decls = @[app]
  decls.add lowerToSolver(result.input)
  let empty: seq[VariantDecl] = @[]
  let sol = solve(empty, decls, vpNone)
  for k, v in sol.packages:
    if k.startsWith("nimble:"): result.chosen[k] = v

proc fromHex(hex: string): seq[byte] =
  let h = hex.strip()
  for i in countup(0, h.len - 2, 2):
    result.add byte(parseHexInt(h[i .. i + 1]))

proc fixtureNameMap(): seq[byte] =
  ## The name map of a fixed index with one alias and no candidate: what
  ## `fixtures/npc_m15_name_map_schema1.hex` holds, as written by the
  ## build before NPC-M15.
  let built = buildIndex(buildInput(@[
    package("alpha", @[record("alpha", "v1.0.0")]),
    package("beta", @[record("beta", "v1.0.0")])],
    @[PackageAlias(alias: "oldname", target: "alpha")]))
  built.objectTable()[built.root.nameMap.id]

suite "NPC-M15: an alias retarget is an event the solve does not follow":

  test "alias-retargeted is recorded; the solve keeps alpha; beta is a candidate":
    var w = newWorld("m15-alias")
    let f = newFixture("m15-alias")
    var repos: seq[(string, string)]
    for (name, reqs) in [("user", @["oldname >= 1.0"]), ("alpha", @[]),
                         ("beta", @[])]:
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
    let work = createTempDir("npc-m15-alias-", "")
    let t0 = uint64(daysAgo(30))
    proc generation(rc: string; at: uint64; name, previous: string):
        GenerationResult =
      let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"),
        rc), "s.toml")
      result = generate(f.genConfig(ss, at, work / "state",
        previous = (if previous.len > 0: work / previous else: ""),
        outputDir = work / name))
      checkpoint name & ": " & result.diagnostics.join("; ")

    let g1 = generation(rc1, t0, "g1", "")
    check g1.events.len == 0
    let s1 = freshSolve(g1.built, "user")
    check s1.chosen == {"nimble:alpha": "1.0.0", "nimble:user": "1.0.0"}.toTable
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
      checkpoint $e.kind & " " & e.package & " " & e.before & " -> " & e.after
      if e.kind == oeAliasRetargeted:
        inc retargeted
        check e.package == "oldname"
        check e.version == ""
        check e.before == "alpha"
        check e.after == "beta"
        check e.observedAt == t0 + Day
    check retargeted == 1
    var idx2 = openIndex(memorySource(g2.built.objectTable()), g2.built.rootId)
    check idx2.lookupPackage("oldname").package.name == "alpha"
    let names2 = g2.built.objectTable()[g2.built.root.nameMap.id]
    check nameMapSchemaOf(decodeNameMap(names2)) ==
      NimbleNameMapCandidatesSchema
    var entry: NameEntry
    for e in decodeNameMap(names2).entries:
      if e.name == "oldname": entry = e
    check entry.target == "alpha"
    check entry.candidate == "beta"

    # A fresh solve takes alpha, and says beta needs acceptance.
    let s2 = freshSolve(g2.built, "user")
    check s2.chosen == {"nimble:alpha": "1.0.0", "nimble:user": "1.0.0"}.toTable
    check s2.input.aliasCandidates.len == 1
    check s2.input.aliasCandidates[0].alias == "oldname"
    check s2.input.aliasCandidates[0].target == "alpha"
    check s2.input.aliasCandidates[0].candidate == "beta"
    check aliasCandidateNotes(s2.input).len == 1
    # The remedy is the exact `[[policy]]` table that accepts beta (NPC-M17).
    for l in policyTable("oldname", "<the nimble-index import's repo>",
        target = "beta").splitLines():
      check l in aliasCandidateNotes(s2.input)[0]
    check "target = \"nimble:beta\"" in aliasCandidateNotes(s2.input)[0]

    # The next generation reports the retarget no more and keeps the
    # candidate.
    let g3 = generation(rc2, t0 + 2 * Day, "g3", "g2")
    for e in g3.events: check e.kind != oeAliasRetargeted
    for e in decodeNameMap(g3.built.objectTable()[
        g3.built.root.nameMap.id]).entries:
      if e.name == "oldname":
        check e.target == "alpha"
        check e.candidate == "beta"

    publishGeneration(w, work / "g2", "g2")
    let moved = refreshProvisioning(dir)
    checkpoint moved.output
    check moved.rc == 0
    check "nimble:alpha" in nimbleRows(dir)
    check "nimble:beta" notin nimbleRows(dir)
    check "the registry now names nimble:beta" in moved.output
    let fresh = w.newProject(@[("user", "")])
    let r = refreshProvisioning(fresh)
    checkpoint r.output
    check r.rc == 0
    check "nimble:alpha" in nimbleRows(fresh)
    check "nimble:beta" notin nimbleRows(fresh)
    let diff = lockDiff(oldLock, dir / "repro.lock")
    checkpoint diff.output
    var eventLines = 0
    for l in diff.output.splitLines():
      if "alias-retargeted nimble:oldname" in l and "alpha -> beta" in l:
        inc eventLines
    check eventLines == 1

  test "a name map with no retargeted alias keeps its bytes; a schema-2 one is refused by an older reader's schema check":
    check fixtureNameMap() == fromHex(Schema1NameMapHex)
    check nameMapSchemaOf(decodeNameMap(fixtureNameMap())) ==
      NimbleIndexSchemaVersion
    let two = fromHex(Schema2NameMapHex)
    let m = decodeNameMap(two)
    check encodeNameMap(m) == two
    check nameMapSchemaOf(m) == NimbleNameMapCandidatesSchema
    # The schema field (bytes 12-13 of the frame) is 2, which a reader of
    # schema 1 alone refuses before decoding (`unknown-schema`; measured
    # against the build before NPC-M15, see the plan's Results).
    check two[12] == 2'u8 and two[13] == 0'u8
    # The same entries without the candidate are the schema-1 bytes.
    var plain = m
    for e in plain.entries.mitems: e.candidate = ""
    check encodeNameMap(plain) == fromHex(Schema1NameMapHex)
