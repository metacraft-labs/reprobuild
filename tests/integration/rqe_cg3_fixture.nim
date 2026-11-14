## Shared pieces of the thin-cargo-edge cases (the thin cargo edge): a small cargo project
## the standard provider delegates to cargo (it has a build script, which sends
## a project to the delegated "Mode B" edge), a logging stand-in for a
## project's own `RUSTC_WRAPPER`, and the readers of what it logged.
##
## NOTHING HERE IS A MOCK. The projects are built by real cargo and rustc. The
## logging wrapper sits in front of the real rustc, runs it unchanged and only
## records which unit it compiled: it observes the build the way a process
## monitor would and asks nothing of cargo beyond the wrapper hook it documents.

import std/[algorithm, os, osproc, strutils]

import repro_test_support

proc writeCrate(dir, name, body: string) =
  createDir(dir / "src")
  writeFile(dir / "Cargo.toml",
    "[package]\nname = \"" & name & "\"\nversion = \"0.1.0\"\n" &
    "edition = \"2021\"\n")
  writeFile(dir / "src" / "lib.rs", body)

proc writeDelegatedCargoProject*(root: string; appSource = "") =
  ## A root package `cg3_app` with a build script (so the convention routes
  ## it to the delegated cargo edge) and three library crates it depends on:
  ## five units to compile, of which `cg3_app` is the only one nothing else
  ## depends on (a leaf).
  createDir(root / "src")
  writeFile(root / "Cargo.toml",
    "[package]\nname = \"cg3_app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "build = \"build.rs\"\n\n[workspace]\nmembers = [\"liba\", \"libb\", " &
    "\"libc\"]\n\n[dependencies]\nliba = { path = \"liba\" }\n" &
    "libb = { path = \"libb\" }\nlibc = { path = \"libc\" }\n")
  writeFile(root / "build.rs",
    "fn main() { println!(\"cargo:rerun-if-changed=build.rs\"); }\n")
  for name in ["liba", "libb", "libc"]:
    writeCrate(root / name, name, "pub fn id() -> &'static str { \"" & name &
      "\" }\n")
  writeFile(root / "src" / "main.rs",
    if appSource.len > 0: appSource
    else: "fn main() { println!(\"{} {} {}\", liba::id(), libb::id(), " &
      "libc::id()); }\n")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n\npackage cg3_app:\n  uses:\n" &
    "    \"rust >=1.80 <2.0\"\n    \"cargo >=1.80 <2.0\"\n\n" &
    "  executable cg3_app:\n    discard\n")
  let lock = execCmdEx("cargo generate-lockfile --offline",
    workingDir = root)
  if lock.exitCode != 0:
    raise newException(OSError, "cargo generate-lockfile failed: " &
      lock.output)

const
  UnitSeparator = "\x1f"

proc writeUnitLogger*(path: string) =
  ## A POSIX shell `RUSTC_WRAPPER` that records, to the file the environment
  ## variable `CARGO_EDGE_UNIT_LOG` names, for every compile of a unit,
  ## `<crate name><TAB><each argument followed by a unit separator>` and then
  ## runs `"$@"` (rustc, with the arguments cargo gave) unchanged. A call that
  ## is not a unit (a `-vV` or `--print` probe) is passed through unrecorded.
  ## Because it records what it was handed, it is also the oracle for "the
  ## compiler received the arguments cargo meant it to".
  let script = "#!/bin/sh\n" &
    "case \" $* \" in\n" &
    "  *\" --crate-name ___ \"*|*\" --print\"*|*\" -vV \"*) exec \"$@\" ;;\n" &
    "  *\" --crate-name \"*) ;;\n" &
    "  *) exec \"$@\" ;;\n" &
    "esac\n" &
    "crate=\n" &
    "prev=\n" &
    "for a in \"$@\"; do\n" &
    "  if [ \"$prev\" = --crate-name ]; then crate=$a; fi\n" &
    "  prev=$a\n" &
    "done\n" &
    "line=\n" &
    "for a in \"$@\"; do line=\"$line$a" & UnitSeparator & "\"; done\n" &
    "printf '%s\\t%s\\n' \"$crate\" \"$line\" >> \"${CARGO_EDGE_UNIT_LOG:?}\"\n" &
    "exec \"$@\"\n"
  writeFile(path, script)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

type UnitCompile* = object
  crate*: string
  args*: string

proc readUnitLog*(logPath: string): seq[UnitCompile] =
  ## The compiles in the log, ordered by crate name and then arguments, so
  ## that the order cargo scheduled them in does not matter.
  if fileExists(logPath):
    for line in readFile(logPath).splitLines:
      if line.len == 0: continue
      let tab = line.find('\t')
      if tab < 0:
        raise newException(ValueError, "malformed unit log line: " & line)
      result.add UnitCompile(crate: line[0 ..< tab], args: line[tab + 1 .. ^1])
  result.sort(proc (a, b: UnitCompile): int =
    if a.crate != b.crate: cmp(a.crate, b.crate) else: cmp(a.args, b.args))

proc crates*(units: seq[UnitCompile]): seq[string] =
  for unit in units: result.add unit.crate
  result.sort()
