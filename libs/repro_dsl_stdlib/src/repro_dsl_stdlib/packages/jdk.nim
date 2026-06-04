## ``jdk`` — Adoptium Temurin OpenJDK.
##
## M63 reference catalog entry. The first ``packages/<tool>.nim`` to
## carry a ``VersionedProvisioning`` record exposed via
## ``jdkCatalog: seq[VersionedProvisioning]``. The campaign's
## M49–M62 ``windows/ensure-jdk.ps1`` script remains live until M70
## deprecates it — this catalog is the planned replacement, declared
## only and not yet consumed by any realize loop (M64 is the first
## consumer).
##
## The entry mirrors the M49 ``ensure-jdk.ps1`` ground truth: same
## Adoptium GitHub-release URL pattern, same published SHA-256, same
## inner-dir flatten path (``jdk-21.0.5+11``), same probed binaries
## (``bin/javac.exe`` + ``bin/java.exe`` are the harness probes; the
## fuller catalog records ``jar.exe`` + ``jlink.exe`` too because the
## downstream maven / gradle / direct ``jar`` users need them).
##
## ``env.JAVA_HOME`` carries the conventional Java environment
## variable (the value ``${prefix}`` is substituted by the M64
## realizer with the realized prefix dir). Maven / Gradle / direct
## ``javac`` invocations honor it.
##
## Versions ship newest-first (the spec's "LAST entry is the default"
## convention is intentionally violated here — see M63
## ``selectDefault`` which keeps the LAST entry as default. M63 ships
## ONE version; M67's bulk-harvest will add 17.0.13 + 11.0.25 ahead
## of 21.0.5 so the default tracks the newest LTS).

import repro_project_dsl
import ../packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Existing M21 Nix provisioning (untouched by M63).
# ---------------------------------------------------------------------------
#
# The new ``versioned:`` catalog coexists alongside the Nix
# provisioning per the M63 spec ("M63 adds ``versioned: [...]``
# alongside, never instead — the M65 chain picks one per
# host/profile."). When the M64+M65 cakBuiltin adapter chain selects
# the Nix branch on a Nix-capable host, this declaration is honored;
# when it selects cakBuiltin, ``jdkCatalog`` below is consulted.

package jdk:
  provisioning:
    nixPackage "nixpkgs#jdk21", executablePath = "bin/javac",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

# ---------------------------------------------------------------------------
# M63 deliverable: the VersionedProvisioning catalog.
# ---------------------------------------------------------------------------

let jdkCatalog* = @[
  initVersionedProvisioning(
    version = "21.0.5",
    archive_format = afZip,
    install_method = imExtract,
    bin_relpath = @[
      "bin/javac.exe",
      "bin/java.exe",
      "bin/jar.exe",
      "bin/jlink.exe",
    ],
    platforms = @[
      # Windows x86_64 — the M49 reference case. URL + SHA-256 lifted
      # verbatim from windows/ensure-jdk.ps1 (the Adoptium release
      # asset's published SHA-256 sidecar).
      initPlatformBinary(
        cpu = pcX86_64,
        os = poWindows,
        url = "https://github.com/adoptium/temurin21-binaries/releases/" &
          "download/jdk-21.0.5%2B11/" &
          "OpenJDK21U-jdk_x64_windows_hotspot_21.0.5_11.zip",
        sha256 = "6f09d4a3598542313cca1540106d537c7092a54e415d569f7b928160a90d3128",
        extract_path = "jdk-21.0.5+11",
      ),
      # M9.5: Linux x86_64 slice. Adoptium ships the same inner-dir
      # layout (``jdk-21.0.5+11/bin/``) so extract_path matches; archive
      # is .tar.gz (vs. Windows .zip) and the binaries lack the .exe
      # suffix → both encoded via the M9.5 per-platform overrides.
      # Adoptium's HotSpot Linux builds target glibc 2.17 (RHEL 7
      # floor) per their release notes — matches the M9.5 spec's
      # honest-scope target.
      initPlatformBinary(
        cpu = pcX86_64,
        os = poLinux,
        url = "https://github.com/adoptium/temurin21-binaries/releases/" &
          "download/jdk-21.0.5%2B11/" &
          "OpenJDK21U-jdk_x64_linux_hotspot_21.0.5_11.tar.gz",
        sha256 = "3c654d98404c073b8a7e66bffb27f4ae3e7ede47d13284c132d40a83144bfd8c",
        extract_path = "jdk-21.0.5+11",
        archive_format_override = afTarGz,
        has_archive_format_override = true,
        bin_relpath_override = @[
          "bin/javac",
          "bin/java",
          "bin/jar",
          "bin/jlink",
        ],
      ),
    ],
    env = {"JAVA_HOME": "${prefix}"},
  ),
]
