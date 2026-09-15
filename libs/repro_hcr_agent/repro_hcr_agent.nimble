version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Minimal in-target HCR runtime for direct trampoline tests"
license       = "MIT"
srcDir        = "src"
requires "nim >= 2.2.0"

task buildWindowsAgent, "Build repro_hcr_agent.dll and its new-process launcher":
  exec "python build_windows_agent.py --out build/windows-agent"
