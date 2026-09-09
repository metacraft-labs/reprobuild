import repro_project_dsl
import repro_dsl_stdlib/constructors

package noSynthesisMirror:
  nativeBuildDeps:
    "cmake >=3.24"
  fetch:
    url: "https://example.invalid/mirror.tar.gz"
    sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  executable noSynthesisProbe:
    discard
