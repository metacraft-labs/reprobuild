## `repro store closure | export | import` through the built CLI
## (docs/store-bundles.md §7), on a real temporary store and action cache.
## No mocks: the records are written by the production action-cache API, and
## the bundle is produced and consumed by `build/bin/repro` with GNU tar and
## zstd.
##
## What it pins at the CLI boundary:
##   * the roots resolve from `--store-root` / `--action-cache-root` exactly
##     as `repro build` resolves them, and `closure` reports the bundle;
##   * `export` writes the manifest and parts, `import` restores the
##     outputs and re-witnesses the record (exit 0), and a second import is
##     a verified no-op;
##   * `import` into different roots exits 1, says why, and writes nothing.
##
## The full source-build round trip (a from-source producer, a wiped
## machine, an offline rebuild that runs nothing) needs the recipe
## toolchains and is exercised by the library test
## `libs/repro_local_store/tests/t_store_bundle_roundtrip.nim` plus the
## end-to-end procedure recorded in docs/store-bundles.md §10.

import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_hash
import repro_local_store
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

proc weakOf(name: string): ContentDigest =
  var bytes = newSeq[byte](name.len)
  for i, ch in name:
    bytes[i] = byte(ord(ch))
  blake3DomainDigest(bytes, hdActionFingerprint)

proc run(args: openArray[string]): tuple[output: string, exitCode: int] =
  execCmdEx(args.mapIt(q(it)).join(" ") & " 2>&1")

suite "repro store bundle CLI":
  test "closure, export, import, re-import, refusal":
    when defined(windows):
      skip("store bundles are POSIX-only; the CLI refuses them on Windows")
    else:
      if findExe("tar").len == 0 or findExe("zstd").len == 0:
        skip("GNU tar and zstd are not on PATH; bundles are written with them")
      else:
        let repro = reproBinary()
        let top = createTempDir("repro-store-bundle-cli-", "")
        defer: removeDir(top)
        let storeRoot = top / "store"
        let cacheRoot = top / "cache"
        let ws = top / "ws"
        let outDir = top / "out"
        createDir(ws / "src")
        createDir(ws / ".repro" / "output")
        writeFile(ws / "src" / "in.txt", "in\n")
        writeFile(ws / ".repro" / "output" / "out.txt", "out\n")
        block:
          var cache = openActionCache(cacheRoot / "action-cache",
            attachShm = false)
          var cas = openStore(cacheRoot)
          discard cache.recordActionResult(cas, weakOf("cli"), ffpTimestamp,
            [ws / "src" / "in.txt"], [ws / ".repro" / "output" / "out.txt"],
            storeOutputBlobs = false)
          cas.close()
          cache.closeShmTier()
        let common = @["--store-root=" & storeRoot,
          "--action-cache-root=" & cacheRoot]

        let closure = run(@[repro, "store", "closure", "--root=" & ws,
          "--json"] & common)
        check closure.exitCode == 0
        let c = parseJson(closure.output)
        check c["records"].getInt() == 1
        check c["restamps"].getInt() == 1
        check c["roots"]["storeRoot"].getStr() == storeRoot

        let exported = run(@[repro, "store", "export", "--root=" & ws,
          "--out=" & outDir, "--zstd-level=1"] & common)
        checkpoint exported.output
        check exported.exitCode == 0
        check fileExists(outDir / "native-store.json")
        check fileExists(outDir / "part-0000")

        removeDir(cacheRoot)
        removeDir(ws / ".repro")
        let imported = run(@[repro, "store", "import", outDir, "--json"] &
          common)
        checkpoint imported.output
        check imported.exitCode == 0
        let r = parseJson(imported.output)
        check r["rewitnessedRecords"].getInt() == 1
        check readFile(ws / ".repro" / "output" / "out.txt") == "out\n"

        let again = run(@[repro, "store", "import", outDir, "--json"] & common)
        check again.exitCode == 0
        check parseJson(again.output)["skippedExtraction"].getBool()

        let refused = run(@[repro, "store", "import", outDir,
          "--store-root=" & top / "elsewhere",
          "--action-cache-root=" & cacheRoot])
        check refused.exitCode == 1
        check "different absolute paths" in refused.output
        check not dirExists(top / "elsewhere" / "bundles")
