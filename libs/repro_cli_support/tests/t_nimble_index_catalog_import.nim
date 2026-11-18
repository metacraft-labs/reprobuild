## A ``kind = "nimble-index"`` catalog import, read from a real git
## repository through the workspace's shared bare clone (Federated-Catalog-
## Imports.md § Catalog kinds; Nimble package catalog NPC-AREQ1, NPC-M3).
##
## The index repository publishes ``published-index/`` -- written by the
## production index writer -- in an ordinary commit; discovery reads it at
## the pinned revision by object id, re-hashing every git object (C1), from
## the shared clone whose origin is the declared remote (C2), as it reads a
## provisioning catalog. Re-selection pins the import with its kind and the
## index identity (the root's hash); a build re-reads it at the pin and
## refuses another identity; the shards are read on demand and each is
## checked against the root's hash.

import std/[os, sequtils, strutils, tables, tempfiles, unittest]

import repro_lock
import repro_cli_support/catalog_discovery
import repro_nimble_index

import ../../repro_nimble_index/tests/index_fixtures
import ../../../tests/integration/published_catalog_fixtures

const Remote = "https://example.invalid/nim/nimble-index"

proc toStr(b: seq[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc declare(project, commit: string; kind = "nimble-index") =
  createDir(project)
  writeFile(project / "repro-catalogs.toml",
    "schema = \"reprobuild.catalog-imports.v1\"\n\n[[import]]\n" &
    "repo = \"nimble-index\"\nremote = \"" & Remote & "\"\n" &
    "kind = \"" & kind & "\"\ncommit = \"" & commit & "\"\n")

proc failure(body: proc ()): string =
  try:
    body()
    "no refusal"
  except CatalogDiscoveryError as e:
    e.msg
  except NimbleIndexError as e:
    "index: " & $e.reason & ": " & e.msg

suite "a nimble-index catalog import is read at its pinned revision":
  let root = createTempDir("npc-m3-import-", "")
  putEnv("HOME", root / "home")
  createDir(root / "home")
  let clones = root / "clones"
  putEnv("REPRO_WORKSPACE_CLONES", clones)
  let built = syntheticIndex(60)
  var repo = initCatalogRepo(root, "nimble-index", Remote)
  writeIndexDir(built, repo.upstream / "published-index")
  let good = repo.publishCommit([], "index generation 1")
  # A second commit: one shard's object replaced by other bytes under its
  # name (a substituted shard), everything else unchanged.
  let victim = built.root.shards[0]
  # (Files go through ``extraFiles``: ``publishCommit`` checks the branch
  # out with ``-f`` first, which would discard an edit made before it.)
  let victimPath = "published-index/" & IndexObjectsDir & "/" & $victim.id
  let substituted = repo.publishCommit([], "substituted shard",
    extraFiles = [(victimPath,
      toStr(objectTable(built)[built.root.shards[1].id]))])
  # A third: a stray file in published-index/.
  let stray = repo.publishCommit([], "stray file",
    extraFiles = [("published-index/README", "not an object\n")])
  discard repo.syncSharedClone(clones)

  test "re-selection pins the import with its kind and the index identity":
    let project = root / "p1"
    declare(project, good)
    let answer = catalogsForReselect(project, @[])
    check answer.imports.len == 0 # it supplies no provisioning content
    check answer.nimbleIndexes.len == 1
    check answer.pins.len == 1
    let pin = answer.pins[0]
    check pin.kind == cikNimbleIndex
    check pin.revision == good
    check pin.interfaceArtifact == $built.rootId
    # The record round-trips through the lock's canonical bytes.
    check parseCatalogImports(serializeCatalogImports(answer.pins)) ==
      answer.pins
    # And the index reads through the shared clone, shard by shard.
    var idx = openNimbleIndex(answer.nimbleIndexes[0])
    let found = lookupPackage(idx, "beta")
    check found.found
    check found.package.versions.len == 2

  test "a build reads the index at the pin and refuses another identity":
    let project = root / "p2"
    declare(project, good)
    let pins = catalogsForReselect(project, @[]).pins
    let answer = catalogsForBuild(project, pins, @[])
    check answer.nimbleIndexes.len == 1
    check answer.nimbleIndexes[0].indexIdentity == $built.rootId
    var wrong = pins
    wrong[0].interfaceArtifact = "0".repeat(64)
    let msg = failure(proc () = discard catalogsForBuild(project, wrong, @[]))
    check "publishes the Nimble index " & $built.rootId in msg
    check "the committed lock pins " & "0".repeat(64) in msg
    var kind = pins
    kind[0].kind = cikProvisioning
    check "the lock pins kind `provisioning`" in
      failure(proc () = discard catalogsForBuild(project, kind, @[]))

  test "a substituted shard in the published tree is refused when it is read":
    let project = root / "p3"
    declare(project, substituted)
    let answer = catalogsForReselect(project, @[])
    # The root is the same, so the identity is too; the shard is not.
    check answer.pins[0].interfaceArtifact == $built.rootId
    var idx = openNimbleIndex(answer.nimbleIndexes[0])
    var victimName = ""
    for p in decodeShard(objectTable(built)[victim.id]).packages:
      victimName = p.name
    let msg = failure(proc () = discard lookupPackage(idx, victimName))
    checkpoint "lookup of " & victimName & ": " & msg
    check msg.startsWith("index: " & $nrSizeMismatch) or
      msg.startsWith("index: " & $nrHashMismatch)

  test "a published-index holding anything but the index is refused":
    let project = root / "p4"
    declare(project, stray)
    let msg = failure(proc () = discard catalogsForReselect(project, @[]))
    check "`published-index/README`" in msg
    check "nothing else" in msg

  test "the same repository imported as a provisioning catalog is not read as an index":
    let project = root / "p5"
    declare(project, good, kind = "provisioning")
    let msg = failure(proc () = discard catalogsForReselect(project, @[]))
    check "published-interfaces" in msg
