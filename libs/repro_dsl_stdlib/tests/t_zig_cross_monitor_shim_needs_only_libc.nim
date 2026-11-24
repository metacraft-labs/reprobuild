## A Linux monitor shim that `zig cc` links for a glibc target needs only
## `libc.so.6` and the loader, and reprobuild declares a zig that links it so.
##
## WHY. The shim is LD_PRELOADed into every monitored process, and its
## dependencies resolve through that process's search path, never its own.
## A program that finds its C runtime through DT_RUNPATH cannot resolve any
## further C-runtime library for it, so every build of the Linux shim must
## need `libc.so.6` and the loader and nothing else. io-mon's
## `linux_preload.nim.cfg` heads the link template with `-Wl,--as-needed`,
## which drops the `-lm -lrt -ldl -pthread` Nim adds -- for gcc, clang and
## zig 0.14 alike.
##
## zig 0.13 cannot link that shim. It hands the linker every glibc stub it
## has, in a fixed order with `libpthread.so.0`'s ahead of `libc.so.6`'s,
## whatever the command line says (`zig cc -v`). For glibc 2.34 and later
## both stubs define `pthread_mutex_lock` and the ten other symbols the shim
## calls, and the linker binds each symbol to the first library defining
## it, so `--as-needed` keeps `libpthread.so.0` and no link flag removes it
## (measured 2026-11-24 with io-mon `agents` `fd2f508`: zig 0.13.0 NEEDED
## `libpthread.so.0 libc.so.6 ld-linux-x86-64.so.2` for
## `x86_64-linux-gnu.2.38`; zig 0.14.1, 0.15.2 and 0.16.0 linking the same
## objects only libc and the loader). So `repro.nim` declares
## `zig >=0.14 <0.15` and the dev shell provides 0.14.
##
## THE CASES.
##
##   1. The shim, built the way `repro.nim`'s
##      `reprobuild.test_fixtures.monitor_shim` edge builds it under
##      `--target=armv7-unknown-linux-gnueabihf` (zig's
##      `arm-linux-gnueabihf.2.38`, the one glibc row of `cross_zig`), with
##      the zig on PATH. The edges are emitted in process, through the same
##      DSL calls the edge makes: `nim.c` threads the zig target (the
##      `cross_zig` wrapper edge, `--cpu:arm --os:linux`, clang pointed at
##      the wrapper) and `emitZigCrossVersionScriptAction` merges io-mon's
##      version script with the compiler-rt node. The inline-exec edges the
##      compile orders after are run as the engine runs them, then the
##      compile's argv as the engine renders it against the `nim` on PATH.
##      Its DT_NEEDED must be `libc.so.6` and `ld-linux-armhf.so.3`. Under
##      zig 0.13 on PATH this case fails with `libpthread.so.0` in the list
##      -- the issue's defect; with the dev shell's zig 0.14 it passes.
##   2. `repro.nim`'s own zig declaration excludes every 0.13 release, so a
##      solve that realizes zig for it (the stdlib `zig` package carries
##      0.14.1) never picks 0.13. Path mode does not hold the zig on PATH to
##      the range today: zig answers no `--version` probe, and a tool whose
##      probe reports no version is accepted (`pathToolVersionRangeRefusal`).
##      Case 1 is what catches a zig 0.13 on PATH.
##
## WHY NOT THE ENGINE'S OWN LOWERING. `tests/integration/
## t_preloaded_monitor_shim_carries_no_runpath.nim` replays the native edge
## from `repro graph .#test-fixtures`. The same graph under `--target` also
## resolves reprobuild's target libraries (`sqlite`, `libblake3`, `xxhash`,
## `openssl`), each of which must first be cross-built from the catalog, so
## it cannot be lowered on a host that has not built them. This case keeps
## the parts that decide the shim's DT_NEEDED -- the shim's source and
## defines, io-mon's link template, the version script, the wrapper and the
## zig on PATH -- and mirrors the edge's arguments; a change to that edge
## must be mirrored here (`repro.nim`, "The Linux shim exports a
## version-scripted, interposed dlsym"). One define is left out, and
## `emitShimEdge` says why.
##
## NO MOCKS: the real nim, the real `cross_zig` wrapper and zig, the real
## linker and io-mon's real shim source. Without zig, nim, readelf or an
## io-mon checkout the case skips with the reason, and fails in a gate run
## (`REPROBUILD_GATE_RUN=1`): the dev shell carries all of them.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip
import repro_project_dsl
import repro_cli_support
import repro_tool_profiles
import repro_dsl_stdlib/adapters/cross_zig
import repro_dsl_stdlib/operations/zig_c
import repro_dsl_stdlib/packages/nim as nim_module

