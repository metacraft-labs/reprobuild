## The engine's own recipe compiles (the project provider compile and the
## interface extraction) record no file of the host's `/bin/sh` as an input.
##
## WHY. Those edges run the pinned Nim compiler, which starts the C compiler,
## the assembler driver and the linker. When it started them through
## `/bin/sh -c`, the monitor recorded the host shell's startup closure (on
## NixOS an interactive bash with its own C library, readline and ncurses) as
## inputs of every recipe compile. A machine whose `/bin/sh` is another
## program (a Debian dash) then recompiled every provider and interface a
## restored bundle carried, although the compiler, the C toolchain and the
## recipe were the same. Three things started that shell inside the edge:
## the Nim compiler for each C compile and link, the edge's own C compiler
## probes (`cCompilerFamily`, `cCompilerAcceptsFlags`), and the compile-time
## `staticExec` that named the compiler an image was built with
## (`BuiltCCompilerPath`). Each now runs without one, so these records must
## name only the toolchain's files.
## The bundle container gate
## (`tests/e2e/bundles/t_bundle_restores_on_a_plain_machine_without_rebuilding.nim`)
## measures the consequence across two machines; this test measures the
## cause on one, without a container.
##
## THE ROUTES A RECIPE CHOOSES. Three more places started the host shell
## inside a recipe compile, each only for a recipe or an environment that
## reaches it, so each has a case of its own:
##   * `dslDeps:` resolves each package with a compile-time `staticExec` of
##     the engine (`emitDeclaredPackageImports`);
##   * a consumer of a resource contract probes, at compile time, that it can
##     create its DSL scratch directory (`dirLooksWritable`) and runs the
##     accessor generator there (`cd <dir> && exec <nim> c -r …`);
##   * an action whose environment names a loader path had the monitored
##     command started through `/bin/sh -c 'export LD_LIBRARY_PATH=…; exec
##     "$@"'` (`deferRuntimeLibraryEnvForShell`); the provider compile is one,
##     since it passes the caller's `LD_LIBRARY_PATH` through.
## Upstream Nim runs every `staticExec` through `/bin/sh -c`; the pinned
## compiler runs a plain command (and `cd <absolute dir> && [exec] <plain
## command>`) directly, the commands are built plain
## (`compile_time_shell.compileTimeCommand`, `compilerWritabilityProbe`), and
## the monitor sets a loader path for the command it starts
## (`--payload-env`). Each case carries its own vacuity guard: the package
## was imported, the generator ran in this build, the loader searched the
## path.
##
## WHAT IS "THE HOST SHELL'S CLOSURE". The files the dynamic loader maps to
## start `/bin/sh` on this host (`LD_TRACE_LOADED_OBJECTS=1 /bin/sh`, read
## by the loader itself, plus the shell binary), less any file of a Nix store
## path the toolchain's own closure holds: a file the compiler or the C
## toolchain needs for itself is the toolchain's input, whatever else uses
## it. The toolchain is the closure (`nix-store -qR`) of every store path the
## provider compile's command names and of the Nim compiler it runs. Also
## less the objects the host's environment preloads into every process
## (`LD_PRELOAD`, `/etc/ld.so.preload`): the loader maps them into `/bin/sh`
## and into the compiler alike, so their presence in a record says nothing
## about whether the compile started the shell. An agent harness's command
## tracer is one, and it re-adds itself to every process it starts even
## after `reproRun` removes the variable, so on such a host every record
## names it.
##
## THE COMPILER. The recipe compiles run the Nim compiler named by
## `REPRO_NIM_COMPILER`. The installed package sets it to the Nim it ships
## (the pinned compiler the dev shell puts on PATH), and that is the one a
## bundle carries; this test sets it the same way, to the dev shell's `nim`,
## unless the caller names one (which is how the falsifying mutation below
## is run). Without the variable a checkout build provisions an upstream
## bootstrap Nim instead, which still starts the C compiler through the
## shell; that route is outside this test.
##
## ASSERTS, for a one-edge project built by the `repro` under test into a
## fresh action cache:
##   * VACUITY GUARD: the host shell's closure, less the toolchain's, is not
##     empty (otherwise nothing could be told apart), and the build recorded
##     a provider-compile and an interface-extraction record, each with more
##     than a hundred inputs, among them a file of the Nim compiler;
##   * no input of either record is a file of that closure, nor `/bin/sh`
##     itself;
##   * the `PATH` either record read is the one the edge declares, made of
##     the toolchain's Nix store directories, not the caller's;
##   * no input lies in the caller's `TMPDIR`, which the build is given fresh
##     (a Nix dev shell makes one per shell).
##
## Falsifying mutations: `REPRO_NIM_COMPILER` naming a Nim compiler that
## starts the C compiler through `/bin/sh -c` (the pinned compiler before
## the fix) turns every case red, naming the shell's C library, readline
## and ncurses; a compiler that runs commands without a shell but whose
## `staticExec` still goes through one turns the `dslDeps` and resource
## cases red; restoring the `export …; exec "$@"` payload shell turns the
## loader-path case red.
##
## A DOCUMENTED LIMIT, IN THE OTHER DIRECTION. A project whose lock pins an
## upstream Nim release to compile its recipe gets that release, which
## starts every command through `/bin/sh -c`; the last case builds one and
## asserts that its recipe-compile records DO name the host shell, as the
## limit is documented, so the statement cannot go stale unnoticed. It is
## the confirmation test of reprobuild-pm
## `issues/2026-11-18-a-project-that-pins-an-upstream-provider-nim-gets-recipe-compiles-keyed-on-the-host-bin-sh.md`,
## and a network case (nim-lang.org).
##
## NO MOCKS: the built `repro`, the pinned Nim compiler and C toolchain, the
## real monitor and action cache; the shell's closure is read from the
## host's dynamic loader.

