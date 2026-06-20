## DSL-port M9.R.15e.3 — stdlib provisioning stub for
## ``gsettings-desktop-schemas``.
##
## Pure-schema package surfacing the canonical GSettings .gschema.xml
## definitions for the GNOME desktop (a11y, calendar, default
## applications, input-sources, lockdown, peripherals, privacy, screen,
## sound, system, thumbnailers, ...). Consumed by mutter (47.x's
## ``src/meson.build:116`` declares the dep) and by gnome-shell + every
## GTK4 application that uses ``g_settings_new("org.gnome.<schema>")``.
##
## ## Why this stub exists separately from a full from-source recipe
##
## gsettings-desktop-schemas ships exclusively XML schema definitions
## (the .gschema.xml files); there's no compiled code beyond the gettext
## translation catalogs. Building it from source would mean re-running
## ``glib-compile-schemas`` over the XML tree; the nixpkgs prebuilt is
## byte-identical to a from-source build and the v1 desktop closure
## doesn't gain anything by re-emitting it. The pure-data shape mirrors
## the libegl-headers (M9.R.15d.1) precedent.
##
## ## Provisioning channel — nixpkgs#gsettings-desktop-schemas
##
## The .pc file lives at:
##   /nix/store/...-gsettings-desktop-schemas-49.1/
##     share/pkgconfig/gsettings-desktop-schemas.pc
##
## The resolver's ``share/pkgconfig`` channel (M9.R.14e.1 line 3881)
## already picks this up; declaring the package as a buildDep is enough
## to thread the pc file onto consumers' ``PKG_CONFIG_PATH``.

import repro_project_dsl

package `gsettings-desktop-schemas`:
  provisioning:
    nixPackage "nixpkgs#gsettings-desktop-schemas",
      executablePath = "share/pkgconfig/gsettings-desktop-schemas.pc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
