## t_cmake_trycompile_probes_are_served_across_configures — a CMake
## `try_compile()` probe is served from the shared action cache in a second
## configure, the configure computes what a cold one does, and a `repro`
## without the features keeps the old envelope.
##
## What this test owns
## -------------------
## The capability gating between the CMake fork and `repro`
## (reprobuild-pm spec/CMake-Reprobuild-Generator.md §"Metadata shape" and
## §"Cache interaction"): the fork writes a v6 `trycompile.rbsz` (relocatable
## probe actions) only when `repro capabilities` lists
## `trycompile-relocatable-probes`, and passes `--restore-cached-outputs` to a
## try_compile build only when it lists `build-action-output-replay`
## (Provider-Compile-Tiering.md §"A TryCompile hit must replay the probe's
## output"). The cases pin, through the forked `cmake` and the real `repro`:
##
##   * with this `repro`: the probes of a second configure of the same
##     project in another binary directory are all served from the cache,
##     their envelopes are v6, and the second configure's check result and
##     implicit include directories equal the first's, non-empty (the ABI
##     probe's compiler output was replayed);
##   * with an older `repro` — emulated by a stub that answers
##     `capabilities` without the two features and forwards everything else
##     to this `repro` — the fork writes v5 envelopes and keeps the scratch
##     wrapper directory on the declared PATH, the configure succeeds, and
##     the check result is the same.
##
## Needs the forked `cmake` (`REPROBUILD_FORKED_CMAKE` or the sibling
## `reprobuild-cmake` build) and a C compiler (`REPROBUILD_TEST_CC`, else
## `cc`/`gcc`/`clang` on PATH), which also compiles the stub. Skipped
## otherwise.

import std/[json, os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

from repro_test_support import CmdResult, runShell, shellCommand,
  workspaceRootForRepo

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir.parentDir

let reproBin = getEnv("REPROBUILD_REPRO",
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt))

proc findForkedCMake(): string =
  let explicit = getEnv("REPROBUILD_FORKED_CMAKE")
  if explicit.len > 0 and fileExists(explicit):
    return explicit
  let cmakeRoot = workspaceRootForRepo(repoRoot()) / "reprobuild-cmake"
  for candidate in [cmakeRoot / "build" / "bin" / addFileExt("cmake", ExeExt),
                    cmakeRoot / "_build" / "bin" / addFileExt("cmake", ExeExt)]:
    if fileExists(candidate):
      return candidate
  ""

proc findCompiler(): string =
  let explicit = getEnv("REPROBUILD_TEST_CC")
  if explicit.len > 0 and fileExists(explicit):
    return explicit
  for name in ["cc", "gcc", "clang"]:
    let found = findExe(name)
    if found.len > 0:
      return found
  ""

let cmakeBin = findForkedCMake()
let cc = findCompiler()

proc unavailable(): string =
  if not fileExists(reproBin):
    return "needs " & reproBin & " (run `just build`)"
  if cmakeBin.len == 0:
    return "needs the forked cmake (REPROBUILD_FORKED_CMAKE or ../reprobuild-cmake/build)"
  if cc.len == 0:
    return "needs a C compiler (REPROBUILD_TEST_CC, or cc/gcc/clang on PATH)"
  ""

const
  StubSource = """
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif
/* A `repro` from before `build-action-output-replay` and
   `trycompile-relocatable-probes`: it lists neither, and forwards every
   other command to the real binary. */
int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "capabilities") == 0) {
    puts("{\"provider\":{\"features\":[\"build-action-output\"]}}");
    return 0;
  }
  const char *real = getenv("REPRO_TEST_REAL_REPRO");
  if (!real) return 125;
#ifdef _WIN32
  char **quoted = calloc((size_t)argc + 1, sizeof(char *));
  for (int i = 0; i < argc; ++i) {
    const char *arg = i == 0 ? real : argv[i];
    quoted[i] = malloc(strlen(arg) + 3);
    sprintf(quoted[i], strchr(arg, ' ') ? "\"%s\"" : "%s", arg);
  }
  return (int)_spawnv(_P_WAIT, real, (const char *const *)quoted);
#else
  argv[0] = (char *)real;
  execv(real, argv);
  return 127;
#endif
}
"""
  ProjectSource = """
cmake_minimum_required(VERSION 3.20)
project(TryCompileReuse C)
include(CheckIncludeFile)
check_include_file(stdint.h TCR_HAVE_STDINT_H)
"""

let root = createTempDir("repro-tc-reuse-", "")
let source = root / "src"
createDir(source)
writeFile(source / "CMakeLists.txt", ProjectSource)