from repro_core/process_streams import drainStream
import std/[os, osproc, sets, streams, strtabs, strutils, tables, tempfiles,
  unittest]

import repro_hash
import repro_local_store
import repro_interface_artifacts
import repro_selfhost
import repro_test_support/reasoned_skip

import library_cache_sharing_fixture

proc storePathOf(path: string): string =
  ## `/nix/store/<hash-name>` of a path inside the Nix store, else "".
  if not path.startsWith("/nix/store/"): return ""
  let rest = path["/nix/store/".len .. ^1]
  let slash = rest.find('/')
  "/nix/store/" & (if slash < 0: rest else: rest[0 ..< slash])

proc loaderClosure(program: string): HashSet[string] =
  ## `program` and every object the dynamic loader maps to start it,
  ## each with symlinks resolved.
  result.incl(expandFilename(program))
  let res = execCmdEx("env LD_TRACE_LOADED_OBJECTS=1 " & quoteShell(program))
  for line in res.output.splitLines():
    # `libc.so.6 => /path (0x...)` or `/lib64/ld-linux-x86-64.so.2 (0x...)`
    var path = ""
    let arrow = line.find("=> ")
    if arrow >= 0:
      path = line[arrow + 3 .. ^1].strip()
    else:
      path = line.strip()
    let paren = path.find(" (")
    if paren >= 0: path = path[0 ..< paren]
    if path.startsWith("/") and fileExists(path):
      result.incl(expandFilename(path))

proc loaderNeeds(program: string): seq[(string, string)] =
  ## The `(soname, path)` pairs the dynamic loader resolves to start
  ## `program`, as it reports them.
  let res = execCmdEx("env LD_TRACE_LOADED_OBJECTS=1 " & quoteShell(program))
  for line in res.output.splitLines():
    let arrow = line.find(" => ")
    if arrow < 0: continue
    var path = line[arrow + 4 .. ^1].strip()
    let paren = path.find(" (")
    if paren >= 0: path = path[0 ..< paren]
    if path.startsWith("/") and fileExists(path):
      result.add((line[0 ..< arrow].strip(), path))

proc nixClosure(paths: openArray[string]): HashSet[string] =
  var roots: seq[string]
  for p in paths:
    let sp = storePathOf(p)
    if sp.len > 0 and sp notin roots: roots.add(sp)
  if roots.len == 0: return
  var cmd = "nix-store -qR"
  for r in roots: cmd.add(" " & quoteShell(r))
  let res = execCmdEx(cmd)
  doAssert res.exitCode == 0, res.output
  for line in res.output.splitLines():
    if line.strip().len > 0: result.incl(line.strip())

