## The monitor-evidence level of one execution, as a record states it to
## another host (Edge-Derived-Identities.md §3.4 item 1; campaign M17).
##
## The engine grades every monitored execution on the monitor-loss ladder
## (Failure-Semantics.md §"Monitoring Failures"; `MonitorEvidenceStatus` in
## `repro_build_engine`). That grade decides what happens LOCALLY: a Level-1
## record is stored and serves this host, its downstream narrowing kept in
## session memory. Whether a record may LEAVE the host is a second question,
## and the answer travels with the record, so it needs a spelling that the
## layers below the engine can read without linking it: the local store keeps
## it beside the record (`InputAccesses`), and the peer cache carries it in
## the attested memo entry (`memo_store.nim`, entry version 3).
##
## `elUnstated` is what a record says when its writer never said anything: a
## memo entry from a producer older than the field, or a local sidecar written
## before it. Nothing may be published on its behalf, and a consumer refuses
## it, because Level 1 is exactly the case such a writer could not exclude.

type
  EvidenceLevel* = enum
    elUnstated = "unstated"
      ## The writer did not state a level.
    elComplete = "level-0"
      ## Level 0: no monitor loss.
    elKnownScopeLoss = "level-1"
      ## Level 1: known-scope loss (kill-before-flush); stored, served
      ## locally, never published.
    elUnknownScopeLoss = "level-2"
      ## Level 2: never stored, so never published.
    elMonitorUnavailable = "level-3"
      ## Level 3: never stored, so never published.

const
  EvidenceLevelUnstatedByte* = 0xff'u8
    ## The wire byte for `elUnstated`. The stated levels are their ladder
    ## number (0-3), so the byte reads as what it means.

func evidenceLevelByte*(level: EvidenceLevel): uint8 =
  case level
  of elUnstated: EvidenceLevelUnstatedByte
  of elComplete: 0'u8
  of elKnownScopeLoss: 1'u8
  of elUnknownScopeLoss: 2'u8
  of elMonitorUnavailable: 3'u8

func evidenceLevelFromByte*(b: uint8; level: var EvidenceLevel): bool =
  ## False for a byte no writer produces.
  case b
  of 0'u8: level = elComplete
  of 1'u8: level = elKnownScopeLoss
  of 2'u8: level = elUnknownScopeLoss
  of 3'u8: level = elMonitorUnavailable
  of EvidenceLevelUnstatedByte: level = elUnstated
  else: return false
  true

func describeEvidenceLevel*(level: EvidenceLevel): string =
  case level
  of elUnstated: "an unstated monitor-evidence level"
  of elComplete: "Level 0 (complete monitoring)"
  of elKnownScopeLoss: "Level 1 (known-scope monitor loss)"
  of elUnknownScopeLoss: "Level 2 (unknown-scope monitor loss)"
  of elMonitorUnavailable: "Level 3 (monitoring unavailable)"
