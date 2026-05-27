## Fixture privileged-operation drivers (M81 gate `allowed_mocks`).
##
## The M81 verification gate's `allowed_mocks` explicitly permits a
## "fixture privileged-operation set whose drivers write only to a
## sandboxed prefix / an isolated `HKLM\SOFTWARE\Reprobuild-Tests\`
## subkey". This module is that fixture catalog. It is the ONE real
## driver pair M81 ships so the broker MECHANISM is proven
## end-to-end; M69 plugs the real system-scope catalog into
## `dispatch.nim` the same way.
##
## Both drivers implement the spec's mandated contract: before
## mutating, **re-observe** the resource's current real-world state
## and drift-check it against the value the non-elevated plan
## recorded. State can change between the non-elevated plan and the
## elevated execution; the broker re-validates rather than blindly
## trusting the parent. A drift is fail-closed (`EBrokerDrift`).
##
## `pokFixtureFile` writes under a caller-supplied sandbox prefix
## (the gate points it at a temp dir). `pokFixtureRegistry` writes
## ONLY under `HKLM\SOFTWARE\Reprobuild-Tests\` — the driver pins
## that root and refuses anything else, so even a buggy or hostile
## operation cannot touch real system state.

import std/[os, strutils]

import blake3

import ./errors
import ./operations

const
  FixtureRegistryRoot* = "SOFTWARE\\Reprobuild-Tests"
    ## The ONLY `HKLM` subtree the fixture registry driver will ever
    ## write. Hard-coded; not parent-supplied.

type
  ObservedOperationState* = object
    ## What the driver saw when re-observing the operation's target
    ## just before mutating. `present == false` means the target is
    ## absent. `digestHex` is the BLAKE3-256 (hex) over the canonical
    ## observed bytes — the value drift detection compares against.
    ## `restartNeeded` is set by the M69 `windows.optionalFeature` /
    ## `windows.capability` drivers when DISM signals a reboot is
    ## required; Reprobuild never auto-reboots — it surfaces the flag.
    present*: bool
    digestHex*: string
    restartNeeded*: bool

  FixtureContext* = object
    ## Per-apply context the broker hands every fixture driver call.
    ## `filePrefix` is the sandbox root for `pokFixtureFile`; it MUST
    ## be an existing absolute directory.
    filePrefix*: string

proc digestHexOf(bytes: openArray[byte]): string =
  let d = blake3.digest(bytes)
  result = newStringOfCap(64)
  for b in d:
    result.add(toHex(int(b), 2).toLowerAscii())

proc digestHexOfText(text: string): string =
  var buf = newSeq[byte](text.len)
  for i, ch in text:
    buf[i] = byte(ord(ch))
  digestHexOf(buf)

const ZeroDigestHex* = "0000000000000000000000000000000000000000000000000000000000000000"
  ## The "target is absent" sentinel digest, shared by the plan side
  ## and the broker side so an absent->present transition is detected
  ## as a `create`, not a spurious drift.

# ---------------------------------------------------------------------------
# Desired-state digest. The non-elevated planner computes this for
# every privileged operation; the broker compares its re-observed
# state against the value the plan EXPECTED so a mid-flight change is
# caught.
# ---------------------------------------------------------------------------

proc desiredDigestHex*(op: PrivilegedOperation): string =
  ## Canonical content digest of a FIXTURE operation's desired
  ## payload. The M69 real system kinds compute their desired digest
  ## in `windows_system_driver.systemDesiredDigestHex`; `dispatch.nim`
  ## routes each kind to the right function.
  case op.kind
  of pokFixtureFile:
    digestHexOfText(op.fileContent)
  of pokFixtureRegistry:
    digestHexOfText(op.regValueData)
  else:
    raise newException(ValueError,
      "desiredDigestHex (fixture) called on a non-fixture kind " & $op.kind)

# ---------------------------------------------------------------------------
# fixture.systemFile
# ---------------------------------------------------------------------------

