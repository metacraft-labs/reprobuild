## A ``runquotad`` that answers with capture off makes ``repro stats``
## report ``store_status: unprovisioned``, and the ``remedy`` beside it has
## to fit the reason the daemon gives for capture being off.
##
## "Started without ``--measurement capture=on``" is only one reason. The
## daemon names the others in the ``store_status`` of its ``observations``
## inspection subject: ``verifying`` (a daemon started WITH capture on has
## bound its endpoint and its store's integrity check has not returned yet,
## which RunQuota's ``docs/database.md`` documents as the start-up order),
## and the degraded verdicts (``degraded-corrupt``, ``degraded-unwritable``,
## ``degraded-no-sqlite-tool``, ``refused-newer-schema``). Telling the
## reader of any of those to restart with capture on sends them to a fix
## that changes nothing.
##
## WHY THIS IS A UNIT TEST OVER CONSTRUCTED VIEWS, NOT A MOCK. The function
## under test, ``statsStoreStatus``, is a pure mapping from a
## ``SharedStoreView`` value to a report; nothing is stubbed out. The
## integration test ``t_stats_and_pressure_report_store_state`` drives the
## real daemon through ``disabled`` and ``open``. The other verdicts need a
## corrupt, unwritable, newer-schema or lock-held store file, and a
## ``verifying`` window lasts only while the check runs, so the views are
## built here with the fields ``readSharedStore`` fills from the daemon's
## answer.

import std/[strutils, unittest]

import repro_runquota/stats_query
import repro_runquota/store_status

proc captureOffView(daemonStoreStatus: string): SharedStoreView =
  SharedStoreView(state: sssCaptureDisabled,
    reason: "runquotad is running with capture disabled",
    endpoint: "/run/user/1000/runquota/runquotad.sock",
    storePath: "/var/lib/runquota/observations.sqlite3",
    daemonStoreStatus: daemonStoreStatus)

const RestartWithCapture = "restart runquotad with --measurement capture=on"

suite "repro stats names why the daemon's capture is off":
  test "every capture-off verdict is unprovisioned, with capture off":
    for verdict in ["", "disabled", "verifying", "degraded-corrupt",
                    "degraded-unwritable", "degraded-no-sqlite-tool",
                    "refused-newer-schema"]:
      checkpoint("daemon store_status: " & verdict)
      let report = statsStoreStatus(captureOffView(verdict), "/p")
      check report.status == ssUnprovisioned
      check not report.captureEnabled
      check report.remedy.len > 0
      check report.reason.len > 0

  test "a daemon started without capture is told to restart with it":
    for verdict in ["", "disabled"]:
      checkpoint("daemon store_status: " & verdict)
      let report = statsStoreStatus(captureOffView(verdict), "/p")
      check report.remedy.startsWith(RestartWithCapture)
      check report.remedy.contains("--socket " &
        "/run/user/1000/runquota/runquotad.sock")

  test "a daemon still verifying its store is not told to restart":
    let report = statsStoreStatus(captureOffView("verifying"), "/p")
    check "restart" notin report.remedy
    check report.remedy.startsWith("wait for runquotad")
    check report.reason.contains("verifying")
    check report.reason.contains("/var/lib/runquota/observations.sqlite3")

  test "each degraded verdict gets its own remedy, none of them capture=on":
    var remedies: seq[string]
    for (verdict, cue) in [("degraded-corrupt", "move "),
                           ("degraded-unwritable", "writable"),
                           ("degraded-no-sqlite-tool", "sqlite3"),
                           ("refused-newer-schema", "upgrade runquotad")]:
      checkpoint("daemon store_status: " & verdict)
      let report = statsStoreStatus(captureOffView(verdict), "/p")
      check not report.remedy.startsWith(RestartWithCapture)
      check report.remedy.contains(cue)
      check report.remedy notin remedies
      remedies.add(report.remedy)

  test "the stderr notice stays one line and carries the remedy":
    let report = statsStoreStatus(captureOffView("verifying"), "/p")
    let line = storeStatusNotice("repro stats", report)
    check line.startsWith(
      "repro stats: store_status=unprovisioned capture_enabled=false -- ")
    check line.endsWith("; remedy: " & report.remedy)
    check '\n' notin line
