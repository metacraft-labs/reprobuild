## DSL-port M9.R.15b — stdlib provisioning stub for ``gtk-update-icon-cache``.
##
## adwaita-icon-theme's meson build invokes
##   gtk_update_icon_cache = find_program(
##     'gtk4-update-icon-cache',
##     'gtk-update-icon-cache',
##     required : true,
##   )
## at configure time; missing this binary short-fails meson setup
## even when the install_script that uses it is guarded by
## ``skip_if_destdir: true``.
##
## We register a stdlib provisioning channel keyed on the gtk3
## flavour of the binary (``bin/gtk-update-icon-cache``) so the
## resolver provisions it for the action's PATH at run time. The
## gtk4 flavour ships in gtk4's ``bin/`` output; for v1 we route
## through gtk3 because the v1 from-source closure does not yet
## publish gtk4 (gtk4 is a M9.R.15c target).

import repro_project_dsl

package `gtk-update-icon-cache`:
  provisioning:
    nixPackage "nixpkgs#gtk3", executablePath = "bin/gtk-update-icon-cache",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
