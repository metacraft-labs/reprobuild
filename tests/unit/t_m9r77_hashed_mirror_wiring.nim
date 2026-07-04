## M9.R.77.3 — regression tests for the CAS-backed hashed install-
## mirror resolver.
##
## Pins:
##   1. ``resolveCasStoreRoot`` respects ``$REPRO_STORE_ROOT``.
##   2. ``resolveCasStoreRoot`` falls back to a platform default when
##      the env var is unset.
##   3. ``writeRealizationInfoFile`` creates a well-formed KV sidecar.
##   4. ``writeRealizationInfoFile`` is idempotent (same payload = no
##      unnecessary rewrite).
##   5. ``readRealizationInfoFile`` returns zeros when the sidecar is
##      missing / malformed / partial.
##   6. ``hashedDepMirrorRoot`` returns "" when no sidecar exists.
##   7. ``hashedDepMirrorRoot`` returns
##      ``<store-root>/prefixes/<name>/<version>-<hash>/`` when the
##      sidecar is present and well-formed.
##   8. ``packageInstallMirrorRoot`` in ``immHashed`` mode routes
##      through the sidecar and returns the hashed path.
##   9. ``packageInstallMirrorRoot`` in ``immHashedWithLegacyFallback``
##      returns the hashed path when the on-disk prefix exists and
##      falls back to legacy otherwise.

