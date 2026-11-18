## Measurement: does the store root's physical path land in the outputs of a
## registry crate compiled from a store prefix?
##
## A registry crate compiled by a rustc edge reads its sources from a prefix
## under the reprobuild store root, and rustc writes source paths into what
## it produces: panic locations, debug info, the crate metadata and the
## dep-info file. The engine's embedded-path scan (`embedded_root_scan`, run
## before a portable record is written) makes a record non-portable when an
## output names the physical path of a tracked root, the store root among
## them. Whether a rustc edge must pass `--remap-path-prefix` to stay
## shareable therefore depends on what rustc actually embeds, and this
## program measures it rather than assuming it.
##
## What it does, in order:
##
## 1. Realizes rust-lang's 1.94.0 release archive for x86_64 Linux and the
##    catalog's Linux x86_64 C toolchain into `<store root>/tool-store`
##    through the engine's own tarball realizer (`resolveTarballTool`, the
##    route `repro build --tool-provisioning=tarball` takes). The rustc
##    archive is not relocated onto a store-root C library: it runs on the
##    host's dynamic loader. Relocation rewrites only rustc's own loader and
##    run path; what rustc embeds depends on where the crate sources and the
##    rustc sysroot sit, and those are the same prefixes either way. A C
##    toolchain the realizer cannot provide is replaced by the host's `cc`,
##    and the report says which linker was used.
## 2. Downloads a fixed set of small crates.io crates (no build script, no
##    procedural macro, no dependencies), verifies each against the SHA-256
##    the crates.io index publishes for it, refuses an archive entry that is
##    absolute, climbs with `..`, or lies outside `<name>-<version>/`, and
##    extracts each into its own prefix under the store root.
## 3. Writes a positive-control crate into a store prefix as well: its
##    `pub static` holds `file!()`, so its outputs name its source path by
##    construction. If the scan does not find that path in the control's
##    rlib, the measurement is invalid and the program exits non-zero.
## 4. Compiles every crate under a dev profile (debuginfo on) and a release
##    profile, with the flags cargo passes for a registry dependency, then
##    links a binary that uses each one, first with no remap and then with
##    `--remap-path-prefix=<prefix>=<name>-<version>` on each crate's compile.
## 5. Runs `scanOutputForEmbeddedRoots` -- the engine's scan, which also
##    reads decompressed ELF sections and every `ar` member -- over each
##    rlib, rmeta, dep-info file and the binary, once per needle: the store
##    root (what the engine searches for), each crate's source prefix, the
##    rustc prefix (its sysroot) and the C toolchain prefix. Separate scans
##    are needed because the scan reports only its first finding, and every
##    prefix lies under the store root.
##
## It is a measurement, not a test: it needs the network (two toolchain
## archives and the crates), takes minutes, and reports numbers instead of
## asserting a property, so it is deliberately not named `t_*` and the test
## runner does not pick it up. Run it from the dev shell:
##
##   nim c -r --out:build/bin/measure_store_path_in_rust_crate_outputs \
##     libs/repro_build_engine/tests/measure_store_path_in_rust_crate_outputs.nim \
##     --store-root=<dir> --work=<dir> --report=<file.md>
##
## No mocks: the toolchains are the catalog's own pinned archives realized by
## the engine, the crates are the published ones, and the scan is the
## engine's. Network access uses `curl` with a generic User-Agent.

import std/[os, osproc, parseopt, strutils, tables, times]

import nimcrypto/[hash, sha2]

import repro_project_dsl
import repro_interface_artifacts
import repro_tool_profiles
import repro_tool_profiles/tarball_conformance
# Imported for its effect: it registers every catalog package with a tarball
# arm, `rustc` and `gcc` among them, so `registeredPackages` finds them.
import repro_dsl_stdlib/catalog_tarball_packages
import repro_core/ambient_execution
import repro_build_engine/embedded_root_scan

const
  RustArchiveName = "rust-1.94.0-x86_64-unknown-linux-gnu.tar.xz"
    ## The rustc arm measured: the stdlib's default Linux x86_64 release.
  UserAgent = "reprobuild-research"
  CratesIoDownload = "https://static.crates.io/crates/"

