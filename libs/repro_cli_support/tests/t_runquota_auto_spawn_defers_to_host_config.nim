## An auto-spawned ``runquotad`` takes its budget from the host, not from
## the command that started it.
##
## RunQuota serves the whole host from one daemon, so whoever spawns it sets
## the budget for every workspace. Measured 2026-09-23 on a 125.6 GiB Windows
## workstation: the only daemon had been auto-spawned by another workspace
## with ``--memory-bytes 17179869184`` (``DefaultAutoRunQuotaMemoryBytes``) and
## refused a provider compile with ``lease request exceeds machine memory
## budget: local``.
##
## A FLAG PINS ITS KEY. It overrides the host file and the daemon's own
## default, and survives ``runquota config reload``, so a later ``runquota
## config set`` of that key does nothing to that daemon. The decision
## (reprobuild-specs/RunQuota-Host-Configuration.md, "What the auto-spawn
## passes", 2026-10-01) is that the auto-spawn passes NO budget flag:
##
## - no ``--memory-bytes`` (removed 2026-09-30);
## - no ``--cpu-milli``. It used to be ``buildMaxParallelism() * 1000``
##   whenever the file left ``cpu_milli`` unset, which made one build's
##   parallelism the host's CPU budget and pinned it;
## - no ``--pool``. A build declares its pools on its own session instead
##   (``runQuotaPoolDeclaration`` / ``declareRunQuotaPools``).
##
## ``REPROBUILD_RUNQUOTA_MEMORY_BYTES`` is the one explicit override left, and
## it says what it does every time it takes effect.
##
## Revert ``autoRunQuotaBudgetArgs`` to pass ``--cpu-milli`` (or ``--pool``)
## when the file leaves the key unset and the first two cases fail.
## ``tests/integration/t_runquota_auto_spawned_daemon_follows_host_config.nim``
## runs the consequence against a real daemon and ``runquota config``.

import std/[options, os, strutils, unittest]

import repro_cli_support
import runquota_daemon/host_config

const MemoryKey = "REPROBUILD_RUNQUOTA_MEMORY_BYTES"

proc hostFile(text: string): HostConfig =
  parseHostConfig("schema = \"runquota.host-config.v1\"\n" & text,
    "runquotad.toml")

suite "runquota auto-spawn passes the host's budget, not its own":
  let previous = getEnv(MemoryKey)
  let wasPresent = existsEnv(MemoryKey)
  setup:
    delEnv(MemoryKey)
  teardown:
    if wasPresent:
      putEnv(MemoryKey, previous)
    else:
      delEnv(MemoryKey)

  test "no host file: no budget flag at all":
    # In particular no --cpu-milli: the daemon's default (one core per
    # logical processor) applies, and `config set machine.cpu_milli`
    # reaches it by reload.
    let budget = autoRunQuotaBudgetArgs(HostConfig())
    check budget.args.len == 0
    check budget.warnings.len == 0

  test "a host file that sets every key: still no flag":
    let host = hostFile("""
[machine]
memory_bytes = 103079215104
cpu_milli = 16000
[pools]
compile = 4
""")
    let budget = autoRunQuotaBudgetArgs(host)
    check budget.args.len == 0
    check budget.warnings.len == 0

  test "the environment override is a flag, and says what it pins":
    putEnv(MemoryKey, "68719476736")
    let host = hostFile("[machine]\nmemory_bytes = 103079215104\n")
    let budget = autoRunQuotaBudgetArgs(host)
    check budget.args == @["--memory-bytes", "68719476736"]
    check budget.warnings.len == 1
    check "runquotad.toml" in budget.warnings[0]
    check "103079215104" in budget.warnings[0]
    check "pins" in budget.warnings[0]
    check "runquota config set machine.memory_bytes" in budget.warnings[0]

  test "with no host file, the override says it replaces the daemon's default":
    putEnv(MemoryKey, "68719476736")
    let budget = autoRunQuotaBudgetArgs(HostConfig())
    check budget.args == @["--memory-bytes", "68719476736"]
    check budget.warnings.len == 1
    check "75% of physical memory" in budget.warnings[0]

  test "an override that agrees with the file passes nothing and is silent":
    # Nothing to override, and a flag would pin the key for nothing.
    putEnv(MemoryKey, "103079215104")
    let host = hostFile("[machine]\nmemory_bytes = 103079215104\n")
    let budget = autoRunQuotaBudgetArgs(host)
    check budget.args.len == 0
    check budget.warnings.len == 0

suite "the memory override against a daemon that is already running":
  let previous = getEnv(MemoryKey)
  let wasPresent = existsEnv(MemoryKey)
  setup:
    delEnv(MemoryKey)
  teardown:
    if wasPresent:
      putEnv(MemoryKey, previous)
    else:
      delEnv(MemoryKey)

  test "unset: nothing to say":
    check autoRunQuotaMemoryOverrideNotApplied(some(1'u64)).len == 0

  test "the running daemon already enforces it: silent":
    putEnv(MemoryKey, "68719476736")
    check autoRunQuotaMemoryOverrideNotApplied(
      some(68719476736'u64)).len == 0

  test "a different budget is in force: says it had no effect, and what is":
    putEnv(MemoryKey, "68719476736")
    let warnings = autoRunQuotaMemoryOverrideNotApplied(
      some(103079215104'u64))
    check warnings.len == 1
    check "has no effect" in warnings[0]
    check "103079215104" in warnings[0]
    check "runquota config set machine.memory_bytes" in warnings[0]
