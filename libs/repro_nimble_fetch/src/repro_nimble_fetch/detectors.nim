## The catalog's detectors over its durable source store (threat model
## G27, G30; DET-3, DET-4, DET-5).
##
## **Scrub (G27).** `scrubStore` re-hashes every object a directory store
## holds against the digest it is named by: a source object is extracted
## (under the client's extraction rules, into private staging) and its tree
## digest recomputed; a closure index is decoded and its key compared with
## its name; anything else under the store's prefix is reported as an
## object the store should not hold. A finding names the object's path, the
## digest it is named by and what it hashes to. Presence is not integrity:
## a store whose every object is present can still serve other bytes.
##
## **Positive control (DET-4).** A scrub that finds nothing is
## indistinguishable from one that checks nothing, so every run first
## scrubs a control store holding one object planted under the wrong
## digest (`plantScrubControl`). Only a run that reports exactly that
## object is a working scrub.
##
## **Reporting (DET-5, G28).** `runScrubDetector` sends each finding to the
## evidence sink as a detection, and a heartbeat ONLY when the control
## tripped; a scrub whose control was missed reports `control-missed` and
## no heartbeat, so it goes silent in the sink's liveness report, as a
## stopped scrub does. Silence is therefore distinct from "nothing
## detected" (a heartbeat and no detection). The same rule is followed by
## the other detectors (`NpcDetectors`): each heartbeats only after its own
## control passed.

import std/[algorithm, os, strutils, tables]

import repro_peer_cache/evidence
import repro_peer_cache/evidence_record

import repro_nimble_generator/capture
import repro_nimble_generator/egress
import repro_nimble_generator/origin_git
import repro_nimble_generator/source_tree

import ./archive_extract
import ./closure_index
import ./mirror
import ./store
import ./tree_walk

const
  ScrubDetector* = "nimble-store-scrub"
  RegenerationDetector* = "nimble-independent-regeneration"
  EgressDenialDetector* = "nimble-egress-denial"
  CanaryDetector* = "nimble-canary"
  NpcDetectors* = [ScrubDetector, RegenerationDetector, EgressDenialDetector,
    CanaryDetector]
    ## the catalog's detectors, by the name their sink records carry

type
  ScrubFinding* = object
    path*: string     ## relative to the store
    digest*: string   ## what the object is named by ("" when its name is none)
    observed*: string ## what it hashes to ("" when it could not be read)
    detail*: string

  ScrubReport* = object
    objects*: int     ## objects examined
    findings*: seq[ScrubFinding]

proc relTo(path, base: string): string =
  result = path
  if path.startsWith(base & "/"): result = path[base.len + 1 .. ^1]

proc scrubSource(store: string; path: string; limits: ExtractLimits;
                 scratch: string): ScrubFinding =
  ## One source object: "" detail when it is the tree its name says.
  let rel = path.relTo(store)
  let name = extractFilename(path)
  let parent = extractFilename(parentDir(path))
  if not name.endsWith(".tar") or not isTreeHex(name[0 ..< ^4]) or
      parent != name[0 .. 1]:
    return ScrubFinding(path: rel, detail: "not a source object path")
  result = ScrubFinding(path: rel, digest: name[0 ..< ^4])
  let staging = newStaging(scratch)
  try:
    discard extractArchive(readFile(path), staging,
      ExtractOptions(limits: limits))
    result.observed = treeDigestOf(staging)
    if result.observed != result.digest:
      result.detail = "the object hashes to " & result.observed &
        ", not the digest it is stored under"
  except ExtractRefusal as e:
    result.detail = "the object does not extract: " & e.msg
  except CatchableError as e:
    result.detail = "the object cannot be read: " & e.msg
  finally:
    discardStaging(staging)

proc scrubClosure(store, path: string): ScrubFinding =
  let rel = path.relTo(store)
  let name = extractFilename(path)
  if not isTreeHex(name) or extractFilename(parentDir(path)) != "closure":
    return ScrubFinding(path: rel, detail: "not a closure index path")
  result = ScrubFinding(path: rel, digest: name)
  try:
    let ci = decodeClosureIndex(readFile(path))
    result.observed = ci.key
    if ci.key != name:
      result.detail = "the closure index is keyed " & ci.key &
        ", not the key it is stored under"
  except CatchableError as e:
    result.detail = "the closure index does not decode: " & e.msg

