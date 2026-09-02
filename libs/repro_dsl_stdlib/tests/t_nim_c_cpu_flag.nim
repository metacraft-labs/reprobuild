## A cross-bitness `nim c` must be expressible in the DSL.
##
## Windows process monitoring needs a 32-bit shim and a 32-bit WOW64 probe
## staged beside the 64-bit shim, because a 64-bit shim cannot be injected
## into a 32-bit child at all. `nim.c` had no `cpu` parameter, so neither
## artefact could be a graph edge: the only way to produce them was to shell
## out to `io-mon/scripts/build_shim.sh`, and a `sh.shell` edge is neither
## cacheable nor described by the graph. They were consequently not built at
## all, and existed on the developer's host only because they had been copied
## there by hand after each run of that script.
##
## `gccLinkerExe` is tested alongside `cpu` because the two are only useful
## together. `--gcc.exe:` selects the COMPILER driver; nim keeps invoking
## whatever `gcc.linkerexe` names for the link step, so an edge that sets only
## `gccExe` compiles 32-bit objects and then hands them to the host's 64-bit
## linker.
##
## The assertions read the rendered ARGV rather than the wrapper's parameters,
## because the parameters are not the contract: nim only does what it is told
## on the command line, and the whole class of bug this initiative chased is a
## disagreement between what a recipe declares and what the tool is asked to
## do.

import std/[os, strutils, unittest]

import repro_project_dsl
# Imported under an alias on purpose: the `package nim:` block inside that
# module emits a const named `nim`, and a plain `import` would shadow it with
# the module name and break `nim.c(...)` resolution -- the same reason
# reprobuild's own `repro.nim` reaches the const through the `uses:` pass.
import repro_dsl_stdlib/packages/nim as nim_module

const nimTool = nim_module.nim

proc argvOf(act: BuildActionDef): seq[string] =
  ## Render the recorded CLI call the way the engine does: a `concat` flag
  ## joins its alias to its value, a bool flag contributes its alias alone,
  ## a positional contributes its value alone, and a `repeated` seq flag
  ## contributes one occurrence per element (`cliArgSeq` packs them into a
  ## single `\x1f`-joined `encodedValue`).
  for arg in act.call.arguments:
    var values = @[arg.encodedValue]
    if arg.nimType == "seq[string]":
      values = arg.encodedValue.split('\x1f')
      if values.len == 1 and values[0].len == 0:
        values = @[]
    for value in values:
      case arg.format
      of cafConcat:
        result.add(arg.alias & value)
      else:
        if arg.alias.len == 0:
          result.add(value)
        elif arg.nimType == "bool":
          result.add(arg.alias)
        else:
          result.add(arg.alias)
          result.add(value)

proc hasArg(act: BuildActionDef; wanted: string): bool =
  wanted in argvOf(act)

proc anyArgStartingWith(act: BuildActionDef; prefix: string): bool =
  for value in argvOf(act):
    if value.startsWith(prefix):
      return true
  false

