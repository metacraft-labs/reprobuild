## The library-source fingerprint memo: reused while stamps hold, never after
## the sources move.
##
## `reproLibSourceFingerprint` keys every provider compile, and every dev-env
## entry computes it before its first cache lookup. Hashing reprobuild's whole
## `libs/` tree was 75% of the CPU of a fully warm `repro exec` (measured with
## `perf`, 2026-09-29). With a memo directory set, the digest is reused while
## every source's (path, kind, size, mtime) stamp is unchanged, which is the
## same stamp check `ProviderFreshnessCacheRecord.reproLibStamps` already
## applies to the same files.
##
## Each direction is asserted with an instrument that can tell the two answers
## apart. A test that only checked "the digest is stable" would pass whether
## or not the memo was consulted.
##
##   * REUSE: the recorded digest is replaced with a sentinel that no hash can
##     produce, and a call with unchanged stamps must return the sentinel.
##   * INVALIDATION: after a source changes (content and stamp), the call must
##     return the digest of the NEW bytes, which differs from both the old
##     digest and the sentinel.
##   * NO MEMO BY DEFAULT: a process that never opted in must hash, so it
##     ignores a planted sentinel.
##
## MOCKS: none. Real files in a temporary directory, the real fingerprint and
## the real memo file. The fixture is laid out as a reprobuild tree (it has
## `libs/repro_project_dsl/src/repro_project_dsl.nim`) so that
## `reproLibSources` walks only the fixture and never the checkout running the
## test.

import std/[os, strutils, tempfiles, times, unittest]

import repro_core/codec
import repro_interface_artifacts

proc writeSource(root, rel, content: string) =
  let path = root / rel
  createDir(parentDir(path))
  writeFile(path, content)

proc makeTree(): string =
  result = createTempDir("repro-lib-fp-memo-", "")
  writeSource(result, "libs/repro_project_dsl/src/repro_project_dsl.nim",
    "proc dsl*() = discard\n")
  writeSource(result, "libs/other/src/other.nim", "const x* = 1\n")

proc memoFile(memoDir: string): string =
  for kind, path in walkDir(memoDir):
    if kind == pcFile and path.endsWith(".rbsz"):
      return path
  ""

proc plantSentinel(memoPath, sentinel: string) =
  ## Rewrite the recorded digest in place, keeping the recorded stamps, so a
  ## later call can only return `sentinel` by trusting the memo.
  let bytes = toBytes(readFile(memoPath))
  var pos = 0
  var rebuilt: seq[byte] = @[]
  rebuilt.writeString(readString(bytes, pos))        # schema
  let stampsStart = pos
  let count = int(readU32Le(bytes, pos))
  for _ in 0 ..< count:
    discard readString(bytes, pos)                   # path
    inc pos                                          # kind (one byte)
    discard readU64Le(bytes, pos)                    # size
    discard readU64Le(bytes, pos)                    # mtime
  for i in stampsStart ..< pos:
    rebuilt.add(bytes[i])
  rebuilt.writeString(sentinel)
  writeFile(memoPath, fromBytes(rebuilt))

const Sentinel = "memo-sentinel-not-a-hash"

suite "repro lib source fingerprint memo":
  test "the memo is reused while every source stamp is unchanged":
    let tree = makeTree()
    defer: removeDir(tree)
    let memoDir = tree / "memo"
    setReproLibFingerprintMemoDir(memoDir)
    defer: setReproLibFingerprintMemoDir("")

    let first = frontendRuntimeIdentity(tree)
    check first.len == 64
    let memoPath = memoFile(memoDir)
    check memoPath.len > 0
    plantSentinel(memoPath, Sentinel)
    check frontendRuntimeIdentity(tree) == Sentinel

  test "a changed source is re-hashed, never served from the memo":
    let tree = makeTree()
    defer: removeDir(tree)
    let memoDir = tree / "memo"
    setReproLibFingerprintMemoDir(memoDir)
    defer: setReproLibFingerprintMemoDir("")

    let before = frontendRuntimeIdentity(tree)
    plantSentinel(memoFile(memoDir), Sentinel)
    let source = tree / "libs/other/src/other.nim"
    writeFile(source, "const x* = 2\n")
    # Same size as the old content, so SIZE alone cannot tell them apart; pin
    # the mtime forward so the stamp moves by mtime.
    setLastModificationTime(source, getTime() + initDuration(seconds = 5))

    let after = frontendRuntimeIdentity(tree)
    check after != Sentinel
    check after != before
    # And it is the digest of the new bytes: a process with no memo agrees.
    setReproLibFingerprintMemoDir("")
    check frontendRuntimeIdentity(tree) == after

  test "without a memo directory the fingerprint always hashes":
    let tree = makeTree()
    defer: removeDir(tree)
    let memoDir = tree / "memo"
    setReproLibFingerprintMemoDir(memoDir)
    let hashed = frontendRuntimeIdentity(tree)
    plantSentinel(memoFile(memoDir), Sentinel)
    setReproLibFingerprintMemoDir("")
    check frontendRuntimeIdentity(tree) == hashed

  test "the source scope shares one walk and ends with the computation":
    # Inside one dev-env computation the libs tree is walked and stat-ed once
    # and shared. The scope must END with the computation: a long-lived
    # session that reused the list across computations would miss every edit
    # made between them.
    let tree = makeTree()
    defer: removeDir(tree)
    let memoDir = tree / "memo"
    setReproLibFingerprintMemoDir(memoDir)
    defer: setReproLibFingerprintMemoDir("")

    beginReproLibSourcesScope()
    let inScope = frontendRuntimeIdentity(tree)
    let source = tree / "libs/other/src/other.nim"
    writeFile(source, "const x* = 3\n")
    setLastModificationTime(source, getTime() + initDuration(seconds = 7))
    # Same computation: the shared stamps are reused (the stated trade).
    check frontendRuntimeIdentity(tree) == inScope
    endReproLibSourcesScope()

    # Next computation: the move is seen and the new bytes are hashed.
    let next = frontendRuntimeIdentity(tree)
    check next != inScope
    setReproLibFingerprintMemoDir("")
    check frontendRuntimeIdentity(tree) == next
