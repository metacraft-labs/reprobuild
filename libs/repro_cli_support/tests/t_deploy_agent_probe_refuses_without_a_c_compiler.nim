## ReproOS Add-On Mode §13 decision 31: a profile compile that resolves no C
## compiler -- none named, none on ``PATH``, and the engine's build compiler
## absent, as for a cross-built engine -- is refused by name rather than
## failing later on ``gcc: not found``; and bootstrap's preflight learns it
## from ``repro deploy-agent compile-profile --probe-c-compiler``, which exits
## 1.
##
## This drives the real ``resolveProfileCCompiler`` and the real probe
## command in a process whose environment names no compiler and whose
## ``PATH`` is an empty directory. The binary is built as a cross-built
## engine is (``-d:reproBuiltCCompiler=``, this file's ``.nim.cfg``), so the
## last fallback is absent too. The positive controls put a ``cc`` and then
## a ``gcc`` on that ``PATH``.
##
## *Mocking.* None. The compiler files on ``PATH`` are empty executables:
## resolution only finds them, it never runs them.

import std/[os, strutils, tempfiles, unittest]

import repro_core/c_compiler
import repro_cli_support/deploy_agent
from repro_profile_compile/compile import CompileFailure,
  resolveProfileCCompiler, ProfileNimCompilerEnvVar, NimDefaultCCompilerExe

template withEnvs(vars: openArray[(string, string)]; body: untyped) =
  ## Run ``body`` with each variable set (to "" means unset), then restore.
  var saved: seq[(string, bool, string)]
  for (k, v) in vars:
    saved.add((k, existsEnv(k), getEnv(k)))
    if v.len == 0: delEnv(k) else: putEnv(k, v)
  try:
    body
  finally:
    for (k, had, v) in saved:
      if had: putEnv(k, v) else: delEnv(k)

proc touchExe(path: string) =
  writeFile(path, "")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

suite "a host with no C compiler (decision 31)":
  test "this binary has no build-compiler fallback, as a cross-built engine":
    check BuiltCCompilerPath.len == 0

  test "the profile compile refuses by name, and the probe exits 1":
    let bin = createTempDir("no-c-compiler-", "")
    defer: removeDir(bin)
    # A Nim compiler is named, so the probe gets as far as the C compiler.
    withEnvs([("REPRO_BOOTSTRAP_CC", ""), ("CC", ""), ("PATH", bin),
              (ProfileNimCompilerEnvVar, getAppFilename())]):
      var msg = ""
      try:
        discard resolveProfileCCompiler()
      except CompileFailure as e:
        msg = e.msg
      check "no C compiler" in msg
      check "install one from the distribution" in msg
      check runDeployAgentCompileProfile(@["--probe-c-compiler"]) == 1

  test "a cc on PATH is the answer, and the probe exits 0":
    let bin = createTempDir("cc-only-", "")
    defer: removeDir(bin)
    touchExe(bin / "cc")
    withEnvs([("REPRO_BOOTSTRAP_CC", ""), ("CC", ""), ("PATH", bin),
              (ProfileNimCompilerEnvVar, getAppFilename())]):
      check resolveProfileCCompiler() == bin / "cc"
      check runDeployAgentCompileProfile(@["--probe-c-compiler"]) == 0

  test "Nim's default compiler on PATH is left to Nim":
    let bin = createTempDir("gcc-", "")
    defer: removeDir(bin)
    touchExe(bin / NimDefaultCCompilerExe)
    withEnvs([("REPRO_BOOTSTRAP_CC", ""), ("CC", ""), ("PATH", bin),
              (ProfileNimCompilerEnvVar, getAppFilename())]):
      check resolveProfileCCompiler() == ""
      check runDeployAgentCompileProfile(@["--probe-c-compiler"]) == 0
