## DSL-port M9.R.28.4 — stdlib provisioning stub for ``libfontenc``.
##
## libfontenc is the X.org font-encoding helper library; libxfont2's
## historic-font-path bootstrap depends on it. Pure-C library with
## one ``.so`` + headers under ``include/X11/fonts/``.
##
## Routed through nixpkgs#libfontenc.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libfontenc`:
  provisioning:
    nixPackage "nixpkgs#libfontenc", executablePath = "lib/libfontenc.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
