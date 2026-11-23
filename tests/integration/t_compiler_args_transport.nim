## A compiler argv over the platform's process argument limit still compiles.
##
## Windows' `CreateProcessW` refuses a command line longer than 32,767 UTF-16
## units (error 206). A provider or interface compile that carries every
## selected SDK root with its paired exclusion flags exceeds that (release run
## 41078006278 measured 37,924 units), so the compile runner carries the same
## LOGICAL argv through the compiler's `--compilerArgsFile` transport
## (codetracer-pm `spec/Nim-Compiler-Argument-Files.md`).
##
## Everywhere: the length measure, the version-1 file encoding (decoded back
## by an independent JSON parser), its refusals, atomic staging and owner-only
## removal.
##
## On Windows, with the real canonical compiler the bootstrap provisions
## (`provisionBootstrapNim`, archive route) and the real C toolchain: a
## >32,767-unit compile argv fails with 206 when launched directly, and the
## production provider-compile runner compiles and links it, the program sees
## the define given LAST in the vector, and the runner leaves no argument file
## behind. Nothing is mocked.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_interface_artifacts/compiler_args_transport
import repro_tool_profiles
import repro_test_support

suite "compiler argument transport":
  test "measures the command line CreateProcessW receives":
    check utf16Units("a") == 1
    check utf16Units("é") == 1
    check utf16Units("😀") == 2
    check windowsQuotedCommandLine(["nim", "a b", ""]) == "nim \"a b\" \"\""
    check windowsCommandLineUnits(["nim", "a b", ""]) == len("nim \"a b\" \"\"") + 1
    let atLimit = @["n", repeat('x', WindowsCommandLineLimitUnits - 3)]
    check windowsCommandLineUnits(atLimit) == WindowsCommandLineLimitUnits
    check not exceedsWindowsCommandLineLimit(atLimit)
    check exceedsWindowsCommandLineLimit(atLimit & @[""])

  test "encodes the exact logical vector as version-1 JSON":
    let argv = @["c", "", "--path:relative imports", "-d:q=\"x\"",
      "back\\slash", "tab\tnew\nline\r\x01\x1f", "é😀", "$HOME %PATH% @f"]
    let node = parseJson(encodeCompilerArgsFile(argv))
    check node.len == 2
    check node["version"].getInt == 1
    var decoded: seq[string]
    for item in node["argv"]: decoded.add item.getStr
    check decoded == argv
    check encodeCompilerArgsFile([]) == "{\"version\":1,\"argv\":[]}"

  test "refuses what no process argv can carry":
    expect CompilerArgsTransportError:
      discard encodeCompilerArgsFile(["a\0b"])
    expect CompilerArgsTransportError:
      discard encodeCompilerArgsFile(["\xff"])
    expect CompilerArgsTransportError:
      discard stageCompilerArgsFile("", ["c"])

  test "stages atomically in the owner's scratch and removes only its file":
    let scratch = createTempDir("t_compiler_args_transport_", "")
    defer: removeDir(scratch)
    writeFile(scratch / "unrelated.txt", "keep")
    let path = stageCompilerArgsFile(scratch, ["c", "main.nim"])
    check path.isAbsolute
    check path.parentDir == absolutePath(scratch)
    check path.endsWith(".json")
    check readFile(path) == encodeCompilerArgsFile(["c", "main.nim"])
    for kind, entry in walkDir(scratch):
      check not entry.endsWith(".tmp")
    check physicalCompilerCommand("nim", path) ==
      @["nim", "--compilerArgsFile:" & path]
    let second = stageCompilerArgsFile(scratch, ["c"])
    check second != path
    removeStagedCompilerArgsFile(path)
    removeStagedCompilerArgsFile(second)
    removeStagedCompilerArgsFile("")
    check not fileExists(path)
    check fileExists(scratch / "unrelated.txt")

  when defined(linux):
    test "a single argument over MAX_ARG_STRLEN exceeds the exec limit":
      check not compilerArgvExceedsPlatformLimit(["nim", "c", "x.nim"])
      check compilerArgvExceedsPlatformLimit(["nim", repeat('x', 200_000)])

  when defined(windows):
    test "a >32,767-unit provider compile fails directly and compiles via the file":
      let root = createTempDir("t_compiler_args_transport_win_", "")
      # The private tool store's action-cache records sit past MAX_PATH under
      # %TEMP%; `removeDirEventually` retries with the extended-length form.
      defer: removeDirEventually(root)
      let store = root / "tool-store"
      let nim = provisionBootstrapNim(store, bnrArchive)
      writeFile(root / "main.nim",
        "const lastFlag {.strdefine.} = \"\"\necho \"last=\", lastFlag\n")
      let exe = root / "main.exe"
      var command = @[nim, "c", "--hints:off", "--skipUserCfg",
        "--nimcache:" & (root / "nimcache"), "--out:" & exe]
      var i = 0
      while windowsCommandLineUnits(command) <= 40_000:
        let sdkRoot = root / ("sdk-root-" & align($i, 4, '0') & "-" & repeat('r', 80))
        command.add "--excludePath:" & sdkRoot
        command.add "--path:" & sdkRoot
        inc i
      command.add @["-d:lastFlag=long-argv-ok", root / "main.nim"]
      check windowsCommandLineUnits(command) > WindowsCommandLineLimitUnits
      check compilerArgvExceedsPlatformLimit(command)

      let directCwd = createTempDir("direct-", "", root)
      var direct = ""
      try:
        discard runCommand(command, cwd = directCwd, raiseOnFailure = false)
      except OSError as err:
        direct = err.msg
      check "CreateProcessW failed (206)" in direct

      let cwd = createTempDir("provider-compiler-cwd-", "", root)
      discard runProviderCompilerCommand(command, cwd)
      check fileExists(exe)
      check execProcess(exe, args = [], options = {}).strip == "last=long-argv-ok"
      for kind, entry in walkDir(cwd):
        check "repro-compiler-args-" notin entry.extractFilename
