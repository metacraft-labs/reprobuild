## `repro store copy` through the built CLI, on real temporary store roots.
## No mocks: the source prefix is realized by the production store and the
## copy is run by `build/bin/repro`.
##
## What it pins at the CLI boundary: the `copy` subcommand is dispatched,
## the source resolves from `--store-root`, `--json` reports what moved, a
## repeated copy moves nothing, a damaged source fails with exit 1 and
## writes nothing, and a missing `--to` is a usage error. The copy rules
## themselves are pinned by `libs/repro_local_store/tests/t_store_copy.nim`.

import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_local_store/store
from repro_test_support import requireBinary
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc findReproRepoRoot(): string =
  var current = getAppFilename().parentDir
  for _ in 0 .. 8:
    if dirExists(current / "libs") and
        fileExists(current / "apps" / "repro" / "repro.nim"):
      return current
    let p = current.parentDir
    if p == current: break
    current = p
  ""

proc reproBinary(): string =
  let root = findReproRepoRoot()
  doAssert root.len > 0, "could not locate the reprobuild repo root"
  requireBinary(root / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc run(args: openArray[string]): tuple[output: string, exitCode: int] =
  execCmdEx(args.mapIt(q(it)).join(" ") & " 2>/dev/null")

proc runAll(args: openArray[string]): tuple[output: string, exitCode: int] =
  execCmdEx(args.mapIt(q(it)).join(" ") & " 2>&1")

suite "repro store copy CLI":
  test "copy, re-copy, damaged source, usage":
    when defined(windows):
      skip("store copy is POSIX-only; the CLI refuses it on Windows")
    else:
      let repro = reproBinary()
      let top = createTempDir("repro-store-copy-cli-", "")
      defer: removeDir(top)
      let src = top / "src"
      let dst = top / "dst"
      let staging = top / "staging"
      createDir(staging / "bin")
      writeFile(staging / "bin" / "probe", "probe\n")
      var s = openStore(src)
      let realized = s.realizeDirectoryAsPrefix(staging, StoreReceiptHint(
        adapter: "path", packageName: "probe", version: "1.0",
        lockIdentity: "cli-test"))
      s.close()
      let rel = realized.relativePath

      let first = run([repro, "store", "copy", rel, "--to=" & dst,
        "--store-root=" & src, "--json"])
      checkpoint first.output
      check first.exitCode == 0
      let r = parseJson(first.output)
      check r["copied"].getElems().mapIt(it.getStr()) == @[rel]
      check r["destinationStoreRoot"].getStr() == dst
      check readFile(dst / rel / ReceiptFileName) ==
        readFile(src / rel / ReceiptFileName)

      let again = run([repro, "store", "copy", rel, "--to=" & dst,
        "--store-root=" & src, "--json"])
      check again.exitCode == 0
      let a = parseJson(again.output)
      check a["copied"].len == 0
      check a["alreadyPresent"].getElems().mapIt(it.getStr()) == @[rel]

      let fresh = top / "fresh"
      removeFile(src / rel / "bin" / "probe")
      let damaged = runAll([repro, "store", "copy", rel, "--to=" & fresh,
        "--store-root=" & src])
      checkpoint damaged.output
      check damaged.exitCode == 1
      check "content does not match" in damaged.output
      check not dirExists(fresh / rel)

      let usage = runAll([repro, "store", "copy", rel, "--store-root=" & src])
      check usage.exitCode == 2
      check "--to=STORE-ROOT is required" in usage.output
