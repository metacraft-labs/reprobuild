## Registry crates are fetched into the store root by fetch edges and
## verified against their `Cargo.lock` checksum.
##
## One `cargo.fetch` edge per locked crate version, derived from the
## lockfile alone, run through the real build engine (`fetchLockedCrates`
## registers the edge executor and calls `runBuild`). What each suite
## checks:
##
## * **A verified fetch lands in its store prefix; a second run is a cache
##   hit.** A real `.crate` made by `cargo package` (GNU headers, one file
##   whose path needs a GNU long-name record) is served by an HTTPS mirror.
##   The edge is `netFetch` and names the mirror and the crate's origin URL
##   as its destinations; the graph passes the network audit. The crate is
##   published at `<store>/prefixes/<name>/<version>-<40 hex>/`, the hex
##   being the store's realization hash of the crate's identity; the tree is
##   the package's files with the top directory stripped, read-only, with
##   the store's receipt; the verified `.crate` is a blob in the store's
##   `cas/`, which the receipt names beside the lock's checksum. An unchanged second run is an engine cache hit (no executor,
##   no request). A second checkout of the same lockfile (another state
##   directory, the same store) runs the edge, which finds the prefix and
##   sends no request.
## * **A checksum mismatch is refused.** A lock whose checksum is not the
##   served bytes' SHA-256 fails the edge: the mirror and the origin are
##   each reported as a mismatch, and the store holds no prefix, no index
##   row, no blob and no staging directory for it.
## * **Verified before extraction (`test_cpc_fetch_verified_before_extract`).**
##   A first mirror serves wrong bytes and a second the right ones: the
##   crate comes from the second, and the first is reported as a checksum
##   mismatch, not as an extraction refusal, although the wrong archive
##   also holds a `../` member (so it was never parsed). The first mirror is
##   then downgraded: the next crate of the wave asks the second mirror
##   first. A `.crate` whose checksum IS the lock's but which holds a `../`
##   member, an absolute member, a member outside `<name>-<version>/`, a
##   single top directory of another name, or a link out of the tree is
##   refused, naming the member, and nothing of it is left in the store.
## * **Shared across projects (`test_cpc_store_shared_across_projects`).**
##   A second project, with its own lockfile and state directory, that
##   locks a crate the first already fetched gets the same prefix and sends
##   no request for it.
## * **Only crates.io rows are fetch edges.** A `git+` package and another
##   registry's package are reported as unfetched, with the reason, and get
##   no edge.
##
## Falsifying mutations, each applied once by hand and reverted (see the
## change's report): accepting bytes whose SHA-256 differs from the lock
## fails the mismatch suite; extracting before hashing turns the first
## mirror's attempt into an extraction refusal; dropping the downgrade makes
## the next crate ask the bad mirror first; not checking the top
## directory's name accepts the renamed archive; refusing GNU long-name
## records fails the first suite's real crate; marking the edge non-cacheable
## makes the second run execute it; putting the state directory into the
## realization hash makes the second project fetch again.
##
## No mock: a real HTTPS server (loopback, a minted certificate), real
## crates from cargo, the production fetch, the real engine and the real
## local store. The only stand-in is the test resolver and dialer described
## in `crate_fixtures`.

import std/[os, sets, strutils, tables, tempfiles, unittest]

import repro_build_engine

import ./crate_fixtures

const
  LongDir = "src/a-directory-name-long-enough/that-the-whole-member-path/" &
    "does-not-fit-a-hundred-bytes"
  LongFile = LongDir & "/data.txt"

proc goodCrate(work: string): tuple[row: CrateRow; bytes: string] =
  let bytes = packCrate(work, "rqefetch", "0.1.0", @[
    ("src/lib.rs", "pub fn answer() -> u32 { 42 }\n"),
    (LongFile, "long path\n")])
  (CrateRow(name: "rqefetch", version: "0.1.0", cksum: sha256Hex(bytes)),
   bytes)

