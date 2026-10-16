## A content-keyed cache record compares the input's KIND as well as its
## content hash, so two different kinds of entity whose hashed bytes happen
## to coincide can never be served as the same input.
##
## THE DEFECT THIS PINS. Under `ffpChecksum` a recorded input was compared by
## its local content hash alone, and under `ffpHybrid` a metadata change was
## "cut off" whenever the content hash still matched. The hashed bytes are not
## unique to one kind of entity:
##
##   * an absent path, a directory and a FIFO all hash the EMPTY payload, so
##     an absent path that became an empty regular file (or a directory) was
##     a cache hit;
##   * a dangling symlink hashes a marker text that names its target
##     (`reprobuild.unresolved-symlink.v1\0<target>\0<reason>`), so a link
##     whose target was created as a regular file containing exactly that
##     text was a cache hit.
##
## Each is a WRONG hit: the action could observe something different (a file
## where there was none, a resolving link where there was a dangling one).
## Unlikely contents, but a cache must not be able to produce a wrong hit by
## construction, so the comparison now requires the kinds to match too.
##
## Every case runs under both content-keyed policies and carries a positive
## control (the unchanged state is a hit), so a change that simply stopped
## caching these inputs cannot pass.
##
## MOCK POLICY: none. Real files, symlinks and directories in a temporary
## directory, recorded and looked up through the production
## `recordActionResult` / `lookupActionResult`.

import std/[os, tempfiles, times, unittest]

import repro_hash
import repro_local_store

proc weakFor(text: string): ContentDigest =
  var payload = newSeq[byte](text.len)
  for i, ch in text:
    payload[i] = byte(ord(ch))
  blake3DomainDigest(payload, hdActionFingerprint)

type Fixture = object
  root: string
  work: string
  cache: ActionCache
  cas: LocalCas

proc newFixture(prefix: string): Fixture =
  result.root = createTempDir(prefix, "")
  result.work = result.root / "work"
  createDir(result.work)
  result.cache = openActionCache(result.root / "cache", attachShm = false)
  result.cas = openLocalCas(result.root / "cas")

proc record(fx: var Fixture; weak: ContentDigest;
            policy: FileFingerprintPolicy; input: string): ActionResultRecord =
  fx.cache.recordActionResult(fx.cas, weak, policy, [input], [],
    outputRoot = fx.work, storeOutputBlobs = false)

proc lookup(fx: var Fixture; weak: ContentDigest;
            policy: FileFingerprintPolicy): ActionCacheLookup =
  fx.cache.lookupActionResult(fx.cas, weak, policy, verifyOutputBlobs = false,
    outputRoot = fx.work)

proc unresolvedSymlinkMarker(target, reason: string): string =
  ## The exact bytes a content-keyed policy hashes for a dangling link
  ## (`unresolvedSymlinkIdentity`). Spelled out here rather than imported:
  ## the test's claim is that a REGULAR FILE with these bytes is not
  ## mistaken for the link, so it must not depend on how production builds
  ## them.
  "reprobuild.unresolved-symlink.v1\0" & target & "\0" & reason

const contentKeyed = [ffpChecksum, ffpHybrid]

