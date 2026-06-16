## NDE0-A unit test: apt-jammy native catalog adapter.
##
## Exercises the spec'd public surface of
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/apt_jammy.nim``
## against real jammy .deb fixtures harvested under
## ``recipes/reproos-mvp-config/vendored-archives/linux/``.
##
## Required test surfaces (per the NDE0-A sub-agent prompt):
##
##   1. ``sha256 verification`` — pass a known-good .deb + matching
##      sha256 → succeeds; pass same .deb + WRONG sha256 → raises
##      ``AptVerifyError``.
##   2. ``content-addressed store path`` — different .debs produce
##      different store paths; same .deb (same fingerprint) produces
##      the same store path (graph-cache hit).
##   3. ``expectedFiles failure`` — an ``expectedFiles`` entry the .deb
##      does not contain raises ``AptExpectedFileMissing``.
##   4. ``installSystemdUnit normalisation`` — a unit shipped at
##      ``lib/systemd/system/<name>`` ends up at
##      ``usr/lib/systemd/system/<name>`` in the output store (the
##      cascade-G fix DE-G/DE-H/DE-K all need).
##   5. ``determinism`` — extract the same .deb twice into separate
##      store roots; byte-compare the resulting trees.
##
## Fixtures are pre-fetched .debs from the Tier-2 harvest the
## DE-G/DE-H/DE-K shell scripts already use; their bytes are stable
## under the snapshot pin and have known sha256s.

import std/[algorithm, os, sequtils, strutils, tables, tempfiles, unittest]

import repro_dsl_stdlib/packages/apt_jammy

# ---------------------------------------------------------------------------
# Fixture-path helpers
# ---------------------------------------------------------------------------

const RepoRoot =
  currentSourcePath.parentDir.parentDir.parentDir.parentDir
  ## .../libs/repro_dsl_stdlib/tests/<file>.nim
  ## ^         ^                   ^     ^
  ## └───┬─────┘                   │     └ this file
  ##     │   parentDir = tests/    │
  ##     │   parentDir = .../stdlib
  ##     │   parentDir = .../libs
  ##     └─ parentDir = repo root

const VendoredDir =
  RepoRoot / "recipes" / "reproos-mvp-config" / "vendored-archives" / "linux"

# ---------------------------------------------------------------------------
# Fixture catalogue. sha256 + size computed against the actual on-disk
# bytes (sha256sum + stat on Windows via python3). These pins are the
# Tier-2 harvest the DE shell scripts already use; bumping them would
# require a corresponding pin bump in the .json catalogs under
# ``recipes/catalog/linux/`` and is intentionally tied to a snapshot
# revision the campaign tracks.
# ---------------------------------------------------------------------------

type
  DebFixture = object
    filename: string
    sha256: string

const
  # Tiny pure-data .deb (no executables, no soname links). Good for the
  # sha256 + store-path + determinism tests.
  FxLibdrmCommon = DebFixture(
    filename: "libdrm-common_2.4.113-2~ubuntu0.22.04.1_all.deb",
    sha256: "35a306712d8b15b30c42ecd73ec087813eb01c0b3125dc8f7ca2b5134e133522")

  # Second small fixture so we can verify "different debs → different
  # store paths".
  FxFootTerminfo = DebFixture(
    filename: "foot-terminfo_1.11.0-2_all.deb",
    sha256: "f96344f31bc8f02aea4c3e82e451bca8ea2c723954dd5cbe5725f1eb2c0feffd")

  # Ships a systemd unit at lib/systemd/system/accounts-daemon.service —
  # exercises the cascade-G normalisation (spec §5).
  FxAccountsService = DebFixture(
    filename: "accountsservice_22.07.5-2ubuntu1.5_amd64.deb",
    sha256: "95ef667f9ada1acb2629bb98d3aa004dcf49a694430ac46b72d9add43adc569d")

# A wrong-sha for negative-test path (single bit flipped on the last char).
const WrongSha =
  "35a306712d8b15b30c42ecd73ec087813eb01c0b3125dc8f7ca2b5134e133523"

const TestSnapshot = "ubuntu/jammy/20260615T000000Z"

proc fixturePath(fx: DebFixture): string =
  VendoredDir / fx.filename

proc requireFixture(fx: DebFixture) =
  ## Skip-by-fail: the .deb fixtures must be present for the test to be
  ## meaningful. We fail loudly (not silently skip) so a missing fixture
  ## blocks the regression suite the way the spec demands.
  let p = fixturePath(fx)
  if not fileExists(p):
    raise newException(IOError,
      "NDE0-A fixture missing: " & p &
      " — these .debs are checked into the repo under " &
      "recipes/reproos-mvp-config/vendored-archives/linux/.")

