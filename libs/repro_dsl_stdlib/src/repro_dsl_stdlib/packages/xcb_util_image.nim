## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for
## ``xcb-util-image``.
##
## ``xcb-util-image`` ships ``libxcb-image.so`` — utility routines
## for XImage <-> xcb_image_t conversion used by X11-side
## screenshot / framebuffer-read paths.
##
## ## Provisioning channel — nixpkgs#xorg.xcbutilimage^*

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `xcb-util-image`:
  provisioning:
    nixPackage "nixpkgs#xorg.xcbutilimage^*", executablePath = "lib/libxcb-image.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
