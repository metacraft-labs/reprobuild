## Source-from-tarball adwaita-icon-theme recipe — M9.R.15b
## GNOME-stack foundation.
##
## adwaita-icon-theme is the GNOME platform's default icon theme;
## it ships the SVG / PNG icon assets every GNOME / libadwaita /
## GTK4 application falls back to when the user hasn't selected a
## different theme. Without it, gtk4 apps render with empty buttons
## (no fallback) and gtk4's own widget catalog (e.g. the dialog
## icons) is missing.
##
## ## Why adwaita-icon-theme matters for the v1 desktop story
##
## NDE-G1 plants adwaita-icon-theme as a /usr/share/icons/Adwaita/
## tree so gtk4's icon-name -> file-path resolver finds the icons
## at runtime. The catalog at
## ``recipes/catalog/linux/adwaita-icon-theme.json`` pins the jammy
## .deb form; the from-source recipe is the alternate path for v1.
##
## ## sha256 strategy
##
## Per the network + audio batch convention: live ``fetch:`` URL
## points at download.gnome.org directly (no vendoring). sha256
## cross-checked against nixpkgs's
## ``pkgs/by-name/ad/adwaita-icon-theme/package.nix`` SRI hash
## ``sha256-+sbgQB/KcUeAVhoIG49+J8O8HbNOvaTaF1CB8msk1GA=`` (decodes
## to the hex value pinned below; verified to match the upstream
## tarball bytes).
##
## ## Version choice — 50.0 (current upstream stable)
##
## adwaita-icon-theme 50.0 is the current stable matching the
## GNOME 50 release line. nixpkgs (2026-06) pins 50.0 too. The
## adwaita-icon-theme repo follows the GNOME major-only versioning
## scheme (no point releases within a major).
##
## sha256 = fac6e0401fca714780561a081b8f7e27c3bc1db34ebda4da175081f26b24d460
##
## ## Build shape
##
## Meson + ninja, but the build is almost entirely a "copy files
## into $prefix/share/icons/Adwaita/" step. No compiled artifacts.
##
## ## Artifacts
##
## adwaita-icon-theme produces NO shared libraries and NO
## executables — it ships only data files (SVG icons + an
## index.theme metadata file). For the artifact registry we
## record one ``files`` artifact rooted at the install component
## that owns the icon tree, so the M9.L install glue can plant
## the share/icons/Adwaita subtree under the activation root.
##
## ## Configurables
##
## v1 ships NO configurables.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package adwaitaIconThemeSource:
  ## From-source adwaita-icon-theme — GNOME-stack icon assets.

  versions:
    "50.0":
      sourceRevision = "50.0"
      sourceUrl = "https://download.gnome.org/sources/adwaita-icon-theme/50/adwaita-icon-theme-50.0.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/adwaita-icon-theme"

  fetch:
    url: "https://download.gnome.org/sources/adwaita-icon-theme/50/adwaita-icon-theme-50.0.tar.xz"
    sha256: "fac6e0401fca714780561a081b8f7e27c3bc1db34ebda4da175081f26b24d460"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=0.55"
    "ninja >=1.10"

  buildDeps:
    discard

  config:
    discard

  files iconAssets:
    ## ``/usr/share/icons/Adwaita/`` — the SVG + PNG icon tree
    ## consumed by gtk4 + libadwaita at runtime.
    discard

  build:
    setCurrentOwningPackageOverride("adwaitaIconThemeSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[])
      discard pkg.files("iconAssets")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
