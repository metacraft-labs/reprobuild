## A separately compiled fail-closed gate. The graph gives this source the
## `reproShmIndexTestBootIdUnavailable` define, making the platform boot-ID
## provider return zero without changing the create/attach implementation.

import std/[os, tempfiles, unittest]

import repro_shm_index

when not defined(reproShmIndexTestBootIdUnavailable):
  {.error: "this gate must be compiled with the boot-ID-unavailable seam".}

suite "shared-memory boot identity fail-closed behavior":
  test "unavailable authoritative boot ID creates no namespace files":
    let tempRoot = createTempDir("repro-shm-no-boot-id", "")
    defer: removeDir(tempRoot)
    let cacheRoot = tempRoot / "action-cache"

    check bootId() == 0
    check not dirExists(cacheRoot)

    var creator = openShmIndex(cacheRoot, create = true)
    check not creator.available
    check not dirExists(cacheRoot)
    creator.close()

    var attacher = openShmIndex(cacheRoot, create = false)
    check not attacher.available
    check not dirExists(cacheRoot)
    attacher.close()
