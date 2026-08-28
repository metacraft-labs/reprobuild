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
##   3b. **Microarchitecture floor** (PMC-4). ``manifest.entryKey.platform
##      .microarch`` is the target the artifact was BUILT FOR; the host must
##      provide at least it. Unlike every other gate here this one is an
##      ORDERING and not an equality — a v4 host runs a v3 artifact — and it
##      is evaluated by ``packages_schema.resolvedTargetSatisfiedBy``, the
##      same subset test arm selection uses, so the cache and the resolver
##      cannot reach opposite verdicts about one host.
##
##      The entry key already separates a v2 artifact from a v3 one, so in
##      normal operation a v2 host never names the v3 entry. This gate exists
##      for the keys the client did NOT derive: one read out of a lock file,
##      one followed from another manifest's ``depReferences``, one typed
##      into ``lookup <hex>``, or one published before its floor was
##      declared. Without it the failure is a ``SIGILL`` inside an unrelated
##      build with nothing pointing back at the substitution.
##
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
##
##      Reprobuild-Binary-Cache-Fleet R1 — DEFAULT-UNTRUSTED. When the
##      endpoint sets ``enforceTrust`` (every config-loaded cache
##      does), an EMPTY ``trustedSigners`` list REJECTS the manifest:
##      a cache with no explicit trusted key is a MISS, never a silent
##      trust. Pre-R1 callers that leave ``enforceTrust = false`` keep
##      the legacy behaviour where an empty list trusts the
##      signature-verified producer.

import repro_dsl_stdlib/packages_schema

import ./types
import ./decompress
import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes

type
  LocalPlatform* = object
    cpu*: string
    os*: string
    abi*: string
    libcVariant*: string
    microarch*: string
      ## PMC-4 — what this host PROVIDES on the microarchitecture axis, in
      ## ``packages_schema.renderResolvedTarget``'s spelling.
      ##
      ## Note the direction, which is the opposite of the identically-spelled
      ## ``PlatformTriple.microarch``: on an ENTRY the string is a FLOOR (the
      ## minimum required), on a HOST it is a CEILING (the maximum provided).
      ## The gate compares them as PMC-3's subset test, so the asymmetry is a
      ## property of the comparison rather than of two separate rules.
      ##
      ## ``""`` means "this host has stated nothing", which is NOT ``v1``, and
      ## it satisfies no declared floor. That is PMC-2's deliberate asymmetry
      ## carried into the cache: guessing high on the host side is exactly the
      ## ``SIGILL`` this milestone exists to prevent, and a floor-less entry —
      ## every entry published before PMC-4 — is served to such a host anyway
      ## because ``{}`` is a subset of everything.
    storeDir*: string

proc detectLocalPlatform*(storeDir: string; microarch = ""): LocalPlatform =
  ## Returns the local solve target. The platform values match the
  ## ones the binary-cache server's manifests would be keyed on for a
  ## native build of this workstation.
  ##
  ## PMC-4: ``microarch`` is a DEFAULTED PARAMETER rather than a probe, for
  ## the two reasons the campaign has applied to every host fact so far.
  ##
  ## First, authority. What a machine may be GIVEN is a fleet decision, not a
  ## silicon one — the same argument ``REPRO_HOST_MICROARCH_LEVEL`` is built
  ## on — and this module deliberately does not reach for that variable
  ## itself. ``package_catalog.detectHostTarget`` is where the environment is
  ## read and validated, and a second reader here would be a second place for
  ## the vocabulary to drift. A caller that has resolved a host target renders
  ## it (``renderResolvedTarget``) and passes it in.
  ##
  ## Second, the default is the SAFE one rather than the convenient one. ``""``
  ## means "this host has stated nothing", which satisfies no declared floor —
  ## so a client that has not been told what it provides is refused optimised
  ## artifacts and served every floor-less one, which is exactly the state of
  ## every entry published before this milestone. Defaulting to the build
  ## host's real capability would have been Spack's default, and Spack's
  ## default is the reason its binaries famously do not run elsewhere.
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
  result.microarch = microarch
  result.storeDir = storeDir

proc checkCompat*(manifest: BinaryCacheManifest;
                  local: LocalPlatform;
                  trustedSigners: seq[PublicKeyBytes];
                  enforceTrust = false): tuple[ok: bool; reason: string] =
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
  # PMC-4 gate — the microarchitecture floor.
  #
  # Note what is NOT written here: an equality test. Every gate above is one,
  # because every coordinate above is an identity (a musl binary is not a
  # glibc binary at any strength). The microarchitecture is an ORDERING: a v4
  # host runs a v3 artifact correctly, and refusing it would throw away
  # exactly the cache reuse this axis was modelled to enable. So the test is
  # PMC-3's subset check, reached through ``resolvedTargetSatisfiedBy`` so
  # that this gate and ``selectPlatformBinaryEx`` cannot disagree about the
  # same host.
  #
  # An empty manifest floor is satisfied by every host including one that has
  # stated nothing — that is what keeps every pre-PMC-4 entry servable — and
  # an unreadable floor is REFUSED rather than ignored, because a floor this
  # client cannot read is a requirement it cannot honour.
  if p.microarch.len > 0:
    let hostTarget = parseResolvedTarget(local.microarch)
    if not hostTarget.ok:
      return (false, "local microarchitecture '" & local.microarch &
        "' is unreadable: '" & hostTarget.badToken & "' names no " &
        "microarchitecture level or CPU feature this build understands")
    # The family coordinate is carried for legibility only: the ``p.cpu !=
    # local.cpu`` gate above has already established that the two agree, and
    # ``providedFeatures`` is a function of the level and the feature set
    # alone. Passing the parsed local family rather than a literal keeps the
    # value honest if that ever stops being true.
    let localFamily = parsePlatformCpuToken(local.cpu)
    let shortfall = describeResolvedTargetShortfall(p.microarch,
      initPlatformTarget(
        (if localFamily.ok: localFamily.cpu else: pcAny),
        hostTarget.level, hostTarget.features))
    if shortfall.len > 0:
      return (false, shortfall & " — manifest was built for " & p.microarch &
        ", this host provides " &
        (if local.microarch.len == 0: "no declared microarchitecture"
         else: local.microarch) &
        ". Substituting it would run instructions this CPU does not " &
        "implement (SIGILL), so the entry is a MISS and the engine builds " &
        "locally.")
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
  if trustedSigners.len == 0:
    if enforceTrust:
      # Default-untrusted: a cache with no explicit trusted key is
      # never substituted from. Treated as a MISS by the caller.
      return (false, "cache has no trusted-public-keys configured " &
        "(default-untrusted): manifest rejected")
    # Legacy (pre-R1) callers: an empty list trusts the
    # signature-verified producer.
  else:
    var trusted = false
    for ts in trustedSigners:
      if ts == manifest.producerPubKey:
        trusted = true
        break
    if not trusted:
      return (false, "producer pubkey not in trustedSigners list")
  return (true, "")