suite "a verified fetch lands in its store prefix, and a second run is a cache hit":
  let cf = newCrateFixture("fetch-checked")
  let work = createTempDir("cg4a-fetch-checked-", "")
  let (row, bytes) = goodCrate(work)
  let store = work / "store"

  test "fetched, verified, published, then a cache hit":
    cf.putOnHttpsMirror(row.cksum, bytes)
    let locked = lockedCratesOf(lockText(@[row]))
    check locked.rows == @[row]
    let cfg = cf.crateConfig(work / "state-a", store, @[cf.httpsMirror()])
    let r = fetchLockedCrates(locked.rows, cfg)
    check r.ok
    require r.crates.len == 1
    let c = r.crates[0]
    check c.state == csFetched
    check c.transport == ctMirror
    check r.executed == @[crateFetchEdgeId(row)]
    check cf.requestsFor(crateObjectPath(row.cksum)) == 1
    # The edge declares the network and names every place it may contact.
    require r.actions.len == 1
    let a = r.actions[0]
    check a.kind == bakSourceFetch
    check a.networkMode == netFetch
    check a.netDestinations == @[cf.httpsMirror().location,
      cf.originBase() & "rqefetch/0.1.0/download"]
    check auditNetworkPolicy(graph(r.actions)).len == 0
    # The prefix: the store's layout, named by the realization hash.
    let expected = store / "prefixes" / "rqefetch" /
      ("0.1.0-" & prefixIdHex(crateRealizationId(row))[0 ..< 40])
    check c.prefix == expected
    check readFile(expected / "src" / "lib.rs") ==
      "pub fn answer() -> u32 { 42 }\n"
    check readFile(expected / LongFile) == "long path\n"
    check fileExists(expected / "Cargo.toml")
    check fileExists(expected / ".repro-receipt")
    let receipt = readReceiptFile(expected / ".repro-receipt")
    check receipt.adapter == CrateAdapter
    check receipt.provenanceChecksum == "sha256:" & row.cksum
    check receipt.provenanceUrl ==
      "cas:blake3:" & prefixIdHex(blake3Digest(bytes))
    check not dirExists(expected / "rqefetch-0.1.0")
    check fpUserWrite notin getFilePermissions(expected / "src" / "lib.rs")
    # The verified archive is kept in the store's cas/.
    let blob = store / casBlobRelative(blake3Digest(bytes))
    check fileExists(blob)
    check readFile(blob) == bytes
    check stagingEntries(store).len == 0

    # The same checkout again: an engine cache hit, nothing contacted.
    let again = fetchLockedCrates(locked.rows, cfg)
    check again.ok
    check again.executed.len == 0
    check again.crates[0].state == csPresent
    check again.crates[0].prefix == expected
    check cf.requestsFor(crateObjectPath(row.cksum)) == 1

    # A second checkout of the same lockfile: its own state directory, the
    # same store. The edge runs, finds the prefix, contacts nothing.
    let other = fetchLockedCrates(locked.rows,
      cf.crateConfig(work / "state-b", store, @[cf.httpsMirror()]))
    check other.ok
    check other.executed == @[crateFetchEdgeId(row)]
    check other.crates[0].state == csPresent
    check other.crates[0].transport == ctStore
    check other.crates[0].attempts.len == 0
    check other.crates[0].prefix == expected
    check cf.requestsFor(crateObjectPath(row.cksum)) == 1
    check cf.requestsFor("/origin/") == 0

  removeTestTree(work)
  cleanup(cf)

suite "a checksum mismatch is refused":
  let cf = newCrateFixture("fetch-mismatch")
  let work = createTempDir("cg4a-fetch-mismatch-", "")
  let (row, bytes) = goodCrate(work)
  let store = work / "store"

  test "wrong bytes from the mirror and from the origin are both refused":
    # The lock pins a checksum the served bytes do not have: the mirror
    # serves the real crate under that checksum, the origin serves it at
    # the crate's URL.
    var tampered = bytes
    tampered[tampered.len div 2] = chr(ord(tampered[tampered.len div 2]) xor 1)
    let pinned = CrateRow(name: row.name, version: row.version,
      cksum: sha256Hex(tampered))
    cf.putOnHttpsMirror(pinned.cksum, bytes)
    cf.putAtOrigin(row.name, row.version, bytes)
    let r = fetchLockedCrates(@[pinned],
      cf.crateConfig(work / "state", store, @[cf.httpsMirror()]))
    check not r.ok
    let c = r.crates[0]
    check c.state == csFailed
    require c.attempts.len == 2
    check c.attempts[0].transport == ctMirror
    check c.attempts[0].outcome == caMismatch
    check c.attempts[0].rule == "cksum"
    check c.attempts[1].transport == ctOrigin
    check c.attempts[1].outcome == caMismatch
    check pinned.cksum in c.failureText()
    check cratePrefixDirs(store, row.name).len == 0
    check stagingEntries(store).len == 0
    check not fileExists(store / casBlobRelative(blake3Digest(bytes)))
    var s = openStore(store)
    check not s.lookupPrefix(crateRealizationId(pinned)).found
    s.close()
    # Positive control: the same bytes under their own checksum are taken.
    let ok = fetchLockedCrates(@[row],
      cf.crateConfig(work / "state-ok", store, @[], withOrigin = true))
    check ok.ok
    check ok.crates[0].transport == ctOrigin

  removeTestTree(work)
  cleanup(cf)

