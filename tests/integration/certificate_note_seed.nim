## Putting a certificate note in a test repository's local notes ref, for tests
## about what READS notes: the gateway, ``repro ci plan``, the reader itself.
##
## Reprobuild writes no notes. A test about how notes get to a remote goes
## through the real flow instead (``certificate_push_fixture``). The tests here
## need states that flow does not make, such as a record on the wrong tree or a
## note on a commit nothing certified, so they write the note directly. The
## framing and the writer rule are the reference library's
## (``test_certificates/note_framing``), which is what the real flow runs, and
## only the two git commands that attach the blob are spelled out.
##
## ``import``ed, not a registered test.

import std/[os, osproc, strutils]

import repro_cli_support
from test_certificates/note_framing as tcframing import nil

proc certificateNoteRecord*(cert: TestCertificate): string =
  ## One record in note form (Transport §3.1): the canonical payload, then, only
  ## when signed, one blank line and the signature table.
  result = canonicalCertificatePayload(cert)
  if cert.isSigned:
    # Base64 and algorithm names hold nothing TOML would escape.
    for value in [cert.signature.algorithm, cert.signature.value]:
      doAssert '"' notin value and '\\' notin value and '\n' notin value, value
    result.add("\n[certificate.signature]\nalgorithm = \"" &
      cert.signature.algorithm & "\"\nvalue = \"" & cert.signature.value &
      "\"\n")

proc addCertificateToNote*(note: string; cert: TestCertificate):
    tuple[note: string; changed: bool] =
  ## The library's relay writer rule on a note blob (Transport §3.1).
  let incoming = tcframing.recordPiece(certificateNoteRecord(cert))
  doAssert incoming.kind == tcframing.pkRecord, incoming.problem
  var pieces = tcframing.splitNote(note)
  if tcframing.addRecord(pieces, incoming) == tcframing.aoPresent:
    return (note, false)
  let updated = tcframing.renderNote(pieces)
  (updated, updated != note)

type
  NoteMergeReportKind* = enum
    ## The report categories Transport §3.1 requires of a merge (the
    ## ``expected.json`` categories of the ``notes/merge-*`` vectors).
    nmrSignedConflict = "signed-conflict"
      ## Both sides carry differently signed copies of one payload; the
      ## published (base) copy was kept.
    nmrLeadingJoined = "leading-joined"
      ## Both sides carry different text before the first delimiter; the
      ## incoming block was joined after the published one.
    nmrLfRepair = "lf-repair"
      ## One LF was supplied so that a following delimiter stays on its own
      ## line.
    nmrOther = "other"
      ## A remark the pinned library makes that maps to none of the above.

  NoteMergeReport* = object
    kind*: NoteMergeReportKind
    message*: string

  CertificateNoteMerge* = object
    ## The union of two note blobs for the same object.
    note*: string          ## the merged blob
    changed*: bool         ## ``note`` differs from the published blob
    reports*: seq[NoteMergeReport]

proc noteMergeReportKind*(remark: string): NoteMergeReportKind =
  ## The §3.1 category of one of the library's merge remarks. Matched on the
  ## remark's wording, which the PINNED library fixes; the conformance walker
  ## asserts every ``merge-*`` vector's categories through this function, so
  ## a library bump that rewords a remark fails there.
  if "published copy was kept" in remark: nmrSignedConflict
  elif "text before the first delimiter" in remark: nmrLeadingJoined
  elif "LF" in remark: nmrLfRepair
  else: nmrOther

proc mergeCertificateNotes*(published, incoming: string): CertificateNoteMerge =
  ## The library's merge of two notes (Transport §3.1), with its remarks in the
  ## categories the conformance vectors state.
  let merged = tcframing.mergeNotes(published, incoming)
  result = CertificateNoteMerge(note: merged.blob, changed: merged.changed)
  for remark in merged.remarks:
    result.reports.add(NoteMergeReport(kind: noteMergeReportKind(remark),
      message: remark))

proc gitQuiet(gitBin, repo: string; args: openArray[string]):
    tuple[code: int; output: string] =
  let run = execCmdEx(quoteShellCommand(@[gitBin, "-C", repo] & @args))
  (run.exitCode, run.output)

proc seedCertificateRecord*(gitBin, repo, annotated: string;
                            cert: TestCertificate):
    tuple[ok: bool; diagnostic: string] =
  ## Add ``cert`` to the note on ``annotated``, which may be any object id:
  ## nothing checks that the certificate names it, so a test can misattach one.
  ## ``notes add -C`` keeps the blob's bytes, which ``-m`` and ``-F`` would not.
  let current = readNoteBlob(gitBin, repo, annotated, certificateNotesRef)
  if current.status == gorUnreadable:
    return (false, current.diagnostic)
  let added = addCertificateToNote(current.body, cert)
  if not added.changed:
    return (true, "")
  let file = repo / ".git" / "seed-certificate-note"
  writeFile(file, added.note)
  defer: removeFile(file)
  let blob = gitQuiet(gitBin, repo, ["hash-object", "-w", "--", file])
  if blob.code != 0:
    return (false, blob.output)
  let attached = gitQuiet(gitBin, repo, ["notes", "--ref", certificateNotesRef,
    "add", "-f", "-C", blob.output.strip(), annotated])
  (attached.code == 0, attached.output)

proc seedCertificateNote*(gitBin, repo: string; cert: TestCertificate):
    tuple[ok: bool; diagnostic: string] =
  ## Add ``cert`` to the note on the tree its content names, where a verifier
  ## looks. The tree object need not exist in ``repo``.
  let key = certificateNoteKey(cert.vcs.content)
  if not key.ok:
    return (false, key.problem)
  seedCertificateRecord(gitBin, repo, key.oid, cert)
