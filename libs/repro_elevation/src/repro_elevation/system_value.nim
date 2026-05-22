## Typed value kinds shared by the M69 system-scope privileged
## operations.
##
## `windows.registryValue scope=system` carries the SAME six typed
## value kinds as the M68 home-scope HKCU `windows.registryValue`
## resource (`repro_home_resources/types.nim`). The home-scope
## catalog and the privileged catalog are separate compilation units
## (the broker library deliberately does not depend on the home-scope
## resource library), so the typed kind set is re-declared here with
## an identical string form — a wire frame encodes the string, so the
## two catalogs interoperate by construction.
##
## This module is platform-pure and unit-testable everywhere.

import std/[strutils]

type
  SystemRegistryValueKind* = enum
    ## The 6 typed registry value kinds the HKLM driver understands.
    ## String form matches the M68 `RegistryValueKind` exactly so an
    ## operator authoring a `system.nim` profile uses the same names
    ## as a `home.nim` profile. The REG_* numeric constant is what
    ## `RegSetValueExW` receives.
    srvkString = "string"             ## REG_SZ (1)
    srvkExpandString = "expandString" ## REG_EXPAND_SZ (2)
    srvkBinary = "binary"             ## REG_BINARY (3)
    srvkDword = "dword"               ## REG_DWORD (4)
    srvkMultiString = "multiString"   ## REG_MULTI_SZ (7)
    srvkQword = "qword"               ## REG_QWORD (11)

proc systemRegistryValueKindFromString*(s: string): SystemRegistryValueKind =
  ## Strict parse — an unknown tag raises so the protocol decoder
  ## rejects a malformed frame rather than silently mis-typing it.
  case s
  of $srvkString: srvkString
  of $srvkExpandString: srvkExpandString
  of $srvkBinary: srvkBinary
  of $srvkDword: srvkDword
  of $srvkMultiString: srvkMultiString
  of $srvkQword: srvkQword
  else:
    raise newException(ValueError,
      "unknown system registry value kind tag: '" & s & "'")

proc isKnownSystemRegistryValueKind*(s: string): bool =
  try:
    discard systemRegistryValueKindFromString(s)
    true
  except ValueError:
    false

proc systemRegistryValueKindToRegType*(k: SystemRegistryValueKind): uint32 =
  ## Map the typed enum to the Win32 REG_* numeric constant.
  case k
  of srvkString: 1'u32
  of srvkExpandString: 2'u32
  of srvkBinary: 3'u32
  of srvkDword: 4'u32
  of srvkMultiString: 7'u32
  of srvkQword: 11'u32

proc systemRegistryValueKindFromRegType*(regType: uint32):
    SystemRegistryValueKind =
  case regType
  of 1'u32: srvkString
  of 2'u32: srvkExpandString
  of 3'u32: srvkBinary
  of 4'u32: srvkDword
  of 7'u32: srvkMultiString
  of 11'u32: srvkQword
  else:
    raise newException(ValueError,
      "unknown REG_TYPE numeric constant: " & $regType)

# ---------------------------------------------------------------------------
# Typed payload encoding. All six kinds collapse to a (kind, bytes)
# representation; the bytes are what `RegSetValueExW` writes and what
# the digest covers. The encoders are pure so drift comparison and
# the wire codec can run cross-platform.
# ---------------------------------------------------------------------------

