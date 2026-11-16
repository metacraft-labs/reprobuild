## The store status every ``repro stats`` view and ``repro pressure``
## report beside their figures: whether capture is on, whether there is a
## store to read at all, and what to run when there is not.
##
## WHY THIS EXISTS. Both commands answer from ``runquotad``. Without these
## fields, "nobody ever set this host up", "the daemon is not running",
## "the daemon records nothing" and "the daemon is fine and has nothing for
## you yet" can all come back as an empty table, which a reader takes for
## "nothing was slow". So each answer carries, at the TOP LEVEL of its JSON
## object:
##
## * ``capture_enabled`` (bool),
## * ``store_status``: ``ready`` | ``unprovisioned`` | ``daemon_unreachable``
##   | ``empty``,
## * ``remedy`` (a command to run), present whenever the status is not
##   ``ready``,
##
## and a text-mode invocation prints ONE line on stderr whenever the status
## is not ``ready`` (``storeStatusNotice``). A ready store whose view matched
## no rows is ``ready``: the status describes the store, not the view's
## filter, so "zero matching rows" and "no store" stay apart.
##
## The keys are spelled with underscores, unlike the camelCase of the stats
## schemas, because the same three keys sit beside the daemon's own
## snake_case ``PressureAnswer`` in ``repro pressure --json`` and a tool that
## reads both commands looks for one spelling.
##
## HOW "UNPROVISIONED" IS TOLD FROM "UNREACHABLE" WHEN NOTHING ANSWERS. A
## daemon that is not listening tells the client nothing, so the
## distinction is made from what is on disk at the endpoint the client
## resolved (``RUNQUOTA_SOCKET``, else the host-wide default):
##
## * a file at the socket path (a stale socket left by a daemon that died),
##   or an existing rendezvous directory around it (a provisioned host's
##   ``/run/runquota``, or a directory an operator pointed
##   ``RUNQUOTA_SOCKET`` into), means a daemon was set up to be there:
##   ``daemon_unreachable``;
## * neither means nothing was ever set up at that endpoint:
##   ``unprovisioned``.
##
## Named-pipe endpoints (Windows) have no directory to inspect, so a failed
## connection there is always ``daemon_unreachable``.

import std/[json, os, strutils]

import runquota_ipc except connectDefault

import repro_runquota/stats_query

type
  StoreStatus* = enum
    ssReady = "ready"
      ## The store answered and holds something to report.
    ssUnprovisioned = "unprovisioned"
      ## Nothing was set up to record: no daemon was ever provisioned at
      ## the endpoint, or the daemon that answered records nothing.
    ssDaemonUnreachable = "daemon_unreachable"
      ## A daemon was set up at the endpoint and did not answer (or
      ## answered and then could not serve the request).
    ssEmpty = "empty"
      ## The daemon answered, records, and holds nothing yet.

  StoreStatusReport* = object
    captureEnabled*: bool
    status*: StoreStatus
    remedy*: string
      ## Empty exactly when ``status`` is ``ssReady``.
    reason*: string
      ## One sentence saying why, for the stderr notice.

proc endpointWasProvisioned*(endpoint: Endpoint): bool =
  ## Whether anything was ever set up at ``endpoint``, judged from the
  ## filesystem only (see the module comment). Never connects.
  case endpoint.kind
  of endpointUnixSocket:
    let path = endpoint.path
    if path.len == 0:
      return false
    if fileExists(path) or symlinkExists(path) or dirExists(path):
      return true
    # ``fileExists`` is false for a socket on some platforms; ask for the
    # entry itself.
    try:
      discard getFileInfo(path, followSymlink = false)
      return true
    except OSError:
      discard
    dirExists(parentDir(path))
  else:
    # A named pipe exists only while a server holds it, so its absence
    # says nothing about provisioning.
    true

proc resolvedEndpoint(): Endpoint =
  try:
    defaultEndpoint()
  except CatchableError:
    Endpoint(kind: endpointUnsupported, path: getEnv("RUNQUOTA_SOCKET"))

