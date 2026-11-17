## The archive edge is deterministic: two checkouts that compile
## byte-identical objects archive byte-identical libraries, when each
## checkout runs the archive itself.
##
## The project is `reprobuild-examples/c-cpp-mode3/binary-with-library`,
## built from two Git checkouts at different absolute paths with the
## toolchain the engine realizes into the store root
## (`--tool-provisioning=tarball`), each with its own action cache and the
## portable identity off (`REPRO_PORTABLE_CACHE=0`), so the second checkout
## cannot be served the first's archive and must run `ar` itself. The
## builds are at least a second apart, so the objects the archive reads
## carry different modification times. That GNU `ar` was built without
## deterministic archives by default: called as `ar rcs` it records each
## member's mtime, owner and group, and the two libraries differed. The
## conventions now pass `D`.
##
## Vacuity guard: both builds executed the archive edge, and their objects
## are byte-identical, so a difference in the libraries could only come
## from the archiver.
##
## Falsifying mutation (run by hand, recorded in the plan): the conventions'
## archive modifiers back to `rcs` make the two libraries differ, and the
## test fails.
##
## No mocks: the built `repro`, the realized compiler and `ar`, real Git
## checkouts.

import std/[os, unittest]

import repro_test_support
import library_cache_sharing_fixture

const
  ArchiveEdge = "ccpp-direct-archive-mathlib"
  ObjectPath = ".repro/build/mathlib/obj/add.o"
  ArchivePath = ".repro/build/mathlib/libmathlib.a"

proc exampleSource(): string =
  result = workspaceRootForRepo(ReprobuildRoot) / "reprobuild-examples" /
    "c-cpp-mode3" / "binary-with-library"
  if not fileExists(result / "repro.nim"):
    raise newException(IOError, "the c-cpp-mode3/binary-with-library " &
      "example is not at " & result & "; this test builds it from the " &
      "reprobuild-examples checkout beside this repository")

suite "an archive rebuilt in another checkout is byte-identical":
  test "two checkouts that each run ar produce the same library":
    var hostA = newSharedHost("repro-ar-determinism-a-")
    defer: cleanup(hostA)
    var hostB = newSharedHost("repro-ar-determinism-b-")
    defer: cleanup(hostB)
    let first = hostA.scratch / "first" / "binary-with-library"
    let second = hostB.scratch / "second" / "elsewhere" / "binary-with-library"
    copyCheckout(exampleSource(), first)
    copyCheckout(exampleSource(), second)

    let one = hostA.build(first, portable = false, provisioning = "tarball",
      extraEnv = [("REPRO_PORTABLE_CACHE", "0")])
    checkpoint("first build, exit " & $one.code & ":\n" & one.output)
    require one.code == 0
    sleep(1100)
    let two = hostB.build(second, portable = false, provisioning = "tarball",
      extraEnv = [("REPRO_PORTABLE_CACHE", "0")])
    checkpoint("second build, exit " & $two.code & ":\n" & two.output)
    require two.code == 0
    # Vacuity guard.
    require one.launched(ArchiveEdge)
    require two.launched(ArchiveEdge)
    require sameBytes(first / ObjectPath, second / ObjectPath)
    check nonEmptyFile(second / ArchivePath)
    check sameBytes(first / ArchivePath, second / ArchivePath)
