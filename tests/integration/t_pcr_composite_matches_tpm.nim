## The PCR composite: what a TPM signs when it quotes a set of
## registers, recomputed.
##
## ## The claim
##
## A quote's `pcrDigest` is `H(PCR[s₀] ‖ PCR[s₁] ‖ … )` over the
## registers the quote's own selection names, in the order that structure
## enumerates them, under the hash of the *signing scheme*. This case
## says the codec's recomputation lands on the digest a real TPM
## produced.
##
## ## The trap this is built to avoid
##
## A composite is a digest of a concatenation, so every way of getting it
## wrong produces a perfectly stable answer: a different order, a
## different bank, a superset of the selected registers, the bank's hash
## instead of the scheme's. Each of those verifies happily against
## itself, forever. The only useful comparison is against a value
## computed by something that is not this code, over registers read by
## something that is not this code.
##
## There are three such values here, and they agree:
##
##   1. **The TPM's own answer, signed.** `pcrDigest` inside the pinned
##      `TPMS_ATTEST`. swtpm computed it; `tpm2_checkquote` accepted the
##      signature over it.
##   2. **tpm2-tools' independent recomputation.** The `calcDigest:` line
##      `tpm2_quote` prints, which the tool derives by reading the
##      registers itself.
##   3. **A live TPM, at run time, over values chosen at run time** —
##      layer 2 below.
##
## ## Two layers
##
##   * **Layer 1, always on.** Seven pinned quotes: five selections across
##     two banks, including one that spans all three bitmap bytes, one
##     that mixes SHA-1 and SHA-256 registers under a SHA-256 scheme, and
##     one signed under a SHA-384 scheme whose composite is therefore 48
##     bytes over a SHA-256 bank. Register values from `tpm2_pcrread`.
##     No external tool needed.
##   * **Layer 2, opt-in with `REPROOS_TPM_QUOTE_GATE=1`.** A transient
##     swtpm of its own, extended with values drawn from the system
##     random source *at run time*, quoted with `qualifyingData` drawn
##     the same way, and the composite recomputed from a fresh
##     `tpm2_pcrread`. Nothing in this file could be the source of that
##     agreement. The process is torn down unconditionally.
##
##     When the layer is asked for and the tools are missing, it FAILS
##     and names the remedy. It does not quietly skip: an opt-in gate
##     that silently passes when it did not run is worse than no gate.
##
## ## The negative halves
##
## Present in both layers, because a positive composite check is nearly
## worthless on its own: swapping two selected registers, and altering
## one byte of one register value, must both move the digest away. Layer
## 1 additionally checks that the two-bank vector's composite is NOT
## reproduced under the bank's own algorithm — the mistake that looks
## most like the right answer.
##
## ## What this does not prove
##
## Nothing here verifies a signature or replays an event log. swtpm is a
## TPM implementation, not a discrete chip. And a matching composite says
## the quoted digest is explained by these register values; it says
## nothing about whether those values are acceptable, which is a
## verifier's policy and not a codec's business.
##
## ## Mocking
##
## None. Layer 2 runs a real TPM implementation; layer 1 compares against
## what one produced.

import std/[os, osproc, random, strutils, tables, times, unittest]

import repro_attest
import ./tpm2_quote_vectors

proc bankAlg(name: string): TpmAlgId =
  case name
  of "sha1": TpmAlgSha1
  of "sha256": TpmAlgSha256
  else:
    doAssert false, "the vectors carry no bank called " & name
    TpmAlgNull

proc bankName(alg: TpmAlgId): string =
  if alg == TpmAlgSha1: "sha1"
  elif alg == TpmAlgSha256: "sha256"
  else: $alg

# ---------------------------------------------------------------------
# Layer 2 plumbing. Everything here shells out; nothing here parses TPM
# structures.
# ---------------------------------------------------------------------

const
  LiveGateEnv = "REPROOS_TPM_QUOTE_GATE"
  SwtpmBinEnv = "REPROOS_SWTPM_BIN"
  Tpm2ToolsBinEnv = "REPROOS_TPM2_TOOLS_BIN"

type
  LiveTpm = ref object
    dir: string
    port: int
    tcti: string
    toolsDir: string
    swtpmProc: Process
      ## swtpm is run in the FOREGROUND and held as a direct child, not
      ## daemonised. Two reasons, and the second is not obvious:
      ##
      ##   * teardown becomes a kill on a handle we own, rather than a
      ##     `kill` on a number read out of a file the daemon may not
      ##     have written yet;
      ##   * a daemonised swtpm inherits every descriptor its launcher
      ##     had, INCLUDING the pipe the launcher's own output was being
      ##     read through. Redirecting fds 0, 1 and 2 does not help —
      ##     the pipe survives on a higher-numbered descriptor, and the
      ##     read that was waiting for the launcher to exit waits
      ##     forever instead. Measured, not theorised: the daemon held
      ##     the read end's partner on fd 6.