proc scrubStore*(m: Mirror; scratch: string;
                 limits = DefaultExtractLimits): ScrubReport =
  ## Every object of the directory store ``m``, re-hashed (see the module
  ## docstring). ``scratch`` holds the private staging directories.
  if m.kind != mkDirectory:
    raise newException(IOError, "a scrub reads a directory store; " &
      m.location & " is scrubbed by its own service")
  createDir(scratch)
  let root = m.location / "nimble"
  if not dirExists(root): return
  var paths: seq[string]
  for p in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile, pcLinkToDir}):
    paths.add p
  paths.sort()
  for p in paths:
    inc result.objects
    var f: ScrubFinding
    if symlinkExists(p):
      f = ScrubFinding(path: p.relTo(m.location),
        detail: "a symbolic link in the store")
    elif p.startsWith(m.location / SourcesDir & "/"):
      f = scrubSource(m.location, p, limits, scratch)
    elif p.startsWith(m.location / ClosureDir & "/"):
      f = scrubClosure(m.location, p)
    else:
      f = ScrubFinding(path: p.relTo(m.location),
        detail: "an object the store does not hold by design")
    if f.detail.len > 0: result.findings.add f

proc plantScrubControl*(dir: string) =
  ## The control store of DET-4: one source object whose bytes are the
  ## canonical archive of a one-file tree, stored under a digest that is
  ## not that tree's (the digest of a different one-file tree).
  proc archiveOf(content: string): (string, string) =
    var tree = FetchedTree(entries: @[TreeEntry(kind: teFile, mode: "100644",
      path: "control.txt", oid: "control.txt")])
    tree.blobs["control.txt"] = content
    let (facts, archive, _) = sourceFacts(tree)
    (facts.treeDigest, archive)
  let (_, planted) = archiveOf("the bytes the control store holds\n")
  let (wrongDigest, _) = archiveOf("the bytes its name promises\n")
  let m = parseMirror(dir)
  m.putObject(sourceObjectPath(wrongDigest), planted)

proc controlTripped*(r: ScrubReport): bool =
  ## Whether a scrub of the control store found its planted object, and
  ## only it.
  r.findings.len == 1 and r.findings[0].digest.len == 64 and
    r.findings[0].observed.len == 64 and
    r.findings[0].observed != r.findings[0].digest

proc runScrubDetector*(m: Mirror; control: string; scratch: string;
                       appender: EvidenceAppender;
                       limits = DefaultExtractLimits): ScrubReport =
  ## One scheduled scrub run: the control store first, then the store. Each
  ## finding is a detection; the heartbeat is sent only when the control
  ## tripped (``appender`` must have registered ``ScrubDetector`` as a
  ## probed detector).
  let c = scrubStore(parseMirror(control), scratch / "control", limits)
  if not controlTripped(c):
    appender.append(newEvidenceRecord(ecDetection, ScrubDetector,
      "control-missed", [("control", "missed: the control store's planted " &
        "object was not reported"), ("count", $c.findings.len)]))
    return
  result = scrubStore(m, scratch / "store", limits)
  for f in result.findings:
    appender.append(newEvidenceRecord(ecDetection, ScrubDetector,
      "scrub-mismatch", [("digest", f.digest), ("observedDigest", f.observed),
        ("path", f.path), ("reason", f.detail)]))
  appender.heartbeat(ScrubDetector, [("control", "tripped"),
    ("count", $result.objects)])

const EgressControlUrl* = "https://169.254.169.254/latest/meta-data/"
  ## the egress-denial reporter's control: the cloud metadata address, which
  ## the origin policy refuses by address class before any connection

proc runEgressDenialReporter*(captureLog: string; offset: var int64;
                              policy: EgressPolicy;
                              appender: EvidenceAppender): int =
  ## One scheduled run of the egress-denial reporter (DET-2): the control
  ## first -- the policy must refuse ``EgressControlUrl`` -- then every
  ## `egress-refusal` record appended to ``captureLog`` since ``offset``
  ## (advanced past what was read) is sent as a detection. Heartbeats only
  ## when the control tripped (``appender`` must have registered
  ## ``EgressDenialDetector`` as a probed detector). Returns the detections
  ## sent.
  var tripped = false
  try:
    discard vetOrigin(policy, EgressControlUrl)
  except EgressError:
    tripped = true
  if not tripped:
    appender.append(newEvidenceRecord(ecDetection, EgressDenialDetector,
      "control-missed", [("control", "missed: the policy let " &
        EgressControlUrl & " through")]))
    return
  if fileExists(captureLog):
    let text = readFile(captureLog)
    if offset < 0 or offset > int64(text.len): offset = 0
    var pos = int(offset)
    while pos < text.len:
      let nl = text.find('\n', pos)
      if nl < 0: break
      let r = parseCaptureLine(text[pos ..< nl])
      pos = nl + 1
      if r.class == ccEgressRefusal:
        appender.append(newEvidenceRecord(ecDetection, EgressDenialDetector,
          "egress-refusal", [("package", r.package), ("refusal", r.observed),
            ("destination", r.source), ("reason", r.detail)]))
        inc result
    offset = int64(pos)
  appender.heartbeat(EgressDenialDetector, [("control", "tripped")])
