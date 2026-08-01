import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package auditSource:
  versions:
    "4.1.0":
      sourceRevision = "v4.1.0"
      sourceUrl = "https://github.com/linux-audit/audit-userspace/archive/refs/tags/v4.1.0.tar.gz"
      sourceRepository = "https://github.com/linux-audit/audit-userspace"
  fetch:
    url: "https://github.com/linux-audit/audit-userspace/archive/refs/tags/v4.1.0.tar.gz"
    sha256: "5911200423909b141e45bb1ae9d1608b1c974e5a5a52226d2f21501eb4ca809c"
    extractStrip: 1
  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"
  buildDeps:
    "libcap-ng"
  config:
    discard
  library libaudit:
    discard
  library libauparse:
    discard
  build:
    setCurrentOwningPackageOverride("auditSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-zos-remote",
        "--without-python3",
        "--with-libcap-ng=yes",
      ], patchHardcodedFile = true)
      discard pkg.library("libaudit")
      discard pkg.library("libauparse")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libcap-ng"
