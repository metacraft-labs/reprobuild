## THE cross-host publication rule (Edge-Derived-Identities.md §3.3a, §3.4
## item 1 and §3.6; §10 decisions 11 and 13), over the facts every record
## format states. Campaign M17.
##
## There is one rule, and every publisher and every consumer of a record from
## another host applies it: the portable memo publisher and its consumer
## (`portable_memo.portableRecordRefusal`, over an `rbpm-v2` record), the
## two-phase peer-cache producer and consumer (`repro_local_store.
## publicationRefusal`, over the local `ActionResultRecord` a memo entry
## carries). Each format adapter only extracts the facts below from its record;
## the decision is made here, once, so the two transports cannot drift apart
## (M17 chunk 2: "keep their rules identical, through shared code").
##
## It decides from what the record already carries, and computes no identity:
## publication never hashes a record's inputs after the fact to make it
## publishable.

import repro_core/evidence_level
import repro_core/evidence_source
import repro_core/input_check_policy

const
  AssignedDeclaredCompleteFormats* = ["nix-pure-flake"]
    ## The recognized dependency formats Edge-Derived-Identities.md assigns
    ## to an edge kind as declared-complete evidence (§3.4 item 1, "a
    ## declared-complete format (§5, §6) counts as complete only for the edge
    ## kinds this document assigns it to"): `nix-pure-flake`, for the
    ## `nix-eval` edge of a pure locked flake (§5.3). A record evidenced by
    ## one of these may publish. Binding the format to its edge kind is the
    ## registration's job (the edge that declares `nix-pure-flake` is the
    ## pure-flake `nix-eval` edge, M19); nothing declares it yet.

proc nonMonitoredSourceRefusal*(source: EvidenceSource): string =
  ## Whether a record whose evidence came from no monitor may cross hosts.
  ## Owner decision, 2026-10-29 (Edge-Derived-Identities.md §3.1 and §3.4
  ## riders, §10 decision 23): "builtins yes, depfiles no".
  ##
  ## * `builtin`: publishes. An engine builtin runs in-process, and the engine
  ##   knows every byte it reads: its declared inputs and payload ARE its
  ##   reads.
  ## * `format:<name>` and `converter:<name>`: refused, unless the format is
  ##   one EDI assigns to an edge kind (`AssignedDeclaredCompleteFormats`,
  ##   today only `nix-pure-flake`). A depfile is the tool's account of what
  ##   it read, and it typically leaves out the compiler binary itself, the
  ##   system headers (`-MMD`) and the environment, so it is not complete
  ##   evidence for another host. The record stays local and keeps serving
  ##   this host. That includes `format:iomon` (an edge that hands the engine
  ##   its own capture) and any combination of formats.
  ##
  ## Called for every source other than `monitored` by
  ## `publicationRuleRefusal`, so both transports (the portable memo and the
  ## peer cache) and both ends (producer and consumer) apply it.
  case source.kind
  of eskBuiltin, eskMonitored:
    ""
  of eskRecognizedFormat:
    if source.format in AssignedDeclaredCompleteFormats:
      ""
    else:
      "the record's evidence is " & describeEvidenceSource(source) &
        "; a record evidenced by a dependency report rather than by the " &
        "monitor does not leave this host (a depfile typically omits the " &
        "compiler binary, system headers and the environment; owner " &
        "decision 2026-10-29, Edge-Derived-Identities.md §3.4 item 1)"
  of eskConvertedFormat:
    "the record's evidence is " & describeEvidenceSource(source) &
      "; a record evidenced by a converted dependency report rather than " &
      "by the monitor does not leave this host (owner decision 2026-10-29, " &
      "Edge-Derived-Identities.md §3.4 item 1)"
  of eskUnstated:
    "the record does not state its evidence source"

proc publicationRuleRefusal*(policy: FileFingerprintPolicy;
                             unhashedRegularInput: string;
                             level: EvidenceLevel;
                             source: EvidenceSource;
                             observations: int): string =
  ## Why a record may NOT leave this host (or be accepted from another), or
  ## "" when it may. `unhashedRegularInput` names a regular-file input the
  ## record carries no content digest for ("" when there is none);
  ## `observations` counts the inputs a consumer would verify.
  ##
  ## In order, the record is refused when:
  ##   1. it was made under `ffpTimestamp`. Its local evidence is metadata,
  ##      and timestamp-only evidence MUST NOT cross a machine
  ##      (Caching-Architecture.md). A project that wants an edge shared
  ##      selects `checksum` or `hybrid` for it;
  ##   2. a regular-file input carries no content hash, which no conforming
  ##      checksum or hybrid record has, so only a forged or damaged record
  ##      reaches this;
  ##   3. its monitor evidence is not Level 0. Level 1 serves locally, but its
  ##      narrowing lives in session memory and travels with nothing; an
  ##      unstated level is refused because Level 1 is what it could hide;
  ##   4. it does not state its evidence source (§3.1: a published trace
  ##      records it), or its evidence came from a dependency report rather
  ##      than the monitor or a builtin (`nonMonitoredSourceRefusal`; owner
  ##      decision 2026-10-29);
  ##   5. it names no observed input at all (`observations == 0`): a record
  ##      keyed on its weak fingerprint alone, which any host with the same
  ##      static description would accept.
  ##
  ## The reason names the policy, the level, the source or the missing
  ## evidence, because a refusal at publication is a diagnostic, never an
  ## error: the record stays local and keeps serving this host.
  if policy notin {ffpChecksum, ffpHybrid}:
    return "the record was made under the " & $policy & " input-check " &
      "policy; only ffpChecksum and ffpHybrid records leave this host " &
      "(Edge-Derived-Identities.md §3.3a). Select checksum or hybrid for " &
      "an edge whose results should be shared"
  if unhashedRegularInput.len > 0:
    return "input " & unhashedRegularInput & " is a regular file the record " &
      "carries no content hash for, under the " & $policy & " policy; " &
      "such a record does not leave this host " &
      "(Edge-Derived-Identities.md §3.3a)"
  if level != elComplete:
    return "the record's monitor evidence is " &
      describeEvidenceLevel(level) & "; only Level-0 records leave this " &
      "host (Edge-Derived-Identities.md §3.4 item 1)"
  if source.kind == eskUnstated:
    return "the record does not state its evidence source (" &
      describeEvidenceSource(source) & "); a published trace records " &
      "whether its evidence was monitored or which format reported it " &
      "(Edge-Derived-Identities.md §3.1)"
  if source.kind != eskMonitored:
    let refused = nonMonitoredSourceRefusal(source)
    if refused.len > 0:
      return refused
  if observations <= 0:
    return "the record names no observed input (zero evidence), so it " &
      "would be accepted on its weak fingerprint alone; it does not leave " &
      "this host (Edge-Derived-Identities.md §3.4 item 1)"
  ""
