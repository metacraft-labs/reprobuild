## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for
## ``xcb-util-image``.
##
## ``xcb-util-image`` ships ``libxcb-image.so`` — utility routines
## for XImage <-> xcb_image_t conversion used by X11-side
## screenshot / framebuffer-read paths.
##
## ## Provisioning channel — nixpkgs#xorg.xcbutilimage^*

import repro_project_dsl

package `xcb-util-image`:
  provisioning:
    nixPackage "nixpkgs#xorg.xcbutilimage^*", executablePath = "lib/libxcb-image.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
