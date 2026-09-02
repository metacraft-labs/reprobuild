## Local-CAS-Hardlink-Materialization M0 — tests for the filesystem
## link-capability model and probe.
##
## Spec: ``reprobuild-specs/Local-Content-Addressed-Store.md``
##       §"Hardlink, Reflink, and Copy Policy" (normative).
##
## The probe is deliberately empirical: it attempts each mechanism once
## per filesystem pair instead of predicting from a filesystem-type
## string. These tests therefore run against the REAL volumes of the
## host and assert what the operations actually do, including the two
## properties that decide safety:
##
##   * a write through a hardlink is visible through every other name
##     (the hazard M3 exists to fence);
##   * a write through a reflink is not (shared extents break on write).
##
## Arms that need a second writable volume, or a specific filesystem,
## announce via ``checkpoint`` when the host cannot supply one rather
## than silently passing.

import std/[exitprocs, os, sequtils, strutils, unittest]

from repro_core/paths import extendedPath

import repro_cas_store

# ---------------------------------------------------------------------------
# Host volume discovery
# ---------------------------------------------------------------------------

type
  ProbeVolume = object
    dir*: string      ## A writable scratch directory on the volume.
    fsName*: string   ## Diagnostic only — never an input to a capability.
    pairKey*: string  ## ``filesystemPairKey(dir, dir)``; the identity we
                      ## use to tell one volume from another.

var scratchDirs: seq[string] = @[]

proc claimScratchDir(parent: string; tag: string): string =
  ## Create ``<parent>/repro-m0-<pid>-<tag>`` and remember it for
  ## teardown. Returns ``""`` when the parent is not writable.
  if parent.len == 0 or not dirExists(extendedPath(parent)):
    return ""
  let candidate = parent / ("repro-m0-" & $getCurrentProcessId() & "-" & tag)
  try:
    createDir(extendedPath(candidate))
    # Prove it is writable, not merely creatable.
    let witness = candidate / "witness"
    writeFile(extendedPath(witness), "ok")
    removeFile(extendedPath(witness))
  except CatchableError, Defect:
    return ""
  scratchDirs.add(candidate)
  candidate

proc candidateParents(): seq[string] =
  ## Places that plausibly sit on distinct filesystems on this host.
  result = @[getTempDir()]
  when defined(windows):
    for letter in 'A' .. 'Z':
      result.add($letter & ":\\")
  else:
    for p in ["/tmp", "/var/tmp", "/dev/shm", getHomeDir()]:
      result.add(p)
  # The checkout the test itself lives in — on this workspace that is a
  # different volume from %TEMP%.
  result.add(currentSourcePath().parentDir())

proc discoverVolumes(): seq[ProbeVolume] =
  ## One scratch directory per distinct filesystem. The candidate's own
  ## identity is read BEFORE anything is created, so a host with a dozen
  ## drive letters on one volume gets one scratch directory, not a dozen.
  result = @[]
  var seenKeys: seq[string] = @[]
  var tag = 0
  for parent in candidateParents():
    if parent.len == 0 or not dirExists(extendedPath(parent)):
      continue
    let key = filesystemPairKey(parent, parent)
    if key in seenKeys:
      continue
    let dir = claimScratchDir(parent, "vol" & $tag)
    tag.inc
    if dir.len == 0:
      continue
    seenKeys.add(key)
    result.add(ProbeVolume(dir: dir, fsName: filesystemName(dir),
                           pairKey: filesystemPairKey(dir, dir)))

let volumes = discoverVolumes()

proc primaryVolume(): ProbeVolume =
  doAssert volumes.len > 0,
    "no writable scratch directory could be created on this host; the " &
    "link-capability probe cannot be exercised at all"
  volumes[0]

# ---------------------------------------------------------------------------

