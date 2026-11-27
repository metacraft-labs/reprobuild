## NPC-M17 verification `test_npc_m17_develop_overlay_reads_acceptances`
## (NPC-AREQ16, NPC-AREQ27; spec § 13.1, the develop overlay lock's
## re-solve; operator decision A1, 2026-11-25).
##
## `extra` is repointed from origin X (which offers 0.5.0) to origin Y
## (which offers 1.0.0). The project requires `lib` only, so its committed
## lock has no `extra` row. A develop checkout of `lib` adds `extra >= 1.0`,
## and the overlay's re-solve (``solveDevelopOverlay``) must place `extra`
## as the committed lock's solve would:
##
## 1. With a `[[policy]]` accepting Y, the re-solve takes Y's 1.0.0 and the
##    overlay's lock row names Y.
## 2. Without it, Y's records are excluded (`repointed-origin`) and no
##    version satisfies `extra >= 1.0`: the re-solve is refused.
## 3. A `[[policy]]` naming an origin the index does not record for
##    `extra` is refused by the re-solve, naming the file and the line.
##
## Falsifying mutation (recorded in the plan): the overlay re-solve not
## reading the project's acceptances refuses case 1 and accepts case 3,
## and the test fails.
##
## No mock: a real index repository and shared clone and the production
## lock verbs; the overlay's solve runs in process.

import std/[os, sequtils, strutils, tables, unittest]

import repro_cli_support/nimble_develop

import ./nimble_m6_fixtures

proc appendPolicy(dir, table: string): int =
  let path = dir / "repro-catalogs.toml"
  let before = readFile(path)
  result = before.splitLines().len + 1
  writeFile(path, before & "\n" & table & "\n")

proc libCheckout(dir: string): seq[tuple[o: NimbleOverride;
                                         record: VersionRecord]] =
  ## A recorded override of `lib` whose checkout requires `extra >= 1.0`.
  let co = dir / "lib-checkout"
  createDir(co)
  @[(o: NimbleOverride(package: "lib", kind: nokRecorded, checkout: co,
       packageDir: co),
     record: record("lib", "v1.0.0", @[req("extra", ">= 1.0")]))]

suite "NPC-M17: the develop overlay's re-solve reads the acceptances":
  test "an accepted origin places a package the overlay adds; refused without it":
    var w = newWorld("m17-overlay")
    let originX = "https://example.invalid/x/extra"
    let originY = "https://example.invalid/y/extra"
    var old = record("extra", "v0.5.0")
    var moved = record("extra", "v1.0.0")
    moved.origin = 1
    var extra = package("extra", @[old, moved])
    extra.origins = @[PackageOrigin(url: originX, vcs: ovGit),
      PackageOrigin(url: originY, vcs: ovGit)]
    extra.registryOrigin = 1
    let at = daysAgo(1)
    discard w.publish(@[package("lib", @[record("lib", "v1.0.0")]), extra],
      at, "generation 1", events = @[OriginEvent(kind: oeRepointed,
        package: "extra", before: originX, after: originY,
        observedAt: uint64(at))])

    # 1. Accepted: the overlay takes Y's 1.0.0.
    let accepted = w.newProject(@[("lib", ">= 1.0")])
    discard appendPolicy(accepted, policyTable("extra", IndexRepo, originY))
    let locked = refreshProvisioning(accepted)
    checkpoint locked.output
    check locked.rc == 0
    check "nimble:extra" notin nimbleRows(accepted)
    let taken = solveDevelopOverlay(accepted, accepted / "repro.lock",
      libCheckout(accepted))
    checkpoint taken.refusals.join("\n")
    checkpoint taken.overlay.lockText
    check taken.refusals.len == 0
    var row: LockedDep
    var found = false
    if taken.refusals.len == 0:
      for d in parseLockedDependencies(taken.overlay.lockText).deps:
        if d.name == "nimble:extra":
          row = d
          found = true
    check found
    check row.version == "1.0.0"
    check row.coordinates.url == originY
    check row.coordinates.revision == moved.commit

    # 2. Not accepted: Y's records are excluded, and nothing satisfies the
    # checkout's requirement.
    let plain = w.newProject(@[("lib", ">= 1.0")])
    let plainLocked = refreshProvisioning(plain)
    checkpoint plainLocked.output
    check plainLocked.rc == 0
    let refused = solveDevelopOverlay(plain, plain / "repro.lock",
      libCheckout(plain))
    checkpoint refused.refusals.join("\n")
    check refused.refusals.anyIt("no version of nimble:extra the index " &
      "offers satisfies \"extra >= 1.0\"" in it)

    # 3. An acceptance of an origin the index does not record: refused,
    # naming the file and the line.
    let wrong = w.newProject(@[("lib", ">= 1.0")])
    let wrongLocked = refreshProvisioning(wrong)
    checkpoint wrongLocked.output
    check wrongLocked.rc == 0
    let line = appendPolicy(wrong, policyTable("extra", IndexRepo,
      "https://example.invalid/z/extra"))
    let unapplied = solveDevelopOverlay(wrong, wrong / "repro.lock",
      libCheckout(wrong))
    checkpoint unapplied.refusals.join("\n")
    check unapplied.refusals.anyIt((wrong / "repro-catalogs.toml:" & $line &
      ": [[policy]] accepts the origin https://example.invalid/z/extra " &
      "for nimble:extra, which ") in it)
