## An input the volatile-path fold keeps under `/dev` is never left out of a
## portable key as untracked.
##
## The portable roots name the untracked `/dev` system root, so a path under
## it is left out of the portable fingerprint. The volatile-path fold KEEPS
## some paths there: the project's own files when the project is on
## `/dev/shm`, and any file in a directory under `/dev/shm`. A tracked root
## claims the first when it is declared there (longest root wins). Nothing
## claims a project reached through a SYMLINK whose resolved spelling is on
## `/dev/shm`: the fold keeps those reads (its scope holds both spellings of
## every root), while the portable roots carry the declared spelling only.
## Left out of the key, a change to such a file would be served from the
## portable memo. The record is non-portable instead, as one with an input
## outside every root is.
##
## WHAT IS GRADED, through the whole engine (real `runBuild`, real files on
## the real `/dev/shm` tmpfs, the real portable fingerprint):
##   * the project reached through a symlink into `/dev/shm`: the edge runs,
##     its local record carries the resolved-spelling read, and its portable
##     fingerprint is unavailable, naming the path;
##   * NOT VACUOUS: the same project declared at its `/dev/shm` spelling is
##     portable, its read named by the project root.
##
## The one synthetic input is the monitor capture, a literal io-mon record
## stream (the shape `t_pattern_scoped_enumeration_keys_only_matching_entries`
## uses): what is graded is what the engine does with the reads, not how the
## monitor reports them. Skip rule: Linux with a writable `/dev/shm`.

import std/[os, strutils, tempfiles, unittest]

from repro_test_support import testCaseScratchSlug
import repro_test_support/reasoned_skip

import repro_build_engine
import repro_core
import repro_local_store
import io_mon/[capabilities, types, writer]

let TmpDir = absolutePath(
  "build/test-tmp/t_an_input_kept_under_dev_shm-" & testCaseScratchSlug())

const EdgeId = "t-shm-edge"

proc writeCapture(path: string; records: seq[MonitorRecord]) =
  let raw = encodeCanonical(profileRecords(defaultHooksMonitorProfile()) &
    records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

proc devShmUsable(): bool =
  try:
    removeDir(createTempDir("repro-probe-", "", "/dev/shm"))
    true
  except CatchableError, OSError:
    false

proc buildOnce(declaredProject, resolvedProject, scratch: string):
    ActionResult =
  ## One edge whose cwd is `declaredProject`; the monitor reports its read
  ## and its listing of the project root under `resolvedProject`, the
  ## spelling the kernel reports for a cwd reached through a symlink.
  createDir(scratch)
  let capture = scratch / "edge.rdep"
  writeCapture(capture, @[
    MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
      osPid: 4242, threadId: 4242,
      path: resolvedProject / "src" / "input.txt"),
    MonitorRecord(kind: mrDirectoryEnumerate,
      observationKind: moDirectoryEnumerate,
      osPid: 4242, threadId: 4242, path: resolvedProject)])
  var edge = builtinAction(bakWriteText, EdgeId, cwd = declaredProject,
    outputs = [scratch / "work" / "out.txt"],
    text = "built\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  edge.monitorDepfile = capture
  var config = defaultBuildEngineConfig(scratch / "cache")
  config.maxParallelism = 1
  config.actionCacheRoot = scratch / "shared"
  config.filesystemRoots = declaredFilesystemRoots(declaredProject,
    scratch / "work")
  config.portableRoots = config.filesystemRoots
  let run = runBuild(graph(@[edge], newSeq[BuildPool]()), config)
  for item in run.results:
    if item.id == EdgeId:
      checkpoint(item.id & ": " & $item.status & " portable=" &
        $item.portable & " reason=" & item.portableReason)
      return item
  raise newException(KeyError, "no result for " & EdgeId)

suite "an input kept under /dev/shm is never left out of a portable key":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "a project reached through a symlink into /dev/shm is not portable":
    if not defined(linux) or not devShmUsable():
      skip("needs Linux and a writable /dev/shm; this case keeps a project " &
        "on that tmpfs")
    else:
      let shm = createTempDir("repro-portable-shm-", "", "/dev/shm")
      defer: removeDir(shm)
      let resolved = shm / "proj"
      createDir(resolved / "src")
      writeFile(resolved / "src" / "input.txt", "input v1\n")
      let link = TmpDir / "proj"
      createSymlink(resolved, link)
      let item = buildOnce(link, resolved, TmpDir / "symlinked")
      check item.launched
      check item.status == asSucceeded
      check not item.portable
      check (resolved / "src" / "input.txt") in item.portableReason or
        resolved in item.portableReason

  test "the same project declared at its /dev/shm spelling is portable":
    if not defined(linux) or not devShmUsable():
      skip("needs Linux and a writable /dev/shm; this case keeps a project " &
        "on that tmpfs")
    else:
      let shm = createTempDir("repro-portable-shm-", "", "/dev/shm")
      defer: removeDir(shm)
      let resolved = shm / "proj"
      createDir(resolved / "src")
      writeFile(resolved / "src" / "input.txt", "input v1\n")
      let item = buildOnce(resolved, resolved, TmpDir / "direct")
      check item.launched
      check item.status == asSucceeded
      check item.portable
      check item.portableReason.len == 0
