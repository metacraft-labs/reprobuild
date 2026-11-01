## The compressed form of a publish payload is created exclusively, and is
## only chosen when it decompresses to the archive that was pinned.
##
## Found by the independent review of `--publish` (2026-11-01):
## `publishInProcess` compressed the archive to `<archive>.zst` with a plain
## `open(fmWrite)` -- following whatever already sat at that path, a symlink
## included -- discarded `writeBuffer`'s count, so a short write left a
## truncated frame, and signed and uploaded the result without checking that
## it still decompressed to the bytes `expectedOutputDigest` pins.
##
## Real files and the real libzstd; no mocks. Skipped with a stated reason
## only where libzstd cannot be loaded (`supportsCompressor`), which a gate
## run (`REPROBUILD_GATE_RUN=1`) turns into a failure.

import std/[os, strutils, tempfiles, unittest]

import blake3
import repro_binary_cache_server/types as bcsTypes
import repro_binary_cache_client/compress
import repro_binary_cache_client/in_process
import repro_test_support/reasoned_skip

template withZstd(body: untyped) =
  if supportsCompressor(bcsTypes.ckZstd):
    body
  elif getEnv("REPROBUILD_GATE_RUN") == "1":
    checkpoint("libzstd cannot be loaded in a gate run")
    check false
  else:
    skip("libzstd cannot be loaded on this host")

proc digestOf(path: string): Blake3Digest =
  var h = initHasher()
  defer: h.close()
  h.update(readFile(path))
  h.finalize()

suite "the compressed publish payload":

  test "an existing file at the destination is refused, not overwritten":
    withZstd:
      let dir = createTempDir("publish-zst-", "")
      defer: removeDir(dir)
      writeFile(dir / "a.rbcarc", repeat("payload ", 4096))
      writeFile(dir / "a.rbcarc.zst", "someone else's file")
      expect CompressError:
        discard compressFileToFile(dir / "a.rbcarc", dir / "a.rbcarc.zst",
          bcsTypes.ckZstd)
      check readFile(dir / "a.rbcarc.zst") == "someone else's file"

  when defined(posix):
    test "a symlink planted at the destination is not written through":
      withZstd:
        let dir = createTempDir("publish-zst-", "")
        defer: removeDir(dir)
        writeFile(dir / "a.rbcarc", repeat("payload ", 4096))
        writeFile(dir / "victim", "do not touch")
        createSymlink(dir / "victim", dir / "a.rbcarc.zst")
        expect CompressError:
          discard compressFileToFile(dir / "a.rbcarc", dir / "a.rbcarc.zst",
            bcsTypes.ckZstd)
        check readFile(dir / "victim") == "do not touch"

  test "a payload is accepted only if it decompresses to the pinned bytes":
    withZstd:
      let dir = createTempDir("publish-zst-", "")
      defer: removeDir(dir)
      let raw = dir / "a.rbcarc"
      writeFile(raw, repeat("payload ", 4096))
      let zst = dir / "a.rbcarc.zst"
      discard compressFileToFile(raw, zst, bcsTypes.ckZstd)
      check zstdFileDecompressesTo(zst, digestOf(raw))
      # The pin of other bytes.
      var other = digestOf(raw)
      other[0] = other[0] xor 1
      check not zstdFileDecompressesTo(zst, other)
      # A corrupted frame: one byte flipped in the middle.
      var bytes = readFile(zst)
      bytes[bytes.len div 2] = char(uint8(bytes[bytes.len div 2]) xor 0x55)
      writeFile(zst, bytes)
      check not zstdFileDecompressesTo(zst, digestOf(raw))
      # A truncated frame, as a short write would leave.
      writeFile(zst, readFile(zst)[0 ..< 16])
      check not zstdFileDecompressesTo(zst, digestOf(raw))