# ---------------------------------------------------------------------------
# Filesystem helpers
# ---------------------------------------------------------------------------

proc collectFileSnapshot(root: string): seq[(string, string)] =
  ## Return ``[(relpath, sha256)]`` for every regular file under ``root``.
  ## Used to byte-compare two store outputs.
  result = @[]
  for rel in walkDirRec(root, relative = true):
    let abs = root / rel
    if fileExists(abs):
      result.add((rel.replace('\\', '/'), sha256OfFile(abs)))
  result.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "NDE0-A apt-jammy adapter":

  test "sha256 verification: matching sha succeeds":
    requireFixture(FxLibdrmCommon)
    let storeRoot = createTempDir("nde0a_shaOk_", "")
    defer: removeDir(storeRoot)

    let res = extractAptDeb(
      debPath = fixturePath(FxLibdrmCommon),
      sha256 = FxLibdrmCommon.sha256,
      storeRoot = storeRoot)

    check res.storePath.startsWith(storeRoot)
    check dirExists(res.storePath)
    # The libdrm-common archive plants usr/share/libdrm/amdgpu.ids per
    # the dpkg-deb listing — assert it landed.
    check fileExists(res.storePath / "usr" / "share" / "libdrm" /
                     "amdgpu.ids")

  test "sha256 verification: wrong sha raises AptVerifyError":
    requireFixture(FxLibdrmCommon)
    let storeRoot = createTempDir("nde0a_shaBad_", "")
    defer: removeDir(storeRoot)

    # NO try/except swallowing — let the test fail loudly if the wrong
    # path doesn't raise.
    expect AptVerifyError:
      discard extractAptDeb(
        debPath = fixturePath(FxLibdrmCommon),
        sha256 = WrongSha,
        storeRoot = storeRoot)

  test "content-addressed store path: different debs → different paths":
    requireFixture(FxLibdrmCommon)
    requireFixture(FxFootTerminfo)
    let storeRoot = createTempDir("nde0a_caDiff_", "")
    defer: removeDir(storeRoot)

    let a = extractAptDeb(
      debPath = fixturePath(FxLibdrmCommon),
      sha256 = FxLibdrmCommon.sha256,
      storeRoot = storeRoot)
    let b = extractAptDeb(
      debPath = fixturePath(FxFootTerminfo),
      sha256 = FxFootTerminfo.sha256,
      storeRoot = storeRoot)

    check a.storePath != b.storePath
    check dirExists(a.storePath)
    check dirExists(b.storePath)

  test "content-addressed store path: same deb twice → same path":
    requireFixture(FxLibdrmCommon)
    let storeRoot = createTempDir("nde0a_caSame_", "")
    defer: removeDir(storeRoot)

    let a = extractAptDeb(
      debPath = fixturePath(FxLibdrmCommon),
      sha256 = FxLibdrmCommon.sha256,
      storeRoot = storeRoot)
    let b = extractAptDeb(
      debPath = fixturePath(FxLibdrmCommon),
      sha256 = FxLibdrmCommon.sha256,
      storeRoot = storeRoot)
    check a.storePath == b.storePath

  test "expectedFiles failure: missing entry raises AptExpectedFileMissing":
    requireFixture(FxLibdrmCommon)
    let storeRoot = createTempDir("nde0a_efMiss_", "")
    defer: removeDir(storeRoot)

    expect AptExpectedFileMissing:
      discard installAptDeb(
        snapshot = TestSnapshot,
        debs = @[AptDebSource(
          name: "libdrm-common",
          version: "2.4.113-2~ubuntu0.22.04.1",
          debPath: fixturePath(FxLibdrmCommon),
          sha256: FxLibdrmCommon.sha256)],
        expectedFiles = @["usr/lib/x86_64-linux-gnu/this-does-not-exist.so"],
        storeRoot = storeRoot)

  test "expectedFiles success: present entry produces output":
    requireFixture(FxLibdrmCommon)
    let storeRoot = createTempDir("nde0a_efOk_", "")
    defer: removeDir(storeRoot)

    let res = installAptDeb(
      snapshot = TestSnapshot,
      debs = @[AptDebSource(
        name: "libdrm-common",
        version: "2.4.113-2~ubuntu0.22.04.1",
        debPath: fixturePath(FxLibdrmCommon),
        sha256: FxLibdrmCommon.sha256)],
      expectedFiles = @["usr/share/libdrm/amdgpu.ids"],
      storeRoot = storeRoot)
    check dirExists(res.storePath)
    check fileExists(res.tree("usr/share/libdrm/amdgpu.ids"))

  test "installSystemdUnit: normalises lib/systemd/system/ -> usr/lib/systemd/system/":
    # Cascade-G fix (spec §5): the upstream .deb ships
    # ``lib/systemd/system/accounts-daemon.service`` but R9 systemd's
    # compiled-in UnitPath only includes ``usr/lib/systemd/system/``.
    # ``installSystemdUnit`` must move the bytes verbatim.
    requireFixture(FxAccountsService)
    let storeRoot = createTempDir("nde0a_sysd_", "")
    defer: removeDir(storeRoot)

    let extracted = extractAptDeb(
      debPath = fixturePath(FxAccountsService),
      sha256 = FxAccountsService.sha256,
      storeRoot = storeRoot)
    # Sanity: the upstream layout is the cascade-G shape.
    check fileExists(
      extracted.storePath / "lib" / "systemd" / "system" /
        "accounts-daemon.service")

    let installed = installSystemdUnit(
      unit = extracted,
      unitName = "accounts-daemon.service",
      storeRoot = storeRoot)

    let expectedDest = installed.tree(
      "usr/lib/systemd/system/accounts-daemon.service")
    check fileExists(expectedDest)

    # Byte-identical to the upstream source — the spec forbids unit-file
    # modification.
    let srcBytes = readFile(extracted.storePath / "lib" / "systemd" /
      "system" / "accounts-daemon.service")
    let destBytes = readFile(expectedDest)
    check srcBytes == destBytes

  test "determinism: extract same deb twice into separate roots → byte-identical trees":
    # The spec's idempotency contract (§3) is "content-addressed
    # fingerprint", but a real byte-compare across two fresh roots
    # catches any non-deterministic state the fingerprint glosses over
    # (e.g. ordering bugs in walkDirRec, timestamp leaks, partial-write
    # races). Required by the sub-agent prompt.
    requireFixture(FxLibdrmCommon)

    let rootA = createTempDir("nde0a_detA_", "")
    let rootB = createTempDir("nde0a_detB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    let a = extractAptDeb(
      debPath = fixturePath(FxLibdrmCommon),
      sha256 = FxLibdrmCommon.sha256,
      storeRoot = rootA)
    let b = extractAptDeb(
      debPath = fixturePath(FxLibdrmCommon),
      sha256 = FxLibdrmCommon.sha256,
      storeRoot = rootB)

    # The store-path basename must match (same fingerprint).
    check extractFilename(a.storePath) == extractFilename(b.storePath)

    # And the contents must be byte-identical (sha256 of every file).
    # We skip the marker file in the comparison since it's an internal
    # idempotency artefact.
    let snapA = collectFileSnapshot(a.storePath).filterIt(
      not it[0].endsWith(".apt-jammy-sha256"))
    let snapB = collectFileSnapshot(b.storePath).filterIt(
      not it[0].endsWith(".apt-jammy-sha256"))
    check snapA == snapB
    check snapA.len > 0

  test "fingerprint composition: install hash is order-independent":
    # Spec §3: permuting ``debs`` order is a cache hit.
    requireFixture(FxLibdrmCommon)
    requireFixture(FxFootTerminfo)

    let h1 = installFingerprint(TestSnapshot,
      @["libdrm-common", "foot-terminfo"], @[])
    let h2 = installFingerprint(TestSnapshot,
      @["foot-terminfo", "libdrm-common"], @[])
    check h1 == h2

  test "fingerprint composition: install hash changes when snapshot changes":
    # Spec §3: a different snapshot string produces a fresh store path.
    let h1 = installFingerprint("ubuntu/jammy/20260101T000000Z",
      @["libdrm-common"], @[])
    let h2 = installFingerprint("ubuntu/jammy/20260615T000000Z",
      @["libdrm-common"], @[])
    check h1 != h2

  test "extractFingerprint: changes with sha256, stable with same sha256":
    let hA = extractFingerprint(FxLibdrmCommon.sha256)
    let hB = extractFingerprint(FxLibdrmCommon.sha256)
    let hC = extractFingerprint(FxFootTerminfo.sha256)
    check hA == hB
    check hA != hC
    check hA.len == 16
