## DSL-port M9.R.2 — typed Layer-3 ``cli:`` blocks for the stdlib
## build-tool packages (meson, cmake, ninja, make, autoconf, binutils,
## gcc).
##
## The test asserts that recipes can invoke each build tool typed-style
## (e.g. ``meson.setup(srcDir = ..., buildDir = ...)``) and that the
## resulting ``BuildActionDef`` carries the expected ``call.arguments``
## shape — flag aliases, formats, roles, positional ordering, and
## ``outputs`` wiring. Downstream consumers (the engine, action-cache,
## solver) read those fields to materialise argv + fingerprint inputs /
## outputs without re-parsing the DSL.
##
## What's covered:
##
##   1. ``meson.setup`` — argv shape + positional ordering
##      (``buildDir`` at position 0, ``srcDir`` at position 1).
##   2. ``meson.compile`` + ``meson.install`` — ``-C <workDir>``,
##      ``--destdir=...`` + ``--tags=...``.
##   3. ``cmake.configure`` — ``-S <srcDir> -B <buildDir> -G <gen>
##      -D<var>``.
##   4. ``cmake.build`` + ``cmake.install`` — ``--build <buildDir>
##      --target <name>`` and ``--install <buildDir> --prefix <dir>``.
##   5. ``ninja.call`` — ``-C <workDir>`` + positional targets.
##   6. ``make.call`` — ``-C <workDir>`` + positional vars / targets.
##   7. ``autoconf.call`` — ``--force`` + positional configure.ac.
##   8. ``ld.call`` + ``ar.call`` — binutils typed call sites
##      resolve to the ``ld(output = ..., objects = @[...])`` /
##      ``ar(modifiers = "rcs", archive = ..., objects = @[...])``
##      shape.
##   9. ``gcc.call`` — the existing gcc driver call still works with
##      the M9.R.2 extensions (``-c -o out.o src.c`` byte-equivalent).

## The ``call:`` (no-subcmd) wrapper procs emitted by the package
## macro use Nim's experimental callOperator feature so call sites
## read ``ninja(workDir = ...)`` rather than ``ninja.call(workDir = ...)``
## or ``ninja.\`()\`(workDir = ...)``. We opt into the experimental
## feature locally so the test module can drive each ``call:`` surface
## under the same syntax as production recipes.
{.experimental: "callOperator".}

import std/[unittest]

import repro_project_dsl
# Each ``package`` block emits a top-level ``const <name>* = <Type>()``.
# Module-name == const-name collision is resolved by aliasing the
# module import as ``<name>_module`` (same convention as the package
# macro's ``usesImportCode`` auto-import) so the bare identifier
# resolves to the const value and ``<name>.<subcmd>(...)`` dispatches
# via UFCS to the generated wrapper proc.
import repro_dsl_stdlib/packages/meson as meson_module
import repro_dsl_stdlib/packages/cmake as cmake_module
import repro_dsl_stdlib/packages/ninja as ninja_module
import repro_dsl_stdlib/packages/make as make_module
import repro_dsl_stdlib/packages/autoconf as autoconf_module
import repro_dsl_stdlib/packages/binutils as binutils_module
import repro_dsl_stdlib/packages/gcc as gcc_module

# ---------------------------------------------------------------------------
# Helpers — look up a call's argument by name; collect every encoded
# value. The typed wrapper proc records each non-default flag in
# ``call.arguments`` as a ``PublicCliArg`` with the documented role +
# format. Tests use these helpers to keep per-tool assertions short.
# ---------------------------------------------------------------------------

proc argByName(action: BuildActionDef; name: string): PublicCliArg =
  for arg in action.call.arguments:
    if arg.name == name:
      return arg
  raise newException(ValueError, "no argument named '" & name &
    "' in call to " & action.call.packageName & "." &
    action.call.executableName & "." & action.call.subcommand)

# ---------------------------------------------------------------------------
# meson — setup / compile / install / dist
# ---------------------------------------------------------------------------

