## NPC-M3 verification ``test_npc_every_tag_has_its_own_requires``
## (NPC-AREQ31): a fixture package whose tags 1.0, 1.1 and 2.0 have
## different `requires` yields three records, each with its own ranges, and
## the solver reads those from shards without fetching any source.
##
## The records are made from what the static `.nimble` reader reads at each
## tag (``repro_nimble_reader.readNimbleSource``), through the production
## writer, and read back through the production reader and solver input.
## The object source holds the index objects and nothing else, and records
## every fetch: no source object exists to be fetched, and none is asked for.

import std/[options, sequtils, tables, unittest]

import repro_nimble_reader
import repro_nimble_index
import repro_solver/version_constraints

import ./index_fixtures

const tags = [
  ("v1.0", """
version = "1.0"
requires "nim >= 1.6.0"
requires "dep >= 0.1.0"
"""),
  ("v1.1", """
version = "1.1"
requires "nim >= 1.6.0", "dep >= 0.2.0", "other"
when defined(windows):
  requires "winlib"
"""),
  ("v2.0", """
version = "2.0"
requires "nim >= 2.0.0"
requires "dep ^= 1.0"
feature "async":
  requires "chronos >= 4.0"
""")]

proc fixtureIndex(): BuiltIndex =
  var versions: seq[VersionRecord]
  for (tag, nimble) in tags:
    let f = readNimbleSource(nimble, "fixturepkg.nimble")
    doAssert f.isStaticallyReadable
    versions.add recordFromNimbleFile(f, VersionFacts(tag: tag,
      commit: commitOf("fixturepkg@" & tag),
      tree: digestOf("tree:" & tag), archiveSha256: digestOf("archive:" & tag),
      size: 2048, firstSeen: 1_790_000_000,
      nimbleFile: some(digestOf(nimble)), modules: @["fixturepkg"]))
  var packages = @[package("fixturepkg", versions)]
  for (name, vs) in [("dep", @["0.1.0", "0.2.0", "1.0.0", "1.5.0"]),
                     ("other", @["3.0.0"]), ("winlib", @["0.1.0"]),
                     ("chronos", @["4.0.1"])]:
    packages.add package(name, vs.mapIt(record(name, it)))
  buildIndex(buildInput(packages))

proc ranges(reqs: seq[SolverRequirement]): seq[(string, string)] =
  reqs.mapIt((it.package, it.range))

suite "NPC-AREQ31: every tag has its own requires":
  let built = fixtureIndex()

  test "three tags with different requires yield three records, each with its own ranges":
    var idx = openIndex(memorySource(objectTable(built)), built.rootId)
    let found = lookupPackage(idx, "fixturepkg")
    check found.found
    let records = found.package.versions
    check records.len == 3
    check records.mapIt(it.version.tag) == @["v1.0", "v1.1", "v2.0"]
    # Each record holds what the reader read at ITS tag, not another's.
    for i, (tag, nimble) in tags:
      let f = readNimbleSource(nimble, "fixturepkg.nimble")
      check records[i].requires == f.requires.mapIt(requirementEntry(it))
      check records[i].nim == f.nim.mapIt(requirementEntry(it))
    check records[0].requires.mapIt(it.constraint) == @[">= 0.1.0"]
    check records[1].requires.mapIt(it.constraint) == @[">= 0.2.0", "", ""]
    check records[1].requires[2].condition ==
      @[ConditionNode(kind: cnDefinedOs, name: "windows")]
    check records[2].requires.mapIt(it.constraint) == @[">= 1.0.0, < 2.0.0"]
    check records[2].features.mapIt(it.name) == @["async"]
    check records.mapIt(it.nim.mapIt(it.constraint)) ==
      @[@[">= 1.6.0"], @[">= 1.6.0"], @[">= 2.0.0"]]

  test "the solver reads each version's ranges from the shards without fetching any source":
    let log = FetchLog()
    var idx = openIndex(countingSource(memorySource(objectTable(built)), log),
      built.rootId)
    let input = solverInput(idx, ["fixturepkg"], LinuxAmd64)
    let pkg = input.packages.filterIt(it.name == "fixturepkg")[0]
    check pkg.candidates.mapIt(it.version) == @["1.0.0", "1.1.0", "2.0.0"]
    check pkg.candidates.allIt(it.offered)
    check pkg.candidates.mapIt(ranges(it.requires)) == @[
      @[("dep", ">= 0.1.0")],
      @[("dep", ">= 0.2.0"), ("other", "")],    # winlib: windows only
      @[("dep", ">= 1.0.0, < 2.0.0")]]
    check pkg.candidates.mapIt(it.nim) ==
      @[@[">= 1.6.0"], @[">= 1.6.0"], @[">= 2.0.0"]]
    # The ranges are the solver's own language: which `dep` each version
    # admits differs by version.
    let depVersions = ["0.1.0", "0.2.0", "1.0.0", "1.5.0"]
    var admitted: seq[seq[string]]
    for c in pkg.candidates:
      let r = parseSemverRange(c.requires[0].range)
      admitted.add depVersions.filterIt(satisfies(parseSemver(it), r))
    check admitted == @[@["0.1.0", "0.2.0", "1.0.0", "1.5.0"],
      @["0.2.0", "1.0.0", "1.5.0"], @["1.0.0", "1.5.0"]]
    # Only index objects were read: the root, then shards.
    check log.fetches.allIt(it[1] in ["root", "shard"])
    check log.kinds("root").len == 1
    let held = objectTable(built)
    check log.fetches.allIt(it[0] in held)
    # And the per-version dependency lists the solver's encoder takes.
    let deps = perVersionDependencies(input, pkg)
    check deps.mapIt(it[0]) == @["1.0.0", "1.1.0", "2.0.0"]
    check deps.mapIt(it[1].mapIt((it.name, it.range))) == @[
      @[("nimble:dep", ">= 0.1.0")],
      @[("nimble:dep", ">= 0.2.0"), ("nimble:other", "")],
      @[("nimble:dep", ">= 1.0.0, < 2.0.0")]]

  test "a platform condition is evaluated per version for the platform solved for":
    var idx = openIndex(memorySource(objectTable(built)), built.rootId)
    let input = solverInput(idx, ["fixturepkg"], WindowsAmd64)
    let pkg = input.packages.filterIt(it.name == "fixturepkg")[0]
    check pkg.candidates.mapIt(ranges(it.requires)) == @[
      @[("dep", ">= 0.1.0")],
      @[("dep", ">= 0.2.0"), ("other", ""), ("winlib", "")],
      @[("dep", ">= 1.0.0, < 2.0.0")]]
    check input.packages.mapIt(it.name) ==
      @["dep", "fixturepkg", "other", "winlib"]

  test "a feature's requirements are its version's own and join the closure only when named":
    var idx = openIndex(memorySource(objectTable(built)), built.rootId)
    let input = solverInput(idx, ["fixturepkg"], LinuxAmd64)
    let pkg = input.packages.filterIt(it.name == "fixturepkg")[0]
    check pkg.candidates.mapIt(it.features.mapIt(it[0])) ==
      @[newSeq[string](), newSeq[string](), @["async"]]
    check pkg.candidates[2].features[0][1].mapIt((it.package, it.range)) ==
      @[("chronos", ">= 4.0.0")]
    check "chronos" notin input.packages.mapIt(it.name)
