## The `reproos.attested-image.v1` measurement manifest and the PCR-11
## calculator underneath it.
##
## ## What each case is worth
##
## `t_manifest_deterministic` and `t_manifest_rejects_unknown_launch_shape`
## are about the document: the same image must render the same bytes, and
## a document this build cannot fully honour must be refused rather than
## partly understood.
##
## `t_pcr11_precomputation_matches_measured_boot` is the case the rest
## rests on. A PCR calculator that agrees with itself proves nothing at
## all — it is a hash chain, and a hash chain will happily produce a
## stable wrong answer forever. So the values pinned here are not this
## code's output. They are:
##
##   * the PCR 11 a REAL guest read off `/dev/tpm0` after a real
##     swtpm-backed TPM 2.0 was extended by real UEFI firmware and a real
##     stub, together with the ordered section digests of the image it
##     booted; and
##   * a value produced by systemd 258.2's OWN `systemd-measure
##     calculate`, which is a different implementation by a different
##     author of the same specification.
##
## The two anchors are independent of each other and both independent of
## this module. The live re-derivation — building an image, booting it
## with a virtual TPM and reading the register — lives in the image
## repository's gate, where the artifacts are; these are the regression
## anchors that keep the calculator honest between such runs.
##
## ## Mocking
##
## None. The synthetic PE below is a fixture, not a mock: it is a real
## PE32+ section table built from the specification, and the code under
## test is the real reader operating on real bytes.

import std/[json, strutils, unittest]

import repro_attest

# ---------------------------------------------------------------------
# Anchors from a real measured boot
#
# One boot, x86-64 QEMU, OVMF (the edk2 build QEMU ships, which carries
# the TCG2 protocol), a virtual TPM 2.0 backed by swtpm 0.10.1, and
# systemd 258.2's `linuxx64.efi.stub`. The guest loaded the TPM drivers
# and issued a raw TPM2_PCR_Read for PCR 11 in the SHA-256 bank.
# ---------------------------------------------------------------------

const
  MeasuredBootPcr11 =
    "6e1f6485d8bd6c5f317ac3985459f5adc14fec33ffdf8ab2b67864ea96817f82"
    ## The 32 bytes the guest read back out of the TPM.

  MeasuredBootTemplate =
    EventLogTemplateId & ";bank=sha256" &
    ";.linux=5dc3814e8591c1fe70ae2d8182f3cde2bdace696aa9fcad9c38abb37553336f3" &
    ";.osrel=fef1fa91366c4b1a1f3603c5924d98369e835e401e216f36dfd0c76945069692" &
    ";.cmdline=ac5c46bfd0c3fbeaee4f065b3fd100bdb6ae4c11c44cfafa4a84813265c9f28e" &
    ";.initrd=d49174542adb0ad2011e3f11692975c410a5b82d5b8711e29a81b4a189399f3f" &
    ";.uname=b6c9363758d01225d788522c8f634b17358961700c95afd50edac85fae05987f" &
    ";.sbat=5222a493b7d36f37db2003bfd108f2eb969f88f214384fe37654a23b43596366"
    ## The sections of the image that boot loaded, in the order the stub
    ## measured them. Note that `.sbat` is here and is LAST: it belongs to
    ## the stub itself, not to anything the build appended, and it sorts
    ## after every appended section. A calculator that only knows about
    ## appended sections is wrong by one event pair, and this template is
    ## what says so.

  SystemdMeasureEnterInitrd =
    "c328b272ce615d76aae4d6dbd160b6ea48de7c55e50b9196d1cb8f52459f3578"
    ## `systemd-measure calculate --bank=SHA256` over the same six
    ## sections, for the `enter-initrd` phase — that is, PCR 11 after the
    ## stub's measurements AND one further extension with the phase
    ## string. A third-party implementation therefore agrees with
    ## `MeasuredBootPcr11` if extending it by that phase reproduces this.

