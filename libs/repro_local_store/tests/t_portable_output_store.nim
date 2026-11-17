## The output bytes of a shareable portable record, stored on this host and
## restored, verified, in another checkout (`portable_output_store`;
## Caching-Architecture.md "Design for XPC-AREQ1", D6).
##
## The properties: a record's file and directory outputs, stored from one
## checkout, are put in place byte-identical (with their executable bits,
## symbolic links and empty directories) at the paths ANOTHER checkout's
## roots give them; storing again writes nothing; a blob whose bytes were
## altered is refused naming the output, removed, and leaves the destination
## as it was; a missing blob is refused the same way; and a refusal on the
## second output of a record writes neither output (every output is verified
## before the first destination is written); and a directory manifest with an
## entry that would be written outside its tree (a `..` component, or a path
## below a link entry) is refused before anything is written.
##
## No mocks: real files in a fresh temporary directory, the real BLAKE3
## published digests (`fileContentHex`, `treeContentHex`).

import std/[options, os, strutils, tempfiles, unittest]

import repro_core/paths
import repro_local_store/portable_fingerprint
import repro_local_store/portable_memo
import repro_local_store/portable_output_store

proc roots(project: string): seq[LogicalRoot] =
  @[LogicalRoot(label: "project", path: project, kind: lrkTracked)]

proc recordOf(project: string; outputs: openArray[string]):
    PortableMemoRecord =
  ## The record the engine would store for outputs already on disk.
  let outs = portableOutputs(roots(project), outputs)
  doAssert outs.portable, outs.reason
  newPortableMemoRecord("w", [], "s", outs.outputs, ffpChecksum,
    elComplete, MonitoredEvidence)

proc blobOf(store, content: string): string =
  ## The stored blob holding `content`, found by its bytes (the test does
  ## not trust the module's own path function to find what it wrote).
  for path in walkDirRec(store):
    if readFile(path) == content:
      return path
  ""

