## The Rust toolchain the engine provisions into the store root on Linux
## x86_64 runs on the store root's C library, links through the store root's
## C compiler driver, and a monitored compile with it reads nothing outside
## the logical roots.
##
## rust-lang's release archive carries no C library: its programs ask for
## the host's loader (`/lib64/ld-linux-x86-64.so.2`), which NixOS does not
## have and which, on any other host, is a read outside every logical root
## of the portable cache identity. `--tool-provisioning=tarball` therefore
## relocates it onto the loader and C library of the catalog's Linux C
## toolchain, the `gcc` package's realization in the same tool store, and the
## `gcc` arm exports its driver as `cc`, the linker rustc runs by default.
##
## What it checks, against the catalog's own pinned arms realized by the
## engine's own tarball realizer (`resolveTarballTool`) into a dedicated
## store root:
##   * the `PT_INTERP` of `rustc` and `cargo` is the loader in the realized
##     `gcc` prefix, and the run path of `rustc`, `cargo` and
##     `librustc_driver` names that prefix's C library directory; every
##     absolute loader or run-path entry lies inside the store root;
##   * `cc` sits beside the realized `gcc` driver, and the relocated
##     `rustc -vV` runs;
##   * two monitored engine edges (`runBuild`, automatic monitor policy)
##     run the realized `rustc` with `PATH` holding only the realized `rustc`
##     and `gcc` directories: one compiles a library crate, the other
##     compiles and links a binary that uses it, through `cc`. The binary
##     runs, prints what it should, and asks for the store root's loader;
##   * every access the monitor recorded for either edge lies inside a
##     logical root of the invocation (`declaredFilesystemRoots` for this
##     project and store). The judgement is the engine's own:
##     `computePortableFingerprint`, the function whose verdict is the
##     `portable-fingerprint-unavailable ... outside every logical root`
##     trace, applied to the edge's monitored reads, probes and directory
##     listings. The monitor's reads include the realized toolchains' files,
##     the relocated C library among them (vacuity: the shim entered the
##     relocated rustc and the driver it ran).
##
## Why the evidence and not the edge's recorded portable verdict: the engine
## computes that verdict only for an edge whose result it records, and it
## records no rustc edge yet, because rustc's observed entropy is not
## blessed (`cache-skip-ineligible ... reasons=unblessed-entropy`). That is
## a property of the rustc edge, which is later work; the reads are what
## this deliverable governs. The edges' trace is in the checkpoint output.
##
## Two exclusions, each named in the checkpoint output: the engine's own
## monitor shim (never an input, by the engine's rule), and an `LD_PRELOAD`
## the test process inherited from the session that runs it (a command
## tracer, for example), which the actions inherit and the monitor sees.
## The second is narrow on purpose: the preloaded file itself, and the
## loader's lookups of a library the preload names (`DT_NEEDED`) under a
## directory of the preload's own run path. Nothing else under those
## directories is left out, so a toolchain that read its C library from the
## same place would still fail the check. Without such a preload it is empty.
##
## The library compile passes `--remap-path-prefix=<project>=.`, as a later
## registry-crate edge will, so its rlib does not embed the project path.
##
## Falsifying mutations, both run: dropping the `elf*` relocation from the
## Rust arms leaves rustc on the host loader (the interpreter and run-path
## checks fail, and the read check names `/lib64/ld-linux-x86-64.so.2` as
## outside every logical root); dropping the `cc` export from the `gcc` arm
## makes the link fail with "linker `cc` not found".
##
## Network: the first run on an empty store downloads the Rust release
## (about 250 MB), the C toolchain (about 100 MB) and `patchelf`, each
## verified against its pinned SHA-256. `REPRO_CONFORMANCE_STORE` names a
## store root that survives between runs; otherwise one under this
## checkout's `build/` is used and kept, so the downloads happen once.
##
## No mocks: the catalog's packages, the engine's realizer and build engine,
## the graph-built monitor and shim, a real rustc and gcc. Linux x86_64 only:
## it is the one host the catalog relocates the Rust toolchain on.

import std/[os, osproc, strutils, unittest]

import repro_core/ambient_execution

