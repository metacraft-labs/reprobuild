import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

const MirrorRecipeSource* = currentSourcePath()

package sed:
  versions:
    "1.0.0":
      discard
  nativeBuildDeps:
    "cmake >=3.24"
    "ninja >=1.10"
    "gcc >=11"
  executable `mirror-probe`:
    discard
  build:
    let pkg = cmake_package(srcDir = "src", buildDir = "build",
      generator = "Ninja")
    discard pkg.executable("mirror-probe")
    defaultTarget(target("mirror",
      BuildActionDef(id: "install-mirror-sed")))
