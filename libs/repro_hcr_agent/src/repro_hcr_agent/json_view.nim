import std/[json, options]

import repro_hcr_agent/coordinator
import repro_hcr_agent/protocol
import repro_hcr_agent/session
import repro_hcr_agent/transport

const
  HcrCoordinatorReportSchemaId* =
    "reprobuild.hcr.coordinator-report.v1"
  HcrAgentProtocolTranscriptSchemaId* =
    "reprobuild.hcr.agent-protocol-transcript.v1"

proc directionName*(direction: HcrMessageDirection): string =
  case direction
  of hmdCoordinatorToAgent: "coordinator-to-agent"
  of hmdAgentToCoordinator: "agent-to-coordinator"

proc transcriptEntryJson*(entry: HcrProtocolTranscriptEntry): JsonNode =
  %*{
    "direction": entry.direction.directionName,
    "kind": entry.message.kind.kindName,
    "messageId": entry.message.messageId,
    "rawFrameByteCount": entry.rawFrame.len,
    "message": agentMessageJson(entry.message)
  }

proc transcriptJson*(entries: openArray[HcrProtocolTranscriptEntry]):
    JsonNode =
  result = newJObject()
  result["schemaId"] = %HcrAgentProtocolTranscriptSchemaId
  var messages = newJArray()
  for entry in entries:
    messages.add transcriptEntryJson(entry)
  result["messages"] = messages

proc coordinatorDeliveryJson*(delivery: HcrCoordinatorDelivery): JsonNode =
  result = newJObject()
  result["schemaId"] = %HcrCoordinatorReportSchemaId
  result["supportProfile"] = %delivery.session.supportProfile
  result["sessionState"] = %($delivery.session.state)
  result["activePatchId"] = %delivery.session.activePatchId
  result["agentCapabilities"] = %delivery.session.agentCapabilities
  result["lifecycleEvents"] = %delivery.session.lifecycleEvents
  result["transcript"] = transcriptJson(delivery.transcript)
  if delivery.patchApplied.isSome:
    result["patchApplied"] =
      agentMessageJson(HcrAgentMessage(
        schemaId: HcrAgentProtocolSchemaId,
        transportScope: HcrAgentTransportScope,
        protocolVersion: HcrAgentProtocolVersion,
        messageId: "coordinator-report-patch-applied",
        kind: hmkPatchApplied,
        patchApplied: delivery.patchApplied.get()))["patchApplied"]
  if delivery.patchFailed.isSome:
    result["patchFailed"] =
      agentMessageJson(HcrAgentMessage(
        schemaId: HcrAgentProtocolSchemaId,
        transportScope: HcrAgentTransportScope,
        protocolVersion: HcrAgentProtocolVersion,
        messageId: "coordinator-report-patch-failed",
        kind: hmkPatchFailed,
        patchFailed: delivery.patchFailed.get()))["patchFailed"]