type
  CratePin = object
    ## One crates.io crate, pinned by the SHA-256 the crates.io index states
    ## for it (`cksum`, read from https://index.crates.io), with the cfgs of
    ## its default features, as cargo would pass them.
    name, version, sha256: string
    features: seq[string]

  Crate = object
    pin: CratePin
    prefix: string        ## the store prefix holding the crate's sources
    libRoot: string       ## its library root file, inside `prefix`
    crateName: string     ## the Rust crate name (`-` becomes `_`)
    edition: string
    metadataHash: string  ## the `-C metadata` / file-name suffix

  Needle = object
    label: string
    path: string

  Row = object
    remap: bool
    profile: string
    crate: string
    output: string        ## rlib / rmeta / dep-info / binary
    findings: OrderedTable[string, string]  ## needle label -> where, or ""

const Pins = [
  CratePin(name: "fnv", version: "1.0.7",
    sha256: "3f9eec918d3f24069decb9af1554cad7c880e2da24a9afd88aca000531ab82c1",
    features: @["default", "std"]),
  CratePin(name: "itoa", version: "1.0.11",
    sha256: "49f1f14873335454500d59611f1cf4a4b0f786f9ac11f4312a78e4cf2566695b",
    features: @[]),
  CratePin(name: "hex", version: "0.4.3",
    sha256: "7f24254aa9a54b5c858eaee2f5bccdb46aaf0e486a595ed5fd8f86ba55232a70",
    features: @["alloc", "default", "std"]),
  CratePin(name: "scopeguard", version: "1.2.0",
    sha256: "94143f37725109f92c262ed2cf5e59bce7498c01bcc1502d7b9afe439a4e9f49",
    features: @["default", "use_std"]),
]

const ControlSource = """//! Positive control: the source path rustc was given is a string in the
//! crate's data, so a scan that cannot find it cannot be trusted.
pub static SOURCE: &str = file!();
"""

const AppSource = """use std::hash::Hasher;

fn main() {
    let mut h = fnv::FnvHasher::default();
    h.write(b"measure");
    let mut buf = itoa::Buffer::new();
    let n = buf.format(h.finish());
    let encoded = hex::encode(n.as_bytes());
    let guard = scopeguard::guard(encoded, |e| println!("{}", e.len()));
    println!("{} {}", *guard, pathcontrol::SOURCE);
}
"""

proc fail(msg: string) {.noreturn.} =
  raise newException(CatchableError, msg)

proc run(cmd: string; dir = ""): string =
  ## Run `cmd` through the shell, returning its output, and fail with the
  ## output when it exits non-zero.
  # The commands are this measurement's own (curl, tar, the realized rustc,
  # the built binary), run on purpose outside any execution profile.
  let res = uncontrolledExecCmdEx(cmd,
    workingDir = (if dir.len > 0: dir else: getCurrentDir()))
  if res.exitCode != 0:
    fail("`" & cmd & "` failed (exit " & $res.exitCode & "):\n" & res.output)
  res.output

proc sha256Hex(data: string): string =
  toLowerAscii($sha256.digest(data))

# --- toolchains ---------------------------------------------------------------

proc toolUseFor(packageName: string): InterfaceToolUse =
  ## The tool use a recipe declaring `uses: "<packageName>"` gets, from the
  ## registered stdlib package, so the arms are the catalog's own. The
  ## catalog module registers them; its enrolment list is non-empty by its
  ## own gate, and naming it here keeps the import from looking unused.
  doAssert CatalogTarballModules.len > 0
  let iface = toProjectInterface(PackageDef(
    packageName: "storePathMeasurement",
    nativeBuildDeps: @[PackageUseDef(rawConstraint: packageName,
      packageSelector: packageName, executableName: packageName,
      depKind: "native")]), registeredPackages())
  doAssert iface.toolUses.len == 1
  iface.toolUses[0]

proc realizeArm(packageName: string; toolStore: string;
                pick: proc (arm: InterfaceTarballProvisioning): bool):
    tuple[prefix, executable: string] =
  ## Realize exactly the one arm `pick` selects, through the engine's tarball
  ## realizer, and return its prefix and executable.
  var use = toolUseFor(packageName)
  var chosen: seq[InterfaceTarballProvisioning] = @[]
  for arm in use.tarballProvisioning:
    if armMatchesTarget(arm, "linux", "x86_64") and pick(arm):
      chosen.add(arm)
  if chosen.len == 0:
    fail("the catalog's " & packageName & " package has no matching Linux x86_64 arm")
  use.tarballProvisioning = @[chosen[0]]
  let profile = resolveTarballTool(use, toolStore)
  (profile.selectedStorePath, profile.resolvedExecutablePath)

# --- crates -------------------------------------------------------------------

