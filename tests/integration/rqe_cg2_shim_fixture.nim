## Shared pieces of the cargo-shim cases (`t_rqe_cg2_shim_*`): a small cargo
## project, the shim installed under the name `cargo` in a directory of its
## own, and the readers of what the shim recorded.
##
## NOTHING HERE IS A MOCK. The projects are built by real cargo and rustc, the
## shim is the real `repro-cargo-shim` binary, and every expectation about what
## cargo prints is obtained by running the same argv through bare cargo. The
## only oracle that is not a second cargo run is the directory listing of
## `<target>/debug/.fingerprint`, which for a target directory that only ever
## ran the builds under test is exactly the set of live units, and which
## does not go through the recorder, the JSON stream or the shim.

import std/[algorithm, os, sequtils, strutils, tempfiles]

import repro_test_support
import repro_cargo_gc

const
  OkSource* = "use std::io::IsTerminal;\n" &
    "fn main() {\n" &
    "    let unused_value = 1; // a warning, so stderr carries a diagnostic\n" &
    "    println!(\"{}\", chain_a::id());\n" &
    "    println!(\"tty={}\", std::io::stdout().is_terminal());\n" &
    "}\n" &
    "#[cfg(test)]\nmod tests {\n" &
    "    use std::io::IsTerminal;\n" &
    "    #[test]\n    fn prints() {\n" &
    "        println!(\"stdout from the test\");\n" &
    "        eprintln!(\"stderr from the test\");\n    }\n" &
    "    #[test]\n    fn terminal() {\n" &
    "        println!(\"test-tty={}\", std::io::stdout().is_terminal());\n    }\n}\n"
    ## A binary that says whether its standard output is a terminal, and two
    ## unit tests that print to both streams and say the same.
  WarnSource* = "fn main() {\n    let unused_variable = 1;\n" &
    "    println!(\"{}\", chain_a::id());\n}\n"
  FailSource* = "fn main() {\n    let broken: u32 = \"not a number\";\n" &
    "    println!(\"{} {}\", chain_a::id(), broken);\n}\n"

type
  ShimRig* = object
    root*: string      ## scratch root, removed by the case
    project*: string
    target*: string
    shimDir*: string   ## holds `cargo`, a symlink to the shim
    shim*: string      ## `<shimDir>/cargo`
    realCargo*: string
    cargoHome*: string

proc scrubCargoEnvironment() =
  ## A developer shell's cargo placement and wrappers change what is built
  ## and printed; the cases are about the shim, not about them.
  for name in ["CARGO_TARGET_DIR", "CARGO_BUILD_TARGET_DIR",
               "CARGO_BUILD_TARGET", "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS",
               "RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER", "CARGO_BUILD_RUSTC",
               "CARGO_BUILD_RUSTC_WRAPPER", "CARGO_BUILD_JOBS",
               "CARGO_INCREMENTAL", "CARGO_TERM_COLOR", "CARGO_TERM_VERBOSE",
               "CARGO_TERM_QUIET", "CARGO_TERM_PROGRESS_WHEN",
               "RUSTUP_TOOLCHAIN", "REPRO_CARGO_RECORD", "REPRO_CARGO_REAL",
               "REPRO_CARGO_SHIM_ACTIVE", "REPRO_CARGO_GC_KEEP_SETS",
               "REPRO_CARGO_GC_MIN_AGE", "NO_COLOR", "CLICOLOR_FORCE"]:
    delEnv(name)

proc writeChainProject(root, appSource: string) =
  ## A package `cg2_app` with a build script and three libraries in a CHAIN
  ## (`cg2_app` -> `chain_a` -> `chain_b` -> `chain_c`; the build script uses
  ## `chain_a` too). A chain gives cargo no choice of order, so even with
  ## `--jobs 1` the progress lines and the JSON messages of two runs come out
  ## in the same order: independent crates would be compiled in an order that
  ## differs from run to run of bare cargo itself, and comparing the shim
  ## against that would need normalisation.
  createDir(root / "src")
  writeFile(root / "Cargo.toml",
    "[package]\nname = \"cg2_app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "build = \"build.rs\"\n\n[dependencies]\nchain_a = { path = \"chain_a\" }\n\n" &
    "[build-dependencies]\nchain_a = { path = \"chain_a\" }\n")
  writeFile(root / "build.rs",
    "fn main() { let _ = chain_a::id(); " &
    "println!(\"cargo:rerun-if-changed=build.rs\"); }\n")
  writeFile(root / "src" / "main.rs", appSource)
  for (name, dep) in [("chain_a", "chain_b"), ("chain_b", "chain_c"),
                      ("chain_c", "")]:
    createDir(root / name / "src")
    writeFile(root / name / "Cargo.toml",
      "[package]\nname = \"" & name & "\"\nversion = \"0.1.0\"\n" &
      "edition = \"2021\"\n\n[features]\nextra = []\n" &
      (if dep.len > 0: "\n[dependencies]\n" & dep & " = { path = \"../" & dep &
        "\" }\n" else: ""))
    writeFile(root / name / "src" / "lib.rs",
      if dep.len > 0:
        "pub fn id() -> String { format!(\"" & name & "<{}\", " & dep &
          "::id()) }\n"
      else:
        "pub fn id() -> String { \"" & name & "\".to_string() }\n")

