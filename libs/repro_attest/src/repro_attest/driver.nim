## The backend driver seam: how the agent asks a root of trust for
## evidence.
##
## ## What this is
##
## An attested instance has exactly one thing a remote party can rely on:
## bytes a hardware root signed. *Which* root, and *how* those bytes are
## obtained, differs completely between a confidential-computing guest, a
## measured-boot TPM and a test emulator — and nothing else in the system
## may care. This module is the whole of what the agent knows about a
## backend.
##
## The interface is deliberately narrower than the surface a driver
## implements internally. A driver may open device nodes, talk to a quote
## service, walk configfs, or parse an event log; the agent sees three
## operations and two data shapes.
##
## ## The one decision that shapes everything else
##
## **A driver receives the 64 bytes. It does not compute them, and it is
## not told what they were computed from.**
##
## ``QuoteRequest`` carries ``reportData`` and nothing else — no
## challenge, no purpose, no ephemeral key. That is not an oversight and
## it is not minimalism for its own sake:
##
##   * The construction lives in ``binding`` and runs once, for every
##     backend. A driver that could see the challenge could derive its own
##     bytes, and then "what did this instance bind?" would have as many
##     answers as there are drivers. The whole point of the discipline is
##     that it has one.
##   * A driver that cannot see the challenge cannot bind anything other
##     than what it was handed. The property is structural rather than
##     documented.
##   * The purpose is already *inside* the 64 bytes, so a driver has no
##     use for it that is not a way to behave differently for two
##     protocols — which is the thing the purpose field exists to prevent.
##
## The agent computes the envelope's ``reportData`` itself, from the
## request's challenge and bindings, and never from anything a driver
## returns. So a driver cannot write that field, and a driver that embeds
## the *wrong* bytes in its evidence produces a report whose envelope and
## evidence disagree — which is exactly the failure a verifier is there to
## catch, and exactly what a fault-injecting emulator wants to be able to
## produce.
##
## ## Why the backend is a value and not the driver's type
##
## ``backend`` says what the evidence *is*, not which code produced it.
## They are usually the same and in one important case they are not: a
## software-root emulator produces SEV-SNP-shaped evidence signed by a
## test root, so its ``backend`` is ``abSevSnp`` while its ``driverName``
## is its own. A report names the evidence format a verifier must parse;
## ``driverName`` is for diagnostics and logs, and nothing on the wire
## reads it.
##
## The tier is never a driver's to choose. It follows from ``backend``
## through ``tierOf``, and ``report`` refuses a backend outside the tier
## naming it, so a driver cannot raise its own tier.
##
## ## How the later backends fit
##
##   * **tpm2** — ``driverQuote`` runs ``TPM2_Quote`` with the 64 bytes as
##     ``qualifyingData`` over a fixed PCR selection, and packs the
##     attestation structure, the signature and the TCG event log into one
##     opaque ``evidence`` blob. The AK certificate goes in
##     ``certificates``. The PCR selection is the driver's configuration,
##     not a request field: a caller that could choose which registers are
##     quoted could choose the ones that say nothing.
##   * **sev-snp** and **tdx** — both are the configfs-tsm shape: write 64
##     bytes to ``inblob``, read ``outblob``. SNP's certificate blob
##     becomes ``certificates``; TDX normally leaves it absent because the
##     verifier fetches DCAP collateral itself.
##   * **a software-root emulator** — subclasses this, declares whichever
##     ``backend`` it is emulating, and takes its scenario (measurement,
##     TCB, firmware, chain, and every mutation) *at construction*. Not
##     from the request: an emulator steerable by a remote caller is a
##     verifier bypass wearing a driver's clothes, and the interface must
##     not make that spellable.
##
## ## What is deliberately not here
##
##   * **Verification.** A backend surface is often described as
##     acquisition plus serialization plus a verification driver. Only
##     acquisition is here. The agent sits inside every attested TCB, and
##     linking a verifier into it would ship the code that decides
##     whether to trust into the thing being trusted.
##   * **Collateral fetching and revocation.** A driver returns what the
##     instance has. Reaching a vendor's distribution point is the
##     verifier's business, on the verifier's network.
##   * **Per-request configuration of any kind.** See the emulator note
##     above. Everything a driver needs is fixed when it is constructed.
##   * **Long-term keys.** The agent holds none, and neither does a
##     driver: an attestation key that lives in the TPM is the TPM's, and
##     the ephemeral key of a key agreement is minted per session by a
##     separate seam.
##   * **Asynchrony and cancellation.** Every one of these operations is a
##     blocking ioctl, a blocking file write, or a blocking command
##     transaction. Wrapping them in an async interface would describe a
##     concurrency none of the hardware has.
##
## ## Mocking
##
## None here. ``mock_backend`` implements this interface for a root of
## trust that does not exist, which is a backend rather than a mock of
## one.

