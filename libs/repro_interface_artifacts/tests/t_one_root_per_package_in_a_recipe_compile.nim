## A recipe compile puts ONE root of each bootstrap package on its search
## path: the workspace sibling's copy replaces the engine's staged copy
## (Cross-Repo-Source-Consumption.md §9.2b).
##
## THE DEFECT. A `repro exec` of codetracer's native recorder ran a
## recipe compile whose command carried BOTH the workspace's `nim-cli-spec`
## sibling (`…/nim-cli-spec/src`) and the engine's staged nim-cli-spec
## (`/nix/store/…-source/src`) on `--path`. Nim resolved each import against
## the two roots separately, and the compile failed with `cannot open file:
## clispec/config_check` and then a `CliModel` type mismatch between the two
## copies. The scratch reproduction of 2026-11-22 (engine 0.2.29) showed the
## same pair for `repro_test_adapters`, `shm_queue`, `shm_gset` and `clispec`.
##
## The two copies came from two layers of the command that resolved the same
## package differently when the compile's work directory is a reprobuild tree
## (the cross-repo producer path compiles against the engine's own staged
## source, `reprobuildLibraryWorkDir`): one ranked the consumer workspace's
## sibling above the root the engine seeded into `$CLI_SPEC_SRC`, the other
## took `$CLI_SPEC_SRC` first, seeded or not. Both layers now take the one
## sibling-first resolver (`bootstrapSiblingPackagePathFlags`), so each
## package gets exactly one root.
##
## Fixture (real directory trees carrying the marker modules the resolvers
## probe, and the real command assembly, `providerCompileCommand`, which
## shares its path layers with the interface extraction):
##
##   <tmp>/store/sdk                  the engine's staged reprobuild source
##   <tmp>/store/clispec/src          the engine's staged nim-cli-spec,
##                                    seeded into $CLI_SPEC_SRC the way the
##                                    CLI seeds it (`seedSourcePackageEnvironment`)
##   <tmp>/ws/nim-cli-spec/src        the workspace sibling, which carries
##                                    `clispec/config_check.nim` the staged
##                                    copy lacks
##   <tmp>/ws/consumer                the process's working directory
##
## Cases:
##
##   1. the sibling's copy is the only clispec root on the command, in both
##      `--path:` and `--excludePath:` (against 98a3006d24 unfixed, the staged
##      root is on it as well, so this case fails);
##   2. control: with no sibling checked out, the staged copy is the one
##      root, so the compile still finds the package.
##
## No mocks. The process environment and working directory are changed, so
## this binary runs on its own.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts

proc touch(path: string) =
  createDir(path.parentDir)
  writeFile(path, "")

proc pathRoots(command: openArray[string]; flag: string): seq[string] =
  for arg in command:
    if arg.startsWith(flag): result.add(arg[flag.len .. ^1])

proc clispecRoots(command: openArray[string]): seq[string] =
  ## The distinct `--path:` roots that carry the package's marker module.
  for root in pathRoots(command, "--path:"):
    if fileExists(root / "clispec.nim") and root notin result:
      result.add(root)

const ClearedEnv = ["CLI_SPEC_SRC", SeededSourceEnvironmentVar,
  "REPROBUILD_LIBS_DIR", "REPROBUILD_REPO_ROOT", "REPROBUILD_SOURCE_ROOT"]
  ## An explicit `$CLI_SPEC_SRC` outranks every candidate by design (the dev
  ## shell exports one), and the SDK overrides would move the SDK root away
  ## from the fixture's.

suite "one root per package in a recipe compile":
  var tmp, savedCwd: string
  var savedEnv: seq[(string, string, bool)]

  setup:
    tmp = createTempDir("repro-one-root-per-package-", "")
    savedCwd = getCurrentDir()
    savedEnv = @[]
    for name in ClearedEnv:
      savedEnv.add((name, getEnv(name), existsEnv(name)))
      delEnv(name)
    touch(tmp / "store" / "sdk" / "libs" / "repro_project_dsl" / "src" /
      "repro_project_dsl.nim")
    touch(tmp / "store" / "clispec" / "src" / "clispec.nim")
    touch(tmp / "store" / "clispec" / "src" / "clispec" / "model.nim")
    touch(tmp / "ws" / "consumer" / "repro.nim")
    seedSourcePackageEnvironment([("CLI_SPEC_SRC",
      tmp / "store" / "clispec" / "src")])
    setCurrentDir(tmp / "ws" / "consumer")

  teardown:
    setCurrentDir(savedCwd)
    clearSeededSourcePackageEnvironment()
    for (name, value, present) in savedEnv:
      if present: putEnv(name, value) else: delEnv(name)
    removeDir(tmp)

  proc providerCommand(): seq[string] =
    # The cross-repo producer path: the work directory is the engine's staged
    # reprobuild source, not the consumer.
    providerCompileCommand(tmp / "ws" / "consumer" / "repro.nim",
      tmp / "out" / "provider", tmp / "store" / "sdk", tmp / "scratch")

  test "the workspace sibling's copy replaces the staged one":
    let sibling = tmp / "ws" / "nim-cli-spec" / "src"
    touch(sibling / "clispec.nim")
    touch(sibling / "clispec" / "model.nim")
    touch(sibling / "clispec" / "config_check.nim")
    let command = providerCommand()
    check clispecRoots(command) == @[sibling]
    let staged = tmp / "store" / "clispec" / "src"
    check staged notin pathRoots(command, "--path:")
    check staged notin pathRoots(command, "--excludePath:")

  test "with no sibling, the staged copy is the one root":
    let command = providerCommand()
    check clispecRoots(command) == @[tmp / "store" / "clispec" / "src"]
