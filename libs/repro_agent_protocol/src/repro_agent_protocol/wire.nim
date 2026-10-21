## The request/response messages and the frame codec (spec §"Encoding and
## transport").
##
## `handleMessage` decodes one request, calls the typed host entry point,
## and encodes the response. It decides nothing itself: the channel and
## attachment checks live in `host`, so the typed API and the wire API
## cannot disagree about what is allowed.

import std/strutils

import cbor

import ./[types, canonical, host]

proc familiesItem(fs: set[Family]): CborItem =
  var items: seq[CborItem]
  for f in fs:
    items.add cText($f & ".v1")
  cArray(items)

proc parseFamilies(v: CborItem): set[Family] =
  ## `<family>.v1` entries. An unknown family or major is not an error in
  ## `Hello` (the peer may be newer); it is simply not served.
  for e in asArray(v, "families", 64):
    let s = asText(e, "family")
    if not s.endsWith(".v1"):
      continue
    for f in Family:
      if $f & ".v1" == s:
        result.incl f

proc okResponse(h: Host; extra: openArray[CborPair]): seq[byte] =
  var entries = @[tp("outcome", cText("ok")),
                  tp("auditSeq", cUInt(uint64(h.audit.records.len - 1)))]
  for e in extra:
    entries.add e
  encodeDeterministic(cMap(entries))

proc refusedResponse(h: Host; e: ref AgentRefusal): seq[byte] =
  encodeDeterministic(cMap([
    tp("outcome", cText("refused")),
    tp("reason", cText($e.reason)),
    tp("detail", cText(e.msg)),
    tp("auditSeq", cUInt(uint64(max(h.audit.records.len - 1, 0))))]))

proc handleMessage*(h: Host; conn: Connection;
                    request: openArray[byte]): seq[byte] =
  ## Serve one request. Never raises for peer input: every refusal becomes
  ## a `refused` response naming its reason.
  try:
    let req = decodeRecord(request)
    let kind = asText(req.field("kind"), "request kind")
    if kind != "hello" and not conn.helloDone:
      refuse(arMalformed, "the first message must be hello")
    case kind
    of "hello":
      let served = h.hello(conn, asUInt(req.field("protocol"), "protocol"),
                           parseFamilies(req.field("families")))
      h.okResponse([tp("families", familiesItem(served))])
    of "session.attach":
      h.attach(conn, asText(req.field("session"), "session"),
               asText(req.field("secret"), "secret"))
      h.okResponse([])
    of "session.create":
      var grants: seq[Grant]
      for g in asArray(req.field("grants"), "grants", MaxGrantsPerSession):
        grants.add decodeGrant(g)
      let (sid, secret) = h.createSession(conn,
        asText(req.field("provider"), "provider"), grants)
      h.okResponse([tp("session", cText(sid)), tp("secret", cText(secret))])
    of "intent.capture":
      var items: seq[Grant]
      let ctx = req.field("context")
      if not ctx.isNil:
        for g in asArray(ctx, "context", MaxGrantsPerSession):
          items.add decodeGrant(g)
      let intent = h.captureIntent(conn, asText(req.field("session"),
        "session"), asText(req.field("text"), "text"), items)
      h.okResponse([tp("intent", cDigest(intentId(intent)))])
    of "plan.submit":
      let r = h.submitPlan(conn, decodePlanItem(req.field("plan")))
      var idx: seq[CborItem]
      for i in r.approvalRequired:
        idx.add cUInt(uint64(i))
      h.okResponse([tp("plan", cDigest(r.planId)),
                    tp("approvalRequired", cArray(idx))])
    of "plan.show":
      let p = h.showPlan(conn, asText(req.field("plan"), "plan"))
      h.okResponse([tp("plan", encodePlanItem(p))])
    of "plan.approve":
      let a = h.approvePlan(conn, asText(req.field("plan"), "plan"))
      h.okResponse([tp("approval", cText(a))])
    of "plan.reject":
      h.rejectPlan(conn, asText(req.field("plan"), "plan"))
      h.okResponse([])
    of "plan.execute":
      let ap = req.field("approval")
      let rep = h.execute(conn, asText(req.field("plan"), "plan"),
                          if ap.isNil: "" else: asText(ap, "approval"))
      var rs: seq[CborItem]
      for r in rep.results:
        rs.add cMap([tp("status", cText($r.status)),
                     tp("detail", cText(r.detail)),
                     tp("output", cBytes(r.output.toBytes))])
      h.okResponse([tp("results", cArray(rs))])
    of "grant.revoke":
      h.revokeGrant(conn, asText(req.field("session"), "session"),
                    decodeGrant(req.field("grant")))
      h.okResponse([])
    of "session.revoke":
      h.revokeSession(conn, asText(req.field("session"), "session"))
      h.okResponse([])
    else:
      refuse(arUnsupportedFamily, "unknown request kind " & kind.escape)
  except AgentRefusal as e:
    h.refusedResponse(e)

# ---------------------------------------------------------------------
# Framing: a u32 big-endian length, then one CBOR item.

proc frame*(payload: openArray[byte]): seq[byte] =
  if payload.len > MaxFrameBytes:
    refuse(arBoundsExceeded, "frame larger than 16 MiB")
  let n = uint32(payload.len)
  result = @[byte(n shr 24), byte((n shr 16) and 0xff),
             byte((n shr 8) and 0xff), byte(n and 0xff)]
  result.add payload

proc unframe*(buf: openArray[byte]; pos: var int): seq[byte] =
  ## The next complete frame at `pos`, advancing `pos`; empty with `pos`
  ## unchanged when the frame is not complete yet.
  if buf.len - pos < 4:
    return @[]
  let n = (int(buf[pos]) shl 24) or (int(buf[pos + 1]) shl 16) or
          (int(buf[pos + 2]) shl 8) or int(buf[pos + 3])
  if n > MaxFrameBytes:
    refuse(arBoundsExceeded, "frame larger than 16 MiB")
  if buf.len - pos - 4 < n:
    return @[]
  result = @(buf[pos + 4 ..< pos + 4 + n])
  pos += 4 + n
