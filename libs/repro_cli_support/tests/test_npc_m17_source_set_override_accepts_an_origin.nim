## NPC-M17 verification `test_npc_m17_source_set_override_accepts_an_origin`
## (NPC-AREQ16, threat model G7; operator decision A1, 2026-11-25; spec
## Nimble-Package-Catalog.md § 5.1 `[[override]]`).
##
## The repoint of `test_npc_m17_accepted_repointed_origin_is_solved` (`lib`
## from origin A to origin B, which offers 2.0.0), accepted instead by an
## `[[override]]` with `origin = B` in the project's own source set: the
## `nimble-sources.toml` of the index repository the project imports, read
## at the pinned revision. A project locked at A's 1.0.0 takes B's 2.0.0 on
## refresh with no `[[policy]]`, the refresh names the override, and `repro
## lock diff` shows the move and the override. A `[[policy]]` that names the
## same origin agrees with the override and is accepted; one that names
## another origin is a refusal naming both tables, and writes nothing.
##
## The override is read only from the source set the index's root names
## (its identity, spec § 5.1): a generation whose `nimble-sources.toml`
## carries the override but whose root names another source set (the file
## edited after the generation) is refused, naming both identities, and a
## fresh project's refresh writes no lock.
##
## Falsifying mutations (recorded in the plan): reading only
## `repro-catalogs.toml` (``nimbleAcceptances`` not reading the source set's
## overrides) leaves the override unread and the solve on A, and the test
## fails; dropping the identity check reads the edited file's override, the
## fresh project takes B, and the test fails.

import std/[os, strutils, tables, unittest]

import repro_nimble_generator/source_set

import ./nimble_m7_fixtures

proc appendPolicy(dir, table: string): int =
  let path = dir / "repro-catalogs.toml"
  let before = readFile(path)
  result = before.splitLines().len + 1
  writeFile(path, before & "\n" & table & "\n")

suite "NPC-M17: a source-set override accepts an origin":
  test "the override moves the lock to B; a disagreeing policy is refused naming both":
    var w = newWorld("m17-override")
    let mirrorDir = w.root / "mirror"
    createDir(mirrorDir)
    let f = newFixture("m17-override",
      @[Route(prefix: "/mirror/", serveDir: mirrorDir)])
    let srcA = f.package("nim/lib.git", @[nimbleFile("lib"),
      file("src/lib.nim", "proc lib*(): int = 1\n")])
    let srcB = f.package("fork/lib.git", @[nimbleFile("lib"),
      file("src/lib.nim", "proc lib*(): int = 2\n")])
    parseMirror(mirrorDir).putSource(srcA)
    parseMirror(mirrorDir).putSource(srcB)
    let originA = f.url(srcA.path)
    let originB = f.url(srcB.path)
    let v1 = f.recordOf("lib", srcA, "1.0.0")
    var env1 = package("lib", @[v1])
    env1.origins = @[PackageOrigin(url: originA, vcs: ovGit)]
    discard w.publish(@[env1], daysAgo(20), "generation 1",
      extraFiles = @[("nimble-sources.toml", sourceSetText(@[]))])
    let dir = w.newProject(@[("lib", ">= 1.0")])
    let first = refreshProvisioning(dir)
    checkpoint first.output
    check first.rc == 0
    check nimbleRows(dir)["nimble:lib"].coordinates.url == originA
    let before = dir / "before.lock"
    copyFile(dir / "repro.lock", before)

    # Generation 2: the index's source set overrides `lib`'s origin to B,
    # so the generator repoints it (spec § 4.4, `repointed`: "the origin the
    # registry (or an `[[override]]`) names").
    let sources = sourceSetText(@[]) & "\n[[override]]\npackage = \"lib\"\n" &
      "origin = \"" & originB & "\"\n"
    var overrideLine = 0
    let sourceLines = sources.splitLines()
    for i, l in sourceLines:
      if l == "[[override]]": overrideLine = i + 1
    var v2 = f.recordOf("lib", srcB, "2.0.0")
    v2.origin = 1
    var env2 = package("lib", @[v1, v2])
    env2.origins = @[PackageOrigin(url: originA, vcs: ovGit),
      PackageOrigin(url: originB, vcs: ovGit)]
    env2.registryOrigin = 1
    let at2 = daysAgo(1)
    discard w.publish(@[env2], at2, "generation 2", events = @[
      OriginEvent(kind: oeRepointed, package: "lib", before: originA,
        after: originB, observedAt: uint64(at2))],
      extraFiles = @[("nimble-sources.toml", sources)],
      sourceSet = some(sourceSetIdentity(parseSourceSet(sources,
        "nimble-sources.toml"))))
    let overrideAt = IndexRepo & ":nimble-sources.toml:" & $overrideLine

    let moved = refreshProvisioning(dir)
    checkpoint moved.output
    check moved.rc == 0
    let row = nimbleRows(dir)["nimble:lib"]
    check row.coordinates.url == originB
    check row.coordinates.revision == srcB.commit
    check row.version == "2.0.0"
    check ("nimble:lib is taken from " & originB & ", the origin the " &
      "[[override]] at " & overrideAt & " accepts") in moved.output
    let diff = lockDiff(before, dir / "repro.lock")
    checkpoint diff.output
    check ("  ~ nimble:lib: origin " & originA & " (the first recorded) -> " &
      originB & " (repointed, the registry's now), accepted by the " &
      "[[override]] at " & overrideAt) in diff.output

    # A policy that names the same origin agrees: accepted.
    let agreeing = w.newProject(@[("lib", ">= 1.0")])
    discard appendPolicy(agreeing, policyTable("lib", IndexRepo, originB))
    let agreed = refreshProvisioning(agreeing)
    checkpoint agreed.output
    check agreed.rc == 0
    check nimbleRows(agreeing)["nimble:lib"].coordinates.url == originB

    # A policy that names another origin: a refusal naming both, and the
    # committed lock is left as it was.
    let lockBefore = readFile(dir / "repro.lock")
    let line = appendPolicy(dir, policyTable("lib", IndexRepo, originA))
    let refused = refreshProvisioning(dir)
    checkpoint refused.output
    check refused.rc != 0
    check ("nimble:lib is accepted twice, differently: the [[policy]] at " &
      dir / "repro-catalogs.toml:" & $line & " accepts the origin " &
      originA & ", and the [[override]] at " & overrideAt) in refused.output
    check readFile(dir / "repro.lock") == lockBefore

    # Generation 3: the same index and the same `nimble-sources.toml`, but
    # the root names the source set of generation 1 (the override was added
    # to the file after the index was generated). The override is not the
    # index's word: refused, naming both identities, and nothing written.
    let plainIdentity = sourceSetIdentity(parseSourceSet(sourceSetText(@[]),
      "nimble-sources.toml"))
    let editedIdentity = sourceSetIdentity(parseSourceSet(sources,
      "nimble-sources.toml"))
    discard w.publish(@[env2], daysAgo(0), "generation 3", events = @[],
      extraFiles = @[("nimble-sources.toml", sources)],
      sourceSet = some(plainIdentity))
    let unrelated = w.newProject(@[("lib", ">= 1.0")])
    let mismatch = refreshProvisioning(unrelated)
    checkpoint mismatch.output
    check mismatch.rc != 0
    check (IndexRepo & ":nimble-sources.toml at ") in mismatch.output
    check ("is not the source set its index was generated from (its " &
      "identity is " & $editedIdentity & ", the root names " &
      $plainIdentity & ")") in mismatch.output
    check not fileExists(unrelated / "repro.lock")
