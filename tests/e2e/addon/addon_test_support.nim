## Shared helpers for the ReproOS add-on mode gates under `tests/e2e/addon/`.
##
## The system commands (`repro infra plan` / `apply`, `repro system sync` /
## `rollback`) observe the host's base from `os-release` before acting on a
## host the registry declares (`repro_infra/host_base`). These gates run on
## whatever machine runs the suite, so they choose the base explicitly:
## `runRepro` binds one of the committed `tests/fixtures/os-release/` files
## over `/etc/os-release` in the engine's own mount namespace
## (`TestbedOsReleaseKey`; no engine reads a variable for it). That is not a
## mock of the code under test -- the real parser reads a real
## `/etc/os-release`; only which bytes are there is chosen. Linux only: a
## Debian base cannot be shown elsewhere (`canReidentifyHostBase`).

import std/[os, strutils, unittest]

import repro_test_support/reasoned_skip

import ../m83/profile_compile_edge_harness

const
  OsReleaseFixtures* = ProjectRoot / "tests" / "fixtures" / "os-release"
  OsReleaseEnvVar* = TestbedOsReleaseKey

const LinuxOnlyBaseReason* = "the host base is re-identified only on " &
  "Linux, through a mount namespace (no engine reads a variable for it; " &
  "A12 review finding 5), and this gate needs a Debian-family base"

template linuxOnlyTest*(name: string; body: untyped) =
  ## A ``test`` that runs its body only on Linux, where ``runRepro`` can show
  ## the engine a Debian base, and is skipped with ``LinuxOnlyBaseReason``
  ## elsewhere. The body is passed through untouched.
  test name:
    when defined(linux):
      body
    else:
      skip(LinuxOnlyBaseReason)

proc baseEnv*(fixture: string): (string, string) =
  ## The `runRepro` entry that makes the system commands observe the base
  ## in `tests/fixtures/os-release/<fixture>` (`debian-13`, `reproos`, ...).
  let path = OsReleaseFixtures / fixture
  doAssert fileExists(path), "no os-release fixture " & path
  (OsReleaseEnvVar, path)

proc planLines*(output: string): seq[string] =
  ## The operation lines of a `repro infra plan` report (`* create ...`),
  ## stripped -- what the plan would do, in its order.
  for line in output.splitLines():
    let t = line.strip()
    if t.startsWith("* "):
      result.add t
