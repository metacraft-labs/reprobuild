## A foreign project's DSL compile finds `shm_gset` and `shm_queue`.
##
## WHY. `repro_local_store/action_index` imports `shm_gset` directly, so every
## compile of a project's `repro.nim` reaches it through `repro_project_dsl`.
## Such a compile runs outside reprobuild's tree, where `config.nims` is not
## evaluated, and `consumerCompilePathFlags` replays its package paths. That
## replay listed neither shm package. With the environment allowlisted and no
## sibling checkout, interface extraction of any other project failed:
##
##   repro_local_store/action_index.nim(39, 8) Error: cannot open file: shm_gset
##
## (observed 2026-10-20 building reproos `unattended-iso` with reprobuild
## c89e624e54 built from a checkout).
##
## HOW. Both arms drive the real `consumerCompilePathFlags`. The first points
## the environment variables at real marker trees and expects exactly those
## directories. The second removes the variables and uses a work dir with no
## `../nim-shm-*` siblings, the shape of the allowlisted provider edge, and
## expects the source root captured when this library was built (the dev
## shell exports both), so the compile still resolves.
##
## Falsifiability: before the fix neither arm finds any `--path` holding
## `shm_gset.nim` or `shm_queue.nim`.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_test_support/reasoned_skip

proc pathsWithMarker(flags: seq[string]; marker: string): seq[string] =
  for flag in flags:
    if flag.startsWith("--path:"):
      let dir = flag["--path:".len .. ^1]
      if fileExists(dir / marker):
        result.add(dir)

const
  builtGset = static(getEnv("SHM_GSET_SRC"))
  builtQueue = static(getEnv("SHM_QUEUE_SRC"))

suite "consumer compile paths carry the shm packages":
  test "the environment variables are honoured":
    let root = createTempDir("shm-paths-", "")
    defer: removeDir(root)
    let gset = root / "gset"
    let queue = root / "queue"
    createDir(gset)
    createDir(queue)
    writeFile(gset / "shm_gset.nim", "")
    writeFile(queue / "shm_queue.nim", "")
    let savedGset = getEnv("SHM_GSET_SRC")
    let savedQueue = getEnv("SHM_QUEUE_SRC")
    putEnv("SHM_GSET_SRC", gset)
    putEnv("SHM_QUEUE_SRC", queue)
    defer:
      putEnv("SHM_GSET_SRC", savedGset)
      putEnv("SHM_QUEUE_SRC", savedQueue)
    let flags = consumerCompilePathFlags(root / "work")
    check gset in pathsWithMarker(flags, "shm_gset.nim")
    check queue in pathsWithMarker(flags, "shm_queue.nim")

  test "a scrubbed environment beside no sibling falls back to the build pin":
    if builtGset.len == 0 or builtQueue.len == 0:
      skip("this test was compiled without SHM_GSET_SRC / SHM_QUEUE_SRC, " &
           "so the library has no build pin to fall back to")
    else:
      let root = createTempDir("shm-paths-", "")
      defer: removeDir(root)
      let savedGset = getEnv("SHM_GSET_SRC")
      let savedQueue = getEnv("SHM_QUEUE_SRC")
      delEnv("SHM_GSET_SRC")
      delEnv("SHM_QUEUE_SRC")
      defer:
        putEnv("SHM_GSET_SRC", savedGset)
        putEnv("SHM_QUEUE_SRC", savedQueue)
      let flags = consumerCompilePathFlags(root / "work")
      check pathsWithMarker(flags, "shm_gset.nim").len > 0
      check pathsWithMarker(flags, "shm_queue.nim").len > 0