suite "M0 link-capability probe — availability":
  test "a probe within one directory reports hardlink available on this host":
    let vol = primaryVolume()
    var cache: LinkCapabilityCache
    let cap = probeLinkCapabilities(cache, vol.dir, vol.dir)
    checkpoint("volume " & vol.dir & " fs=" & vol.fsName & " -> " &
               cap.describe())
    check cap.probed
    check cap.hardlink
    check cap.hardlinkAttempt.outcome == loOk
    check lmHardlink in cap.preferredMechanisms()

  test "hardlink is unavailable across two different volumes":
    if volumes.len < 2:
      checkpoint("only one writable volume was discoverable on this host (" &
                 volumes.mapIt(it.dir).join(", ") &
                 "); the cross-device arm was NOT exercised")
      check volumes.len >= 1
    else:
      let a = volumes[0]
      let b = volumes[1]
      check a.pairKey != b.pairKey
      var cache: LinkCapabilityCache
      let cap = probeLinkCapabilities(cache, a.dir, b.dir)
      checkpoint(a.dir & " (" & a.fsName & ") -> " & b.dir & " (" &
                 b.fsName & "): " & cap.describe())
      check cap.probed
      check not cap.hardlink
      # The refusal must come from the operation's own error, not from a
      # prediction: EXDEV / ERROR_NOT_SAME_DEVICE.
      check cap.hardlinkAttempt.outcome == loCrossDevice
      # ...and the only mechanism left is the one that cannot be
      # unavailable.
      check cap.preferredMechanisms() == @[lmCopy]

  test "reflink availability matches what the filesystem actually implements":
    var examined = 0
    for vol in volumes:
      var cache: LinkCapabilityCache
      let cap = probeLinkCapabilities(cache, vol.dir, vol.dir)
      check cap.probed
      examined.inc
      checkpoint(vol.dir & " fs=" & vol.fsName & " -> " & cap.describe())
      when defined(windows):
        # NTFS has no clone primitive at all; ReFS implements
        # FSCTL_DUPLICATE_EXTENTS_TO_FILE (block cloning).
        if vol.fsName == "NTFS":
          check not cap.reflink
          # Platform-And-Filesystem-Facts F3 made this assertion more
          # specific rather than less: the answer used to be
          # ``loUnsupported``, DISCOVERED by issuing the FSCTL against a
          # filesystem that has never implemented it. It is now
          # ``loNotAttempted``, REASONED from NTFS's declared
          # ``reflink = no``, and the verdict is what pins that it came
          # from the table and not from a probe that quietly stopped
          # running. ``t_link_capability_facts.nim`` asserts the
          # syscall counter does not move.
          check cap.reflinkVerdict == fvImpossible
          check cap.reflinkAttempt.outcome == loNotAttempted
        elif vol.fsName == "ReFS":
          check cap.reflink
          check cap.reflinkVerdict == fvPossible
          check cap.reflinkAttempt.outcome == loOk
      # Whatever the filesystem, the recorded flag and the recorded
      # outcome must agree — a "true" that was never observed is the
      # failure mode the probe exists to prevent.
      check cap.reflink == (cap.reflinkAttempt.outcome == loOk)
      check cap.hardlink == (cap.hardlinkAttempt.outcome == loOk)
    check examined > 0

  test "the probe leaves no debris behind":
    let vol = primaryVolume()
    var cache: LinkCapabilityCache
    discard probeLinkCapabilities(cache, vol.dir, vol.dir)
    var leftovers: seq[string] = @[]
    for kind, path in walkDir(extendedPath(vol.dir)):
      if "linkprobe" in extractFilename(path):
        leftovers.add(path)
    check leftovers.len == 0

