## `repro build --target=<triple>` refuses a recipe whose constructor does
## not thread the target, and leaves nothing behind that a consumer or a
## publisher could take for a target build.
##
## ReproOS-Add-On-Mode A15. Measured before the guard, at reprobuild
## 9ed83d2f8: `repro build --target=armv7-unknown-linux-musleabihf` of the
## autotools zlib recipe exited 0 with an x86-64 `libz.so` under
## `install@armv7-…` and a realization sidecar saying armv7. This is the same
## shape on a recipe small enough to build offline: an `autotools_package`
## whose `configure` writes a Makefile that runs the host `cc`.
##
## Black box: the built `build/bin/repro`, every root in a fresh temp
## directory, nothing mocked. The native build of the same tree is the
## control. It must succeed and write the install mirror and the staging
## directory, which shows the cross run's empty `.repro/output` is a
## refusal and not a recipe that never writes anything.
##
## Assertions, cross run first:
##   1. exit status non-zero, and the refusal names the recipe, the
##      constructor and the triple;
##   2. no build action launched (`--log=actions`), so there is nothing a
##      cache or a publisher could take;
##   3. no `.repro/output` at all, so neither `install@<triple>` nor a
##      `<artifact>@<triple>` staging directory;
##   4. the native control exits 0, launches actions and writes
##      `install/usr/bin/hello` and `hello/hello`;
##   5. a cross run over the native tree is refused again and changes no
##      byte of the native outputs.
##
## Falsifiability: with `requireCrossTargetConsulted` reduced to a bare
## `return`, the cross run exits 0, launches the autotools actions and writes
## an x86-64 `install@armv7-unknown-linux-musleabihf/usr/bin/hello`, failing
## 1, 2 and 3.
##
## The second case is the object check that backstops the refusal
## (CLI/build.md §"Cross Targets: `--target`", approved by Zahary Karadjov
## 2026-10-30): a recipe that reads `activeCrossTarget()` -- so the
## constructor guard lets it through -- but threads nothing still compiles
## for the host. Its staged mirror is refused by its bytes: exit non-zero,
## the message names the x86-64 object, and nothing is left under
## `install@<triple>`. Falsifiability: with the check fragment removed from
## `emitInstallMirrorStorePublish`, the run exits 0 and mirrors an x86-64
## `install@armv7-…/usr/bin/hello`.
##
## Skip rule: `sh`, `cc` or `make` missing on PATH, or `build/bin/repro`
## unbuilt -- except in a gate run (`REPROBUILD_GATE_RUN=1`, exported by
## `scripts/run_tests.sh`, which builds `build/bin/repro` first), where an
## unbuilt binary FAILS the case instead of skipping it.

import std/[algorithm, monotimes, os, osproc, strtabs, strutils, tempfiles,
  unittest]

import repro_test_support/reasoned_skip

const
  ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)
  Triple = "armv7-unknown-linux-musleabihf"

  Recipe = """
import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package hostOnly:
  defaultToolProvisioning "path"
  nativeBuildDeps:
    "gcc"
    "make"
  build:
    let pkg = autotools_package(srcDir = "./src")
    discard pkg.executable("hello")
"""

  # A configure that ignores every target hint, as most upstreams do when
  # nothing passes them one: the Makefile runs the host `cc`.
  Configure = """#!/bin/sh
prefix=/usr
for a in "$@"; do case "$a" in --prefix=*) prefix=${a#--prefix=};; esac; done
srcdir=$(dirname "$0")
cat > Makefile <<MK
all: hello
hello: $srcdir/hello.c
	cc -o hello $srcdir/hello.c
install: hello
	mkdir -p \$(DESTDIR)$prefix/bin
	cp hello \$(DESTDIR)$prefix/bin/hello
MK
"""

  # Lifts the guard by reading the slot, then threads nothing: the
  # constructor runs the host compiler exactly as `Recipe` would.
  DishonestRecipe = """
import repro_project_dsl
import repro_dsl_stdlib/active_context
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package hostOnly:
  defaultToolProvisioning "path"
  nativeBuildDeps:
    "gcc"
    "make"
  build:
    discard activeCrossTarget()
    let pkg = autotools_package(srcDir = "./src")
    discard pkg.executable("hello")
"""

  HelloC = "#include <stdio.h>\nint main(void){puts(\"hi\");return 0;}\n"

proc createProject(root: string; recipe = Recipe): string =
  result = root / "proj"
  createDir(result / "src")
  writeFile(result / "repro.nim", recipe)
  writeFile(result / "src/configure", Configure)
  setFilePermissions(result / "src/configure",
    {fpUserRead, fpUserWrite, fpUserExec})
  writeFile(result / "src/hello.c", HelloC)

