## A quote taken from a real TPM, and the reason a recording of one
## cannot stand in for it.
##
## ## The claim
##
## This machine can produce measured-boot evidence by *asking a TPM*,
## through the same source seam and the same driver a deployment uses,
## and the agent's own command line can be configured to do it. Every
## byte of evidence checked below came out of a TPM 2.0 implementation
## over a socket during this run.
##
## ## How it is known not to be a recording
##
## This is the whole difficulty. The backend already had a source that
## reads a quote, a signature and an event log out of three files, and
## every byte in those files was produced by a real TPM — so "the
## numbers look like a TPM's" distinguishes nothing. What distinguishes
## a live TPM is that it can answer a question **nobody has asked it
## before**, and four properties here depend on that:
##
## 1. **The question.** The 64 bytes bound into the quote are drawn from
##    the system random source in this process, microseconds before the
##    `TPM2_Quote`. The TPM copies them into the structure it signs. A
##    recording carries whatever was asked when it was recorded.
## 2. **The registers.** The values the quote's digest is over are
##    extended into the TPM in this run, also from the system random
##    source, and then read back out of it with `TPM2_PCR_Read`. The
##    composite over the values read back has to equal the digest inside
##    the signed structure.
## 3. **The key, and its signature.** The quote's `qualifiedSigner` has
##    to equal the qualified name the TPM reports for the key this run
##    created — a software TPM manufactures a fresh hierarchy seed into
##    an empty state directory, so that is a different key every run —
##    the key's own name has to be the digest of its own public area,
##    its stored attributes have to include `restricted`, and **the
##    signature has to verify under its public point**. The first three
##    are values a forger could copy after asking the TPM for them; the
##    fourth needs a private key that never leaves the device.
## 4. **The join.** The event log shipped beside the quote has to replay
##    to the registers the TPM signed for — which, because the registers
##    were extended from this run's random values, it can only do if the
##    log describes this run.
##
## And then the distinction is **demonstrated rather than argued**: the
## second case writes the live evidence to three files, hands them to
## the recording-backed source, shows that source answering the question
## it recorded, and shows it refused for the next question while the
## live source answers that one. Same driver, same checks, same bytes on
## disk; one source can move and the other cannot.
##
## ## There is no skip in this file
##
## When a software TPM cannot be started this case FAILS and names the
## remedy. An attestation gate that exits zero having talked to nothing
## is worse than no gate: it converts "this was never measured" into
## "this was measured and was fine", which is the one failure an
## attestation surface must not have. `swtpm` is part of this
## repository's development toolchain; a directory holding it may also
## be named in `REPROOS_SWTPM_BIN`.
##
## ## What this does NOT prove
##
## The signature is checked against the key's **own** public point and
## against no certificate: nothing here says the key is one a
## manufacturer vouched for, which is a chain question and a verifier's
## business. A software TPM is also a TPM *implementation* rather than a
## discrete chip, so this shows the command transactions, the
## structures, the key's restrictions and the joins are right, and says
## nothing about any particular machine's hardware. And the event log's
## CONTENT is composed here rather than written by firmware — see
## Mocking below — so the measurements describe a run of this gate and
## not a boot.
##
## Two more, about how far down the shipped path this reaches. **No
## daemon process is spawned.** The last case drives `parseArgs` →
## `newDriverFor` → `acquireQuote` → `buildBoundReport` in THIS process,
## which is the agent's own option parser, its own options-to-backend
## mapping and its own report builder — but not its binary, its socket
## or its systemd unit. So "the command line reaches a TPM" is exactly
## what is shown, and "the installed daemon serves a TPM-backed report
## over HTTP" is not. And the transport is a Unix socket every time:
## `--tpm-device` also accepts a character device path, and that branch
## of `tpm2_device` is compiled and never run here, because this host
## has no TPM device node to point it at.
##
## ## Mocking
##
## None. A real `swtpm` process, a real socket, real TPM commands, real
## register extends, and a real event log written to a real file. The
## one thing built by hand is the event log's *content* — a platform's
## firmware is what normally writes that, and there is no firmware in a
## bare software TPM — so the log is composed here and then extended
## into the TPM, which is the honest way round: the log describes
## measurements that were really performed on the device.

