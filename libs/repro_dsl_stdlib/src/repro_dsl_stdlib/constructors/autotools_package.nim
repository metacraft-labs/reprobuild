## DSL-port M9.R.2b — Layer-1 ``autotools_package`` multi-artifact
## constructor.
##
## Internally drives ``<srcDir>/configure`` + ``make`` + ``make
## install DESTDIR=...`` and returns an ``AutotoolsPackageResult``.

{.experimental: "callOperator".}

import std/strutils

import repro_project_dsl

import ../types/package_result
import ../packages/sh as sh_module
import ../packages/make as make_module

proc autotools_package*(srcDir: string;
                        buildDir = "build";
                        destdir = "out";
                        prefix = "/usr";
                        configureOptions: seq[string] = @[];
                        installTarget = "install"): AutotoolsPackageResult =
  ## Configure → build → install pipeline for an upstream autotools
  ## project. The configure step shells out via ``sh.shell`` to allow
  ## the recipe author to pass shell-escaped configure flags; the
  ## subsequent steps run ``make`` typed-style.
  var configureArgs = @["--prefix=" & prefix]
  for o in configureOptions:
    configureArgs.add(o)
  let configureEdge = shell(
    command = srcDir & "/configure " & configureArgs.join(" "),
    args = @[])
  let buildEdge = make(workDir = buildDir, vars = @[], targets = @[])
  let installEdge = make(
    workDir = buildDir,
    targets = @[installTarget],
    vars = @["DESTDIR=" & destdir])
  AutotoolsPackageResult(
    buildEdge: configureEdge,
    compileEdge: buildEdge,
    installEdge: installEdge,
    destdir: destdir,
    components: standardComponents())
