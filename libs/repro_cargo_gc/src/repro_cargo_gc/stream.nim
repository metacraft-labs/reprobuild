## Splitting a mixed stdout into cargo's JSON messages and everything else.
##
## `cargo build --message-format=json-render-diagnostics` writes one JSON
## object per line to standard output, each starting with `{"reason":`
## (https://doc.rust-lang.org/cargo/reference/external-tools.html). With
## `cargo test` the same stream also carries the test binaries' own output,
## which cargo lets them write to its standard output. This module separates
## the two WITHOUT buffering what is not cargo's: a recorder (the `repro
## cargo record-live --pass-through` verb, or the cargo shim) diverts the JSON
## lines and forwards every other byte, in order, as soon as it is known not to
## belong to a JSON line.
##
## The rule is deliberately about the first ten bytes of a line, so the
## decision never waits for a newline: the only bytes ever held back are a
## line's leading bytes while they are still a proper prefix of `{"reason":`
## (at most nine), and they are released the moment a byte contradicts the
## prefix, a newline ends the line, or the stream ends. A partial last line
## (no newline) is therefore forwarded as bytes, immediately.
##
## Known limit: a program that writes a line beginning with exactly
## `{"reason":` to a stream cargo also writes to is taken for cargo's, as any
## consumer of `--message-format=json` takes it.

import std/os
when defined(posix):
  import std/posix
import ./[record, types]

const
  CargoMessageMarker* = "{\"reason\":"
    ## What every cargo JSON message starts with.
  ReadChunkBytes* = 64 * 1024

type
  LineMode = enum
    lmUndecided ## at the start of a line, fewer than the marker's bytes seen
    lmPass      ## the line is not cargo's: forward until its newline
    lmJson      ## the line is cargo's: divert until its newline

  StreamSplitter* = object
    mode: LineMode
    held: string ## the bytes of an undecided line seen so far

  ChunkSink* = proc (chunk: string) {.closure.}

proc initStreamSplitter*(): StreamSplitter =
  StreamSplitter(mode: lmUndecided)

proc feed*(s: var StreamSplitter; data: openArray[char];
           pass, divert: ChunkSink) =
  ## Route `data`, the next bytes of the stream, to `pass` (not cargo's) or
  ## `divert` (cargo's JSON). Every byte goes to exactly one of them, in
  ## stream order within each, and nothing but an undecided line's leading
  ## bytes is retained between calls.
  var i = 0
  let n = data.len
  while i < n:
    case s.mode
    of lmPass, lmJson:
      var j = i
      while j < n and data[j] != '\n': inc j
      let ended = j < n
      let stop = if ended: j + 1 else: n
      var piece = newString(stop - i)
      for k in i ..< stop: piece[k - i] = data[k]
      if s.mode == lmPass: pass(piece) else: divert(piece)
      if ended:
        s.mode = lmUndecided
        s.held.setLen 0
      i = stop
    of lmUndecided:
      let c = data[i]
      if s.held.len == 0 and c != CargoMessageMarker[0] and c != '\n':
        # The overwhelmingly common start of a line that is not cargo's.
        s.mode = lmPass
        continue # re-enter in lmPass without consuming
      let candidate = s.held & c
      if candidate.len <= CargoMessageMarker.len and
          candidate == CargoMessageMarker[0 ..< candidate.len]:
        s.held = candidate
        inc i
        if candidate.len == CargoMessageMarker.len:
          divert(s.held)
          s.held.setLen 0
          s.mode = lmJson
      else:
        # The prefix was not cargo's after all (or the line ended): release
        # what was held, with this byte.
        pass(candidate)
        s.held.setLen 0
        inc i
        s.mode = if c == '\n': lmUndecided else: lmPass

proc finish*(s: var StreamSplitter; pass: ChunkSink) =
  ## The stream ended: release a held partial prefix as ordinary output.
  if s.held.len > 0:
    pass(s.held)
    s.held.setLen 0
  s.mode = lmUndecided

type
  LineAssembler* = object
    ## Reassembles diverted chunks into whole lines for the recorder.
    partial: string

proc feed*(a: var LineAssembler; chunk: string; each: proc (line: string)) =
  for c in chunk:
    if c == '\n':
      each(a.partial)
      a.partial.setLen 0
    else:
      a.partial.add c

proc flush*(a: var LineAssembler; each: proc (line: string)) =
  if a.partial.len > 0:
    each(a.partial)
    a.partial.setLen 0

proc readRaw*(f: File; buffer: var string): int =
  ## Read what is available from `f` (at least one byte unless the stream
  ## ended): the bytes the writer has produced so far, not a full buffer. A
  ## buffered `readBuffer` would wait for a whole chunk and stall a stream
  ## that is being forwarded live. Returns 0 at the end of the stream.
  if buffer.len == 0: buffer.setLen ReadChunkBytes
  when defined(posix):
    while true:
      let got = read(cint(getFileHandle(f)), addr buffer[0], buffer.len)
      if got >= 0: return int(got)
      if errno != EINTR: raise newException(IOError, $strerror(errno))
  else:
    readBuffer(f, addr buffer[0], buffer.len)

proc recordLiveSetPassThrough*(targetDir: string; input, output: File;
                               keepSets = DefaultKeepSets): RecordReport =
  ## `recordLiveSetFromStream` for a MIXED stream: cargo's JSON lines go to
  ## the recorder and every other byte of `input` is copied to `output`
  ## unchanged and as it arrives. The live set is stored when the stream
  ## ends. This is the one implementation of the diversion; the cargo shim
  ## runs the same splitter over cargo's pipe.
  var parser = newCargoStreamParser(targetDir)
  var splitter = initStreamSplitter()
  var assembler = LineAssembler()
  let pass: ChunkSink = proc (chunk: string) =
    if chunk.len > 0:
      discard writeBuffer(output, unsafeAddr chunk[0], chunk.len)
      flushFile(output)
  let divert: ChunkSink = proc (chunk: string) =
    assembler.feed(chunk, proc (line: string) = parser.feedLine(line))
  var buffer = newString(ReadChunkBytes)
  while true:
    let got = readRaw(input, buffer)
    if got <= 0: break
    splitter.feed(buffer.toOpenArray(0, got - 1), pass, divert)
  splitter.finish(pass)
  assembler.flush(proc (line: string) = parser.feedLine(line))
  recordFromParser(parser, targetDir, keepSets)