proc toolchainPaths(): seq[string] =
  ## The resolved files the provider compile's command names, and the
  ## compiler it runs.
  let command = providerCompileCommand("repro.nim", "out" / "provider")
  for arg in command:
    for piece in arg.split({':', ',', '=', ' '}):
      if piece.startsWith("/nix/store/"): result.add(piece)
  # The command starts with the Nim compiler (`boundedNimCompileCommand`).
  let nim = command[0]
  let resolved = (if nim.isAbsolute: nim else: findExe(nim))
  if resolved.len > 0:
    result.add(resolved)
    result.add(expandFilename(resolved))

proc digestOfRecordDir(name: string): ContentDigest =
  ## `<algorithm>-<domain>-<hex>.rbar`, as the per-edge store names it.
  let parts = name.changeFileExt("").split('-')
  doAssert parts.len == 3, name
  result.algorithm = HashAlgorithm(parseInt(parts[0]))
  result.domain = HashDomain(parseInt(parts[1]))
  let raw = parseHexStr(parts[2])
  doAssert raw.len == 32, name
  for i in 0 ..< 32: result.bytes[i] = byte(raw[i])

proc recipeCompileRecords(actionCacheRoot: string):
    Table[string, seq[ActionResultRecord]] =
  ## The records whose outputs live under `recipe-compiles/<kind>/`, by kind.
  let cache = openActionCache(actionCacheRoot / "action-cache",
    attachShm = false)
  for kind, dir in walkDir(actionCacheRoot / "action-cache" / "hot-records"):
    if kind != pcDir or not dir.endsWith(".rbar"): continue
    for record in cache.loadPerEdgeRecords(
        digestOfRecordDir(dir.extractFilename)):
      for output in record.outputs:
        for k in ["provider", "interface"]:
          if ("recipe-compiles" / k) in output.path:
            result.mgetOrPut(k, @[]).add(record)
            break

proc environmentPreloads(): HashSet[string] =
  ## The objects this host's environment preloads into every process: the
  ## `LD_PRELOAD` this test was started with and `/etc/ld.so.preload`, each
  ## with symlinks resolved. Both lists are separated by spaces or colons
  ## (ld.so(8), "LD_PRELOAD" and "/etc/ld.so.preload").
  var listed = getEnv("LD_PRELOAD")
  if fileExists("/etc/ld.so.preload"):
    listed.add(" " & readFile("/etc/ld.so.preload"))
  for entry in listed.split({' ', ':', '\t', '\n'}):
    if entry.startsWith("/") and fileExists(entry):
      result.incl(expandFilename(entry))

proc hostShellOnly(): HashSet[string] =
  ## The host shell's closure, less the toolchain's and less what the
  ## environment preloads into every process (see the header).
  let toolchain = nixClosure(toolchainPaths())
  let preloads = environmentPreloads()
  for f in loaderClosure("/bin/sh"):
    let sp = storePathOf(f)
    if (sp.len == 0 or sp notin toolchain) and f notin preloads:
      result.incl(f)

proc useShippedCompiler() =
  ## `REPRO_NIM_COMPILER` as the installed package sets it, unless the caller
  ## named one (the falsifying mutation's route).
  if getEnv("REPRO_NIM_COMPILER").len == 0:
    let nim = findExe("nim")
    if nim.len > 0: putEnv("REPRO_NIM_COMPILER", expandFilename(nim))
  checkpoint("REPRO_NIM_COMPILER=" & getEnv("REPRO_NIM_COMPILER"))

type RecipeCompileCheck = object
  shellOnly: HashSet[string]
  callerTmp: string
  callerPath: string

proc newRecipeCompileCheck(): RecipeCompileCheck =
  useShippedCompiler()
  # The compiler is the pinned one from the Nix store.
  doAssert getEnv("REPRO_NIM_COMPILER").startsWith("/nix/store/"),
    "REPRO_NIM_COMPILER does not name a Nix store compiler"
  result.shellOnly = hostShellOnly()
  checkpoint("the host shell's closure, less the toolchain's: " &
    $result.shellOnly)
  # Vacuity guard: there is something to tell apart.
  doAssert result.shellOnly.len > 0, "the host shell's closure is empty"
  # A `TMPDIR` of the build's own, as a Nix dev shell makes one per shell
  # (`mktemp -d`): another shell or machine has another, so nothing of it
  # may be an input.
  result.callerTmp = createTempDir("repro-recipe-shell-tmpdir-", "")
  result.callerPath = getEnv("PATH")

