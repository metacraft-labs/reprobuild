## ``repro_lock_gen/upstream_archives`` — resolving a store-sourced package
## version to the upstream release archive that holds it, at LOCK time.
##
## Reprobuild-specs Distribution-And-Packaging.milestones.org, M5 "pin the
## provider-compile toolchain". A project pins the Nim that compiles its
## provider with ``packageSource "nim", "store"`` and ``uses: "nim ==V"``. The
## lock's ``ckStore`` coordinate names the version; it does not say where the
## bytes come from, so before this module a reprobuild could realize only the
## one Nim it carried a pin for itself. ``repro lock refresh`` now resolves the
## solved version to an official release archive for the lock's platform and
## records its URL and SHA-256 in the lock entry (``repro_lock.LockedArchive``).
## Realization verifies the download against that digest, so the network is
## trusted once, when the lock is written and reviewed, and never at use time.
##
## ## What upstream publishes (measured 2026-10-01)
##
## ``https://nim-lang.org/download/`` serves, for every release from 1.6.0 to
## 2.2.10, each with a ``<file>.sha256`` beside it (``<hex>  <file>``):
##
##   * ``nim-V_x64.zip`` / ``nim-V_x32.zip`` — Windows binaries;
##   * ``nim-V.tar.xz`` — the source archive (C sources + ``build.sh``);
##   * ``nim-V-linux_x64.tar.xz`` — a STATIC Linux binary, not used: a static
##     ELF cannot be entered by the preload monitor, so every interface
##     extraction it ran would be uncacheable (the bootstrap's no-Nix route
##     builds from source for the same reason);
##   * ``nim-V-macosx_{arm64,x64}.tar.xz`` — only from 2.2.8 on.
##
## The ``nim-lang/nightlies`` GitHub releases also carry darwin builds at
## older release commits (2.2.6, 2.0.16, ...), but under tags named
## ``<date>-version-X-Y-<commit>`` that cannot be derived from a version
## without enumerating ~2800 releases through the GitHub API, and they are CI
## artifacts of a commit rather than release archives. They are not used.
##
## So the route per lock platform is:
##
## | platform | archive | build |
## |---|---|---|
## | ``amd64-windows`` | ``nim-V_x64.zip`` | binary |
## | ``i386-windows`` | ``nim-V_x32.zip`` | binary |
## | ``arm64-macosx`` / ``amd64-macosx`` | ``nim-V-macosx_{arm64,x64}.tar.xz`` if published, else ``nim-V.tar.xz`` | binary, else source |
## | every other non-Windows platform (Linux, BSDs) | ``nim-V.tar.xz`` | source |
## | any other Windows CPU | none: the lock records no archive | |
##
## Linux builds from source with or without Nix. A nixpkgs pin cannot give an
## arbitrary Nim version: one nixpkgs revision carries one Nim, and mapping a
## version to the revision that happened to carry it is neither derivable nor
## stable. Building the pinned release from its own sources gives exactly the
## version the lock names, on every CPU ``build.sh`` knows, dynamically linked
## against the host's (or Nix's) C runtime.
##
## ## The edge
##
## One ``bakMetadataFetch`` edge per (package, declared candidate version),
## planned from static inputs like the acquisition records of
## ``Repository-And-Index-Format.md`` §5 (``MetadataObjectKind.
## mokUpstreamArchive``). Its object is the RECORD this module renders — the
## chosen archive URL, its digest, the archive type and whether it is a binary
## or a source build — and the solve edge, which already reads every fetched
## object, copies the record of the solved version into the lock entry. The
## digest comes from upstream's own ``.sha256`` file, fetched over the same
## in-process TLS path as every metadata object; the file must name the
## archive it is for, or it is refused.

import std/[strutils]

import repro_lock

import ./metadata_objects

const
  NimReleaseBase* = "https://nim-lang.org/download"
    ## Where official Nim release archives and their ``.sha256`` files live.

  UpstreamArchiveTextSchema* = "reprobuild.upstream-archive-request.v1"
    ## First line of the ``builtinText`` of an upstream-archive fetch edge.
  UpstreamArchiveRecordSchema* = "reprobuild.upstream-archive.v1"
    ## First line of the object such an edge writes.

