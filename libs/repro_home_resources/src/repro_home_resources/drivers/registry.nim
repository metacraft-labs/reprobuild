## `windows.registryValue` driver — direct Win32 `Reg*` API surface.
##
## Per the anti-patterns list: NO `reg.exe` shell-out, NO string
## comparison of typed values, NO mocking the registry. Each typed
## kind has its own byte representation; the driver writes the raw
## bytes via `RegSetValueExW` and reads them back via
## `RegQueryValueExW` for drift detection.
##
## We hand-roll a small Win32 binding rather than pulling in winim
## because it's a tiny, stable surface and avoids a transitive
## dependency only this driver needs.

import std/[strutils]

import ./../errors
import ./../manifest_record
import ./../types

proc stripHkcuPrefix*(key: string): string =
  ## Helper used by env.userVariable / windows.startup. Accepts
  ## either "HKCU\..." or "HKEY_CURRENT_USER\...". HKLM and other
  ## hives are not stripped — the driver will refuse to open them.
  if key.startsWith("HKCU\\") or key.startsWith("HKCU/"):
    return key[5 ..< key.len]
  if key.startsWith("HKEY_CURRENT_USER\\") or
     key.startsWith("HKEY_CURRENT_USER/"):
    return key[18 ..< key.len]
  return key

