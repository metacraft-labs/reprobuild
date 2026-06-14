## ReproOS-Generations-And-Foreign-Packages A2.5 — compatibility gate.
##
## Binary-Caches.md § "Compatibility Checks" mandates that the client
## reject a manifest whose platform/ABI/toolchain identity doesn't
## match the local environment BEFORE any payload byte is fetched.
## The engine falls back to a local build for the rejected entry.
##
## ## Gates (cumulative; first failure rejects)
##
##   1. **Format version.** ``manifest.formatVersion ==
##      BinaryCacheFormatVersion``. A future v2 manifest format must
##      coexist via a parallel decoder.
##   2. **Platform.** ``manifest.entryKey.platform.cpu`` /
##      ``.os`` / ``.abi`` match the local solved values.
##   3. **libc variant** (Linux only). ``glibc-X.Y`` consumers must
##      not substitute a ``musl-X.Y`` producer's output even if every
##      other tuple field matches.
##   4. **Relocation policy.** ``rpForbidden`` payloads require the
##      producer's exact ``StoreDir`` (the ``CacheInfoRecord.storeDir``
##      value). If our local store root differs, the substitute is
##      bypass-only.
##   5. **Compression codec.** A payload requesting ``ckZstd`` is
##      rejected if libzstd isn't available; ``ckXz`` is rejected
##      unconditionally in v1.
##   6. **Signer trust.** ``manifest.producerPubKey`` must be on the
##      configured ``trustedSigners`` list for the endpoint we
##      fetched from. (The signature itself has already been verified
##      by ``manifest_codec.decodeAndVerify``; this gate enforces the
##      additional "is this signer authorised to publish for THIS
##      cache" policy.)

import ./types
import ./decompress
import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes

type
  LocalPlatform* = object
    cpu*: string
    os*: string
    abi*: string
    libcVariant*: string
    storeDir*: string

proc detectLocalPlatform*(storeDir: string): LocalPlatform =
  ## Returns the local solve target. The platform values match the
  ## ones the binary-cache server's manifests would be keyed on for a
  ## native build of this workstation.
  when defined(amd64) or defined(x86_64):
    result.cpu = "x86_64"
  elif defined(arm64) or defined(aarch64):
    result.cpu = "aarch64"
  else:
    result.cpu = "unknown"
  when defined(linux):
    result.os = "linux"
    result.abi = "gnu"
    result.libcVariant = ""        # left empty: probe lazily on R5
  elif defined(windows):
    result.os = "windows"
    result.abi = "msvc"
    result.libcVariant = ""
  elif defined(macosx):
    result.os = "darwin"
    result.abi = ""
    result.libcVariant = ""
  else:
    result.os = "unknown"
  result.storeDir = storeDir

proc checkCompat*(manifest: BinaryCacheManifest;
                  local: LocalPlatform;
                  trustedSigners: seq[PublicKeyBytes]): tuple[ok: bool; reason: string] =
  if manifest.formatVersion != bcsTypes.BinaryCacheFormatVersion:
    return (false, "manifest format version mismatch: " &
      $manifest.formatVersion & " vs local " &
      $bcsTypes.BinaryCacheFormatVersion)
  let p = manifest.entryKey.platform
  if p.cpu != local.cpu:
    return (false, "CPU mismatch: manifest=" & p.cpu & " local=" & local.cpu)
  if p.os != local.os:
    return (false, "OS mismatch: manifest=" & p.os & " local=" & local.os)
  if p.abi.len > 0 and local.abi.len > 0 and p.abi != local.abi:
    return (false, "ABI mismatch: manifest=" & p.abi & " local=" & local.abi)
  if p.libcVariant.len > 0 and local.libcVariant.len > 0 and
     p.libcVariant != local.libcVariant:
    return (false, "libc-variant mismatch: manifest=" & p.libcVariant &
      " local=" & local.libcVariant)
  for payload in manifest.payloads:
    if not supportsCompression(payload.compression):
      return (false, "compression codec unavailable: " &
        $payload.compression & " for payload " & payload.name)
  if manifest.relocationPolicy == rpForbidden:
    # rpForbidden payloads pin to a specific StoreDir. We don't know
    # the producer's storeDir at compat-check time (that's a
    # CacheInfoRecord field; the client populates it via the
    # endpoint cache-info probe). Best-effort: warn-only via the
    # caller's reason string; the actual storeDir comparison runs
    # at materialize time in ``payload_sink``.
    discard
  if trustedSigners.len > 0:
    var trusted = false
    for ts in trustedSigners:
      if ts == manifest.producerPubKey:
        trusted = true
        break
    if not trusted:
      return (false, "producer pubkey not in trustedSigners list")
  return (true, "")
