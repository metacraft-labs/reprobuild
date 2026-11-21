## GM4b: every archive realization of ``just`` is a ``tarball`` statement
## in the ``provisioning:`` block below. The M68 ``justCatalog``
## (``VersionedProvisioning``) copy that once sat beside it carried the
## same Windows and Linux archives; it was merged into these statements
## and removed, so a home profile and a recipe's ``uses:`` select from
## one set of records. The catalog harvester emits ``tarball`` statements
## to merge here.
##
## M9.5: the Linux realization was harvested via ``--source
## gh-releases:casey/just --asset-pattern
## 'just-1\.51\.0-x86_64-unknown-linux-musl\.tar\.gz' --platform-os
## linux``. The musl variant ships a statically-linked binary so
## glibc-floor is not a concern.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 Nix provisioning (preserved across the M68 harvest).
# ---------------------------------------------------------------------------

package just:
  provisioning:
    nixPackage "nixpkgs#just", executablePath = "bin/just",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows / non-Nix Linux: just via ScoopInstaller/Main. Single
    # static binary at the prefix root.
    scoopApp(bucket = "main", app = "just",
      preferredVersion = ">=1", executablePath = "just.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: just from GitHub Releases. Archive ships
    # `just.exe` flat at the root (no enclosing directory), so
    # stripComponents defaults to 0.
    tarball url = "https://github.com/casey/just/releases/download/1.51.0/just-1.51.0-x86_64-pc-windows-msvc.zip",
      sha256 = "09d1138b6845e73f04bff5e26be3f57663bddca25e36fe6241d28a5aa310b64e",
      archiveType = "zip",
      executablePath = "just.exe",
      packageId = "just@1.51.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:just@1.51.0:sha256:09d1138b6845e73f04bff5e26be3f57663bddca25e36fe6241d28a5aa310b64e",
      version = "1.51.0"
    # Linux x86_64: musl static binary from GitHub Releases. Archive
    # ships `just` flat at the root (no enclosing directory).
    tarball url = "https://github.com/casey/just/releases/download/1.51.0/just-1.51.0-x86_64-unknown-linux-musl.tar.gz",
      sha256 = "c8f085ca3e885723c341d06243fc291b5abfdc8bbe3b2c076b117de490387b59",
      archiveType = "tar.gz",
      executablePath = "just",
      packageId = "just@1.51.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:just@1.51.0:linux:sha256:c8f085ca3e885723c341d06243fc291b5abfdc8bbe3b2c076b117de490387b59",
      version = "1.51.0"
    # macOS aarch64: native Apple Silicon binary from GitHub Releases.
    # Same flat archive shape as the Linux/Windows entries (the `just`
    # binary sits at the archive root, no enclosing directory).
    tarball url = "https://github.com/casey/just/releases/download/1.51.0/just-1.51.0-aarch64-apple-darwin.tar.gz",
      sha256 = "61e3f1b8a545ff064b091eab4b6e14f8cc743ff15549be293b1e92f5b1467002",
      archiveType = "tar.gz",
      executablePath = "just",
      packageId = "just@1.51.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:just@1.51.0:macos-aarch64:sha256:61e3f1b8a545ff064b091eab4b6e14f8cc743ff15549be293b1e92f5b1467002",
      version = "1.51.0"
