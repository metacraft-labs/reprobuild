## Threat model G11: a mirror's or a forge's archive cannot write outside the
## staging directory it is extracted into.
##
## Each hostile archive below is served twice, by a mirror (a plain tar
## under the locked digest) and by the forge (a `.tar.gz` under the
## archive's single top directory), and each is refused and captured with
## the rule it broke, nothing is written outside staging, and the staging
## directory is discarded:
##
## * a `..` member;
## * an absolute member name;
## * a symbolic link to a directory outside the tree, then a member written
##   through it (C6's rule, `refuseWriteThroughSymlink`);
## * a hard link;
## * a symbolic link pointing outside the tree, written through by nothing.
##
## `nimble.fetch` extracts in process: a canary `tar` first on `PATH` is
## never run.
##
## The extractor itself (`extractArchive`) also refuses what a forge or a
## mirror could use to make two readers disagree, or to leave something no
## source tree holds: a pax `path` override with `..`, a pax `size` that
## disagrees with the header's, a second member at a path already
## extracted, a FIFO, a device, a GNU long-name record, a header with a
## wrong checksum, and an archive cut short.
##
## No mock: hand-made tar archives (the attacks) served by a real directory
## mirror and the shared HTTPS fixture's forge endpoint; the production
## fetch edges and extractor.

import std/[os, strutils, tempfiles, unittest]

import ./fetch_fixtures

suite "NPC-M5: archive members cannot escape staging":
  test "every hostile member is refused, captured, and lands nowhere":
    let archiveDir = createTempDir("npc-m5-hostile-archives-", "")
    let f = newFixture("escape",
      @[Route(prefix: "/owner/hostile/archive/", serveDir: archiveDir)])
    let work = createTempDir("npc-m5-escape-", "")
    let outside = work / "outside"
    createDir(outside)
    # A canary `tar`: running it would leave a mark.
    let canaryBin = work / "bin"
    createDir(canaryBin)
    writeFile(canaryBin / "tar", "#!/bin/sh\ntouch " & work / "tar-ran" &
      "\nexit 1\n")
    setFilePermissions(canaryBin / "tar", {fpUserRead, fpUserWrite,
      fpUserExec})
    putEnv("PATH", canaryBin & ":" & getEnv("PATH"))
    let benign = regular("pkg.nimble", "version = \"1.0.0\"\n")
    let cases = @[
      ("dotdot", @[benign, regular("../escape.txt", "escaped\n")],
        "name"),
      ("absolute", @[benign, regular(outside / "abs.txt", "escaped\n")],
        "name"),
      ("through-link", @[benign, linkMember("d", outside),
        regular("d/through.txt", "escaped\n")], "through-link"),
      ("hard-link", @[benign, hardLinkMember("h", outside / "target")],
        "kind"),
      ("link-outside", @[benign, linkMember("l", "../../outside/x")],
        "link-outside")]
    let mirror = parseMirror(work / "mirror")
    var i = 0
    for (label, members, rule) in cases:
      inc i
      # A digest of its own for each case, so each is fetched afresh.
      let tree = toHex(i, 64).toLowerAscii()
      let commit = toHex(i, 40).toLowerAscii()
      # The mirror's copy: a plain tar under the digest.
      mirror.putObject(sourceObjectPath(tree), tarOf(members))
      # The forge's copy: the same members under one top directory.
      var forged: seq[TarMember] = @[dirMember("hostile-" & commit & "/")]
      for m in members:
        var x = m
        if not x.name.startsWith("/"):
          x.name = "hostile-" & commit & "/" & x.name
        forged.add x
      writeFile(archiveDir / commit & ".tar.gz", gzipOf(work, tarOf(forged)))
      let row = NimbleLockRow(name: label, origin: f.url("owner/hostile.git"),
        commit: commit, tree: tree, size: -1)
      for viaMirror in [true, false]:
        let w = work / label & (if viaMirror: "-mirror" else: "-forge")
        var cfg = f.fetchConfig(w, (if viaMirror: @[mirror] else: @[]))
        if viaMirror: cfg = cfg.withNoOrigin()
        let r = fetchLocked(@[row], cfg)
        checkpoint label & " via " & (if viaMirror: "mirror" else: "forge")
        check not r.ok
        var seen = false
        for a in r.packages[0].attempts:
          if a.transport == (if viaMirror: tMirror else: tForgeArchive):
            seen = true
            checkpoint a.detail
            # An absolute name inside the forge's top directory is not
            # stripped into the tree: it is outside the top directory.
            check a.outcome == aoRefused
            check a.rule == rule or (not viaMirror and label == "absolute")
        check seen
        check stagingLeft(w / "store").len == 0
        check not dirExists(w / "store" / tree)
        check not fileExists(w / "escape.txt")
        check not fileExists(w / "store" / "escape.txt")
    # Nothing was written outside any staging directory, and tar never ran.
    var outsideEntries: seq[string]
    for p in walkDirRec(outside): outsideEntries.add p
    check outsideEntries.len == 0
    check not fileExists(work / "escape.txt")
    check not fileExists(work / "tar-ran")

  test "pax overrides, duplicates, special members and damage are refused":
    let benign = regular("pkg.nimble", "version = \"1.0.0\"\n")
    let cases = @[
      ("pax-dotdot", tarOf(@[benign, paxMember(@[("path", "../escape.txt")]),
        regular("ok.txt", "escaped\n")]), xrName),
      ("pax-size", tarOf(@[benign, paxMember(@[("size", "1")]),
        regular("ok.txt", "two\n")]), xrMalformed),
      ("duplicate", tarOf(@[benign, regular("a.nim", "1"),
        regular("a.nim", "2")]), xrDuplicate),
      ("fifo", tarOf(@[benign, TarMember(name: "p", typeflag: '6')]),
        xrKind),
      ("chardev", tarOf(@[benign, TarMember(name: "d", typeflag: '3')]),
        xrKind),
      ("gnu-longname", tarOf(@[benign, TarMember(name: "@LongLink",
        typeflag: 'L', content: "../escape.txt\0")]), xrKind)]
    var damaged = tarOf(@[benign, regular("a.nim", "1")])
    damaged[148] = if damaged[148] == '0': '1' else: '0'
    let cut = tarOf(@[benign, regular("a.nim", repeat('x', 2000))])
    let all = cases & @[("checksum", damaged, xrMalformed),
      ("cut-in-data", cut[0 ..< 1024 + 600], xrMalformed),
      ("no-end-blocks", cut[0 ..< cut.len - 1024], xrMalformed)]
    let work = createTempDir("npc-m5-extract-rules-", "")
    for (label, archive, rule) in all:
      let staging = work / label
      createDir(staging)
      var got = "accepted"
      try:
        discard extractArchive(archive, staging,
          ExtractOptions(limits: DefaultExtractLimits))
      except ExtractRefusal as e:
        got = $e.rule
        checkpoint label & ": " & e.msg
      checkpoint label
      check got == $rule
    check not fileExists(work / "escape.txt")
    check not fileExists(parentDir(work) / "escape.txt")
