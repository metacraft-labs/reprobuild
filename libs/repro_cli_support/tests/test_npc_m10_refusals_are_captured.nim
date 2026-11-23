## NPC-M10 verification `test_npc_m10_refusals_are_captured` (threat model
## § 9, G28's capture half; NPC-M10 "Detection and capture").
##
## Each refusal class reaches the capture log with the package, the digest
## (or commit, or revision) expected and observed, and where the bytes came
## from:
##
## * the generator, over two generations of a fixture registry: an egress
##   refusal (an origin on a private address), a worker output the
##   publisher refuses (an unknown record type), a link out of its tree, an
##   origin event (a moved tag) and a repoint candidate (the registry
##   repoints a name);
## * a client fetch: a mirror serving one changed byte, refused by
##   `archive_sha256` before extraction and by the tree digest after it;
## * a refresh refused as a rewind (`repro lock refresh --provisioning`, in
##   process): written by the verb itself to the project's capture log.
##
## Every record is read back from the append-only log file, and each also
## converts to an evidence-sink record carrying the same fields. A URL's
## credentials are never recorded, and records appended by concurrent
## writers stay whole lines.
##
## Falsifying mutation (recorded in the plan): removing the capture call
## from one refusal class (the rewound refresh) leaves that class absent
## from the log and fails the test.

import std/[os, strutils, tempfiles, typedthreads, unittest]

import repro_peer_cache/evidence_record

import ./nimble_m6_fixtures
import ../../repro_nimble_fetch/tests/fetch_fixtures

const Now = 1_790_000_000'u64

proc flipByteIn(data, needle: string): string =
  let at = data.find(needle)
  doAssert at >= 0, "needle not found"
  result = data
  result[at] = chr(ord(result[at]) xor 0x01)

proc only(log: seq[CaptureRecord]; class: CaptureClass;
          package: string): seq[CaptureRecord] =
  for r in log:
    if r.class == class and r.package == package: result.add r

proc isHex64(s: string): bool =
  s.len == 64 and s.allCharsInSet({'0'..'9', 'a'..'f'})

