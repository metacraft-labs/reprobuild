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
## The third case is the publication boundary: every edge tagged for
## publication (the install mirror AND the autotools stage copies) is checked
## by the engine before it counts as succeeded, so the stage copy itself is
## reported failed, never recorded -- the binary-cache and peer-cache
## publishers run only on a recorded success -- and leaves no
## `hello@<triple>`. Measured why a cache server is not part of this test:
## a path-mode recipe like this one has no complete cache identity
## (`binary-cache-identity-incomplete`: source closure, dependencies and
## toolchain unbound), so not even the native build publishes; a server
## could only ever count zero. Falsifiability: against an engine without
## the boundary (reprobuild 600a079f4, whose only check sat in the mirror
## edge) the stage copy succeeds and writes an x86-64
## `hello@armv7-…/hello`.
##
## Skip rule: `sh`, `cc` or `make` missing on PATH, or `build/bin/repro`
## unbuilt -- except in a gate run (`REPROBUILD_GATE_RUN=1`, exported by
## `scripts/run_tests.sh`, which builds `build/bin/repro` first), where any
## of them FAILS the case instead of skipping it.

import std/[algorithm, monotimes, net, os, osproc, strtabs, strutils,
  tempfiles, unittest]
import repro_peer_cache/auth

import repro_test_support/reasoned_skip

const
  ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)
  Triple = "armv7-unknown-linux-musleabihf"
  # The guard case needs a triple no adapter threads for autotools: under
  # a zig triple `autotools_package` threads the target itself. The
  # generic stub's riscv64 has an object rule and no toolchain.
  GuardTriple = "riscv64-unknown-linux-gnu"

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

  # Claims to build for the target -- autotools_package threads a zig
  # target, with CC naming the zig wrapper -- but its configure writes a
  # Makefile that runs the host `cc` whatever CC says, as some upstreams do.
  # So the staged objects are the host's, and only their bytes show it.
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
    "zig >=0.13 <0.14"
  build:
    discard activeCrossTarget()
    let pkg = autotools_package(srcDir = "./src")
    discard pkg.executable("hello")
"""

  HelloC = "#include <stdio.h>\nint main(void){puts(\"hi\");return 0;}\n"

  # Same source natively and for the target: `compile` / `link` thread a
  # zig target themselves (Reprobuild-Standard-Library.md, "Worked Example:
  # Cross-Compilation", step 4). `zig` is declared once, unconditionally.
  CExecutableRecipe = """
import repro_project_dsl
import repro_dsl_stdlib/constructors

package helloC:
  defaultToolProvisioning "path"
  nativeBuildDeps:
    "gcc"
    "zig >=0.13 <0.14"
  build:
    discard c_executable("hello", @["src/hello.c"])