suite "DSL-port M9.R.2 — meson typed CLI surface":

  test "meson.setup records buildDir + srcDir positionals + flags":
    let action = meson.setup(srcDir = "./src", buildDir = "./b",
      prefix = "/usr", buildtype = "release",
      options = @["foo=bar", "baz=qux"])
    check action.call.packageName == "meson"
    check action.call.executableName == "mesonBin"
    check action.call.subcommand == "setup"
    # Positional ordering: buildDir is position 0, srcDir is position 1.
    # This matches the canonical ``meson setup <buildDir> <srcDir>``
    # invocation; the order is load-bearing because meson reads the
    # build dir from argv[1] and the source dir from argv[2].
    let buildDirArg = action.argByName("buildDir")
    let srcDirArg = action.argByName("srcDir")
    check buildDirArg.kind == cpkPositional
    check buildDirArg.position == 0
    check buildDirArg.role == carOutput
    check buildDirArg.encodedValue == "./b"
    check srcDirArg.kind == cpkPositional
    check srcDirArg.position == 1
    check srcDirArg.role == carInput
    check srcDirArg.encodedValue == "./src"
    # Flags: prefix uses concat (``--prefix=/usr``), buildtype too,
    # options repeats with ``-D`` concat.
    let prefixArg = action.argByName("prefix")
    check prefixArg.kind == cpkFlag
    check prefixArg.alias == "--prefix="
    check prefixArg.format == cafConcat
    check prefixArg.encodedValue == "/usr"
    let optsArg = action.argByName("options")
    check optsArg.alias == "-D"
    check optsArg.format == cafConcat
    check optsArg.repeated
    # The outputs wiring records ``buildDir`` as the canonical implicit
    # target slot (the actual name derivation depends on the engine's
    # path-canonicalisation pass and isn't asserted here; the
    # ``outputs buildDir`` declaration's contribution is verified by
    # the role tagging above).

  test "meson.compile + meson.install carry the right -C + --destdir":
    let compileAction = meson.compile(workDir = "./b")
    check compileAction.call.subcommand == "compile"
    let wd = compileAction.argByName("workDir")
    check wd.alias == "-C"
    check wd.format == cafSeparate
    check wd.role == carInput
    check wd.encodedValue == "./b"

    let installAction = meson.install(workDir = "./b",
      destdir = "/tmp/stage", tags = @["runtime", "devel"])
    check installAction.call.subcommand == "install"
    let ddArg = installAction.argByName("destdir")
    check ddArg.alias == "--destdir="
    check ddArg.format == cafConcat
    check ddArg.role == carOutput
    check ddArg.encodedValue == "/tmp/stage"
    let tagsArg = installAction.argByName("tags")
    check tagsArg.alias == "--tags="
    check tagsArg.repeated

  test "meson.dist surfaces formats + workDir":
    let action = meson.dist(workDir = "./b",
      formats = @["xztar", "gztar"])
    check action.call.subcommand == "dist"
    check action.argByName("workDir").encodedValue == "./b"
    let formats = action.argByName("formats")
    check formats.alias == "--formats="
    check formats.repeated

# ---------------------------------------------------------------------------
# cmake — configure / build / install
# ---------------------------------------------------------------------------

suite "DSL-port M9.R.2 — cmake typed CLI surface":

  test "cmake.configure records -S / -B / -G / -D":
    let action = cmake.configure(srcDir = "./src", buildDir = "./b",
      generator = "Ninja",
      cacheVars = @["CMAKE_BUILD_TYPE=Release",
        "CMAKE_INSTALL_PREFIX=/usr"])
    check action.call.packageName == "cmake"
    check action.call.executableName == "cmakeBin"
    check action.call.subcommand == "configure"

    let srcArg = action.argByName("srcDir")
    check srcArg.alias == "-S"
    check srcArg.format == cafSeparate
    check srcArg.role == carInput
    check srcArg.encodedValue == "./src"

    let buildArg = action.argByName("buildDir")
    check buildArg.alias == "-B"
    check buildArg.format == cafSeparate
    check buildArg.role == carOutput
    check buildArg.encodedValue == "./b"

    let genArg = action.argByName("generator")
    check genArg.alias == "-G"
    check genArg.format == cafSeparate
    check genArg.encodedValue == "Ninja"

    let cacheArg = action.argByName("cacheVars")
    check cacheArg.alias == "-D"
    check cacheArg.format == cafConcat
    check cacheArg.repeated

  test "cmake.build + cmake.install carry --build / --install":
    let buildAction = cmake.build(buildDir = "./b", target = "all",
      jobs = 4)
    check buildAction.call.subcommand == "build"
    let bdArg = buildAction.argByName("buildDir")
    check bdArg.alias == "--build"
    check bdArg.format == cafSeparate
    check bdArg.role == carInput

    let installAction = cmake.install(buildDir = "./b",
      prefix = "/usr/local", component = "runtime")
    check installAction.call.subcommand == "install"
    let bArg = installAction.argByName("buildDir")
    check bArg.alias == "--install"
    check bArg.format == cafSeparate
    let prefixArg = installAction.argByName("prefix")
    check prefixArg.alias == "--prefix"
    check prefixArg.role == carOutput
    let compArg = installAction.argByName("component")
    check compArg.alias == "--component"
    check compArg.encodedValue == "runtime"

