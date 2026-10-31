## Shared steps of the add-on secrets gates (milestone A7): a producer that
## publishes signed manifests with a sealed section to the guest, the
## deploy-agent tick in the guest, random canaries, and the raw-disk scan.
##
## The producer runs on the test host with the deploy agent's own code
## (``sealSecrets``, ``signManifest``, ``encodeManifest``) and one of the
## deploy-signer key pairs the guest was bootstrapped to trust; the
## manifest reaches the guest as a file and the tick reads it from there
## (a plain-path source), so nothing listens on the network.

import std/[base64, json, os, osproc, sequtils, strutils, sysrand]

import repro_deploy_agent/[manifest, secrets]
import repro_peer_cache/auth as peerAuth

import ./addon_testbed

proc randomBytes*(n: int): string =
  ## ``n`` bytes from the OS's CSPRNG.
  let b = urandom(n)
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc hexLower(s: string): string =
  for c in s: result.add(toHex(ord(c), 2).toLowerAscii())

proc canaryForms*(canary: string): seq[tuple[form, bytes: string]] =
  ## The forms a leaked secret is searched for: the bytes, standard and
  ## URL-safe base64, and lower- and upper-case hex.
  @[("raw", canary), ("base64", encode(canary)),
    ("base64url", encode(canary, safe = true)),
    ("hex", hexLower(canary)), ("HEX", hexLower(canary).toUpperAscii())]

proc pubFromHex*(hex: string): PublicKeyBytes =
  let h = hex.strip()
  doAssert h.len == 2 * result.len, "not a P-256 public key: " & h
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(h[2 * i .. 2 * i + 1]))

proc recipientPubHex*(g: Guest): string =
  g.run("cat /var/lib/repro/agent/recipient.pub").strip()

proc publishManifest*(g: Guest; signer: PeerKeypair; target: string;
                      sequence: uint64; profileText: string;
                      secrets: seq[tuple[path, content: string]];
                      sealToHex: string): string =
  ## Seal ``secrets`` to the recipient key ``sealToHex``, sign the manifest
  ## with ``signer``, and copy it into the guest; returns its guest path.
  var files: seq[SecretFile]
  for s in secrets:
    files.add(SecretFile(path: s.path, mode: 0o400,
                         content: s.content.toSeq.mapIt(byte(it))))
  var m = DeployManifest(target: target, sequence: sequence,
    deploymentId: "a7-" & $sequence, profileText: profileText)
  if files.len > 0:
    m.hasSecrets = true
    m.secrets = sealSecrets(pubFromHex(sealToHex), target, files)
  signManifest(signer, m)
  let enc = encodeManifest(m)
  var bytes = newString(enc.len)
  for i, x in enc: bytes[i] = char(x)
  let local = g.runDir / ("manifest-" & $sequence & ".rdmf")
  writeFile(local, bytes)
  result = "/root/addon/manifests/m" & $sequence & ".rdmf"
  discard g.run("mkdir -p /root/addon/manifests")
  g.copyTo(local, result)

proc tick*(g: Guest; repro, target: string; sources: seq[string]): ExecOut =
  ## One deploy-agent tick in the guest.
  var cmd = repro & " system addon agent-tick --target " & target
  for s in sources: cmd.add(" --source " & s)
  g.exec(cmd, timeoutSec = 1200)

proc outcomeOf*(r: ExecOut): string =
  for line in r.stdout.splitLines:
    if line.startsWith("outcome: "): return line["outcome: ".len .. ^1].strip()

proc c_memmem(h: pointer; hl: csize_t; n: pointer; nl: csize_t): pointer
  {.importc: "memmem", header: "<string.h>".}

proc scanFile*(path: string; needles: seq[tuple[form, bytes: string]]):
    seq[tuple[form: string; hits: int]] =
  ## Count the occurrences of every needle in the file, streaming it in
  ## 64 MiB chunks that overlap by the longest needle (a hit across a chunk
  ## boundary is found once).
  var longest = 0
  for n in needles: longest = max(longest, n.bytes.len)
  var counts = newSeq[int](needles.len)
  var f = open(path, fmRead)
  defer: f.close()
  const Chunk = 64 * 1024 * 1024
  var buf = newString(Chunk + longest)
  var carry = 0
  while true:
    let got = f.readBuffer(addr buf[carry], Chunk)
    let total = carry + got
    if total == 0: break
    for i, n in needles:
      if n.bytes.len == 0: continue    # nothing to look for (counted 0)
      var off = 0
      while off + n.bytes.len <= total:
        let p = c_memmem(addr buf[off], csize_t(total - off),
                         unsafeAddr n.bytes[0], csize_t(n.bytes.len))
        if p == nil: break
        let at = cast[int](p) - cast[int](addr buf[0])
        # A hit wholly inside the carried-over tail was counted last round.
        if at + n.bytes.len > carry or carry == 0: inc counts[i]
        off = at + 1
    if got == 0: break
    carry = min(longest - 1, total)
    if carry > 0:
      moveMem(addr buf[0], addr buf[total - carry], carry)
  for i, n in needles: result.add((n.form, counts[i]))

proc scanDiskImage*(g: Guest; needles: seq[tuple[form, bytes: string]]):
    seq[tuple[form: string; hits: int]] =
  ## The guest must be powered off. Convert its disk (the run's overlay and
  ## the base image under it) to one raw image and scan it; the raw image
  ## is removed afterwards.
  let raw = g.runDir / "scan.raw"
  if execCmd("qemu-img convert -O raw " & quoteShell(g.diskPath) & " " &
             quoteShell(raw)) != 0:
    raise newException(TestBedError, "qemu-img convert failed")
  defer: removeFile(raw)
  scanFile(raw, needles)

proc totalHits*(r: seq[tuple[form: string; hits: int]]): int =
  for x in r: result += x.hits

proc hitsJson*(r: seq[tuple[form: string; hits: int]]): JsonNode =
  result = newJObject()
  for x in r: result[x.form] = %x.hits