when defined(windows):
  # -------------------------------------------------------------------------
  # Win32 binding (hand-rolled — small stable surface).
  # -------------------------------------------------------------------------
  type
    LPBYTE = ptr UncheckedArray[uint8]
    HKEY* {.importc, header: "<windows.h>".} = distinct pointer
    DWORD = uint32
    LSTATUS = clong
    LPCWSTR = ptr UncheckedArray[uint16]
    LPDWORD = ptr DWORD
    PHKEY = ptr HKEY
    LPCVOID = pointer
    REGSAM = DWORD
    HWND = pointer
    WPARAM = uint
    LPARAM = int

  const
    HKEY_CURRENT_USER_INT = cast[int](0x80000001'u32)
    KEY_READ: REGSAM = 0x20019
    KEY_WRITE: REGSAM = 0x20006
    KEY_ALL_ACCESS: REGSAM = 0xF003F
    ERROR_SUCCESS: LSTATUS = 0
    ERROR_FILE_NOT_FOUND: LSTATUS = 2
    ERROR_MORE_DATA: LSTATUS = 234
    REG_OPTION_NON_VOLATILE: DWORD = 0
    HWND_BROADCAST_INT = cast[int](0xffff'u32)
    WM_SETTINGCHANGE: uint = 0x001A
    SMTO_ABORTIFHUNG: uint = 0x0002

  proc hkeyCurrentUser(): HKEY =
    cast[HKEY](cast[pointer](HKEY_CURRENT_USER_INT))

  proc hwndBroadcast(): HWND =
    cast[HWND](cast[pointer](HWND_BROADCAST_INT))

  proc RegOpenKeyExW(hKey: HKEY; lpSubKey: LPCWSTR; ulOptions: DWORD;
                    samDesired: REGSAM; phkResult: PHKEY): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc RegCreateKeyExW(hKey: HKEY; lpSubKey: LPCWSTR; Reserved: DWORD;
                      lpClass: LPCWSTR; dwOptions: DWORD;
                      samDesired: REGSAM; lpSecurityAttributes: pointer;
                      phkResult: PHKEY; lpdwDisposition: LPDWORD): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc RegCloseKey(hKey: HKEY): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc RegQueryValueExW(hKey: HKEY; lpValueName: LPCWSTR; lpReserved: LPDWORD;
                       lpType: LPDWORD; lpData: LPBYTE;
                       lpcbData: LPDWORD): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc RegSetValueExW(hKey: HKEY; lpValueName: LPCWSTR; Reserved: DWORD;
                     dwType: DWORD; lpData: LPCVOID; cbData: DWORD): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc RegDeleteValueW(hKey: HKEY; lpValueName: LPCWSTR): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc SendMessageTimeoutW(hWnd: HWND; Msg: uint; wParam: WPARAM;
                          lParam: LPARAM; fuFlags: uint; uTimeout: uint;
                          lpdwResult: ptr uint): int
    {.importc, stdcall, dynlib: "user32".}

  # -------------------------------------------------------------------------
  # UTF-16LE conversion.
  # -------------------------------------------------------------------------

  proc toUtf16Z(s: string): seq[uint16] =
    ## UTF-8 -> UTF-16LE with a trailing NUL. Surrogate pairs are
    ## decoded via std/unicode's runes; we keep this hand-rolled to
    ## avoid pulling unicode just for one call.
    result = @[]
    var i = 0
    while i < s.len:
      let b0 = uint32(byte(s[i]))
      var cp: uint32
      var advance: int
      if b0 < 0x80:
        cp = b0; advance = 1
      elif (b0 and 0xE0) == 0xC0 and i + 1 < s.len:
        cp = ((b0 and 0x1F) shl 6) or (uint32(byte(s[i+1])) and 0x3F)
        advance = 2
      elif (b0 and 0xF0) == 0xE0 and i + 2 < s.len:
        cp = ((b0 and 0x0F) shl 12) or
             ((uint32(byte(s[i+1])) and 0x3F) shl 6) or
             (uint32(byte(s[i+2])) and 0x3F)
        advance = 3
      elif (b0 and 0xF8) == 0xF0 and i + 3 < s.len:
        cp = ((b0 and 0x07) shl 18) or
             ((uint32(byte(s[i+1])) and 0x3F) shl 12) or
             ((uint32(byte(s[i+2])) and 0x3F) shl 6) or
             (uint32(byte(s[i+3])) and 0x3F)
        advance = 4
      else:
        cp = b0; advance = 1
      if cp <= 0xFFFF:
        result.add(uint16(cp))
      else:
        let c = cp - 0x10000
        result.add(uint16(0xD800 + (c shr 10)))
        result.add(uint16(0xDC00 + (c and 0x3FF)))
      i += advance
    result.add(0'u16)

  proc fromUtf16Bytes(bytes: openArray[byte]; trimTrailingNul = true): string =
    ## UTF-16LE bytes -> UTF-8. If `trimTrailingNul`, any trailing
    ## U+0000 code units are dropped.
    var units: seq[uint16] = @[]
    var i = 0
    while i + 1 < bytes.len:
      units.add(uint16(bytes[i]) or (uint16(bytes[i+1]) shl 8))
      i += 2
    if trimTrailingNul:
      while units.len > 0 and units[^1] == 0'u16:
        units.setLen(units.len - 1)
    result = ""
    var j = 0
    while j < units.len:
      var cp: uint32
      let u = uint32(units[j])
      if u >= 0xD800 and u <= 0xDBFF and j + 1 < units.len:
        let lo = uint32(units[j+1])
        cp = 0x10000 + ((u - 0xD800) shl 10) + (lo - 0xDC00)
        inc j
      else:
        cp = u
      inc j
      if cp < 0x80:
        result.add(char(cp))
      elif cp < 0x800:
        result.add(char(0xC0 or (cp shr 6)))
        result.add(char(0x80 or (cp and 0x3F)))
      elif cp < 0x10000:
        result.add(char(0xE0 or (cp shr 12)))
        result.add(char(0x80 or ((cp shr 6) and 0x3F)))
        result.add(char(0x80 or (cp and 0x3F)))
      else:
        result.add(char(0xF0 or (cp shr 18)))
        result.add(char(0x80 or ((cp shr 12) and 0x3F)))
        result.add(char(0x80 or ((cp shr 6) and 0x3F)))
        result.add(char(0x80 or (cp and 0x3F)))

  proc utf16Bytes(units: seq[uint16]): seq[byte] =
    result = newSeq[byte](units.len * 2)
    for i, u in units:
      result[i*2] = byte(u and 0xff)
      result[i*2 + 1] = byte((u shr 8) and 0xff)

  # -------------------------------------------------------------------------
  # Payload encoding per typed value kind.
  # -------------------------------------------------------------------------

  proc encodeString*(s: string): seq[byte] =
    let units = toUtf16Z(s)
    utf16Bytes(units)

  proc encodeDword*(v: uint32): seq[byte] =
    result = newSeq[byte](4)
    result[0] = byte(v and 0xff)
    result[1] = byte((v shr 8) and 0xff)
    result[2] = byte((v shr 16) and 0xff)
    result[3] = byte((v shr 24) and 0xff)

  proc encodeQword*(v: uint64): seq[byte] =
    result = newSeq[byte](8)
    for i in 0 ..< 8:
      result[i] = byte((v shr (i*8)) and 0xff)

  proc encodeBinary*(b: openArray[byte]): seq[byte] =
    result = newSeq[byte](b.len)
    for i, v in b:
      result[i] = v

  proc encodeMultiString*(items: openArray[string]): seq[byte] =
    ## REG_MULTI_SZ: each entry is UTF-16LE terminated by U+0000;
    ## the whole sequence ends with an extra U+0000.
    var units: seq[uint16] = @[]
    for item in items:
      let z = toUtf16Z(item)
      # z already has trailing 0; keep it.
      units.add(z)
    # Final terminator
    units.add(0'u16)
    utf16Bytes(units)

  proc decodeMultiString*(bytes: openArray[byte]): seq[string] =
    ## Reverse of encodeMultiString. Stops at the double-zero
    ## terminator; tolerates a trailing single zero (legacy
    ## writers).
    var s = ""
    var i = 0
    while i + 1 < bytes.len:
      let u = uint16(bytes[i]) or (uint16(bytes[i+1]) shl 8)
      i += 2
      if u == 0:
        if s.len == 0:
          break
        result.add(s)
        s = ""
      else:
        # Re-encode this UTF-16 code unit into the building string.
        if u < 0x80:
          s.add(char(u))
        elif u < 0x800:
          s.add(char(0xC0 or (u shr 6)))
          s.add(char(0x80 or (u and 0x3F)))
        else:
          s.add(char(0xE0 or (u shr 12)))
          s.add(char(0x80 or ((u shr 6) and 0x3F)))
          s.add(char(0x80 or (u and 0x3F)))

  # -------------------------------------------------------------------------
  # Core read/write/delete operations.
  # -------------------------------------------------------------------------

  type
    RegReadResult* = object
      present*: bool
      regType*: uint32
      bytes*: seq[byte]

  proc subkeyWide(subkey: string): seq[uint16] =
    toUtf16Z(subkey)

  proc valueNameWide(name: string): seq[uint16] =
    toUtf16Z(name)

  proc openOrCreateKey(subkey: string; sam: REGSAM; create: bool): HKEY =
    ## Opens HKCU\<subkey>. When `create` is true, creates the
    ## subkey if it doesn't exist.
    var hk: HKEY
    var wide = subkeyWide(subkey)
    let widePtr = cast[LPCWSTR](addr wide[0])
    var status: LSTATUS
    if create:
      var disposition: DWORD = 0
      status = RegCreateKeyExW(hkeyCurrentUser(), widePtr, 0, nil,
        REG_OPTION_NON_VOLATILE, sam, nil, addr hk, addr disposition)
    else:
      status = RegOpenKeyExW(hkeyCurrentUser(), widePtr, 0, sam, addr hk)
    if status != ERROR_SUCCESS:
      raiseResourceDriver("HKCU\\" & subkey, "windows.registryValue",
        if create: "RegCreateKeyExW" else: "RegOpenKeyExW",
        "Win32 status " & $status)
    return hk

  proc readRegistryValue*(subkey, name: string): RegReadResult =
    ## Read a registry value. `present == false` when the value is
    ## absent (the SUBKEY may still exist; we don't auto-create on
    ## read). Raises on unexpected Win32 errors.
    var hk: HKEY
    var wide = subkeyWide(subkey)
    let widePtr = cast[LPCWSTR](addr wide[0])
    var openStatus = RegOpenKeyExW(hkeyCurrentUser(), widePtr, 0,
      KEY_READ, addr hk)
    if openStatus == ERROR_FILE_NOT_FOUND:
      result.present = false
      return
    if openStatus != ERROR_SUCCESS:
      raiseResourceDriver("HKCU\\" & subkey, "windows.registryValue",
        "RegOpenKeyExW", "Win32 status " & $openStatus)
    defer:
      discard RegCloseKey(hk)
    var nameWide = valueNameWide(name)
    let namePtr = cast[LPCWSTR](addr nameWide[0])
    var regType: DWORD = 0
    var cb: DWORD = 0
    var status = RegQueryValueExW(hk, namePtr, nil, addr regType,
      nil, addr cb)
    if status == ERROR_FILE_NOT_FOUND:
      result.present = false
      return
    if status != ERROR_SUCCESS and status != ERROR_MORE_DATA:
      raiseResourceDriver("HKCU\\" & subkey & "\\" & name,
        "windows.registryValue", "RegQueryValueExW (size)",
        "Win32 status " & $status)
    var buf = newSeq[byte](int(cb))
    if cb > 0:
      status = RegQueryValueExW(hk, namePtr, nil, addr regType,
        cast[LPBYTE](addr buf[0]), addr cb)
      if status != ERROR_SUCCESS:
        raiseResourceDriver("HKCU\\" & subkey & "\\" & name,
          "windows.registryValue", "RegQueryValueExW (data)",
          "Win32 status " & $status)
    else:
      status = RegQueryValueExW(hk, namePtr, nil, addr regType,
        nil, addr cb)
      if status != ERROR_SUCCESS:
        raiseResourceDriver("HKCU\\" & subkey & "\\" & name,
          "windows.registryValue", "RegQueryValueExW (zero-size)",
          "Win32 status " & $status)
    result.present = true
    result.regType = uint32(regType)
    result.bytes = buf

  proc writeRegistryValue*(subkey, name: string; regType: uint32;
                          data: openArray[byte]) =
    ## Create the subkey if missing, then set the value with the
    ## given REG_TYPE and raw bytes.
    let hk = openOrCreateKey(subkey, KEY_WRITE, create = true)
    defer: discard RegCloseKey(hk)
    var nameWide = valueNameWide(name)
    let namePtr = cast[LPCWSTR](addr nameWide[0])
    let dataPtr =
      if data.len > 0:
        cast[LPCVOID](unsafeAddr data[0])
      else:
        cast[LPCVOID](nil)
    let status = RegSetValueExW(hk, namePtr, 0, regType,
      dataPtr, DWORD(data.len))
    if status != ERROR_SUCCESS:
      raiseResourceDriver("HKCU\\" & subkey & "\\" & name,
        "windows.registryValue", "RegSetValueExW",
        "Win32 status " & $status)

  proc deleteRegistryValue*(subkey, name: string) =
    ## Delete the value. Silently succeeds if the value (or the
    ## subkey) was already gone.
    var hk: HKEY
    var wide = subkeyWide(subkey)
    let widePtr = cast[LPCWSTR](addr wide[0])
    let openStatus = RegOpenKeyExW(hkeyCurrentUser(), widePtr, 0,
      KEY_WRITE, addr hk)
    if openStatus == ERROR_FILE_NOT_FOUND:
      return
    if openStatus != ERROR_SUCCESS:
      raiseResourceDriver("HKCU\\" & subkey, "windows.registryValue",
        "RegOpenKeyExW (delete)", "Win32 status " & $openStatus)
    defer: discard RegCloseKey(hk)
    var nameWide = valueNameWide(name)
    let namePtr = cast[LPCWSTR](addr nameWide[0])
    let status = RegDeleteValueW(hk, namePtr)
    if status != ERROR_SUCCESS and status != ERROR_FILE_NOT_FOUND:
      raiseResourceDriver("HKCU\\" & subkey & "\\" & name,
        "windows.registryValue", "RegDeleteValueW",
        "Win32 status " & $status)

  proc broadcastEnvironmentChange*() =
    ## Notify running processes that the user-environment has
    ## changed. Used by `env.userVariable` after a write so cmd.exe
    ## / Explorer pick up the new PATH without requiring a logoff.
    var dwResult: uint = 0
    let envWide = toUtf16Z("Environment")
    let envPtr = cast[LPARAM](cast[int](unsafeAddr envWide[0]))
    discard SendMessageTimeoutW(hwndBroadcast(), WM_SETTINGCHANGE,
      0, envPtr, SMTO_ABORTIFHUNG, 5000, addr dwResult)

  # -------------------------------------------------------------------------
  # ObservedState construction (used by the lifecycle planner).
  # -------------------------------------------------------------------------

  proc observeRegistryValue*(key, name: string): ObservedState =
    let subkey = stripHkcuPrefix(key)
    let r = readRegistryValue(subkey, name)
    if r.present:
      result.present = true
      result.rawBytes = r.bytes
      result.digest = digestOfBytes(r.bytes)
    else:
      result.present = false
      result.digest = zeroDigest()
      result.rawBytes = @[]

else:
  # Non-Windows stubs so the module compiles. The lifecycle layer
  # platform-skips registry resources outside Windows; these stubs
  # exist only so the umbrella import succeeds in tests on macOS /
  # Linux (the gates that exercise registry are Windows-only).
  type RegReadResult* = object
    present*: bool
    regType*: uint32
    bytes*: seq[byte]

  proc readRegistryValue*(subkey, name: string): RegReadResult =
    raiseResourceDriver("HKCU\\" & subkey, "windows.registryValue",
      "platform", "registry driver is Windows-only")

  proc writeRegistryValue*(subkey, name: string; regType: uint32;
                          data: openArray[byte]) =
    raiseResourceDriver("HKCU\\" & subkey, "windows.registryValue",
      "platform", "registry driver is Windows-only")

  proc deleteRegistryValue*(subkey, name: string) =
    raiseResourceDriver("HKCU\\" & subkey, "windows.registryValue",
      "platform", "registry driver is Windows-only")

  proc broadcastEnvironmentChange*() = discard

  proc encodeString*(s: string): seq[byte] =
    var buf = newSeq[byte](s.len * 2 + 2)
    for i, ch in s:
      buf[i*2] = byte(ord(ch))
    buf

  proc encodeDword*(v: uint32): seq[byte] =
    result = newSeq[byte](4)
    result[0] = byte(v and 0xff)
    result[1] = byte((v shr 8) and 0xff)
    result[2] = byte((v shr 16) and 0xff)
    result[3] = byte((v shr 24) and 0xff)

  proc encodeQword*(v: uint64): seq[byte] =
    result = newSeq[byte](8)
    for i in 0 ..< 8:
      result[i] = byte((v shr (i*8)) and 0xff)

  proc encodeBinary*(b: openArray[byte]): seq[byte] =
    result = newSeq[byte](b.len)
    for i, v in b: result[i] = v

  proc encodeMultiString*(items: openArray[string]): seq[byte] =
    var buf: seq[byte] = @[]
    for item in items:
      for ch in item:
        buf.add(byte(ord(ch)))
        buf.add(0'u8)
      buf.add(0'u8); buf.add(0'u8)
    buf.add(0'u8); buf.add(0'u8)
    buf

  proc decodeMultiString*(bytes: openArray[byte]): seq[string] = @[]

  proc observeRegistryValue*(key, name: string): ObservedState =
    result.present = false
    result.digest = zeroDigest()
    result.rawBytes = @[]
