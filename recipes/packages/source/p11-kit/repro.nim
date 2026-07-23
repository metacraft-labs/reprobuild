import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package p11KitSource:
  versions:
    "0.25.5":
      sourceRevision = "0.25.5"
      sourceUrl = "https://github.com/p11-glue/p11-kit/releases/download/0.25.5/p11-kit-0.25.5.tar.xz"
      sourceRepository = "https://github.com/p11-glue/p11-kit"
  fetch:
    url: "https://github.com/p11-glue/p11-kit/releases/download/0.25.5/p11-kit-0.25.5.tar.xz"
    sha256: "04d0a86450cdb1be018f26af6699857171a188ac6d5b8c90786a60854e1198e5"
    extractStrip: 1
  nativeBuildDeps:
    "meson >=0.59"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
  config:
    discard
  library libP11Kit:
    discard
  build:
    setCurrentOwningPackageOverride("p11KitSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "hash_impl=internal",
        "libffi=disabled",
        "trust_module=disabled",
        "systemd=disabled",
        "bash_completion=disabled",
        "gtk_doc=false",
        "man=false",
        "nls=false",
        "test=false",
        "post_install_test=false",
      ])
      discard pkg.library("libP11Kit")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