suite "portable output store":

  var scratch: string

  setup:
    scratch = createTempDir("repro-portable-output-store-", "")

  teardown:
    if scratch.len > 0 and dirExists(scratch):
      removeDir(scratch)

  test "file and directory outputs restore byte-identically in another checkout":
    let a = scratch / "a" / "proj"
    let b = scratch / "elsewhere" / "deeper" / "proj"
    let store = scratch / "action-cache" / PortableOutputsDirName
    createDir(a / "out" / "tree" / "sub")
    createDir(a / "out" / "tree" / "empty")
    writeFile(a / "out" / "lib.a", "archive bytes\0\1\2")
    writeFile(a / "out" / "tool", "#!/bin/sh\necho tool\n")
    setFilePermissions(a / "out" / "tool",
      {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpOthersRead})
    writeFile(a / "out" / "tree" / "sub" / "x.txt", "x")
    writeFile(a / "out" / "tree" / "y.txt", "y")
    createSymlink("sub/x.txt", a / "out" / "tree" / "link")
    let record = recordOf(a, [a / "out" / "lib.a", a / "out" / "tool",
      a / "out" / "tree"])
    let stored = storePortableOutputs(store, roots(a), record)
    check stored.reason == ""
    # lib.a, tool, x.txt and y.txt: one blob each; the link and the empty
    # directory come from the manifest.
    check stored.blobsWritten == 4
    check stored.bytesWritten > 0
    check portableOutputsStored(store, record)
    # Storing again writes nothing.
    let again = storePortableOutputs(store, roots(a), record)
    check again.reason == ""
    check again.blobsWritten == 0
    check again.blobsPresent == 4

    createDir(b)
    check restorePortableOutputs(store, roots(b), record) == ""
    check readFile(b / "out" / "lib.a") == readFile(a / "out" / "lib.a")
    check readFile(b / "out" / "tool") == readFile(a / "out" / "tool")
    check executableBit(b / "out" / "tool")
    check not executableBit(b / "out" / "lib.a")
    check treeContentHex(b / "out" / "tree") ==
      treeContentHex(a / "out" / "tree")
    check symlinkExists(b / "out" / "tree" / "link")
    check dirExists(b / "out" / "tree" / "empty")
    check outputsOnDiskReason(roots(b), record) == ""
    # No staging debris is left beside the outputs.
    for kind, path in walkDir(b / "out"):
      check ".repro-restore-" notin path

  test "an altered blob is refused, removed, and the destination is left as it was":
    let a = scratch / "a" / "proj"
    let b = scratch / "b" / "proj"
    let store = scratch / "store"
    createDir(a / "out")
    writeFile(a / "out" / "lib.a", "the recorded bytes")
    let record = recordOf(a, [a / "out" / "lib.a"])
    require storePortableOutputs(store, roots(a), record).reason == ""
    let blob = blobOf(store, "the recorded bytes")
    require blob.len > 0
    writeFile(blob, "the altered bytes!")
    createDir(b / "out")
    writeFile(b / "out" / "lib.a", "what b had")
    let why = restorePortableOutputs(store, roots(b), record)
    check why == "project:out/lib.a: digest mismatch"
    check readFile(b / "out" / "lib.a") == "what b had"
    check not fileExists(blob)
    check not portableOutputsStored(store, record)
    # The next store from a checkout holding the right bytes repairs it.
    check storePortableOutputs(store, roots(a), record).blobsWritten == 1
    check restorePortableOutputs(store, roots(b), record) == ""
    check readFile(b / "out" / "lib.a") == "the recorded bytes"

  test "a missing blob is refused naming the output":
    let a = scratch / "a" / "proj"
    let b = scratch / "b" / "proj"
    let store = scratch / "store"
    createDir(a / "out")
    writeFile(a / "out" / "lib.a", "bytes")
    let record = recordOf(a, [a / "out" / "lib.a"])
    check restorePortableOutputs(store, roots(b), record) ==
      "project:out/lib.a: not stored"
    check not fileExists(b / "out" / "lib.a")

  test "a refusal on a later output writes no earlier one":
    let a = scratch / "a" / "proj"
    let b = scratch / "b" / "proj"
    let store = scratch / "store"
    createDir(a / "out")
    writeFile(a / "out" / "a.o", "first output")
    writeFile(a / "out" / "z.o", "second output")
    let record = recordOf(a, [a / "out" / "a.o", a / "out" / "z.o"])
    require record.outputs.len == 2
    require record.outputs[0].path == "project:out/a.o"
    require storePortableOutputs(store, roots(a), record).reason == ""
    let second = blobOf(store, "second output")
    require second.len > 0
    writeFile(second, "tampered")
    createDir(b)
    check restorePortableOutputs(store, roots(b), record) ==
      "project:out/z.o: digest mismatch"
    check not fileExists(b / "out" / "a.o")
    check not fileExists(b / "out" / "z.o")
    if dirExists(b / "out"):
      for kind, path in walkDir(b / "out"):
        check ".repro-restore-" notin path

  test "a directory manifest that would write outside its tree writes nothing":
    # The tree digest can only be checked once the tree is written, so a
    # manifest entry that escapes the staging directory (a `..` component, or
    # a path below a link entry) must be refused before any write. The blob
    # each tampered entry names exists, so only the refusal keeps the bytes
    # from being written outside the tree.
    let a = scratch / "a" / "proj"
    let b = scratch / "b" / "proj"
    let outside = scratch / "outside"
    let store = scratch / "store"
    createDir(a / "out" / "tree")
    writeFile(a / "out" / "tree" / "x.txt", "tree bytes")
    let record = recordOf(a, [a / "out" / "tree"])
    require record.outputs.len == 1
    require record.outputs[0].directory
    require storePortableOutputs(store, roots(a), record).reason == ""
    let stored = record.outputs[0].entries
    var digest = ""
    for entry in stored:
      if entry.kind == tekFile: digest = entry.identity
    require digest.len == 64
    createDir(outside)
    createDir(b / "out")

    var dotdot = record
    dotdot.outputs[0].entries.add TreeEntry(rel: "../escaped.txt",
      kind: tekFile, identity: digest)
    let why = restorePortableOutputs(store, roots(b), dotdot)
    check "is not a relative path" in why
    check not fileExists(b / "out" / "escaped.txt")
    check not dirExists(b / "out" / "tree")

    var throughLink = record
    throughLink.outputs[0].entries.add TreeEntry(rel: "l",
      kind: tekLinkToDir, identity: outside)
    throughLink.outputs[0].entries.add TreeEntry(rel: "l/escaped.txt",
      kind: tekFile, identity: digest)
    let why2 = restorePortableOutputs(store, roots(b), throughLink)
    check "lies below the symbolic link" in why2
    check not fileExists(outside / "escaped.txt")
    check not dirExists(b / "out" / "tree")
    for kind, path in walkDir(b / "out"):
      check ".repro-restore-" notin path

    # The untampered record still restores.
    check restorePortableOutputs(store, roots(b), record) == ""
    check readFile(b / "out" / "tree" / "x.txt") == "tree bytes"

  test "an output that changed after its digest was taken is not stored":
    let a = scratch / "a" / "proj"
    let store = scratch / "store"
    createDir(a / "out")
    writeFile(a / "out" / "lib.a", "as recorded")
    let record = recordOf(a, [a / "out" / "lib.a"])
    writeFile(a / "out" / "lib.a", "rewritten since")
    let stored = storePortableOutputs(store, roots(a), record)
    check "changed while its bytes were being stored" in stored.reason
    check stored.blobsWritten == 0
    check blobOf(store, "rewritten since").len == 0
