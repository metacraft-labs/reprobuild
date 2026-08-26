## Reprobuild's ONLY read path into RunQuota's observation store (M18).
##
## Normative specification:
##
## * ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Query Interface"
##   and invariants OS-2 (honest completeness) and OS-6 (hardware-qualified
##   statistics);
## * ``reprobuild-specs/Build-Analytics-And-Optimization.md`` §"Two Stores";
## * ``reprobuild-specs/Retired-Names.md`` §"Analytics store paths and
##   schema ids".
##
## **NOTHING HERE OPENS A DATABASE FILE.** ``runquotad`` is the only
## sanctioned reader of the observation store, so every fact below arrives
## over RQSP: the rows through ``queryStats``, the loss counters through the
## ``observations`` inspection subject. This module does not link
## ``runquota_observation_store`` and must not: a client that opened the file
## would be a second reader of a schema RunQuota owns, past every scoping
## rule the daemon applies.
##
## **THE THREE EMPTY WINDOWS ARE THREE DIFFERENT ANSWERS, AND THIS MODULE
## EXISTS TO KEEP THEM APART.** A view with no figures because no daemon is
## running, a view with no figures because nothing has been built, and a view
## with no figures because the query itself failed are not the same state,
## and OS-2 forbids presenting any of them as a complete sample:
##
##   "A thinned sample MUST NEVER be presentable as complete — statistics
##    over a silently truncated window are worse than absent statistics,
##    because they read as authoritative."
##
## M13a's query interface already answers UNKNOWN distinguishably from a
## distribution that is known to be zero. Collapsing that distinction into
## "no rows" here would throw away the one thing the read path was built to
## preserve, so ``SharedStoreState`` keeps each state a separate value and
## ``figuresArePresentable`` is the single predicate every caller asks before
## rendering a number.

import std/[json, options, os, strutils]

import runquota_client
import runquota_ipc except connectDefault
import runquota_protocol

