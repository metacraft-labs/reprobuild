## Threat model G12 (NPC-AREQ13): an index revision is published only when
## every source object it names is on EVERY required mirror.
##
## The source set declares two required mirrors: a directory the publisher
## writes, and an HTTPS mirror the publisher cannot write (its write path is
## its own service). The generation writes every archive to the first, so
## the first is always complete; the second holds all objects but one. The
## generation is refused, names the missing object and the mirror, and
## writes no index directory. With the object copied to the second mirror
## the same generation is published. An optional mirror that lacks objects
## never holds a publish back.
##
## No mock: a real generation over the shared HTTPS fixture, a real
## directory mirror and a real directory served as an HTTPS mirror.

import std/[options, os, strutils, tempfiles, unittest]

import ./fetch_fixtures

proc objectsUnder(dir: string): seq[string] =
  if not dirExists(dir): return
  for p in walkDirRec(dir):
    if p.endsWith(".tar"): result.add relativePath(p, dir)

suite "NPC-M5: an incomplete revision is not published":
  test "one object missing from the second required mirror is refused":
    let httpsDir = createTempDir("npc-m5-https-mirror-", "")
    let optionalDir = createTempDir("npc-m5-optional-mirror-", "")
    let f = newFixture("publish-incomplete", @[
      Route(prefix: "/second/", serveDir: httpsDir),
      Route(prefix: "/optional/", serveDir: optionalDir)])
    let work = createTempDir("npc-m5-publish-", "")
    var entries: seq[(string, string)]
    for name in ["alpha", "beta", "gamma"]:
      discard f.package("owner/" & name & ".git", @[nimbleFile(name),
        file("src/" & name & ".nim", "# " & name & "\n")])
      entries.add (name, f.url("owner/" & name & ".git"))
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = commit(reg, @[packagesJson(entries)])
    publish(reg)
    let firstDir = work / "first"
    let text = sourceSetText(f.url("nim-lang/packages.git"), regCommit,
      mirror = firstDir, extra = "\n[[mirror]]\nurl = \"" &
        "https://" & MirrorHost & ":" & $f.port & "/second/\"\n" &
        "\n[[mirror]]\nurl = \"https://" & MirrorHost & ":" & $f.port &
        "/optional/\"\nrole = \"optional\"\n")
    let ss = parseSourceSet(text, "s.toml")
    check ss.mirrors.len == 3
    proc attempt(outDir: string): string =
      var cfg = f.genConfig(ss, 1_790_000_000, work / "state",
        outputDir = outDir)
      cfg.mirrorAccess = some(f.mirrorPolicy())
      try:
        discard generate(cfg)
        ""
      except GeneratorError as e:
        e.msg

    # Nothing on the second mirror: refused, every object named.
    let msg0 = attempt(work / "out0")
    checkpoint msg0
    check "not published" in msg0
    check "3 source object(s)" in msg0
    check "/second/" in msg0
    check not dirExists(work / "out0")
    let published = objectsUnder(firstDir)
    check published.len == 3 # the first mirror got every archive

    # All but one on the second mirror: refused, naming the one.
    for rel in published[0 .. 1]:
      createDir(parentDir(httpsDir / rel))
      copyFile(firstDir / rel, httpsDir / rel)
    let missing = published[2]
    let msg1 = attempt(work / "out1")
    checkpoint msg1
    check "1 source object(s)" in msg1
    check missing.extractFilename.changeFileExt("") in msg1
    check "/second/" in msg1
    check not dirExists(work / "out1")

    # The last one too: published, although the optional mirror is empty.
    createDir(parentDir(httpsDir / missing))
    copyFile(firstDir / missing, httpsDir / missing)
    check attempt(work / "out2") == ""
    check fileExists(work / "out2" / "root")
    check objectsUnder(optionalDir).len == 0

  test "an index with no required mirror is not published":
    let f = newFixture("publish-no-mirror")
    let work = createTempDir("npc-m5-publish-none-", "")
    discard f.package("owner/solo.git", @[nimbleFile("solo"),
      file("src/solo.nim", "\n")])
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = commit(reg, @[packagesJson(@[("solo",
      f.url("owner/solo.git"))])])
    publish(reg)
    let text = "schema = \"reprobuild.nimble-source-set.v1\"\n\n" &
      "[[registry]]\nremote = \"" & f.url("nim-lang/packages.git") &
      "\"\ncommit = \"" & regCommit & "\"\n"
    var refused = ""
    try:
      discard generate(f.genConfig(parseSourceSet(text, "s.toml"),
        1_790_000_000, work / "state", outputDir = work / "out"))
    except GeneratorError as e:
      refused = e.msg
    check "no required mirror" in refused
    check not dirExists(work / "out")
    # Without an output directory nothing is published, so none is needed.
    discard generate(f.genConfig(parseSourceSet(text, "s.toml"),
      1_790_000_000, work / "state"))