proc runBuild(root, project: string; args: seq[string]):
    tuple[code: int, output: string] =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  env["REPROBUILD_WORK_ROOT"] = root / "work"
  env["REPROBUILD_ACTION_CACHE_ROOT"] = root / "action-cache"
  env["REPRO_LOCAL_STORE"] = root / "store"
  env["REPRO_STORE_ROOT"] = root / "cas"
  env["REPRO_CACHE_DISABLE"] = "1"
  env.del("REPRO_VARIANTS")
  # The mirror action's object check runs `repro-install-mirror-publish`,
  # built beside `repro`.
  env["PATH"] = reproBinary.parentDir & PathSep & getEnv("PATH")
  let log = root / ("build-" & $getMonoTime().ticks & ".log")
  let argv = @[reproBinary, "build", "--daemon=off", "--progress=quiet",
    "--log=actions"] & args
  let p = startProcess(findExe("sh"), args = @["-c",
    quoteShellCommand(argv) & " > " & quoteShell(log) & " 2>&1"],
    workingDir = project, env = env, options = {poParentStreams})
  let code = p.waitForExit()
  p.close()
  (code, readFile(log))

proc launchedActions(output: string): int =
  for line in output.splitLines():
    if line.startsWith("action: ") and " launched=true " in line:
      inc result

proc outputDigest(project: string): seq[string] =
  ## Every file under `.repro/output` with its bytes, sorted: two equal
  ## results mean no byte changed.
  let root = project / ".repro" / "output"
  for path in walkDirRec(root):
    result.add(path.relativePath(root) & "\t" & readFile(path))
  result.sort()


suite "--target refuses a recipe that does not thread it, end to end":

  test "t_target_build_refuses_a_recipe_that_does_not_thread_it":
    if not fileExists(reproBinary) and getEnv("REPROBUILD_GATE_RUN") == "1":
      checkpoint(reproBinary & " is missing in a gate run")
      check false
    elif not fileExists(reproBinary) or findExe("sh").len == 0 or
        findExe("cc").len == 0 or findExe("make").len == 0:
      skip("build/bin/repro unbuilt, or sh/cc/make missing on PATH")
    else:
      let root = createTempDir("target-refusal-", "")
      defer: removeDir(root)
      let project = createProject(root)
      let refusal = "recipe 'hostOnly': autotools_package cannot build " &
        "for --target '" & Triple & "'"

      # 1-3: the cross run on a fresh tree.
      let cross = runBuild(root, project, @["--target=" & Triple])
      checkpoint(cross.output)
      check cross.code != 0
      check refusal in cross.output
      check launchedActions(cross.output) == 0
      check not dirExists(project / ".repro" / "output")

      # 4: the control.
      let native = runBuild(root, project, @[])
      checkpoint(native.output)
      require native.code == 0
      check launchedActions(native.output) > 0
      let mirror = project / ".repro/output/install/usr/bin/hello"
      check fileExists(mirror)
      check fileExists(project / ".repro/output/hello/hello")
      let before = outputDigest(project)

      # 5: refused again over the native tree, which it leaves untouched.
      let again = runBuild(root, project, @["--target=" & Triple])
      checkpoint(again.output)
      check again.code != 0
      check refusal in again.output
      check launchedActions(again.output) == 0
      check not dirExists(project / ".repro/output/install@" & Triple)
      check not dirExists(project / ".repro/output/hello@" & Triple)
      check outputDigest(project) == before

  test "t_target_build_refuses_host_objects_a_recipe_claims_to_thread":
    if not fileExists(reproBinary) and getEnv("REPROBUILD_GATE_RUN") == "1":
      checkpoint(reproBinary & " is missing in a gate run")
      check false
    elif not fileExists(reproBinary) or findExe("sh").len == 0 or
        findExe("cc").len == 0 or findExe("make").len == 0:
      skip("build/bin/repro unbuilt, or sh/cc/make missing on PATH")
    else:
      let root = createTempDir("target-object-check-", "")
      defer: removeDir(root)
      let project = createProject(root, DishonestRecipe)
      let cross = runBuild(root, project, @["--target=" & Triple])
      checkpoint(cross.output)
      check cross.code != 0
      check ("are not for --target '" & Triple & "'") in cross.output
      check "bin/hello: x86-64 (EM_X86_64)" in cross.output
      let keyed = project / ".repro/output/install@" & Triple
      check not fileExists(keyed / "usr/bin/hello")
      check not fileExists(project / ".repro/output/.realization-info@" &
        Triple)