proc newShimRig*(tag: string; appSource = OkSource): ShimRig =
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  let shimBinary = requireBinary(
    reproBinaryPath(repoRoot, "repro-cargo-shim"),
    "reprobuild.apps.repro-cargo-shim")
  result.realCargo = findExe("cargo")
  doAssert result.realCargo.len > 0 and findExe("rustc").len > 0,
    "this case needs cargo and rustc on PATH (the dev shell provides them)"
  scrubCargoEnvironment()
  result.root = createTempDir("rqe-cg2-shim-" & tag & "-", "")
  result.project = result.root / "project"
  createDir(result.project)
  writeChainProject(result.project, appSource)
  result.target = result.root / "project" / "target"
  result.cargoHome = result.root / "cargo-home"
  result.shimDir = result.root / "shim-bin"
  createDir(result.shimDir)
  result.shim = result.shimDir / "cargo"
  createSymlink(shimBinary, result.shim)
  # Cargo prints `Locking N packages` on the run that creates Cargo.lock, so
  # whichever of two compared runs came first would differ from the other for
  # that reason alone: create the lock file once, up front, with real cargo.
  let lock = runShell(shellCommand(@[result.realCargo, "generate-lockfile",
    "--offline"], [("CARGO_HOME", result.cargoHome)]), result.project)
  doAssert lock.code == 0, lock.output

proc cleanup*(rig: ShimRig) =
  removeDirEventually(rig.root)

proc cargoEnv*(rig: ShimRig; extra: openArray[tuple[name, value: string]] = []):
    seq[tuple[name, value: string]] =
  result = @[("CARGO_HOME", rig.cargoHome), ("CARGO_TARGET_DIR", rig.target),
             ("REPRO_CARGO_REAL", rig.realCargo)]
  for e in extra: result.add e

proc runCargo*(rig: ShimRig; viaShim: bool; args: seq[string];
               extra: openArray[tuple[name, value: string]] = [];
               cwd = ""): CmdSplitResult =
  ## One cargo run with standard output and standard error kept apart; through
  ## the shim, or bare cargo. Same environment and working directory.
  let program = if viaShim: rig.shim else: rig.realCargo
  runShellSplit(shellCommand(@[program] & args, rig.cargoEnv(extra)),
    if cwd.len > 0: cwd else: rig.project, timeoutMs = 1_500_000)

proc freshTarget*(rig: ShimRig) =
  ## Both runs of a comparison start from an empty target directory.
  removeDir(rig.target)

proc normalizeTimings*(text: string): string =
  ## The one thing that differs between two runs of the same command: the
  ## elapsed time cargo and libtest print (`Finished ... in 0.48s`,
  ## `finished in 0.00s`). Nothing else is rewritten.
  var lines: seq[string]
  for line in text.split('\n'):
    if ("Finished `" in line or "test result:" in line) and " in " in line:
      let at = line.rfind(" in ")
      let tail = line[at + 4 .. ^1]
      if tail.len > 0 and tail.allIt(it in {'0'..'9', '.', 's', 'm', ' '}):
        lines.add line[0 ..< at] & " in <time>"
        continue
    lines.add line
  lines.join("\n")

proc liveSetFiles*(target: string): seq[string] =
  if dirExists(liveSetsDir(target)):
    for kind, path in walkDir(liveSetsDir(target)):
      if kind == pcFile: result.add path
  result.sort()

proc recordedUnits*(setFile: string): seq[string] =
  ## `<profile dir>|<hash>` of every unit one stored live set names.
  let parsed = parseLiveSet(readFile(setFile))
  for u in parsed.units: result.add u.profileDir & "|" & u.hash
  result.sort()
  result = result.deduplicate(isSorted = true)

proc fingerprintUnits*(target: string): seq[string] =
  ## The oracle: every unit the target directory's fingerprint directories
  ## know, as `<profile dir>|<hash>`.
  for profile in ["debug", "release"]:
    let dir = target / profile / ".fingerprint"
    if not dirExists(dir): continue
    for kind, path in walkDir(dir):
      if kind != pcDir: continue
      let hash = embeddedUnitHash(path.extractFilename)
      if hash.len > 0: result.add profile & "|" & hash
  result.sort()
  result = result.deduplicate(isSorted = true)

proc leftoverStreams*(target: string): seq[string] =
  ## Temporary stream files the shim must always delete.
  for dir in [liveSetsDir(target).parentDir, getTempDir()]:
    if dirExists(dir):
      for kind, path in walkDir(dir):
        if path.extractFilename.startsWith("shim-") and
            path.endsWith(".stream"):
          result.add path

proc runUnderPty*(rig: ShimRig; program: string; args: seq[string];
                  extra: openArray[tuple[name, value: string]] = []):
    CmdResult =
  ## Run `program args` with a pseudo-terminal as its standard input, output
  ## and error (python's `pty`), returning the exit status and everything it
  ## wrote to the terminal. The stand-in for a person typing the command.
  let python = findExe("python3")
  doAssert python.len > 0, "the pty cases need python3 on PATH"
  let script = rig.root / "pty_run.py"
  writeFile(script,
    "import os, pty, sys\n" &
    "pid, fd = pty.fork()\n" &
    "if pid == 0:\n" &
    "    os.execv(sys.argv[1], sys.argv[1:])\n" &
    "out = b''\n" &
    "while True:\n" &
    "    try:\n        data = os.read(fd, 65536)\n" &
    "    except OSError:\n        break\n" &
    "    if not data:\n        break\n" &
    "    out += data\n" &
    "_, status = os.waitpid(pid, 0)\n" &
    "sys.stdout.buffer.write(out)\n" &
    "sys.exit(os.waitstatus_to_exitcode(status))\n")
  runShell(shellCommand(@[python, "-I", script, program] & args,
    rig.cargoEnv(extra)), rig.project, timeoutMs = 1_500_000)
