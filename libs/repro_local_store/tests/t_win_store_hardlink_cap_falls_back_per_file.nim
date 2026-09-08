## The prefix materialiser's PER-FILE fallback, and the 1023-link cap.
##
## Spec: ``reprobuild-specs/Local-Content-Addressed-Store.md`` §"Hardlink,
## Reflink, and Copy Policy" (normative preference order; per-file limits are
## not pair capabilities).
##
## WHY THIS TEST IS ABOUT ``materializeDirectory`` AND NOT ``casMaterialize``
##
## The per-file cap fallback was already implemented and already tested on the
## CAS facade's two directions — ``casPutPath`` on the way in and
## ``casMaterialize`` on the way out, both of which go through
## ``link_capability``'s attempt-and-classify machinery
## (``libs/repro_cas_store/tests/t_cas_ingest_link.nim``,
## ``t_cas_materialize_link.nim``).
##
## ``materializeDirectory`` is the third path and it had none of it. It is the
## one that builds a PREFIX — ``realizeDirectoryAsPrefix`` and
## ``realizeMultiOutput`` both call it — which is what a toolchain store entry
## and the overlay over it actually are. Before this change it was a bare
## ``try: createHardlink except OSError, IOError: copyFile``, which cannot
## distinguish a blob at its link cap from a cross-volume destination from a
## permission error, reported nothing per file, and consulted no capability at
## all. A copy fallback that is only visible as a SIZE is a fallback
## discovered by an overlay being fat, which is late and gives no cause.
##
## THE SEAM, AND WHY IT IS NOT A MOCK
##
## MOCK POLICY — NO MOCK OBJECTS ARE USED IN THIS FILE. Every case runs the
## production ``materializeDirectory`` against real directories on the real
## filesystem, and the link attempts are real ``link()`` / ``CreateHardLinkW``
## calls.
##
## ONE case uses ``materializeLinkAttemptHook``, the store's documented test
## seam, and the justification is the same shape as the one
## ``casIngestRaceWindowHook`` already carries: **the 1023-link cap is a
## property of NTFS and is unreachable anywhere else.** ext4 permits 65 000
## links, so driving a real inode to the cap on this host would not reach it,
## and a case that only ran on Windows would leave the fallback unexercised on
## every other platform. The seam turns "this one file is at its cap" into a
## deterministic input. It substitutes an ERROR CODE, not a collaborator: the
## copy that follows, the counting, the capability cache and the destination
## bytes are all the production code doing the real thing.
##
## And the seam does not carry the whole claim. The case immediately after it
## materialises one real entry into **more than 1023 real destinations** on
## the real filesystem, so "the loop is per file" and "the cached capability
## survives" are measured against the operating system.

import std/[os, sequtils, strutils, tempfiles, unittest]

from repro_core/paths import extendedPath

import repro_local_store

proc scratchDir(tag: string): string =
  createTempDir("repro-win-store-linkcap-" & tag & "-", "")

proc makeSourceTree(dir: string; fileCount: int): seq[string] =
  ## A real directory of real files. Contents differ per file so a copy
  ## that produced the wrong bytes would be visible.
  createDir(extendedPath(dir))
  for i in 0 ..< fileCount:
    let name = "f" & $i & ".bin"
    writeFile(dir / name, "payload-" & $i & "-" & repeat('x', 64))
    result.add(name)

