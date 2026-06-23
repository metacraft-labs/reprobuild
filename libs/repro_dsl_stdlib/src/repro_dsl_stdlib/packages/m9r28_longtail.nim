## DSL-port M9.R.28.4 — long-tail filesystem-utility deps.
##
## Stubs for the buildDep / nativeBuildDep selectors referenced by the
## M9.R.27.4 long-tail recipes (shadow-utils, sudo, parted, e2fsprogs,
## dosfstools, gdisk, cryptsetup, lvm2, btrfs-progs). Each is a
## single-channel nix stub; richer provisioning arrives when (and if)
## a sibling from-source recipe is authored later.

import repro_project_dsl

const NixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8"
const NixpkgsNarHash =
  "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `ncurses`:
  provisioning:
    nixPackage "nixpkgs#ncurses", executablePath = "lib/libncurses.so",
      nixpkgsRev = NixpkgsRev, nixpkgsNarHash = NixpkgsNarHash

package `popt`:
  provisioning:
    nixPackage "nixpkgs#popt", executablePath = "lib/libpopt.so",
      nixpkgsRev = NixpkgsRev, nixpkgsNarHash = NixpkgsNarHash

package `readline`:
  provisioning:
    nixPackage "nixpkgs#readline", executablePath = "lib/libreadline.so",
      nixpkgsRev = NixpkgsRev, nixpkgsNarHash = NixpkgsNarHash

package `zlib`:
  provisioning:
    nixPackage "nixpkgs#zlib", executablePath = "lib/libz.so",
      nixpkgsRev = NixpkgsRev, nixpkgsNarHash = NixpkgsNarHash

package `lzo`:
  provisioning:
    nixPackage "nixpkgs#lzo", executablePath = "lib/liblzo2.so",
      nixpkgsRev = NixpkgsRev, nixpkgsNarHash = NixpkgsNarHash

package `libgcrypt`:
  provisioning:
    nixPackage "nixpkgs#libgcrypt", executablePath = "lib/libgcrypt.so",
      nixpkgsRev = NixpkgsRev, nixpkgsNarHash = NixpkgsNarHash

package `json-c`:
  provisioning:
    nixPackage "nixpkgs#json_c", executablePath = "lib/libjson-c.so",
      nixpkgsRev = NixpkgsRev, nixpkgsNarHash = NixpkgsNarHash

package `device-mapper`:
  provisioning:
    nixPackage "nixpkgs#lvm2.lib", executablePath = "lib/libdevmapper.so",
      nixpkgsRev = NixpkgsRev, nixpkgsNarHash = NixpkgsNarHash

package `util-linux`:
  provisioning:
    nixPackage "nixpkgs#util-linux", executablePath = "lib/libblkid.so",
      nixpkgsRev = NixpkgsRev, nixpkgsNarHash = NixpkgsNarHash

package `pam`:
  provisioning:
    nixPackage "nixpkgs#linux-pam", executablePath = "lib/libpam.so",
      nixpkgsRev = NixpkgsRev, nixpkgsNarHash = NixpkgsNarHash
