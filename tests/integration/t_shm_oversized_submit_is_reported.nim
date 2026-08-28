## A record the shared-memory cache tier refuses must SAY SO.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The test drives the real `runBuild` scheduler, the real `ActionCache`
## with the real POSIX shared-memory index attached (an explicit
## `actionCacheRoot` is what attaches it), a real subprocess and real
## files in real temporary directories. The defect is a missing
## diagnostic on a real rejection path, so the rejection has to be the
## real one; a fake shm tier would decide nothing and report nothing.
##
## The defect: `submitToShm` (`repro_local_store`) drops any record whose
## ENCODED form exceeds `SlotInlineCap` (256 B) and says nothing at all.
## The encoded size is dominated by absolute path strings, so whether the
## shared-memory tier carries any traffic at all is a function of how
## long the checkout / temp path happens to be. Measured on the
## pre-fix tree, one one-edge graph:
##
##   rootLen=19    encodedBytes=173   submitted; the daemon republishes
##   rootLen=104   encodedBytes=258   dropped; nothing is ever submitted
##
## About one byte per character of root, with the cliff around 102
## characters. A developer in a deep checkout gets no shm tier and no way
## to find out — and this has already cost real time: two agents on one
## branch got opposite results from the same test because one had a
## 35-character temp root and the other about 104.
##
## The property: the drop must be visible from outside the process, and
## must NOT be announced when nothing was dropped. Both halves are
## required — a diagnostic that is always printed is as useless as one
## that never is.
##
## The stderr capture below is a real `dup2(2)` of the process's own
## file descriptor 2, not an injected sink: what the test reads is
## exactly the bytes production writes.

import std/[os, posix, strutils, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_local_store
import repro_shm_index

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("shm-oversized-submit." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

type Capture = object
  savedFd: cint
  path: string

proc beginCapture(path: string): Capture =
  stderr.flushFile()
  let saved = dup(2)
  let fd = posix.open(path.cstring,
    O_WRONLY or O_CREAT or O_TRUNC, 0o644.Mode)
  doAssert fd >= 0, "could not open " & path
  discard dup2(fd, 2)
  discard close(fd)
  Capture(savedFd: saved, path: path)

proc endCapture(c: Capture): string =
  stderr.flushFile()
  discard dup2(c.savedFd, 2)
  discard close(c.savedFd)
  readFile(c.path)

proc buildUnder(root: string): tuple[encodedBytes: int; stderrText: string] =
  ## Run one cacheable edge with the shm tier attached (an explicit
  ## `actionCacheRoot` is what attaches it) and report both the encoded
  ## record size and everything production wrote to stderr while doing it.
  let workRoot = root / "work"
  let cacheRoot = root / "cache"
  let actionCacheRoot = root / "acr"
  createDir(workRoot / "src")
  createDir(actionCacheRoot)
  writeFile(workRoot / "src" / "i.txt", "payload\n")

  let copy = builtinAction(bakCopyFile, "shmsize/copy",
    cwd = workRoot,
    inputs = ["src/i.txt"],
    outputs = ["out/c.txt"],
    cacheable = true,
    weakFingerprint = weak(root),
    actionCachePolicy = ffpTimestamp,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

  var config = defaultBuildEngineConfig(cacheRoot, actionCacheRoot)
  config.rebuildMissingOutputsOnCacheHit = true
  config.deferLocalOutputBlobs = true
  config.bypassRunQuota = true
  config.maxParallelism = 1'u32

  let capture = beginCapture(root / "stderr.txt")
  var built: BuildRunResult
  try:
    built = runBuild(graph([copy]), config)
  finally:
    result.stderrText = endCapture(capture)
  doAssert built.byId("shmsize/copy").status == asSucceeded

  var probe = openActionCache(actionCacheRoot / "action-cache",
    attachShm = false)
  for record in probe.loadPerEdgeRecords(copy.weakFingerprint):
    result.encodedBytes = max(result.encodedBytes,
      encodeActionResultRecord(record).len)

# Load-bearing fragments of the diagnostic. Deliberately not the whole
# sentence: the wording may be improved, the facts may not disappear.
const DiagnosticMarkers = [
  "shared-memory",
  "inline slot cap",
]

proc mentionsOversizedDrop(text: string): bool =
  for marker in DiagnosticMarkers:
    if marker notin text:
      return false
  true

suite "an oversized shm submit is reported, and a fitting one is not":

  test "a record over the inline slot cap is announced; one under it is not":
    when not shmIndexSupported:
      checkpoint("shared-memory index unsupported on this host; the drop " &
        "path under test does not exist here")
      skip()
    else:
      # SHORT root: the encoded record fits the inline slot, so the submit
      # goes through and nothing should be said about it.
      let shortRoot = "/tmp/rbshm-" & $getCurrentProcessId()
      removeDir(shortRoot)
      createDir(shortRoot)
      defer: removeDir(shortRoot)

      # LONG root: same graph, same edge, ONLY the path length differs.
      let deepParent = createTempDir("repro-shm-oversized-", "")
      defer: removeDir(deepParent)
      let longRoot = deepParent / repeat("d", 40) / repeat("e", 40) /
        repeat("f", 40)
      createDir(longRoot)

      let small = buildUnder(shortRoot)
      let large = buildUnder(longRoot)

      checkpoint("short root (" & $shortRoot.len & " chars): encoded " &
        $small.encodedBytes & " B, cap " & $SlotInlineCap & " B")
      checkpoint("long root (" & $longRoot.len & " chars): encoded " &
        $large.encodedBytes & " B, cap " & $SlotInlineCap & " B")

      # Non-vacuity: if the two roots did not actually land on opposite
      # sides of the cap, this test can say nothing — so say THAT rather
      # than pass.
      check small.encodedBytes > 0
      check small.encodedBytes <= SlotInlineCap
      check large.encodedBytes > SlotInlineCap

      checkpoint("long-root stderr: " & large.stderrText.strip())
      checkpoint("short-root stderr: " & small.stderrText.strip())

      # THE PROPERTY, both halves.
      check mentionsOversizedDrop(large.stderrText)
      check not mentionsOversizedDrop(small.stderrText)
