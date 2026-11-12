## Target-directory janitor (`repro_cargo_gc`), against REAL cargo and rustc
## building small path-dependency workspaces in temporary directories. No mocks:
## every assertion is about files cargo itself wrote and about what cargo says
## on the next build. cargo is run `--offline`; nothing needs the network.
##
## The four `test_rqe_cg2_*` cases are the core verification list. Each
## carries the mutation that must make it fail; each mutation was applied once
## to the implementation, the case observed to fail, and the mutation reverted.
##
## Toolchain bump. Only one rustc is guaranteed on PATH, so a "toolchain
## upgrade" is simulated at the one place cargo observes a toolchain: `rustc
## -vV`. A tiny wrapper (RUSTC=<wrapper>) forwards to the real rustc and
## appends `-bumped` to the `release:` line of `-vV`. Cargo then derives a
## different rustc fingerprint and different unit hashes, exactly as for a
## real upgrade. (On Windows, where a shell wrapper is not available, the bump
## is a RUSTFLAGS change instead: different hashes, same fingerprint
## machinery; the toolchain-orphan rule is then exercised less precisely.)

import std/[algorithm, json, os, osproc, sequtils, strutils, tables, tempfiles,
            unittest]
import repro_cargo_gc
import repro_core/file_lock

# ---------------------------------------------------------------------------
# Fixture: a workspace of a library `<lib>` (feature `extra`, version bumped
# per round so every round yields new unit hashes) and a binary `app` with a
# build script that depends on it.
# ---------------------------------------------------------------------------

type Fixture = object
  root: string ## temp root holding ws/, target/ and cargo-home/
  ws: string
  target: string
  lib: string  ## current library crate name

proc newFixture(): Fixture =
  doAssert findExe("cargo").len > 0 and findExe("rustc").len > 0,
    "this test needs cargo and rustc on PATH (nix develop provides them)"
  result.root = createTempDir("rqe_cg2_", "")
  result.ws = result.root / "ws"
  result.target = result.root / "target"
  result.lib = "c1"
  createDir(result.ws)

proc writeIfChanged(path, content: string) =
  ## Cargo treats a source file newer than its fingerprint as modified, so a
  ## fixture that is rewritten with the same bytes must keep its mtime.
  if not fileExists(path) or readFile(path) != content:
    writeFile(path, content)

proc writeWorkspace(fx: Fixture; version: int) =
  let ws = fx.ws
  createDir(ws / "app" / "src")
  writeIfChanged(ws / "Cargo.toml",
    "[workspace]\nmembers = [\"" & fx.lib & "\", \"app\"]\nresolver = \"2\"\n")
  createDir(ws / fx.lib / "src")
  writeIfChanged(ws / fx.lib / "Cargo.toml",
    "[package]\nname = \"" & fx.lib & "\"\nversion = \"0.1." & $version &
    "\"\nedition = \"2021\"\n[features]\nextra = []\n")
  writeIfChanged(ws / fx.lib / "src" / "lib.rs",
    "pub fn f() -> u32 { if cfg!(feature = \"extra\") { 2 } else { 1 } }\n")
  writeIfChanged(ws / "app" / "Cargo.toml",
    "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" &
    "build = \"build.rs\"\n[dependencies]\n" & fx.lib & " = { path = \"../" &
    fx.lib & "\" }\n")
  writeIfChanged(ws / "app" / "src" / "main.rs",
    "fn main() { println!(\"{}\", " & fx.lib & "::f()); }\n")
  writeIfChanged(ws / "app" / "build.rs",
    "fn main() { println!(\"cargo:rerun-if-changed=build.rs\"); }\n")

proc renameLib(fx: var Fixture; newName: string; version: int) =
  removeDir(fx.ws / fx.lib)
  fx.lib = newName
  writeWorkspace(fx, version)

type Toolchain = enum tcA, tcB

