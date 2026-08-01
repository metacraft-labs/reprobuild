## Clingo 5.8.0 source build for the repro CLI's ASP solver runtime.
## The CLI loads libclingo.so by soname at process startup, so the
## bootable image must provide the library independently of the build
## environment used to compile the CLI.

import repro_project_dsl
import repro_dsl_stdlib/types

package clingoSource:
  versions:
    "5.8.0":
      sourceRevision = "v5.8.0"
      sourceUrl = "https://github.com/potassco/clingo/archive/refs/tags/v5.8.0.tar.gz"
      sourceRepository = "https://github.com/potassco/clingo"

  fetch:
    url: "https://github.com/potassco/clingo/archive/refs/tags/v5.8.0.tar.gz"
    sha256: "4ddd5975e79d7a0f8d126039f1b923a371b1a43e0e0687e1537a37d6d6d5cc7c"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"
    "bison >=3.0"

  config:
    discard

  library libclingo:
    build:
      # Clingo generates libclingo/clingo.h in its source directory.
      # Build from a writable copy while preserving the fetched tree as
      # an immutable input to the monitored action.
      shell "rm -rf $out/source $out/build; mkdir -p $out/source $out/build; cp -a $extracted/. $out/source/"
      shell "cmake -S $out/source -B $out/build -G Ninja -DCMAKE_INSTALL_PREFIX=$out -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release -DCLINGO_BUILD_TESTS=OFF -DCLINGO_BUILD_EXAMPLES=OFF -DCLINGO_BUILD_APPS=OFF -DCLINGO_BUILD_SHARED=ON -DCLINGO_BUILD_WITH_PYTHON=OFF -DCLINGO_BUILD_WITH_LUA=OFF"
      shell "cmake --build $out/build -j8"
      shell "cmake --install $out/build"

  runtimeDeps:
    discard
