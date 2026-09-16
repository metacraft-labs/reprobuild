## ``addlicense`` — Google's SPDX licence-header tool.
##
## Part of the contributor gate: the repository requires every source file to
## carry its licence header, and this is what adds and checks them.
##
## Upstream publishes per-platform zips with the binary flat at the root.
## Version 1.2.0; both Windows digests come from Agent Harbor's
## ``ADDLICENSE_SHA256_WINDOWS_*`` pins. Note upstream's arm64 asset is
## spelled ``Windows_arm64`` while the x64 one is ``Windows_x86_64`` — not a
## typo here, an inconsistency in the release naming.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

const
  AddlicenseVersion = "1.2.0"
  AddlicenseBase =
    "https://github.com/google/addlicense/releases/download/v" &
    AddlicenseVersion & "/addlicense_v" & AddlicenseVersion & "_Windows_"

package addlicense:
  provisioning:
    nixPackage "nixpkgs#addlicense", executablePath = "bin/addlicense",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    tarball url = AddlicenseBase & "x86_64.zip",
      sha256 = "fe4f4a54daa4a750ffa7d1b0da471d077ac24f09d04d7c1f307e7b7950969d25",
      archiveType = "zip",
      executablePath = "addlicense.exe",
      packageId = "addlicense@" & AddlicenseVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:addlicense@" & AddlicenseVersion &
        ":windows-x86_64:sha256:fe4f4a54daa4a750ffa7d1b0da471d077ac24f09d04d7c1f307e7b7950969d25"

    tarball url = AddlicenseBase & "arm64.zip",
      sha256 = "32ab8ff74e9bb5d547acb9f074b396dee1e3a86ebac6a47bb7c35ed26940b219",
      archiveType = "zip",
      executablePath = "addlicense.exe",
      packageId = "addlicense@" & AddlicenseVersion,
      cpu = "aarch64",
      os = "windows",
      lockIdentity = "tarball:addlicense@" & AddlicenseVersion &
        ":windows-aarch64:sha256:32ab8ff74e9bb5d547acb9f074b396dee1e3a86ebac6a47bb7c35ed26940b219"
