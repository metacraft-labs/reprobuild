## The portable Linux release launcher must not make the engine self-spawn
## the glibc loader.
##
## reprobuild-pm issue 2026-09-26 "release-launcher-makes-the-engine-self-
## spawn-the-loader". The POSIX release archive does not ship ELF images in
## `bin/`: `scripts/relocate_release_posix.sh` replaces each `bin/<app>` with
## a `/bin/sh` launcher that runs `bin/.<app>.real` through the BUNDLED loader
## (`exec <prefix>/lib/ld-linux-*.so.2 --library-path <prefix>/lib
## <prefix>/bin/.<app>.real "$@"`) and exports
## `REPRO_PUBLIC_CLI_PATH=<prefix>/bin/reprobuild`. Under that launcher
## `/proc/self/exe` -- hence `getAppFilename()` -- is the LOADER, so every
## place the engine re-executes "itself" by that name runs
## `<loader> <verb> …`, which rtld reads as "map the program `<verb>`".
##
## Two consumers of that mistake are reached by the single build below, and
## each fails it in its own recognisable way:
##
##   1. The interface-extraction helper spawn (`__repro-extract-interface`)
##      and the provider-compile helper (`__repro-compile-provider`). Failure:
##      `__repro-extract-interface: error while loading shared libraries:
##      __repro-extract-interface: cannot open shared object file` -- the CI
##      line from the issue, byte for byte.
##   2. The recipe compile's `-d:reproBin`, which a `dslDeps:` block's macro
##      expansion calls back through
##      (`staticExec(reproBin & " internal resolve-package …")`). `staticExec`
##      does not fail on a failed command; the dependency silently resolves to
##      nothing and its import is dropped. The consumer recipe below USES a
##      symbol the dependency exports, so a dropped import is a compile error
##      (`undeclared identifier: 'launcherExporterGreeting'`) rather than a
##      green build that quietly lost a feature.
##
## WHAT IS REAL HERE. The engine (`build/bin/reprobuild` from this checkout,
## copied to `bin/.reprobuild.real`), the loader it actually uses (its own
## PT_INTERP, read from the ELF, copied to `lib/`), the launcher text (written
## by `scripts/release/write_posix_loader_launcher.sh`, the same script the
## release relocation uses), and a real `repro build` with a cold action cache.
##
## WHAT IS NOT, AND WHY:
##
##   * `lib/` holds the loader, the monitor shim and SYMLINKS to the shared
##     objects of the inherited `LD_LIBRARY_PATH`, not the archive's copied
##     closure. The copied engine keeps the DT_RPATH `scripts/build_apps.sh`
##     gave it, which rtld honours under explicit-loader invocation; what it
##     does not honour is `LD_LIBRARY_PATH`, through which the dev shell
##     supplies the bare-name dlopen()s (libssl, libclingo, libzstd), so those
##     are linked into lib/ where the archive puts its copies. Copying the
##     real ldd closure would test `relocate_release_posix.sh`'s walk, which
##     is not what this defect is about and is covered by the release legs.
##   * `REPROBUILD_SOURCE_ROOT` names this checkout instead of an archive's
##     `share/repro/source`, the way the Nix package's wrapper names its
##     sources. Staging the full source closure is
##     `scripts/release/stage_release_sources.sh`'s job and its own gate
##     (`check_release_source_closure.sh`); it is not involved here.
##   * No thin client: the test runs the ENGINE's launcher directly. The thin
##     client's own resolution of the engine through `REPRO_PUBLIC_CLI_PATH`
##     is covered by `t_thin_daemon_client`.
##
## THE CONTROL. The same build, run through the loader by hand WITHOUT the
## launcher's `REPRO_PUBLIC_CLI_PATH`, must fail with the rtld signature.
## That proves the fabricated tree really makes `getAppFilename()` the loader
## -- without it, a tree in which the engine still saw its own image would
## pass the main case without exercising anything.
##
## Linux only: the loader launcher is a Linux artifact (macOS archives use
## LC_RPATH, Windows ships the PE images directly).