type
  UpstreamArchiveCandidate* = object
    ## One archive upstream may publish for a version and platform.
    fileName*: string
    url*: string
    sha256Url*: string
    archiveType*: string
    build*: string        ## ``LockedArchiveBinary`` / ``LockedArchiveSource``

  UpstreamArchiveError* = object of CatchableError
    ## A version could not be resolved to an archive: it is not a released
    ## version, upstream published nothing for the platform, or the published
    ## digest file is malformed or names another file.

proc hasUpstreamArchives*(packageName: string): bool =
  ## Whether ``repro lock refresh`` resolves a store-sourced ``packageName``
  ## to an upstream archive. Today only the provider compiler, ``nim``.
  packageName == "nim"

proc validReleaseVersion(version: string): bool =
  ## A release version as upstream spells it in a file name: digits and dots.
  ## Checked because the version is spliced into a URL.
  if version.len == 0 or version[0] == '.' or version[^1] == '.':
    return false
  for ch in version:
    if ch notin {'0'..'9', '.'}:
      return false
  true

proc platformParts(platform: string): tuple[cpu, os: string] =
  let dash = platform.find('-')
  if dash <= 0 or dash + 1 >= platform.len:
    raise newException(UpstreamArchiveError,
      "\"" & platform & "\" is not a <cpu>-<os> platform id")
  (platform[0 ..< dash], platform[dash + 1 .. ^1])

proc nimReleaseCandidates*(version, platform: string;
                           base = NimReleaseBase):
    seq[UpstreamArchiveCandidate] =
  ## The archives that may hold Nim ``version`` for ``platform`` (a lock
  ## platform id, ``<cpu>-<os>`` as ``currentPlatformId`` spells it), most
  ## preferred first. The first one upstream publishes is the pin. Empty when
  ## upstream publishes nothing usable for the platform.
  if not validReleaseVersion(version):
    raise newException(UpstreamArchiveError,
      "nim \"" & version & "\" is not a release version (digits and dots)")
  let (cpu, os) = platformParts(platform)
  let root = base.strip(leading = false, chars = {'/'})
  proc candidate(fileName, archiveType, build: string):
      UpstreamArchiveCandidate =
    UpstreamArchiveCandidate(fileName: fileName,
      url: root & "/" & fileName, sha256Url: root & "/" & fileName & ".sha256",
      archiveType: archiveType, build: build)
  let source = candidate("nim-" & version & ".tar.xz", "tar.xz",
    LockedArchiveSource)
  if os == "windows":
    case cpu
    of "amd64":
      result.add(candidate("nim-" & version & "_x64.zip", "zip",
        LockedArchiveBinary))
    of "i386":
      result.add(candidate("nim-" & version & "_x32.zip", "zip",
        LockedArchiveBinary))
    else:
      discard
  elif os == "macosx":
    case cpu
    of "arm64":
      result.add(candidate("nim-" & version & "-macosx_arm64.tar.xz",
        "tar.xz", LockedArchiveBinary))
    of "amd64":
      result.add(candidate("nim-" & version & "-macosx_x64.tar.xz",
        "tar.xz", LockedArchiveBinary))
    else:
      discard
    result.add(source)
  else:
    result.add(source)

proc parseSha256File*(body, fileName: string): string =
  ## The digest in an upstream ``<file>.sha256`` body (``<hex>  <file>``, as
  ## ``sha256sum`` writes it). The file name, when present, must be
  ## ``fileName``: a digest file for some other archive is not this archive's
  ## digest, however it came to be served at this URL.
  let line = body.strip()
  if line.len == 0:
    raise newException(UpstreamArchiveError,
      "the digest file for " & fileName & " is empty")
  let fields = line.splitLines()[0].splitWhitespace()
  let hex = fields[0].toLowerAscii()
  if hex.len != 64 or not hex.allCharsInSet(HexDigits):
    raise newException(UpstreamArchiveError,
      "the digest file for " & fileName & " does not start with a SHA-256 " &
      "hex digest: " & line.splitLines()[0])
  if fields.len > 1:
    let named = fields[1].strip(chars = {'*'})
    if named != fileName:
      raise newException(UpstreamArchiveError,
        "the digest file served for " & fileName & " names " & named)
  hex

