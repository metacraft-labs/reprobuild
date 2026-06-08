## Unit tests for the `REPRO_REGISTRY_ROOT` fake-hive test-isolation
## seam in `drivers/registry.nim`. Runs on every host (the override
## bypasses the Win32 RegOpenKeyExW path so the same assertions hold
## on Windows, macOS and Linux).

import std/[os, tempfiles, unittest]

import repro_home_resources/drivers/registry

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
    check true # no exception thrown

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
