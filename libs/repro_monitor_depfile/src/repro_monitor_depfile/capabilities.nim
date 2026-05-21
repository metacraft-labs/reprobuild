import std/[strutils]

import repro_monitor_depfile/types

const
  MacosInterposeSupportedCapabilities* = {
    mcapProcess,
    mcapFileRead,
    mcapFileWrite,
    mcapPathProbe,
    mcapDirectoryEnumerate,
    mcapEventLoss,
    mcapProcessTree,
    mcapProcessExec,
    mcapBackendProvenance,
    mcapFileCreate,
    mcapFileTruncate,
    mcapFileAppend
  }

  MacosInterposeKnownUnsupportedCapabilities* = {
    mcapEndpointSecurity,
    mcapHybrid,
    mcapRename,
    mcapSymlink,
    mcapLibraryLoad,
    mcapAuthorizationEnforcement,
    mcapPathMutation
  }

  MacosMonitorShimTaxonomyCapabilities* = {
    mcapProcess,
    mcapFileRead,
    mcapFileWrite,
    mcapPathProbe,
    mcapDirectoryEnumerate,
    mcapEventLoss,
    mcapProcessTree,
    mcapProcessExec,
    mcapBackendProvenance,
    mcapFileCreate,
    mcapFileTruncate,
    mcapFileAppend
  }

  LinuxPreloadSupportedCapabilities* = {
    mcapProcess,
    mcapFileRead,
    mcapFileWrite,
    mcapPathProbe,
    mcapDirectoryEnumerate,
    mcapEventLoss,
    mcapProcessTree,
    mcapProcessExec,
    mcapBackendProvenance,
    mcapFileCreate,
    mcapFileTruncate,
    mcapFileAppend
  }

  LinuxPreloadKnownUnsupportedCapabilities* = {
    mcapEndpointSecurity,
    mcapHybrid,
    mcapRename,
    mcapSymlink,
    mcapLibraryLoad,
    mcapAuthorizationEnforcement,
    mcapPathMutation
  }

proc backendFamilyId*(family: MonitorBackendFamily): string =
  case family
  of mbfMacosHooks:
    "macos-interpose-hooks"
  of mbfMacosEndpointSecurity:
    "macos-endpoint-security"
  of mbfMacosHybrid:
    "macos-hybrid"
  of mbfLinuxPreloadHooks:
    "linux-preload-hooks"
  of mbfUnknown:
    "unknown"

proc capabilityId*(capability: MonitorCapability): string =
  case capability
  of mcapProcess:
    "process"
  of mcapFileRead:
    "file-read"
  of mcapFileWrite:
    "file-write"
  of mcapPathProbe:
    "path-probe"
  of mcapDirectoryEnumerate:
    "directory-enumerate"
  of mcapEventLoss:
    "event-loss"
  of mcapProcessTree:
    "process-tree"
  of mcapProcessExec:
    "process-exec"
  of mcapBackendProvenance:
    "backend-provenance"
  of mcapFileCreate:
    "file-create"
  of mcapFileTruncate:
    "file-truncate"
  of mcapFileAppend:
    "file-append"
  of mcapEndpointSecurity:
    "endpoint-security"
  of mcapHybrid:
    "hybrid"
  of mcapRename:
    "rename"
  of mcapSymlink:
    "symlink"
  of mcapLibraryLoad:
    "library-load"
  of mcapAuthorizationEnforcement:
    "authorization-enforcement"
  of mcapPathMutation:
    "path-mutation"

proc capabilityFromId*(value: string): MonitorCapability =
  for capability in MonitorCapability:
    if capabilityId(capability) == value:
      return capability
  raise newException(ValueError, "unknown monitor capability: " & value)

proc backendFamilyFromId*(value: string): MonitorBackendFamily =
  for family in MonitorBackendFamily:
    if backendFamilyId(family) == value:
      return family
  mbfUnknown

proc parseCapabilityList(value: string): set[MonitorCapability] =
  if value.len == 0:
    return {}
  for item in value.split(','):
    if item.len > 0:
      result.incl capabilityFromId(item)

