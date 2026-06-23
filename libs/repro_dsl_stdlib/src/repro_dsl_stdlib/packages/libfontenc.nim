## DSL-port M9.R.28.4 — stdlib provisioning stub for ``libfontenc``.
##
## libfontenc is the X.org font-encoding helper library; libxfont2's
## historic-font-path bootstrap depends on it. Pure-C library with
## one ``.so`` + headers under ``include/X11/fonts/``.
##
## Routed through nixpkgs#libfontenc.

import repro_project_dsl

package `libfontenc`:
  provisioning:
    nixPackage "nixpkgs#libfontenc", executablePath = "lib/libfontenc.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
