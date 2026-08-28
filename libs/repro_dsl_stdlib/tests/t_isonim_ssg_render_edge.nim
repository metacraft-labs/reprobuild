## `buildIsonimStaticSite.build` must emit a run edge that (a) runs the
## compiled exporter binary and (b) declares its `dist/` output as a captured
## directory output while declaring the exporter binary as an input.
##
## The directory-vs-file distinction is made by the engine at revalidate time
## (a `dist` path in `action.outputs` is classified `ffkDirectory` when it is
## stat'd), so at DSL-emission time the invariant to pin is: `outputDir` lands
## in `outputs`, the exporter binary lands in `inputs` (so the engine builds it
## first and re-keys on its content), and the run edge's argv is the bare
## exporter invocation.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/isonim_ssg
import repro_dsl_stdlib/types

suite "buildIsonimStaticSite emits a directory-output render edge":

  test "declares dist/ as an output and the exporter as an input":
    resetBuildActionRegistry()
    let edge = buildIsonimStaticSite.build(
      exporter = "build" / "static_export",
      outputDir = "dist",
      actionId = "site.export.render")

    check edge.id == "site.export.render"
    check "dist" in edge.outputs
    check ("build" / "static_export") in edge.inputs

  test "the run edge's argv is the bare exporter invocation":
    resetBuildActionRegistry()
    let edge = buildIsonimStaticSite.build(
      exporter = "build" / "static_export",
      actionId = "site.export.render2")
    # The whole argv is carried as a single positional "argv" seq arg; with no
    # extra args it is just the exporter binary path.
    check edge.call.arguments.len == 1
    check edge.call.arguments[0].name == "argv"
    check ("build" / "static_export") in edge.call.arguments[0].encodedValue

  test "extra argv, inputs and outputs are threaded through":
    resetBuildActionRegistry()
    let edge = buildIsonimStaticSite.build(
      exporter = "build" / "export",
      outputDir = "public",
      args = @["--out", "public"],
      extraInputs = @["site.config"],
      extraOutputs = @["public/sitemap.xml"],
      actionId = "site.export.render3")
    check "public" in edge.outputs
    check "public/sitemap.xml" in edge.outputs
    check ("build" / "export") in edge.inputs
    check "site.config" in edge.inputs
    # exporter + --out + public are all carried in the single argv seq arg.
    let argv = edge.call.arguments[0].encodedValue
    check ("build" / "export") in argv
    check "--out" in argv
    check "public" in argv

  test "an `after` edge is folded into the render edge's deps":
    resetBuildActionRegistry()
    # A stand-in compile edge whose id the render edge must depend on.
    let compileEdge = buildAction("site.export.compile",
      inlineExecCall(@["nim", "c", "src/static_export.nim"]))
    let edge = buildIsonimStaticSite.build(
      exporter = "build" / "static_export",
      after = @[compileEdge],
      actionId = "site.export.render4")
    check "site.export.compile" in edge.deps

  test "default outputDir is dist":
    resetBuildActionRegistry()
    let edge = buildIsonimStaticSite.build(
      exporter = "build" / "static_export",
      actionId = "site.export.render5")
    check "dist" in edge.outputs
