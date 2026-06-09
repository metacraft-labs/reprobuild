## Spec-Implementation M3 — clang-backed ``Toolchain`` default adapter.
##
## Same shape as ``gcc_toolchain.nim``: argv is ``clang -c <source>
## -o <output> <flags>``. Selected when the ``compiler`` variant
## resolves to ``"clang"``.

import std/tables

import ../interfaces/toolchain
export toolchain

proc clangCompile(source: string; output: string;
                  flags: seq[string]): BuildAction =
  var argv = @["clang", "-c", source, "-o", output]
  for f in flags:
    argv.add(f)
  BuildAction(
    actionId: "clang-compile:" & source,
    argv: argv,
    inputs: @[source],
    outputs: @[output],
    env: initTable[string, string]())

proc clangLink(objects: seq[string]; output: string;
               flags: seq[string]): BuildAction =
  var argv = @["clang"]
  for o in objects:
    argv.add(o)
  argv.add("-o")
  argv.add(output)
  for f in flags:
    argv.add(f)
  BuildAction(
    actionId: "clang-link:" & output,
    argv: argv,
    inputs: objects,
    outputs: @[output],
    env: initTable[string, string]())

proc clangArchiveExecutable(binary: string; archive: string): BuildAction =
  BuildAction(
    actionId: "clang-archive:" & archive,
    argv: @["cp", binary, archive],
    inputs: @[binary],
    outputs: @[archive],
    env: initTable[string, string]())

proc clangToolchain*(): Toolchain =
  ## The stdlib's default clang-backed ``Toolchain``. Selected when
  ## the ``compiler`` variant resolves to ``"clang"``.
  newToolchain(
    name = "clang-toolchain",
    cCompilerPath = "clang",
    cxxCompilerPath = "clang++",
    linkerPath = "clang",
    defaultFlags = ToolchainFlags(
      pic: false,
      debug3: false,
      optimization: "O2",
      languageStandard: "c11"),
    compile = clangCompile,
    link = clangLink,
    archiveExecutable = clangArchiveExecutable)
