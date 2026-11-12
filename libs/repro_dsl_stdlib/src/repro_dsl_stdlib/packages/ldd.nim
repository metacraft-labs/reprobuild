## ``ldd``: lists an ELF image's dynamic dependencies. It is glibc's script,
## from nixpkgs' ``glibc`` ``bin`` output at the canonical pin.
##
## Linux only: ``ldd`` is a glibc tool and nixpkgs builds glibc for Linux
## alone. macOS answers the same question with ``otool -L`` and Windows with
## ``llvm-objdump -p``; neither is this package.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

package ldd:
  platforms [linux], msg = "ldd is glibc's tool; nixpkgs builds glibc for Linux only. macOS uses otool -L and Windows llvm-objdump -p."
  provisioning:
    nixPackage "nixpkgs#glibc^bin", executablePath = "bin/ldd",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
