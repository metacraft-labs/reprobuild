import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package curlSource:
  versions:
    "8.14.1":
      sourceRevision = "curl-8_14_1"
      sourceUrl = "https://curl.se/download/curl-8.14.1.tar.xz"
      sourceRepository = "https://github.com/curl/curl"
  fetch:
    url: "https://curl.se/download/curl-8.14.1.tar.xz"
    sha256: "f4619a1e2474c4bbfedc88a7c2191209c8334b48fa1f4e53fd584cc12e9120dd"
    extractStrip: 1
  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"
    "perl"
  buildDeps:
    "openssl"
    "zlib"
  config:
    discard
  library libcurl:
    discard
  executable curl:
    discard
  build:
    setCurrentOwningPackageOverride("curlSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static",
        "--enable-shared",
        "--disable-manual",
        "--disable-ldap",
        "--disable-ldaps",
        "--without-brotli",
        "--without-libidn2",
        "--without-libpsl",
        "--without-libssh2",
        "--without-nghttp2",
        "--without-zstd",
        "--with-openssl",
        "--with-zlib",
        "--with-ca-path=/etc/ssl/certs",
      ])
      discard pkg.library("libcurl")
      discard pkg.executable("curl")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "openssl"
    "zlib"
