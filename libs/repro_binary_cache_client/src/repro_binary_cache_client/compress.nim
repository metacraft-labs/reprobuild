## Streaming zstd compression for published cache payloads.
##
## ## Why a compressor exists at all
##
## The manifest format has carried a ``compression`` field since A2 and the
## client has had a working ``ckZstd`` DECOMPRESSOR for as long
## (``decompress.nim``), but every payload the publisher ever produced was
## ``ckNone``. That asymmetry had a visible cost. ``/publish`` accepts a
## 1 GiB request body, so an uncompressed prefix archive larger than that
## could not be published at all -- and the packages that exceed it are
## precisely the ones worth caching: a Rust distribution, an LLVM release, a
## database server. The artifacts other machines most want to install
## quickly were the ones they always had to fetch from upstream and unpack
## themselves.
##
## Compressing the archive before it is weighed against that limit closes
## the gap for the same reason it shrinks every other payload: a prefix is
## mostly executables and archives, which zstd reduces several-fold.
##
## ## Soft-failure is the contract
##
## libzstd is loaded lazily by name, exactly as ``decompress.nim`` loads it,
## and for the same reason: a ``{.dynlib.}`` pragma dlopens in the module's
## init proc, so every binary that merely links this module -- including the
## recipe *provider* binaries reprobuild compiles on the fly -- would abort
## at startup on a host without libzstd, and the fallback would never run.
##
## A host that cannot load libzstd raises ``CompressUnavailable``. Callers
## treat that as "publish uncompressed", not as an error: the resulting
## entry is still correct, merely larger. Producer and consumer never need
## to agree in advance, because the payload declares its own codec.

import std/dynlib

import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types
import ./dynlib_names

type
  CompressError* = object of CatchableError
  CompressUnavailable* = object of CompressError
    ## Raised when libzstd (or an expected symbol) is missing. The caller
    ## falls back to an uncompressed payload.

  ZSTD_inBuffer = object
    src: pointer
    size: csize_t
    pos: csize_t

  ZSTD_outBuffer = object
    dst: pointer
    size: csize_t
    pos: csize_t

const
  ZstdEndDirectiveContinue = 0'i32
  ZstdEndDirectiveEnd = 2'i32
  ZstdCompressionLevel = 10'i32
    ## Level 10 rather than the default 3.
    ##
    ## A prefix is published once and substituted many times, so the trade
    ## is asymmetric: producer CPU is spent once, every consumer afterwards
    ## pays the transfer. Level 10 is roughly where zstd's ratio curve
    ## flattens for executable content -- the levels above cost
    ## disproportionately more time for a few percent -- and it decompresses
    ## at the same speed as every other level, since zstd's decoder is
    ## level-independent.

type
  ZstdCreateCStreamProc = proc(): pointer {.cdecl, gcsafe, raises: [].}
  ZstdFreeCStreamProc = proc(c: pointer): csize_t {.cdecl, gcsafe, raises: [].}
  ZstdInitCStreamProc = proc(c: pointer; level: cint): csize_t {.
    cdecl, gcsafe, raises: [].}
  ZstdCompressStream2Proc = proc(c: pointer; outBuf: ptr ZSTD_outBuffer;
                                 inBuf: ptr ZSTD_inBuffer;
                                 endOp: cint): csize_t {.
    cdecl, gcsafe, raises: [].}
  ZstdIsErrorProc = proc(code: csize_t): cuint {.cdecl, gcsafe, raises: [].}
  ZstdGetErrorNameProc = proc(code: csize_t): cstring {.
    cdecl, gcsafe, raises: [].}
  ZstdCStreamInSizeProc = proc(): csize_t {.cdecl, gcsafe, raises: [].}
  ZstdCStreamOutSizeProc = proc(): csize_t {.cdecl, gcsafe, raises: [].}

var
  zstdLibHandle: LibHandle
  ZSTD_createCStream: ZstdCreateCStreamProc
  ZSTD_freeCStream: ZstdFreeCStreamProc
  ZSTD_initCStream: ZstdInitCStreamProc
  ZSTD_compressStream2: ZstdCompressStream2Proc
  ZSTD_isError: ZstdIsErrorProc
  ZSTD_getErrorName: ZstdGetErrorNameProc
  ZSTD_CStreamInSize: ZstdCStreamInSizeProc
  ZSTD_CStreamOutSize: ZstdCStreamOutSizeProc

const ZstdDynLib = zstdDynlibName(HostZstdDynlibTarget)

