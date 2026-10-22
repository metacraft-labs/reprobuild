## `repro-agent-conformance -- <provider command...>`: run the agent
## integration protocol's provider conformance scenario (`agent-v1`)
## against a provider, for alternative agents and Agent Harbor alike
## (ReproOS-Agent-Harbor-Integration M7). Thin: the harness is
## `repro_agent_protocol/conformance`.
##
## Exit status: 0 when the provider passes, 1 when it fails, 2 on usage
## errors. The verdict and every failure are printed.

import std/[os, strutils, tempfiles]

import repro_agent_protocol/conformance

proc runAgentConformanceCommand*(args: seq[string]): int =
  let sep = args.find("--")
  if sep < 0 or sep == args.high:
    echo "usage: repro-agent-conformance -- <provider command> [args...]"
    return 2
  let root = createTempDir("rac-", "")
  defer: removeDir(root)
  let report = runConformance(args[sep + 1 .. ^1], root)
  echo "provider exit: ", report.providerExit
  echo "backend calls: ", report.backendCalls.join(", ")
  for f in report.failures:
    echo "FAIL: ", f
  echo (if report.passed: "PASS agent-v1" else: "FAIL agent-v1")
  if report.passed: 0 else: 1

when isMainModule:
  quit(runAgentConformanceCommand(commandLineParams()))