import std/[os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/types/install_mirror_resolver

const DepName = "wayland"
const Version = "1.23.0"
const Hash64 =
  "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"

suite "M9.R.77.3 — resolveCasStoreRoot":

  test "REPRO_STORE_ROOT overrides platform default":
    putEnv(StoreRootEnvVar, "/tmp/custom-store-root")
    try:
      check resolveCasStoreRoot() == "/tmp/custom-store-root"
    finally:
      delEnv(StoreRootEnvVar)

  test "empty env falls back to platform default":
    delEnv(StoreRootEnvVar)
    let root = resolveCasStoreRoot()
    check root.len > 0
    when defined(windows):
      check "repro" in root
    elif defined(macosx):
      check "Library/Caches/repro" in root
    else:
      check "repro/store" in root

suite "M9.R.77.3 — realization-info sidecar":

  test "writeRealizationInfoFile creates the KV file":
    let recipes = createTempDir("m9r77-rec-", "")
    defer:
      try: removeDir(recipes) except OSError: discard
    writeRealizationInfoFile(recipes, DepName, Version, Hash64)
    let sidecar = realizationInfoPath(recipes, DepName)
    check fileExists(sidecar)
    let raw = readFile(sidecar)
    check "version=" & Version in raw
    check "realization-hash=" & Hash64 in raw

  test "writeRealizationInfoFile is idempotent (no rewrite on repeat)":
    let recipes = createTempDir("m9r77-idem-", "")
    defer:
      try: removeDir(recipes) except OSError: discard
    writeRealizationInfoFile(recipes, DepName, Version, Hash64)
    let path = realizationInfoPath(recipes, DepName)
    let mtimeBefore = getLastModificationTime(path)
    # Sleep-free idempotence check: file content is identical, so the
    # writer's fileExists guard short-circuits WITHOUT rewriting.
    writeRealizationInfoFile(recipes, DepName, Version, Hash64)
    let mtimeAfter = getLastModificationTime(path)
    check mtimeBefore == mtimeAfter

  test "readRealizationInfoFile returns zeros for missing sidecar":
    let recipes = createTempDir("m9r77-miss-", "")
    defer:
      try: removeDir(recipes) except OSError: discard
    let info = readRealizationInfoFile(recipes, DepName)
    check info.version == ""
    check info.realizationHashHex == ""

  test "readRealizationInfoFile roundtrips a well-formed sidecar":
    let recipes = createTempDir("m9r77-round-", "")
    defer:
      try: removeDir(recipes) except OSError: discard
    writeRealizationInfoFile(recipes, DepName, Version, Hash64)
    let info = readRealizationInfoFile(recipes, DepName)
    check info.version == Version
    check info.realizationHashHex == Hash64

  test "readRealizationInfoFile rejects malformed hash (wrong length)":
    let recipes = createTempDir("m9r77-mal-", "")
    defer:
      try: removeDir(recipes) except OSError: discard
    let path = realizationInfoPath(recipes, DepName)
    createDir(parentDir(path))
    # 32-char hash, not 64 — the reader must ignore it.
    writeFile(path, "version=" & Version & "\n" &
                    "realization-hash=aabbccdd\n")
    let info = readRealizationInfoFile(recipes, DepName)
    check info.version == Version
    check info.realizationHashHex == ""

  test "writeRealizationInfoFile rejects short hash":
    let recipes = createTempDir("m9r77-writermal-", "")
    defer:
      try: removeDir(recipes) except OSError: discard
    writeRealizationInfoFile(recipes, DepName, Version, "abcdef")
    let sidecar = realizationInfoPath(recipes, DepName)
    check not fileExists(sidecar)

  test "writeRealizationInfoFile rejects empty version":
    let recipes = createTempDir("m9r77-writeremptyv-", "")
    defer:
      try: removeDir(recipes) except OSError: discard
    writeRealizationInfoFile(recipes, DepName, "", Hash64)
    let sidecar = realizationInfoPath(recipes, DepName)
    check not fileExists(sidecar)

suite "M9.R.77.3 — hashedDepMirrorRoot (CAS-backed lookup)":

  test "returns empty string when no sidecar exists":
    let recipes = createTempDir("m9r77-hno-", "")
    defer:
      try: removeDir(recipes) except OSError: discard
    check hashedDepMirrorRoot(recipes, DepName) == ""

  test "returns <store-root>/prefixes/<dep>/<version>-<hash> when sidecar present":
    let recipes = createTempDir("m9r77-hres-", "")
    defer:
      try: removeDir(recipes) except OSError: discard
    let storeRoot = "/tmp/m9r77-store-root"
    putEnv(StoreRootEnvVar, storeRoot)
    try:
      writeRealizationInfoFile(recipes, DepName, Version, Hash64)
      let resolved = hashedDepMirrorRoot(recipes, DepName)
      check resolved == storeRoot & "/prefixes/" & DepName & "/" &
        Version & "-" & Hash64
    finally:
      delEnv(StoreRootEnvVar)

suite "M9.R.77.3 — packageInstallMirrorRoot (mode-routed)":

  test "immHashed with sidecar returns the hashed path":
    let recipes = createTempDir("m9r77-modeh-", "")
    defer:
      try: removeDir(recipes) except OSError: discard
    let storeRoot = "/tmp/m9r77-immhashed-root"
    putEnv(StoreRootEnvVar, storeRoot)
    putEnv(InstallMirrorModeEnvVar, "hashed")
    try:
      writeRealizationInfoFile(recipes, DepName, Version, Hash64)
      let root = packageInstallMirrorRoot(recipes, DepName)
      check root == storeRoot & "/prefixes/" & DepName & "/" &
        Version & "-" & Hash64
    finally:
      delEnv(InstallMirrorModeEnvVar)
      delEnv(StoreRootEnvVar)

  test "immHashed without sidecar still falls back to legacy":
    let recipes = createTempDir("m9r77-modehnos-", "")
    defer:
      try: removeDir(recipes) except OSError: discard
    putEnv(InstallMirrorModeEnvVar, "hashed")
    try:
      let root = packageInstallMirrorRoot(recipes, DepName)
      # Legacy shape: <recipes>/<dep>/.repro/output/install
      check root.endsWith("/wayland/.repro/output/install")
    finally:
      delEnv(InstallMirrorModeEnvVar)

  test "immHashedWithLegacyFallback returns legacy when hashed prefix absent":
    let recipes = createTempDir("m9r77-fbl-", "")
    defer:
      try: removeDir(recipes) except OSError: discard
    let storeRoot = "/tmp/m9r77-neverexists-store"
    putEnv(StoreRootEnvVar, storeRoot)
    putEnv(InstallMirrorModeEnvVar, "hashed-with-legacy-fallback")
    try:
      writeRealizationInfoFile(recipes, DepName, Version, Hash64)
      # No on-disk directory at the hashed path — falls back to legacy.
      let root = packageInstallMirrorRoot(recipes, DepName)
      check root.endsWith("/wayland/.repro/output/install")
    finally:
      delEnv(InstallMirrorModeEnvVar)
      delEnv(StoreRootEnvVar)

  test "immHashedWithLegacyFallback returns hashed when prefix exists":
    let recipes = createTempDir("m9r77-fbh-", "")
    defer:
      try: removeDir(recipes) except OSError: discard
    let storeRoot = createTempDir("m9r77-realstore-", "")
    defer:
      try: removeDir(storeRoot) except OSError: discard
    putEnv(StoreRootEnvVar, storeRoot)
    putEnv(InstallMirrorModeEnvVar, "hashed-with-legacy-fallback")
    try:
      writeRealizationInfoFile(recipes, DepName, Version, Hash64)
      let expected = storeRoot & "/prefixes/" & DepName & "/" &
        Version & "-" & Hash64
      createDir(expected)
      let root = packageInstallMirrorRoot(recipes, DepName)
      # Normalise both to forward slashes for comparison since the
      # created dir uses the host separator but the resolver returns
      # POSIX form.
      let normalised = root.replace("\\", "/")
      let expectedNorm = expected.replace("\\", "/")
      check normalised == expectedNorm
    finally:
      delEnv(InstallMirrorModeEnvVar)
      delEnv(StoreRootEnvVar)
