## M5 (Realize-Closure-And-Catalog-Expansion spec) — cakBuiltin
## Scoop-style launcher emit tests for the composer .phar shape.
##
## All tests are HERMETIC: artifacts are served from ``file://`` URLs
## pointing at fixtures the test materializes on disk; the php
## interpreter is a synthetic stub seeded into the store via
## ``realizePrefix`` so the discovery path resolves without a real php
## install. The end-to-end live smoke (``package(php) +
## package(composer)`` → ``composer --version``) is the M5 LIVE
## verification gate (``REPRO_M5_LIVE=1``) and lives in the hand-off
## transcript rather than as an automated test.

import std/[os, strutils, tables, unittest]
from repro_core/paths import extendedPath

import repro_local_store
import repro_dsl_stdlib/packages_schema

import repro_home_apply/package_catalog
import repro_home_apply/builtin_adapter

const FixtureRoot = "build/test-tmp/t-builtin-adapter-launcher-emit-composer"

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc fileToUrl(absPath: string): string =
  let normalized = absPath.replace('\\', '/')
  when defined(windows):
    if normalized.len >= 2 and normalized[1] == ':':
      "file:///" & normalized
    else:
      "file://" & normalized
  else:
    "file://" & normalized

proc writePayloadFile(path: string; content: string): string =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), content)
  fileShaHex(path, "sha256")

proc seedPhpPrefix(store: var Store; stubContent: string): string =
  ## Seed a synthetic ``php`` catalog prefix carrying a php.exe stub
  ## at the prefix root (matches php.nim's bin_relpath layout). The
  ## stub is a plain text file — the launcher emit test does NOT
  ## execute it, only verifies the discovery picked it up + the
  ## launcher text references its absolute path.
  let prefixId = computeRealizationHash("php", "test-seed-php",
    "builtin", "sha256:seed-php", "php.exe",
    "file:///seed-php", "seed-php", @["fixture"])
  let hint = StoreReceiptHint(
    adapter: "builtin",
    packageName: "php",
    version: "test-seed-php",
    declaredExecutablePath: "php.exe",
    exportedExecutables: @["php.exe"],
    lockIdentity: "sha256:seed-php",
    provenanceUrl: "file:///seed-php",
    provenanceChecksum: "sha256:seed-php",
    materializationMechanism: "raw+extract")
  let outcome = realizePrefix(store, prefixId, hint,
    proc (stagingDir: string; mechanism: var string) =
      writeFile(extendedPath(stagingDir / "php.exe"), stubContent)
      mechanism = "copy")
  outcome.absolutePath

