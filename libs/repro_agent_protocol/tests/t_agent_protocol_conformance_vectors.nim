## Agent integration protocol v1 conformance vectors
## (ReproOS-Agent-Harbor-Integration M7: "publish the integration protocol
## and conformance suite independently of Agent Harbor implementation
## internals").
##
## `libs/repro_agent_protocol/conformance/agent-v1.vectors` is a plain-text
## corpus any provider implementation can run without this code: each
## vector names an operation, its input (hex bytes or text), and the exact
## expected output, which is an identity, a canonical form, a grant list
## or a refusal code. This test checks that this implementation reproduces
## every committed vector byte for byte. An alternative provider (and
## Agent Harbor's client) proves wire agreement by passing the same file.
##
## Operations:
## - `plan-id`: input is a CBOR plan; expect its `PlanId` hex or a refusal.
## - `intent-id`: input is a CBOR intent; expect its `IntentId` hex.
## - `grant`: input is grant text; expect its canonical text or a refusal.
## - `rel-path`: input is a path; expect `ok` or `refuse:path-escape`.
## - `required-grants`: input is a CBOR operation, then `|`, then the
##   package of its target workspace; expect the grants it exercises,
##   comma-separated, or a refusal.
## - `audit-digest`: input is a CBOR audit record; expect its digest hex.
## - `frame`: input is payload hex; expect the framed bytes hex.
##
## Regenerate (only when the protocol deliberately changes) with
##   nim c -r -d:writeAgentVectors libs/repro_agent_protocol/tests/t_agent_protocol_conformance_vectors.nim
## and review the diff: a changed vector is a wire-format change.

import std/[os, strutils, unittest]

import cbor
import repro_agent_protocol

const VectorFile = currentSourcePath().parentDir.parentDir / "conformance" /
  "agent-v1.vectors"

proc hexOf(b: openArray[byte]): string =
  const h = "0123456789abcdef"
  for x in b:
    result.add h[int(x shr 4)]
    result.add h[int(x and 0x0f)]

proc unhex(s: string): seq[byte] =
  for i in countup(0, s.len - 2, 2):
    result.add byte(parseHexInt(s[i .. i + 1]))

type Vector = object
  name, op, input, expect: string

proc run(v: Vector): string =
  ## The output of `v.op` on `v.input`, in the vector's expect syntax.
  try:
    case v.op
    of "plan-id": planId(decodePlan(unhex(v.input))).hex
    of "intent-id": intentId(decodeIntent(unhex(v.input))).hex
    of "grant": $parseGrant(v.input)
    of "rel-path":
      if isCanonicalRelPath(v.input): "ok"
      else: "refuse:" & $arPathEscape
    of "required-grants":
      let bar = v.input.find('|')
      let op = decodeOperation(decodeRecord(unhex(v.input[0 ..< bar])))
      var names: seq[string]
      for g in requiredGrants(op, v.input[bar + 1 .. ^1]):
        names.add $g
      names.join(",")
    of "audit-digest":
      recordDigest(decodeAuditRecord(unhex(v.input))).hex
    of "frame": hexOf(frame(unhex(v.input)))
    else: "unknown-op"
  except AgentRefusal as e:
    "refuse:" & $e.reason

# ---------------------------------------------------------------------
# The corpus, as built from this implementation. Kept in code so that a
# regeneration is reviewable as a diff of the committed file.

proc op(kind: OperationKind; target: string;
        args: openArray[(string, string)] = []): Operation =
  result = Operation(kind: kind, target: target)
  for (n, v) in args:
    result.args.add OpArg(name: n, value: v)

proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32:
    result[i] = seed xor byte(i)

proc samplePlan(): Plan =
  Plan(sessionId: "s1-0011223344556677", intentId: d32(7),
       baseGeneration: "gen-1",
       operations: @[
         op(okSourceWrite, "w2-aabbcc",
            {"content": "int main(void){return 0;}\n", "path": "src/main.c"}),
         op(okBuildRun, "w2-aabbcc"),
         op(okGenerationStage, "w2-aabbcc")],
       declaredCapabilities: @[parseGrant("build.run:hello"),
                               parseGrant("source.write:hello"),
                               parseGrant("system.generation:stage")],
       evidence: @[d32(9)])

proc planItemWith(p: Plan; key: string; value: CborItem): CborItem =
  ## The plan's map with `key` replaced (or added), for refusal vectors.
  result = encodePlanItem(p)
  var found = false
  for e in result.entries.mitems:
    if e.key.text == key:
      e.val = value
      found = true
  if not found:
    result.entries.add tp(key, value)

