## Streaming in-process archive verification; no executable dependency.
import std/[os, strutils]
import nimcrypto/[hash, sha, sha2]
from repro_core/paths import extendedPath

proc digestFile[T](path: string; algorithm: typedesc[T]): string =
  var input: File
  if not open(input, extendedPath(path), fmRead):
    raise newException(OSError, "cannot open for digest verification: " & path)
  defer: close(input)
  var ctx: T
  ctx.init()
  var buffer = newSeq[byte](1 shl 20)
  while true:
    let got = input.readBytes(buffer, 0, buffer.len)
    if got <= 0: break
    ctx.update(buffer.toOpenArray(0, got - 1))
  result = toLowerAscii($ctx.finish())
  ctx.clear()

proc fileShaHex*(path, algorithm: string): string =
  case algorithm
  of "sha256": digestFile(path, sha256)
  of "sha512": digestFile(path, sha512)
  of "sha1": digestFile(path, sha1)
  else: raise newException(ValueError, "unsupported digest algorithm: " & algorithm)