proc renderUpstreamArchiveRecord*(archive: LockedArchive;
                                  digestSource: string): string =
  ## The object an upstream-archive fetch edge writes.
  UpstreamArchiveRecordSchema & "\n" &
    "url=" & archive.url & "\n" &
    "sha256=" & archive.sha256 & "\n" &
    "type=" & archive.archiveType & "\n" &
    "build=" & archive.build & "\n" &
    "digest-source=" & digestSource & "\n"

proc parseUpstreamArchiveRecord*(body: string): LockedArchive =
  let lines = body.splitLines()
  if lines.len == 0 or lines[0].strip() != UpstreamArchiveRecordSchema:
    raise newException(UpstreamArchiveError,
      "not an upstream-archive record (expected " &
      UpstreamArchiveRecordSchema & ")")
  for raw in lines[1 .. ^1]:
    let eq = raw.find('=')
    if eq <= 0: continue
    let value = raw[eq + 1 .. ^1].strip()
    case raw[0 ..< eq]
    of "url": result.url = value
    of "sha256": result.sha256 = value
    of "type": result.archiveType = value
    of "build": result.build = value
    else: discard
  if result.url.len == 0 or result.sha256.len != 64:
    raise newException(UpstreamArchiveError,
      "incomplete upstream-archive record: " & body.strip())

proc renderUpstreamArchiveRequest*(packageName, version, platform,
                                   base: string): string =
  ## The ``builtinText`` of an upstream-archive fetch edge.
  UpstreamArchiveTextSchema & "\n" &
    "package=" & packageName & "\n" &
    "version=" & version & "\n" &
    "platform=" & platform & "\n" &
    "base=" & base & "\n"

proc isUpstreamArchiveRequest*(text: string): bool =
  text.startsWith(UpstreamArchiveTextSchema & "\n")

proc resolveUpstreamArchive*(text: string): RetrievedMetadata =
  ## The executor body of an upstream-archive fetch edge: try each candidate
  ## in order, take the first whose ``.sha256`` upstream publishes, and
  ## return the record. A candidate upstream does not publish (HTTP 404) is
  ## skipped; any other failure is a failure.
  var packageName, version, platform, base: string
  for raw in text.splitLines()[1 .. ^1]:
    let eq = raw.find('=')
    if eq <= 0: continue
    let value = raw[eq + 1 .. ^1]
    case raw[0 ..< eq]
    of "package": packageName = value
    of "version": version = value
    of "platform": platform = value
    of "base": base = value
    else: discard
  if packageName != "nim":
    raise newException(UpstreamArchiveError,
      "no upstream archive route for package \"" & packageName & "\"")
  let candidates = nimReleaseCandidates(version, platform,
    if base.len > 0: base else: NimReleaseBase)
  if candidates.len == 0:
    raise newException(UpstreamArchiveError,
      "upstream publishes no nim archive for platform " & platform)
  var looked: seq[string]
  for c in candidates:
    let fetched = fetchMetadataObjectIfPublished(c.sha256Url)
    if not fetched.published:
      looked.add(c.sha256Url)
      continue
    let archive = LockedArchive(url: c.url,
      sha256: parseSha256File(fetched.retrieved.body, c.fileName),
      archiveType: c.archiveType, build: c.build)
    let body = renderUpstreamArchiveRecord(archive, c.sha256Url)
    return RetrievedMetadata(url: c.sha256Url, body: body,
      integrity: narStyleTreeMultihash(@[(path: "body", content: body)]))
  raise newException(UpstreamArchiveError,
    "nim " & version & " has no release archive for " & platform &
    ": upstream answered 404 for " & looked.join(", ") & ". Is " & version &
    " a released Nim version? (the pin is the recipe's `uses: \"nim ==" &
    version & "\"`)")