proc startDaemonRemedy*(endpointPath: string): string =
  ## The command that puts a recording daemon at ``endpointPath``.
  "runquotad --socket " & quoteShell(endpointPath) &
    " --measurement capture=on"

proc unreachableReport*(endpoint: Endpoint; detail: string): StoreStatusReport =
  ## The report for a client whose connection to ``endpoint`` failed.
  result.captureEnabled = false
  if endpointWasProvisioned(endpoint):
    result.status = ssDaemonUnreachable
    result.reason = "no runquotad answered at " & endpoint.path &
      (if detail.len > 0: " (" & detail & ")" else: "")
    result.remedy = "start runquotad at that endpoint: " &
      startDaemonRemedy(endpoint.path) &
      " (or point RUNQUOTA_SOCKET at a running daemon)"
  else:
    result.status = ssUnprovisioned
    result.reason = "no runquotad has been set up at " & endpoint.path &
      " (neither the socket nor its directory exists)"
    result.remedy = "start a recording runquotad: " &
      startDaemonRemedy(endpoint.path) &
      " (or point RUNQUOTA_SOCKET at a running daemon)"

proc unreachableReport*(detail = ""): StoreStatusReport =
  unreachableReport(resolvedEndpoint(), detail)

proc capturelessDaemonReport*(view: SharedStoreView): StoreStatusReport =
  ## A daemon that answered with capture off. All of these are
  ## ``unprovisioned`` -- there is no store to read -- but "started without
  ## capture" is only ONE reason, and telling every reader to restart with
  ## ``--measurement capture=on`` is wrong for the others. The daemon says
  ## which in the ``store_status`` of its ``observations`` inspection
  ## subject (RunQuota ``docs/database.md``, "Corruption handling" and the
  ## start-up order), carried here as ``view.daemonStoreStatus``.
  result = StoreStatusReport(captureEnabled: false, status: ssUnprovisioned,
    reason: view.reason)
  let store =
    if view.storePath.len > 0: view.storePath
    else: "its observation store"
  let inspect = "runquota inspect observations shows the daemon's " &
    "store_status"
  case view.daemonStoreStatus
  of "verifying":
    # THE DAEMON WAS STARTED WITH CAPTURE ON. It binds its endpoint before
    # its store's integrity check returns, and records nothing until the
    # check passes; a restart would only start the check again.
    result.reason = "runquotad is still verifying " & store &
      "; capture starts once the check passes"
    result.remedy = "wait for runquotad to finish checking its store, " &
      "then run this again (" & inspect & ")"
  of "degraded-corrupt":
    result.reason = "runquotad found " & store & " corrupt and is " &
      "recording nothing"
    result.remedy = "stop runquotad, move " & store & " aside, then " &
      "start it again: " & startDaemonRemedy(view.endpoint)
  of "degraded-unwritable":
    result.reason = "runquotad cannot write " & store &
      " and is recording nothing"
    result.remedy = "make " & store & " and its directory writable by " &
      "the daemon's user, then restart it: " &
      startDaemonRemedy(view.endpoint)
  of "degraded-no-sqlite-tool":
    result.reason = "runquotad found no sqlite3 on its PATH and is " &
      "recording nothing"
    result.remedy = "put sqlite3 on runquotad's PATH, then restart it: " &
      startDaemonRemedy(view.endpoint)
  of "refused-newer-schema":
    result.reason = store & " was written by a newer runquotad, so " &
      "this one is recording nothing"
    result.remedy = "upgrade runquotad to the release that wrote " &
      store & ", then restart it"
  else:
    # ``disabled``, or a daemon that did not say: started without capture.
    result.remedy = "restart runquotad with --measurement capture=on: " &
      startDaemonRemedy(view.endpoint) & " (" & inspect & ")"

