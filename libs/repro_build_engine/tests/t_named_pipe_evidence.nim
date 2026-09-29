## A named-pipe open is a channel, not a file read.
##
## io-mon's Windows NT arm records an open with its `\??\` prefix stripped, so
## a node / libuv IPC pipe `\??\pipe\uv\<id>-<pid>` reaches the engine as the
## bare `pipe\uv\<id>-<pid>` — indistinguishable from a RELATIVE file under the
## action's cwd, and different in every process. io-mon classifies the same
## open with an `mrIpcConnect` "connect named-pipe" record carrying the very
## same path; the fold uses it to drop the pipe from the action's path set.
## Without that, no two runs of a node build observe the same inputs.

import std/[os, strutils, unittest]

import repro_build_engine
import io_mon/types

proc fileRead(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
    osPid: 909, threadId: 909, path: path, detail: "")

proc pipeConnect(path: string): MonitorRecord =
  ## The shape `io_mon/shim/windows_interpose.emitIpcConnect` writes.
  MonitorRecord(kind: mrIpcConnect, observationKind: moIpcConnect,
    osPid: 909, threadId: 909, path: path,
    detail: "connect named-pipe peer=unknown")

suite "named-pipe opens are not file inputs":

  test "a pipe open is dropped; a real relative file of that shape is not":
    let cwd = getTempDir() / "t-named-pipe-evidence"
    let pipe = "pipe\\uv\\18446744073709551615-4242"
    let lookalike = "pipe\\x.c"   # an ordinary relative file named like one
    var evidence: PathSetEvidence
    var seen: EvidenceSeenSets
    discard foldMonitorRecordsEvidence(@[
      fileRead(pipe), pipeConnect(pipe),
      fileRead(lookalike),
      fileRead(cwd / "src" / "main.js")], cwd, evidence, seen)
    var sawPipe, sawLookalike, sawSource = false
    for path in evidence.monitorReads:
      let p = path.replace('\\', '/')
      if p.endsWith("pipe/uv/18446744073709551615-4242"): sawPipe = true
      if p.endsWith("pipe/x.c"): sawLookalike = true
      if p.endsWith("src/main.js"): sawSource = true
    check not sawPipe
    check sawLookalike
    check sawSource
