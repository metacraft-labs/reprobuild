## Unit tests for the `REPRO_REGISTRY_ROOT` fake-hive test-isolation
## seam in `drivers/registry.nim`. Runs on every host (the override
## bypasses the Win32 RegOpenKeyExW path so the same assertions hold
## on Windows, macOS and Linux).

import std/[os, strutils, tempfiles, unittest]

import repro_home_resources/drivers/registry
import repro_home_resources/drivers/env_user
import repro_home_resources/test_home_fence
import repro_test_support/reasoned_skip
import repro_test_support/registry_isolation as test_registry_isolation

suite "registry root override (REPRO_REGISTRY_ROOT)":

  setup:
    let hive = createTempDir("repro-reg-override-", "")
    putEnv("REPRO_REGISTRY_ROOT", hive)

  teardown:
    delEnv("REPRO_REGISTRY_ROOT")
    removeDir(hive)

  test "absent value reads as present=false":
    let r = readRegistryValue("Environment", "DoesNotExist")
    check r.present == false
    check r.bytes.len == 0

  test "REG_SZ round-trips byte-exact":
    let payload = encodeString("C:\\Users\\zahary\\scoop\\shims")
    writeRegistryValue("Environment", "Path", 1'u32, payload)
    let r = readRegistryValue("Environment", "Path")
    check r.present
    check r.regType == 1'u32
    check r.bytes == payload

  test "REG_EXPAND_SZ round-trips byte-exact":
    let payload = encodeString("%USERPROFILE%\\bin")
    writeRegistryValue("Environment", "Custom", 2'u32, payload)
    let r = readRegistryValue("Environment", "Custom")
    check r.present
    check r.regType == 2'u32
    check r.bytes == payload

  test "REG_DWORD round-trips byte-exact":
    let payload = encodeDword(0xDEADBEEF'u32)
    writeRegistryValue("Software\\Reprobuild-Tests", "Count", 4'u32, payload)
    let r = readRegistryValue("Software\\Reprobuild-Tests", "Count")
    check r.present
    check r.regType == 4'u32
    check r.bytes == payload

  test "REG_MULTI_SZ round-trips byte-exact":
    let payload = encodeMultiString(["alpha", "beta", "gamma"])
    writeRegistryValue("Software\\Reprobuild-Tests", "List", 7'u32, payload)
    let r = readRegistryValue("Software\\Reprobuild-Tests", "List")
    check r.present
    check r.regType == 7'u32
    check r.bytes == payload
    check decodeMultiString(r.bytes) == @["alpha", "beta", "gamma"]

  test "value-name lookup is case-insensitive (Path == PATH)":
    let payload = encodeString("C:\\one")
    writeRegistryValue("Environment", "Path", 1'u32, payload)
    let r1 = readRegistryValue("Environment", "PATH")
    let r2 = readRegistryValue("Environment", "path")
    let r3 = readRegistryValue("Environment", "Path")
    check r1.present and r2.present and r3.present
    check r1.bytes == payload
    check r2.bytes == payload
    check r3.bytes == payload

  test "subkey lookup is case-insensitive":
    let payload = encodeString("hi")
    writeRegistryValue("Environment", "X", 1'u32, payload)
    let r = readRegistryValue("ENVIRONMENT", "x")
    check r.present
    check r.bytes == payload

  test "subkey accepts both backslash and forward-slash separators":
    let payload = encodeDword(42'u32)
    writeRegistryValue("Software\\Reprobuild-Tests\\Nested", "v", 4'u32, payload)
    let r = readRegistryValue("Software/Reprobuild-Tests/Nested", "v")
    check r.present
    check r.bytes == payload

  test "overwriting a value replaces the previous contents":
    writeRegistryValue("Environment", "Path", 1'u32, encodeString("first"))
    writeRegistryValue("Environment", "Path", 1'u32, encodeString("second"))
    let r = readRegistryValue("Environment", "Path")
    check r.present
    check r.bytes == encodeString("second")

  test "delete makes a value absent":
    writeRegistryValue("Environment", "Tmp", 1'u32, encodeString("x"))
    check readRegistryValue("Environment", "Tmp").present
    deleteRegistryValue("Environment", "Tmp")
    check readRegistryValue("Environment", "Tmp").present == false

  test "deleting an absent value is a no-op (no raise)":
    deleteRegistryValue("Environment", "NeverWritten")
    deleteRegistryValue("NeverCreated\\Subkey", "Anything")
    # ``check true`` used to stand in for "no exception thrown", but an
    # assertion that cannot fail cannot tell "did not raise" from "was never
    # called" -- and it reports [OK] either way. Assert the observable
    # post-state instead: the absent value is still absent, and deleting from
    # a key that does not exist did not conjure it.
    check not readRegistryValue("Environment", "NeverWritten").present
    check not readRegistryValue("NeverCreated\\Subkey", "Anything").present

  test "writes under the override never touch a sibling hive":
    let other = createTempDir("repro-reg-other-", "")
    defer: removeDir(other)
    putEnv("REPRO_REGISTRY_ROOT", other)
    writeRegistryValue("Environment", "Path", 1'u32, encodeString("OTHER"))
    putEnv("REPRO_REGISTRY_ROOT", hive)
    let r = readRegistryValue("Environment", "Path")
    # Either present=false (nothing written under `hive`) or a value
    # written by a previous test in the same `hive` — the assertion is
    # that we did NOT read "OTHER" from the other temp dir.
    if r.present:
      check r.bytes != encodeString("OTHER")

# ---------------------------------------------------------------------------
# The registry half of the test home fence.
#
# reprobuild-pm issue
# 2026-10-23-windows-home-apply-gates-leak-store-prefixes-into-the-real-user-path:
# Windows home-apply gates that forgot `REPRO_REGISTRY_ROOT` wrote their
# sandbox store prefixes into the real `HKCU\Environment\Path`. With
# `REPRO_TEST_HOME_FENCE` set, a write or delete that would reach the real
# hive must raise `TestHomeFenceError` before its first side effect. The
# decision is platform independent, so these cases run on every host; on
# Linux and macOS the unfenced real-hive branch raises the driver's
# "Windows-only" error instead, which is what makes the fenced cases a
# positive control there too (without the fence the expected exception type
# is not the one raised). No registry is mocked: the fenced calls are the
# real driver primitives, and on Windows the real `HKCU\Environment\Path`
# is read before and after to prove it did not change.
# ---------------------------------------------------------------------------

template withRegistryFenceEnv(fence, registryRoot: string; body: untyped) =
  ## Set `REPRO_TEST_HOME_FENCE` / `REPRO_REGISTRY_ROOT` for `body` ("" =
  ## unset) and restore both afterwards, also on failure.
  let priorFence = (existsEnv(TestHomeFenceEnvVar), getEnv(TestHomeFenceEnvVar))
  let priorRoot = (existsEnv(test_home_fence.RegistryRootEnvVar),
    getEnv(test_home_fence.RegistryRootEnvVar))
  if fence.len > 0: putEnv(TestHomeFenceEnvVar, fence)
  else: delEnv(TestHomeFenceEnvVar)
  if registryRoot.len > 0: putEnv(test_home_fence.RegistryRootEnvVar, registryRoot)
  else: delEnv(test_home_fence.RegistryRootEnvVar)
  try:
    body
  finally:
    if priorFence[0]: putEnv(TestHomeFenceEnvVar, priorFence[1])
    else: delEnv(TestHomeFenceEnvVar)
    if priorRoot[0]: putEnv(test_home_fence.RegistryRootEnvVar, priorRoot[1])
    else: delEnv(test_home_fence.RegistryRootEnvVar)

when defined(windows):
  # Key-level cleanup for the real-hive round-trip below. The driver only
  # writes and deletes VALUES (`RegDeleteValueW`), so without this every
  # run would leave an empty `HKCU\Software\Reprobuild-Tests\fence-
  # roundtrip-<pid>` key behind. It is deliberately not a driver
  # primitive: production never deletes keys, and a key-deleting call in
  # the driver would be one more real-hive writer for the fence to guard.
  # https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regdeletekeyw
  # https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regopenkeyexw
  const
    TestHkcu = cast[int](0x80000001'u32)  # HKEY_CURRENT_USER, as the driver spells it
    TestKeyRead = 0x20019'u32
    TestErrorSuccess = 0'i32
    TestErrorFileNotFound = 2'i32

  proc RegDeleteKeyW(hKey: pointer; lpSubKey: ptr uint16): int32
    {.importc, stdcall, dynlib: "advapi32".}
  proc RegOpenKeyExW(hKey: pointer; lpSubKey: ptr uint16; ulOptions: uint32;
                     samDesired: uint32; phkResult: ptr pointer): int32
    {.importc, stdcall, dynlib: "advapi32".}
  proc RegCloseKey(hKey: pointer): int32
    {.importc, stdcall, dynlib: "advapi32".}

  proc asciiUtf16Z(s: string): seq[uint16] =
    ## NUL-terminated UTF-16 of an ASCII subkey (the only kind used here).
    for c in s:
      doAssert ord(c) < 0x80, "asciiUtf16Z: non-ASCII subkey " & s
      result.add(uint16(ord(c)))
    result.add(0'u16)

  proc deleteEmptyScratchKey(subkey: string): int32 =
    ## `RegDeleteKeyW` of a leaf key under the fence's scratch subtree;
    ## the Win32 status. Refuses anything outside the subtree, so a typo
    ## here cannot delete account state.
    doAssert isTestRegistryScratchSubkey(subkey) and
      subkey.len > TestRegistryScratchSubkey.len,
      "deleteEmptyScratchKey: not a key inside the scratch subtree: " & subkey
    var wide = asciiUtf16Z(subkey)
    RegDeleteKeyW(cast[pointer](TestHkcu), addr wide[0])

  proc scratchKeyStatus(subkey: string): int32 =
    ## `RegOpenKeyExW` status for `HKCU\<subkey>` (2 = absent).
    var wide = asciiUtf16Z(subkey)
    var hk: pointer
    result = RegOpenKeyExW(cast[pointer](TestHkcu), addr wide[0], 0,
      TestKeyRead, addr hk)
    if result == TestErrorSuccess:
      discard RegCloseKey(hk)

proc realUserPathSnapshot(): string =
  ## The real user PATH value, raw, on Windows (where `readUserPathRaw`
  ## reads `HKCU\Environment\Path` -- call it only with the seam unset);
  ## "" elsewhere, where there is no user registry to protect.
  when defined(windows):
    let r = readUserPathRaw()
    $r.present & "|" & $r.regType & "|" & r.raw
  else:
    ""

suite "test home fence: registry writes":

  test "the test-support seam and the driver spell the variable alike":
    check test_registry_isolation.RegistryRootEnvVar ==
      test_home_fence.RegistryRootEnvVar
    let entry = registryRootEnv("scratch")
    check entry.k == test_home_fence.RegistryRootEnvVar
    check entry.v == "scratch" / "registry"

  test "decision: refuse only a fenced, unredirected write outside the scratch subkey":
    const Fence = "/home/someone"
    # Fence off: never refused, whatever the target.
    check not testRegistryFenceRefuses("Environment", "", "")
    check not testRegistryFenceRefuses("Environment", "  ", "")
    # Fence on, redirected into a fake hive: not refused.
    check not testRegistryFenceRefuses("Environment", Fence, "/tmp/hive")
    # Fence on, real hive: refused for the user's account state ...
    check testRegistryFenceRefuses("Environment", Fence, "")
    check testRegistryFenceRefuses("HKCU\\Environment", Fence, "")
    check testRegistryFenceRefuses(
      "Software\\Microsoft\\Windows\\CurrentVersion\\Run", Fence, "")
    # ... but not inside the scratch subtree the real-hive gates use,
    # matched case-insensitively.
    check not testRegistryFenceRefuses("Software\\Reprobuild-Tests", Fence, "")
    check not testRegistryFenceRefuses(
      "Software\\Reprobuild-Tests\\m68-gate1-1", Fence, "")
    check not testRegistryFenceRefuses(
      "software\\REPROBUILD-TESTS\\x", Fence, "")
    check isTestRegistryScratchSubkey("Software\\Reprobuild-Tests\\a\\b")
    # The match is on the string Win32 receives, which normalises nothing
    # but case: each spelling below names a key OUTSIDE the scratch
    # subtree (`/` is a name character, a leading `HKCU\` names a key
    # called `HKCU`), so each is refused.
    for outside in [
        "Software\\Reprobuild-Tests-Other",
        "Software\\Reprobuild-TestsX\\a",
        "Software",
        "Software/Reprobuild-Tests/x",
        "Software\\Reprobuild-Tests/x",
        "HKCU\\Software\\Reprobuild-Tests\\x",
        "HKEY_CURRENT_USER\\software\\REPROBUILD-TESTS\\x",
        "\\Software\\Reprobuild-Tests\\x",
        "Software\\\\Reprobuild-Tests\\x",
        "Software\\Reprobuild-Tests\\",
        "Software\\Reprobuild-Tests\\x\\\\y",
        "Software\\Reprobuild-Tests\\..",
        "Software\\Reprobuild-Tests\\..\\..\\Environment",
        "Software\\Reprobuild-Tests\\.\\x",
        ""]:
      checkpoint "outside: " & outside
      check testRegistryFenceRefuses(outside, Fence, "")
      check not isTestRegistryScratchSubkey(outside)

  test "fenced writes and deletes of the real hive raise and change nothing":
    let fakeHome = createTempDir("repro-reg-fence-home-", "")
    defer: removeDir(fakeHome)
    withRegistryFenceEnv("", ""):
      let before = realUserPathSnapshot()
      withRegistryFenceEnv(fakeHome, ""):
        check testRegistryFenceViolation("Environment")
        expect TestHomeFenceError:
          discard resolveRegistryWriteTarget("Environment", "Path", "probe")
        expect TestHomeFenceError:
          writeRegistryValue("Environment", "Path", 1'u32,
            encodeString("C:\\leak\\bin"))
        expect TestHomeFenceError:
          deleteRegistryValue("Environment", "Path")
        expect TestHomeFenceError:
          writeRegistryValue(
            "Software\\Microsoft\\Windows\\CurrentVersion\\Run",
            "repro-fence-leak", 1'u32, encodeString("C:\\leak.exe"))
        when defined(windows):
          # The env.userPath driver, the issue's leak, reaches the same
          # primitive. (Off Windows it writes an rc file instead, which
          # the path half of the fence covers in t_smoke_home_resources.)
          expect TestHomeFenceError:
            discard applyUserPath(@["C:\\leak\\bin"], @[])
        # The message names the refused key and both variables.
        try:
          writeRegistryValue("Environment", "Path", 1'u32,
            encodeString("C:\\leak\\bin"))
          check false
        except TestHomeFenceError as e:
          check e.path == "HKCU\\Environment\\Path"
          check e.protectedRoot == "HKCU"
          check TestHomeFenceEnvVar in e.msg
          check test_home_fence.RegistryRootEnvVar in e.msg
          check "registryRootEnv" in e.msg
      check realUserPathSnapshot() == before

  test "the fence lets a write through where the seam redirects it":
    let fakeHome = createTempDir("repro-reg-fence-home-", "")
    let hive = createTempDir("repro-reg-fence-hive-", "")
    defer:
      removeDir(fakeHome)
      removeDir(hive)
    withRegistryFenceEnv(fakeHome, hive):
      check not testRegistryFenceViolation("Environment")
      let target = resolveRegistryWriteTarget("Environment", "Path", "probe")
      check target.kind == rtkFakeHive
      check target.root == hive
      writeRegistryValue("Environment", "Path", 1'u32,
        encodeString("C:\\sandbox\\bin"))
      let r = readRegistryValue("Environment", "Path")
      check r.present
      check r.bytes == encodeString("C:\\sandbox\\bin")
      check fileExists(hive / "environment" / "path.regval")
      deleteRegistryValue("Environment", "Path")
      check not readRegistryValue("Environment", "Path").present

  test "unfenced, or inside the scratch subkey, the real hive stays the target":
    let fakeHome = createTempDir("repro-reg-fence-home-", "")
    defer: removeDir(fakeHome)
    # Only resolved, never written: these name the real hive.
    withRegistryFenceEnv("", ""):
      check resolveRegistryWriteTarget("Environment", "Path",
        "probe").kind == rtkRealHive
    withRegistryFenceEnv(fakeHome, ""):
      check resolveRegistryWriteTarget(
        "Software\\Reprobuild-Tests\\fence-probe", "v",
        "probe").kind == rtkRealHive

  test "fenced, the real Win32 hive still round-trips every typed kind under the scratch subkey":
    # The m68 gates run against the fake hive (their applies also write the
    # user PATH); this case keeps the real `RegSetValueExW` /
    # `RegQueryValueExW` / `RegDeleteValueW` path covered, byte for byte,
    # on the one subtree the fence leaves open. Windows only: elsewhere
    # there is no real hive.
    when not defined(windows):
      skip("platform N/A: needs the real Windows registry (eli-pc runs it)")
    else:
      let fakeHome = createTempDir("repro-reg-fence-home-", "")
      defer: removeDir(fakeHome)
      let subkey = TestRegistryScratchSubkey & "\\fence-roundtrip-" &
        $getCurrentProcessId()
      let kinds = @[
        ("v_string", 1'u32, encodeString("hello-world")),
        ("v_expand", 2'u32, encodeString("%USERPROFILE%\\bin")),
        ("v_binary", 3'u32, @[byte(0xDE), byte(0xAD), byte(0xBE), byte(0xEF)]),
        ("v_dword", 4'u32, encodeDword(0x12345678'u32)),
        ("v_multi", 7'u32, encodeMultiString(@["alpha", "beta"])),
        ("v_qword", 11'u32, encodeQword(81985529216486895'u64))]
      withRegistryFenceEnv(fakeHome, ""):
        let pathBefore = realUserPathSnapshot()
        try:
          for (name, regType, bytes) in kinds:
            check resolveRegistryWriteTarget(subkey, name,
              "probe").kind == rtkRealHive
            writeRegistryValue(subkey, name, regType, bytes)
            let r = readRegistryValue(subkey, name)
            check r.present
            check r.regType == regType
            check r.bytes == bytes
        finally:
          for (name, _, _) in kinds:
            deleteRegistryValue(subkey, name)
          # Values gone, remove the now-empty per-run key too, so runs do
          # not accumulate keys under the scratch subtree.
          let deleteStatus = deleteEmptyScratchKey(subkey)
          check deleteStatus in [TestErrorSuccess, TestErrorFileNotFound]
        for (name, _, _) in kinds:
          check not readRegistryValue(subkey, name).present
        check scratchKeyStatus(subkey) == TestErrorFileNotFound
        check realUserPathSnapshot() == pathBefore