proc tomlValue(manifest, section, key: string): string =
  ## The string value of `key` in `[section]` of a normalized Cargo.toml (as
  ## crates.io serves it: one `key = "value"` per line). Empty when absent.
  var inSection = false
  for raw in manifest.splitLines():
    let line = raw.strip()
    if line.startsWith("["):
      inSection = line == "[" & section & "]"
      continue
    if inSection and line.startsWith(key):
      let rest = line[key.len .. ^1].strip()
      if rest.startsWith("="):
        return rest[1 .. ^1].strip().strip(chars = {'"'})
  ""

proc describeCrate(pin: CratePin; prefix: string): Crate =
  ## Read what the compile needs from the crate's own manifest, refusing a
  ## crate this measurement does not cover (a build script or a proc macro
  ## would bring compile steps the measurement does not model).
  let manifest = readFile(prefix / "Cargo.toml")
  if fileExists(prefix / "build.rs") or tomlValue(manifest, "package", "build").len > 0:
    fail(pin.name & " " & pin.version & " has a build script")
  if tomlValue(manifest, "lib", "proc-macro") == "true":
    fail(pin.name & " " & pin.version & " is a procedural macro crate")
  var libPath = tomlValue(manifest, "lib", "path")
  if libPath.len == 0: libPath = "src/lib.rs"
  var edition = tomlValue(manifest, "package", "edition")
  if edition.len == 0: edition = "2015"
  Crate(pin: pin, prefix: prefix, libRoot: prefix / libPath,
    crateName: pin.name.replace('-', '_'), edition: edition,
    metadataHash: sha256Hex(pin.name & "@" & pin.version)[0 ..< 16])

proc fetchCrate(pin: CratePin; storeRoot: string): Crate =
  ## Download `pin`, verify it against its pinned SHA-256 before anything is
  ## extracted, check every archive entry, and extract it into a store prefix
  ## named by that digest.
  let prefix = storeRoot / "crate-sources" / (pin.sha256[0 ..< 32] & "-" &
    pin.name & "-" & pin.version)
  if dirExists(prefix):
    return describeCrate(pin, prefix)
  let downloads = storeRoot / "crate-downloads"
  createDir(downloads)
  let archive = downloads / (pin.sha256 & ".crate")
  if not fileExists(archive):
    let partial = archive & ".partial"
    discard run("curl -fsSL --proto =https -A " & quoteShell(UserAgent) &
      " -o " & quoteShell(partial) & " " &
      quoteShell(CratesIoDownload & pin.name & "/" & pin.name & "-" &
        pin.version & ".crate"))
    moveFile(partial, archive)
  let digest = sha256Hex(readFile(archive))
  if digest != pin.sha256:
    removeFile(archive)
    fail(pin.name & " " & pin.version & ": downloaded SHA-256 " & digest &
      " differs from the pinned " & pin.sha256)
  let top = pin.name & "-" & pin.version
  for entry in run("tar -tzf " & quoteShell(archive)).splitLines():
    if entry.len == 0: continue
    if entry.startsWith("/") or ".." in entry.split('/') or
        not (entry == top or entry.startsWith(top & "/")):
      fail(pin.name & " " & pin.version & ": archive entry '" & entry &
        "' lies outside " & top & "/")
  let staging = prefix & ".staging"
  if dirExists(staging): removeDir(staging)
  createDir(staging)
  discard run("tar -xzf " & quoteShell(archive) & " --no-same-owner -C " &
    quoteShell(staging))
  moveDir(staging / top, prefix)
  removeDir(staging)
  describeCrate(pin, prefix)

proc writeControl(storeRoot: string): Crate =
  ## The positive-control crate, in a store prefix named by its content.
  let pin = CratePin(name: "pathcontrol", version: "0.1.0",
    sha256: sha256Hex(ControlSource))
  let prefix = storeRoot / "crate-sources" / (pin.sha256[0 ..< 32] & "-" &
    pin.name & "-" & pin.version)
  createDir(prefix / "src")
  writeFile(prefix / "src" / "lib.rs", ControlSource)
  Crate(pin: pin, prefix: prefix, libRoot: prefix / "src" / "lib.rs",
    crateName: pin.name, edition: "2021",
    metadataHash: sha256Hex(pin.name & "@" & pin.version)[0 ..< 16])

# --- compile and scan ---------------------------------------------------------

proc profileFlags(profile: string): seq[string] =
  ## What cargo passes for its built-in profiles (Cargo Book, "Profiles",
  ## https://doc.rust-lang.org/cargo/reference/profiles.html): dev is
  ## opt-level 0 with full debuginfo; release is opt-level 3 with none.
  if profile == "dev": @["-C", "debuginfo=2"]
  else: @["-C", "opt-level=3"]

