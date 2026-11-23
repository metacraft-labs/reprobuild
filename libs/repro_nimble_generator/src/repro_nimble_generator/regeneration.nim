## The scheduled independent regeneration (threat model G9, DET-1).
##
## A host that shares no credential with the publisher repeats the
## generation of each published index from the inputs the index names
## (`verify.verifyIndex`) and classifies what differs:
##
## * **agrees** -- no difference: the published index is the one the inputs
##   give;
## * **explained** -- every difference is in a package whose origin answered
##   differently to the two runs (its observed tags, `HEAD`, state or
##   origin changed between them), reported as that origin change; the
##   events an origin change adds are explained with it. A record present
##   in both runs for the same version and commit is never explained by
##   it: the commit fixes the record's tree, size and requirements, so a
##   field of it that differs is unexplained whatever the origin did (a
##   publisher that forges both a digest and the package's observation is
##   still caught);
## * **unexplained** -- any other difference: a record whose digest, commit
##   or size differs while its origin answered the same, a package or an
##   object present in one run alone, a root that differs with nothing to
##   show for it. This is a published index nobody else derives.
##
## An unexplained result alerts (a detection in the evidence sink) and
## holds the next publish: `holdPublish` writes a hold naming the published
## root, and the generator refuses to publish on top of a held root
## (`GeneratorConfig.publishHold`) until an operator removes the hold.
## Every run that completed heartbeats, whatever it found; one that could
## not repeat the generation does not, so a broken regeneration goes silent.

import std/[os, sets, strutils]

import repro_peer_cache/evidence
import repro_peer_cache/evidence_record

import repro_domain_types/nimble_index
import repro_nimble_index

import ./generator
import ./source_set
import ./verify

const
  RegenerationDetectorName* = "nimble-independent-regeneration"

type
  RegenerationVerdict* = enum
    rvAgrees = "agrees"
    rvExplained = "explained"
    rvUnexplained = "unexplained"

  ExplainedDifference* = object
    difference*: IndexDifference
    change*: string ## the origin change that explains it

  RegenerationCheck* = object
    verdict*: RegenerationVerdict
    publishedRoot*: IndexObjectId
    repeatedRoot*: IndexObjectId
    explained*: seq[ExplainedDifference]
    unexplained*: seq[IndexDifference]

proc isOriginField(field: string): bool =
  field.startsWith("origin ") or field == "observed origin" or
    field == "held versions"

proc isSameCommitRecordField(d: IndexDifference): bool =
  ## A field of one version record (same version, same commit) that
  ## differs between the runs; a record present in one run alone is
  ## reported as "present"/"absent" instead.
  d.field.startsWith("version ") and
    not (d.published in ["present", "absent"] and
         d.repeated in ["present", "absent"])

proc classify*(publishedRoot, repeatedRoot: IndexObjectId;
               differences: seq[IndexDifference]): RegenerationCheck =
  ## The verdict over one comparison's differences (see the module
  ## docstring).
  result = RegenerationCheck(publishedRoot: publishedRoot,
    repeatedRoot: repeatedRoot)
  var changed = initHashSet[string]()
  var changeOf: seq[(string, string)]
  for d in differences:
    if d.package.len > 0 and isOriginField(d.field):
      changed.incl d.package
      changeOf.add (d.package, d.field & ": " & d.published & " -> " &
        d.repeated)
  proc changeFor(p: string): string =
    for (n, c) in changeOf:
      if n == p:
        if result.len > 0: result.add "; "
        result.add c
  for d in differences:
    if d.package.len > 0 and d.package in changed and
        not isSameCommitRecordField(d):
      result.explained.add ExplainedDifference(difference: d,
        change: changeFor(d.package))
    elif d.package.len == 0 and d.field == "events" and changed.len > 0:
      result.explained.add ExplainedDifference(difference: d,
        change: "the events of the changed origins")
    else:
      result.unexplained.add d
  result.verdict =
    if result.unexplained.len > 0: rvUnexplained
    elif result.explained.len > 0: rvExplained
    elif publishedRoot != repeatedRoot: rvUnexplained
    else: rvAgrees

proc runRegeneration*(indexDir: string; sourceSet: SourceSet;
                      previousIndex, stateDir: string;
                      base: GeneratorConfig = GeneratorConfig(shardBits: -1)):
                        RegenerationCheck =
  ## Repeat the generation of ``indexDir`` and classify the differences.
  let v = verifyIndex(indexDir, sourceSet, previousIndex, stateDir, base)
  var diffs = v.differences
  if v.publishedRoot != v.repeatedRoot and diffs.len == 0:
    diffs.add IndexDifference(field: "root", published: $v.publishedRoot,
      repeated: $v.repeatedRoot)
  classify(v.publishedRoot, v.repeatedRoot, diffs)

proc holdText(c: RegenerationCheck): string =
  result = PublishHoldHeader & "\n" & "root " & $c.publishedRoot & "\n"
  for d in c.unexplained:
    result.add "unexplained " & (if d.package.len > 0: d.package else: "-") &
      " " & d.field.replace("\n", " ") & "\n"

proc holdPublish*(path: string; c: RegenerationCheck) =
  ## Hold the next publish on top of ``c``'s published root.
  createDir(parentDir(path))
  writeFile(path, holdText(c))

proc reportRegeneration*(c: RegenerationCheck; appender: EvidenceAppender) =
  ## Send one completed run to the evidence sink: a detection per
  ## unexplained difference, one audit record per explained origin change,
  ## and the run's heartbeat. ``appender`` must have registered
  ## ``RegenerationDetectorName`` as a probed detector.
  for d in c.unexplained:
    appender.append(newEvidenceRecord(ecDetection, RegenerationDetectorName,
      "regeneration-mismatch", [("package", d.package), ("finding", d.field),
        ("digest", d.published), ("observedDigest", d.repeated),
        ("target", $c.publishedRoot)]))
  var seen = initHashSet[string]()
  for e in c.explained:
    if e.change in seen: continue
    seen.incl e.change
    appender.append(newEvidenceRecord(ecAudit, RegenerationDetectorName,
      "origin-changed", [("package", e.difference.package),
        ("reason", e.change), ("target", $c.publishedRoot)]))
  appender.heartbeat(RegenerationDetectorName, [("outcome", $c.verdict)])