import repro_build_engine
from repro_core/dependency_gathering import automaticMonitorGatheringPolicy
import repro_core/input_check_policy
import repro_project_dsl
import repro_project_dsl/install_mirror_relocation
import repro_interface_artifacts
import repro_tool_profiles
import repro_tool_profiles/tarball_conformance
# Imported for its effect: it registers every catalog package with a tarball
# arm, `rustc`, `cargo` and `gcc` among them.
import repro_dsl_stdlib/catalog_tarball_packages
import repro_dsl_stdlib/linux_toolchain_pin
import repro_test_support
import repro_test_support/reasoned_skip
import repro_local_store/portable_fingerprint

const
  RustVersion = "1.94.0"
    ## The stdlib's default release, the arm a plain `uses: "rustc"` takes.
  OutsideRoots = "outside every logical root"

proc toolUseFor(packageName: string): InterfaceToolUse =
  ## The tool use a recipe declaring `uses: "<packageName>"` gets, from the
  ## registered stdlib package.
  doAssert CatalogTarballModules.len > 0
  let iface = toProjectInterface(PackageDef(
    packageName: "storeRootRustc",
    nativeBuildDeps: @[PackageUseDef(rawConstraint: packageName,
      packageSelector: packageName, executableName: packageName,
      depKind: "native")]), registeredPackages())
  doAssert iface.toolUses.len == 1
  iface.toolUses[0]

proc realize(packageName, version: string; storeRoot: string):
    tuple[prefix, executable: string] =
  ## Realize the package's Linux x86_64 arm of `version` (any when empty)
  ## through the engine's tarball realizer.
  var use = toolUseFor(packageName)
  var chosen: seq[InterfaceTarballProvisioning]
  for arm in use.tarballProvisioning:
    if armMatchesTarget(arm, "linux", "x86_64") and
        (version.len == 0 or arm.detail.version == version):
      chosen.add(arm)
  doAssert chosen.len > 0, "no Linux x86_64 arm of " & packageName
  use.tarballProvisioning = @[chosen[0]]
  let profile = resolveTarballTool(use, storeRoot / "tool-store")
  (profile.selectedStorePath, profile.resolvedExecutablePath)

proc inside(path, root: string): bool =
  ## Whether `path` lies in `root`. The monitor reports paths as the program
  ## spelled them (`<gcc>/bin/../lib/...`), so both are normalized first.
  let p = normalizedPath(path)
  let r = normalizedPath(root).strip(leading = false, chars = {'/'})
  p == r or p.startsWith(r & "/")

type AmbientPreload = object
  ## One library of an `LD_PRELOAD` this test process inherited, and what
  ## the loader looks up on its behalf: each library it names
  ## (`DT_NEEDED`), in each absolute directory of its own run path.
  library: string
  needed: seq[string]
  runPaths: seq[string]

proc ambientPreloads(): seq[AmbientPreload] =
  ## The engine passes `LD_PRELOAD` on to the actions, so the monitor sees
  ## the preload's loads beside the compiler's. They belong to the session
  ## that runs the test (a command tracer, for example), not to the
  ## toolchain, so the read check below leaves them out. In a session
  ## without a preload this is empty and the check covers every read.
  for entry in getEnv("LD_PRELOAD").replace(' ', ':').split(':'):
    if entry.len == 0 or not fileExists(entry):
      continue
    let facts = readElfRuntimeFacts(entry)
    var preload = AmbientPreload(library: normalizedPath(entry),
      needed: facts.needed)
    for dir in facts.runPaths:
      if dir.startsWith("/"):
        preload.runPaths.add(dir)
    result.add(preload)

proc loadedForPreload(path: string; preloads: seq[AmbientPreload]): bool =
  ## Whether `path` is a preloaded library, or the loader's lookup (a hit or
  ## a probe, `glibc-hwcaps` subdirectories included) of a library a preload
  ## names, under a directory of that preload's run path. Any other file in
  ## those directories is NOT covered.
  for preload in preloads:
    if normalizedPath(path) == preload.library:
      return true
    if path.extractFilename in preload.needed:
      for dir in preload.runPaths:
        if path.inside(dir):
          return true
  false

