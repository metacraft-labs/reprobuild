## NPC-M9 verification `test_npc_m9_audit_classifies_gitlinks`
## (Nimble-Package-Catalog NPC-AREQ28), the classifier half: on hermetic
## fixtures, not on codetracer. The run over codetracer's own gitlinks and
## its registry URL matches belongs to the re-measurement of spec § 13
## (NPC-M9 part B).
##
## A project repository records six gitlinks, each under a directory name
## that is not its package's name, with a `.gitmodules` naming each URL
## (one of them relative to the project's own remote) and two declared
## branches. The Nimble index the project imports holds `alpha` (tag
## v1.0.0), `snap` (no tag: one snapshot) and `beta` (tag v1.0.0). The
## origins are local bare repositories:
##
## | gitlink | commit | expected |
## |---|---|---|
## | `libs/nim-alpha` | alpha's v1.0.0 commit | catalog, `nimble:alpha == 1.0.0` |
## | `libs/alpha-head` | a later commit on alpha's `main`, no tag | catalog, untagged, `nimble:alpha#<commit>` |
## | `libs/snapshot` | snap's snapshot commit | catalog, snapshot, bare `nimble:snap` |
## | `libs/fork` | a commit of a fork of beta (another origin) | overlay: no package has that origin |
## | `libs/beta-local` | a commit beta's origin does not hold | overlay: on no branch or tag of the origin |
## | `libs/rel` | beta's v1.0.0, URL `../beta.git` | catalog (the relative URL resolved against the project's remote) |
##
## Every verdict carries a reason, and the JSON output is what `repro nimble
## gitlink-audit --json` prints. Positive control: the untagged commit is
## classified untagged only because the origin was asked; with the origin
## gone the same gitlink is `undecided`, never an overlay.
##
## Then, on the classifier directly: the origin is asked at the URL the
## index records for it, not at the `.gitmodules` spelling (`<alpha>/`,
## which has the same identity); and a gitlink with no `.gitmodules` URL is
## `undecided`. Falsifying mutation: asking the `.gitmodules` URL records
## `<alpha>/` as the URL asked.

import std/[json, os, osproc, sequtils, strutils, tables, unittest]

from repro_core/process_streams import drainStream

import ./nimble_m6_fixtures
from ../../repro_nimble_generator/tests/generator_fixtures import gitEnv
import repro_cli_support/nimble_gitlink_audit

proc sh(args: openArray[string]; cwd = ""): string =
  let argv = @args
  let p = startProcess(argv[0], workingDir = cwd, args = argv[1 .. ^1],
    options = {poUsePath, poStdErrToStdOut}, env = gitEnv())
  result = drainStream(p.outputStream).strip()
  let rc = p.waitForExit()
  p.close()
  doAssert rc == 0, args.join(" ") & ": " & result

proc bareWith(root, name: string; commits: int; tagFirst = ""):
    tuple[bare: string; commits: seq[string]] =
  ## A bare origin at ``root/<name>.git`` with ``commits`` commits on `main`.
  result.bare = root / (name & ".git")
  let work = root / ("work-" & name)
  discard sh(["git", "init", "-q", "--bare", "-b", "main", result.bare])
  discard sh(["git", "init", "-q", "-b", "main", work])
  for i in 1 .. commits:
    writeFile(work / (name & ".nimble"), "version = \"0." & $i & ".0\"\n")
    discard sh(["git", "-C", work, "add", "-A"])
    discard sh(["git", "-C", work, "commit", "-q", "-m", name & " " & $i])
    result.commits.add sh(["git", "-C", work, "rev-parse", "HEAD"])
    if i == 1 and tagFirst.len > 0:
      discard sh(["git", "-C", work, "tag", tagFirst])
  discard sh(["git", "-C", work, "push", "-q", result.bare,
    "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"])

proc atCommit(rec: VersionRecord; commit: string): VersionRecord =
  result = rec
  result.commit = commit