import std/[options, os, osproc, strutils, sysrand, times, unittest]

import repro_attest
import repro_attest_agent
import repro_attest_agent/cli
# The one public-key operation in this file, and it is deliberately NOT
# from the agent's own libraries: nothing an attested instance ships
# verifies a signature, because the agent runs inside the thing being
# trusted. This is the verifier side's primitive, used here the way a
# verifier would use it.
import repro_attest_verify

const
  SwtpmBinEnv = "REPROOS_SWTPM_BIN"
    ## A directory holding `swtpm`, for a host where it is not on PATH.

  SwtpmStartAttempts = 200
  SwtpmStartIntervalMs = 50

  QuotedRegisters = @[0, 1, 2, 3, 4, 5, 6, 7]
    ## The registers this gate measures into and quotes. The same set
    ## the driver quotes by default, so the driver's own
    ## selection check is exercised rather than configured around.

type
  LiveTpm = ref object
    ## One software TPM, its socket, and the conversation with it.
    dir: string
    dataSocket: string
    ctrlSocket: string
    process: Process
    transport: Tpm2Transport

  Measured = tuple[pcr: int, digest: string]
    ## One entry of the log this gate writes, and one `TPM2_PCR_Extend`.

# ---------------------------------------------------------------------
# Randomness
# ---------------------------------------------------------------------

proc systemRandom(n: int): string =
  ## From the operating system, not from a seeded generator.
  ##
  ## The whole argument of this file is that the values below could not
  ## have been known to whoever recorded a fixture, so where they come
  ## from is load-bearing: a pseudo-random generator seeded from the
  ## clock is reproducible by anyone who knows the clock.
  var buf = newSeq[byte](n)
  doAssert urandom(buf),
    "the system random source would not answer, so nothing in this gate " &
    "can be claimed to be unpredictable"
  result = newString(n)
  for i in 0 ..< n: result[i] = char(buf[i])

# ---------------------------------------------------------------------
# A software TPM
# ---------------------------------------------------------------------

proc swtpmCommand(): string =
  let dir = getEnv(SwtpmBinEnv)
  if dir.len > 0: dir / "swtpm" else: "swtpm"

proc stopLiveTpm(t: LiveTpm) =
  ## Unconditional teardown: the socket, the process and the state
  ## directory, whatever happened above. A software TPM left running
  ## holds a socket in a temporary directory that nothing will ever
  ## clean up.
  if t == nil: return
  if t.transport != nil:
    try: t.transport.transportClose()
    except CatchableError: discard
    t.transport = nil
  if t.process != nil:
    try:
      if t.process.running:
        t.process.terminate()
        for _ in 0 ..< 40:
          if not t.process.running: break
          sleep(50)
        if t.process.running: t.process.kill()
      discard t.process.waitForExit()
    except CatchableError: discard
    try: t.process.close()
    except CatchableError: discard
    t.process = nil
  try: removeDir(t.dir)
  except CatchableError: discard