import std/[os, osproc, streams, strtabs, strutils, tempfiles, times, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

# Ambient-execution hatch. This test exists to run a launcher script and a
# loader as the release archive does; no typed execution profile describes
# either. `git grep uncontrolled` is the audit surface.
import repro_core/ambient_execution

const
  ExporterName = "launcher_exporter"
    ## The `dslDeps:` dependency, resolved as a sibling of the consumer.
  ExportedSymbol = "launcherExporterGreeting"
  RtldSignature = "error while loading shared libraries"

proc elfInterpreter(path: string): string =
  ## PT_INTERP of the ELF64 little-endian image at `path` (the loader the
  ## kernel would map for it), read straight from the program headers so the
  ## test needs no `patchelf`/`readelf` on PATH.
  ## https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.pheader.html
  let data = readFile(path)
  doAssert data.len > 64 and data[0 .. 3] == "\x7fELF",
    path & " is not an ELF image"
  doAssert data[4] == '\x02' and data[5] == '\x01',
    path & " is not ELF64 little-endian"
  proc u16(off: int): int = int(data[off].uint8) or
    (int(data[off + 1].uint8) shl 8)
  proc u64(off: int): int =
    for i in countdown(7, 0):
      result = (result shl 8) or int(data[off + i].uint8)
  const PtInterp = 3
  let phoff = u64(0x20)
  let phentsize = u16(0x36)
  let phnum = u16(0x38)
  for i in 0 ..< phnum:
    let ph = phoff + i * phentsize
    if u16(ph) == PtInterp and u16(ph + 2) == 0:
      let off = u64(ph + 0x08)
      let size = u64(ph + 0x20)
      return data[off ..< off + size].strip(chars = {'\0'})
  raise newException(ValueError, path & " has no PT_INTERP")

type LauncherTree = object
  prefix: string
  launcher: string ## `<prefix>/bin/reprobuild`, the launcher script
  real: string     ## `<prefix>/bin/.reprobuild.real`, the engine image
  loader: string   ## `<prefix>/lib/<loader>`

proc buildLauncherTree(prefix: string): LauncherTree =
  ## Lay out `<prefix>/{bin,lib}` the way the relocated archive does.
  let engine = requireHostBinary(reproBinaryPath(stem = "reprobuild"))
  let interp = elfInterpreter(engine)
  result.prefix = prefix
  result.launcher = prefix / "bin" / "reprobuild"
  result.real = prefix / "bin" / ".reprobuild.real"
  result.loader = prefix / "lib" / extractFilename(interp)
  createDir(prefix / "bin")
  createDir(prefix / "lib")
  copyFile(engine, result.real)
  copyFile(interp, result.loader) # follows a symlinked interpreter
  # The archive ships the monitor shim in lib/ (release.yml copies build/lib),
  # and io-mon finds it as `<appDir>/../lib` -- under the loader `<appDir>` is
  # lib/ itself, so that is where it must be for the monitored actions to run.
  let shim = requireBinary(monitorShimPath(ReprobuildRepoRoot),
    "reprobuild.test_fixtures.monitor_shim")
  copyFile(shim, prefix / "lib" / extractFilename(shim))
  # The libraries the engine dlopen()s by bare name (libssl/libcrypto,
  # libclingo, libzstd) reach it from `build/bin` through LD_LIBRARY_PATH,
  # which the dev shell sets. rtld ignores LD_LIBRARY_PATH when it is given
  # `--library-path`, which is exactly why the archive bundles them into
  # lib/. Mirror that: link every shared object the inherited LD_LIBRARY_PATH
  # offers into lib/, first directory winning, as rtld's own search would.
  for dir in getEnv("LD_LIBRARY_PATH").split(PathSep):
    if dir.len == 0 or not dirExists(dir):
      continue
    for kind, path in walkDir(dir):
      let name = extractFilename(path)
      if kind notin {pcFile, pcLinkToFile} or ".so" notin name:
        continue
      let dest = prefix / "lib" / name
      if not fileExists(dest) and not symlinkExists(dest):
        createSymlink(path, dest)
  for f in [result.real, result.loader]:
    inclFilePermissions(f, {fpUserExec, fpUserRead})
  let writer = ReprobuildRepoRoot / "scripts" / "release" /
    "write_posix_loader_launcher.sh"
  let bash = uncontrolledFindExe("bash")
  doAssert bash.len > 0, "bash is required to run " & writer
  let r = uncontrolledExecCmdEx(quoteShellCommand(
    [bash, writer, result.launcher, extractFilename(interp), "yes"]))
  doAssert r.exitCode == 0, "launcher writer failed:\n" & r.output

proc writeProjects(root, token: string): string =
  ## The exporter and the consumer, siblings under `root` (`dslDeps:`
  ## resolves `<consumer>/../<name>`). `token` makes both recipes unique to
  ## this run so nothing an earlier run compiled can be served for them.
  ## Returns the consumer's directory.
  createDir(root / ExporterName)
  writeFile(root / ExporterName / "repro.nim",
    "# run " & token & "\n" &
    "const " & ExportedSymbol & "* = \"hello from the exporter\"\n")
  result = root / "consumer"
  createDir(result)
  # The use is under `reproInterfaceMode`: `dslDeps:` imports are emitted
  # only into the recipe's interface compile (the only compile handed
  # `-d:reproBin`), so that is the compile whose success depends on the
  # resolution.
  writeFile(result / "repro.nim",
    "import repro_project_dsl\n\n" &
    "# run " & token & "\n" &
    "package launcherConsumer:\n" &
    "  dslDeps:\n" &
    "    \"" & ExporterName & "\"\n" &
    "  when defined(reproInterfaceMode):\n" &
    "    const consumerGreeting = " & ExportedSymbol & "\n" &
    "    static: doAssert consumerGreeting.len > 0\n" &
    "  build:\n" &
    "    discard\n")

proc runBuild(program: string; args: seq[string]; cwd, cacheRoot: string;
              unset: openArray[string] = []): tuple[code: int; output: string] =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  # Inherited values would decide the answer for the engine: the launcher
  # must be the one that names the public CLI, and nothing may point the
  # engine at an image other than the one under test.
  for name in ["REPRO_PUBLIC_CLI_PATH", "REPRO_FULL_CLI",
               "REPROBUILD_LIBS_DIR", "REPROBUILD_REPO_ROOT"]:
    env.del(name)
  for name in unset:
    env.del(name)
  env["REPROBUILD_SOURCE_ROOT"] = ReprobuildRepoRoot
  env["REPROBUILD_ACTION_CACHE_ROOT"] = cacheRoot
  env["REPRO_CACHE_DISABLE"] = "1"
  env["REPROBUILD_NO_RUNQUOTA"] = "1"
  env["REPROBUILD_PROGRESS"] = "quiet"
  env["REPRO_DAEMON"] = "off"
  var p = uncontrolledStartProcess(program, workingDir = cwd, args = args,
    env = env, options = {poStdErrToStdOut})
  try:
    result.output = p.outputStream.readAll()
    result.code = p.waitForExit()
  finally:
    p.close()

const BuildArgs = @["build", "--tool-provisioning=path", "--progress=none"]

suite "the release launcher does not make the engine self-spawn the loader":
  test "control: through the loader without the launcher, the engine spawns the loader":
    when not defined(linux):
      skip("the loader launcher is a Linux-only artifact; on " & hostOS &
        " the release ships its images directly")
    else:
      let root = createTempDir("repro-launcher-control-", "")
      defer: removeDirEventually(root)
      let tree = buildLauncherTree(root / "prefix")
      let consumer = writeProjects(root / "projects",
        "control-" & $getCurrentProcessId() & "-" & $epochTime())
      # Exactly the launcher's exec line, minus the variable it exports.
      let r = runBuild(tree.loader,
        @["--library-path", tree.prefix / "lib", tree.real] & BuildArgs,
        consumer, root / "action-cache")
      checkpoint(r.output)
      check r.code != 0
      check r.output.contains(RtldSignature)

  test "repro build through the launcher extracts the interface and resolves dslDeps":
    when not defined(linux):
      skip("the loader launcher is a Linux-only artifact; on " & hostOS &
        " the release ships its images directly")
    else:
      let root = createTempDir("repro-launcher-build-", "")
      defer: removeDirEventually(root)
      let tree = buildLauncherTree(root / "prefix")
      let consumer = writeProjects(root / "projects",
        "launcher-" & $getCurrentProcessId() & "-" & $epochTime())
      let r = runBuild(tree.launcher, BuildArgs, consumer,
        root / "action-cache")
      checkpoint(r.output)
      check not r.output.contains(RtldSignature)
      check not r.output.contains("undeclared identifier")
      check r.code == 0
