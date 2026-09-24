## A provider whose instances are files, for the two gates about what
## happens to a leased instance when nothing goes to plan.
##
## ## What this is, and what it is not
##
## It is **not a mock of a cloud**. Nothing here fabricates a provider
## response that the code under test then believes: there is no
## attestation, no measurement, no identity and no verdict anywhere in
## it. What it is is a second implementation of `CloudLeaseEffector` —
## the same seam a real `aws` or `gcloud` process is reached through —
## whose side effects are *observable filesystem state*. The measurement
## every case here makes is on that state: a file exists, or it does
## not.
##
## That matters because the claim under test is a claim about
## **lifetime**, not about content. "The instance this process created
## does not outlive it" is a statement of the form "after event X,
## object Y is gone", and a file is a perfectly faithful Y for it. A
## real instance differs from a file in what it costs and in how it is
## reached — and the reaching is exactly what the effector seam
## abstracts, which is why the seam is where the substitution goes.
##
## The justification this repository's conventions ask for, stated
## plainly: the alternative to substituting here is launching a
## confidential virtual machine on a public cloud from a test suite, and
## then killing the test to see whether the machine survives. That is
## an experiment to run once, deliberately, with credentials and a
## budget and an operator watching. Running it on every commit is not a
## stronger test, it is an unbounded bill attached to a `-9`.
##
## ## What it models, and what it deliberately does not
##
## Three provider operations, because three are what the reaper uses:
## create an instance with tags, list instances by tag, destroy an
## instance by identifier. The tags are parsed out of the *real*
## rendered invocation rather than passed in beside it, so a launch
## plan that carried no lease tag produces an instance the sweep cannot
## find — which is the failure this file is here to be able to see.
##
## It does not model eventual consistency, throttling, partial failure
## inside one call, or an instance that refuses to die. The first three
## would make the gate flaky without making it stronger; the fourth has
## a case of its own, driven by an explicit failure mode rather than by
## a simulation.

import std/[algorithm, os, strutils]

import repro_attest
import repro_attest/cloud_lease

type
  FakeProvider* = object
    root*: string

  FakeFailureMode* = enum
    ffmNone = "none"
    ffmDestroyFails = "destroy-fails"
    ffmListFails = "list-fails"

proc instancesDir*(p: FakeProvider): string = p.root / "instances"
proc invocationLog*(p: FakeProvider): string = p.root / "invocations.log"
proc failureModePath*(p: FakeProvider): string = p.root / "failure-mode"

proc openFakeProvider*(root: string): FakeProvider =
  createDir(root)
  createDir(root / "instances")
  FakeProvider(root: root)

proc setFailureMode*(p: FakeProvider; mode: FakeFailureMode) =
  writeFile(failureModePath(p), $mode)

proc failureMode*(p: FakeProvider): FakeFailureMode =
  if not fileExists(failureModePath(p)): return ffmNone
  let text = readFile(failureModePath(p)).strip()
  for m in FakeFailureMode:
    if $m == text: return m
  ffmNone

proc liveInstances*(p: FakeProvider): seq[string] =
  ## Every instance that exists right now, by identifier. This is the
  ## measurement: every assertion in both gates is about whether a
  ## particular identifier is in this list.
  if not dirExists(instancesDir(p)): return
  for _, path in walkDir(instancesDir(p)):
    result.add path.extractFilename
  result.sort()

proc invocationCount*(p: FakeProvider): int =
  if not fileExists(invocationLog(p)): return 0
  for line in readFile(invocationLog(p)).splitLines:
    if line.strip().len > 0: inc result

proc invocationsMentioning*(p: FakeProvider; needle: string): int =
  if not fileExists(invocationLog(p)): return 0
  for line in readFile(invocationLog(p)).splitLines:
    if line.strip().len > 0 and needle in line: inc result

proc tagsOf*(p: FakeProvider; id: string): seq[(string, string)] =
  ## The tags an instance was created with, read back off the instance
  ## rather than remembered — so a gate asserting a tag is asserting
  ## something the rendered invocation actually carried.
  let path = instancesDir(p) / id
  if not fileExists(path): return
  for line in readFile(path).splitLines:
    let at = line.find('=')
    if at <= 0: continue
    result.add (line[0 ..< at], line[at + 1 .. ^1])

proc tagValueOf*(p: FakeProvider; id, key: string): string =
  for pair in tagsOf(p, id):
    if pair[0] == key: return pair[1]
  ""

proc parseAwsTagSpecification(value: string): seq[(string, string)] =
  ## `ResourceType=instance,Tags=[{Key=a,Value=b},{Key=c,Value=d}]`,
  ## read the way a provider would have to read it.
  var i = 0
  while true:
    let open = value.find("{Key=", i)
    if open < 0: break
    let close = value.find('}', open)
    if close < 0: break
    let body = value[open + 1 ..< close]
    var key = ""
    var val = ""
    for part in body.split(','):
      if part.startsWith("Key="): key = part[4 .. ^1]
      elif part.startsWith("Value="): val = part[6 .. ^1]
    if key.len > 0: result.add (key, val)
    i = close + 1