proc bumpedRustc(dir: string): string =
  ## A `rustc` that reports a different `-vV` release and otherwise forwards.
  let real = findExe("rustc")
  when defined(windows):
    result = real
  else:
    result = dir / "rustc-bumped"
    writeFile(result,
      "#!/bin/sh\nreal=" & quoteShell(real) & "\n" &
      "if [ \"$1\" = \"-vV\" ]; then \"$real\" -vV | sed 's/^release: .*/&-bumped/'\n" &
      "else exec \"$real\" \"$@\"; fi\n")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc cargoJson(fx: Fixture; args: seq[string]; tc = tcA;
               targetDir = ""): seq[string] =
  ## Run cargo with `--message-format=json` and return its stdout lines.
  let target = if targetDir.len > 0: targetDir else: fx.target
  let saved = (getEnv("CARGO_TARGET_DIR"), getEnv("CARGO_HOME"),
               getEnv("RUSTC"), getEnv("RUSTFLAGS"))
  putEnv("CARGO_TARGET_DIR", target)
  putEnv("CARGO_HOME", fx.root / "cargo-home")
  delEnv("RUSTFLAGS"); delEnv("CARGO_ENCODED_RUSTFLAGS"); delEnv("RUSTC")
  if tc == tcB:
    when defined(windows):
      putEnv("RUSTFLAGS", "-C codegen-units=7")
    else:
      putEnv("RUSTC", bumpedRustc(fx.root))
  try:
    let (output, code) = execCmdEx("cargo " & args.map(quoteShell).join(" ") &
      " --offline --quiet --message-format=json", workingDir = fx.ws)
    doAssert code == 0, "cargo failed: " & output
    result = output.splitLines.filterIt(it.len > 0)
  finally:
    putEnv("CARGO_TARGET_DIR", saved[0]); putEnv("CARGO_HOME", saved[1])
    putEnv("RUSTC", saved[2]); putEnv("RUSTFLAGS", saved[3])
    for (name, value) in [("CARGO_TARGET_DIR", saved[0]),
        ("CARGO_HOME", saved[1]), ("RUSTC", saved[2]), ("RUSTFLAGS", saved[3])]:
      if value.len == 0: delEnv(name)

proc build(fx: Fixture; features = ""; release = false; tc = tcA;
           keep = 3; record = true): seq[string] =
  ## `cargo build` and record its live set, as the wrapper in front of cargo
  ## would.
  var args = @["build"]
  if features.len > 0: args.add ["--features", fx.lib & "/" & features]
  if release: args.add "--release"
  result = cargoJson(fx, args, tc)
  if record:
    let report = recordLiveSet(fx.target, result, keep)
    doAssert report.units > 0, "the stream named no unit under the target dir"

proc freshFlags(lines: seq[string]): seq[bool] =
  ## `fresh` of every compiler-artifact message.
  for line in lines:
    if line.startsWith("{"):
      let node = parseJson(line)
      if node{"reason"}.getStr == "compiler-artifact":
        result.add node{"fresh"}.getBool

proc gcConfig(keep: int; minAgeSeconds = 0'i64; dry = false): GcConfig =
  GcConfig(keepSets: keep, minAgeSeconds: minAgeSeconds, dryRun: dry)

proc names(dir: string): seq[string] =
  if not dirExists(dir): return
  for kind, path in walkDir(dir): result.add path.extractFilename
  result.sort()

proc anyStartsWith(dir, prefix: string): bool =
  names(dir).anyIt(it.startsWith(prefix))

proc listing(root: string): seq[string] =
  ## Every path under `root` with its size, for before/after comparisons.
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir, pcLinkToFile},
                         relative = true):
    let abs = root / path
    result.add path & (if fileExists(abs): ":" & $getFileSize(abs) else: "/")
  result.sort()

# ---------------------------------------------------------------------------
# The four verification cases
# ---------------------------------------------------------------------------