import std/options

import ./binding
import ./report

type
  DriverError* = object of CatchableError
    ## Raised when a backend cannot produce evidence, or produces
    ## something this seam will not pass on. The message names the
    ## backend, because whoever reads it is looking at a machine that
    ## would not attest.

  BackendReadiness* = object
    ## What ``GET /health`` says about the root of trust.
    ready*: bool
      ## Whether a quote requested right now would be attempted at all.
      ## It is not a promise that one would succeed — that costs a quote,
      ## and a liveness probe that consumed one would be a way to exhaust
      ## the device by asking whether it works.
    detail*: string
      ## One line naming what was checked: the device node, the quote
      ## service, the configfs directory. Read by an operator looking at
      ## a machine that will not attest, so it says *what* was missing
      ## rather than that something was.

  QuoteRequest* = object
    ## Everything a driver is told. See the module header for why it is
    ## this and nothing else.
    reportData*: string
      ## Exactly ``ReportDataSize`` RAW bytes — not hex. These are the
      ## bytes that must appear in the hardware's report-data field.

  QuoteResult* = object
    ## Everything a driver returns.
    evidence*: string
      ## The backend-native quote or report, RAW bytes. The envelope's
      ## base64 is not the driver's business.
    certificates*: Option[seq[string]]
      ## The chain the instance holds, RAW DER per element, when it holds
      ## one. ``none`` and an empty sequence are different answers and the
      ## envelope refuses the second, so a driver that bundles nothing
      ## returns ``none``.

  AttestationDriver* = ref object of RootObj
    ## The seam. Subclass it, call ``initAttestationDriver`` once, and
    ## override the three methods below.
    backendKind: AttestationBackend
    nameForDiagnostics: string

proc initAttestationDriver*(d: AttestationDriver;
                            backend: AttestationBackend;
                            driverName: string) =
  ## Every subclass calls this exactly once, in its constructor. The two
  ## fields are set here rather than being public and assignable, so a
  ## driver's identity is decided when it is built and not by whatever
  ## last wrote to it.
  if driverName.len == 0:
    raise newException(DriverError,
      "a driver must name itself; the name is what an operator reads " &
      "when a machine will not attest")
  d.backendKind = backend
  d.nameForDiagnostics = driverName

proc backend*(d: AttestationDriver): AttestationBackend =
  ## What this driver's evidence *is* — the value a report carries and a
  ## verifier parses against.
  d.backendKind

proc tier*(d: AttestationDriver): AttestationTier =
  ## Never a driver's choice; it follows from the backend.
  tierOf(d.backendKind)

proc driverName*(d: AttestationDriver): string =
  ## Which implementation produced the evidence. Diagnostics only —
  ## nothing on the wire reads it, and a verifier must never be able to.
  d.nameForDiagnostics

# ---------------------------------------------------------------------
# The three operations
# ---------------------------------------------------------------------

method driverProbe*(d: AttestationDriver): BackendReadiness {.base.} =
  ## Cheap, side-effect-free, and it must not consume a quote.
  raise newException(DriverError,
    "driver " & d.driverName & " does not implement driverProbe")

method driverQuote*(d: AttestationDriver;
                    req: QuoteRequest): QuoteResult {.base.} =
  ## Produce evidence carrying ``req.reportData``.
  ##
  ## Call it through ``acquireQuote``, never directly: the pre- and
  ## post-conditions are the seam, and a driver invoked around them is a
  ## driver whose output nothing checked.
  raise newException(DriverError,
    "driver " & d.driverName & " does not implement driverQuote")

method driverClose*(d: AttestationDriver) {.base.} =
  ## Release device handles. Drivers with none need not override.
  discard

# ---------------------------------------------------------------------
# The checked entry point
# ---------------------------------------------------------------------