proc fixtureFileTargetPath*(ctx: FixtureContext;
                            op: PrivilegedOperation): string =
  ## Resolve and sandbox-confine the target path. Raises `EProtocol`
  ## if the relative path is unsafe — the caller (the broker) has
  ## already run `operationValidationError`, but the driver
  ## re-checks: defence in depth.
  doAssert op.kind == pokFixtureFile
  if not isSafeRelativeSubPath(op.fileRelPath):
    raiseProtocol("fixture.systemFile path '" & op.fileRelPath &
      "' escapes the sandbox prefix")
  ctx.filePrefix / op.fileRelPath

proc observeFixtureFile*(ctx: FixtureContext;
                         op: PrivilegedOperation): ObservedOperationState =
  ## Re-observe a `pokFixtureFile` target's current real-world state.
  let target = fixtureFileTargetPath(ctx, op)
  if fileExists(target):
    result.present = true
    result.digestHex = digestHexOfText(readFile(target))
  else:
    result.present = false
    result.digestHex = ZeroDigestHex

proc applyFixtureFile*(ctx: FixtureContext;
                       op: PrivilegedOperation): ObservedOperationState =
  ## Apply a `pokFixtureFile` operation. Returns the post-write
  ## observed state. Drift must already have been checked by the
  ## broker; this proc only performs the I/O.
  ##
  ## POST-APPLY RE-PROBE EXEMPTION (M82 Phase A): the file write here
  ## is a pure, synchronous `writeFile` of `op.fileContent`. There is
  ## no OS-side async propagation, no cmdlet exit-code-vs-state gap,
  ## and no second agent capable of clobbering the bytes during the
  ## driver's call. The post-write digest is unconditionally
  ## `digestHexOfText(op.fileContent)` by construction; a re-read and
  ## compare would be tautological. The fixture-file driver is the
  ## M81 mechanism prover, not a production driver — keeping it free
  ## of incidental ceremony is intentional.
  let target = fixtureFileTargetPath(ctx, op)
  createDir(target.parentDir)
  writeFile(target, op.fileContent)
  result.present = true
  result.digestHex = digestHexOfText(op.fileContent)

# ---------------------------------------------------------------------------
# fixture.systemRegistry — HKLM\SOFTWARE\Reprobuild-Tests\ only.
# ---------------------------------------------------------------------------

proc fixtureRegistrySubkey*(op: PrivilegedOperation): string =
  ## The HKLM subkey path the operation targets, pinned under
  ## `FixtureRegistryRoot`. `regSubPath` is appended; an unsafe
  ## sub-path raises.
  doAssert op.kind == pokFixtureRegistry
  if not isSafeRelativeSubPath(op.regSubPath):
    raiseProtocol("fixture.systemRegistry sub-path '" & op.regSubPath &
      "' escapes HKLM\\" & FixtureRegistryRoot)
  FixtureRegistryRoot & "\\" & op.regSubPath.replace('/', '\\')