const
  Glibc = "armv7-unknown-linux-gnueabihf"
  ShimFileName = "librepro_monitor_shim.so"

proc repoRoot(): string =
  ## `libs/repro_dsl_stdlib/tests/<this file>` -> the reprobuild checkout.
  currentSourcePath().parentDir.parentDir.parentDir.parentDir

proc siblingSrc(envName, sibling: string): string =
  ## A source root the way the build scripts resolve it: the environment
  ## override (the dev shell sets these to the pinned store paths), else the
  ## sibling checkout's `src`.
  result = getEnv(envName)
  if result.len == 0:
    result = repoRoot().parentDir / sibling / "src"

proc ioMonSrc(): string = siblingSrc("IO_MON_SRC", "io-mon")

proc zigOnPathVersion(): string =
  let (version, code) = execCmdEx("zig version")
  if code != 0: "" else: version.strip()

proc toolMissing(): string =
  ## Why the shim case cannot run here, or "" when it can.
  when not defined(linux):
    return "the Linux shim is built on a Linux host"
  if findExe("zig").len == 0: return "zig is not on PATH"
  if findExe("nim").len == 0: return "nim is not on PATH"
  if findExe("readelf").len == 0: return "readelf is not on PATH"
  if not fileExists(ioMonSrc() / "io_mon" / "shim" / "linux_preload.nim"):
    return "no io-mon source at " & ioMonSrc() &
      "; set IO_MON_SRC or check out io-mon beside this repository"
  ""

template requireTools(body: untyped) =
  let missing = toolMissing()
  if missing.len > 0:
    if getEnv("REPROBUILD_GATE_RUN") == "1":
      checkpoint(missing & " in a gate run")
      check false
    else:
      skip(missing)
  else:
    body

package zigMonitorShimFixture:
  nativeBuildDeps:
    # The range `repro.nim` declares (case 2 holds it there); `nim.c` under a
    # zig target refuses a package that declares no zig.
    "zig >=0.14 <0.15"

proc inlineArgv(act: BuildActionDef): seq[string] =
  ## The argv of an inline-exec action (`sh -c <script>`).
  for arg in act.call.arguments:
    if arg.name == "argv":
      return arg.encodedValue.split('\x1f')

proc run(argv: seq[string]; dir: string;
         env: openArray[(string, string)] = []):
    tuple[output: string, code: int] =
  ## `argv` in `dir`, this process's environment plus `env`, with zig's
  ## caches inside `dir`.
  var cmd = "env ZIG_GLOBAL_CACHE_DIR=" & quoteShell(dir / "zig-global") &
    " ZIG_LOCAL_CACHE_DIR=" & quoteShell(dir / "zig-local")
  for (k, v) in env:
    cmd.add(" " & quoteShell(k & "=" & v))
  cmd.add(" " & quoteShellCommand(argv))
  let r = execCmdEx(cmd, workingDir = dir)
  (r.output, r.exitCode)

proc neededOf(file: string): seq[string] =
  ## The DT_NEEDED sonames of `file`, in order.
  let (output, _) = execCmdEx("readelf -d -W " & quoteShell(file))
  for line in output.splitLines:
    if "(NEEDED)" in line:
      let start = line.find('[')
      let stop = line.rfind(']')
      if start >= 0 and stop > start:
        result.add line[start + 1 ..< stop]

