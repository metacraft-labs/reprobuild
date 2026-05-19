## Smoke test for the M64 rollback library. Pins the public API
## compiles, the diff planner orders ops deterministically, and the
## digest-check helper detects drift correctly.

import std/[unittest]

import blake3
import repro_home_generations
import repro_home_rollback

proc digestOf(s: string): Digest256 =
  var buf = newSeq[byte](s.len)
  for i, ch in s:
    buf[i] = byte(ord(ch))
  let raw = blake3.digest(buf)
  for i in 0 ..< 32:
    result[i] = raw[i]

proc mkFile(path, content: string): GeneratedFile =
  result.absoluteOutputPath = path
  result.ownershipPolicy = gfoOwned
  result.postWriteDigest = digestOf(content)
  result.storeContentHash = result.postWriteDigest

suite "Home-rollback smoke":

  test "diff plan: removes, restores, updates each populated":
    var curManifest = ActivationManifest(schemaVersion: 1'u16)
    var tgtManifest = ActivationManifest(schemaVersion: 1'u16)
    # File A: only in current -> remove on rollback.
    curManifest.generatedFiles.add(mkFile("/h/a", "a-cur"))
    # File B: only in target -> restore on rollback.
    tgtManifest.generatedFiles.add(mkFile("/h/b", "b-tgt"))
    # File C: in both but different digest -> update on rollback.
    curManifest.generatedFiles.add(mkFile("/h/c", "c-cur"))
    tgtManifest.generatedFiles.add(mkFile("/h/c", "c-tgt"))

    var env = PointerEnvelope(schemaVersion: 1'u16)
    let plan = buildRollbackPlan(curManifest, tgtManifest, env)
    check plan.fileOps.len == 3
    # Order: removes first, then restores, then updates.
    check plan.fileOps[0].kind == rokRemoveFile
    check plan.fileOps[0].absoluteOutputPath == "/h/a"
    check plan.fileOps[1].kind == rokRestoreFile
    check plan.fileOps[1].absoluteOutputPath == "/h/b"
    check plan.fileOps[2].kind == rokUpdateFile
    check plan.fileOps[2].absoluteOutputPath == "/h/c"

  test "diff plan: empty when manifests are equal":
    var same = ActivationManifest(schemaVersion: 1'u16)
    same.generatedFiles.add(mkFile("/h/x", "shared"))
    var env = PointerEnvelope(schemaVersion: 1'u16)
    let plan = buildRollbackPlan(same, same, env)
    check plan.isEmpty
