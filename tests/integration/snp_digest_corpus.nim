## The reference implementation's published test corpus, decoded and
## parsed — shared by the gates that need a vector out of it.
##
## Included rather than imported, for the same reason the constants it
## sits on top of are: the corpus is a fixture, and a fixture that two
## gates disagree about is worse than a fixture only one of them has.
## Everything about where the bytes came from, and about what they do and
## do not establish, is in `snp_digest_vectors` beside them.
##
## The parser is here and not in either gate because a second parser is a
## second opinion about what upstream states, and the whole point of
## parsing rather than transcribing is that there is exactly one reading.
##
## Requires, from the including module: `std/[base64, os, strutils]`.

include ./snp_digest_vectors

proc bytesOfHex(h: string): seq[byte] =
  doAssert h.len mod 2 == 0
  result = newSeq[byte](h.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(h[2 * i .. 2 * i + 1]))

proc hexOfBytes(b: openArray[byte]): string =
  for x in b: result.add toHex(int(x), 2).toLowerAscii

# ---------------------------------------------------------------------
# The parser over the reference implementation's test suite
#
# Python, read as text. It does not need to be a Python parser: it needs
# to find every call to the two entry points, recover the argument list,
# and recover the literal the assertion beside it compares against. What
# it must NOT do is be lenient — a shape it misreads becomes a vector
# that checks the wrong thing, so every token it does not recognise is a
# hard failure rather than a default.
# ---------------------------------------------------------------------

type
  UpstreamVectorKind = enum
    uvkDigest        ## a launch shape with a stated digest
    uvkFirmwareHash  ## the firmware's own contribution, stated
    uvkRefusal       ## a launch shape upstream states an error for
    uvkNoAssertion   ## a call whose test asserts about files, not digests

  UpstreamVector = object
    test: string
    kind: UpstreamVectorKind
    mode: string
    vcpus: int
    vcpuModel: string        ## "" when upstream passes None
    firmware: string         ## the fixture's basename
    hasKernel: bool
    kernel, initrd, cmdline: string
    guestFeatures: uint64
    seedHex: string          ## a precomputed firmware contribution, or ""
    vmm: string
    expected: string         ## a digest in hex, or a refusal's exact text

proc stripComment(line: string): string =
  ## Drop a trailing `#` comment that is not inside a string literal.
  var inSingle = false
  var inDouble = false
  for i, c in line:
    if c == '\'' and not inDouble: inSingle = not inSingle
    elif c == '"' and not inSingle: inDouble = not inDouble
    elif c == '#' and not inSingle and not inDouble: return line[0 ..< i]
  line

proc joinLiterals(text: string): string =
  ## Every quoted run in `text`, concatenated — which is how Python
  ## spells a long literal across lines, and how every expected digest in
  ## the corpus is written.
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '\'' or c == '"':
      var j = i + 1
      while j < text.len and text[j] != c: inc j
      result.add text[i + 1 ..< j]
      i = j + 1
    else:
      inc i

proc hasLiteral(text: string): bool =
  for c in text:
    if c == '\'' or c == '"': return true
  false

proc balancedArgs(text: string; start: int): tuple[args: seq[string]; stop: int] =
  ## The argument list of a call whose opening parenthesis is at
  ## `start`, split on commas at depth zero. Returns the index just past
  ## the closing parenthesis.
  var depth = 0
  var i = start
  var current = ""
  var inSingle = false
  var inDouble = false
  while i < text.len:
    let c = text[i]
    if inSingle:
      current.add c
      if c == '\'': inSingle = false
      inc i
      continue
    if inDouble:
      current.add c
      if c == '"': inDouble = false
      inc i
      continue
    case c
    of '\'':
      inSingle = true
      current.add c
    of '"':
      inDouble = true
      current.add c
    of '(', '[', '{':
      inc depth
      if depth > 1: current.add c
    of ')', ']', '}':
      dec depth
      if depth == 0:
        if current.strip().len > 0: result.args.add current.strip()
        result.stop = i + 1
        return
      current.add c
    of ',':
      if depth == 1:
        result.args.add current.strip()
        current = ""
      else: current.add c
    else:
      current.add c
    inc i
  doAssert false, "unbalanced call in the corpus at " & $start

proc quotedIn(text: string): string =
  ## The single quoted token inside an expression such as
  ## `vcpu_types.CPU_SIGS["EPYC-v4"]` or `fixtures_dir / "ovmf.bin"`.
  joinLiterals(text)

proc normaliseText(source: string): string =
  ## The corpus with comments and line breaks removed, so a call that
  ## spans lines is one run of text. Indentation is collapsed to single
  ## spaces; nothing inside a literal is touched, because `stripComment`
  ## leaves literals alone and no literal in this corpus contains a
  ## newline.
  var pieces: seq[string] = @[]
  for raw in source.splitLines:
    pieces.add stripComment(raw).strip()
  pieces.join(" ")

