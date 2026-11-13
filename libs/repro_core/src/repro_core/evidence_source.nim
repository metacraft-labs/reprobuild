## Where a record's dependency evidence came from, as a published record
## states it to another host (Edge-Derived-Identities.md §3.1, "The evidence
## source"; campaign M17 chunk 2, `rbpm-v2` and peer-cache memo entry v4).
##
## §3.1: the evidence source of a published trace is "either `monitored`
## (Level 0, non-empty), or the registry name of a declared-complete format
## (Build-Engine-And-Scheduler.md §\"Recognized dependency formats\")". The
## engine grades monitored executions on the monitor-loss ladder
## (`evidence_level.nim`), and an execution NO monitor graded keeps the
## ladder's default grade, Level 0 -- a builtin, a recognized depfile, a
## converter's output. Until this field existed a published record could not
## tell the two apart: both said "Level 0". This field is what lets a reader
## (and the publication rule) see which it is.
##
## The engine derives the source from the action's dependency-gathering
## policy and kind (`evidenceSourceOf` in `repro_build_engine`):
##
## * `eskMonitored` -- the action ran under io-mon (`dgAutomaticMonitor`, or a
##   recognized report / converter VALIDATED by the monitor);
## * `eskRecognizedFormat` -- a recognized dependency report the action
##   produces, by its registry name (`make-depfile`, `iomon` for an edge that
##   produces its own capture, ...), with no monitor of the action itself;
## * `eskConvertedFormat` -- a post-build converter's output format, unmonitored;
## * `eskBuiltin` -- an in-process engine action (copy, write-text, stamp, a
##   provisioner request ...): no child process exists to monitor, and its
##   evidence is its declared inputs and outputs. It names its BUILTIN KIND
##   (`builtin:<kind>`, `builtinKind`), because whether a builtin's declared
##   inputs are all it reads depends on the kind (owner decision 2026-10-31,
##   Edge-Derived-Identities.md §3.1 / §10 decision 23 rider): the
##   publication rule admits only the kinds proven to read exactly their
##   declared inputs (`publication_rule.PublishableBuiltinKinds`), so a
##   consumer must be able to read the kind off the signed record.
##
## The text form grew the kind on 2026-11-03. An older reader refuses
## `builtin:<kind>` (it parses no name on `builtin`), and this reader reads
## the older bare `builtin` as a builtin of UNSTATED kind, which the rule
## refuses: both directions fail closed, so the value-space extension needs
## no new container version (the field is inside the signed v4 memo entry
## and the `rbpm-v2` record either way).
##
## `eskUnstated` is what a record says when its writer never said: a local
## access sidecar written before the field, a memo entry from an older
## producer. Nothing may be published on its behalf, and a consumer refuses
## it, exactly as for an unstated evidence level.

import std/strutils

type
  EvidenceSourceKind* = enum
    eskUnstated = "unstated"
    eskMonitored = "monitored"
    eskRecognizedFormat = "format"
    eskConvertedFormat = "converter"
    eskBuiltin = "builtin"

  EvidenceSource* = object
    kind*: EvidenceSourceKind
    format*: string
      ## The registry name(s) of the format, for `eskRecognizedFormat` and
      ## `eskConvertedFormat` (several reports are joined by `+`, sorted).
      ## Empty for every other kind.
    builtinKind*: string
      ## For `eskBuiltin`: the builtin's kind (`write-text`, `copy-file`,
      ## `foreign-provision`, ...; `repro_build_engine.builtinKindName`).
      ## Empty for every other kind, and for a builtin record written before
      ## the kind was stated, which no rule may publish on its behalf.

const
  MonitoredEvidence* = EvidenceSource(kind: eskMonitored)
  BuiltinEvidence* = EvidenceSource(kind: eskBuiltin)
  UnstatedEvidence* = EvidenceSource(kind: eskUnstated)

func formatEvidence*(name: string): EvidenceSource =
  EvidenceSource(kind: eskRecognizedFormat, format: name)

func convertedEvidence*(name: string): EvidenceSource =
  EvidenceSource(kind: eskConvertedFormat, format: name)

func builtinEvidence*(builtinKind: string): EvidenceSource =
  ## A builtin's evidence, naming its kind.
  EvidenceSource(kind: eskBuiltin, builtinKind: builtinKind)

func `$`*(source: EvidenceSource): string =
  ## The text form a record carries: `monitored`, `builtin:<kind>`,
  ## `unstated`, `format:<name>`, `converter:<name>` (and the older bare
  ## `builtin`, for a builtin of unstated kind).
  case source.kind
  of eskRecognizedFormat, eskConvertedFormat:
    $source.kind & ":" & source.format
  of eskBuiltin:
    if source.builtinKind.len > 0: $source.kind & ":" & source.builtinKind
    else: $source.kind
  else:
    $source.kind

func parseEvidenceSource*(text: string; source: var EvidenceSource): bool =
  ## Inverse of `$`. False for any text no writer produces (an unknown kind,
  ## a format kind with no name, a name on a kind that takes none).
  let colon = text.find(':')
  let head = if colon < 0: text else: text[0 ..< colon]
  let tail = if colon < 0: "" else: text[colon + 1 .. ^1]
  for kind in EvidenceSourceKind:
    if head == $kind:
      case kind
      of eskRecognizedFormat, eskConvertedFormat:
        if colon < 0 or tail.len == 0:
          return false
        source = EvidenceSource(kind: kind, format: tail)
      of eskBuiltin:
        # `builtin:<kind>`, or the older bare `builtin` (kind unstated).
        if colon >= 0 and tail.len == 0:
          return false
        source = EvidenceSource(kind: kind, builtinKind: tail)
      else:
        if colon >= 0:
          return false
        source = EvidenceSource(kind: kind)
      return true
  false

func describeEvidenceSource*(source: EvidenceSource): string =
  case source.kind
  of eskUnstated: "an unstated evidence source"
  of eskMonitored: "monitored evidence"
  of eskRecognizedFormat:
    "the recognized dependency format '" & source.format & "' (unmonitored)"
  of eskConvertedFormat:
    "the converted dependency format '" & source.format & "' (unmonitored)"
  of eskBuiltin:
    if source.builtinKind.len > 0:
      "the declared inputs of a '" & source.builtinKind & "' builtin " &
        "(unmonitored)"
    else:
      "a builtin's declared inputs, of an unstated builtin kind (unmonitored)"
