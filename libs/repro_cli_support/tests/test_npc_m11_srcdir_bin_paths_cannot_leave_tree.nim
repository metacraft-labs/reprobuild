## NPC-M11 adversarial audit (threat model G31, T18; NPC-AREQ21, NPC-AREQ23):
## a record's `srcDir`, `bin` and `paths` cannot hand a build anything
## outside the package's verified tree.
##
## A record carries what the generator read from a hostile `.nimble` (or
## what a hostile publisher wrote, A5), and the build turns `srcDir` into a
## `--path:` root and `bin` into a compiled source. Each is checked against
## the verified store tree before anything compiles:
##
## * `srcDir` that is absolute, has a `..` component, or climbs out through
##   one (`src/../..`) refuses the build's preparation, naming each package
##   (`prepareLockedNimbleSources`);
## * a `bin` entry with a `..` component, or an absolute one, refuses the
##   binary plan (`planNimbleBinaries`, `insideTree`);
## * `paths` (Nimble's extra search directories) is not applied at all
##   (plan M7-P6): a record whose `paths` names `/etc` and `../../..` adds no
##   root.
##
## Positive control: the same package with `srcDir = "src"` prepares, and
## its one root is `<store tree>/src`.
##
## No mock: real source repositories served over the shared HTTPS fixture as
## a mirror, a real index repository, the production lock verbs and build
## preparation.

import std/[options, os, strutils, tables, unittest]

import ./nimble_m6_fixtures
import ../../repro_nimble_fetch/tests/fetch_fixtures

proc hexBytes(hex: string): seq[byte] =
  for i in countup(0, hex.len - 2, 2):
    result.add byte(parseHexInt(hex[i .. i + 1]))

proc recordOf(name: string; s: PublishedSource; srcDir: string): VersionRecord =
  result = record(name, "v1.0.0")
  result.commit = s.commit
  let t = hexBytes(s.tree)
  for i in 0 ..< 32: result.tree[i] = t[i]
  let a = hexBytes(s.archiveSha256)
  for i in 0 ..< 32: result.archiveSha256[i] = a[i]
  result.size = uint64(s.archive.len)
  result.layout.srcDir = srcDir

suite "NPC-M11: srcDir, bin and paths cannot leave the package's tree":
  test "escaping srcDir and bin are refused by name; paths adds no root":
    var w = newWorld("m11-srcdir")
    let mirrorDir = w.root / "mirror"
    createDir(mirrorDir)
    let f = newFixture("m11-srcdir",
      @[Route(prefix: "/mirror/", serveDir: mirrorDir)])
    let local = parseMirror(mirrorDir)
    let cases = @[("good", "src"), ("updir", "../outside"), ("absolute", "/etc"),
      ("climbs", "src/../..")]
    var packages: seq[PackageEnvelope]
    for (name, srcDir) in cases:
      let s = f.package("owner/" & name & ".git", @[nimbleFile(name),
        file("src/" & name & ".nim", "proc x*() = discard\n"),
        file("src/tool.nim", "discard\n")])
      local.putSource(s)
      var rec = recordOf(name, s, srcDir)
      if name == "good":
        rec.layout.paths = @["/etc", "../../..", "src/../../.."]
        rec.binaries.bin = @["tool", "../../../etc/evil", "/abs/evil"]
      var p = package(name, @[rec])
      p.origins = @[PackageOrigin(url: f.url(s.path), vcs: ovGit)]
      packages.add p
    discard w.publish(packages, daysAgo(2), "generation 1")
    let store = w.root / "store"
    var cfg = f.fetchConfig(w.root / "fetch", @[f.httpsMirror("/mirror/")],
      store = store)
    cfg.useClosureIndex = false

    # The escaping srcDirs: one project locks all three.
    let bad = w.newProject(@[("updir", ""), ("absolute", ""), ("climbs", "")])
    let r1 = refreshProvisioning(bad)
    checkpoint r1.output
    check r1.rc == 0
    var refusal = ""
    try:
      discard prepareLockedNimbleSources(bad, bad / "repro.lock",
        NimbleSourcesOptions(fetchConfig: some(cfg)))
    except CatchableError as e:
      refusal = e.msg
    checkpoint refusal
    check "nimble:updir 1.0.0: the record's srcDir \"../outside\" leaves the package's tree" in refusal
    check "nimble:absolute 1.0.0: the record's srcDir \"/etc\" leaves the package's tree" in refusal
    check "nimble:climbs 1.0.0: the record's srcDir \"src/../..\" leaves the package's tree" in refusal

    # The control: srcDir `src` prepares, `paths` adds nothing, and the
    # escaping `bin` entries refuse the binary plan.
    let good = w.newProject(@[("good", "")])
    let r2 = refreshProvisioning(good)
    checkpoint r2.output
    check r2.rc == 0
    let report = prepareLockedNimbleSources(good, good / "repro.lock",
      NimbleSourcesOptions(fetchConfig: some(cfg)))
    check report.packages.len == 1
    let tree = report.storePaths["good"]
    check report.nimPathDirs == @[tree / "src"]
    for d in report.nimPathDirs:
      check d.startsWith(tree)
    let plan = planNimbleBinaries(report, report.packages[0])
    checkpoint plan.refusal
    check plan.refusal == "nimble:good: bin \"../../../etc/evil\" leaves the package's tree"
    check plan.binaries.len == 1
    # Positive control for the bin check: the in-tree entry alone plans.
    var onlyTool = report.packages[0]
    onlyTool.record.binaries.bin = @["tool"]
    let ok = planNimbleBinaries(report, onlyTool)
    check ok.refusal == ""
    check ok.binaries.len == 1
    check ok.binaries[0].source == tree / "src" / "tool.nim"
    var onlyAbs = report.packages[0]
    onlyAbs.record.binaries.bin = @["/abs/evil"]
    check planNimbleBinaries(report, onlyAbs).refusal ==
      "nimble:good: bin \"/abs/evil\" leaves the package's tree"