suite "nim.c can express a cross-bitness compile":

  test "cpu = \"i386\" reaches argv as --cpu:i386":
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "shim.nim",
      binary = "build" / "lib" / "cpu_flag_shim32.dll",
      appLib = true,
      cpu = "i386")
    check hasArg(act, "--cpu:i386")

  test "an omitted cpu emits no --cpu: at all":
    # The default must stay invisible: every existing edge in every recipe
    # goes through this same wrapper, and a `--cpu:` naming the host would
    # change their argv -- and therefore their action fingerprint -- for
    # nothing, invalidating every cached nim edge in the tree.
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "host.nim",
      binary = "build" / "lib" / "cpu_flag_host.dll",
      appLib = true)
    check not anyArgStartingWith(act, "--cpu:")

  test "gccExe and gccLinkerExe are emitted independently":
    resetBuildActionRegistry()
    let i686 = "D:" / "toolchains" / "mingw32" / "bin" / "gcc.exe"
    let act = nimTool.c(
      source = "src" / "shim.nim",
      binary = "build" / "lib" / "cpu_flag_both32.dll",
      appLib = true,
      cpu = "i386",
      cc = "gcc",
      gccExe = i686,
      gccLinkerExe = i686)
    check hasArg(act, "--cc:gcc")
    check hasArg(act, "--gcc.exe:" & i686)
    check hasArg(act, "--gcc.linkerexe:" & i686)

  test "an omitted gccLinkerExe emits no --gcc.linkerexe:":
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "plain.nim",
      binary = "build" / "lib" / "cpu_flag_plain.dll",
      appLib = true,
      cc = "gcc")
    check not anyArgStartingWith(act, "--gcc.linkerexe:")

  test "the 32-bit shim's link flags survive verbatim":
    # `-Wl,--kill-at` is the one flag whose absence is invisible. 32-bit
    # mingw decorates stdcall exports with the callee's argument-byte count,
    # so `repro_runtime_init` ships as `repro_runtime_init@4` while every
    # lookup asks for the undecorated name. LoadLibraryW still succeeds, the
    # shim sits in the child with no hooks installed, and the run reports no
    # records at all while still grading complete.
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "shim.nim",
      binary = "build" / "lib" / "cpu_flag_kill_at32.dll",
      appLib = true,
      cpu = "i386",
      passL = @["-static-libgcc", "-Wl,--kill-at"])
    check hasArg(act, "--passL:-static-libgcc")
    check hasArg(act, "--passL:-Wl,--kill-at")

  test "a 32-bit executable edge still declares exactly one .exe":
    # The WOW64 probe is an executable, and Windows nim appends `.exe`
    # regardless of what `--out:` says. The recipe spells the extension, so
    # the suffixing must not fire a second time and declare `...exe.exe`:
    # a declared output that never comes into existence is precisely what
    # made every nim executable edge on Windows uncacheable.
    resetBuildActionRegistry()
    let staged = "build" / "lib" / "stackable_hooks_wow64_probe32.exe"
    let act = nimTool.c(
      source = "tools" / "wow64_proc_probe.nim",
      binary = staged,
      cpu = "i386")
    check act.outputs == @[staged]
    check hasArg(act, "--out:" & staged)

  test "a cpu-varying edge carries the nimcache the recipe named":
    # Two bitnesses sharing one nimcache would link 32-bit objects into a
    # 64-bit image: nim keys the cache directory by nothing but the path it
    # is handed. The wrapper must therefore pass a recipe-supplied nimcache
    # through unchanged rather than deriving a cpu-independent default.
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "shim.nim",
      binary = "build" / "lib" / "cpu_flag_cache32.dll",
      appLib = true,
      cpu = "i386",
      nimcache = "build" / "nimcache" / "cpu_flag_cache32")
    check hasArg(act,
      "--nimcache:" & ("build" / "nimcache" / "cpu_flag_cache32"))

  test "two bitnesses of one source produce two distinct argvs":
    # The end state S1 needs: the SAME source compiled twice, differing only
    # in cpu/toolchain/output, so the graph owns both artefacts.
    resetBuildActionRegistry()
    let source = "src" / "io_mon" / "shim" / "windows_interpose.nim"
    let i686 = "D:" / "toolchains" / "mingw32" / "bin" / "gcc.exe"
    let shim64 = nimTool.c(
      source = source,
      binary = "build" / "lib" / "librepro_monitor_shim.dll",
      appLib = true,
      threadsOn = true,
      nimcache = "build" / "nimcache" / "repro_monitor_shim")
    let shim32 = nimTool.c(
      source = source,
      binary = "build" / "lib" / "librepro_monitor_shim32.dll",
      appLib = true,
      threadsOn = true,
      mm = "orc",
      cpu = "i386",
      cc = "gcc",
      gccExe = i686,
      gccLinkerExe = i686,
      passL = @["-static-libgcc", "-Wl,--kill-at"],
      nimcache = "build" / "nimcache" / "repro_monitor_shim32")
    check shim64.id != shim32.id
    check shim64.outputs != shim32.outputs
    check not anyArgStartingWith(shim64, "--cpu:")
    check hasArg(shim32, "--cpu:i386")
    check hasArg(shim32, "--gcc.linkerexe:" & i686)