proc buildProject(rc: RecipeCompileCheck; host: var SharedHost;
                  project: string;
                  extraEnv: openArray[(string, string)] = []): BuildRun =
  ## Build `project` without `LD_LIBRARY_PATH` (as the installed package
  ## runs: its wrapper sets none, the dev shell does) unless `extraEnv`
  ## names one, and with the check's own `TMPDIR`.
  var env = @[("TMPDIR", rc.callerTmp)]
  for pair in extraEnv: env.add(pair)
  result = host.build(project, portable = false, extraEnv = env,
    dropEnv = ["LD_LIBRARY_PATH"])
  checkpoint("build output:\n" & result.output)

proc absoluteInput(project, path: string): string =
  ## A record input as an absolute path: a relocatable record names its
  ## inputs relative to the recipe's directory, the edge's working
  ## directory.
  if path.isAbsolute: path else: normalizedPath(project / path)

proc hostShellInputs(rc: RecipeCompileCheck; record: ActionResultRecord;
                     project: string): seq[string] =
  ## The inputs of `record` that are `/bin/sh` or a file of the host
  ## shell's closure (less the toolchain's), as the record names them.
  for input in record.inputs:
    let absolute = absoluteInput(project, input.path)
    let resolved =
      if fileExists(absolute): expandFilename(absolute)
      else: absolute
    if absolute == "/bin/sh" or absolute in rc.shellOnly or
        resolved in rc.shellOnly:
      result.add(input.path)

proc reproRun(host: SharedHost; cwd: string; args: openArray[string]):
    tuple[code: int, output: string] =
  ## Run the `repro` under test in `cwd` against `host`'s store and action
  ## cache, with no remote cache and no compiler named by the caller
  ## (a project pin must decide it); stdout and stderr together.
  let env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key.startsWith("REPRO_BINARY_CACHE_") or key in ["LD_PRELOAD",
        "REPRO_NIM_COMPILER", "REPRO_SELFHOST_RESOLVED", "REPRO_LOCK_PINS",
        "REPRO_LOCK_PATH"]:
      continue
    env[key] = value
  env["REPRO_STORE_ROOT"] = host.storeRoot
  env["REPROBUILD_ACTION_CACHE_ROOT"] = host.actionCacheRoot
  env["REPRO_CACHE_DISABLE"] = "1"
  let p = startProcess(reproBinary(), workingDir = cwd, args = args,
    env = env, options = {poStdErrToStdOut})
  result.output = drainStream(p.outputStream)
  result.code = p.waitForExit()
  p.close()

proc requireNoHostShell(rc: RecipeCompileCheck; host: SharedHost;
                        project: string):
    Table[string, seq[ActionResultRecord]] =
  ## The provider-compile and interface-extraction records of `host`'s
  ## action cache, after asserting that each names no file of the host
  ## shell's closure, reads the `PATH` it declares and nothing of the
  ## caller's `TMPDIR`. Returned for the caller's own vacuity guards.
  result = recipeCompileRecords(host.actionCacheRoot)
  for kind in ["provider", "interface"]:
    checkpoint("records of " & kind & ": " &
      $result.getOrDefault(kind).len)
    # Vacuity guard: the edge ran and recorded what it read.
    doAssert result.getOrDefault(kind).len > 0, "no " & kind & " record"
    for record in result[kind]:
      check record.inputs.len > 100
      var sawCompiler = false
      var inCallerTmp: seq[string]
      let offending = rc.hostShellInputs(record, project)
      for input in record.inputs:
        if "-nim-" in input.path or "/nim-" in input.path:
          sawCompiler = true
        let absolute = absoluteInput(project, input.path)
        if absolute == rc.callerTmp or
            absolute.startsWith(rc.callerTmp & "/"):
          inCallerTmp.add(input.path)
      checkpoint(kind & " inputs in the caller's TMPDIR: " & $inCallerTmp)
      check inCallerTmp.len == 0
      check sawCompiler
      # The `PATH` the compile read is the one it declares (the
      # toolchain's directories), not the caller's: an inherited `PATH`
      # would key the record on the machine's default one.
      for e in record.envInputs:
        if e.name == "PATH":
          checkpoint(kind & " PATH=" & e.value)
          check e.value != rc.callerPath
          for dir in e.value.split(PathSep):
            check dir.startsWith("/nix/store/")
      checkpoint(kind & " inputs from the host shell: " & $offending)
      check offending.len == 0

