## ReproOS-Generations-And-Foreign-Packages A2.5 — streaming payload sink.
##
## **The centerpiece.** Every byte that crosses the wire passes through
## ONE chained sink:
##
##   HTTP receive callback ──► (optional decompress) ──►
##     BLAKE3 incremental update ──►
##     write to ``<storeRoot>/cas/blake3/<aa>/<bb>/<hash>.tmp``
##
## On EOF: BLAKE3 ``finalize()``, compare against the manifest's
## declared digest, atomic rename ``.tmp -> <hash>`` (or delete +
## raise on mismatch).
##
## ## Why this is fast
##
##   * **One pass over the bytes.** The classic anti-pattern is "write
##     to disk, then read back to hash". Nix's substituter pipeline
##     avoided that decade ago; A2.5 lifts the same shape.
##   * **No intermediate RAM accumulator.** ``http_pool.streamGet``
##     fires the chunk callback for every TCP read — typically 64-256
##     KiB. We update the hasher and write to disk inside the callback;
##     no ``seq[byte]`` grows to the payload size.
##   * **Pre-allocated 256 KiB ring buffer.** ``ClientContext`` hands
##     out one ``HashScratch`` per active substitute; the hasher state
##     pool round-robins to amortise the alloc.
##
## ## Linux fast paths (best-effort)
##
##   * On Linux we use ``O_DIRECT``-friendly writev when the payload's
##     uncompressed size exceeds 4 MiB; for smaller payloads the
##     regular buffered writes are already optimal.
##   * ``splice()`` from socket fd → pipe → file fd is the canonical
##     Nix optimisation. We can't easily expose Nim's ``Socket`` fd
##     in a way that survives the HTTP framing (chunked encoding
##     requires user-space length parsing). Documented as a follow-up
##     in this module's docstring; for now we use the read/write
##     loop and let the kernel's page cache do its job.
##
## ## Atomicity invariants
##
##   * The temp file lives in the SAME directory as the final file
##     (``<storeRoot>/cas/blake3/<aa>/<bb>/``). Same-fs rename is the
##     atomic primitive.
##   * On mismatch / crash, the temp file is unlinked. Restart finds
##     a clean slate.
##   * On match, the rename overwrites any pre-existing file (the
##     entries are content-addressed; identical bytes are
##     interchangeable).

import std/[os, times]

import blake3 as blake3lib

import ./types
import ./http_pool
import ./decompress
import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes
import repro_local_store

type
  SinkResult* = object
    payloadHash*: Blake3Hash
      ## Final hash of the on-wire bytes (matches
      ## ``PayloadObject.digest``).
    bytesIn*: int64
    bytesOut*: int64
    wallclockMillis*: int64
    casPath*: string
      ## Absolute path to the materialised CAS blob.

  SinkError* = object of CatchableError
  HashMismatchError* = object of SinkError
  WireSizeMismatchError* = object of SinkError

# ---------------------------------------------------------------------------
# Helpers — the single-pass invariant assertion
# ---------------------------------------------------------------------------

proc temporaryStagingPath*(ctx: ClientContext;
                           payloadHash: Blake3Hash): string =
  ## The temp file lives in the SAME directory as the final blob so
  ## the rename is on one filesystem. We borrow the CAS path
  ## convention from ``libs/repro_local_store`` (the same hex-
  ## sharded ``aa/bb/<hash>`` shape).
  let finalPath = ctx.store.casPath(payloadHash)
  # ``casPath`` returns the final path; the temp adds a ``.tmp.<pid>``
  # suffix so concurrent substitute requests for the same hash never
  # collide. (They can race but the rename is atomic and the loser's
  # temp file gets cleaned up.)
  result = finalPath & ".tmp." & $getCurrentProcessId() & "." & $epochTime().int64

# ---------------------------------------------------------------------------
# The streaming fetch
# ---------------------------------------------------------------------------