proc acquireQuote*(d: AttestationDriver; reportData: string): QuoteResult =
  ## The only way the agent obtains evidence.
  ##
  ## The checks below are here rather than in each driver because they are
  ## the seam's contract and not any one backend's: a driver handed the
  ## wrong number of bytes has been mis-called, and a driver returning
  ## something the envelope cannot carry has misbehaved. Catching either
  ## here means the failure names the driver, at the moment it happened,
  ## instead of surfacing forty lines later as a schema complaint about a
  ## document nobody meant to build.
  if reportData.len != ReportDataSize:
    raise newException(DriverError,
      "driver " & d.driverName & " was handed " & $reportData.len &
      " bytes of report data; the discipline binds exactly " &
      $ReportDataSize)

  result = d.driverQuote(QuoteRequest(reportData: reportData))

  if result.evidence.len == 0:
    raise newException(DriverError,
      "driver " & d.driverName & " returned no evidence; evidence is the " &
      "only authoritative field a report has, so there is nothing to send")
  # The envelope bounds base64, which is four characters per three bytes.
  # Refusing here rather than after encoding means the message names the
  # driver that produced the oversized blob.
  if result.evidence.len > (MaxEvidenceBase64 div 4) * 3:
    raise newException(DriverError,
      "driver " & d.driverName & " returned " & $result.evidence.len &
      " bytes of evidence, which does not fit the envelope's bound of " &
      $MaxEvidenceBase64 & " base64 characters")
  if result.certificates.isSome:
    let chain = result.certificates.get
    if chain.len == 0:
      raise newException(DriverError,
        "driver " & d.driverName & " returned a present-but-empty " &
        "certificate chain; a driver that bundles nothing returns none, " &
        "so that \"fetch your own collateral\" cannot be mistaken for " &
        "\"here is a chain\"")
    if chain.len > MaxCertificates:
      raise newException(DriverError,
        "driver " & d.driverName & " returned " & $chain.len &
        " certificates; the envelope carries at most " & $MaxCertificates)
    for i, cert in chain:
      if cert.len == 0:
        raise newException(DriverError,
          "driver " & d.driverName & " returned an empty certificate at " &
          "index " & $i)
      if cert.len > (MaxCertificateBase64 div 4) * 3:
        raise newException(DriverError,
          "driver " & d.driverName & " returned a " & $cert.len &
          "-byte certificate at index " & $i &
          ", which does not fit the envelope's per-certificate bound")

# ---------------------------------------------------------------------
# The ephemeral key seam
# ---------------------------------------------------------------------

type
  EphemeralKeyPair* = object
    ## One key agreement's key material, held in memory for the lifetime
    ## of one session and never written anywhere.
    publicKey*: string
      ## RAW public-key bytes. These are what the evidence binds, so the
      ## quote and the key become one object.
    privateKey*: string
      ## RAW private-key bytes. Never leaves the instance, never appears
      ## in a report, and is overwritten when the session ends.

  EphemeralKeySource* = ref object of RootObj
    ## Where ``POST /key-agreement`` gets its key pair.
    ##
    ## Separate from ``AttestationDriver`` on purpose. The root of trust
    ## and the key agreement are independent axes: the same TPM backend
    ## serves an X25519 agreement and a P-384 one, and the same key
    ## agreement runs on every backend. Folding the key into the driver
    ## would multiply the two.
    ##
    ## This seam exists so the endpoint, its binding and its session
    ## lifecycle can be built and proved now, while the key-encapsulation
    ## mechanism they will carry is built separately. A build with no
    ## source configured refuses key agreements rather than inventing a
    ## key — a public key nobody holds the private half of is worse than
    ## no key at all, because a secret encrypted to it is a secret
    ## destroyed in transit.
    algorithmName: string

proc initEphemeralKeySource*(s: EphemeralKeySource; algorithm: string) =
  if algorithm.len == 0:
    raise newException(DriverError,
      "an ephemeral key source must name its algorithm; a report binds " &
      "the key and the party encrypting to it has to know what it is")
  s.algorithmName = algorithm

proc algorithm*(s: EphemeralKeySource): string =
  ## The named key-encapsulation mechanism, for diagnostics and for the
  ## health surface.
  s.algorithmName

method generateEphemeralKeyPair*(s: EphemeralKeySource): EphemeralKeyPair
    {.base.} =
  raise newException(DriverError,
    "key source " & s.algorithm & " does not implement " &
    "generateEphemeralKeyPair")