# ---------------------------------------------------------------------------
# ninja — single-mode ``call:``
# ---------------------------------------------------------------------------

suite "DSL-port M9.R.2 — ninja typed CLI surface":

  test "ninja.call produces -C <workDir> + positional targets":
    let action = ninja(workDir = "./b",
      targets = @["all", "install"])
    check action.call.packageName == "ninja"
    check action.call.executableName == "ninjaBin"
    check action.call.subcommand == ""
    let wd = action.argByName("workDir")
    check wd.alias == "-C"
    check wd.format == cafSeparate
    check wd.role == carInput
    check wd.encodedValue == "./b"
    let targetsArg = action.argByName("targets")
    check targetsArg.kind == cpkPositional
    check targetsArg.position == 0
    check targetsArg.role == carInput
    check targetsArg.repeated

  test "ninja.call accepts -j + -t flags":
    # ``targets`` is a required positional (the DSL flags every ``pos``
    # declaration ``required = true`` by default); pass the empty seq
    # to satisfy the formal without contributing argv entries.
    let action = ninja(workDir = "./b", jobs = 8, tool = "graph",
      targets = @[])
    let jobs = action.argByName("jobs")
    check jobs.alias == "-j"
    check jobs.format == cafSeparate
    check jobs.encodedValue == "8"
    let tool = action.argByName("tool")
    check tool.alias == "-t"
    check tool.encodedValue == "graph"

# ---------------------------------------------------------------------------
# make
# ---------------------------------------------------------------------------

suite "DSL-port M9.R.2 — make typed CLI surface":

  test "make.call records -C + vars + targets":
    let action = make(workDir = "./b",
      vars = @["DESTDIR=/tmp/out"], targets = @["install"])
    check action.call.packageName == "make"
    check action.call.executableName == "makeBin"
    check action.call.subcommand == ""
    check action.argByName("workDir").encodedValue == "./b"
    let varsArg = action.argByName("vars")
    check varsArg.kind == cpkPositional
    check varsArg.position == 0
    check varsArg.repeated
    let targetsArg = action.argByName("targets")
    check targetsArg.kind == cpkPositional
    check targetsArg.position == 1
    check targetsArg.repeated

  test "make.call accepts -f + -j":
    let action = make(workDir = "./b",
      file = "GNUmakefile", jobs = 8,
      vars = @[], targets = @["clean"])
    check action.argByName("file").alias == "-f"
    check action.argByName("file").encodedValue == "GNUmakefile"
    check action.argByName("jobs").alias == "-j"
    check action.argByName("jobs").encodedValue == "8"

# ---------------------------------------------------------------------------
# autoconf
# ---------------------------------------------------------------------------

suite "DSL-port M9.R.2 — autoconf typed CLI surface":

  test "autoconf.call records --version + --force + configure.ac":
    let action = autoconf(version = true, force = true,
      configureAc = "./configure.ac")
    check action.call.packageName == "autoconf"
    check action.call.executableName == "autoconfBin"
    check action.argByName("version").alias == "--version"
    check action.argByName("force").alias == "--force"
    let cf = action.argByName("configureAc")
    check cf.kind == cpkPositional
    check cf.position == 0
    check cf.role == carInput
    check cf.encodedValue == "./configure.ac"

# ---------------------------------------------------------------------------
# binutils — ld + ar typed calls. The remaining five (ranlib / strip /
# nm / objdump / objcopy / gas) share the same shape; one representative
# assertion per call surface is sufficient given the binutils.nim source
# is a flat list of single-executable packages.
# ---------------------------------------------------------------------------