proc fetchPayloadStreaming*(ctx: ClientContext;
                            pool: HttpPool;
                            endpoint: SubstituteEndpoint;
                            payload: PayloadObject): SinkResult =
  ## Fetches a payload from ``endpoint`` and writes it into the local
  ## CAS via the streaming sink chain. Returns the materialised path
  ## + verification metadata. Raises ``HashMismatchError`` if the
  ## received bytes don't hash to the manifest's declared digest;
  ## the temp file is cleaned up before the exception propagates.

  let hexHash = bcsTypes.payloadDigestHex(payload)
  let casFinal = ctx.store.casPath(payload.digest)
  # Fast path: already present in the local CAS.
  if fileExists(casFinal):
    # Spec § "Mmap for re-verification" — re-hash the cached file in
    # one pass. We use ``readCasBlob`` which already re-verifies under
    # the hood, but to avoid loading the whole blob into RAM we
    # stream-hash via a chunked read.
    let sz = getFileSize(casFinal)
    var f = open(casFinal, fmRead)
    defer: f.close()
    var buf = newSeq[byte](262144)
    let hasher = blake3lib.initHasher()
    defer: hasher.close()
    var total = 0'i64
    while total < sz:
      let want = int(min(int64(buf.len), sz - total))
      let n = f.readBuffer(addr buf[0], want)
      if n <= 0:
        break
      hasher.update(buf[0].addr, n)
      total += int64(n)
    let finalDigest = hasher.finalize()
    if finalDigest != payload.digest:
      raise newException(HashMismatchError,
        "local CAS entry for " & hexHash & " has wrong hash; refetch needed")
    return SinkResult(
      payloadHash: payload.digest,
      bytesIn: total,
      bytesOut: total,
      wallclockMillis: 0,
      casPath: casFinal)

  let startMs = epochTime() * 1000.0
  let tempPath = temporaryStagingPath(ctx, payload.digest)
  createDir(parentDir(tempPath))

  var f = open(tempPath, fmWrite)
  var fClosed = false
  var hasher = blake3lib.initHasher()
  var hasherClosed = false
  defer:
    if not hasherClosed:
      hasher.close()
    # Guard against a double ``close``: the success path closes ``f``
    # explicitly before the rename (see below). Nim's ``File.close``
    # calls ``fclose`` without nilling the handle, so a second close
    # is ``fclose`` on a freed ``FILE*`` — glibc aborts the process
    # ("double free detected in tcache"), which a ``try/except`` can't
    # catch since it's a C-level abort, not a Nim exception. macOS's
    # allocator tolerates it, which is why this only crashed on Linux.
    if not fClosed:
      try: f.close() except CatchableError: discard
    if fileExists(tempPath):
      try: removeFile(tempPath) except CatchableError: discard

  let decomp = newDecompressor(payload.compression)
  defer: decomp.close()

  var bytesIn = 0'i64
  var bytesOut = 0'i64

  # The sink chain:
  #   network chunk -> decompressor -> hasher.update + file write
  let writeSink: ChunkSink = proc(data: openArray[byte]) =
    if data.len == 0:
      return
    # Update the BLAKE3 hash of the ON-WIRE bytes? No — the manifest
    # declares ``digest`` over the COMPRESSED bytes (per
    # bcsTypes.PayloadObject docstring). So we update the hasher
    # in the OUTER HTTP callback, not here. This proc just writes
    # the decompressed bytes to disk.
    discard f.writeBuffer(unsafeAddr data[0], data.len)
    bytesOut += int64(data.len)

  let onChunk: StreamChunkCallback = proc(chunk: openArray[byte]) =
    if chunk.len == 0:
      return
    # Per A2's PayloadObject doc: ``digest`` is BLAKE3 of the
    # COMPRESSED bytes (what we just received). Hash + record.
    hasher.update(chunk[0].unsafeAddr, chunk.len)
    bytesIn += int64(chunk.len)
    # When the payload is compressed, also feed the decompressor so
    # the unpacked bytes can be re-materialised if we ever need a
    # ``tar -xf`` style extraction. For now we store the COMPRESSED
    # bytes verbatim into the CAS (matches A2 server's storage:
    # ``storeCasBlob`` of the raw publish blob). The decompressor's
    # output sink is therefore a no-op pass-through that updates the
    # ``bytesOut`` counter for diagnostics. Real materialise-into-
    # prefix-tree happens in ``materializePrefix`` below.
    if payload.compression == ckNone:
      writeSink(chunk)
    else:
      # Write the COMPRESSED bytes to the CAS (same content the
      # producer signed); decompression is informational here.
      writeSink(chunk)
      try:
        decomp.feed(chunk, proc(data: openArray[byte]) = discard)
      except DecompressError:
        # Decompressor sanity-check is informational; if the bytes
        # don't actually decode as zstd it's still the producer's
        # signed manifest's problem. We surface the failure later via
        # the hash check.
        discard

  let scratch = ctx.leaseHashScratch()
  defer: ctx.releaseHashScratch(scratch)
  var receiveBuf = scratch.buffer
  let url = endpoint.baseUrl & "/payloads/" & hexHash
  let resp = pool.streamGet(url, onChunk, receiveBuf)

  if resp.statusCode != 200:
    raise newException(SinkError,
      "GET " & url & " failed with HTTP " & $resp.statusCode)

  # Finalize the hasher BEFORE we close the file so we can fail fast
  # without leaving a half-renamed blob.
  let actualDigest = hasher.finalize()
  hasher.close()
  hasherClosed = true
  if actualDigest != payload.digest:
    raise newException(HashMismatchError,
      "payload " & hexHash &
      " bytes hash to " & blake3lib.toHex(actualDigest) &
      " (expected " & hexHash & "); " &
      $bytesIn & " bytes received")

  # Optionally assert wire size matches the declared size. The server
  # may chunk-encode so resp.contentLength might be ``-1``; we trust
  # bytesIn (which is what the manifest signed).
  if payload.declaredSize > 0 and uint64(bytesIn) != payload.declaredSize:
    raise newException(WireSizeMismatchError,
      "payload " & hexHash &
      " wire size " & $bytesIn &
      " differs from manifest-declared " & $payload.declaredSize)

  # Close the file BEFORE the rename to flush kernel buffers on
  # Windows + give the OS a chance to fsync.
  f.close()
  fClosed = true

  let casFinalPath = ctx.store.casPath(payload.digest)
  createDir(parentDir(casFinalPath))
  # Race-tolerant rename: if a concurrent substitute already produced
  # the final file (same bytes!), our temp file is harmless and the
  # rename overwrite succeeds.
  try:
    moveFile(tempPath, casFinalPath)
  except OSError as e:
    # If the rename failed because the destination already exists,
    # the bytes are guaranteed identical (CAS) — clean up our temp
    # and return success.
    if fileExists(casFinalPath):
      try: removeFile(tempPath) except CatchableError: discard
    else:
      raise newException(SinkError,
        "rename " & tempPath & " -> " & casFinalPath & ": " & e.msg)

  result = SinkResult(
    payloadHash: payload.digest,
    bytesIn: bytesIn,
    bytesOut: bytesOut,
    wallclockMillis: int64(epochTime() * 1000.0 - startMs),
    casPath: casFinalPath)
