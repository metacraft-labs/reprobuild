## Every entry point that reaches the provider compile publishes the
## bootstrap toolchain first.
##
## `ensureBootstrapToolchainEnv` puts the tool-store nim and gcc into
## `REPRO_NIM_COMPILER` / `REPRO_BOOTSTRAP_CC` before the recipe provider is
## compiled; without it `nimCompilerPath()` and `hostCCompilerPath()` fall back
## to whatever is on `PATH`. `Development-Environments-And-Control-API.md`
## places the dev-env's provider compile on the SAME edge as the build's, so
## the resolution must not depend on which verb reached the edge.
##
## It did. `build`, `develop` and graph inspection called it; the dev-env
## path behind `repro exec` / `repro shell` (`computePublicDevEnv`) did not.
## Measured on Windows with an outer PATH reduced to System32: `repro build
## --tool-provisioning=tarball` compiled the provider from the store, while
## `repro exec` of the same recipe failed with `CreateProcessW failed (2)` for
## `nim c`. With the call added, the same `repro exec` resolved nim 2.2.10,
## git 2.54.0, just 1.51.0, python 3.12.10 and gcc 16.1.0 from the store.
##
## This is a wiring test, not a behavioural one, and says so: the behaviour
## needs a provisioned tool store and a Windows host with no ambient
## toolchain, which is the measurement above rather than something a unit
## test can stage. What it pins is the part that regressed -- a call site --
## so a new entry point, or a refactor of an existing one, that drops the call
## fails here instead of on the next clean machine.
##
## No mocks: it reads the real source of the module under test.

import std/[os, strutils, unittest]

const cliSupportSource = currentSourcePath().parentDir.parentDir /
  "src" / "repro_cli_support.nim"

proc procBody(source, name: string): string =
  ## The text of top-level proc `name`, from its `proc` line up to the next
  ## top-level `proc`. Empty if the proc is absent, which the callers below
  ## treat as a failure rather than a pass.
  let lines = source.splitLines()
  var start = -1
  for i, line in lines:
    if line.startsWith("proc " & name & "(") or
       line.startsWith("proc " & name & "*("):
      start = i
      break
  if start < 0:
    return ""
  var stop = lines.len
  for i in start + 1 ..< lines.len:
    if lines[i].startsWith("proc "):
      stop = i
      break
  lines[start ..< stop].join("\n")

proc callSite(body, callee: string): int =
  ## Index of the first real call to `callee` in `body`, skipping comment
  ## lines so that a comment naming the call does not satisfy the test.
  var offset = 0
  for line in body.splitLines():
    let stripped = line.strip()
    if not stripped.startsWith("#"):
      let at = line.find(callee & "(")
      if at >= 0:
        return offset + at
    offset += line.len + 1
  -1

let source = readFile(cliSupportSource)

suite "provider-compile entry points publish the bootstrap toolchain":

  for entry in ["executeBuildTarget", "runDevelopCommand",
                "computePublicDevEnv"]:
    test entry & " calls ensureBootstrapToolchainEnv":
      let body = procBody(source, entry)
      check body.len > 0
      check callSite(body, "ensureBootstrapToolchainEnv") >= 0

  test "computePublicDevEnv publishes it BEFORE computing the dev-env edge":
    # Order matters: the edge is where the provider compile happens, so a call
    # placed after it would satisfy the test above and still compile from PATH.
    let body = procBody(source, "computePublicDevEnv")
    let bootstrap = callSite(body, "ensureBootstrapToolchainEnv")
    let edge = callSite(body, "computeDevEnvEdge")
    check bootstrap >= 0
    check edge >= 0
    check bootstrap < edge

  test "computePublicDevEnv hands the edge the mode it bootstrapped for":
    # A second, independent resolution would let the bootstrap and the edge
    # disagree about which toolchain they are provisioning.
    let body = procBody(source, "computePublicDevEnv")
    check "ensureBootstrapToolchainEnv(toolProvisioning," in body
    check "toolProvisioning: toolProvisioning" in body