# ---------------------------------------------------------------------
# A REGENERABLE third-party vector.
#
# The two constants above came from one particular image, and neither
# that image nor the guest that booted it exists any more, so nobody can
# re-derive them from this file. The vector below can be: its six section
# CONTENTS are written out here as literals, so anyone with systemd can
# reproduce it from this source alone —
#
#   printf 'K-kernel-bytes-for-anchor'                          > linux
#   printf 'ID=reproos\nVERSION_ID=0.1.0\n'                     > osrel
#   printf 'root=/dev/mapper/reproos ro quiet'                  > cmdline
#   printf 'INITRD-BYTES-FOR-ANCHOR'                            > initrd
#   printf '6.12.0-reproos'                                     > uname
#   printf 'sbat,1,SBAT Version,sbat,1,https://example.invalid\n' > sbat
#   systemd-measure calculate --bank=SHA256 \
#     --linux=linux --osrel=osrel --cmdline=cmdline \
#     --initrd=initrd --uname=uname --sbat=sbat
#
# — and the four values below are what systemd 258.2 printed. The case
# assembles those same bytes into a PE32+ image and drives the REAL
# reader and the REAL extend chain over it, so the vector constrains the
# measured order, the name-including-NUL rule, the inclusion of `.sbat`,
# AND the use of `VirtualSize` rather than `SizeOfRawData` (the sections
# below are all far shorter than the 512-byte file alignment, so a
# calculator that digested the padding would land somewhere else).
# ---------------------------------------------------------------------

const
  VectorLinux = "K-kernel-bytes-for-anchor"
  VectorOsRel = "ID=reproos\nVERSION_ID=0.1.0\n"
  VectorCmdline = "root=/dev/mapper/reproos ro quiet"
  VectorInitrd = "INITRD-BYTES-FOR-ANCHOR"
  VectorUname = "6.12.0-reproos"
  VectorSbat = "sbat,1,SBAT Version,sbat,1,https://example.invalid\n"

  SystemdMeasurePhases: array[4, (string, string)] = [
    ("enter-initrd",
     "725824feef2736199bf78f0e86a4348b337e07b62445c01678da6a654466b2a7"),
    ("leave-initrd",
     "aede074bf10bf6e9594ee1b280198f3cab7b2c5185fbe047432ff8aed5a3e3fb"),
    ("sysinit",
     "88b0ce3b26b55769da7dd07cbbf36699d8bf7720a9513a780d90631009439026"),
    ("ready",
     "b025c692fbc78781b752267add2e95a366b1b6846042aa67aee20636d5f35a68")]
    ## `systemd-measure calculate` prints PCR 11 for each boot phase in
    ## turn, each one a further extension of the previous with the phase
    ## string. The FIRST of them is our base register extended once, so
    ## the whole list is an independent implementation's opinion about
    ## the base register, stated four times over.

# ---------------------------------------------------------------------
# A synthetic PE32+ image, built here from the specification.
# ---------------------------------------------------------------------

const
  OptionalHeaderSize = 240
  PeOffset = 0x40
  SectionTableAt = PeOffset + 4 + 20 + OptionalHeaderSize
  FileAlignment = 512
  SectionAlignment = 4096

proc putU16(b: var string; at, v: int) =
  b[at] = char(v and 0xFF)
  b[at + 1] = char((v shr 8) and 0xFF)

proc putU32(b: var string; at: int; v: int) =
  for i in 0 ..< 4:
    b[at + i] = char((v shr (8 * i)) and 0xFF)

proc syntheticUki(sections: openArray[(string, string)]): string =
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
  var nextRaw = ((headerRoom + FileAlignment - 1) div FileAlignment) * FileAlignment
  var nextVirtual = SectionAlignment
  for i, (name, content) in sections:
    let at = SectionTableAt + i * 40
    for j in 0 ..< name.len:
      headers[at + j] = name[j]
    let rawSize = ((content.len + FileAlignment - 1) div FileAlignment) * FileAlignment
    putU32(headers, at + 8, content.len)
    putU32(headers, at + 12, nextVirtual)
    putU32(headers, at + 16, rawSize)
    putU32(headers, at + 20, nextRaw)
    putU32(headers, at + 36, 0x40000040)
    var padded = content
    while padded.len < rawSize: padded.add '\0'
    body.add padded
    nextRaw += rawSize
    nextVirtual += ((content.len + SectionAlignment - 1) div SectionAlignment) *
      SectionAlignment
  putU32(headers, opt + 56, nextVirtual)
  var image = headers
  while image.len < ((headerRoom + FileAlignment - 1) div FileAlignment) * FileAlignment:
    image.add '\0'
  image.add body
  image

proc demoUki(cmdline = "root=/dev/mapper/reproos ro quiet"): string =
  ## The file order is DELIBERATELY not the measurement order, and
  ## `.sbat` is written first the way a stub's own section is.
  syntheticUki(@[
    (".sbat", "sbat,1\nreproos,1,ReproOS,reproos,1,https://example.invalid\n"),
    (".osrel", "ID=reproos\nVERSION_ID=0.1.0\n"),
    (".cmdline", cmdline),
    (".uname", "6.12.0-reproos"),
    (".initrd", repeat("I", 3000)),
    (".linux", repeat("K", 9000))])