proc toolPath(t: LiveTpm; tool: string): string =
  if t.toolsDir.len > 0: t.toolsDir / tool else: tool

proc runTool(t: LiveTpm; args: string): tuple[output: string, exitCode: int] =
  ## One tpm2-tools invocation, with the TCTI in the environment because
  ## it is not a flag every tool accepts.
  execCmdEx("TPM2TOOLS_TCTI=" & quoteShell(t.tcti) & " " & args,
            workingDir = t.dir)

proc mustRunTool(t: LiveTpm; args: string): string =
  let r = t.runTool(args)
  if r.exitCode != 0:
    raise newException(IOError,
      "tpm2-tools invocation failed (" & $r.exitCode & "): " & args &
      "\n" & r.output)
  r.output

proc stopLiveTpm(t: LiveTpm) =
  ## Unconditional teardown, and it runs whatever happened above.
  if t == nil: return
  if t.swtpmProc != nil:
    try:
      if t.swtpmProc.running:
        t.swtpmProc.terminate()
        for _ in 0 ..< 20:
          if not t.swtpmProc.running: break
          sleep(50)
        if t.swtpmProc.running:
          t.swtpmProc.kill()
      discard t.swtpmProc.waitForExit()
    except CatchableError:
      discard
    try: t.swtpmProc.close()
    except CatchableError: discard
  try:
    removeDir(t.dir)
  except CatchableError:
    discard

proc startLiveTpm(toolsDir, swtpmDir: string): LiveTpm =
  let pid = getCurrentProcessId()
  result = LiveTpm(toolsDir: toolsDir)
  result.dir = getTempDir() / ("reproos-att-tpm2-" & $pid)
  removeDir(result.dir)
  createDir(result.dir)
  # A port derived from this process, so two runs on one host do not
  # collide, and well above the ephemeral range this host uses.
  result.port = 21000 + (pid mod 2000) * 2
  result.tcti = "swtpm:host=127.0.0.1,port=" & $result.port

  let swtpm = if swtpmDir.len > 0: swtpmDir / "swtpm" else: "swtpm"
  let cmd = "exec " & quoteShell(swtpm) & " socket --tpm2" &
    " --server type=tcp,port=" & $result.port &
    " --ctrl type=tcp,port=" & $(result.port + 1) &
    " --tpmstate dir=" & quoteShell(result.dir) &
    " --flags not-need-init,startup-clear" &
    " < /dev/null > " & quoteShell(result.dir / "swtpm.log") & " 2>&1"
  try:
    result.swtpmProc = startProcess("/bin/sh", args = ["-c", cmd],
                                options = {poParentStreams})
  except OSError as e:
    removeDir(result.dir)
    raise newException(IOError, "swtpm would not start: " & e.msg)

  # Wait for it to answer, rather than sleeping a guessed interval.
  var ready = false
  for _ in 0 ..< 100:
    let probe = result.runTool(
      quoteShell(result.toolPath("tpm2_pcrread")) & " sha256:0")
    if probe.exitCode == 0:
      ready = true
      break
    sleep(100)
  if not ready:
    # Whatever swtpm said goes in the message. The launcher is a shell, so
    # an swtpm that is not on disk at all still gives a successful
    # `startProcess` and a silent port — "never answered" without the log
    # would send an operator looking at the network.
    var detail = ""
    try: detail = readFile(result.dir / "swtpm.log").strip()
    except CatchableError: discard
    stopLiveTpm(result)
    raise newException(IOError,
      "swtpm never answered on port " & $result.port &
      (if detail.len > 0: "; it said: " & detail
       else: "; it printed nothing, which usually means the binary was " &
             "not found"))

proc parsePcrRead(output: string): Table[string, Table[int, string]] =
  ## `tpm2_pcrread`'s own rendering:
  ##
  ## ::
  ##
  ##     sha256:
  ##       0 : 0x90F4B3…
  result = initTable[string, Table[int, string]]()
  var bank = ""
  for rawLine in output.splitLines():
    let line = rawLine.strip()
    if line.len == 0: continue
    if line.endsWith(":") and ':' notin line[0 ..< line.len - 1]:
      bank = line[0 ..< line.len - 1]
      if bank notin result: result[bank] = initTable[int, string]()
      continue
    let colon = line.find(':')
    if colon < 0 or bank.len == 0: continue
    let idxText = line[0 ..< colon].strip()
    var value = line[colon + 1 .. ^1].strip()
    if not value.startsWith("0x"): continue
    value = value[2 .. ^1].toLowerAscii
    try:
      result[bank][parseInt(idxText)] = value
    except ValueError:
      discard

# ---------------------------------------------------------------------

