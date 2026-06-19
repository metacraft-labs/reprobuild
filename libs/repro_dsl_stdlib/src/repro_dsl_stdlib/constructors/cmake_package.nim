## DSL-port M9.R.2b — Layer-1 ``cmake_package`` multi-artifact
## constructor.
##
## Internally drives ``cmake.configure`` + ``cmake.build`` +
## ``cmake.install`` and returns a ``CmakePackageResult``.

{.experimental: "callOperator".}

import repro_project_dsl

import ../types/package_result
import ../packages/cmake as cmake_module

proc cmake_package*(srcDir: string;
                    buildDir = "build";
                    destdir = "out";
                    prefix = "/usr";
                    generator = "";
                    cacheVars: seq[string] = @[];
                    target = ""): CmakePackageResult =
  ## Configure → build → install pipeline for an upstream cmake
  ## project. v1 leaves component selection up to the recipe
  ## (``component`` field on the install call); the standard layout
  ## table populated on the result mirrors meson's.
  let configureEdge = cmake.configure(
    srcDir = srcDir,
    buildDir = buildDir,
    generator = generator,
    cacheVars = cacheVars)
  let buildEdge = cmake.build(
    buildDir = buildDir,
    target = target)
  let installEdge = cmake.install(
    buildDir = buildDir,
    prefix = destdir & prefix)
  CmakePackageResult(
    buildEdge: configureEdge,
    compileEdge: buildEdge,
    installEdge: installEdge,
    destdir: destdir,
    components: standardComponents())
