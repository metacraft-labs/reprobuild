## `packaging/producers/installed_prefix`: the prefix carries its runtime
## closure, names no build-host path, and refuses what would not load.
##
## reprobuild-pm Distribution-And-Packaging.md §5.3 (approved by Zahary
## Karadjov, 2026-11-03): decision C (the runtime closure, RUNPATH relative
## to the image, the symbol check) and decision B (the builder-path gate).
##
## NO MOCKS. The images and libraries are real ELF files compiled by the
## host's C compiler in a temp dir, and the edges' own shell programs run
## against them with the real readelf, patchelf, awk and grep. A native
## build stands in for the target's: what is under test is the closure walk,
## the RUNPATH rule, the symbol check and the gate, none of which depend on
## the architecture. Without the tools on PATH the cases skip with the
## reason, and fail in a gate run.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip
import repro_project_dsl
import repro_dsl_stdlib/packaging/producers/installed_prefix

proc missingTool(): string =
  for tool in ["cc", "readelf", "patchelf", "awk", "sed", "sort", "grep",
               "find", "mktemp", "tar", "gzip"]:
    if findExe(tool).len == 0:
      return tool & " is not on PATH"
  ""

template requireTools(body: untyped) =
  let missing = missingTool()
  if missing.len > 0:
    if getEnv("REPROBUILD_GATE_RUN") == "1":
      checkpoint(missing & " in a gate run")
      check false
    else:
      skip(missing)
  else:
    body

proc sh(cmd, dir: string): tuple[output: string, code: int] =
  let r = execCmdEx("sh -c " & quoteShell(cmd), workingDir = dir)
  (r.output, r.exitCode)

proc cc(dir, args: string) =
  # A Nix toolchain's linker wrapper writes an rpath for every `-L`
  # directory (`NIX_DONT_SET_RPATH` stops that) and a dev shell adds
  # `$out/lib` (through `out` and `NIX_LDFLAGS`); those bytes stay in
  # `.dynstr` when the entry is removed -- a build-host path the gate would
  # rightly find in a fixture that stands for a clean image.
  let r = sh("env -u out -u NIX_LDFLAGS NIX_DONT_SET_RPATH=1 cc " & args, dir)
  doAssert r.code == 0, r.output

type Fixture = object
  root, built, libs, oldLibs: string

proc makeFixture(root: string; homeLiteral = false;
                 portableInterp = false): Fixture =
  ## `built/bin/app` needs `libfoo.so.1`, which needs `libbar.so.1`; both
  ## libraries are in `libs/`. `oldlibs/` holds a `libfoo.so.1` built
  ## without `foo_new`, which `app` calls. `built/lib/libplain.so` needs
  ## nothing bundled.
  result = Fixture(root: root, built: root / "built", libs: root / "libs",
    oldLibs: root / "oldlibs")
  createDir(result.built / "bin")
  createDir(result.built / "lib")
  createDir(result.libs)
  createDir(result.oldLibs)
  writeFile(root / "bar.c", "int bar(void) { return 2; }\n")
  writeFile(root / "foo.c",
    "int bar(void);\nint foo(void) { return bar(); }\nint foo_new(void) { return 3; }\n")
  writeFile(root / "foo_old.c",
    "int bar(void);\nint foo(void) { return bar(); }\n")
  writeFile(root / "app.c",
    "int foo(void); int foo_new(void);\n" &
    (if homeLiteral: "const char *where = \"/home/someone/build/app.c\";\n" else: "") &
    "int main(void) { return foo() + foo_new() == 5 ? 0 : 1; }\n")
  writeFile(root / "plain.c", "int plain(void) { return 1; }\n")
  cc(root, "-shared -fPIC -Wl,-soname,libbar.so.1 -o libs/libbar.so.1 bar.c")
  cc(root, "-shared -fPIC -Wl,-soname,libfoo.so.1 -o libs/libfoo.so.1 foo.c " &
    "-Llibs -l:libbar.so.1")
  cc(root, "-shared -fPIC -Wl,-soname,libfoo.so.1 -o oldlibs/libfoo.so.1 " &
    "foo_old.c -Llibs -l:libbar.so.1")
  # `portableInterp`: the target's loader path, not the build toolchain's
  # (a store path), for a fixture the gate must pass; such an app does not
  # run on this host, so only the gate cases use it.
  cc(root, "-o built/bin/app app.c -Llibs -l:libfoo.so.1 " &
    "-Wl,-rpath-link,libs" &
    (if portableInterp: " -Wl,--dynamic-linker=/lib/ld-linux.so.2" else: ""))
  cc(root, "-shared -fPIC -o built/lib/libplain.so plain.c")

proc spec(f: Fixture; sources: seq[string]): InstalledPrefixSpec =
  result = InstalledPrefixSpec(name: "probe", triple: "native",
    output: f.root / "prefix",
    entries: @[
      PrefixEntry(source: f.built / "bin" / "app", dest: "bin/app"),
      PrefixEntry(source: f.built / "lib" / "libplain.so",
        dest: "lib/libplain.so")],
    systemSonames: @GlibcSonames,
    recordLines: @["source_revision=abc123"])
  for s in sources:
    result.librarySources.add(PrefixLibrarySource(dir: s,
      origin: "test:" & s.extractFilename))

proc runpath(f: string): string =
  sh("patchelf --print-rpath " & quoteShell(f), "/").output.strip()

