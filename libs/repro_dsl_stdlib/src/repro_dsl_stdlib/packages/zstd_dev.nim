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
## ## Windows
##
## The same facebook/zstd v1.5.6 win64 release the ``zstd`` package already
## realizes. It ships ``include/zstd.h`` and ``static/libzstd_static.lib``
## beside ``zstd.exe``, and ``stripComponents = 1`` puts them at the realized
## prefix root — which is why the Windows half of ``packages/zstd.nim``
## already described the shape this module implements on POSIX. The declared
## executable here is the HEADER, so the two packages realize the same archive
## and select different files out of it.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `zstd-dev`:
  provisioning:
    nixPackage "nixpkgs#zstd^*", executablePath = "include/zstd.h",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: the same archive ``packages/zstd.nim`` pins, selected on its
    # header instead of its ``zstd.exe``. Keep the url/sha256/packageId in
    # lockstep with that file — they are two views of one upstream release.
    tarball url = "https://github.com/facebook/zstd/releases/download/v1.5.6/zstd-v1.5.6-win64.zip",
      sha256 = "7b4eff6719990e38aca93a4844c2e86a1935090625c4611f7e89675e999c56cc",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "include/zstd.h",
      version = "1.5.6",
      packageId = "zstd-dev@1.5.6",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:zstd-dev@1.5.6:sha256:7b4eff6719990e38aca93a4844c2e86a1935090625c4611f7e89675e999c56cc"