"""

proc createProject(root: string; recipe = Recipe): string =
  result = root / "proj"
  createDir(result / "src")
  writeFile(result / "repro.nim", recipe)
  writeFile(result / "src/configure", Configure)
  setFilePermissions(result / "src/configure",
    {fpUserRead, fpUserWrite, fpUserExec})
  writeFile(result / "src/hello.c", HelloC)

proc runRepro(root: string; args: seq[string];
               extraEnv: openArray[(string, string)]):
    tuple[code: int, output: string] =
  ## `build/bin/repro <args>` with the test's roots and ``extraEnv``.
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  env["REPRO_LOCAL_STORE"] = root / "store"
  env.del("REPRO_VARIANTS")
  for (k, v) in extraEnv: env[k] = v
  let log = root / ("repro-" & $getMonoTime().ticks & ".log")
  let p = startProcess(findExe("sh"), args = @["-c",
    quoteShellCommand(@[reproBinary] & args) & " > " & quoteShell(log) &
    " 2>&1"], workingDir = root, env = env, options = {poParentStreams})
  let code = p.waitForExit()
  p.close()
  (code, readFile(log))

proc startCacheServer(root: string): (Process, string) =
  ## A real `repro-binary-cache` on a loopback port: the server a
  ## `repro cache publish` reaches. Not a mock -- the point is what arrives.
  let listener = newSocket()
  listener.bindAddr(Port(0), "127.0.0.1")
  let port = listener.getLocalAddr()[1]
  listener.close()
  let server = startProcess(reproBinary.parentDir /
    addFileExt("repro-binary-cache", ExeExt),
    args = @["--root=" & root / "cache", "--listen=127.0.0.1:" & $port],
    options = {poParentStreams})
  for _ in 0 ..< 200:
    let probe = newSocket()
    try:
      probe.connect("127.0.0.1", port)
      probe.close()
      return (server, "http://127.0.0.1:" & $port)
    except OSError:
      probe.close()
    sleep(50)
  raise newException(IOError, "repro-binary-cache did not start listening")

proc manifestCount(root: string): int =
  if dirExists(root / "cache" / "manifests"):
    for path in walkDirRec(root / "cache" / "manifests"):
      if path.endsWith(".manifest"): inc result

const EmArm = 40'u8

proc isElf(path: string; machine: uint8): bool =
  ## Whether ``path`` is an ELF file for ``machine`` (``e_machine``, LSB).
  if not fileExists(path): return false
  let head = readFile(path)
  head.len > 20 and head.startsWith("\x7fELF") and uint8(head[18]) == machine

proc isHostElf(path: string): bool =
  fileExists(path) and readFile(path).startsWith("\x7fELF") and
    not isElf(path, EmArm)

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

proc unmetPrecondition(extraTools: openArray[string] = []): string =
  ## Why this file's cases cannot run here, or "". A gate run
  ## (`REPROBUILD_GATE_RUN=1`, exported by `scripts/run_tests.sh`) FAILS on
  ## any of these instead of skipping, so a gate never passes by skipping.
  if not fileExists(reproBinary): return reproBinary & " is not built"
  for tool in @["sh", "cc", "make"] & @extraTools:
    if findExe(tool).len == 0: return tool & " is not on PATH"
  ""

template requirePreconditions(body: untyped) =
  requirePreconditions([], body)

template requirePreconditions(extraTools: openArray[string];
                              body: untyped) =
  let unmet = unmetPrecondition(extraTools)
  if unmet.len > 0 and getEnv("REPROBUILD_GATE_RUN") == "1":
    checkpoint(unmet & " in a gate run")
    check false
  elif unmet.len > 0:
    skip(unmet)
  else:
    body

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
    requirePreconditions:
      let root = createTempDir("target-refusal-", "")
      defer: removeDir(root)
      let project = createProject(root)
      let refusal = "recipe 'hostOnly': autotools_package cannot build " &
        "for --target '" & GuardTriple & "'"

      # 1-3: the cross run on a fresh tree.
      let cross = runBuild(root, project, @["--target=" & GuardTriple])
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
      let again = runBuild(root, project, @["--target=" & GuardTriple])
      checkpoint(again.output)
      check again.code != 0
      check refusal in again.output
      check launchedActions(again.output) == 0
      check not dirExists(project / ".repro/output/install@" & GuardTriple)
      check not dirExists(project / ".repro/output/hello@" & GuardTriple)
      check outputDigest(project) == before

  test "t_target_build_refuses_host_objects_a_recipe_claims_to_thread":
    requirePreconditions(["zig"]):
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
      # The stage copy is a second edge tagged for publication; it is refused
      # at the publication boundary, not only the mirror edge.
      check not fileExists(project / ".repro/output/hello@" & Triple / "hello")

  test "t_target_build_fails_every_publication_edge_holding_host_objects":
    requirePreconditions(["zig"]):
      let root = createTempDir("target-publish-gate-", "")
      defer: removeDir(root)
      let project = createProject(root, DishonestRecipe)
      let cross = runBuild(root, project, @["--target=" & Triple])
      checkpoint(cross.output)
      check cross.code != 0
      # The stage copy is not the mirror edge; it fails at the engine's
      # publication boundary, so it is never recorded -- and the binary-cache
      # and peer-cache publishers only run on a recorded success.
      var stageFailed = false
      for line in cross.output.splitLines():
        if line.startsWith("action: autotools-stage-executable-") and
            " status=asFailed " in line:
          stageFailed = true
      check stageFailed
      check "output object(s) are not for --target '" & Triple & "'" in
        cross.output
      check not fileExists(project / ".repro/output/hello@" & Triple / "hello")

  test "t_target_build_threads_a_zig_target_into_c_executable":
    requirePreconditions(["zig"]):
      let root = createTempDir("target-c-executable-", "")
      defer: removeDir(root)
      let project = createProject(root, CExecutableRecipe)
      let cross = runBuild(root, project, @["--target=" & Triple])
      checkpoint(cross.output)
      check cross.code == 0
      check launchedActions(cross.output) > 0
      # The link wrote an ARM hard-float ELF at the target-keyed path
      # (EM_ARM = 40, ELFCLASS32, EF_ARM_ABI_FLOAT_HARD).
      let armExe = project / ("hello@" & Triple)
      check isElf(armExe, EmArm)
      if fileExists(armExe):
        let elf = readFile(armExe)
        check elf[4] == '\x01'
        check (uint8(elf[37]) and 0x04'u8) != 0

  test "t_target_publish_admits_target_bytes_and_refuses_host_bytes":
    # A cross build's bytes reach a cache by `repro cache publish` under an
    # identity naming the consumer's platform (Binary-Caches.md, "Publishing
    # for a host that cannot build"); a source build's own identity stays
    # pending, so `repro build` never publishes one. This is that route,
    # with the rpi2 profile's platform (armv7 / linux / gnu / "").
    requirePreconditions(["zig"]):
      let root = createTempDir("target-publish-route-", "")
      defer: removeDir(root)
      let project = createProject(root, CExecutableRecipe)
      let cross = runBuild(root, project, @["--target=" & Triple])
      checkpoint(cross.output)
      require cross.code == 0
      let native = runBuild(root, project, @[])
      checkpoint(native.output)
      require native.code == 0
      # Both builds' outputs coexist: the target build's at its keyed
      # path, the native build's at the bare one (CLI/build.md, "Cross
      # Targets"). Nothing is copied aside.
      let armExe = project / ("hello@" & Triple)
      let hostExe = project / "hello"
      check isElf(armExe, EmArm)
      check isHostElf(hostExe)
      require fileExists(armExe) and fileExists(hostExe)
      let (server, url) = startCacheServer(root)
      defer:
        server.terminate()
        discard server.waitForExit()
        server.close()
      discard loadOrGenerateKeypair(root / "producer.cert", root / "producer.key")
      let env = @[("REPRO_BINARY_CACHE_URL", url),
                  ("REPRO_BINARY_CACHE_KEY_PATH", root / "producer.key"),
                  ("REPRO_BINARY_CACHE_CERT_PATH", root / "producer.cert")]
      proc identity(version: string): seq[string] =
        @["--package-name=helloC", "--package-version=" & version,
          "--platform-cpu=armv7", "--platform-os=linux", "--platform-abi=gnu",
          "--toolchain-name=zig", "--toolchain-version=0.13.0",
          "--provider-revision=" & repeat("ab", 32)]
      proc keyFor(version: string): string =
        let r = runRepro(root, @["cache", "derive-key"] & identity(version), env)
        checkpoint(r.output)
        r.output.strip().splitLines()[^1].strip()
      # Positive control: the threaded build's ARM bytes are published.
      let good = runRepro(root, @["cache", "publish", keyFor("1"), armExe] &
        identity("1"), env)
      checkpoint(good.output)
      check good.code == 0
      check manifestCount(root) == 1
      # Negative: host bytes under the same target identity publish nothing.
      let bad = runRepro(root, @["cache", "publish", keyFor("2"), hostExe] &
        identity("2"), env)
      checkpoint(bad.output)
      check bad.code == 2
      check "(the object check)" in bad.output
      check "EM_X86_64" in bad.output
      check manifestCount(root) == 1
