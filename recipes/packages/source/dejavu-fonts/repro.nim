## DejaVu 2.37 fonts generated from upstream SFD sources.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package dejavuFontsSource:
  versions:
    "2.37":
      sourceRevision = "version_2_37"
      sourceUrl = "https://github.com/dejavu-fonts/dejavu-fonts/archive/version_2_37.tar.gz"
      sourceRepository = "https://github.com/dejavu-fonts/dejavu-fonts"

  fetch:
    url: "https://github.com/dejavu-fonts/dejavu-fonts/archive/version_2_37.tar.gz"
    sha256: "c4d10a1b665db893adc0c0aaee7ecd81b2b47c877d5cea0b40216707cbf327e4"
    extractStrip: 1

  nativeBuildDeps:
    "make"
    "fontforge"

  buildDeps:
    discard

  config:
    discard

  files fonts:
    discard

  build:
    setCurrentOwningPackageOverride("dejavuFontsSource")
    try:
      let patches = @[
        "sed -i 's/^all : full sans lgc$/all : full-ttf/' src/Makefile",
        # FontForge has already generated the TTF at this point. Upstream's
        # optional Perl pass adjusts scaler flags and gasp tables only.
        "sed -i 's|^TTPOSTPROC  = .*|TTPOSTPROC = true|' src/Makefile",
        "printf '%b\\n' '' 'install:' " &
          "'\\tmkdir -p $(DESTDIR)/usr/share/fonts/truetype/dejavu " &
          "$(DESTDIR)/usr/share/fontconfig/conf.avail' " &
          "'\\tcp build/*.ttf $(DESTDIR)/usr/share/fonts/truetype/dejavu/' " &
          "'\\tcp fontconfig/*.conf $(DESTDIR)/usr/share/fontconfig/conf.avail/' " &
          ">> src/Makefile",
      ]
      let pkg = autotools_package(
        srcDir = "./src",
        configureOptions = @[],
        skipConfigure = true,
        srcPatches = patches)
      pkg.installTreeMirror()
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