const PinnedUpstreamNim = "2.2.10"
  ## The upstream Nim release the documented-limit case pins.

const OneEdgeRecipe = """
package PKGNAME:
  build:
    let root = activeProviderProjectRoot()
    let src = root / "src/in.txt"
    let outp = root / "out/o.txt"
    createDir(outp.parentDir)
    let a = buildAction(id = "PKGNAME-copy",
      call = inlineExecCall(@["cp", src, outp], root),
      inputs = @[src], outputs = @[outp],
      dependencyPolicy = automaticMonitorPolicy())
    defaultBuildAction(a)
"""

proc writeOneEdgeProject(project: string; packageName = "shellprobe";
                         head = ""; tail = "") =
  ## A recipe with one `cp` edge, and `head` / `tail` around its package.
  createDir(project / "src")
  writeFile(project / "src" / "in.txt", "in\n")
  writeFile(project / "repro.nim", "import std/os\nimport repro_project_dsl\n" &
    head & "\n" & OneEdgeRecipe.replace("PKGNAME", packageName) & tail)

const ResourceProducerRecipe = """
import repro_project_dsl
IMPORT_RESOURCES
import std/options

type
  ProbeAttrs = object
    image*: string

proc pIdentity(inst: ResourceInstance): string {.nimcall.} =
  "probe:" & inst.address

proc pDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  digestString(inst.address)

proc pObserve(inst: ResourceInstance;
              recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  result.present = false

proc pApply(inst: ResourceInstance; action: ResourceActionKind;
            observed: ObservedState): ResourceBinding {.nimcall.} =
  ResourceBinding(address: inst.address, typeId: inst.typeId,
    resourceId: pIdentity(inst), present: true)

let probeDriver = ResourceProviderDriver(
  identity: pIdentity, digest: pDigest, observe: pObserve, apply: pApply)

resourceType "shellprobe.box":
  attrs: ProbeAttrs
  wrapper: box
  determinism: rdVolatile
  driver: probeDriver
  attr image: string

package shellprobeproducer:
  executable placeholder:
    discard
"""

