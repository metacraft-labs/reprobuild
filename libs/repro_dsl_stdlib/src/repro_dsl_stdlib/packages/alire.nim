## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: gh-releases:alire-project/alire
## Versions (newest-first): 2.1.1
##
## M9.5 (hand-edited): added the x86_64-linux tarball
## realization harvested via ``--source
## gh-releases:alire-project/alire --asset-pattern
## 'alr-2\.1\.1-bin-x86_64-linux\.zip' --platform-os linux``. Same
## archive format (``zip``) as Windows, but the Linux binary is
## ``bin/alr`` (no ``.exe``) → the per-platform executablePath carries the
## platform-specific basename. Upstream Alire's Linux build targets
## Ubuntu 22.04 LTS as the floor; operators on older distros should
## fall through to nix realization.

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package alire:
  provisioning:
    tarball url = "https://github.com/alire-project/alire/releases/download/v2.1.1/alr-2.1.1-bin-x86_64-windows.zip",
      sha256 = "863013b1f94da6f3b7d0d5a74022ac3370424eeea9a470ebdb33d188d61b9125",
      archiveType = "zip",
      executablePath = "bin/alr.exe",
      version = "2.1.1",
      packageId = "alire@2.1.1",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://github.com/alire-project/alire/releases/download/v2.1.1/alr-2.1.1-bin-x86_64-linux.zip",
      sha256 = "09c66bcd8c35dd4b97b72c3d9b76e44caa6964a2db35aba069f396f00f1f64c7",
      archiveType = "zip",
      executablePath = "bin/alr",
      version = "2.1.1",
      packageId = "alire@2.1.1",
      cpu = "x86_64",
      os = "linux"
