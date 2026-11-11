## ``libclang`` — Clang's C library (``libclang``) and its ``clang-c``
## headers, for build steps that load it rather than run ``clang``.
##
## The commonest consumer is a Cargo build script that runs bindgen (directly
## or through crates such as ``rb-sys``). bindgen loads ``libclang`` at run
## time through clang-sys, which looks in ``LIBCLANG_PATH``, then in
## ``llvm-config --libdir``, then — on Linux — in the directories of
## ``LD_LIBRARY_PATH``, then in a fixed list of system directories
## (https://github.com/KyleMayes/clang-sys#dependencies). Declaring ``clang``
## does not help: the ``clang`` package is the compiler driver, and its
## realization carries no ``libclang.so``. Before this package a recipe had
## no way to declare the library, so such an edge failed with "Unable to
## find libclang" outside a dev shell that exported ``LIBCLANG_PATH``.
##
## ## Provisioning channel — ``nixpkgs#libclang^*``
##
## nixpkgs' ``libclang`` splits into ``lib`` (``lib/libclang.so``), ``dev``
## (``include/clang-c``) and others. ``^*`` realizes every output, so the
## resolver threads ``<lib>/lib`` onto the action's ``LIBRARY_PATH`` and
## ``LD_LIBRARY_PATH`` and ``<dev>/include`` onto ``CPATH`` — the same
## multi-output channel ``zstd-dev`` uses. ``LD_LIBRARY_PATH`` is where
## clang-sys finds it.
##
## ``executablePath`` names a HEADER, as ``zstd-dev`` does: it exists on every
## POSIX platform under the same name (the library's file name differs between
## ``.so`` and ``.dylib``), and ``resolveNixTool`` refuses a realization that
## lacks it by name instead of contributing an empty channel.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libclang`:
  provisioning:
    nixPackage "nixpkgs#libclang^*", executablePath = "include/clang-c/Index.h",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
