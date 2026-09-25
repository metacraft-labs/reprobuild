## An auto-spawned ``runquotad`` takes its budget from the host file.
##
## RunQuota serves the whole host from one daemon, so whoever spawns it sets
## the budget for every workspace. Measured 2026-09-23 on a 125.6 GiB Windows
## workstation: the only daemon had been auto-spawned by another workspace
## with ``--memory-bytes 17179869184`` (``DefaultAutoRunQuotaMemoryBytes``) and
## refused a provider compile with ``lease request exceeds machine memory
## budget: local``. The daemon now reads ``hostConfigPath`` at start, and a
## flag overrides the file, so ``autoRunQuotaBudgetArgs`` must pass a flag
## only for what the file leaves unset
## (reprobuild-specs/RunQuota-Host-Configuration.md).
##
## Revert the ``startAutoRunQuotaIfNeeded`` change (always pass
## ``--memory-bytes`` / ``--cpu-milli`` / every convention pool) and the
## "host file sets it" cases fail: the spawned daemon would enforce 16 GiB
## whatever the file says.

import std/[options, os, strutils, tables, unittest]

import repro_build_engine
import repro_cli_support
import runquota_daemon/host_config

const MemoryKey = "REPROBUILD_RUNQUOTA_MEMORY_BYTES"

proc flagValue(args: seq[string]; flag: string): Option[string] =
  var i = 0
  while i + 1 < args.len:
    if args[i] == flag:
      return some(args[i + 1])
    i += 2
  none(string)

proc poolValues(args: seq[string]): seq[string] =
  var i = 0
  while i + 1 < args.len:
    if args[i] == "--pool":
      result.add(args[i + 1])
    i += 2

proc hostFile(text: string): HostConfig =
  parseHostConfig("schema = \"runquota.host-config.v1\"\n" & text,
    "runquotad.toml")

suite "runquota auto-spawn defers to the host config":
  let previous = getEnv(MemoryKey)
  let wasPresent = existsEnv(MemoryKey)
  setup:
    delEnv(MemoryKey)
  teardown:
    if wasPresent:
      putEnv(MemoryKey, previous)
    else:
      delEnv(MemoryKey)

  test "no host file: the built-in budget, as before":
    let budget = autoRunQuotaBudgetArgs(HostConfig(), [], 12000'u32)
    check budget.args.flagValue("--memory-bytes") ==
      some($DefaultAutoRunQuotaMemoryBytes)
    check budget.args.flagValue("--cpu-milli") == some("12000")
    check budget.args.poolValues == @["compile=8", "fetch=2"]
    check budget.warnings.len == 0

  test "the host file's keys are left to the daemon":
    let host = hostFile("""
[machine]
memory_bytes = 103079215104
cpu_milli = 16000
[pools]
compile = 4
""")
    let budget = autoRunQuotaBudgetArgs(host, [], 12000'u32)
    check budget.args.flagValue("--memory-bytes").isNone
    check budget.args.flagValue("--cpu-milli").isNone
    check budget.args.poolValues == @["fetch=2"]
    check budget.warnings.len == 0

  test "a pool the recipe declares is passed even when the file sizes it":
    let host = hostFile("[pools]\ncompile = 4\n")
    let budget = autoRunQuotaBudgetArgs(host,
      [BuildPool(name: "compile", capacity: 6'u32)], 12000'u32)
    check budget.args.poolValues == @["compile=6", "fetch=2"]

  test "the environment override still wins, and says it overrides the file":
    putEnv(MemoryKey, "68719476736")
    let host = hostFile("[machine]\nmemory_bytes = 103079215104\n")
    let budget = autoRunQuotaBudgetArgs(host, [], 12000'u32)
    check budget.args.flagValue("--memory-bytes") == some("68719476736")
    check budget.warnings.len == 1
    check "runquotad.toml" in budget.warnings[0]

  test "an environment override that agrees with the file is silent":
    putEnv(MemoryKey, "103079215104")
    let host = hostFile("[machine]\nmemory_bytes = 103079215104\n")
    check autoRunQuotaBudgetArgs(host, [], 12000'u32).warnings.len == 0