suite "DSL-port M9.R.2 — binutils typed CLI surface":

  test "ld.call records -o + -l + -L + objects":
    let action = ld(output = "libfoo.so", shared = true,
      libDirs = @["/usr/lib"],
      libs = @["pthread", "m"],
      objects = @["foo.o", "bar.o"])
    check action.call.packageName == "ld"
    check action.call.executableName == "ldBin"
    let outArg = action.argByName("output")
    check outArg.alias == "-o"
    check outArg.format == cafSeparate
    check outArg.role == carOutput
    check outArg.encodedValue == "libfoo.so"
    let libsArg = action.argByName("libs")
    check libsArg.alias == "-l"
    check libsArg.format == cafConcat
    check libsArg.repeated
    let objs = action.argByName("objects")
    check objs.kind == cpkPositional
    check objs.role == carInput
    check objs.repeated
    check action.argByName("shared").alias == "-shared"

  test "ar.call records modifiers + archive + objects":
    let action = ar(modifiers = "rcs", archive = "libfoo.a",
      objects = @["foo.o", "bar.o"])
    check action.call.packageName == "ar"
    check action.call.executableName == "arBin"
    let mods = action.argByName("modifiers")
    check mods.kind == cpkPositional
    check mods.position == 0
    check mods.encodedValue == "rcs"
    let arch = action.argByName("archive")
    check arch.kind == cpkPositional
    check arch.position == 1
    check arch.role == carOutput
    check arch.encodedValue == "libfoo.a"
    let objs = action.argByName("objects")
    check objs.kind == cpkPositional
    check objs.position == 2
    check objs.role == carInput
    check objs.repeated

  test "strip.call records -s + -o + input":
    let action = strip(stripAll = true,
      output = "stripped.so", input = "libfoo.so")
    check action.call.packageName == "strip"
    check action.argByName("stripAll").alias == "-s"
    check action.argByName("output").alias == "-o"
    check action.argByName("input").kind == cpkPositional

  test "objcopy.call records -O + input + output positionals":
    let action = objcopy(outputFormat = "binary",
      input = "kernel.elf", output = "kernel.bin")
    check action.argByName("outputFormat").alias == "-O"
    let inp = action.argByName("input")
    check inp.kind == cpkPositional
    check inp.position == 0
    check inp.role == carInput
    let outp = action.argByName("output")
    check outp.kind == cpkPositional
    check outp.position == 1
    check outp.role == carOutput

# ---------------------------------------------------------------------------
# gcc — existing call still works; M9.R.2 audit extensions wired in.
# ---------------------------------------------------------------------------

suite "DSL-port M9.R.2 — gcc typed CLI surface (existing + audit)":

  test "gcc.call records -c -o out.o src.c":
    let action = gcc(source = "foo.c", output = "foo.o",
      compileOnly = true)
    check action.call.packageName == "gcc"
    check action.call.executableName == "gcc"
    check action.argByName("compileOnly").alias == "-c"
    let outArg = action.argByName("output")
    check outArg.alias == "-o"
    check outArg.role == carOutput
    check outArg.encodedValue == "foo.o"
    let srcArg = action.argByName("source")
    check srcArg.kind == cpkPositional
    check srcArg.role == carInput
    check srcArg.encodedValue == "foo.c"

  test "gcc.call audit extensions: -shared + -l + -L + -I + -D":
    let action = gcc(source = "libfoo_src.c", output = "libfoo.so",
      shared = true,
      includeDirs = @["include", "vendor/include"],
      libDirs = @["/usr/lib"],
      libs = @["pthread"],
      defines = @["NDEBUG", "VERSION=\"1.0\""],
      optimization = "2")
    check action.argByName("shared").alias == "-shared"
    let inc = action.argByName("includeDirs")
    check inc.alias == "-I"
    check inc.format == cafConcat
    check inc.repeated
    let libs = action.argByName("libs")
    check libs.alias == "-l"
    check libs.format == cafConcat
    let defs = action.argByName("defines")
    check defs.alias == "-D"
    check defs.format == cafConcat
    let opt = action.argByName("optimization")
    check opt.alias == "-O"
    check opt.format == cafConcat
    check opt.encodedValue == "2"

  test "gcc.call preprocess + make-deps extensions":
    # Use unique output basenames per call so the engine's implicit
    # target-name registry doesn't see a duplicate ``foo`` slot.
    let action = gcc(source = "preprocess_src.c",
      output = "preprocess_out.i", preprocessOnly = true)
    check action.argByName("preprocessOnly").alias == "-E"

    let depsAction = gcc(source = "makedeps_src.c",
      output = "makedeps_out.o",
      compileOnly = true, makeDepsMMD = true,
      depfileOut = "makedeps_out.d")
    check depsAction.argByName("makeDepsMMD").alias == "-MMD"
    let dep = depsAction.argByName("depfileOut")
    check dep.alias == "-MF"
    check dep.format == cafSeparate
    check dep.role == carOutput
    check dep.encodedValue == "makedeps_out.d"