type
  SharedStoreState* = enum
    ## Why a window looks the way it does. The first four are all "no
    ## figures", and they are FOUR VALUES rather than one because a reader
    ## acts differently on each: start the daemon, report a bug, enable
    ## capture, or build something.
    sssDaemonUnreachable = "unavailable"
      ## No ``runquotad`` answered. OS-4: this is not an error, and it is
      ## not zero either.
    sssQueryFailed = "query-failed"
      ## A daemon answered the handshake and then failed the query. Kept
      ## apart from ``sssDaemonUnreachable`` because "nobody is listening"
      ## and "the reader is broken" have different owners.
      ##
      ## NOT EXERCISED BY ANY TEST. Reaching it needs a daemon that
      ## completes a handshake and then refuses ``queryStats``, which no
      ## fixture here can produce. No gate clause rides on it, so it is an
      ## unexercised branch rather than a check that cannot fail -- but
      ## the "four distinguishable answers" claim is proven for two of
      ## them (``unavailable`` vs ``empty``), not four.
    sssCaptureDisabled = "capture-disabled"
      ## The daemon is running and is recording nothing, so the window is
      ## empty by configuration rather than by history.
      ##
      ## ALSO NOT EXERCISED: ``runquotad`` would have to be started with
      ## capture off. Same standing as ``sssQueryFailed`` above.
    sssEmpty = "empty"
      ## The daemon answered, capture is on, and it knows nothing about
      ## this scope. This is M13a's UNKNOWN, carried through.
    sssIncomplete = "incomplete"
      ## Rows are present AND the daemon counted at least one dropped or
      ## refused observation. The figures are real and the sample is
      ## thinned, which is exactly the state OS-2 forbids rendering as
      ## complete.
    sssComplete = "complete"
      ## Rows are present and nothing was counted lost.

  SharedStoreProfile* = object
    ## OS-6: no aggregate may be reported without the host and
    ## hardware-profile dimension. Carried on every response by the query
    ## interface and carried through to every rendered statistic here.
    hostId*: string
    profileId*: string
    profileHash*: string
    cpuModel*: string
    logicalCores*: int64

  SharedStoreLoss* = object
    ## The daemon's own count of what it lost, read back through the
    ## ``observations`` inspection subject — the place the daemon's write
    ## path documents as where OS-2's "every dropped observation MUST be
    ## counted" is satisfied, since every lossy message on that path is
    ## one-way and cannot report a refusal to its client.
    ##
    ## EXACT COUNTERS, NOT A SAMPLED QUANTITY. Each field is a monotonic
    ## counter the daemon increments at the point of loss, so a comparison
    ## against zero cannot come out differently depending on when the
    ## reader happened to look.
    known*: bool
    dropped*: int64
      ## Observations offered to the writer queue and not queued.
    writeFailures*: int64
    rejected*: int64
      ## Lease self-reports the daemon refused. One-way message, so the
      ## client was never told.
    extensionRowsRefused*: int64
      ## ``ext_repro_action`` rows the daemon would not store. Same shape.
    deferredBatchesRefused*: int64
    contradictoryExecutions*: int64
      ## WHOLE EXECUTIONS the daemon refused to store because the finish
      ## that reported them contradicted its own evidence -- a kill claim
      ## beside ``exit_status = 0``. The daemon acknowledges the finish
      ## anyway (refusing ``LeaseFinished`` would strand the lease), so the
      ## client believes it reported an execution the store does not hold,
      ## and this counter is the ONLY place that loss is visible.
      ##
      ## COUNTED SEPARATELY FROM ``rejected`` for the reason the daemon
      ## keeps the two keys apart: ``rejected`` is a refused SAMPLE of a
      ## live execution, this is the execution itself. Both are losses, so
      ## both enter ``totalLost`` -- a window thinned by either one is
      ## thinned, and OS-2 does not grade thinning by cause.

  SharedActionRow* = object
    ## One ``ext_repro_action`` row with the spine context RunQuota joined
    ## it to. The extension values arrive as opaque text (OS-5); this
    ## module pairs them with their column names and interprets nothing
    ## beyond what ``docs/stats.md`` documents reprobuild as writing.
    executionId*: string
    statsKey*: string
    profile*: SharedStoreProfile
    columns*: seq[string]
    values*: seq[string]

  SharedExecution* = object
    ## One spine row.
    executionId*: string
    statsKey*: string
    profile*: SharedStoreProfile
    startedAtUnixMillis*: int64
    durationMillis*: int64
    peakRssBytes*: int64
    exitStatus*: int64
    termination*: string

  SharedStoreView* = object
    ## Everything ``repro stats`` is allowed to know, and the state that
    ## says how much of it may be rendered.
    state*: SharedStoreState
    reason*: string
      ## Human-readable, and never empty for a state that carries no
      ## figures: a view that says "no data" without saying why is the
      ## thing this type exists to prevent.
    scopeApplied*: StatsScopeWire
      ## WHOSE ROWS THESE ARE, taken from the daemon's own answer rather
      ## than from what was asked, and rendered on every surface. A
      ## figure whose scope is not stated is the same class of dishonesty
      ## as one whose sample size is not stated: on a shared host a
      ## host-wide window silently includes other users' builds, and a
      ## reader who cannot see that reads it as this project's.
      ##
      ## THERE IS NO ``spanApplied`` HERE, AND THAT IS A FINDING RATHER
      ## THAN AN OVERSIGHT. ``scopeApplied`` is carried because the daemon
      ## CAN disagree with the request — the estimate path widens an owner
      ## scope to host and says so — so the answer carries information the
      ## request does not. ``spanApplied`` cannot: ``ProfileSpan`` and
      ## ``ProfileSpanWire`` are ordinal-identical two-value enums, the
      ## daemon sets the field to ``request.span.toStore.toWire``, and
      ## nothing anywhere overrides it. A field carried on that basis would
      ## be the REQUEST wearing the answer's clothes — worse than absent,
      ## because a reader takes "applied" for a daemon-confirmed fact.
      ## Host qualification is genuinely carried, by ``profiles`` (OS-6),
      ## which is derived from the ROWS and is rendered on every surface.
    endpoint*: string
    captureEnabled*: bool
    storePath*: string
    loss*: SharedStoreLoss
    executions*: seq[SharedExecution]
    actionRows*: seq[SharedActionRow]

const
  SharedStoreNullMarker* = "~"
    ## What RunQuota renders SQL NULL as on the wire
    ## (``runquota_observation_store/sqlite_cli.nim``). Spelled here rather
    ## than imported because importing it would mean linking the
    ## observation store, which is the one thing this module must not do.
  ReproActionExtension* = "repro_action"
  ReproActionQueryColumns* = [
    "action_id", "action_kind", "compatibility_key", "cache_outcome",
    "cache_miss_reason", "weak_fingerprint", "strong_fingerprint", "pool",
    "pool_units", "output_bytes", "substituted", "tool_kind", "tool_identity",
    "declared_inputs", "declared_outputs", "depfile_inputs", "monitor_reads",
    "monitor_writes", "monitor_probes"]

