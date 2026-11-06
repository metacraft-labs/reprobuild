## The credential self-test's forbidden-verb probes never share the
## appender's connection (reprobuild-pm issue
## ``2026-11-06-evidence-sink-raw-verb-test-client-segfaults-in-tls-recv``;
## A11 code review round 2).
##
## A ``drain`` that returns at its deadline leaves a flush in flight on the
## appender's connection. A probe that used that connection read it again
## after its own send, by which time the flush's error path (the sink
## refuses an unenrolled credential and closes) had set it to nil: SIGSEGV
## in ``tls.recv``. With an enrolled credential the two coroutines read one
## TLS stream, and a probe could take the flush's acknowledgement for an
## answer to a forbidden verb. The probe now opens a connection of its own.
##
## Each case repeats the round-2 reviewer's reproducer 150 times (an
## appender, one record, a drain whose deadline lands anywhere in a flush,
## then the four probes) in a CHILD process, so a crash is a failed case,
## not a dead test binary: unenrolled (the crash), enrolled (no probe reads
## as answered), and through ``runCredentialCheck`` itself.
##
## Falsifying build: ``probe-shares-connection`` (the old shared-connection
## probe): the unenrolled case goes red (the child dies with SIGSEGV within
## the first run, measured by the reviewer at ``6e3e63d7a7``).
##
## Mocks: none. The sink is the real in-process sink fixture over real TLS.

import std/[asyncdispatch, os, osproc, strtabs, strutils, unittest]

import repro_peer_cache/evidence
import repro_peer_cache/evidence_record

import repro_addon/evidence_ship

import ./addon_evidence_fixture

const Iterations = 150

proc childRun(mode: string): int =
  ## The reproducer; 0 when no probe crashed or read as answered.
  let root = getTempDir() / ("a11-probe-conn-" & mode & "-" &
                             $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  defer: removeDir(root)
  let sink = startSink(root)
  defer: sink.server.stop()
  let h = newHost(root, "race", sink)
  if mode != "unenrolled": sink.enrol(h)
  var answered = 0
  for i in 0 ..< Iterations:
    if mode == "credential-check":
      let c = runCredentialCheck(h.site, h.conf, "race")
      for (op, got) in c.answered:
        if got: inc answered
      continue
    let a = openAppender(h.site, h.conf)
    a.append(newEvidenceRecord(ecAudit, "addon-evidence-ship",
      "credential-probe", [("host", "race")], nowMs = 1))
    discard a.drain(1 + (i * 7) mod 60)     # the deadline lands anywhere
    for op in ForbiddenOperation:
      let got = try: waitFor a.probeForbiddenOperation(op)
                except CatchableError: false
      if got:
        inc answered
        echo "iteration ", i, ": ", op, " read as ANSWERED"
    a.close()
  if answered == 0: 0 else: 1

proc inChild(mode: string): tuple[code: int; output: string] =
  let (o, c) = execCmdEx(quoteShell(getAppFilename()),
    env = newStringTable({"A11_PROBE_CONN_CHILD": mode,
                          "TMPDIR": getTempDir()}))
  (c, o)

if getEnv("A11_PROBE_CONN_CHILD").len > 0:
  quit(childRun(getEnv("A11_PROBE_CONN_CHILD")))

suite "a forbidden-verb probe owns its connection":
  test "unenrolled: probes after a timed-out drain never crash":
    let r = inChild("unenrolled")
    checkpoint r.output[max(0, r.output.len - 2000) .. ^1]
    check r.code == 0

  test "enrolled: no probe reads the flush's acknowledgement as an answer":
    let r = inChild("enrolled")
    checkpoint r.output[max(0, r.output.len - 2000) .. ^1]
    check r.code == 0

  test "the credential check itself, repeated, reports every verb refused":
    let r = inChild("credential-check")
    checkpoint r.output[max(0, r.output.len - 2000) .. ^1]
    check r.code == 0
