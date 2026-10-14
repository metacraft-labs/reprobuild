## GM4b: every archive realization of ``gh`` is a ``tarball`` statement
## in the ``provisioning:`` block below. The M68 ``ghCatalog``
## (``VersionedProvisioning``) copy that once sat beside it was merged
## into these statements and removed, so a home profile and a recipe's
## ``uses:`` select from one set of records. The catalog harvester
## emits ``tarball`` statements to merge here.
##
## M9.5: the Linux realization was harvested via ``--source
## gh-releases:cli/cli --asset-pattern 'gh_2\.93\.0_linux_amd64\.tar\.gz'
## --platform-os linux``. The inner ``bin/gh`` binary nests under
## ``gh_<ver>_linux_amd64/``, which ``stripComponents = 1`` removes.
## glibc floor: the gh upstream builds against the GoReleaser default
## (RHEL/CentOS 7 era, glibc 2.17+), satisfying the M9.5 spec's
## "glibc-2.17-compatible Linux tarballs" honest-scope target.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 Nix provisioning (preserved across the M68 harvest).
# ---------------------------------------------------------------------------

package gh:
  provisioning:
    nixPackage "nixpkgs#gh", executablePath = "bin/gh",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Direct-download arms. A recipe's `uses: "gh >=2"` under `tarball`
    # mode and a home profile's `package "gh"` both select from them
    # (GM4b). With only the nix arm, a Windows dev shell reported
    # `package "gh" ... does not declare provisioning: tarball metadata` and
    # gh was the one tool in the workspace dev-env floor it could not
    # provide.
    #
    # Digests are GitHub's own published asset digests for v2.93.0, checked
    # by downloading each asset (2026-09-24); they agreed with the retired
    # catalog record's. The Windows zip ships `bin/gh.exe` at the root; the Linux and
    # macOS archives nest it under `gh_2.93.0_<platform>/`, hence the strip.
    tarball url = "https://github.com/cli/cli/releases/download/v2.93.0/gh_2.93.0_windows_amd64.zip",
      sha256 = "77aa01ed7317295ad550de0ad04f3f276b1ef0e9272e3d002ac28dd99853d211",
      archiveType = "zip",
      executablePath = "bin/gh.exe",
      packageId = "gh@2.93.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:gh@2.93.0:sha256:77aa01ed7317295ad550de0ad04f3f276b1ef0e9272e3d002ac28dd99853d211",
      version = "2.93.0"
    tarball url = "https://github.com/cli/cli/releases/download/v2.93.0/gh_2.93.0_windows_arm64.zip",
      sha256 = "1d2ab9d48f01a86c7156dae3008428743d6cd716a51fc50410078d51dec3dea4",
      archiveType = "zip",
      executablePath = "bin/gh.exe",
      packageId = "gh@2.93.0",
      cpu = "aarch64",
      os = "windows",
      lockIdentity = "tarball:gh@2.93.0:windows-aarch64:sha256:1d2ab9d48f01a86c7156dae3008428743d6cd716a51fc50410078d51dec3dea4",
      version = "2.93.0"
    tarball url = "https://github.com/cli/cli/releases/download/v2.93.0/gh_2.93.0_linux_amd64.tar.gz",
      sha256 = "02d1290eba130e0b896f3709ffff22e1c75a51475ddb70476a85abc6b5807af0",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "bin/gh",
      packageId = "gh@2.93.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:gh@2.93.0:linux:sha256:02d1290eba130e0b896f3709ffff22e1c75a51475ddb70476a85abc6b5807af0",
      version = "2.93.0"
    tarball url = "https://github.com/cli/cli/releases/download/v2.93.0/gh_2.93.0_macOS_arm64.zip",
      sha256 = "a86be4e0a86c26456cf71177d6572d6f1165cf1679e532b72f7f15918ee51fd2",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "bin/gh",
      packageId = "gh@2.93.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:gh@2.93.0:macos-aarch64:sha256:a86be4e0a86c26456cf71177d6572d6f1165cf1679e532b72f7f15918ee51fd2",
      version = "2.93.0"
