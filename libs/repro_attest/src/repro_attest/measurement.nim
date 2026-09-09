## Launch-measurement precomputation for unified kernel images.
##
## ## What this computes, and why it is a pure function
##
## A UEFI stub that starts a unified kernel image measures each of the
## image's own PE sections into TPM PCR 11 before it hands control to the
## kernel: first the section's NAME, then the section's CONTENT, each as
## an ordinary TCG event, i.e. `PCR := SHA256(PCR ‖ SHA256(event data))`.
## Because both the order and the bytes are fixed by the image, the PCR
## value a machine will report is a pure function of the image — it can be
## computed at build time, published, and checked against a running
## instance.
##
## The three things that make the result exact rather than approximate:
##
##   * **The order is the stub's, not the file's.** Sections are measured
##     in the order of the stub's own unified-section table
##     (`UnifiedSectionOrder` below), which is NOT the order the sections
##     are written into the PE. Getting this wrong yields a plausible,
##     stable, wrong answer.
##   * **The measured length is `VirtualSize`, not `SizeOfRawData`.**
##     A section is padded to the file alignment on disk; the stub measures
##     what it loaded, so the alignment padding is outside the digest.
##   * **The stub's own sections count.** A stub carries `.sbat`, and
##     `.sbat` is a unified section, so it is measured too — before any
##     appended section that sorts after it. A calculator that only knows
##     about the sections the build appended is wrong by one event pair.
##
## ## What is deliberately refused
##
## Multi-profile images (an image carrying a `.profile` section) select a
## subset of sections at boot, so a single PCR value does not describe
## them. Rather than compute a value that is right only for profile 0,
## `measureUkiPcr11` refuses. The same applies to any PE this module
## cannot read exactly: a measurement derived from a guess is worse than
## no measurement.
##
## ## Mocking
##
## None. Everything here operates on real PE bytes.

import std/[strutils]

import nimcrypto/[hash, sha2]

type
  MeasurementError* = object of CatchableError
    ## Raised for any image this module cannot measure exactly.

  PeSection* = object
    ## One row of a PE/COFF section table.
    name*: string
    virtualSize*: int
    virtualAddress*: int
    rawSize*: int
    fileOffset*: int

  MeasuredEvent* = object
    ## One measured section: the stub logs two TCG events for it, the
    ## name and then the content, and both extend the same PCR.
    section*: string
    size*: int
      ## The number of bytes measured — the section's ``VirtualSize``.
    dataDigest*: string
      ## Lower-case hex SHA-256 of those bytes. This is the digest of the
      ## CONTENT event; the NAME event's digest is derived from
      ## ``section`` and needs no storing.

  UkiMeasurement* = object
    pcr11*: string
      ## Lower-case hex, 64 characters. The value PCR 11 holds after the
      ## stub has measured the image and before anything else extends it.
    events*: seq[MeasuredEvent]

const
  UnifiedSectionOrder*: array[15, string] = [
    ".linux", ".osrel", ".cmdline", ".initrd", ".ucode", ".splash",
    ".dtb", ".uname", ".sbat", ".pcrsig", ".pcrpkey", ".profile",
    ".dtbauto", ".hwids", ".efifw"]
    ## The stub's unified-section table, in the order it walks it.
    ##
    ## This constant is not a recollection: it is the NUL-separated run of
    ## strings the pinned stub carries in its own read-only data, and the
    ## gate that consumes this module checks it back against those bytes,
    ## so a stub whose table changed cannot be measured with a stale copy
    ## of it.

  UnmeasuredSections*: array[2, string] = [".pcrsig", ".pcrpkey"]
    ## The two sections a stub does NOT measure: the signed policy over
    ## the measurements, and the key that policy is verified with. Both
    ## are statements ABOUT the measurement, so measuring them would make
    ## the value they describe depend on themselves.

  ProfileSection* = ".profile"
    ## Its presence means the image carries more than one profile, which
    ## this module refuses rather than half-understands.

  Pcr11* = 11
    ## The PCR a stub extends with the image's sections.

  PcrDigestSize* = 32
  ZeroPcr* = "0000000000000000000000000000000000000000000000000000000000000000"
    ## A PCR that has never been extended, as this module renders it.

  EventLogTemplateId* = "systemd-stub-uki-sections.v1"
    ## The identifier that opens a rendered replay template. It names the
    ## measuring agent and the shape of what follows, so a verifier that
    ## meets a template it does not know refuses instead of replaying it
    ## under the wrong rules.

