## M66 Part D — Scoop manifest parser unit tests.
##
## Verifies that the ``parseScoopManifest`` translator turns various
## Scoop manifest shapes into the M63 ``VersionedProvisioning``
## schema with the right field values + the right diagnostics.

import std/[os, strutils, tables, unittest]

import ../src/manifest_parser
import repro_dsl_stdlib/packages_schema

const FixturesDir = currentSourcePath.parentDir / "fixtures"

proc readFixture(bucket, app: string): string =
  readFile(FixturesDir / bucket / "bucket" / (app & ".json"))

proc hasDiagnostic(diags: openArray[Diagnostic]; kind: DiagnosticKind): bool =
  for d in diags:
    if d.kind == kind: return true
  false

suite "M66 — Scoop manifest parser":

  test "simple top-level url + hash + bin -> 1-platform slice":
    let raw = readFixture("bucket-simple", "hello")
    let p = parseScoopManifest("hello", raw)
    check p.ok
    check p.entry.version == "1.0.0"
    check p.entry.archive_format == afZip
    check p.entry.install_method == imExtract
    check p.entry.bin_relpath == @["hello.exe"]
    check p.entry.platforms.len == 1
    check p.entry.platforms[0].cpu == pcAny
    check p.entry.platforms[0].os == poWindows
    check p.entry.platforms[0].url == "https://example.test/hello-1.0.0.zip"
    check p.entry.platforms[0].sha256 ==
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    check p.entry.platforms[0].sha512 == ""
    check p.entry.platforms[0].extract_path == "hello-1.0.0"
    check validateVersionedProvisioning(p.entry).len == 0

  test "architecture: {64bit, arm64, 32bit} -> two slices, 32bit ignored":
    let raw = readFixture("bucket-architecture", "ripgrep")
    let p = parseScoopManifest("ripgrep", raw)
    check p.ok
    check p.entry.version == "15.1.0"
    check p.entry.archive_format == afZip
    check p.entry.platforms.len == 2
    # x86_64 entry comes first (ordering enforced by the parser for
    # determinism).
    check p.entry.platforms[0].cpu == pcX86_64
    check p.entry.platforms[0].os == poWindows
    check "x86_64-pc-windows-msvc" in p.entry.platforms[0].url
    check p.entry.platforms[1].cpu == pcAArch64
    check p.entry.platforms[1].os == poWindows
    check "aarch64-pc-windows-msvc" in p.entry.platforms[1].url
    check hasDiagnostic(p.diagnostics, dkManifest32BitIgnored)
    check validateVersionedProvisioning(p.entry).len == 0

  test "installer block -> imInstallerSilent + parsed args":
    let raw = readFixture("bucket-installer", "myinstaller")
    let p = parseScoopManifest("myinstaller", raw)
    check p.ok
    check p.entry.install_method == imInstallerSilent
    check p.entry.installer_args == @["-sasl"]
    check p.entry.env["MYINSTALLER_HOME"] == "${prefix}"
    # Diagnostic NOT emitted because args were present.
    check not hasDiagnostic(p.diagnostics, dkInstallerArgsUnknown)
    check validateVersionedProvisioning(p.entry).len == 0

  test "bin as [exe, alias] pair -> exe kept, alias dropped + diagnostic":
    let raw = readFixture("bucket-pair-rename", "winflexbison")
    let p = parseScoopManifest("winflexbison", raw)
    check p.ok
    check p.entry.bin_relpath == @["win_bison.exe", "win_flex.exe"]
    check hasDiagnostic(p.diagnostics, dkBinRenameIgnored)
    var renameCount = 0
    for d in p.diagnostics:
      if d.kind == dkBinRenameIgnored: inc renameCount
    check renameCount == 2

  test "missing hash -> dkManifestNoHash + ok = false":
    let raw = readFixture("bucket-missing-hash", "broken")
    let p = parseScoopManifest("broken", raw)
    check not p.ok
    check hasDiagnostic(p.diagnostics, dkManifestNoHash)

  test "missing version -> ok = false":
    let raw = """{"url": "x", "hash": "y"}"""
    let p = parseScoopManifest("noversion", raw)
    check not p.ok

  test "invalid JSON -> ok = false (no exception)":
    let p = parseScoopManifest("invalid", "{not json")
    check not p.ok

  test "per-arch extract_dir -> each platform gets its own extract_path":
    let raw = readFixture("bucket-multiarch-extract", "multitool")
    let p = parseScoopManifest("multitool", raw)
    check p.ok
    check p.entry.platforms.len == 2
    check p.entry.platforms[0].extract_path == "multitool-3.2.1-x64"
    check p.entry.platforms[1].extract_path == "multitool-3.2.1-arm64"
    # env_set keys land in stable sorted order.
    check p.entry.env["MULTITOOL_HOME"] == "${prefix}"
    check p.entry.env["MULTITOOL_CONF"] == "${prefix}\\etc"

  test "sha512: prefix -> sha512 field set, sha256 left empty":
    let raw = """{
      "version": "1.0.0",
      "url": "https://example.test/x.tar.gz",
      "hash": "sha512:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "bin": "x"
    }"""
    let p = parseScoopManifest("x", raw)
    check p.ok
    check p.entry.archive_format == afTarGz
    check p.entry.platforms[0].sha256 == ""
    check p.entry.platforms[0].sha512.len == 128

  test "md5: hash prefix -> diagnostic + ok = false (M63 doesn't model md5)":
    let raw = """{
      "version": "1.0.0",
      "url": "https://example.test/x.zip",
      "hash": "md5:0123456789abcdef0123456789abcdef",
      "bin": "x.exe"
    }"""
    let p = parseScoopManifest("x", raw)
    check not p.ok
    check hasDiagnostic(p.diagnostics, dkHashAlgorithmUnsupported)

  test "archive_format inferred from 7z extension":
    let raw = """{
      "version": "1.0.0",
      "url": "https://example.test/x-1.0.0.7z",
      "hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "bin": "x.exe"
    }"""
    let p = parseScoopManifest("x", raw)
    check p.ok
    check p.entry.archive_format == afSevenZip

  test "archive_format inferred from .msi extension":
    let raw = """{
      "version": "1.0.0",
      "url": "https://example.test/x.msi",
      "hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "bin": "x.exe"
    }"""
    let p = parseScoopManifest("x", raw)
    check p.ok
    check p.entry.archive_format == afInstallerMsi

  test "Scoop ``#/dl.7z`` rename suffix is stripped before extension sniff":
    let raw = """{
      "version": "1.0.0",
      "url": "https://example.test/x.7z.exe#/dl.7z",
      "hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "installer": {"file": "Install.exe", "args": "-sasl"},
      "bin": "bin\\x.exe"
    }"""
    let p = parseScoopManifest("x", raw)
    check p.ok
    # The URL "ends with" .7z after stripping #/dl.7z; the .exe
    # extension is gone. We expect afSevenZip rather than afInstallerNsis
    # — the installer-NSIS hint only fires on .exe URLs.
    check p.entry.archive_format == afSevenZip

  test "installer with default args (MSI) -> /quiet /norestart":
    let raw = """{
      "version": "1.0.0",
      "url": "https://example.test/x.msi",
      "hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "installer": {"file": "Install.exe"},
      "bin": "x.exe"
    }"""
    let p = parseScoopManifest("x", raw)
    check p.ok
    check p.entry.install_method == imInstallerSilent
    check p.entry.installer_args == @["/quiet", "/norestart"]
    # The fixture omits args, so we synthesized them — no diagnostic.
    check not hasDiagnostic(p.diagnostics, dkInstallerArgsUnknown)

  test "args provided as a JSON array survive in order":
    let raw = """{
      "version": "1.0.0",
      "url": "https://example.test/x.exe",
      "hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "installer": {"file": "Install.exe", "args": ["/S", "/D=C:\\foo"]},
      "bin": "x.exe"
    }"""
    let p = parseScoopManifest("x", raw)
    check p.ok
    check p.entry.installer_args == @["/S", "/D=C:\\foo"]

  # ===========================================================================
  # M67 — bin_relpath synthesis from env_add_path + binDefaults
  # ===========================================================================

  test "M67: env_add_path + binDefaults cross-product synthesizes bin_relpath":
    let raw = readFixture("bucket-env-path", "envapp")
    let p = parseScoopManifest("envapp", raw, @["envapp.exe", "envappc.exe"])
    check p.ok
    # bin_relpath should be the cross-product of env_add_path ('bin',
    # 'tools\\bin') with the binDefaults list — 2x2 = 4 entries. The
    # parser normalizes backslashes to forward slashes.
    check p.entry.bin_relpath == @[
      "bin/envapp.exe", "bin/envappc.exe",
      "tools/bin/envapp.exe", "tools/bin/envappc.exe",
    ]
    check validateVersionedProvisioning(p.entry).len == 0
    check p.entry.env["ENVAPP_HOME"] == "${prefix}"

  test "M67: binDefaults ignored when manifest already has bin":
    let raw = """{
      "version": "1.0.0",
      "url": "https://example.test/x.zip",
      "hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "bin": "x.exe",
      "env_add_path": "bin"
    }"""
    let p = parseScoopManifest("x", raw, @["should-be-ignored.exe"])
    check p.ok
    # The manifest's own bin field wins over the binDefaults fallback.
    check p.entry.bin_relpath == @["x.exe"]

  test "M67: no env_add_path -> binDefaults are used at the root":
    let raw = """{
      "version": "1.0.0",
      "url": "https://example.test/x.zip",
      "hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }"""
    let p = parseScoopManifest("x", raw, @["zig.exe"])
    check p.ok
    check p.entry.bin_relpath == @["zig.exe"]

  test "M67: top-level extract_dir propagates to per-arch slices":
    ## ScoopInstaller/Java's temurin*-jdk manifests carry the inner-dir
    ## extract path at the TOP level (since both x64 and arm64 land in
    ## the same JDK directory). The M67 parser fix lifts the top-level
    ## ``extract_dir`` into every per-arch slice that lacks its own.
    let raw = """{
      "version": "21.0.5",
      "architecture": {
        "64bit": {
          "url": "https://example.test/jdk-x64.zip",
          "hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        }
      },
      "extract_dir": "jdk-21.0.5+11",
      "bin": "bin\\javac.exe"
    }"""
    let p = parseScoopManifest("temurin21-jdk", raw)
    check p.ok
    check p.entry.platforms.len == 1
    check p.entry.platforms[0].extract_path == "jdk-21.0.5+11"

  # ===========================================================================
  # M68 — installer.script-only is a post-extract hook, not a silent installer
  # ===========================================================================

  test "M68: bare installer.script (no url/file) keeps imExtract":
    ## Scoop's ``nim`` manifest carries an ``installer.script``
    ## (``Add-Path -Path "$env:USERPROFILE\.nimble\bin"``) which is a
    ## PATH tweak, NOT a true installer. Pre-M68 the parser flipped
    ## ``install_method`` to ``imInstallerSilent`` for ANY ``installer``
    ## object, which mis-classified zip-extractable tools. The M68 fix
    ## requires ``installer.url`` OR ``installer.file`` to flip the
    ## method; a bare ``installer.script`` is treated as a dropped
    ## post-extract hook (consistent with how ``post_install`` is
    ## silently discarded per the module docstring).
    let raw = """{
      "version": "2.2.10",
      "url": "https://example.test/nim-2.2.10_x64.zip",
      "hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "bin": "bin\\nim.exe",
      "installer": {
        "script": "Add-Path -Path \"$env:USERPROFILE\\.nimble\\bin\""
      }
    }"""
    let p = parseScoopManifest("nim", raw)
    check p.ok
    check p.entry.install_method == imExtract
    check p.entry.archive_format == afZip

  test "M68: installer with url still flips to imInstallerSilent":
    ## Sanity check that the M68 narrowing did not break the normal
    ## installer path: an ``installer`` object that DOES carry
    ## ``url`` (or ``file``) still drives the installer codepath.
    let raw = """{
      "version": "1.0.0",
      "url": "https://example.test/install.exe",
      "hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "installer": {
        "url": "https://example.test/install.exe",
        "args": ["/S"]
      },
      "bin": "x.exe"
    }"""
    let p = parseScoopManifest("x", raw)
    check p.ok
    check p.entry.install_method == imInstallerSilent

  # ===========================================================================
  # M68 — env_add_path "." current-dir marker stripped from bin synthesis
  # ===========================================================================

  test "M68: env_add_path '.' synthesizes root-relative bins (no leading ./)":
    ## Scoop's ``nodejs-lts`` (and ``dotnet-sdk``) manifests use
    ## ``env_add_path: ["bin", "."]`` to surface BOTH the bin subdir
    ## and the prefix root. Pre-M68 the cross-product produced
    ## ``./node.exe`` for the "." segment; M68 also strips '.' from
    ## ``dir.strip(chars = {'/', '\\', '.'})`` so the root entry comes
    ## out as a bare relpath, matching how Zig/Just emit root binaries.
    let raw = """{
      "version": "1.0.0",
      "url": "https://example.test/x.zip",
      "hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "env_add_path": ["bin", "."]
    }"""
    let p = parseScoopManifest("x", raw, @["x.exe"])
    check p.ok
    # Cross-product: "bin" -> "bin/x.exe", "." -> "x.exe" (NOT "./x.exe")
    check p.entry.bin_relpath == @["bin/x.exe", "x.exe"]

  # ===========================================================================
  # M1 (Realize-Closure spec) — sha1 weak-hash acceptance
  # ===========================================================================

  test "M1: sha1 hash recognized and mapped to schema sha1 field":
    ## A Scoop manifest with ``hash: "sha1:<40-char-hex>"`` translates
    ## into a PlatformBinary whose ``sha1`` field is populated; sha256
    ## and sha512 stay empty. ``validateVersionedProvisioning`` accepts
    ## the entry (the weak-hash warning is non-fatal).
    let raw = """{
      "version": "3.2.2",
      "url": "https://example.test/freepascal.7z",
      "hash": "sha1:0123456789abcdef0123456789abcdef01234567",
      "bin": "bin/fpc.exe"
    }"""
    let p = parseScoopManifest("fpc", raw)
    check p.ok
    check p.entry.platforms.len == 1
    check p.entry.platforms[0].sha1 ==
      "0123456789abcdef0123456789abcdef01234567"
    check p.entry.platforms[0].sha256 == ""
    check p.entry.platforms[0].sha512 == ""

  test "M1: bare 40-char hex is treated as sha1":
    ## Some Scoop manifests ship the bare 40-char hex with no algo
    ## prefix (the harvester now detects this by length).
    let raw = """{
      "version": "3.2.2",
      "url": "https://example.test/freepascal.7z",
      "hash": "0123456789abcdef0123456789abcdef01234567",
      "bin": "bin/fpc.exe"
    }"""
    let p = parseScoopManifest("fpc", raw)
    check p.ok
    check p.entry.platforms[0].sha1.len == 40
    check p.entry.platforms[0].sha256 == ""

  test "M1: sha1 emits HHashAlgorithmWeak diagnostic, not HHashAlgorithmUnsupported":
    let raw = """{
      "version": "3.2.2",
      "url": "https://example.test/freepascal.7z",
      "hash": "sha1:0123456789abcdef0123456789abcdef01234567",
      "bin": "bin/fpc.exe"
    }"""
    let p = parseScoopManifest("fpc", raw)
    check p.ok
    check hasDiagnostic(p.diagnostics, dkHashAlgorithmWeak)
    check (not hasDiagnostic(p.diagnostics, dkHashAlgorithmUnsupported))
    # The diagnostic detail names the tool + the upgrade hint.
    var sawHint = false
    for d in p.diagnostics:
      if d.kind == dkHashAlgorithmWeak and "prefer sha256" in d.detail:
        sawHint = true
    check sawHint

  test "M1: md5 stays rejected (still HHashAlgorithmUnsupported)":
    let raw = """{
      "version": "1.0.0",
      "url": "https://example.test/x.zip",
      "hash": "md5:0123456789abcdef0123456789abcdef",
      "bin": "x.exe"
    }"""
    let p = parseScoopManifest("x", raw)
    check not p.ok
    check hasDiagnostic(p.diagnostics, dkHashAlgorithmUnsupported)
    check (not hasDiagnostic(p.diagnostics, dkHashAlgorithmWeak))

  test "M68: env_add_path '.' alone yields root-relative bins":
    ## Single-segment "." should behave like an empty env_add_path:
    ## the binDefaults end up at the prefix root.
    let raw = """{
      "version": "1.0.0",
      "url": "https://example.test/x.zip",
      "hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "env_add_path": "."
    }"""
    let p = parseScoopManifest("x", raw, @["x.exe"])
    check p.ok
    check p.entry.bin_relpath == @["x.exe"]

  test "M4: innosetup manifest emits imInstallerInnoSetup":
    ## A Scoop manifest carrying ``innosetup: true`` (with no
    ## ``installer:`` block, matching the freepascal shape) translates
    ## to ``install_method == imInstallerInnoSetup`` and emits the
    ## ``dkInstallMethodInnoSetup`` diagnostic so operators can grep
    ## for it. The no-innosetup-key regression guard is the
    ## ``bucket-simple`` case (already covered above): without the
    ## marker, install_method stays imExtract.
    let raw = readFixture("bucket-innosetup", "innofakepascal")
    let p = parseScoopManifest("innofakepascal", raw)
    check p.ok
    check p.entry.install_method == imInstallerInnoSetup
    check hasDiagnostic(p.diagnostics, dkInstallMethodInnoSetup)
    # Validator accepts the new variant (M4 schema extension).
    check validateVersionedProvisioning(p.entry).len == 0

  test "M4: msi URL emits imInstallerMsi (was imExtract pre-M4)":
    ## A Scoop manifest with a ``.msi`` URL and no installer block
    ## translates to ``install_method == imInstallerMsi`` (so the
    ## cakBuiltin realize loop dispatches through dark.exe) instead
    ## of the pre-M4 default of ``imExtract`` (which would fail at
    ## apply time because afInstallerMsi is incompatible with
    ## imExtract). Emits the ``dkInstallMethodMsi`` diagnostic.
    let raw = readFixture("bucket-msi", "fakemsitool")
    let p = parseScoopManifest("fakemsitool", raw)
    check p.ok
    check p.entry.archive_format == afInstallerMsi
    check p.entry.install_method == imInstallerMsi
    check hasDiagnostic(p.diagnostics, dkInstallMethodMsi)
    check p.entry.platforms[0].extract_path == "PFiles64\\Meson".replace(
      "Meson", "FakeMsi")
    check validateVersionedProvisioning(p.entry).len == 0

  test "M4: installer.script with Expand-DarkArchive emits imInstallerNsisBundle":
    ## A Scoop manifest whose installer.script contains
    ## Expand-DarkArchive / Expand-MsiArchive (the python3 + swift
    ## shape) translates to ``install_method == imInstallerNsisBundle``.
    ## Emits the ``dkInstallMethodNsisBundle`` diagnostic and the
    ## allowlisted script lines land in pre_install_actions.
    let raw = readFixture("bucket-nsis-bundle", "fakebundle")
    let p = parseScoopManifest("fakebundle", raw)
    check p.ok
    check p.entry.install_method == imInstallerNsisBundle
    check hasDiagnostic(p.diagnostics, dkInstallMethodNsisBundle)
    # The harvester translated both Expand-{Dark,Msi}Archive script
    # lines into structured pre_install_actions.
    var sawDark = false
    var sawMsi = false
    for action in p.entry.pre_install_actions:
      if action.kind == piaExpandDark: sawDark = true
      if action.kind == piaExpandMsi: sawMsi = true
    check sawDark
    check sawMsi
    check validateVersionedProvisioning(p.entry).len == 0

  test "M4: regression — bucket-simple manifest stays imExtract":
    ## Regression guard: a manifest WITHOUT innosetup/MSI/installer-
    ## script markers continues to translate to imExtract via the
    ## pre-M4 dispatch.
    let raw = readFixture("bucket-simple", "hello")
    let p = parseScoopManifest("hello", raw)
    check p.ok
    check p.entry.install_method == imExtract
    check (not hasDiagnostic(p.diagnostics, dkInstallMethodInnoSetup))
    check (not hasDiagnostic(p.diagnostics, dkInstallMethodMsi))
    check (not hasDiagnostic(p.diagnostics, dkInstallMethodNsisBundle))
