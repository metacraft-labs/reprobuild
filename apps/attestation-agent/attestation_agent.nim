## ``attestation-agent`` — the entry point. Everything it does lives in
## ``repro_attest_agent/cli``, so that the flags the daemon parses and the
## service unit it renders for itself can be checked against each other
## by a gate, which a module reachable only through ``isMainModule``
## could not be.

import std/os

import repro_attest_agent/cli

when isMainModule:
  quit(runAttestationAgent(commandLineParams()))
