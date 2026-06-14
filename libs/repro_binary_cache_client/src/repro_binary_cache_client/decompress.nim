## ReproOS-Generations-And-Foreign-Packages A2.5 — streaming decompress.
##
## A streaming-decompress sink that sits inside the payload sink chain.
## Bytes arrive in arbitrary-sized chunks; we surface decompressed
## bytes through ``onChunk`` as soon as we have them. The decompressor
## carries its own state across ``feed`` calls — there is no
## "decompress this whole buffer" entry point because that would
## defeat the streaming design.
##
## ## v1 scope: ckNone + ckZstd
##
## ``ckNone`` is the identity passthrough — every received byte is
## forwarded verbatim. This is the path A2's payload format takes
## today (the server stores raw bytes in the CAS; ``PayloadObject.
## compression`` is metadata for future codec negotiation).
##
## ``ckZstd`` plugs into libzstd's streaming decode API
## (``ZSTD_decompressStream``). The bindings are kept local + minimal:
## one shared library, one struct, three procs. Build callers must
## ``passC:"-DZSTD_STATIC_LINKING_ONLY"`` and ``passL:"-lzstd"`` when
## requesting zstd payloads.
##
## ``ckXz`` is documented as a follow-up; A2's R5 toolchain payloads
## use zstd by default (matches modern Nix, R5 vendor policy).
##
## ## Library availability
##
## On Linux + WSL, ``libzstd.so.1`` is universally present (it's a
## dependency of dpkg/rpm/systemd on every modern distro). On Windows
## scoop ships zstd as part of the standard dev toolchain; if it
## isn't on PATH the decompressor raises ``DecompressUnavailable``
## and the caller falls back to a ``ckNone`` payload. The library is
## loaded lazily via ``dynlib:`` so a build that never requests a
## ``ckZstd`` payload doesn't need libzstd installed.

import std/[strutils]

import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types

type
  DecompressError* = object of CatchableError
  DecompressUnavailable* = object of DecompressError
    ## Raised when the requested codec's runtime library isn't
    ## present. The client falls back to ``ckNone`` payloads or
    ## reports a soft error so the engine builds locally.

  ChunkSink* = proc(data: openArray[byte]) {.gcsafe.}

  Decompressor* = ref object
    kind*: CompressionKind
    bytesIn*: int64
    bytesOut*: int64
    case impl*: CompressionKind
    of ckNone:
      discard
    of ckZstd:
      zstdDStream: pointer
      zstdOutBuf: seq[byte]
    of ckXz:
      discard

# ---------------------------------------------------------------------------
# libzstd thin binding — loaded lazily via dynlib
# ---------------------------------------------------------------------------

const
  ZstdDynLib =
    when defined(windows): "libzstd.dll"
    elif defined(macosx): "libzstd.1.dylib"
    else: "libzstd.so.1"

type
  ZSTD_inBuffer = object
    src: pointer
    size: csize_t
    pos: csize_t

  ZSTD_outBuffer = object
    dst: pointer
    size: csize_t
    pos: csize_t

proc ZSTD_createDStream(): pointer {.cdecl, importc, dynlib: ZstdDynLib.}
proc ZSTD_freeDStream(d: pointer): csize_t {.cdecl, importc, dynlib: ZstdDynLib.}
proc ZSTD_initDStream(d: pointer): csize_t {.cdecl, importc, dynlib: ZstdDynLib.}
proc ZSTD_decompressStream(d: pointer; outBuf: ptr ZSTD_outBuffer;
                            inBuf: ptr ZSTD_inBuffer): csize_t {.
  cdecl, importc, dynlib: ZstdDynLib.}
proc ZSTD_isError(code: csize_t): cuint {.cdecl, importc, dynlib: ZstdDynLib.}
proc ZSTD_getErrorName(code: csize_t): cstring {.cdecl, importc, dynlib: ZstdDynLib.}
proc ZSTD_DStreamOutSize(): csize_t {.cdecl, importc, dynlib: ZstdDynLib.}

# ---------------------------------------------------------------------------
# Constructor / destructor
# ---------------------------------------------------------------------------