proc scopeText*(scope: StatsScopeWire): string =
  ## The scope axis, spelled for a human. Not ``$scope``: the wire
  ## enumerator names are protocol identifiers, and a surface that leaks
  ## them tells a reader less than one word would.
  case scope
  of statsScopeWireOwner: "owner"
  of statsScopeWireHost: "host"

proc figuresArePresentable*(state: SharedStoreState): bool =
  ## The one predicate a renderer asks. Deliberately a function of the
  ## STATE rather than of ``executions.len``: a caller testing the row
  ## count would render an unreachable daemon and an empty store
  ## identically, which is the collapse OS-2 forbids.
  state in {sssComplete, sssIncomplete}

proc isComplete*(state: SharedStoreState): bool =
  state == sssComplete

proc totalLost*(loss: SharedStoreLoss): int64 =
  if not loss.known:
    return 0
  loss.dropped + loss.writeFailures + loss.rejected +
    loss.extensionRowsRefused + loss.deferredBatchesRefused +
    loss.contradictoryExecutions

proc sampleCount*(view: SharedStoreView): int =
  ## The number of SPINE rows the figures were computed over. Reported
  ## beside every statistic because a figure without its sample size is
  ## not a statistic.
  ##
  ## **THE SPINE/EXTENSION DISTINCTION HERE IS NOT YET UNDER TEST, AND
  ## THAT IS RECORDED RATHER THAN ASSUMED AWAY.** Replacing this body with
  ## ``view.actionRows.len`` and running ``t_stats_reads_shared_store``
  ## leaves all four arms GREEN (measured 2026-08-25, macOS arm64): every
  ## fixture in that file builds only reprobuild actions, so each spine row
  ## carries exactly one ``ext_repro_action`` row and the two counts never
  ## disagree. On a real shared store they routinely do -- a lease taken by
  ## a test runner, or by any other RunQuota client, is a spine row with no
  ## reprobuild extension attached. Discriminating the two needs a fixture
  ## that produces one lease-taking execution WITHOUT an ``ext_repro_action``
  ## row; until it exists, "sample count" is proven present and non-zero but
  ## not proven to count the spine.
  view.executions.len

proc firstObservationUnixMillis*(view: SharedStoreView): int64 =
  result = 0
  for entry in view.executions:
    if entry.startedAtUnixMillis > 0 and
        (result == 0 or entry.startedAtUnixMillis < result):
      result = entry.startedAtUnixMillis

proc lastObservationUnixMillis*(view: SharedStoreView): int64 =
  for entry in view.executions:
    let ends = entry.startedAtUnixMillis + entry.durationMillis
    if ends > result:
      result = ends

proc profiles*(view: SharedStoreView): seq[SharedStoreProfile] =
  ## Every distinct hardware profile the window touches, in first-seen
  ## order. NOT folded into one: OS-6 refuses an aggregate that pools rows
  ## from different hardware, and the query interface already returns one
  ## entry per profile rather than a blend. A caller that finds two here
  ## is looking at two machines' figures and must say so.
  for entry in view.executions:
    var seen = false
    for known in result:
      if known.hostId == entry.profile.hostId and
          known.profileId == entry.profile.profileId:
        seen = true
        break
    if not seen:
      result.add(entry.profile)
  for entry in view.actionRows:
    var seen = false
    for known in result:
      if known.hostId == entry.profile.hostId and
          known.profileId == entry.profile.profileId:
        seen = true
        break
    if not seen:
      result.add(entry.profile)

proc value*(row: SharedActionRow; column: string): string =
  for i, name in row.columns:
    if name == column and i < row.values.len:
      return row.values[i]
  ""

proc hasValue*(row: SharedActionRow; column: string): bool =
  ## SQL NULL comes back as the store's null marker, so "the column is
  ## absent" and "the column is the empty string" stay distinguishable.
  ##
  ## THE NULL-MARKER DISCRIMINATION IS UNASSERTED. Its one caller filters
  ## the ``Pools:`` line of ``stats overview``, and no test asserts that
  ## line at all -- so nothing here distinguishes ``~`` from a real value
  ## in either direction. This is the exact shape §"WHERE THE VACUOUS
  ## CHECKS COME FROM" lists third ("the NULL marker asserted only against
  ## values that could never be confused with it"), one degree worse.
  ## Recorded, not claimed as proven.
  for i, name in row.columns:
    if name == column and i < row.values.len:
      return row.values[i].len > 0 and row.values[i] != SharedStoreNullMarker
  false

