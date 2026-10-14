## ``claude-code`` built-in tarball realization.
##
## **Upstream distribution model.** Anthropic publishes Claude Code as
## a single bare native binary per (cpu, os) — no archive, no
## installer, no inner directory. The binaries live in a GCS bucket
## under a stable per-release prefix:
##
##   https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/<VERSION>/<PLATFORM>/<binary>
##
## ``<PLATFORM>`` is one of ``win32-x64`` / ``win32-arm64`` /
## ``linux-x64`` / ``linux-arm64`` / ``darwin-x64`` / ``darwin-arm64``.
## ``<binary>`` is ``claude.exe`` on Windows realizations and ``claude``
## elsewhere. Upstream also ships ``linux-{x64,arm64}-musl`` variants;
## the schema has no libc dimension so we OMIT those realizations and let
## the glibc variant cover the ``os = "linux"`` axis (matches the
## ``gh`` / ``nim`` / ``zig`` precedent in this realization).
##
## **Checksum manifest.** Each version publishes a sibling manifest:
##
##   https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/<VERSION>/manifest.json
##
## with the JSON shape ``.platforms.<platform>.checksum`` (sha256, hex)
## per platform key. The harvester (or any future re-harvest) should
## fetch the manifest and surface the checksum verbatim. The hashes
## below were captured from the upstream manifests on 2026-06-10
## (versions 2.1.169 + 2.1.170; see the M0 milestone in
## ``reprobuild-specs/Dotfiles-Migration-Completion.milestones.org``
## for the campaign context).
##
## **Realize-time shape.** ``archiveType = "raw"`` (single bare
## executable, no extraction) + ``install method = extract``. For
## ``raw`` the M64 home archive realizer adapter performs a no-op copy-and-rename
## of the downloaded file into the realized prefix under
## declared executable list — ``@["claude.exe"]`` on Windows, ``@["claude"]``
## elsewhere (per-platform override).

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package `claude-code`:
  provisioning:
    tarball url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.1.169/win32-x64/claude.exe",
      sha256 = "b4b4bbedc86c6b4ad617f4e5fe59f299c9909d068b25b6916c5f6701451cdf12",
      archiveType = "raw",
      executablePath = "claude.exe",
      version = "2.1.169",
      packageId = "claude-code@2.1.169",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.1.169/win32-arm64/claude.exe",
      sha256 = "29360b804dba89eae9927c6161b3d35023a349119b6e5086377f29bed77e89ff",
      archiveType = "raw",
      executablePath = "claude.exe",
      version = "2.1.169",
      packageId = "claude-code@2.1.169",
      cpu = "aarch64",
      os = "windows"
    tarball url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.1.169/linux-x64/claude",
      sha256 = "cf066bf360cbf7b51abeb8cb230012fc0f2fed4253b2ce305de48ccd6d49a39c",
      archiveType = "raw",
      executablePath = "claude",
      version = "2.1.169",
      packageId = "claude-code@2.1.169",
      cpu = "x86_64",
      os = "linux"
    tarball url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.1.169/linux-arm64/claude",
      sha256 = "341072395844b2b6d2846d8d61d551752b12a44433c920d0cc7fe6e7b5692a9b",
      archiveType = "raw",
      executablePath = "claude",
      version = "2.1.169",
      packageId = "claude-code@2.1.169",
      cpu = "aarch64",
      os = "linux"
    tarball url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.1.169/darwin-x64/claude",
      sha256 = "6d8d510c715b899307b7d29a1062d43e62c99370c55330dac3ec1851a2fbf7c8",
      archiveType = "raw",
      executablePath = "claude",
      version = "2.1.169",
      packageId = "claude-code@2.1.169",
      cpu = "x86_64",
      os = "macos"
    tarball url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.1.169/darwin-arm64/claude",
      sha256 = "86d8b820ad7eed50e50a130706d3dc5ef70696f91194de1b3897a842182afe3a",
      archiveType = "raw",
      executablePath = "claude",
      version = "2.1.169",
      packageId = "claude-code@2.1.169",
      cpu = "aarch64",
      os = "macos"
    tarball url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.1.170/win32-x64/claude.exe",
      sha256 = "193061508fe619abf534b2c9d48151f26971d1d5b8460ad75c0af4be3d3525fb",
      archiveType = "raw",
      executablePath = "claude.exe",
      version = "2.1.170",
      packageId = "claude-code@2.1.170",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.1.170/win32-arm64/claude.exe",
      sha256 = "9abd330bcc191aecc877a8ee9da2b448852cfe3bda15e5e4608385ea1d9d1709",
      archiveType = "raw",
      executablePath = "claude.exe",
      version = "2.1.170",
      packageId = "claude-code@2.1.170",
      cpu = "aarch64",
      os = "windows"
    tarball url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.1.170/linux-x64/claude",
      sha256 = "849e007277a0442ab27570d3e3d6d43787507946590e8dd1947e5a39b7081f9e",
      archiveType = "raw",
      executablePath = "claude",
      version = "2.1.170",
      packageId = "claude-code@2.1.170",
      cpu = "x86_64",
      os = "linux"
    tarball url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.1.170/linux-arm64/claude",
      sha256 = "1bb9d032440a75532f7dd4cafbc687f220aaf16c63eba17e192dfbec2f04bd25",
      archiveType = "raw",
      executablePath = "claude",
      version = "2.1.170",
      packageId = "claude-code@2.1.170",
      cpu = "aarch64",
      os = "linux"
    tarball url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.1.170/darwin-x64/claude",
      sha256 = "914f23a70bbed5d9ae567e3e04b86206ed9971b371bc9baca3f79c8885bfddb4",
      archiveType = "raw",
      executablePath = "claude",
      version = "2.1.170",
      packageId = "claude-code@2.1.170",
      cpu = "x86_64",
      os = "macos"
    tarball url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.1.170/darwin-arm64/claude",
      sha256 = "e903646d8b7a31882a80ecd27569a27d8ac57b3708745f349709632c84117fdf",
      archiveType = "raw",
      executablePath = "claude",
      version = "2.1.170",
      packageId = "claude-code@2.1.170",
      cpu = "aarch64",
      os = "macos"