suite "test_cpc_fetch_verified_before_extract":
  let cf = newCrateFixture("verified-before-extract")
  let work = createTempDir("cg4a-before-extract-", "")
  let store = work / "store"

  test "a mirror with wrong bytes is skipped unparsed, downgraded, and the next mirror is used":
    let first = packCrate(work, "firstcrate", "1.0.0",
      @[("src/lib.rs", "pub fn one() {}\n")])
    let second = packCrate(work, "secondcrate", "2.0.0",
      @[("src/lib.rs", "pub fn two() {}\n")])
    let rows = @[
      CrateRow(name: "firstcrate", version: "1.0.0", cksum: sha256Hex(first)),
      CrateRow(name: "secondcrate", version: "2.0.0",
        cksum: sha256Hex(second))]
    # The bad mirror serves, for both crates, an archive that is not the
    # locked one and that would also be refused if anything parsed it.
    let evil = handCrate(work, @[
      dirMember("firstcrate-1.0.0/"),
      regular("firstcrate-1.0.0/../evil-escape.txt", "escaped\n")])
    let bad = parseMirror(work / "bad-mirror")
    for r in rows: bad.putObject(crateObjectPath(r.cksum), evil)
    cf.putOnHttpsMirror(rows[0].cksum, first)
    cf.putOnHttpsMirror(rows[1].cksum, second)
    let r = fetchLockedCrates(rows, cf.crateConfig(work / "state", store,
      @[bad, cf.httpsMirror()], withOrigin = false))
    check r.ok
    let a = r.crates[0]
    check a.state == csFetched
    require a.attempts.len == 2
    check a.attempts[0].location == bad.urlOf(crateObjectPath(rows[0].cksum))
    check a.attempts[0].outcome == caMismatch  # not caRefused: never parsed
    check a.attempts[0].rule == "cksum"
    check a.attempts[1].outcome == caFetched
    # Downgraded for the rest of the wave: the second crate asks the good
    # mirror first.
    let b = r.crates[1]
    check b.state == csFetched
    require b.attempts.len >= 1
    check b.attempts[0].location ==
      cf.httpsMirror().urlOf(crateObjectPath(rows[1].cksum))
    check b.attempts[0].outcome == caFetched
    for rel in filesUnder(store):
      check "evil-escape" notin rel
    check not fileExists(store / "evil-escape.txt")
    check not fileExists(store / "prefixes" / "evil-escape.txt")

  test "a locked archive with an unsafe member is refused, naming it":
    let cases = @[
      ("dotdot", "unsafe-1.0.0/../outside.txt", "name"),
      ("absolute", "/etc/unsafe-absolute.txt", "name"),
      ("other-top", "elsewhere/src/lib.rs", "name")]
    for (label, member, rule) in cases:
      let archive = handCrate(work, @[
        dirMember("unsafe-1.0.0/"),
        regular("unsafe-1.0.0/Cargo.toml", "[package]\n"),
        regular(member, "x\n")])
      let row = CrateRow(name: "unsafe", version: "1.0.0",
        cksum: sha256Hex(archive))
      let m = parseMirror(work / ("mirror-" & label))
      m.putObject(crateObjectPath(row.cksum), archive)
      let r = fetchLockedCrates(@[row], cf.crateConfig(work / ("state-" &
        label), store, @[m], withOrigin = false))
      checkpoint(label & ": " & r.crates[0].failureText())
      check not r.ok
      let c = r.crates[0]
      require c.attempts.len == 1
      check c.attempts[0].outcome == caRefused
      check c.attempts[0].rule == rule
      check member in c.attempts[0].detail
      check cratePrefixDirs(store, "unsafe").len == 0
      check stagingEntries(store).len == 0
      check not fileExists(store / casBlobRelative(blake3Digest(archive)))
    # An archive whose one top directory is not `<name>-<version>`: every
    # member is consistent with the others, and only the name is wrong.
    let renamed = handCrate(work, @[
      dirMember("impostor-1.0.0/"),
      regular("impostor-1.0.0/Cargo.toml", "[package]\n"),
      regular("impostor-1.0.0/src/lib.rs", "\n")])
    let renamedRow = CrateRow(name: "named", version: "1.0.0",
      cksum: sha256Hex(renamed))
    let rm = parseMirror(work / "mirror-renamed")
    rm.putObject(crateObjectPath(renamedRow.cksum), renamed)
    let rr = fetchLockedCrates(@[renamedRow], cf.crateConfig(work /
      "state-renamed", store, @[rm], withOrigin = false))
    check not rr.ok
    check rr.crates[0].attempts[0].rule == "name"
    check "impostor-1.0.0" in rr.crates[0].attempts[0].detail
    check cratePrefixDirs(store, "named").len == 0
    # A link that leaves the tree.
    let linked = handCrate(work, @[
      dirMember("linky-1.0.0/"),
      regular("linky-1.0.0/Cargo.toml", "[package]\n"),
      linkMember("linky-1.0.0/escape", "../../outside")])
    let row = CrateRow(name: "linky", version: "1.0.0",
      cksum: sha256Hex(linked))
    let m = parseMirror(work / "mirror-link")
    m.putObject(crateObjectPath(row.cksum), linked)
    let r = fetchLockedCrates(@[row], cf.crateConfig(work / "state-link",
      store, @[m], withOrigin = false))
    check not r.ok
    check r.crates[0].attempts[0].rule == "link-outside"
    check cratePrefixDirs(store, "linky").len == 0
    check stagingEntries(store).len == 0

  removeTestTree(work)
  cleanup(cf)

