## Test support (not a test): the Nimble catalog's detectors reporting to
## the real evidence sink, run as its own process
## (`build/bin/repro-evidence-sink`, `m7_test_pki`), with real host CAs and
## TLS. The catalog's tests read the sink's store the way an investigator
## on the sink host would (`sinkEntries`).

import std/os

import repro_peer_cache

import ../../repro_peer_cache/tests/m7_test_pki

export m7_test_pki, repro_peer_cache

type
  NpcSink* = object
    base*: string
    sink*: SinkProcess
    writer*: TestNode
      ## the detector host
    writers*: seq[TestNode]
      ## the other hosts the sink accepts appends from

proc leafProvider*(n: TestNode): LeafProvider =
  let leaf = mintLeaf(n.identity, lrDaemon)
  result = proc(): LeafCredential {.gcsafe.} = leaf

proc startNpcSink*(name: string; others: seq[string] = @[]): NpcSink =
  ## The sink, accepting appends from the detector host and from one more
  ## host per name in ``others`` (``writers``).
  result.base = m7TestBase(name)
  result.writer = newTestNode(result.base, "detector-host")
  result.sink = prepareEvidenceSink(result.base)
  result.sink.acceptsFrom(result.writer)
  for o in others:
    let n = newTestNode(result.base, o)
    result.sink.acceptsFrom(n)
    result.writers.add n
  result.sink.startEvidenceSink()

proc appenderFor*(s: NpcSink; n: TestNode): EvidenceAppender =
  ## An appender holding ``n``'s own credential.
  newEvidenceAppender(parseSinkEndpoint(s.sink.endpoint), leafProvider(n),
    sinkAnchors(s.sink))

proc appender*(s: NpcSink): EvidenceAppender =
  ## An appender holding the detector host's own credential.
  s.appenderFor(s.writer)

proc stop*(s: var NpcSink) =
  stopEvidenceSink(s.sink)
  removeDir(s.base)

proc heartbeats*(s: NpcSink; detector: string): seq[EvidenceEntry] =
  for e in s.sink.sinkEntries():
    if e.kind == ekRecord and e.record.category == ecHeartbeat and
        e.record.detector == detector:
      result.add e
