## NPC-M17 verification `test_npc_m17_accepted_repointed_origin_is_solved`
## (NPC-AREQ16, threat model G7 and T9; operator decision A1, 2026-11-25).
##
## `lib` is repointed from origin A to origin B between generations 1 and 2,
## and B offers 2.0.0. Without an acceptance, a refresh of the project locked
## at A's 1.0.0 and a fresh solve both keep A (as
## `test_npc_m6_pin_survives_repoint`), and each prints the `[[policy]]`
## table that accepts B. With exactly that printed table committed to
## `repro-catalogs.toml`, the refresh takes B's 2.0.0: the lock row names B,
## a later refresh keeps it, `repro lock diff` shows the move and the
## policy, and a build's preparation fetches B's tree by its locked digest
## from the mirror. A policy naming an origin the index does not record for
## `lib` is refused, naming the file and the line, and writes nothing.
##
## A second case reads the acceptance keys of `[[policy]]` strictly: every
## malformed table is refused, naming its line.
##
## Falsifying mutation (recorded in the plan): `candidatesOf` ignoring the
## acceptance (``acceptedOrigin`` not reading ``options.acceptances``) leaves
## the solve on A, and the test fails.
##
## No mock: a real index repository and shared clone, the production lock
## verbs, the production fetch edges and the shared HTTPS fixture as the
## mirror.

import std/[options, os, strutils, tables, unittest]

import repro_interface_artifacts/catalog_declaration

import ./nimble_m7_fixtures

proc printedTable(output: string): string =
  ## The `[[policy]]` table a remedy printed, as the user would paste it:
  ## the indented lines under the first "add to ...:".
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
  ## Append ``table`` to the project's `repro-catalogs.toml`; return the
  ## line its `[[policy]]` header is on.
  let path = dir / "repro-catalogs.toml"
  let before = readFile(path)
  result = before.splitLines().len + 1
  writeFile(path, before & "\n" & table & "\n")