proc corpus(): seq[Vector] =
  let p = samplePlan()
  let canonical = encodePlan(p)
  result.add Vector(name: "canonical plan", op: "plan-id",
                    input: hexOf(canonical))
  var unsortedCaps = p
  unsortedCaps.declaredCapabilities = @[parseGrant("system.generation:stage"),
                                        parseGrant("build.run:hello"),
                                        parseGrant("source.write:hello")]
  result.add Vector(name: "capability order does not change the identity",
                    op: "plan-id", input: hexOf(encodePlan(unsortedCaps)))
  var swapped = p
  swapped.operations = @[p.operations[1], p.operations[0], p.operations[2]]
  result.add Vector(name: "operation order changes the identity",
                    op: "plan-id", input: hexOf(encodePlan(swapped)))
  # Faithful (non-deterministic) encoding of the same map: keys in
  # insertion order instead of bytewise order.
  result.add Vector(name: "non-deterministic key order",
                    op: "plan-id", input: hexOf(encodeItem(encodePlanItem(p))))
  result.add Vector(name: "unknown key", op: "plan-id", input: hexOf(
    encodeDeterministic(p.planItemWith("x-note", cText("hi")))))
  result.add Vector(name: "unsorted capability array", op: "plan-id",
    input: hexOf(encodeDeterministic(p.planItemWith("capabilities", cArray([
      cText("system.generation:stage"), cText("build.run:hello")])))))
  result.add Vector(name: "unknown operation kind", op: "plan-id",
    input: hexOf(encodeDeterministic(p.planItemWith("operations", cArray([
      cMap([tp("kind", cText("system.exec")), tp("target", cText("x")),
            tp("args", cMap([]))])])))))
  result.add Vector(name: "unknown capability kind", op: "plan-id",
    input: hexOf(encodeDeterministic(p.planItemWith("capabilities",
      cArray([cText("system.root")])))))
  result.add Vector(name: "ill-scoped capability", op: "plan-id",
    input: hexOf(encodeDeterministic(p.planItemWith("capabilities",
      cArray([cText("source.write:../etc")])))))
  var many: seq[CborItem]
  for i in 0 .. MaxOperationsPerPlan:
    many.add encodeOperation(op(okBuildRun, "w"))
  result.add Vector(name: "too many operations", op: "plan-id",
    input: hexOf(encodeDeterministic(p.planItemWith("operations",
      cArray(many)))))
  result.add Vector(name: "digest of the wrong width", op: "plan-id",
    input: hexOf(encodeDeterministic(p.planItemWith("intent",
      cBytes([1'u8, 2, 3])))))

  let intent = Intent(sessionId: "s1-0011223344556677",
                      text: "make the tab strip shorter",
                      contextItems: @[parseGrant("context.active-app"),
                                      parseGrant("context.selection")],
                      capturedAt: 1_800_000_000)
  result.add Vector(name: "intent", op: "intent-id",
                    input: hexOf(encodeIntent(intent)))
  var nfd = intent
  nfd.text = "café"
  result.add Vector(name: "intent text is hashed as given (NFD differs)",
                    op: "intent-id", input: hexOf(encodeIntent(nfd)))

  for g in ["context.active-app", "context.package:hello",
            "context.file:/home/u/notes.txt", "context.screenshot:out-1",
            "workspace.create:hello", "source.read:hello",
            "source.write:lib.foo+bar-2_x", "build.run:hello",
            "test.run:hello", "debug.attach:hello", "preview.run:hello",
            "desktop.automate:hello", "network.egress:crates-io",
            "credentials.use:github:main", "system.generation:stage",
            "system.generation:activate", "system.generation:rollback",
            "remix.publish:private", "remix.publish:export",
            "remix.publish:marketplace",
            "system.root", "context.selection:x", "context.active-app:",
            "source.write:", "source.write:../x", "source.write:a/b",
            "source.write:-x", "context.file:relative", "context.file:/a/../b",
            "context.file:/", "system.generation:all", "remix.publish:public",
            "network.egress:a b", "build.run:" & "x".repeat(129)]:
    result.add Vector(name: "grant " & g.escape, op: "grant", input: g)

  for path in ["src/main.c", "a", "a/b/c.txt", ".hidden", "a..b", "..",
               ".", "../x", "a/../b", "/abs", "a//b", "a/", "./a", "a\\b",
               "", "a/.", "x/" & "y".repeat(256)]:
    result.add Vector(name: "path " & path.escape, op: "rel-path", input: path)

  for (o, pkg) in [
      (op(okOwnershipResolve, "active-app"), ""),
      (op(okOwnershipResolve, "firefox"), ""),
      (op(okCheckoutCreate, "firefox"), ""),
      (op(okCheckoutReapply, "firefox", {"release": "00"}), ""),
      (op(okSourceList, "w1", {"path": "."}), "firefox"),
      (op(okSourceDiff, "w1"), "firefox"),
      (op(okSourceWrite, "w1", {"path": "a", "content": "b"}), "firefox"),
      (op(okBuildRun, "w1"), "firefox"),
      (op(okBuildRun, "w1", {"network": "crates-io"}), "firefox"),
      (op(okTestRun, "w1"), "firefox"),
      (op(okPreviewStart, "w1", {"automate": "1", "debug": "1"}), "firefox"),
      (op(okGenerationStage, "w1"), "firefox"),
      (op(okGenerationActivate, "gen-2"), ""),
      (op(okGenerationRollback, "gen-1"), ""),
      (op(okRemixCapture, "w1"), "firefox"),
      (op(okRemixExport, "w1"), "firefox"),
      (op(okRemixSubmit, "w1", {"credential": "registry-main"}), "firefox"),
      (op(okRemixSubmit, "w1"), "firefox"),
      (op(okBuildRun, "w1", {"network": "../etc"}), "firefox")]:
    result.add Vector(name: "required grants of " & $o.kind &
                      (if o.args.len > 0: " with " & $o.args.len & " args"
                       else: "") & " on " & o.target,
                      op: "required-grants",
                      input: hexOf(encodeDeterministic(encodeOperation(o))) &
                        "|" & pkg)

  result.add Vector(name: "audit record", op: "audit-digest",
    input: hexOf(encodeRecord(AuditRecord(seq: 3, prevDigest: d32(1),
      time: 1_800_000_000, sessionId: "s1", provider: "agent-harbor",
      family: "plan", kind: "submit", decision: "refused",
      reason: "capability-not-held"))))
  result.add Vector(name: "frame", op: "frame", input: "a0")
  result.add Vector(name: "empty frame", op: "frame", input: "")
  for v in result.mitems:
    v.expect = run(v)

proc render(vs: seq[Vector]): string =
  result = "# Agent integration protocol v1 conformance vectors. Generated by\n" &
    "# libs/repro_agent_protocol/tests/t_agent_protocol_conformance_vectors.nim;\n" &
    "# see its header for the operations. Each vector: name, op, input, expect.\n"
  for v in vs:
    result.add "\nname: " & v.name & "\nop: " & v.op & "\ninput: " & v.input &
      "\nexpect: " & v.expect & "\n"

proc parse(text: string): seq[Vector] =
  var cur: Vector
  var open = false
  for line in text.splitLines:
    if line.startsWith("#"):
      continue
    if line.len == 0:
      if open:
        result.add cur
        cur = Vector()
        open = false
      continue
    let colon = line.find(": ")
    let (k, v) =
      if colon < 0: (line.strip(chars = {':'}), "")
      else: (line[0 ..< colon], line[colon + 2 .. ^1])
    open = true
    case k
    of "name": cur.name = v
    of "op": cur.op = v
    of "input": cur.input = v
    of "expect": cur.expect = v
    else: doAssert false, "unknown vector field " & k
  if open:
    result.add cur

when defined(writeAgentVectors):
  createDir(VectorFile.parentDir)
  writeFile(VectorFile, render(corpus()))
  echo "wrote ", VectorFile

suite "M7 — agent protocol v1 conformance vectors":
  let committed = parse(readFile(VectorFile))

  test "this implementation reproduces every committed vector":
    check committed.len > 50
    for v in committed:
      checkpoint v.name
      check run(v) == v.expect

  test "the committed corpus is the one this implementation generates":
    check render(corpus()) == readFile(VectorFile)

  test "the corpus covers acceptance and every refusal it claims to":
    var refusals: seq[string]
    for v in committed:
      if v.expect.startsWith("refuse:"):
        refusals.add v.expect
    for r in ["refuse:malformed", "refuse:unsupported-family",
              "refuse:unknown-capability", "refuse:bad-scope",
              "refuse:bounds-exceeded", "refuse:path-escape"]:
      checkpoint r
      check r in refusals
    # Set order does not move the identity; operation order does.
    check committed[0].expect == committed[1].expect
    check committed[0].expect != committed[2].expect
