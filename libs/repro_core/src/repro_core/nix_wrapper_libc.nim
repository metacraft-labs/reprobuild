## The libc a nixpkgs compiler wrapper records for itself.
##
## A nixpkgs cc-wrapper (and the binutils-wrapper it propagates) writes the
## store path of the libc it compiles and links against to
## ``nix-support/orig-libc``. The wrapper passes that libc to its own compiler
## and linker on every call: ``-B<libc>/lib`` through ``libc-crt1-cflags`` and
## ``-L<libc>/lib`` through the binutils wrapper's ``libc-ldflags``
## (https://github.com/NixOS/nixpkgs/blob/master/pkgs/build-support/cc-wrapper/default.nix,
## https://github.com/NixOS/nixpkgs/blob/master/pkgs/build-support/bintools-wrapper/default.nix).
##
## So this libc is the wrapper's private business. Placed on ``LIBRARY_PATH``,
## it is consulted by every compiler an action runs, including a host ``gcc``
## that keeps its own dynamic loader: that compiler then links against the Nix
## libc, and the binary fails on the host's older libc at run time
## (``version `GLIBC_2.xx' not found``). Readers here exist for the consumers
## that need the recorded libc for another purpose (install normalization, and
## the engine's check that refuses the libc on the shared link channel). Both
## the tool catalog and the build engine read it, and the engine does not
## import the catalog, so the reader lives here.

import std/[os, strutils]

from ./paths import extendedPath

const NixWrapperLibcManifest* = "orig-libc"
  ## The ``nix-support`` file in which a nixpkgs cc-wrapper or
  ## binutils-wrapper records the store path of its libc.

proc nixCompilerWrapperLibcs*(storePaths: openArray[string]): seq[string] =
  ## The libc store paths that the Nix compiler and binutils wrappers among
  ## ``storePaths`` record in ``nix-support/orig-libc``, in discovery order,
  ## without duplicates. A recorded path that does not exist is skipped, and
  ## so is a manifest that cannot be read.
  for path in storePaths:
    let manifest = path / "nix-support" / NixWrapperLibcManifest
    if not fileExists(extendedPath(manifest)):
      continue
    let text =
      try: readFile(extendedPath(manifest))
      except IOError, OSError: continue
    for candidate in text.splitWhitespace:
      if dirExists(extendedPath(candidate)) and candidate notin result:
        result.add(candidate)

proc nixCompilerWrapperLibcDirs*(storePaths: openArray[string]): seq[string] =
  ## The library directories (``lib``, ``lib64``, those that exist) of the
  ## libcs that the Nix wrappers among ``storePaths`` record
  ## (``nixCompilerWrapperLibcs``).
  for libc in nixCompilerWrapperLibcs(storePaths):
    for leaf in ["lib", "lib64"]:
      let dir = libc / leaf
      if dirExists(extendedPath(dir)) and dir notin result:
        result.add(dir)
