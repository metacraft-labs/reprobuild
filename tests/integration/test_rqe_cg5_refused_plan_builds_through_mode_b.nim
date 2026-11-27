## A crates.io workspace whose plan holds a unit the plan's edges do not
## build is built through the Mode B edge the units edge creates, and no
## unit edge runs.
##
## THE CONTRACT (the manager's decision of 2026-11-27 for deliverable 3c,
## Build-Engine item (c)). The plan is produced by an edge, so a plan these
## edges cannot build as a whole is known only while the build runs. The
## units edge then writes, in place of the unit edges' records, the record of
## the workspace's Mode B build edge (`mode_b.modeBBuildSpec`, the edge the
## static Mode B fragment declares), and the engine creates and runs it. A
## workspace is built either wholly by the plan's edges or wholly by cargo.
##
## THE FIXTURE. A one-package workspace `app` that depends on the crates.io
## crates `regbs`, which has a build script, and `regleaf`
## (`rqe_cg5_plan_fixture.setupRegistry`). The plan holds `regbs`'s build
## script compile and run, which these edges do not build yet.
##
## THE CHECKS. The build succeeds; the Mode B edge (`crude-build-app`) is
## created and runs; no `cargo.rustc/` edge exists in the build; cargo's
## `target/release/app` prints what the program prints; and the units edge's
## fragment holds the Mode B edge's record alone. (Printing the reason on
## every such build is deliverable 10's.)
##
## Falsifying mutation: the units edge failing on a refused plan instead of
## writing the Mode B edge's record (the regression option (B) of the
## decision would have been) fails the build and the test.
##
## MOCK POLICY: NO MOCKS. The real CLI, engine, cargo and rustc; real
## `.crate` files in a real store root; a vendored source in the builds'
## own cargo configuration so Mode B runs offline (see `vendorCargoHome`).

import std/[json, os, osproc, strutils, tempfiles, unittest]

import ./rqe_cg5_mode_a_support
import ./rqe_cg5_plan_fixture
import ./rqe_cg5_repro_build_support

proc writeBuildScriptDependent(root: string) =
  writeFileIn(root, "reprobuild.nim", "import repro_project_dsl\n" &
    "package app:\n  uses:\n    \"rust >=1.80\"\n")
  writeFileIn(root, "Cargo.toml",
    "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n" &
    "[dependencies]\nregbs = \"0.1.0\"\nregleaf = \"0.1.0\"\n")
  writeFileIn(root, "src/main.rs",
    "fn main() { println!(\"{} {}\", regbs::bs(), regleaf::leaf()); }\n")

suite "a refused plan builds through the Mode B edge":

  test "test_rqe_cg5_refused_plan_builds_through_mode_b":
    let work = createTempDir("rqe-cg5-refused-", "")
    defer: removeTestTree(work)
    let reg = setupRegistry(work, smReal)
    let ws = work / "ws"
    writeBuildScriptDependent(ws)
    lockWorkspace(ws, work, reg)
    let env = reproBuildEnv(work, reg)
    vendorCargoHome(work, reg)
    let o = reproBuild(env, ws)
    checkpoint o.describe
    require o.code == 0
    check o.launchedIds("cargo.plan/").len == 1
    check o.launchedIds("cargo.plan-units/").len == 1
    check o.idsWithPrefix("cargo.rustc/").len == 0
    let modeB = o.action("crude-build-app")
    require modeB.kind == JObject
    check modeB{"status"}.getStr() == "asSucceeded"
    check modeB{"launched"}.getBool()
    let app = ws / "target" / "release" / "app"
    require fileExists(app)
    check execCmdEx(app).output.strip() == "5 5"
    # The units edge's fragment created the Mode B edge and nothing else.
    var created: seq[string]
    for u in unitRecords(ws): created.add u.id
    check created == @["crude-build-app"]
