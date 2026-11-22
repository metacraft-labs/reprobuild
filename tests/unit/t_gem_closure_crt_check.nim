## The gem-closure step's C-runtime check, on real PE files: a compiled
## extension must import the UCRT (``ucrtbase.dll`` or ``api-ms-win-crt-*``),
## must not import ``msvcrt.dll``, and must not import a DLL of a library the
## step links statically (libxml2, libxslt, libyaml, zlib, libiconv). A
## failure names the file and the import, and fails the edge.
##
## The DLLs are built here with the MinGW-w64 cross compiler the dev shell
## names in ``REPRO_WINDOWS_CC``, each linked against one C runtime's import
## library, and read with the dev shell's ``objdump``, which reads PE import
## tables like the WinLibs ``objdump`` the step runs on Windows. No mocks:
## the files and the tool are real; only the host is not Windows.
##
## Mutation: let ``crtImportRefusal`` accept ``msvcrt.dll`` (or stop
## requiring a UCRT import) and the first case fails.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_tool_profiles

proc compile(cc, dir, name, source: string; libs: openArray[string]): string =
  ## A DLL with no C runtime start-up code of its own, so that its only
  ## C-runtime import is the library named in ``libs``.
  writeFile(dir / (name & ".c"), source)
  result = dir / (name & ".dll")
  var argv = @[cc, "-shared", "-nostdlib", "-o", result, dir / (name & ".c")]
  for lib in libs:
    argv.add(lib)
  argv.add("-lkernel32")
  let res = execCmdEx(quoteShellCommand(argv))
  doAssert res.exitCode == 0, res.output

const
  Entry = "int __stdcall DllMainCRTStartup(void *h, unsigned r, void *p) " &
    "{ return 1; }\n"
  UsesMalloc = "#include <stdlib.h>\n" & Entry &
    "__declspec(dllexport) void *fx(unsigned n) { return malloc(n); }\n"

suite "gem-closure C-runtime check on real PE files":
  let cc = getEnv("REPRO_WINDOWS_CC")
  let objdump = findExe("objdump")
  let ready = cc.len > 0 and fileExists(cc) and objdump.len > 0
  if not ready:
    checkpoint "REPRO_WINDOWS_CC (the dev shell's MinGW-w64 gcc) and an " &
      "objdump are required; run inside the reprobuild dev shell"
  let dir = createTempDir("repro-gem-crt-", "")

  test "an extension importing msvcrt.dll fails the edge, naming the file":
    require ready
    let msvcrt = compile(cc, dir, "msvcrt_ext", UsesMalloc, ["-lmsvcrt"])
    var message = ""
    try:
      checkCompiledExtensions("fx-ruby", [msvcrt], objdump)
    except GemClosureStepError as err:
      message = err.msg
    checkpoint message
    check msvcrt in message
    check "imports msvcrt.dll" in message

  test "UCRT extensions pass, through ucrtbase or the api sets":
    require ready
    let viaBase = compile(cc, dir, "ucrtbase_ext", UsesMalloc, ["-lucrtbase"])
    let viaApiSet = compile(cc, dir, "apiset_ext", UsesMalloc, ["-lucrt"])
    checkCompiledExtensions("fx-ruby", [viaBase, viaApiSet], objdump)
    let listed = execCmdEx(quoteShellCommand(@[objdump, "-p", viaApiSet]))
    check peImports(listed.output).len > 0
    for name in peImports(listed.output):
      check name == "kernel32.dll" or name.startsWith("api-ms-win-crt-")

  test "an import of a statically linked library's DLL is refused":
    require ready
    # A stand-in for MSYS2's libxml2 DLL, exporting the symbol the extension
    # calls; the extension links against it as nokogiri would against a
    # libxml2 import library.
    let xml = compile(cc, dir, "libxml2-16",
      Entry & "__declspec(dllexport) void xmlCheckVersion(int v) { (void)v; }\n",
      ["-lucrtbase"])
    let ext = compile(cc, dir, "nokogiri_ext",
      Entry & "extern void xmlCheckVersion(int);\n" &
      "__declspec(dllexport) void fx(void) { xmlCheckVersion(1); }\n",
      [xml, "-lucrtbase"])
    var message = ""
    try:
      checkCompiledExtensions("fx-ruby", [ext], objdump)
    except GemClosureStepError as err:
      message = err.msg
    checkpoint message
    check "libxml2-16.dll" in message
    check "linked statically" in message

  test "the import decision, from the listing alone":
    check crtImportRefusal(["kernel32.dll", "ucrtbase.dll"]) == ""
    check "neither" in crtImportRefusal(["kernel32.dll"])
    check "msvcrt" in crtImportRefusal(["ucrtbase.dll", "msvcrt.dll"])
    for name in ["zlib1.dll", "libyaml-0-2.dll", "libiconv-2.dll",
                 "libxslt-1.dll", "libexslt-0.dll", "libz.dll"]:
      check "linked statically" in crtImportRefusal(["ucrtbase.dll", name])
    # A name that merely starts like one of them is not one of them.
    check crtImportRefusal(["ucrtbase.dll", "zlibrary.dll"]) == ""
    check peImports("\tDLL Name: KERNEL32.dll\n  DLL Name:  UCRTBASE.dll\n") ==
      @["kernel32.dll", "ucrtbase.dll"]

  removeDir(dir)
