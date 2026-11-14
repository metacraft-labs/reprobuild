## A static library compiled with debug info (`-g`) and
## `-ffile-prefix-map=<checkout>=.` is byte-identical in two checkouts at
## different absolute paths and contains no checkout path; without the
## prefix map the same build embeds the checkout path.
##
## Byte identity of the library's outputs is what makes sharing them across
## checkouts correct: a record served to another checkout puts the first
## checkout's bytes there, so those bytes must be the ones the second would
## have produced. Debug info is where a compiler records absolute paths (the
## compilation directory and the source file names), and the prefix map is
## the compiler's own way to rewrite them.
##
## The scan reads the DECOMPRESSED debug sections. The toolchain this suite
## runs with writes compressed `.debug_*` sections by default, so the checkout
## path is not present as plain bytes even when it is in the debug info; a
## plain `strings` scan of such an object finds nothing, with or without the
## prefix map. Each output is copied through `objcopy
## --decompress-debug-sections` and both the original and the decompressed
## copy are scanned.
##
## Each checkout builds against its own action cache with the portable
## identity off, so both builds compile (asserted: the vacuity guard), and the
## comparison is between two compiler runs, not a run and a restore of it.
##
## Negative control: the same build under `-g` without the prefix map is
## asserted to embed the checkout path in the object, which proves the scan
## can see a path. Which outputs embed it is printed, as a record.
##
## No mocks: the built `repro`, the C compiler, `ar` and `objcopy` on `PATH`,
## real Git checkouts.

import std/[os, osproc, strutils, tempfiles, unittest]

import library_cache_sharing_fixture

proc decompressedCopy(path, scratch: string): string =
  ## `path` with its debug sections decompressed, in a new file under
  ## `scratch`. `objcopy` handles an object and an archive of objects alike.
  let objcopy = findExe("objcopy")
  if objcopy.len == 0:
    raise newException(OSError, "objcopy is not on PATH; this test reads " &
      "decompressed debug sections and runs in the dev shell, which " &
      "provides it")
  let (file, copyPath) = createTempFile("decompressed-", "-" &
    extractFilename(path), scratch)
  file.close()
  let res = execCmdEx(quoteShell(objcopy) & " --decompress-debug-sections " &
    quoteShell(path) & " " & quoteShell(copyPath))
  if res.exitCode != 0:
    raise newException(OSError, "objcopy --decompress-debug-sections " &
      path & " failed (exit " & $res.exitCode & "):\n" & res.output)
  copyPath

proc embedsPath(path, needle, scratch: string): bool =
  ## Whether `needle` occurs in `path`'s bytes or in its decompressed debug
  ## sections.
  readFile(path).contains(needle) or
    readFile(decompressedCopy(path, scratch)).contains(needle)

proc buildCheckout(dest, scratchName: string; mapPrefix: bool):
    tuple[host: SharedHost; run: BuildRun] =
  var host = newSharedHost(scratchName)
  writeLibraryProject(host.scratch / dest, "debugInfoPkg", ["-O2", "-g"],
    mapPrefix = mapPrefix, greeting = "debug info")
  let run = host.build(host.scratch / dest, portable = false)
  (host: host, run: run)

suite "library outputs are path-free with debug info":
  test "with -g and -ffile-prefix-map the library's object and archive are byte-identical across checkouts and contain no checkout path":
    var (hostA, a) = buildCheckout("first/checkout",
      "repro-path-free-a-", mapPrefix = true)
    defer: cleanup(hostA)
    var (hostB, b) = buildCheckout("second/nested/deeper/checkout",
      "repro-path-free-b-", mapPrefix = true)
    defer: cleanup(hostB)
    let checkoutA = hostA.scratch / "first" / "checkout"
    let checkoutB = hostB.scratch / "second" / "nested" / "deeper" / "checkout"
    checkpoint("first checkout build, exit " & $a.code & ":\n" & a.output)
    checkpoint("second checkout build, exit " & $b.code & ":\n" & b.output)
    require a.code == 0
    require b.code == 0
    # Vacuity guard: both checkouts compiled and archived.
    for run in [a, b]:
      check run.launched(LibraryCompileEdge)
      check run.launched(LibraryArchiveEdge)
    for output in [LibraryObject, LibraryArchive]:
      check nonEmptyFile(checkoutA / output)
      check nonEmptyFile(checkoutB / output)
      check sameBytes(checkoutA / output, checkoutB / output)
      for (checkout, scratch) in [(checkoutA, hostA.scratch),
                                  (checkoutB, hostB.scratch)]:
        let found = embedsPath(checkout / output, checkout, scratch) or
          embedsPath(checkout / output, scratch, scratch)
        checkpoint(checkout / output & " embeds its checkout path: " & $found)
        check not found

  test "with -g and no prefix map the object embeds the checkout path":
    var (host, run) = buildCheckout("only/checkout",
      "repro-path-free-control-", mapPrefix = false)
    defer: cleanup(host)
    let checkout = host.scratch / "only" / "checkout"
    checkpoint("build, exit " & $run.code & ":\n" & run.output)
    require run.code == 0
    check run.launched(LibraryCompileEdge)
    check run.launched(LibraryArchiveEdge)
    var embedding: seq[string] = @[]
    for output in [LibraryObject, LibraryArchive]:
      require nonEmptyFile(checkout / output)
      if embedsPath(checkout / output, checkout, host.scratch):
        embedding.add(output)
    # The record of which outputs embed the path without the map.
    echo "outputs embedding the checkout path under -g without " &
      "-ffile-prefix-map: ", (if embedding.len == 0: "none"
                              else: embedding.join(", "))
    check LibraryObject in embedding
    check LibraryArchive in embedding
