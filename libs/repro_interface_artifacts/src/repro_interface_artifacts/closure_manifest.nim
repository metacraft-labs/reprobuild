## The closure-manifest grammar, shared by the publisher that inlines a
## manifest into a published record and the realization that unpacks it.
##
## A tarball record with ``closureManifest`` names a committed file of
## additional pinned archives realize unpacks into the prefix (an npm
## package's dependency closure). Spec: Federated-Catalog-Imports.md
## § Home profiles, "Decided 2026-11-17 (owner): option 1". The entries
## travel IN the record (envelope v34) so a consumer that reads only a
## catalog's ``published-interfaces/`` can realize the package without the
## file. This module is the one place that parses the grammar, so the
## producer and the consumer cannot disagree about what a line means.

import std/[os, sequtils, strutils]

type ClosureEntry* = object
  ## One archive the closure manifest names, and where it lands.
  path*: string    ## prefix-relative destination directory
  sha256*: string
  url*: string
  archiveType*: string   ## ``zip``, ``tar.gz`` or ``tar.xz``
  stripComponents*: int

const
  ## The entry a three-field line describes: npm publishes every package as
  ## a ``package/``-rooted gzip tarball.
  NpmClosureArchiveType* = "tar.gz"
  NpmClosureStripComponents* = 1
  ## The kinds a five-field line may name. Each is an archive the existing
  ## extractor unpacks with no provisioned extractor edge; an installer or an
  ## executable bootstrap is deliberately not one of them.
  ClosureArchiveTypes* = ["zip", "tar.gz", "tar.xz"]

proc closureSha256(value: string): string =
  result = value.strip().toLowerAscii()
  if result.startsWith("sha256:"):
    result = result["sha256:".len .. ^1]
  if result.len != 64 or result.anyIt(not (it in {'0' .. '9', 'a' .. 'f'})):
    raise newException(ValueError, "invalid sha256 digest: " & value)

proc normalizedClosureDestination*(path: string): string =
  ## The destination with ``\`` read as ``/`` and empty and ``.`` components
  ## dropped -- what two lines must not share, because the second would
  ## replace the first's tree. "" when the path is unsafe or names the prefix
  ## root itself: absolute, a drive or UNC path, or reaching a ``..``.
  let slashed = path.replace('\\', '/')
  if slashed.len == 0 or slashed.isAbsolute or slashed.startsWith("/") or
      (slashed.len >= 2 and slashed[0] in {'a' .. 'z', 'A' .. 'Z'} and
       slashed[1] == ':'):
    return ""
  var parts: seq[string] = @[]
  for part in slashed.split('/'):
    if part.len == 0 or part == ".":
      continue
    if part == "..":
      return ""
    parts.add(part)
  parts.join("/")

proc parseClosureStrip(text: string): int =
  ## A nonnegative decimal integer that fits the extractor's ``int``; -1
  ## otherwise. No sign, no radix prefix, no whitespace.
  if text.len == 0 or text.anyIt(it notin {'0' .. '9'}):
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return -1

proc parseClosureManifestText*(text, origin: string): seq[ClosureEntry] =
  ## ``<destination> <sha256> <url>`` (an npm archive: ``tar.gz``, one
  ## stripped component) or ``<destination> <sha256> <url> <archiveType>
  ## <stripComponents>`` per line; ``#`` comments and blank lines ignored.
  ## ``origin`` names the file in diagnostics.
  ##
  ## The WHOLE manifest is validated here, and every caller parses it before
  ## anything is fetched, so a malformed line costs no download.
  ##
  ## Deliberately a flat text format rather than JSON: it is GENERATED from
  ## a lock file and read by a human reviewing a dependency change, and a
  ## line-per-archive diff is what makes "one dependency moved" legible.
  var destinations: seq[string] = @[]
  for rawLine in text.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let parts = line.splitWhitespace()
    if parts.len != 3 and parts.len != 5:
      raise newException(ValueError,
        "tool-resolution failed: closure manifest line must be " &
        "\"<path> <sha256> <url>\" or \"<path> <sha256> <url> " &
        "<archiveType> <stripComponents>\": " & origin & ": " & line)
    let entryPath = parts[0].replace('\\', '/')
    let destination = normalizedClosureDestination(entryPath)
    if destination.len == 0:
      raise newException(ValueError,
        "tool-resolution failed: closure entry path must be relative and " &
        "inside the prefix: " & entryPath & " (" & origin & ": " & line & ")")
    if destination in destinations:
      raise newException(ValueError,
        "tool-resolution failed: two closure entries unpack to " &
        destination & ": " & origin & ": " & line)
    destinations.add(destination)
    var sha = ""
    try:
      sha = closureSha256(parts[1])
    except ValueError:
      raise newException(ValueError,
        "tool-resolution failed: closure entry sha256 is not a SHA-256 " &
        "digest: " & origin & ": " & line)
    var entry = ClosureEntry(path: entryPath, sha256: sha, url: parts[2],
      archiveType: NpmClosureArchiveType,
      stripComponents: NpmClosureStripComponents)
    if parts.len == 5:
      if parts[3] notin ClosureArchiveTypes:
        raise newException(ValueError,
          "tool-resolution failed: closure entry archiveType must be one of " &
          ClosureArchiveTypes.join(", ") & ": " & origin & ": " & line)
      let strip = parseClosureStrip(parts[4])
      if strip < 0:
        raise newException(ValueError,
          "tool-resolution failed: closure entry stripComponents must be a " &
          "nonnegative decimal integer: " & origin & ": " & line)
      # The zip arm strips by moving a single top-level directory up and
      # performs no deeper strip; refused here rather than after a download.
      if parts[3] == "zip" and strip > 1:
        raise newException(ValueError,
          "tool-resolution failed: closure entry stripComponents must be " &
          "0 or 1 for a zip archive: " & origin & ": " & line)
      entry.archiveType = parts[3]
      entry.stripComponents = strip
    result.add(entry)

proc canonicalClosureLine*(entry: ClosureEntry): string =
  ## An entry with the npm defaults is written as the three-field line, so an
  ## explicit ``tar.gz 1`` and the legacy line share one identity; any other
  ## kind or strip count is part of it.
  result = entry.path & " " & entry.sha256 & " " & entry.url
  if entry.archiveType != NpmClosureArchiveType or
      entry.stripComponents != NpmClosureStripComponents:
    result.add(" " & entry.archiveType & " " & $entry.stripComponents)