proc newDecompressor*(kind: CompressionKind): Decompressor =
  case kind
  of ckNone:
    result = Decompressor(kind: ckNone, impl: ckNone)
  of ckZstd:
    var d: pointer = nil
    var outSize: csize_t = 0
    try:
      d = ZSTD_createDStream()
      if d == nil:
        raise newException(DecompressUnavailable,
          "libzstd ZSTD_createDStream returned NULL")
      let initRc = ZSTD_initDStream(d)
      if ZSTD_isError(initRc) != 0:
        raise newException(DecompressError,
          "ZSTD_initDStream: " & $ZSTD_getErrorName(initRc))
      outSize = ZSTD_DStreamOutSize()
    except LibraryError as e:
      raise newException(DecompressUnavailable,
        "libzstd not loadable: " & e.msg)
    result = Decompressor(kind: ckZstd, impl: ckZstd,
                          zstdDStream: d,
                          zstdOutBuf: newSeq[byte](int(outSize)))
  of ckXz:
    raise newException(DecompressUnavailable,
      "ckXz decompression not yet implemented (A2.5 v1 ships ckNone + ckZstd)")

proc close*(d: Decompressor) =
  if d.isNil: return
  case d.impl
  of ckZstd:
    if d.zstdDStream != nil:
      discard ZSTD_freeDStream(d.zstdDStream)
      d.zstdDStream = nil
  else:
    discard

# ---------------------------------------------------------------------------
# Streaming feed
# ---------------------------------------------------------------------------

proc feed*(d: Decompressor; input: openArray[byte]; sink: ChunkSink) =
  ## Feeds ``input`` into the decompressor. Decompressed bytes (if
  ## any) are surfaced through ``sink`` zero or more times. Tail
  ## bytes that the decoder is still buffering stay inside the
  ## decompressor state.
  d.bytesIn += int64(input.len)
  case d.impl
  of ckNone:
    if input.len > 0:
      sink(input)
      d.bytesOut += int64(input.len)
  of ckZstd:
    if input.len == 0:
      return
    var inBuf = ZSTD_inBuffer(
      src: unsafeAddr input[0],
      size: csize_t(input.len),
      pos: csize_t(0))
    while inBuf.pos < inBuf.size:
      var outBuf = ZSTD_outBuffer(
        dst: addr d.zstdOutBuf[0],
        size: csize_t(d.zstdOutBuf.len),
        pos: csize_t(0))
      let rc = ZSTD_decompressStream(d.zstdDStream, addr outBuf, addr inBuf)
      if ZSTD_isError(rc) != 0:
        raise newException(DecompressError,
          "ZSTD_decompressStream: " & $ZSTD_getErrorName(rc))
      if outBuf.pos > 0:
        sink(d.zstdOutBuf.toOpenArray(0, int(outBuf.pos) - 1))
        d.bytesOut += int64(outBuf.pos)
      # If the decompressor consumed 0 bytes AND produced 0 bytes, it's
      # waiting for more input — break to receive the next TCP chunk.
      if outBuf.pos == 0 and inBuf.pos == 0:
        break
  of ckXz:
    raise newException(DecompressUnavailable, "ckXz unimplemented")

proc finish*(d: Decompressor; sink: ChunkSink) =
  ## Drains any trailing buffered output. Most chunk-based codecs
  ## (zstd, gzip) emit a final frame end marker that may have been
  ## consumed without producing output yet.
  if d.impl == ckZstd:
    # Loop with empty input until the decoder reports "nothing
    # buffered" (rc == 0 means a frame was fully consumed).
    var inBuf = ZSTD_inBuffer(src: nil, size: csize_t(0), pos: csize_t(0))
    for _ in 0 ..< 4:
      var outBuf = ZSTD_outBuffer(
        dst: addr d.zstdOutBuf[0],
        size: csize_t(d.zstdOutBuf.len),
        pos: csize_t(0))
      let rc = ZSTD_decompressStream(d.zstdDStream, addr outBuf, addr inBuf)
      if ZSTD_isError(rc) != 0:
        raise newException(DecompressError,
          "ZSTD_decompressStream(finish): " & $ZSTD_getErrorName(rc))
      if outBuf.pos > 0:
        sink(d.zstdOutBuf.toOpenArray(0, int(outBuf.pos) - 1))
        d.bytesOut += int64(outBuf.pos)
      if outBuf.pos == 0:
        break

proc supportsCompression*(kind: CompressionKind): bool =
  ## Probes whether the decompressor for ``kind`` can be constructed
  ## right now. Used by ``compat_check`` to fail fast before any byte
  ## travels.
  case kind
  of ckNone:
    return true
  of ckZstd:
    try:
      let d = newDecompressor(ckZstd)
      d.close()
      return true
    except DecompressUnavailable:
      return false
    except DecompressError:
      return false
  of ckXz:
    return false