proc toProfile(wire: ProfileIdentityWire): SharedStoreProfile =
  SharedStoreProfile(
    hostId: wire.hostId,
    profileId: (if wire.profileIdPresent: wire.profileId else: ""),
    profileHash: wire.profileHash,
    cpuModel: wire.cpuModel,
    logicalCores: int64(wire.logicalCores))

proc profileJson*(profile: SharedStoreProfile): JsonNode =
  %*{
    "hostId": profile.hostId,
    "profileId": profile.profileId,
    "profileHash": profile.profileHash,
    "cpuModel": profile.cpuModel,
    "logicalCores": profile.logicalCores
  }

proc lossJson*(loss: SharedStoreLoss): JsonNode =
  if not loss.known:
    return %*{"known": false}
  %*{
    "known": true,
    "dropped": loss.dropped,
    "writeFailures": loss.writeFailures,
    "rejected": loss.rejected,
    "extensionRowsRefused": loss.extensionRowsRefused,
    "deferredBatchesRefused": loss.deferredBatchesRefused,
    "contradictoryExecutions": loss.contradictoryExecutions,
    "total": loss.totalLost
  }

proc windowJson*(view: SharedStoreView): JsonNode =
  ## THE QUALIFICATION EVERY REPORTED STATISTIC CARRIES: which window, how
  ## many samples, on what hardware, and whether the sample is whole.
  ##
  ## ``complete`` is a THIRD value rather than a boolean pair with
  ## ``available``: a window can be available and thinned at the same
  ## time, and rendering that as "available" alone is precisely the
  ## silently-thin presentation OS-2 rules out.
  var profileNodes = newJArray()
  for profile in view.profiles:
    profileNodes.add(profileJson(profile))
  result = %*{
    "source": "runquota-observation-store",
    "state": $view.state,
    "available": figuresArePresentable(view.state),
    "complete": view.state == sssComplete,
    "reason": view.reason,
    "scope": scopeText(view.scopeApplied),
    "endpoint": view.endpoint,
    "captureEnabled": view.captureEnabled,
    "sampleCount": view.sampleCount,
    "actionRowCount": view.actionRows.len,
    "firstObservationUnixMs": view.firstObservationUnixMillis,
    "lastObservationUnixMs": view.lastObservationUnixMillis,
    "profiles": profileNodes,
    "loss": lossJson(view.loss)
  }

proc windowText*(view: SharedStoreView): string =
  ## One line, and it always names the state. A renderer that printed
  ## figures without this line would be presenting a window whose
  ## provenance the reader cannot see.
  var parts = @[
    "store: runquota observation store (" & view.endpoint & ")",
    "state: " & $view.state,
    "scope: " & scopeText(view.scopeApplied)
  ]
  if figuresArePresentable(view.state):
    parts.add("samples: " & $view.sampleCount)
    parts.add("window: " & $view.firstObservationUnixMillis & ".." &
      $view.lastObservationUnixMillis & "ms")
    var names: seq[string] = @[]
    for profile in view.profiles:
      names.add(profile.hostId & "/" & profile.profileId)
    parts.add("profiles: " & (if names.len == 0: "none" else: names.join(",")))
    if view.state == sssIncomplete:
      parts.add("INCOMPLETE: " & $view.loss.totalLost &
        " observations counted lost")
  else:
    parts.add("reason: " & view.reason)
  parts.join(" | ")

proc parseLoss(payload: string): SharedStoreLoss =
  ## The ``observations`` inspection subject, parsed. A payload that does
  ## not carry the counters leaves ``known`` false, which renders as
  ## "loss unknown" rather than as zero: a reader told "0 lost" by a
  ## daemon that never said so has been told something false.
  try:
    let root = parseJson(payload){"observations"}
    if root.isNil or root.kind != JObject:
      return
    result.known = true
    result.dropped = root{"dropped"}.getBiggestInt(0)
    result.writeFailures = root{"write_failures"}.getBiggestInt(0)
    result.rejected = root{"rejected"}.getBiggestInt(0)
    result.extensionRowsRefused =
      root{"extension_rows_refused"}.getBiggestInt(0)
    result.deferredBatchesRefused =
      root{"deferred_batches_refused"}.getBiggestInt(0)
    result.contradictoryExecutions =
      root{"executions_contradictory"}.getBiggestInt(0)
  except CatchableError:
    result = SharedStoreLoss()

proc endpointPath(): string =
  try:
    defaultEndpoint().path
  except CatchableError:
    getEnv("RUNQUOTA_SOCKET")

