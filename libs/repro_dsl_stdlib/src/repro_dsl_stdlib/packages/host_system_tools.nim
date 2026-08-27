## Host utilities used by image and infrastructure recipes when no sibling
## from-source recipe exists. Each tool keeps its command name while sharing
## the canonical nixpkgs package that supplies it.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `qemu-img`:
  provisioning:
    nixPackage "nixpkgs#qemu", executablePath = "bin/qemu-img",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `qemu-nbd`:
  provisioning:
    nixPackage "nixpkgs#qemu", executablePath = "bin/qemu-nbd",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `partprobe`:
  provisioning:
    nixPackage "nixpkgs#parted", executablePath = "bin/partprobe",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `sgdisk`:
  provisioning:
    nixPackage "nixpkgs#gptfdisk", executablePath = "bin/sgdisk",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `mkfs.ext4`:
  provisioning:
    nixPackage "nixpkgs#e2fsprogs", executablePath = "bin/mkfs.ext4",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `mkfs.vfat`:
  provisioning:
    nixPackage "nixpkgs#dosfstools", executablePath = "bin/mkfs.vfat",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `grub-install`:
  provisioning:
    nixPackage "nixpkgs#grub2_efi", executablePath = "bin/grub-install",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `grub-mkconfig`:
  provisioning:
    nixPackage "nixpkgs#grub2_efi", executablePath = "bin/grub-mkconfig",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `modprobe`:
  provisioning:
    nixPackage "nixpkgs#kmod", executablePath = "bin/modprobe",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `rmmod`:
  provisioning:
    nixPackage "nixpkgs#kmod", executablePath = "bin/rmmod",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `lsmod`:
  provisioning:
    nixPackage "nixpkgs#kmod", executablePath = "bin/lsmod",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `mount`:
  provisioning:
    nixPackage "nixpkgs#util-linux", executablePath = "bin/mount",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `umount`:
  provisioning:
    nixPackage "nixpkgs#util-linux", executablePath = "bin/umount",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `mountpoint`:
  provisioning:
    nixPackage "nixpkgs#util-linux", executablePath = "bin/mountpoint",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `awk`:
  provisioning:
    nixPackage "nixpkgs#gawk", executablePath = "bin/awk",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `cmp`:
  provisioning:
    nixPackage "nixpkgs#diffutils", executablePath = "bin/cmp",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `diff`:
  provisioning:
    nixPackage "nixpkgs#diffutils", executablePath = "bin/diff",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `head`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/head",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `ln`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/ln",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `sort`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/sort",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `sha256sum`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/sha256sum",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `dirname`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/dirname",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `basename`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/basename",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `chmod`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/chmod",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `mv`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/mv",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `cp`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/cp",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `rm`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/rm",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `find`:
  provisioning:
    nixPackage "nixpkgs#findutils", executablePath = "bin/find",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `mkdir`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/mkdir",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `ls`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/ls",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `cat`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/cat",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `sleep`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/sleep",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `sync`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/sync",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `touch`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/touch",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `du`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/du",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `df`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/df",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `tail`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/tail",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
