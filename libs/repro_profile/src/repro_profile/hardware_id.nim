## M9.R.21.1 — stable system identifier composer for ``hardware.nim``.
##
## Spec: ``reprobuild-specs/ReproOS-Configuration-Architecture.md`` §3.2.
##
## Strategy (in order):
##   1. DMI fields under ``/sys/class/dmi/id/`` (``board_vendor`` +
##      ``board_name`` + ``board_serial`` + ``product_uuid`` +
##      ``chassis_serial``). The first three reproducibly identify the
##      motherboard; the last two add stability across firmware
##      reflashes that re-randomise machine-id.
##   2. ``/etc/repro/machine-id`` — a UUID-shaped fallback persisted on
##      first probe when no usable DMI is present (typical of VMs,
##      SBCs, containers).
##
## The composed identifier is canonicalised:
##   * lowercased
##   * non-alphanumeric (other than ``-``) stripped
##   * hashed with SHA-1, truncated to 130 bits and re-encoded in
##     Crockford base-32 → 26 characters.
##
## Spec wording: "Returns a 26-char identifier like
## ``01J5Z8P0XYZ...``." The format is opaque to the user — the only
## guarantees are deterministic-given-same-DMI + collision-resistant
## (130 bits ≈ 1.4×10^39 keyspace).

import std/[os, strutils, times]
{.push warning[Deprecated]: off.}
import std/sha1
{.pop.}

const
  DmiRoot* = "/sys/class/dmi/id"
    ## Default DMI tree root. Tests override via the ``dmiRoot`` arg
    ## on the lower-level entry points.
  MachineIdPath* = "/etc/repro/machine-id"
    ## Default persistent-UUID fallback path. Tests override.
  IdLen* = 26
    ## Crockford-base32 output length.

# Crockford base-32 alphabet, per the canonical RFC-less spec:
# https://www.crockford.com/base32.html — chosen for human-readable
# IDs (no I/L/O/U) and bidirectional symbol normalisation.
const CrockfordAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

proc readDmiField(dmiRoot, name: string): string =
  ## Read ``<dmiRoot>/<name>`` and return its trimmed contents, or
  ## "" if the file is absent / unreadable / contains a placeholder
  ## ("Not Specified", "To be filled by O.E.M.", "Default string",
  ## or 32 zeroes which BIOS vendors stamp into ``product_uuid``).
  let path = dmiRoot / name
  if not fileExists(path):
    return ""
  var content =
    try: readFile(path)
    except CatchableError: return ""
  content = content.strip()
  if content.len == 0: return ""
  let normalised = content.toLowerAscii()
  if normalised in ["not specified", "not applicable",
                    "to be filled by o.e.m.", "default string",
                    "system manufacturer", "system product name",
                    "system serial number", "chassis manufacturer",
                    "chassis serial number"]:
    return ""
  # ``product_uuid`` of all-zeros is a common BIOS placeholder.
  if name == "product_uuid":
    var noDashes = ""
    for c in content:
      if c != '-': noDashes.add c
    if noDashes.len == 32 and noDashes.allCharsInSet({'0'}):
      return ""
  content

proc canonicalise(s: string): string =
  ## Lowercase + strip non-alphanumeric-except-dash, collapse runs of
  ## whitespace into single ``-``.
  var prevDash = true   # avoid leading dash
  for c in s:
    case c
    of 'A' .. 'Z': result.add char(c.int + 0x20); prevDash = false
    of 'a' .. 'z', '0' .. '9': result.add c; prevDash = false
    of '-':
      if not prevDash: result.add '-'; prevDash = true
    of ' ', '\t', '_', '.', '/', ',':
      if not prevDash: result.add '-'; prevDash = true
    else: discard  # drop weird chars
  while result.len > 0 and result[^1] == '-':
    result.setLen(result.len - 1)

proc readMachineId(machineIdPath: string): string =
  if not fileExists(machineIdPath):
    return ""
  try: readFile(machineIdPath).strip()
  except CatchableError: ""