suite "M0 link-capability probe — caching":
  test "a cached answer is reused rather than re-probed":
    let vol = primaryVolume()
    var cache: LinkCapabilityCache
    check cache.probeCount() == 0
    let first = probeLinkCapabilities(cache, vol.dir, vol.dir)
    check cache.probeCount() == 1
    check cache.cachedPairCount() == 1
    let second = probeLinkCapabilities(cache, vol.dir, vol.dir)
    check cache.probeCount() == 1
    check cache.cachedPairCount() == 1
    check second.hardlink == first.hardlink
    check second.reflink == first.reflink
    check second.key == first.key

  test "two directories on one filesystem share a single cache entry":
    let vol = primaryVolume()
    let sub = vol.dir / "sub-a"
    let sub2 = vol.dir / "sub-b"
    createDir(extendedPath(sub))
    createDir(extendedPath(sub2))
    var cache: LinkCapabilityCache
    discard probeLinkCapabilities(cache, sub, sub2)
    check cache.probeCount() == 1
    discard probeLinkCapabilities(cache, sub2, sub)
    check cache.probeCount() == 1
    check cache.cachedPairCount() == 1

  test "an unprobeable pair is not cached and does not poison a good one":
    let vol = primaryVolume()
    let missing = vol.dir / "does-not-exist-anywhere"
    var cache: LinkCapabilityCache
    let bad = probeLinkCapabilities(cache, vol.dir, missing)
    check not bad.probed
    check not bad.hardlink
    check not bad.reflink
    # Nothing was learned, so nothing may be remembered.
    check cache.probeCount() == 0
    check cache.cachedPairCount() == 0
    # The same pair becomes probeable once the directory exists.
    createDir(extendedPath(missing))
    let good = probeLinkCapabilities(cache, vol.dir, missing)
    check good.probed
    check good.hardlink
    check cache.probeCount() == 1

  test "a cross-device answer does not poison a same-device pair":
    if volumes.len < 2:
      checkpoint("only one writable volume was discoverable on this host; " &
                 "the cross-device cache-isolation arm was NOT exercised")
      check volumes.len >= 1
    else:
      let a = volumes[0]
      let b = volumes[1]
      var cache: LinkCapabilityCache
      let crossPair = probeLinkCapabilities(cache, a.dir, b.dir)
      check crossPair.probed
      check not crossPair.hardlink
      check cache.probeCount() == 1
      let samePair = probeLinkCapabilities(cache, a.dir, a.dir)
      check samePair.probed
      check samePair.hardlink
      check cache.probeCount() == 2
      check cache.cachedPairCount() == 2
      check samePair.key != crossPair.key

  test "clear forgets every answer":
    let vol = primaryVolume()
    var cache: LinkCapabilityCache
    discard probeLinkCapabilities(cache, vol.dir, vol.dir)
    check cache.probeCount() == 1
    cache.clear()
    check cache.probeCount() == 0
    check cache.cachedPairCount() == 0
    discard probeLinkCapabilities(cache, vol.dir, vol.dir)
    check cache.probeCount() == 1

  test "the process-wide cache probes a pair at most once":
    let vol = primaryVolume()
    resetGlobalLinkCapabilityCache()
    check globalProbeCount() == 0
    let a = linkCapabilities(vol.dir, vol.dir)
    check globalProbeCount() == 1
    let b = linkCapabilities(vol.dir, vol.dir)
    check globalProbeCount() == 1
    check a.key == b.key
    resetGlobalLinkCapabilityCache()

suite "M0 link-capability probe — the safety model":
  test "a write through a hardlink is visible through every other name":
    let vol = primaryVolume()
    var cache: LinkCapabilityCache
    let cap = probeLinkCapabilities(cache, vol.dir, vol.dir)
    require cap.hardlink
    let src = vol.dir / "shared-inode-src.bin"
    let dst = vol.dir / "shared-inode-dst.bin"
    removeFile(extendedPath(dst))
    writeFile(extendedPath(src), "original")
    check attemptHardlink(src, dst).outcome == loOk
    check hardlinkCount(src) == 2
    check hardlinkCount(dst) == 2
    writeFile(extendedPath(dst), "mutated-through-the-link")
    # THIS is the hazard: the CAS blob would have been edited.
    check readFile(extendedPath(src)) == "mutated-through-the-link"
    removeFile(extendedPath(dst))
    check hardlinkCount(src) == 1
    removeFile(extendedPath(src))

  test "a write through a reflink is not visible through the source":
    let refsVols = volumes.filterIt(
      (block:
        var c: LinkCapabilityCache
        probeLinkCapabilities(c, it.dir, it.dir).reflink))
    if refsVols.len == 0:
      checkpoint("no volume on this host implements reflink (" &
                 volumes.mapIt(it.dir & "=" & it.fsName).join(", ") &
                 "); the copy-on-write arm was NOT exercised")
      check volumes.len >= 1
    else:
      let vol = refsVols[0]
      let src = vol.dir / "cow-src.bin"
      let dst = vol.dir / "cow-dst.bin"
      removeFile(extendedPath(dst))
      writeFile(extendedPath(src), "original")
      check attemptReflink(src, dst).outcome == loOk
      check readFile(extendedPath(dst)) == "original"
      # A clone is its own inode: no shared link count.
      check hardlinkCount(src) == 1
      writeFile(extendedPath(dst), "mutated-through-the-clone")
      # Copy-on-write: the source is untouched. This is why the spec
      # prefers reflink over hardlink on safety grounds, not just cost.
      check readFile(extendedPath(src)) == "original"
      removeFile(extendedPath(dst))
      removeFile(extendedPath(src))

  test "preferredMechanisms orders reflink before hardlink before copy":
    var cap = LinkCapability(probed: true, reflink: true, hardlink: true)
    check cap.preferredMechanisms() == @[lmReflink, lmHardlink, lmCopy]
    cap = LinkCapability(probed: true, reflink: false, hardlink: true)
    check cap.preferredMechanisms() == @[lmHardlink, lmCopy]
    cap = LinkCapability(probed: true, reflink: true, hardlink: false)
    check cap.preferredMechanisms() == @[lmReflink, lmCopy]
    cap = LinkCapability(probed: true, reflink: false, hardlink: false)
    check cap.preferredMechanisms() == @[lmCopy]

  test "allowSharedInode=false drops the hardlink arm but keeps copy":
    let cap = LinkCapability(probed: true, reflink: true, hardlink: true)
    check cap.preferredMechanisms(allowSharedInode = false) ==
      @[lmReflink, lmCopy]
    let hlOnly = LinkCapability(probed: true, reflink: false, hardlink: true)
    check hlOnly.preferredMechanisms(allowSharedInode = false) == @[lmCopy]

  test "copy is always the last resort and is never absent":
    for reflink in [false, true]:
      for hardlink in [false, true]:
        let cap = LinkCapability(probed: true, reflink: reflink,
                                 hardlink: hardlink)
        let order = cap.preferredMechanisms()
        check order.len >= 1
        check order[^1] == lmCopy
        check order.count(lmCopy) == 1