proc rustcCommand(rustc: string; args: seq[string]): string =
  result = quoteShell(rustc)
  for arg in args:
    result.add(" " & quoteShell(arg))

proc compileCrate(rustc: string; crate: Crate; profile, outDir: string;
                  remap: bool): string =
  ## Compile one registry crate as cargo would for a dependency, returning
  ## the command line run.
  var args = @["--crate-name", crate.crateName, "--edition=" & crate.edition,
    crate.libRoot, "--crate-type", "lib", "--emit=dep-info,metadata,link",
    "-C", "embed-bitcode=no"] & profileFlags(profile)
  for feature in crate.pin.features:
    args.add(["--cfg", "feature=\"" & feature & "\""])
  args.add(["-C", "metadata=" & crate.metadataHash,
    "-C", "extra-filename=-" & crate.metadataHash,
    "--out-dir", outDir, "-L", "dependency=" & outDir, "--cap-lints", "allow"])
  if remap:
    args.add("--remap-path-prefix=" & crate.prefix & "=" & crate.pin.name &
      "-" & crate.pin.version)
  result = rustcCommand(rustc, args)
  discard run(result)

proc compileApp(rustc, linker: string; crates: seq[Crate]; profile, appDir,
                outDir: string): string =
  ## Link the binary that uses every crate. Its own source lies outside the
  ## store, so it is compiled without a remap in both runs.
  var args = @["--crate-name", "measure_app", "--edition=2021",
    appDir / "main.rs", "--crate-type", "bin", "--emit=dep-info,link"] &
    profileFlags(profile)
  if profile == "release":
    args.add(["-C", "strip=debuginfo"])
  args.add(["-C", "linker=" & linker, "--out-dir", outDir,
    "-L", "dependency=" & outDir])
  for crate in crates:
    args.add(["--extern", crate.crateName & "=" & outDir / ("lib" &
      crate.crateName & "-" & crate.metadataHash & ".rlib")])
  result = rustcCommand(rustc, args)
  discard run(result)

proc scanEach(path: string; needles: seq[Needle]): OrderedTable[string, string] =
  ## One engine scan per needle, so that each prefix is reported on its own
  ## (the scan stops at its first finding, and every prefix here lies under
  ## the store root). The value is where the path was found, `""` if not.
  for needle in needles:
    let finding = scanOutputForEmbeddedRoots(path,
      [EmbeddedRootNeedle(label: needle.label, path: needle.path)])
    if finding.unscannable.len > 0:
      fail(path & " cannot be scanned: " & finding.unscannable)
    result[needle.label] = (if finding.found: finding.where else: "")