proc sha256Hex*(data: string): string =
  ## Lower-case hex SHA-256, the one digest this module speaks.
  toLowerAscii($sha256.digest(data))

proc extendPcr*(pcr, eventDigest: string): string =
  ## One TCG extend: ``PCR := SHA256(PCR ‖ digest)``. Both arguments and
  ## the result are 64-character lower-case hex.
  if pcr.len != PcrDigestSize * 2:
    raise newException(MeasurementError,
      "a PCR value must be " & $(PcrDigestSize * 2) &
      " hex characters, got " & $pcr.len)
  if eventDigest.len != PcrDigestSize * 2:
    raise newException(MeasurementError,
      "an event digest must be " & $(PcrDigestSize * 2) &
      " hex characters, got " & $eventDigest.len)
  var raw = newString(PcrDigestSize * 2)
  for i in 0 ..< PcrDigestSize:
    raw[i] = char(parseHexInt(pcr[2 * i .. 2 * i + 1]))
    raw[PcrDigestSize + i] = char(parseHexInt(eventDigest[2 * i .. 2 * i + 1]))
  sha256Hex(raw)

proc sectionNameEventDigest*(name: string): string =
  ## The digest of the NAME event. The stub measures the section name as
  ## its ASCII bytes INCLUDING the terminating NUL — a calculator that
  ## drops the NUL produces a stable, plausible, wrong PCR.
  sha256Hex(name & "\0")

# ---------------------------------------------------------------------
# PE/COFF section table
# ---------------------------------------------------------------------

proc u16(image: string; at: int): int =
  int(uint8(image[at])) or (int(uint8(image[at + 1])) shl 8)

proc u32(image: string; at: int): int =
  var v = 0'i64
  for i in countdown(3, 0):
    v = (v shl 8) or int64(uint8(image[at + i]))
  int(v)

proc readPeSectionTable*(image: string): seq[PeSection] =
  ## The section table of a PE32+ image, in file order.
  ##
  ## Every bound is checked and every unexpected shape raises: this reads
  ## the artifact a measurement is taken over, so "probably fine" is not
  ## an acceptable outcome.
  if image.len < 0x40:
    raise newException(MeasurementError, "not a PE image: shorter than a DOS header")
  if image[0] != 'M' or image[1] != 'Z':
    raise newException(MeasurementError, "not a PE image: no MZ signature")
  let peOffset = u32(image, 0x3C)
  if peOffset <= 0 or peOffset + 24 > image.len:
    raise newException(MeasurementError,
      "not a PE image: e_lfanew " & $peOffset & " is outside the file")
  if image[peOffset] != 'P' or image[peOffset + 1] != 'E' or
     image[peOffset + 2] != '\0' or image[peOffset + 3] != '\0':
    raise newException(MeasurementError, "not a PE image: no PE\\0\\0 signature")
  let coff = peOffset + 4
  let numberOfSections = u16(image, coff + 2)
  let optionalHeaderSize = u16(image, coff + 16)
  let opt = coff + 20
  if opt + 2 > image.len:
    raise newException(MeasurementError, "truncated PE optional header")
  if u16(image, opt) != 0x20B:
    raise newException(MeasurementError,
      "not a PE32+ image: optional header magic is 0x" &
      toHex(u16(image, opt), 4) & ", expected 0x020B")
  let tableAt = opt + optionalHeaderSize
  if numberOfSections <= 0:
    raise newException(MeasurementError, "the PE section table is empty")
  if tableAt + numberOfSections * 40 > image.len:
    raise newException(MeasurementError,
      "the PE section table (" & $numberOfSections &
      " sections) runs past the end of the file")
  result = @[]
  for i in 0 ..< numberOfSections:
    let at = tableAt + i * 40
    var name = ""
    for j in 0 ..< 8:
      let c = image[at + j]
      if c == '\0': break
      name.add c
    let s = PeSection(
      name: name,
      virtualSize: u32(image, at + 8),
      virtualAddress: u32(image, at + 12),
      rawSize: u32(image, at + 16),
      fileOffset: u32(image, at + 20))
    if s.fileOffset < 0 or s.rawSize < 0 or s.virtualSize < 0:
      raise newException(MeasurementError,
        "section " & name & " has a negative offset or size")
    if s.rawSize > 0 and s.fileOffset + s.rawSize > image.len:
      raise newException(MeasurementError,
        "section " & name & "'s raw data runs past the end of the file")
    result.add s