proc generateUuid(): string =
  ## Cheap UUID-shaped 128-bit random for the fallback. Sourced from
  ## ``/dev/urandom`` when available, clock+pid hash otherwise.
  ## Format: 32 lowercase hex chars (no dashes).
  var bytes: array[16, byte]
  var gotRandom = false
  when defined(posix):
    if fileExists("/dev/urandom"):
      try:
        let f = open("/dev/urandom")
        defer: f.close()
        let n = f.readBuffer(addr bytes[0], 16)
        if n == 16: gotRandom = true
      except CatchableError: discard
  if not gotRandom:
    # Fallback: hash the current clock + pid + a stack address.
    let seed = $epochTime() & "|" & $getCurrentProcessId() & "|" &
               $cast[int](addr bytes)
    let h = secureHash(seed)
    let d = Sha1Digest(h)
    for i in 0 ..< 16:
      bytes[i] = byte(d[i])
  result = ""
  for b in bytes: result.add toHex(b.int, 2).toLowerAscii()

proc ensureMachineId*(machineIdPath: string = MachineIdPath): string =
  ## Read ``machineIdPath``; generate + persist a fresh UUID-shaped
  ## value when the file doesn't exist. Returns the stable value.
  let existing = readMachineId(machineIdPath)
  if existing.len > 0:
    return existing
  let fresh = generateUuid()
  try:
    let parent = parentDir(machineIdPath)
    if parent.len > 0 and not dirExists(parent):
      createDir(parent)
    writeFile(machineIdPath, fresh & "\n")
  except CatchableError: discard
  fresh

proc collectDmiInputs*(dmiRoot: string = DmiRoot): seq[string] =
  ## Read the DMI fields used by the composer. The order is fixed so
  ## that two probes on the same machine produce the same hash input.
  ## Returns the non-empty fields only; an empty result signals
  ## "no usable DMI, use the UUID fallback".
  const FieldOrder = [
    "board_vendor", "board_name", "board_serial",
    "product_uuid", "chassis_serial",
    "product_name", "product_serial"]
  for f in FieldOrder:
    let v = readDmiField(dmiRoot, f)
    if v.len > 0:
      result.add f & "=" & v

proc encodeCrockford(digest: Sha1Digest; length: int): string =
  ## Truncate the SHA-1 digest (160 bits) to ``length * 5`` bits and
  ## encode in Crockford base-32. The 26-char output uses 130 bits.
  result = newString(length)
  # Pack the digest's leading bytes into a bit buffer 5 bits at a time.
  var bitBuffer: uint64 = 0
  var bitsInBuffer = 0
  var byteIdx = 0
  for i in 0 ..< length:
    while bitsInBuffer < 5 and byteIdx < digest.len:
      bitBuffer = (bitBuffer shl 8) or uint64(digest[byteIdx])
      bitsInBuffer += 8
      inc byteIdx
    let shift = bitsInBuffer - 5
    let idx = int((bitBuffer shr shift) and 0x1F'u64)
    bitBuffer = bitBuffer and ((1'u64 shl shift) - 1)
    bitsInBuffer -= 5
    result[i] = CrockfordAlphabet[idx]

proc composeStableSystemIdFrom*(inputs: seq[string]): string =
  ## Lowest-level entry point: take the canonicalised input lines and
  ## emit the 26-char identifier. Pure (no filesystem I/O) so unit
  ## tests can pin the encoding contract.
  if inputs.len == 0:
    raise newException(ValueError,
      "composeStableSystemIdFrom: at least one input required")
  var buf = ""
  for line in inputs:
    if buf.len > 0: buf.add '\n'
    buf.add canonicalise(line)
  let digest = secureHash(buf)
  encodeCrockford(Sha1Digest(digest), IdLen)

proc composeStableSystemId*(dmiRoot: string = DmiRoot;
                            machineIdPath: string = MachineIdPath): string =
  ## High-level entry point. Reads DMI first, falls back to the
  ## persistent ``/etc/repro/machine-id`` UUID. Always returns a
  ## 26-char Crockford-base32 identifier; never raises (a totally
  ## unreadable system still yields a deterministic ID from a
  ## generated UUID).
  let dmi = collectDmiInputs(dmiRoot)
  if dmi.len > 0:
    return composeStableSystemIdFrom(dmi)
  let mid = ensureMachineId(machineIdPath)
  composeStableSystemIdFrom(@["machine-id=" & mid])
