## Source-built GNU nano for the ReproOS live environment.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package nanoSource:
  versions:
    "9.1":
      sourceRevision = "v9.1"
      sourceUrl = "https://www.nano-editor.org/dist/latest/nano-9.1.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/cgit/nano.git"

  fetch:
    url: "https://www.nano-editor.org/dist/latest/nano-9.1.tar.xz"
    sha256: "5f47764274cb7532349ce0aa20ec10f1e8e851a6e9fa3eb66812c43d196db042"
    extractStrip: 1

  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    "ncurses >=6.0"

  config:
    discard

  executable nano:
    discard

  build:
    setCurrentOwningPackageOverride("nanoSource")
    try:
      let opts = @[
        "--disable-nls",
        "--disable-libmagic",
        "--disable-speller",
        "--enable-utf8",
        "LIBS=-ltinfow",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("nano")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "ncurses >=6.0"
