## Real TypeScript and Meson executions check output declarations against each
## tool's own emitted artifact set. No compiler or filesystem adapter is mocked.
import std/[algorithm, os, osproc, strutils, unittest]
import repro_standard_provider/conventions/javascript_typescript
import repro_standard_provider/conventions/output_discovery

proc run(argv: seq[string]): string =
  let outcome = execCmdEx(argv.quoteShellCommand())
  if outcome.exitCode != 0:
    raise newException(IOError, argv.quoteShellCommand() & "\n" & outcome.output)
  outcome.output

suite "delegated output discovery":
  test "TypeScript .mts .cts exclude noEmit and declaration-only match actual emit":
    let root = getTempDir() / "repro-ts-output-obligation"
    if dirExists(root): removeDir(root)
    createDir(root / "src")
    defer: removeDir(root)
    writeFile(root / "src/module.mts", "export const answer = 42;\n")
    writeFile(root / "src/common.cts", "export const answer = 42;\n")
    writeFile(root / "src/excluded.ts", "export const excluded = 0;\n")
    let config = root / "tsconfig.json"
    let output = root / "dist"
    let fragment = root / "outputs.dyndep"
    for mode in ["", ",\"noEmit\":true", ",\"emitDeclarationOnly\":true",
        ",\"incremental\":true", ",\"incremental\":true,\"noEmit\":true"]:
      if dirExists(output): removeDir(output)
      if fileExists(root / "tsconfig.tsbuildinfo"): removeFile(root / "tsconfig.tsbuildinfo")
      writeFile(config, "{\"compilerOptions\":{\"module\":\"NodeNext\",\"target\":\"ES2020\"" & mode &
        "},\"include\":[\"src/**/*\"],\"exclude\":[\"src/excluded.ts\"]}")
      discard run(@["npx", "--yes", "--package", "typescript@5.6", "node", "-e",
        TscOutputDiscoveryScript, config, output, root / "src", fragment, "[]"])
      var declared: seq[string]
      for line in readFile(fragment).splitLines():
        if line.startsWith("output\t"):
          declared.add(line.split('\t')[2])
      let log = run(@["npx", "--yes", "--package", "typescript@5.6", "tsc", "-p", config,
        "--outDir", output, "--rootDir", root / "src", "--declaration",
        "--declarationMap", "--listEmittedFiles"])
      var emitted: seq[string]
      for line in log.splitLines():
        if line.startsWith("TSFILE: "): emitted.add(line[8 .. ^1].strip())
      emitted.sort()
      declared.sort()
      checkpoint "mode=" & mode & "\n" & log
      check declared == emitted
      for path in declared:
        check fileExists(path)
        check not path.contains("excluded")
      if mode.contains("noEmit"):
        if mode.contains("incremental"):
          check declared.len == 1
          check declared[0].endsWith(".tsbuildinfo")
        else:
          check declared.len == 0
        check not dirExists(output)
      else:
        check output / "module.d.mts" in declared
        check output / "common.d.cts" in declared
        if not mode.contains("emitDeclarationOnly"):
          check output / "module.mjs" in declared
          check output / "common.cjs" in declared

  test "Meson target filenames include subdirectory prefix and suffix overrides":
    let root = getTempDir() / "repro-meson-output-obligation"
    if dirExists(root): removeDir(root)
    createDir(root / "child")
    defer: removeDir(root)
    writeFile(root / "meson.build", "project('outputs', 'c')\nsubdir('child')\n")
    writeFile(root / "child/meson.build", "static_library('hello', 'hello.c', name_prefix: 'custom-', name_suffix: 'archive')\n")
    writeFile(root / "child/hello.c", "int answer(void) { return 42; }\n")
    let build = root / "build"
    discard run(@["meson", "setup", build, root])
    let outputs = mesonTargetOutputs(build, "hello")
    require outputs.len == 1
    check outputs[0].endsWith("child/custom-hello.archive")
    discard run(@["meson", "compile", "-C", build, "-j", "2"])
    check fileExists(outputs[0])