suite "NPC-M17: an accepted repointed origin is solved":
  test "the printed policy moves the lock to the new origin; an unrecorded origin is refused":
    var w = newWorld("m17-repoint")
    let mirrorDir = w.root / "mirror"
    createDir(mirrorDir)
    let f = newFixture("m17-repoint",
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
    discard w.publish(@[env1], daysAgo(20), "generation 1")
    let dir = w.newProject(@[("lib", ">= 1.0")])
    let first = refreshProvisioning(dir)
    checkpoint first.output
    check first.rc == 0
    check nimbleRows(dir)["nimble:lib"].coordinates.url == originA
    let before = dir / "before.lock"
    copyFile(dir / "repro.lock", before)

    # Generation 2: the registry repoints `lib` to B, which offers 2.0.0.
    var v2 = f.recordOf("lib", srcB, "2.0.0")
    v2.origin = 1
    var env2 = package("lib", @[v1, v2])
    env2.origins = @[PackageOrigin(url: originA, vcs: ovGit),
      PackageOrigin(url: originB, vcs: ovGit)]
    env2.registryOrigin = 1
    let at2 = daysAgo(1)
    discard w.publish(@[env2], at2, "generation 2", events = @[
      OriginEvent(kind: oeRepointed, package: "lib", before: originA,
        after: originB, observedAt: uint64(at2))])

    # No acceptance: the locked project and a fresh one keep A, and both
    # print the table that accepts B.
    let expected = policyTable("lib", IndexRepo, originB)
    let kept = refreshProvisioning(dir)
    checkpoint kept.output
    check kept.rc == 0
    check nimbleRows(dir)["nimble:lib"].coordinates.url == originA
    check nimbleRows(dir)["nimble:lib"].version == "1.0.0"
    check printedTable(kept.output) == expected
    let fresh = w.newProject(@[("lib", ">= 1.0")])
    let freshRun = refreshProvisioning(fresh)
    checkpoint freshRun.output
    check freshRun.rc == 0
    check nimbleRows(fresh)["nimble:lib"].coordinates.url == originA
    check printedTable(freshRun.output) == expected

    # The printed table, committed: the solve takes B's 2.0.0.
    let line = appendPolicy(dir, printedTable(kept.output))
    let moved = refreshProvisioning(dir)
    checkpoint moved.output
    check moved.rc == 0
    let row = nimbleRows(dir)["nimble:lib"]
    check row.coordinates.url == originB
    check row.coordinates.revision == srcB.commit
    check row.version == "2.0.0"
    check row.integrity == "blake3:" & srcB.tree
    let at = dir / "repro-catalogs.toml:" & $line
    check ("nimble:lib is taken from " & originB & ", the origin the " &
      "[[policy]] at " & at & " accepts") in moved.output

    # A later refresh keeps it.
    let again = refreshProvisioning(dir)
    checkpoint again.output
    check again.rc == 0
    check nimbleRows(dir)["nimble:lib"].coordinates.revision == srcB.commit

    # `repro lock diff` shows the move and the policy that made it.
    let diff = lockDiff(before, dir / "repro.lock")
    checkpoint diff.output
    check "nimble:lib: version 1.0.0 -> 2.0.0 (upgrade)" in diff.output
    check ("origin " & originA & " -> " & originB) in diff.output
    check "accepted sources:" in diff.output
    check ("  ~ nimble:lib: origin " & originA & " (the first recorded) -> " &
      originB & " (repointed, the registry's now), accepted by the " &
      "[[policy]] at " & at) in diff.output
    check ("repointed nimble:lib: " & originA & " -> " & originB) in diff.output

    # A build's preparation fetches B's tree by its locked digest.
    let store = w.root / "store"
    var cfg = f.fetchConfig(w.root / "fetch", @[f.httpsMirror("/mirror/")],
      store = store)
    cfg.useClosureIndex = false
    var prep: NimbleSourcesReport
    var refusal = ""
    try:
      prep = prepareLockedNimbleSources(dir, dir / "repro.lock",
        NimbleSourcesOptions(fetchConfig: some(cfg)))
    except CatchableError as e:
      refusal = e.msg
    checkpoint refusal
    check refusal.len == 0
    check prep.fetched == @["lib"]
    check entryVerified(store, srcB.tree)
    check prep.storePaths["lib"] == entryPath(store, srcB.tree)

    # A policy naming an origin the index does not record for `lib` is
    # refused, naming the file and line, and the lock is left as it was.
    let other = w.newProject(@[("lib", ">= 1.0")])
    let badLine = appendPolicy(other, policyTable("lib", IndexRepo,
      "https://example.invalid/nowhere/lib"))
    let lockBefore = if fileExists(other / "repro.lock"):
                       readFile(other / "repro.lock") else: ""
    let bad = refreshProvisioning(other)
    checkpoint bad.output
    check bad.rc != 0
    check (other / "repro-catalogs.toml:" & $badLine & ": [[policy]] " &
      "accepts the origin https://example.invalid/nowhere/lib for " &
      "nimble:lib, which ") in bad.output
    check "does not record for it; it records " & originA in bad.output
    check (if fileExists(other / "repro.lock"): readFile(other / "repro.lock")
           else: "") == lockBefore

  test "the acceptance keys of [[policy]] are read strictly":
    const Head = "schema = \"reprobuild.catalog-imports.v1\"\n\n" &
      "[[import]]\nrepo = \"idx\"\nremote = \"https://h/idx\"\n" &
      "kind = \"nimble-index\"\nref = \"main\"\n\n" &
      "[[import]]\nrepo = \"prov\"\nremote = \"https://h/prov\"\n" &
      "ref = \"main\"\n\n"
    let good = parseCatalogImportsDeclaration(Head &
      "[[policy]]\npackage = \"nimble:lib\"\nrepo = \"idx\"\n" &
      "origin = \"https://h/fork/lib?subdir=x\"\n\n" &
      "[[policy]]\npackage = \"nimble:old\"\nrepo = \"idx\"\n" &
      "target = \"nimble:beta\"\n\n" &
      "[[policy]]\npackage = \"nimble:pkg\"\nrepo = \"idx\"\n" &
      "origin = \"https://h/pkg\"\nrevived = \"2026-11-20T00:00:00Z\"\n\n" &
      "[[policy]]\npackage = \"bash\"\ncontributor = \"github:o/r\"\n", "f")
    check good.nimbleAcceptances.len == 3
    check good.nimbleAcceptances[0].package == "lib"
    check good.nimbleAcceptances[0].origin == "https://h/fork/lib?subdir=x"
    check good.nimbleAcceptances[1].target == "beta"
    check good.nimbleAcceptances[2].revivedAt == 1_795_132_800
    check good.policy.selections.len == 1
    proc refusal(tables: string): string =
      try:
        discard parseCatalogImportsDeclaration(Head & tables, "f")
      except CatalogDeclarationError as e:
        return e.msg
      ""
    let cases = @[
      ("[[policy]]\npackage = \"nimble:lib\"\nrepo = \"idx\"\n" &
        "origin = \"https://h/a\"\ncontributor = \"c\"\n",
       "f:14: [[policy]] names both a `contributor`"),
      ("[[policy]]\npackage = \"nimble:lib\"\norigin = \"https://h/a\"\n",
       "f:14: [[policy]] accepting a Nimble source is missing `repo`"),
      ("[[policy]]\npackage = \"nimble:lib\"\nrepo = \"prov\"\n" &
        "origin = \"https://h/a\"\n",
       "f:14: policy repo \"prov\" is not a `nimble-index` [[import]]"),
      ("[[policy]]\npackage = \"lib\"\nrepo = \"idx\"\n" &
        "origin = \"https://h/a\"\n",
       "f:14: policy package \"lib\" is not a `nimble:<name>` package"),
      ("[[policy]]\npackage = \"nimble:lib\"\nrepo = \"idx\"\n",
       "f:14: [[policy]] accepting a Nimble source names exactly one of"),
      ("[[policy]]\npackage = \"nimble:lib\"\nrepo = \"idx\"\n" &
        "origin = \"https://h/a\"\ntarget = \"nimble:b\"\n",
       "names exactly one of"),
      ("[[policy]]\npackage = \"nimble:lib\"\nrepo = \"idx\"\n" &
        "target = \"nimble:b\"\nrevived = \"2026-11-20T00:00:00Z\"\n",
       "f:14: policy `revived` names a revival entry of an origin and " &
         "needs `origin`"),
      ("[[policy]]\npackage = \"nimble:lib\"\nrepo = \"idx\"\n" &
        "origin = \"https://h/a\"\nrevived = \"2026-11-20\"\n",
       "f:14: policy revived \"2026-11-20\" is not a UTC time"),
      ("[[policy]]\npackage = \"nimble:lib\"\nrepo = \"idx\"\n" &
        "target = \"beta\"\n",
       "f:14: policy target \"beta\" is not a `nimble:<name>` package"),
      ("[[policy]]\npackage = \"nimble:lib\"\nrepo = \"idx\"\n" &
        "origin = \" https://h/a\"\n",
       "has leading or trailing whitespace"),
      ("[[policy]]\npackage = \"nimble:lib\"\nrepo = \"idx\"\n" &
        "origin = \"https://h/a\"\nrank = \"1\"\n",
       "unknown key \"rank\" in [[policy]]"),
      ("[[policy]]\npackage = \"nimble:lib\"\nrepo = \"idx\"\n" &
        "origin = \"https://h/a\"\n\n[[policy]]\npackage = \"nimble:L_ib\"\n" &
        "repo = \"idx\"\norigin = \"https://h/b\"\n",
       "f:19: nimble:L_ib is accepted twice through \"idx\" (the other " &
         "[[policy]] is at line 14)")]
    for (tables, expected) in cases:
      let msg = refusal(tables)
      checkpoint tables & "\n=> " & msg
      check expected in msg
