## A `kind = "nimble-index"` catalog read through the shared bare clone asks
## each object's SIZE before reading it, and refuses an object larger than
## its bound without reading it (NPC-M3's open gap, closed by NPC-M5).
##
## The index repository publishes a good index, then a commit in which one
## shard's object is replaced by a 17 MiB blob (the shard bound is 16 MiB),
## and one in which `published-index/root` is a 9 MiB blob (the root bound is
## 8 MiB). Every git invocation of the reader goes through a logging wrapper
## first on `PATH`, which then runs the real git: the oversized objects are
## sized (`cat-file -s`) and refused, and never read (`cat-file blob`). A
## good shard is still read (positive control: the log does see reads).
##
## The wrapper is the only stand-in, and it changes nothing git does; the
## repositories, the shared clone and the reader are the production ones.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_lock
import repro_cli_support/catalog_discovery
import repro_nimble_index

import ../../repro_nimble_index/tests/index_fixtures
import ../../../tests/integration/published_catalog_fixtures

const Remote = "https://example.invalid/nim/nimble-index-sized"

proc declare(project, commit: string) =
  createDir(project)
  writeFile(project / "repro-catalogs.toml",
    "schema = \"reprobuild.catalog-imports.v1\"\n\n[[import]]\n" &
    "repo = \"nimble-index\"\nremote = \"" & Remote & "\"\n" &
    "kind = \"nimble-index\"\ncommit = \"" & commit & "\"\n")

proc failure(body: proc ()): string =
  try:
    body()
    "no refusal"
  except CatalogDiscoveryError as e:
    e.msg
  except NimbleIndexError as e:
    "index: " & $e.reason & ": " & e.msg

suite "the git-backed index source sizes an object before reading it":
  let root = createTempDir("npc-m5-sized-", "")
  putEnv("HOME", root / "home")
  createDir(root / "home")
  let clones = root / "clones"
  putEnv("REPRO_WORKSPACE_CLONES", clones)
  let built = syntheticIndex(60)
  var repo = initCatalogRepo(root, "nimble-index", Remote)
  writeIndexDir(built, repo.upstream / "published-index")
  let good = repo.publishCommit([], "index generation 1")
  let victim = built.root.shards[0]
  let bigShard = repeat('s', 17 * 1024 * 1024)
  let bigShardOid = gitObjectId("blob", bigShard)
  let oversizedShard = repo.publishCommit([], "oversized shard",
    extraFiles = [("published-index/" & IndexObjectsDir & "/" & $victim.id,
      bigShard)])
  let bigRoot = repeat('r', 9 * 1024 * 1024)
  let bigRootOid = gitObjectId("blob", bigRoot)
  let oversizedRoot = repo.publishCommit([], "oversized root",
    extraFiles = [("published-index/" & IndexRootFile, bigRoot)])
  discard repo.syncSharedClone(clones)
  # The logging wrapper, first on PATH from here on.
  let realGit = findExe("git")
  let wrapperDir = root / "bin"
  let log = root / "git.log"
  createDir(wrapperDir)
  writeFile(wrapperDir / "git", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" & log &
    "'\nexec '" & realGit & "' \"$@\"\n")
  setFilePermissions(wrapperDir / "git", {fpUserRead, fpUserWrite,
    fpUserExec})
  putEnv("PATH", wrapperDir & ":" & getEnv("PATH"))

  proc logged(): string =
    if fileExists(log): readFile(log) else: ""

  test "an oversized shard is refused unread; a good shard is read":
    writeFile(log, "")
    let project = root / "p1"
    declare(project, oversizedShard)
    let answer = catalogsForReselect(project, @[])
    var idx = openNimbleIndex(answer.nimbleIndexes[0])
    var victimName = ""
    for p in decodeShard(objectTable(built)[victim.id]).packages:
      victimName = p.name
    let msg = failure(proc () = discard lookupPackage(idx, victimName))
    checkpoint msg
    check msg.startsWith("index: " & $nrOversize)
    check "it is not read" in msg
    let calls = logged()
    check ("cat-file -s " & bigShardOid) in calls
    check ("cat-file blob " & bigShardOid) notin calls
    # Positive control: a shard within its bound is sized and read.
    var otherName = ""
    for p in decodeShard(objectTable(built)[built.root.shards[1].id]).packages:
      otherName = p.name
    check lookupPackage(idx, otherName).found
    check "cat-file blob " in logged()

  test "an oversized root is refused unread":
    writeFile(log, "")
    let project = root / "p2"
    declare(project, oversizedRoot)
    let msg = failure(proc () = discard catalogsForReselect(project, @[]))
    checkpoint msg
    check "is refused" in msg
    check "it is not read" in msg
    let calls = logged()
    check ("cat-file -s " & bigRootOid) in calls
    check ("cat-file blob " & bigRootOid) notin calls

  test "the good revision still reads":
    let project = root / "p3"
    declare(project, good)
    let answer = catalogsForReselect(project, @[])
    check answer.pins[0].interfaceArtifact == $built.rootId
