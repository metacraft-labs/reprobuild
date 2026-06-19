## DSL-port M9.R.2b — Layer-1 ``meson_package`` multi-artifact
## constructor.
##
## Internally drives ``meson.setup`` + ``meson.compile`` + ``meson.install``
## and returns a ``MesonPackageResult`` whose ``.executable(name)`` /
## ``.library(name)`` / ``.files(name)`` methods slice install
## components into individual artifact bindings.
##
## The v1 component layout is the standard ``meson install`` layout
## (``usr/bin`` for runtime, ``usr/lib`` for libraries, ``usr/share/man``
## for man pages, ...) — see ``types/package_result.standardComponents``.

{.experimental: "callOperator".}

import repro_project_dsl

import ../types/package_result
import ../packages/meson as meson_module

proc meson_package*(srcDir: string;
                    buildDir = "build";
                    destdir = "out";
                    prefix = "/usr";
                    buildtype = "release";
                    configureOptions: seq[string] = @[];
                    crossFile = "";
                    nativeFile = ""): MesonPackageResult =
  ## Configure → build → install pipeline for an upstream meson
  ## project. v1 ignores ``--tags`` filtering at install time — the
  ## ``.files("man")`` slicer returns the whole install edge and the
  ## caller resolves the specific component path via ``components``.
  let setup = meson.setup(
    srcDir = srcDir,
    buildDir = buildDir,
    prefix = prefix,
    buildtype = buildtype,
    options = configureOptions,
    crossFile = crossFile,
    nativeFile = nativeFile)
  let compileEdge = meson.compile(workDir = buildDir)
  let installEdge = meson.install(
    workDir = buildDir,
    destdir = destdir,
    tags = @[])
  MesonPackageResult(
    buildEdge: setup,
    compileEdge: compileEdge,
    installEdge: installEdge,
    destdir: destdir,
    components: standardComponents())
