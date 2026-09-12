import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_tool_profiles

const ToolName = when defined(windows): "probe-stdin.cmd" else: "probe-stdin"

proc probeAfterEof(tail: string): ToolProbeResult =
  let root = createTempDir("repro-probe-stdin-", "")
  defer: removeDir(root)
  let tool = root / ToolName
  when defined(windows):
    writeFile(tool, "@echo off\r\nset /p line=\r\n" &
      "if not errorlevel 1 exit /b 99\r\n" & tail)
  else:
    writeFile(tool, "#!/bin/sh\nif read -r line; then exit 99; fi\n" & tail)
    setFilePermissions(tool, {fpUserRead, fpUserWrite, fpUserExec})
  let profile = resolvePathOnlyTool(InterfaceToolUse(
    rawConstraint: ToolName, packageSelector: ToolName,
    executableName: ToolName), pathValue = root)
  doAssert profile.probes.len == 1
  profile.probes[0]

suite "tool_probe_stdin":
  test "a non-interactive probe receives EOF without timing out":
    let ending = when defined(windows):
      "echo probe-stdin 1.0\r\nexit /b 0\r\n"
    else:
      "printf 'probe-stdin 1.0\\n'\nexit 0\n"
    let probe = probeAfterEof(ending)
    check not probe.timedOut
    check probe.exitCode == 0
    check probe.output.strip() == "probe-stdin 1.0"

  test "EOF preserves a probe's nonzero exit and diagnostics":
    let ending = when defined(windows):
      "echo expected-probe-error 1>&2\r\nexit /b 7\r\n"
    else:
      "printf 'expected-probe-error\\n' >&2\nexit 7\n"
    let probe = probeAfterEof(ending)
    check not probe.timedOut
    check probe.exitCode == 7
    check probe.output.strip() == "expected-probe-error"

  test "a probe stuck after EOF still reaches the hard timeout":
    let ending = when defined(windows):
      ":wait\r\ngoto wait\r\n"
    else:
      "exec sleep 30\n"
    let probe = probeAfterEof(ending)
    check probe.timedOut
    check probe.exitCode == probeTimeoutExitCode
