## The materialisation REPORT, and why a copy fallback must name its cause.
##
## Spec: ``reprobuild-specs/Local-Content-Addressed-Store.md`` §"Hardlink,
## Reflink, and Copy Policy".
##
## WHAT THIS COVERS THAT ITS SIBLING DOES NOT
##
## ``t_win_store_hardlink_cap_falls_back_per_file.nim`` covers the FALLBACK:
## that a file which cannot be linked is copied, per file, and counted. This
## covers the REPORT: that the counts and their causes are rendered in a form
## a consumer can act on, in both the human and the machine shape.
##
## That is a separate property and it is the one a thin overlay depends on.
## A tree composed out of store entries degrades to full byte copies for four
## unrelated reasons — a per-file link cap, a cross-device destination, a
## filesystem with no link arm, and a caller that passed
## ``allowSharedInode = false`` — and ALL FOUR PRODUCE A CORRECT TREE. Nothing
## fails, nothing logs, and the only symptom is size. So the composition's
## only chance to name the cause is at the moment the decision is taken, and
## a renderer that dropped the breakdown would turn every one of those four
## into the same undiagnosable "the overlay is fat".
##
## MOCK POLICY — NO MOCK OBJECTS ARE USED IN THIS FILE. Every case runs the
## production ``materializeDirectory`` against real directories on the real
## filesystem, and the link attempts are real ``link()`` /
## ``CreateHardLinkW`` calls. The ``allowSharedInode = false`` case is not a
## simulation of a degraded filesystem: it is the arm both of the store's own
## callers can select, and on a filesystem where links work it is the only
## remaining way for a composed tree to degrade to copies.

import std/[json, os, strutils, tempfiles, unittest]

import repro_local_store

proc scratchDir(tag: string): string =
  createTempDir("repro-overlay-materialize-" & tag & "-", "")

proc makeSourceTree(dir: string; fileCount: int): seq[string] =
  ## Real files with per-file contents, so a copy that produced the wrong
  ## bytes would be visible rather than merely uncounted.
  createDir(dir / "bin")
  for i in 0 ..< fileCount:
    let path = dir / "bin" / ("f" & $i & ".bin")
    writeFile(path, "payload-" & $i & "-" & repeat("x", 64))
    result.add(path)

suite "overlay materialisation reports its mechanism and its cause":

  test "the link tier is used and the report says so, in both renderings":
    let src = scratchDir("link-src")
    let dst = scratchDir("link-dst") / "out"
    defer:
      removeDir(src)
      removeDir(parentDir(dst))
    discard makeSourceTree(src, 4)

    var report: MaterializeReport
    materializeDirectory(src, dst, report)

    check report.files == 4
    check report.hardlinked == 4
    check report.copied == 0
    check report.describeMechanism() == "hardlink"

    let text = renderMaterializeReportText(report, src, dst)
    check text.contains("mechanism: hardlink")
    check text.contains("files: 4")
    check text.contains("hardlinked: 4")
    check text.contains("copied: 0")
    # A zero-valued cause is omitted rather than printed: the text rendering
    # exists to be read, and four "0" lines on every successful
    # materialisation are how the one non-zero line gets scrolled past.
    check not text.contains("fallback shared-inode-arm-disabled")

    let doc = parseJson(renderMaterializeReportJson(report, src, dst))
    check doc["schema"].getStr() == "reprobuild.store-materialize.v1"
    check doc["mechanism"].getStr() == "hardlink"
    check doc["files"].getInt() == 4
    check doc["hardlinked"].getInt() == 4
    check doc["copied"].getInt() == 0
    check doc["hardlink_available"].getBool()
    # Every cause is present in the JSON even at zero, unlike the text: a
    # consumer summing causes across entries must not have to distinguish
    # "absent" from "zero", and a missing key is how that distinction gets
    # made accidentally.
    for cause in ["per-file-link-cap", "cross-device", "unsupported",
                  "shared-inode-arm-disabled", "other"]:
      check doc["fallback_reasons"].hasKey(cause)
      check doc["fallback_reasons"][cause].getInt() == 0

  test "THE SILENT HAZARD: the shared-inode arm off is a copy, and it is named":
    ## The negative control for the case above. The output is
    ## byte-identical, nothing errors, and the ONLY difference from a
    ## hardlink materialisation is the size on disk — so the report is the
    ## only thing that can tell the two apart.
    let src = scratchDir("nolink-src")
    let dst = scratchDir("nolink-dst") / "out"
    defer:
      removeDir(src)
      removeDir(parentDir(dst))
    let sources = makeSourceTree(src, 4)

    var report: MaterializeReport
    materializeDirectory(src, dst, report, allowSharedInode = false)

    check report.files == 4
    check report.hardlinked == 0
    check report.copied == 4
    check report.describeMechanism() == "copy"
    check report.reasons[mfrArmDisabled] == 4
    # NOT a per-file fallback: the arm being off is a property of the CALLER,
    # not of any one blob, and conflating the two would make a deliberate
    # policy look like 4 files at their link cap.
    check report.perFileFallbacks == 0

    # The bytes are right. That is the hazard, stated as an assertion rather
    # than as a comment.
    for source in sources:
      let rel = source[(src.len + 1) .. ^1]
      check readFile(dst / rel) == readFile(source)

    let text = renderMaterializeReportText(report, src, dst)
    check text.contains("mechanism: copy")
    check text.contains("fallback shared-inode-arm-disabled: 4")
    check text.contains("hardlink available: yes")
    check text.contains("diagnostic: ")

    let doc = parseJson(renderMaterializeReportJson(report, src, dst))
    check doc["mechanism"].getStr() == "copy"
    check doc["copied"].getInt() == 4
    check doc["fallback_reasons"]["shared-inode-arm-disabled"].getInt() == 4
    # The pair CAN link. Reporting that alongside the copy is what turns
    # "the overlay is fat" into "the overlay is fat because this caller
    # declined the arm", which is a different bug report.
    check doc["hardlink_available"].getBool()
    check doc["diagnostic"].getStr().len > 0

  test "the JSON survives a source path that would break a naive encoder":
    ## The report carries filesystem paths, and a machine-readable report
    ## that a quote or a backslash can corrupt is one a Windows path
    ## corrupts — every one of which contains backslashes.
    let src = scratchDir("quote-src")
    let dst = scratchDir("quote-dst") / "out"
    defer:
      removeDir(src)
      removeDir(parentDir(dst))
    discard makeSourceTree(src, 1)

    var report: MaterializeReport
    materializeDirectory(src, dst, report)
    let awkward = "C:\\dev-deps\\a \"b\"\\c"
    let doc = parseJson(renderMaterializeReportJson(report, awkward, dst))
    check doc["source"].getStr() == awkward

  test "a missing source is an error, not an empty success":
    ## A materialisation that silently reported zero files for a source that
    ## does not exist would let a composer record "composed" for an entry it
    ## never placed, and the in-job fallback would never fire.
    let dst = scratchDir("missing-dst") / "out"
    defer: removeDir(parentDir(dst))
    var report: MaterializeReport
    expect StoreError:
      materializeDirectory(dst / "no-such-source", dst, report)