proc emitShimEdge(dir: string): BuildActionDef =
  ## The monitor-shim compile `repro.nim` emits under `--target=<Glibc>`,
  ## in a fresh registry, with the version-script edge it orders after.
  ## Mirrors `repro.nim` (`linuxShimDefines(triple)` & `release` less
  ## `ioMonGlibcPrivateHeap`, the `--strip-debug` / soname `passL`, the
  ## merged version script).
  let saved = getEnv("REPRO_VARIANTS")
  putEnv("REPRO_VARIANTS", "targetTriple=" & Glibc)
  try:
    resetBuildActionRegistry()
    resetTargetExportRegistry()
    let state = beginBuildBlock("zigMonitorShimFixture")
    try:
      let target = activeZigCrossTarget()
      require target != nil
      let versionScript = emitZigCrossVersionScriptAction(dir,
        "zigMonitorShimFixture", Glibc,
        ioMonSrc() / "io_mon" / "hooks" / "linux_preload_versions.map",
        targetKeyedPath("build/lib/librepro_monitor_shim.versions.map"))
      result = nim.c(
        source = ioMonSrc() / "io_mon" / "shim" / "linux_preload.nim",
        # `repro.nim` also passes `ioMonGlibcPrivateHeap` for a glibc row
        # (`linuxShimDefines`). It is left out here: its
        # `-Wl,--wrap=malloc,...` is refused by every zig from 0.13 to 0.16
        # (`unsupported linker arg: --wrap`), so with it the link fails
        # before any library is NEEDED -- a separate defect. It adds no
        # library to the link either way.
        defines = @["useMalloc", "release"],
        binary = "build/lib/" & ShimFileName,
        appLib = true,
        threadsOn = true,
        paths = @[ioMonSrc(),
          siblingSrc("STACKABLE_HOOKS_SRC", "nim-stackable-hooks"),
          siblingSrc("SHM_GSET_SRC", "nim-shm-gset")],
        passL = @["-Wl,--version-script=" & versionScript.outputs[0],
          "-Wl,--strip-debug", "-Wl,-soname," & ShimFileName],
        extraInputs = @[versionScript.outputs[0]],
        after = @[versionScript],
        nimcache = "build/nimcache/repro_monitor_shim")
    finally:
      endBuildBlock(state)
  finally:
    if saved.len > 0: putEnv("REPRO_VARIANTS", saved)
    else: delEnv("REPRO_VARIANTS")

suite "a zig-linked monitor shim needs only the C runtime":

  test "under the glibc zig target the shim needs libc.so.6 and the loader alone":
    requireTools:
      let dir = createTempDir("zig-monitor-shim-", "")
      defer: removeDir(dir)
      let zigVersion = zigOnPathVersion()
      checkpoint("zig on PATH: " & findExe("zig") & " " & zigVersion)
      let saved = getCurrentDir()
      setCurrentDir(dir)
      try:
        let shim = emitShimEdge(dir)
        check shim.deps.anyIt(it.startsWith("zig-cross-wrappers-"))
        # The edges the compile orders after: the `cross_zig` wrappers and
        # the merged version script, both inline execs. Run as the engine
        # runs them: each after its own dependencies, with its outputs'
        # directories created first.
        var done: seq[string]
        proc runDeps(id: string) =
          for act in registeredBuildActions():
            if act.id == id:
              for dep in act.deps:
                if dep notin done: runDeps(dep)
              if id != shim.id:
                let argv = inlineArgv(act)
                require argv.len > 0
                for output in act.outputs:
                  createDir(parentDir(dir / output))
                let r = run(argv, dir)
                if r.code != 0: checkpoint(act.id & ":\n" & r.output)
                require r.code == 0
              done.add(id)
        runDeps(shim.id)
        for output in shim.outputs:
          createDir(parentDir(dir / output))
        let argv = argvForCall(shim.call,
          PathOnlyToolProfile(resolvedExecutablePath: findExe("nim")))
        checkpoint(argv.join(" "))
        # The edge's own environment (`shimLinkEnvironment()` and the Nim
        # user configuration of a target build, in `repro.nim`).
        let r = run(argv, dir, [("NIX_DONT_SET_RPATH", "1"),
          ("NIX_LDFLAGS", ""),
          ("XDG_CONFIG_HOME", repoRoot() / "scripts" / "cross" /
            "nim-user-config")])
        if r.code != 0: checkpoint(r.output)
        require r.code == 0
        require shim.outputs.len > 0
        let lib = dir / shim.outputs[0]
        require fileExists(lib)
        let needed = neededOf(lib)
        checkpoint("NEEDED (zig " & zigVersion & "): " & needed.join(" "))
        check "libc.so.6" in needed
        # zig 0.13 binds the shim's pthread symbols to libpthread.so.0; see
        # the module comment.
        check "libpthread.so.0" notin needed
        check needed == @["libc.so.6", "ld-linux-armhf.so.3"]
      finally:
        setCurrentDir(saved)

  test "repro.nim's zig declaration excludes zig 0.13":
    # The one `"zig >=<a>.<b> <<c>.<d>"` entry of the manifest.
    var floors: seq[string]
    for line in readFile(repoRoot() / "repro.nim").splitLines:
      let entry = line.strip()
      if entry.startsWith("\"zig >=") and entry.endsWith("\""):
        floors.add(entry[len("\"zig >=") ..< entry.len - 1])
    checkpoint("repro.nim declares zig >=" & floors.join(" | >="))
    require floors.len == 1
    let parts = floors[0].split(' ')[0].split('.')
    require parts.len >= 2
    # A floor of 0.14 or later leaves every 0.13.x outside the range.
    check (parseInt(parts[0]), parseInt(parts[1])) >= (0, 14)
