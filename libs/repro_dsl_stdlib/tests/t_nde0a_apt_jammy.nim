## NDE0-A unit test: apt-jammy native catalog adapter.
##
## Exercises the spec'd public surface of
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/apt_jammy.nim``
## against deterministic minimal ``.deb`` fixtures assembled from
## Apache-2.0 test-only payloads below.
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
## The fixture archives are constructed byte-for-byte (by the shared
## ``apt_deb_fixture_builder.nim`` next to this file) instead of fetched
## from a mutable Ubuntu pool URL. Their complete payload and
## metadata are authored here under the repository's Apache-2.0 license;
## they contain no Ubuntu package bytes. Exact sha256 pins below make archive
## construction drift fail closed before the adapter sees the fixture.

import std/[algorithm, os, sequtils, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/apt_jammy
import ./apt_deb_fixture_builder

# Importing the recipe's ``repro.nim`` evaluates its ``package aptJammy:``
# block at module init, exercising the M2 ``versions:`` lowerer + the
# M1 ``defaultToolProvisioning`` / config: surface against the real
# production recipe shape. Without this import the registry stays empty
# and the "DSL surface" assertion below would be vacuous.
#
# We pull in the project DSL host for its ``registeredVersions`` accessor;
# the recipe itself imports + re-exports ``apt_jammy`` already so this
# double-import resolves to the same module instance.
import repro_project_dsl
import "../../../recipes/packages/adapters/apt-jammy/repro" as aptJammyRecipe

# ---------------------------------------------------------------------------
# The apt-jammy adapter unpacks Debian ``.deb`` archives via its internal
# ``ar`` parser plus GNU ``tar`` and asserts on Debian-specific store layouts
# (systemd unit normalisation and ``usr/share/...`` paths). The fixture
# builder below emits a valid ``control.tar`` plus a pure-Nim raw-block
# ``data.tar.zst`` in a deterministic ``ar`` container without consulting
# the network. The archive and filesystem-layout assertions are
# Linux/Debian-only, so that suite is compiled only on Linux. The recipe DSL
# registry contract at the end of this file is host-independent and remains
# real coverage on every supported platform.
# ---------------------------------------------------------------------------
when defined(linux):
  # ---------------------------------------------------------------------------
  # Hermetic .deb fixtures (archive assembly lives in apt_deb_fixture_builder)
  # ---------------------------------------------------------------------------

  type
    DebFixtureKind = enum
      dfCommonData
      dfTerminfo
      dfSystemdUnit

    DebFixture = object
      filename: string
      sha256: string
      kind: DebFixtureKind

  const
    # Tiny pure-data fixtures (no executables or soname links). They use
    # package-shaped names solely to keep adapter diagnostics realistic.
    FxCommonData = DebFixture(
      filename: "reprobuild-test-common_1.0_all.deb",
      sha256: "18948ecdeb78661641999e4f74531ceacdc660dde8bdc3422c5560ce1b58050e",
      kind: dfCommonData)

    FxTerminfo = DebFixture(
      filename: "reprobuild-test-terminfo_1.0_all.deb",
      sha256: "eae4d26c825346a9da1bec49f35e1b07445a50e31eb36ae2567a43a54f1d6394",
      kind: dfTerminfo)

    # Carries a systemd unit at lib/systemd/system/accounts-daemon.service to
    # exercise the cascade-G normalisation contract (spec §5).
    FxSystemdUnit = DebFixture(
      filename: "reprobuild-test-systemd-unit_1.0_all.deb",
      sha256: "ebbb86717d84c517e05ed8e5ce53a9dff433f830f9f9753f354e4278b3b39164",
      kind: dfSystemdUnit)

  # A wrong-sha for negative-test path (single bit flipped on the last char).
  const WrongSha =
    "18948ecdeb78661641999e4f74531ceacdc660dde8bdc3422c5560ce1b58050f"

  const TestSnapshot = "ubuntu/jammy/20260615T000000Z"

  const
    CommonDataBytes = "reprobuild apt fixture: common data\n"
    TerminfoBytes = "reprobuild apt fixture: terminfo\n"
    SystemdUnitBytes = """[Unit]
Description=Reprobuild apt adapter fixture

[Service]
Type=oneshot
ExecStart=/usr/bin/true
"""

  proc fixturePayload(fx: DebFixture): tuple[path, bytes: string] =
    case fx.kind
    of dfCommonData:
      ("usr/share/libdrm/amdgpu.ids", CommonDataBytes)
    of dfTerminfo:
      ("usr/share/terminfo/f/foot", TerminfoBytes)
    of dfSystemdUnit:
      ("lib/systemd/system/accounts-daemon.service", SystemdUnitBytes)

  proc fixtureBytes(fx: DebFixture): string =
    let payload = fixturePayload(fx)
    debArchiveBytes(payload.path, payload.bytes, ddcZstdRaw)

  proc materializeFixture(fx: DebFixture; root: string): string =
    let fixtureDir = root / "apt-fixtures"
    createDir(fixtureDir)
    result = fixtureDir / fx.filename
    writeFile(result, fixtureBytes(fx))
    let observed = sha256OfFile(result)
    if observed != fx.sha256:
      raise newException(IOError,
        "deterministic .deb fixture drift for " & fx.filename &
        " (expected " & fx.sha256 & ", got " & observed & ")")

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
      let storeRoot = createTempDir("nde0a_shaOk_", "")
      defer: removeDir(storeRoot)
      let debPath = materializeFixture(FxCommonData, storeRoot)

      let res = extractAptDeb(
        debPath = debPath,
        sha256 = FxCommonData.sha256,
        storeRoot = storeRoot)

      check res.storePath.startsWith(storeRoot)
      check dirExists(res.storePath)
      check extractFilename(res.storePath) ==
        extractFingerprint(FxCommonData.sha256)
      check fileExists(res.storePath / "usr" / "share" / "libdrm" /
                       "amdgpu.ids")
      check readFile(res.storePath / "usr" / "share" / "libdrm" /
                     "amdgpu.ids") == CommonDataBytes

    test "sha256 verification: wrong sha raises AptVerifyError":
      let storeRoot = createTempDir("nde0a_shaBad_", "")
      defer: removeDir(storeRoot)
      let debPath = materializeFixture(FxCommonData, storeRoot)

      # NO try/except swallowing — let the test fail loudly if the wrong
      # path doesn't raise.
      expect AptVerifyError:
        discard extractAptDeb(
          debPath = debPath,
          sha256 = WrongSha,
          storeRoot = storeRoot)

    test "content-addressed store path: different debs → different paths":
      let storeRoot = createTempDir("nde0a_caDiff_", "")
      defer: removeDir(storeRoot)
      let commonDeb = materializeFixture(FxCommonData, storeRoot)
      let terminfoDeb = materializeFixture(FxTerminfo, storeRoot)

      let a = extractAptDeb(
        debPath = commonDeb,
        sha256 = FxCommonData.sha256,
        storeRoot = storeRoot)
      let b = extractAptDeb(
        debPath = terminfoDeb,
        sha256 = FxTerminfo.sha256,
        storeRoot = storeRoot)

      check a.storePath != b.storePath
      check dirExists(a.storePath)
      check dirExists(b.storePath)
      check readFile(a.tree("usr/share/libdrm/amdgpu.ids")) ==
        CommonDataBytes
      check readFile(b.tree("usr/share/terminfo/f/foot")) == TerminfoBytes

    test "content-addressed store path: same deb twice → same path":
      let storeRoot = createTempDir("nde0a_caSame_", "")
      defer: removeDir(storeRoot)
      let debPath = materializeFixture(FxCommonData, storeRoot)

      let a = extractAptDeb(
        debPath = debPath,
        sha256 = FxCommonData.sha256,
        storeRoot = storeRoot)
      let b = extractAptDeb(
        debPath = debPath,
        sha256 = FxCommonData.sha256,
        storeRoot = storeRoot)
      check a.storePath == b.storePath

    test "expectedFiles failure: missing entry raises AptExpectedFileMissing":
      let storeRoot = createTempDir("nde0a_efMiss_", "")
      defer: removeDir(storeRoot)
      let debPath = materializeFixture(FxCommonData, storeRoot)

      expect AptExpectedFileMissing:
        discard installAptDeb(
          snapshot = TestSnapshot,
          debs = @[AptDebSource(
            name: "reprobuild-test-common",
            version: "1.0",
            debPath: debPath,
            sha256: FxCommonData.sha256)],
          expectedFiles = @["usr/lib/x86_64-linux-gnu/this-does-not-exist.so"],
          storeRoot = storeRoot)

    test "expectedFiles success: present entry produces output":
      let storeRoot = createTempDir("nde0a_efOk_", "")
      defer: removeDir(storeRoot)
      let debPath = materializeFixture(FxCommonData, storeRoot)

      let res = installAptDeb(
        snapshot = TestSnapshot,
        debs = @[AptDebSource(
          name: "reprobuild-test-common",
          version: "1.0",
          debPath: debPath,
          sha256: FxCommonData.sha256)],
        expectedFiles = @["usr/share/libdrm/amdgpu.ids"],
        storeRoot = storeRoot)
      check dirExists(res.storePath)
      check fileExists(res.tree("usr/share/libdrm/amdgpu.ids"))
      check readFile(res.tree("usr/share/libdrm/amdgpu.ids")) ==
        CommonDataBytes

    test "installSystemdUnit: normalises lib/systemd/system/ -> usr/lib/systemd/system/":
      # Cascade-G fix (spec §5): Debian packages may ship
      # ``lib/systemd/system/accounts-daemon.service`` but R9 systemd's
      # compiled-in UnitPath only includes ``usr/lib/systemd/system/``.
      # ``installSystemdUnit`` must move the bytes verbatim.
      let storeRoot = createTempDir("nde0a_sysd_", "")
      defer: removeDir(storeRoot)
      let debPath = materializeFixture(FxSystemdUnit, storeRoot)

      let extracted = extractAptDeb(
        debPath = debPath,
        sha256 = FxSystemdUnit.sha256,
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
      check destBytes == SystemdUnitBytes

    test "determinism: extract same deb twice into separate roots → byte-identical trees":
      # The spec's idempotency contract (§3) is "content-addressed
      # fingerprint", but a real byte-compare across two fresh roots
      # catches any non-deterministic state the fingerprint glosses over
      # (e.g. ordering bugs in walkDirRec, timestamp leaks, partial-write
      # races). Required by the sub-agent prompt.
      let rootA = createTempDir("nde0a_detA_", "")
      let rootB = createTempDir("nde0a_detB_", "")
      defer:
        removeDir(rootA)
        removeDir(rootB)
      let debA = materializeFixture(FxCommonData, rootA)
      let debB = materializeFixture(FxCommonData, rootB)
      check sha256OfFile(debA) == sha256OfFile(debB)

      let a = extractAptDeb(
        debPath = debA,
        sha256 = FxCommonData.sha256,
        storeRoot = rootA)
      let b = extractAptDeb(
        debPath = debB,
        sha256 = FxCommonData.sha256,
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
      let common = ExtractedDeb(name: "libdrm-common", version: "1.0",
                                sha256: FxCommonData.sha256)
      let terminfo = ExtractedDeb(name: "foot-terminfo", version: "1.0",
                                  sha256: FxTerminfo.sha256)
      let h1 = installFingerprint([common, terminfo])
      let h2 = installFingerprint([terminfo, common])
      check h1 == h2
      check h1.len == 64

    test "fingerprint composition: install hash changes when a .deb's sha256 changes":
      # Spec §3: the identity is the bytes. The same package name and
      # version with different bytes (e.g. a different archive served for
      # the same snapshot) is a different store path. The snapshot string
      # is not an input at all — see
      # ``t_apt_install_store_identity_is_byte_keyed.nim``.
      let h1 = installFingerprint([ExtractedDeb(
        name: "libdrm-common", version: "1.0", sha256: FxCommonData.sha256)])
      let h2 = installFingerprint([ExtractedDeb(
        name: "libdrm-common", version: "1.0", sha256: FxTerminfo.sha256)])
      check h1 != h2

    test "extractFingerprint: changes with sha256, stable with same sha256":
      let hA = extractFingerprint(FxCommonData.sha256)
      let hB = extractFingerprint(FxCommonData.sha256)
      let hC = extractFingerprint(FxTerminfo.sha256)
      check hA == hB
      check hA != hC
      # Full SHA-256, not a truncated prefix.
      check hA.len == 64

    test "malformed input is refused before any store path is named":
      # Fail-closed input validation: a digest with two spellings, or a
      # package named twice, has no single well-defined identity.
      expect AptInputError:
        discard extractFingerprint(FxCommonData.sha256.toUpperAscii)
      expect AptInputError:
        discard extractFingerprint(FxCommonData.sha256[0 ..< 16])
      expect AptInputError:
        discard installFingerprint([ExtractedDeb(
          name: "", version: "1.0", sha256: FxCommonData.sha256)])
      expect AptInputError:
        discard installFingerprint([ExtractedDeb(
          name: "libdrm common", version: "1.0", sha256: FxCommonData.sha256)])
      expect AptInputError:
        discard installFingerprint([
          ExtractedDeb(name: "libdrm-common", version: "1.0",
                       sha256: FxCommonData.sha256),
          ExtractedDeb(name: "libdrm-common", version: "1.1",
                       sha256: FxTerminfo.sha256)])
      # A unit name is joined onto store paths: anything but a single path
      # component could read or write outside them.
      let storeRoot = createTempDir("nde0a_badInput_", "")
      defer: removeDir(storeRoot)
      for bad in ["../escape.service", "a/b.service", "..", ""]:
        expect AptInputError:
          discard installSystemdUnit(
            unit = AptFiles(storePath: storeRoot),
            unitName = bad,
            storeRoot = storeRoot)

# ---------------------------------------------------------------------------
# NDE-A DSL-surface coverage. Pins that the rewritten
# ``recipes/packages/adapters/apt-jammy/repro.nim`` actually exercises
# the new DSL surface (M2 ``versions:``) rather than silently keeping the
# legacy ``config:``-only shape. Confirms the recipe's version declaration
# is wired through ``registerVersion`` and that the recorded fields round-trip
# via ``registeredVersions``. Unlike the Debian archive/layout assertions
# above, this is a pure registry contract and is meaningful on every host.
# Keeping these real cases outside the Linux branch also means a non-Linux
# binary truthfully implements the test catalog protocol instead of looking
# like an unexplained zero-case binary.
#
# The version string must track ``AptJammyAdapterVersion`` (the spec §3
# fingerprint input) so a stdlib bugfix and a recipe-side bump stay in
# lockstep.
# ---------------------------------------------------------------------------

suite "NDE0-A apt-jammy DSL surface":

  test "recipe registers exactly one version via the DSL versions: block":
    let vs = registeredVersions("aptJammy")
    check vs.len == 1

  test "recorded version string matches AptJammyAdapterVersion constant":
    # Tying the recipe-declared version to the stdlib constant is the whole
    # point of M2's surface — it makes the cache-key contract auditable from
    # the DSL side.
    let vs = registeredVersions("aptJammy")
    check vs[0].version == AptJammyAdapterVersion

  test "recorded version carries the snapshot pin as sourceRevision":
    # The recipe pins the snapshot string into ``sourceRevision`` so the
    # adapter version (a spec §3 fingerprint input) and the snapshot (its
    # provenance, not an identity input) are both reachable from the
    # registry without parsing the config: block.
    let vs = registeredVersions("aptJammy")
    check vs[0].sourceRevision == "ubuntu/jammy/20260615T000000Z"
    check vs[0].sourceUrl.startsWith("https://snapshot.ubuntu.com/")
    check vs[0].sourceRepository == "https://snapshot.ubuntu.com/ubuntu"