suite "cargo target-dir janitor":
  test "test_rqe_cg2_renamed_crate_units_removed":
    ## Build, rename a crate, build, gc: no output of the old name remains and
    ## the renamed crate is intact.
    ## Falsifying mutation (applied once): keep every unit younger than T
    ## with T larger than this test's duration (gc.nim: `age >=
    ## config.minAgeSeconds` -> `age >= max(config.minAgeSeconds, 3600)`).
    ## The old crate's units then survive and the first `check` fails.
    var fx = newFixture()
    defer: removeDir(fx.root)
    writeWorkspace(fx, 1)
    discard fx.build()
    let debug = fx.target / "debug"
    check anyStartsWith(debug / "deps", "libc1-")
    check anyStartsWith(debug / ".fingerprint", "c1-")
    check anyStartsWith(debug / "incremental", "c1-")
    fx.renameLib("c1renamed", 1)
    discard fx.build(keep = 1)
    let report = collectGarbage(fx.target, gcConfig(keep = 1))
    check report.errors.len == 0
    check report.unitsDeleted > 0
    check not anyStartsWith(debug / "deps", "libc1-")
    check not anyStartsWith(debug / "deps", "c1-")
    check not anyStartsWith(debug / ".fingerprint", "c1-")
    check not anyStartsWith(debug / "incremental", "c1-")
    check not fileExists(debug / "libc1.rlib")
    check not fileExists(debug / "libc1.d")
    check anyStartsWith(debug / "deps", "libc1renamed-")
    check anyStartsWith(debug / ".fingerprint", "c1renamed-")
    check anyStartsWith(debug / "incremental", "c1renamed-")
    check fileExists(debug / "libc1renamed.rlib")
    check fileExists(debug / "app")
    # intact means usable: cargo finds everything fresh.
    let again = cargoJson(fx, @["build"])
    check freshFlags(again).len >= 3
    check freshFlags(again).allIt(it)

  test "test_rqe_cg2_target_bounded_by_live_set":
    ## Ten rounds of feature, profile, toolchain and version churn, then gc:
    ## du(target) <= 1.5 x the bytes of the last K live sets (kept per profile
    ## directory). The oracle for "the last K live sets" is independent of the
    ## janitor: a pristine target directory in which only those builds were run.
    ## Falsifying mutation (applied once): prune only by toolchain, i.e. skip
    ## the live-set rule in gc.nim (`if hash notin live` never deletes unless
    ## orphaned). Feature/profile/version churn units then stay and the bound
    ## fails.
    const rounds = 10
    const keep = 3
    var fx = newFixture()
    defer: removeDir(fx.root)
    proc roundBuild(fx: Fixture; i: int; target: string): seq[string] =
      let features = if i mod 2 == 1: "extra" else: ""
      let release = i mod 4 == 2 # release in rounds 2 and 6
      let tc = if i >= 8: tcB else: tcA # the toolchain is bumped for 8 and 9
      var args = @["build"]
      if features.len > 0: args.add ["--features", fx.lib & "/" & features]
      if release: args.add "--release"
      cargoJson(fx, args, tc, target)
    for i in 0 ..< rounds:
      writeWorkspace(fx, i) # a new library version: new unit hashes
      let lines = roundBuild(fx, i, fx.target)
      check recordLiveSet(fx.target, lines, keep).units > 0
    let churned = treeBytes(fx.target)
    # Oracle: a pristine target dir in which only the builds the design
    # retains were ever run: per profile directory (dev, release), its last
    # `keep` rounds.
    let refTarget = fx.root / "target-reference"
    var retained: seq[int]
    for isRelease in [false, true]:
      let own = toSeq(0 ..< rounds).filterIt((it mod 4 == 2) == isRelease)
      retained.add own[max(0, own.len - keep) .. ^1]
    retained.sort()
    for i in retained:
      writeWorkspace(fx, i)
      discard roundBuild(fx, i, refTarget)
    let liveBytes = treeBytes(refTarget)
    check churned > liveBytes * 3 div 2 # the churn really accumulated
    let report = collectGarbage(fx.target, gcConfig(keep = keep))
    check report.errors.len == 0
    let after = treeBytes(fx.target)
    echo "      bytes: churned=", churned, " live-set oracle=", liveBytes,
      " after gc=", after, " (bound 1.5x = ", liveBytes * 3 div 2, ")"
    check after * 2 <= liveBytes * 3
    check after < churned

  test "test_rqe_cg2_spares_foreign_trees":
    ## target/test-logs, target/nextest, a rust-analyzer style
    ## target/flycheck0 (a complete nested cargo layout) and an unknown file in
    ## a profile directory survive a gc that does delete stale units.
    ## Falsifying mutation (applied once): after the sweep also delete every
    ## top-level name of the target directory that is not a recorded profile
    ## directory or the janitor's own store ("delete every unknown name").
    var fx = newFixture()
    defer: removeDir(fx.root)
    writeWorkspace(fx, 1)
    discard fx.build(keep = 1)
    # A real flycheck tree, built by cargo into target/flycheck0.
    discard cargoJson(fx, @["check"], tcA, fx.target / "flycheck0")
    createDir(fx.target / "test-logs")
    writeFile(fx.target / "test-logs" / "x", "log of a test run\n")
    createDir(fx.target / "nextest" / "ci")
    writeFile(fx.target / "nextest" / "ci" / "junit.xml", "<testsuites/>\n")
    writeFile(fx.target / "debug" / "keep-me.txt", "not cargo's\n")
    let before = listing(fx.target / "flycheck0")
    check before.len > 10
    writeWorkspace(fx, 2) # new hashes: version 1 units go stale
    discard fx.build(keep = 1)
    let report = collectGarbage(fx.target, gcConfig(keep = 1))
    check report.errors.len == 0
    check report.unitsDeleted > 0 # the sweep really ran
    check fileExists(fx.target / "test-logs" / "x")
    check readFile(fx.target / "test-logs" / "x") == "log of a test run\n"
    check fileExists(fx.target / "nextest" / "ci" / "junit.xml")
    check fileExists(fx.target / "debug" / "keep-me.txt")
    check listing(fx.target / "flycheck0") == before

  test "test_rqe_cg2_next_build_is_fresh":
    ## After gc, cargo reports every live unit fresh (`"fresh":true`) for each
    ## of the last K builds' configurations.
    ## Falsifying mutation (applied once): also delete the `.fingerprint`
    ## directory of live units in gc.nim. Cargo then rebuilds them and the
    ## `fresh` assertion fails.
    var fx = newFixture()
    defer: removeDir(fx.root)
    for i in 0 ..< 4:
      writeWorkspace(fx, i)
      discard fx.build(features = (if i mod 2 == 1: "extra" else: ""),
        release = i == 2, keep = 2)
    let report = collectGarbage(fx.target, gcConfig(keep = 2))
    check report.errors.len == 0
    check report.unitsDeleted > 0
    # The last two configurations: round 3 (extra, dev) and round 2 (release).
    # Rebuild round 2's first (the workspace is at version 3 now, so put the
    # matching version back), then round 3's.
    writeWorkspace(fx, 2)
    let r2 = cargoJson(fx, @["build", "--release"])
    check freshFlags(r2).len >= 3
    check freshFlags(r2).allIt(it)
    writeWorkspace(fx, 3)
    let r3 = cargoJson(fx, @["build", "--features", "c1/extra"])
    check freshFlags(r3).len >= 3
    check freshFlags(r3).allIt(it)
    # build scripts replayed from cache too
    check r3.anyIt(it.contains("build-script-executed"))