suite "recipe compiles do not record the host shell":
  test "the provider compile and the interface extraction name no file of /bin/sh":
    when not defined(linux):
      skip("reads the host shell's closure from the glibc dynamic loader; " &
        "Linux only")
    else:
      var host = newSharedHost("repro-recipe-shell-")
      defer: cleanup(host)
      let rc = newRecipeCompileCheck()
      defer: removeDir(rc.callerTmp)
      let project = host.scratch / "proj"
      writeOneEdgeProject(project)
      commitCheckout(project)
      let run = rc.buildProject(host, project)
      require run.code == 0
      discard rc.requireNoHostShell(host, project)

  test "a recipe that imports a dslDeps package names no file of /bin/sh":
    ## `dslDeps:` resolves each package through the engine at compile
    ## time (`staticExec` of `<repro> internal resolve-package …`, in
    ## `emitDeclaredPackageImports`), inside the interface extraction.
    when not defined(linux):
      skip("reads the host shell's closure from the glibc dynamic loader; " &
        "Linux only")
    else:
      var host = newSharedHost("repro-recipe-shell-dsldeps-")
      defer: cleanup(host)
      let rc = newRecipeCompileCheck()
      defer: removeDir(rc.callerTmp)
      let exporter = host.scratch / "shellprobe_exporter"
      createDir(exporter)
      writeFile(exporter / "repro.nim",
        "const shellprobeExported* = \"from the exporter\"\n")
      commitCheckout(exporter)
      let project = host.scratch / "consumer"
      # The use is under `reproInterfaceMode`, the only compile handed
      # `-d:reproBin`: a resolution that failed drops the import, and the
      # compile then fails on the undeclared symbol instead of passing.
      writeOneEdgeProject(project, packageName = "shellprobedeps",
        tail = """
  dslDeps:
    "shellprobe_exporter"
  when defined(reproInterfaceMode):
    const consumerSees = shellprobeExported
    static: doAssert consumerSees.len > 0
""")
      commitCheckout(project)
      let run = rc.buildProject(host, project)
      require run.code == 0
      let records = rc.requireNoHostShell(host, project)
      # Vacuity guard: the extraction resolved and imported the package.
      var sawExporter = false
      for record in records["interface"]:
        for input in record.inputs:
          if input.path.endsWith("shellprobe_exporter/repro.nim"):
            sawExporter = true
      check sawExporter

  test "a recipe that uses a resource contract names no file of /bin/sh":
    ## A consumer that `uses:` a sibling declaring a `resourceType` makes
    ## the DSL create its scratch directory (probing that it can) and run
    ## the accessor generator (`nim c -r` in that directory) at compile
    ## time, the first time any of its recipe compiles expands the macro.
    when not defined(linux):
      skip("reads the host shell's closure from the glibc dynamic loader; " &
        "Linux only")
    else:
      var host = newSharedHost("repro-recipe-shell-resource-")
      defer: cleanup(host)
      let rc = newRecipeCompileCheck()
      defer: removeDir(rc.callerTmp)
      let workspace = host.scratch / "ws"
      let producer = workspace / "shellprobeproducer"
      createDir(producer)
      # Spliced here so the suite inventory, which reads this file's import
      # lines, does not count the fixture's import as the test's own.
      writeFile(producer / "repro.nim", ResourceProducerRecipe.replace(
        "IMPORT_RESOURCES", "import " & "repro_resources"))
      let project = workspace / "consumer"
      writeOneEdgeProject(project, packageName = "shellprobeconsumer",
        tail = """
proc useBox() =
  discard box("one", image = "busybox")
""")
      # `uses:` names the producer.
      writeFile(project / "repro.nim", readFile(project / "repro.nim").replace(
        "package shellprobeconsumer:\n",
        "package shellprobeconsumer:\n  uses:\n    \"shellprobeproducer\"\n"))
      commitCheckout(workspace)
      let scratchRoot = workspace / ".repro" / "build" / "dsl"
      # Vacuity guard: the scratch directory is new, so the probe runs.
      require not dirExists(scratchRoot)
      let run = rc.buildProject(host, project)
      require run.code == 0
      discard rc.requireNoHostShell(host, project)
      # Vacuity guard: the generator ran in this build (its witness log).
      var generated = 0
      for f in walkDirRec(scratchRoot):
        if f.endsWith(".genlog"):
          for line in readFile(f).splitLines():
            if line.strip().len > 0: inc generated
      checkpoint("accessor generator runs: " & $generated)
      check generated > 0

  test "an action whose environment names a loader path names no file of /bin/sh":
    ## A loader path in an action's environment is set for the monitored
    ## command alone, after the monitor has started without it
    ## (`deferRuntimeLibraryEnvForShell`). The provider compile passes
    ## `LD_LIBRARY_PATH` through from the caller (the dev shell sets one).
    when not defined(linux):
      skip("reads the host shell's closure from the glibc dynamic loader; " &
        "Linux only")
    else:
      var host = newSharedHost("repro-recipe-shell-loader-")
      defer: cleanup(host)
      let rc = newRecipeCompileCheck()
      defer: removeDir(rc.callerTmp)
      # The loader path holds a copy of a library the compiler loads (not the
      # C library), so a compile that received it loads that copy and the
      # record names it: the guard that the variable reached the command.
      let loaderDir = host.scratch / "loader-path"
      createDir(loaderDir)
      var placed = ""
      for (soname, path) in loaderNeeds(getEnv("REPRO_NIM_COMPILER")):
        var libcFamily = false
        for prefix in ["libc.", "libm.", "libdl.", "librt.", "libpthread.",
                       "ld-linux", "linux-vdso"]:
          if soname.startsWith(prefix): libcFamily = true
        if not libcFamily:
          copyFile(path, loaderDir / soname)
          placed = loaderDir / soname
          break
      checkpoint("loader path copy: " & placed)
      require placed.len > 0
      let project = host.scratch / "proj"
      writeOneEdgeProject(project)
      commitCheckout(project)
      let run = rc.buildProject(host, project,
        extraEnv = [("LD_LIBRARY_PATH", loaderDir)])
      require run.code == 0
      let records = rc.requireNoHostShell(host, project)
      # Vacuity guard: the compile ran with the loader path (the compiler
      # loaded the copy placed there).
      var sawLoaderCopy = false
      for record in records["provider"]:
        for input in record.inputs:
          # Relative to the recipe's directory when outside every anchor.
          let absolute =
            if input.path.isAbsolute: input.path
            else: normalizedPath(project / input.path)
          if absolute == placed:
            sawLoaderCopy = true
      check sawLoaderCopy

  test "a recipe compiled by a pinned upstream Nim names the host shell (a documented limit)":
    ## A project's lock may pin the Nim that compiles its recipe to an
    ## official release (`packageSource "nim", "store"`, `uses: "nim ==V"`).
    ## An upstream release starts the C compiler, the linker and every
    ## compile-time command through `/bin/sh -c`, so its recipe compiles
    ## record the host shell: the limit `docs/store-bundles.md` states for
    ## such a pin, and the reason `repro bundle create` warns about one.
    ## This case keeps that statement true. Should a pinned release stop
    ## starting the shell (the change offered upstream), it turns red, and
    ## the documented limit and the warning are to be revisited with it.
    ##
    ## A network case: `repro lock refresh` reads the release's digest from
    ## nim-lang.org, and the build downloads the source archive and builds
    ## it into this host's fresh store.
    when not defined(linux):
      skip("reads the host shell's closure from the glibc dynamic loader; " &
        "Linux only")
    else:
      var host = newSharedHost("repro-recipe-shell-pinned-nim-")
      defer: cleanup(host)
      let rc = newRecipeCompileCheck()
      defer: removeDir(rc.callerTmp)
      let project = host.scratch / "proj"
      writeOneEdgeProject(project, packageName = "shellprobepinned",
        head = "when NimVersion != \"" & PinnedUpstreamNim & "\":\n" &
          "  {.error: \"recipe compiled with Nim \" & NimVersion & \", not " &
          "the pinned " & PinnedUpstreamNim & "\".}\n")
      # The solver inputs the recipe states, read verbatim (`--inputs`):
      # before the first refresh there is no pin, and compiling the recipe
      # to find them would use another Nim, which the guard refuses.
      writeFile(project / "repro.solver",
        "package shellprobepinned\nversions: 0.1.0\ndepends: nim ==" &
        PinnedUpstreamNim & "\n\npackage nim\nversions: " &
        PinnedUpstreamNim & "\nsource: store\n")
      let refresh = host.reproRun(project, ["lock", "refresh", "--inputs",
        project / "repro.solver"])
      checkpoint("lock refresh, exit " & $refresh.code & ":\n" &
        refresh.output)
      require refresh.code == 0
      let pin = projectPinsFor(project).providerNim
      require pin.state == spsPinned
      require pin.archive.url.startsWith("https://nim-lang.org/download/")
      commitCheckout(project)
      var extra: seq[(string, string)] = @[]
      let cc = findExe("gcc")
      if cc.len > 0:
        # The bootstrap C compiler the source archive is built with, as
        # `t_a_pinned_nim_is_provisioned_from_a_cold_store` names it.
        extra.add(("REPRO_BOOTSTRAP_CC", cc))
      let run = rc.buildProject(host, project, extraEnv = extra)
      require run.code == 0
      # Vacuity guard: the pinned release compiled the recipe. The recipe's
      # own guard refuses every other Nim, and the build realized the pin
      # into this host's fresh store. (The records cannot show it: reads
      # under the compiler's own content-addressed prefix are keyed by its
      # identity rather than listed as inputs.)
      check not run.output.contains("recipe compiled with Nim")
      check fileExists(pinnedExecutableIn(providerNimPin(),
        selfPrefixAbsolutePath(host.storeRoot, pin)))
      let records = recipeCompileRecords(host.actionCacheRoot)
      for kind in ["provider", "interface"]:
        doAssert records.getOrDefault(kind).len > 0, "no " & kind & " record"
        var shellFiles: seq[string]
        for record in records[kind]:
          shellFiles.add(rc.hostShellInputs(record, project))
        checkpoint(kind & " inputs from the host shell: " & $shellFiles)
        # The documented limit: the host shell is among the inputs.
        check shellFiles.len > 0
