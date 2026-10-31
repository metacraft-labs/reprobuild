## C2 P1: parse the ``--source`` flag's
## ``apt:<pkgs>@<distro>/<suite>:<snapshot>`` mini-grammar.
##
## Accepted forms:
##
##   apt:git@debian/bookworm:20260601T000000Z
##   apt:{git,vim,curl}@debian/bookworm:20260601T000000Z
##   apt:prometheus-node-exporter@raspbian/trixie
##
## The last form names no snapshot: the archive has no snapshot service
## (Raspbian), so the harvester reads the archive given by ``--archive``
## and the closure lock it writes (``--emit-lock``) is the only pin. See
## ``reprobuild-pm/spec/ReproOS-Add-On-Mode.md`` §8.3 item 1.
##
## The brace-expansion form is the C2 "multi-package" mode: the
## harvester walks the union closure of the listed packages and emits
## one catalog file per transitive dep with no duplicates.

import std/[strutils]

type
  AptSourceSpec* = object
    distro*: string          ## always "debian" for now; "ubuntu"
                             ## reuses the same source-spec parser when
                             ## landed later
    suite*: string           ## "bookworm", "trixie", "sid", "noble", ...
    snapshot*: string        ## "20260601T000000Z" (Debian) or the
                             ## same-shape Ubuntu equivalent; "" when
                             ## the archive has no snapshot service
    archive*: string         ## archive base URL overriding the
                             ## snapshot.debian.org default ("" = default)
    packages*: seq[string]   ## non-empty list of root package names

  SourceSpecError* = object of CatchableError

proc parseAptSourceSpec*(raw: string): AptSourceSpec =
  ## Parses ``apt:<pkgs>@<distro>/<suite>:<snapshot>``. Raises
  ## ``SourceSpecError`` on a malformed input.
  if not raw.startsWith("apt:"):
    raise newException(SourceSpecError,
      "apt source spec must start with 'apt:'; got: " & raw)
  let rest = raw[4 .. ^1]
  let atIdx = rest.find('@')
  if atIdx < 0:
    raise newException(SourceSpecError,
      "apt source spec missing '@<distro>/<suite>:<snapshot>' after " &
      "the package list: " & raw)
  let pkgPart = rest[0 ..< atIdx]
  let tail = rest[atIdx + 1 .. ^1]
  let slashIdx = tail.find('/')
  if slashIdx < 0:
    raise newException(SourceSpecError,
      "apt source spec missing '/' between distro + suite: " & raw)
  let distro = tail[0 ..< slashIdx]
  let suiteAndSnap = tail[slashIdx + 1 .. ^1]
  let colonIdx = suiteAndSnap.find(':')
  var suite = suiteAndSnap
  var snapshot = ""
  if colonIdx >= 0:
    suite = suiteAndSnap[0 ..< colonIdx]
    snapshot = suiteAndSnap[colonIdx + 1 .. ^1]
    if snapshot.len == 0:
      raise newException(SourceSpecError,
        "apt source spec has an empty snapshot after ':': " & raw)

  result.distro = distro
  result.suite = suite
  result.snapshot = snapshot

  # Package list: single name or brace-enclosed comma-separated set.
  if pkgPart.len == 0:
    raise newException(SourceSpecError,
      "apt source spec has empty package list: " & raw)
  if pkgPart[0] == '{':
    if not pkgPart.endsWith("}"):
      raise newException(SourceSpecError,
        "apt source spec brace group not closed: " & raw)
    let inner = pkgPart[1 ..< pkgPart.len - 1]
    for raw2 in inner.split(','):
      let n = raw2.strip()
      if n.len == 0: continue
      result.packages.add(n)
    if result.packages.len == 0:
      raise newException(SourceSpecError,
        "apt source spec brace group is empty: " & raw)
  else:
    result.packages.add(pkgPart.strip())

  for f, val in fieldPairs(result):
    when val is string:
      if val.len == 0 and f notin ["snapshot", "archive"]:
        raise newException(SourceSpecError,
          "apt source spec has empty " & f & ": " & raw)

proc snapshotBaseUrl*(spec: AptSourceSpec): string =
  ## The archive base URL: ``spec.archive`` when given, otherwise
  ## ``https://snapshot.debian.org/archive/<distro>/<snapshot>``. A spec
  ## with neither names no archive and is refused.
  if spec.archive.len > 0:
    return spec.archive.strip(leading = false, chars = {'/'})
  if spec.snapshot.len == 0:
    raise newException(SourceSpecError,
      "apt source spec for " & spec.distro & "/" & spec.suite &
      " names no snapshot; pass --archive <url>")
  "https://snapshot.debian.org/archive/" & spec.distro & "/" &
    spec.snapshot

proc suiteBaseUrl*(spec: AptSourceSpec): string =
  spec.snapshotBaseUrl & "/dists/" & spec.suite

proc inReleaseUrl*(spec: AptSourceSpec): string =
  spec.suiteBaseUrl & "/InRelease"

proc packagesIndexUrl*(spec: AptSourceSpec; component = "main";
                      arch = "amd64"; compression = "xz"): string =
  spec.suiteBaseUrl & "/" & component & "/binary-" & arch &
    "/Packages." & compression

proc canonicalSnapshotPin*(spec: AptSourceSpec): string =
  ## Returns the snapshot pin string the catalog files store. Matches
  ## the B1 grammar (3 segments) which the C1 schema requires:
  ## ``<distro>/<suite>/<snapshot>``. Catalog emission needs a snapshot;
  ## a snapshot-less spec is refused by ``mkForeignPackageRef``.
  spec.distro & "/" & spec.suite & "/" & spec.snapshot
