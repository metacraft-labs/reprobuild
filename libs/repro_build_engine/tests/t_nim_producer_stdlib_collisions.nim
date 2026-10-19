## Exercise the real compiler and the engine's production producer validation.
## No mocks: poison modules must be rejected before they replace stdlib, while
## valid siblings and consumer paths compile unchanged. The shell wrapper is a
## real forwarding compiler, testing installations without a sibling lib/.
## The ambient compiler is intentional: it is the development-shell toolchain.
import std/[compilesettings, os, strutils, tempfiles, unittest]
import repro_build_engine
import repro_core/ambient_execution

proc compile(argv: seq[string]; cwd: string): int =
  let execution = uncontrolledExecCmdEx(argv.quoteShellCommand, workingDir = cwd)
  checkpoint(execution.output)
  execution.exitCode

proc refusal(argv: seq[string]; roots: seq[string]): string =
  try:
    discard applyNimPathArgs(argv, roots)
  except BuildEngineError as error:
    return error.msg

suite "Nim producer standard module protection":
  test "reject reserved namespace and bare standard module collisions":
    let nim = uncontrolledFindExe("nim")
    require nim.len > 0
    let scratch = createTempDir("nim-producer-collision-", "")
    defer: removeDir(scratch)
    let producer = scratch / "producer with spaces"
    createDir(producer / "std")
    let source = scratch / "app.nim"
    writeFile(source, "import std/objectdollar, strutils\n")
    writeFile(producer / "std/objectdollar.nim",
      "{.error: \"producer replaced std/objectdollar\".}\n")
    let argv = @[nim, "c", "--hints:off", "--compileOnly:on",
      "--nimcache:" & (scratch / "cache"), source]
    # Positive failure control: the original projection really selects poison.
    let control = uncontrolledExecCmdEx((@[nim, "c", "--path:" & producer] &
      argv[2 .. ^1]).quoteShellCommand, workingDir = scratch)
    checkpoint(control.output)
    check control.exitCode != 0
    check control.output.contains("producer replaced std/objectdollar")
    let namespaceRefusal = refusal(argv, @[producer])
    check namespaceRefusal.contains("reserved standard-library module namespace std")
    check namespaceRefusal.contains(producer)
    removeDir(producer / "std")
    writeFile(producer / "strutils.nim",
      "{.error: \"producer replaced strutils\".}\n")
    let bareRefusal = refusal(argv, @[producer])
    check bareRefusal.contains("collides with standard-library module")
    check bareRefusal.contains("strutils.nim")
    removeFile(producer / "strutils.nim")
    writeFile(producer / "greetlib.nim", "const greeting* = \"sibling\"\n")
    writeFile(producer / "chosen.nim", "const choice* = \"producer\"\n")
    let consumer = scratch / "consumer"
    createDir(consumer)
    writeFile(consumer / "chosen.nim", "const choice* = \"consumer\"\n")
    writeFile(source, """
import greetlib, chosen
import std/objectdollar, strutils
static:
  doAssert greeting == "sibling"
  doAssert choice == "consumer"
  doAssert "standard".toUpperAscii == "STANDARD"
""")
    let validArgv = @[nim, "c", "--path:" & consumer, "--noNimblePath"] & argv[2 .. ^1]
    check compile(applyNimPathArgs(validArgv, @[producer]), scratch) == 0
    # The reservation is independent of whether this action imports a sibling.
    writeFile(producer / "os.nim", "{.error: \"producer replaced os\".}\n")
    writeFile(source, "import std/os\n")
    check refusal(argv, @[producer]).contains("os.nim")

  test "honor explicit library roots and preserve original path flags":
    let nim = uncontrolledFindExe("nim")
    require nim.len > 0
    let scratch = createTempDir("nim-producer-selected-lib-", "")
    defer: removeDir(scratch)
    let producer = scratch / "producer"
    createDir(producer)
    writeFile(producer / "selectedlib.nim", "const selectedLibrary* = false\n")
    const compilerLib = querySetting(SingleValueSetting.libPath)
    let customLib = scratch / "custom standard library"
    copyDir(compilerLib, customLib)
    writeFile(customLib / "selectedlib.nim", "const selectedLibrary* = true\n")
    let argv = @[nim, "c", "--lib:" & customLib, "app.nim"]
    let selectedRefusal = refusal(argv, @[producer])
    check selectedRefusal.contains("selectedlib.nim")
    check selectedRefusal.contains(customLib)
    check refusal(@[nim, "c", "--lib:$unknown/custom", "app.nim"],
      @[producer]).contains("unsupported --lib substitution")
    check refusal(@[nim, "c", "--lib:$nimble/custom", "app.nim"],
      @[producer]).contains("unsupported --lib substitution")
    removeFile(producer / "selectedlib.nim")
    writeFile(producer / "greetlib.nim", "const greeting* = true\n")
    writeFile(customLib / "pure/selectedlib.nim", "const selectedLibrary* = true\n")
    writeFile(scratch / "config.nims", "switch(\"lib\", " & customLib.escape &
      ")\nswitch(\"noNimblePath\")\n")
    let source = scratch / "app.nim"
    writeFile(source, "import greetlib, std/selectedlib\n" &
      "static: doAssert greeting and selectedLibrary\n")
    let configured = @[nim, "c", "--hints:off", "--compileOnly:on",
      "--nimcache:" & (scratch / "configured-cache"), source]
    check compile(applyNimPathArgs(configured, @[producer]), scratch) == 0
    removeFile(producer / "greetlib.nim")
    let prefix = @["repro", "internal", "io", "monitor", "--", "nim", "c"]
    check applyNimPathArgs(prefix & @["--path:consumer", "app.nim"],
      @[producer]) == prefix & @["--excludePath:" & producer,
        "--excludePath:consumer", "--path:" & producer, "--path:consumer", "app.nim"]
    check applyNimPathArgs(prefix & @["app.nim", "--path:runtime-only"],
      @[producer]) == prefix & @["--excludePath:" & producer,
        "--path:" & producer, "app.nim", "--path:runtime-only"]
    for command in [@["nim", "c"], prefix]:
      check applyNimPathArgs(command & @["app.nim", "--", "runtime"],
        @[producer]) == command & @["--excludePath:" & producer,
          "--path:" & producer, "app.nim", "--", "runtime"]
    check applyNimPathArgs(@["clang", "-c", "app.c"], @[producer]) ==
      @["clang", "-c", "app.c"]
    check applyNimPathArgs(@["nim", "c", "app.nim"], @[]) ==
      @["nim", "c", "app.nim"]

  test "selected producer roots outrank stale config without bypassing it":
    let nim = uncontrolledFindExe("nim")
    require nim.len > 0
    let scratch = createTempDir("nim-producer-config-precedence-", "")
    defer: removeDir(scratch)
    let producer = scratch / "selected producer"
    let stale = scratch / "stale producer"
    let consumer = scratch / "consumer modules"
    let earlier = scratch / "earlier consumer modules"
    for root in [producer, stale, consumer, earlier]: createDir(root)
    writeFile(earlier / "chosen.nim", "const choice* = \"earlier\"\n")
    writeFile(producer / "propagation.nim",
      "proc resolveSipReplacement*(): string = \"selected revision\"\n")
    writeFile(stale / "propagation.nim", "proc oldApi*() = discard\n")
    writeFile(producer / "chosen.nim", "const choice* = \"producer\"\n")
    writeFile(consumer / "chosen.nim", "const choice* = \"consumer\"\n")
    let marker = scratch / "config-executed"
    writeFile(scratch / "config.nims", "import std/os\n" &
      "switch(\"path\", " & consumer.escape & ")\n" &
      "switch(\"path\", " & producer.escape & ")\n" &
      "switch(\"path\", " & stale.escape & ")\n" &
      "writeFile(" & marker.escape & ", \"configured\")\n")
    let source = scratch / "app.nim"
    writeFile(source, "import propagation, chosen\nstatic:\n" &
      "  doAssert resolveSipReplacement() == \"selected revision\"\n" &
      "  doAssert choice == \"consumer\"\n")
    let tail = @["--hints:off", "--compileOnly:on",
      "--nimcache:" & (scratch / "cache"), source]
    # This is the original projection, not a mocked resolver: the compiler
    # actually imports the stale module and names the missing newer API.
    let control = uncontrolledExecCmdEx((@[nim, "c", "--path:" & producer,
      "--path:" & consumer] & tail).quoteShellCommand, workingDir = scratch)
    checkpoint(control.output)
    check control.exitCode != 0
    check control.output.contains("undeclared identifier: 'resolveSipReplacement'")
    check readFile(marker) == "configured"
    var pathCases: seq[seq[string]]
    for spelling in ["--path:", "--path=", "-p:", "-p=", "--Path:", "--p_a_t_h:"]:
      pathCases.add(@[spelling & consumer])
    pathCases.add(@["--path:" & earlier, "--path:" & consumer,
      "--path:" & earlier])
    for paths in pathCases:
      removeFile(marker)
      let argv = @[nim, "c"] & paths & tail
      check compile(applyNimPathArgs(argv, @[producer]), scratch) == 0
      check readFile(marker) == "configured"

  when defined(posix):
    test "resolve compiler symlinks and wrappers without evaluating config":
      let nim = uncontrolledFindExe("nim")
      require nim.len > 0
      let scratch = createTempDir("nim-producer-wrapper-", "")
      defer: removeDir(scratch)
      let producer = scratch / "producer"
      createDir(producer)
      writeFile(producer / "greetlib.nim", "const greeting* = true\n")
      let source = scratch / "app.nim"
      writeFile(source, "import greetlib\nstatic: doAssert greeting\n")
      let marker = scratch / "config-ran"
      writeFile(scratch / "config.nims", "import std/os\nswitch(\"noNimblePath\")\n" &
        "writeFile(" & marker.escape & ", (if fileExists(" & marker.escape &
        "): readFile(" & marker.escape & ") else: \"\") & \"x\")\n")
      let linkDir = scratch / "symlink-bin"
      createDir(linkDir)
      createSymlink(nim, linkDir / "nim")
      let wrapperDir = scratch / "wrapper-bin"
      createDir(wrapperDir)
      let wrapper = wrapperDir / "nim"
      writeFile(wrapper, "#!/bin/sh\nexec " & nim.quoteShell & " \"$@\"\n")
      setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
      for compilerDir in [linkDir, wrapperDir]:
        let argv = @["nim", "c", "--hints:off", "--compileOnly:on",
          "--nimcache:" & (scratch / "cache"), source]
        let projected = applyNimPathArgs(argv, @[producer],
          @["PATH=" & compilerDir], scratch)
        check not fileExists(marker)
        var runnable = projected
        runnable[0] = compilerDir / "nim"
        check compile(runnable, scratch) == 0
        check readFile(marker) == "x"
        removeFile(marker)

      # Split-layout installations keep their library below lib/nim/lib;
      # $nim still denotes the executable prefix, not the library parent.
      let splitPrefix = scratch / "split-install"
      createDir(splitPrefix / "bin")
      createDir(splitPrefix / "lib/nim")
      copyFile(nim.expandFilename(), splitPrefix / "bin/nim")
      setFilePermissions(splitPrefix / "bin/nim", {fpUserRead, fpUserWrite, fpUserExec})
      const compilerLib = querySetting(SingleValueSetting.libPath)
      createSymlink(compilerLib, splitPrefix / "lib/nim/lib")
      createDir(splitPrefix / "custom-library")
      writeFile(splitPrefix / "custom-library/selectedlib.nim", "discard\n")
      writeFile(producer / "selectedlib.nim", "discard\n")
      let splitRefusal = refusal(@[splitPrefix / "bin/nim", "c",
        "--lib:$nim/custom-library", source], @[producer])
      check splitRefusal.contains("collides with standard-library module")
      check splitRefusal.contains(splitPrefix / "custom-library/selectedlib.nim")
      removeFile(producer / "selectedlib.nim")

      # Alias directories must each be inspected, while an ancestor cycle
      # must terminate. Only pure/os collides; harmless/os does not.
      let shared = scratch / "shared"
      createDir(shared)
      writeFile(shared / "os.nim", "const externalModule* = true\n")
      createSymlink(shared, producer / "harmless")
      createSymlink(shared, producer / "pure")
      createSymlink(shared, shared / "cycle")
      check refusal(@[nim, "c", source], @[producer]).contains("os.nim")
