## The cargo plan edge starts cargo with this process's CURRENT environment.
##
## `plan_run.spawnWait` hands `posix_spawn` the process's `environ`. That
## array is read differently per platform: Linux declares it in <unistd.h>,
## macOS declares it nowhere and is read through `_NSGetEnviron()` from
## <crt_externs.h>. Reading it as `<unistd.h>`'s `environ` everywhere did not
## compile on macOS at all (`use of undeclared identifier 'environ'` in every
## macOS build of the engine and of repro-rustc-wrapper); this file is the
## unit that compiles and runs that read on each POSIX host. On macOS it
## fails to build if the platform branch is lost again, and on every host it
## fails if the child does not see the environment as it is at spawn time.
##
## Each case starts a real `/bin/sh` through `spawnWait` and reads what the
## child printed into a file. The variable is set (and in the control,
## removed) with `putEnv` / `delEnv` AFTER the process started, so a pointer
## read once at start-up, or a stale copy, shows up as a wrong answer: the
## removal case is the negative control that shows the check can see a
## variable that should not be there.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE. `posix_spawn`, `/bin/sh`,
## the process environment and the filesystem are all real. POSIX only: the
## edge's record run is refused on other platforms (`runCargoPlan`).

import std/unittest

when defined(posix):
  import std/[os, strutils, tempfiles]

  import repro_cargo_edge/plan_run

  const Probe = "REPRO_PLAN_RUN_SPAWN_ENV_PROBE"

  proc childValue(dir: string): tuple[status: int, output: string] =
    ## What a child started by `spawnWait` sees as `$Probe`, and its exit
    ## status. `${VAR-unset}` tells an absent variable from an empty one.
    let outFile = dir / "child.out"
    let status = spawnWait(["/bin/sh", "-c",
      "printf '%s' \"${" & Probe & "-unset}\""], outFile)
    (status, readFile(outFile))

  suite "the plan edge spawns with the current environment":

    test "a variable set after start-up reaches the child":
      let dir = createTempDir("repro-plan-run-env-", "")
      defer: removeDir(dir)
      putEnv(Probe, "seen by the child")
      defer: delEnv(Probe)
      let (status, output) = childValue(dir)
      check status == 0
      check output == "seen by the child"

    test "a variable removed before the spawn does not reach the child":
      let dir = createTempDir("repro-plan-run-env-", "")
      defer: removeDir(dir)
      putEnv(Probe, "removed again")
      delEnv(Probe)
      let (status, output) = childValue(dir)
      check status == 0
      check output == "unset"

    test "the child's exit status is returned":
      let dir = createTempDir("repro-plan-run-env-", "")
      defer: removeDir(dir)
      check spawnWait(["/bin/sh", "-c", "exit 7"], dir / "child.out") == 7
      check readFile(dir / "child.out").strip() == ""

else:
  import repro_test_support/reasoned_skip
  suite "the plan edge spawns with the current environment":
    test "POSIX only":
      skip("the cargo plan edge's record run is POSIX only")