proc configure(buildDir, makeProgram, store, statsDir: string): CmdResult =
  createDir(statsDir)
  # REPROBUILD_REPRO is cleared so the generator takes CMAKE_MAKE_PROGRAM,
  # which is how the stub stands in for `repro`.
  runShell(shellCommand(@[cmakeBin, "-S", source, "-B", buildDir,
      "-G", "Reprobuild", "-DCMAKE_MAKE_PROGRAM=" & makeProgram,
      "-DCMAKE_C_COMPILER=" & cc, "--debug-trycompile"],
    @[(name: "REPROBUILD_STORE_ROOT", value: store),
      (name: "REPRO_STATS_DIR", value: statsDir),
      (name: "REPROBUILD_REPRO", value: ""),
      (name: "REPRO_TEST_REAL_REPRO", value: reproBin),
      (name: "REPRO_DAEMON", value: "off")]))

proc actionTotals(statsDir: string): tuple[total, launched, hits: int] =
  for kind, path in walkDir(statsDir):
    if kind != pcFile or not path.endsWith(".json"):
      continue
    let actions = parseJson(readFile(path)){"actions"}
    if actions.isNil:
      continue
    result.total += actions{"total"}.getInt
    result.launched += actions{"launched"}.getInt
    result.hits += actions{"cacheHit"}.getInt

proc cacheValue(buildDir, name: string): string =
  for line in readFile(buildDir / "CMakeCache.txt").splitLines:
    if line.startsWith(name & ":"):
      return line.split('=', 1)[1]
  ""

proc implicitIncludes(buildDir: string): string =
  for kind, dir in walkDir(buildDir / "CMakeFiles"):
    if kind == pcDir and fileExists(dir / "CMakeCCompiler.cmake"):
      for line in readFile(dir / "CMakeCCompiler.cmake").splitLines:
        if line.startsWith("set(CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES"):
          return line
  ""

proc envelopeVersions(buildDir: string): seq[int] =
  for kind, dir in walkDir(buildDir / "CMakeFiles" / "CMakeScratch"):
    if kind == pcDir and fileExists(dir / "trycompile.rbsz"):
      let raw = readFile(dir / "trycompile.rbsz")
      result.add(ord(raw[4]) or (ord(raw[5]) shl 8))

proc scratchWrapperOnPath(buildDir: string): bool =
  ## Whether a probe's generated `reprobuild.nim` declares a PATH naming its
  ## own scratch wrapper directory.
  for kind, dir in walkDir(buildDir / "CMakeFiles" / "CMakeScratch"):
    if kind == pcDir and fileExists(dir / "reprobuild.nim"):
      let text = readFile(dir / "reprobuild.nim").replace('\\', '/')
      if (dir.replace('\\', '/') & "/CMakeFiles/reprobuild/bin") in text:
        return true

suite "CMake try_compile probes across configures":

  test "with this repro a second configure is served and computes the same":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      let store = root / "store-new"
      let first = configure(root / "new" / "b1", reproBin, store,
        root / "new" / "s1")
      checkpoint(first.output)
      check first.code == 0
      let second = configure(root / "new" / "b2", reproBin, store,
        root / "new" / "s2")
      checkpoint(second.output)
      check second.code == 0
      let cold = actionTotals(root / "new" / "s1")
      let warm = actionTotals(root / "new" / "s2")
      checkpoint("cold " & $cold & " warm " & $warm)
      check cold.total > 0 and cold.launched > 0
      check warm.total == cold.total
      check warm.hits == warm.total
      check warm.launched == 0
      check cacheValue(root / "new" / "b1", "TCR_HAVE_STDINT_H") == "1"
      check cacheValue(root / "new" / "b2", "TCR_HAVE_STDINT_H") == "1"
      let implicit = implicitIncludes(root / "new" / "b1")
      check implicit.len > 0 and "\"\"" notin implicit
      check implicitIncludes(root / "new" / "b2") == implicit
      for version in envelopeVersions(root / "new" / "b2"):
        check version == 6
      check not scratchWrapperOnPath(root / "new" / "b2")

  test "with an older repro the fork writes v5 and still configures":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      let stub = root / addFileExt("old-repro", ExeExt)
      writeFile(root / "old_repro.c", StubSource)
      let built = runShell(shellCommand(@[cc, "-o", stub,
        root / "old_repro.c"]))
      checkpoint(built.output)
      require built.code == 0
      let run = configure(root / "old" / "b1", stub, root / "store-old",
        root / "old" / "s1")
      checkpoint(run.output)
      check run.code == 0
      check cacheValue(root / "old" / "b1", "TCR_HAVE_STDINT_H") == "1"
      let versions = envelopeVersions(root / "old" / "b1")
      check versions.len > 0
      for version in versions:
        check version == 5
      check scratchWrapperOnPath(root / "old" / "b1")
      check implicitIncludes(root / "old" / "b1").len > 0

try:
  removeDir(root)
except OSError:
  discard