suite "an installed prefix":

  test "the closure is bundled transitively, with RUNPATH where it is needed":
    requireTools:
      let root = createTempDir("prefix-closure-", "")
      defer: removeDir(root)
      let f = makeFixture(root)
      let r = sh(assemblyScript(spec(f, @[f.libs])), root)
      checkpoint(r.output)
      require r.code == 0
      let o = root / "prefix"
      check fileExists(o / "bin" / "app")
      check fileExists(o / "lib" / "libfoo.so.1")
      check fileExists(o / "lib" / "libbar.so.1")   # needed by libfoo
      check runpath(o / "bin" / "app") == "$ORIGIN/../lib"
      check runpath(o / "lib" / "libfoo.so.1") == "$ORIGIN"
      check runpath(o / "lib" / "libplain.so") == ""
      let record = readFile(o / PrefixRecordPath)
      check "triple=native\n" in record
      check "source_revision=abc123\n" in record
      check "runtime libfoo.so.1 test:libs\n" in record
      # The bundled prefix runs from where it is, with nothing else.
      check sh(quoteShell(o / "bin" / "app"), "/").code == 0

  test "a library no source holds is refused by name":
    requireTools:
      let root = createTempDir("prefix-missing-", "")
      defer: removeDir(root)
      let f = makeFixture(root)
      let r = sh(assemblyScript(spec(f, @[root / "empty"])), root)
      checkpoint(r.output)
      check r.code != 0
      check "bin/app needs libfoo.so.1" in r.output

  test "a symbol the run-time build lacks is refused by name":
    requireTools:
      let root = createTempDir("prefix-symbols-", "")
      defer: removeDir(root)
      let f = makeFixture(root)
      # The old libfoo first: same soname, no foo_new.
      let r = sh(assemblyScript(spec(f, @[f.oldLibs, f.libs])), root)
      checkpoint(r.output)
      check r.code != 0
      check "foo_new bin/app" in r.output

  test "the gate refuses a build-host path and passes a clean prefix":
    requireTools:
      let root = createTempDir("prefix-gate-", "")
      defer: removeDir(root)
      let f = makeFixture(root, homeLiteral = true, portableInterp = true)
      require sh(assemblyScript(spec(f, @[f.libs])), root).code == 0
      let dirty = sh(gateScript(root / "prefix"), root)
      checkpoint(dirty.output)
      check dirty.code != 0
      check "bin/app:" in dirty.output
      check "/home/" in dirty.output
      check not fileExists(gateStamp(root / "prefix"))
      # Rebuilt without the literal, it passes and leaves its stamp.
      removeDir(root / "prefix")
      let g = makeFixture(root / "clean", portableInterp = true)
      require sh(assemblyScript(spec(g, @[g.libs])), root / "clean").code == 0
      let clean = sh(gateScript(root / "clean" / "prefix"), root / "clean")
      checkpoint(clean.output)
      check clean.code == 0
      check fileExists(gateStamp(root / "clean" / "prefix"))

  test "the gate refuses the working directory's own path":
    requireTools:
      let root = createTempDir("prefix-gate-pwd-", "")
      defer: removeDir(root)
      let f = makeFixture(root, portableInterp = true)
      require sh(assemblyScript(spec(f, @[f.libs])), root).code == 0
      # Plant the working directory in a bundled library's bytes.
      let lib = root / "prefix" / "lib" / "libbar.so.1"
      writeFile(lib, readFile(lib) & root & "/build/x.c\0")
      let r = sh(gateScript(root / "prefix"), root)
      checkpoint(r.output)
      check r.code != 0
      check ("lib/libbar.so.1: 1 line(s) carry " & root) in r.output

  test "the archive refuses a prefix built from a modified tree":
    requireTools:
      let root = createTempDir("prefix-dirty-", "")
      defer: removeDir(root)
      let f = makeFixture(root)
      var s = spec(f, @[f.libs])
      s.recordLines = @["source_revision=abc123-dirty"]
      require sh(assemblyScript(s), root).code == 0
      resetBuildActionRegistry()
      let p = installedPrefix(s, root)
      let act = installedPrefixArchive(p, root / "probe.tar.gz", "probe-1.0", root)
      var script = ""
      for arg in act.call.arguments:
        if arg.name == "argv":
          let argv = arg.encodedValue.split('\x1f')
          script = argv[argv.find("-c") + 1]
      let r = sh(script, root)
      checkpoint(r.output)
      check r.code != 0
      check "modified tree" in r.output
      check not fileExists(root / "probe.tar.gz")

  test "a destination outside the prefix is refused before any edge":
    var s = InstalledPrefixSpec(name: "x", triple: "t", output: "/o",
      entries: @[PrefixEntry(source: "/a", dest: "../escape")])
    expect ValueError:
      discard assemblyScript(s)

  test "a bundled library with debug info is stripped, one without is kept":
    requireTools:
      let root = createTempDir("prefix-strip-", "")
      defer: removeDir(root)
      let f = makeFixture(root)
      # libbar with debug info; libfoo as built (no -g).
      cc(root, "-g -shared -fPIC -Wl,-soname,libbar.so.1 -o libs/libbar.so.1 bar.c")
      var s = spec(f, @[f.libs])
      # The host's own objcopy stands in for the target's, behind a shim
      # that records which libraries it was asked to strip.
      let log = root / "stripped.log"
      writeFile(root / "strip.sh", "#!/bin/sh\nbasename \"$1\" >> " & log &
        "\nexec objcopy --strip-debug \"$1\" \"$2\"\n")
      setFilePermissions(root / "strip.sh", {fpUserRead, fpUserWrite, fpUserExec})
      s.debugStripCommand = root / "strip.sh"
      let r = sh(assemblyScript(s), root)
      checkpoint(r.output)
      require r.code == 0
      check readFile(log).splitLines().filterIt(it.len > 0) == @["libbar.so.1"]
      check sh("readelf -S " & quoteShell(root / "prefix" / "lib" /
        "libbar.so.1") & " | grep -c '\\.debug'", root).output.strip() == "0"
