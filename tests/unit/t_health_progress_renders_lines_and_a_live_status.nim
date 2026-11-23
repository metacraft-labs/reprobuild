## ``repro health``'s progress writer (``repro_cli_support/health_progress``)
## renders the same events two ways:
##
## * off a terminal, one prefixed line per event, each complete with its
##   newline, so a run killed in the middle leaves the row and the checkout
##   it was in as its last line;
## * on a terminal, one status line rewritten in place (CR + erase-line), cut
##   to the terminal's width so it never wraps, and erased by ``finish`` so
##   the report that follows starts on a clean line.
##
## A ``nil`` writer is silent and must accept every call, because the
## gatherer calls it unconditionally.
##
## The sink here collects what would have been written to stderr: what is
## under test is the text the writer produces, and the binary-level test
## (``t_health_names_the_row_and_checkout_it_is_in.nim``) checks that the
## production command routes it to stderr.

import std/[strutils, unittest]

import repro_cli_support/health_progress

proc collector(): tuple[sink: HealthProgressSink; written: ref seq[string]] =
  let written = new(seq[string])
  (sink: proc (text: string) = written[].add(text), written: written)

suite "health progress":

  test "off a terminal every event is its own prefixed line":
    let (sink, written) = collector()
    let progress = newHealthProgress(sink, hpmLines)
    progress.beginRow("unpublished-heads")
    progress.beginItem("reprobuild/references/llvm-project", 87, 119)
    progress.beginRow("disjoint-local-branches")
    progress.finish()
    check written[] == @[
      "repro health: checking unpublished-heads\n",
      "repro health: unpublished-heads: " &
        "reprobuild/references/llvm-project (87/119)\n",
      "repro health: checking disjoint-local-branches\n"]
    # Nothing to take back in line mode.
    check written[].len == 3

  test "on a terminal one status line is rewritten, cut to width, and erased":
    let (sink, written) = collector()
    let progress = newHealthProgress(sink, hpmLive, width = 40)
    progress.beginRow("vcs-hooks")
    progress.beginItem("a/very/long/path/to/a/checkout/deep/inside", 3, 9)
    progress.finish()
    check written[].len == 3
    for text in written[0 .. 1]:
      check text.startsWith("\r\e[K" & ProgressPrefix)
      check '\n' notin text
      # Never as wide as the terminal: a full-width line wraps on some
      # terminals, and CR then rewrites only its last row.
      check text.len - "\r\e[K".len <= 39
    check written[0] == "\r\e[Krepro health: checking vcs-hooks"
    check written[1].endsWith("...")
    check written[2] == "\r\e[K"

  test "finish erases nothing when nothing was shown":
    let (sink, written) = collector()
    newHealthProgress(sink, hpmLive).finish()
    check written[].len == 0

  test "a nil writer is silent and accepts every call":
    let progress: HealthProgress = nil
    progress.beginRow("manifest")
    progress.beginItem("lib-a", 1, 1)
    progress.finish()
    check progress.isNil
