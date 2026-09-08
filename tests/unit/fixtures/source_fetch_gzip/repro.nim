import repro_project_dsl

const GzipRecipeSource* = currentSourcePath()

package gzip:
  nativeBuildDeps:
    "curl >=8"
  fetch:
    url: "https://example.invalid/gzip.tar.xz"
    sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  build:
    raise newException(ValueError, "metadata extraction must not execute build bodies")