suite "prefix materialisation falls back per FILE, not per filesystem":

  test "an ordinary materialisation links every file and reports no fallback":
    ## The baseline the other cases are read against. Without it, a
    ## materialiser that copied everything would satisfy "the bytes are
    ## right" in every case below and nothing would notice.
    let dir = scratchDir("baseline")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard

    let src = dir / "src"
    let dst = dir / "dst"
    let names = makeSourceTree(src, 8)

    var report: MaterializeReport
    materializeDirectory(src, dst, report)

    checkpoint("files=" & $report.files & " hardlinked=" & $report.hardlinked &
      " copied=" & $report.copied & " probed=" & $report.capabilityProbed &
      " hardlinkAvailable=" & $report.hardlinkAvailable &
      " diagnostic=" & report.diagnostic)

    check report.files == names.len
    check report.perFileFallbacks == 0
    for name in names:
      check readFile(dst / name) == readFile(src / name)

    if report.hardlinkAvailable:
      # On a host whose temp volume supports hardlinks, EVERY file must be
      # linked. "mixed" here would mean something fell back without saying
      # why, which is the condition this whole change exists to remove.
      check report.hardlinked == names.len
      check report.copied == 0
      check report.describeMechanism() == "hardlink"
    else:
      # A host that cannot link must say so rather than passing silently.
      checkpoint("this host's temp volume offers no hardlink arm; the link " &
                 "assertions were not exercised")
      check report.diagnostic.len > 0

  test "the shared-inode arm can be declined, and declining it is REPORTED":
    ## The spec asks that the hardlink arm be turned on or off deliberately
    ## rather than inherited from a default nobody read. Both halves are
    ## asserted: the default reaches the arm, and a caller that declines it
    ## gets copies AND a diagnostic saying that is why.
    let dir = scratchDir("arm")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard

    let src = dir / "src"
    discard makeSourceTree(src, 4)

    var defaultReport: MaterializeReport
    materializeDirectory(src, dir / "dst-default", defaultReport)

    var declinedReport: MaterializeReport
    materializeDirectory(src, dir / "dst-declined", declinedReport,
                         allowSharedInode = false)

    check declinedReport.files == 4
    check declinedReport.hardlinked == 0
    check declinedReport.copied == 4
    check declinedReport.describeMechanism() == "copy"
    # The reason must be legible. "It copied" with no reason is the log line
    # that makes a misconfigured store look like a working one.
    checkpoint("declined diagnostic: " & declinedReport.diagnostic)

    if defaultReport.hardlinkAvailable:
      check defaultReport.hardlinked == 4
      check declinedReport.diagnostic.contains("disabled")
      check declinedReport.reasons[mfrArmDisabled] == 4
      # ...and the DEFAULT is the opposite, which is the half that says the
      # policy was chosen for this direction rather than copied from the
      # ingest side, where the same flag defaults the other way.
      check PrefixMaterializeAllowSharedInodeDefault
      check not CasIngestAllowSharedInodeDefault
    else:
      checkpoint("no hardlink arm on this host; the contrast between the " &
                 "two calls could not be exercised")

    # Whichever arm ran, the bytes are right.
    for name in @["f0.bin", "f1.bin", "f2.bin", "f3.bin"]:
      check readFile(dir / "dst-declined" / name) == readFile(src / name)

  test "a file at its per-file link cap falls back to copy for THAT FILE only":
    ## The 1023-cap case. Driven through the documented test seam because
    ## the cap is an NTFS property (see this file's header); the injected
    ## value is the error code NTFS would return, and everything downstream
    ## of it is production code.
    let dir = scratchDir("cap")
    defer:
      materializeLinkAttemptHook = nil
      try: removeDir(extendedPath(dir)) except OSError: discard

    let src = dir / "src"
    let dst = dir / "dst"
    let names = makeSourceTree(src, 6)
    let cappedName = names[2]

    var probe: MaterializeReport
    materializeDirectory(src, dir / "probe", probe)
    if not probe.hardlinkAvailable:
      checkpoint("this host's temp volume offers no hardlink arm, so there " &
                 "is no link attempt for the cap to interrupt; case NOT " &
                 "exercised")
      check probe.files == names.len
    else:
      # The cached pair capability BEFORE the capped materialisation, so the
      # "not invalidated" assertion below has a before as well as an after.
      # The destination has to exist to be probed -- a probe of a missing
      # directory resolves nothing and is not cached, which would make both
      # sides of the before/after comparison vacuous.
      createDir(extendedPath(dst))
      var beforeCache: LinkCapabilityCache
      check probeLinkCapabilities(beforeCache, src, dst).hardlink

      var injected = 0
      materializeLinkAttemptHook = proc (s, d: string): LinkAttempt =
        if lastPathPart(s) == cappedName:
          injected.inc
          return LinkAttempt(outcome: loLinkLimitExceeded, errorCode: 1142,
                             message: "CreateHardLinkW failed with ERROR_TOO_MANY_LINKS")
        LinkAttempt(outcome: loOk)

      var report: MaterializeReport
      materializeDirectory(src, dst, report)
      materializeLinkAttemptHook = nil

      check injected == 1
      check report.files == names.len

      # THE CLAIM: one file copied, every other file linked.
      check report.copied == 1
      check report.hardlinked == names.len - 1
      check report.perFileFallbacks == 1
      check report.reasons[mfrLinkLimit] == 1
      check report.describeMechanism() == "mixed"

      # It is OBSERVABLE, which is the half a size measurement cannot give.
      check report.reasons[mfrCrossDevice] == 0
      check report.reasons[mfrUnsupported] == 0

      # The bytes are right in both arms.
      for name in names:
        check readFile(dst / name) == readFile(src / name)

      # And the cached pair capability is NOT invalidated. A per-file limit
      # says nothing about the filesystem, and treating it as a verdict would
      # turn every later file into a copy because one file was popular.
      var afterCache: LinkCapabilityCache
      check probeLinkCapabilities(afterCache, src, dst).hardlink
      check report.hardlinkAvailable

  test "the same materialisation without the cap links every file (control)":
    ## NEGATIVE CONTROL for the case above, and it is required: without it,
    ## "one file copied" would also be satisfied by a materialiser that
    ## copied one arbitrary file every time, and by a hook that was never
    ## consulted at all.
    let dir = scratchDir("cap-control")
    defer:
      materializeLinkAttemptHook = nil
      try: removeDir(extendedPath(dir)) except OSError: discard

    let src = dir / "src"
    let dst = dir / "dst"
    let names = makeSourceTree(src, 6)

    var report: MaterializeReport
    materializeDirectory(src, dst, report)

    check report.files == names.len
    check report.perFileFallbacks == 0
    check report.reasons[mfrLinkLimit] == 0
    if report.hardlinkAvailable:
      check report.copied == 0
      check report.hardlinked == names.len

  test "one entry materialised into more than 1023 destinations, for real":
    ## The half the seam does not cover. No injection here: the loop, the
    ## link count and the capability cache are exercised against the real
    ## operating system across a link population that EXCEEDS the NTFS cap.
    ##
    ## On NTFS this crosses the cap and the store must degrade per file
    ## without failing. On a filesystem with a higher ceiling it does not
    ## cross it, and what is measured instead is that 1024 successive
    ## materialisations of one entry neither fail nor silently stop linking
    ## — which is the property the cap handling must not break.
    let dir = scratchDir("many")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard

    let src = dir / "src"
    createDir(extendedPath(src))
    writeFile(src / "shared.bin", "one blob, many names")

    const Destinations = 1100
    var hardlinkTotal = 0
    var copyTotal = 0
    var perFileFallbackTotal = 0
    var firstFallbackAt = -1

    for i in 0 ..< Destinations:
      var report: MaterializeReport
      materializeDirectory(src, dir / "dst" / $i, report)
      hardlinkTotal += report.hardlinked
      copyTotal += report.copied
      perFileFallbackTotal += report.perFileFallbacks
      if report.perFileFallbacks > 0 and firstFallbackAt < 0:
        firstFallbackAt = i
      # Whatever arm was taken, the bytes are right. Checked every time
      # rather than once at the end, because "it stopped being correct at
      # destination 1024" is precisely the failure being looked for.
      check readFile(dir / "dst" / $i / "shared.bin") == "one blob, many names"

    checkpoint("destinations=" & $Destinations & " hardlinked=" &
      $hardlinkTotal & " copied=" & $copyTotal & " perFileFallbacks=" &
      $perFileFallbackTotal & " firstFallbackAt=" & $firstFallbackAt &
      " observedLinkCount=" & $hardlinkCount(src / "shared.bin"))

    check hardlinkTotal + copyTotal == Destinations

    # The capability must have survived the whole population.
    var cache: LinkCapabilityCache
    let cap = probeLinkCapabilities(cache, src, dir / "dst")
    if cap.hardlink:
      check hardlinkTotal > 0
      # A per-file fallback is allowed (and expected on NTFS past 1023); a
      # PAIR-level collapse is not. Either every destination linked, or the
      # ones that did not are accounted for as per-file fallbacks.
      check copyTotal == perFileFallbackTotal
    else:
      checkpoint("no hardlink arm on this host; every destination was a " &
                 "copy, which is correct but does not exercise the cap")
      check copyTotal == Destinations

  test "a per-file CROSS-DEVICE refusal is not counted as a per-file cap":
    ## The discrimination itself: two failures arrive through the SAME code
    ## path -- an attempt that did not return ``loOk`` -- and only one of
    ## them is a property of the file. ``isPerFileFallback`` is what
    ## separates them, and conflating the two is how a misconfigured store
    ## reads as a popular blob.
    ##
    ## WHY THIS CASE EXISTS IN THIS SHAPE. It was first written against a
    ## real second filesystem (``/dev/shm``), and mutation testing showed
    ## that control COULD NOT FAIL: a genuinely cross-volume pair is refused
    ## by the capability PROBE, so ``materializeDirectory`` never reaches the
    ## per-file attempt branch and ``perFileFallbacks`` is trivially zero
    ## whatever the classification code does. Asserting zero there measured
    ## nothing. The real-volume case is kept below, with its assertions
    ## limited to what it can actually witness; the discrimination is tested
    ## here, on a pair the probe accepts, so the attempt branch really runs.
    let dir = scratchDir("xdev-perfile")
    defer:
      materializeLinkAttemptHook = nil
      try: removeDir(extendedPath(dir)) except OSError: discard

    let src = dir / "src"
    let dst = dir / "dst"
    let names = makeSourceTree(src, 4)

    var probe: MaterializeReport
    materializeDirectory(src, dir / "probe", probe)
    if not probe.hardlinkAvailable:
      checkpoint("no hardlink arm on this host, so the attempt branch " &
                 "cannot be reached; case NOT exercised")
      check probe.files == names.len
    else:
      materializeLinkAttemptHook = proc (s, d: string): LinkAttempt =
        if lastPathPart(s) == names[0]:
          return LinkAttempt(outcome: loCrossDevice, errorCode: 17,
                             message: "link() failed with errno 17")
        if lastPathPart(s) == names[1]:
          return LinkAttempt(outcome: loLinkLimitExceeded, errorCode: 1142,
                             message: "CreateHardLinkW failed with ERROR_TOO_MANY_LINKS")
        LinkAttempt(outcome: loOk)

      var report: MaterializeReport
      materializeDirectory(src, dst, report)
      materializeLinkAttemptHook = nil

      checkpoint("report: hardlinked=" & $report.hardlinked & " copied=" &
        $report.copied & " perFileFallbacks=" & $report.perFileFallbacks &
        " crossDevice=" & $report.reasons[mfrCrossDevice] & " linkLimit=" &
        $report.reasons[mfrLinkLimit])

      # Both files fell back, and both are copies with the right bytes...
      check report.copied == 2
      check report.hardlinked == names.len - 2
      # ...but only ONE of them is a per-file fallback.
      check report.perFileFallbacks == 1
      check report.reasons[mfrLinkLimit] == 1
      check report.reasons[mfrCrossDevice] == 1
      for name in names:
        check readFile(dst / name) == readFile(src / name)

  test "a genuinely cross-volume destination is refused by the PROBE":
    ## The real-volume half, with assertions limited to what it can witness.
    ## A cross-volume pair never reaches the per-file attempt branch, so
    ## what this measures is that the probe declines it, that every file is
    ## nonetheless materialised correctly by copy, and that the report says
    ## WHY rather than leaving "it copied" unexplained.
    let dir = scratchDir("xdev")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard

    let src = dir / "src"
    discard makeSourceTree(src, 3)

    # /dev/shm is a different filesystem from the default temp dir on
    # essentially every Linux host, which is what makes this reachable
    # without mounting anything.
    var otherFs = ""
    when defined(linux):
      if dirExists("/dev/shm"):
        otherFs = "/dev/shm"
    if otherFs.len == 0:
      checkpoint("no second filesystem available on this host; the " &
                 "cross-volume arm was NOT exercised")
      check dirExists(extendedPath(src))
    else:
      let dst = otherFs / ("repro-xdev-" & $getCurrentProcessId())
      defer:
        try: removeDir(extendedPath(dst)) except OSError: discard
      var report: MaterializeReport
      materializeDirectory(src, dst, report)
      checkpoint("cross-volume report: hardlinked=" & $report.hardlinked &
        " copied=" & $report.copied & " probed=" & $report.capabilityProbed &
        " hardlinkAvailable=" & $report.hardlinkAvailable &
        " diagnostic=" & report.diagnostic)
      check report.copied == 3
      check report.hardlinked == 0
      check not report.hardlinkAvailable
      # The reason is legible. This is the assertion that has teeth here:
      # the pre-change implementation copied for exactly this reason and
      # said nothing at all.
      check report.diagnostic.len > 0
      for name in @["f0.bin", "f1.bin", "f2.bin"]:
        check readFile(dst / name) == readFile(src / name)