proc unsupportedReason(capability: MonitorCapability): string =
  case capability
  of mcapEndpointSecurity:
    "EndpointSecurity backend is not implemented in M14; future native backend"
  of mcapHybrid:
    "hybrid EndpointSecurity plus interpose profile is not implemented in M14"
  of mcapRename:
    "macOS interpose shim does not hook rename/renameat yet"
  of mcapSymlink:
    "macOS interpose shim does not hook symlink/symlinkat/readlink yet"
  of mcapLibraryLoad:
    "macOS interpose shim does not hook dlopen/library-load events yet"
  of mcapAuthorizationEnforcement:
    "macOS interpose shim observes only and cannot authorize or deny operations"
  of mcapPathMutation:
    "macOS interpose shim does not cover the full mutation surface yet"
  else:
    "capability is not advertised by the selected macOS interpose profile"

proc linuxUnsupportedReason(capability: MonitorCapability): string =
  case capability
  of mcapEndpointSecurity:
    "EndpointSecurity is macOS-only; Linux native backend is future eBPF work"
  of mcapHybrid:
    "hybrid native plus preload profile is not implemented"
  of mcapRename:
    "Linux preload shim does not yet normalize rename/renameat as path mutations"
  of mcapSymlink:
    "Linux preload shim does not yet normalize symlink/readlink as path mutations"
  of mcapLibraryLoad:
    "Linux preload shim does not yet emit library-load records"
  of mcapAuthorizationEnforcement:
    "Linux preload shim observes only and cannot authorize or deny operations"
  of mcapPathMutation:
    "Linux preload shim does not cover the full mutation surface yet"
  else:
    "capability is not advertised by the selected Linux preload profile"

proc gapDetail*(gap: MonitorCapabilityGap): string =
  "backend=" & backendFamilyId(gap.backendFamily) &
    ";capability=" & capabilityId(gap.capability) &
    ";required=" & (if gap.required: "true" else: "false") &
    ";reason=" & gap.reason

proc parseGapDetail*(detail: string): MonitorCapabilityGap =
  result.backendFamily = mbfUnknown
  result.capability = mcapProcess
  for part in detail.split(';'):
    let pair = part.split("=", 1)
    if pair.len != 2:
      continue
    case pair[0]
    of "backend":
      result.backendFamily = backendFamilyFromId(pair[1])
    of "capability":
      result.capability = capabilityFromId(pair[1])
    of "required":
      result.required = pair[1] == "true"
    of "reason":
      result.reason = pair[1]
    else:
      discard

proc capabilityGapRecord*(gap: MonitorCapabilityGap): MonitorRecord =
  MonitorRecord(
    kind: mrCapabilityGap,
    observationKind: moCapabilityGap,
    osPid: 0,
    parentOsPid: 0,
    threadId: 0,
    probeResult: prUnknown,
    path: capabilityId(gap.capability),
    detail: gapDetail(gap))

proc backendProfileRecord*(profile: MonitorBackendProfile): MonitorRecord =
  var caps: seq[string] = @[]
  for capability in profile.supportedCapabilities:
    caps.add capabilityId(capability)
  var requiredCaps: seq[string] = @[]
  for capability in profile.requiredCapabilities:
    requiredCaps.add capabilityId(capability)
  MonitorRecord(
    kind: mrBackendProfile,
    observationKind: moBackendProfile,
    osPid: 0,
    parentOsPid: 0,
    threadId: 0,
    probeResult: prUnknown,
    path: profile.profileName,
    detail: "backend=" & backendFamilyId(profile.backendFamily) &
      ";supported=" & caps.join(",") &
      ";required=" & requiredCaps.join(",") &
      ";evidenceComplete=" & (if profile.evidenceComplete: "true" else: "false"))

proc macosInterposeMonitorProfile*(
    required: set[MonitorCapability] = {}): MonitorBackendProfile =
  result.profileName = "macos-interpose-hooks-m14"
  result.backendFamily = mbfMacosHooks
  result.supportedCapabilities = MacosInterposeSupportedCapabilities
  result.requiredCapabilities = required
  result.evidenceComplete = true
  result.diagnostics.add MonitorDiagnostic(
    level: mdlInfo,
    message: "selected macOS interpose/hooks backend; EndpointSecurity and " &
      "hybrid backends are unavailable in M14")

  var gapCapabilities = MacosInterposeKnownUnsupportedCapabilities
  for capability in required:
    if capability notin result.supportedCapabilities:
      gapCapabilities.incl capability
      result.evidenceComplete = false

  for capability in gapCapabilities:
    let requiredGap = capability in required and
      capability notin result.supportedCapabilities
    result.gaps.add MonitorCapabilityGap(
      backendFamily: result.backendFamily,
      capability: capability,
      required: requiredGap,
      reason: unsupportedReason(capability))
    if requiredGap:
      result.diagnostics.add MonitorDiagnostic(
        level: mdlError,
        message: "required monitor capability is unsupported by " &
          backendFamilyId(result.backendFamily) & ": " &
          capabilityId(capability))