type
  ParsedCorpus = object
    vectors: seq[UpstreamVector]
    testNames: seq[string]

proc parseUpstreamCorpus(source: string): ParsedCorpus =
  ## Every test function in the corpus, and the vector each one states.
  ##
  ## Each function is read whole, because a vector is the pairing of a
  ## call with the assertion below it: reading calls and assertions
  ## independently and matching them up by position is how a gate ends up
  ## checking one shape's digest against another shape's.
  var starts: seq[int] = @[]
  var pos = 0
  const Marker = "def test_"
  while true:
    let at = source.find(Marker, pos)
    if at < 0: break
    starts.add at
    pos = at + Marker.len
  doAssert starts.len > 0, "the corpus declares no tests"

  for idx, at in starts:
    let stop = if idx + 1 < starts.len: starts[idx + 1] else: source.len
    let nameEnd = source.find('(', at)
    let name = source[at + 4 ..< nameEnd].strip()
    result.testNames.add name
    let body = normaliseText(source[nameEnd ..< stop])

    # A literal seed assigned before the call, e.g.
    #   ovmf_hash = '086e…'
    var seedHex = ""
    let seedAt = body.find("ovmf_hash = '")
    if seedAt >= 0:
      let lineEnd = body.find('\'', seedAt + 13)
      seedHex = body[seedAt + 13 ..< lineEnd]

    # The assertions of this test, in order.
    var assertions: seq[tuple[subject, value: string]] = @[]
    var apos = 0
    while true:
      let a = body.find("self.assertEqual(", apos)
      if a < 0: break
      let parsed = balancedArgs(body, a + len("self.assertEqual"))
      doAssert parsed.args.len == 2,
        name & ": an assertion with " & $parsed.args.len & " arguments"
      assertions.add (parsed.args[0], joinLiterals(parsed.args[1]))
      apos = parsed.stop

    proc valueFor(subject: string): string =
      for a in assertions:
        if a.subject == subject: return a.value
      ""

    # `calc_snp_ovmf_hash` — the firmware's own contribution.
    let fwAt = body.find("guest.calc_snp_ovmf_hash(")
    if fwAt >= 0:
      let parsed = balancedArgs(body, fwAt + len("guest.calc_snp_ovmf_hash"))
      doAssert parsed.args.len == 1, name & ": a firmware-hash call"
      let stated = valueFor("ovmf_hash")
      doAssert stated.len > 0, name & ": a firmware hash nothing asserts"
      result.vectors.add UpstreamVector(test: name, kind: uvkFirmwareHash,
        firmware: quotedIn(parsed.args[0]).extractFilename, expected: stated)
      seedHex = stated

    let callAt = body.find("guest.calc_launch_digest(")
    if callAt < 0: continue
    let call = balancedArgs(body, callAt + len("guest.calc_launch_digest"))
    var v = UpstreamVector(test: name, vcpus: -1, vmm: "QEMU", seedHex: "")
    var positional = 0
    for arg in call.args:
      var key = ""
      var value = arg
      let eq = arg.find('=')
      # A keyword argument, as distinct from `a == b`; nothing in this
      # corpus contains `==`, and an unrecognised token fails below
      # rather than being taken for one.
      if eq > 0 and not arg.startsWith("\"") and not arg.startsWith("'") and
         (eq + 1 >= arg.len or arg[eq + 1] != '='):
        key = arg[0 ..< eq].strip()
        value = arg[eq + 1 .. ^1].strip()
      case key
      of "snp_ovmf_hash_str":
        v.seedHex = if hasLiteral(value): joinLiterals(value) else: seedHex
        doAssert v.seedHex.len > 0, name & ": a seed with no value"
        continue
      of "vmm_type":
        v.vmm = value.split('.')[^1]
        continue
      of "dump_vmsa":
        continue
      of "":
        discard
      else:
        doAssert false, name & ": unrecognised keyword " & key

      inc positional
      case positional
      of 1: v.mode = value.split('.')[^1]
      of 2: v.vcpus = parseInt(value)
      of 3: v.vcpuModel = quotedIn(value)
      of 4: v.firmware = quotedIn(value).extractFilename
      of 5:
        v.hasKernel = value != "None"
        v.kernel = quotedIn(value)
      of 6: v.initrd = quotedIn(value)
      of 7: v.cmdline = quotedIn(value)
      of 8: v.guestFeatures = uint64(parseHexInt(value))
      of 9:
        doAssert value == "None", name & ": positional seed " & value
      of 10: v.vmm = value.split('.')[^1]
      of 11: discard                      ## dump_vmsa, positionally
      of 12: v.firmware = quotedIn(value).extractFilename & "+supervisor"
      of 13: discard                      ## the variables region's size
      else:
        doAssert false, name & ": " & $positional & " positional arguments"

    doAssert v.mode.len > 0 and v.vcpus > 0, name & ": an incomplete shape"
    let digest = valueFor("ld.hex()")
    let refusal = valueFor("str(c.exception)")
    if digest.len > 0:
      v.kind = uvkDigest
      v.expected = digest
    elif refusal.len > 0:
      v.kind = uvkRefusal
      v.expected = refusal
    else:
      v.kind = uvkNoAssertion
    result.vectors.add v