proc toUtf16Z*(s: string): seq[uint16] =
  ## UTF-8 -> UTF-16LE with a trailing NUL. Surrogate pairs handled so
  ## the helper is correct for non-ASCII registry payloads.
  result = @[]
  var i = 0
  while i < s.len:
    let b0 = uint32(byte(s[i]))
    var cp: uint32
    var adv: int
    if b0 < 0x80:
      cp = b0; adv = 1
    elif (b0 and 0xE0) == 0xC0 and i + 1 < s.len:
      cp = ((b0 and 0x1F) shl 6) or (uint32(byte(s[i+1])) and 0x3F)
      adv = 2
    elif (b0 and 0xF0) == 0xE0 and i + 2 < s.len:
      cp = ((b0 and 0x0F) shl 12) or
           ((uint32(byte(s[i+1])) and 0x3F) shl 6) or
           (uint32(byte(s[i+2])) and 0x3F)
      adv = 3
    elif (b0 and 0xF8) == 0xF0 and i + 3 < s.len:
      cp = ((b0 and 0x07) shl 18) or
           ((uint32(byte(s[i+1])) and 0x3F) shl 12) or
           ((uint32(byte(s[i+2])) and 0x3F) shl 6) or
           (uint32(byte(s[i+3])) and 0x3F)
      adv = 4
    else:
      cp = b0; adv = 1
    if cp <= 0xFFFF:
      result.add(uint16(cp))
    else:
      let c = cp - 0x10000
      result.add(uint16(0xD800 + (c shr 10)))
      result.add(uint16(0xDC00 + (c and 0x3FF)))
    i += adv
  result.add(0'u16)

proc utf16Bytes*(units: seq[uint16]): seq[byte] =
  result = newSeq[byte](units.len * 2)
  for i, u in units:
    result[i*2] = byte(u and 0xff)
    result[i*2 + 1] = byte((u shr 8) and 0xff)

proc encodeRegString*(s: string): seq[byte] =
  ## REG_SZ / REG_EXPAND_SZ payload: UTF-16LE bytes with trailing NUL.
  utf16Bytes(toUtf16Z(s))

proc encodeRegDword*(v: uint32): seq[byte] =
  result = newSeq[byte](4)
  for i in 0 ..< 4:
    result[i] = byte((v shr (i*8)) and 0xff)

proc encodeRegQword*(v: uint64): seq[byte] =
  result = newSeq[byte](8)
  for i in 0 ..< 8:
    result[i] = byte((v shr (i*8)) and 0xff)

proc encodeRegMultiString*(items: openArray[string]): seq[byte] =
  ## REG_MULTI_SZ: each entry UTF-16LE terminated by U+0000, the whole
  ## sequence ending with an extra U+0000.
  var units: seq[uint16] = @[]
  for item in items:
    units.add(toUtf16Z(item))
  units.add(0'u16)
  utf16Bytes(units)

proc parseHexNibble(c: char): int =
  case c
  of '0' .. '9': int(ord(c) - ord('0'))
  of 'a' .. 'f': int(ord(c) - ord('a') + 10)
  of 'A' .. 'F': int(ord(c) - ord('A') + 10)
  else:
    raise newException(ValueError, "not a hex nibble: '" & $c & "'")

proc decodeHexBytes*(hex: string): seq[byte] =
  ## Parse an even-length hex string into raw bytes (used by the
  ## `srvkBinary` value-literal form). Raises on odd length / non-hex.
  if hex.len mod 2 != 0:
    raise newException(ValueError,
      "binary registry literal must have an even hex length")
  result = newSeq[byte](hex.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte((parseHexNibble(hex[2*i]) shl 4) or
      parseHexNibble(hex[2*i + 1]))

proc encodeSystemRegistryPayload*(kind: SystemRegistryValueKind;
                                  valueLiteral: string): seq[byte] =
  ## Turn a string value-literal (the form a `system.nim` profile
  ## authors) into the raw REG_* bytes for the given kind:
  ##
  ##   string / expandString : the literal text
  ##   dword                 : a decimal or 0x-hex unsigned 32-bit
  ##   qword                 : a decimal or 0x-hex unsigned 64-bit
  ##   binary                : an even-length hex string
  ##   multiString           : "\n"-separated entries
  ##
  ## Pure and unit-tested cross-platform.
  case kind
  of srvkString, srvkExpandString:
    encodeRegString(valueLiteral)
  of srvkDword:
    let v =
      if valueLiteral.toLowerAscii().startsWith("0x"):
        uint32(fromHex[uint64](valueLiteral))
      else:
        uint32(parseBiggestUInt(valueLiteral))
    encodeRegDword(v)
  of srvkQword:
    let v =
      if valueLiteral.toLowerAscii().startsWith("0x"):
        fromHex[uint64](valueLiteral)
      else:
        uint64(parseBiggestUInt(valueLiteral))
    encodeRegQword(v)
  of srvkBinary:
    decodeHexBytes(valueLiteral)
  of srvkMultiString:
    var items: seq[string]
    if valueLiteral.len > 0:
      for line in valueLiteral.split('\n'):
        items.add(line)
    encodeRegMultiString(items)
