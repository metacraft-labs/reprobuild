## `packaging/producers/installed_prefix`: the prefix carries its runtime
## closure, names no build-host path, and refuses what would not load.
##
## reprobuild-pm Distribution-And-Packaging.md §5.3 (approved by Zahary
## Karadjov, 2026-11-03): decision C (the runtime closure, RUNPATH relative
## to the image, the symbol check) and decision B (the builder-path gate),
## and its 2026-11-26 amendment: with glibc a system soname, each image's
## `PT_INTERP` names the triple's system loader (`glibc_loaders`).
##
## NO MOCKS. The images and libraries are real ELF files compiled by the
## host's C compiler in a temp dir, and the edges' own shell programs run
## against them with the real readelf, patchelf, awk and grep. A native
## build stands in for the target's: what is under test is the closure walk,
## the RUNPATH rule, the symbol check and the gate, none of which depend on
## the architecture. Without the tools on PATH the cases skip with the
## reason, and fail in a gate run.
##
## The loader cases link their images with `--dynamic-linker=` naming a
## loader that need not exist: a store-shaped path standing in for what a
## Nix gcc links with, so the case does not depend on which C compiler is on
## PATH (the host's gcc already names the system loader). The images are
## never run; what is under test is what the assembly writes into them.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip
import repro_core/target_object_check
import repro_project_dsl
import repro_dsl_stdlib/glibc_loaders
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
                 portableInterp = false; interp = ""): Fixture =
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
  # `portableInterp`: a loader path that is not the build toolchain's (a
  # store path), for a fixture the gate must pass; such an app does not run
  # on this host, so only the gate cases use it. `interp`: the loader the
  # app is linked to name.
  let dynamicLinker =
    if interp.len > 0: interp
    elif portableInterp: "/lib/ld-linux.so.2"
    else: ""
  cc(root, "-o built/bin/app app.c -Llibs -l:libfoo.so.1 " &
    "-Wl,-rpath-link,libs" &
    (if dynamicLinker.len > 0: " -Wl,--dynamic-linker=" & dynamicLinker
     else: ""))
  cc(root, "-shared -fPIC -o built/lib/libplain.so plain.c")

