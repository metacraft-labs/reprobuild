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

const
  PublishableBuiltinKinds* = ["ensure-dir", "write-text", "stamp"]
    ## The builtin kinds whose reads are exactly their declared inputs and
    ## the action's own fingerprinted payload: the ALLOWLIST of owner
    ## decision 2026-10-31 (Edge-Derived-Identities.md §3.1 / §10 decision 23
    ## rider: "Refuse those kinds"; the table of every kind, with its verdict
    ## and the code it rests on, is EDI §10 decision 23's 2026-11-03 rider).
    ##
    ## * `ensure-dir` creates its one output directory and reads nothing;
    ## * `write-text` writes `builtinText`, reading its own output only to
    ##   skip a rewrite of identical bytes;
    ## * `stamp` writes `builtinText` and `builtinEntries` and reads nothing.
    ##
    ## Every other kind is refused, at both ends, by NAME: `copy-file` and
    ## `preserve-tree` copy their sources' mode bits, which no input
    ## identity keys (and `preserve-tree` reads its previous manifest);
    ## `ensure-line` and `ensure-snippet` read the existing contents of the
    ## file they rewrite, which is not an input; `workspace-vcs`,
    ## `binary-cache-substitute`, `foreign-provision`, `metadata-fetch`,
    ## `solve-lock` and `lock-update` run a registered executor that reads
    ## the network, a repository, a daemon or the host. A kind that is not
    ## listed here -- a new one, an unknown name, or a record that does not
    ## state its kind -- is refused by default.

proc builtinKindRefusal*(builtinKind: string): string =
  ## Why a builtin of `builtinKind` may not cross hosts, or "" when it may
  ## (`PublishableBuiltinKinds`).
  if builtinKind.len == 0:
    return "the record's evidence is a builtin's declared inputs, but it " &
      "does not state the builtin's kind; only builtin kinds whose reads " &
      "are exactly their declared inputs leave this host, so a record that " &
      "does not name its kind does not (owner decision 2026-10-31, " &
      "Edge-Derived-Identities.md §10 decision 23)"
  if builtinKind in PublishableBuiltinKinds:
    return ""
  "the record's evidence is the declared inputs of a '" & builtinKind &
    "' builtin, a kind that reads more than its declared inputs (or is not " &
    "known to read only them); a record of that kind does not leave this " &
    "host (owner decision 2026-10-31, Edge-Derived-Identities.md §10 " &
    "decision 23: only builtins whose reads are exactly their declared " &
    "inputs publish)"

proc nonMonitoredSourceRefusal*(source: EvidenceSource): string =
  ## Whether a record whose evidence came from no monitor may cross hosts.
  ## Owner decision, 2026-10-29 (Edge-Derived-Identities.md §3.1 and §3.4
  ## riders, §10 decision 23): "builtins yes, depfiles no", NARROWED by the
  ## owner on 2026-10-31: only the builtin kinds whose reads are exactly
  ## their declared inputs.
  ##
  ## * `builtin:<kind>`: publishes when the kind is in
  ##   `PublishableBuiltinKinds`, and is refused, naming the kind, otherwise
  ##   (`builtinKindRefusal`). The 2026-10-29 premise -- "the engine knows
  ##   every byte a builtin reads" -- holds for those kinds only.
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
  of eskMonitored:
    ""
  of eskBuiltin:
    builtinKindRefusal(source.builtinKind)
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