suite "M5 — cakBuiltin Scoop-style launcher emit (composer .phar)":

  test "test_m5_launcher_emit_composer_phar_realize_synthesizes_ps1_and_cmd":
    ## End-to-end realize of a synthetic composer catalog entry. The
    ## .phar payload is downloaded via file://, copied to the prefix
    ## root via afRaw with the launcher_emit-aware target redirect,
    ## then the launcher emit step writes bin/composer.ps1 +
    ## bin/composer.cmd. Both launchers reference the seeded php
    ## interpreter's absolute path + the prefix-relative
    ## composer.phar.
    let fixtureDir = FixtureRoot / "phar-realize"
    let storeDir = fixtureDir / "store"
    let payloadDir = fixtureDir / "payload"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(payloadDir)

    var store = openStore(storeDir)
    defer: store.close()

    # Seed the php interpreter prefix so discoverPhpExe finds it via the
    # catalog-registered prefix path (step (i) of the M5 discovery order).
    let phpPrefixAbs = seedPhpPrefix(store, "fake-php-stub\n")
    let expectedPhpExe = phpPrefixAbs / "php.exe"
    check fileExists(extendedPath(expectedPhpExe))

    let payload = "<?php /* fake composer phar bytes */ ?>\n"
    let payloadPath = payloadDir / "composer.phar"
    let sha = writePayloadFile(payloadPath, payload)
    let url = fileToUrl(absolutePath(payloadPath))

    let vp = initVersionedProvisioning(
      version = "2.10.0",
      archive_format = afRaw,
      install_method = imExtract,
      bin_relpath = @["bin/composer.ps1", "bin/composer.cmd"],
      platforms = @[
        initPlatformBinary(
          cpu = pcAny, os = detectHostOs(),
          url = url,
          sha256 = sha)
      ],
      launcher_emit = @[
        LauncherEmitSpec(kind: lekPhar, target: "composer.phar",
          interpreter_package_id: "php", launcher_name: "composer")
      ])

    # Validator must accept the new shape (launcher_name in bin_relpath).
    check validateVersionedProvisioning(vp).len == 0

    let res = resolveBuiltinPackage("composer", @[vp])
    check res.found
    check res.resolution.launcherEmit.len == 1
    check res.resolution.launcherEmit[0].kind == lekPhar
    check res.resolution.launcherEmit[0].target == "composer.phar"

    let outR = realizeBuiltinPackage(store, res.resolution)
    check (not outR.cacheHit)
    let prefixAbs = outR.prefixAbsolutePath

    # The .phar payload landed at the prefix root.
    let realizedPhar = prefixAbs / "composer.phar"
    check fileExists(extendedPath(realizedPhar))
    check readFile(extendedPath(realizedPhar)) == payload

    # Both launchers exist.
    let ps1Path = prefixAbs / "bin" / "composer.ps1"
    let cmdPath = prefixAbs / "bin" / "composer.cmd"
    check fileExists(extendedPath(ps1Path))
    check fileExists(extendedPath(cmdPath))

    # Launcher contents reference the seeded php (absolute baked path)
    # and the .phar target VIA $PSScriptRoot / %~dp0 (relative to the
    # launcher's own bin/ directory so the launcher works after
    # realizePrefix's atomic rename).
    let ps1Body = readFile(extendedPath(ps1Path))
    check ps1Body.contains(expectedPhpExe)
    check ps1Body.contains("$PSScriptRoot")
    check ps1Body.contains("composer.phar")
    check ps1Body.contains("lekPhar")
    # The target is referenced relative to bin/ (one dir up).
    check ps1Body.contains("..\\composer.phar")

    let cmdBody = readFile(extendedPath(cmdPath))
    check cmdBody.contains(expectedPhpExe)
    check cmdBody.contains("%~dp0")
    check cmdBody.contains("composer.phar")
    check cmdBody.contains("..\\composer.phar")

  test "test_m5_launcher_emit_idempotent_bytes_across_reruns":
    ## A second realize against the same inputs is a cache-hit (the
    ## prefix digest covers the launcher bytes; identical inputs
    ## produce identical output). Verify by capturing the realized
    ## prefix path on run 1, re-running with the source payload
    ## removed, and checking the launcher bytes match.
    let fixtureDir = FixtureRoot / "phar-idempotent"
    let storeDir = fixtureDir / "store"
    let payloadDir = fixtureDir / "payload"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(payloadDir)
    var store = openStore(storeDir)
    defer: store.close()
    discard seedPhpPrefix(store, "fake-php-stub\n")

    let payload = "<?php /* idempotent */ ?>\n"
    let payloadPath = payloadDir / "composer.phar"
    let sha = writePayloadFile(payloadPath, payload)
    let url = fileToUrl(absolutePath(payloadPath))

    let vp = initVersionedProvisioning(
      version = "2.10.0",
      archive_format = afRaw,
      install_method = imExtract,
      bin_relpath = @["bin/composer.ps1", "bin/composer.cmd"],
      platforms = @[
        initPlatformBinary(cpu = pcAny, os = detectHostOs(),
          url = url, sha256 = sha)
      ],
      launcher_emit = @[
        LauncherEmitSpec(kind: lekPhar, target: "composer.phar",
          interpreter_package_id: "php", launcher_name: "composer")
      ])
    let res = resolveBuiltinPackage("composer", @[vp])
    check res.found

    let out1 = realizeBuiltinPackage(store, res.resolution)
    check (not out1.cacheHit)
    let ps1Bytes1 = readFile(extendedPath(
      out1.prefixAbsolutePath / "bin" / "composer.ps1"))
    let cmdBytes1 = readFile(extendedPath(
      out1.prefixAbsolutePath / "bin" / "composer.cmd"))

    # Remove the source so a second download FAILS; the cache-hit must
    # skip download AND launcher emit (the prefix is already realized).
    removeFile(extendedPath(payloadPath))
    let out2 = realizeBuiltinPackage(store, res.resolution)
    check out2.cacheHit
    check out2.prefixId == out1.prefixId
    let ps1Bytes2 = readFile(extendedPath(
      out2.prefixAbsolutePath / "bin" / "composer.ps1"))
    let cmdBytes2 = readFile(extendedPath(
      out2.prefixAbsolutePath / "bin" / "composer.cmd"))
    check ps1Bytes1 == ps1Bytes2
    check cmdBytes1 == cmdBytes2

  test "test_m5_launcher_emit_php_missing_fails_closed_with_remediation":
    ## When php is not in the store AND not on PATH, the realize hook
    ## raises EBuiltinPhpUnavailable BEFORE any download / extraction
    ## happens (the discovery runs outside the staging closure). The
    ## error names the missing catalog package + the ``repro home add``
    ## remediation.
    let fixtureDir = FixtureRoot / "phar-no-php"
    let storeDir = fixtureDir / "store"
    let payloadDir = fixtureDir / "payload"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(payloadDir)

    # Materialize the payload + compute SHA BEFORE stripping PATH (the
    # sha-tool discovery needs PATH; the discovery-failure check runs
    # AFTER setup).
    let payload = "stub-phar\n"
    let payloadPath = payloadDir / "composer.phar"
    let sha = writePayloadFile(payloadPath, payload)
    let url = fileToUrl(absolutePath(payloadPath))

    # Strip PATH so findExe("php.exe") returns "". The download path
    # uses file:// (no curl needed) and SHA verification is done by
    # discoverInterpreterExe-time but with hashing in the staging
    # closure. The discoverPhpExe call runs OUTSIDE the staging closure
    # so it raises BEFORE the download/hash attempt — no need for
    # sha-tool discovery in the fail-closed path.
    let emptyDir = fixtureDir / "empty-path"
    resetDir(emptyDir)
    let savedPath = getEnv("PATH")
    putEnv("PATH", emptyDir)
    defer: putEnv("PATH", savedPath)

    var store = openStore(storeDir)
    defer: store.close()
    # NB: NO seedPhpPrefix call — store has no php prefix.

    let vp = initVersionedProvisioning(
      version = "2.10.0",
      archive_format = afRaw,
      install_method = imExtract,
      bin_relpath = @["bin/composer.ps1", "bin/composer.cmd"],
      platforms = @[
        initPlatformBinary(cpu = pcAny, os = detectHostOs(),
          url = url, sha256 = sha)
      ],
      launcher_emit = @[
        LauncherEmitSpec(kind: lekPhar, target: "composer.phar",
          interpreter_package_id: "php", launcher_name: "composer")
      ])
    let res = resolveBuiltinPackage("composer", @[vp])
    check res.found

    var raised = false
    var pkg = ""
    var interp = ""
    var msg = ""
    try:
      discard realizeBuiltinPackage(store, res.resolution)
    except EBuiltinPhpUnavailable as err:
      raised = true
      pkg = err.packageId
      interp = err.interpreterPackageId
      msg = err.msg
    check raised
    check pkg == "composer"
    check interp == "php"
    check "repro home add php" in msg
    # Realize did not write a prefix (the discovery raised before staging).
    let prefixes = listPrefixes(store)
    var sawComposer = false
    for row in prefixes:
      if row.packageName == "composer": sawComposer = true
    check (not sawComposer)

  test "test_m5_schema_validator_rejects_launcher_name_not_in_bin_relpath":
    ## launcher_name typo / missing-from-bin_relpath is caught by the
    ## schema validator. Sanity check that the validator catches the
    ## bin_relpath drift class.
    let vp = initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afRaw,
      install_method = imExtract,
      bin_relpath = @["bin/wrong.ps1"],
      platforms = @[
        initPlatformBinary(cpu = pcAny, os = poWindows,
          url = "file:///x",
          sha256 = "a".repeat(64))
      ],
      launcher_emit = @[
        LauncherEmitSpec(kind: lekPhar, target: "composer.phar",
          interpreter_package_id: "php", launcher_name: "composer")
      ])
    let errors = validateVersionedProvisioning(vp)
    var foundMismatch = false
    for err in errors:
      if "launcher_name 'composer'" in err and "bin_relpath" in err:
        foundMismatch = true
    check foundMismatch