suite "test_cpc_store_shared_across_projects":
  let cf = newCrateFixture("shared-projects")
  let work = createTempDir("cg4a-shared-", "")
  let store = work / "store"

  test "a second project locking the same crate fetches nothing for it":
    let shared = packCrate(work, "sharedcrate", "0.3.1",
      @[("src/lib.rs", "pub fn shared() {}\n")])
    let own = packCrate(work, "owncrate", "0.1.0",
      @[("src/lib.rs", "pub fn own() {}\n")])
    let sharedRow = CrateRow(name: "sharedcrate", version: "0.3.1",
      cksum: sha256Hex(shared))
    let ownRow = CrateRow(name: "owncrate", version: "0.1.0",
      cksum: sha256Hex(own))
    cf.putOnHttpsMirror(sharedRow.cksum, shared)
    cf.putOnHttpsMirror(ownRow.cksum, own)
    let projectA = work / "project-a"
    let projectB = work / "project-b"
    createDir(projectA)
    createDir(projectB)
    writeFile(projectA / "Cargo.lock", lockText(@[sharedRow]))
    writeFile(projectB / "Cargo.lock", lockText(@[ownRow, sharedRow]))
    let a = fetchLockedCrates(lockedCratesOf(readFile(projectA /
      "Cargo.lock")).rows, cf.crateConfig(projectA / ".repro" /
      "cargo-fetch", store, @[cf.httpsMirror()]))
    check a.ok
    check cf.requestsFor(crateObjectPath(sharedRow.cksum)) == 1
    let b = fetchLockedCrates(lockedCratesOf(readFile(projectB /
      "Cargo.lock")).rows, cf.crateConfig(projectB / ".repro" /
      "cargo-fetch", store, @[cf.httpsMirror()]))
    check b.ok
    var byName = initTable[string, CrateFetch]()
    for c in b.crates: byName[c.row.name] = c
    check byName["sharedcrate"].state == csPresent
    check byName["sharedcrate"].transport == ctStore
    check byName["sharedcrate"].prefix == a.crates[0].prefix
    check byName["owncrate"].state == csFetched
    check cf.requestsFor(crateObjectPath(sharedRow.cksum)) == 1
    check cf.requestsFor(crateObjectPath(ownRow.cksum)) == 1
    check cratePrefixDirs(store, "sharedcrate").len == 1

  removeTestTree(work)
  cleanup(cf)

suite "only crates.io rows are fetch edges":
  test "git and other-registry packages are reported, not fetched":
    let row = CrateRow(name: "plain", version: "1.2.3", cksum: repeat('a', 64))
    let locked = lockedCratesOf(lockText(@[row], @[
      ("gitdep", "0.1.0", "git+https://example.invalid/x?tag=v1#" &
        repeat('b', 40)),
      ("otherreg", "0.2.0", "registry+https://example.invalid/index")]))
    check locked.rows == @[row]
    check locked.unfetched.len == 2
    var names: HashSet[string]
    for u in locked.unfetched:
      names.incl u.name
      check u.reason.len > 0
    check names == toHashSet(["gitdep", "otherreg"])

  test "a row whose name or version could change a path is refused":
    for bad in [CrateRow(name: "../x", version: "1.0.0", cksum: repeat('a', 64)),
                CrateRow(name: "x", version: "../1", cksum: repeat('a', 64)),
                CrateRow(name: "x", version: "1.0.0", cksum: "ABC")]:
      expect CrateRowError:
        validateRow(bad)
