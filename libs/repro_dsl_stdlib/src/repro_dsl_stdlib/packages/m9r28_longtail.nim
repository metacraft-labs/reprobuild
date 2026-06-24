## DSL-port M9.R.28.4 — long-tail filesystem-utility deps.
##
## Stubs for the buildDep / nativeBuildDep selectors referenced by the
## M9.R.27.4 long-tail recipes (shadow-utils, sudo, parted, e2fsprogs,
## dosfstools, gdisk, cryptsetup, lvm2, btrfs-progs). Each is a
## single-channel nix stub; richer provisioning arrives when (and if)
## a sibling from-source recipe is authored later.
##
## M9.R.29.1 — the macro layer's ``stringLiteral`` helper falls back to
## ``node.repr`` for non-string-literal arguments. Passing ``nixpkgsRev =
## NixpkgsRev`` (a top-level ``const``) therefore emitted the literal
## identifier ``"NixpkgsRev"`` into the nix invocation and the build
## failed with ``error: hash 'NixpkgsNarHash' is not SRI``. Inline the
## values per the sibling stubs (``audit.nim``, ``libxcrypt.nim``, ...).

import repro_project_dsl

package `ncurses`:
  provisioning:
    nixPackage "nixpkgs#ncurses", executablePath = "lib/libncurses.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `popt`:
  provisioning:
    nixPackage "nixpkgs#popt", executablePath = "lib/libpopt.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `readline`:
  provisioning:
    nixPackage "nixpkgs#readline", executablePath = "lib/libreadline.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `zlib`:
  provisioning:
    nixPackage "nixpkgs#zlib", executablePath = "lib/libz.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `lzo`:
  provisioning:
    nixPackage "nixpkgs#lzo", executablePath = "lib/liblzo2.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `libgcrypt`:
  provisioning:
    nixPackage "nixpkgs#libgcrypt", executablePath = "lib/libgcrypt.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `json-c`:
  provisioning:
    nixPackage "nixpkgs#json_c", executablePath = "lib/libjson-c.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `device-mapper`:
  provisioning:
    nixPackage "nixpkgs#lvm2.lib", executablePath = "lib/libdevmapper.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `util-linux`:
  provisioning:
    nixPackage "nixpkgs#util-linux", executablePath = "lib/libblkid.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `pam`:
  provisioning:
    nixPackage "nixpkgs#linux-pam", executablePath = "lib/libpam.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `libbsd`:
  ## shadow-utils' configure tests for ``readpassphrase()`` which
  ## glibc lacks; libbsd provides it.
  provisioning:
    nixPackage "nixpkgs#libbsd", executablePath = "lib/libbsd.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `libmd`:
  ## libmd ships ``libmd.so`` which libbsd's runtime depends on
  ## (libbsd's DT_NEEDED includes libmd.so.0; the autoconf-style
  ## ``-lbsd`` link probe in shadow-utils therefore needs the libmd
  ## library on LIBRARY_PATH too, otherwise the linker fails with
  ## ``cannot find -lmd``).
  provisioning:
    nixPackage "nixpkgs#libmd", executablePath = "lib/libmd.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `libcap`:
  ## shadow-utils' helpers (``newuidmap``, ``newgidmap``) link against
  ## libcap for fine-grained capability management.
  provisioning:
    nixPackage "nixpkgs#libcap", executablePath = "lib/libcap.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `libaio`:
  ## Linux native AIO userspace library (libaio.so + libaio.h);
  ## lvm2 reaches for it for bcache async I/O.
  provisioning:
    nixPackage "nixpkgs#libaio", executablePath = "lib/libaio.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

package `gettext`:
  ## gettext provides ``msgfmt`` (compile .po → .mo locale catalogs)
  ## referenced by shadow-utils, sudo, parted, e2fsprogs, util-linux
  ## as a nativeBuildDep for translation files. The nix store ships
  ## the runtime libintl.so + the msgfmt binary in the same package.
  provisioning:
    nixPackage "nixpkgs#gettext", executablePath = "bin/msgfmt",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