suite "t_content_keyed_comparison_includes_file_kind":

  # POSIX only: the case is defined by a dangling symlink, which needs
  # privileges to create on Windows. Declared conditionally, not skipped.
  when defined(posix):
    test "a dangling link whose target appears holding exactly the marker bytes is a miss":
      for policy in contentKeyed:
        checkpoint("policy " & $policy)
        var fx = newFixture("repro-kind-marker-")
        defer: removeDir(fx.root)
        let target = fx.work / "target-appears-later.txt"
        let link = fx.work / "dangling"
        createSymlink(target, link)
        let weak = weakFor("kind.marker." & $policy)

        let recorded = fx.record(weak, policy, link)
        require recorded.inputs.len == 1
        require recorded.inputs[0].metadata.kind == ffkUnresolvedSymlink
        # Positive control: nothing changed, the record is served.
        check fx.lookup(weak, policy).status == aclHit

        # The target appears as a regular file whose bytes are exactly what
        # the dangling link hashed. The content hashes are therefore EQUAL;
        # only the kind tells the two states apart.
        writeFile(target, unresolvedSymlinkMarker(target, "absent"))
        let now = observeFile(link, policy)
        require now.metadata.kind == ffkRegular
        require now.hasLocalHash and recorded.inputs[0].hasLocalHash
        require now.localHash == recorded.inputs[0].localHash

        let after = fx.lookup(weak, policy)
        check after.status == aclMissInputChanged
        check after.changedInputPath == link

  test "an absent path that becomes an empty regular file is a miss":
    for policy in contentKeyed:
      checkpoint("policy " & $policy)
      var fx = newFixture("repro-kind-absent-file-")
      defer: removeDir(fx.root)
      let probe = fx.work / "probed-but-absent.h"
      let weak = weakFor("kind.absent-file." & $policy)

      let recorded = fx.record(weak, policy, probe)
      require recorded.inputs.len == 1
      require recorded.inputs[0].metadata.kind == ffkMissing
      check fx.lookup(weak, policy).status == aclHit

      # An empty file hashes the same empty payload an absent path does.
      writeFile(probe, "")
      require observeFile(probe, policy).localHash ==
        recorded.inputs[0].localHash

      let after = fx.lookup(weak, policy)
      check after.status == aclMissInputChanged
      check after.changedInputPath == probe

  test "an absent path that becomes a directory is a miss":
    for policy in contentKeyed:
      checkpoint("policy " & $policy)
      var fx = newFixture("repro-kind-absent-dir-")
      defer: removeDir(fx.root)
      let probe = fx.work / "probed-but-absent"
      let weak = weakFor("kind.absent-dir." & $policy)

      let recorded = fx.record(weak, policy, probe)
      require recorded.inputs[0].metadata.kind == ffkMissing
      check fx.lookup(weak, policy).status == aclHit

      createDir(probe)
      require observeFile(probe, policy).localHash ==
        recorded.inputs[0].localHash

      let after = fx.lookup(weak, policy)
      check after.status == aclMissInputChanged
      check after.changedInputPath == probe

  test "a directory replaced by an empty regular file is a miss":
    for policy in contentKeyed:
      checkpoint("policy " & $policy)
      var fx = newFixture("repro-kind-dir-file-")
      defer: removeDir(fx.root)
      let entry = fx.work / "was-a-directory"
      createDir(entry)
      let weak = weakFor("kind.dir-file." & $policy)

      let recorded = fx.record(weak, policy, entry)
      require recorded.inputs[0].metadata.kind == ffkDirectory
      check fx.lookup(weak, policy).status == aclHit

      removeDir(entry)
      writeFile(entry, "")
      require observeFile(entry, policy).localHash ==
        recorded.inputs[0].localHash

      let after = fx.lookup(weak, policy)
      check after.status == aclMissInputChanged
      check after.changedInputPath == entry

  test "a regular file whose content does not change is still cut off across a metadata change":
    # The other side of the fix: requiring equal kinds must not cost the
    # hybrid cutoff its purpose. A touch moves the mtime but keeps the kind
    # and the hash, and the record is still served.
    var fx = newFixture("repro-kind-cutoff-")
    defer: removeDir(fx.root)
    let input = fx.work / "input.txt"
    writeFile(input, "same bytes\n")
    let weak = weakFor("kind.cutoff")
    discard fx.record(weak, ffpHybrid, input)
    check fx.lookup(weak, ffpHybrid).status == aclHit
    setLastModificationTime(input, getLastModificationTime(input) +
      initDuration(seconds = 5))
    # Served through the cutoff: the metadata moved, the content did not.
    check fx.lookup(weak, ffpHybrid).status == aclHybridCutoff