proc startLiveTpm(): LiveTpm =
  ## Start one `swtpm` over a Unix socket and return once it has
  ## answered a command.
  ##
  ## Readiness is "it answered `TPM2_Startup`", not "its socket file
  ## appeared". The socket is created before the emulator is ready to
  ## converse, so waiting on the path is a race that fails inside the
  ## first real command — and it fails there as a transport error, which
  ## reads like a broken endpoint rather than like a slow start.
  ##
  ## The state directory is empty, which is what makes the key in it
  ## this run's own: `swtpm` manufactures a fresh TPM, with a fresh
  ## hierarchy seed, into an empty directory.
  result = LiveTpm()
  result.dir = getTempDir() / ("repro-live-tpm-" & $getCurrentProcessId() &
                               "-" & $int64(epochTime() * 1000.0))
  removeDir(result.dir)
  createDir(result.dir)
  result.dataSocket = result.dir / "tpm-data.sock"
  result.ctrlSocket = result.dir / "tpm-ctrl.sock"

  let command = swtpmCommand()
  try:
    result.process = startProcess(command, args = @[
        "socket", "--tpm2",
        "--tpmstate", "dir=" & result.dir,
        "--server", "type=unixio,path=" & result.dataSocket,
        "--ctrl", "type=unixio,path=" & result.ctrlSocket,
        # The emulator starts its own TPM, so nothing here has to speak
        # the control channel's protocol to initialise it.
        "--flags", "not-need-init,startup-clear",
        # To a file, because the emulator writes to stderr while it runs
        # and that would land in the middle of this suite's output.
        "--log", "file=" & (result.dir / "swtpm.log")],
      # Held as a direct child rather than daemonised: teardown is then
      # a kill on a handle this process owns, and a daemon would inherit
      # every descriptor this process had open.
      options = {poUsePath, poParentStreams}, workingDir = result.dir)
  except CatchableError as e:
    let dir = result.dir
    removeDir(dir)
    raise newException(IOError,
      "could not start a software TPM (" & command & "): " & e.msg &
      ". It is part of this repository's development toolchain; enter the " &
      "development shell, or name the directory holding it in " &
      SwtpmBinEnv & ".")

  for _ in 0 ..< SwtpmStartAttempts:
    try:
      result.transport = newTpm2Transport("unix:" & result.dataSocket)
      tpmStartupClear(result.transport)
      return
    except CatchableError:
      if result.transport != nil:
        try: result.transport.transportClose()
        except CatchableError: discard
        result.transport = nil
      if not result.process.running: break
      sleep(SwtpmStartIntervalMs)

  var detail = ""
  try: detail = readFile(result.dir / "swtpm.log").strip()
  except CatchableError: discard
  let endpoint = result.dataSocket
  stopLiveTpm(result)
  raise newException(IOError,
    "the software TPM never answered on " & endpoint &
    (if detail.len > 0: "; it said: " & detail
     else: "; it printed nothing, which usually means " & command &
           " is not on this host") &
    ". Nothing was measured, so this is a failure and not a skip.")

# ---------------------------------------------------------------------
# A measurement log, and the extends that make it true
# ---------------------------------------------------------------------