# ---------------------------------------------------------------------------
# Further behaviour the design depends on
# ---------------------------------------------------------------------------

suite "cargo target-dir janitor mechanics":
  test "units younger than the minimum age survive; an orphaned toolchain does not wait":
    var fx = newFixture()
    defer: removeDir(fx.root)
    let thirtyDays = 30 * 24 * 3600'i64
    writeWorkspace(fx, 1)
    discard fx.build(keep = 1)
    writeWorkspace(fx, 2)
    discard fx.build(keep = 1)
    # version 1's units are outside the live set but younger than T.
    let young = collectGarbage(fx.target, gcConfig(keep = 1, thirtyDays))
    check young.deletions.len == 0
    # A different toolchain builds version 3; the toolchain that built
    # versions 1 and 2 is in no retained live set, so they go at once.
    writeWorkspace(fx, 3)
    discard fx.build(tc = tcB, keep = 1)
    let orphans = collectGarbage(fx.target, gcConfig(keep = 1, thirtyDays))
    when not defined(windows):
      check orphans.unitsDeleted >= 4
      check orphans.deletions.anyIt(it.reason == drOrphanedToolchain)
    let again = cargoJson(fx, @["build"], tcB)
    check freshFlags(again).allIt(it)

  test "a dry run lists byte counts and deletes nothing":
    var fx = newFixture()
    defer: removeDir(fx.root)
    writeWorkspace(fx, 1)
    discard fx.build(keep = 1)
    writeWorkspace(fx, 2)
    discard fx.build(keep = 1)
    let before = listing(fx.target)
    let report = collectGarbage(fx.target, gcConfig(1, 0, dry = true))
    check report.deletions.len > 0
    check report.bytesFreed > 0
    check listing(fx.target) == before
    check "would delete" in renderReport(report)

  test "gc refuses while a build holds cargo's lock":
    var fx = newFixture()
    defer: removeDir(fx.root)
    writeWorkspace(fx, 1)
    discard fx.build(keep = 1)
    writeWorkspace(fx, 2)
    discard fx.build(keep = 1)
    var held: ReproFileLock
    doAssert tryAcquireExclusiveFileLock(fx.target / "debug" / ".cargo-lock", held)
    let before = listing(fx.target)
    expect GcBusyError:
      discard collectGarbage(fx.target, gcConfig(keep = 1))
    check listing(fx.target) == before
    releaseExclusiveFileLock(held)
    check collectGarbage(fx.target, gcConfig(keep = 1)).unitsDeleted > 0

  test "a deps/ symlink leading out of the target directory is never deleted through":
    ## Falsifying mutation: drop the resolved-parent check in
    ## `gc.deletePath`; the outside files then disappear.
    when not defined(windows):
      var fx = newFixture()
      defer: removeDir(fx.root)
      writeWorkspace(fx, 1)
      discard fx.build(keep = 1)
      writeWorkspace(fx, 2)
      discard fx.build(keep = 1)
      let outside = fx.root / "outside"
      createDir(outside)
      moveDir(fx.target / "debug" / "deps", outside / "deps")
      createSymlink(outside / "deps", fx.target / "debug" / "deps")
      let before = listing(outside)
      let report = collectGarbage(fx.target, gcConfig(keep = 1))
      check report.errors.anyIt("symlink" in it)
      check listing(outside) == before

  test "a target directory with no recorded live set is left alone":
    var fx = newFixture()
    defer: removeDir(fx.root)
    writeWorkspace(fx, 1)
    discard fx.build(record = false)
    let before = listing(fx.target)
    let report = collectGarbage(fx.target, gcConfig(keep = 1))
    check report.deletions.len == 0
    check report.skippedProfileDirs.len > 0
    check listing(fx.target) == before

  test "the recorded set names the binary unit, resolved through its hard link":
    var fx = newFixture()
    defer: removeDir(fx.root)
    writeWorkspace(fx, 1)
    let lines = fx.build()
    var problems: seq[string]
    let sets = loadLiveSets(fx.target, problems)
    check problems.len == 0
    check sets.len == 1
    let kinds = sets[0].units.mapIt($it.kind)
    check "build-script" in kinds and "build-script-run" in kinds
    check sets[0].units.anyIt(it.targetName == "app" and it.targetKind == "bin")
    check sets[0].units.allIt(it.profileDir == "debug" and
      it.rustcFingerprint.len > 0)
    check lines.len > 3

  test "a damaged live-set record stops the sweep":
    var fx = newFixture()
    defer: removeDir(fx.root)
    writeWorkspace(fx, 1)
    discard fx.build()
    writeFile(liveSetsDir(fx.target) / "00000000000000000000-damaged.toml",
      "this is = not [valid\n")
    expect GcSetupError:
      discard collectGarbage(fx.target, gcConfig(keep = 1))

  test "only the last keep-sets records are stored":
    var fx = newFixture()
    defer: removeDir(fx.root)
    for i in 0 ..< 5:
      writeWorkspace(fx, i)
      discard fx.build(keep = 2)
    var problems: seq[string]
    check loadLiveSets(fx.target, problems).len == 2

