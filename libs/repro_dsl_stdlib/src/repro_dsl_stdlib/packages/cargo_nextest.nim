## ``cargo-nextest`` — the next-generation Rust test runner.
##
## Until now this package carried a Nix realization only, which made
## ``uses: "cargo-nextest"`` resolvable on a Nix host and nowhere else. The
## direct-download entries below close that gap for the same three platform
## slices ``rustc.nim`` / ``cargo.nim`` / ``rustfmt.nim`` already cover, so a
## project whose test suite runs under nextest can declare it in ``uses:``
## and have it realized on Windows and on non-Nix Linux as well.
##
## **Archive shape.** nextest-rs publishes one flat archive per target — a
## single ``cargo-nextest`` / ``cargo-nextest.exe`` at the archive root, with
## no wrapping directory. So ``stripComponents`` is 0 (the default) and
## ``executablePath`` is the bare binary name, unlike the rust-installer
## tarballs in ``rustc.nim`` which need a strip plus the component merge.
##
## **Why the Windows slices take the ``.zip`` and the others the
## ``.tar.gz``.** Upstream ships BOTH for every target. The contents are
## identical; the choice follows the platform's native archive format so the
## realize step uses the extractor each host already has, which is what the
## ``uv`` / ``just`` entries in this catalog do.
##
## **macOS is one universal binary.** Upstream publishes
## ``universal-apple-darwin`` rather than per-arch macOS archives, so the
## same artifact serves the aarch64 slice. There is no x86_64 macOS entry
## for the same reason ``rustc.nim`` ships only aarch64: the runner fleet is
## Apple Silicon.
##
## **Version.** 0.9.124, matching the ``CARGO_NEXTEST_VERSION`` pin Agent
## Harbor's ``scripts/windows-devenv/toolchain-versions.env`` carries. The
## aarch64-windows digest below is byte-identical to the
## ``CARGO_NEXTEST_SHA256_AARCH64_PC_WINDOWS_MSVC`` value that file already
## records, which is what cross-checks these URLs against a pin that was
## harvested independently. The remaining digests were computed from the
## upstream release assets on 2026-09-16.
##
## Bumping the version means re-harvesting every digest here; upstream
## publishes a ``<asset>.sha256`` sibling for each one.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

const
  NextestVersion = "0.9.124"
  NextestBase =
    "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-" &
    NextestVersion & "/cargo-nextest-" & NextestVersion & "-"

package `cargo-nextest`:
  provisioning:
    nixPackage "nixpkgs#cargo-nextest", executablePath = "bin/cargo-nextest",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    tarball url = NextestBase & "x86_64-pc-windows-msvc.zip",
      sha256 = "f9144814dc3d348f0756440acbad27cbae3e169b9ad686d4a7ca7a8301c7ac74",
      archiveType = "zip",
      executablePath = "cargo-nextest.exe",
      packageId = "cargo-nextest@" & NextestVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:cargo-nextest@" & NextestVersion &
        ":sha256:f9144814dc3d348f0756440acbad27cbae3e169b9ad686d4a7ca7a8301c7ac74"

    tarball url = NextestBase & "aarch64-pc-windows-msvc.zip",
      sha256 = "006f172250035bb0826ea056e5bf3efda2ebce14fcbdc58fd130e680a3b57874",
      archiveType = "zip",
      executablePath = "cargo-nextest.exe",
      packageId = "cargo-nextest@" & NextestVersion,
      cpu = "aarch64",
      os = "windows",
      lockIdentity = "tarball:cargo-nextest@" & NextestVersion &
        ":windows-aarch64:sha256:006f172250035bb0826ea056e5bf3efda2ebce14fcbdc58fd130e680a3b57874"

    tarball url = NextestBase & "x86_64-unknown-linux-gnu.tar.gz",
      sha256 = "cf3694155011e6e19a7306448b7984e5d0d781417a31478996a9018b7ec78e25",
      archiveType = "tar.gz",
      executablePath = "cargo-nextest",
      packageId = "cargo-nextest@" & NextestVersion,
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:cargo-nextest@" & NextestVersion &
        ":linux:sha256:cf3694155011e6e19a7306448b7984e5d0d781417a31478996a9018b7ec78e25"

    tarball url = NextestBase & "universal-apple-darwin.tar.gz",
      sha256 = "7fa40a74fbad476859211759528186252da77d6872bdb67b06a709152bd0a20c",
      archiveType = "tar.gz",
      executablePath = "cargo-nextest",
      packageId = "cargo-nextest@" & NextestVersion,
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:cargo-nextest@" & NextestVersion &
        ":macos-universal:sha256:7fa40a74fbad476859211759528186252da77d6872bdb67b06a709152bd0a20c"
