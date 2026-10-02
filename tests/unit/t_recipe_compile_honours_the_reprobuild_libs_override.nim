## A recipe compile honours `$REPROBUILD_REPO_ROOT` / `$REPROBUILD_LIBS_DIR`,
## across both process boundaries it crosses.
##
## `reprobuildLibsRootFromEnv` documents the two variables as the operator's
## override for which reprobuild `libs/` a recipe is compiled against, and
## `reprobuildExternalLibsRoot` consults them first. Two things stopped that
## from reaching a dev environment (reprobuild-specs issue
## 2026-09-30-dev-env-provider-compile-ignores-reprobuild-repo-root):
##
##   1. The provider compile is launched ISOLATED -- from its declared
##      environment and nothing else -- and `providerCompileLaunchEnv`, which
##      is that declaration, did not carry the overrides. The compile's own
##      `reproLibPathFlags` then fell through to the libs of the checkout the
##      engine binary was built in.
##   2. The dev-env activation reuses a previously extracted interface
##      whenever `computeDevEnvEdgeCacheKey` matches, and the key ignored the
##      overrides, so setting one after an activation replayed an interface
##      extracted from the other libs.
##
## Each case grades the real function at that boundary. No mocks.

import std/[os, strutils, unittest]

import repro_interface_artifacts
import repro_dev_env_engine/cache_key

proc valueIn(env: openArray[string]; name: string): string =
  for entry in env:
    if entry.startsWith(name & "="):
      return entry[name.len + 1 .. ^1]
  "<absent>"

suite "the reprobuild libs override reaches the recipe compile":
  setup:
    let saved = @[getEnv("REPROBUILD_REPO_ROOT"), getEnv("REPROBUILD_LIBS_DIR")]
    let home = getTempDir() / "repro-libs-override-home"

  teardown:
    for i, name in ["REPROBUILD_REPO_ROOT", "REPROBUILD_LIBS_DIR"]:
      if saved[i].len > 0: putEnv(name, saved[i])
      else: delEnv(name)
    removeDir(home)

  test "the isolated provider compile is launched with both overrides":
    putEnv("REPROBUILD_REPO_ROOT", "/elsewhere/reprobuild")
    putEnv("REPROBUILD_LIBS_DIR", "/elsewhere/reprobuild/libs")
    let env = providerCompileLaunchEnv(home)
    check env.valueIn("REPROBUILD_REPO_ROOT") == "/elsewhere/reprobuild"
    check env.valueIn("REPROBUILD_LIBS_DIR") == "/elsewhere/reprobuild/libs"

  test "an unset override is not invented":
    delEnv("REPROBUILD_REPO_ROOT")
    delEnv("REPROBUILD_LIBS_DIR")
    let env = providerCompileLaunchEnv(home)
    check env.valueIn("REPROBUILD_REPO_ROOT") == "<absent>"
    check env.valueIn("REPROBUILD_LIBS_DIR") == "<absent>"

  test "the activation key moves with either override":
    let root = getCurrentDir()
    delEnv("REPROBUILD_REPO_ROOT")
    delEnv("REPROBUILD_LIBS_DIR")
    let unset = computeDevEnvEdgeCacheKey(root, "default", "", "")
    putEnv("REPROBUILD_REPO_ROOT", "/elsewhere/reprobuild")
    let repoRoot = computeDevEnvEdgeCacheKey(root, "default", "", "")
    delEnv("REPROBUILD_REPO_ROOT")
    putEnv("REPROBUILD_LIBS_DIR", "/elsewhere/reprobuild/libs")
    let libsDir = computeDevEnvEdgeCacheKey(root, "default", "", "")
    check unset != repoRoot
    check unset != libsDir
    check repoRoot != libsDir
    # And it stays a key: the same override, the same activation.
    check libsDir == computeDevEnvEdgeCacheKey(root, "default", "", "")