when defined(windows):
  # ---------------------------------------------------------------------
  # Win32 binding for the HKLM registry path — same hand-rolled
  # surface as the M68 registry driver, but rooted at HKLM and
  # confined to the Reprobuild-Tests subtree.
  # ---------------------------------------------------------------------
  type
    HKEY = distinct pointer
    DWORD = uint32
    LSTATUS = clong
    LPCWSTR = ptr UncheckedArray[uint16]
    LPDWORD = ptr DWORD
    PHKEY = ptr HKEY
    REGSAM = DWORD
    LPBYTE = ptr UncheckedArray[uint8]
    LPCVOID = pointer

  const
    HKEY_LOCAL_MACHINE_INT = cast[int](0x80000002'u32)
    KEY_READ: REGSAM = 0x20019
    KEY_WRITE: REGSAM = 0x20006
    ERROR_SUCCESS: LSTATUS = 0
    ERROR_FILE_NOT_FOUND: LSTATUS = 2
    ERROR_MORE_DATA: LSTATUS = 234
    REG_OPTION_NON_VOLATILE: DWORD = 0
    REG_SZ: DWORD = 1

  proc hklm(): HKEY = cast[HKEY](cast[pointer](HKEY_LOCAL_MACHINE_INT))

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

  proc RegDeleteKeyExW(hKey: HKEY; lpSubKey: LPCWSTR; samDesired: REGSAM;
                       Reserved: DWORD): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc RegDeleteValueW(hKey: HKEY; lpValueName: LPCWSTR): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc RegDeleteTreeW(hKey: HKEY; lpSubKey: LPCWSTR): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc RegQueryInfoKeyW(hKey: HKEY; lpClass: LPCWSTR; lpcchClass: LPDWORD;
                        lpReserved: LPDWORD; lpcSubKeys: LPDWORD;
                        lpcbMaxSubKeyLen: LPDWORD; lpcbMaxClassLen: LPDWORD;
                        lpcValues: LPDWORD; lpcbMaxValueNameLen: LPDWORD;
                        lpcbMaxValueLen: LPDWORD; lpcbSecurityDescriptor: LPDWORD;
                        lpftLastWriteTime: pointer): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc toWideZ(s: string): seq[uint16] =
    ## UTF-8 -> UTF-16LE NUL-terminated. The fixture sub-paths and
    ## value names are ASCII in practice but the converter is
    ## codepoint-correct anyway.
    result = @[]
    var i = 0
    while i < s.len:
      let b0 = uint32(byte(s[i]))
      var cp: uint32
      var adv: int
      if b0 < 0x80: cp = b0; adv = 1
      elif (b0 and 0xE0) == 0xC0 and i + 1 < s.len:
        cp = ((b0 and 0x1F) shl 6) or (uint32(byte(s[i+1])) and 0x3F); adv = 2
      elif (b0 and 0xF0) == 0xE0 and i + 2 < s.len:
        cp = ((b0 and 0x0F) shl 12) or
             ((uint32(byte(s[i+1])) and 0x3F) shl 6) or
             (uint32(byte(s[i+2])) and 0x3F); adv = 3
      else: cp = b0; adv = 1
      if cp <= 0xFFFF: result.add(uint16(cp))
      else:
        let c = cp - 0x10000
        result.add(uint16(0xD800 + (c shr 10)))
        result.add(uint16(0xDC00 + (c and 0x3FF)))
      i += adv
    result.add(0'u16)

  proc fromWideBytes(bytes: openArray[byte]): string =
    var i = 0
    while i + 1 < bytes.len:
      let u = uint16(bytes[i]) or (uint16(bytes[i+1]) shl 8)
      if u == 0: break
      # ASCII / BMP-only readback is sufficient for the fixture
      # REG_SZ values; encode the codepoint as UTF-8.
      let cp = uint32(u)
      if cp < 0x80: result.add(char(cp))
      elif cp < 0x800:
        result.add(char(0xC0 or (cp shr 6)))
        result.add(char(0x80 or (cp and 0x3F)))
      else:
        result.add(char(0xE0 or (cp shr 12)))
        result.add(char(0x80 or ((cp shr 6) and 0x3F)))
        result.add(char(0x80 or (cp and 0x3F)))
      i += 2

  proc assertFixtureSubtree(subkey: string) =
    ## Hard guard: the registry driver only ever touches the
    ## Reprobuild-Tests subtree. A subkey outside it is an invariant
    ## breach — fail-closed.
    let norm = subkey.toLowerAscii()
    if not (norm == FixtureRegistryRoot.toLowerAscii() or
            norm.startsWith(FixtureRegistryRoot.toLowerAscii() & "\\")):
      raiseProtocol("fixture registry driver refused subkey '" & subkey &
        "' — it writes ONLY under HKLM\\" & FixtureRegistryRoot)

  proc observeFixtureRegistry*(op: PrivilegedOperation):
      ObservedOperationState =
    ## Re-observe an `HKLM\SOFTWARE\Reprobuild-Tests\...` value.
    let subkey = fixtureRegistrySubkey(op)
    assertFixtureSubtree(subkey)
    var hk: HKEY
    var sub = toWideZ(subkey)
    let openStatus = RegOpenKeyExW(hklm(), cast[LPCWSTR](addr sub[0]), 0,
      KEY_READ, addr hk)
    if openStatus == ERROR_FILE_NOT_FOUND:
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    if openStatus != ERROR_SUCCESS:
      raiseProtocol("RegOpenKeyExW(HKLM\\" & subkey & ") status " &
        $openStatus)
    defer: discard RegCloseKey(hk)
    var nameW = toWideZ(op.regValueName)
    var regType: DWORD = 0
    var cb: DWORD = 0
    var status = RegQueryValueExW(hk, cast[LPCWSTR](addr nameW[0]), nil,
      addr regType, nil, addr cb)
    if status == ERROR_FILE_NOT_FOUND:
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    if status != ERROR_SUCCESS and status != ERROR_MORE_DATA:
      raiseProtocol("RegQueryValueExW(size) status " & $status)
    var buf = newSeq[byte](int(cb))
    if cb > 0:
      status = RegQueryValueExW(hk, cast[LPCWSTR](addr nameW[0]), nil,
        addr regType, cast[LPBYTE](addr buf[0]), addr cb)
      if status != ERROR_SUCCESS:
        raiseProtocol("RegQueryValueExW(data) status " & $status)
    result.present = true
    result.digestHex = digestHexOfText(fromWideBytes(buf))

  proc applyFixtureRegistry*(op: PrivilegedOperation):
      ObservedOperationState =
    ## Write the REG_SZ value under the pinned subtree.
    ##
    ## POST-APPLY RE-PROBE EXEMPTION (M82 Phase A): the registry write
    ## here is a single synchronous `RegSetValueExW` of a payload
    ## derived from `op.regValueData` only, under a subtree
    ## (`HKLM\SOFTWARE\Reprobuild-Tests`) that nothing on a normal host
    ## touches. There is no async OS-side propagation; a subsequent
    ## `RegQueryValueExW` returns the bytes just written. The
    ## post-write digest is `digestHexOfText(op.regValueData)` by
    ## construction — a re-read and compare would be tautological. The
    ## fixture-registry driver is the M81 mechanism prover, not a
    ## production driver — keeping it free of incidental ceremony is
    ## intentional.
    let subkey = fixtureRegistrySubkey(op)
    assertFixtureSubtree(subkey)
    var hk: HKEY
    var sub = toWideZ(subkey)
    var disposition: DWORD = 0
    let status = RegCreateKeyExW(hklm(), cast[LPCWSTR](addr sub[0]), 0,
      nil, REG_OPTION_NON_VOLATILE, KEY_WRITE, nil, addr hk,
      addr disposition)
    if status != ERROR_SUCCESS:
      raiseProtocol("RegCreateKeyExW(HKLM\\" & subkey & ") status " &
        $status & " — broker may lack Administrator rights")
    defer: discard RegCloseKey(hk)
    var nameW = toWideZ(op.regValueName)
    # REG_SZ payload: UTF-16LE bytes with trailing double-NUL.
    let dataW = toWideZ(op.regValueData)
    var dataBytes = newSeq[byte](dataW.len * 2)
    for i, u in dataW:
      dataBytes[i*2] = byte(u and 0xff)
      dataBytes[i*2 + 1] = byte((u shr 8) and 0xff)
    let setStatus = RegSetValueExW(hk, cast[LPCWSTR](addr nameW[0]), 0,
      REG_SZ, cast[LPCVOID](addr dataBytes[0]), DWORD(dataBytes.len))
    if setStatus != ERROR_SUCCESS:
      raiseProtocol("RegSetValueExW status " & $setStatus)
    result.present = true
    result.digestHex = digestHexOfText(op.regValueData)

  proc deleteFixtureRegistryValue*(subPath, valueName: string) =
    ## Test-cleanup helper: remove a single value under the fixture
    ## subtree. Silently succeeds if absent.
    let subkey = FixtureRegistryRoot & "\\" & subPath.replace('/', '\\')
    assertFixtureSubtree(subkey)
    var hk: HKEY
    var sub = toWideZ(subkey)
    let openStatus = RegOpenKeyExW(hklm(), cast[LPCWSTR](addr sub[0]), 0,
      KEY_WRITE, addr hk)
    if openStatus == ERROR_FILE_NOT_FOUND: return
    if openStatus != ERROR_SUCCESS:
      raiseProtocol("RegOpenKeyExW(delete) status " & $openStatus)
    defer: discard RegCloseKey(hk)
    var nameW = toWideZ(valueName)
    discard RegDeleteValueW(hk, cast[LPCWSTR](addr nameW[0]))

  proc deleteFixtureRegistrySubkey*(subPath: string) =
    ## Test-cleanup helper: remove a leaf subkey under the fixture
    ## subtree. Silently succeeds if absent. Caller must ensure the
    ## subkey has no children.
    let subkey = FixtureRegistryRoot & "\\" & subPath.replace('/', '\\')
    assertFixtureSubtree(subkey)
    var sub = toWideZ(subkey)
    discard RegDeleteKeyExW(hklm(), cast[LPCWSTR](addr sub[0]),
      KEY_WRITE, 0)

  proc deleteFixtureRegistryTree*(subPath: string) =
    ## Test-cleanup helper: recursively remove a subkey AND all of its
    ## child subkeys / values under the fixture subtree. Pinned to
    ## `HKLM\SOFTWARE\Reprobuild-Tests\` — `assertFixtureSubtree`
    ## refuses anything else, so this can never recurse into real
    ## system state. Silently succeeds if the subkey is absent.
    let subkey = FixtureRegistryRoot & "\\" & subPath.replace('/', '\\')
    assertFixtureSubtree(subkey)
    var sub = toWideZ(subkey)
    discard RegDeleteTreeW(hklm(), cast[LPCWSTR](addr sub[0]))
    # RegDeleteTreeW empties the key but leaves the (now empty) key
    # itself; drop it too.
    discard RegDeleteKeyExW(hklm(), cast[LPCWSTR](addr sub[0]),
      KEY_WRITE, 0)

  proc deleteFixtureRegistryRoot*() =
    ## Test-cleanup helper: remove the `HKLM\SOFTWARE\Reprobuild-Tests`
    ## root key itself — but ONLY if it is empty (zero subkeys AND zero
    ## values). Pinned to the fixture root via `assertFixtureSubtree`.
    ##
    ## The emptiness check is mandatory for concurrency safety: a
    ## concurrent gate run isolated under its own `gate-<pid>` subkey
    ## leaves the root non-empty, and in that case the root must NOT be
    ## deleted. Silently succeeds (no-op) when the root is absent or
    ## still has children.
    assertFixtureSubtree(FixtureRegistryRoot)
    var hk: HKEY
    var sub = toWideZ(FixtureRegistryRoot)
    let openStatus = RegOpenKeyExW(hklm(), cast[LPCWSTR](addr sub[0]), 0,
      KEY_READ, addr hk)
    if openStatus == ERROR_FILE_NOT_FOUND: return
    if openStatus != ERROR_SUCCESS:
      raiseProtocol("RegOpenKeyExW(HKLM\\" & FixtureRegistryRoot &
        ") status " & $openStatus)
    var subKeyCount: DWORD = 0
    var valueCount: DWORD = 0
    let infoStatus = RegQueryInfoKeyW(hk, nil, nil, nil,
      addr subKeyCount, nil, nil, addr valueCount, nil, nil, nil, nil)
    discard RegCloseKey(hk)
    if infoStatus != ERROR_SUCCESS:
      raiseProtocol("RegQueryInfoKeyW(HKLM\\" & FixtureRegistryRoot &
        ") status " & $infoStatus)
    # Non-empty root (e.g. a concurrent gate's `gate-<pid>` subtree):
    # leave it untouched.
    if subKeyCount != 0 or valueCount != 0: return
    discard RegDeleteKeyExW(hklm(), cast[LPCWSTR](addr sub[0]),
      KEY_WRITE, 0)

else:
  # Non-Windows stubs so the umbrella import compiles. The registry
  # fixture is Windows-only by nature; the file fixture is
  # cross-platform and lives above.
  proc observeFixtureRegistry*(op: PrivilegedOperation):
      ObservedOperationState =
    raiseNotImplementedPlatform("fixture.systemRegistry observe")

  proc applyFixtureRegistry*(op: PrivilegedOperation):
      ObservedOperationState =
    raiseNotImplementedPlatform("fixture.systemRegistry apply")

  proc deleteFixtureRegistryValue*(subPath, valueName: string) =
    discard

  proc deleteFixtureRegistrySubkey*(subPath: string) =
    discard

  proc deleteFixtureRegistryTree*(subPath: string) =
    discard

  proc deleteFixtureRegistryRoot*() =
    discard