proc ensureZstdLoaded() =
  if zstdLibHandle != nil:
    return
  let lib = loadLib(ZstdDynLib)
  if lib == nil:
    raise newException(CompressUnavailable,
      "libzstd not loadable: could not load " & ZstdDynLib)
  template resolve(field: untyped; T: typedesc; name: string) =
    let p = lib.symAddr(name)
    if p == nil:
      unloadLib(lib)
      raise newException(CompressUnavailable,
        "libzstd missing symbol " & name)
    field = cast[T](p)
  resolve(ZSTD_createCStream, ZstdCreateCStreamProc, "ZSTD_createCStream")
  resolve(ZSTD_freeCStream, ZstdFreeCStreamProc, "ZSTD_freeCStream")
  resolve(ZSTD_initCStream, ZstdInitCStreamProc, "ZSTD_initCStream")
  resolve(ZSTD_compressStream2, ZstdCompressStream2Proc,
    "ZSTD_compressStream2")
  resolve(ZSTD_isError, ZstdIsErrorProc, "ZSTD_isError")
  resolve(ZSTD_getErrorName, ZstdGetErrorNameProc, "ZSTD_getErrorName")
  resolve(ZSTD_CStreamInSize, ZstdCStreamInSizeProc, "ZSTD_CStreamInSize")
  resolve(ZSTD_CStreamOutSize, ZstdCStreamOutSizeProc, "ZSTD_CStreamOutSize")
  zstdLibHandle = lib

proc supportsCompressor*(kind: CompressionKind): bool =
  ## Whether ``kind`` can be produced on this host right now.
  ##
  ## Probing rather than assuming is what lets the publisher choose between a
  ## compressed and an uncompressed payload without an exception on the hot
  ## path, and what keeps a host without libzstd publishing successfully.
  case kind
  of ckNone:
    true
  of ckZstd:
    try:
      ensureZstdLoaded()
      true
    except CatchableError:
      false
  of ckXz:
    false

proc compressFileToFile*(sourcePath, destinationPath: string;
                         kind: CompressionKind = ckZstd): int64 =
  ## Compress ``sourcePath`` into ``destinationPath``; returns bytes written.
  ##
  ## Streams through fixed-size buffers rather than reading the archive into
  ## memory: the payloads this exists for are the multi-gigabyte ones, and
  ## the publisher already holds no more than a buffer at a time when it
  ## writes the archive itself.
  ##
  ## Raises ``CompressUnavailable`` when the codec's runtime library is
  ## missing -- the caller's cue to publish the uncompressed file instead.
  if kind == ckNone:
    raise newException(CompressError,
      "compressFileToFile: ckNone has no compressed form; publish the " &
      "source file directly")
  if kind != ckZstd:
    raise newException(CompressUnavailable,
      "compressFileToFile: only ckZstd is implemented")
  ensureZstdLoaded()

  let stream = ZSTD_createCStream()
  if stream == nil:
    raise newException(CompressUnavailable,
      "libzstd ZSTD_createCStream returned NULL")
  defer: discard ZSTD_freeCStream(stream)
  let initRc = ZSTD_initCStream(stream, cint(ZstdCompressionLevel))
  if ZSTD_isError(initRc) != 0:
    raise newException(CompressError,
      "ZSTD_initCStream: " & $ZSTD_getErrorName(initRc))

  var inBuf = newSeq[byte](int(ZSTD_CStreamInSize()))
  var outBuf = newSeq[byte](int(ZSTD_CStreamOutSize()))

  var source = open(sourcePath, fmRead)
  defer: close(source)
  var destination = open(destinationPath, fmWrite)
  defer: close(destination)

  var written = 0'i64

  # ``ZSTD_compressStream2`` returns a HINT, not a byte count: nonzero means
  # "call me again". So the loop is driven by that return value and by how
  # much of the input was consumed, never by how full the output buffer came
  # back -- a full buffer with nothing left to flush is a normal outcome.
  proc drain(endOp: int32; inputPtr: pointer; inputLen: int) =
    var zin = ZSTD_inBuffer(src: inputPtr, size: csize_t(inputLen), pos: 0)
    while true:
      var zout = ZSTD_outBuffer(dst: addr outBuf[0],
        size: csize_t(outBuf.len), pos: 0)
      let rc = ZSTD_compressStream2(stream, addr zout, addr zin, cint(endOp))
      if ZSTD_isError(rc) != 0:
        raise newException(CompressError,
          "ZSTD_compressStream2: " & $ZSTD_getErrorName(rc))
      if zout.pos > 0:
        discard destination.writeBuffer(addr outBuf[0], int(zout.pos))
        written += int64(zout.pos)
      if endOp == ZstdEndDirectiveEnd:
        if rc == 0:
          break
      elif int(zin.pos) >= inputLen:
        break

  while true:
    let read = source.readBuffer(addr inBuf[0], inBuf.len)
    if read <= 0:
      break
    drain(ZstdEndDirectiveContinue, addr inBuf[0], read)
  drain(ZstdEndDirectiveEnd, nil, 0)
  written

proc isZstdFrame*(head: openArray[byte]): bool =
  ## Whether ``head`` starts with a zstd frame magic number.
  ##
  ## The substitute side needs this because the CAS stores the payload
  ## exactly as the producer signed it, compressed or not, and a consumer
  ## reading a blob back has only the bytes -- not the manifest that
  ## described them. ``rbcarc`` archives begin with ``RBCA``, so the two are
  ## never ambiguous.
  head.len >= 4 and head[0] == 0x28'u8 and head[1] == 0xB5'u8 and
    head[2] == 0x2F'u8 and head[3] == 0xFD'u8