proc spec(f: Fixture; sources: seq[string]): InstalledPrefixSpec =
  result = InstalledPrefixSpec(name: "probe", triple: hostTriple(),
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

proc interpreter(f: string): string =
  ## The image's `PT_INTERP`, or "" for one without (readelf's own words).
  let r = sh("readelf -l -W " & quoteShell(f), "/")
  doAssert r.code == 0, r.output
  const marker = "[Requesting program interpreter: "
  let at = r.output.find(marker)
  if at < 0: return ""
  let rest = r.output[at + marker.len .. ^1]
  rest[0 ..< rest.find(']')]

const FakeStoreGlibc = "/nix/store/" & repeat('a', 32) & "-glibc-2.42/lib/"
  ## A store-shaped directory: what a Nix gcc's images name their loader in.

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
      check ("triple=" & hostTriple() & "\n") in record
      check "source_revision=abc123\n" in record
      check "runtime libfoo.so.1 test:libs\n" in record
      # The bundled prefix runs from where it is, with nothing else. Through
      # the loader the app was linked with: the assembly made the image
      # name this triple's system loader, which a NixOS host does not have.
      let linkedLoader = interpreter(f.built / "bin" / "app")
      require linkedLoader.len > 0
      check sh(quoteShell(linkedLoader) & " " & quoteShell(o / "bin" / "app"),
        "/").code == 0

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

  test "the gate refuses a path of a library source's own build tree":
    # The catalog's nim-fork put 47 lines of `<catalog>/nim-fork/.repro/
    # build/...` into `nim/bin/nim`, and the gate, which searched only the
    # store, `/home/`, its working directory and `$HOME`, passed it
    # (measured 2026-11-04). A catalog checkout is not under the project.
    requireTools:
      let root = createTempDir("prefix-gate-roots-", "")
      defer: removeDir(root)
      let f = makeFixture(root, portableInterp = true)
      let recipe = root / "catalog" / "libbar"
      let mirror = recipe / ".repro" / "output" / "install" / "usr" / "lib"
      createDir(mirror)
      copyFile(f.libs / "libbar.so.1", mirror / "libbar.so.1")
      writeFile(mirror / "libbar.so.1", readFile(mirror / "libbar.so.1") &
        recipe & "/.repro/build/tree/bar.c\0")
      var s = spec(f, @[mirror, f.libs])
      let project = root / "project"
      createDir(project)
      require sh(assemblyScript(s), project).code == 0
      check prefixBuildRoots(s) == @[recipe]
      let r = sh(gateScript(s.output, roots = prefixBuildRoots(s)), project)
      checkpoint(r.output)
      check r.code != 0
      check ("lib/libbar.so.1: 1 line(s) carry " & recipe) in r.output
      # An explicit root (the whole catalog checkout) is searched too.
      s.buildRoots = @[root / "catalog"]
      check prefixBuildRoots(s) == @[root / "catalog", recipe]

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
      # that records which libraries it was asked to strip. The strip is a
      # filter, so the library is the file its standard input reads.
      let log = root / "stripped.log"
      writeFile(root / "strip.sh", "#!/bin/sh\n" &
        "basename \"$(readlink /proc/self/fd/0)\" >> " & log & "\n" &
        "t=$(mktemp)\nobjcopy --strip-debug /dev/stdin \"$t\" && cat \"$t\"\n" &
        "s=$?\nrm -f \"$t\"\nexit $s\n")
      setFilePermissions(root / "strip.sh", {fpUserRead, fpUserWrite, fpUserExec})
      s.debugStripCommand = root / "strip.sh"
      let r = sh(assemblyScript(s), root)
      checkpoint(r.output)
      require r.code == 0
      check readFile(log).splitLines().filterIt(it.len > 0) == @["libbar.so.1"]
      check sh("readelf -S " & quoteShell(root / "prefix" / "lib" /
        "libbar.so.1") & " | grep -c '\\.debug'", root).output.strip() == "0"

  test "a debug strip that fails refuses the prefix, naming the library":
    # zig 0.13's objcopy failed on an armv7 library ("error: Unexpected"),
    # left a truncated `<lib>.stripped` beside it, and the assembly went on
    # with the unstripped library (measured 2026-11-03).
    requireTools:
      let root = createTempDir("prefix-strip-fails-", "")
      defer: removeDir(root)
      let f = makeFixture(root)
      cc(root, "-g -shared -fPIC -Wl,-soname,libbar.so.1 -o libs/libbar.so.1 bar.c")
      var s = spec(f, @[f.libs])
      writeFile(root / "strip.sh", "#!/bin/sh\nhead -c 100\n" &
        "echo 'error: Unexpected' >&2; exit 1\n")
      setFilePermissions(root / "strip.sh", {fpUserRead, fpUserWrite, fpUserExec})
      s.debugStripCommand = root / "strip.sh"
      let r = sh(assemblyScript(s), root)
      checkpoint(r.output)
      check r.code != 0
      check "libbar.so.1" in r.output
      check "error: Unexpected" in r.output
      check not fileExists(root / "prefix" / "lib" / "libbar.so.1.stripped")

  test "a gate check that fails refuses the prefix; one that passes does not":
    requireTools:
      let root = createTempDir("prefix-gate-check-", "")
      defer: removeDir(root)
      let f = makeFixture(root, portableInterp = true)
      require sh(assemblyScript(spec(f, @[f.libs])), root).code == 0
      let o = root / "prefix"
      let refused = sh(gateScript(o, @["echo 'sources do not close' >&2; exit 1"]), root)
      checkpoint(refused.output)
      check refused.code != 0
      check "sources do not close" in refused.output
      check not fileExists(gateStamp(o))
      let passed = sh(gateScript(o, @["test -f \"$O/bin/app\""]), root)
      checkpoint(passed.output)
      check passed.code == 0
      check fileExists(gateStamp(o))

  test "the loader table holds glibc's own paths, by triple":
    check glibcLoaderOfTriple("x86_64-unknown-linux-gnu") ==
      "/lib64/ld-linux-x86-64.so.2"
    check glibcLoaderOfTriple("aarch64-unknown-linux-gnu") ==
      "/lib/ld-linux-aarch64.so.1"
    check glibcLoaderOfTriple("armv7-unknown-linux-gnueabihf") ==
      "/lib/ld-linux-armhf.so.3"
    check glibcLoaderOfTriple("armv7-unknown-linux-gnueabi") ==
      "/lib/ld-linux.so.3"
    check glibcLoaderOfTriple("i686-unknown-linux-gnu") == "/lib/ld-linux.so.2"
    check glibcLoaderOfTriple("riscv64gc-unknown-linux-gnu") ==
      "/lib/ld-linux-riscv64-lp64d.so.1"
    # Not glibc, or not in the table: no answer, never a guess.
    check glibcLoaderOfTriple("x86_64-unknown-linux-musl") == ""
    check glibcLoaderOfTriple("aarch64-apple-darwin") == ""
    check glibcLoaderOfTriple("native") == ""
    var seen: seq[string]
    for row in GlibcLoaders:
      check row.path.isAbsolute
      # A prefix that keeps glibc the target's never bundles a loader.
      check row.path.extractFilename in GlibcSonames
      for t in row.triples:
        checkpoint(t)
        check t notin seen
        seen.add(t)
    # The architecture names the packaging layer uses read the same rows.
    check glibcLoaderOfArchitecture("x86_64") == "/lib64/ld-linux-x86-64.so.2"
    check glibcLoaderOfArchitecture("armhf") == "/lib/ld-linux-armhf.so.3"
    check glibcLoaderOfArchitecture("sparc") == ""

  test "each image names the triple's system loader; others are left alone":
    requireTools:
      let triple = hostTriple()
      let loader = glibcLoaderOfTriple(triple)
      if loader.len == 0:
        skip("no glibc loader is known for this host's triple " & triple)
      else:
        let root = createTempDir("prefix-interp-", "")
        defer: removeDir(root)
        # bin/app names the loader under a store path, as a Nix gcc links.
        let f = makeFixture(root,
          interp = FakeStoreGlibc & loader.extractFilename)
        require interpreter(f.built / "bin" / "app") ==
          FakeStoreGlibc & loader.extractFilename
        # Three images in lib/, which no RUNPATH rule touches, so any
        # change to their bytes is the loader step's: one that already
        # names the system loader, one that names musl's, and a static one.
        writeFile(root / "helper.c", "int main(void) { return 0; }\n")
        writeFile(root / "start.c", "void _start(void) { for (;;) {} }\n")
        cc(root, "-o built/lib/helper helper.c -Wl,--dynamic-linker=" & loader)
        let musl = "/lib/ld-musl-" & triple.split('-')[0] & ".so.1"
        cc(root, "-o built/lib/helper-musl helper.c -Wl,--dynamic-linker=" &
          musl)
        cc(root, "-nostdlib -static -no-pie -o built/lib/static start.c")
        require interpreter(f.built / "lib" / "static") == ""
        var s = spec(f, @[f.libs])
        for name in ["helper", "helper-musl", "static"]:
          s.entries.add(PrefixEntry(source: f.built / "lib" / name,
            dest: "lib/" & name))
        let o = root / "prefix"
        # Control: the image as the toolchain linked it fails the gate, on
        # the store path in its PT_INTERP and on nothing else.
        let raw = root / "raw"
        createDir(raw / "bin")
        copyFile(f.built / "bin" / "app", raw / "bin" / "app")
        let refused = sh(gateScript(raw), root)
        checkpoint(refused.output)
        check refused.code != 0
        check "bin/app: 1 line(s) match /nix/store/" in refused.output
        let r = sh(assemblyScript(s), root)
        checkpoint(r.output)
        require r.code == 0
        check interpreter(o / "bin" / "app") == loader
        check interpreter(o / "lib" / "helper") == loader
        check interpreter(o / "lib" / "helper-musl") == musl
        check interpreter(o / "lib" / "static") == ""
        for name in ["helper", "helper-musl", "static", "libplain.so"]:
          checkpoint(name)
          check readFile(o / "lib" / name) == readFile(f.built / "lib" / name)
        let gate = sh(gateScript(o), root)
        checkpoint(gate.output)
        check gate.code == 0
        check fileExists(gateStamp(o))
        # Assembling again writes the same bytes.
        let first = readFile(o / "bin" / "app")
        require sh(assemblyScript(s), root).code == 0
        check readFile(o / "bin" / "app") == first

  test "a triple with no known loader is refused when glibc is a system soname":
    var s = InstalledPrefixSpec(name: "x", triple: "sparc64-unknown-linux-gnu",
      output: "/o", systemSonames: @GlibcSonames)
    try:
      discard assemblyScript(s)
      check false
    except ValueError as e:
      checkpoint(e.msg)
      check "sparc64-unknown-linux-gnu" in e.msg
      check "GlibcLoaders" in e.msg
    resetBuildActionRegistry()
    expect ValueError:
      discard installedPrefix(s, "/project")
    # Without glibc among the system sonames (a musl prefix) the images keep
    # their loader, so any triple is accepted and no loader step is written.
    s.systemSonames = @["libc.musl-x86_64.so.1"]
    check systemLoaderOf(s) == ""
    check "--set-interpreter" notin assemblyScript(s)
