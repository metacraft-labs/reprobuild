## THE DEV-ENV CACHE KEY IS A FINGERPRINT TOO.
##
## `repro_dev_env_engine/cache_key` carries its OWN copy of the frame that
## `repro_hash/policy` owns -- same magic, same `action-fingerprint` tag, same
## length fields -- because it is the prompt-time fast path and will not pull
## `gxhash` / `xxh3` into the front controller's link for a digest it never
## takes. That copy is a liability: nothing about a duplicated byte layout
## fails loudly when one half drifts. It just stops matching every dev-env
## edge cached before the drift.
##
## This file is what holds the copy to its claim. The expectations are NOT
## this module's own output replayed back at it -- they are recomputed
## through `repro_hash.casDigest(payload, hdActionFingerprint)`, a separate
## implementation of the same frame in a different library, and through a
## literal byte-by-byte rebuild of the frame in this file. Either one
## disagreeing means the two frames have diverged.
##
## The payload composition is pinned as well, not just the framing. The key
## is a digest over a specific ordered list of parts; dropping one, renaming
## one or reordering them is exactly as invalidating as moving a length
## field, and is invisible to a test that only checks the frame.
##
## NO MOCKS. Real files in a real temp directory, the shipped
## `computeDevEnvEdgeCacheKey`, and real environment variables.

import std/[os, strutils, unittest]

import repro_dev_env_engine/cache_key
import repro_hash
import blake3

const
  FrameMagic = "reprobuild.hash.v1\0"
  Tag = "action-fingerprint"
  CacheKeySchemaLiteral = "reprobuild.dev-env.cache-key.v1"

proc textBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc literalFrame(payload: openArray[byte]): seq[byte] =
  ## The frame written out longhand, with no helper shared with either
  ## implementation under test. This is the third opinion.
  result = @[]
  for ch in FrameMagic:
    result.add(byte(ord(ch)))
  result.add(byte(Tag.len and 0xff))
  result.add(byte((Tag.len shr 8) and 0xff))
  for ch in Tag:
    result.add(byte(ord(ch)))
  let n = uint64(payload.len)
  for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
    result.add(byte((n shr shift) and 0xff'u64))
  for b in payload:
    result.add(b)

proc expectedKey(payload: string): string =
  ## The key the shipped code must produce: first 16 bytes of the frame
  ## digest, lowercase hex.
  let digest = casDigest(payload.textBytes(), hdActionFingerprint).bytes
  result = newStringOfCap(32)
  for i in 0 ..< 16:
    result.add(toHex(int(digest[i]), 2).toLowerAscii())

proc fingerprintPart(path: string): string =
  if path.len == 0: return ""
  if not fileExists(path): return path & "\n<missing>"
  path & "\n" & readFile(path)

proc envPart(name: string): string =
  if existsEnv(name): name & "=" & getEnv(name)
  else: name & "=<unset>"

suite "dev-env cache key frame":

  test "the duplicated frame is the repro_hash frame":
    # Cross-library agreement over the sizes the frame's own fields move at:
    # the 2-byte tag length, the 8-byte payload length, and the BLAKE3 block
    # and chunk edges.
    for n in [0, 1, 2, 63, 64, 65, 127, 128, 129, 1023, 1024, 1025,
              4095, 4096, 4097, 65535, 65536, 65537]:
      var payload = newSeq[byte](n)
      for i in 0 ..< n:
        payload[i] = byte((i * 31 + 13) and 0xff)
      let viaPolicy = blake3.toHex(casDigest(payload, hdActionFingerprint).bytes)
      let viaLiteral = blake3.toHex(blake3.digest(literalFrame(payload)))
      check viaPolicy == viaLiteral

  test "the empty payload is framed, not skipped":
    check blake3.toHex(casDigest(@[], hdActionFingerprint).bytes) !=
      blake3.toHex(blake3.digest(newSeq[byte](0)))
    check blake3.toHex(blake3.digest(literalFrame([]))) ==
      blake3.toHex(casDigest(@[], hdActionFingerprint).bytes)

  test "computeDevEnvEdgeCacheKey digests the documented part list":
    # Rebuilds the payload the shipped proc must be hashing, from a project
    # tree on the real filesystem, and checks the shipped key against it.
    # Both the framing AND the ordered part list are pinned by this.
    let root = getTempDir() / "t_dev_env_cache_key_frame" / "proj"
    removeDir(parentDir(root))
    createDir(root)
    createDir(root / ".repro")
    defer: removeDir(parentDir(root))

    writeFile(root / "repro.nim", "# project file\nexecutable demo\n")
    writeFile(root / ".repro" / "dev-env.lock", "lock-slice-body\n")
    let overrides = root / "overrides.json"
    writeFile(overrides, "{\"k\":1}\n")

    putEnv("REPRO_DEVELOP_OVERRIDES_FILE", "/some/where")
    delEnv("REPRO_TOOL_PROVISIONING")
    defer: delEnv("REPRO_DEVELOP_OVERRIDES_FILE")

    for activity in ["", "build", "shell"]:
      for lockSliceId in ["", "slice-1"]:
        let effectiveActivity = if activity.len > 0: activity else: "default"
        let parts = @[
          CacheKeySchemaLiteral,
          "projectRoot=" & root,
          "projectFile=" & fingerprintPart(root / "repro.nim"),
          "activity=" & effectiveActivity,
          "lockSliceId=" & lockSliceId,
          "lockSliceFile=" & fingerprintPart(root / ".repro" / "dev-env.lock"),
          "developOverrides=" &
            fingerprintPart(os.normalizedPath(absolutePath(overrides))),
          envPart("REPRO_DEVELOP_OVERRIDES_FILE"),
          envPart("REPRO_TOOL_PROVISIONING")
        ]
        check computeDevEnvEdgeCacheKey(root, activity, lockSliceId,
          overrides) == expectedKey(parts.join("\n"))

  test "the key moves when any input moves":
    # A key that ignores an input is worse than no cache: it serves the
    # previous decision's artifact after the decision changed.
    let root = getTempDir() / "t_dev_env_cache_key_frame_vary" / "proj"
    removeDir(parentDir(root))
    createDir(root)
    createDir(root / ".repro")
    defer: removeDir(parentDir(root))
    writeFile(root / "repro.nim", "original\n")
    writeFile(root / ".repro" / "dev-env.lock", "lock-a\n")
    let overrides = root / "overrides.json"
    writeFile(overrides, "{}\n")
    delEnv("REPRO_DEVELOP_OVERRIDES_FILE")
    delEnv("REPRO_TOOL_PROVISIONING")

    var seen: seq[string]
    proc note(k: string) =
      check k.len == 32
      check k notin seen
      seen.add(k)

    note(computeDevEnvEdgeCacheKey(root, "build", "s1", overrides))
    note(computeDevEnvEdgeCacheKey(root, "shell", "s1", overrides))
    note(computeDevEnvEdgeCacheKey(root, "build", "s2", overrides))
    writeFile(root / "repro.nim", "edited\n")
    note(computeDevEnvEdgeCacheKey(root, "build", "s1", overrides))
    writeFile(root / ".repro" / "dev-env.lock", "lock-b\n")
    note(computeDevEnvEdgeCacheKey(root, "build", "s1", overrides))
    writeFile(overrides, "{\"x\":2}\n")
    note(computeDevEnvEdgeCacheKey(root, "build", "s1", overrides))
    putEnv("REPRO_TOOL_PROVISIONING", "on")
    note(computeDevEnvEdgeCacheKey(root, "build", "s1", overrides))
    delEnv("REPRO_TOOL_PROVISIONING")
