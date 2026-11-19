## NPC-M4 verification `test_npc_m4_symlink_out_of_tree_never_followed`
## (threat model G4, spec § 6.1).
##
## A fixture tag whose tree holds symbolic links out of the tree -- an
## absolute one to a canary on this host, and a relative one that climbs
## out -- the shape NPC-M0 found at 22 registry tags. The version is
## recorded `unreadable`; the canonical archive holds the links as links,
## with their target text, and not the canary's bytes; and nothing outside
## the tree is opened.
##
## The canary is a named pipe whose only writer is this test: a reader that
## opens it (anything that followed the link) makes the writer's
## non-blocking open succeed, which the test records, and then receives the
## canary bytes, which would reach the archive.

import std/[os, posix, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures

const CanaryBytes = "CANARY-host-secret-0123456789"

var watching: bool
var opened: bool
var watcher: Thread[string]

proc watch(path: string) {.thread.} =
  {.cast(gcsafe).}:
    while watching:
      let fd = posix.open(path.cstring, O_WRONLY or O_NONBLOCK)
      if fd >= 0:
        opened = true
        discard posix.write(fd, CanaryBytes.cstring, CanaryBytes.len)
        discard posix.close(fd)
      sleep(5)

proc tarEntries(tar: string): seq[tuple[name, link: string; typeflag: char;
                                        body: string]] =
  var pos = 0
  var paxPath = ""
  while pos + 512 <= tar.len:
    let h = tar[pos ..< pos + 512]
    if h == repeat('\0', 512): break
    proc cstr(field: string): string =
      let z = field.find('\0')
      if z < 0: field else: field[0 ..< z]
    var name = cstr(h[0 ..< 100])
    let link = cstr(h[157 ..< 257])
    let size = parseOctInt(h[124 ..< 135].strip(chars = {'\0', ' '}))
    let body = tar[pos + 512 ..< pos + 512 + size]
    pos += 512 + ((size + 511) div 512) * 512
    if h[156] == 'x':
      for rec in body.splitLines():
        let eq = rec.find("path=")
        if eq >= 0: paxPath = rec[eq + 5 .. ^1]
      continue
    if paxPath.len > 0:
      name = paxPath
      paxPath = ""
    result.add (name, link, h[156], body)

suite "NPC-M4: a link out of the tree is never followed":

  test "the version is unreadable, the archive holds the links, the canary is never opened":
    let f = newFixture("symlink")
    let canaryDir = f.dir / "host"
    createDir(canaryDir)
    let canary = canaryDir / "id_ed25519"
    check mkfifo(canary.cstring, 0o600) == 0
    watching = true
    createThread(watcher, watch, canary)

    let w = f.newRepo("nim/leaky.git")
    let readable = w.commit(@[nimbleFile("leaky"),
      file("src/leaky.nim", "discard\n"),
      symlink("docs", "src")])                 # a link inside the tree
    w.tag("v1.0.0")
    let leaking = w.commit(@[nimbleFile("leaky"),
      file("src/leaky.nim", "discard\n"),
      symlink("src/key", canary),              # absolute, to the canary
      symlink("climb", "../../../../../../../../.." & canary), # relative, out
      symlink("docs", "src")])
    w.tag("v1.1.0")
    w.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(@[("leaky",
      f.url("nim/leaky.git"))])])
    reg.publish()
    let work = createTempDir("npc-m4-symlink-run-", "")
    let g = generate(f.genConfig(parseSourceSet(sourceSetText(
      f.url("nim-lang/packages.git"), regCommit), "s.toml"), 1_790_000_000,
      work / "state"))
    watching = false
    joinThread(watcher)

    check not opened
    let e = g.built.envelopeOf("leaky")
    var byTag: seq[VersionRecord]
    for v in e.versions: byTag.add v
    check byTag.len == 2
    for v in byTag:
      if v.commit == leaking:
        check flUnreadable in v.flags
      else:
        check v.commit == readable
        check flUnreadable notin v.flags  # a link inside the tree is fine
    var sawDiagnostic = false
    for d in g.diagnostics:
      if "points outside the tree" in d and "src/key" in d: sawDiagnostic = true
    check sawDiagnostic

    # The archives the source edge wrote hold the links as links.
    var archives = 0
    for path in walkDirRec(work / "state" / "edges" / "source"):
      if not path.endsWith(".tar"): continue
      let tar = readFile(path)
      check CanaryBytes notin tar
      let entries = tarEntries(tar)
      var names: seq[string]
      for en in entries: names.add en.name
      if "src/key" in names:
        inc archives
        for en in entries:
          case en.name
          of "src/key":
            check en.typeflag == '2'
            check en.link == canary
            check en.body.len == 0
          of "climb":
            check en.typeflag == '2'
            check en.link.endsWith(canary)
          of "docs":
            check en.typeflag == '2'
            check en.link == "src"
          else:
            check en.typeflag == '0'
    check archives == 1
    # Nothing the generator wrote anywhere holds the canary's bytes.
    for path in walkDirRec(work):
      if getFileInfo(path, followSymlink = false).kind == pcFile:
        check CanaryBytes notin readFile(path)