proc demoManifest(image: string;
                  fingerprint = "reproos-image-v1:a1b2c3"): AttestedImageManifest =
  attestedImageManifest(fingerprint, image,
    DigestPrefix & sha256Hex("a-verity-protected-root-image"),
    sha256Hex("a-verity-root-hash"))

suite "attested-image measurement manifest":

  test "t_manifest_deterministic":
    # Two independent renders of the same image must be the same bytes.
    # Nothing downstream can compare manifests otherwise.
    let image = demoUki()
    let a = renderAttestedImageManifest(demoManifest(image))
    let b = renderAttestedImageManifest(demoManifest(image))
    check a == b

    # ...and "identical" must not be identical-by-not-looking: a
    # one-character change to the command line has to move it.
    let moved = renderAttestedImageManifest(
      demoManifest(demoUki("root=/dev/mapper/reproos ro quiEt")))
    check moved != a

    # The document must survive its own parser byte for byte, or a
    # verifier who reads and re-renders it would see a different image.
    let reparsed = parseAttestedImageManifest(a, "<memory>")
    check renderAttestedImageManifest(reparsed) == a

    # It is really the schema the design names, and it really carries all
    # three backend keys even though only one of them is computed here.
    let doc = parseJson(a)
    check doc["schema"].getStr == "reproos.attested-image.v1"
    for backend in KnownBackends:
      check doc["expected"].hasKey(backend)
    check doc["expected"]["tpm"].len == 1
    check doc["expected"]["sev-snp"].len == 0
    check doc["expected"]["tdx"].len == 0

  test "t_manifest_rejects_unknown_launch_shape":
    let image = demoUki()
    let good = renderAttestedImageManifest(demoManifest(image))

    # 1. An unknown BACKEND, asked for at construction time. This is the
    #    build refusing to emit an expectation nobody can compute — the
    #    refusal has to be here, because after the document is published
    #    it is too late for a verifier to do anything but reject it.
    expect ManifestError:
      discard attestedImageManifest("reproos-image-v1:a1b2c3", image,
        DigestPrefix & sha256Hex("v"), sha256Hex("r"), ["sev-es"])

    # 2. An unknown backend key in a document.
    var doc = parseJson(good)
    doc["expected"]["sev-es"] = newJArray()
    expect ManifestError:
      discard parseAttestedImageManifest($doc, "<mutated>")

    # 3. An unknown field inside a launch shape.
    doc = parseJson(good)
    doc["expected"]["tpm"][0]["pcr12"] = newJString(repeat("0", 64))
    expect ManifestError:
      discard parseAttestedImageManifest($doc, "<mutated>")

    # 4. An unknown top-level field.
    doc = parseJson(good)
    doc["notes"] = newJString("hello")
    expect ManifestError:
      discard parseAttestedImageManifest($doc, "<mutated>")

    # 5. An unknown field inside imageOutputs.
    doc = parseJson(good)
    doc["imageOutputs"]["kernel"] = newJString("sha256:" & repeat("0", 64))
    expect ManifestError:
      discard parseAttestedImageManifest($doc, "<mutated>")

    # 6. A missing required field.
    doc = parseJson(good)
    doc["imageOutputs"].delete("verityRootHash")
    expect ManifestError:
      discard parseAttestedImageManifest($doc, "<mutated>")

    # 7. A different schema version.
    doc = parseJson(good)
    doc["schema"] = newJString("reproos.attested-image.v2")
    expect ManifestError:
      discard parseAttestedImageManifest($doc, "<mutated>")

    # 8. A document that disagrees with itself: the template no longer
    #    replays to the pcr11 beside it. There is no safe way to choose
    #    which half to believe, so neither is believed.
    doc = parseJson(good)
    doc["expected"]["tpm"][0]["pcr11"] = newJString(repeat("a", 64))
    expect ManifestError:
      discard parseAttestedImageManifest($doc, "<mutated>")

    # 9. A template naming a section a stub does not measure. `.pcrsig`
    #    is the signature OVER the measurements, so measuring it would
    #    make the value depend on itself.
    doc = parseJson(good)
    doc["expected"]["tpm"][0]["eventLogTemplate"] =
      newJString(EventLogTemplateId & ";bank=sha256;.pcrsig=" & repeat("0", 64))
    expect ManifestError:
      discard parseAttestedImageManifest($doc, "<mutated>")

    # 10. A template from a measuring agent this build does not know.
    doc = parseJson(good)
    doc["expected"]["tpm"][0]["eventLogTemplate"] =
      newJString("some-other-stub.v9;bank=sha256;.linux=" & repeat("0", 64))
    expect ManifestError:
      discard parseAttestedImageManifest($doc, "<mutated>")

    # 11. A bank this build cannot compute in.
    doc = parseJson(good)
    doc["expected"]["tpm"][0]["eventLogTemplate"] =
      newJString(EventLogTemplateId & ";bank=sha1;.linux=" & repeat("0", 64))
    expect ManifestError:
      discard parseAttestedImageManifest($doc, "<mutated>")

    # 12. An image no single PCR value describes. A multi-profile image
    #     picks its sections at boot, so precomputing one number for it
    #     would be a number that is right for one profile and wrong for
    #     the others.
    expect MeasurementError:
      discard measureUkiPcr11(syntheticUki(@[
        (".linux", "K"), (".profile", "ID=alt\n"), (".cmdline", "quiet")]))

    # 13. And the good document still parses, so the refusals above are
    #     discriminating rather than universal.
    check parseAttestedImageManifest(good, "<good>").tpm.len == 1

  test "t_pcr11_precomputation_matches_measured_boot":
    # (a) Replaying the events of the real boot must produce the register
    #     that real boot reported. This exercises the extend chain, the
    #     name-including-NUL rule and the measured order all at once: get
    #     any of the three wrong and the replay lands somewhere else.
    check replayEventLogTemplate(MeasuredBootTemplate) == MeasuredBootPcr11

    # (b) An independent implementation agrees. systemd's own calculator
    #     reports the `enter-initrd` phase value, which is one further
    #     extension of the boot-time register with the phase string, so
    #     it confirms the boot-time value without ever printing it.
    check extendPcr(MeasuredBootPcr11, sha256Hex("enter-initrd")) ==
      SystemdMeasureEnterInitrd

    # (c) The chain is genuinely order-dependent, so (a) is not something
    #     any permutation would satisfy.
    let parts = MeasuredBootTemplate.split(';')
    let swapped = (parts[0 .. 1] & @[parts[3], parts[2]] & parts[4 .. ^1]).join(";")
    check replayEventLogTemplate(swapped) != MeasuredBootPcr11

    # (d) And the NUL that terminates each measured section name is
    #     load-bearing: dropping it gives a different, plausible, wrong
    #     answer, which is exactly why it cannot be checked by inspection.
    check sectionNameEventDigest(".linux") != sha256Hex(".linux")

    # (e) The calculator reaches the same value from the image bytes as
    #     the template does from the digests, on an image built here.
    let image = demoUki()
    let measured = measureUkiPcr11(image)
    check replayEventLogTemplate(renderEventLogTemplate(measured)) ==
      measured.pcr11

    # (f) The measured order is the stub's, not the file's. The fixture
    #     writes `.sbat` first and `.linux` last; the stub measures
    #     `.linux` first and `.sbat` last.
    var order: seq[string] = @[]
    for e in measured.events: order.add e.section
    check order == @[".linux", ".osrel", ".cmdline", ".initrd", ".uname", ".sbat"]
    var fileOrder: seq[string] = @[]
    for s in readPeSectionTable(image): fileOrder.add s.name
    check fileOrder[0] == ".sbat"
    check order != fileOrder

    # (g) The measured length is VirtualSize, not the file-aligned raw
    #     size. `.cmdline` is 33 bytes in a 512-byte raw slot; measuring
    #     the padding would digest 479 zero bytes that are not in the
    #     image's identity.
    for e in measured.events:
      if e.section == ".cmdline":
        check e.size == "root=/dev/mapper/reproos ro quiet".len
        check e.dataDigest == sha256Hex("root=/dev/mapper/reproos ro quiet")

    # (h) The regenerable third-party vector. A PE assembled here from
    #     the byte strings systemd-measure was given, measured by the
    #     real reader and the real extend chain, must reach the register
    #     systemd's own calculator reached — checked through all four of
    #     the phase values it prints, which pin the base register four
    #     times over. Unlike (a) and (b) this can be re-derived from this
    #     file by anyone with systemd installed; the command is in the
    #     comment above.
    #
    #     The file order is again deliberately not the measurement order.
    let vectorImage = syntheticUki(@[
      (".sbat", VectorSbat),
      (".uname", VectorUname),
      (".osrel", VectorOsRel),
      (".initrd", VectorInitrd),
      (".cmdline", VectorCmdline),
      (".linux", VectorLinux)])
    var vectorPcr = measureUkiPcr11(vectorImage).pcr11
    for (phase, expected) in SystemdMeasurePhases:
      vectorPcr = extendPcr(vectorPcr, sha256Hex(phase))
      check vectorPcr == expected