proc readSharedStore*(scope = statsScopeWireOwner;
                      span = profileSpanWireAll;
                      limit = 0'u32): SharedStoreView =
  ## Ask ``runquotad`` for everything the analysis views need, in one
  ## connection.
  ##
  ## THE DEFAULT SPAN IS ``profileSpanWireAll``, and that is not a
  ## widening of OS-6 but the only honest reading of it. The store returns
  ## ONE DISTRIBUTION PER PROFILE and never blends, so asking for all
  ## profiles yields per-profile answers a renderer can label; asking for
  ## a single profile would silently hide the rows recorded on other
  ## hardware — which is the same window presented as though it were the
  ## whole one.
  ##
  ## THE DEFAULT SCOPE IS THE OWNER'S, AND THE ESTIMATE PATH'S REASONING
  ## DOES NOT REACH HERE. §"Scoping on a shared host" scopes queries to
  ## the calling uid by default and requires widening to be EXPLICIT;
  ## the exemption it grants — "the estimate path is deliberately not
  ## uid-scoped" — is granted to the estimate path by name, because a
  ## cost is a property of the work rather than of who ran it. ``repro
  ## stats`` is one of the HUMAN surfaces the same section lists on the
  ## other side of that line. Hard-coding the widening here would make it
  ## implicit, and on a shared CI account it would fold a dozen users'
  ## builds into a window a reader takes for this project's. A caller
  ## that wants the host-wide answer passes ``statsScopeWireHost``, and
  ## ``scopeApplied`` renders on every surface either way. The uid the
  ## narrow scope resolves to is not a parameter here or anywhere — the
  ## daemon takes it from peer credentials.
  result.scopeApplied = scope
  result.state = sssDaemonUnreachable
  result.endpoint = endpointPath()
  result.reason = "no runquotad answered at " & result.endpoint &
    "; start it, or accept that this project has no shared history yet"

  var client: RunQuotaClient
  try:
    client = connectDefault()
  except CatchableError as err:
    result.reason = "no runquotad answered at " & result.endpoint &
      " (" & err.msg & ")"
    return
  defer: client.close()

  # The loss counters FIRST, so a query that then fails still leaves the
  # view carrying what the daemon said it had already lost.
  try:
    result.loss = parseLoss(client.inspectionJson("observations"))
  except CatchableError:
    result.loss = SharedStoreLoss()

  var executions: StatsResponseMessage
  var rows: StatsResponseMessage
  try:
    executions = client.queryStats(statsSubjectExecutions, scope = scope,
      span = span, limit = limit)
    rows = client.queryStats(statsSubjectExtensionRows, scope = scope,
      span = span, limit = limit, extensionId = ReproActionExtension,
      extensionColumns = ReproActionQueryColumns)
  except CatchableError as err:
    result.state = sssQueryFailed
    result.reason = "runquotad refused the query: " & err.msg
    return

  # FROM THE ANSWER, NOT FROM THE REQUEST. The daemon may widen a scope
  # it will not narrow (the estimate path does exactly that), so the
  # scope a reader is shown must be the one the rows were selected under.
  result.scopeApplied = executions.scopeApplied
  result.captureEnabled = executions.captureEnabled
  if not result.captureEnabled:
    result.state = sssCaptureDisabled
    result.reason = "runquotad is running with capture disabled, so this " &
      "window is empty by configuration rather than by history"
    return

  for entry in executions.executions:
    result.executions.add(SharedExecution(
      executionId: entry.executionId,
      statsKey: entry.statsKey,
      profile: toProfile(entry.profile),
      startedAtUnixMillis: int64(entry.startedAtUnixMillis),
      durationMillis: int64(entry.durationMillis),
      peakRssBytes: int64(entry.peakRssBytes),
      exitStatus: int64(entry.exitStatus),
      termination: entry.termination))
  for entry in rows.extensionRows:
    result.actionRows.add(SharedActionRow(
      executionId: entry.executionId,
      statsKey: entry.statsKey,
      profile: toProfile(entry.profile),
      columns: entry.columns,
      values: entry.values))

  let lost = result.loss.totalLost
  if result.executions.len == 0 and result.actionRows.len == 0:
    if lost > 0:
      # NOT ``sssEmpty``. A window that lost everything it was offered is
      # not a window in which nothing happened, and the difference is the
      # whole of OS-2.
      result.state = sssIncomplete
      result.reason = "runquotad counted " & $lost &
        " lost observations and holds no rows for this scope"
    else:
      result.state = sssEmpty
      result.reason = "runquotad holds no executions for this scope yet"
    return
  if lost > 0:
    result.state = sssIncomplete
    result.reason = "runquotad counted " & $lost &
      " lost observations; this sample is thinned"
  else:
    result.state = sssComplete
    result.reason = ""
