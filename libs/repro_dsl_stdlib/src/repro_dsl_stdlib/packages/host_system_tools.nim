## Host utilities used by image and infrastructure recipes when no sibling
## from-source recipe exists. Each tool keeps its command name while sharing
## the canonical nixpkgs package that supplies it.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

# `gzip` is defined ONCE, in `gzip.nim` (nix + the Windows PortableGit
# channel `tar -z` needs). A second, nix-only `package gzip:` used to live
# here, and because every recipe reaches this module through `system_tools`
# while `gzip.nim` was imported only by the packaging producers, the
# nix-only copy is the one a from-source recipe saw — so any Windows
# `--tool-provisioning=tarball` build that extracts a `.tar.gz` failed tool
# resolution on `gzip`. Re-exported so importers of this module keep it.
import ./gzip
export gzip

package xz:
  provisioning:
    nixPackage "nixpkgs#xz", executablePath = "bin/xz",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package bzip2:
  provisioning:
    nixPackage "nixpkgs#bzip2", executablePath = "bin/bzip2",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package b3sum:
  provisioning:
    nixPackage "nixpkgs#b3sum", executablePath = "bin/b3sum",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package sed:
  provisioning:
    nixPackage "nixpkgs#gnused", executablePath = "bin/sed",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: Git for Windows ships this at `usr/bin/sed.exe`. Same
    # two channels as `sh` -- Scoop's `main/git` and the pinned
    # PortableGit archive (one download, deduped by the store; only the
    # `executablePath` view differs). Precedent: sh.nim, tar.nim, gzip.nim.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "usr/bin/sed.exe",
      requiresExecutionProfileChecksum = false)
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "usr/bin/sed.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"

package grep:
  provisioning:
    nixPackage "nixpkgs#gnugrep", executablePath = "bin/grep",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package ssh:
  provisioning:
    nixPackage "nixpkgs#openssh", executablePath = "bin/ssh",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `ssh-keygen`:
  provisioning:
    nixPackage "nixpkgs#openssh", executablePath = "bin/ssh-keygen",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

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

package od:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/od",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package tr:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/tr",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package wc:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/wc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package cut:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/cut",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package uname:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/uname",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package readlink:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/readlink",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package mktemp:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/mktemp",
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
    # Windows: Git for Windows ships this at `usr/bin/sha256sum.exe`. Same
    # two channels as `sh` -- Scoop's `main/git` and the pinned
    # PortableGit archive (one download, deduped by the store; only the
    # `executablePath` view differs). Precedent: sh.nim, tar.nim, gzip.nim.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "usr/bin/sha256sum.exe",
      requiresExecutionProfileChecksum = false)
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "usr/bin/sha256sum.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"

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
    # Windows: Git for Windows ships this at `usr/bin/chmod.exe`. Same
    # two channels as `sh` -- Scoop's `main/git` and the pinned
    # PortableGit archive (one download, deduped by the store; only the
    # `executablePath` view differs). Precedent: sh.nim, tar.nim, gzip.nim.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "usr/bin/chmod.exe",
      requiresExecutionProfileChecksum = false)
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "usr/bin/chmod.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"

package `mv`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/mv",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: Git for Windows ships this at `usr/bin/mv.exe`. Same
    # two channels as `sh` -- Scoop's `main/git` and the pinned
    # PortableGit archive (one download, deduped by the store; only the
    # `executablePath` view differs). Precedent: sh.nim, tar.nim, gzip.nim.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "usr/bin/mv.exe",
      requiresExecutionProfileChecksum = false)
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "usr/bin/mv.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"

package `cp`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/cp",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: Git for Windows ships this at `usr/bin/cp.exe`. Same
    # two channels as `sh` -- Scoop's `main/git` and the pinned
    # PortableGit archive (one download, deduped by the store; only the
    # `executablePath` view differs). Precedent: sh.nim, tar.nim, gzip.nim.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "usr/bin/cp.exe",
      requiresExecutionProfileChecksum = false)
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "usr/bin/cp.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"

package `rm`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/rm",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: Git for Windows ships this at `usr/bin/rm.exe`. Same
    # two channels as `sh` -- Scoop's `main/git` and the pinned
    # PortableGit archive (one download, deduped by the store; only the
    # `executablePath` view differs). Precedent: sh.nim, tar.nim, gzip.nim.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "usr/bin/rm.exe",
      requiresExecutionProfileChecksum = false)
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "usr/bin/rm.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"

package `find`:
  provisioning:
    nixPackage "nixpkgs#findutils", executablePath = "bin/find",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package patchelf:
  provisioning:
    nixPackage "nixpkgs#patchelf", executablePath = "bin/patchelf",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package readelf:
  provisioning:
    nixPackage "nixpkgs#binutils", executablePath = "bin/readelf",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `mkdir`:
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/mkdir",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: Git for Windows ships this at `usr/bin/mkdir.exe`. Same
    # two channels as `sh` -- Scoop's `main/git` and the pinned
    # PortableGit archive (one download, deduped by the store; only the
    # `executablePath` view differs). Precedent: sh.nim, tar.nim, gzip.nim.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "usr/bin/mkdir.exe",
      requiresExecutionProfileChecksum = false)
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "usr/bin/mkdir.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"

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
    # Windows: Git for Windows ships this at `usr/bin/touch.exe`. Same
    # two channels as `sh` -- Scoop's `main/git` and the pinned
    # PortableGit archive (one download, deduped by the store; only the
    # `executablePath` view differs). Precedent: sh.nim, tar.nim, gzip.nim.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "usr/bin/touch.exe",
      requiresExecutionProfileChecksum = false)
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "usr/bin/touch.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"

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

package `printf`:
  ## `printf(1)`, used by from-source shell actions to write stamps and
  ## launchers. A shell builtin too, but an action that names it as a
  ## tool identity needs a package that resolves in every provisioning
  ## mode, not only `path`.
  provisioning:
    nixPackage "nixpkgs#coreutils", executablePath = "bin/printf",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: Git for Windows ships this at `usr/bin/printf.exe`. Same
    # two channels as `sh` -- Scoop's `main/git` and the pinned
    # PortableGit archive (one download, deduped by the store; only the
    # `executablePath` view differs). Precedent: sh.nim, tar.nim, gzip.nim.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "usr/bin/printf.exe",
      requiresExecutionProfileChecksum = false)
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "usr/bin/printf.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"