# ---------------------------------------------------------------------
# The corpus, read once
# ---------------------------------------------------------------------

let corpusBytes = base64.decode(UpstreamMeasureTestsBase64)
let vcpuTypesBytes = base64.decode(UpstreamVcpuTypesBase64)
let amdSevFirmware = bytesOfHex(UpstreamOvmfAmdSevSuffixHex)
let ovmfX64Firmware = bytesOfHex(UpstreamOvmfX64SuffixHex)

const
  AmdSevFixture = "ovmf_AmdSev_suffix.bin"
  OvmfX64Fixture = "ovmf_OvmfX64_suffix.bin"

  ShapesThisBuildDoesNotRun*: array[3, string] = [
    "test_snp_svsm_4_vcpus",
    "test_snp_svsm_2_vcpus",
    "test_snp_svsm_dump_vmsa"]
    ## Named, one by one, rather than filtered by a pattern. These are
    ## the paravisor-mode shapes: this build refuses that launch shape by
    ## name, and their fixtures are 4.6 MB that this repository does not
    ## carry. A shape that stops being computed for any other reason
    ## fails the case below rather than joining a silent exclusion.

  ExpectedTestCount* = 29
  ExpectedDigestVectors* = 23
  ExpectedFirmwareHashVectors* = 2
  ExpectedRefusalVectors* = 3
  ExpectedUnassertedCalls* = 3
    ## Pinned so that a row leaving the corpus is red rather than
    ## invisible. These count what the parser found in the pinned file,
    ## including the paravisor shapes it then declines to run.

let corpus = parseUpstreamCorpus(corpusBytes)

proc firmwareFor(v: UpstreamVector): seq[byte] =
  if v.firmware == AmdSevFixture: return amdSevFirmware
  if v.firmware == OvmfX64Fixture: return ovmfX64Firmware
  doAssert false, v.test & ": no fixture named " & v.firmware

proc parametersFor(v: UpstreamVector): SevLaunchParameters =
  result.mode =
    case v.mode
    of "SEV_SNP": slmSevSnp
    of "SEV_ES": slmSevEs
    of "SEV": slmSev
    else:
      doAssert false, v.test & ": no launch mode named " & v.mode
      slmSev
  result.firmware = firmwareFor(v)
  result.vcpus = v.vcpus
  result.vcpuSignature =
    if v.vcpuModel.len == 0: 0'u32 else: cpuSignatureFor(v.vcpuModel)
  result.guestFeatures = v.guestFeatures
  result.vmm =
    case v.vmm
    of "QEMU": svkQemu
    of "ec2": svkEc2
    of "gce": svkGce
    else:
      doAssert false, v.test & ": no hypervisor named " & v.vmm
      svkQemu
  result.hasKernel = v.hasKernel
  # Upstream's kernel and initial ramdisk are the null device, which
  # reads as no bytes at all. That is ASSERTED rather than assumed: a
  # corpus row naming a real file would otherwise be checked against an
  # empty one, and the digest it states would be compared against a
  # number computed from different inputs.
  if v.hasKernel:
    doAssert v.kernel == "/dev/null",
      v.test & ": a kernel this gate has no bytes for: " & v.kernel
  doAssert v.initrd in ["", "/dev/null"],
    v.test & ": an initial ramdisk this gate has no bytes for: " & v.initrd
  result.kernel = @[]
  result.initrd = @[]
  result.cmdline = v.cmdline

proc isSkipped(name: string): bool =
  for s in ShapesThisBuildDoesNotRun:
    if s == name: return true
  false


proc statedDigestFor*(name: string): string =
  ## The digest the corpus states for one named launch shape.
  ##
  ## A lookup by NAME rather than by position, so a gate quoting a vector
  ## quotes a row of upstream's file and not an index into it — and a
  ## name that is not in the corpus is a failure rather than an empty
  ## string that compares equal to nothing.
  for v in corpus.vectors:
    if v.test == name and v.kind == uvkDigest: return v.expected
  doAssert false, "the corpus states no digest for " & name

proc statedShapeFor*(name: string): UpstreamVector =
  for v in corpus.vectors:
    if v.test == name: return v
  doAssert false, "the corpus has no shape named " & name
