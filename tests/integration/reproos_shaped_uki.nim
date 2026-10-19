## A ReproOS-shaped unified kernel image, built here from the PE
## specification, and the two things a measured boot does with it.
##
## Named without a ``t_`` / ``test_`` prefix so the test-edge generator
## does not discover it as a test in its own right.
##
## ## What this is
##
## A real PE32+ image: an ``MZ`` stub, a ``PE\0\0`` signature, a COFF
## header, a 240-byte optional header and one 40-byte section header per
## section, with each section's bytes written at a file-aligned offset
## and given a virtual address. It is what ``measureUkiPcr11`` walks and
## what ``readPeSectionTable`` parses; nothing about the FORMAT is stood
## in for.
##
## What it is not is the product's own assembler. ReproOS builds a UKI
## by appending sections to a content-pinned ``systemd-stub``, and that
## assembler lives in the product repository. This one synthesises the
## image from the specification instead, so a gate can have one without
## the stub being present on the machine — and so that a gate can build
## two images differing in ONE byte of one section, which is the input
## the measurement cases need and which an assembler driven by files is
## a clumsy way to get.
##
## ## Why it is shared rather than copied
##
## It was private to one gate. A second gate needing a UKI is exactly
## the moment at which a copy becomes two answers to what a UKI is, and
## the two would drift. The gate it came from now imports it, and its
## own cases are the regression test for this module.
##
## ## The trust-domain log
##
## ``trustDomainLogFor`` writes a crypto-agile TCG event log in the
## SHA-384 bank describing this image's measured sections, for the log
## index a trust domain's third runtime register is read out of. It is
## written here and replayed by the LIBRARY — ``replayTdxRegisters``,
## the same procedure that reproduces a real operator's four registers
## from that operator's own published record.
##
## **What that establishes and what it does not.** It establishes that
## an image built here produces a runtime register value through this
## build's own fold. It does NOT establish that a trust domain's
## firmware would write this log for this image: which register a stub
## extends on a trust domain, and with which event types, is a property
## of the firmware and is not settled here. The register VALUE is a
## calculation; the claim that a host would produce it is not made.
##
## ## Mocking
##
## None. Real PE bytes, the library's own event-log writer, the
## library's own replay.

import std/[strutils]

import nimcrypto/[hash, sha2]

import repro_attest

const
  OptionalHeaderSize = 240
  PeOffset = 0x40
  SectionTableAt = PeOffset + 4 + 20 + OptionalHeaderSize
  FileAlignment = 512
  SectionAlignment = 4096

  ReproosCmdline* = "root=/dev/mapper/reproos ro quiet"
    ## The command line the demonstration image carries. A real one:
    ## the section an attacker changes to alter what a kernel does
    ## without replacing the kernel.

  ReproosSbat* =
    "sbat,1\nreproos,1,ReproOS,reproos,1,https://example.invalid\n"
  ReproosOsRelease* = "ID=reproos\nVERSION_ID=0.1.0\n"
  ReproosUname* = "6.12.0-reproos"

  TrustDomainUkiRegister* = 2
    ## Which runtime register this module's log folds the image's
    ## sections into. A trust domain has four and the mapping from a
    ## discrete chip's registers is the firmware's; this is the index
    ## used here and the module header says so rather than implying the
    ## choice is established.

proc putU16(b: var string; at, v: int) =
  b[at] = char(v and 0xFF)
  b[at + 1] = char((v shr 8) and 0xFF)

proc putU32(b: var string; at: int; v: int) =
  for i in 0 ..< 4:
    b[at + i] = char((v shr (8 * i)) and 0xFF)

proc syntheticUki*(sections: openArray[(string, string)]): string =
  ## A real PE32+ image carrying `sections` in the given file order.
  let headerRoom = max(SectionTableAt + sections.len * 40 + 64, FileAlignment)
  var body = ""
  var headers = newString(headerRoom)
  headers[0] = 'M'
  headers[1] = 'Z'
  putU32(headers, 0x3C, PeOffset)
  headers[PeOffset] = 'P'
  headers[PeOffset + 1] = 'E'
  let coff = PeOffset + 4
  putU16(headers, coff, 0x8664)
  putU16(headers, coff + 2, sections.len)
  putU16(headers, coff + 16, OptionalHeaderSize)
  let opt = coff + 20
  putU16(headers, opt, 0x20B)
  putU32(headers, opt + 32, SectionAlignment)
  putU32(headers, opt + 36, FileAlignment)
  putU32(headers, opt + 60, headerRoom)
  var nextRaw =
    ((headerRoom + FileAlignment - 1) div FileAlignment) * FileAlignment
  var nextVirtual = SectionAlignment
  for i, (name, content) in sections:
    let at = SectionTableAt + i * 40
    for j in 0 ..< name.len:
      headers[at + j] = name[j]
    let rawSize =
      ((content.len + FileAlignment - 1) div FileAlignment) * FileAlignment
    putU32(headers, at + 8, content.len)
    putU32(headers, at + 12, nextVirtual)
    putU32(headers, at + 16, rawSize)
    putU32(headers, at + 20, nextRaw)
    putU32(headers, at + 36, 0x40000040)
    var padded = content
    while padded.len < rawSize: padded.add '\0'
    body.add padded
    nextRaw += rawSize
    nextVirtual +=
      ((content.len + SectionAlignment - 1) div SectionAlignment) *
      SectionAlignment
  putU32(headers, opt + 56, nextVirtual)
  var image = headers
  while image.len <
      ((headerRoom + FileAlignment - 1) div FileAlignment) * FileAlignment:
    image.add '\0'
  image.add body
  image