proc statsStoreStatus*(view: SharedStoreView;
                       projectRoot: string): StoreStatusReport =
  ## The status of the RunQuota observation store every ``repro stats``
  ## view renders from, mapped from the state ``readSharedStore`` already
  ## established.
  ##
  ## ``capture_enabled`` is the daemon's own answer (``captureEnabled`` on
  ## its stats response). When no daemon answered, or the query failed
  ## before that answer arrived, nothing can be recording on this client's
  ## behalf, so it is false.
  case view.state
  of sssComplete, sssIncomplete:
    # INCOMPLETE IS READY. The figures exist and are labelled thinned by
    # ``window.state``; the store itself is there to read.
    StoreStatusReport(captureEnabled: true, status: ssReady)
  of sssEmpty:
    StoreStatusReport(captureEnabled: true, status: ssEmpty,
      reason: view.reason,
      remedy: "repro build " & quoteShell(projectRoot) &
        " (actions it launches are recorded by runquotad at " &
        view.endpoint & ")")
  of sssCaptureDisabled:
    capturelessDaemonReport(view)
  of sssQueryFailed:
    StoreStatusReport(captureEnabled: false, status: ssDaemonUnreachable,
      reason: view.reason,
      remedy: "runquota stats capture (checks the daemon at " &
        view.endpoint & "; restart it with " &
        startDaemonRemedy(view.endpoint) & " if it does not answer)")
  of sssDaemonUnreachable:
    var report = unreachableReport()
    if report.status == ssDaemonUnreachable:
      # The view's sentence carries the connection error; keep it.
      report.reason = view.reason
    report

proc pressureStoreStatus*(answer: JsonNode;
                          captureEnabled: bool): StoreStatusReport =
  ## The status of a daemon's build-wait pressure figures, for a daemon
  ## that ANSWERED. ``captureEnabled`` is whether builds started from this
  ## environment report pressure (the ``pressure-reports`` measurement in
  ## ``RUNQUOTA_MEASUREMENT``, off by default): the daemon holds only what
  ## clients reported, and the switch lives with the clients.
  ##
  ## ``ready`` when the host has received at least one report, whatever the
  ## local switch says (some client did report); otherwise ``empty`` when
  ## the switch is on (nothing has reported yet) and ``unprovisioned`` when
  ## it is off (nothing from here ever will).
  result.captureEnabled = captureEnabled
  let reports = answer{"host"}{"reports"}.getBiggestInt(0)
  if reports > 0:
    result.status = ssReady
  elif captureEnabled:
    result.status = ssEmpty
    result.reason = "runquotad has received no build-wait pressure " &
      "reports yet"
    result.remedy = "run a build with RUNQUOTA_MEASUREMENT=" &
      "pressure-reports=on (e.g. RUNQUOTA_MEASUREMENT=pressure-reports=on " &
      "repro build)"
  else:
    result.status = ssUnprovisioned
    result.reason = "build-wait pressure reports are off " &
      "(RUNQUOTA_MEASUREMENT has no pressure-reports=on) and runquotad " &
      "has received none"
    result.remedy = "export RUNQUOTA_MEASUREMENT=pressure-reports=on, " &
      "then run repro build"

proc addStoreStatus*(node: JsonNode; report: StoreStatusReport) =
  ## Adds the three top-level keys to a JSON object. ``remedy`` is
  ## omitted, not empty, when the store is ready.
  node["capture_enabled"] = %report.captureEnabled
  node["store_status"] = %($report.status)
  if report.status != ssReady:
    node["remedy"] = %report.remedy
  elif node.hasKey("remedy"):
    node.delete("remedy")

proc storeStatusNotice*(command: string; report: StoreStatusReport): string =
  ## The one stderr line a text-mode run prints when the store is not
  ## ready; empty when it is. Always a single line: embedded line breaks in
  ## the daemon's diagnostics are folded.
  if report.status == ssReady:
    return ""
  var line = command & ": store_status=" & $report.status &
    " capture_enabled=" & $report.captureEnabled
  if report.reason.len > 0:
    line.add(" -- " & report.reason)
  line.add("; remedy: " & report.remedy)
  line.replace("\r\n", " ").replace('\n', ' ').replace('\r', ' ')

proc writeStoreStatusNotice*(command: string; report: StoreStatusReport) =
  let line = storeStatusNotice(command, report)
  if line.len > 0:
    stderr.writeLine(line)
