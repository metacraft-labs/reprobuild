## M63 Part C: VersionedProvisioning schema tests.
##
## Exercises:
##   * positive construction + record-shape round-trip;
##   * ``jdkCatalog``'s JDK 21.0.5 entry carries every expected field
##     (URL, SHA-256, archive_format, extract_path, bin_relpath,
##     install_method, env);
##   * ``validateVersionedProvisioning`` rejects entries without any
##     SHA (and accepts entries with exactly one);
##   * ``validateVersionedProvisioning`` rejects entries with BOTH
##     ``sha256`` and ``sha512`` (per the M63 spec);
##   * ``selectPlatformBinary`` resolves per-(cpu, os) tuples and
##     falls back to ``pcAny`` / ``poAny`` slots;
##   * ``selectDefault`` returns the LAST entry in declaration order;
##   * ``serializeAsCode`` round-trips the JDK reference entry (proxy
##     for the M66 harvester's "byte-identical re-runs" requirement).

import std/[strutils, tables, unittest]
import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/packages/jdk

suite "M63 — VersionedProvisioning schema":

  test "positive construction: minimal imExtract record validates":
    let pb = initPlatformBinary(
      cpu = pcX86_64,
      os = poWindows,
      url = "https://example.test/tool.zip",
      sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      extract_path = "tool-1.0.0",
    )
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      install_method = imExtract,
      bin_relpath = @["bin/tool.exe"],
      platforms = @[pb],
      env = {"TOOL_HOME": "${prefix}"},
    )
    let errors = validateVersionedProvisioning(vp)
    check errors.len == 0
    check vp.version == "1.0.0"
    check vp.archive_format == afZip
    check vp.platforms.len == 1
    check vp.platforms[0].url == "https://example.test/tool.zip"
    check vp.env["TOOL_HOME"] == "${prefix}"

  test "negative: missing url is rejected":
    let pb = PlatformBinary(
      cpu: pcX86_64, os: poWindows,
      url: "",
      sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      bin_relpath = @["bin/tool.exe"],
      platforms = @[pb])
    let errors = validateVersionedProvisioning(vp)
    check errors.len >= 1
    var sawUrl = false
    for e in errors:
      if "url is required" in e:
        sawUrl = true
    check sawUrl

  test "negative: missing all of sha256 / sha512 / sha1 is rejected":
    let pb = PlatformBinary(
      cpu: pcX86_64, os: poWindows,
      url: "https://example.test/tool.zip")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      bin_relpath = @["bin/tool.exe"],
      platforms = @[pb])
    let errors = validateVersionedProvisioning(vp)
    check errors.len >= 1
    var sawSha = false
    for e in errors:
      if "at least one of sha256 / sha512 / sha1" in e:
        sawSha = true
    check sawSha

  test "negative: BOTH sha256 and sha512 set is rejected":
    let pb = PlatformBinary(
      cpu: pcX86_64, os: poWindows,
      url: "https://example.test/tool.zip",
      sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      sha512: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" &
              "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      bin_relpath = @["bin/tool.exe"],
      platforms = @[pb])
    let errors = validateVersionedProvisioning(vp)
    check errors.len >= 1
    var sawConflict = false
    for e in errors:
      if "only one of sha256 / sha512 / sha1" in e:
        sawConflict = true
    check sawConflict

  test "positive: sha512-only is accepted":
    let pb = PlatformBinary(
      cpu: pcX86_64, os: poLinux,
      url: "https://example.test/tool.tar.gz",
      sha512: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" &
              "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afTarGz,
      bin_relpath = @["bin/tool"],
      platforms = @[pb])
    check validateVersionedProvisioning(vp).len == 0

  test "negative: non-hex sha256 is rejected":
    let pb = PlatformBinary(
      cpu: pcX86_64, os: poWindows,
      url: "https://example.test/tool.zip",
      sha256: "ZZZZ56789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      bin_relpath = @["bin/tool.exe"],
      platforms = @[pb])
    let errors = validateVersionedProvisioning(vp)
    var sawHex = false
    for e in errors:
      if "hex-encoded" in e:
        sawHex = true
    check sawHex

  test "negative: wrong-length sha256 is rejected":
    let pb = PlatformBinary(
      cpu: pcX86_64, os: poWindows,
      url: "https://example.test/tool.zip",
      sha256: "abcd")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      bin_relpath = @["bin/tool.exe"],
      platforms = @[pb])
    let errors = validateVersionedProvisioning(vp)
    var sawLen = false
    for e in errors:
      if "64-char hex digest" in e:
        sawLen = true
    check sawLen

  test "negative: imExtract without bin_relpath is rejected":
    let pb = initPlatformBinary(
      cpu = pcX86_64, os = poWindows,
      url = "https://example.test/tool.zip",
      sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      install_method = imExtract,
      platforms = @[pb])
    let errors = validateVersionedProvisioning(vp)
    var sawBin = false
    for e in errors:
      if "bin_relpath" in e:
        sawBin = true
    check sawBin

  test "negative: imMsys2Pacman without pacman_packages is rejected":
    let pb = initPlatformBinary(
      cpu = pcX86_64, os = poWindows,
      url = "https://example.test/dummy",
      sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    let vp = initVersionedProvisioning(
      version = "5.2.0",
      archive_format = afRaw,
      install_method = imMsys2Pacman,
      platforms = @[pb])
    let errors = validateVersionedProvisioning(vp)
    var sawPac = false
    for e in errors:
      if "pacman_packages" in e:
        sawPac = true
    check sawPac

  test "negative: duplicate (cpu, os) pair is rejected":
    let pb1 = initPlatformBinary(
      cpu = pcX86_64, os = poWindows,
      url = "https://example.test/a.zip",
      sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    let pb2 = initPlatformBinary(
      cpu = pcX86_64, os = poWindows,
      url = "https://example.test/b.zip",
      sha256 = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      bin_relpath = @["bin/tool.exe"],
      platforms = @[pb1, pb2])
    let errors = validateVersionedProvisioning(vp)
    var sawDup = false
    for e in errors:
      if "duplicate" in e:
        sawDup = true
    check sawDup

  test "per-platform resolution: exact match wins":
    let pbWin = initPlatformBinary(
      cpu = pcX86_64, os = poWindows,
      url = "win-url",
      sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    let pbLinux = initPlatformBinary(
      cpu = pcX86_64, os = poLinux,
      url = "linux-url",
      sha256 = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210")
    let pbArm = initPlatformBinary(
      cpu = pcAArch64, os = poWindows,
      url = "arm-win-url",
      sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      bin_relpath = @["bin/tool.exe"],
      platforms = @[pbWin, pbLinux, pbArm])

    let win = selectPlatformBinary(vp, pcX86_64, poWindows)
    check win.found
    check win.binary.url == "win-url"

    let lnx = selectPlatformBinary(vp, pcX86_64, poLinux)
    check lnx.found
    check lnx.binary.url == "linux-url"

    let arm = selectPlatformBinary(vp, pcAArch64, poWindows)
    check arm.found
    check arm.binary.url == "arm-win-url"

    let missing = selectPlatformBinary(vp, pcAArch64, poLinux)
    check not missing.found

  test "per-platform resolution: pcAny fallback":
    let pbAny = initPlatformBinary(
      cpu = pcAny, os = poLinux,
      url = "any-cpu-linux",
      sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afTarGz,
      bin_relpath = @["bin/tool"],
      platforms = @[pbAny])
    let r = selectPlatformBinary(vp, pcX86_64, poLinux)
    check r.found
    check r.binary.url == "any-cpu-linux"

  test "selectDefault picks LAST entry":
    let pb = initPlatformBinary(
      cpu = pcX86_64, os = poWindows,
      url = "https://example.test/x.zip",
      sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    let v1 = initVersionedProvisioning(
      version = "1.0.0", archive_format = afZip,
      bin_relpath = @["bin/x.exe"], platforms = @[pb])
    let v2 = initVersionedProvisioning(
      version = "2.0.0", archive_format = afZip,
      bin_relpath = @["bin/x.exe"], platforms = @[pb])
    let catalog = @[v1, v2]
    let d = selectDefault(catalog)
    check d.found
    check d.entry.version == "2.0.0"

  test "selectVersion picks the exact-match entry":
    let pb = initPlatformBinary(
      cpu = pcX86_64, os = poWindows,
      url = "https://example.test/x.zip",
      sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    let v1 = initVersionedProvisioning(
      version = "1.0.0", archive_format = afZip,
      bin_relpath = @["bin/x.exe"], platforms = @[pb])
    let v2 = initVersionedProvisioning(
      version = "2.0.0", archive_format = afZip,
      bin_relpath = @["bin/x.exe"], platforms = @[pb])
    let catalog = @[v1, v2]
    let r = selectVersion(catalog, "1.0.0")
    check r.found
    check r.entry.version == "1.0.0"
    let missing = selectVersion(catalog, "3.0.0")
    check not missing.found

  test "validateCatalog rejects duplicate version":
    let pb = initPlatformBinary(
      cpu = pcX86_64, os = poWindows,
      url = "https://example.test/x.zip",
      sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    let v1 = initVersionedProvisioning(
      version = "1.0.0", archive_format = afZip,
      bin_relpath = @["bin/x.exe"], platforms = @[pb])
    let v2 = initVersionedProvisioning(
      version = "1.0.0", archive_format = afZip,
      bin_relpath = @["bin/x.exe"], platforms = @[pb])
    let errors = validateCatalog([v1, v2])
    var sawDup = false
    for e in errors:
      if "duplicate version" in e:
        sawDup = true
    check sawDup

  # =========================================================================
  # M1 (Realize-Closure spec) — sha1 weak-hash acceptance.
  # =========================================================================

  test "test_m1_schema_accepts_sha1":
    ## sha1-only entry validates with 0 errors + 1 warning (the weak-
    ## hash deprecation).
    let pb = PlatformBinary(
      cpu: pcX86_64, os: poWindows,
      url: "https://example.test/tool.zip",
      sha1: "0123456789abcdef0123456789abcdef01234567")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      install_method = imExtract,
      bin_relpath = @["bin/tool.exe"],
      platforms = @[pb])
    var warnings: seq[string] = @[]
    let errors = validateVersionedProvisioningEx(vp, warnings)
    if errors.len > 0:
      checkpoint "errors: " & errors.join(" | ")
    check errors.len == 0
    check warnings.len == 1
    check "sha1 digest is weaker than sha256" in warnings[0]

  test "test_m1_schema_accepts_sha1: 40-char non-hex rejected":
    let pb = PlatformBinary(
      cpu: pcX86_64, os: poWindows,
      url: "https://example.test/tool.zip",
      sha1: "ZZZZ56789abcdef0123456789abcdef0123456789")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      install_method = imExtract,
      bin_relpath = @["bin/tool.exe"],
      platforms = @[pb])
    var warnings: seq[string] = @[]
    let errors = validateVersionedProvisioningEx(vp, warnings)
    var sawHex = false
    for e in errors:
      if "sha1 must be hex-encoded" in e:
        sawHex = true
    check sawHex
    # No deprecation warning when the digest is malformed.
    check warnings.len == 0

  test "test_m1_schema_accepts_sha1: wrong-length sha1 rejected":
    let pb = PlatformBinary(
      cpu: pcX86_64, os: poWindows,
      url: "https://example.test/tool.zip",
      sha1: "abcd")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      install_method = imExtract,
      bin_relpath = @["bin/tool.exe"],
      platforms = @[pb])
    var warnings: seq[string] = @[]
    let errors = validateVersionedProvisioningEx(vp, warnings)
    var sawLen = false
    for e in errors:
      if "40-char hex digest" in e:
        sawLen = true
    check sawLen

  test "test_m1_schema_accepts_sha1: sha1 + sha256 mutex preserved":
    let pb = PlatformBinary(
      cpu: pcX86_64, os: poWindows,
      url: "https://example.test/tool.zip",
      sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      sha1:   "0123456789abcdef0123456789abcdef01234567")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      install_method = imExtract,
      bin_relpath = @["bin/tool.exe"],
      platforms = @[pb])
    var warnings: seq[string] = @[]
    let errors = validateVersionedProvisioningEx(vp, warnings)
    var sawMutex = false
    for e in errors:
      if "only one of sha256 / sha512 / sha1" in e:
        sawMutex = true
    check sawMutex

  test "test_m1_schema_serializeAsCode_emits_sha1_last":
    let pb = PlatformBinary(
      cpu: pcX86_64, os: poWindows,
      url: "https://example.test/tool.zip",
      sha1: "0123456789abcdef0123456789abcdef01234567",
      extract_path: "tool-1.0.0")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      install_method = imExtract,
      bin_relpath = @["bin/tool.exe"],
      platforms = @[pb])
    let src = serializeAsCode(vp)
    check "sha1: \"0123456789abcdef0123456789abcdef01234567\"" in src
    let sha256Idx = src.find("sha256:")
    let sha512Idx = src.find("sha512:")
    let sha1Idx = src.find("sha1:")
    check sha256Idx >= 0
    check sha512Idx > sha256Idx
    check sha1Idx > sha512Idx

  test "test_m1_schema_warning_on_sha1_only":
    ## The warning IS emitted when only sha1 is set, and is NOT emitted
    ## when sha256 is also set (the sha1 field there would be a schema
    ## mutex error, not a deprecation case).
    let pbSha1 = PlatformBinary(
      cpu: pcX86_64, os: poWindows,
      url: "https://example.test/tool.zip",
      sha1: "0123456789abcdef0123456789abcdef01234567")
    let pbSha256 = PlatformBinary(
      cpu: pcX86_64, os: poWindows,
      url: "https://example.test/tool.zip",
      sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    var warningsSha1: seq[string] = @[]
    var warningsSha256: seq[string] = @[]
    discard validatePlatformBinaryEx(pbSha1, 0, warningsSha1)
    discard validatePlatformBinaryEx(pbSha256, 0, warningsSha256)
    check warningsSha1.len == 1
    check warningsSha256.len == 0

  test "serializeAsCode emits a non-empty Nim fragment":
    let pb = initPlatformBinary(
      cpu = pcX86_64, os = poWindows,
      url = "https://example.test/x.zip",
      sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      extract_path = "x-1.0.0")
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afZip,
      install_method = imExtract,
      bin_relpath = @["bin/x.exe"],
      platforms = @[pb],
      env = {"X_HOME": "${prefix}"})
    let src = serializeAsCode(vp)
    check "VersionedProvisioning" in src
    check "version: \"1.0.0\"" in src
    check "afZip" in src
    check "imExtract" in src
    check "bin/x.exe" in src
    check "https://example.test/x.zip" in src
    check "X_HOME" in src
    check "${prefix}" in src

suite "M63 — jdkCatalog reference entry":

  test "jdkCatalog has exactly one entry (M63 scope: only 21.0.5)":
    check jdkCatalog.len == 1

  test "jdkCatalog passes validateCatalog":
    let errors = validateCatalog(jdkCatalog)
    if errors.len > 0:
      checkpoint "errors: " & errors.join(" | ")
    check errors.len == 0

  test "jdkCatalog[0] is JDK 21.0.5":
    let e = jdkCatalog[0]
    check e.version == "21.0.5"
    check e.archive_format == afZip
    check e.install_method == imExtract

  test "jdkCatalog[0] bin_relpath includes javac.exe + java.exe":
    let e = jdkCatalog[0]
    check "bin/javac.exe" in e.bin_relpath
    check "bin/java.exe" in e.bin_relpath
    check "bin/jar.exe" in e.bin_relpath
    check "bin/jlink.exe" in e.bin_relpath

  test "jdkCatalog[0] env carries JAVA_HOME = ${prefix}":
    let e = jdkCatalog[0]
    check e.env.hasKey("JAVA_HOME")
    check e.env["JAVA_HOME"] == "${prefix}"

  test "jdkCatalog[0] Windows x86_64 platform: URL + SHA-256 + extract_path":
    let r = selectPlatformBinary(jdkCatalog[0], pcX86_64, poWindows)
    check r.found
    check r.binary.url == "https://github.com/adoptium/temurin21-binaries/" &
      "releases/download/jdk-21.0.5%2B11/" &
      "OpenJDK21U-jdk_x64_windows_hotspot_21.0.5_11.zip"
    check r.binary.sha256 ==
      "6f09d4a3598542313cca1540106d537c7092a54e415d569f7b928160a90d3128"
    check r.binary.extract_path == "jdk-21.0.5+11"
    check r.binary.sha512 == ""

  test "jdkCatalog[0] selectDefault returns the 21.0.5 entry":
    let d = selectDefault(jdkCatalog)
    check d.found
    check d.entry.version == "21.0.5"

  test "jdkCatalog[0] selectVersion('21.0.5') is found":
    let r = selectVersion(jdkCatalog, "21.0.5")
    check r.found
    check r.entry.version == "21.0.5"

  test "jdkCatalog[0] selectVersion('99.0.0') is not found":
    let r = selectVersion(jdkCatalog, "99.0.0")
    check not r.found
