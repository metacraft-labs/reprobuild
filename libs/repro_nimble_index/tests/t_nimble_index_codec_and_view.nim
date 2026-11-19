## The Nimble index objects: canonical round trips, determinism of the
## writer, the text view, navigator partial access (in memory and over a
## memory-mapped file), aliases, version shapes and the candidate
## exclusions the solver input reports.

import std/[algorithm, json, options, os, random, sequtils, strutils, tables,
            tempfiles, unittest]

import repro_nimble_reader/conditions
import repro_nimble_index

import ./index_fixtures

suite "Nimble index objects":

  test "every object kind round-trips through its canonical bytes":
    var s = NimbleShard(shardBits: 0, bucket: 0,
      packages: @[package("aaa", @[record("aaa", "0.1.0")]), richPackage()],
      aliases: @[PackageAlias(alias: "richer", target: "rich")])
    let bytes = encodeShard(s)
    check decodeShard(bytes) == s
    check encodeShard(decodeShard(bytes)) == bytes
    let built = syntheticIndex(100)
    check encodeRoot(decodeRoot(built.rootBytes)) == built.rootBytes
    let table = objectTable(built)
    let names = decodeNameMap(table[built.root.nameMap.id])
    check names.entries.len == 100
    check encodeNameMap(names) == table[built.root.nameMap.id]
    let events = NimbleEvents(events: @[
      OriginEvent(kind: oeRepointed, package: "aaa",
        before: "https://a.invalid/x", after: "https://b.invalid/x",
        observedAt: 7),
      OriginEvent(kind: oeTagMoved, package: "aaa", version: "v1.0",
        before: commitOf("a"), after: commitOf("b"), observedAt: 7)])
    check decodeEvents(encodeEvents(events)) == events

  test "the writer is deterministic and independent of input order":
    var ps = @[richPackage(),
      package("zeta", @[record("zeta", "2.0.0"), record("zeta", "1.0.0")]),
      package("Alpha_One", @[record("Alpha_One", "0.1.0")])]
    let a = buildIndex(buildInput(ps, shardBits = 2))
    var r = initRand(20261118)
    for round in 0 ..< 5:
      var shuffled = ps
      r.shuffle(shuffled)
      for p in shuffled.mitems: r.shuffle(p.versions)
      let b = buildIndex(buildInput(shuffled, shardBits = 2))
      check b.rootId == a.rootId
      check b.objects == a.objects

  test "two index directories written from differently ordered input are byte-identical":
    let ps = syntheticPackages(200)
    var reversed = ps
    reversed.reverse()
    for p in reversed.mitems: p.versions.reverse()
    let dirA = createTempDir("npc-m3-det-a-", "")
    let dirB = createTempDir("npc-m3-det-b-", "")
    defer:
      removeDir(dirA)
      removeDir(dirB)
    buildIndex(buildInput(ps)).writeIndexDir(dirA)
    buildIndex(buildInput(reversed)).writeIndexDir(dirB)
    proc tree(dir: string): seq[(string, string)] =
      for path in walkDirRec(dir, relative = true):
        result.add (path, readFile(dir / path))
      result.sort()
    let ta = tree(dirA)
    check ta.len > 3
    check ta == tree(dirB)
    check indexDirRootId(dirA) == indexDirRootId(dirB)
    # The root file is the object its own id names.
    check readFile(dirA / IndexRootFile) ==
      readFile(objectPath(dirA, indexDirRootId(dirA)))

  test "two packages one name apart under the style-insensitive comparison are refused":
    let ps = @[package("foo_bar", @[record("foo_bar", "1.0")]),
               package("FooBar", @[record("FooBar", "1.0")])]
    expect NimbleIndexError:
      discard buildIndex(buildInput(ps))

  test "the text view is deterministic and shows every field":
    let s = NimbleShard(shardBits: 0, bucket: 0, packages: @[richPackage()])
    let bytes = encodeShard(s)
    let text = renderIndexObject(bytes)
    check text == renderIndexObject(bytes)
    check text.startsWith("object blake3:" & $indexObjectId(bytes))
    for line in [
        "nimble-index shard schema=1 bits=0 bucket=0 packages=1 aliases=0",
        "package rich registry_origin=1",
        "  origin[1] git https://example.invalid/fork/rich",
        "  version 1.2.3 kind=tag tag=\"v1.2.3\"",
        "    nim package \"nim\" range \">= 1.6.0\" source=\"nim >= 1.6.0\"",
        "    requires package \"bearssl\" any features=[tls] when defined(linux) source=\"bearssl\"",
        "    feature \"dev\" root-only",
        "    layout bin += [\"richw\"] when defined(macosx) and not (hostCPU == \"arm64\")",
        "    foreign \"libssl-dev\" when defined(linux)",
        "  version label:nightly kind=label tag=\"nightly\"",
        "    flags: [unreadable]",
        "  version #head kind=head tag=\"main\"",
        "    requires url \"https://example.invalid/nim/other\" subdir=\"pkg\" commit \"0123abcd\""]:
      check line in text
    let root = renderIndexObject(syntheticIndex(40).rootBytes)
    check "\nnimble-index root schema=1\n" in root
    check "\ncounts: packages=40 versions=" in root

  test "the JSON view is deterministic and carries the decoded fields":
    let s = NimbleShard(shardBits: 0, bucket: 0, packages: @[richPackage()])
    let bytes = encodeShard(s)
    let text = renderIndexObjectJson(bytes)
    check text == renderIndexObjectJson(bytes)
    let doc = parseJson(text)
    check doc["object"]["kind"].getStr == "shard"
    check doc["object"]["blake3"].getStr == $indexObjectId(bytes)
    check doc["object"]["bytes"].getInt == bytes.len
    let pkg = doc["value"]["packages"][0]
    check pkg["name"].getStr == "rich"
    check pkg["versions"].len == s.packages[0].versions.len
    let v = pkg["versions"][0]
    check v["version"]["kind"].getStr == "tag"
    check v["version"]["tag"].getStr == "v1.2.3"
    check v["tree"].getStr == $s.packages[0].versions[0].tree
    check v["requires"][0]["target"].getStr == "chronos"
    check v["requires"][1]["condition"][0]["kind"].getStr == "defined-os"
    let root = parseJson(renderIndexObjectJson(syntheticIndex(40).rootBytes))
    check root["object"]["kind"].getStr == "root"
    check root["value"]["packageCount"].getInt == 40
    # A refused object renders nothing: the view decodes before it prints.
    let damaged = bytes[0 ..< bytes.len - 1]
    expect NimbleIndexError:
      discard renderIndexObjectJson(damaged)

  test "the navigator finds every package and agrees with the whole-shard decode":
    let built = syntheticIndex(300)
    let table = objectTable(built)
    let rootNav = navigateRoot(viewOf(built.rootBytes))
    check rootNav.shardCount == built.root.shards.len
    for i, s in built.root.shards:
      check rootNav.shardRefAt(i) == s
      check rootNav.findShard(s.bucket) == i
      let bytes = table[s.id]
      let shard = decodeShard(bytes)
      let nav = navigateShard(viewOf(bytes))
      check nav.packageCount == shard.packages.len
      for j, p in shard.packages:
        check nav.packageNameAt(j) == p.name
        check nav.findPackage(p.name.toUpperAscii) == j
        check rootNav.shardFor(p.name) == i
        check nav.decodePackageAt(j) == p
      check nav.findPackage("no-such-package") == -1

  test "a memory-mapped shard is navigated without reading it into the heap":
    let built = syntheticIndex(300)
    let dir = createTempDir("npc-m3-map-", "")
    defer: removeDir(dir)
    writeIndexDir(built, dir)
    let s = built.root.shards[0]
    var m = mapIndexObject(dir, s.id, MaxShardBytes)
    defer: m.close()
    let nav = navigateShard(m.view)
    let shard = decodeShard(objectTable(built)[s.id])
    check nav.packageCount == shard.packages.len
    check nav.decodePackageAt(0) == shard.packages[0]
    expect NimbleIndexError:
      discard mapIndexObject(dir, built.root.shards[1].id, 10)

  test "an alias resolves to its canonical package, across shards":
    let ps = @[package("canonical", @[record("canonical", "1.0")])]
    var alias = ""
    # An alias name that lands in another bucket than its target: its
    # shard holds the alias alone.
    for i in 0 ..< 100:
      let a = "old" & $i
      if shardBucket(nameKey(a), 4) != shardBucket(nameKey("canonical"), 4):
        alias = a
        break
    let built = buildIndex(buildInput(ps,
      @[PackageAlias(alias: alias, target: "canonical")], shardBits = 4))
    check built.root.shards.len == 2
    check built.root.shards.mapIt(it.packages).sorted == @[0'u32, 1]
    let log = FetchLog()
    var idx = openIndex(countingSource(memorySource(objectTable(built)), log),
      built.rootId)
    let found = lookupPackage(idx, alias.toUpperAscii)
    check found.found
    check found.alias == alias
    check found.package.name == "canonical"
    check log.kinds("shard").len == 2
    check loadNameMap(idx).entries.mapIt((it.name, it.target)) ==
      @[("canonical", ""), (alias, "canonical")]
    # An alias naming no package of the index is refused by the writer.
    expect NimbleIndexError:
      discard buildIndex(buildInput(ps,
        @[PackageAlias(alias: "x", target: "nothere")]))

  test "tags read as versions the way Nimble reads them; others are labels":
    check recordVersion("v1.2.3").components == @[1'u64, 2, 3]
    check recordVersion("1.2").components == @[1'u64, 2]
    check recordVersion("release-0.7.0.8.0").components ==
      @[0'u64, 7, 0, 8, 0]
    check recordVersion("1.2.3-rc1").kind == rvkLabel
    check recordVersion("latest").kind == rvkLabel
    check recordVersion("v1..2").kind == rvkLabel
    check recordVersion("1.2.3.4.5.6.7.8.9").kind == rvkLabel

  test "candidates the solver cannot take are kept with the reason":
    var five = record("secp", "v0.7.0.8.0")
    var trailing = record("secp", "v0.6.0.0")
    var limited = record("secp", "v0.5.0")
    limited.flags = {flUsesProbe, flPlatformLimited}
    limited.probePlatform = "linux-amd64"
    let pkg = package("secp", @[five, trailing, limited,
      record("secp", "nightly")])
    let built = buildIndex(buildInput(@[pkg]))
    var idx = openIndex(memorySource(objectTable(built)), built.rootId)
    let found = lookupPackage(idx, "secp")
    proc byTag(cs: seq[NimbleCandidate]; tag: string): NimbleCandidate =
      cs.filterIt(it.record.version.tag == tag)[0]
    let linux = candidatesOf(found.package, LinuxAmd64)
    check linux.byTag("v0.7.0.8.0").exclusions.mapIt(it.kind) ==
      @[exVersionShape]
    check linux.byTag("v0.6.0.0").version == "0.6.0"
    check linux.byTag("v0.6.0.0").offered
    check linux.byTag("v0.5.0").offered
    check linux.byTag("nightly").exclusions.mapIt(it.kind) == @[exLabel]
    let windows = candidatesOf(found.package, WindowsAmd64)
    check windows.byTag("v0.5.0").exclusions.mapIt(it.kind) ==
      @[exPlatformLimited]
    check "linux-amd64" in windows.byTag("v0.5.0").exclusions[0].detail
    check "v0.7.0.8.0 has 5 components" in
      linux.byTag("v0.7.0.8.0").exclusions[0].detail

  test "a requirement on a name the index does not hold stays a dependency":
    let pkg = package("needy", @[record("needy", "1.0.0",
      @[req("Absent_Pkg", ">= 1.0.0"), req("present")])])
    let built = buildIndex(buildInput(@[pkg,
      package("present", @[record("present", "0.1.0")])]))
    var idx = openIndex(memorySource(objectTable(built)), built.rootId)
    let input = solverInput(idx, ["needy"], LinuxAmd64)
    check input.missing == @["Absent_Pkg"]
    let deps = perVersionDependencies(input,
      input.packages.filterIt(it.name == "needy")[0])
    check deps.len == 1
    check deps[0][0] == "1.0.0"
    # Dropped, the version would be chosen with a requirement nothing meets.
    check deps[0][1].mapIt(it.name) == @["nimble:Absent_Pkg", "nimble:present"]

  test "conditions survive the record and evaluate as the reader's do":
    let c = Condition(kind: ckAnd, left: definedOs("linux"),
      right: Condition(kind: ckNot, operand: hostCpuIs("arm64")))
    let nodes = conditionNodes(c)
    validateCondition(nodes, "c")
    check conditionNodes(conditionOf(nodes)) == nodes
    check activeOn(nodes, LinuxAmd64)
    check not activeOn(nodes, WindowsAmd64)
    # Nim's `defined(linux)` holds on Android.
    let android = NimblePlatform(id: "android-arm64", targetOs: "android",
      targetCpu: "arm64", hostOs: "linux", hostCpu: "amd64")
    check activeOn(@[ConditionNode(kind: cnDefinedOs, name: "linux")], android)
    expect NimbleIndexError:
      validateCondition(@[ConditionNode(kind: cnAnd)], "c")