suite "M0 link-capability probe — per-file limits are not pair capabilities":
  test "isPerFileFallback distinguishes a link-count limit from a pair verdict":
    check isPerFileFallback(LinkAttempt(outcome: loLinkLimitExceeded))
    check not isPerFileFallback(LinkAttempt(outcome: loCrossDevice))
    check not isPerFileFallback(LinkAttempt(outcome: loUnsupported))
    check not isPerFileFallback(LinkAttempt(outcome: loOk))

  test "exhausting the NTFS per-file link cap yields a per-file fallback":
    when defined(windows):
      var target = ""
      for vol in volumes:
        if vol.fsName == "NTFS":
          var c: LinkCapabilityCache
          if probeLinkCapabilities(c, vol.dir, vol.dir).hardlink:
            target = vol.dir
            break
      if target.len == 0:
        checkpoint("no NTFS volume with working hardlinks on this host; " &
                   "the link-cap-exhaustion arm was NOT exercised")
        check volumes.len >= 1
      else:
        let cage = target / "linkcap"
        removeDir(extendedPath(cage))
        createDir(extendedPath(cage))
        let src = cage / "src.bin"
        writeFile(extendedPath(src), "shared blob")
        var created = 0
        var final = LinkAttempt(outcome: loOk)
        while created < 4096:
          let attempt = attemptHardlink(src, cage / ("l" & $created & ".bin"))
          if attempt.outcome != loOk:
            final = attempt
            break
          created.inc
        checkpoint("NTFS accepted " & $created & " extra links, then " &
                   final.message)
        # NTFS caps a file at 1024 names. The cap must present as a
        # per-file fallback, never as a pair-level "hardlinks are
        # unavailable" verdict and never as a build error.
        check created > 0
        check created < 4096
        check final.outcome == loLinkLimitExceeded
        check isPerFileFallback(final)
        # ...and the pair capability is unchanged by it.
        var after: LinkCapabilityCache
        check probeLinkCapabilities(after, target, target).hardlink
        removeDir(extendedPath(cage))
    else:
      checkpoint("the 1024-link NTFS cap is a Windows property; not " &
                 "exercised on this platform")
      check volumes.len >= 1

suite "M0 link-capability probe — pair identity":
  test "the same filesystem yields the same key, a different one does not":
    let vol = primaryVolume()
    check filesystemPairKey(vol.dir, vol.dir) ==
      filesystemPairKey(vol.dir, vol.dir)
    if volumes.len >= 2:
      check filesystemPairKey(volumes[0].dir, volumes[0].dir) !=
        filesystemPairKey(volumes[0].dir, volumes[1].dir)
    else:
      checkpoint("only one writable volume; the distinct-key arm was NOT " &
                 "exercised")

  test "hardlinkCount reports -1 for a path that does not exist":
    let vol = primaryVolume()
    check hardlinkCount(vol.dir / "definitely-not-here.bin") == -1

suite "M0 link-capability probe — teardown":
  # Deliberately a test rather than an ``addExitProc``: under ORC the
  # exit-proc closure runs after this module's globals have been
  # destroyed, so ``scratchDirs`` is already gone by then.
  test "every scratch directory this suite created is removed":
    for d in scratchDirs:
      try:
        removeDir(extendedPath(d))
      except CatchableError, Defect:
        discard
      check not dirExists(extendedPath(d))
