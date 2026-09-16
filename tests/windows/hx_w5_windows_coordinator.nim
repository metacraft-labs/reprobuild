## HX-W-5 real coordinator driver.
##
## No mocks are used: this imports the production protocol, session,
## coordinator, and Windows named-pipe transport and exchanges framed messages
## with the injected production DLL.

import std/[json, options, os, strutils]

import repro_hcr_agent

proc main() =
  if paramCount() != 1:
    quit "usage: hx_w5_windows_coordinator.exe <pid>", 2
  let pid = parseInt(paramStr(1))
  var connection = connectHcrAgentWindowsPipe(pid, timeoutMs = 5_000)
  defer: connection.close()
  var client = initHcrCoordinatorClient(HcrWindowsX86_64DirectSupportProfile)
  let request = directPatchRequest(
    "hx-w5-malformed-bundle-probe",
    HcrWindowsX86_64DirectSupportProfile,
    ["hx_w5_changed"],
    ["hx_w5_target"],
    [byte 0x90],
    [],
    [],
    [])
  let delivery = client.deliverPatchRequest(connection, request)
  if delivery.patchFailed.isNone:
    raise newException(ValueError,
      "Windows agent accepted the malformed W5 transport probe")
  let failure = delivery.patchFailed.get()
  if not failure.message.startsWith("windows-patch-bundle-invalid"):
    raise newException(ValueError,
      "Windows malformed-bundle refusal is not named: " & failure.message)
  if HcrWindowsX86_64DirectSupportProfile != client.supportProfile:
    raise newException(ValueError, "coordinator profile changed during handshake")
  echo $(%*{
    "handshake_completed": delivery.session.state == hssFailed,
    "support_profile": client.supportProfile,
    "capabilities": delivery.session.agentCapabilities,
    "direct_patch_advertised":
      "direct-patch-injection" in delivery.session.agentCapabilities,
    "patch_failure_stage": failure.stage,
    "patch_failure": failure.message,
    "transcript_frames": delivery.transcript.len
  })

when isMainModule:
  try:
    main()
  except CatchableError as failure:
    stderr.writeLine(failure.msg)
    quit 1
