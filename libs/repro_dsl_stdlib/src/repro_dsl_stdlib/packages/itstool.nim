## DSL-port M9.R.15g.2 — stdlib provisioning stub for ``itstool``.
##
## itstool is the XML-to-PO translation helper GNOME projects use to
## translate DocBook / Mallard user help.  gdm 47.x's
## ``src/docs/meson.build:1`` calls ``find_program('itstool')`` to
## generate the localised user-manual XML before invoking gnome.yelp.
## Without itstool the meson setup fails:
##
##   src/docs/meson.build:1:6: ERROR: Program 'itstool' not found or
##                                      not executable
##
## The `docs/` subdir is unconditional in gdm 47.0's meson.build —
## there's no upstream option to skip it.
##
## ## Provisioning channel — nixpkgs#itstool
##
## Standard nixpkgs entry; the package ships ``/bin/itstool`` (a Python
## script with the libxml2 binding) which is what
## ``find_program('itstool')`` consumes at configure time.

import repro_project_dsl

package `itstool`:
  provisioning:
    nixPackage "nixpkgs#itstool",
      executablePath = "bin/itstool",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