proc measuredBytes(image: string; s: PeSection): string =
  ## The bytes the stub measures for one section: ``VirtualSize`` bytes
  ## from the loaded image. Anything the file does not carry is zero-fill
  ## in memory, so it is zero-fill here too.
  if s.virtualSize == 0: return ""
  let fromFile = min(s.virtualSize, s.rawSize)
  if fromFile < 0 or s.fileOffset + fromFile > image.len:
    raise newException(MeasurementError,
      "section " & s.name & " is not readable from this image")
  result = image[s.fileOffset ..< s.fileOffset + fromFile]
  if s.virtualSize > fromFile:
    result.add repeat('\0', s.virtualSize - fromFile)

proc measureUkiPcr11*(image: string): UkiMeasurement =
  ## Precompute PCR 11 for a unified kernel image.
  ##
  ## Raises ``MeasurementError`` for anything that cannot be measured
  ## exactly: an unreadable PE, an image with no measurable section, or a
  ## multi-profile image.
  let sections = readPeSectionTable(image)
  for s in sections:
    if s.name == ProfileSection:
      raise newException(MeasurementError,
        "this image carries a " & ProfileSection & " section, so it selects " &
        "one of several profiles at boot and no single PCR 11 value " &
        "describes it; per-profile precomputation is not implemented")
  var pcr = ZeroPcr
  result.events = @[]
  for want in UnifiedSectionOrder:
    if want in UnmeasuredSections: continue
    for s in sections:
      if s.name != want: continue
      let content = measuredBytes(image, s)
      pcr = extendPcr(pcr, sectionNameEventDigest(want))
      let dataDigest = sha256Hex(content)
      pcr = extendPcr(pcr, dataDigest)
      result.events.add MeasuredEvent(
        section: want, size: s.virtualSize, dataDigest: dataDigest)
      break
  if result.events.len == 0:
    raise newException(MeasurementError,
      "this image carries none of the sections a stub measures, so it is " &
      "not a unified kernel image")
  result.pcr11 = pcr

# ---------------------------------------------------------------------
# The replay template
# ---------------------------------------------------------------------

proc renderEventLogTemplate*(m: UkiMeasurement): string =
  ## A one-line, canonical rendering of everything a verifier needs to
  ## REPLAY PCR 11 rather than take its value on trust: the measuring
  ## agent, the bank, and the ordered content digests.
  ##
  ## The section names are the keys, so the name events are implied; the
  ## content digests are given, so the verifier never needs the image.
  result = EventLogTemplateId & ";bank=sha256"
  for e in m.events:
    result.add ";" & e.section & "=" & e.dataDigest

proc replayEventLogTemplate*(tmpl: string): string =
  ## Replay a template to the PCR value it describes. This is the inverse
  ## of ``renderEventLogTemplate`` and the reason the template is a
  ## contract rather than a comment: a template that does not replay to
  ## the manifest's own ``pcr11`` is a manifest that disagrees with itself.
  let parts = tmpl.split(';')
  if parts.len < 3:
    raise newException(MeasurementError,
      "an event-log template needs an id, a bank and at least one event")
  if parts[0] != EventLogTemplateId:
    raise newException(MeasurementError,
      "unknown event-log template " & parts[0] & "; this build understands " &
      EventLogTemplateId & " and refuses to replay anything else")
  if parts[1] != "bank=sha256":
    raise newException(MeasurementError,
      "unsupported PCR bank " & parts[1] & "; this build understands " &
      "bank=sha256")
  var pcr = ZeroPcr
  for i in 2 ..< parts.len:
    let eq = parts[i].find('=')
    if eq <= 0:
      raise newException(MeasurementError,
        "malformed event-log entry " & parts[i] & "; expected <section>=<digest>")
    let name = parts[i][0 ..< eq]
    let digest = parts[i][eq + 1 .. ^1]
    if name notin UnifiedSectionOrder:
      raise newException(MeasurementError,
        "event-log entry names " & name & ", which is not a section a stub " &
        "measures")
    if name in UnmeasuredSections:
      raise newException(MeasurementError,
        "event-log entry names " & name & ", which a stub deliberately does " &
        "not measure")
    if digest.len != PcrDigestSize * 2:
      raise newException(MeasurementError,
        "event-log entry " & name & " carries a " & $digest.len &
        "-character digest; a SHA-256 digest is " & $(PcrDigestSize * 2))
    for c in digest:
      if c notin {'0' .. '9', 'a' .. 'f'}:
        raise newException(MeasurementError,
          "event-log entry " & name & "'s digest is not lower-case hex")
    pcr = extendPcr(pcr, sectionNameEventDigest(name))
    pcr = extendPcr(pcr, digest)
  pcr
