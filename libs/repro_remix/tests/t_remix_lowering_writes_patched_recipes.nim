## Lowering a gated plan into patched Reprobuild recipes (M2 deliverable 1,
## M6 activation step 1).
##
## The plan comes from the real gate (`planInstall`) over real signed,
## logged releases. The "original recipe" is a recipe file this test
## writes in the exact shape of reprobuild-packages' from-source recipes
## (an `autotools_package` call after a `nativeBuildDeps` block): the test
## must not depend on a sibling checkout, and the rewrite only reads that
## shape. Building the lowered recipe is the separate e2e run recorded in
## the milestones file (`examples/lower_gzip_e2e.nim`), because it fetches a
## source tarball and runs a real toolchain.

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_remix
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32: result[i] = seed xor byte(i)
proc kid(k: PeerKeypair): Digest32 = Digest32(keyIdOf(k))
proc bytesOf(s: string): seq[byte] = s.mapIt(byte(ord(it)))

const Recipe = """
import repro_project_dsl
package gzipSource:
  nativeBuildDeps:
    "gcc >=11"
    "make >=4"
  build:
    let pkg = autotools_package(
      srcDir = "./src",
      configureOptions = @["--disable-nls"])
    discard pkg.executable("gzip")
"""

let logKey = generateKeypair()
let trust = TrustConfig(logKeys: @[kid(logKey)])
let gzipRef = OriginalRef(package: "gzip", interfaceFingerprint: d32(1),
  catalogWorkspace: "reprobuild-packages",
  catalogRemote: "https://github.com/metacraft-labs/reprobuild-packages",
  catalogRevision: "0123456789abcdef0123456789abcdef01234567",
  catalogInterfaceArtifact: d32(2))

var blobStore: seq[(Digest32, seq[byte])]
proc blobs(id: Digest32): (bool, seq[byte]) =
  for (k, v) in blobStore:
    if k == id: return (true, v)
  (false, @[])

proc diffOf(path, newLine: string): string =
  "--- a/" & path & "\n+++ b/" & path & "\n@@ -1,1 +1,2 @@\n line\n+" & newLine & "\n"

type World = object
  log: MerkleLog
  records: seq[seq[byte]]

proc logRecord(w: var World; env: Envelope): uint64 =
  let b = encodeEnvelope(env)
  result = uint64(w.log.append(logLeaf(env.recordKind, envelopeIdentity(env), b)))
  w.records.add b

proc gatedPlan(manifests: seq[(Manifest, PeerKeypair)]): PlanResult =
  var w: World
  var chains: seq[Principal]
  var seenKeys: seq[Digest32]
  for (_, k) in manifests:
    if kid(k) in seenKeys: continue
    seenKeys.add kid(k)
    let g = entrySigned(KeyLogEntry(operation: klGenesis, algorithm: saEcdsaP256,
      publicKey: @(k.publicKey), roles: {roleAuthor}), @[k])
    chains.add replayKeyLog(@[(g, w.logRecord(g))])
  var positions: seq[uint64]
  for (m, k) in manifests:
    var env = newManifestEnvelope(m)
    env.signEnvelope(k)
    positions.add w.logRecord(env)
  var cp = newStatementEnvelope(Statement(kind: skLogCheckpoint, subjectKind: sbLog,
    subject: kid(logKey), treeSize: uint64(w.log.size), rootHash: w.log.root()))
  cp.signEnvelope(logKey)
  var cands: seq[Candidate]
  for p in positions:
    cands.add Candidate(record: LoggedRecord(envelopeBytes: w.records[p], index: p,
      proof: w.log.inclusionProof(int(p), w.log.size)))
  planInstall(srcCli, cands, @[], PolicySnapshot(trust: trust, checkpoint: cp,
    principals: chains), d32(9), 0, blobs = blobs, admittedLicenses = @["MIT"])

proc release(name, path, line: string; k: PeerKeypair; strip = 1'u8;
             config = false): Manifest =
  let patch = bytesOf(diffOf(path, line))
  blobStore.add (blobId(patch), patch)
  result = Manifest(remixName: name, version: "1.0.0", intent: "Fixture.",
    license: "MIT", targets: @[Target(original: gzipRef, constraintKind: ckExactFingerprint)],
    patches: @[Patch(appliesToKind: ptTarget, appliesToIndex: 0,
      blob: BlobRef(id: blobId(patch), mediaType: "text/x-diff", size: uint64(patch.len)),
      strip: strip, order: 0)],
    authors: @[kid(k)])
  if config:
    let v = bytesOf("on")
    blobStore.add (blobId(v), v)
    result.configuration = @[ConfigContribution(configurable: "gzip.rsyncable",
      schemaFingerprint: d32(5), priority: cpSet, operation: coReplace,
      value: BlobRef(id: blobId(v), mediaType: "text/plain", size: 2))]

suite "Remix lowering — gated plans become patched recipes":

  let root = createTempDir("remix-lower-", "")
  let recipes = root / "originals" / "gzip"
  createDir(recipes)
  writeFile(recipes / "repro.nim", Recipe)
  createDir(recipes / ".repro")
  writeFile(recipes / ".repro" / "stale-output", "x")
  let recipeDir = proc (pkg: string): string =
    if pkg == "gzip": recipes else: ""

  test "two members' patches are written in plan order and applied idempotently":
    let a = generateKeypair()
    let b = generateKeypair()
    let r = gatedPlan(@[(release("a/one", "gzip.c", "one();", a), a),
                        (release("b/two", "NEWS", "two", b, strip = 1), b)])
    check r.ok
    let cat = lowerPlan(r.plan, root / "lowered", recipeDir, blobs)
    check cat.root == root / "lowered" / toHex(r.plan.composition.id)
    check cat.packages.len == 1
    check cat.notLowered.len == 0
    let p = cat.packages[0]
    check p.patchFiles.len == 2
    let recipe = readFile(p.recipeDir / "repro.nim")
    check "srcPatches = @[" in recipe
    check "\"git\"" in recipe
    check recipe.count("git apply -R --check -p1") == 2
    # Patch files hold exactly the blob bytes, in the plan's order.
    let steps = r.plan.composition.plan.patches
    for i, rel in p.patchFiles:
      let (_, bytes) = blobs(steps[i].patch.blob.id)
      check readFile(p.recipeDir / rel) == bytes.mapIt(char(it)).join("")
    check recipe.find(p.patchFiles[0]) < recipe.find(p.patchFiles[1])
    # Build outputs of the original recipe are never copied.
    check not dirExists(p.recipeDir / ".repro")

  test "items lowering cannot yet express are reported, not dropped":
    let a = generateKeypair()
    let r = gatedPlan(@[(release("a/cfg", "gzip.c", "cfg();", a, config = true), a)])
    check r.ok
    let cat = lowerPlan(r.plan, root / "lowered", recipeDir, blobs)
    check cat.notLowered == @["1 configuration contribution(s)"]

  test "recipes the rewrite cannot handle safely are refused":
    var reason = ""
    try: discard rewriteRecipe(Recipe.replace("srcDir", "srcPatches = @[], srcDir"), @["x"])
    except RemixError as e: reason = $e.reason
    check reason == $rrForbiddenContent
    reason = ""
    try: discard rewriteRecipe(Recipe.replace("autotools_package(", "nim_package("), @["x"])
    except RemixError as e: reason = $e.reason
    check reason == $rrForbiddenContent
    # And an ungated plan never lowers.
    reason = ""
    try: discard lowerPlan(nil, root / "lowered", recipeDir, blobs)
    except RemixError as e: reason = $e.reason
    check reason == $rrForbiddenContent

  removeDir(root)