proc main() =
  var storeRoot, work, report: string
  for kind, key, value in getopt():
    if kind in {cmdLongOption, cmdShortOption}:
      case key
      of "store-root": storeRoot = absolutePath(value)
      of "work": work = absolutePath(value)
      of "report": report = absolutePath(value)
      else: fail("unknown option --" & key)
  if storeRoot.len == 0 or work.len == 0:
    fail("usage: --store-root=<dir> --work=<dir> [--report=<file.md>]")
  createDir(storeRoot)
  createDir(work)
  # The scan compares bytes, so the needles must be the physical spellings.
  storeRoot = expandFilename(storeRoot)
  putEnv("REPRO_CACHE_DISABLE", "1")

  let rust = realizeArm("rustc", storeRoot / "tool-store",
    proc (arm: InterfaceTarballProvisioning): bool =
      arm.url.endsWith("/" & RustArchiveName))
  let rustc = rust.prefix / "bin" / "rustc"
  var linker = ""
  var linkerNote = ""
  var cPrefix = ""
  try:
    let gcc = realizeArm("gcc", storeRoot / "tool-store",
      proc (arm: InterfaceTarballProvisioning): bool = true)
    linker = gcc.executable
    cPrefix = gcc.prefix
    linkerNote = "store-root C toolchain driver " & linker
  except CatchableError as err:
    linker = "cc"
    linkerNote = "host cc (the store-root C toolchain did not realize: " &
      err.msg.splitLines()[0] & ")"

  var crates: seq[Crate] = @[]
  for pin in Pins:
    crates.add(fetchCrate(pin, storeRoot))
  let control = writeControl(storeRoot)
  crates.add(control)

  let appDir = work / "app"
  createDir(appDir)
  writeFile(appDir / "main.rs", AppSource)

  var needles = @[Needle(label: "store root", path: storeRoot),
    Needle(label: "rustc prefix", path: rust.prefix)]
  if cPrefix.len > 0:
    needles.add(Needle(label: "C toolchain prefix", path: cPrefix))
  var rows: seq[Row] = @[]
  var commands: seq[string] = @[]
  var appOutput = ""

  for remap in [false, true]:
    for profile in ["dev", "release"]:
      let outDir = work / "out" / ((if remap: "remap-" else: "noremap-") & profile)
      if dirExists(outDir): removeDir(outDir)
      createDir(outDir)
      for crate in crates:
        commands.add(compileCrate(rustc, crate, profile, outDir, remap))
        let crateNeedles = needles & @[Needle(label: "crate source prefix",
          path: crate.prefix)]
        let stem = outDir / ("lib" & crate.crateName & "-" & crate.metadataHash)
        for (kind, file) in [("rlib", stem & ".rlib"), ("rmeta", stem & ".rmeta"),
            ("dep-info", outDir / (crate.crateName & "-" & crate.metadataHash & ".d"))]:
          if not fileExists(file):
            fail("expected output " & file & " was not produced")
          rows.add(Row(remap: remap, profile: profile, crate: crate.pin.name &
            " " & crate.pin.version, output: kind,
            findings: scanEach(file, crateNeedles)))
      commands.add(compileApp(rustc, linker, crates, profile, appDir, outDir))
      var appNeedles = needles
      for crate in crates:
        appNeedles.add(Needle(label: "crate source prefix (" & crate.pin.name &
          ")", path: crate.prefix))
      let app = outDir / "measure_app"
      rows.add(Row(remap: remap, profile: profile, crate: "(all, linked)",
        output: "binary", findings: scanEach(app, appNeedles)))
      appOutput.add(((if remap: "remap " else: "no remap ") & profile & ": ") &
        run(quoteShell(app)).strip() & "\n")

  # The positive control must be seen in its own rlib without a remap.
  var controlSeen = false
  for row in rows:
    if not row.remap and row.crate.startsWith("pathcontrol") and
        row.output == "rlib" and
        row.findings.getOrDefault("crate source prefix").len > 0:
      controlSeen = true

  var md = "# Store path in Rust crate outputs\n\n"
  md.add("- date: " & now().utc.format("yyyy-MM-dd HH:mm") & " UTC\n")
  md.add("- rustc: `" & run(quoteShell(rustc) & " -vV").replace("\n", "; ") & "`\n")
  md.add("- rustc prefix: `" & rust.prefix & "`\n")
  md.add("- linker: " & linkerNote & "\n")
  md.add("- store root: `" & storeRoot & "`\n")
  for crate in crates:
    md.add("- crate `" & crate.pin.name & " " & crate.pin.version & "` sha256 `" &
      crate.pin.sha256 & "` edition " & crate.edition & ", prefix `" &
      crate.prefix & "`\n")
  md.add("- positive control found in its rlib without remap: " &
    $controlSeen & "\n\n")
  md.add("| remap | profile | crate | output |")
  for needle in needles: md.add(" " & needle.label & " |")
  md.add(" crate source prefix |\n|---|---|---|---|")
  for needle in needles: md.add("---|")
  md.add("---|\n")
  for row in rows:
    md.add("| " & (if row.remap: "yes" else: "no") & " | " & row.profile &
      " | " & row.crate & " | " & row.output & " |")
    for needle in needles:
      let where = row.findings.getOrDefault(needle.label)
      md.add(" " & (if where.len > 0: "found (" & where & ")" else: "-") & " |")
    var crateHits: seq[string] = @[]
    for label, where in row.findings:
      if label.startsWith("crate source prefix") and where.len > 0:
        crateHits.add(label.replace("crate source prefix", "").strip() &
          (if label == "crate source prefix": "" else: " ") & "(" & where & ")")
    md.add(" " & (if crateHits.len > 0: "found " & crateHits.join(", ") else: "-") &
      " |\n")
  md.add("\n## Binary runs\n\n```\n" & appOutput & "```\n\n## Commands\n\n```\n")
  for command in commands: md.add(command & "\n")
  md.add("```\n")
  if report.len > 0:
    writeFile(report, md)
  echo md
  if not controlSeen:
    fail("INVALID: the positive control's source path was not found in its " &
      "rlib, so the scan cannot be shown to see an embedding")

when isMainModule:
  try:
    main()
  except CatchableError as err:
    stderr.writeLine("measure_store_path_in_rust_crate_outputs: " & err.msg)
    quit(1)
