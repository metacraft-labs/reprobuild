version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Minimal in-target HCR runtime for direct trampoline tests"
license       = "MIT"
srcDir        = "src"
requires "nim >= 2.2.0"

import std/os

task buildLib, "Build canonical shared library (librepro_hcr_agent)":
  let script = thisDir() / "build_lib.sh"
  exec("bash " & script)

task testLib, "Verify exported symbols in built librepro_hcr_agent":
  let script = thisDir() / "build_lib.sh"
  exec("bash " & script)
  let checkScript = thisDir() / "check_symbols.sh"
  exec("bash " & checkScript)

task buildWindowsAgent, "Build repro_hcr_agent.dll and its new-process launcher":
  exec "python build_windows_agent.py --out build/windows-agent"