proc linuxPreloadMonitorProfile*(
    required: set[MonitorCapability] = {}): MonitorBackendProfile =
  result.profileName = "linux-preload-hooks-m14"
  result.backendFamily = mbfLinuxPreloadHooks
  result.supportedCapabilities = LinuxPreloadSupportedCapabilities
  result.requiredCapabilities = required
  result.evidenceComplete = true
  result.diagnostics.add MonitorDiagnostic(
    level: mdlInfo,
    message: "selected Linux LD_PRELOAD/hooks backend; future native eBPF " &
      "backend is unavailable in M14")

  var gapCapabilities = LinuxPreloadKnownUnsupportedCapabilities
  for capability in required:
    if capability notin result.supportedCapabilities:
      gapCapabilities.incl capability
      result.evidenceComplete = false

  for capability in gapCapabilities:
    let requiredGap = capability in required and
      capability notin result.supportedCapabilities
    result.gaps.add MonitorCapabilityGap(
      backendFamily: result.backendFamily,
      capability: capability,
      required: requiredGap,
      reason: linuxUnsupportedReason(capability))
    if requiredGap:
      result.diagnostics.add MonitorDiagnostic(
        level: mdlError,
        message: "required monitor capability is unsupported by " &
          backendFamilyId(result.backendFamily) & ": " &
          capabilityId(capability))

proc defaultHooksMonitorProfile*(
    required: set[MonitorCapability] = {}): MonitorBackendProfile =
  when defined(linux):
    linuxPreloadMonitorProfile(required)
  else:
    macosInterposeMonitorProfile(required)

proc profileRecords*(profile: MonitorBackendProfile): seq[MonitorRecord] =
  result.add backendProfileRecord(profile)
  for gap in profile.gaps:
    result.add capabilityGapRecord(gap)

proc profileFromRecords*(records: openArray[MonitorRecord];
                         required: set[MonitorCapability] = {}):
                         MonitorBackendProfile =
  result = defaultHooksMonitorProfile(required)
  var sawProfile = false
  var gaps: seq[MonitorCapabilityGap] = @[]
  for record in records:
    case record.kind
    of mrBackendProfile:
      sawProfile = true
      for part in record.detail.split(';'):
        let pair = part.split("=", 1)
        if pair.len != 2:
          continue
        case pair[0]
        of "backend":
          result.backendFamily = backendFamilyFromId(pair[1])
        of "supported":
          result.supportedCapabilities = parseCapabilityList(pair[1])
        of "required":
          result.requiredCapabilities = parseCapabilityList(pair[1])
        of "evidenceComplete":
          result.evidenceComplete = pair[1] == "true"
        else:
          discard
    of mrCapabilityGap:
      try:
        var gap = parseGapDetail(record.detail)
        if gap.capability in required and
            gap.capability notin result.supportedCapabilities:
          gap.required = true
        gaps.add gap
      except ValueError:
        result.diagnostics.add MonitorDiagnostic(
          level: mdlWarning,
          message: "malformed monitor capability gap record: " & record.detail)
    else:
      discard

  if sawProfile and gaps.len > 0:
    result.gaps = gaps

  for capability in required:
    result.requiredCapabilities.incl capability
    if capability notin result.supportedCapabilities:
      result.evidenceComplete = false
      var found = false
      for gap in result.gaps.mitems:
        if gap.capability == capability:
          gap.required = true
          found = true
      if not found:
        result.gaps.add MonitorCapabilityGap(
          backendFamily: result.backendFamily,
          capability: capability,
          required: true,
          reason: if result.backendFamily == mbfLinuxPreloadHooks:
              linuxUnsupportedReason(capability)
            else:
              unsupportedReason(capability))

proc evaluateMonitorEvidence*(dep: MonitorDepFile;
                              required: set[MonitorCapability]):
                              MonitorBackendProfile =
  result = profileFromRecords(dep.records, required)
  if dep.summary.eventLossCount != 0:
    result.evidenceComplete = false
    result.diagnostics.add MonitorDiagnostic(
      level: mdlError,
      message: "monitor evidence contains event-loss records")