suite "NPC-M10: every refusal class is captured":

  test "the generator's classes: egress, worker output, symlink, origin event, repoint":
    let f = newFixture("m10-capture-gen")
    let moved = f.newRepo("nim/moved.git")
    let movedV1 = moved.commit(@[nimbleFile("moved"),
      file("src/moved.nim", "discard\n")])
    moved.tag("v1.0.0")
    moved.publish()
    let linky = f.newRepo("nim/linky.git")
    discard linky.commit(@[nimbleFile("linky"),
      file("src/linky.nim", "discard\n"),
      symlink("src/secret", "/etc/passwd")])
    linky.tag("v1.0.0")
    linky.publish()
    for name in ["repointed", "hostile"]:
      let r = f.newRepo("nim/" & name & ".git")
      discard r.commit(@[nimbleFile(name), file("src/" & name & ".nim",
        "discard\n")])
      r.tag("v1.0.0")
      r.publish()
    let fork = f.newRepo("fork/repointed.git")
    discard fork.commit(@[nimbleFile("repointed"),
      file("src/repointed.nim", "echo 1\n")])
    fork.tag("v2.0.0")
    fork.publish()
    let privateUrl = f.url("nim/private.git", host = "private.test")
    let credsUrl = f.url("nim/creds.git").replace("https://",
      "https://reader:hunter2@")
    let base = @[("moved", f.url("nim/moved.git")),
      ("linky", f.url("nim/linky.git")),
      ("hostile", f.url("nim/hostile.git")),
      ("private", privateUrl), ("creds", credsUrl)]
    let reg = f.newRepo("nim-lang/packages.git")
    let reg1 = reg.commit(@[packagesJson(base &
      @[("repointed", f.url("nim/repointed.git"))])])
    let reg2 = reg.commit(@[packagesJson(base &
      @[("repointed", f.url("fork/repointed.git"))])])
    reg.publish()
    let regUrl = f.url("nim-lang/packages.git")
    let work = createTempDir("npc-m10-capture-gen-", "")
    let log = work / "captures.log"

    var cfg = f.genConfig(parseSourceSet(sourceSetText(regUrl, reg1),
      "s.toml"), Now, work / "state", outputDir = work / "gen1")
    cfg.workerOutputTap = proc(family: EdgeFamily; subject, outPath: string)
        {.gcsafe.} =
      if family == efRefs and subject == "hostile":
        writeFile(outPath, readFile(outPath) & "exec x\n")
    let first = generate(cfg)
    appendCaptures(log, capturesOfGeneration(first, Now))

    let movedV2 = moved.commit(@[nimbleFile("moved"),
      file("src/moved.nim", "echo 2\n")], date = 1_700_500_000)
    moved.tag("v1.0.0")
    moved.publish()
    var cfg2 = f.genConfig(parseSourceSet(sourceSetText(regUrl, reg2),
      "s.toml"), Now + 86400, work / "state", previous = work / "gen1",
      outputDir = work / "gen2")
    cfg2.workerOutputTap = cfg.workerOutputTap
    let second = generate(cfg2)
    appendCaptures(log, capturesOfGeneration(second, Now + 86400))

    let got = readCaptures(log)
    for r in got: checkpoint captureLine(r)

    let egress = got.only(ccEgressRefusal, "private")
    check egress.len >= 1
    if egress.len > 0:
      check egress[0].source == privateUrl
      check egress[0].observed.len > 0
      check egress[0].at == Now

    # An origin refused for its credentials is captured; they are not.
    let creds = got.only(ccEgressRefusal, "creds")
    check creds.len >= 1
    if creds.len > 0:
      check creds[0].observed == "credentials"
      check creds[0].source == credsUrl.replace("reader:hunter2@", "***@")
    check "hunter2" notin readFile(log)

    let worker = got.only(ccWorkerOutputRefused, "hostile")
    check worker.len >= 1
    if worker.len > 0:
      check isHex64(worker[0].observed)
      check "refs" in worker[0].source
      check "unknown refs record" in worker[0].detail

    let link = got.only(ccUnreadableSymlink, "linky")
    check link.len >= 1
    if link.len > 0:
      check link[0].expected == "/etc/passwd"
      check isHex64(link[0].observed)
      check link[0].source.startsWith(f.url("nim/linky.git") & "@")

    let event = got.only(ccOriginEvent, "moved")
    check event.len == 1
    if event.len == 1:
      check event[0].expected == movedV1
      check event[0].observed == movedV2
      check event[0].source == f.url("nim/moved.git")
      check "tag-moved" in event[0].detail

    let repoint = got.only(ccRepointCandidate, "repointed")
    check repoint.len == 1
    if repoint.len == 1:
      check repoint[0].expected == f.url("nim/repointed.git")
      check repoint[0].observed == f.url("fork/repointed.git")
      check repoint[0].source == f.url("fork/repointed.git")

    # The same records, as the evidence sink receives them.
    for r in got:
      let e = redact(evidenceRecordOf(r))
      check e.trigger == $r.class
      check e.field("package") == r.package
      check e.field("bytesFrom").len > 0
      check r.source.startsWith(e.field("bytesFrom"))

  test "a client fetch's digest mismatch, by archive_sha256 and by tree":
    let f = newFixture("m10-capture-fetch")
    let s = f.package("owner/forged.git", @[nimbleFile("forged"),
      file("src/forged.nim", "proc answer*(): int = 42\n")])
    let work = createTempDir("npc-m10-capture-fetch-", "")
    let m = parseMirror(work / "mirror")
    m.putObject(sourceObjectPath(s.tree), flipByteIn(s.archive, "answer"))
    let log = work / "captures.log"
    for withArchive in [true, false]:
      var cfg = f.fetchConfig(work / $withArchive, @[m]).withNoOrigin()
      cfg.captureLog = log
      let r = fetchLocked(@[f.rowOf("forged", s, withArchive)], cfg)
      check not r.ok
    let got = readCaptures(log)
    for r in got: checkpoint captureLine(r)
    let mism = got.only(ccDigestMismatch, "forged")
    check mism.len == 2
    if mism.len == 2:
      check mism[0].expected == s.archiveSha256
      check isHex64(mism[0].observed)
      check mism[0].observed != s.archiveSha256
      check mism[1].expected == s.tree
      check isHex64(mism[1].observed)
      check mism[1].observed != s.tree
      for x in mism:
        check x.source.startsWith("mirror ")
        check (work / "mirror") in x.source

  test "a refresh refused as a rewind is captured by the verb":
    var w = newWorld("m10-capture-rewind")
    let pkg = @[nimble_m6_fixtures.package("alpha",
      @[record("alpha", "1.0.0")])]
    let gen1 = w.publish(pkg, daysAgo(10), "generation 1")
    let gen2 = w.publish(pkg, daysAgo(5), "generation 2")
    let dir = w.newProject(@[("alpha", "")])
    check refreshProvisioning(dir).rc == 0
    w.resetMain(gen1.commit)
    let refused = refreshProvisioning(dir)
    check refused.rc != 0
    let got = readCaptures(projectCaptureLog(dir))
    for r in got: checkpoint captureLine(r)
    var rewinds: seq[CaptureRecord]
    for r in got:
      if r.class == ccRewoundRefresh: rewinds.add r
    check rewinds.len == 1
    if rewinds.len == 1:
      check IndexRepo in rewinds[0].package
      check rewinds[0].expected == gen2.commit
      check rewinds[0].observed == gen1.commit
      check rewinds[0].source == IndexRemote
      check "does not descend" in rewinds[0].detail

  test "concurrent writers append whole records":
    let work = createTempDir("npc-m10-capture-concurrent-", "")
    let log = work / "captures.log"
    var threads: array[4, Thread[(string, int)]]
    proc writer(arg: (string, int)) {.thread.} =
      let (log, id) = arg
      {.cast(gcsafe).}:
        for i in 0 ..< 100:
          # Batches of records each larger than a stdio buffer, so a record
          # written in pieces would show as a torn or mixed line.
          var batch: seq[CaptureRecord]
          for j in 0 ..< 3:
            batch.add CaptureRecord(class: ccDigestMismatch,
              package: "w" & $id, expected: repeat(char(ord('a') + id), 4000),
              observed: repeat(char(ord('e') + id), 4000),
              source: "mirror " & $i & " " & repeat(char(ord('i') + id), 3900),
              detail: repeat(char(ord('m') + id), 4000), at: Now)
          appendCaptures(log, batch)
    for i in 0 ..< threads.len: createThread(threads[i], writer, (log, i))
    joinThreads(threads)
    let got = readCaptures(log)
    check got.len == 1200
    var whole = 0
    for r in got:
      let id = parseInt(r.package[1 .. ^1])
      if r.expected == repeat(char(ord('a') + id), 4000) and
          r.observed == repeat(char(ord('e') + id), 4000) and
          r.source.endsWith(repeat(char(ord('i') + id), 3900)) and
          r.detail == repeat(char(ord('m') + id), 4000):
        inc whole
    check whole == 1200