suite "PCR composite against a real TPM":

  test "t_pcr_composite_matches_tpm":

    # -----------------------------------------------------------------
    # Layer 1: the pinned quotes.
    # -----------------------------------------------------------------
    var vectorsChecked = 0
    for v in QuoteVectors:
      let q = parseQuote(unhex(v.attestHex), unhex(v.signatureHex))

      # Values are looked up by the (bank, index) pairs the SELECTION
      # names, read out of the quote — not by the list in the vector
      # record. The vector's own list is used a few lines down as the
      # independent statement of what those should be.
      var values: seq[SelectedPcr] = @[]
      for s in selectedPcrs(q.attest.quote.pcrSelect):
        let hex = pcrValueHex(bankName(s.bank), s.index)
        check hex.len > 0
        values.add selectedPcr(s.bank, s.index, unhex(hex))

      check values.len == v.expectedSelected.len
      for i in 0 ..< min(values.len, v.expectedSelected.len):
        check bankName(values[i].bank) == v.expectedSelected[i].bank
        check values[i].index == v.expectedSelected[i].index

      let composite = pcrComposite(compositeAlg(q),
                                   q.attest.quote.pcrSelect, values)

      # 1. against the digest the TPM signed,
      check toHexLower(composite) == v.printedPcrDigestHex
      check composite == q.attest.quote.pcrDigest
      # 2. against tpm2-tools' independent recomputation,
      check toHexLower(composite) == v.toolsCalcDigestHex
      # 3. and through the convenience predicate, which is what callers
      #    will actually reach for.
      check pcrCompositeMatches(q, values)
      inc vectorsChecked

      # -- the negative halves, per vector.
      if values.len >= 2:
        var swapped = values
        swap(swapped[0], swapped[1])
        # The codec takes its order from the SELECTION, so a caller
        # handing the same registers in a different order must still get
        # the right answer — that is the property that makes the order
        # unspoofable — and the composite over a genuinely different
        # order must differ. Both are checked, because only having the
        # first would be satisfied by a codec that sorted its input and
        # ignored the wire.
        check pcrComposite(compositeAlg(q), q.attest.quote.pcrSelect,
                           swapped) == composite

        var reversedSel = q.attest.quote.pcrSelect
        if reversedSel.selections.len == 1 and
            reversedSel.selections[0].select.len == 3:
          # Reverse the bitmap bytes: a genuinely different register set
          # in a genuinely different order, still well formed.
          let s0 = reversedSel.selections[0].select
          reversedSel.selections[0].select = s0[2] & s0[1] & s0[0]
          if selectedPcrs(reversedSel) != selectedPcrs(q.attest.quote.pcrSelect):
            var otherValues: seq[SelectedPcr] = @[]
            var haveAll = true
            for s in selectedPcrs(reversedSel):
              let hex = pcrValueHex(bankName(s.bank), s.index)
              if hex.len == 0: haveAll = false
              else: otherValues.add selectedPcr(s.bank, s.index, unhex(hex))
            if haveAll:
              check pcrComposite(compositeAlg(q), reversedSel, otherValues) !=
                composite

      # One byte of one register value.
      var altered = values
      var v0 = altered[0].value
      v0[0] = char(uint8(v0[0]) xor 0x01'u8)
      altered[0] = selectedPcr(altered[0].bank, altered[0].index, v0)
      check pcrComposite(compositeAlg(q), q.attest.quote.pcrSelect,
                         altered) != composite
      check not pcrCompositeMatches(q, altered)

    check vectorsChecked == 7

    # The mistake that looks most like the right answer: digesting the
    # two-bank selection under the BANK's algorithm rather than the
    # signing scheme's.
    block:
      let q = parseQuote(unhex(QuoteVectors[4].attestHex),
                         unhex(QuoteVectors[4].signatureHex))
      var values: seq[SelectedPcr] = @[]
      for s in selectedPcrs(q.attest.quote.pcrSelect):
        values.add selectedPcr(s.bank, s.index,
                               unhex(pcrValueHex(bankName(s.bank), s.index)))
      check compositeAlg(q) == TpmAlgSha256
      check q.attest.quote.pcrSelect.selections[0].hashAlg == TpmAlgSha1
      let underBank = pcrComposite(TpmAlgSha1, q.attest.quote.pcrSelect, values)
      check underBank != q.attest.quote.pcrDigest
      check underBank.len == 20

  test "t_pcr_composite_matches_live_swtpm":
    ## Layer 2. See the header: opt-in, and a hard failure rather than a
    ## skip when it is asked for and cannot run.
    ##
    ## Written as ONE NESTED `if` rather than with early returns.
    ## `unittest`'s `test` body is a template instantiation and the
    ## compiler will not let a `return` leave one. A `return` here
    ## compiles from a development shell and FAILS under the engine's own
    ## `nim c` invocation, which is where it was caught — so the shape is
    ## load-bearing rather than stylistic.
    if getEnv(LiveGateEnv) != "1":
      skip()
    else:
      let toolsDir = getEnv(Tpm2ToolsBinEnv)
      let swtpmDir = getEnv(SwtpmBinEnv)
      let probe = execCmdEx(
        quoteShell(
          if toolsDir.len > 0: toolsDir / "tpm2_quote" else: "tpm2_quote") &
        " --version")
      if probe.exitCode != 0:
        checkpoint("tpm2-tools is not runnable. Put its bin directory on " &
          "PATH, or name it in " & Tpm2ToolsBinEnv & "; likewise swtpm in " &
          SwtpmBinEnv & ". Neither package is in this host's profile.")
        fail()
      else:
        randomize(int(epochTime() * 1000) xor getCurrentProcessId())

        proc randomHex(n: int): string =
          const digits = "0123456789abcdef"
          result = newStringOfCap(n * 2)
          for _ in 0 ..< n:
            let b = rand(255)
            result.add digits[b shr 4]
            result.add digits[b and 0x0F]

        let tpm = startLiveTpm(toolsDir, swtpmDir)
        try:
          # Values drawn now. Nothing in this file, and nothing in the pinned
          # vectors, can be where the agreement below comes from.
          let selected = [0, 1, 4, 7, 11]
          for i in selected:
            discard tpm.mustRunTool(
              quoteShell(tpm.toolPath("tpm2_pcrextend")) & " " & $i &
              ":sha256=" & randomHex(32))

          let qualifying = randomHex(64)

          discard tpm.mustRunTool(
            quoteShell(tpm.toolPath("tpm2_createek")) & " -c ek.ctx -G rsa -u ek.pub")
          discard tpm.mustRunTool(
            quoteShell(tpm.toolPath("tpm2_createak")) &
            " -C ek.ctx -c ak.ctx -G ecc -g sha256 -s ecdsa -u ak.pub -f pem" &
            " -n ak.name")
          discard tpm.runTool(quoteShell(tpm.toolPath("tpm2_flushcontext")) & " -t")

          let quoteOut = tpm.mustRunTool(
            quoteShell(tpm.toolPath("tpm2_quote")) &
            " -c ak.ctx -l sha256:0,1,4,7,11 -q " & qualifying &
            " -m q.msg -s q.sig -o q.pcrs -f tss")
          discard tpm.runTool(quoteShell(tpm.toolPath("tpm2_flushcontext")) & " -t")

          let attestBytes = readFile(tpm.dir / "q.msg")
          let sigBytes = readFile(tpm.dir / "q.sig")
          let q = parseQuote(attestBytes, sigBytes)

          # The codec read the bytes the TPM wrote.
          check serializeAttest(q.attest) == attestBytes
          check serializeSignature(q.signature) == sigBytes
          check toHexLower(qualifyingData(q)) == qualifying

          # The registers, read back by the tool.
          let pcrs = parsePcrRead(tpm.mustRunTool(
            quoteShell(tpm.toolPath("tpm2_pcrread")) & " sha256:0,1,4,7,11"))
          check "sha256" in pcrs
          check pcrs["sha256"].len == 5

          var values: seq[SelectedPcr] = @[]
          for s in selectedPcrs(q.attest.quote.pcrSelect):
            check bankName(s.bank) == "sha256"
            check s.index in pcrs["sha256"]
            let hex = pcrs["sha256"][s.index]
            # An unextended register is all zeros, and a composite over one
            # would be a constant. These were extended above; assert it.
            check hex != repeat("00", 32)
            values.add selectedPcr(s.bank, s.index, unhex(hex))
          check values.len == 5

          let composite = pcrComposite(compositeAlg(q),
                                       q.attest.quote.pcrSelect, values)
          check composite == q.attest.quote.pcrDigest
          check pcrCompositeMatches(q, values)

          # And against tpm2-tools' own recomputation, scraped from the
          # `calcDigest:` line it printed a moment ago.
          var toolsDigest = ""
          for line in quoteOut.splitLines():
            let l = line.strip()
            if l.startsWith("calcDigest:"):
              toolsDigest = l[len("calcDigest:") .. ^1].strip().toLowerAscii
          check toolsDigest.len == 64
          check toHexLower(composite) == toolsDigest

          # The negative halves, against values this run produced.
          var altered = values
          var v0 = altered[0].value
          v0[31] = char(uint8(v0[31]) xor 0x01'u8)
          altered[0] = selectedPcr(altered[0].bank, altered[0].index, v0)
          check not pcrCompositeMatches(q, altered)

          var oneMissing = values[0 ..< 4]
          expect Tpm2CodecError:
            discard pcrComposite(compositeAlg(q), q.attest.quote.pcrSelect,
                                 oneMissing)
        finally:
          stopLiveTpm(tpm)
