## D2 P2: parse the pacman harvester's ``--source`` flag mini-grammar.
##
## Accepted forms:
##
##   pacman:htop@archlinux/rolling:20260601
##   pacman:{htop,fzf}@archlinux/rolling:20260601
##
## Arch's "release" is always ``rolling``; we still keep the slot in
## the spec so the snapshot pin matches the 3-segment B1 grammar.

import std/[strutils]

type
  PacmanSourceSpec* = object
    distro*: string          ## "archlinux" (canonical)
    release*: string         ## "rolling" (Arch is rolling-release)
    snapshot*: string        ## "20260601" (YYYYMMDD)
    packages*: seq[string]

  SourceSpecError* = object of CatchableError

const KnownPacmanDistros* = ["archlinux"]

proc parsePacmanSourceSpec*(raw: string): PacmanSourceSpec =
  if not raw.startsWith("pacman:"):
    raise newException(SourceSpecError,
      "pacman source spec must start with 'pacman:'; got: " & raw)
  let rest = raw[7 .. ^1]
  let atIdx = rest.find('@')
  if atIdx < 0:
    raise newException(SourceSpecError,
      "pacman source spec missing '@<distro>/<release>:<snapshot>': " &
      raw)
  let pkgPart = rest[0 ..< atIdx]
  let tail = rest[atIdx + 1 .. ^1]
  let slashIdx = tail.find('/')
  if slashIdx < 0:
    raise newException(SourceSpecError,
      "pacman source spec missing '/': " & raw)
  let distro = tail[0 ..< slashIdx]
  let releaseSnap = tail[slashIdx + 1 .. ^1]
  let colonIdx = releaseSnap.find(':')
  if colonIdx < 0:
    raise newException(SourceSpecError,
      "pacman source spec missing ':': " & raw)
  let release = releaseSnap[0 ..< colonIdx]
  let snapshot = releaseSnap[colonIdx + 1 .. ^1]

  result.distro = distro
  result.release = release
  result.snapshot = snapshot

  if pkgPart.len == 0:
    raise newException(SourceSpecError,
      "pacman source spec has empty package list: " & raw)
  if pkgPart[0] == '{':
    if not pkgPart.endsWith("}"):
      raise newException(SourceSpecError,
        "pacman source spec brace group not closed: " & raw)
    let inner = pkgPart[1 ..< pkgPart.len - 1]
    for raw2 in inner.split(','):
      let n = raw2.strip()
      if n.len == 0: continue
      result.packages.add(n)
    if result.packages.len == 0:
      raise newException(SourceSpecError,
        "pacman source spec brace group is empty: " & raw)
  else:
    result.packages.add(pkgPart.strip())

  for f, val in fieldPairs(result):
    when val is string:
      if val.len == 0:
        raise newException(SourceSpecError,
          "pacman source spec has empty " & f & ": " & raw)
  if result.distro notin KnownPacmanDistros:
    raise newException(SourceSpecError,
      "pacman source spec distro '" & result.distro &
      "' is not in the known set " & $KnownPacmanDistros)

# ---------------------------------------------------------------------------
# URL templates
# ---------------------------------------------------------------------------

const DefaultUpstream* = "archive.archlinux.org"

proc snapshotBaseUrl*(spec: PacmanSourceSpec;
                     upstream = DefaultUpstream;
                     repoName = "core"): string =
  ## The Arch archive layout is
  ## ``archive.archlinux.org/repos/<YYYY>/<MM>/<DD>/<repo>/os/x86_64``.
  ## We accept the snapshot in either ``YYYYMMDD`` or ``YYYY/MM/DD``
  ## form; canonicalise to slash-separated here.
  var dayPath = spec.snapshot
  if dayPath.len == 8 and not dayPath.contains('/'):
    dayPath = dayPath[0 ..< 4] & "/" & dayPath[4 ..< 6] & "/" &
      dayPath[6 ..< 8]
  return "https://" & upstream & "/repos/" & dayPath & "/" & repoName &
    "/os/x86_64"

proc repoDbUrl*(spec: PacmanSourceSpec; upstream = DefaultUpstream;
               repoName = "core"): string =
  ## URL of the ``<repo>.db`` tarball.
  snapshotBaseUrl(spec, upstream, repoName) & "/" & repoName & ".db"

proc canonicalSnapshotPin*(spec: PacmanSourceSpec): string =
  spec.distro & "/" & spec.release & "/" & spec.snapshot
