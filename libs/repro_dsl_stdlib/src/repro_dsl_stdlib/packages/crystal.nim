## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: ScoopInstaller/Main
## Versions (newest-first): 1.20.2
##
## M9.5 (hand-edited): added the x86_64-linux tarball
## realization harvested via ``--source
## gh-releases:crystal-lang/crystal --asset-pattern
## 'crystal-1\.20\.2-1-linux-x86_64\.tar\.gz' --platform-os linux``.
## The Linux tarball is ``tar.gz`` + nests under ``crystal-1.20.2-1/``
## (``extractPath``) with ``bin/crystal`` + ``bin/shards`` inside; the
## non-bundled variant is used (the ``-bundled`` asset name ships
## additional libs that conflict with the host's runtime). Upstream
## Crystal's Linux release notes target glibc 2.17 — matches the M9.5
## spec's honest-scope target.

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package crystal:
  provisioning:
    tarball url = "https://github.com/crystal-lang/crystal/releases/download/1.20.2/crystal-1.20.2-windows-x86_64-msvc-unsupported.zip",
      sha256 = "15a41963373cc481f68dcc9a968bb11d36ee9254f1515eccee86d02223f8f82e",
      archiveType = "zip",
      executablePath = "crystal.exe",
      extraExecutable = "shards.exe",
      version = "1.20.2",
      packageId = "crystal@1.20.2",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://github.com/crystal-lang/crystal/releases/download/1.20.2/crystal-1.20.2-1-linux-x86_64.tar.gz",
      sha256 = "a28b99aded6b2836a2c6b9da4afc89d03fb951cfe6b41ff1594576317fec8c8e",
      archiveType = "tar.gz",
      executablePath = "bin/crystal",
      extraExecutable = "bin/shards",
      version = "1.20.2",
      packageId = "crystal@1.20.2",
      extractPath = "crystal-1.20.2-1",
      cpu = "x86_64",
      os = "linux"
