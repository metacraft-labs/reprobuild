import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package gypSource:
  versions:
    "0.21.1":
      sourceRevision = "v0.21.1"
      sourceUrl = "https://github.com/nodejs/gyp-next/archive/refs/tags/v0.21.1.tar.gz"
      sourceRepository = "https://github.com/nodejs/gyp-next"
  fetch:
    url: "https://github.com/nodejs/gyp-next/archive/refs/tags/v0.21.1.tar.gz"
    sha256: "d75d7a8365e823292d94d80ea2178aa37897272af275a71ce32493d931178caf"
    extractStrip: 1
  nativeBuildDeps:
    "python3 >=3.8"
  buildDeps:
    discard
  executable gyp:
    build:
      shell "mkdir -p $out/bin $out/share/gyp; cp -a pylib/gyp pylib/packaging $out/share/gyp/; printf '#!/bin/sh\\nprefix=$(CDPATH= cd -- \"$(dirname -- \"$0\")/..\" && pwd)\\nPYTHONPATH=\"$prefix/share/gyp\" exec python3 -c \"import gyp; gyp.script_main()\" \"$@\"\\n' > $out/bin/gyp; chmod +x $out/bin/gyp"
  runtimeDeps:
    discard
