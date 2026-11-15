## `cargo nextest run` gets its thread count from the grant.
##
## THE DEFECT. nextest runs one process per test, as many at once as it has
## test threads, and its default is the CPU count. An edge that runs it as one
## ordinary one-slot action was admitted as one slot and then ran every core's
## worth of tests (the "Not sized yet" gap of the sized-tool table).
##
## THE CONTRACT. The standard library's typed nextest call
## (`cargo_nextest.nextest(run = true, ...)`) records a width range and names
## `--test-threads` as the flag that takes the grant; the engine writes the
## granted width after it at launch.
##
## HOW IT IS OBSERVED. A real `repro build` of a recipe whose edge is the typed
## call, over a crate with eight tests that each hold for 0.4 s and log when
## they start and end, under a real `runquotad` whose whole budget is two slots:
## the peak number of tests that ran at once is exactly 2. The falsifying
## control is the same nextest command recorded as an inline command: the
## one-slot default with no width flag, so nextest uses its own default (the
## CPU count) and its peak is above 2. The same result was obtained by making
## `sizedWidthFor` return nothing for nextest.
##
## NO MOCKS: real repro, real runquotad, real cargo, rustc and nextest.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support
import rqe_m15_width_fixture

const
  TestCount = 8
  BudgetMilli = 2000

proc writeCrate(root: string) =
  createDir(root / "src")
  writeFile(root / "Cargo.toml",
    "[package]\nname = \"nxt\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
  var source = "use std::io::Write;\n" &
    "fn mark(kind: &str) {\n" &
    "    let ns = std::time::SystemTime::now()\n" &
    "        .duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();\n" &
    "    let path = std::env::var(\"NXT_LOG\").unwrap();\n" &
    "    let mut f = std::fs::OpenOptions::new().append(true).create(true)\n" &
    "        .open(path).unwrap();\n" &
    "    // One write of the whole line: with O_APPEND a single write is atomic,\n" &
    "    // and tests running side by side must not interleave their lines.\n" &
    "    let line = format!(\"{} {} {}\\n\", kind, std::process::id(), ns);\n" &
    "    f.write_all(line.as_bytes()).unwrap();\n" &
    "}\n" &
    "fn hold() {\n" &
    "    mark(\"S\");\n" &
    "    std::thread::sleep(std::time::Duration::from_millis(400));\n" &
    "    mark(\"E\");\n" &
    "}\n\n#[cfg(test)]\nmod tests {\n"
  for i in 0 ..< TestCount:
    source.add "    #[test]\n    fn t" & $i & "() { super::hold(); }\n"
  source.add "}\n"
  writeFile(root / "src" / "lib.rs", source)

suite "a sized nextest edge runs as many tests as it is granted":

  test "test_rqe_cg3_nextest_threads_follow_grant: eight tests under a " &
      "2-slot host budget never show more than 2 running at once":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let reproBin = requireBinary(reproBinaryPath(repoRoot),
      "reprobuild.apps.repro")
    let cargo = findExe("cargo")
    let nextest = findExe("cargo-nextest")
    require cargo.len > 0 and findExe("rustc").len > 0 and
      findExe("gcc").len > 0 and nextest.len > 0

    let scratch = createTempDir("rqe-cg3-nextest-", "")
    defer: removeDir(scratch)
    let project = scratch / "recipe"
    createDir(project)
    writeCrate(project)

    let sizedLog = scratch / "sized.log"
    let controlLog = scratch / "control.log"
    let manifest = project / "Cargo.toml"
    writeFile(project / "repro.nim", """
import repro_project_dsl

package cg3_nextest:
  defaultToolProvisioning "path"

  uses:
    "cargo"
    "cargo-nextest"
    "rustc"
    "gcc"

  build:
    let sized = cargo_nextest.nextest(
      actionId = "cg3.nextest.sized",
      run = true,
      noFailFast = true,
      manifestPath = "Cargo.toml",
      targetDir = "target-sized",
      cacheable = false,
      extraEnv = @[("NXT_LOG", """ & escape(sizedLog) & """)])
    # The control: the same nextest command as an inline command. It carries
    # no width flag, so it is the one-slot default.
    let control = buildAction("cg3.nextest.control",
      inlineExecCall(@[""" & escape(nextest) & """, "nextest", "run",
        "--no-fail-fast", "--manifest-path", """ & escape(manifest) &
      """, "--target-dir", "target-control"]),
      deps = @["cg3.nextest.sized"],
      env = @[("NXT_LOG", """ & escape(controlLog) & """)],
      cacheable = false)
    discard collect("default", @[sized, control])
""")

    var daemon = startPrivateDaemon(repoRoot, BudgetMilli)
    defer: daemon.stop()

    let args = @[reproBin, "build", project,
      "--daemon=off", "--tool-provisioning=path",
      "--work-root=" & (scratch / "work"),
      "--action-cache-root=" & (scratch / "cache"),
      "--progress=quiet"]
    let build = runShell(shellCommand(args), repoRoot, timeoutMs = 1_500_000)
    checkpoint build.output
    require build.code == 0

    let sized = peakConcurrency(sizedLog)
    checkpoint "sized edge: " & $sized
    echo "      measured, sized nextest edge: ", sized
    check sized.started == TestCount
    check sized.ended == TestCount
    # The grant is the whole 2-slot budget: nextest used it (more than one at
    # a time) and stayed inside it.
    check sized.peak == 2

    let control = peakConcurrency(controlLog)
    checkpoint "control edge: " & $control
    echo "      measured, control nextest edge: ", control
    check control.started == TestCount
    # Falsifying control: with no width flag nextest is not bounded by the
    # 2-slot budget.
    check control.peak > 2
