## ``zstd-dev`` — Zstandard's DEVELOPMENT channel: ``zstd.h`` on the include
## path and ``libzstd`` on the library path. The sibling ``zstd`` package
## (``packages/zstd.nim``) is the CLI tool, and the two are deliberately
## separate selectors.
##
## ## Why a second package rather than a wider ``zstd``
##
## A recipe declares what it needs, and "I run ``zstd``" and "I compile
## against ``zstd.h``" are different needs with different realizations. The
## catalog already splits exactly this way twice:
##
##   * ``cvt`` (``packages/cvt.nim``, ``nixpkgs#libxcvt`` -> ``bin/cvt``) is
##     the VESA timings CLI; ``libxcvt`` (``packages/libxcvt.nim``,
##     ``nixpkgs#libxcvt^*`` -> ``lib/libxcvt.so``) is the library kwin's DRM
##     backend probes through pkg-config. One upstream package, two selectors,
##     and only the library one realizes every output.
##   * ``python3`` is the interpreter; ``python-dev``
##     (``packages/python_dev.nim``) is the headers + import libraries PyO3
##     links against.
##
## ``zstd`` had only the first half. This module is its second.
##
## (``openssl`` needs no such pair: ``packages/openssl.nim`` already declares
## ``nixpkgs#openssl^*``, so its ``dev`` output is realized even though its
## declared executable is ``bin/openssl``. Checked 2026-10-15 — it is not an
## instance of this defect, and neither is ``libxcvt``.)
##
## The split is the general answer to a SPLIT-OUTPUT package, not a zstd
## special case:
##
##   * the CLI package names the output that carries ``bin/<tool>`` and
##     declares that executable, so resolution fails loudly when the tool is
##     missing;
##   * the dev package names EVERY output (``^*``) and declares a HEADER as
##     its ``executablePath``, so resolution fails loudly when the header is
##     missing.
##
## ## The defect this closes, and why it was invisible
##
## ``nixpkgs#zstd``'s outputs are ``bin`` / ``dev`` / ``out`` / ``man``, and
## the DEFAULT output is ``bin`` — ``bin/zstd`` and nothing else. ``zstd.h``
## is in ``dev`` and ``libzstd.dylib`` / ``libzstd.so`` is in ``out``, so a
## consumer that declared only ``uses: "zstd"`` got neither.
##
## It got neither SILENTLY. ``repro_tool_profiles.addUniquePath`` appends a
## directory only "when the directory exists on disk", so
## ``<bin-output>/include`` — which does not exist — was dropped with no
## diagnostic, and the declared input failed OPEN. The failure surfaced much
## later and somewhere else, as a C compile error in generated Nim output
## (measured 2026-10-14 on aarch64-darwin against codetracer
## `4e2201692`: ``zstd_bindings.nim.c:557``, ``record_chunk.nim.c:559`` and
## ``span_stream.nim.c:559`` each ``fatal error: 'zstd.h' file not found``),
## attributed to the compile rather than to the dependency.
##
## ``executablePath = "include/zstd.h"`` is what turns that back into a
## diagnostic, and it costs nothing: ``resolveNixTool`` searches every
## realized output for the declared path and raises
## ``tool-resolution failed: nix package realized outputs without
## include/zstd.h`` when no output carries it. A realization that cannot
## supply the header is refused at resolution time, by name, instead of
## quietly contributing an empty include channel. ``packages/libegl_headers.nim``
## declares a header the same way for the same reason.
##
## ## Provisioning channel — ``nixpkgs#zstd^*``
##
## ``^*`` realizes ALL outputs (the M9.R.14f.10 multi-output pattern, as used
## by ``packages/libxcb.nim``), so ``resolveNixTool`` threads
##
##   * ``<dev>/include``            onto CPATH          (``zstd.h``)
##   * ``<out>/lib``                onto LIBRARY_PATH   (``-lzstd``)
##   * ``<dev>/lib/pkgconfig``      onto PKG_CONFIG_PATH (``libzstd.pc``)
##
## ``^*`` is preferred over the narrower ``nixpkgs#zstd.dev``. The ``dev``
## output does happen to name ``bin`` and ``out`` in its
## ``nix-support/propagated-build-inputs`` — measured 2026-10-15 on
## aarch64-darwin, ``/nix/store/4jdw27jn…-zstd-1.5.7-dev`` propagates
## ``…-zstd-1.5.7-bin`` and ``…-zstd-1.5.7`` — and
## ``expandNixPropagatedStorePaths`` would follow it. But that is a property
## of how this derivation happens to be written, not of the output model, so
## relying on it would make the recipe correct by coincidence. ``^*`` asks for
## what the package needs directly.
##
## ## Windows — MSYS2's UCRT64 package, pruned to a static ``libzstd.a``
##
## The contract is the POSIX one: ``zstd.h`` reaches the action through
## ``CPATH`` and ``libzstd`` through ``LIBRARY_PATH``, so a consumer that
## compiles ``#include <zstd.h>`` and links ``-lzstd`` with the MinGW gcc the
## catalog provisions (``packages/gcc.nim``, WinLibs UCRT) needs nothing else.
## A tarball realization threads exactly ``<prefix>/include`` and
## ``<prefix>/lib`` into those channels (``repro_tool_profiles``'
## ``tarballProfileFor``), so the archive has to put the library THERE.
##
## The facebook/zstd win64 release the ``zstd`` CLI package realizes does
## not. Its static archive is ``static/libzstd_static.lib`` and its import
## library is ``dll/libzstd.dll.a``; neither directory is ``lib/``, and
## ``libzstd_static.lib`` is not a name ``ld``'s ``-lzstd`` search accepts.
## That realization therefore supplied the header and silently no library:
## ``addUniquePath`` drops the missing ``<prefix>/lib`` without a diagnostic,
## the failure mode the sections above describe for the POSIX ``bin`` output.
## (Upstream ships no Windows arm64 build at all: the v1.5.6 and v1.5.7
## releases carry ``win32`` and ``win64`` zips only, checked 2026-11-11.)
##
## MSYS2's ``mingw-w64-ucrt-x86_64-zstd`` package has the standard layout
## under one top-level ``ucrt64/`` directory, beside pacman's ``.BUILDINFO`` /
## ``.MTREE`` / ``.PKGINFO``; ``stripComponents = 1`` puts ``include/`` and
## ``lib/`` at the prefix root and drops those three. Its ``libzstd.a`` is a
## plain COFF archive built by MSYS2's gcc 16.1.0 for the UCRT, without LTO
## (``.PKGINFO``: ``options = !lto``; no ``.gnu.lto_*`` sections), so the
## WinLibs gcc links it. It also matches the 1.5.7 the Nix arm realizes.
##
## Three paths are pruned, and each prune is load-bearing:
##
##   * ``lib/libzstd.dll.a`` — ``ld`` tries ``libzstd.dll.a`` before
##     ``libzstd.a`` for ``-lzstd``, so with it present every consumer would
##     link the DLL and then need ``libzstd.dll`` on its ``PATH`` at run time,
##     which nothing provisions for the programs a build produces. Pruned,
##     ``-lzstd`` can only bind the static archive.
##   * ``bin`` — ``libzstd.dll`` and a ``zstd.exe`` that imports it. A
##     tarball prefix's ``bin`` goes on the consuming action's ``PATH``, where
##     this ``zstd.exe`` would shadow the ``zstd`` package's self-contained
##     one and fail to start without its DLL. The CLI is the ``zstd``
##     package's job.
##   * ``lib/cmake`` — its ``zstdTargets-release.cmake`` names the pruned
##     ``libzstd.dll.a`` / ``libzstd.dll`` for ``zstd::libzstd_shared`` and
##     would fail ``find_package(zstd)`` on the missing files.
##
## ``lib/pkgconfig/libzstd.pc`` is kept: it says ``-lzstd``, which the
## pruned ``lib/`` satisfies statically, and its ``prefix=/ucrt64`` is
## relocated by pkg-config / pkgconf on Windows, which derive the prefix from
## the ``.pc`` file's own location there.
##
## The ``lib/`` that remains holds ``libzstd.a`` alone, no CRT or pthread
## archive, so putting it on ``LIBRARY_PATH`` cannot displace the
## compiler's own runtime libraries, which a whole MSYS2 ``lib/`` would.
##
## MSYS2 keeps superseded package files on ``repo.msys2.org`` (``1.5.7-1``,
## from 2025-02, is still served beside ``1.5.7-2``), so the pinned URL stays
## fetchable after a rebuild; ``packages/msys2_libevent.nim`` and
## ``packages/libtool.nim`` rely on the same.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

