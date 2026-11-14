## The delegated cargo edge (the standard provider's Mode B) stays
## inside the width RunQuota grants it.
##
## THE CONTRACT. The edge is sized like a typed cargo call
## (Build-Engine-And-Scheduler.md, Sized T0 actions): it asks RunQuota for a
## width range and the engine writes the granted width after `-j` in the helper
## command (`repro-standard-provider --cargo-edge -j <grant> -- cargo build
## ...`), which hands it to cargo. cargo is the jobserver of its own rustc
## processes, so the tree stays inside the grant. Without the width the edge
## was the one-slot default and cargo used every core.
##
## HOW IT IS OBSERVED. A real `repro build` of a project with a build script
## and twelve independent library crates (the convention routes it to the
## delegated edge), under a real `runquotad` whose whole budget is two slots,
## with a `RUSTC_WRAPPER` in front of the real rustc that records when each
## crate's compile starts and ends (and holds each for 0.4 s so concurrent
## compiles overlap in time): the peak is exactly 2, and every crate compiled.
## The mutation named in the milestone (no width on the edge) leaves cargo at
## its default of every core; it was applied and the case observed to fail.
##
## NO MOCKS: real repro, real runquotad, real cargo and rustc.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import rqe_m15_width_fixture

const
  CrateCount = 12
  BudgetMilli = 2000

proc writeProject(root: string) =
  createDir(root / "src")
  var members: seq[string]
  var dependencies = ""
  for i in 0 ..< CrateCount:
    let name = "cg3_c" & $i
    members.add "\"" & name & "\""
    dependencies.add name & " = { path = \"" & name & "\" }\n"
    createDir(root / name / "src")
    writeFile(root / name / "Cargo.toml",
      "[package]\nname = \"" & name & "\"\nversion = \"0.1.0\"\n" &
      "edition = \"2021\"\n")
    writeFile(root / name / "src" / "lib.rs",
      "pub fn id() -> u32 { " & $i & " }\n")
  writeFile(root / "Cargo.toml",
    "[package]\nname = \"cg3_bounded\"\nversion = \"0.1.0\"\n" &
    "edition = \"2021\"\nbuild = \"build.rs\"\n\n[workspace]\nmembers = [" &
    members.join(", ") & "]\n\n[dependencies]\n" & dependencies)
  writeFile(root / "build.rs",
    "fn main() { println!(\"cargo:rerun-if-changed=build.rs\"); }\n")
  writeFile(root / "src" / "main.rs", "fn main() {}\n")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n\npackage cg3_bounded:\n  uses:\n" &
    "    \"rust >=1.80 <2.0\"\n    \"cargo >=1.80 <2.0\"\n\n" &
    "  executable cg3_bounded:\n    discard\n")
  let lock = execCmdEx("cargo generate-lockfile --offline",
    workingDir = root)
  if lock.exitCode != 0:
    raise newException(OSError, "cargo generate-lockfile failed: " &
      lock.output)

suite "the delegated cargo edge stays inside its grant":

  test "test_rqe_cg3_delegated_edge_bounded: twelve crates under a 2-slot " &
      "host budget never show more than 2 concurrent rustc":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let reproBin = requireBinary(reproBinaryPath(repoRoot),
      "reprobuild.apps.repro")
    let rustc = findExe("rustc")
    require findExe("cargo").len > 0 and rustc.len > 0

    let scratch = createTempDir("rqe-cg3-bounded-", "")
    defer: removeDir(scratch)
    let project = scratch / "project"
    createDir(project)
    writeProject(project)

    let log = scratch / "compiles.log"
    let wrapper = scratch / "rustc-wrapper"
    writeLoggingWrapper(wrapper, log, " --crate-name cg3_c", "$1")

    var daemon = startPrivateDaemon(repoRoot, BudgetMilli)
    defer: daemon.stop()

    let args = @[reproBin, "build", project,
      "--daemon=off", "--tool-provisioning=path",
      "--work-root=" & (scratch / "work"),
      "--action-cache-root=" & (scratch / "cache"),
      "--progress=quiet"]
    let build = runShell(shellCommand(args, env = [("RUSTC_WRAPPER", wrapper)]),
      repoRoot, timeoutMs = 1_500_000)
    checkpoint build.output
    require build.code == 0

    let measured = peakConcurrency(log)
    checkpoint "delegated edge: " & $measured
    echo "      measured, delegated cargo edge: ", measured
    check measured.started == CrateCount
    check measured.ended == CrateCount
    # The grant is the whole 2-slot budget: cargo used it (more than one at a
    # time) and stayed inside it.
    check measured.peak == 2