proc reproosUkiSections*(cmdline = ReproosCmdline;
                         kernel = repeat("K", 9000);
                         initrd = repeat("I", 3000)):
                        seq[(string, string)] =
  ## The six sections a ReproOS image carries, in FILE order — which is
  ## deliberately not the measurement order, and `.sbat` first the way a
  ## stub's own section is.
  @[(".sbat", ReproosSbat),
    (".osrel", ReproosOsRelease),
    (".cmdline", cmdline),
    (".uname", ReproosUname),
    (".initrd", initrd),
    (".linux", kernel)]

proc demoUki*(cmdline = ReproosCmdline): string =
  syntheticUki(reproosUkiSections(cmdline))

# ---------------------------------------------------------------------
# The trust-domain event log
# ---------------------------------------------------------------------

proc rawOfHex(hex: string): string =
  result = newString(hex.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(hex[2 * i .. 2 * i + 1]))

proc sha384Hex(data: string): string =
  ## SHA-384 of `data`, as 96 lower-case hex characters. The bank a
  ## trust domain's registers are kept in.
  toLowerAscii($sha384.digest(data))

proc specIdHeaderEntry(): string =
  ## Entry 0, in both shapes, declaring the one bank every later entry
  ## carries.
  var spec = initTpm2Writer("TCG_EfiSpecIdEvent")
  spec.writeBytes(SpecIdSignature)
  spec.writeU32Le(0'u32)                    # platformClass
  spec.writeU8(0'u8)                        # specVersionMinor
  spec.writeU8(2'u8)                        # specVersionMajor
  spec.writeU8(0'u8)                        # specErrata
  spec.writeU8(2'u8)                        # uintnSize: 64-bit
  spec.writeU32Le(1'u32)                    # numberOfAlgorithms
  spec.writeU16Le(uint16(TpmAlgSha384))
  spec.writeU16Le(uint16(digestSize(TpmAlgSha384)))
  spec.writeU8(0'u8)                        # vendorInfoSize
  let payload = spec.bytes

  var w = initTpm2Writer("TCG_PCR_EVENT")
  w.writeU32Le(0'u32)
  w.writeU32Le(uint32(EvNoAction))
  w.writeBytes(repeat('\0', LegacyDigestBytes))
  w.writeU32Le(uint32(payload.len))
  w.writeBytes(payload)
  w.bytes

proc agileEntry(index: int; eventType: TcgEventType;
                digestHex, data: string): string =
  var w = initTpm2Writer("TCG_PCR_EVENT2")
  w.writeU32Le(uint32(index))
  w.writeU32Le(uint32(eventType))
  w.writeU32Le(1'u32)                       # one digest, one bank
  w.writeU16Le(uint16(TpmAlgSha384))
  w.writeBytes(rawOfHex(digestHex))
  w.writeU32Le(uint32(data.len))
  w.writeBytes(data)
  w.bytes

proc trustDomainLogFor*(image: string): string =
  ## A crypto-agile SHA-384 event log describing this image's measured
  ## sections, plus two firmware entries so the first runtime register
  ## has an input of its own.
  ##
  ## The measured sections and their content digests come from
  ## ``measureUkiPcr11`` — the library's own walk over the image's
  ## section table, in the library's own measurement order, with its own
  ## rule about zero-fill beyond the raw size. Only the BANK differs
  ## from what that procedure reports, so a section this module measures
  ## is a section that procedure measured.
  let measured = measureUkiPcr11(image)
  result = specIdHeaderEntry()
  for (label, eventType) in [
      ("reproos trust domain firmware", EvSCrtmVersion),
      ("reproos trust domain configuration", EvEfiVariableDriverConfig)]:
    result.add agileEntry(TdxFirstLogRegisterIndex, eventType,
      sha384Hex("emulated-td-firmware:" & label), label)
  let index = TdxFirstLogRegisterIndex + TrustDomainUkiRegister
  for ev in measured.events:
    result.add agileEntry(index, EvEventTag,
      sha384Hex(ev.section & "\0"), ev.section & "\0")
    result.add agileEntry(index, EvIpl,
      sha384Hex("content:" & ev.dataDigest),
      "reproos " & ev.section & " content")