const ZstdDevMsys2Version* = "1.5.7-2"
  ## MSYS2's ``pkgver-pkgrel`` of the Windows realization. The record's
  ## ``version`` is zstd's own, 1.5.7: a ``-2`` suffix would read as a
  ## pre-release in a ``uses:`` range (``packages/msys2_libevent.nim``).

package `zstd-dev`:
  provisioning:
    nixPackage "nixpkgs#zstd^*", executablePath = "include/zstd.h",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: MSYS2's UCRT64 build, pruned so that ``lib/`` holds only the
    # static ``libzstd.a`` (module doc, "Windows"). Not the facebook/zstd zip
    # ``packages/zstd.nim`` pins: that one has no ``lib/`` directory.
    tarball url = "https://repo.msys2.org/mingw/ucrt64/mingw-w64-ucrt-x86_64-zstd-" &
        ZstdDevMsys2Version & "-any.pkg.tar.zst",
      sha256 = "dbdb8427280046a2b41697780aa4c52983b708082b0da4755951dc3bea96ca89",
      archiveType = "tar.zst",
      stripComponents = 1,
      prune = "bin",
      prune = "lib/libzstd.dll.a",
      prune = "lib/cmake",
      executablePath = "include/zstd.h",
      version = "1.5.7",
      packageId = "zstd-dev@" & ZstdDevMsys2Version,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:zstd-dev@" & ZstdDevMsys2Version &
        ":windows-x86_64:sha256:dbdb8427280046a2b41697780aa4c52983b708082b0da4755951dc3bea96ca89"