suite "NPC-M9: repro nimble gitlink-audit":
  test "each gitlink gets a class and a reason":
    var w = newWorld("m9-audit")
    let origins = w.root / "origins"
    createDir(origins)
    let alpha = bareWith(origins, "alpha", 2, tagFirst = "v1.0.0")
    let snap = bareWith(origins, "snap", 1)
    let beta = bareWith(origins, "beta", 1, tagFirst = "v1.0.0")
    let fork = bareWith(origins, "beta-fork", 1)
    # A commit that exists nowhere beta's origin can be asked about.
    let stranger = bareWith(w.root / "elsewhere", "stray", 1)

    var snapRec = record("snap", "v0.0.0")
    # A snapshot is dated by its first sighting: the fixture record's
    # `first_seen` 1_790_000_000 is 2026-09-21 (UTC).
    snapRec.version = RecordVersion(kind: rvkSnapshot,
      components: @[20260921'u64])
    snapRec.commit = snap.commits[0]
    proc envelopeAt(name: string; recs: seq[VersionRecord];
                    bare: string): PackageEnvelope =
      result = package(name, recs)
      result.origins = @[PackageOrigin(url: bare, vcs: ovGit)]
    discard w.publish(@[
      envelopeAt("alpha", @[record("alpha", "v1.0.0").atCommit(
        alpha.commits[0])], alpha.bare),
      envelopeAt("snap", @[snapRec], snap.bare),
      envelopeAt("beta", @[record("beta", "v1.0.0").atCommit(
        beta.commits[0])], beta.bare)], daysAgo(1), "generation 1")

    # The project: gitlinks and their .gitmodules, and the index import.
    let dir = w.newProject(@[])
    discard sh(["git", "init", "-q", "-b", "main", dir])
    discard sh(["git", "-C", dir, "remote", "add", "origin",
      origins / "project.git"])
    writeFile(dir / ".gitmodules", """
[submodule "nim-alpha"]
	path = libs/nim-alpha
	url = $1
[submodule "alpha-head"]
	path = libs/alpha-head
	url = $1
	branch = main
[submodule "snapshot"]
	path = ./libs/snapshot/
	url = $2
[submodule "fork"]
	path = libs/fork
	url = $3
	branch = codetracer
[submodule "beta-local"]
	path = libs/beta-local
	url = $4
[submodule "rel"]
	path = libs/rel
	url = ../beta.git
""" % [alpha.bare, snap.bare, fork.bare, beta.bare])
    discard sh(["git", "-C", dir, "add", ".gitmodules"])
    for (path, commit) in [("libs/nim-alpha", alpha.commits[0]),
        ("libs/alpha-head", alpha.commits[1]),
        ("libs/snapshot", snap.commits[0]),
        ("libs/fork", fork.commits[0]),
        ("libs/beta-local", stranger.commits[0]),
        ("libs/rel", beta.commits[0])]:
      discard sh(["git", "-C", dir, "update-index", "--add", "--cacheinfo",
        "160000," & commit & "," & path])
    discard sh(["git", "-C", dir, "commit", "-q", "-m", "gitlinks"])

    let ran = captured(proc (): int =
      runGitlinkAuditCommand(dir, "", "", "amd64-linux", true))
    checkpoint ran.output
    check ran.rc == 0
    let report = parseJson(ran.output)
    check report["schema"].getStr() == "reprobuild.nimble.gitlink-audit.v1"
    var by = initTable[string, JsonNode]()
    for g in report["gitlinks"]: by[g["path"].getStr()] = g
    check by.len == 6
    for path, g in by:
      check g["reason"].getStr().len > 0

    check by["libs/nim-alpha"]["class"].getStr() == "catalog"
    check by["libs/nim-alpha"]["requirement"].getStr() ==
      "nimble:alpha == 1.0.0"
    check by["libs/alpha-head"]["class"].getStr() == "catalog, untagged"
    check by["libs/alpha-head"]["requirement"].getStr() ==
      "nimble:alpha#" & alpha.commits[1]
    check by["libs/alpha-head"]["branch"].getStr() == "main"
    check by["libs/snapshot"]["class"].getStr() == "catalog, snapshot"
    check by["libs/snapshot"]["requirement"].getStr() == "nimble:snap"
    check by["libs/fork"]["class"].getStr() == "overlay"
    check by["libs/fork"]["branch"].getStr() == "codetracer"
    check "no package of the index has the origin" in
      by["libs/fork"]["reason"].getStr()
    check by["libs/beta-local"]["class"].getStr() == "overlay"
    check "on no branch or tag" in by["libs/beta-local"]["reason"].getStr()
    check by["libs/rel"]["class"].getStr() == "catalog"
    check by["libs/rel"]["resolved_url"].getStr() == beta.bare
    check by["libs/rel"]["url"].getStr() == "../beta.git"

    # Positive control: without the origin, reachability is not known, and
    # the untagged gitlink is undecided rather than called an overlay.
    removeDir(alpha.bare)
    let gone = captured(proc (): int =
      runGitlinkAuditCommand(dir, "", "", "amd64-linux", true))
    checkpoint gone.output
    check gone.rc == 1
    for g in parseJson(gone.output)["gitlinks"]:
      if g["path"].getStr() == "libs/alpha-head":
        check g["class"].getStr() == "undecided"
      if g["path"].getStr() == "libs/nim-alpha":
        check g["class"].getStr() == "catalog"

    # The origin is asked at the URL the index records, never at the
    # `.gitmodules` spelling of it: `<alpha>/` has alpha's origin identity
    # (a trailing `/` does not count), but it is not the URL the index's
    # generation fetched. A gitlink with no `.gitmodules` URL has no known
    # origin, so it is undecided, never an overlay.
    var asked: seq[string]
    let recording = proc (url, commit: string): Reachability =
      asked.add url
      Reachability(known: true, reachable: true)
    let direct = classifyGitlinks(@[
        Gitlink(path: "libs/spelled", commit: alpha.commits[1],
          url: alpha.bare & "/"),
        Gitlink(path: "libs/no-url", commit: alpha.commits[1], url: "")],
      "", @[envelopeAt("alpha", @[record("alpha", "v1.0.0").atCommit(
        alpha.commits[0])], alpha.bare)], nimblePlatformOf("amd64-linux"),
      recording)
    checkpoint $direct.mapIt($it.class & ": " & it.reason)
    check asked == @[alpha.bare]
    check direct[0].class == gcCatalogUntagged
    check direct[1].class == gcUndecided
    check "origin is not known" in direct[1].reason