proc specIdEntry(): string =
  ## The crypto-agile header: one SHA-256 bank, which is what every
  ## entry after it is read with.
  var payload = initTpm2Writer("TCG_EfiSpecIdEvent")
  payload.writeBytes(SpecIdSignature)
  payload.writeU32Le(0'u32)                       # platformClass
  payload.writeU8(0'u8)                           # specVersionMinor
  payload.writeU8(2'u8)                           # specVersionMajor
  payload.writeU8(0'u8)                           # specErrata
  payload.writeU8(2'u8)                           # uintnSize: 64-bit
  payload.writeU32Le(1'u32)                       # numberOfAlgorithms
  payload.writeU16Le(uint16(TpmAlgSha256))
  payload.writeU16Le(uint16(digestSize(TpmAlgSha256)))
  payload.writeU8(0'u8)                           # vendorInfoSize

  var w = initTpm2Writer("TCG_PCR_EVENT")
  w.writeU32Le(0'u32)                             # pcrIndex
  w.writeU32Le(uint32(EvNoAction))
  w.writeBytes(repeat('\0', LegacyDigestBytes))
  w.writeU32Le(uint32(payload.bytes.len))
  w.writeBytes(payload.bytes)
  w.bytes

proc measurementEntry(pcr: int; digest, data: string): string =
  var w = initTpm2Writer("TCG_PCR_EVENT2")
  w.writeU32Le(uint32(pcr))
  w.writeU32Le(uint32(EvEfiBootServicesApplication))
  w.writeU32Le(1'u32)                             # one digest, one bank
  w.writeU16Le(uint16(TpmAlgSha256))
  w.writeBytes(digest)
  w.writeU32Le(uint32(data.len))
  w.writeBytes(data)
  w.bytes

proc runMeasurements(): seq[Measured] =
  ## Two measurements per quoted register, every digest from the system
  ## random source.
  ##
  ## Two rather than one so the ORDER of the extends matters: a single
  ## extend per register would leave the composite the same under any
  ## permutation of the log, and the join being checked here is
  ## order-sensitive.
  result = @[]
  for pcr in QuotedRegisters:
    for _ in 0 ..< 2:
      result.add (pcr: pcr, digest: systemRandom(digestSize(TpmAlgSha256)))

proc composeLog(ms: seq[Measured]): string =
  result = specIdEntry()
  for i, m in ms:
    result.add measurementEntry(m.pcr, m.digest,
                                "measured-at-run-time-" & $i)

proc applyMeasurements(t: LiveTpm; ms: seq[Measured]) =
  ## Perform, on the device, the measurements the log describes — in the
  ## log's order, because that is the order a replay folds them in.
  for m in ms:
    tpmPcrExtend(t.transport, m.pcr, TpmAlgSha256, m.digest)

proc expectedRegisters(ms: seq[Measured]): seq[SelectedPcr] =
  ## What the registers should hold after `applyMeasurements`, folded
  ## here from the digests rather than read from the device, so the
  ## comparison against the device has two independent sides.
  var values = newSeq[string](24)
  for i in 0 ..< values.len:
    values[i] = initialPcrValue(i, digestSize(TpmAlgSha256))
  for m in ms:
    values[m.pcr] = extendPcr(TpmAlgSha256, values[m.pcr], m.digest)
  result = @[]
  for pcr in QuotedRegisters:
    result.add selectedPcr(TpmAlgSha256, pcr, values[pcr])

proc widened(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len: result[i] = byte(s[i])

proc p256PointOf(publicArea: string): array[P256PointLen, byte] =
  ## The uncompressed public point inside a `TPMT_PUBLIC`.
  ##
  ## The two coordinates are `TPM2B_ECC_PARAMETER`s and a TPM emits them
  ## UNPADDED, so a coordinate whose top byte happens to be zero arrives
  ## 31 bytes long. Left-padding is therefore not cosmetic: dropping it
  ## shifts a scalar by eight bits and the verification fails once in
  ## every few hundred keys, which is the worst possible frequency.
  var r = initTpm2Reader(publicArea, "TPMT_PUBLIC")
  discard r.readBytes("fixed", AttestationKeyFixedBytes)
  let x = r.readTpm2b("unique.x", MaxEccParamBytes)
  let y = r.readTpm2b("unique.y", MaxEccParamBytes)
  r.finish()
  const Coordinate = 32
  doAssert x.len <= Coordinate and y.len <= Coordinate,
    "a P-256 coordinate is at most " & $Coordinate & " bytes"
  result[0] = 0x04'u8                       # uncompressed
  for i in 0 ..< x.len:
    result[1 + Coordinate - x.len + i] = byte(x[i])
  for i in 0 ..< y.len:
    result[1 + Coordinate + Coordinate - y.len + i] = byte(y[i])

proc execStartOf(unitText: string): string =
  ## The unit's `ExecStart`, so the flags it writes can be fed back
  ## through the parser that will read them at boot.
  for raw in unitText.splitLines():
    let line = raw.strip()
    if line.startsWith("ExecStart="):
      return line["ExecStart=".len .. ^1]
  raise newException(ValueError, "the rendered unit has no ExecStart")

proc driverRefusal(body: proc (): void): string =
  try:
    body()
  except DriverError as e:
    return e.msg
  raise newException(ValueError,
    "expected a DriverError and the call returned normally")

# ---------------------------------------------------------------------

suite "evidence this machine's own TPM produced":

  test "a live quote answers the question this run asked, and nothing else":
    let tpm = startLiveTpm()
    try:
      let measurements = runMeasurements()
      applyMeasurements(tpm, measurements)
      let logPath = tpm.dir / "binary_bios_measurements"
      writeFile(logPath, composeLog(measurements))

      # The source and the driver a deployment builds, over the socket
      # this gate opened. The source is held separately from the driver
      # only so the key it created can be read back; the paired
      # constructor is exercised below.
      let source = newDeviceTpm2Source(tpm.transport, logPath)
      check source.label.startsWith("device:")
      check source.transportEndpoint() == "unix:" & tpm.dataSocket

      # The probe is two TPM commands and a stat, and it must not need
      # a quote to have happened.
      let readiness = source.sourceProbe()
      check readiness.ready
      check tpm.dataSocket in readiness.detail
      check logPath in readiness.detail

      let driver = newTpm2Driver(source)
      check driver.backend == abTpm2
      check driver.tier == atTpm

      # (1) THE QUESTION. Drawn now; the TPM has never seen it.
      let question = systemRandom(ReportDataSize)
      let evidence = acquireQuote(driver, question)
      let ev = parseTpm2Evidence(evidence.evidence)
      let quote = tpm2EvidenceQuote(ev)

      check qualifyingData(quote) == question
      # Stated the other way round as well: the bytes are not a constant
      # and not the zero string, so the equality above is not satisfied
      # by a source that ignored its argument.
      check question != repeat('\0', ReportDataSize)
      check bytesToHex(qualifyingData(quote)) == bytesToHex(question)

      # The codec read exactly the bytes the TPM wrote. A signature
      # covers the bytes that arrived, so this is the property that says
      # the attest in the composite is the TPM's and not this build's
      # opinion of it.
      check serializeAttest(quote.attest) == ev.attestBytes
      check serializeSignature(quote.signature) == ev.signatureBytes

      # (2) THE REGISTERS. Read back out of the device, compared against
      # the fold this file computed, and then digested into the
      # composite the TPM signed.
      let readBack = tpmPcrRead(tpm.transport, TpmAlgSha256,
                                QuotedRegisters)
      let expected = expectedRegisters(measurements)
      check readBack.len == QuotedRegisters.len
      check expected.len == QuotedRegisters.len
      for i in 0 ..< readBack.len:
        check readBack[i].index == expected[i].index
        check readBack[i].bank == TpmAlgSha256
        check readBack[i].value == expected[i].value
        # An unextended register is all zeros, and a composite over one
        # would be the same digest on every machine in the world.
        check readBack[i].value != repeat('\0', digestSize(TpmAlgSha256))
      check pcrCompositeMatches(quote, readBack)
      check pcrComposite(compositeAlg(quote), quote.attest.quote.pcrSelect,
                         readBack) == quote.attest.quote.pcrDigest

      # (3) THE KEY. The TPM's own statement about what signed this.
      let key = source.attestationKey()
      check key.handle != 0'u32
      let reread = tpmReadPublic(tpm.transport, key.handle)
      check reread.publicArea == key.publicArea
      check reread.qualifiedName == key.qualifiedName
      check quote.attest.qualifiedSigner == reread.qualifiedName
      check quote.attest.qualifiedSigner != reread.name
      # A key's name is the digest of its own public area under its own
      # name algorithm, so a holder of the public half can check it.
      var expectedName = initTpm2Writer("TPM2B_NAME")
      expectedName.writeAlg(TpmAlgSha256)
      expectedName.writeBytes(tpmDigest(TpmAlgSha256, key.publicArea))
      check key.name == expectedName.bytes

      # And the attributes the TPM stored, read out of the public area
      # it reported and compared against bits SPELLED HERE rather than
      # against the constant the template was built from — comparing a
      # value against the thing that produced it would pass whatever
      # either of them said.
      #
      # `restricted` is the one that matters. A restricted signing key
      # will not sign a digest beginning with `TPM_GENERATED_VALUE`, so
      # it cannot be handed a hand-written attestation structure; an
      # unrestricted key produces a quote that looks identical and
      # vouches for nothing.
      var publicReader = initTpm2Reader(key.publicArea, "TPMT_PUBLIC")
      let keyType = publicReader.readAlg("type")
      let keyNameAlg = publicReader.readAlg("nameAlg")
      let attributes = publicReader.readU32("objectAttributes")
      check keyType == TpmAlgId(0x0023'u16)            # TPM_ALG_ECC
      check keyNameAlg == TpmAlgSha256
      for (bit, _) in [(0x00000002'u32, "fixedTPM"),
                       (0x00000010'u32, "fixedParent"),
                       (0x00000020'u32, "sensitiveDataOrigin"),
                       (0x00010000'u32, "restricted"),
                       (0x00040000'u32, "sign")]:
        check (attributes and bit) == bit
      # And not a decryption key, which would be a different object
      # wearing the same name.
      check (attributes and 0x00020000'u32) == 0'u32

      # (3b) THE SIGNATURE, under that key.
      #
      # Without this the three properties above are satisfiable by
      # something that talks to the TPM only to LEARN the answers and
      # then writes its own attestation structure: the qualifying data,
      # the register digest and the qualified signer are all values a
      # forger could copy. The one thing it cannot copy is a signature
      # under a private key that never leaves the device. So the
      # signature is checked here, over the bytes that ARRIVED — a
      # re-serialisation would make a codec bug into a forgery oracle —
      # with the public point read out of the public area the TPM
      # reported for the key it created in this run.
      check quote.signature.sigAlg == TpmAlgEcdsa
      check quote.signature.hashAlg == TpmAlgSha256
      check quote.signature.kind == tskEcc
      let point = p256PointOf(key.publicArea)
      check verifyEcdsaSha256Raw(widened(ev.attestBytes),
                                 widened(quote.signature.signatureR),
                                 widened(quote.signature.signatureS),
                                 point)
      # The negative half, because a verifier that returns true for
      # everything would satisfy the line above. One flipped bit of the
      # signed bytes, and the same operation must refuse.
      var tampered = ev.attestBytes
      tampered[0] = char(uint8(tampered[0]) xor 0x01'u8)
      check not verifyEcdsaSha256Raw(widened(tampered),
                                     widened(quote.signature.signatureR),
                                     widened(quote.signature.signatureS),
                                     point)

      # (4) THE JOIN. The log this machine shipped replays to the
      # registers its own quote was taken over.
      check logExplainsQuote(ev)
      check ev.eventLogBytes == readFile(logPath)
      let parsedLog = parseEventLog(ev.eventLogBytes)
      check parsedLog.events.len == measurements.len + 1
      check banks(parsedLog) == @[TpmAlgSha256]
      check replayBank(parsedLog, TpmAlgSha256).extendsApplied ==
        measurements.len

      # The paired constructor: the same machine, reached the way a
      # deployment reaches it, with the source and the driver given one
      # selection.
      let paired = newTpm2DeviceDriver(tpm.transport, logPath)
      let second = systemRandom(ReportDataSize)
      check second != question
      let pairedEvidence = acquireQuote(paired, second)
      check qualifyingData(tpm2EvidenceQuote(
        parseTpm2Evidence(pairedEvidence.evidence))) == second
      # A second quote over the same registers is a different document:
      # it answers a different question, so the evidence cannot be the
      # same bytes.
      check pairedEvidence.evidence != evidence.evidence
      check evidence.certificates.isNone

      # THE JOIN IS LIVE, not a property of the files. One more extend
      # moves a register the log does not account for, and the driver
      # refuses its own machine's evidence.
      tpmPcrExtend(tpm.transport, QuotedRegisters[0], TpmAlgSha256,
                   systemRandom(digestSize(TpmAlgSha256)))
      let msg = driverRefusal(proc () =
        discard acquireQuote(driver, systemRandom(ReportDataSize)))
      check "does not reproduce the register digest" in msg
      check "driver tpm2" in msg
    finally:
      stopLiveTpm(tpm)

  test "a recording of that evidence cannot answer the next question":
    ## The distinction, demonstrated. Both sources are real: one reads a
    ## device, the other reads three files holding bytes that device
    ## produced a moment earlier. Only one of them can answer something
    ## new.
    let tpm = startLiveTpm()
    try:
      let measurements = runMeasurements()
      applyMeasurements(tpm, measurements)
      let logPath = tpm.dir / "binary_bios_measurements"
      writeFile(logPath, composeLog(measurements))

      let live = newDeviceTpm2Source(tpm.transport, logPath)
      let liveDriver = newTpm2Driver(live)

      let recorded = systemRandom(ReportDataSize)
      let evidence = acquireQuote(liveDriver, recorded)
      let ev = parseTpm2Evidence(evidence.evidence)

      # The capture: exactly what a provisioning step would leave on a
      # machine's filesystem.
      let attestPath = tpm.dir / "quote.attest"
      let signaturePath = tpm.dir / "quote.sig"
      writeFile(attestPath, ev.attestBytes)
      writeFile(signaturePath, ev.signatureBytes)
      let replaySource = newCapturedTpm2Source(attestPath, signaturePath,
                                               logPath)
      let replayDriver = newTpm2Driver(replaySource)

      # The capture is GOOD. Asked the question it recorded, it produces
      # byte-identical evidence — which is what makes the refusal below
      # a statement about freshness and not about the files.
      let replayed = acquireQuote(replayDriver, recorded)
      check replayed.evidence == evidence.evidence
      check logExplainsQuote(parseTpm2Evidence(replayed.evidence))

      # The next question. The recording cannot move.
      let next = systemRandom(ReportDataSize)
      check next != recorded
      let msg = driverRefusal(proc () =
        discard acquireQuote(replayDriver, next))
      check "the quote binds" in msg
      check bytesToHex(recorded) in msg
      check bytesToHex(next) in msg

      # The live source answers it, over the same driver checks, from
      # the same machine, with the same event log on disk. That is the
      # difference this gate exists to show.
      let answered = acquireQuote(liveDriver, next)
      check qualifyingData(tpm2EvidenceQuote(
        parseTpm2Evidence(answered.evidence))) == next
      check answered.evidence != replayed.evidence
      # And the recording's own bytes are still what they were, so
      # nothing above worked by rewriting the files.
      check readFile(attestPath) == ev.attestBytes
    finally:
      stopLiveTpm(tpm)

suite "the agent's own command line reaches a TPM":

  test "the surface no longer says this build can only mock":
    # The refusal that used to be unconditional. Both tiers are named in
    # the help, and the one that needs a device says which flags
    # configure it.
    let usage = renderUsage()
    check "--tpm-device" in usage
    check "--tpm-event-log" in usage
    check "implements mock, tpm" in usage
    check DefaultTpmDevicePath in usage
    check DefaultTpmEventLogPath in usage

    # The defaults, so a unit that names neither flag still describes a
    # machine rather than nothing.
    let defaults = parseArgs(@["serve"])
    check defaults.tier == "mock"
    check defaults.tpmDevice == DefaultTpmDevicePath
    check defaults.tpmEventLog == DefaultTpmEventLogPath

    # A tier the schema defines and this build does not implement is
    # still a refusal, so the widening did not become a fallback.
    expect ValueError:
      discard newDriverFor(parseArgs(@["serve", "--tier=sev-snp"]))

    # And a TPM flag under another tier is refused rather than ignored,
    # whichever order the two were typed in.
    expect ValueError:
      discard parseArgs(@["serve", "--tpm-device=/dev/tpmrm0"])
    expect ValueError:
      discard parseArgs(@["serve", "--tpm-device=/dev/tpmrm0",
                          "--tier=mock"])
    expect ValueError:
      discard parseArgs(@["serve", "--tier=mock",
                          "--tpm-event-log=/dev/null"])

  test "the daemon configured for a TPM produces a report from one":
    let tpm = startLiveTpm()
    try:
      let measurements = runMeasurements()
      applyMeasurements(tpm, measurements)
      let logPath = tpm.dir / "binary_bios_measurements"
      writeFile(logPath, composeLog(measurements))

      # The setup conversation is handed over before the daemon's own
      # begins. A software TPM's data channel serves ONE client, so two
      # open conversations with it would leave the second waiting behind
      # the first — and `newDriverFor` opens its own, because that is
      # what a daemon told `--tpm-device` does.
      tpm.transport.transportClose()
      tpm.transport = nil

      # The command line, parsed by the parser that will read it at
      # boot, and turned into a backend by the one mapping the daemon
      # uses.
      let opts = parseArgs(@["serve", "--tier=tpm",
                             "--tpm-device=unix:" & tpm.dataSocket,
                             "--tpm-event-log=" & logPath])
      check opts.tier == "tpm"
      check opts.tpmDevice == "unix:" & tpm.dataSocket
      check opts.tpmEventLog == logPath

      # The unit this binary renders carries the flags back, so a
      # machine deployed this way does not lose its endpoint.
      let exec = execStartOf(renderServiceUnit(unitOptionsFor(opts)))
      check ("--tpm-device=unix:" & tpm.dataSocket) in exec
      check ("--tpm-event-log=" & logPath) in exec
      let reparsed = parseArgs(exec.splitWhitespace()[1 .. ^1])
      check reparsed.tier == opts.tier
      check reparsed.tpmDevice == opts.tpmDevice
      check reparsed.tpmEventLog == opts.tpmEventLog

      let driver = newDriverFor(opts)
      try:
        check driver.backend == abTpm2
        check driver.tier == atTpm
        check driver.driverName == Tpm2DriverName

        # A whole report, built the way the endpoint builds one: the
        # challenge is this run's, the 64 bytes are derived from it by
        # the binding discipline, and the driver is handed them.
        let challenge = bytesToHex(systemRandom(32))
        let bindings = ReportBindings(purpose: bpAttest, ephemeralPub: "")
        let reportText = buildBoundReport(driver,
          AgentIdentity(generation: "live-tpm-gate-0001",
                        configFingerprint: "reproos-attested-uefi:live-tpm",
                        verityRootHash: repeat("3a", 32)),
          bindings, challenge, int64(epochTime() * 1000.0))
        let report = parseAttestationReport(reportText, "<this gate>")
        check report.backend == abTpm2
        check report.tier == atTpm
        check report.bindsChallenge(challenge)

        # The envelope's evidence is a tpm2 composite, and the quote
        # inside it binds the 64 bytes the envelope says it does —
        # computed from the challenge by the binding discipline and
        # never taken from the driver.
        let ev = parseTpm2Evidence(authoritativeEvidence(report))
        check qualifyingData(tpm2EvidenceQuote(ev)) ==
          hexToBytes("reportData", reportDataHexFor(bindings, challenge))
        check logExplainsQuote(ev)
      finally:
        driver.driverClose()

      # Closing released the conversation: the driver is not reusable
      # afterwards, and it says so rather than quietly answering from
      # whatever it still held.
      check "is closed" in driverRefusal(proc () =
        discard acquireQuote(driver, systemRandom(ReportDataSize)))
    finally:
      stopLiveTpm(tpm)
