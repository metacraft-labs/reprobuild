## ``jdk`` — Adoptium Temurin OpenJDK.
##
## The M63 reference package for archive realizations. Until GM4b its
## Adoptium archives were a ``jdkCatalog`` (``VersionedProvisioning``)
## record beside the ``package jdk:`` block; they are now ``tarball``
## realizations inside it, which a home profile's ``package "jdk"`` and a
## recipe's ``uses:`` select from alike. They replace the M49–M62
## ``windows/ensure-jdk.ps1`` script.
##
## The realizations mirror the M49 ``ensure-jdk.ps1`` ground truth: same
## Adoptium GitHub-release URL pattern, same published SHA-256, same
## inner-dir flatten path (``extractPath = "jdk-21.0.5+11"``), same probed
## binaries (``bin/javac.exe`` + ``bin/java.exe`` are the harness probes;
## ``jar.exe`` + ``jlink.exe`` are declared too because the downstream
## maven / gradle / direct ``jar`` users need them).
##
## ``env = "JAVA_HOME=${prefix}"`` carries the conventional Java
## environment variable (``${prefix}`` is substituted by the realizer with
## the realized prefix dir). Maven / Gradle / direct ``javac`` invocations
## honor it.
##
## When more versions are added, list the default first: an unpinned
## reference takes the first eligible realization in declaration order.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import ../packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# The M21 Nix provisioning and the (GM4b) archive realizations. Which one a
# reference selects is the realization selector's decision, made from the
# selection policy and the target platform.
# ---------------------------------------------------------------------------

package jdk:
  provisioning:
    nixPackage "nixpkgs#jdk21", executablePath = "bin/javac",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # GM4b: archive realizations formerly held by the retired
    # `VersionedProvisioning` catalog record (see the conflict notes
    # in the Gradual-Nix-To-Reprobuild-Migration GM4b milestone).
    tarball url = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.5%2B11/OpenJDK21U-jdk_x64_windows_hotspot_21.0.5_11.zip",
      sha256 = "6f09d4a3598542313cca1540106d537c7092a54e415d569f7b928160a90d3128",
      archiveType = "zip",
      executablePath = "bin/javac.exe",
      extraExecutable = "bin/java.exe",
      extraExecutable = "bin/jar.exe",
      extraExecutable = "bin/jlink.exe",
      version = "21.0.5",
      packageId = "jdk@21.0.5",
      extractPath = "jdk-21.0.5+11",
      env = "JAVA_HOME=${prefix}",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.5%2B11/OpenJDK21U-jdk_x64_linux_hotspot_21.0.5_11.tar.gz",
      sha256 = "3c654d98404c073b8a7e66bffb27f4ae3e7ede47d13284c132d40a83144bfd8c",
      archiveType = "tar.gz",
      executablePath = "bin/javac",
      extraExecutable = "bin/java",
      extraExecutable = "bin/jar",
      extraExecutable = "bin/jlink",
      version = "21.0.5",
      packageId = "jdk@21.0.5",
      extractPath = "jdk-21.0.5+11",
      env = "JAVA_HOME=${prefix}",
      cpu = "x86_64",
      os = "linux"
