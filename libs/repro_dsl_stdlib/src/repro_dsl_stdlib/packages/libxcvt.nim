## DSL-port M9.R.15q.5.12 — stdlib provisioning stub for ``libxcvt``.
##
## libxcvt is the VESA Coordinated Video Timings library +
## ``libxcvt.pc`` pkg-config file kwin 6.2.5's CMakeLists.txt:340
## probes via ``pkg_check_modules(... libxcvt>=0.1.1 ...)`` for the
## DRM backend's modeline-fallback computation. The sibling ``cvt``
## stub points at the ``bin/cvt`` binary; this stub points at the
## ``lib/libxcvt.so`` library + headers so resolvers consuming the
## library (vs the CLI tool) get the right multi-output channel.
##
## ## Provisioning channel — nixpkgs#libxcvt^*
##
## The ``^*`` suffix realizes ALL outputs (out + dev) so the
## resolver's multi-output walk finds the ``libxcvt.so`` and the
## ``libxcvt.pc`` in the dev output.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libxcvt`:
  provisioning:
    nixPackage "nixpkgs#libxcvt^*", executablePath = "lib/libxcvt.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
