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
## WHAT IS "THE HOST SHELL'S CLOSURE". The files the dynamic loader maps to
## start `/bin/sh` on this host (`LD_TRACE_LOADED_OBJECTS=1 /bin/sh`, read
## by the loader itself, plus the shell binary), less any file of a Nix store
## path the toolchain's own closure holds: a file the compiler or the C
## toolchain needs for itself is the toolchain's input, whatever else uses
## it. The toolchain is the closure (`nix-store -qR`) of every store path the
## provider compile's command names and of the Nim compiler it runs.
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
## Falsifying mutation: `REPRO_NIM_COMPILER` naming a Nim compiler that
## starts the C compiler through `/bin/sh -c` (the pinned compiler before
## the fix) turns it red, naming the shell's C library, readline and
## ncurses.
##
## NO MOCKS: the built `repro`, the pinned Nim compiler and C toolchain, the
## real monitor and action cache; the shell's closure is read from the
## host's dynamic loader.

import std/[os, osproc, sets, strutils, tables, tempfiles, unittest]

import repro_hash
import repro_local_store
import repro_interface_artifacts
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

suite "recipe compiles do not record the host shell":
  test "the provider compile and the interface extraction name no file of /bin/sh":
    when not defined(linux):
      skip("reads the host shell's closure from the glibc dynamic loader; " &
        "Linux only")
    else:
      var host = newSharedHost("repro-recipe-shell-")
      defer: cleanup(host)
      if getEnv("REPRO_NIM_COMPILER").len == 0:
        let nim = findExe("nim")
        if nim.len > 0: putEnv("REPRO_NIM_COMPILER", expandFilename(nim))
      checkpoint("REPRO_NIM_COMPILER=" & getEnv("REPRO_NIM_COMPILER"))
      # The compiler is the pinned one from the Nix store.
      require getEnv("REPRO_NIM_COMPILER").startsWith("/nix/store/")
      let toolchain = nixClosure(toolchainPaths())
      var shellOnly = initHashSet[string]()
      for f in loaderClosure("/bin/sh"):
        let sp = storePathOf(f)
        if sp.len == 0 or sp notin toolchain:
          shellOnly.incl(f)
      checkpoint("the host shell's closure, less the toolchain's: " &
        $shellOnly)
      # Vacuity guard: there is something to tell apart.
      require shellOnly.len > 0

      let project = host.scratch / "proj"
      createDir(project / "src")
      writeFile(project / "src" / "in.txt", "in\n")
      writeFile(project / "repro.nim", """import std/os
import repro_project_dsl

package shellprobe:
  build:
    let root = activeProviderProjectRoot()
    let src = root / "src/in.txt"
    let outp = root / "out/o.txt"
    createDir(outp.parentDir)
    let a = buildAction(id = "shellprobe-copy",
      call = inlineExecCall(@["cp", src, outp], root),
      inputs = @[src], outputs = @[outp],
      dependencyPolicy = automaticMonitorPolicy())
    defaultBuildAction(a)
""")
      commitCheckout(project)
      # Without `LD_LIBRARY_PATH`, as the installed package runs (its wrapper
      # sets none; the dev shell does). With a loader path in an action's
      # environment the engine starts the monitored payload through a
      # `/bin/sh` that exports it (`deferRuntimeLibraryEnvForShell`), a
      # separate host-shell input of every such action; this test is about
      # what the compile itself starts.
      #
      # And with a `TMPDIR` of its own, as a Nix dev shell makes one per shell
      # (`mktemp -d`): another shell or machine has another, so nothing of it
      # may be an input.
      let callerPath = getEnv("PATH")
      let callerTmp = createTempDir("repro-recipe-shell-tmpdir-", "")
      defer: removeDir(callerTmp)
      let run = host.build(project, portable = false,
        extraEnv = [("TMPDIR", callerTmp)],
        dropEnv = ["LD_LIBRARY_PATH"])
      checkpoint("build output:\n" & run.output)
      require run.code == 0

      let records = recipeCompileRecords(host.actionCacheRoot)
      for kind in ["provider", "interface"]:
        checkpoint("records of " & kind & ": " &
          $records.getOrDefault(kind).len)
        # Vacuity guard: the edge ran and recorded what it read.
        require records.getOrDefault(kind).len > 0
        for record in records[kind]:
          check record.inputs.len > 100
          var sawCompiler = false
          var offending, inCallerTmp: seq[string]
          for input in record.inputs:
            if "-nim-" in input.path or "/nim-" in input.path:
              sawCompiler = true
            # A relocatable record names its inputs relative to the recipe's
            # directory, the edge's working directory.
            let absolute =
              if input.path.isAbsolute: input.path
              else: normalizedPath(project / input.path)
            let resolved =
              if fileExists(absolute): expandFilename(absolute)
              else: absolute
            if absolute == "/bin/sh" or absolute in shellOnly or
                resolved in shellOnly:
              offending.add(input.path)
            if absolute == callerTmp or absolute.startsWith(callerTmp & "/"):
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
              check e.value != callerPath
              for dir in e.value.split(PathSep):
                check dir.startsWith("/nix/store/")
          checkpoint(kind & " inputs from the host shell: " & $offending)
          check offending.len == 0
