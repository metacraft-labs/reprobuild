## Spec-Implementation M3 — gcc-backed ``Toolchain`` default adapter.
##
## Per Reprobuild-Standard-Library §"Cross-Cutting Interfaces" /
## §"`Toolchain`", an adapter package supplies a populated
## ``Toolchain`` value to the active build context. The gcc adapter
## emits the canonical argv shape ``gcc -c <source> -o <output>
## <flags>`` for ``compile``; ``gcc <objects> -o <output> <flags>``
## for ``link``; and ``cp <binary> <archive>`` for
## ``archiveExecutable`` (the trivial native-host archive form). M5's
## cross-compilation worked example replaces this with a sysroot-aware
## variant; M3 ships the native host form.
##
## The adapter does NOT inspect the active ``CrossTarget``; it relies
## on the typed-tool wrapper layer (``gcc.nim``) to inject
## target-aware flags. This keeps the gcc adapter usable from both
## native and cross paths once the cross adapter overrides
## ``Toolchain.compile`` directly.

import std/tables

import ../interfaces/toolchain
export toolchain

proc gccCompile(source: string; output: string;
                flags: seq[string]): BuildAction =
  ## ``gcc -c <source> -o <output> <flags>``. The action-id encodes
  ## the source basename so the engine's cache key has a stable hook;
  ## the input/output sets reflect the literal paths.
  var argv = @["gcc", "-c", source, "-o", output]
  for f in flags:
    argv.add(f)
  BuildAction(
    actionId: "gcc-compile:" & source,
    argv: argv,
    inputs: @[source],
    outputs: @[output],
    env: initTable[string, string]())

proc gccLink(objects: seq[string]; output: string;
             flags: seq[string]): BuildAction =
  var argv = @["gcc"]
  for o in objects:
    argv.add(o)
  argv.add("-o")
  argv.add(output)
  for f in flags:
    argv.add(f)
  BuildAction(
    actionId: "gcc-link:" & output,
    argv: argv,
    inputs: objects,
    outputs: @[output],
    env: initTable[string, string]())

proc gccArchiveExecutable(binary: string; archive: string): BuildAction =
  BuildAction(
    actionId: "gcc-archive:" & archive,
    argv: @["cp", binary, archive],
    inputs: @[binary],
    outputs: @[archive],
    env: initTable[string, string]())

proc gccToolchain*(): Toolchain =
  ## The stdlib's default gcc-backed ``Toolchain``. Selected when the
  ## ``compiler`` variant resolves to ``"gcc"`` (the M3 default).
  newToolchain(
    name = "gcc-toolchain",
    cCompilerPath = "gcc",
    cxxCompilerPath = "g++",
    linkerPath = "gcc",
    defaultFlags = ToolchainFlags(
      pic: false,
      debug3: false,
      optimization: "O2",
      languageStandard: "c11"),
    compile = gccCompile,
    link = gccLink,
    archiveExecutable = gccArchiveExecutable)
