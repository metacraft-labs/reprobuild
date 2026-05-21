import std/[json, streams, strutils]

import repro_hcr_agent/protocol
import repro_hcr_agent/session

type
  HcrProtocolTranscriptEntry* = object
    direction*: HcrMessageDirection
    rawFrame*: string
    message*: HcrAgentMessage

proc readAsciiLine(stream: Stream): string =
  while true:
    if stream.atEnd:
      raise newException(IOError,
        "unexpected EOF while reading HCR protocol line")
    let ch = stream.readChar()
    if ch == '\n':
      if result.len > 0 and result[^1] == '\r':
        result.setLen(result.len - 1)
      return
    result.add ch

proc readExactString(stream: Stream; byteCount: int): string =
  if byteCount < 0:
    raise newException(ValueError, "negative HCR frame length")
  result = newString(byteCount)
  for index in 0 ..< byteCount:
    if stream.atEnd:
      raise newException(IOError,
        "unexpected EOF while reading HCR protocol body")
    result[index] = stream.readChar()

proc parseContentLength(line: string): int =
  const prefix = "content-length:"
  if not line.toLowerAscii().startsWith(prefix):
    raise newException(ValueError,
      "missing Content-Length header in HCR protocol frame")
  parseInt(line[prefix.len .. ^1].strip())

proc readAgentFrame*(stream: Stream): string =
  let firstHeader = stream.readAsciiLine()
  let contentLength = parseContentLength(firstHeader)

  var headers = @[firstHeader]
  while true:
    let line = stream.readAsciiLine()
    if line.len == 0:
      break
    headers.add line

  let body = stream.readExactString(contentLength)
  headers.join("\r\n") & "\r\n\r\n" & body

proc readAgentMessageWithFrame*(stream: Stream):
    tuple[frame: string, message: HcrAgentMessage] =
  let frame = stream.readAgentFrame()
  let separator = "\r\n\r\n"
  let splitAt = frame.find(separator)
  if splitAt < 0:
    raise newException(ValueError, "missing HCR protocol frame separator")
  let body = frame[splitAt + separator.len .. ^1]
  (frame, parseAgentMessage(parseJson(body)))

proc readAgentMessage*(stream: Stream): HcrAgentMessage =
  stream.readAgentMessageWithFrame().message

proc writeAgentMessage*(stream: Stream; message: HcrAgentMessage): string =
  result = frameAgentMessage(message)
  stream.write(result)
  stream.flush()

proc transcriptEntry*(direction: HcrMessageDirection; rawFrame: string;
                      message: HcrAgentMessage): HcrProtocolTranscriptEntry =
  HcrProtocolTranscriptEntry(
    direction: direction,
    rawFrame: rawFrame,
    message: message)
