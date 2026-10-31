## Shared helpers for the ReproOS add-on mode gates under `tests/e2e/addon/`.
##
## The system commands (`repro infra plan` / `apply`, `repro system sync` /
## `rollback`) observe the host's base from `os-release` before acting on a
## host the registry declares (`repro_infra/host_base`). These gates run on
## whatever machine runs the suite, so they choose the base explicitly: the
## `REPRO_OS_RELEASE_PATH` seam points the observation at one of the
## committed `tests/fixtures/os-release/` files. That is not a mock of the
## code under test -- the real parser reads a real `os-release` file; only
## which file it reads is chosen.

import std/[os, strutils]

import ../m83/profile_compile_edge_harness

const
  OsReleaseFixtures* = ProjectRoot / "tests" / "fixtures" / "os-release"
  OsReleaseEnvVar* = "REPRO_OS_RELEASE_PATH"

proc baseEnv*(fixture: string): (string, string) =
  ## The environment entry that makes the system commands observe the base
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
