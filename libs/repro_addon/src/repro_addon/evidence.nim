## Evidence records the add-on writes for its deploy-agent outcomes (spec
## §10.4): one JSON document per event under ``EvidenceDir``, written
## atomically before anything else is reported, then one journal line.
## Shipping them off-host is the detection track's (DET-6); this module is
## the local record they ship from.
##
## Kinds written today: ``stale-manifest`` (``aoStale``, spec §9.2) and
## ``failed-at-floor`` (a failed switch the signed rollback floor kept in
## place, spec §7.5).

import std/[algorithm, json, os, strutils, times]

import ./generation0
import ./host_exec
import ./ledger

const
  EvidenceDir* = "/var/lib/repro/system/addon/evidence"
    ## Root-only, beside the add-on's other state.
  EvidenceSchema* = "reprobuild.addon.evidence.v1"

proc writeEvidenceRecord*(kind: string; data: JsonNode;
                          dir = EvidenceDir): string =
  ## Write one record and return its path. ``data`` is merged under the
  ## schema, kind and time fields. Raises when the record cannot be
  ## written: an event the add-on promised to record must not pass
  ## silently.
  let t = getTime()
  var doc = %*{"schema": EvidenceSchema, "kind": kind,
               "timeUnix": t.toUnix(),
               "time": t.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")}
  for k, v in data: doc[k] = v
  createDir(dir)
  setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
  result = dir / (t.utc.format("yyyyMMdd'T'HHmmss") & "-" &
                  $t.nanosecond & "-" & kind & ".json")
  writeFileAtomic(result, pretty(doc) & "\n", 0o600)
  # The journal line is best effort; the file above is the record.
  try:
    let exe = resolveHostTool([AptHookLoggerTool, "/bin/logger"])
    if exe.len > 0:
      discard runHostTool([exe, "-t", "repro-addon-agent", "-p",
        "user.warning", "repro-addon evidence " & kind & ": " & $data],
        timeoutSec = 5)
  except CatchableError:
    discard

proc evidenceRecords*(kind: string; dir = EvidenceDir): seq[string] =
  ## The paths of every record of ``kind``, oldest first.
  if not dirExists(dir): return
  for f in walkFiles(dir / ("*-" & kind & ".json")): result.add(f)
  result.sort()