proc parseGcpLabels(value: string): seq[(string, string)] =
  for part in value.split(','):
    let at = part.find('=')
    if at > 0: result.add (part[0 ..< at], part[at + 1 .. ^1])

proc argAfter(argv: seq[string]; flag: string): string =
  for i in 0 ..< argv.len - 1:
    if argv[i] == flag: return argv[i + 1]
  ""

proc argsAfter(argv: seq[string]; flag: string): seq[string] =
  ## Every value following a flag up to the next flag, which is how the
  ## one provider that takes repeated filters spells them.
  var collecting = false
  for arg in argv:
    if arg == flag:
      collecting = true
      continue
    if collecting:
      if arg.startsWith("--"): break
      result.add arg

proc fakeProviderEffector*(p: FakeProvider): CloudLeaseEffector =
  ## The seam, implemented against files.
  ##
  ## Every invocation is appended to a log BEFORE it is acted on, so a
  ## gate can count what was attempted even when the attempt failed —
  ## the distinction between "the destroy was never tried" and "the
  ## destroy was tried and refused" is one both gates make.
  let root = p.root
  result = proc (effect: CloudEffect): CloudEffectResult =
    let provider = FakeProvider(root: root)
    let f = open(invocationLog(provider), fmAppend)
    f.write(effect.argv.join(" ") & "\n")
    f.close()
    let argv = effect.argv
    if argv.len < 4: return CloudEffectResult(status: 64)

    # create
    if argv[0 .. 2] == @["aws", "ec2", "run-instances"] or
       argv[0 .. 3] == @["gcloud", "compute", "instances", "create"]:
      var tags: seq[(string, string)] = @[]
      if argv[0] == "aws":
        tags = parseAwsTagSpecification(argAfter(argv, "--tag-specifications"))
      else:
        tags = parseGcpLabels(argAfter(argv, "--labels"))
      let id = "i-" & $getCurrentProcessId() & "-" &
        $(liveInstances(provider).len + 1)
      var body = ""
      for pair in tags: body.add pair[0] & "=" & pair[1] & "\n"
      writeFile(instancesDir(provider) / id, body)
      return CloudEffectResult(status: 0, output: id & "\n")

    # list
    if argv[0 .. 2] == @["aws", "ec2", "describe-instances"] or
       argv[0 .. 3] == @["gcloud", "compute", "instances", "list"]:
      if failureMode(provider) == ffmListFails:
        return CloudEffectResult(status: 254, output: "")
      var wantedLease = ""
      var wholeRegion = false
      if argv[0] == "aws":
        for filter in argsAfter(argv, "--filters"):
          if filter.startsWith("Name=tag:" & $cltLeaseId & ",Values="):
            wantedLease = filter[len("Name=tag:" & $cltLeaseId & ",Values=") .. ^1]
          elif filter == "Name=tag-key,Values=" & $cltLeaseId:
            wholeRegion = true
      else:
        let filter = argAfter(argv, "--filter")
        if filter == "labels." & $cltLeaseId & ":*":
          wholeRegion = true
        elif filter.startsWith("labels." & $cltLeaseId & "="):
          wantedLease = filter[len("labels." & $cltLeaseId & "=") .. ^1]
      var lines: seq[string] = @[]
      for id in liveInstances(provider):
        let leaseId = tagValueOf(provider, id, $cltLeaseId)
        if leaseId.len == 0: continue
        if wholeRegion:
          lines.add id & "\t" & leaseId & "\t" &
            tagValueOf(provider, id, $cltExpiresAt)
        elif wantedLease.len > 0 and leaseId == wantedLease:
          lines.add id
      if lines.len == 0:
        # The word one of these providers writes for an empty answer,
        # rather than nothing. Reproduced on purpose: a reaper that
        # treated it as an identifier would try to destroy a machine
        # called `None`.
        return CloudEffectResult(status: 0, output: "None\n")
      return CloudEffectResult(status: 0, output: lines.join("\n") & "\n")

    # destroy
    if argv[0 .. 2] == @["aws", "ec2", "terminate-instances"] or
       argv[0 .. 3] == @["gcloud", "compute", "instances", "delete"]:
      if failureMode(provider) == ffmDestroyFails:
        return CloudEffectResult(status: 255, output: "")
      let id = (if argv[0] == "aws": argAfter(argv, "--instance-ids")
                else: argv[4])
      let path = instancesDir(provider) / id
      if not fileExists(path):
        return CloudEffectResult(status: 0, output: "")
      removeFile(path)
      return CloudEffectResult(status: 0, output: "")

    CloudEffectResult(status: 64)
