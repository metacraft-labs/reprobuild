## A per-output realization id covers every property of the output's tree
## that the published prefix carries: a file's executable bit and a symbolic
## link's target text, not only regular-file content.
##
## Issue: reprobuild-pm
## issues/2026-11-12-the-realization-hash-envelope-omits-the-recipe-itself-runtimedeps-and-environment-values.md
## (the realization envelope must determine the prefix's bytes;
## spec/Local-Content-Addressed-Store.md §"Realization Hash (normative)",
## "Output-addressed").
##
## ``realizeMultiOutput`` keys each output on a digest of its staging tree.
## When that digest saw only regular-file bytes, two builds whose ``bin``
## output differed only in an exec bit, or in where a link points, got ONE
## per-output id, and the index row for it made the second realize return the
## first build's prefix. Each case realizes through the store API against a
## real temp store and asserts distinct ids plus the second tree's property in
## the second prefix. No mocks.

import std/[os, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_local_store

proc realizeBin(store: var Store; dir: string): PerOutputRealize =
  let hint = StoreReceiptHint(adapter: "path", packageName: "pkg",
    version: "1.0", lockIdentity: "same-lock")
  realizeMultiOutput(store, hint,
    @[MultiOutputSpec(outputName: "bin", stagingDir: dir)]).perOutput[0]

when not defined(windows):
  suite "multi-output realization id covers modes and links":

    test "an exec-bit-only difference yields a distinct output prefix":
      let scratch = createTempDir("repro-mo-mode-", "")
      defer:
        try: removeDir(extendedPath(scratch)) except OSError: discard
      var store = openStore(scratch / "store")
      defer: store.close()
      for name in ["a", "b"]:
        createDir(scratch / name / "bin")
        writeFile(scratch / name / "bin" / "tool", "#!/bin/sh\n")
      var p = getFilePermissions(scratch / "b" / "bin" / "tool")
      p.incl(fpUserExec)
      setFilePermissions(scratch / "b" / "bin" / "tool", p)
      let first = realizeBin(store, scratch / "a")
      let second = realizeBin(store, scratch / "b")
      check first.prefixId != second.prefixId
      check fpUserExec in getFilePermissions(
        second.absolutePath / "bin" / "tool")

    test "a link re-pointed at a byte-identical sibling is distinct":
      let scratch = createTempDir("repro-mo-link-", "")
      defer:
        try: removeDir(extendedPath(scratch)) except OSError: discard
      var store = openStore(scratch / "store")
      defer: store.close()
      for (name, target) in [("a", "libfoo.so.1"), ("b", "libfoo.so.2")]:
        createDir(scratch / name / "lib")
        writeFile(scratch / name / "lib" / "libfoo.so.1", "same bytes\n")
        writeFile(scratch / name / "lib" / "libfoo.so.2", "same bytes\n")
        createSymlink(target, scratch / name / "lib" / "libfoo.so")
      let first = realizeBin(store, scratch / "a")
      let second = realizeBin(store, scratch / "b")
      check first.prefixId != second.prefixId
      check expandSymlink(second.absolutePath / "lib" / "libfoo.so") ==
        "libfoo.so.2"