suite "cargo target-dir configuration":
  test "durations":
    check parseDuration("0") == (true, 0'i64)
    check parseDuration("14d") == (true, 14 * 86400'i64)
    check parseDuration("36h") == (true, 36 * 3600'i64)
    check parseDuration("90m") == (true, 5400'i64)
    check parseDuration("2w") == (true, 14 * 86400'i64)
    check not parseDuration("14").ok
    check not parseDuration("-1d").ok
    check not parseDuration("d").ok

  test "defaults, then user config, then environment, then flag":
    let dir = createTempDir("rqe_cg2_cfg_", "")
    defer: removeDir(dir)
    createDir(dir / "reprobuild")
    writeFile(dir / "reprobuild" / "config.toml",
      "[cargo_gc]\nkeep_sets = 5\nmin_age = \"2d\"\n")
    var env = initTable[string, string]()
    env["XDG_CONFIG_HOME"] = dir
    let reader = proc (name: string): string = env.getOrDefault(name)
    var r = resolveGcConfig(reader)
    check r.config.keepSets == 5 and r.keepSource == csUserConfig
    check r.config.minAgeSeconds == 2 * 86400 and r.minAgeSource == csUserConfig
    env["REPRO_CARGO_GC_KEEP_SETS"] = "7"
    env["REPRO_CARGO_GC_MIN_AGE"] = "1h"
    r = resolveGcConfig(reader)
    check r.config.keepSets == 7 and r.keepSource == csEnvironment
    check r.config.minAgeSeconds == 3600
    r = resolveGcConfig(reader, "9", "0")
    check r.config.keepSets == 9 and r.keepSource == csFlag
    check r.config.minAgeSeconds == 0 and r.minAgeSource == csFlag
    # a bad value is reported and the next layer used
    r = resolveGcConfig(reader, "zero", "soon")
    check r.config.keepSets == 7 and r.config.minAgeSeconds == 3600
    check r.problems.len == 2
    env.clear()
    r = resolveGcConfig(reader)
    check r.config.keepSets == DefaultKeepSets
    check r.config.minAgeSeconds == DefaultMinAgeSeconds
    check DefaultKeepSets == 3 and DefaultMinAgeSeconds == 14 * 86400
