## ``repro_multihash`` — self-describing, algorithm-tagged content digests
## (Workspace-Manifest-Optional MO-8).
##
## The integrity value attached to every locked dependency is a
## **self-describing multihash** of the form ``<alg>:<digest>`` (the
## libp2p-multihash / Nix-SRI approach), so Reprobuild can evolve its hash
## functions without breaking the lock format. The leading ``<alg>`` token
## names the algorithm; ``<digest>`` is the lowercase hex digest.
##
## Registered algorithm codes (Workspace-Manifests.md §"Self-describing
## integrity (multihash)"):
##
## - ``git-sha1`` / ``git-sha256`` — a git object id (commit/tree). This is
##   the VCS-native content hash: for a content-addressed VCS the object id
##   *is* the integrity, so no recomputation over files is needed.
## - ``blake3`` — Reprobuild's OWN deterministic hash over the checked-out
##   files (the NAR-style canonical tree hash). Used where the source is not
##   content-addressed (a plain directory / tarball-style source).
## - ``fnv1a64`` — the legacy provenance digest already used by
##   ``inputs_digest``; formalized here so every integrity value in the
##   system reads the same way.
##
## This module is dependency-light: it owns the multihash grammar, the
## BLAKE3 own-file-hash, and the NAR-style canonical tree serialization. It
## does NOT touch the filesystem or git — callers (``repro_cli_support``,
## ``repro_lock``) gather the bytes / object ids and hand them here.

import std/[algorithm, strutils]

import blake3

type
  Multihash* = object
    ## A parsed self-describing multihash. ``alg`` is a registered code
    ## (e.g. ``"git-sha1"``); ``digest`` is the lowercase hex digest.
    alg*: string
    digest*: string

  MultihashError* = object of CatchableError
    ## Raised on a malformed multihash string.

const
  registeredMultihashAlgs* = [
    "git-sha1", "git-sha256", "blake3", "fnv1a64"]
    ## The algorithm codes this build understands. An integrity value whose
    ## ``<alg>`` is not in this set is structurally well-formed but
    ## UNRECOGNIZED; ``isWellFormedMultihash`` rejects it so a typo or a
    ## future-only algorithm is a loud failure rather than a silent pass.

  narTreeMagicV1* = "reprobuild-nar-tree-v1"
    ## Domain tag prefixed into the NAR-style canonical serialization so a
    ## tree hash can never collide with a raw-payload BLAKE3 hash.

proc formatMultihash*(alg, digest: string): string =
  ## Render an ``<alg>:<digest>`` multihash string.
  alg & ":" & digest

proc `$`*(m: Multihash): string =
  formatMultihash(m.alg, m.digest)

proc parseMultihash*(s: string): Multihash =
  ## Parse an ``<alg>:<digest>`` string. Raises ``MultihashError`` when the
  ## separator is missing or either half is empty.
  let idx = s.find(':')
  if idx <= 0 or idx >= s.high:
    raise newException(MultihashError,
      "not a self-describing multihash '" & s & "' (expected <alg>:<digest>)")
  Multihash(alg: s[0 ..< idx], digest: s[idx + 1 .. ^1])

proc isHexDigest(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin {'0'..'9', 'a'..'f'}:
      return false
  true

proc isWellFormedMultihash*(s: string): bool =
  ## True iff ``s`` is ``<alg>:<digest>`` with a REGISTERED ``<alg>`` and a
  ## non-empty lowercase-hex ``<digest>``. This is the validation the lock
  ## reader and ``repro lock validate`` use: a fake/constant or
  ## wrong-algorithm integrity fails it.
  let idx = s.find(':')
  if idx <= 0 or idx >= s.high:
    return false
  let alg = s[0 ..< idx]
  let digest = s[idx + 1 .. ^1]
  if alg notin registeredMultihashAlgs:
    return false
  isHexDigest(digest)

# ---------------------------------------------------------------------------
# BLAKE3 own-file-hash
# ---------------------------------------------------------------------------

proc toHexLower(bytes: openArray[byte]): string =
  const digits = "0123456789abcdef"
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add(digits[int(b shr 4) and 0xF])
    result.add(digits[int(b) and 0xF])

proc blake3Hex*(payload: openArray[byte]): string =
  ## Lowercase hex of the raw BLAKE3-256 digest of ``payload``.
  toHexLower(blake3.digest(@payload))

proc blake3Multihash*(payload: openArray[byte]): string =
  ## ``blake3:<hex>`` over ``payload``.
  formatMultihash("blake3", blake3Hex(payload))

# ---------------------------------------------------------------------------
# NAR-style canonical tree hash (the own-file-hash for a non-content-addressed
# source). Deterministic: entries are sorted by path and every field is
# length-prefixed so no concatenation is ambiguous. Changing ANY file's
# content (or any path) changes the digest.
# ---------------------------------------------------------------------------

proc addLenPrefixed(buf: var seq[byte]; s: string) =
  # 8-byte little-endian length, then the raw bytes.
  let n = uint64(s.len)
  for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
    buf.add(byte((n shr uint64(shift)) and 0xff'u64))
  for ch in s:
    buf.add(byte(ch))

proc narStyleTreeSerialization*(
    entries: seq[tuple[path: string, content: string]]): seq[byte] =
  ## The canonical NAR-style byte serialization of a set of (relative path,
  ## content) entries. Entries are SORTED by path so the result is
  ## independent of discovery order; each path and content is length-framed.
  var sorted = entries
  sorted.sort(proc(a, b: tuple[path, content: string]): int = cmp(a.path, b.path))
  result = @[]
  for ch in narTreeMagicV1:
    result.add(byte(ch))
  let count = uint64(sorted.len)
  for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
    result.add(byte((count shr uint64(shift)) and 0xff'u64))
  for e in sorted:
    addLenPrefixed(result, e.path)
    addLenPrefixed(result, e.content)

proc narStyleTreeMultihash*(
    entries: seq[tuple[path: string, content: string]]): string =
  ## ``blake3:<hex>`` over the NAR-style canonical serialization of a tree —
  ## Reprobuild's own-file-hash for a source the VCS does not
  ## content-address. Genuinely hashes the file contents.
  blake3Multihash(narStyleTreeSerialization(entries))

# ---------------------------------------------------------------------------
# Git object-id integrity (the VCS-native content hash)
# ---------------------------------------------------------------------------

proc gitObjectFormatToAlg*(objectFormat: string): string =
  ## Map a git ``--show-object-format`` value to the multihash algorithm
  ## code. Git defaults to SHA-1; SHA-256 repositories report ``"sha256"``.
  if objectFormat.strip().toLowerAscii() == "sha256": "git-sha256"
  else: "git-sha1"

proc gitObjectMultihash*(objectFormat, objectId: string): string =
  ## ``git-sha1:<oid>`` / ``git-sha256:<oid>`` — the VCS-native content hash.
  ## For a content-addressed VCS the object id IS the integrity, so this is
  ## the coordinate revision re-tagged as a self-describing integrity value.
  formatMultihash(gitObjectFormatToAlg(objectFormat), objectId.strip().toLowerAscii())
