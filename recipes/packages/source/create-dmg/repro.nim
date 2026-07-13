import repro_project_dsl
import repro_dsl_stdlib/types

package `create-dmg`:
  versions:
    "1.2.3":
      sourceRevision = "v1.2.3"
      sourceUrl = "https://github.com/create-dmg/create-dmg/archive/refs/tags/v1.2.3.tar.gz"
      sourceRepository = "https://github.com/create-dmg/create-dmg.git"

  fetch:
    url: "https://github.com/create-dmg/create-dmg/archive/refs/tags/v1.2.3.tar.gz"
    sha256: "8cf7b4ae540801171f4f630f1f2956913aaa87483b7ac03458f52b6cd0c48953"
    extractStrip: 1

  nativeBuildDeps:
    "sh"

  executable `create-dmg`:
    build:
      shell "chmod +x create-dmg"
      shell "mkdir -p $out/bin && cp create-dmg $out/bin/create-dmg"
      shell "mkdir -p $out/share/create-dmg && cp -r support $out/share/create-dmg/support"