proc checkRelocated(path, storeRoot, gccPrefix: string; program: bool) =
  ## `path` asks for the realized gcc prefix's loader (a program) and its run
  ## path names that prefix's C library; no absolute entry leaves the store.
  checkpoint("ELF " & path)
  let facts = readElfRuntimeFacts(path)
  require facts.isElf and facts.parsed
  checkpoint("  PT_INTERP " & facts.interpreter & "; run path " &
    facts.runPaths.join(":"))
  if program:
    check facts.interpreter == gccPrefix / LinuxToolchainLoader
  else:
    check facts.interpreter.len == 0
  check (gccPrefix / LinuxToolchainRuntimeDir) in facts.runPaths
  for entry in facts.runPaths:
    if entry.startsWith("/"):
      check entry.inside(storeRoot)

proc onlyChild(dir, prefix, suffix: string): string =
  for kind, path in walkDir(dir):
    let name = path.extractFilename
    if name.startsWith(prefix) and name.endsWith(suffix):
      return path
  ""

suite "the store-root Rust toolchain":
  when not (defined(linux) and defined(amd64)):
    test "is relocated on Linux x86_64 only":
      skip("the catalog relocates the Rust toolchain on Linux x86_64 only")
  else:
    let storeRoot = absolutePath(getEnv("REPRO_CONFORMANCE_STORE",
      "build" / "test-store" / "store-root-rustc"))
    createDir(storeRoot)
    let gcc = realize("gcc", "", storeRoot)
    let rustc = realize("rustc", RustVersion, storeRoot)
    let cargo = realize("cargo", RustVersion, storeRoot)

    test "rustc, cargo and librustc_driver run on the store root's C library":
      check gcc.prefix.inside(storeRoot)
      check rustc.prefix.inside(storeRoot)
      check cargo.prefix.inside(storeRoot)
      checkRelocated(rustc.executable, storeRoot, gcc.prefix, program = true)
      checkRelocated(cargo.executable, storeRoot, gcc.prefix, program = true)
      let driver = onlyChild(rustc.prefix / "lib", "librustc_driver-", ".so")
      require driver.len > 0
      checkRelocated(driver, storeRoot, gcc.prefix, program = false)
      # The C driver answers to `cc`, the linker rustc runs by default.
      check fileExists(gcc.prefix / "bin" / LinuxToolchainCcAlias)
      # And the relocated compiler starts.
      let version = uncontrolledExecCmdEx(
        quoteShellCommand([rustc.executable, "-vV"]))
      checkpoint(version.output)
      check version.exitCode == 0
      check ("release: " & RustVersion) in version.output

    test "a monitored compile and link read nothing outside the logical roots":
      let base = absolutePath("build" / "test-tmp" /
        "t_store_root_rustc_links_through_the_store_root_c_driver" /
        testCaseScratchSlug())
      if dirExists(base):
        removeDir(base)
      let project = base / "project"
      createDir(project / "src")
      createDir(project / "out")
      writeFile(project / "src" / "greet.rs",
        "pub fn greeting() -> &'static str { \"store-root rustc\" }\n")
      writeFile(project / "src" / "main.rs",
        "fn main() { println!(\"{}\", greet::greeting()); }\n")
      let preloads = ambientPreloads()
      for preload in preloads:
        checkpoint("ambient preload left out of the read check: " &
          preload.library & " (its lookups of " & preload.needed.join(", ") &
          " under " & preload.runPaths.join(":") & ")")
      let tools = prepareMonitorTools(getCurrentDir(), base / "monitor",
        "store-root-rustc")
      putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
      # PATH holds the two realized toolchains and nothing else, as an
      # action of a recipe declaring `rustc` and `gcc` does in tarball mode.
      let pathEnv = "PATH=" & rustc.executable.parentDir & ":" &
        (gcc.prefix / "bin")
      let policy = automaticMonitorGatheringPolicy()
      let lib = action("rustc-lib-greet",
        @[rustc.executable, "--crate-name", "greet", "--edition=2021",
          "--crate-type", "lib", "--emit=link", "-C", "debuginfo=2",
          "--remap-path-prefix=" & project & "=.",
          "--out-dir", "out", "src/greet.rs"],
        cwd = project, inputs = @["src/greet.rs"],
        outputs = @["out/libgreet.rlib"], cacheable = true,
        actionCachePolicy = ffpHybrid, dependencyPolicy = policy,
        env = @[pathEnv],
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let bin = action("rustc-bin-hello",
        @[rustc.executable, "--crate-name", "hello", "--edition=2021",
          "--crate-type", "bin", "--extern", "greet=out/libgreet.rlib",
          "-o", "out/hello", "src/main.rs"],
        cwd = project, deps = @["rustc-lib-greet"],
        inputs = @["src/main.rs", "out/libgreet.rlib"],
        outputs = @["out/hello"], cacheable = true,
        actionCachePolicy = ffpHybrid, dependencyPolicy = policy,
        env = @[pathEnv],
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      var config = BuildEngineConfig(
        cacheRoot: base / "cache",
        runQuotaCliPath: tools.monitorCliPath,
        monitorCliPath: tools.monitorCliPath,
        monitorCliArgs: tools.monitorCliArgs,
        maxParallelism: 1'u32,
        stdoutLimit: 256 * 1024,
        stderrLimit: 256 * 1024,
        bypassRunQuota: true)
      # The roots `repro build` declares for a project with this store.
      config.portableRoots = declaredFilesystemRoots(project, base / "work",
        storeRoot = storeRoot, outRoot = project / "out")
      let run = runBuild(graph([lib, bin]), config)
      require run.results.len == 2
      for res in run.results:
        checkpoint(res.id & ": status " & $res.status & ", exit " &
          $res.exitCode & ", portable " & $res.portable & " (" &
          res.portableReason & ")\nstderr: " & res.stderr)
        var reads: seq[string]
        for path in res.evidence.monitorReads:
          reads.add(path)
        checkpoint(res.id & " monitor reads:\n  " & reads.join("\n  "))
        var events: seq[string]
        for entry in run.trace:
          if entry.actionId == res.id:
            events.add(entry.event & " " & entry.detail)
        checkpoint(res.id & " trace:\n  " & events.join("\n  "))
        require res.status == asSucceeded
        # Vacuity guard: the monitor entered the relocated compiler and the
        # driver it ran, so their reads of the store root were observed.
        var sawRust, sawLibc = false
        for path in reads:
          if path.inside(rustc.prefix): sawRust = true
          if path.inside(gcc.prefix / LinuxToolchainRuntimeDir):
            sawLibc = true
        check sawRust
        check sawLibc
        check OutsideRoots notin res.portableReason
        # The read check, by the engine's own classification
        # (`computePortableFingerprint`, which writes the
        # `outside every logical root` reason): every access the monitor
        # saw, less the engine's own monitor shim and the session's preload,
        # lies inside a logical root of this invocation.
        var excluded: seq[string]
        proc keep(path: string): bool =
          if path == tools.shim or path.loadedForPreload(preloads):
            excluded.add(path)
            return false
          true
        var probes, enumerations, kept: seq[string]
        for path in reads:
          if keep(path): kept.add(path)
        for path in res.evidence.monitorProbes:
          if keep(path): probes.add(path)
        for path in res.evidence.monitorDirectoryEnumerations:
          if keep(path): enumerations.add(path)
        checkpoint(res.id & " accesses left out:\n  " & excluded.join("\n  "))
        let verdict = computePortableFingerprint(config.portableRoots,
          [res.id], project, [], [], kept, probes, enumerations)
        checkpoint(res.id & " read check: " & verdict.reason)
        check verdict.portable
        check OutsideRoots notin verdict.reason
      let libResult = run.results[0]
      let binResult = run.results[1]
      check libResult.id == "rustc-lib-greet"
      check binResult.id == "rustc-bin-hello"
      # The link ran the store root's driver, through `cc`: the driver read
      # its own start files and its specs.
      var sawDriver = false
      for path in binResult.evidence.monitorReads:
        if path.inside(gcc.prefix) and (path.endsWith("/crtbeginS.o") or
            path.endsWith("/specs")):
          sawDriver = true
      check sawDriver
      let ran = uncontrolledExecCmdEx(
        quoteShellCommand([project / "out" / "hello"]))
      check ran.exitCode == 0
      check ran.output.strip() == "store-root rustc"
      let linked = readElfRuntimeFacts(project / "out" / "hello")
      check linked.interpreter == gcc.prefix / LinuxToolchainLoader
